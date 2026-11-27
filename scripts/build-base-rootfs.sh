#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

TARGET_ARCH="${TARGET_ARCH:-}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
PACKAGES_FILE="$ROOT_DIR/system/base/packages.txt"
DESKTOP_PACKAGES_FILE="$ROOT_DIR/system/desktop/packages.txt"
AURA_DESKTOP_PROFILE="${AURA_DESKTOP_PROFILE:-0}"
BASE_OUTPUT_DIR="$ROOT_DIR/build/base-userspace"
OUTPUT_DIR="${OUTPUT_DIR:-}"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-$BASE_OUTPUT_DIR/debian-trixie-keyring.gpg}"

case "$TARGET_ARCH" in
  x86_64)
    DEBIAN_ARCH="amd64"
    GRUB_PACKAGE="grub-efi-amd64-bin"
    ;;
  aarch64)
    DEBIAN_ARCH="arm64"
    GRUB_PACKAGE="grub-efi-arm64-bin"
    ;;
  riscv64)
    DEBIAN_ARCH="riscv64"
    GRUB_PACKAGE="grub-efi-riscv64-bin"
    ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

if [[ "$DEBIAN_SUITE" != "trixie" ]]; then
  echo "error: only the reviewed Debian suite 'trixie' is supported." >&2
  exit 2
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run this builder as root; use sudo env TARGET_ARCH=$TARGET_ARCH bash scripts/build-base-rootfs.sh." >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

for cmd in mmdebstrap tar gzip sha256sum dpkg-query python3 sed sort install; do
  require_command "$cmd"
done

if [[ ! -s "$PACKAGES_FILE" ]]; then
  echo "error: package manifest is missing or empty: $PACKAGES_FILE" >&2
  exit 1
fi
if [[ ! -s "$DEBIAN_KEYRING" ]]; then
  echo "error: verified Debian Trixie keyring is missing: $DEBIAN_KEYRING" >&2
  echo "hint: run scripts/prepare-debian-trixie-keyring.sh first." >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$BASE_OUTPUT_DIR/$TARGET_ARCH"
fi
case "$OUTPUT_DIR" in
  /*) ;;
  *)
    echo "error: OUTPUT_DIR must be an absolute path." >&2
    exit 2
    ;;
esac

mkdir -p "$BASE_OUTPUT_DIR" "$OUTPUT_DIR"
BASE_OUTPUT_DIR="$(cd -- "$BASE_OUTPUT_DIR" && pwd -P)"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
case "$OUTPUT_DIR/" in
  "$BASE_OUTPUT_DIR"/*/) ;;
  *)
    echo "error: OUTPUT_DIR must be a subdirectory of $BASE_OUTPUT_DIR." >&2
    exit 2
    ;;
esac

ROOTFS_DIR="$OUTPUT_DIR/rootfs"
ARCHIVE="$OUTPUT_DIR/aura-base-$TARGET_ARCH.tar.gz"
CHECKSUM_FILE="$ARCHIVE.sha256"
MANIFEST_FILE="$OUTPUT_DIR/packages.tsv"
PROVENANCE_FILE="$OUTPUT_DIR/build-provenance.txt"

case "$AURA_DESKTOP_PROFILE" in
  0|1) ;;
  *) echo "error: AURA_DESKTOP_PROFILE must be 0 or 1." >&2; exit 2 ;;
esac

mapfile -t PACKAGES < <(sed -E 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$PACKAGES_FILE")
if [[ "$AURA_DESKTOP_PROFILE" == "1" ]]; then
  [[ -s "$DESKTOP_PACKAGES_FILE" ]] || { echo "error: desktop package manifest is missing: $DESKTOP_PACKAGES_FILE" >&2; exit 1; }
  mapfile -t DESKTOP_PACKAGES < <(sed -E 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$DESKTOP_PACKAGES_FILE")
  PACKAGES+=("${DESKTOP_PACKAGES[@]}")
fi
# These target-native packages provide the offline installer with FAT32
# formatting and architecture-matched UEFI GRUB modules.
PACKAGES+=(dosfstools fdisk grub2-common "$GRUB_PACKAGE")
if [[ "${#PACKAGES[@]}" -eq 0 ]]; then
  echo "error: no packages were found in $PACKAGES_FILE" >&2
  exit 1
fi
INCLUDE_PACKAGES="$(IFS=,; printf '%s' "${PACKAGES[*]}")"

echo "Building Aura OS base userspace:"
printf '  Debian suite: %s\n' "$DEBIAN_SUITE"
printf '  Debian architecture: %s\n' "$DEBIAN_ARCH"
printf '  Target architecture: %s\n' "$TARGET_ARCH"
printf '  Packages: %s\n' "$INCLUDE_PACKAGES"

rm -rf -- "$ROOTFS_DIR" "$ARCHIVE" "$CHECKSUM_FILE" "$MANIFEST_FILE" "$PROVENANCE_FILE"
mkdir -p "$OUTPUT_DIR"

DEBIAN_FRONTEND=noninteractive mmdebstrap \
  --mode=root \
  --variant=minbase \
  --architectures="$DEBIAN_ARCH" \
  --components=main \
  --keyring="$DEBIAN_KEYRING" \
  --include="$INCLUDE_PACKAGES" \
  --aptopt='APT::Install-Recommends "false";' \
  --aptopt='Acquire::Retries "3";' \
  "$DEBIAN_SUITE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"

mkdir -p "$ROOTFS_DIR/etc"
printf 'aura-os\n' > "$ROOTFS_DIR/etc/hostname"
printf '%s\n' \
  '127.0.0.1 localhost' \
  '127.0.1.1 aura-os' \
  '::1 localhost ip6-localhost ip6-loopback' \
  > "$ROOTFS_DIR/etc/hosts"
printf '%s\n' \
  'Aura OS — early base userspace' \
  'Kernel and platform support are under active development.' \
  > "$ROOTFS_DIR/etc/issue"
printf 'NAME="Aura OS"\nBASE="Debian GNU/Linux"\nVERSION_CODENAME="%s"\nTARGET_ARCH="%s"\nDEBIAN_ARCH="%s"\n' \
  "$DEBIAN_SUITE" "$TARGET_ARCH" "$DEBIAN_ARCH" \
  > "$ROOTFS_DIR/etc/aura-release"

echo "Installing Aura first-boot account setup..."
FIRSTBOOT_SOURCE="$ROOT_DIR/system/base/firstboot"
if [[ ! -s "$FIRSTBOOT_SOURCE/aura-firstboot" || ! -s "$FIRSTBOOT_SOURCE/aura-firstboot.service" ]]; then
  echo "error: first-boot account setup source files are missing." >&2
  exit 1
fi
install -D -m 0644 "$FIRSTBOOT_SOURCE/aura-firstboot" \
  "$ROOTFS_DIR/usr/lib/aura/aura-firstboot"
install -D -m 0644 "$FIRSTBOOT_SOURCE/aura-firstboot.service" \
  "$ROOTFS_DIR/etc/systemd/system/aura-firstboot.service"
mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/aura-firstboot.service \
  "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/aura-firstboot.service"

echo "Installing the authenticated Aura Recovery Mode..."
RECOVERY_SOURCE="$ROOT_DIR/system/base/recovery"
for source in "$RECOVERY_SOURCE/aura-recovery.target" \
              "$RECOVERY_SOURCE/aura-recovery-banner.service" \
              "$RECOVERY_SOURCE/aura-recovery-banner"; do
  if [[ ! -s "$source" ]]; then
    echo "error: Aura Recovery Mode source is missing: $source" >&2
    exit 1
  fi
done
install -D -m 0644 "$RECOVERY_SOURCE/aura-recovery.target" \
  "$ROOTFS_DIR/etc/systemd/system/aura-recovery.target"
install -D -m 0644 "$RECOVERY_SOURCE/aura-recovery-banner.service" \
  "$ROOTFS_DIR/etc/systemd/system/aura-recovery-banner.service"
install -D -m 0755 "$RECOVERY_SOURCE/aura-recovery-banner" \
  "$ROOTFS_DIR/usr/lib/aura/recovery/aura-recovery-banner"
mkdir -p "$ROOTFS_DIR/etc/systemd/system/aura-recovery.target.wants"
ln -sfn /etc/systemd/system/aura-firstboot.service \
  "$ROOTFS_DIR/etc/systemd/system/aura-recovery.target.wants/aura-firstboot.service"
ln -sfn /etc/systemd/system/aura-recovery-banner.service \
  "$ROOTFS_DIR/etc/systemd/system/aura-recovery.target.wants/aura-recovery-banner.service"

echo "Installing Aura network and time configuration..."
NETWORK_SOURCE="$ROOT_DIR/system/base/network"
for source in "$NETWORK_SOURCE/20-wired.network" "$NETWORK_SOURCE/20-aura-timesyncd.conf"; do
  if [[ ! -s "$source" ]]; then
    echo "error: network/time configuration source is missing: $source" >&2
    exit 1
  fi
done
install -D -m 0644 "$NETWORK_SOURCE/20-wired.network" \
  "$ROOTFS_DIR/etc/systemd/network/20-wired.network"
install -D -m 0644 "$NETWORK_SOURCE/20-aura-timesyncd.conf" \
  "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d/20-aura.conf"

echo "Installing the read-only Aura diagnostics tool..."
DIAGNOSTICS_SOURCE="$ROOT_DIR/system/base/diagnostics/aura-diagnose"
if [[ ! -s "$DIAGNOSTICS_SOURCE" ]]; then
  echo "error: Aura diagnostics tool source is missing: $DIAGNOSTICS_SOURCE" >&2
  exit 1
fi
install -D -m 0755 "$DIAGNOSTICS_SOURCE" "$ROOTFS_DIR/usr/bin/aura-diagnose"

for unit in systemd-networkd.service systemd-resolved.service systemd-timesyncd.service; do
  unit_path="$ROOTFS_DIR/usr/lib/systemd/system/$unit"
  if [[ ! -s "$unit_path" ]]; then
    echo "error: required network/time systemd unit is missing: $unit_path" >&2
    exit 1
  fi
  ln -sfn "/usr/lib/systemd/system/$unit" \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$unit"
done

# Route libc DNS lookups through systemd-resolved's local stub listener.
rm -f "$ROOTFS_DIR/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

if [[ "$AURA_DESKTOP_PROFILE" == "1" ]]; then
  echo "Installing the optional Aura Wayland desktop profile..."
  python3 "$ROOT_DIR/scripts/install_desktop_profile.py" --rootfs "$ROOTFS_DIR"
fi

echo "Verifying the generated root filesystem..."
VERIFY_ARGS=(--rootfs "$ROOTFS_DIR" --target-arch "$TARGET_ARCH" --suite "$DEBIAN_SUITE")
if [[ "$AURA_DESKTOP_PROFILE" == "1" ]]; then VERIFY_ARGS+=(--desktop-profile); fi
python3 "$ROOT_DIR/scripts/verify_base_rootfs.py" "${VERIFY_ARGS[@]}"

echo "Writing installed package manifest..."
dpkg-query \
  --admindir="$ROOTFS_DIR/var/lib/dpkg" \
  --show \
  --showformat='${binary:Package}\t${Version}\t${Architecture}\n' \
  | LC_ALL=C sort > "$MANIFEST_FILE"

echo "Creating root filesystem archive with normalized tar metadata..."
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" tar \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH:-0}" \
  --numeric-owner \
  --owner=0 \
  --group=0 \
  --xattrs \
  --acls \
  -C "$ROOTFS_DIR" \
  -cf - . | gzip -n -9 > "$ARCHIVE"

test -s "$ARCHIVE"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM_FILE")"
)
cat "$CHECKSUM_FILE"

{
  printf 'Aura OS base userspace build\n'
  printf 'Debian suite: %s\n' "$DEBIAN_SUITE"
  printf 'Debian mirror: %s\n' "$DEBIAN_MIRROR"
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Debian architecture: %s\n' "$DEBIAN_ARCH"
  printf 'Bootstrap tool: mmdebstrap --variant=minbase\n'
  printf 'Init/service manager: systemd (systemd-sysv)\n'
  printf 'Package manager: apt/dpkg\n'
  printf 'Wired networking: systemd-networkd with DHCPv4/DHCPv6 and IPv6 RA\n'
  printf 'DNS: systemd-resolved stub resolver\n'
  printf 'Time synchronization: systemd-timesyncd with DHCP NTP and Debian fallback\n'
  printf 'Root account: locked; no default password configured\n'
  if [[ "$AURA_DESKTOP_PROFILE" == "1" ]]; then
    printf 'Desktop: optional labwc/Wayland profile (greetd + tuigreet)\n'
  else
    printf 'Desktop: not installed\n'
  fi
  printf 'Archive: %s\n' "$ARCHIVE"
  printf 'Installed package manifest: %s\n' "$MANIFEST_FILE"
  printf 'Debian keyring SHA-256: '
  sha256sum "$DEBIAN_KEYRING" | awk '{print $1}'
} > "$PROVENANCE_FILE"

printf 'Created Aura OS base userspace archive: %s\n' "$ARCHIVE"
