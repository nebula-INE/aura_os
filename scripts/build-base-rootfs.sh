#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
PACKAGES_FILE="${ROOT_DIR}/system/base/packages.txt"
BASE_OUTPUT_DIR="${ROOT_DIR}/build/base-userspace"
OUTPUT_DIR="${OUTPUT_DIR:-}"
DEBIAN_KEYRING="${DEBIAN_KEYRING:-${ROOT_DIR}/build/base-userspace/debian-trixie-keyring.gpg"}

case "$TARGET_ARCH" in
  x86_64) DEBIAN_ARCH="amd64" ;;
  aarch64) DEBIAN_ARCH="arm64" ;;
  riscv64) DEBIAN_ARCH="riscv64" ;;
  *)
    echo "error: TARGET_ARCH must be x86_64, aarch64, or riscv64." >&2
    exit 2
    ;;
esac

case "$DEBIAN_SUITE" in
  trixie) ;;
  *)
    echo "error: only the reviewed Debian suite 'trixie' is supported." >&2
    exit 2
    ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  echo "error: run this builder as root (for example: sudo env TARGET_ARCH=$TARGET_ARCH bash scripts/build-base-rootfs.sh)." >&2
  exit 1
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

for cmd in mmdebstrap tar gzip sha256sum dpkg-query python3; do
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

# Restrict destructive cleanup to the repository's build directory.
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
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
BASE_OUTPUT_DIR="$(mkdir -p "$BASE_OUTPUT_DIR" && cd "$BASE_OUTPUT_DIR" && pwd -P)"
case "$OUTPUT_DIR/" in
  "$BASE_OUTPUT_DIR"/*/) ;;
  *)
    echo "error: OUTPUT_DIR must be a subdirectory of $BASE_OUTPUT_DIR (got $OUTPUT_DIR)." >&2
    exit 2
    ;;
esac

ROOTFS_DIR="$OUTPUT_DIR/rootfs"
ARCHIVE="$OUTPUT_DIR/aura-base-$TARGET_ARCH.tar.gz"
CHECKSUM_FILE="$ARCHIVE.sha256"
MANIFEST_FILE="$OUTPUT_DIR/packages.tsv"
PROVENANCE_FILE="$OUTPUT_DIR/build-provenance.txt"

mapfile -t PACKAGES < <(sed -E 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d' "$PACKAGES_FILE")
if [[ "${#PACKAGES[@]}" -eq 0 ]]; then
  echo "error: no packages were found in $PACKAGES_FILE" >&2
  exit 1
fi
INCLUDE_PACKAGES="$(IFS=,; printf '%s' "${PACKAGES[*]}")"

echo "Building Aura OS base userspace:"
echo "  Debian suite: $DEBIAN_SUITE"
echo "  Debian architecture: $DEBIAN_ARCH"
echo "  Target architecture: $TARGET_ARCH"
echo "  Packages: $INCLUDE_PACKAGES"

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
cat > "$ROOTFS_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 aura-os
::1 localhost ip6-localhost ip6-loopback
EOF
cat > "$ROOTFS_DIR/etc/issue" <<'EOF'
Aura OS — early base userspace
Kernel and platform support are under active development.
EOF
cat > "$ROOTFS_DIR/etc/aura-release" <<EOF
NAME="Aura OS"
BASE="Debian GNU/Linux"
VERSION_CODENAME="$DEBIAN_SUITE"
TARGET_ARCH="$TARGET_ARCH"
DEBIAN_ARCH="$DEBIAN_ARCH"
EOF

echo "Verifying the generated root filesystem..."
python3 "$ROOT_DIR/scripts/verify_base_rootfs.py" \
  --rootfs "$ROOTFS_DIR" \
  --target-arch "$TARGET_ARCH" \
  --suite "$DEBIAN_SUITE"

echo "Writing installed package manifest..."
dpkg-query \
  --admindir="$ROOTFS_DIR/var/lib/dpkg" \
  --show \
  --showformat='${binary:Package}\t${Version}\t${Architecture}\n' \
  | LC_ALL=C sort > "$MANIFEST_FILE"

echo "Creating root filesystem archive with normalized tar metadata..."
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
tar \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --numeric-owner \
  --owner=0 \
  --group=0 \
  --xattrs \
  --acls \
  -C "$ROOTFS_DIR" \
  -cf - . | gzip -n -9 > "$ARCHIVE"

test -s "$ARCHIVE"
sha256sum "$ARCHIVE" | tee "$CHECKSUM_FILE"
DEBIAN_KEYRING_SHA256="$(sha256sum "$DEBIAN_KEYRING" | awk -F' ' '{print $1}')"

{
  printf 'Aura OS base userspace build\n'
  printf 'Debian suite: %s\n' "$DEBIAN_SUITE"
  printf 'Debian mirror: %s\n' "$DEBIAN_MIRROR"
  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Debian architecture: %s\n' "$DEBIAN_ARCH"
  printf 'Bootstrap tool: mmdebstrap --variant=minbase\n'
  printf 'Init/service manager: systemd (systemd-sysv)\n'
  printf 'Package manager: apt/dpkg\n'
  printf 'Debian keyring SHA-256: %s\n' "$DEBIAN_KEYRING_SHA256"
  printf 'Root account: locked; no default password configured\n'
  printf 'Desktop: not installed\n'
  printf 'Archive: %s\n' "$ARCHIVE"
  printf 'Installed package manifest: %s\n' "$MANIFEST_FILE"
} | tee "$PROVENANCE_FILE"

printf 'Created Aura OS base userspace archive: %s\n' "$ARCHIVE"
