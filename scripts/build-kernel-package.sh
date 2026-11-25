#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
source "$ROOT_DIR/kernel/linux-version.env"
KERNEL_IMAGE="${KERNEL_IMAGE:-$ROOT_DIR/build/kernel-installed/$TARGET_ARCH/vmlinuz-$TARGET_ARCH}"
INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-$ROOT_DIR/build/initramfs/aura-initramfs-$TARGET_ARCH.cpio.gz}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/kernel-packages/$TARGET_ARCH}"
MODULES_ROOT="${MODULES_ROOT:-$ROOT_DIR/build/kernel-installed/$TARGET_ARCH/modules-root}"
MODULES_ENABLED_FILE="${MODULES_ENABLED_FILE:-$ROOT_DIR/build/kernel-installed/$TARGET_ARCH/modules-enabled}"
KERNEL_RELEASE_FILE="$ROOT_DIR/build/kernel-installed/$TARGET_ARCH/kernelrelease"
if [[ -z "${KERNEL_RELEASE:-}" ]]; then
  [[ -s "$KERNEL_RELEASE_FILE" ]] || { echo "error: exact kernel release metadata is missing: $KERNEL_RELEASE_FILE" >&2; exit 1; }
  KERNEL_RELEASE="$(cat "$KERNEL_RELEASE_FILE")"
fi
PACKAGE_VERSION="${PACKAGE_VERSION:-${KERNEL_RELEASE}+aura1}"
[[ "$KERNEL_RELEASE" =~ ^[0-9][A-Za-z0-9.+~_-]*$ ]] || {
  echo "error: invalid kernel release for Debian package naming: $KERNEL_RELEASE" >&2
  exit 2
}
case "$TARGET_ARCH" in
  x86_64) DEB_ARCH=amd64; INITRAMFS_MODE=external ;;
  aarch64) DEB_ARCH=arm64; INITRAMFS_MODE=external ;;
  riscv64) DEB_ARCH=riscv64; INITRAMFS_MODE=embedded ;;
  *) echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2; exit 2 ;;
esac
for cmd in dpkg-deb install cp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: required command not found: $cmd" >&2; exit 1; }
done
[[ -s "$KERNEL_IMAGE" ]] || { echo "error: installed kernel is missing: $KERNEL_IMAGE" >&2; exit 1; }
[[ -s "$INITRAMFS_IMAGE" ]] || { echo "error: persistent-root initramfs is missing: $INITRAMFS_IMAGE" >&2; exit 1; }
[[ -s "$MODULES_ENABLED_FILE" ]] || { echo "error: kernel module build marker is missing: $MODULES_ENABLED_FILE" >&2; exit 1; }
MODULES_ENABLED="$(cat "$MODULES_ENABLED_FILE")"
case "$MODULES_ENABLED" in
  0) ;;
  1)
    [[ -d "$MODULES_ROOT/lib/modules/$KERNEL_RELEASE" ]] || {
      echo "error: installed kernel module tree is missing for $KERNEL_RELEASE." >&2
      exit 1
    }
    [[ -s "$MODULES_ROOT/lib/modules/$KERNEL_RELEASE/modules.dep" ]] || {
      echo "error: module dependency index is missing for $KERNEL_RELEASE." >&2
      exit 1
    }
    ;;
  *) echo "error: invalid kernel module build marker: $MODULES_ENABLED" >&2; exit 1 ;;
esac
[[ "$PACKAGE_VERSION" =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]] || { echo "error: invalid Debian package version: $PACKAGE_VERSION" >&2; exit 2; }

IMAGE_PACKAGE="aura-kernel-image-$KERNEL_RELEASE"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aura-kernel-package.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
IMAGE_ROOT="$WORK_DIR/image"
META_ROOT="$WORK_DIR/meta"
mkdir -p "$IMAGE_ROOT/DEBIAN" "$IMAGE_ROOT/boot" "$IMAGE_ROOT/usr/share/aura-kernel"
mkdir -p "$META_ROOT/DEBIAN" "$META_ROOT/usr/share/aura-kernel" "$META_ROOT/usr/lib/aura-kernel"
mkdir -p "$META_ROOT/etc/systemd/system/multi-user.target.wants"

install -m 0644 "$KERNEL_IMAGE" "$IMAGE_ROOT/boot/vmlinuz-aura-$KERNEL_RELEASE"
if [[ "$INITRAMFS_MODE" == external ]]; then
  install -m 0644 "$INITRAMFS_IMAGE" "$IMAGE_ROOT/boot/aura-initramfs-$KERNEL_RELEASE.cpio.gz"
fi
if [[ "$MODULES_ENABLED" == "1" ]]; then
  mkdir -p "$IMAGE_ROOT/lib/modules"
  cp -a "$MODULES_ROOT/lib/modules/$KERNEL_RELEASE" "$IMAGE_ROOT/lib/modules/"
fi
cat > "$IMAGE_ROOT/usr/share/aura-kernel/$KERNEL_RELEASE.conf" <<CONF
AURA_KERNEL_ARCH=$TARGET_ARCH
AURA_INITRAMFS_MODE=$INITRAMFS_MODE
AURA_KERNEL_MODULES=$MODULES_ENABLED
CONF
cat > "$IMAGE_ROOT/DEBIAN/control" <<CONTROL
Package: $IMAGE_PACKAGE
Version: $PACKAGE_VERSION
Section: kernel
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Aura OS
Description: Versioned Aura OS kernel image for $TARGET_ARCH
 The kernel image and its matching persistent-root initramfs are installed
 under versioned /boot paths so a previous known-good image can be retained.
CONTROL
install -m 0755 "$ROOT_DIR/system/base/kernel/image-prerm" "$IMAGE_ROOT/DEBIAN/prerm"
install -m 0755 "$ROOT_DIR/system/base/kernel/image-postrm" "$IMAGE_ROOT/DEBIAN/postrm"

install -m 0755 "$ROOT_DIR/system/base/kernel/update-grub-menu" "$META_ROOT/usr/lib/aura-kernel/update-grub-menu"
install -m 0755 "$ROOT_DIR/system/base/kernel/activate-kernel" "$META_ROOT/usr/lib/aura-kernel/activate-kernel"
install -m 0755 "$ROOT_DIR/system/base/kernel/confirm-boot" "$META_ROOT/usr/lib/aura-kernel/confirm-boot"
install -m 0644 "$ROOT_DIR/system/base/kernel/aura-kernel-confirm.service" "$META_ROOT/etc/systemd/system/aura-kernel-confirm.service"
ln -s /etc/systemd/system/aura-kernel-confirm.service "$META_ROOT/etc/systemd/system/multi-user.target.wants/aura-kernel-confirm.service"
printf '%s\n' "$KERNEL_RELEASE" > "$META_ROOT/usr/share/aura-kernel/current-version"
cat > "$META_ROOT/DEBIAN/control" <<CONTROL
Package: aura-kernel
Version: $PACKAGE_VERSION
Section: kernel
Priority: optional
Architecture: all
Depends: $IMAGE_PACKAGE (= $PACKAGE_VERSION), apt, grub2-common, systemd
Description: Aura OS kernel lifecycle and GRUB integration
 Installs the versioned-kernel menu generator and first-boot health
 confirmation service. Previous kernel image packages are retained for
 manual fallback and one-boot update trials.
CONTROL
install -m 0755 "$ROOT_DIR/system/base/kernel/postinst" "$META_ROOT/DEBIAN/postinst"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.deb
dpkg-deb --root-owner-group --build "$IMAGE_ROOT" "$OUTPUT_DIR/aura-kernel-image-$TARGET_ARCH.deb"
dpkg-deb --root-owner-group --build "$META_ROOT" "$OUTPUT_DIR/aura-kernel-$TARGET_ARCH.deb"
printf 'Built Aura kernel packages for %s (%s):\n' "$TARGET_ARCH" "$PACKAGE_VERSION"
ls -lh "$OUTPUT_DIR"/*.deb
