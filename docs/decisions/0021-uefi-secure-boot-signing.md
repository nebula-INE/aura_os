# ADR 0021: UEFI Secure Boot signing foundation

- **Status:** Accepted for the boot-media signing milestone; installed-system enforcement remains open
- **Date:** 2026-11-28
- **Scope:** Authenticode signing and verification of Aura's directly launched EFI-stub boot images

## Context

Aura's install-media payload manifest and detached ISO checksum signatures are
verified by the installer or the operator, but those checks do not make UEFI
firmware authenticate the EFI executable before it starts. Firmware Secure
Boot validates EFI executable signatures against its authorized signature
database (db) and revocation database (dbx). The key used for firmware image
authentication must therefore be an X.509 signing identity, not the existing
Ed25519 payload-manifest key or the OpenPGP APT repository key.

## Decision

- Use a dedicated RSA 3072-bit X.509 code-signing identity and SHA-256
  Authenticode signatures for EFI-stub images.
- Keep the UEFI image-signing private key separate from the Ed25519 installer
  manifest key and the OpenPGP APT repository key.
- Use sbsign to sign the architecture-specific EFI-stub kernel and
  sbverify --cert to verify the output with the exact certificate used for
  signing. A build must fail closed if signing or verification fails.
- PR, branch, and manual CI builds generate throwaway keys. Tagged release
  builds require the configured private-key Secret and matching certificate
  and SHA-256 fingerprint Variables; no ephemeral fallback is allowed for a
  release tag.
- Export the signing certificate as DER (.cer) and include its SHA-256
  fingerprint in build artifacts and install media. This makes enrollment
  possible on firmware that supports owner-managed Secure Boot databases.

## Trust and operational boundary

The certificate inside an ISO is not an independent trust anchor. Operators
must obtain the expected certificate fingerprint from a separately trusted
release channel before enrolling the certificate into the firmware db.
Only append the signing certificate to the authorized image-signature
database when the firmware offers a supported owner-key workflow; do not
replace the Platform Key (PK) or Key Exchange Keys (KEK) as a shortcut.

This milestone signs the EFI-stub image that firmware launches for the
installer/bring-up media. It does **not** yet provide a complete installed
system Secure Boot chain: installed GRUB binaries, installed kernels and
kernel modules are not all signed and enforced by this change. The installable
image is therefore a Secure Boot development preview, not a claim that
Secure Boot can remain enabled through installation and subsequent boots.

The RISC-V image can be Authenticode-signed and signature-verified offline,
but Secure Boot runtime acceptance depends on the selected RISC-V firmware.
No RISC-V Secure Boot support is claimed until EDK2/QEMU and reference hardware
are tested with enrolled keys.

## Follow-up required for full support

1. Choose an installed-system chain (for example, a maintained shim/GRUB
   chain or an owner-signed GRUB with mandatory verification of every loaded
   kernel).
2. Sign and validate the GRUB loader, installed kernels, and any boot-critical
   EFI applications with the enrolled owner key.
3. Add Secure Boot firmware tests with owner keys enrolled for x86-64 and
   AArch64, then validate RISC-V firmware separately.
4. Test updates, kernel rollback, recovery, key rotation, revocation, and
   recovery from an unavailable or compromised signing key.
5. Validate the complete chain on physical reference devices before claiming
   production support.
