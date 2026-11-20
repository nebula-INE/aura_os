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

for cmd in truncate mkfs.ext4 mount umount mountpoint tar sha256sum e2fsck blkid python3 chmod chown install; do
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
INSTALL_QEMU_SMOKE_SERVICE="${AURA_INSTALL_QEMU_SMOKE_SERVICE:-1}"
case "$INSTALL_QEMU_SMOKE_SERVICE" in
  1)
    NETWORK_SMOKE_SOURCE="$ROOT_DIR/scripts/qemu-network-smoke.sh"
    if [[ ! -s "$NETWORK_SMOKE_SOURCE" ]]; then
      echo "error: QEMU network smoke script is missing: $NETWORK_SMOKE_SOURCE" >&2
      exit 1
    fi
    install -D -m 0755 "$NETWORK_SMOKE_SOURCE" \
      "$MOUNT_DIR/usr/lib/aura/qemu-network-smoke"
    cat > "$MOUNT_DIR/etc/systemd/system/aura-rootfs-smoke.service" <<'UNIT'
[Unit]
Description=Aura OS persistent rootfs and network QEMU smoke test
Wants=systemd-networkd.service systemd-resolved.service systemd-timesyncd.service
After=basic.target systemd-networkd.service systemd-resolved.service systemd-timesyncd.service

[Service]
Type=oneshot
ExecStart=/usr/lib/aura/qemu-network-smoke
TimeoutStartSec=150
TimeoutStopSec=10
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
    ln -sfn /etc/systemd/system/aura-rootfs-smoke.service \
      "$MOUNT_DIR/etc/systemd/system/multi-user.target.wants/aura-rootfs-smoke.service"
    ;;
  0)
    echo "Skipping the auto-poweroff smoke service for interactive first-boot login testing."
    ;;
  *)
    echo "error: AURA_INSTALL_QEMU_SMOKE_SERVICE must be 0 or 1." >&2
    exit 2
    ;;
esac

INSTALL_QEMU_CONSOLE_GETTY="${AURA_INSTALL_QEMU_CONSOLE_GETTY:-0}"
case "$INSTALL_QEMU_CONSOLE_GETTY" in
  1)
    mkdir -p "$MOUNT_DIR/etc/systemd/system/getty.target.wants"
    cat > "$MOUNT_DIR/etc/systemd/system/aura-qemu-console-getty.service" <<'UNIT'
[Unit]
Description=Aura OS QEMU kernel-console login for integration tests
After=systemd-user-sessions.service
Before=getty.target
Conflicts=serial-getty@ttyS0.service serial-getty@ttyAMA0.service
ConditionPathExists=/dev/console

[Service]
ExecStart=-/sbin/agetty --noclear --keep-baud - 115200,38400,9600 linux
Type=idle
Restart=always
RestartSec=0
UtmpIdentifier=cons
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
StandardInput=tty-force
StandardOutput=tty
StandardError=tty

[Install]
WantedBy=getty.target
UNIT
    ln -sfn /etc/systemd/system/aura-qemu-console-getty.service \
      "$MOUNT_DIR/etc/systemd/system/getty.target.wants/aura-qemu-console-getty.service"
    # Avoid the systemd-generated per-device serial gettys in this test
    # image; the test getty owns /dev/console on every architecture.
    ln -sfn /dev/null "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyS0.service"
    ln -sfn /dev/null "$MOUNT_DIR/etc/systemd/system/serial-getty@ttyAMA0.service"
    ;;
  0)
    echo "Skipping the QEMU-only kernel-console getty."
    ;;
  *)
    echo "error: AURA_INSTALL_QEMU_CONSOLE_GETTY must be 0 or 1." >&2
    exit 2
    ;;
esac

sync
umount "$MOUNT_DIR"
STORAGE_REPORT="$OUTPUT_IMAGE.storage.json"
python3 "$ROOT_DIR/scripts/verify_storage_image.py" --image "$OUTPUT_IMAGE" --json > "$STORAGE_REPORT"

# The image is built under sudo, but QEMU runs as the original unprivileged
# runner user and opens the disk read-write. Return ownership to that caller.
(
  cd "$(dirname "$OUTPUT_IMAGE")"
  sha256sum "$(basename "$OUTPUT_IMAGE")" > "$(basename "$OUTPUT_IMAGE").sha256"
)
if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]]; then
  chown "$SUDO_UID:$SUDO_GID" "$OUTPUT_IMAGE" "$OUTPUT_IMAGE.sha256" "$STORAGE_REPORT"
else
  # Direct root invocation is expected to run QEMU as root; do not make the
  # image world-writable just to accommodate an unknown caller.
  chmod 0644 "$OUTPUT_IMAGE" "$OUTPUT_IMAGE.sha256" "$STORAGE_REPORT"
fi
cat "$OUTPUT_IMAGE.sha256"
cat "$STORAGE_REPORT"
printf 'Created Aura OS %s persistent rootfs image: %s\n' "$TARGET_ARCH" "$OUTPUT_IMAGE"
