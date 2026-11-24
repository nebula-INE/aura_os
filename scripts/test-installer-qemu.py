#!/usr/bin/env python3
"""Install Aura OS to a disposable QEMU disk, then boot the installed disk."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pexpect


ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = ROOT / "build" / "qemu-installer"


def require_file(path: Path, description: str) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"required {description} is missing or empty: {path}")


def report_serial_log_tail(log_path: Path, *, max_lines: int = 160) -> None:
    """Print the guest serial failure context into the GitHub Actions job log."""
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        print(f"Could not read serial log {log_path}: {exc}", file=sys.stderr)
        return
    print(
        f"\n===== Last {min(max_lines, len(lines))} lines of {log_path} =====",
        file=sys.stderr,
    )
    for line in lines[-max_lines:]:
        print(line, file=sys.stderr)
    print(f"===== End of {log_path} =====\n", file=sys.stderr)


def qemu_profile(
    architecture: str,
    disk: Path,
    firmware_vars: Path,
    *,
    iso: Path | None,
) -> tuple[str, list[str]]:
    target_boot_index = "2" if iso is not None else "1"
    common = [
        "-m",
        "2048",
        "-smp",
        "2",
        "-display",
        "none",
        "-serial",
        "stdio",
        "-monitor",
        "none",
        "-no-reboot",
        "-drive",
        f"if=pflash,format=raw,unit=1,file={firmware_vars}",
    ]

    if architecture == "x86_64":
        binary = "qemu-system-x86_64"
        code = Path(os.environ.get("OVMF_CODE", "/usr/share/OVMF/OVMF_CODE_4M.fd"))
        args = [
            "-machine",
            "q35,accel=tcg",
            "-cpu",
            "qemu64",
            "-drive",
            f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
            "-drive",
            f"if=none,id=target,format=raw,file={disk},cache=none",
            "-device",
            f"virtio-blk-pci,drive=target,bootindex={target_boot_index}",
            "-netdev",
            "user,id=auranet,ipv4=on,ipv6=on,net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15,dns=10.0.2.3",
            "-device",
            "virtio-net-pci,netdev=auranet",
        ]
        if iso is not None:
            args += [
                "-device",
                "ich9-ahci,id=ahci",
                "-drive",
                f"if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file={iso}",
                "-device",
                "ide-cd,drive=cdrom,bus=ahci.1,bootindex=1",
                "-boot",
                "order=d",
            ]
        else:
            args += ["-boot", "order=c"]
        return binary, args + common

    if architecture == "aarch64":
        binary = "qemu-system-aarch64"
        code = Path(os.environ.get("AAVMF_CODE", "/usr/share/AAVMF/AAVMF_CODE.fd"))
        args = [
            "-machine",
            "virt,gic-version=3,accel=tcg",
            "-cpu",
            "cortex-a57",
            "-drive",
            f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
            "-drive",
            f"if=none,id=target,format=raw,file={disk},cache=none",
            "-device",
            f"virtio-blk-device,drive=target,bootindex={target_boot_index}",
            "-netdev",
            "user,id=auranet,ipv4=on,ipv6=on,net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15,dns=10.0.2.3",
            "-device",
            "virtio-net-device,netdev=auranet",
        ]
        if iso is not None:
            args += [
                "-device",
                "virtio-scsi-device,id=scsi0",
                "-drive",
                f"if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file={iso}",
                "-device",
                "scsi-cd,drive=cdrom,bus=scsi0.0,bootindex=1",
                "-boot",
                "order=d",
            ]
        else:
            args += ["-boot", "order=c"]
        return binary, args + common

    if architecture == "riscv64":
        binary = "qemu-system-riscv64"
        code = Path(
            os.environ.get(
                "RISCV_EFI_CODE", "/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd"
            )
        )
        vars_template = os.environ.get(
            "RISCV_EFI_VARS", "/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
        )
        # RISC-V firmware uses blockdev nodes rather than the x86 pflash syntax.
        common = [
            "-m",
            "2048",
            "-smp",
            "2",
            "-display",
            "none",
            "-serial",
            "stdio",
            "-monitor",
            "none",
            "-no-reboot",
            "-blockdev",
            f"node-name=pflash0,driver=file,read-only=on,filename={code}",
            "-blockdev",
            f"node-name=pflash1,driver=file,filename={firmware_vars}",
            "-drive",
            f"if=none,id=target,format=raw,file={disk},cache=none",
            "-device",
            f"virtio-blk-device,drive=target,bootindex={target_boot_index}",
            "-netdev",
            "user,id=auranet,ipv4=on,ipv6=on,net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15,dns=10.0.2.3",
            "-device",
            "virtio-net-device,netdev=auranet",
            "-machine",
            "virt,pflash0=pflash0,pflash1=pflash1,acpi=off,accel=tcg",
            "-cpu",
            "rv64",
        ]
        if iso is not None:
            common += [
                "-device",
                "virtio-scsi-device,id=scsi0",
                "-drive",
                f"if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file={iso}",
                "-device",
                "scsi-cd,drive=cdrom,bus=scsi0.0,bootindex=1",
                "-boot",
                "order=d",
            ]
        else:
            common += ["-boot", "order=c"]
        return binary, common

    raise ValueError(f"unsupported architecture: {architecture}")


def spawn_qemu(
    architecture: str,
    disk: Path,
    vars_template: Path,
    *,
    iso: Path | None,
    log_path: Path,
    timeout: int,
) -> pexpect.spawn:
    firmware_vars = LOG_DIR / f"{architecture}-{ 'installer' if iso else 'installed' }-vars.fd"
    shutil.copyfile(vars_template, firmware_vars)
    binary, args = qemu_profile(architecture, disk, firmware_vars, iso=iso)
    if shutil.which(binary) is None:
        raise RuntimeError(f"QEMU binary is not installed: {binary}")
    child = pexpect.spawn(
        binary,
        args=args,
        cwd=str(ROOT),
        encoding="utf-8",
        codec_errors="replace",
        timeout=timeout,
        env=os.environ.copy(),
    )
    child.logfile = log_path.open("w", encoding="utf-8")
    return child


def run_installer(architecture: str, iso: Path, disk: Path) -> None:
    if architecture == "x86_64":
        vars_template = Path(
            os.environ.get("OVMF_VARS", "/usr/share/OVMF/OVMF_VARS_4M.fd")
        )
    elif architecture == "aarch64":
        vars_template = Path(
            os.environ.get("AAVMF_VARS", "/usr/share/AAVMF/AAVMF_VARS.fd")
        )
    else:
        vars_template = Path(
            os.environ.get(
                "RISCV_EFI_VARS", "/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
            )
        )
    require_file(vars_template, "UEFI variables template")

    log_path = LOG_DIR / f"aura-{architecture}-installer.log"
    child = spawn_qemu(
        architecture,
        disk,
        vars_template,
        iso=iso,
        log_path=log_path,
        timeout=600,
    )
    try:
        child.expect("AURA_INSTALLER_READY")
        child.expect("Select the target disk number:")
        child.sendline("1")
        child.expect(r"Type ERASE (/dev/[A-Za-z0-9]+) to confirm:")
        target = child.match.group(1)
        child.sendline(f"ERASE {target}")
        child.expect("Final confirmation: type INSTALL AURA to begin writing:")
        child.sendline("INSTALL AURA")
        installer_result = child.expect(
            [
                "AURA_INSTALL_COMPLETE",
                "Installer stopped with an error",
                "ERROR:",
                r"(?m)^# ",
                pexpect.EOF,
            ],
            timeout=600,
        )
        if installer_result != 0:
            reasons = (
                "installer returned to the rescue shell",
                "installer reported an explicit error",
                "installer returned to the rescue shell prompt",
                "installer process exited before the success marker",
            )
            raise RuntimeError(
                f"{architecture} installer did not complete: "
                f"{reasons[installer_result - 1]}; see {log_path}"
            )
        child.sendline("")
        child.expect(pexpect.EOF, timeout=120)
        child.close()
        if child.exitstatus not in (0, None):
            raise RuntimeError(
                f"installer QEMU exited with status {child.exitstatus}; see {log_path}"
            )
    except Exception:
        if child.logfile:
            child.logfile.flush()
        child.close(force=True)
        report_serial_log_tail(log_path)
        raise
    finally:
        if child.logfile:
            child.logfile.close()


def run_installed_boot(architecture: str, disk: Path) -> None:
    if architecture == "x86_64":
        vars_template = Path(
            os.environ.get("OVMF_VARS", "/usr/share/OVMF/OVMF_VARS_4M.fd")
        )
    elif architecture == "aarch64":
        vars_template = Path(
            os.environ.get("AAVMF_VARS", "/usr/share/AAVMF/AAVMF_VARS.fd")
        )
    else:
        vars_template = Path(
            os.environ.get(
                "RISCV_EFI_VARS", "/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
            )
        )
    require_file(vars_template, "UEFI variables template")

    log_path = LOG_DIR / f"aura-{architecture}-installed-boot.log"
    child = spawn_qemu(
        architecture,
        disk,
        vars_template,
        iso=None,
        log_path=log_path,
        timeout=480,
    )
    password = "Aura-CI-Only-2026!"
    username = "auraci"
    initramfs_mode = "embedded-in-kernel" if architecture == "riscv64" else "external"
    grub_initrd_check = (
        "! grep -Eq '^[[:space:]]*initrd[[:space:]]' /boot/grub/grub.cfg"
        if architecture == "riscv64"
        else "grep -Eq '^[[:space:]]*initrd[[:space:]]+/boot/aura-initramfs.cpio.gz$' /boot/grub/grub.cfg"
    )

    try:
        root_boot_result = child.expect(
            [
                "AURA_ROOT_DEVICE_MATCHED",
                "Kernel panic",
                "ERROR:",
                pexpect.EOF,
            ],
            timeout=360,
        )
        if root_boot_result != 0:
            reasons = (
                "installed kernel panicked before the persistent-root init completed",
                "persistent-root initramfs reported an explicit error",
                "installed kernel exited before root UUID discovery",
            )
            raise RuntimeError(
                f"{architecture} installed disk did not reach persistent-root init: "
                f"{reasons[root_boot_result - 1]}; see {log_path}"
            )
        child.expect("New username")
        child.sendline(username)
        child.expect("New password:")
        child.sendline(password)
        child.expect("Retype new password:")
        child.sendline(password)
        child.expect("initial administrator account is ready")
        child.expect("login:")
        child.sendline(username)
        child.expect("Password:")
        child.sendline(password)
        child.expect(r"[$#] ")
        command = (
            "id -nG | tr ' ' '\\n' | grep -qx sudo && echo AURA_SUDO_GROUP_OK; "
            "systemctl is-active systemd-networkd.service; "
            "systemctl is-active systemd-resolved.service; "
            "network_ok=0; "
            "for attempt in $(seq 1 60); do "
            "if ip -4 -o addr show scope global | grep -q 'inet 10\\.0\\.2\\.' "
            "&& ip -4 route show default | grep -q '^default ' "
            "&& getent ahostsv4 deb.debian.org >/dev/null 2>&1; then "
            "network_ok=1; break; fi; sleep 2; done; "
            "test \"$network_ok\" -eq 1 && echo AURA_NETWORK_OK; "
            "sudo -S sh -c 'test -s /var/lib/aura/firstboot/complete "
            "&& passwd -S root | grep -q \"^root L \" "
            "&& root_uuid=$(findmnt -n -o UUID /) "
            "&& grep -Fxq \"UUID=$root_uuid / ext4 defaults,noatime 0 1\" /etc/fstab "
            "&& grep -Fxq \"root_uuid=$root_uuid\" /var/lib/aura/install-manifest "
            "&& esp_uuid=$(findmnt -n -o UUID /boot/efi) "
            "&& grep -Fxq \"UUID=$esp_uuid /boot/efi vfat umask=0077 0 2\" /etc/fstab "
            "&& loader=$(sed -n 's/^efi_loader=//p' /var/lib/aura/install-manifest) "
            "&& test -s \"/boot/efi/$loader\" "
            f"&& grep -Fxq 'initramfs_mode={initramfs_mode}' /var/lib/aura/install-manifest "
            f"&& {grub_initrd_check} "
            "&& echo AURA_ROOT_UUID_FSTAB_ESP_OK "
            "&& cat /var/lib/aura/install-manifest "
            "&& cat /etc/fstab "
            "&& echo AURA_USER_LOGIN_OK'"
        )
        child.sendline(command)
        child.expect("AURA_SUDO_GROUP_OK")
        group_output = child.before + child.after
        child.expect("AURA_NETWORK_OK")
        network_output = child.before + child.after
        child.expect(r"password for auraci:")
        sudo_prompt_output = child.before
        child.sendline(password)
        child.expect("AURA_ROOT_UUID_FSTAB_ESP_OK")
        child.expect("AURA_USER_LOGIN_OK")
        command_output = group_output + network_output + sudo_prompt_output + child.before + child.after
        if command_output.count("active") < 2:
            raise RuntimeError("networkd/resolved services did not both become active")
        child.sendline("sudo systemctl poweroff")
        child.expect(pexpect.EOF, timeout=120)
        child.close()
        if child.exitstatus not in (0, None):
            raise RuntimeError(
                f"installed-system QEMU exited with status {child.exitstatus}; see {log_path}"
            )
    except Exception:
        if child.logfile:
            child.logfile.flush()
        child.close(force=True)
        report_serial_log_tail(log_path)
        raise
    finally:
        if child.logfile:
            child.logfile.close()


def write_disk_metadata(architecture: str, disk: Path, iso: Path) -> Path:
    result = subprocess.run(
        ["sfdisk", "--dump", str(disk)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"could not inspect installed GPT image: {detail}")
    digest_state = hashlib.sha256()
    with iso.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest_state.update(chunk)
    digest = digest_state.hexdigest()
    report = LOG_DIR / f"aura-{architecture}-install-disk.sfdisk"
    report.write_text(
        f"architecture={architecture}\n"
        f"iso={iso.name}\n"
        f"iso_sha256={digest}\n"
        "sfdisk_partition_table:\n"
        f"{result.stdout}",
        encoding="utf-8",
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, choices=("x86_64", "aarch64", "riscv64"))
    parser.add_argument(
        "--iso",
        type=Path,
        default=ROOT / "build" / "iso" / f"aura-os-{os.environ.get('TARGET_ARCH', 'x86_64')}-uefi.iso",
    )
    parser.add_argument(
        "--disk",
        type=Path,
        default=LOG_DIR / f"aura-{os.environ.get('TARGET_ARCH', 'x86_64')}-target.raw",
    )
    args = parser.parse_args()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    iso = args.iso.resolve()
    disk = args.disk.resolve()
    require_file(iso, "installable ISO")
    if disk.exists():
        disk.unlink()
    subprocess.run(["truncate", "-s", "6G", str(disk)], check=True)

    print(f"Installing {args.arch} from {iso} to disposable QEMU disk {disk}")
    run_installer(args.arch, iso, disk)
    print("Installer completed; booting the installed target disk without the ISO.")
    run_installed_boot(args.arch, disk)
    metadata = write_disk_metadata(args.arch, disk, iso)
    print(f"Installed-disk partition metadata: {metadata}")
    print(f"Aura OS {args.arch}: install, UUID root boot, first user, login, network and shutdown passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, pexpect.ExceptionPexpect, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
 /boot/grub/grub.cfg"
    )

    try:
        root_boot_result = child.expect(
            [
                "AURA_ROOT_DEVICE_MATCHED",
                "Kernel panic",
                "ERROR:",
                pexpect.EOF,
            ],
            timeout=360,
        )
        if root_boot_result != 0:
            reasons = (
                "installed kernel panicked before the persistent-root init completed",
                "persistent-root initramfs reported an explicit error",
                "installed kernel exited before root UUID discovery",
            )
            raise RuntimeError(
                f"{architecture} installed disk did not reach persistent-root init: "
                f"{reasons[root_boot_result - 1]}; see {log_path}"
            )
        child.expect("New username")
        child.sendline(username)
        child.expect("New password:")
        child.sendline(password)
        child.expect("Retype new password:")
        child.sendline(password)
        child.expect("initial administrator account is ready")
        child.expect("login:")
        child.sendline(username)
        child.expect("Password:")
        child.sendline(password)
        child.expect(r"[$#] ")
        command = (
            "id -nG | tr ' ' '\\n' | grep -qx sudo && echo AURA_SUDO_GROUP_OK; "
            "systemctl is-active systemd-networkd.service; "
            "systemctl is-active systemd-resolved.service; "
            "network_ok=0; "
            "for attempt in $(seq 1 60); do "
            "if ip -4 -o addr show scope global | grep -q 'inet 10\\.0\\.2\\.' "
            "&& ip -4 route show default | grep -q '^default ' "
            "&& getent ahostsv4 deb.debian.org >/dev/null 2>&1; then "
            "network_ok=1; break; fi; sleep 2; done; "
            "test \"$network_ok\" -eq 1 && echo AURA_NETWORK_OK; "
            "sudo -S sh -c 'test -s /var/lib/aura/firstboot/complete "
            "&& passwd -S root | grep -q \"^root L \" "
            "&& root_uuid=$(findmnt -n -o UUID /) "
            "&& grep -Fxq \"UUID=$root_uuid / ext4 defaults,noatime 0 1\" /etc/fstab "
            "&& grep -Fxq \"root_uuid=$root_uuid\" /var/lib/aura/install-manifest "
            "&& esp_uuid=$(findmnt -n -o UUID /boot/efi) "
            "&& grep -Fxq \"UUID=$esp_uuid /boot/efi vfat umask=0077 0 2\" /etc/fstab "
            "&& loader=$(sed -n 's/^efi_loader=//p' /var/lib/aura/install-manifest) "
            "&& test -s \"/boot/efi/$loader\" "
            "&& echo AURA_ROOT_UUID_FSTAB_ESP_OK "
            "&& cat /var/lib/aura/install-manifest "
            "&& cat /etc/fstab "
            "&& echo AURA_USER_LOGIN_OK'"
        )
        child.sendline(command)
        child.expect("AURA_SUDO_GROUP_OK")
        group_output = child.before + child.after
        child.expect("AURA_NETWORK_OK")
        network_output = child.before + child.after
        child.expect(r"password for auraci:")
        sudo_prompt_output = child.before
        child.sendline(password)
        child.expect("AURA_ROOT_UUID_FSTAB_ESP_OK")
        child.expect("AURA_USER_LOGIN_OK")
        command_output = group_output + network_output + sudo_prompt_output + child.before + child.after
        if command_output.count("active") < 2:
            raise RuntimeError("networkd/resolved services did not both become active")
        child.sendline("sudo systemctl poweroff")
        child.expect(pexpect.EOF, timeout=120)
        child.close()
        if child.exitstatus not in (0, None):
            raise RuntimeError(
                f"installed-system QEMU exited with status {child.exitstatus}; see {log_path}"
            )
    except Exception:
        if child.logfile:
            child.logfile.flush()
        child.close(force=True)
        report_serial_log_tail(log_path)
        raise
    finally:
        if child.logfile:
            child.logfile.close()


def write_disk_metadata(architecture: str, disk: Path, iso: Path) -> Path:
    result = subprocess.run(
        ["sfdisk", "--dump", str(disk)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"could not inspect installed GPT image: {detail}")
    digest_state = hashlib.sha256()
    with iso.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest_state.update(chunk)
    digest = digest_state.hexdigest()
    report = LOG_DIR / f"aura-{architecture}-install-disk.sfdisk"
    report.write_text(
        f"architecture={architecture}\n"
        f"iso={iso.name}\n"
        f"iso_sha256={digest}\n"
        "sfdisk_partition_table:\n"
        f"{result.stdout}",
        encoding="utf-8",
    )
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True, choices=("x86_64", "aarch64", "riscv64"))
    parser.add_argument(
        "--iso",
        type=Path,
        default=ROOT / "build" / "iso" / f"aura-os-{os.environ.get('TARGET_ARCH', 'x86_64')}-uefi.iso",
    )
    parser.add_argument(
        "--disk",
        type=Path,
        default=LOG_DIR / f"aura-{os.environ.get('TARGET_ARCH', 'x86_64')}-target.raw",
    )
    args = parser.parse_args()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    iso = args.iso.resolve()
    disk = args.disk.resolve()
    require_file(iso, "installable ISO")
    if disk.exists():
        disk.unlink()
    subprocess.run(["truncate", "-s", "6G", str(disk)], check=True)

    print(f"Installing {args.arch} from {iso} to disposable QEMU disk {disk}")
    run_installer(args.arch, iso, disk)
    print("Installer completed; booting the installed target disk without the ISO.")
    run_installed_boot(args.arch, disk)
    metadata = write_disk_metadata(args.arch, disk, iso)
    print(f"Installed-disk partition metadata: {metadata}")
    print(f"Aura OS {args.arch}: install, UUID root boot, first user, login, network and shutdown passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, pexpect.ExceptionPexpect, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
