# ADR 0005: AArch64 UEFI first-boot reference profile

- **Status:** Proposed; CI validation pending
- **Date:** 2026-11-18
- **Scope:** QEMU AArch64 UEFI firmware handoff and first userspace execution only

## Context

Aura OS has an AArch64 QEMU direct-kernel smoke test, but it does not exercise a real UEFI firmware handoff. AArch64 is a first-class Aura OS target, so the project needs a repeatable firmware-mediated validation path in addition to direct Linux loading.

## Decision

Use the Ubuntu 24.04 AAVMF firmware package `qemu-efi-aarch64` with QEMU's `virt` machine.

- Firmware code: `/usr/share/AAVMF/AAVMF_CODE.fd`, attached read-only as pflash unit 0.
- Firmware variables template: `/usr/share/AAVMF/AAVMF_VARS.fd`; copy it for every test and attach the copy read-write as pflash unit 1.
- Emulator: `qemu-system-aarch64`, TCG acceleration.
- Machine: `virt,gic-version=3`.
- CPU: fixed `cortex-a57` model.
- Guest memory and CPUs: 1 GiB and two vCPUs.
- Boot media: GPT disk containing a FAT32 EFI System Partition, exposed as a virtio block device.
- Removable-media fallback application: `EFI/BOOT/BOOTAA64.EFI`.
- Kernel: AArch64 Linux `Image` containing the EFI stub and embedded test initramfs.
- Console: PL011 UART using `console=ttyAMA0,115200`.

The UEFI build uses a separate kernel output tree. It starts from the already-tested AArch64 configuration and enables the EFI stub. It embeds the same target-native initramfs root directory used by the direct boot smoke test and forces a deterministic command line:

```text
console=ttyAMA0,115200 rdinit=/init panic=-1
```

The EFI image is copied as `BOOTAA64.EFI` to the standard AArch64 removable-media fallback path on the FAT32 ESP. No separate GRUB binary is required for this first UEFI handoff test.

The test must preserve a complete serial log and firmware/kernel/ESP checksums, use a bounded timeout, reject a kernel panic, and require both `AURA_INIT_OK` and `AURA_QEMU_TEST_PASS` before accepting the guest poweroff.

## Rationale

- Testing the kernel EFI stub directly isolates the UEFI firmware-to-kernel handoff without introducing a second architecture-specific bootloader build dependency.
- Embedding the tiny test initramfs avoids relying on firmware-specific mechanisms for loading an external initrd.
- A separate output tree preserves the ordinary AArch64 `Image` used by the direct QEMU loader test.
- A disposable variables store makes each CI run repeatable and avoids mutating the package's firmware template.

## Consequences and limitations

- The test validates AAVMF → AArch64 Linux EFI stub → embedded initramfs `/init` on the named QEMU virt profile only.
- It does not validate Secure Boot enrollment/signing, physical boards, real NVRAM persistence, installers, complete disk images, or usable peripherals.
- Secure Boot remains a separate policy and test requirement.
- Firmware file paths and package version must be recorded because firmware changes can affect boot behavior.

## Validation and acceptance

This ADR remains proposed until the AArch64 UEFI CI job passes. Acceptance requires:
1. The kernel build configuration proves EFI, EFI stub, initramfs embedding, and the forced serial command line are enabled.
2. The resulting image is recognized as a PE32+ AArch64 EFI application.
3. AAVMF discovers and executes `EFI/BOOT/BOOTAA64.EFI` from the GPT/FAT32 ESP.
4. The kernel executes `/init`, emits both Aura success markers, powers off cleanly, and does not panic.
5. The artifact retains the kernel image, checksums, firmware provenance, ESP image, and complete serial log.

After this emulator profile is verified, select and document an actual AArch64 reference device before making hardware support claims.
