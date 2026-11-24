#!/bin/sh
# Explicit, backup-first export from the read-only Aura Offline Rescue shell.
set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077

ROOT_MOUNT_BASE=/mnt/aura-rescue
BACKUP_MOUNT=/mnt/aura-backup
ROOT_LIST=/run/aura-backup-roots
DEST_LIST=/run/aura-backup-destinations
SOURCE_ANCESTRY=/run/aura-backup-source-ancestry
MOUNTED=0
TEMP_DIR=

fail() {
    echo "[Aura backup] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
    if [ "$MOUNTED" -eq 1 ]; then
        umount "$BACKUP_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

[ "$(id -u)" = 0 ] || fail "backup wizard must run as root."
command -v tar >/dev/null 2>&1 || fail "tar is unavailable."
command -v gzip >/dev/null 2>&1 || fail "gzip is unavailable."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is unavailable."
command -v findmnt >/dev/null 2>&1 || fail "findmnt is unavailable."
command -v lsblk >/dev/null 2>&1 || fail "lsblk is unavailable."
command -v blkid >/dev/null 2>&1 || fail "blkid is unavailable."

mkdir -p /run "$BACKUP_MOUNT"
: > "$ROOT_LIST"
: > "$DEST_LIST"
: > "$SOURCE_ANCESTRY"

echo
echo "Aura OS backup wizard"
echo "The installed source will remain read-only."
echo "Backups are written only to a separate, existing ext4 filesystem."
echo "No filesystem will be formatted or repaired."
echo

root_index=0
for source_root in "$ROOT_MOUNT_BASE"/root-*; do
    [ -d "$source_root" ] || continue
    findmnt --mountpoint "$source_root" >/dev/null 2>&1 || continue
    source_fs="$(findmnt -n -o FSTYPE --target "$source_root" 2>/dev/null || true)"
    source_opts="$(findmnt -n -o OPTIONS --target "$source_root" 2>/dev/null || true)"
    [ "$source_fs" = "ext4" ] || continue
    case ",$source_opts," in
        *,ro,*) ;;
        *) continue ;;
    esac
    root_index=$((root_index + 1))
    printf '%s\n' "$source_root" >> "$ROOT_LIST"
    printf '  %s) %s\n' "$root_index" "$source_root"
done
[ "$root_index" -gt 0 ] || fail "no mounted read-only Aura root filesystem was found."

echo
printf 'Select the source root number: '
IFS= read -r source_selection
case "$source_selection" in
    ''|*[!0-9]*) fail "invalid source selection." ;;
esac
SOURCE_ROOT="$(sed -n "${source_selection}p" "$ROOT_LIST")"
[ -n "$SOURCE_ROOT" ] || fail "the selected source root does not exist."
findmnt --mountpoint "$SOURCE_ROOT" >/dev/null 2>&1 ||
    fail "the selected source is no longer mounted."
SOURCE_DEVICE="$(findmnt -n -o SOURCE --target "$SOURCE_ROOT")"
SOURCE_UUID="$(blkid -s UUID -o value "$SOURCE_DEVICE" 2>/dev/null || true)"
[ -n "$SOURCE_UUID" ] || fail "could not identify the source filesystem UUID."
SOURCE_OPTS="$(findmnt -n -o OPTIONS --target "$SOURCE_ROOT")"
case ",$SOURCE_OPTS," in
    *,ro,*) ;;
    *) fail "source filesystem is not mounted read-only." ;;
esac
lsblk --inverse --list --noheadings --paths --output NAME "$SOURCE_DEVICE" \
    > "$SOURCE_ANCESTRY" ||
    fail "could not identify the source disk ancestry."

ESP_SOURCE="$ROOT_MOUNT_BASE/esp-$source_selection"
ESP_DEVICE=
if [ -d "$ESP_SOURCE" ] && findmnt --mountpoint "$ESP_SOURCE" >/dev/null 2>&1; then
    ESP_OPTS="$(findmnt -n -o OPTIONS --target "$ESP_SOURCE")"
    case ",$ESP_OPTS," in
        *,ro,*)
            ESP_DEVICE="$(findmnt -n -o SOURCE --target "$ESP_SOURCE")"
            ;;
        *)
            fail "EFI source is not mounted read-only."
            ;;
    esac
else
    ESP_SOURCE=
fi

echo
echo "Available separate ext4 backup filesystems:"
dest_index=0
for destination in $(blkid -t TYPE=ext4 -o device 2>/dev/null || true); do
    [ -b "$destination" ] || continue
    dest_label="$(blkid -s LABEL -o value "$destination" 2>/dev/null || true)"
    case "$dest_label" in
        AURA_ROOTFS|AURA_EFI) continue ;;
    esac
    dest_uuid="$(blkid -s UUID -o value "$destination" 2>/dev/null || true)"
    [ -n "$dest_uuid" ] || continue
    [ "$dest_uuid" != "$SOURCE_UUID" ] || continue
    dest_ro="$(lsblk --nodeps --noheadings --output RO "$destination" | tr -d '[:space:]')"
    [ "$dest_ro" = "0" ] || continue
    dest_mount="$(findmnt --noheadings --raw --source "$destination" --output TARGET 2>/dev/null || true)"
    [ -z "$dest_mount" ] || continue

    shared_ancestry=0
    while IFS= read -r ancestor; do
        [ -n "$ancestor" ] || continue
        if grep -Fqx -- "$ancestor" "$SOURCE_ANCESTRY"; then
            shared_ancestry=1
            break
        fi
    done <<DEST_ANCESTRY
$(lsblk --inverse --list --noheadings --paths --output NAME "$destination" 2>/dev/null || true)
DEST_ANCESTRY
    [ "$shared_ancestry" -eq 0 ] || continue

    dest_index=$((dest_index + 1))
    printf '%s\n' "$destination" >> "$DEST_LIST"
    printf '  %s) %s  %s\n' "$dest_index" "$destination" \
        "$(lsblk --nodeps --noheadings --output SIZE,MODEL,TRAN "$destination" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g')"
done
[ "$dest_index" -gt 0 ] ||
    fail "no separate, unmounted, writable ext4 backup filesystem was found."

echo
printf 'Select the backup destination number: '
IFS= read -r destination_selection
case "$destination_selection" in
    ''|*[!0-9]*) fail "invalid destination selection." ;;
esac
DEST_DEVICE="$(sed -n "${destination_selection}p" "$DEST_LIST")"
[ -n "$DEST_DEVICE" ] || fail "the selected backup destination is unavailable."

# Revalidate the source and destination immediately before explicit consent.
[ -b "$DEST_DEVICE" ] || fail "the destination device disappeared."
DEST_FS="$(blkid -s TYPE -o value "$DEST_DEVICE" 2>/dev/null || true)"
[ "$DEST_FS" = "ext4" ] || fail "the backup destination must remain ext4."
DEST_RO="$(lsblk --nodeps --noheadings --output RO "$DEST_DEVICE" | tr -d '[:space:]')"
[ "$DEST_RO" = "0" ] || fail "the backup destination is read-only."
dest_mount="$(findmnt --noheadings --raw --source "$DEST_DEVICE" --output TARGET 2>/dev/null || true)"
[ -z "$dest_mount" ] || fail "the backup destination is already mounted."
dest_label="$(blkid -s LABEL -o value "$DEST_DEVICE" 2>/dev/null || true)"
case "$dest_label" in
    AURA_ROOTFS|AURA_EFI) fail "refusing to use an Aura system filesystem as the backup destination." ;;
esac
while IFS= read -r ancestor; do
    [ -n "$ancestor" ] || continue
    if grep -Fqx -- "$ancestor" "$SOURCE_ANCESTRY"; then
        fail "backup destination shares a physical disk with the source."
    fi
done <<DEST_ANCESTRY
$(lsblk --inverse --list --noheadings --paths --output NAME "$DEST_DEVICE")
DEST_ANCESTRY

echo
echo "BACKUP DESTINATION"
echo "  Source:      $SOURCE_ROOT ($SOURCE_DEVICE, UUID $SOURCE_UUID)"
echo "  Destination: $DEST_DEVICE"
echo "  Filesystem:  ext4"
echo "  Mount path:  $BACKUP_MOUNT"
echo "  Format:      none (existing data on the destination is preserved)"
printf 'Type BACKUP TO %s to confirm: ' "$DEST_DEVICE"
IFS= read -r confirmation
[ "$confirmation" = "BACKUP TO $DEST_DEVICE" ] ||
    fail "backup destination confirmation did not match."
printf 'Final confirmation: type CREATE BACKUP to write the backup: '
IFS= read -r final_confirmation
[ "$final_confirmation" = "CREATE BACKUP" ] ||
    fail "final backup confirmation did not match."

# Recheck the source and destination after both confirmations.
SOURCE_OPTS="$(findmnt -n -o OPTIONS --target "$SOURCE_ROOT")"
case ",$SOURCE_OPTS," in
    *,ro,*) ;;
    *) fail "source filesystem changed from read-only state." ;;
esac
[ "$(blkid -s TYPE -o value "$DEST_DEVICE" 2>/dev/null || true)" = "ext4" ] ||
    fail "destination filesystem changed."
[ "$(lsblk --nodeps --noheadings --output RO "$DEST_DEVICE" | tr -d '[:space:]')" = "0" ] ||
    fail "destination became read-only."
[ -z "$(findmnt --noheadings --raw --source "$DEST_DEVICE" --output TARGET 2>/dev/null || true)" ] ||
    fail "destination was mounted during confirmation."

mount -t ext4 -o rw,nodev,nosuid,noexec "$DEST_DEVICE" "$BACKUP_MOUNT" ||
    fail "could not mount the selected destination filesystem."
MOUNTED=1
mount_options="$(findmnt -n -o OPTIONS --target "$BACKUP_MOUNT")"
case ",$mount_options," in
    *,rw,*) ;;
    *) fail "backup destination did not mount read-write." ;;
esac

source_bytes="$(du -sx -B1 "$SOURCE_ROOT" | awk '{print $1}')"
esp_bytes=0
if [ -n "$ESP_SOURCE" ]; then
    esp_bytes="$(du -sx -B1 "$ESP_SOURCE" | awk '{print $1}')"
fi
required_bytes=$((source_bytes + esp_bytes + 104857600))
available_bytes="$(df -PB1 "$BACKUP_MOUNT" | awk 'NR == 2 {print $4}')"
case "$available_bytes" in
    ''|*[!0-9]*) fail "could not determine free space on the destination." ;;
esac
[ "$available_bytes" -ge "$required_bytes" ] ||
    fail "destination has insufficient free space for a conservative uncompressed-size estimate."

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
backup_root="$BACKUP_MOUNT/AuraOS-backups"
mkdir -p "$backup_root"
final_dir="$backup_root/$timestamp-$SOURCE_UUID"
[ ! -e "$final_dir" ] || fail "a backup with this timestamp and UUID already exists."
TEMP_DIR="$(mktemp -d "$backup_root/.backup.XXXXXX")" ||
    fail "could not create a private temporary backup directory."

root_name="aura-rootfs-$SOURCE_UUID.tar.gz"
root_tmp="$TEMP_DIR/$root_name"
echo
echo "Creating read-only root filesystem backup..."
tar --create --gzip --file="$root_tmp" \
    --numeric-owner --xattrs --acls --one-file-system \
    --exclude=./dev --exclude=./proc --exclude=./sys \
    --exclude=./run --exclude=./tmp \
    --directory="$SOURCE_ROOT" .
gzip --test "$root_tmp"
tar --list --gzip --file="$root_tmp" >/dev/null
root_sha="$(sha256sum "$root_tmp" | awk '{print $1}')"
printf '%s  %s\n' "$root_sha" "$root_name" > "$TEMP_DIR/$root_name.sha256"

efi_name=none
efi_sha=none
if [ -n "$ESP_SOURCE" ]; then
    efi_name="aura-efi-$SOURCE_UUID.tar.gz"
    efi_tmp="$TEMP_DIR/$efi_name"
    echo "Creating read-only EFI system partition backup..."
    tar --create --gzip --file="$efi_tmp" \
        --numeric-owner --directory="$ESP_SOURCE" .
    gzip --test "$efi_tmp"
    tar --list --gzip --file="$efi_tmp" >/dev/null
    efi_sha="$(sha256sum "$efi_tmp" | awk '{print $1}')"
    printf '%s  %s\n' "$efi_sha" "$efi_name" > "$TEMP_DIR/$efi_name.sha256"
fi

{
    printf 'format=1\n'
    printf 'created_utc=%s\n' "$timestamp"
    printf 'architecture=%s\n' "$(uname -m)"
    printf 'source_device=%s\n' "$SOURCE_DEVICE"
    printf 'source_uuid=%s\n' "$SOURCE_UUID"
    printf 'source_filesystem=ext4\n'
    printf 'source_mount=read-only\n'
    printf 'root_archive=%s\n' "$root_name"
    printf 'root_sha256=%s\n' "$root_sha"
    printf 'efi_device=%s\n' "${ESP_DEVICE:-none}"
    printf 'efi_archive=%s\n' "$efi_name"
    printf 'efi_sha256=%s\n' "$efi_sha"
    printf 'backup_destination=%s\n' "$DEST_DEVICE"
    printf 'backup_destination_filesystem=ext4\n'
    printf 'repair_performed=no\n'
} > "$TEMP_DIR/manifest.txt"

mv "$TEMP_DIR" "$final_dir"
TEMP_DIR=
sync
umount "$BACKUP_MOUNT" || fail "backup created but destination could not be cleanly unmounted."
MOUNTED=0

echo
echo "AURA_BACKUP_COMPLETE"
echo "Backup directory: AuraOS-backups/$timestamp-$SOURCE_UUID"
echo "Root archive SHA-256: $root_sha"
echo "EFI archive: $efi_name"
echo "EFI SHA-256: $efi_sha"
echo "The source filesystem was never mounted read-write."
