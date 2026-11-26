# ADR 0017: Signed installer media and payload verification

- **Status:** Accepted design; CI implementation under test
- **Date:** 2026-11-25
- **Scope:** Integrity and publisher authenticity for installable Aura OS UEFI media

## Context

A SHA-256 file stored beside the payload detects accidental corruption only
when the checksum itself is trusted. If an attacker can replace both a payload
and its checksum on the same ISO, plain checksum verification accepts the
replacement.

## Decision

Use Ed25519 signatures produced and verified by OpenSSL for this bootstrap
stage. The signed manifest covers the target-native rootfs archive, installed
kernel, persistent-root initramfs, and EFI boot image. The installer initramfs
contains the trusted public key and verifies the manifest signature and every
payload hash before displaying install/rescue choices or allowing disk actions.

The completed ISO also has a detached signature over its SHA-256 checksum
file. Users must verify this signature using a public key obtained through an
independent trusted channel before booting the ISO.

## Signing-key handling

- The private release key is never stored in the repository or included in
  build artifacts.
- The long-lived release private key is supplied through the GitHub Actions
  secret `AURA_RELEASE_PRIVATE_KEY_PEM`; its matching public PEM is supplied
  through the repository variable `AURA_RELEASE_PUBLIC_KEY_PEM`.
- PR and ordinary branch CI may generate a per-run ephemeral key to exercise
  the signing and verification code. Such artifacts are test outputs only and
  are **not trusted release media**.
- A release-tag build must fail closed when the persistent key pair is absent
  or does not match. It must never silently fall back to an ephemeral key.
- The public key is published beside the ISO and embedded in the installer
  initramfs. Its fingerprint must be independently pinned for production use.

## Trust boundary and limitations

The installer verifies media payloads only after the EFI-stub installer
kernel has started. The detached ISO signature is the pre-boot authenticity
check and must be verified by the operator before boot. Firmware Secure Boot
and a hardware-rooted boot trust chain are not established by this ADR.

The public key inside the ISO is not an independent trust anchor by itself.
Copying the public key from an unverified ISO and using it to verify that same
ISO provides no authenticity guarantee.
