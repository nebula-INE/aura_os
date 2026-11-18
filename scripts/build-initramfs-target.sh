#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-}"
OUT_DIR="${ROOT_DIR}/build/initramfs"
ROOTFS_DIR="${OUT_DIR}/rootfs"
ARCHIVE="${OUT_DIR}/aura-initramfs-${TARGET_ARCH}.cpio.gz"
SOURCE_FILE="${ROOT_DIR}/initramfs/init.c"

case "${TARGET_ARCH}" in
  riscv64) CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}" ;;
  aarch64) CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" ;;
  *)
    echo "error: TARGET_ARCH must be riscv64 or aarch64." >&2
    exit 2
    ;;
esac

CC="${CC:-${CROSS_COMPILE}gcc}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in "$CC" cpio gzip find sort readelf sha256sum; do
  require_command "$cmd"
done
if [[ ! -s "$SOURCE_FILE" ]]; then
  echo "error: init source is missing: $SOURCE_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"/{dev,proc,sys,root,tmp}
chmod 1777 "$ROOTFS_DIR/tmp"

echo "Building static /init for ${TARGET_ARCH} with $CC..."
"$CC" -std=c11 -Os -static -s -Wall -Wextra -Werror \
  "$SOURCE_FILE" -o "$ROOTFS_DIR/init"
chmod 0755 "$ROOTFS_DIR/init"

if readelf -l "$ROOTFS_DIR/init" 2>/dev/null | grep -q 'INTERP'; then
  echo "error: cross-compiled /init is dynamically linked." >&2
  exit 1
fi
readelf -h "$ROOTFS_DIR/init" | grep -E 'Class:|Data:|Machine:'

(
  cd "$ROOTFS_DIR"
  find . -print0 | LC_ALL=C sort -z |
    cpio --null --create --format=newc --reproducible --owner=0:0 |
    gzip -n -9 >"$ARCHIVE"
)

test -s "$ARCHIVE"
sha256sum "$ARCHIVE" | tee "$ARCHIVE.sha256"
printf 'Created static %s initramfs: %s\n' "$TARGET_ARCH" "$ARCHIVE"
