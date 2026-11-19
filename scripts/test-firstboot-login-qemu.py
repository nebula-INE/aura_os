#!/usr/bin/env python3
"""Exercise first-boot account creation and real serial-console login in QEMU."""

from __future__ import annotations

import os
import re
import secrets
import shutil
import sys
from pathlib import Path

try:
    import pexpect
except ImportError as exc:  # pragma: no cover - exercised in CI provisioning
    raise SystemExit(
        "error: python3-pexpect is required; install it before running this test."
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
TARGET_ARCH = os.environ.get("TARGET_ARCH", "")
TIMEOUT = int(os.environ.get("AURA_LOGIN_QEMU_TIMEOUT_SECONDS", "240"))
USERNAME = "aura-ci"
PASSWORD = secrets.token_urlsafe(24)
LOG_DIR = ROOT / "build/qemu"


def qemu_configuration() -> tuple[str, Path, Path, list[str], str]:
    if TARGET_ARCH == "x86_64":
        qemu = os.environ.get("QEMU_BIN", "qemu-system-x86_64")
        kernel = ROOT / "build/kernel/arch/x86/boot/bzImage"
        console = "ttyS0"
        args = [
            "-machine", "q35,accel=tcg",
            "-cpu", "qemu64",
            "-m", "2048",
            "-smp", "2",
        ]
        return qemu, kernel, ROOT / f"build/initramfs/aura-initramfs-{TARGET_ARCH}.cpio.gz", args, console
    if TARGET_ARCH == "aarch64":
        qemu = os.environ.get("QEMU_BIN", "qemu-system-aarch64")
        kernel = ROOT / "build/kernel/arch/arm64/boot/Image"
        console = "ttyAMA0"
        args = [
            "-machine", "virt,accel=tcg",
            "-cpu", "cortex-a57",
            "-m", "2048",
            "-smp", "2",
        ]
        return qemu, kernel, ROOT / f"build/initramfs/aura-initramfs-{TARGET_ARCH}.cpio.gz", args, console
    if TARGET_ARCH == "riscv64":
        qemu = os.environ.get("QEMU_BIN", "qemu-system-riscv64")
        kernel = ROOT / "build/kernel/arch/riscv/boot/Image"
        console = "ttyS0"
        args = [
            "-machine", "virt,accel=tcg",
            "-cpu", "rv64",
            "-m", "2048",
            "-smp", "2",
            "-bios", "default",
        ]
        return qemu, kernel, ROOT / f"build/initramfs/aura-initramfs-{TARGET_ARCH}.cpio.gz", args, console
    raise SystemExit("error: TARGET_ARCH must be x86_64, aarch64, or riscv64.")


def start_guest(
    qemu: str, kernel: Path, initramfs: Path, image: Path, console: str, log_path: Path
) -> tuple[pexpect.spawn, object]:
    for path in (kernel, initramfs, image):
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"required QEMU input is missing or empty: {path}")
    if not os.access(image, os.R_OK | os.W_OK):
        raise RuntimeError(f"QEMU runner cannot read and write rootfs image: {image}")
    if shutil.which(qemu) is None:
        raise RuntimeError(f"QEMU executable not found: {qemu}")

    command_line = f"console={console},115200 rdinit=/init panic=-1 aura.rootfs=1"
    args = [
        *qemu_configuration()[3],
        "-kernel", str(kernel),
        "-initrd", str(initramfs),
        "-append", command_line,
        "-drive", f"if=none,id=auraroot,format=raw,file={image}",
        "-device",
        "virtio-blk-pci,drive=auraroot" if TARGET_ARCH == "x86_64"
        else "virtio-blk-device,drive=auraroot",
        "-display", "none",
        "-serial", "stdio",
        "-monitor", "none",
        "-no-reboot",
    ]
    if TARGET_ARCH != "x86_64":
        # The AArch64 virt machine accepts the direct Linux loader; RISC-V uses
        # QEMU's default OpenSBI firmware before entering the kernel.
        pass

    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = log_path.open("w", encoding="utf-8")
    child = pexpect.spawn(
        qemu,
        args,
        encoding="utf-8",
        codec_errors="replace",
        timeout=TIMEOUT,
        echo=False,
    )
    child.logfile_read = log_file
    return child, log_file


def expect_firstboot_prompt(child: pexpect.spawn) -> None:
    child.expect(re.compile(r"New username", re.IGNORECASE), timeout=TIMEOUT)


def expect_login_prompt(child: pexpect.spawn, *, reject_wizard: bool = False) -> None:
    patterns = [
        re.compile(r"login:\s*", re.IGNORECASE),
    ]
    if reject_wizard:
        patterns.insert(0, re.compile(r"New username", re.IGNORECASE))
    matched = child.expect(patterns, timeout=TIMEOUT)
    if reject_wizard and matched == 0:
        raise RuntimeError("first-boot wizard ran again after its completion marker was written")


def authenticate_console(child: pexpect.spawn, *, verify_sudo: bool) -> None:
    child.sendline(USERNAME)
    child.expect(re.compile(r"Password:\s*", re.IGNORECASE), timeout=60)
    child.sendline(PASSWORD)
    child.expect(re.compile(r"(?m)[^\r\n]*[#$] ?$"), timeout=90)

    child.sendline(
        "printf 'AURA_LOGIN_USER=%s\\nAURA_LOGIN_HOME=%s\\nAURA_LOGIN_GROUPS=%s\\n' "
        '"$(id -un)" "$HOME" "$(id -nG)"'
    )
    child.expect("AURA_LOGIN_USER=" + USERNAME, timeout=30)
    child.expect("AURA_LOGIN_HOME=/home/" + USERNAME, timeout=30)
    child.expect(re.compile(r"AURA_LOGIN_GROUPS=.*\bsudo\b"), timeout=30)

    if verify_sudo:
        child.sendline(
            "sudo -k; sudo -S -p 'AURA_SUDO_PASSWORD:' -v; "
            "printf 'AURA_SUDO_AUTH=%s\\n' \"$?\""
        )
        child.expect("AURA_SUDO_PASSWORD:", timeout=30)
        child.sendline(PASSWORD)
        child.expect("AURA_SUDO_AUTH=0", timeout=45)

        child.sendline(
            "sudo -n test -s /var/lib/aura/firstboot/complete "
            "&& echo AURA_FIRSTBOOT_MARKER_OK; sudo -n passwd -S root"
        )
        child.expect("AURA_FIRSTBOOT_MARKER_OK", timeout=30)
        child.expect(re.compile(r"root\s+L\s"), timeout=30)


def poweroff_guest(child: pexpect.spawn, log_file: object) -> None:
    child.sendline("sudo -n systemctl poweroff")
    child.expect(pexpect.EOF, timeout=90)
    child.close()
    log_file.close()
    if child.exitstatus not in (0, None):
        raise RuntimeError(f"QEMU exited with status {child.exitstatus} after guest poweroff")


def run_first_boot(qemu: str, kernel: Path, initramfs: Path, image: Path, console: str) -> None:
    child, log_file = start_guest(
        qemu, kernel, initramfs, image, console,
        LOG_DIR / f"aura-{TARGET_ARCH}-firstboot-login-1.log",
    )
    try:
        expect_firstboot_prompt(child)
        child.sendline(USERNAME)
        child.expect(re.compile(r"New password:\s*", re.IGNORECASE), timeout=45)
        child.sendline(PASSWORD)
        child.expect(re.compile(r"Retype new password:\s*", re.IGNORECASE), timeout=45)
        child.sendline(PASSWORD)
        child.expect("Aura OS initial administrator account is ready", timeout=90)
        expect_login_prompt(child)
        authenticate_console(child, verify_sudo=True)
        poweroff_guest(child, log_file)
    except Exception:
        if child.isalive():
            child.close(force=True)
        log_file.close()
        raise


def run_second_boot(qemu: str, kernel: Path, initramfs: Path, image: Path, console: str) -> None:
    child, log_file = start_guest(
        qemu, kernel, initramfs, image, console,
        LOG_DIR / f"aura-{TARGET_ARCH}-firstboot-login-2.log",
    )
    try:
        expect_login_prompt(child, reject_wizard=True)
        authenticate_console(child, verify_sudo=False)
        poweroff_guest(child, log_file)
        log_text = (LOG_DIR / f"aura-{TARGET_ARCH}-firstboot-login-2.log").read_text(
            encoding="utf-8", errors="replace"
        )
        if "New username" in log_text:
            raise RuntimeError("first-boot account prompt appeared on the second boot")
    except Exception:
        if child.isalive():
            child.close(force=True)
        log_file.close()
        raise


def main() -> int:
    qemu, kernel, initramfs, _args, console = qemu_configuration()
    image = Path(
        os.environ.get(
            "ROOTFS_IMAGE",
            str(ROOT / f"build/base-userspace/{TARGET_ARCH}/aura-firstboot-{TARGET_ARCH}.ext4"),
        )
    ).resolve()
    print(f"Testing first-boot provisioning, serial login, and sudo on {TARGET_ARCH}.")
    run_first_boot(qemu, kernel, initramfs, image, console)
    print("AURA_FIRSTBOOT_LOGIN_PASS: account setup, console login, sudo, and root lock verified.")
    run_second_boot(qemu, kernel, initramfs, image, console)
    print("AURA_FIRSTBOOT_REPEAT_BOOT_PASS: wizard skipped and persisted console login verified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (pexpect.ExceptionPexpect, RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
