#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-}"
LOG_DIR="${ROOT_DIR}/build/qemu"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-90}"

case "${TARGET_ARCH}" in
  riscv64)
    KERNEL_IMAGE="${ROOT_DIR}/build/kernel/arch/riscv/boot/Image"
    INITRAMFS="${ROOT_DIR}/build/initramfs/aura-initramfs-riscv64.cpio.gz"
    QEMU_BIN="${QEMU_BIN:-qemu-system-riscv64}"
    CPU_MODEL="rv64"
    CONSOLE="ttyS0"
    FIRMWARE="QEMU bundled OpenSBI (default firmware)"
    QEMU_ARGS=(
      -machine virt,accel=tcg
      -cpu "$CPU_MODEL"
      -m 1024
      -smp 2
      -bios default
      -kernel "$KERNEL_IMAGE"
      -initrd "$INITRAMFS"
      -append "console=${CONSOLE},115200 rdinit=/init panic=-1"
      -display none
      -serial stdio
      -monitor none
      -no-reboot
    )
    ;;
  aarch64)
    KERNEL_IMAGE="${ROOT_DIR}/build/kernel/arch/arm64/boot/Image"
    INITRAMFS="${ROOT_DIR}/build/initramfs/aura-initramfs-aarch64.cpio.gz"
    QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
    CPU_MODEL="cortex-a57"
    CONSOLE="ttyAMA0"
    FIRMWARE="QEMU direct Linux Image loader (UEFI not exercised in this smoke test)"
    QEMU_ARGS=(
      -machine virt,accel=tcg
      -cpu "$CPU_MODEL"
      -m 1024
      -smp 2
      -kernel "$KERNEL_IMAGE"
      -initrd "$INITRAMFS"
      -append "console=${CONSOLE},115200 rdinit=/init panic=-1"
      -display none
      -serial stdio
      -monitor none
      -no-reboot
    )
    ;;
  *)
    echo "error: TARGET_ARCH must be riscv64 or aarch64." >&2
    exit 2
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in "$QEMU_BIN" timeout tee grep sha256sum; do
  require_command "$cmd"
done
for path in "$KERNEL_IMAGE" "$INITRAMFS"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required boot input is missing or empty: $path" >&2
    exit 1
  fi
done

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/aura-${TARGET_ARCH}-qemu-boot.log"
PROVENANCE_FILE="${LOG_DIR}/${TARGET_ARCH}-firmware-provenance.txt"

{
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'QEMU version: %s\n' "$("$QEMU_BIN" --version | head -n 1)"
  printf 'Machine: virt (TCG)\n'
  printf 'CPU model: %s\n' "$CPU_MODEL"
  printf 'Console: %s\n' "$CONSOLE"
  printf 'Boot firmware/path: %s\n' "$FIRMWARE"
  printf 'Kernel SHA-256:\n'
  sha256sum "$KERNEL_IMAGE"
  printf 'Initramfs SHA-256:\n'
  sha256sum "$INITRAMFS"
  printf 'Kernel command line: console=%s,115200 rdinit=/init panic=-1\n' "$CONSOLE"
} | tee "$PROVENANCE_FILE"

echo "Booting Aura OS ${TARGET_ARCH} in QEMU virt (TCG)..."
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
  echo "error: kernel panic detected in the QEMU serial log." >&2
  exit 1
fi
grep -Fq "AURA_INIT_OK" "$LOG_FILE" || {
  echo "error: /init did not report AURA_INIT_OK." >&2
  exit 1
}
grep -Fq "AURA_QEMU_TEST_PASS" "$LOG_FILE" || {
  echo "error: /init did not report AURA_QEMU_TEST_PASS." >&2
  exit 1
}

echo "QEMU ${TARGET_ARCH} boot smoke test passed."
