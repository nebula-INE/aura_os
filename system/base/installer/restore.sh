#!/bin/sh
# Restore a verified Aura backup to the same UUID-preserving installation.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077

ROOT_MOUNT_BASE=/mnt/aura-rescue
BACKUP_MOUNT=/mnt/aura-restore-backup
TARGET_MOUNT=/mnt/aura-restore-root
TARGET_ESP_MOUNT=/mnt/aura-restore-efi
ROOT_LIST=/run/aura-restore-roots
BACKUP_DEVICE_LIST=/run/aura-restore-devices
BACKUP_SET_LIST=/run/aura-restore-sets
TARGET_ANCESTRY=/run/aura-restore-target-ancestry
EFI_ANCESTRY=/run/aura-restore-efi-ancestry
BACKUP_ANCESTRY=/run/aura-restore-backup-ancestry
MOUNTED_BACKUP=0
MOUNTED_TARGET_ROOT=0
MOUNTED_TARGET_EFI=0
ROOT_ORIGINAL_UNMOUNTED=0
EFI_ORIGINAL_UNMOUNTED=0
ROOT_STAGE=
EFI_STAGE=

fail() {
    echo "[Aura restore] ERROR: $*" >&2
    exit 1
}

VERIFY_ONLY=0
case "${1:-}" in
    "") ;;
    --verify-only) VERIFY_ONLY=1 ;;
    *) fail "usage: restore.sh [--verify-only]" ;;
esac
[ "$#" -le 1 ] || fail "usage: restore.sh [--verify-only]"

cleanup() {
    if [ "$MOUNTED_TARGET_EFI" -eq 1 ]; then
        if [ -n "$EFI_STAGE" ] && [ -d "$EFI_STAGE" ]; then rm -rf -- "$EFI_STAGE" 2>/dev/null || true; fi
        sync 2>/dev/null || true
        umount "$TARGET_ESP_MOUNT" 2>/dev/null || true
        MOUNTED_TARGET_EFI=0
    fi
    if [ "$MOUNTED_TARGET_ROOT" -eq 1 ]; then
        if [ -n "$ROOT_STAGE" ] && [ -d "$ROOT_STAGE" ]; then rm -rf -- "$ROOT_STAGE" 2>/dev/null || true; fi
        sync 2>/dev/null || true
        umount "$TARGET_MOUNT" 2>/dev/null || true
        MOUNTED_TARGET_ROOT=0
    fi
    if [ "$EFI_ORIGINAL_UNMOUNTED" -eq 1 ] && [ -n "$ESP_DEVICE" ]; then
        mount -t vfat -o ro,nodev,nosuid,noexec "$ESP_DEVICE" "$ESP_SOURCE" 2>/dev/null || true
        EFI_ORIGINAL_UNMOUNTED=0
    fi
    if [ "$ROOT_ORIGINAL_UNMOUNTED" -eq 1 ] && [ -n "$TARGET_DEVICE" ]; then
        mount -t ext4 -o ro,noload,nodev,nosuid,noexec "$TARGET_DEVICE" "$TARGET_ROOT" 2>/dev/null || true
        ROOT_ORIGINAL_UNMOUNTED=0
    fi
    if [ "$MOUNTED_BACKUP" -eq 1 ]; then
        umount "$BACKUP_MOUNT" 2>/dev/null || true
        MOUNTED_BACKUP=0
    fi
}

manifest_value() {
    sed -n "s/^$1=//p" "$MANIFEST" | sed -n '1p'
}

validate_archive() {
    archive_path=$1
    expected_sha=$2
    [ -s "$archive_path" ] || fail "backup archive is missing or empty: $(basename "$archive_path")"
    actual_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
    [ "$actual_sha" = "$expected_sha" ] ||
        fail "SHA-256 does not match the backup manifest: $(basename "$archive_path")"
    gzip --test "$archive_path" || fail "gzip integrity check failed: $(basename "$archive_path")"
    tar --list --gzip --file="$archive_path" >/dev/null ||
        fail "tar archive validation failed: $(basename "$archive_path")"
    tar --list --gzip --file="$archive_path" | awk '
        /^\// { unsafe = 1 }
        {
            count = split($0, parts, "/")
            for (part_index = 1; part_index <= count; part_index++) {
                if (parts[part_index] == "..") unsafe = 1
            }
        }
        END { exit unsafe }
    ' || fail "archive contains an absolute or parent-traversal path."
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

[ "$(id -u)" = 0 ] || fail "restore wizard must run as root."
for command_name in tar gzip sha256sum findmnt lsblk blkid mount umount \
                    sed awk grep tr basename dirname mktemp mkdir rm mv find sync cat chmod; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "required command is unavailable: $command_name"
done

mkdir -p /run "$BACKUP_MOUNT" "$TARGET_MOUNT" "$TARGET_ESP_MOUNT"
: > "$ROOT_LIST"
: > "$BACKUP_DEVICE_LIST"
: > "$BACKUP_SET_LIST"

echo
echo "Aura OS restore wizard"
echo "The selected installation will be overwritten by a verified backup."
echo "The backup device remains mounted read-only; no disk is formatted."
echo "Restore is limited to the original root filesystem UUID and architecture."
echo

root_index=0
for root_candidate in "$ROOT_MOUNT_BASE"/root-*; do
    [ -d "$root_candidate" ] || continue
    findmnt --mountpoint "$root_candidate" >/dev/null 2>&1 || continue
    root_fs="$(findmnt -n -o FSTYPE --target "$root_candidate" 2>/dev/null || true)"
    root_opts="$(findmnt -n -o OPTIONS --target "$root_candidate" 2>/dev/null || true)"
    [ "$root_fs" = "ext4" ] || continue
    case ",$root_opts," in *,ro,*) ;; *) continue ;; esac
    root_index=$((root_index + 1))
    printf '%s\n' "$root_candidate" >> "$ROOT_LIST"
    printf '  %s) %s (%s)\n' "$root_index" "$root_candidate" \
        "$(findmnt -n -o SOURCE --target "$root_candidate")"
done
[ "$root_index" -gt 0 ] || fail "no mounted read-only Aura root filesystem was found."

echo
printf 'Select the target root number: '
IFS= read -r target_selection
case "$target_selection" in ''|*[!0-9]*) fail "invalid target root selection." ;; esac
TARGET_ROOT="$(sed -n "$target_selection""p" "$ROOT_LIST")"
[ -n "$TARGET_ROOT" ] || fail "the selected target root does not exist."
TARGET_DEVICE="$(findmnt -n -o SOURCE --target "$TARGET_ROOT")"
[ -b "$TARGET_DEVICE" ] || fail "the selected target root is not a block device."
[ "$(blkid -s TYPE -o value "$TARGET_DEVICE" 2>/dev/null || true)" = "ext4" ] ||
    fail "the selected target root is not ext4."
[ "$(blkid -s LABEL -o value "$TARGET_DEVICE" 2>/dev/null || true)" = "AURA_ROOTFS" ] ||
    fail "the selected target does not have the AURA_ROOTFS label."
TARGET_UUID="$(blkid -s UUID -o value "$TARGET_DEVICE" 2>/dev/null || true)"
[ -n "$TARGET_UUID" ] || fail "could not identify the target root UUID."
TARGET_OPTS="$(findmnt -n -o OPTIONS --target "$TARGET_ROOT")"
case ",$TARGET_OPTS," in *,ro,*) ;; *) fail "the target root is not mounted read-only." ;; esac
lsblk --inverse --list --noheadings --paths --output NAME "$TARGET_DEVICE" \
    > "$TARGET_ANCESTRY" || fail "could not identify the target root disk ancestry."

EXPECTED_ESP_UUID="$(awk '$2 == "/boot/efi" && $1 ~ /^UUID=/ {sub(/^UUID=/, "", $1); print $1; exit}' "$TARGET_ROOT/etc/fstab" 2>/dev/null || true)"
ESP_SOURCE=
ESP_DEVICE=
ESP_UUID=
: > "$EFI_ANCESTRY"
if [ -n "$EXPECTED_ESP_UUID" ]; then
    for esp_candidate in "$ROOT_MOUNT_BASE"/esp-*; do
        [ -d "$esp_candidate" ] || continue
        findmnt --mountpoint "$esp_candidate" >/dev/null 2>&1 || continue
        candidate_device="$(findmnt -n -o SOURCE --target "$esp_candidate")"
        candidate_uuid="$(blkid -s UUID -o value "$candidate_device" 2>/dev/null || true)"
        [ "$candidate_uuid" = "$EXPECTED_ESP_UUID" ] || continue
        candidate_options="$(findmnt -n -o OPTIONS --target "$esp_candidate")"
        case ",$candidate_options," in *,ro,*) ;; *) fail "the target EFI partition is not mounted read-only." ;; esac
        ESP_SOURCE="$esp_candidate"
        ESP_DEVICE="$candidate_device"
        ESP_UUID="$candidate_uuid"
        break
    done
    [ -n "$ESP_SOURCE" ] || fail "the EFI partition referenced by target /etc/fstab was not found."
    [ "$(blkid -s LABEL -o value "$ESP_DEVICE" 2>/dev/null || true)" = "AURA_EFI" ] ||
        fail "the matching EFI partition does not have the AURA_EFI label."
    lsblk --inverse --list --noheadings --paths --output NAME "$ESP_DEVICE" \
        > "$EFI_ANCESTRY" || fail "could not identify the EFI disk ancestry."
fi

echo
echo "Available separate, unmounted ext4 backup filesystems:"
backup_index=0
for backup_candidate in $(blkid -t TYPE=ext4 -o device 2>/dev/null || true); do
    [ -b "$backup_candidate" ] || continue
    backup_label="$(blkid -s LABEL -o value "$backup_candidate" 2>/dev/null || true)"
    case "$backup_label" in AURA_ROOTFS|AURA_EFI) continue ;; esac
    backup_uuid="$(blkid -s UUID -o value "$backup_candidate" 2>/dev/null || true)"
    [ -n "$backup_uuid" ] || continue
    [ "$backup_uuid" != "$TARGET_UUID" ] || continue
    backup_mount="$(findmnt --noheadings --raw --source "$backup_candidate" --output TARGET 2>/dev/null || true)"
    [ -z "$backup_mount" ] || continue
    backup_ro="$(lsblk --nodeps --noheadings --output RO "$backup_candidate" | tr -d '[:space:]')"
    [ "$backup_ro" = "0" ] || continue
    lsblk --inverse --list --noheadings --paths --output NAME "$backup_candidate" \
        > "$BACKUP_ANCESTRY" || continue
    shared_ancestry=0
    while IFS= read -r ancestor; do
        [ -n "$ancestor" ] || continue
        if grep -Fqx -- "$ancestor" "$TARGET_ANCESTRY" ||
           { [ -s "$EFI_ANCESTRY" ] && grep -Fqx -- "$ancestor" "$EFI_ANCESTRY"; }; then
            shared_ancestry=1
            break
        fi
    done < "$BACKUP_ANCESTRY"
    [ "$shared_ancestry" -eq 0 ] || continue
    backup_index=$((backup_index + 1))
    printf '%s\n' "$backup_candidate" >> "$BACKUP_DEVICE_LIST"
    printf '  %s) %s  %s\n' "$backup_index" "$backup_candidate" \
        "$(lsblk --nodeps --noheadings --output SIZE,MODEL,TRAN "$backup_candidate" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g')"
done
[ "$backup_index" -gt 0 ] || fail "no separate, unmounted, writable ext4 backup filesystem was found."

echo
printf 'Select the backup filesystem number: '
IFS= read -r backup_selection
case "$backup_selection" in ''|*[!0-9]*) fail "invalid backup filesystem selection." ;; esac
BACKUP_DEVICE="$(sed -n "$backup_selection""p" "$BACKUP_DEVICE_LIST")"
[ -n "$BACKUP_DEVICE" ] || fail "the selected backup filesystem does not exist."
BACKUP_DEVICE_NAME="$(basename "$BACKUP_DEVICE")"
[ -r "/sys/class/block/$BACKUP_DEVICE_NAME/dev" ] || fail "the backup device identity is unavailable."
BACKUP_DEVICE_ID="$(cat "/sys/class/block/$BACKUP_DEVICE_NAME/dev")"
BACKUP_UUID="$(blkid -s UUID -o value "$BACKUP_DEVICE" 2>/dev/null || true)"
[ -n "$BACKUP_UUID" ] || fail "could not identify the backup filesystem UUID."
[ "$(blkid -s TYPE -o value "$BACKUP_DEVICE" 2>/dev/null || true)" = "ext4" ] ||
    fail "the backup source must be ext4."

lsblk --inverse --list --noheadings --paths --output NAME "$BACKUP_DEVICE" \
    > "$BACKUP_ANCESTRY" || fail "could not identify backup disk ancestry."
while IFS= read -r ancestor; do
    [ -n "$ancestor" ] || continue
    if grep -Fqx -- "$ancestor" "$TARGET_ANCESTRY" ||
       { [ -s "$EFI_ANCESTRY" ] && grep -Fqx -- "$ancestor" "$EFI_ANCESTRY"; }; then
        fail "backup filesystem shares a physical disk with the target root or EFI partition."
    fi
done < "$BACKUP_ANCESTRY"

mount -t ext4 -o ro,noload,nodev,nosuid,noexec "$BACKUP_DEVICE" "$BACKUP_MOUNT" ||
    fail "could not mount the backup filesystem read-only."
MOUNTED_BACKUP=1
backup_options="$(findmnt -n -o OPTIONS --target "$BACKUP_MOUNT")"
case ",$backup_options," in *,ro,*) ;; *) fail "backup filesystem did not mount read-only." ;; esac

echo
echo "Available AuraOS backups:"
set_index=0
for manifest_candidate in "$BACKUP_MOUNT"/AuraOS-backups/*/manifest.txt; do
    [ -f "$manifest_candidate" ] || continue
    backup_set="$(dirname "$manifest_candidate")"
    set_index=$((set_index + 1))
    printf '%s\n' "$backup_set" >> "$BACKUP_SET_LIST"
    printf '  %s) %s\n' "$set_index" "$(basename "$backup_set")"
done
[ "$set_index" -gt 0 ] || fail "no AuraOS-backups/<backup>/manifest.txt was found."

echo
printf 'Select the backup number: '
IFS= read -r set_selection
case "$set_selection" in ''|*[!0-9]*) fail "invalid backup selection." ;; esac
BACKUP_DIR="$(sed -n "$set_selection""p" "$BACKUP_SET_LIST")"
[ -n "$BACKUP_DIR" ] || fail "the selected backup set does not exist."
MANIFEST="$BACKUP_DIR/manifest.txt"

FORMAT="$(manifest_value format)"
SOURCE_ARCH="$(manifest_value architecture)"
SOURCE_UUID="$(manifest_value source_uuid)"
SOURCE_FS="$(manifest_value source_filesystem)"
SOURCE_MOUNT="$(manifest_value source_mount)"
ROOT_ARCHIVE="$(manifest_value root_archive)"
ROOT_SHA="$(manifest_value root_sha256)"
EFI_ARCHIVE="$(manifest_value efi_archive)"
EFI_SHA="$(manifest_value efi_sha256)"
REPAIR_PERFORMED="$(manifest_value repair_performed)"

[ "$FORMAT" = "1" ] || fail "unsupported backup manifest format."
[ "$SOURCE_FS" = "ext4" ] || fail "backup source filesystem is not ext4."
[ "$SOURCE_MOUNT" = "read-only" ] || fail "backup manifest does not confirm a read-only source."
[ "$REPAIR_PERFORMED" = "no" ] || fail "backup manifest reports filesystem repair."
[ "$SOURCE_ARCH" = "$(uname -m)" ] ||
    fail "backup architecture $SOURCE_ARCH does not match this rescue environment ($(uname -m))."
[ "$SOURCE_UUID" = "$TARGET_UUID" ] ||
    fail "backup root UUID does not match the selected target root; cross-device relocation is not supported."
[ "$(printf '%s' "$SOURCE_UUID" | awk '{print length($0)}')" -eq 36 ] ||
    fail "backup manifest contains an invalid root UUID."
case "$SOURCE_UUID" in *[!0-9a-fA-F-]*) fail "backup manifest contains an invalid root UUID." ;; esac
[ "$ROOT_ARCHIVE" = "aura-rootfs-$SOURCE_UUID.tar.gz" ] ||
    fail "backup manifest names an unexpected root archive."
[ "$(printf '%s' "$ROOT_SHA" | awk '{print length($0)}')" -eq 64 ] ||
    fail "backup manifest contains an invalid root checksum."
case "$ROOT_SHA" in *[!0-9a-f]*) fail "backup manifest contains an invalid root checksum." ;; esac

ROOT_ARCHIVE_PATH="$BACKUP_DIR/$ROOT_ARCHIVE"
validate_archive "$ROOT_ARCHIVE_PATH" "$ROOT_SHA"

if [ "$EFI_ARCHIVE" != "none" ]; then
    [ "$EFI_ARCHIVE" = "aura-efi-$SOURCE_UUID.tar.gz" ] ||
        fail "backup manifest names an unexpected EFI archive."
    [ "$(printf '%s' "$EFI_SHA" | awk '{print length($0)}')" -eq 64 ] ||
        fail "backup manifest contains an invalid EFI checksum."
    case "$EFI_SHA" in *[!0-9a-f]*) fail "backup manifest contains an invalid EFI checksum." ;; esac
    [ -n "$ESP_SOURCE" ] ||
        fail "backup contains an EFI archive but the target EFI partition could not be matched."
    EFI_ARCHIVE_PATH="$BACKUP_DIR/$EFI_ARCHIVE"
    validate_archive "$EFI_ARCHIVE_PATH" "$EFI_SHA"
else
    [ "$EFI_SHA" = "none" ] || fail "backup manifest has inconsistent EFI metadata."
    EFI_ARCHIVE_PATH=
fi

if [ "$VERIFY_ONLY" -eq 1 ]; then
    echo
    echo "AURA_BACKUP_VERIFY_COMPLETE"
    echo "Backup set: $(basename "$BACKUP_DIR")"
    echo "Root UUID: $TARGET_UUID"
    echo "Root archive SHA-256 and gzip/tar integrity: OK"
    if [ "$EFI_ARCHIVE" != "none" ]; then
        echo "EFI UUID: $ESP_UUID"
        echo "EFI archive SHA-256 and gzip/tar integrity: OK"
    else
        echo "EFI archive: not present; target EFI remains unchanged"
    fi
    echo "No target or backup filesystem was mounted read-write."
    exit 0
fi

TARGET_DEVICE_NAME="$(basename "$TARGET_DEVICE")"
[ -r "/sys/class/block/$TARGET_DEVICE_NAME/dev" ] || fail "target root device identity is unavailable."
TARGET_DEVICE_ID="$(cat "/sys/class/block/$TARGET_DEVICE_NAME/dev")"
TARGET_ESP_DEVICE_NAME=
TARGET_ESP_DEVICE_ID=
if [ "$EFI_ARCHIVE" != "none" ]; then
    TARGET_ESP_DEVICE_NAME="$(basename "$ESP_DEVICE")"
    [ -r "/sys/class/block/$TARGET_ESP_DEVICE_NAME/dev" ] || fail "target EFI device identity is unavailable."
    TARGET_ESP_DEVICE_ID="$(cat "/sys/class/block/$TARGET_ESP_DEVICE_NAME/dev")"
fi

echo
echo "RESTORE PLAN"
echo "  Backup set:  $(basename "$BACKUP_DIR")"
echo "  Backup disk: $BACKUP_DEVICE (read-only)"
echo "  Target root: $TARGET_DEVICE (UUID $TARGET_UUID)"
if [ "$EFI_ARCHIVE" != "none" ]; then
    echo "  Target EFI:  $ESP_DEVICE (UUID $ESP_UUID)"
else
    echo "  Target EFI:  unchanged (backup contains no EFI archive)"
fi
echo "  Root data:   all existing files on the target root will be replaced"
echo "  EFI data:    all existing files on the target EFI will be replaced when present"
echo "  Format:      none; filesystem UUIDs and partition layout are preserved"
echo "  Bootloader:  not reinstalled or modified"
echo
printf 'Type RESTORE TO %s to confirm: ' "$TARGET_DEVICE"
IFS= read -r confirmation
[ "$confirmation" = "RESTORE TO $TARGET_DEVICE" ] || fail "target device confirmation did not match."
printf 'Final confirmation: type RESTORE AURA to overwrite the selected installation: '
IFS= read -r final_confirmation
[ "$final_confirmation" = "RESTORE AURA" ] || fail "final restore confirmation did not match."

[ -b "$BACKUP_DEVICE" ] || fail "backup device disappeared during confirmation."
[ "$(cat "/sys/class/block/$BACKUP_DEVICE_NAME/dev" 2>/dev/null || true)" = "$BACKUP_DEVICE_ID" ] ||
    fail "backup device identity changed during confirmation."
[ "$(blkid -s UUID -o value "$BACKUP_DEVICE" 2>/dev/null || true)" = "$BACKUP_UUID" ] ||
    fail "backup filesystem UUID changed during confirmation."
# Disk topology is checked again below after all three selected device identities
# have been revalidated.
case ",$(findmnt -n -o OPTIONS --target "$BACKUP_MOUNT")," in *,ro,*) ;; *) fail "backup filesystem is no longer read-only." ;; esac
[ -b "$TARGET_DEVICE" ] || fail "target root device disappeared during confirmation."
[ "$(cat "/sys/class/block/$TARGET_DEVICE_NAME/dev" 2>/dev/null || true)" = "$TARGET_DEVICE_ID" ] ||
    fail "target root device identity changed during confirmation."
[ "$(blkid -s UUID -o value "$TARGET_DEVICE" 2>/dev/null || true)" = "$TARGET_UUID" ] ||
    fail "target root UUID changed during confirmation."
[ "$(blkid -s LABEL -o value "$TARGET_DEVICE" 2>/dev/null || true)" = "AURA_ROOTFS" ] ||
    fail "target root label changed during confirmation."
case ",$(findmnt -n -o OPTIONS --target "$TARGET_ROOT")," in *,ro,*) ;; *) fail "target root is no longer mounted read-only." ;; esac

if [ "$EFI_ARCHIVE" != "none" ]; then
    [ -b "$ESP_DEVICE" ] || fail "target EFI device disappeared during confirmation."
    [ "$(cat "/sys/class/block/$TARGET_ESP_DEVICE_NAME/dev" 2>/dev/null || true)" = "$TARGET_ESP_DEVICE_ID" ] ||
        fail "target EFI device identity changed during confirmation."
    [ "$(blkid -s UUID -o value "$ESP_DEVICE" 2>/dev/null || true)" = "$ESP_UUID" ] ||
        fail "target EFI UUID changed during confirmation."
    [ "$(blkid -s LABEL -o value "$ESP_DEVICE" 2>/dev/null || true)" = "AURA_EFI" ] ||
        fail "target EFI label changed during confirmation."
    case ",$(findmnt -n -o OPTIONS --target "$ESP_SOURCE")," in *,ro,*) ;; *) fail "target EFI is no longer mounted read-only." ;; esac
    lsblk --inverse --list --noheadings --paths --output NAME "$ESP_DEVICE" \
        > "$EFI_ANCESTRY" || fail "could not recheck target EFI disk ancestry."
fi
lsblk --inverse --list --noheadings --paths --output NAME "$TARGET_DEVICE" \
    > "$TARGET_ANCESTRY" || fail "could not recheck target root disk ancestry."
lsblk --inverse --list --noheadings --paths --output NAME "$BACKUP_DEVICE" \
    > "$BACKUP_ANCESTRY" || fail "could not recheck backup disk ancestry."
while IFS= read -r ancestor; do
    [ -n "$ancestor" ] || continue
    if grep -Fqx -- "$ancestor" "$TARGET_ANCESTRY" ||
       { [ -s "$EFI_ANCESTRY" ] && grep -Fqx -- "$ancestor" "$EFI_ANCESTRY"; }; then
        fail "backup filesystem now shares a physical disk with the target root or EFI partition."
    fi
done < "$BACKUP_ANCESTRY"

umount "$TARGET_ROOT" || fail "could not unmount the read-only target root."
ROOT_ORIGINAL_UNMOUNTED=1
if [ "$EFI_ARCHIVE" != "none" ]; then
    umount "$ESP_SOURCE" || fail "could not unmount the read-only target EFI partition."
    EFI_ORIGINAL_UNMOUNTED=1
fi

mount -t ext4 -o rw,nodev,nosuid "$TARGET_DEVICE" "$TARGET_MOUNT" ||
    fail "could not mount the target root read-write."
MOUNTED_TARGET_ROOT=1
root_rw_options="$(findmnt -n -o OPTIONS --target "$TARGET_MOUNT")"
case ",$root_rw_options," in *,rw,*) ;; *) fail "target root did not mount read-write." ;; esac

ROOT_STAGE="$(mktemp -d "$TARGET_MOUNT/.aura-restore-stage.XXXXXX")" ||
    fail "could not create a root restore staging directory."
echo "Validating and staging the root filesystem archive..."
tar --extract --gzip --file="$ROOT_ARCHIVE_PATH" --directory="$ROOT_STAGE" \
    --numeric-owner --same-owner --xattrs --acls
[ -s "$ROOT_STAGE/etc/fstab" ] || fail "staged root archive does not contain /etc/fstab."
grep -Eq "UUID=$TARGET_UUID[[:space:]]+/[[:space:]]+ext4([[:space:]]|$)" "$ROOT_STAGE/etc/fstab" ||
    fail "staged /etc/fstab does not refer to the original root UUID."

if [ "$EFI_ARCHIVE" != "none" ]; then
    mount -t vfat -o rw,nodev,nosuid,noexec "$ESP_DEVICE" "$TARGET_ESP_MOUNT" ||
        fail "could not mount the target EFI partition read-write."
    MOUNTED_TARGET_EFI=1
    efi_rw_options="$(findmnt -n -o OPTIONS --target "$TARGET_ESP_MOUNT")"
    case ",$efi_rw_options," in *,rw,*) ;; *) fail "target EFI did not mount read-write." ;; esac
    EFI_STAGE="$(mktemp -d "$TARGET_ESP_MOUNT/.aura-restore-stage.XXXXXX")" ||
        fail "could not create an EFI restore staging directory."
    echo "Validating and staging the EFI system partition archive..."
    tar --extract --gzip --file="$EFI_ARCHIVE_PATH" --directory="$EFI_STAGE" --numeric-owner --no-same-owner
    grep -Fq "UUID=$ESP_UUID /boot/efi vfat" "$ROOT_STAGE/etc/fstab" ||
        fail "staged /etc/fstab does not refer to the selected EFI UUID."
    case "$(uname -m)" in
        x86_64) efi_loader=BOOTX64.EFI ;;
        aarch64) efi_loader=BOOTAA64.EFI ;;
        riscv64) efi_loader=BOOTRISCV64.EFI ;;
        *) fail "unsupported architecture for EFI restore." ;;
    esac
    [ -s "$EFI_STAGE/EFI/BOOT/$efi_loader" ] ||
        fail "staged EFI archive is missing the architecture fallback loader."
fi

echo "Staged archives passed validation. Replacing the selected filesystem contents..."
find "$TARGET_MOUNT" -mindepth 1 -maxdepth 1 \
    ! -name "$(basename "$ROOT_STAGE")" -exec rm -rf -- {} +
find "$ROOT_STAGE" -mindepth 1 -maxdepth 1 -exec mv -t "$TARGET_MOUNT" -- {} +
rmdir "$ROOT_STAGE"
ROOT_STAGE=

# The backup intentionally excludes volatile mount points and temporary data.
# Recreate the directories expected by the installed system after promotion.
mkdir -p "$TARGET_MOUNT/dev" "$TARGET_MOUNT/proc" "$TARGET_MOUNT/sys" \
    "$TARGET_MOUNT/run" "$TARGET_MOUNT/tmp"
chmod 1777 "$TARGET_MOUNT/tmp"

if [ "$EFI_ARCHIVE" != "none" ]; then
    find "$TARGET_ESP_MOUNT" -mindepth 1 -maxdepth 1 \
        ! -name "$(basename "$EFI_STAGE")" -exec rm -rf -- {} +
    find "$EFI_STAGE" -mindepth 1 -maxdepth 1 -exec mv -t "$TARGET_ESP_MOUNT" -- {} +
    rmdir "$EFI_STAGE"
    EFI_STAGE=
fi

sync
if [ "$MOUNTED_TARGET_EFI" -eq 1 ]; then
    umount "$TARGET_ESP_MOUNT" || fail "restored EFI partition could not be cleanly unmounted."
    MOUNTED_TARGET_EFI=0
    mount -t vfat -o ro,nodev,nosuid,noexec "$ESP_DEVICE" "$ESP_SOURCE" ||
        fail "restored EFI partition could not be remounted read-only."
    EFI_ORIGINAL_UNMOUNTED=0
fi
umount "$TARGET_MOUNT" || fail "restored root filesystem could not be cleanly unmounted."
MOUNTED_TARGET_ROOT=0
mount -t ext4 -o ro,noload,nodev,nosuid,noexec "$TARGET_DEVICE" "$TARGET_ROOT" ||
    fail "restored root filesystem could not be remounted read-only."
ROOT_ORIGINAL_UNMOUNTED=0
umount "$BACKUP_MOUNT" || fail "backup filesystem could not be cleanly unmounted."
MOUNTED_BACKUP=0

echo
echo "AURA_RESTORE_COMPLETE"
echo "Restored root UUID: $TARGET_UUID"
if [ "$EFI_ARCHIVE" != "none" ]; then
    echo "Restored EFI UUID: $ESP_UUID"
else
    echo "EFI partition was left unchanged."
fi
echo "Root and EFI filesystems are mounted read-only again."
echo "No filesystem was formatted and no bootloader repair was attempted."

