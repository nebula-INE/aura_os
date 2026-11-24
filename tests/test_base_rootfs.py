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
        "etc", "usr/lib/systemd", "usr/lib/systemd/system", "usr/lib/systemd/system/sysinit.target.wants",
        "usr/lib/aura", "usr/bin", "usr/sbin", "sbin", "var/lib/dpkg",
        "etc/systemd/system/multi-user.target.wants", "etc/systemd/network", "etc/systemd/timesyncd.conf.d"
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
    (root / "usr/bin/aura-diagnose").write_text(
        "#!/bin/sh\\nexit 0\\n", encoding="utf-8"
    )
    (root / "usr/bin/aura-diagnose").chmod(0o755)
    (root / "usr/lib/systemd/systemd-udevd").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (root / "usr/lib/systemd/systemd-udevd").chmod(0o755)
    (root / "usr/sbin/modprobe").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (root / "usr/sbin/modprobe").chmod(0o755)
    (root / "var/lib/dpkg/status").write_text(
        "\n\n".join(
            f"Package: {name}\nStatus: install ok installed"
            for name in sorted({"apt", "dbus", "debian-archive-keyring", "gzip", "kmod", "libc6", "passwd", "sudo", "systemd", "systemd-resolved", "systemd-sysv", "systemd-timesyncd", "tar", "udev"})
        ) + "\n",
        encoding="utf-8",
    )
    (root / "usr/lib/aura/aura-firstboot").write_text(
        "#!/bin/bash\\nexit 0\\n", encoding="utf-8"
    )
    (root / "etc/systemd/system/aura-firstboot.service").write_text(
        "[Service]\\nExecStart=/bin/bash /usr/lib/aura/aura-firstboot\\n",
        encoding="utf-8",
    )
    (
        root / "etc/systemd/system/multi-user.target.wants/aura-firstboot.service"
    ).symlink_to("/etc/systemd/system/aura-firstboot.service")
    (root / "etc/shadow").write_text(
        "root:!:20000:0:99999:7:::\n", encoding="utf-8"
    )
    for unit in ("systemd-networkd.service", "systemd-resolved.service", "systemd-timesyncd.service"):
        (root / "usr/lib/systemd/system" / unit).write_text("[Service]\n", encoding="utf-8")
        (root / "etc/systemd/system/multi-user.target.wants" / unit).symlink_to(
            f"/usr/lib/systemd/system/{unit}"
        )
    for unit in ("systemd-udevd.service", "systemd-udev-trigger.service"):
        (root / "usr/lib/systemd/system" / unit).write_text("[Service]\n", encoding="utf-8")
        (root / "usr/lib/systemd/system/sysinit.target.wants" / unit).symlink_to(
            f"../{unit}"
        )
    (root / "etc/systemd/network/20-wired.network").write_text(
        "[Match]\nType=ether\n[Network]\nDHCP=yes\nIPv6AcceptRA=yes\nLinkLocalAddressing=ipv6\n",
        encoding="utf-8",
    )
    (root / "etc/systemd/timesyncd.conf.d/20-aura.conf").write_text(
        "[Time]\nFallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org\n",
        encoding="utf-8",
    )
    (root / "etc/resolv.conf").symlink_to("../run/systemd/resolve/stub-resolv.conf")



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

    def test_rejects_missing_firstboot_service(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "usr/lib/aura/aura-firstboot").unlink()
            with self.assertRaisesRegex(ValueError, "missing /usr/lib/aura/aura-firstboot"):
                validate_rootfs(root, "x86_64")

    def test_rejects_disabled_firstboot_service(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (
                root / "etc/systemd/system/multi-user.target.wants/aura-firstboot.service"
            ).unlink()
            with self.assertRaisesRegex(ValueError, "must be enabled"):
                validate_rootfs(root, "x86_64")

    def test_rejects_missing_wired_network_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/systemd/network/20-wired.network").unlink()
            with self.assertRaisesRegex(ValueError, "20-wired.network"):
                validate_rootfs(root, "x86_64")

    def test_rejects_disabled_network_service(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/systemd/system/multi-user.target.wants/systemd-networkd.service").unlink()
            with self.assertRaisesRegex(ValueError, "systemd-networkd.service must be enabled"):
                validate_rootfs(root, "x86_64")

    def test_rejects_unmanaged_resolv_conf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            (root / "etc/resolv.conf").unlink()
            (root / "etc/resolv.conf").write_text("nameserver 1.1.1.1\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "systemd-resolved stub"):
                validate_rootfs(root, "x86_64")

    def test_rejects_missing_timesyncd_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            status = root / "var/lib/dpkg/status"
            packages = {"apt", "dbus", "debian-archive-keyring", "kmod", "libc6", "passwd", "sudo", "systemd", "systemd-resolved", "systemd-sysv", "udev"}
            status.write_text(
                "\n\n".join(
                    f"Package: {name}\nStatus: install ok installed"
                    for name in sorted(packages)
                ) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "systemd-timesyncd"):
                validate_rootfs(root, "x86_64")

    def test_qemu_user_network_explicitly_enables_dual_stack_dhcp(self) -> None:
        script = (SCRIPTS_DIR / "test-base-rootfs-qemu.sh").read_text(encoding="utf-8")
        expected = (
            "-netdev user,id=auranet,ipv4=on,ipv6=on,"
            "net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15,dns=10.0.2.3"
        )
        self.assertEqual(script.count(expected), 3)

    def test_rejects_unknown_target_architecture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "rootfs"
            make_rootfs(root)
            with self.assertRaisesRegex(ValueError, "unsupported target architecture"):
                validate_rootfs(root, "mips64")


if __name__ == "__main__":
    unittest.main()
