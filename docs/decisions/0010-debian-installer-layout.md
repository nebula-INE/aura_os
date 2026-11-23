# ADR 0010: Debian-based installer and partitioned UEFI system disk

- **Status:** Proposed; implementation and three-architecture QEMU validation pending
- **Date:** 2026-11-23
- **Scope:** Connect the Debian 13 persistent root filesystem to architecture-specific UEFI installation media

## Context

Aura OS already has a target-native Debian 13 (trixie) root filesystem, a static initramfs that resolves root=UUID= against ext4 superblocks, first-boot local administrator provisioning, and a three-architecture UEFI ISO boot prototype. The existing prototype intentionally does not modify disks. A separate install environment is required so that installation can be performed without conflating the installer runtime with the installed system.

## Decisions

### Installer separation

- Keep the existing boot-validation ISO mode unchanged by default.
- Build a separate Debian 13 installer root filesystem and embed it in the installer's EFI-stub initramfs.
- Include the target-native Debian base root filesystem archive and the installed-system kernel/initramfs as separate ISO9660 payloads.
- Run the installer from an initramfs /init entry point; mount installer media read-only and keep the installer runtime available in RAM while target disks are written.
- Accept both optical ISO media and hybrid ISO9660 media written to USB storage.

### Initial target disk layout

- GPT partition table.
- 512 MiB FAT32 EFI System Partition labelled AURA_EFI.
- Remaining disk space as one ext4 root filesystem labelled AURA_ROOTFS.
- Record both filesystem UUIDs and target architecture in an installation manifest.

Swap, a separate home/data partition, encryption, LVM, snapshots, rollback, and partition-preservation are deferred.

### Destructive disk safety

- Never choose an installation target automatically.
- Exclude the installer medium and its block-device ancestry.
- Exclude read-only disks, disks with mounted descendant filesystems, disks with active swap on a descendant, and disks smaller than 4 GiB.
- Display the selected disk model/size and layout before writing.
- Require an explicit disk-number selection, the exact ERASE /dev/<disk> confirmation, and a second INSTALL AURA confirmation.
- Revalidate the target immediately before destructive operations.
- If installation fails after confirmation, leave the installer shell available for diagnosis; do not attempt unattended retries against another disk.

### Installed boot

- Install target-matched GRUB EFI modules and generate a removable-media fallback loader for each architecture.
- Keep the installed kernel's command line configurable by GRUB; do not embed the installer's aura.iso=1 command line or installer initramfs in the installed kernel.
- GRUB passes root=UUID=<root-filesystem-uuid> aura.rootfs=1 and loads the separate persistent-root initramfs.
- The installed root filesystem's /etc/fstab mounts root and the ESP by UUID.

### Architecture profiles

| Architecture | Debian architecture | GRUB target | UEFI fallback loader | Initial QEMU profile |
|---|---|---|---|---|
| x86-64 | amd64 | x86_64-efi | BOOTX64.EFI | OVMF / q35 |
| AArch64 | arm64 | arm64-efi | BOOTAA64.EFI | AAVMF / virt |
| RV64GC | riscv64 | riscv64-efi | BOOTRISCV64.EFI | EDK2 RISC-V / virt |

The shared installer logic is architecture-independent; the kernel, GRUB EFI modules, fallback loader, and QEMU firmware remain target-specific.

## Validation requirements

The Aura installable UEFI media workflow must independently complete for each architecture:

1. Build and checksum a target-native Debian 13 rootfs and installer payload.
2. Build an ISO9660 image with a UEFI El Torito entry and the expected FAT32 EFI loader.
3. Boot the ISO as virtual CD-ROM media and reach AURA_INSTALLER_READY.
4. Confirm the installer exposes only eligible disks and requires all explicit confirmations.
5. Install to a disposable second QEMU disk.
6. Power off, detach the ISO, and boot from the installed disk alone.
7. Verify root UUID discovery, systemd, first-user setup, console login, sudo, wired network services, and clean shutdown.
8. Upload ISO, checksums, provenance, disk metadata, and install/boot logs.

The static installer contract tests do not replace the destructive integration test. Do not mark this ADR accepted until the three-architecture matrix passes and logs are reviewed.

## Limitations

- QEMU firmware profiles are reference validation, not universal hardware support.
- No graphical installer is included; initial interaction uses a serial/system console.
- Secure Boot, legacy BIOS, physical-device validation, Wi-Fi, desktop/display-manager support, partition preservation, encryption, updates, snapshots, and rollback are out of scope.
