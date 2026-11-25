#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
source "$ROOT_DIR/kernel/linux-version.env"
SOURCE_DIR="$ROOT_DIR/build/kernel-src/linux-$LINUX_KERNEL_VERSION-git"
BASE_OUT_DIR="$ROOT_DIR/build/kernel"
OUT_DIR="$ROOT_DIR/build/kernel-installed-build/$TARGET_ARCH"
OUTPUT_DIR="$ROOT_DIR/build/kernel-installed/$TARGET_ARCH"
INITRAMFS_ROOTFS="$ROOT_DIR/build/initramfs/rootfs"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

case "$TARGET_ARCH" in
  x86_64)
    ARCH=x86
    CROSS_COMPILE="${CROSS_COMPILE:-}"
    IMAGE_RELATIVE_PATH=arch/x86/boot/bzImage
    IMAGE_TARGET=bzImage
    EMBED_INITRAMFS=0
    ;;
  aarch64)
    ARCH=arm64
    CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/arm64/boot/Image
    IMAGE_TARGET=Image
    EMBED_INITRAMFS=0
    ;;
  riscv64)
    ARCH=riscv
    CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}"
    IMAGE_RELATIVE_PATH=arch/riscv/boot/Image
    IMAGE_TARGET=Image
    EMBED_INITRAMFS=1
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
for path in "$SOURCE_DIR/Makefile" "$BASE_OUT_DIR/.config" "$SOURCE_DIR/scripts/config"; do
  [[ -s "$path" ]] || {
    echo "error: installed-kernel build input is missing: $path" >&2
    exit 1
  }
done

mkdir -p "$OUT_DIR" "$OUTPUT_DIR"
cp "$BASE_OUT_DIR/.config" "$OUT_DIR/.config"

# x86-64 and AArch64 use GRUB's external initrd handoff. The current
# RISC-V UEFI/GRUB path boots the kernel but does not expose GRUB's initrd to
# Linux through the EFI stub/FDT path in our QEMU firmware profile. Embed the
# small static persistent-root /init into RV64GC's installed kernel instead.
if [[ "$EMBED_INITRAMFS" -eq 1 && ! -s "$INITRAMFS_ROOTFS/init" ]]; then
  echo "error: RISC-V embedded persistent-root initramfs source is missing: $INITRAMFS_ROOTFS/init" >&2
  exit 1
fi

config_args=(
  --file "$OUT_DIR/.config"
  --enable BLK_DEV_INITRD
  --enable EFI
  --enable EFI_STUB
  --enable EFI_PARTITION
  --set-str CMDLINE ""
  --disable CMDLINE_BOOL
  --disable CMDLINE_OVERRIDE
  --disable CMDLINE_FORCE
)
if [[ "$EMBED_INITRAMFS" -eq 1 ]]; then
  config_args+=(--set-str INITRAMFS_SOURCE "$INITRAMFS_ROOTFS")
  config_args+=(--enable INITRAMFS_COMPRESSION_GZIP)
else
  config_args+=(--set-str INITRAMFS_SOURCE "")
fi
"$SOURCE_DIR/scripts/config" "${config_args[@]}"

ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" olddefconfig

for option in CONFIG_BLK_DEV_INITRD CONFIG_EFI CONFIG_EFI_STUB CONFIG_EFI_PARTITION; do
  grep -qx "${option}=y" "$OUT_DIR/.config" || {
    echo "error: installed kernel is missing required option: $option" >&2
    exit 1
  }
done
if [[ "$EMBED_INITRAMFS" -eq 1 ]]; then
  grep -Fqx "CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_ROOTFS\"" "$OUT_DIR/.config" || {
    echo "error: RISC-V installed kernel did not retain its embedded initramfs source." >&2
    exit 1
  }
  grep -qx "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" "$OUT_DIR/.config" || {
    echo "error: RISC-V installed kernel must gzip-compress its embedded initramfs." >&2
    exit 1
  }
else
  grep -Fqx 'CONFIG_INITRAMFS_SOURCE=""' "$OUT_DIR/.config" || {
    echo "error: installed kernel unexpectedly embeds an initramfs." >&2
    exit 1
  }
fi
for option in CONFIG_CMDLINE_BOOL CONFIG_CMDLINE_OVERRIDE CONFIG_CMDLINE_FORCE; do
  if grep -qx "${option}=y" "$OUT_DIR/.config"; then
    echo "error: installed kernel must accept the GRUB-provided command line ($option)." >&2
    exit 1
  fi
done

echo "Building the GRUB-loaded EFI-stub kernel for $TARGET_ARCH..."
ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" "$IMAGE_TARGET"

KERNEL_RELEASE="$(make -s -C "$SOURCE_DIR" O="$OUT_DIR" kernelrelease)"
[[ -n "$KERNEL_RELEASE" ]] || { echo "error: could not determine installed kernel release." >&2; exit 1; }
printf '%s\n' "$KERNEL_RELEASE" > "$OUTPUT_DIR/kernelrelease"

# Install the modules that belong to this exact kernel release into a clean
# staging root so the matching .deb can ship them with the kernel image.
MODULES_ROOT="$OUTPUT_DIR/modules-root"
rm -rf "$MODULES_ROOT"
if grep -qx 'CONFIG_MODULES=y' "$OUT_DIR/.config"; then
  for command_name in depmod find; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "error: required module packaging command is unavailable: $command_name" >&2
      exit 1
    }
  done
  echo "Building loadable modules for $TARGET_ARCH ($KERNEL_RELEASE)..."
  ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    make -C "$SOURCE_DIR" O="$OUT_DIR" -j"$JOBS" modules
  mkdir -p "$MODULES_ROOT"
  ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    make -C "$SOURCE_DIR" O="$OUT_DIR" modules_install \
      INSTALL_MOD_PATH="$MODULES_ROOT" INSTALL_MOD_STRIP=1
  MODULES_TREE="$MODULES_ROOT/lib/modules/$KERNEL_RELEASE"
  [[ -d "$MODULES_TREE" ]] || {
    echo "error: modules_install did not create $MODULES_TREE" >&2
    exit 1
  }
  # These links point into the runner's source/build directories and must
  # never escape into the installed target filesystem.
  rm -f "$MODULES_TREE/build" "$MODULES_TREE/source"
  [[ -s "$MODULES_TREE/modules.dep" ]] || {
    echo "error: depmod did not generate modules.dep for $KERNEL_RELEASE" >&2
    exit 1
  }
  printf '1\n' > "$OUTPUT_DIR/modules-enabled"
else
  printf '0\n' > "$OUTPUT_DIR/modules-enabled"
fi

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
  if [[ "$EMBED_INITRAMFS" -eq 1 ]]; then
    printf 'Initramfs: embedded gzip-compressed persistent-root /init\n'
  else
    printf 'Initramfs: external, loaded by GRUB\n'
  fi
  printf 'Kernel command line: provided by GRUB at boot\n'
  printf 'Kernel build directory: %s\n' "$OUT_DIR"
  printf 'Kernel image: %s\n' "$OUTPUT_KERNEL"
  printf 'Kernel SHA-256:\n'
  sha256sum "$OUTPUT_KERNEL"
} > "$OUTPUT_DIR/provenance.txt"

printf 'Created GRUB-booted installed kernel (%s initramfs): %s\n' "$([[ "$EMBED_INITRAMFS" -eq 1 ]] && echo embedded || echo external)" "$OUTPUT_KERNEL"
