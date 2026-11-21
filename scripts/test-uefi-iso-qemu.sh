#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
ISO_IMAGE="${ISO_IMAGE:-$ROOT_DIR/build/iso/aura-os-$TARGET_ARCH-uefi.iso}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/build/qemu-iso}"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-150}"
BOOT_KEY_DELAY_SECONDS="${ISO_BOOT_KEY_DELAY_SECONDS:-30}"
QEMU_BIN="${QEMU_BIN:-}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

case "$TARGET_ARCH" in
  x86_64)
    QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
    OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
    OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
    OVMF_VARS_COPY="$LOG_DIR/OVMF_VARS.fd"
    QEMU_ARGS=(
      -machine q35,accel=tcg
      -cpu qemu64
      -m 1024
      -smp 2
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
      -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS_COPY"
      -device ich9-ahci,id=ahci
      -drive if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file="$ISO_IMAGE"
      -device ide-cd,drive=cdrom,bus=ahci.1,bootindex=1
      -boot order=d
    )
    FIRMWARE_PACKAGE=ovmf
    ;;
  aarch64)
    QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
    OVMF_CODE="${AAVMF_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}"
    OVMF_VARS="${AAVMF_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}"
    OVMF_VARS_COPY="$LOG_DIR/AAVMF_VARS.fd"
    QEMU_ARGS=(
      -machine virt,gic-version=3,accel=tcg
      -cpu cortex-a57
      -m 1024
      -smp 2
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
      -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS_COPY"
      -device virtio-scsi-device,id=scsi0
      -drive if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file="$ISO_IMAGE"
      -device scsi-cd,drive=cdrom,bus=scsi0.0,bootindex=1
      -boot order=d
    )
    FIRMWARE_PACKAGE=qemu-efi-aarch64
    ;;
  riscv64)
    QEMU_BIN="${QEMU_BIN:-qemu-system-riscv64}"
    OVMF_CODE="${RISCV_EFI_CODE:-/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd}"
    OVMF_VARS="${RISCV_EFI_VARS:-/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd}"
    OVMF_VARS_COPY="$LOG_DIR/RISCV_VIRT_VARS.fd"
    QEMU_ARGS=(
      -machine virt,pflash0=pflash0,pflash1=pflash1,acpi=off,accel=tcg
      -cpu rv64
      -m 2048
      -smp 2
      -blockdev "node-name=pflash0,driver=file,read-only=on,filename=$OVMF_CODE"
      -blockdev "node-name=pflash1,driver=file,filename=$OVMF_VARS_COPY"
      -device virtio-scsi-device,id=scsi0
      -drive if=none,id=cdrom,media=cdrom,readonly=on,format=raw,file="$ISO_IMAGE"
      -device scsi-cd,drive=cdrom,bus=scsi0.0,bootindex=1
      -boot order=d
    )
    FIRMWARE_PACKAGE=qemu-efi-riscv64
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

for cmd in "$QEMU_BIN" timeout tee grep tr sha256sum dpkg-query; do
  require_command "$cmd"
done
for path in "$ISO_IMAGE" "$OVMF_CODE" "$OVMF_VARS"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required ISO/UEFI boot input is missing or empty: $path" >&2
    exit 1
  fi
done

mkdir -p "$LOG_DIR"
cp "$OVMF_VARS" "$OVMF_VARS_COPY"
LOG_FILE="$LOG_DIR/aura-$TARGET_ARCH-uefi-iso-boot.log"
PROVENANCE_FILE="$LOG_DIR/$TARGET_ARCH-uefi-iso-qemu-provenance.txt"

{
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'ISO image: %s\n' "$ISO_IMAGE"
  printf 'ISO SHA-256:\n'
  sha256sum "$ISO_IMAGE"
  printf 'QEMU: %s\n' "$("$QEMU_BIN" --version | head -n 1)"
  printf 'Firmware package: %s\n' "$(dpkg-query -W -f='${Version}' "$FIRMWARE_PACKAGE")"
  printf 'Firmware code: %s\n' "$OVMF_CODE"
  printf 'Firmware variables template: %s\n' "$OVMF_VARS"
  printf 'Firmware code/template SHA-256:\n'
  sha256sum "$OVMF_CODE" "$OVMF_VARS"
  printf 'Boot medium: virtual CD-ROM, UEFI El Torito\n'
} | tee "$PROVENANCE_FILE"

echo "Booting the $TARGET_ARCH Aura OS ISO as virtual CD-ROM under QEMU UEFI..."
set +e
(
  sleep "$BOOT_KEY_DELAY_SECONDS"
  printf 'p\\n'
) | timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" \
  "$QEMU_BIN" "${QEMU_ARGS[@]}" \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot 2>&1 | tee "$LOG_FILE"
pipeline_status=("${PIPESTATUS[@]}")
qemu_status="${pipeline_status[1]:-1}"
set -e

if [[ "$qemu_status" -ne 0 ]]; then
  echo "error: QEMU exited with status $qemu_status (timeout, firmware, or guest failure)." >&2
  exit "$qemu_status"
fi
normalized_log="$(tr -d '\r' < "$LOG_FILE")"
for marker in AURA_INIT_OK AURA_ISO_BOOT_READY AURA_QEMU_TEST_PASS; do
  grep -Fqx "$marker" <<<"$normalized_log" || {
    echo "error: UEFI ISO boot did not report exact success marker: $marker" >&2
    exit 1
  }
done
if grep -qi "Kernel panic" "$LOG_FILE"; then
  echo "error: kernel panic detected during UEFI ISO boot." >&2
  exit 1
fi

echo "Aura OS $TARGET_ARCH UEFI ISO boot passed."
