#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/iso}"
STAGING_DIR="${STAGING_DIR:-$ROOT_DIR/build/iso/staging/$TARGET_ARCH}"
ESP_SIZE="${ESP_SIZE:-128M}"

case "$TARGET_ARCH" in
  x86_64)
    EFI_FILENAME=BOOTX64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/x86_64/arch/x86/boot/bzImage"
    FIRMWARE_PROFILE=OVMF-x86_64-UEFI
    ;;
  aarch64)
    EFI_FILENAME=BOOTAA64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/aarch64/arch/arm64/boot/Image"
    FIRMWARE_PROFILE=AAVMF-aarch64-UEFI
    ;;
  riscv64)
    EFI_FILENAME=BOOTRISCV64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/riscv64/arch/riscv/boot/Image"
    FIRMWARE_PROFILE=EDK2-RISCV64-via-QEMU-virt-firmware
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in truncate mformat mmd mcopy mdir xorriso sha256sum python3; do
  require_command "$cmd"
done
if [[ ! -s "$KERNEL_IMAGE" ]]; then
  echo "error: architecture-specific EFI kernel is missing: $KERNEL_IMAGE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/boot" "$STAGING_DIR/EFI/BOOT"
ESP_IMAGE="$STAGING_DIR/boot/efi.img"
VOLUME_ID="AURA_${TARGET_ARCH^^}"
OUTPUT_ISO="$OUTPUT_DIR/aura-os-$TARGET_ARCH-uefi.iso"

echo "Creating a FAT32 El Torito EFI System Partition for $TARGET_ARCH..."
truncate -s "$ESP_SIZE" "$ESP_IMAGE"
mformat -i "$ESP_IMAGE" -F -v "$VOLUME_ID" ::
mmd -i "$ESP_IMAGE" ::/EFI
mmd -i "$ESP_IMAGE" ::/EFI/BOOT
mcopy -i "$ESP_IMAGE" "$KERNEL_IMAGE" "::/EFI/BOOT/$EFI_FILENAME"
mdir -i "$ESP_IMAGE" ::/
mdir -i "$ESP_IMAGE" ::/EFI/BOOT

cat > "$STAGING_DIR/README.txt" <<README
Aura OS $TARGET_ARCH UEFI boot media (bring-up prototype)

Firmware profile: $FIRMWARE_PROFILE
EFI removable-media loader: EFI/BOOT/$EFI_FILENAME
Boot medium: UEFI El Torito ISO9660 with an embedded FAT32 EFI System Partition.

This image is a boot-validation prototype. It starts the embedded Aura OS
initramfs, prints boot success markers, and powers off. It is NOT yet an
installer and does not install Aura OS onto a target disk.

See docs/installation-media.md in the Aura OS repository for current status.
README

echo "Creating UEFI El Torito ISO..."
rm -f "$OUTPUT_ISO"
xorriso -as mkisofs \
  -iso-level 3 \
  -r -J \
  -V "$VOLUME_ID" \
  -e boot/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -o "$OUTPUT_ISO" \
  "$STAGING_DIR"

test -s "$OUTPUT_ISO"

REPORT_FILE="$OUTPUT_ISO.eltorito.txt"
xorriso -indev "$OUTPUT_ISO" -report_el_torito plain 2>&1 | tee "$REPORT_FILE"
grep -qi "El Torito" "$REPORT_FILE" || {
  echo "error: xorriso did not report an El Torito boot catalog." >&2
  exit 1
}
grep -Eqi "EFI|0xEF|0xef" "$REPORT_FILE" || {
  echo "error: ISO does not report an EFI El Torito boot entry." >&2
  exit 1
}

# Extract the EFI boot image again from the finished ISO and inspect its loader.
VERIFY_ESP="$OUTPUT_DIR/verify-$TARGET_ARCH-efi.img"
rm -f "$VERIFY_ESP"
xorriso -osirrox on -indev "$OUTPUT_ISO" -extract /boot/efi.img "$VERIFY_ESP"
mdir -i "$VERIFY_ESP" "::/EFI/BOOT/$EFI_FILENAME"
rm -f "$VERIFY_ESP"

(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$OUTPUT_ISO")" > "$(basename "$OUTPUT_ISO").sha256"
)

python3 - "$OUTPUT_ISO" "$TARGET_ARCH" "$EFI_FILENAME" "$FIRMWARE_PROFILE" \
  > "$OUTPUT_ISO.provenance.json" <<'PY'
import json
import sys
from pathlib import Path

image, architecture, loader, firmware = sys.argv[1:]
path = Path(image)
record = {
    "status": "built",
    "architecture": architecture,
    "format": "ISO9660",
    "boot_method": "UEFI El Torito; FAT32 EFI System Partition",
    "efi_fallback_loader": f"EFI/BOOT/{loader}",
    "firmware_profile": firmware,
    "image": path.name,
    "image_size_bytes": path.stat().st_size,
    "installer_ready": False,
    "purpose": "boot-validation prototype; initramfs smoke boot only",
}
print(json.dumps(record, sort_keys=True, indent=2))
PY

printf 'Created bootable UEFI ISO: %s\n' "$OUTPUT_ISO"
cat "$OUTPUT_ISO.sha256"
cat "$OUTPUT_ISO.provenance.json"
