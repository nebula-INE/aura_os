#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/initramfs"
ROOTFS_DIR="${OUT_DIR}/rootfs"
ARCHIVE="${OUT_DIR}/aura-initramfs.cpio.gz"
BUSYBOX="${BUSYBOX:-$(command -v busybox || true)}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in cpio gzip find sort readelf sha256sum; do
  require_command "$cmd"
done

if [[ -z "$BUSYBOX" || ! -x "$BUSYBOX" ]]; then
  echo "error: a statically linked BusyBox binary is required (install busybox-static)." >&2
  exit 1
fi
if readelf -l "$BUSYBOX" 2>/dev/null | grep -q 'INTERP'; then
  echo "error: BusyBox is dynamically linked; use the busybox-static package." >&2
  exit 1
fi

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,proc,root,sys,tmp,usr/bin,usr/sbin}
chmod 1777 "$ROOTFS_DIR/tmp"
install -m 0755 "$BUSYBOX" "$ROOTFS_DIR/bin/busybox"

# Keep the initramfs self-contained: all applet links resolve to its own BusyBox.
for applet in sh mount grep cat poweroff; do
  ln -sfn busybox "$ROOTFS_DIR/bin/$applet"
done

cat >"$ROOTFS_DIR/init" <<'INIT'
#!/bin/sh
/bin/mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/mount -t proc proc /proc
/bin/mount -t sysfs sysfs /sys

echo "[Aura OS] minimal initramfs started"
if /bin/grep -q 'aura.ci=1' /proc/cmdline; then
  echo "AURA_INIT_OK"
  echo "AURA_QEMU_TEST_PASS"
  /bin/poweroff -f
  echo "AURA_POWEROFF_FAILED"
  exec /bin/sh
fi

echo "[Aura OS] userspace shell is ready"
exec /bin/sh
INIT
chmod 0755 "$ROOTFS_DIR/init"

mkdir -p "$OUT_DIR"
(
  cd "$ROOTFS_DIR"
  find . -print0 | LC_ALL=C sort -z |
    cpio --null --create --format=newc --reproducible --owner=0:0 |
    gzip -n -9 >"$ARCHIVE"
)

test -s "$ARCHIVE"
sha256sum "$ARCHIVE" | tee "$ARCHIVE.sha256"
printf 'Created minimal initramfs: %s\n' "$ARCHIVE"
