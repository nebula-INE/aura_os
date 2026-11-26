#!/usr/bin/env python3
"""Validate the minimum contract of an Aura OS Debian base root filesystem."""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from pathlib import Path
from typing import Any

ARCHITECTURES = {
    "x86_64": {"debian": "amd64", "elf_machine": 62},
    "aarch64": {"debian": "arm64", "elf_machine": 183},
    "riscv64": {"debian": "riscv64", "elf_machine": 243},
}
REQUIRED_PACKAGES = {
    "apt",
    "dbus",
    "debian-archive-keyring",
    "fdisk",
    "gzip",
    "kmod",
    "libc6",
    "openssl",
    "passwd",
    "sudo",
    "systemd",
    "systemd-resolved",
    "systemd-sysv",
    "systemd-timesyncd",
    "tar",
    "udev",
}


def _read_os_release(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"').strip("'")
    return values


def _installed_packages(status_path: Path) -> set[str]:
    installed: set[str] = set()
    if not status_path.is_file():
        return installed

    for paragraph in status_path.read_text(
        encoding="utf-8", errors="replace"
    ).split("\n\n"):
        fields: dict[str, str] = {}
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")) or ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key] = value.strip()
        if fields.get("Status") == "install ok installed" and fields.get("Package"):
            installed.add(fields["Package"])
    return installed


def _read_elf_machine(path: Path) -> int:
    try:
        header = path.read_bytes()[:64]
    except OSError as exc:
        raise ValueError(f"cannot read systemd executable: {exc}") from exc

    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise ValueError("systemd executable is not a valid ELF file")
    if header[4] != 2:
        raise ValueError("systemd executable is not ELF64")
    if header[5] != 1:
        raise ValueError("systemd executable is not little-endian")
    return struct.unpack_from("<H", header, 18)[0]


def _resolve_rootfs_absolute_symlink(rootfs: Path, link: Path) -> Path:
    """Resolve an absolute target symlink as if rootfs were the target's /."""
    target = os.readlink(link)
    if os.path.isabs(target):
        candidate = rootfs / target.lstrip("/")
    else:
        candidate = link.parent / target
    return candidate.resolve(strict=True)


def _validate_enabled_systemd_unit(
    root: Path,
    unit_name: str,
    target_name: str = "multi-user.target",
    wants_directory: str = "etc/systemd/system",
) -> None:
    unit = root / "usr/lib/systemd/system" / unit_name
    if not unit.is_file():
        raise ValueError(f"root filesystem is missing systemd unit {unit_name}")
    link = root / wants_directory / f"{target_name}.wants" / unit_name
    if not link.is_symlink():
        raise ValueError(f"{unit_name} must be enabled for {target_name}")
    try:
        target = _resolve_rootfs_absolute_symlink(root, link)
    except OSError as exc:
        raise ValueError(f"{unit_name} enablement link is broken: {exc}") from exc
    if target != unit.resolve(strict=True):
        raise ValueError(f"{unit_name} enablement link points to the wrong unit")


def validate_rootfs(
    rootfs: str | Path, target_arch: str, suite: str = "trixie"
) -> dict[str, Any]:
    root = Path(rootfs)
    if not root.is_dir():
        raise ValueError(f"root filesystem directory does not exist: {root}")

    if target_arch not in ARCHITECTURES:
        raise ValueError(f"unsupported target architecture: {target_arch}")
    expected = ARCHITECTURES[target_arch]

    os_release_path = root / "etc/os-release"
    if not os_release_path.is_file():
        raise ValueError("root filesystem is missing /etc/os-release")
    os_release = _read_os_release(os_release_path)
    if os_release.get("ID") != "debian":
        raise ValueError("base root filesystem is not identified as Debian")
    if os_release.get("VERSION_CODENAME") != suite:
        raise ValueError(
            f"Debian codename is {os_release.get('VERSION_CODENAME')!r}, expected {suite!r}"
        )

    systemd_path = root / "usr/lib/systemd/systemd"
    if not systemd_path.is_file() or not os.access(systemd_path, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/lib/systemd/systemd")
    machine = _read_elf_machine(systemd_path)
    if machine != expected["elf_machine"]:
        raise ValueError(
            f"systemd ELF machine is {machine}, expected {expected['elf_machine']} "
            f"for {target_arch}"
        )

    init_link = root / "sbin/init"
    if not init_link.is_symlink():
        raise ValueError("/sbin/init must be a symlink to the systemd init binary")
    try:
        init_target = _resolve_rootfs_absolute_symlink(root, init_link)
    except OSError as exc:
        raise ValueError(f"/sbin/init symlink is broken: {exc}") from exc
    expected_systemd = systemd_path.resolve(strict=True)
    if init_target != expected_systemd:
        raise ValueError(
            f"/sbin/init points to {init_target}, not the systemd init binary"
        )

    apt_get = root / "usr/bin/apt-get"
    if not apt_get.is_file() or not os.access(apt_get, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/bin/apt-get")

    diagnostics_tool = root / "usr/bin/aura-diagnose"
    if not diagnostics_tool.is_file() or not os.access(diagnostics_tool, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/bin/aura-diagnose")
    try:
        with diagnostics_tool.open("r", encoding="utf-8") as stream:
            diagnostics_header = stream.readline().rstrip("\n")
    except (OSError, UnicodeDecodeError) as exc:
        raise ValueError(f"cannot read /usr/bin/aura-diagnose: {exc}") from exc
    if diagnostics_header != "#!/bin/sh":
        raise ValueError("/usr/bin/aura-diagnose must use the portable /bin/sh interpreter")

    installed = _installed_packages(root / "var/lib/dpkg/status")
    missing = sorted(REQUIRED_PACKAGES - installed)
    if missing:
        raise ValueError(f"required Debian packages are not installed: {', '.join(missing)}")

    firstboot_program = root / "usr/lib/aura/aura-firstboot"
    if not firstboot_program.is_file():
        raise ValueError("root filesystem is missing /usr/lib/aura/aura-firstboot")
    firstboot_unit = root / "etc/systemd/system/aura-firstboot.service"
    if not firstboot_unit.is_file():
        raise ValueError("root filesystem is missing the aura-firstboot systemd unit")
    firstboot_link = (
        root / "etc/systemd/system/multi-user.target.wants/aura-firstboot.service"
    )
    if not firstboot_link.is_symlink():
        raise ValueError("aura-firstboot.service must be enabled for multi-user.target")
    try:
        firstboot_target = _resolve_rootfs_absolute_symlink(root, firstboot_link)
    except OSError as exc:
        raise ValueError(f"aura-firstboot.service enablement link is broken: {exc}") from exc
    if firstboot_target != firstboot_unit.resolve(strict=True):
        raise ValueError("aura-firstboot.service enablement link points to the wrong unit")

    recovery_target = root / "etc/systemd/system/aura-recovery.target"
    if not recovery_target.is_file():
        raise ValueError("root filesystem is missing /etc/systemd/system/aura-recovery.target")
    recovery_text = recovery_target.read_text(encoding="utf-8")
    for setting in (
        "Requires=basic.target",
        "Wants=systemd-user-sessions.service getty.target",
        "Wants=aura-firstboot.service aura-recovery-banner.service",
        "Conflicts=multi-user.target graphical.target",
        "AllowIsolate=yes",
    ):
        if setting not in recovery_text:
            raise ValueError(f"aura-recovery.target is missing {setting}")

    recovery_banner = root / "usr/lib/aura/recovery/aura-recovery-banner"
    if not recovery_banner.is_file() or not os.access(recovery_banner, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/lib/aura/recovery/aura-recovery-banner")
    recovery_banner_unit = root / "etc/systemd/system/aura-recovery-banner.service"
    if not recovery_banner_unit.is_file():
        raise ValueError("root filesystem is missing aura-recovery-banner.service")

    recovery_wants = root / "etc/systemd/system/aura-recovery.target.wants"
    for unit_name, unit_path in (
        ("aura-firstboot.service", firstboot_unit),
        ("aura-recovery-banner.service", recovery_banner_unit),
    ):
        link = recovery_wants / unit_name
        if not link.is_symlink():
            raise ValueError(f"{unit_name} must be enabled for aura-recovery.target")
        try:
            target = _resolve_rootfs_absolute_symlink(root, link)
        except OSError as exc:
            raise ValueError(f"{unit_name} recovery enablement link is broken: {exc}") from exc
        if target != unit_path.resolve(strict=True):
            raise ValueError(f"{unit_name} recovery enablement link points to the wrong unit")

    # udev must enumerate QEMU's virtio NIC before networkd can configure it.
    udevd = root / "usr/lib/systemd/systemd-udevd"
    if not udevd.is_file() or not os.access(udevd, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/lib/systemd/systemd-udevd")
    modprobe = root / "usr/sbin/modprobe"
    if not modprobe.is_file() or not os.access(modprobe, os.X_OK):
        raise ValueError("root filesystem is missing executable /usr/sbin/modprobe")
    _validate_enabled_systemd_unit(
        root, "systemd-udevd.service", "sysinit.target", "usr/lib/systemd/system"
    )
    _validate_enabled_systemd_unit(
        root, "systemd-udev-trigger.service", "sysinit.target", "usr/lib/systemd/system"
    )

    # systemd-networkd handles wired Ethernet using DHCP and IPv6 RA.
    network_config = root / "etc/systemd/network/20-wired.network"
    if not network_config.is_file():
        raise ValueError("root filesystem is missing /etc/systemd/network/20-wired.network")
    network_text = network_config.read_text(encoding="utf-8")
    for setting in ("Type=ether", "DHCP=yes", "IPv6AcceptRA=yes", "LinkLocalAddressing=ipv6"):
        if setting not in network_text:
            raise ValueError(f"wired network configuration is missing {setting}")
    _validate_enabled_systemd_unit(root, "systemd-networkd.service")
    _validate_enabled_systemd_unit(root, "systemd-resolved.service")
    _validate_enabled_systemd_unit(root, "systemd-timesyncd.service")

    timesyncd_config = root / "etc/systemd/timesyncd.conf.d/20-aura.conf"
    if not timesyncd_config.is_file():
        raise ValueError("root filesystem is missing the Aura timesyncd fallback configuration")
    if "FallbackNTP=0.debian.pool.ntp.org" not in timesyncd_config.read_text(encoding="utf-8"):
        raise ValueError("timesyncd fallback configuration must use the Debian NTP pool")

    resolv_conf = root / "etc/resolv.conf"
    if not resolv_conf.is_symlink():
        raise ValueError("/etc/resolv.conf must point to the systemd-resolved stub resolver")
    if os.readlink(resolv_conf) != "../run/systemd/resolve/stub-resolv.conf":
        raise ValueError("/etc/resolv.conf must use the systemd-resolved stub resolver")

    shadow = root / "etc/shadow"
    if not shadow.is_file():
        raise ValueError("root filesystem is missing /etc/shadow")
    root_entry = next(
        (line for line in shadow.read_text(encoding="utf-8").splitlines()
         if line.startswith("root:")),
        None,
    )
    if root_entry is None:
        raise ValueError("root account is missing from /etc/shadow")
    root_password = root_entry.split(":", 2)[1]
    if not root_password.startswith(("!", "*")):
        raise ValueError("root account must remain password-locked in the base image")

    return {
        "status": "ok",
        "target_arch": target_arch,
        "debian_arch": expected["debian"],
        "debian_suite": suite,
        "systemd_elf_machine": machine,
        "init": "systemd",
        "package_manager": "apt/dpkg",
        "diagnostics": "aura-diagnose (read-only archive)",
        "required_packages": sorted(REQUIRED_PACKAGES),
        "device_management": "udev",
        "kernel_module_loader": "kmod",
        "wired_network": "systemd-networkd DHCP and IPv6 RA",
        "dns": "systemd-resolved",
        "time_sync": "systemd-timesyncd",
        "root_account_locked": True,
        "desktop_installed": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the architecture and security contract of an Aura Debian rootfs."
    )
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--target-arch", required=True, choices=sorted(ARCHITECTURES))
    parser.add_argument("--suite", default="trixie")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = validate_rootfs(args.rootfs, args.target_arch, args.suite)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(
            "Valid Aura OS base rootfs: "
            f"{result['target_arch']} ({result['debian_arch']}), "
            f"Debian {result['debian_suite']}, "
            f"systemd ELF machine {result['systemd_elf_machine']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
