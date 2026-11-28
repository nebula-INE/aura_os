# Aura OS Secure Boot (development preview)

## Current scope

Aura's current Secure Boot work signs the EFI-stub image that UEFI firmware
launches from the install/bring-up medium. The image is signed using
UEFI Authenticode (RSA/SHA-256), and CI verifies the signature with the exact
X.509 certificate used by sbsign.

This is a signing foundation, **not yet end-to-end Secure Boot for an
installed Aura OS**. The installed GRUB loader, installed kernel and
kernel-module verification chain are not all covered by this milestone.
Do not treat this preview as production Secure Boot support or assume that
Secure Boot can remain enabled after installing the OS.

## Release identity and verification

The UEFI signing identity is separate from both:

- the Ed25519 key used for the signed installer payload manifest and ISO
  checksum; and
- the OpenPGP key used for the Aura kernel APT repository.

Tagged releases require these repository settings:

- Secret: AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_PEM
- Variable: AURA_UEFI_SECURE_BOOT_CERT_PEM
- Variable: AURA_UEFI_SECURE_BOOT_CERT_SHA256

PR and branch CI generate ephemeral keys and produce test artifacts only.
Release builds fail when the key, certificate, or configured fingerprint is
missing or mismatched.

For a release, obtain the certificate and expected SHA-256 fingerprint
through independently trusted release channels. A certificate included
inside the ISO cannot authenticate that same ISO by itself.

## Firmware enrollment for the media preview

Only use a test machine or virtual machine whose firmware exposes a supported
owner-managed Secure Boot key database workflow.

1. Obtain the DER certificate (aura-uefi-db.cer) and its SHA-256 fingerprint
   from the trusted release artifacts/channel.
2. Calculate the certificate fingerprint locally and compare it with the
   independently published value before using the certificate.
3. In firmware Setup, use the vendor's custom Secure Boot key-management
   interface to add the certificate to the authorized image-signature
   database (db). Do not replace the Platform Key (PK) or Key Exchange
   Keys (KEK) and do not clear existing keys as a shortcut.
4. Enable Secure Boot and boot the signed Aura media. Firmware menus and
   enrollment capabilities vary by vendor and model.
5. This preview authenticates only the EFI-stub image on the media. The
   installed GRUB/kernel chain is not yet covered; disable Secure Boot before
   attempting to boot the installed system until a later end-to-end milestone
   is available.

If the firmware cannot safely append an owner certificate to db, do not
force enrollment or switch the machine into an unsupported key state.

## Architecture status

| Architecture | Build/signature verification | Secure Boot firmware runtime |
|---|---|---|
| x86-64 | EFI-stub Authenticode signing and sbverify | Not yet validated with an enrolled owner key |
| AArch64 | EFI-stub Authenticode signing and sbverify | Not yet validated with an enrolled owner key |
| RISC-V RV64GC | Offline PE/COFF signing is attempted and verified | Not claimed; firmware acceptance remains unverified |

See ADR 0021 for the trust boundary and the remaining work required for full
installed-system support.
