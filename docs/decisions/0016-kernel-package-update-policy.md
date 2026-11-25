# ADR 0016: APT-managed kernel packages and boot update policy

- **Status:** Accepted design; implementation pending
- **Date:** 2026-11-25
- **Scope:** Installed kernel delivery, security updates, and rollback across x86-64, AArch64, and RV64GC

## Context

The current installer copies the ISO's fixed kernel payload to
`/boot/vmlinuz-aura` and writes a hand-maintained `grub.cfg`. That image is
not owned by dpkg, so `apt upgrade` cannot update the Aura kernel. An OS
whose kernel is outside the package lifecycle has no complete security-update
path.

## Decision

Use Debian's **APT/dpkg package lifecycle** for Aura's installed kernel.
Do not introduce an A/B root filesystem as the first update mechanism.

The implementation contract is:

1. Build one architecture-native `aura-kernel` Debian binary package for each
   supported target from the pinned, signature-verified upstream Linux stable
   source and Aura's architecture-specific kernel configuration.
2. Package the kernel image and its matching persistent-root initramfs as one
   versioned, dependency-consistent unit. RV64GC keeps the current embedded
   `/init` behavior; x86-64 and AArch64 use the external GRUB initrd handoff.
3. Install versioned kernel/initramfs files under `/boot`; do not overwrite
   the currently booted file in place.
4. Use Debian maintainer scripts to refresh GRUB configuration after package
   installation/removal. Preserve the root UUID, Aura kernel command-line
   arguments, and an explicit Recovery Mode menu entry.
5. Publish kernel packages in a signed APT repository. APT's authenticated
   repository metadata (`InRelease`/Release signature) is the trust boundary
   for updates; repository package hashes alone are not authentication.
6. Keep the previously bootable kernel package and its GRUB entry until the
   new kernel has passed the post-update boot/health check. Automatic removal
   of that last-known-good kernel is prohibited. A failed boot must leave a
   selectable previous kernel and a documented manual rollback path.

## Update lifecycle

`apt update` authenticates repository metadata; `apt upgrade` installs the
new kernel package and matching initramfs; package hooks regenerate GRUB;
the next reboot selects the new version. The previous version remains
available until a successful boot is recorded. An update is not considered
complete merely because dpkg installed the package.

The first package publication must include the kernel source version,
source signature verification result, kernel config hash, architecture,
initramfs mode, package SHA-256, and reproducible build provenance.

## Security and rollback requirements

- The APT repository signing key is separate from the installer-media
  signing key.
- Package version and architecture must match the target system; cross-arch
  packages are rejected.
- Kernel and initramfs are installed as a matched pair.
- GRUB must retain a known-good previous entry while the candidate is pending
  first successful boot.
- Tests must cover successful `apt upgrade`, a failed candidate boot,
  selection of the previous kernel, and cleanup only after health confirmation.

## Consequences and current status

This decision establishes the intended update route, but **does not yet make
`apt upgrade` update the kernel**. The current installer still installs the
fixed ISO payload until the versioned package builder, maintainer hooks,
signed APT repository, and update/rollback QEMU tests are implemented.

A/B rootfs updates may be reconsidered later if package-based kernel/rootfs
updates cannot meet a measured atomicity or rollback requirement. The initial
implementation should avoid two competing update mechanisms.
