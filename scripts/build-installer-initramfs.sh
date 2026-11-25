#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
BASE_DIR="$ROOT_DIR/build/base-userspace/$TARGET_ARCH"
BASE_ARCHIVE="$BASE_DIR/aura-base-$TARGET_ARCH.tar.gz"
OUT_DIR="$ROOT_DIR/build/installer-initramfs/$TARGET_ARCH"
ROOTFS_DIR="$OUT_DIR/rootfs"
ARCHIVE="$OUT_DIR/aura-installer-initramfs-$TARGET_ARCH.cpio.gz"

case "$TARGET_ARCH" in
  x86_64|aarch64|riscv64) ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run this builder as root so ownership and device metadata remain correct." >&2
  exit 1
fi

for cmd in tar cpio gzip find sort sha256sum install; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
done

[[ -s "$BASE_ARCHIVE" ]] || {
  echo "error: validated Debian base rootfs archive is missing: $BASE_ARCHIVE" >&2
  exit 1
}
[[ -s "$ROOT_DIR/system/base/installer/init" ]] || {
  echo "error: installer init entry point is missing." >&2
  exit 1
}
[[ -s "$ROOT_DIR/system/base/installer/install.sh" ]] || {
  echo "error: installer program is missing." >&2
  exit 1
}
[[ -s "$ROOT_DIR/system/base/installer/rescue.sh" ]] || {
  echo "error: offline rescue entry point is missing." >&2
  exit 1
}
[[ -s "$ROOT_DIR/system/base/installer/backup.sh" ]] || {
  echo "error: offline rescue backup entry point is missing." >&2
  exit 1
}
[[ -s "$ROOT_DIR/system/base/installer/restore.sh" ]] || {
  echo "error: offline rescue restore entry point is missing." >&2
  exit 1
}

rm -rf -- "$OUT_DIR"
mkdir -p "$ROOTFS_DIR"
tar --numeric-owner --xattrs --acls -xzf "$BASE_ARCHIVE" -C "$ROOTFS_DIR"

# The installer is a separate in-memory Debian environment. Keep /init out of
# the archive that will be installed onto the target root filesystem.
install -m 0755 "$ROOT_DIR/system/base/installer/init" "$ROOTFS_DIR/init"
install -D -m 0755 "$ROOT_DIR/system/base/installer/install.sh" \
  "$ROOTFS_DIR/usr/lib/aura/installer/install.sh"
install -D -m 0755 "$ROOT_DIR/system/base/installer/rescue.sh" \
  "$ROOTFS_DIR/usr/lib/aura/installer/rescue.sh"
install -D -m 0755 "$ROOT_DIR/system/base/installer/backup.sh" \
  "$ROOTFS_DIR/usr/lib/aura/installer/backup.sh"
install -D -m 0755 "$ROOT_DIR/system/base/installer/restore.sh" \
  "$ROOTFS_DIR/usr/lib/aura/installer/restore.sh"
mkdir -p "$ROOTFS_DIR"/{dev,proc,sys,run,run/udev,run/aura-media,mnt,newroot}
chmod 1777 "$ROOTFS_DIR/tmp"

for command_name in lsblk sfdisk blockdev wipefs mkfs.fat mkfs.ext4 blkid \
                    udevadm tar grub-install mount umount swapon install basename sha256sum \
                    findmnt e2fsck sed awk grep poweroff du df date sync mktemp \
                    mv rm tr id dirname find chmod; do
  if ! chroot "$ROOTFS_DIR" /bin/sh -c "command -v '$command_name' >/dev/null 2>&1"; then
    echo "error: installer runtime is missing required command: $command_name" >&2
    exit 1
  fi
done

(
  cd "$ROOTFS_DIR"
  find . -print0 | LC_ALL=C sort -z |
    cpio --null --create --format=newc --reproducible --owner=0:0 |
    gzip -n -9 > "$ARCHIVE"
)

test -s "$ARCHIVE"
(
  cd "$OUT_DIR"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
cat "$ARCHIVE.sha256"

{
  printf 'Aura OS installer initramfs\n'
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Installer userspace: validated Debian 13 (trixie) base rootfs\n'
  printf 'Installer entry point: /init\n'
  printf 'Installer program: /usr/lib/aura/installer/install.sh\n'
  printf 'Target disk layout: GPT / 512 MiB FAT32 ESP / ext4 root\n'
  printf 'Disk selection: explicit console selection and destructive confirmation required\n'
  printf 'Root filesystem payload: %s\n' "$BASE_ARCHIVE"
} > "$OUT_DIR/build-provenance.txt"

printf 'Created %s installer initramfs: %s\n' "$TARGET_ARCH" "$ARCHIVE"
