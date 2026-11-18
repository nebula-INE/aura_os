#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../kernel/linux-version.env
source "${ROOT_DIR}/kernel/linux-version.env"

SOURCE_DIR="${ROOT_DIR}/build/kernel-src/linux-${LINUX_KERNEL_VERSION}-git"
BASE_OUT_DIR="${ROOT_DIR}/build/kernel"
OUT_DIR="${ROOT_DIR}/build/kernel-aarch64-uefi"
INITRAMFS_ROOTFS="${INITRAMFS_ROOTFS:-${ROOT_DIR}/build/initramfs/rootfs}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
COMPILER="${CROSS_COMPILE}gcc"
IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
KERNEL_CMDLINE="console=ttyAMA0,115200 rdinit=/init panic=-1"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in "$COMPILER" make cp grep sha256sum file; do
  require_command "$cmd"
done
for path in "$SOURCE_DIR/Makefile" "$BASE_OUT_DIR/.config" "$INITRAMFS_ROOTFS/init"; do
  if [[ ! -s "$path" && ! -f "$path" ]]; then
    echo "error: required input is missing: $path" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
cp "$BASE_OUT_DIR/.config" "$OUT_DIR/.config"

# Keep the normal AArch64 direct-boot image intact. This separate output tree
# builds a PE/COFF EFI-stub kernel and embeds the same target-native /init.
"$SOURCE_DIR/scripts/config" --file "$OUT_DIR/.config" \
  --enable BLK_DEV_INITRD \
  --enable EFI \
  --enable EFI_STUB \
  --set-str INITRAMFS_SOURCE "$INITRAMFS_ROOTFS" \
  --enable INITRAMFS_COMPRESSION_GZIP \
  --set-str CMDLINE "$KERNEL_CMDLINE" \
  --enable CMDLINE_FORCE

ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" olddefconfig

for option in CONFIG_BLK_DEV_INITRD CONFIG_EFI CONFIG_EFI_STUB \
              CONFIG_INITRAMFS_COMPRESSION_GZIP CONFIG_CMDLINE_FORCE; do
  grep -qx "${option}=y" "$OUT_DIR/.config" || {
    echo "error: required UEFI kernel option is not enabled: ${option}" >&2
    exit 1
  }
done
grep -Fqx "CONFIG_INITRAMFS_SOURCE=\"${INITRAMFS_ROOTFS}\"" "$OUT_DIR/.config" || {
  echo "error: kernel did not retain the embedded initramfs source path." >&2
  exit 1
}
grep -Fqx "CONFIG_CMDLINE=\"${KERNEL_CMDLINE}\"" "$OUT_DIR/.config" || {
  echo "error: kernel did not retain the forced UEFI command line." >&2
  exit 1
}

echo "Building AArch64 EFI-stub kernel with embedded initramfs..."
ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" Image

test -s "$IMAGE"
IMAGE_TYPE="$(file -b "$IMAGE")"
printf 'EFI image type: %s\n' "$IMAGE_TYPE"
if ! grep -qi 'PE32+' <<<"$IMAGE_TYPE"; then
  echo "error: AArch64 kernel image does not contain a PE32+ EFI-stub header." >&2
  exit 1
fi

cp "${BASE_OUT_DIR}/source-verification.txt" "$OUT_DIR/source-verification.txt"
sha256sum "$IMAGE" | tee "$OUT_DIR/aarch64-uefi-kernel-image.sha256"
printf 'Built AArch64 EFI-stub image: %s\n' "$IMAGE"
