from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ACTIVATE = ROOT / "system/base/kernel/activate-kernel"
CONFIRM = ROOT / "system/base/kernel/confirm-boot"
PRERM = ROOT / "system/base/kernel/image-prerm"


class KernelLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "root"
        self.bin = Path(self.temp.name) / "bin"
        self.log = Path(self.temp.name) / "commands.log"
        self.bin.mkdir()
        (self.root / "usr/share/aura-kernel").mkdir(parents=True)
        (self.root / "usr/lib/aura-kernel").mkdir(parents=True)
        (self.root / "boot/grub").mkdir(parents=True)
        (self.root / "var/lib/aura-kernel").mkdir(parents=True)
        (self.root / "boot/vmlinuz-aura-6.18.63").write_bytes(b"known-good")
        (self.root / "boot/vmlinuz-aura-6.18.64").write_bytes(b"candidate")
        (self.root / "usr/share/aura-kernel/current-version").write_text(
            "6.18.64\n", encoding="ascii"
        )
        (self.root / "var/lib/aura-kernel/known-good").write_text(
            "6.18.63\n", encoding="ascii"
        )
        menu = self.root / "usr/lib/aura-kernel/update-grub-menu"
        menu.write_text(
            "#!/bin/sh\nprintf 'menu:update\\n' >> \"$AURA_TEST_LOG\"\n",
            encoding="utf-8",
        )
        menu.chmod(0o755)
        self.command("grub-editenv", 'touch "$1"\nprintf \'editenv:%s:%s\\n\' "$1" "$2" >> "$AURA_TEST_LOG"')
        self.command("grub-set-default", 'printf \'default:%s\\n\' "$1" >> "$AURA_TEST_LOG"')
        self.command("grub-reboot", 'printf \'reboot:%s\\n\' "$1" >> "$AURA_TEST_LOG"')
        self.command("apt-mark", 'printf \'apt-mark:%s\\n\' "$*" >> "$AURA_TEST_LOG"')
        self.command("apt-cache", 'printf "Package: %s\\n" "$2"')
        self.command(
            "dpkg-query",
            'printf \'aura-kernel-image-6.18.63\\naura-kernel-image-6.18.64\\n\'',
        )
        self.command("uname", 'printf \'%s\\n\' "$FAKE_UNAME_RELEASE"')

    def tearDown(self) -> None:
        self.temp.cleanup()

    def command(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def env(self, **extra: str) -> dict[str, str]:
        values = os.environ.copy()
        values.update(
            {
                "AURA_ROOT": str(self.root),
                "AURA_TEST_LOG": str(self.log),
                "PATH": f"{self.bin}:{os.environ.get('PATH', '')}",
                "FAKE_UNAME_RELEASE": "6.18.63",
            }
        )
        values.update(extra)
        return values

    def run_script(
        self, script: Path, args: list[str] | None = None, **env: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", str(script), *(args or [])],
            cwd=ROOT,
            env=self.env(**env),
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def log_lines(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_update_stages_candidate_once_and_keeps_known_good_default(self) -> None:
        result = self.run_script(ACTIVATE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.root / "var/lib/aura-kernel/pending").read_text(encoding="ascii"),
            "6.18.64\n",
        )
        self.assertEqual(
            (self.root / "var/lib/aura-kernel/known-good").read_text(encoding="ascii"),
            "6.18.63\n",
        )
        self.assertTrue((self.root / "boot/grub/grubenv").is_file())
        log = self.log_lines()
        self.assertIn("menu:update", log)
        self.assertIn("default:aura-6.18.63", log)
        self.assertIn("reboot:aura-6.18.64", log)
        self.assertTrue(any(line.startswith("apt-mark:manual") for line in log))

    def test_offline_dpkg_install_skips_apt_mark_when_package_indexes_are_missing(self) -> None:
        self.command("apt-cache", "exit 1")
        result = self.run_script(ACTIVATE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot:aura-6.18.64", self.log_lines())
        self.assertFalse(any(line.startswith("apt-mark:") for line in self.log_lines()))

    def test_old_kernel_boot_does_not_confirm_pending_candidate(self) -> None:
        (self.root / "var/lib/aura-kernel/pending").write_text(
            "6.18.64\n", encoding="ascii"
        )
        result = self.run_script(CONFIRM, FAKE_UNAME_RELEASE="6.18.63")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.root / "var/lib/aura-kernel/pending").read_text(encoding="ascii"),
            "6.18.64\n",
        )
        self.assertEqual(
            (self.root / "var/lib/aura-kernel/known-good").read_text(encoding="ascii"),
            "6.18.63\n",
        )
        self.assertFalse(any(line.startswith("default:") for line in self.log_lines()))

    def test_candidate_kernel_boot_confirms_new_saved_default(self) -> None:
        (self.root / "var/lib/aura-kernel/pending").write_text(
            "6.18.64\n", encoding="ascii"
        )
        result = self.run_script(CONFIRM, FAKE_UNAME_RELEASE="6.18.64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "var/lib/aura-kernel/pending").exists())
        self.assertEqual(
            (self.root / "var/lib/aura-kernel/known-good").read_text(encoding="ascii"),
            "6.18.64\n",
        )
        self.assertIn("default:aura-6.18.64", self.log_lines())

    def test_pending_and_known_good_kernel_packages_cannot_be_removed(self) -> None:
        (self.root / "var/lib/aura-kernel/pending").write_text(
            "6.18.64\n", encoding="ascii"
        )
        for version in ("6.18.63", "6.18.64"):
            result = self.run_script(
                PRERM,
                ["remove"],
                DPKG_MAINTSCRIPT_PACKAGE=f"aura-kernel-image-{version}",
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing to remove Aura kernel", result.stderr)

    def test_unsafe_override_is_explicit_and_still_requires_another_image(self) -> None:
        result = self.run_script(
            PRERM,
            ["remove"],
            DPKG_MAINTSCRIPT_PACKAGE="aura-kernel-image-6.18.63",
            AURA_KERNEL_ALLOW_UNSAFE_REMOVE="1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_last_kernel_with_localversion_suffix_is_not_mistaken_for_another_image(self) -> None:
        for image in (self.root / "boot").glob("vmlinuz-aura-*"):
            image.unlink()
        (self.root / "boot/vmlinuz-aura-6.18.64-custom1").write_bytes(b"only kernel")
        (self.root / "var/lib/aura-kernel/known-good").unlink()
        result = self.run_script(
            PRERM,
            ["remove"],
            DPKG_MAINTSCRIPT_PACKAGE="aura-kernel-image-6.18.64-custom1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("last installed Aura kernel", result.stderr)

    def test_last_installed_kernel_cannot_be_removed_without_override(self) -> None:
        only = self.root / "boot/vmlinuz-aura-6.18.64"
        (self.root / "boot/vmlinuz-aura-6.18.63").unlink()
        (self.root / "var/lib/aura-kernel/known-good").unlink()
        (self.root / "var/lib/aura-kernel/pending").unlink(missing_ok=True)
        result = self.run_script(
            PRERM,
            ["remove"],
            DPKG_MAINTSCRIPT_PACKAGE="aura-kernel-image-6.18.64",
        )
        self.assertTrue(only.is_file())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("last installed Aura kernel", result.stderr)


if __name__ == "__main__":
    unittest.main()
