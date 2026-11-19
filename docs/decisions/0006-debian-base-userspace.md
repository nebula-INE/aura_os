# ADR 0006: Debian base userspace for the first three-architecture bring-up

- **Status:** Accepted for the three-architecture base rootfs bootstrap; persistent-root QEMU boot validation pending
- **Date:** 2026-11-19
- **Scope:** Initial root filesystem, package manager, and init/service baseline; not the final desktop or release image

## Context

Aura OS has verified Linux kernel build and QEMU first-userspace smoke-test paths for x86-64 and RV64GC, plus an AArch64 direct-boot path. It needs a real target-native root filesystem shared by the three architecture profiles before implementing the final init/service configuration, persistent storage layout, desktop, or installer.

The base must offer broad Linux application compatibility and a maintained package ecosystem while keeping the installed package set and enabled services intentionally small.

## Decision for the bring-up baseline

Use Debian 13 (codename `trixie`) as the first shared base userspace source for all three targets.

- x86-64 maps to Debian `amd64`.
- AArch64 maps to Debian `arm64`.
- RISC-V RV64GC maps to Debian `riscv64`.
- Bootstrap with `mmdebstrap --variant=minbase`, using Debian's signed repository metadata and a target-native root filesystem. Foreign-architecture maintainer scripts run through QEMU user-mode static interpreters registered with binfmt_misc using the `F` (fix-binary) flag, so the interpreter remains usable inside the chroot. The CI bootstrap retrieves the official Trixie archive, security, and release public keys, verifies the two published SHA-256 digests and all three full primary-key fingerprints, and passes the resulting keyring to `mmdebstrap`.
- Include `debian-archive-keyring` in the target rootfs so subsequent apt operations can authenticate Debian updates.
- Use glibc as the distribution C library.
- Use apt/dpkg as the package manager and package format.
- Use systemd as the initial init/service manager through `systemd-sysv`.
- Keep the first package manifest small and architecture-independent; omit the desktop, display manager, network manager, firmware bundles, and optional services.
- Preserve a locked root account. First-user creation and password provisioning belong to a later first-boot/provisioning design.
- Build archives and record package versions, target architecture, suite, and checksums.

The Debian suite is explicitly set to `trixie`, not a moving `stable` alias. Package versions are recorded for each generated artifact. A future release process may pin an immutable Debian snapshot once the rootfs package set and upgrade policy are defined.

## Rationale

Debian 13 officially supports amd64, arm64, and riscv64. This permits one distribution policy and one package manifest across the three Aura targets. Its glibc and apt/dpkg ecosystem is a practical starting point for a general-purpose desktop whose priorities include Linux application compatibility and maintainability.

The bootstrap uses `minbase` and a short package list to avoid inheriting a full distribution desktop or enabling a large background service set. This creates room to measure and deliberately select the system services and desktop components later.

## Trade-offs

- A glibc/systemd base is generally larger than an Alpine/musl/OpenRC base; low memory usage is not assumed.
- The repository's 512 MiB idle-desktop RAM target remains a measured stretch goal, not a demonstrated result. It must not be reached by disabling basic security, required hardware support, or normal desktop functionality.
- CI hosts may contain a Debian keyring that predates Trixie's signing keys; the bootstrap therefore prepares an explicit, fingerprint-checked keyring. Its pins must be updated only from Debian's published key announcements and FTP-master key directory.
- Debian's point-release and security updates can change package versions between builds. Each artifact records the installed package manifest; immutable snapshot pinning is future release-engineering work.
- This decision does not imply every board/peripheral on the architecture is supported.

## Validation and acceptance

The bootstrap acceptance checks passed in GitHub Actions run [44428418879](https://github.com/nebula-INE/aura_os/actions/runs/44428418879): amd64, arm64, and riscv64 each generated and uploaded the target-native rootfs, package manifest, checksum, and provenance. The validator checked systemd ELF machine type, `/sbin/init`, required packages, and the locked root account.

The bootstrap is accepted for the next milestone when CI demonstrates:

1. A root filesystem is generated for amd64, arm64, and riscv64 from the same package manifest.
2. The target-native systemd ELF has the expected ELF64 little-endian machine type for each architecture.
3. `/sbin/init` resolves to the systemd executable and apt/dpkg are present.
4. The root account is locked and no default password is configured.
5. Archives, SHA-256 checksums, installed package manifests, and build provenance are retained as artifacts.

A separate follow-up milestone must boot the real root filesystem under QEMU, move from the kernel initramfs into the persistent root, and validate login, services, reboot, and shutdown before claiming a bootable Aura OS base.
