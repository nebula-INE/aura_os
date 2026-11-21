#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
source "${ROOT_DIR}/kernel/linux-version.env"
SOURCE_DIR="${ROOT_DIR}/build/kernel-src/linux-${LINUX_KERNEL_VERSION}-git"
BASE_OUT_DIR="${ROOT_DIR}/build/kernel"
OUT_DIR="${ROOT_DIR}/build/kernel-efi-iso/${TARGET_ARCH}"
INITRAMFS_ROOTFS="${INITRAMFS_ROOTFS:-${ROOT_DIR}/build/initramfs/rootfs}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

case "${TARGET_ARCH}" in
  x86_64)
    ARCH=x86
    CROSS_COMPILE="${CROSS_COMPILE:-}"
    IMAGE_RELATIVE_PATH=arch/x86/boot/bzImage
    IMAGE_TARGET=bzImage
    KERNEL_CMDLINE="console=ttyS0,115200n8 rdinit=/init panic=-1 aura.iso=1"
    EFI_FILENAME=BOOTX64.EFI
    CMDLINE_FORCE_OPTION=CONFIG_CMDLINE_OVERRIDE
    ;;
  aarch64)
    ARCH=arm64
    CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/arm64/boot/Image
    IMAGE_TARGET=Image
    KERNEL_CMDLINE="console=ttyAMA0,115200 rdinit=/init panic=-1 aura.iso=1"
    EFI_FILENAME=BOOTAA64.EFI
    CMDLINE_FORCE_OPTION=CONFIG_CMDLINE_FORCE
    ;;
  riscv64)
    ARCH=riscv
    CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/riscv/boot/Image
    IMAGE_TARGET=Image
    KERNEL_CMDLINE="console=ttyS0,115200 rdinit=/init panic=-1 aura.iso=1"
    EFI_FILENAME=BOOTRISCV64.EFI
    CMDLINE_FORCE_OPTION=CONFIG_CMDLINE_FORCE
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

export ARCH CROSS_COMPILE
COMPILER="${CROSS_COMPILE}gcc"

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
  if [[ ! -s "$path" ]]; then
    echo "error: required EFI ISO build input is missing or empty: $path" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
cp "$BASE_OUT_DIR/.config" "$OUT_DIR/.config"

# Build a separate EFI-stub kernel with the architecture's boot initramfs
# embedded. This keeps the normal kernel outputs used by existing tests intact.
config_args=(
  --file "$OUT_DIR/.config"
  --enable BLK_DEV_INITRD
  --enable EFI
  --enable EFI_STUB
  --set-str INITRAMFS_SOURCE "$INITRAMFS_ROOTFS"
  --enable INITRAMFS_COMPRESSION_GZIP
  --set-str CMDLINE "$KERNEL_CMDLINE"
  --enable CMDLINE_FORCE
)
if [[ "$TARGET_ARCH" == x86_64 ]]; then
  config_args+=(--enable CMDLINE_BOOL --enable CMDLINE_OVERRIDE)
fi
"$SOURCE_DIR/scripts/config" "${config_args[@]}"

ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" olddefconfig

for option in CONFIG_BLK_DEV_INITRD CONFIG_EFI CONFIG_EFI_STUB \
              CONFIG_INITRAMFS_COMPRESSION_GZIP "$CMDLINE_FORCE_OPTION"; do
  grep -qx "${option}=y" "$OUT_DIR/.config" || {
    echo "error: required EFI ISO kernel option is not enabled: ${option}" >&2
    exit 1
  }
done
grep -Fqx "CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_ROOTFS\"" "$OUT_DIR/.config" || {
  echo "error: kernel did not retain the embedded initramfs source path." >&2
  exit 1
}
grep -Fqx "CONFIG_CMDLINE=\"$KERNEL_CMDLINE\"" "$OUT_DIR/.config" || {
  echo "error: kernel did not retain the forced ISO kernel command line." >&2
  exit 1
}

echo "Building ${TARGET_ARCH} EFI-stub kernel with embedded initramfs..."
ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" "$IMAGE_TARGET"

KERNEL_IMAGE="$OUT_DIR/$IMAGE_RELATIVE_PATH"
if [[ ! -s "$KERNEL_IMAGE" ]]; then
  echo "error: EFI-stub kernel output is missing: $KERNEL_IMAGE" >&2
  exit 1
fi

if [[ "$TARGET_ARCH" == aarch64 ]]; then
  python3 "$ROOT_DIR/scripts/verify_aarch64_efi_image.py" "$KERNEL_IMAGE"
fi

cp "$BASE_OUT_DIR/source-verification.txt" "$OUT_DIR/source-verification.txt"
sha256sum "$KERNEL_IMAGE" | tee "$OUT_DIR/kernel-image.sha256"
{
  printf 'Architecture: %s\n' "$TARGET_ARCH"
  printf 'Kernel image: %s\n' "$KERNEL_IMAGE"
  printf 'EFI fallback filename: %s\n' "$EFI_FILENAME"
  printf 'Kernel command line: %s\n' "$KERNEL_CMDLINE"
  printf 'Kernel file identification: %s\n' "$(file -b "$KERNEL_IMAGE")"
  printf 'Embedded initramfs source: %s\n' "$INITRAMFS_ROOTFS"
  printf 'Kernel SHA-256:\n'
  sha256sum "$KERNEL_IMAGE"
} | tee "$OUT_DIR/efi-kernel-provenance.txt"

printf 'Built %s EFI ISO kernel: %s\n' "$TARGET_ARCH" "$KERNEL_IMAGE"
