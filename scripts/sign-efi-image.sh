#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INPUT_IMAGE="${1:?Usage: sign-efi-image.sh INPUT_EFI_IMAGE OUTPUT_SIGNED_EFI_IMAGE}"
OUTPUT_IMAGE="${2:?Usage: sign-efi-image.sh INPUT_EFI_IMAGE OUTPUT_SIGNED_EFI_IMAGE}"
PRIVATE_KEY_FILE="${AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_FILE:-}"
CERT_FILE="${AURA_UEFI_SECURE_BOOT_CERT_FILE:-}"

for command_name in sbsign sbverify openssl sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "error: required Secure Boot signing tool is missing: $command_name" >&2
    exit 1
  }
done
[[ -s "$INPUT_IMAGE" ]] || {
  echo "error: EFI image is missing or empty: $INPUT_IMAGE" >&2
  exit 1
}
[[ -n "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" ]] || {
  echo "error: UEFI Secure Boot private key is not prepared." >&2
  exit 1
}
[[ -n "$CERT_FILE" && -s "$CERT_FILE" ]] || {
  echo "error: UEFI Secure Boot certificate is not prepared." >&2
  exit 1
}
[[ "$INPUT_IMAGE" != "$OUTPUT_IMAGE" ]] || {
  echo "error: signed EFI output must be a different file from the unsigned input." >&2
  exit 2
}

mkdir -p "$(dirname -- "$OUTPUT_IMAGE")"
rm -f "$OUTPUT_IMAGE"
sbsign --key "$PRIVATE_KEY_FILE" --cert "$CERT_FILE" --output "$OUTPUT_IMAGE" "$INPUT_IMAGE"
[[ -s "$OUTPUT_IMAGE" ]] || {
  echo "error: sbsign did not create a signed EFI image." >&2
  exit 1
}
sbverify --cert "$CERT_FILE" "$OUTPUT_IMAGE"
SIGNATURE_LIST="$(sbverify --list "$OUTPUT_IMAGE")"
grep -Eqi 'signature' <<< "$SIGNATURE_LIST" || {
  echo "error: signed EFI image does not contain an Authenticode signature table." >&2
  exit 1
}
CERT_SHA256="$(openssl x509 -in "$CERT_FILE" -outform DER | sha256sum | awk '{print toupper($1)}')"
{
  printf 'Unsigned EFI image: %s\n' "$INPUT_IMAGE"
  printf 'Signed EFI image: %s\n' "$OUTPUT_IMAGE"
  printf 'Signature format: UEFI Authenticode / PKCS#7\n'
  printf 'Signing algorithm: RSA with SHA-256\n'
  printf 'Certificate DER SHA-256: %s\n' "$CERT_SHA256"
  printf 'Unsigned image SHA-256: %s\n' "$(sha256sum "$INPUT_IMAGE" | awk '{print $1}')"
  printf 'Signed image SHA-256: %s\n' "$(sha256sum "$OUTPUT_IMAGE" | awk '{print $1}')"
  printf '%s\n' 'Verification: sbverify --cert passed'
} > "$OUTPUT_IMAGE.secureboot.txt"
printf 'Signed and verified EFI image: %s\n' "$OUTPUT_IMAGE"
