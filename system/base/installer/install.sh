#!/bin/sh
# Destructive disk installer. A target is never selected automatically.
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
export LC_ALL=C
umask 077

MEDIA_ROOT=/run/aura-media
MEDIA_DEVICE="${AURA_MEDIA_DEVICE:-}"
ARCH="${AURA_TARGET_ARCH:-}"
ROOTFS_ARCHIVE="$MEDIA_ROOT/rootfs/aura-base-$ARCH.tar.gz"
ROOTFS_CHECKSUM="$ROOTFS_ARCHIVE.sha256"
BOOT_KERNEL="$MEDIA_ROOT/boot/vmlinuz-$ARCH"
BOOT_KERNEL_CHECKSUM="$BOOT_KERNEL.sha256"
BOOT_INITRAMFS="$MEDIA_ROOT/boot/initramfs-$ARCH.cpio.gz"
BOOT_INITRAMFS_CHECKSUM="$BOOT_INITRAMFS.sha256"

ROOT_MNT=/mnt/aura-root
ESP_MNT="$ROOT_MNT/boot/efi"
CANDIDATES_FILE=/run/aura-install-candidates
ROOT_MOUNTED=0
ESP_MOUNTED=0

cleanup() {
    if [ "$ESP_MOUNTED" -eq 1 ]; then
        umount "$ESP_MNT" 2>/dev/null || true
    fi
    if [ "$ROOT_MOUNTED" -eq 1 ]; then
        umount "$ROOT_MNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "[Aura OS] ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" = 0 ] || fail "installer must run as root."
case "$ARCH:$(uname -m)" in
    x86_64:x86_64|aarch64:aarch64|riscv64:riscv64) ;;
    *) fail "installer architecture does not match this machine." ;;
esac
[ -b "$MEDIA_DEVICE" ] || fail "installer media device is missing."
[ -s "$ROOTFS_ARCHIVE" ] || fail "Debian root filesystem archive is missing."
[ -s "$BOOT_KERNEL" ] || fail "installed kernel payload is missing."
[ -s "$BOOT_INITRAMFS" ] || fail "persistent-root initramfs payload is missing."
[ -s "$ROOTFS_CHECKSUM" ] || fail "Debian root filesystem checksum is missing."
[ -s "$BOOT_KERNEL_CHECKSUM" ] || fail "installed kernel checksum is missing."
[ -s "$BOOT_INITRAMFS_CHECKSUM" ] || fail "persistent-root initramfs checksum is missing."

# Verify every installed payload before presenting or writing any target disk.
(
    cd "$MEDIA_ROOT/rootfs"
    sha256sum --check --status "$(basename "$ROOTFS_CHECKSUM")"
) || fail "Debian root filesystem checksum verification failed."
(
    cd "$MEDIA_ROOT/boot"
    sha256sum --check --status "$(basename "$BOOT_KERNEL_CHECKSUM")"
) || fail "installed kernel checksum verification failed."
(
    cd "$MEDIA_ROOT/boot"
    sha256sum --check --status "$(basename "$BOOT_INITRAMFS_CHECKSUM")"
) || fail "persistent-root initramfs checksum verification failed."
echo "[Aura OS] Installer payload checksums verified."

case "$ARCH" in
    x86_64)
        GRUB_TARGET=x86_64-efi
        EFI_LOADER=BOOTX64.EFI
        CONSOLE_ARGS="console=ttyS0,115200n8"
        ;;
    aarch64)
        GRUB_TARGET=arm64-efi
        EFI_LOADER=BOOTAA64.EFI
        CONSOLE_ARGS="console=ttyAMA0,115200"
        ;;
    riscv64)
        GRUB_TARGET=riscv64-efi
        EFI_LOADER=BOOTRISCV64.EFI
        CONSOLE_ARGS="console=ttyS0,115200"
        ;;
    *) fail "unsupported target architecture: $ARCH" ;;
esac

for command_name in lsblk sfdisk blockdev wipefs mkfs.fat mkfs.ext4 blkid \
                    udevadm tar grub-install sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "required installer command is unavailable: $command_name"
done

[ -d /sys/class/block ] || fail "sysfs block-device inventory is unavailable."
mkdir -p "$ROOT_MNT" "$ESP_MNT"

# Resolve the complete ancestry of the live medium so it can never be selected
# as an installation target (also protects hybrid USB media).
MEDIA_ANCESTRY="$(lsblk --inverse --list --noheadings --paths --output NAME "$MEDIA_DEVICE" 2>/dev/null || printf '%s\n' "$MEDIA_DEVICE")"
: > "$CANDIDATES_FILE"

echo
echo "Available installation disks (minimum size: 4 GiB):"
echo "The installer media and disks with mounted filesystems are excluded."
disk_index=0
for disk in $(lsblk --nodeps --noheadings --paths --output NAME,TYPE |
              awk '$2 == "disk" { print $1 }'); do
    [ -b "$disk" ] || continue
    if printf '%s\n' "$MEDIA_ANCESTRY" | grep -Fqx -- "$disk"; then
        continue
    fi

    disk_name="$(basename "$disk")"
    [ -r "/sys/class/block/$disk_name/ro" ] || continue
    [ "$(cat "/sys/class/block/$disk_name/ro")" = 0 ] || continue

    # Do not wipe any disk with a mounted descendant or active swap.
    mounted="$(lsblk --noheadings --paths --output MOUNTPOINTS "$disk" |
               sed '/^[[:space:]]*$/d')"
    [ -z "$mounted" ] || continue
    has_active_swap=0
    while IFS= read -r active_swap; do
        [ -n "$active_swap" ] || continue
        if lsblk --list --noheadings --paths --output NAME "$disk" |
           grep -Fqx -- "$active_swap"; then
            has_active_swap=1
            break
        fi
    done <<SWAP_DEVICES
$(swapon --noheadings --raw --output NAME 2>/dev/null || true)
SWAP_DEVICES
    [ "$has_active_swap" -eq 0 ] || continue

    size_bytes="$(blockdev --getsize64 "$disk")"
    [ "$size_bytes" -ge 4294967296 ] || continue

    disk_index=$((disk_index + 1))
    printf '%s\n' "$disk" >> "$CANDIDATES_FILE"
    printf '  %s) %s\n' "$disk_index" "$(lsblk --nodeps --noheadings --output SIZE,MODEL,TRAN "$disk")"
done

[ "$disk_index" -gt 0 ] || fail "no eligible installation disk was found."

echo
printf 'Select the target disk number: '
IFS= read -r selection
case "$selection" in
    ''|*[!0-9]*) fail "invalid disk selection." ;;
esac
TARGET_DISK="$(sed -n "${selection}p" "$CANDIDATES_FILE")"
[ -n "$TARGET_DISK" ] || fail "the selected disk number is not available."

# Revalidate the selected device immediately before asking for destructive consent.
[ -b "$TARGET_DISK" ] || fail "selected disk disappeared."
[ "$(lsblk --nodeps --noheadings --output TYPE "$TARGET_DISK")" = disk ] ||
    fail "selected device is no longer a whole disk."
printf '%s\n' "$MEDIA_ANCESTRY" | grep -Fqx -- "$TARGET_DISK" &&
    fail "refusing to overwrite the installer medium."
mounted="$(lsblk --noheadings --paths --output MOUNTPOINTS "$TARGET_DISK" |
           sed '/^[[:space:]]*$/d')"
[ -z "$mounted" ] || fail "selected disk now has a mounted filesystem."
[ "$(cat "/sys/class/block/$(basename "$TARGET_DISK")/ro")" = 0 ] ||
    fail "selected disk is read-only."
[ "$(blockdev --getsize64 "$TARGET_DISK")" -ge 4294967296 ] ||
    fail "selected disk is smaller than 4 GiB."
while IFS= read -r active_swap; do
    [ -n "$active_swap" ] || continue
    if lsblk --list --noheadings --paths --output NAME "$TARGET_DISK" |
       grep -Fqx -- "$active_swap"; then
        fail "selected disk has active swap on $active_swap."
    fi
done <<SWAP_DEVICES
$(swapon --noheadings --raw --output NAME 2>/dev/null || true)
SWAP_DEVICES

echo
echo "DESTRUCTIVE OPERATION"
echo "  Target: $TARGET_DISK"
lsblk --nodeps --output NAME,SIZE,MODEL,TRAN "$TARGET_DISK"
echo "  Layout: GPT / 512 MiB FAT32 EFI / ext4 root (remaining space)"
echo "  ALL DATA ON $TARGET_DISK WILL BE DESTROYED."
printf 'Type ERASE %s to confirm: ' "$TARGET_DISK"
IFS= read -r confirmation
[ "$confirmation" = "ERASE $TARGET_DISK" ] ||
    fail "disk erase confirmation did not match."
printf 'Final confirmation: type INSTALL AURA to begin writing: '
IFS= read -r final_confirmation
[ "$final_confirmation" = "INSTALL AURA" ] ||
    fail "final installation confirmation did not match."

echo
echo "Installing Aura OS to $TARGET_DISK..."

# GPT partition 1 is the EFI System Partition; partition 2 is the root filesystem.
wipefs --all --force "$TARGET_DISK"
sfdisk --wipe always --wipe-partitions always "$TARGET_DISK" <<'PARTITIONS'
label: gpt
unit: sectors
,512M,U
,,L
PARTITIONS
blockdev --rereadpt "$TARGET_DISK" || true
udevadm settle --timeout=30 || true

partition_for_number() {
    lsblk --list --noheadings --paths --output NAME,PARTN "$TARGET_DISK" |
        awk -v wanted="$1" '$2 == wanted { print $1; exit }'
}

ESP_PART=""
ROOT_PART=""
attempt=0
while [ "$attempt" -lt 30 ]; do
    ESP_PART="$(partition_for_number 1)"
    ROOT_PART="$(partition_for_number 2)"
    [ -n "$ESP_PART" ] && [ -n "$ROOT_PART" ] && break
    attempt=$((attempt + 1))
    sleep 1
done
[ -b "$ESP_PART" ] || fail "EFI partition was not created or discovered."
[ -b "$ROOT_PART" ] || fail "root partition was not created or discovered."

mkfs.fat -F 32 -n AURA_EFI "$ESP_PART"
mkfs.ext4 -F -m 0 -L AURA_ROOTFS "$ROOT_PART"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"
[ -n "$ROOT_UUID" ] && [ -n "$ESP_UUID" ] ||
    fail "could not read the new filesystem UUIDs."

mount -t ext4 "$ROOT_PART" "$ROOT_MNT"
ROOT_MOUNTED=1
mkdir -p "$ESP_MNT"
tar --numeric-owner --xattrs --acls --same-owner \
    -xzf "$ROOTFS_ARCHIVE" -C "$ROOT_MNT"

mkdir -p "$ROOT_MNT/boot" "$ESP_MNT"
install -m 0644 "$BOOT_KERNEL" "$ROOT_MNT/boot/vmlinuz-aura"
install -m 0644 "$BOOT_INITRAMFS" "$ROOT_MNT/boot/aura-initramfs.cpio.gz"
mount -t vfat -o umask=0077 "$ESP_PART" "$ESP_MNT"
ESP_MOUNTED=1

mkdir -p "$ROOT_MNT/etc" "$ROOT_MNT/boot/grub"
cat > "$ROOT_MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
UUID=$ESP_UUID /boot/efi vfat umask=0077 0 2
EOF

cat > "$ROOT_MNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Aura OS"
GRUB_CMDLINE_LINUX="aura.rootfs=1"
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF

# The installer runs target-native GRUB modules from the in-memory Debian
# environment, while all generated boot files are written to the target disk.
grub-install \
    --target="$GRUB_TARGET" \
    --efi-directory="$ESP_MNT" \
    --boot-directory="$ROOT_MNT/boot" \
    --bootloader-id=Aura \
    --no-nvram \
    --removable \
    --recheck \
    "$TARGET_DISK"

cat > "$ROOT_MNT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
insmod part_gpt
insmod fat
insmod ext2
search --no-floppy --fs-uuid --set=root $ROOT_UUID

menuentry 'Aura OS' {
    search --no-floppy --fs-uuid --set=root $ROOT_UUID
    linux /boot/vmlinuz-aura root=UUID=$ROOT_UUID aura.rootfs=1 $CONSOLE_ARGS
    initrd /boot/aura-initramfs.cpio.gz
}
EOF

case "$ARCH" in
    x86_64) EFI_DIR="$ESP_MNT/EFI/BOOT" ;;
    aarch64) EFI_DIR="$ESP_MNT/EFI/BOOT" ;;
    riscv64) EFI_DIR="$ESP_MNT/EFI/BOOT" ;;
esac
[ -s "$EFI_DIR/$EFI_LOADER" ] || fail "GRUB did not create the UEFI fallback loader $EFI_LOADER."

mkdir -p "$ROOT_MNT/var/lib/aura"
{
    printf 'format=1\n'
    printf 'architecture=%s\n' "$ARCH"
    printf 'debian_suite=trixie\n'
    printf 'target_disk=%s\n' "$TARGET_DISK"
    printf 'root_partition=%s\n' "$ROOT_PART"
    printf 'root_uuid=%s\n' "$ROOT_UUID"
    printf 'efi_partition=%s\n' "$ESP_PART"
    printf 'efi_uuid=%s\n' "$ESP_UUID"
    printf 'efi_loader=EFI/BOOT/%s\n' "$EFI_LOADER"
} > "$ROOT_MNT/var/lib/aura/install-manifest"
chmod 0600 "$ROOT_MNT/var/lib/aura/install-manifest"

sync
umount "$ESP_MNT"
ESP_MOUNTED=0
umount "$ROOT_MNT"
ROOT_MOUNTED=0
sync

echo
echo "AURA_INSTALL_COMPLETE"
echo "[Aura OS] Installation completed successfully."
echo "Power off, remove the installer media, then boot from the installed disk."
printf 'Press Enter to power off: '
IFS= read -r _
sync
poweroff --force --force
echo "[Aura OS] ERROR: poweroff command returned unexpectedly."
exec /bin/sh
