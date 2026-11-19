from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from verify_base_rootfs import ARCHITECTURES, validate_rootfs  # noqa: E402


def make_rootfs(root: Path, target_arch: str = "x86_64") -> None:
    expected = ARCHITECTURES[target_arch]["elf_machine"]
    for directory in (
        "etc", "usr/lib/systemd", "usr/bin", "sbin", "var/lib/dpkg"
    ):
        (root / directory).mkdir(parents=True, exist_ok=True)

    (root / "etc/os-release").write_text(
        'ID=debian\nVERSION_CODENAME=trixie\n',
        encoding="utf-8",
    )
    (root / "usr/lib/systemd/systemd").write_bytes(
        b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
        + struct.pack("<HH", 3, expected)
        + bytes(44)
    )
    (root / "usr/lib/systemd/systemd").chmod(0o755)
    (root / "sbin/init").symlink_to("../usr/lib/systemd/systemd")
    (root / "usr/bin/apt-get").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (root / "usr/bin/apt-get").chmod(0o755)
    (root / "var/lib/dpkg/status").write_text(
        "\n\n".join(
            f"Package: {name}\nStatus: install ok installed"
            for name in sorted({"apt", "dbus", "libc6", "systemd", "systemd-sysv"})
        ) + "\n",
        encoding="utf-8",
    )
    (root / "etc/shadow").write_text(
        "root:!:20000:0:99999:7:::\n", encoding="utf-8"
    )


class BaseRootfsTests(unittest.TestCase):
    def test_accepts_valid_rootfs_for_each_architecture(self) -> None:
        for target_arch in ARCHITECTURES:
            with self.subTest(target_arch=target_arch), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "rootfs"
                make_rootfs(root, target_arch)
                result = validate_rootfs(root, target_arch)
                self.assertEqual(result["status"], "ok")
                self.assertTrue(result["root_account_locked"])
                self.assertEqual(result["debian_arch"], ARCHITECTURES[target_arch]["debian"])

    def test_rejects_wrong_systemd_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root, "x86_64")
            with self.assertRaisesRegex(ValueError, "ELF machine"):
                validate_rootfs(root, "aarch64")

    def test_rejects_non_debian_rootfs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/os-release").write_text("ID=alpine\nVERSION_CODENAME=trixie\n")
            with self.assertRaisesRegex(ValueError, "not identified as Debian"):
                validate_rootfs(root, "x86_64")

    def test_rejects_wrong_suite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/os-release").write_text("ID=debian\nVERSION_CODENAME=bookworm\n")
            with self.assertRaisesRegex(ValueError, "expected 'trixie'"):
                validate_rootfs(root, "x86_64")

    def test_rejects_missing_systemd_init_link(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "sbin/init").unlink()
            with self.assertRaisesRegex(ValueError, "/sbin/init must be a symlink"):
                validate_rootfs(root, "x86_64")

    def test_rejects_unlocked_root_account(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/shadow").write_text("root::20000:0:99999:7:::\n")
            with self.assertRaisesRegex(ValueError, "password-locked"):
                validate_rootfs(root, "x86_64")

    def test_rejects_missing_required_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "var/lib/dpkg/status").write_text("Package: apt\nStatus: install ok installed\n")
            with self.assertRaisesRegex(ValueError, "required Debian packages"):
                validate_rootfs(root, "x86_64")

    def test_rejects_unknown_target_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            with self.assertRaisesRegex(ValueError, "unsupported target architecture"):
                validate_rootfs(root, "mips64")


if __name__ == "__main__":
    unittest.main()
