#!/bin/sh
# Verify the signed installer payload manifest before install or rescue actions.
set -eu

MEDIA_ROOT=${1:-}
ARCH=${AURA_TARGET_ARCH:-}
PUBLIC_KEY_FILE=${AURA_RELEASE_PUBLIC_KEY_FILE:-/etc/aura/installer-release-key.pub}

fail() {
    printf '[Aura OS] ERROR: release verification failed: %s\n' "$*" >&2
    exit 1
}

[ -n "$MEDIA_ROOT" ] && [ -d "$MEDIA_ROOT" ] ||
    fail "installer media directory is unavailable: $MEDIA_ROOT"
case "$ARCH" in
    x86_64|aarch64|riscv64) ;;
    *) fail "unsupported or unset installer architecture: $ARCH" ;;
esac
[ -s "$PUBLIC_KEY_FILE" ] || fail "trusted release public key is missing: $PUBLIC_KEY_FILE"
MANIFEST="$MEDIA_ROOT/aura-payloads.sha256"
SIGNATURE="$MANIFEST.sig"
[ -s "$MANIFEST" ] || fail "signed payload manifest is missing"
[ -s "$SIGNATURE" ] || fail "payload manifest signature is missing"
command -v openssl >/dev/null 2>&1 || fail "openssl is unavailable"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is unavailable"
command -v awk >/dev/null 2>&1 || fail "awk is unavailable"

# The signed manifest is deliberately limited to the four assets used by the
# installer. Reject unexpected paths even when the signature is valid.
awk -v rootfs="rootfs/aura-base-$ARCH.tar.gz" \
    -v kernel="boot/vmlinuz-$ARCH" \
    -v initrd="boot/initramfs-$ARCH.cpio.gz" \
    -v esp="boot/efi.img" '
    NF != 2 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/ { invalid = 1; next }
    $2 == rootfs { seen_rootfs++; next }
    $2 == kernel { seen_kernel++; next }
    $2 == meta { seen_meta++; next }
    $2 == esp { seen_esp++; next }
    { invalid = 1 }
    END {
        if (invalid || NR != 4 || seen_rootfs != 1 || seen_kernel != 1 ||
            seen_meta != 1 || seen_esp != 1) {
            exit 1
        }
    }
' "$MANIFEST" || fail "payload manifest has unexpected or duplicate entries"

openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY_FILE" -rawin \
    -in "$MANIFEST" -sigfile "$SIGNATURE" >/dev/null 2>&1 ||
    fail "Ed25519 signature is invalid or was not made by the trusted release key"

(
    cd "$MEDIA_ROOT"
    sha256sum --check --strict --status aura-payloads.sha256
) || fail "one or more signed installer payloads failed SHA-256 verification"

printf 'AURA_MEDIA_SIGNATURE_OK\n'
