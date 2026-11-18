# ADR 0004: Initial RV64GC and AArch64 QEMU bring-up profiles

- **Status:** Proposed; CI validation pending
- **Date:** 2026-11-18
- **Scope:** Cross-architecture kernel build and first-userspace smoke tests; not a physical-hardware compatibility promise

## Context

The x86-64 kernel now reaches the initramfs `/init` through OVMF UEFI in QEMU. Aura OS also targets RISC-V RV64GC and AArch64. Before selecting physical boards or claiming support, the project needs deterministic emulator profiles that exercise cross-compilation, architecture-specific kernel configuration, target-native userspace, serial diagnostics, and first userspace execution.

The two target architectures do not share an identical early boot firmware path. The initial profiles therefore validate their respective minimal emulator boot mechanisms without claiming firmware parity.

## Decisions

### Shared build and test requirements

- Build the same pinned, signed upstream Linux tag used by the x86-64 baseline.
- Select architecture-specific kernel `ARCH`, defconfig, and version-controlled configuration fragment.
- Use a target cross compiler and record its version alongside the verified source identity.
- Build a statically linked target-native `/init` in a deterministic gzip-compressed newc initramfs.
- Use QEMU TCG, 1 GiB guest RAM, two vCPUs, a serial console, and a bounded timeout.
- Capture QEMU version, CPU/machine profile, kernel and initramfs hashes, and the complete serial log.
- A passing smoke test requires the kernel to execute `/init`, emit `AURA_INIT_OK` and `AURA_QEMU_TEST_PASS`, shut down cleanly, and produce no kernel panic.

The test init mounts devtmpfs and writes to `/dev/console`. It exists only to validate first userspace execution and does not select Aura OS's final init/service manager.

### RISC-V RV64GC

- QEMU system emulator: `qemu-system-riscv64`.
- Machine: `virt`.
- CPU: QEMU `rv64` model, targeting the RV64GC baseline.
- Firmware: QEMU's default OpenSBI firmware (`-bios default`).
- Kernel payload: `arch/riscv/boot/Image`, loaded with QEMU's Linux kernel loader.
- Platform description: QEMU-generated device tree.
- Console: 16550 UART, Linux console `ttyS0`.

This validates the OpenSBI-to-Linux handoff in the QEMU virt environment. It does not select a physical RISC-V board, board-specific firmware, or a production bootloader.

### ARM 64-bit AArch64

- QEMU system emulator: `qemu-system-aarch64`.
- Machine: `virt`.
- CPU: `cortex-a57`.
- Kernel payload: `arch/arm64/boot/Image`, loaded with QEMU's direct Linux Image loader.
- Console: PL011 UART, Linux console `ttyAMA0`.

The direct-loader smoke test deliberately does **not** exercise UEFI. A separate AAVMF firmware-mediated test is now defined in ADR 0005: it boots a PE/COFF Linux EFI-stub kernel from the removable-media fallback path and embeds the test initramfs into that kernel. That UEFI profile remains unverified until its dedicated CI job passes. Neither emulator path establishes physical-board support.

## Consequences

- RV64GC and AArch64 gain separate, automated cross-build and first-userspace validation paths.
- The same initramfs source is compiled independently for each target; a host-architecture BusyBox binary is never copied into a foreign-architecture initramfs.
- The emulator boot paths are intentionally different and must remain explicitly documented.
- Successful compilation proves build support only. A passing QEMU test proves first-boot support for the named emulator profile only.
- Complete disk images, installers, device enablement, and physical hardware support remain future milestones.

## Validation and exit criteria

This ADR remains proposed until both new CI matrix legs pass and their artifacts are inspected. Acceptance requires successful cross-compilation, target ELF architecture verification, successful QEMU guest boot, both Aura markers, clean shutdown, no panic, and retained kernel/initramfs hashes and serial logs.

After emulator validation, define physical reference platforms and firmware requirements before broad hardware-support claims.
