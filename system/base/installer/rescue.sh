#!/bin/sh
# Offline, inspection-only rescue shell for Aura OS install media.
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
HOME=/root
TERM=linux
LC_ALL=C
export HOME TERM LC_ALL
umask 077

ROOT_MOUNT_BASE=/mnt/aura-rescue
mkdir -p "$ROOT_MOUNT_BASE"
echo
echo "============================================================"
echo " Aura OS Offline Rescue — read-only inspection environment"
echo "============================================================"
echo "No filesystem repair, bootloader rewrite, credential reset, or"
echo "automatic configuration change is performed."
echo

echo "[1/3] Block-device inventory"
lsblk --paths --output NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,RO 2>&1 || true
echo
echo "[2/3] Filesystem signatures"
blkid 2>&1 || true
echo
echo "[3/3] Current mount table"
findmnt --output TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
echo

root_count=0
for device in $(blkid -t LABEL=AURA_ROOTFS -o device 2>/dev/null || true); do
    root_count=$((root_count + 1))
    mount_point="$ROOT_MOUNT_BASE/root-$root_count"
    mkdir -p "$mount_point"
    echo "Inspecting Aura root filesystem: $device"
    # noload prevents ext4 journal replay even though the mount is read-only.
    if mount -t ext4 -o ro,noload,nodev,nosuid,noexec "$device" "$mount_point"; then
        options="$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null || true)"
        case ",$options," in
            *,ro,*)
                echo "AURA_RESCUE_ROOT_RO_OK device=$device mount=$mount_point"
                ;;
            *)
                echo "WARNING: read-only mount flags could not be verified for $device."
                umount "$mount_point" 2>/dev/null || true
                ;;
        esac
    else
        echo "WARNING: could not mount $device read-only; no repair was attempted."
    fi
done

esp_count=0
for device in $(blkid -t LABEL=AURA_EFI -o device 2>/dev/null || true); do
    esp_count=$((esp_count + 1))
    mount_point="$ROOT_MOUNT_BASE/esp-$esp_count"
    mkdir -p "$mount_point"
    echo "Inspecting Aura EFI system partition: $device"
    if mount -t vfat -o ro,nodev,nosuid,noexec "$device" "$mount_point"; then
        options="$(findmnt -n -o OPTIONS --target "$mount_point" 2>/dev/null || true)"
        case ",$options," in
            *,ro,*)
                echo "AURA_RESCUE_ESP_RO_OK device=$device mount=$mount_point"
                ;;
            *)
                echo "WARNING: EFI read-only mount flags could not be verified for $device."
                umount "$mount_point" 2>/dev/null || true
                ;;
        esac
    else
        echo "WARNING: could not mount $device read-only."
    fi
done

if [ "$root_count" -eq 0 ]; then
    echo "AURA_RESCUE_NO_ROOTFS_FOUND"
    echo "No partition labelled AURA_ROOTFS was found."
fi
if [ "$esp_count" -eq 0 ]; then
    echo "No partition labelled AURA_EFI was found."
fi

cat <<'HELP'

Read-only inspection commands:
  lsblk -f
  blkid
  findmnt
  cat /mnt/aura-rescue/root-1/etc/os-release
  cat /mnt/aura-rescue/root-1/var/lib/aura/install-manifest
  e2fsck -fn /dev/<unmounted-root-device>

The installed root filesystems are mounted with ro,noload. Do not run a
repair against a mounted filesystem. This environment does not perform
repairs or modify disks; make a separate backup before any later repair
workflow. The installer ISO itself is mounted read-only.

Type 'poweroff --force' to shut down, or 'exit' to return to the rescue shell.
HELP

echo "AURA_RESCUE_READY"
PS1='[Aura offline rescue]# '
export PS1
exec /bin/sh -i
