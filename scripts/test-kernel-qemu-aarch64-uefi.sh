#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_IMAGE="${ROOT_DIR}/build/kernel-aarch64-uefi/arch/arm64/boot/Image"
LOG_DIR="${ROOT_DIR}/build/qemu"
LOG_FILE="${LOG_DIR}/aura-aarch64-uefi-boot.log"
PROVENANCE_FILE="${LOG_DIR}/aarch64-uefi-firmware-provenance.txt"
ESP_DIR="${LOG_DIR}/aarch64-uefi-esp"
ESP_IMAGE="${LOG_DIR}/aura-aarch64-uefi-esp.img"
OVMF_CODE="${AAVMF_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}"
OVMF_VARS="${AAVMF_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}"
OVMF_VARS_COPY="${LOG_DIR}/AAVMF_VARS.fd"
QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-120}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in "$QEMU_BIN" truncate mformat mmd mcopy mdir parted sha256sum \
           dpkg-query timeout tee grep file; do
  require_command "$cmd"
done
for path in "$KERNEL_IMAGE" "$OVMF_CODE" "$OVMF_VARS"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required UEFI boot input is missing or empty: $path" >&2
    exit 1
  fi
done

IMAGE_TYPE="$(file -b "$KERNEL_IMAGE")"
if ! grep -qi 'PE32+' <<<"$IMAGE_TYPE"; then
  echo "error: UEFI boot payload is not a PE32+ EFI-stub image: $IMAGE_TYPE" >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$ESP_DIR/EFI/BOOT"
rm -f "$ESP_IMAGE" "$OVMF_VARS_COPY"
truncate -s 64M "$ESP_IMAGE"
parted --script "$ESP_IMAGE" mklabel gpt
parted --script "$ESP_IMAGE" mkpart ESP fat32 1MiB 100%
parted --script "$ESP_IMAGE" set 1 esp on

ESP_OFFSET=1048576
ESP_MTOOLS_IMAGE="${ESP_IMAGE}@@${ESP_OFFSET}"
mformat -i "$ESP_MTOOLS_IMAGE" -F ::
mmd -i "$ESP_MTOOLS_IMAGE" ::/EFI
mmd -i "$ESP_MTOOLS_IMAGE" ::/EFI/BOOT
mcopy -i "$ESP_MTOOLS_IMAGE" "$KERNEL_IMAGE" ::/EFI/BOOT/BOOTAA64.EFI

echo "Verifying the removable-media AArch64 EFI fallback path..."
mdir -i "$ESP_MTOOLS_IMAGE" ::/
mdir -i "$ESP_MTOOLS_IMAGE" ::/EFI/BOOT

# Firmware variable storage is writable and must be unique per QEMU run.
cp "$OVMF_VARS" "$OVMF_VARS_COPY"

{
  printf 'Target architecture: AArch64\n'
  printf 'QEMU version: %s\n' "$("$QEMU_BIN" --version | head -n 1)"
  printf 'Machine: virt,gic-version=3 (TCG)\n'
  printf 'CPU model: cortex-a57\n'
  printf 'Firmware package version: %s\n' "$(dpkg-query -W -f='${Version}' qemu-efi-aarch64)"
  printf 'Firmware code: %s\n' "$OVMF_CODE"
  printf 'Firmware variables template: %s\n' "$OVMF_VARS"
  printf 'Firmware code and variables SHA-256:\n'
  sha256sum "$OVMF_CODE" "$OVMF_VARS"
  printf 'EFI fallback application: EFI/BOOT/BOOTAA64.EFI (Linux EFI stub)\n'
  printf 'Kernel image type: %s\n' "$IMAGE_TYPE"
  printf 'Kernel SHA-256:\n'
  sha256sum "$KERNEL_IMAGE"
  printf 'ESP image SHA-256:\n'
  sha256sum "$ESP_IMAGE"
  printf 'Embedded kernel command line: console=ttyAMA0,115200 rdinit=/init panic=-1\n'
} | tee "$PROVENANCE_FILE"

echo "Booting AArch64 EFI-stub kernel via AAVMF UEFI in QEMU..."
set +e
timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" \
  "$QEMU_BIN" \
    -machine virt,gic-version=3,accel=tcg \
    -cpu cortex-a57 \
    -m 1024 \
    -smp 2 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS_COPY" \
    -drive if=none,id=esp,format=raw,file="$ESP_IMAGE" \
    -device virtio-blk-pci,drive=esp,bootindex=1 \
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
if grep -qi "Kernel panic" "$LOG_FILE"; then
  echo "error: kernel panic detected in the AArch64 UEFI serial log." >&2
  exit 1
fi
grep -Fq "AURA_INIT_OK" "$LOG_FILE" || {
  echo "error: UEFI-booted kernel did not report AURA_INIT_OK." >&2
  exit 1
}
grep -Fq "AURA_QEMU_TEST_PASS" "$LOG_FILE" || {
  echo "error: UEFI-booted kernel did not report AURA_QEMU_TEST_PASS." >&2
  exit 1
}

echo "AArch64 AAVMF UEFI first-boot smoke test passed."
