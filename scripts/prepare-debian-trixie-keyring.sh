#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-${ROOT_DIR}/build/base-userspace/debian-trixie-keyring.gpg}"
BUILD_ROOT="${ROOT_DIR}/build/base-userspace"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}
for cmd in curl gpg sha256sum; do
  require_command "$cmd"
done

case "$OUTPUT_PATH" in
  /*) ;;
  *)
    echo "error: keyring output path must be absolute." >&2
    exit 2
    ;;
esac

mkdir -p "$BUILD_ROOT" "$(dirname "$OUTPUT_PATH")"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd -P)"
OUTPUT_PATH="$OUTPUT_DIR/$(basename "$OUTPUT_PATH")"
case "$OUTPUT_PATH" in
  "$BUILD_ROOT"/*) ;;
  *)
    echo "error: keyring must be written under $BUILD_ROOT." >&2
    exit 2
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_KEY="$TMP_DIR/archive-key-13.asc"
SECURITY_KEY="$TMP_DIR/archive-key-13-security.asc"
RELEASE_KEY="$TMP_DIR/release-13.asc"

fetch_key() {
  local url="$1"
  local destination="$2"
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --retry 3 \
    "$url" -o "$destination"
}

echo "Downloading Debian Trixie archive signing keys from ftp-master.debian.org..."
fetch_key "https://ftp-master.debian.org/keys/archive-key-13.asc" "$ARCHIVE_KEY"
fetch_key "https://ftp-master.debian.org/keys/archive-key-13-security.asc" "$SECURITY_KEY"
fetch_key "https://ftp-master.debian.org/keys/release-13.asc" "$RELEASE_KEY"

# These SHA-256 values are published in the Debian-devel announcement that
# introduced the Trixie archive keys. Pinning them prevents key substitution.
printf '%s  %s\n' \
  "6f1d277429dd7ffedcc6f8688a7ad9a458859b1139ffa026d1eeaadcbffb0da7" "$ARCHIVE_KEY" \
  "844c07d242db37f283afab9d5531270a0550841e90f9f1a9c3bd599722b808b7" "$SECURITY_KEY" \
  | sha256sum --check --status || {
    echo "error: Debian Trixie archive key SHA-256 verification failed." >&2
    exit 1
  }

verify_fingerprint() {
  local key_file="$1"
  local expected="$2"
  local actual
  actual="$(gpg --batch --show-keys --with-colons "$key_file" \
    | awk -F: '$1 == "fpr" { print toupper($10); exit }')"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: unexpected Debian archive key fingerprint for $key_file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   ${actual:-<none>}" >&2
    exit 1
  fi
}

verify_fingerprint "$ARCHIVE_KEY" "04B54C3CDCA79751B16BC6B5225629DF75B188BD"
verify_fingerprint "$SECURITY_KEY" "5E04A1E3223A19A20706E20F9904613D4CCE68C6"
verify_fingerprint "$RELEASE_KEY" "41587F7DB8C774BCCF131416762F67A0B2C39DE4"

cat "$ARCHIVE_KEY" "$SECURITY_KEY" "$RELEASE_KEY" > "$TMP_DIR/debian-trixie.asc"
gpg --batch --yes --dearmor --output "$OUTPUT_PATH" "$TMP_DIR/debian-trixie.asc"
chmod 0644 "$OUTPUT_PATH"

for fingerprint in \
  04B54C3CDCA79751B16BC6B5225629DF75B188BD \
  5E04A1E3223A19A20706E20F9904613D4CCE68C6 \
  41587F7DB8C774BCCF131416762F67A0B2C39DE4; do
  if ! gpg --batch --show-keys --with-colons "$OUTPUT_PATH" \
      | awk -F: '$1 == "fpr" { print toupper($10) }' \
      | grep -Fqx "$fingerprint"; then
    echo "error: verified Debian key is missing from the final keyring: $fingerprint" >&2
    exit 1
  fi
done

sha256sum "$OUTPUT_PATH"
echo "Created verified Debian Trixie keyring: $OUTPUT_PATH"
