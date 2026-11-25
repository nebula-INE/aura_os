#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/iso}"
STAGING_DIR="${STAGING_DIR:-$ROOT_DIR/build/iso/staging/$TARGET_ARCH}"
if [[ "${AURA_INSTALLER_MODE:-0}" == "1" ]]; then
  ESP_SIZE="${ESP_SIZE:-512M}"
else
  ESP_SIZE="${ESP_SIZE:-128M}"
fi
AURA_INSTALLER_MODE="${AURA_INSTALLER_MODE:-0}"
ROOTFS_ARCHIVE="${ROOTFS_ARCHIVE:-$ROOT_DIR/build/base-userspace/$TARGET_ARCH/aura-base-$TARGET_ARCH.tar.gz}"
ROOTFS_CHECKSUM="${ROOTFS_CHECKSUM:-$ROOTFS_ARCHIVE.sha256}"
INSTALLED_KERNEL="${INSTALLED_KERNEL:-$ROOT_DIR/build/kernel-installed/$TARGET_ARCH/vmlinuz-$TARGET_ARCH}"
INSTALLED_INITRAMFS="${INSTALLED_INITRAMFS:-$ROOT_DIR/build/initramfs/aura-initramfs-$TARGET_ARCH.cpio.gz}"

case "$TARGET_ARCH" in
  x86_64)
    EFI_FILENAME=BOOTX64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/x86_64/arch/x86/boot/bzImage"
    FIRMWARE_PROFILE=OVMF-x86_64-UEFI
    FAT_LABEL=AURAX64
    ISO_LABEL=AURA_X86_64
    ;;
  aarch64)
    EFI_FILENAME=BOOTAA64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/aarch64/arch/arm64/boot/Image"
    FIRMWARE_PROFILE=AAVMF-aarch64-UEFI
    FAT_LABEL=AURAA64
    ISO_LABEL=AURA_AARCH64
    ;;
  riscv64)
    EFI_FILENAME=BOOTRISCV64.EFI
    KERNEL_IMAGE="$ROOT_DIR/build/kernel-efi-iso/riscv64/arch/riscv/boot/Image"
    FIRMWARE_PROFILE=EDK2-RISCV64-via-QEMU-virt-firmware
    FAT_LABEL=AURARV64
    ISO_LABEL=AURA_RISCV64
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
case "$AURA_INSTALLER_MODE" in
  0) ;;
  1)
    for payload in "$ROOTFS_ARCHIVE" "$ROOTFS_CHECKSUM" "$INSTALLED_KERNEL" "$INSTALLED_INITRAMFS"; do
      if [[ ! -s "$payload" ]]; then
        echo "error: installable ISO payload is missing or empty: $payload" >&2
        exit 1
      fi
    done
    ;;
  *)
    echo "error: AURA_INSTALLER_MODE must be 0 or 1." >&2
    exit 2
    ;;
esac

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/boot" "$STAGING_DIR/EFI/BOOT"
if [[ "$AURA_INSTALLER_MODE" == "1" ]]; then
  mkdir -p "$STAGING_DIR/rootfs"
  cp "$ROOTFS_ARCHIVE" "$STAGING_DIR/rootfs/aura-base-$TARGET_ARCH.tar.gz"
  cp "$ROOTFS_CHECKSUM" "$STAGING_DIR/rootfs/aura-base-$TARGET_ARCH.tar.gz.sha256"
  cp "$INSTALLED_KERNEL" "$STAGING_DIR/boot/vmlinuz-$TARGET_ARCH"
  cp "$INSTALLED_INITRAMFS" "$STAGING_DIR/boot/initramfs-$TARGET_ARCH.cpio.gz"
  (
    cd "$STAGING_DIR/boot"
    sha256sum "vmlinuz-$TARGET_ARCH" > "vmlinuz-$TARGET_ARCH.sha256"
    sha256sum "initramfs-$TARGET_ARCH.cpio.gz" > "initramfs-$TARGET_ARCH.cpio.gz.sha256"
  )
fi
ESP_IMAGE="$STAGING_DIR/boot/efi.img"
VOLUME_ID="$ISO_LABEL"
OUTPUT_ISO="$OUTPUT_DIR/aura-os-$TARGET_ARCH-uefi.iso"

echo "Creating a FAT32 El Torito EFI System Partition for $TARGET_ARCH..."
truncate -s "$ESP_SIZE" "$ESP_IMAGE"
mformat -i "$ESP_IMAGE" -F -v "$FAT_LABEL" ::
mmd -i "$ESP_IMAGE" ::/EFI
mmd -i "$ESP_IMAGE" ::/EFI/BOOT
mcopy -i "$ESP_IMAGE" "$KERNEL_IMAGE" "::/EFI/BOOT/$EFI_FILENAME"
mdir -i "$ESP_IMAGE" ::/
mdir -i "$ESP_IMAGE" ::/EFI/BOOT

if [[ "$AURA_INSTALLER_MODE" == "1" ]]; then
  cat > "$STAGING_DIR/README.txt" <<README
Aura OS $TARGET_ARCH UEFI install media (Debian 13 trixie)

Firmware profile: $FIRMWARE_PROFILE
EFI removable-media loader: EFI/BOOT/$EFI_FILENAME
The installer runs from a Debian 13 initramfs in memory.
The ISO carries a separate Debian rootfs archive and the installed kernel/initramfs.

The installer lists eligible disks and requires the operator to type:
  ERASE /dev/<target>
followed by:
  INSTALL AURA

It creates GPT, a 512 MiB FAT32 EFI System Partition, and an ext4 root
filesystem. Do not select a disk containing data you want to keep.
The installer never selects a target automatically.
README
else
  cat > "$STAGING_DIR/README.txt" <<README
Aura OS $TARGET_ARCH UEFI boot media (bring-up prototype)

Firmware profile: $FIRMWARE_PROFILE
EFI removable-media loader: EFI/BOOT/$EFI_FILENAME
Boot medium: UEFI El Torito ISO9660 with an embedded FAT32 EFI System Partition.

This image is a boot-validation prototype. It starts the embedded Aura OS
initramfs and opens a serial console. Type 'p' then Enter to power off, or 'r' then Enter to reboot.
It is NOT an installer and does not install Aura OS onto a target disk.

See docs/installation-media.md in the Aura OS repository for current status.
README
fi

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

python3 - "$OUTPUT_ISO" "$TARGET_ARCH" "$EFI_FILENAME" "$FIRMWARE_PROFILE" "$AURA_INSTALLER_MODE" \
  > "$OUTPUT_ISO.provenance.json" <<'PY'
import json
import sys
from pathlib import Path

image, architecture, loader, firmware, installer_mode = sys.argv[1:]
path = Path(image)
installer_ready = installer_mode == "1"
record = {
    "status": "built",
    "architecture": architecture,
    "format": "ISO9660",
    "boot_method": "UEFI El Torito; FAT32 EFI System Partition",
    "efi_fallback_loader": f"EFI/BOOT/{loader}",
    "firmware_profile": firmware,
    "image": path.name,
    "image_size_bytes": path.stat().st_size,
    "installer_ready": installer_ready,
    "purpose": "Debian 13 installer with GPT/ESP/rootfs deployment" if installer_ready else "interactive serial-console boot-validation prototype",
}
if installer_ready:
    record["rootfs_archive"] = f"rootfs/aura-base-{architecture}.tar.gz"
    record["installed_kernel"] = f"boot/vmlinuz-{architecture}"
    record["installed_initramfs"] = f"boot/initramfs-{architecture}.cpio.gz"
print(json.dumps(record, sort_keys=True, indent=2))
PY

printf 'Created bootable UEFI ISO: %s\n' "$OUTPUT_ISO"
cat "$OUTPUT_ISO.sha256"
cat "$OUTPUT_ISO.provenance.json"
