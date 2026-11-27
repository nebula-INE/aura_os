from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from install_desktop_profile import DESKTOP_PACKAGES, install_desktop_profile  # noqa: E402
from test_base_rootfs import make_rootfs  # noqa: E402
from verify_base_rootfs import validate_rootfs  # noqa: E402


class DesktopProfileTests(unittest.TestCase):
    def make_desktop_rootfs(self, root: Path) -> None:
        make_rootfs(root)
        status = root / "var/lib/dpkg/status"
        paragraphs = [
            f"Package: {name}\nStatus: install ok installed"
            for name in sorted(DESKTOP_PACKAGES)
        ]
        status.write_text(
            status.read_text(encoding="utf-8").rstrip()
            + "\n\n" + "\n\n".join(paragraphs) + "\n",
            encoding="utf-8",
        )
        systemd = root / "usr/lib/systemd/system"
        (systemd / "graphical.target").write_text(
            "[Unit]\nDescription=Graphical target\n", encoding="utf-8"
        )
        (systemd / "greetd.service").write_text(
            "[Service]\nExecStart=/usr/sbin/greetd\n", encoding="utf-8"
        )

    def test_package_manifest_matches_profile(self) -> None:
        manifest = ROOT / "system/desktop/packages.txt"
        packages = {
            line.strip() for line in manifest.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertEqual(packages, DESKTOP_PACKAGES)

    def test_installs_session_and_graphical_login(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            root.mkdir()
            self.make_desktop_rootfs(root)
            install_desktop_profile(root, ROOT)

            default = root / "etc/systemd/system/default.target"
            self.assertEqual(default.readlink().as_posix(),
                             "/usr/lib/systemd/system/graphical.target")
            greetd_link = root / "etc/systemd/system/graphical.target.wants/greetd.service"
            self.assertEqual(greetd_link.readlink().as_posix(),
                             "/usr/lib/systemd/system/greetd.service")
            self.assertTrue((root / "usr/share/wayland-sessions/aura.desktop").is_file())
            self.assertTrue((root / "usr/lib/aura/desktop/session").stat().st_mode & 0o111)
            self.assertTrue((root / "etc/xdg/labwc/autostart").stat().st_mode & 0o111)

            for relative in (
                "usr/bin/aura-launcher",
                "usr/bin/aura-settings",
                "usr/lib/aura/desktop/aura-wallpaper",
            ):
                program = root / relative
                self.assertTrue(program.is_file(), relative)
                self.assertTrue(program.stat().st_mode & 0o111, relative)
                subprocess.run(["sh", "-n", str(program)], check=True)

            settings_entry = root / "usr/share/applications/aura-settings.desktop"
            settings_text = settings_entry.read_text(encoding="utf-8")
            self.assertIn("Name=Aura Settings", settings_text)
            self.assertIn("Exec=aura-settings", settings_text)
            self.assertIn("Terminal=false", settings_text)

            rc_root = ET.parse(root / "etc/xdg/labwc/rc.xml").getroot()
            keybinds = {
                node.attrib.get("key")
                for node in rc_root.findall("./keyboard/keybind")
            }
            self.assertIn("W-S-q", keybinds)
            self.assertIn("W-d", keybinds)
            self.assertIn("W-F10", keybinds)
            self.assertNotIn("W-Shift-q", keybinds)
            waybar = json.loads((root / "etc/xdg/waybar/config").read_text())
            self.assertIn("clock", waybar["modules-center"])
            self.assertIn("network", waybar["modules-right"])
            greetd = (root / "etc/greetd/config.toml").read_text()
            self.assertIn("tuigreet", greetd)
            self.assertIn("/usr/lib/aura/desktop/session", greetd)

            subprocess.run(["sh", "-n", str(root / "usr/lib/aura/desktop/session")], check=True)
            subprocess.run(["sh", "-n", str(root / "etc/xdg/labwc/autostart")], check=True)
            result = validate_rootfs(root, "x86_64", desktop_profile=True)
            self.assertTrue(result["desktop_installed"])
            self.assertEqual(result["desktop_profile"], "labwc-wayland")

    def test_installation_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            root.mkdir()
            self.make_desktop_rootfs(root)
            install_desktop_profile(root, ROOT)
            install_desktop_profile(root, ROOT)
            self.assertTrue((root / "etc/systemd/system/default.target").is_symlink())

    def test_rejects_missing_packages_before_copying_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            root.mkdir()
            self.make_desktop_rootfs(root)
            status = root / "var/lib/dpkg/status"
            status.write_text(
                status.read_text().replace(
                    "Package: labwc\nStatus: install ok installed\n\n", ""
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "labwc"):
                install_desktop_profile(root, ROOT)
            self.assertFalse((root / "etc/greetd/config.toml").exists())

    def test_rejects_non_debian_rootfs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            (root / "etc").mkdir(parents=True)
            (root / "etc/os-release").write_text("ID=alpine\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Debian root filesystem"):
                install_desktop_profile(root, ROOT)

    def test_rejects_host_root(self) -> None:
        with self.assertRaisesRegex(ValueError, "host root filesystem"):
            install_desktop_profile(Path("/"), ROOT)


if __name__ == "__main__":
    unittest.main()
