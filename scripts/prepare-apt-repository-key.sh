#!/usr/bin/env bash
set -Eeuo pipefail

KEY_DIR="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aura-apt-repository-key}"
PUBLIC_KEY_INPUT="${AURA_APT_REPOSITORY_PUBLIC_KEY_ASC:-}"
EXPECTED_FINGERPRINT="${AURA_APT_REPOSITORY_FINGERPRINT:-}"
REPOSITORY_URL="${AURA_APT_REPOSITORY_URL:-https://nebula-INE.github.io/aura_os/apt}"

for cmd in gpg awk install; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required APT key preparation command is missing: $cmd" >&2
    exit 1
  }
done
mkdir -p "$KEY_DIR"
chmod 0700 "$KEY_DIR"
GNUPGHOME="$KEY_DIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 0700 "$GNUPGHOME"
PUBLIC_KEY_FILE="$KEY_DIR/public.asc"

if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  [[ -n "$PUBLIC_KEY_INPUT" && -n "$EXPECTED_FINGERPRINT" ]] || {
    echo "error: release builds require AURA_APT_REPOSITORY_PUBLIC_KEY_ASC and AURA_APT_REPOSITORY_FINGERPRINT repository variables." >&2
    exit 1
  }
  printf '%s\n' "$PUBLIC_KEY_INPUT" > "$PUBLIC_KEY_FILE"
else
  # PR and branch builds use a disposable key only to test Signed-By wiring.
  gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase "" \
    --quick-generate-key "Aura OS CI APT <ci-apt@invalid.example>" ed25519 sign 1d >/dev/null
  EXPECTED_FINGERPRINT="$(gpg --homedir "$GNUPGHOME" --batch --with-colons --list-keys |
    awk -F: '$1 == "fpr" { print toupper($10); exit }')"
  gpg --homedir "$GNUPGHOME" --batch --armor --export "$EXPECTED_FINGERPRINT" > "$PUBLIC_KEY_FILE"
fi

actual_fingerprint="$(gpg --batch --show-keys --with-colons "$PUBLIC_KEY_FILE" |
  awk -F: '$1 == "fpr" { print toupper($10); exit }')"
[[ -n "$actual_fingerprint" ]] || {
  echo "error: the APT repository public key is invalid." >&2
  exit 1
}
if [[ -n "$EXPECTED_FINGERPRINT" && "$actual_fingerprint" != "${EXPECTED_FINGERPRINT^^}" ]]; then
  echo "error: APT repository public key does not match the configured fingerprint." >&2
  exit 1
fi
[[ "$REPOSITORY_URL" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?$ ]] || {
  echo "error: AURA_APT_REPOSITORY_URL must be a plain HTTPS URL." >&2
  exit 2
}
chmod 0644 "$PUBLIC_KEY_FILE"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'AURA_APT_REPOSITORY_PUBLIC_KEY_FILE=%s\n' "$PUBLIC_KEY_FILE"
    printf 'AURA_APT_REPOSITORY_FINGERPRINT=%s\n' "$actual_fingerprint"
    printf 'AURA_APT_REPOSITORY_URL=%s\n' "$REPOSITORY_URL"
    printf 'AURA_APT_GNUPGHOME=%s\n' "$GNUPGHOME"
  } >> "$GITHUB_ENV"
fi
printf 'APT repository public key prepared (fingerprint %s).\n' "$actual_fingerprint"
