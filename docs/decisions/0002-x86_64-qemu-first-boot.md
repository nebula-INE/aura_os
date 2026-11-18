# ADR 0002: x86-64 QEMU first-boot reference platform

- **Status:** Accepted for the initial bring-up milestone
- **Date:** 2026-11-18
- **Scope:** Development and CI reference environment; not a hardware compatibility promise

## Context

Aura OS has no implementation or automated boot test yet. A single deterministic environment is needed to validate the kernel, image assembly, serial diagnostics, and first userspace process before expanding to three architectures.

## Decision

Use QEMU's x86-64 system emulator as the first bring-up target.

Initial reference profile:

- Machine: QEMU `q35`.
- Firmware: UEFI via OVMF. CI records the OVMF package version and firmware code/variables-template SHA-256 checksums in its artifacts.
- CPU: the fixed QEMU `qemu64` model; do not use `max` or host passthrough for the reproducibility baseline.
- Console: serial console enabled and captured by automated tests.
- Boot payload: upstream Linux kernel plus a generated initramfs.
- First userspace milestone: kernel successfully executes `/init` from the initramfs and emits a stable, machine-detectable success marker.
- Temporary bring-up tools may use BusyBox in the initramfs. This is a bootstrap aid, not a decision to use BusyBox or a particular init/service manager in the final installed OS.

The first smoke test must boot through OVMF UEFI, use the fixed `qemu64` CPU model, have a timeout, preserve the complete serial log on failure, and fail if the success marker is absent or a kernel panic is detected. The build artifact must record the QEMU version, OVMF package version, firmware checksums, kernel configuration, and image hashes.

## Consequences

- x86-64 becomes the first implementation target, not the only strategic architecture.
- QEMU boot success does not imply support for physical PCs or other architectures.
- Build inputs, QEMU arguments, firmware identity, kernel configuration, and image hashes must be recorded.
- RV64GC and AArch64 QEMU profiles follow after the first reproducible x86-64 boot.

## Not decided here

This ADR does not select the final distribution/base userspace, init/service manager, package manager, desktop, or release update model. Those remain separate decisions.
