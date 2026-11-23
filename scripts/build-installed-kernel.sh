#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
source "$ROOT_DIR/kernel/linux-version.env"
SOURCE_DIR="$ROOT_DIR/build/kernel-src/linux-$LINUX_KERNEL_VERSION-git"
OUT_DIR="$ROOT_DIR/build/kernel"
OUTPUT_DIR="$ROOT_DIR/build/kernel-installed/$TARGET_ARCH"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

case "$TARGET_ARCH" in
  x86_64)
    ARCH=x86
    CROSS_COMPILE="${CROSS_COMPILE:-}"
    IMAGE_RELATIVE_PATH=arch/x86/boot/bzImage
    IMAGE_TARGET=bzImage
    ;;
  aarch64)
    ARCH=arm64
    CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/arm64/boot/Image
    IMAGE_TARGET=Image
    ;;
  riscv64)
    ARCH=riscv
    CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/riscv/boot/Image
    IMAGE_TARGET=Image
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac
export ARCH CROSS_COMPILE
COMPILER="${CROSS_COMPILE}gcc"

for cmd in "$COMPILER" make cp grep sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
done
for path in "$SOURCE_DIR/Makefile" "$OUT_DIR/.config" "$SOURCE_DIR/scripts/config"; do
  [[ -s "$path" ]] || {
    echo "error: installed-kernel build input is missing: $path" >&2
    exit 1
  }
done

mkdir -p "$OUTPUT_DIR"

# The installed system uses GRUB to pass the filesystem UUID and load the
# target-native static initramfs from the ESP. Do not embed installer initramfs
# content or force a build-time command line into this kernel.
"$SOURCE_DIR/scripts/config" --file "$OUT_DIR/.config" \
  --enable BLK_DEV_INITRD \
  --enable EFI \
  --enable EFI_STUB \
  --enable EFI_PARTITION \
  --set-str INITRAMFS_SOURCE "" \
  --set-str CMDLINE "" \
  --disable CMDLINE_BOOL \
  --disable CMDLINE_OVERRIDE \
  --disable CMDLINE_FORCE

ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" olddefconfig

for option in CONFIG_BLK_DEV_INITRD CONFIG_EFI CONFIG_EFI_STUB CONFIG_EFI_PARTITION; do
  grep -qx "${option}=y" "$OUT_DIR/.config" || {
    echo "error: installed kernel is missing required option: $option" >&2
    exit 1
  }
done
grep -Fqx 'CONFIG_INITRAMFS_SOURCE=""' "$OUT_DIR/.config" || {
  echo "error: installed kernel unexpectedly embeds an initramfs." >&2
  exit 1
}
for option in CONFIG_CMDLINE_BOOL CONFIG_CMDLINE_OVERRIDE CONFIG_CMDLINE_FORCE; do
  if grep -qx "${option}=y" "$OUT_DIR/.config"; then
    echo "error: installed kernel must accept the GRUB-provided command line ($option)." >&2
    exit 1
  fi
done

echo "Building the GRUB-loaded EFI-stub kernel for $TARGET_ARCH..."
ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" "$IMAGE_TARGET"

KERNEL_IMAGE="$OUT_DIR/$IMAGE_RELATIVE_PATH"
[[ -s "$KERNEL_IMAGE" ]] || {
  echo "error: installed kernel output is missing: $KERNEL_IMAGE" >&2
  exit 1
}
if [[ "$TARGET_ARCH" == aarch64 ]]; then
  python3 "$ROOT_DIR/scripts/verify_aarch64_efi_image.py" "$KERNEL_IMAGE"
fi

OUTPUT_KERNEL="$OUTPUT_DIR/vmlinuz-$TARGET_ARCH"
install -m 0644 "$KERNEL_IMAGE" "$OUTPUT_KERNEL"
sha256sum "$OUTPUT_KERNEL" | tee "$OUTPUT_KERNEL.sha256"
{
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Kernel version: %s\n' "$LINUX_KERNEL_VERSION"
  printf 'Kernel source commit: %s\n' "$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  printf 'EFI-stub: enabled\n'
  printf 'Initramfs: external, loaded by GRUB\n'
  printf 'Kernel command line: provided by GRUB at boot\n'
  printf 'Kernel image: %s\n' "$OUTPUT_KERNEL"
  printf 'Kernel SHA-256:\n'
  sha256sum "$OUTPUT_KERNEL"
} > "$OUTPUT_DIR/provenance.txt"

printf 'Created GRUB-loaded installed kernel: %s\n' "$OUTPUT_KERNEL"
