# ADR 0009: Architecture-specific UEFI boot ISO baseline

- **Status:** Accepted for the boot-validation prototype; installer media remains pending
- **Date:** 2026-11-21
- **Scope:** First downloadable UEFI boot-media format for x86-64, AArch64, and RV64GC

## Context

Aura OS has reproducible target-native kernels, static initramfs images, and persistent Debian rootfs images. Those outputs are CI build artifacts, not optical-disc images. A ZIP containing a kernel and ext4 disk cannot be attached as an ISO/CD-ROM and does not meet the distribution-media requirement.

The three architectures use distinct UEFI firmware and EFI application formats. The project therefore needs architecture-specific loader binaries and firmware tests behind a shared ISO image-building interface. The existing AArch64 UEFI smoke test already demonstrates a Linux EFI-stub image and a FAT EFI System Partition. Ubuntu 24.04 provides QEMU EDK2 RISC-V firmware (qemu-efi-riscv64) for the RV64 virt profile, with OpenSBI as the machine-mode firmware stage.

## Decision

Start with three separate, architecture-specific UEFI El Torito ISO images. Do not attempt a universal multi-architecture ISO until each individual architecture has a stable boot and installer path.

| Architecture | EFI removable-media path | QEMU firmware profile |
|---|---|---|
| x86-64 | EFI/BOOT/BOOTX64.EFI | OVMF / QEMU q35 |
| AArch64 | EFI/BOOT/BOOTAA64.EFI | AAVMF / QEMU virt |
| RV64GC | EFI/BOOT/BOOTRISCV64.EFI | OpenSBI + EDK2 RISC-V / QEMU virt |

Each ISO contains:
- ISO9660 filesystem and an El Torito EFI boot catalog.
- A FAT32 EFI System Partition referenced by the El Torito UEFI boot entry.
- The architecture's Linux EFI-stub kernel at the standard removable-media fallback path.
- A target-native initramfs embedded in that kernel, with an architecture-specific built-in command line.

The ISO builder emits the .iso, SHA-256 checksum, El Torito report, and JSON provenance. The QEMU test attaches the image as an optical CD-ROM and requires AURA_INIT_OK, AURA_ISO_BOOT_READY, and AURA_QEMU_TEST_PASS. The serial console accepts p followed by Enter to power off or r followed by Enter to reboot; CI sends p plus Enter after the ready marker and requires a clean guest poweroff with no kernel panic.

Use separate kernel output directories for ISO EFI-stub images; do not overwrite the existing direct-boot or persistent-rootfs kernel artifacts. Keep firmware and QEMU profiles explicit per architecture.

## Scope boundary

The first ISO milestone is a **boot-validation prototype**, not an installer or a desktop live image. Its initramfs reports successful boot and provides a small serial-console poweroff/reboot menu. It does not partition or write a target disk, install the Debian rootfs, create a user, or offer a graphical environment.

The next milestone under Issue #12 adds an installer runtime, safe target-disk confirmation, GPT + EFI System Partition + root filesystem layout, installation, and post-install boot validation. Legacy BIOS boot for x86-64, Secure Boot signing, physical board support, and a universal combined ISO remain separate decisions.

## Consequences

- Users can receive actual .iso files rather than ZIP archives of raw build artifacts; the first three-architecture matrix passed in [Actions run #33](https://github.com/nebula-INE/aura_os/actions/runs/44902232448).
- ISO creation is shared, while EFI executable names and QEMU firmware remain architecture-specific.
- An ISO build alone is not accepted: the CI must boot the image from a virtual CD-ROM through the architecture's UEFI firmware.
- A green boot-matrix validates the UEFI boot-media prototype only; it does not imply installer or hardware readiness.

## Validation result

The x86-64, AArch64, and RV64GC jobs all passed in [Actions run #33](https://github.com/nebula-INE/aura_os/actions/runs/44902232448) on 2026-11-21. For all three targets, the job completed the kernel build, target-native initramfs build, EFI-stub kernel build, ISO assembly, El Torito/ESP verification, and QEMU UEFI virtual-CD-ROM boot. The serial logs contain AURA_INIT_OK, AURA_ISO_BOOT_READY, and AURA_QEMU_TEST_PASS followed by a clean poweroff. ISO, SHA-256, provenance, El Torito report, and serial log artifacts were uploaded for each architecture.

This validates only the UEFI boot prototype. The images are not installers and are not yet approved for writing to or installing onto a physical disk.

## Acceptance

For each architecture:
1. Build a non-empty ISO9660 image with an EFI El Torito boot entry.
2. Extract the EFI System Partition from the finished ISO and verify its expected fallback loader exists.
3. Boot the ISO as virtual CD-ROM media through the named QEMU UEFI firmware.
4. Require the initramfs success markers, clean poweroff, and absence of kernel panic.
5. Upload the ISO, SHA-256, provenance, El Torito report, and serial log.

Do not mark the installer-media milestone complete until a separate installer workflow writes a disposable target disk and successfully boots the installed system.
