#!/bin/sh
# Read-only offline diagnostics for an installed Aura OS root filesystem.
# This script runs from installer media; it never executes files from the target.
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
LC_ALL=C
export LC_ALL
umask 077

ROOT_MOUNT_BASE=${AURA_RESCUE_ROOT_MOUNT_BASE:-/mnt/aura-rescue}
RUN_DIR=${AURA_RESCUE_RUN_DIR:-/run}
INCLUDE_JOURNAL=0
OUTPUT_NAME=

usage() {
    cat <<'EOF'
Usage: aura-rescue-diagnose [--output FILE.tar.gz] [--include-journal]

Inspect one already-mounted Aura root filesystem without changing it.
The source must be ext4 mounted read-only with noload. The archive and
checksum are written only to the installer RAM filesystem under /run.
Journal collection is opt-in because logs may contain private information.
EOF
}

fail() {
    printf '[Aura diagnostics] ERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail '--output requires a filename'
            OUTPUT_NAME=$2
            shift 2
            ;;
        --include-journal)
            INCLUDE_JOURNAL=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown option: $1"
            ;;
    esac
done

case "$OUTPUT_NAME" in
    */*|.|..)
        fail 'output must be a filename, not a path; reports are restricted to installer RAM'
        ;;
esac
[ -n "$OUTPUT_NAME" ] || {
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || printf 'undated')
    OUTPUT_NAME="aura-rescue-diagnostics-$timestamp.tar.gz"
}
case "$OUTPUT_NAME" in
    *.tar.gz) ;;
    *) fail 'output filename must end in .tar.gz' ;;
esac

[ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] ||
    fail "installer RAM directory is unavailable: $RUN_DIR"
RUN_FS=$(findmnt -n -o FSTYPE --target "$RUN_DIR" 2>/dev/null || true)
[ "$RUN_FS" = tmpfs ] ||
    fail "refusing to write diagnostics outside a tmpfs RAM filesystem (found: ${RUN_FS:-unknown})"
[ -d "$ROOT_MOUNT_BASE" ] && [ ! -L "$ROOT_MOUNT_BASE" ] ||
    fail "offline rescue root mount directory is unavailable: $ROOT_MOUNT_BASE"

OUTPUT="$RUN_DIR/$OUTPUT_NAME"
CHECKSUM="$OUTPUT.sha256"
[ ! -e "$OUTPUT" ] && [ ! -e "$CHECKSUM" ] ||
    fail "refusing to overwrite an existing report: $OUTPUT"

ROOTS_LIST=$(mktemp "$RUN_DIR/aura-rescue-roots.XXXXXX") ||
    fail 'could not create a temporary root inventory'
WORK_DIR=
TEMP_ARCHIVE=
CHECKSUM_TEMP=
cleanup() {
    [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
    [ -z "$TEMP_ARCHIVE" ] || rm -f -- "$TEMP_ARCHIVE"
    [ -z "$CHECKSUM_TEMP" ] || rm -f -- "$CHECKSUM_TEMP"
    [ -z "$ROOTS_LIST" ] || rm -f -- "$ROOTS_LIST"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
: > "$ROOTS_LIST"

echo
echo 'Available mounted Aura root filesystems (must be ext4 and read-only):'
root_index=0
for candidate in "$ROOT_MOUNT_BASE"/root-*; do
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
    findmnt --mountpoint "$candidate" >/dev/null 2>&1 || continue
    candidate_fs=$(findmnt -n -o FSTYPE --target "$candidate" 2>/dev/null || true)
    candidate_opts=$(findmnt -n -o OPTIONS --target "$candidate" 2>/dev/null || true)
    [ "$candidate_fs" = ext4 ] || continue
    case ",$candidate_opts," in
        *,ro,*) ;;
        *) continue ;;
    esac
    case ",$candidate_opts," in
        *,noload,*) ;;
        *) continue ;;
    esac
    root_index=$((root_index + 1))
    printf '%s\n' "$candidate" >> "$ROOTS_LIST"
    printf '  %s) %s\n' "$root_index" "$candidate"
done
[ "$root_index" -gt 0 ] ||
    fail 'no mounted read-only ext4 Aura root filesystem was found'

printf 'Select the root filesystem number to inspect: '
IFS= read -r selection || fail 'could not read root selection'
case "$selection" in
    ''|*[!0-9]*) fail 'invalid root selection' ;;
esac
ROOT=$(sed -n "${selection}p" "$ROOTS_LIST")
[ -n "$ROOT" ] || fail 'selected root filesystem does not exist'
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || fail 'selected root mount disappeared'
findmnt --mountpoint "$ROOT" >/dev/null 2>&1 || fail 'selected root is no longer mounted'
ROOT_FS=$(findmnt -n -o FSTYPE --target "$ROOT" 2>/dev/null || true)
ROOT_OPTIONS=$(findmnt -n -o OPTIONS --target "$ROOT" 2>/dev/null || true)
ROOT_DEVICE=$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)
[ "$ROOT_FS" = ext4 ] || fail 'selected source is no longer an ext4 filesystem'
case ",$ROOT_OPTIONS," in
    *,ro,*) ;;
    *) fail 'selected root filesystem is not mounted read-only' ;;
esac
case ",$ROOT_OPTIONS," in
    *,noload,*) ;;
    *) fail 'selected root filesystem is not mounted with ext4 noload' ;;
esac
[ -n "$ROOT_DEVICE" ] || fail 'could not identify the selected source device'
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEVICE" 2>/dev/null || true)

WORK_DIR=$(mktemp -d "$RUN_DIR/aura-rescue-diagnose.XXXXXX") ||
    fail 'could not create a private work directory'
CAPTURE_INDEX="$WORK_DIR/capture-index.txt"
: > "$CAPTURE_INDEX"

capture_live() {
    section=$1
    shift
    output_file="$WORK_DIR/$section.txt"
    {
        printf 'section=%s\ncommand=' "$section"
        printf '%s ' "$@"
        printf '\n'
        "$@"
        result=$?
        printf '\nexit_status=%s\n' "$result"
    } > "$output_file" 2>&1
    if [ "$result" -eq 0 ]; then
        printf '%s\tcaptured\n' "$section" >> "$CAPTURE_INDEX"
    else
        printf '%s\tcapture-error\n' "$section" >> "$CAPTURE_INDEX"
    fi
    return 0
}

locate_target_file() {
    relative=$1
    relative_parent=${relative%/*}
    relative_name=${relative##*/}
    parent_path=$ROOT
    remaining=$relative_parent
    while [ -n "$remaining" ]; do
        case "$remaining" in
            */*)
                component=${remaining%%/*}
                remaining=${remaining#*/}
                ;;
            *)
                component=$remaining
                remaining=
                ;;
        esac
        [ -n "$component" ] || continue
        parent_path="$parent_path/$component"
        # Never follow a target-controlled symlink into the rescue environment.
        [ ! -L "$parent_path" ] && [ -d "$parent_path" ] || return 1
    done
    SAFE_TARGET_FILE="$parent_path/$relative_name"
    return 0
}

capture_target_file() {
    relative=$1
    output_name=$2
    output_file="$WORK_DIR/$output_name"
    {
        printf 'source_path=%s\n' "$relative"
        if ! locate_target_file "$relative"; then
            printf 'status=parent-directory-missing-or-symlink\n'
        elif [ -L "$SAFE_TARGET_FILE" ]; then
            printf 'status=symlink-not-followed\ntarget='
            readlink -- "$SAFE_TARGET_FILE" 2>/dev/null || true
            printf '\n'
        elif [ -f "$SAFE_TARGET_FILE" ] && [ -r "$SAFE_TARGET_FILE" ]; then
            printf 'status=read\n'
            cat -- "$SAFE_TARGET_FILE"
            printf '\n'
            printf '%s\tread\n' "$output_name" >> "$CAPTURE_INDEX"
        else
            printf 'status=not-present-or-not-readable\n'
            printf '%s\tunavailable\n' "$output_name" >> "$CAPTURE_INDEX"
        fi
    } > "$output_file" 2>&1
    return 0
}

locate_target_directory() {
    relative=$1
    parent_path=$ROOT
    remaining=$relative
    while [ -n "$remaining" ]; do
        case "$remaining" in
            */*)
                component=${remaining%%/*}
                remaining=${remaining#*/}
                ;;
            *)
                component=$remaining
                remaining=
                ;;
        esac
        [ -n "$component" ] || continue
        parent_path="$parent_path/$component"
        [ ! -L "$parent_path" ] && [ -d "$parent_path" ] || return 1
    done
    SAFE_TARGET_DIRECTORY=$parent_path
    return 0
}

capture_target_inventory() {
    relative=$1
    output_name=$2
    inventory_kind=$3
    output_file="$WORK_DIR/$output_name"
    {
        printf 'source_path=%s\n' "$relative"
        if locate_target_directory "$relative"; then
            directory=$SAFE_TARGET_DIRECTORY
            case "$inventory_kind" in
                symlinks)
                    find "$directory" -xdev -maxdepth 4 -type l -printf '%P -> %l\n' 2>&1
                    ;;
                boot)
                    find "$directory" -xdev -maxdepth 4 \( -type f -o -type l \) \
                        -printf '%P\t%y\t%s bytes\n' 2>&1
                    ;;
                logs)
                    find "$directory" -xdev -maxdepth 4 -type f \
                        -printf '%P\t%s bytes\n' 2>&1
                    ;;
            esac
            printf 'status=inventory-complete\n'
            printf '%s\tcaptured\n' "$output_name" >> "$CAPTURE_INDEX"
        else
            printf 'status=directory-missing-or-symlink\n'
            printf '%s\tunavailable\n' "$output_name" >> "$CAPTURE_INDEX"
        fi
    } > "$output_file"
    return 0
}

capture_installed_packages() {
    output_file="$WORK_DIR/installed-packages.txt"
    {
        printf 'source_path=var/lib/dpkg/status\n'
        if locate_target_file var/lib/dpkg/status &&
           [ -f "$SAFE_TARGET_FILE" ] && [ ! -L "$SAFE_TARGET_FILE" ] &&
           [ -r "$SAFE_TARGET_FILE" ]; then
            awk '
                /^Package: / { package = substr($0, 10) }
                /^Status: install ok installed$/ { if (package != "") print package }
            ' "$SAFE_TARGET_FILE" | LC_ALL=C sort -u
            printf 'status=package-names-only\n'
            printf 'installed-packages\tcaptured\n' >> "$CAPTURE_INDEX"
        else
            printf 'status=package-database-unavailable-or-symlink\n'
            printf 'installed-packages\tunavailable\n' >> "$CAPTURE_INDEX"
        fi
    } > "$output_file"
}

capture_live live-block-devices lsblk --json --paths \
    --output NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,RO
capture_live live-filesystem-signatures blkid
capture_live live-mount-table findmnt --output TARGET,SOURCE,FSTYPE,OPTIONS

capture_target_file etc/os-release os-release.txt
capture_target_file usr/lib/os-release usr-lib-os-release.txt
capture_target_file etc/hostname hostname.txt
capture_target_file etc/fstab fstab.txt
capture_target_file etc/aura-release aura-release.txt
capture_target_file var/lib/aura/install-manifest install-manifest.txt
capture_target_file etc/default/grub grub-defaults.txt
capture_target_file boot/grub/grub.cfg grub-config.txt
capture_installed_packages
capture_target_inventory etc/systemd/system systemd-unit-links.txt symlinks
capture_target_inventory boot boot-files.txt boot
capture_target_inventory var/log log-file-inventory.txt logs

JOURNAL_STATUS=excluded
if [ "$INCLUDE_JOURNAL" -eq 1 ]; then
    journal_output="$WORK_DIR/offline-journal-warnings.txt"
    if [ -d "$ROOT/var" ] && [ ! -L "$ROOT/var" ] &&
       [ -d "$ROOT/var/log" ] && [ ! -L "$ROOT/var/log" ] &&
       [ -d "$ROOT/var/log/journal" ] && [ ! -L "$ROOT/var/log/journal" ] &&
       command -v journalctl >/dev/null 2>&1; then
        {
            journalctl --root="$ROOT" --boot=0 --priority=warning \
                --no-pager --lines=200
            result=$?
            printf '\nexit_status=%s\n' "$result"
        } > "$journal_output" 2>&1
        JOURNAL_STATUS="included (latest recorded boot, warning and higher)"
    else
        printf 'status=journal-unavailable-or-not-a-real-directory\n' > "$journal_output"
        JOURNAL_STATUS=unavailable
    fi
    printf 'offline-journal-warnings\t%s\n' "$JOURNAL_STATUS" >> "$CAPTURE_INDEX"
fi

FINAL_FS=$(findmnt -n -o FSTYPE --target "$ROOT" 2>/dev/null || true)
FINAL_OPTIONS=$(findmnt -n -o OPTIONS --target "$ROOT" 2>/dev/null || true)
FINAL_DEVICE=$(findmnt -n -o SOURCE --target "$ROOT" 2>/dev/null || true)
[ "$FINAL_FS" = ext4 ] && [ "$FINAL_DEVICE" = "$ROOT_DEVICE" ] ||
    fail 'selected root mount changed during collection'
case ",$FINAL_OPTIONS," in *,ro,*) ;; *) fail 'selected root became read-write' ;; esac
case ",$FINAL_OPTIONS," in *,noload,*) ;; *) fail 'selected root lost the ext4 noload option' ;; esac

CREATED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')
{
    printf 'Aura OS offline diagnostic report\n'
    printf 'Format version: 1\n'
    printf 'Created UTC: %s\n' "$CREATED_UTC"
    printf 'Collection mode: offline, read-only\n'
    printf 'Target device: %s\n' "$ROOT_DEVICE"
    printf 'Target filesystem: %s\n' "$ROOT_FS"
    printf 'Target UUID: %s\n' "${ROOT_UUID:-unknown}"
    printf 'Target mount: %s\n' "$ROOT"
    printf 'Verified mount options: %s\n' "$ROOT_OPTIONS"
    printf 'Target architecture: %s\n' "$(uname -m)"
    printf 'Journal collection: %s\n' "$JOURNAL_STATUS"
    printf '\n'
    printf '%s\n' \
        'No target OS executable, service, or init script was run.' \
        'No chroot was entered. No repair, package operation, service restart,' \
        'configuration change, mount remount, or block-device write was performed.' \
        '' \
        'Privacy notice:' \
        '- The report can contain filesystem UUIDs, device names, boot configuration, hostnames, package inventory, and system paths.' \
        '- Journal entries are excluded unless --include-journal is supplied; included logs may contain usernames, addresses, or application details.' \
        '- Review every file in the archive before sharing it.' \
        '- User documents, password databases, shell history, network passwords, and environment variables are not collected.' \
        '' \
        'Captured sections (section<TAB>status):'
    cat "$CAPTURE_INDEX"
} > "$WORK_DIR/README.txt"

TEMP_ARCHIVE=$(mktemp "$RUN_DIR/.$OUTPUT_NAME.tmp.XXXXXX") ||
    fail 'could not create the report archive in installer RAM'
if ! tar -czf "$TEMP_ARCHIVE" -C "$WORK_DIR" .; then
    fail 'could not create the report archive'
fi
ARCHIVE_SHA=$(sha256sum "$TEMP_ARCHIVE" | awk '{print $1}')
mv -n -- "$TEMP_ARCHIVE" "$OUTPUT"
if [ -e "$TEMP_ARCHIVE" ]; then
    fail "report appeared concurrently; refusing to overwrite: $OUTPUT"
fi
TEMP_ARCHIVE=

CHECKSUM_TEMP=$(mktemp "$RUN_DIR/.$OUTPUT_NAME.sha256.XXXXXX") ||
    fail 'could not create the report checksum'
printf '%s  %s\n' "$ARCHIVE_SHA" "$OUTPUT_NAME" > "$CHECKSUM_TEMP"
mv -n -- "$CHECKSUM_TEMP" "$CHECKSUM"
if [ -e "$CHECKSUM_TEMP" ]; then
    fail "checksum appeared concurrently; report archive is at $OUTPUT"
fi

echo
echo 'AURA_RESCUE_DIAGNOSTICS_COMPLETE'
printf 'Report: %s\n' "$OUTPUT"
printf 'SHA-256: %s\n' "$ARCHIVE_SHA"
echo 'The report is stored in installer RAM (/run) and will be lost at shutdown.'
echo 'Copy it to separate removable media only after reviewing the privacy notice.'
