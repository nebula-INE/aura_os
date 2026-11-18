#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_IMAGE="${ROOT_DIR}/build/kernel/arch/x86/boot/bzImage"
INITRAMFS="${ROOT_DIR}/build/initramfs/aura-initramfs.cpio.gz"
LOG_DIR="${ROOT_DIR}/build/qemu"
LOG_FILE="${LOG_DIR}/aura-qemu-boot.log"
ESP_DIR="${LOG_DIR}/esp"
ESP_IMAGE="${LOG_DIR}/aura-uefi-esp.img"
GRUB_EFI="${ESP_DIR}/BOOTX64.EFI"
GRUB_CFG="${ESP_DIR}/grub.cfg"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
OVMF_VARS_COPY="${LOG_DIR}/OVMF_VARS.fd"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
TIMEOUT_SECONDS="${QEMU_TIMEOUT_SECONDS:-90}"
CPU_MODEL="qemu64"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in grub-mkstandalone mformat mmd mcopy sha256sum dpkg-query timeout tee grep; do
  require_command "$cmd"
done

for path in "$KERNEL_IMAGE" "$INITRAMFS" "$OVMF_CODE" "$OVMF_VARS"; do
  if [[ ! -s "$path" ]]; then
    echo "error: required boot input is missing or empty: $path" >&2
    exit 1
  fi
done
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "error: QEMU binary not found: $QEMU_BIN" >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$ESP_DIR/EFI/BOOT"
rm -f "$ESP_IMAGE" "$OVMF_VARS_COPY" "$GRUB_EFI"

cat >"$GRUB_CFG" <<'GRUB'
set timeout=0
set default=0
menuentry "Aura OS x86-64 UEFI smoke test" {
    linux /vmlinuz console=ttyS0,115200n8 rdinit=/init panic=-1 aura.ci=1
    initrd /initramfs.cpio.gz
}
GRUB

echo "Building standalone x86-64 UEFI GRUB loader..."
grub-mkstandalone \
  --format=x86_64-efi \
  --output="$GRUB_EFI" \
  --modules="part_gpt fat normal linux" \
  "boot/grub/grub.cfg=$GRUB_CFG"
test -s "$GRUB_EFI"

echo "Creating a FAT32 EFI system partition..."
truncate -s 64M "$ESP_IMAGE"
mformat -i "$ESP_IMAGE" -F ::
mmd -i "$ESP_IMAGE" ::/EFI
mmd -i "$ESP_IMAGE" ::/EFI/BOOT
mcopy -i "$ESP_IMAGE" "$GRUB_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$ESP_IMAGE" "$KERNEL_IMAGE" ::/vmlinuz
mcopy -i "$ESP_IMAGE" "$INITRAMFS" ::/initramfs.cpio.gz

# Use a disposable writable NVRAM copy; never modify the installed firmware template.
cp "$OVMF_VARS" "$OVMF_VARS_COPY"

{
  printf 'QEMU version: %s\n' "$("$QEMU_BIN" --version | head -n 1)"
  printf 'Machine: q35 (TCG)\n'
  printf 'CPU model: %s\n' "$CPU_MODEL"
  printf 'Firmware package: %s\n' "$(dpkg-query -W -f='${Version}' ovmf)"
  printf 'Firmware code: %s\n' "$OVMF_CODE"
  printf 'Firmware variables template: %s\n' "$OVMF_VARS"
  printf 'Firmware code and template SHA-256:\n'
  sha256sum "$OVMF_CODE" "$OVMF_VARS"
  printf 'UEFI loader: GRUB standalone x86_64-efi\n'
  printf 'ESP image SHA-256:\n'
  sha256sum "$ESP_IMAGE"
} | tee "$LOG_DIR/firmware-provenance.txt"

echo "Booting Aura OS through OVMF UEFI in QEMU (q35, CPU=$CPU_MODEL, TCG)..."
set +e
timeout --signal=TERM --kill-after=10s "$TIMEOUT_SECONDS" \
  "$QEMU_BIN" \
    -machine q35,accel=tcg \
    -cpu "$CPU_MODEL" \
    -m 1024 \
    -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS_COPY" \
    -drive if=none,id=esp,format=raw,file="$ESP_IMAGE" \
    -device ich9-ahci,id=ahci \
    -device ide-hd,drive=esp,bus=ahci.0 \
    -boot order=c,strict=on \
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
  echo "error: kernel panic detected in the QEMU serial log." >&2
  exit 1
fi
grep -Fq "AURA_INIT_OK" "$LOG_FILE" || {
  echo "error: initramfs did not report AURA_INIT_OK." >&2
  exit 1
}
grep -Fq "AURA_QEMU_TEST_PASS" "$LOG_FILE" || {
  echo "error: initramfs did not report AURA_QEMU_TEST_PASS." >&2
  exit 1
}

echo "QEMU UEFI boot smoke test passed."
