#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

OUTPUT_DIR="${1:?Usage: prepare-uefi-secureboot-key.sh OUTPUT_DIR}"
PRIVATE_KEY_FILE="$OUTPUT_DIR/private-key.pem"
CERT_FILE="$OUTPUT_DIR/certificate.pem"
CERT_DER_FILE="$OUTPUT_DIR/certificate.der"
EXPECTED_FINGERPRINT="${AURA_UEFI_SECURE_BOOT_CERT_SHA256:-}"
PRIVATE_KEY_INPUT="${AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_PEM:-}"
CERT_INPUT="${AURA_UEFI_SECURE_BOOT_CERT_PEM:-}"

command -v openssl >/dev/null 2>&1 || {
  echo "error: OpenSSL is required to prepare the UEFI Secure Boot key." >&2
  exit 1
}
mkdir -p "$OUTPUT_DIR"
chmod 0700 "$OUTPUT_DIR"

if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  [[ -n "$PRIVATE_KEY_INPUT" && -n "$CERT_INPUT" && -n "$EXPECTED_FINGERPRINT" ]] || {
    echo "error: tagged releases require AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_PEM (Secret), AURA_UEFI_SECURE_BOOT_CERT_PEM and AURA_UEFI_SECURE_BOOT_CERT_SHA256 (Variables)." >&2
    exit 1
  }
  printf '%s\n' "$PRIVATE_KEY_INPUT" > "$PRIVATE_KEY_FILE"
  printf '%s\n' "$CERT_INPUT" > "$CERT_FILE"
  SIGNING_MODE=release-key
else
  # PR, branch, and manual CI builds use a throwaway owner key. These images
  # are test artifacts and must never be represented as trusted release media.
  openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout "$PRIVATE_KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=Aura OS Secure Boot CI/" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"
  SIGNING_MODE=ci-ephemeral
fi

chmod 0600 "$PRIVATE_KEY_FILE"
chmod 0644 "$CERT_FILE"
openssl rsa -in "$PRIVATE_KEY_FILE" -check -noout >/dev/null
openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null
openssl verify -CAfile "$CERT_FILE" "$CERT_FILE" >/dev/null

# UEFI Authenticode signing uses RSA/SHA-256 here for broad firmware support.
# Require the certificate's RSA public key to match the private key exactly.
openssl pkey -in "$PRIVATE_KEY_FILE" -pubout -outform DER > "$OUTPUT_DIR/private-public.der"
openssl x509 -in "$CERT_FILE" -pubkey -noout |
  openssl pkey -pubin -outform DER > "$OUTPUT_DIR/certificate-public.der"
cmp -s "$OUTPUT_DIR/private-public.der" "$OUTPUT_DIR/certificate-public.der" || {
  echo "error: UEFI Secure Boot private key and certificate do not match." >&2
  exit 1
}
public_key_info="$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -text -noout)"
grep -Eq 'Public-Key: \(([2-9][0-9]{3}|[1-9][0-9]{4,}) bit\)' <<< "$public_key_info" || {
  echo "error: UEFI Secure Boot certificate must contain an RSA public key of at least 2048 bits." >&2
  exit 1
}
openssl x509 -in "$CERT_FILE" -outform DER -out "$CERT_DER_FILE"
chmod 0644 "$CERT_DER_FILE"

ACTUAL_FINGERPRINT="$(sha256sum "$CERT_DER_FILE" | awk '{print toupper($1)}')"
if [[ "$SIGNING_MODE" == release-key ]]; then
  NORMALIZED_EXPECTED="$(tr -d ':[:space:]' <<< "$EXPECTED_FINGERPRINT" | tr '[:lower:]' '[:upper:]')"
  [[ "$NORMALIZED_EXPECTED" =~ ^[A-F0-9]{64}$ && "$ACTUAL_FINGERPRINT" == "$NORMALIZED_EXPECTED" ]] || {
    echo "error: UEFI Secure Boot certificate SHA-256 does not match AURA_UEFI_SECURE_BOOT_CERT_SHA256." >&2
    exit 1
  }
fi

rm -f "$OUTPUT_DIR/private-public.der" "$OUTPUT_DIR/certificate-public.der"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_FILE=%s\n' "$PRIVATE_KEY_FILE"
    printf 'AURA_UEFI_SECURE_BOOT_CERT_FILE=%s\n' "$CERT_FILE"
    printf 'AURA_UEFI_SECURE_BOOT_CERT_DER_FILE=%s\n' "$CERT_DER_FILE"
    printf 'AURA_UEFI_SECURE_BOOT_CERT_SHA256=%s\n' "$ACTUAL_FINGERPRINT"
    printf 'AURA_UEFI_SECURE_BOOT_MODE=%s\n' "$SIGNING_MODE"
  } >> "$GITHUB_ENV"
fi
printf 'Prepared UEFI Secure Boot signing identity (%s, SHA-256 %s).\n' "$SIGNING_MODE" "$ACTUAL_FINGERPRINT"
