#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET_ARCH="${TARGET_ARCH:-}"
ROOTFS_DIR="${ROOTFS_DIR:-$ROOT_DIR/build/base-userspace/$TARGET_ARCH/rootfs}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-$ROOT_DIR/build/base-userspace/$TARGET_ARCH/aura-base-$TARGET_ARCH.ext4}"
IMAGE_SIZE="${IMAGE_SIZE:-1G}"
MOUNT_DIR=""

case "$TARGET_ARCH" in
  x86_64|aarch64|riscv64) ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run this image builder as root." >&2
  exit 1
fi

for cmd in truncate mkfs.ext4 mount umount mountpoint tar sha256sum e2fsck chmod chown; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
done

if [[ ! -d "$ROOTFS_DIR" || ! -s "$ROOTFS_DIR/usr/lib/systemd/systemd" ]]; then
  echo "error: a validated Debian rootfs is required: $ROOTFS_DIR" >&2
  exit 1
fi

case "$OUTPUT_IMAGE" in
  "$ROOT_DIR"/build/base-userspace/*) ;;
  *)
    echo "error: output image must be inside build/base-userspace/." >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aura-rootfs.XXXXXX")"
cleanup() {
  if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR"; then
    umount "$MOUNT_DIR"
  fi
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    rmdir "$MOUNT_DIR"
  fi
}
trap cleanup EXIT

rm -f -- "$OUTPUT_IMAGE"
truncate -s "$IMAGE_SIZE" "$OUTPUT_IMAGE"
mkfs.ext4 -F -m 0 -L AURA_ROOTFS "$OUTPUT_IMAGE"
mount -o loop "$OUTPUT_IMAGE" "$MOUNT_DIR"

echo "Copying the $TARGET_ARCH Debian rootfs into the ext4 image..."
tar --numeric-owner --xattrs --acls -C "$ROOTFS_DIR" -cf - . |
  tar --numeric-owner --xattrs --acls -xf - -C "$MOUNT_DIR"

mkdir -p "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants"
cat > "$MOUNT_DIR/etc/systemd/system/aura-rootfs-smoke.service" <<'UNIT'
[Unit]
Description=Aura OS persistent rootfs QEMU smoke test
After=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo AURA_SYSTEMD_ROOTFS_OK > /dev/console; echo AURA_ROOTFS_QEMU_PASS > /dev/console'
ExecStartPost=/bin/systemctl --no-block poweroff
TimeoutStartSec=30
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn /etc/systemd/system/aura-rootfs-smoke.service \
  "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/aura-rootfs-smoke.service"

sync
umount "$MOUNT_DIR"
e2fsck -fn "$OUTPUT_IMAGE"

# The image is built under sudo, but QEMU runs as the original unprivileged
# runner user and opens the disk read-write. Return ownership to that caller.
(
  cd "$(dirname "$OUTPUT_IMAGE")"
  sha256sum "$(basename "$OUTPUT_IMAGE")" > "$(basename "$OUTPUT_IMAGE").sha256"
)
if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
  chown "$SUDO_UID:$SUDO_GID" "$OUTPUT_IMAGE" "$OUTPUT_IMAGE.sha256"
  chmod 0644 "$OUTPUT_IMAGE" "$OUTPUT_IMAGE.sha256"
else
  # Direct root invocation has no recorded caller; allow the local test user
  # to open the temporary image read-write rather than silently making it RO.
  chmod 0666 "$OUTPUT_IMAGE"
  chmod 0644 "$OUTPUT_IMAGE.sha256"
fi
cat "$OUTPUT_IMAGE.sha256"
printf 'Created Aura OS %s persistent rootfs image: %s\n' "$TARGET_ARCH" "$OUTPUT_IMAGE"
