#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_IMAGE="${ROOT_DIR}/build/kernel/arch/x86/boot/bzImage"
INITRAMFS="${ROOT_DIR}/build/initramfs/aura-initramfs.cpio.gz"
LOG_DIR="${ROOT_DIR}/build/qemu"
LOG_FILE="${LOG_DIR}/aura-qemu-boot.log"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-90}"

for path in "$KERNEL_IMAGE" "$INITRAMFS"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required boot artifact is missing or empty: $path" >&2
    exit 1
  fi
done
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "error: QEMU binary not found: $QEMU_BIN" >&2
  exit 1
fi
command -v timeout >/dev/null 2>&1 || {
  echo "error: timeout command is required." >&2
  exit 1
}

mkdir -p "$LOG_DIR"
echo "Booting Aura OS kernel and initramfs in QEMU (q35, TCG)..."
set +e
timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" \
  "$QEMU_BIN" \
    -machine q35,accel=tcg \
    -cpu max \
    -m 1024 \
    -smp 2 \
    -kernel "$KERNEL_IMAGE" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0,115200n8 rdinit=/init panic=-1 aura.ci=1" \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot 2>&1 | tee "$LOG_FILE"
qemu_status="${PIPESTATUS[0]}"
set -e

if [[ "$qemu_status" -ne 0 ]]; then
  echo "error: QEMU exited with status $qemu_status (timeout or guest failure)." >&2
  exit "$qemu_status"
fi
grep -Fq "AURA_INIT_OK" "$LOG_FILE" || {
  echo "error: initramfs did not report AURA_INIT_OK." >&2
  exit 1
}
grep -Fq "AURA_QEMU_TEST_PASS" "$LOG_FILE" || {
  echo "error: initramfs did not report AURA_QEMU_TEST_PASS." >&2
  exit 1
}

echo "QEMU boot smoke test passed."
