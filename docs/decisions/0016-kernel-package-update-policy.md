# ADR 0016: APT-managed kernel packages and boot update policy

- **Status:** Initial versioned package and GRUB trial-boot implementation added; signed APT publication and failure-injection validation pending
- **Date:** 2026-11-25
- **Scope:** Installed kernel delivery, security updates, and rollback across x86-64, AArch64, and RV64GC

## Context

The previous installer copied a fixed kernel payload to /boot/vmlinuz-aura and
wrote a hand-maintained GRUB configuration. That kernel was not owned by dpkg,
so the package lifecycle could not protect or replace it consistently.

## Decision

Use Debian **APT/dpkg packages** for the installed kernel. Do not introduce an
A/B root filesystem as the first update mechanism.

The package contract is:

1. Build an architecture-native image package named
   aura-kernel-image-<kernel-release> and a lifecycle meta package named
   aura-kernel. The image package version is derived from the exact
   make kernelrelease output, not merely the upstream source tag.
2. Keep the kernel image and matching persistent-root initramfs together.
   x86-64 and AArch64 ship a versioned external initramfs; RV64GC keeps its
   current embedded persistent-root /init behavior.
3. Install versioned files under /boot; never overwrite the currently booted
   kernel in place. Keep older image packages installed as fallback candidates.
4. Generate GRUB entries from installed version metadata. Each version gets
   a normal entry and a Recovery Mode entry, both using the installed root
   UUID and the architecture-specific command line.
5. On package configuration, make the previous known-good version the saved
   GRUB default and select a newly installed candidate for one boot using
   GRUB's next_entry. On a fresh installation, the first installed kernel
   is the initial default.
6. A boot-confirmation service records a candidate as known-good only when
   uname -r matches the pending kernel release. The image package's
   removal hook refuses to remove the pending, known-good, or last installed
   kernel unless an explicit unsafe-removal override is supplied.
7. Publish kernel packages through a signed APT repository. Authenticated
   InRelease/Release metadata is the trust boundary; package hashes alone
   are not publisher authentication.

## Update lifecycle

The installer ISO carries the two architecture-matched Debian packages in
its signed payload manifest and installs them into the target with dpkg.
The package maintainer script generates the initial GRUB menu and stages the
first-boot confirmation state.

For future repository-based updates, apt update must authenticate the
repository metadata; apt upgrade then installs the new image and meta
packages. Their maintainer scripts generate the new menu and request a
one-time candidate boot. After a successful boot is confirmed, the new
version becomes the saved default. The previous image remains installed and
manually selectable.

## Current implementation boundary

Implemented in the versioned-kernel package change:

- Architecture-specific .deb creation for x86-64, AArch64, and RV64GC.
- Exact kernel release metadata from make kernelrelease.
- Config-driven module build/install and packaging of the matching /lib/modules/<release> tree when CONFIG_MODULES=y.
- Installer ISO manifest entries for both packages and dpkg installation
  into the target root.
- Versioned GRUB and Recovery Mode entries.
- One-boot candidate selection, known-good state, and package removal guards.
- Unit and QEMU contract assertions for package metadata and first boot.

Not yet implemented or proven:

- A published signed APT repository, its separate signing key, repository
  metadata generation, and release/update publication workflow. Therefore
  apt upgrade does not yet receive Aura kernel updates from a repository.
- A QEMU failure-injection test that boots a deliberately bad candidate and
  observes the previous default on the next reboot.
- A firmware watchdog or automatic recovery from a kernel that hangs without
  rebooting. The current one-shot selection falls back when the candidate
  boot returns/restarts; a hard hang still requires a reset or manual
  intervention.
- UEFI Secure Boot and a firmware-rooted trust chain.

## Security and rollback requirements

- The APT repository signing key must be separate from the installer-media
  signing key.
- Reject packages whose Debian architecture does not match the installed OS.
- Treat the kernel and initramfs as a matched versioned pair.
- Keep the previous known-good entry and image until the candidate's boot is
  confirmed.
- Never garbage-collect the only bootable kernel.
- Test successful repository update, candidate boot, failed candidate boot,
  fallback selection, and cleanup only after health confirmation.

A/B rootfs updates may be reconsidered later if package-based kernel/rootfs
updates cannot meet a measured atomicity or rollback requirement. The initial
implementation should avoid two competing update mechanisms.
