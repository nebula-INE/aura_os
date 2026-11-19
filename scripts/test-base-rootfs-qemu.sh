#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-180}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-$ROOT_DIR/build/base-userspace/$TARGET_ARCH/aura-base-$TARGET_ARCH.ext4}"
INITRAMFS="$ROOT_DIR/build/initramfs/aura-initramfs-$TARGET_ARCH.cpio.gz"
LOG_DIR="$ROOT_DIR/build/qemu"

case "$TARGET_ARCH" in
  x86_64)
    KERNEL_IMAGE="$ROOT_DIR/build/kernel/arch/x86/boot/bzImage"
    QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
    CPU_MODEL="qemu64"
    CONSOLE="ttyS0"
    KERNEL_CMDLINE="console=ttyS0,115200n8 rdinit=/init panic=-1 aura.rootfs=1"
    QEMU_ARGS=(
      -machine q35,accel=tcg
      -cpu "$CPU_MODEL"
      -m 2048
      -smp 2
      -kernel "$KERNEL_IMAGE"
      -initrd "$INITRAMFS"
      -append "$KERNEL_CMDLINE"
      -drive if=none,id=auraroot,format=raw,file="$ROOTFS_IMAGE"
      -device virtio-blk-pci,drive=auraroot
      -display none
      -serial stdio
      -monitor none
      -no-reboot
    )
    ;;
  riscv64)
    KERNEL_IMAGE="$ROOT_DIR/build/kernel/arch/riscv/boot/Image"
    QEMU_BIN="${QEMU_BIN:-qemu-system-riscv64}"
    CPU_MODEL="rv64"
    CONSOLE="ttyS0"
    KERNEL_CMDLINE="console=ttyS0,115200 rdinit=/init panic=-1 aura.rootfs=1"
    QEMU_ARGS=(
      -machine virt,accel=tcg
      -cpu "$CPU_MODEL"
      -m 2048
      -smp 2
      -bios default
      -kernel "$KERNEL_IMAGE"
      -initrd "$INITRAMFS"
      -append "$KERNEL_CMDLINE"
      -drive if=none,id=auraroot,format=raw,file="$ROOTFS_IMAGE"
      -device virtio-blk-device,drive=auraroot
      -display none
      -serial stdio
      -monitor none
      -no-reboot
    )
    ;;
  aarch64)
    KERNEL_IMAGE="$ROOT_DIR/build/kernel/arch/arm64/boot/Image"
    QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
    CPU_MODEL="cortex-a57"
    CONSOLE="ttyAMA0"
    KERNEL_CMDLINE="console=ttyAMA0,115200 rdinit=/init panic=-1 aura.rootfs=1"
    QEMU_ARGS=(
      -machine virt,accel=tcg
      -cpu "$CPU_MODEL"
      -m 2048
      -smp 2
      -kernel "$KERNEL_IMAGE"
      -initrd "$INITRAMFS"
      -append "$KERNEL_CMDLINE"
      -drive if=none,id=auraroot,format=raw,file="$ROOTFS_IMAGE"
      -device virtio-blk-device,drive=auraroot
      -display none
      -serial stdio
      -monitor none
      -no-reboot
    )
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, riscv64, or aarch64." >&2
    exit 2
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}
for cmd in "$QEMU_BIN" timeout tee grep sha256sum head; do
  require_command "$cmd"
done
for path in "$KERNEL_IMAGE" "$INITRAMFS" "$ROOTFS_IMAGE"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required persistent-root boot input is missing or empty: $path" >&2
    exit 1
  fi
done
if [[ ! -r "$ROOTFS_IMAGE" ]]; then
  echo "error: QEMU runner user cannot read the persistent rootfs image: $ROOTFS_IMAGE" >&2
  echo "hint: run scripts/build-base-rootfs-disk.sh to apply the runner-readable image permissions." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/aura-$TARGET_ARCH-rootfs-boot.log"
PROVENANCE_FILE="$LOG_DIR/$TARGET_ARCH-rootfs-boot-provenance.txt"

{
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'QEMU: %s\n' "$("$QEMU_BIN" --version | head -n 1)"
  printf 'CPU model: %s\n' "$CPU_MODEL"
  printf 'Memory: 2048 MiB\n'
  printf 'Console: %s\n' "$CONSOLE"
  printf 'Kernel command line: %s\n' "$KERNEL_CMDLINE"
  printf 'Kernel SHA-256:\n'
  sha256sum "$KERNEL_IMAGE"
  printf 'Initramfs SHA-256:\n'
  sha256sum "$INITRAMFS"
  printf 'Persistent ext4 rootfs SHA-256:\n'
  sha256sum "$ROOTFS_IMAGE"
} | tee "$PROVENANCE_FILE"

echo "Booting Aura OS $TARGET_ARCH into Debian systemd rootfs under QEMU..."
set +e
timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" \
  "$QEMU_BIN" "${QEMU_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
qemu_status="${PIPESTATUS[0]}"
set -e

if [[ "$qemu_status" -ne 0 ]]; then
  echo "error: QEMU exited with status $qemu_status (timeout or guest failure)." >&2
  exit "$qemu_status"
fi
if grep -qi "Kernel panic" "$LOG_FILE"; then
  echo "error: kernel panic detected during persistent-root boot." >&2
  exit 1
fi
grep -Fq "AURA_INIT_OK" "$LOG_FILE" || {
  echo "error: initramfs did not start before rootfs switch." >&2
  exit 1
}
grep -Fq "AURA_SYSTEMD_ROOTFS_OK" "$LOG_FILE" || {
  echo "error: systemd did not reach the persistent-root smoke service." >&2
  exit 1
}
grep -Fq "AURA_ROOTFS_QEMU_PASS" "$LOG_FILE" || {
  echo "error: persistent-root QEMU smoke service did not report success." >&2
  exit 1
}

echo "Aura OS $TARGET_ARCH persistent Debian rootfs boot passed."
