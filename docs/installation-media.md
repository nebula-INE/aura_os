# Aura OS installation media and boot validation

Aura OS builds separate UEFI ISO images for x86-64, AArch64, and RV64GC. The repository now contains two distinct media paths:

- **Boot-validation prototype** — the original small initramfs menu used by the already-passed UEFI boot matrix.
- **Installable-media implementation** — a Debian 13 installer initramfs, target-native Debian rootfs archive, installed-system kernel/initramfs payload, GPT/ESP/root deployment, and a QEMU install-then-boot test. The implementation is under review and is not a released installer until the new Actions matrix passes.

## Architecture and payloads

| Architecture | ISO filename | UEFI fallback loader | QEMU firmware |
|---|---|---|---|
| x86-64 | aura-os-x86_64-uefi.iso | EFI/BOOT/BOOTX64.EFI | OVMF |
| AArch64 | aura-os-aarch64-uefi.iso | EFI/BOOT/BOOTAA64.EFI | AAVMF |
| RV64GC | aura-os-riscv64-uefi.iso | EFI/BOOT/BOOTRISCV64.EFI | EDK2 RISC-V via QEMU virt firmware |

The installable ISO keeps the installation environment separate from the installed OS payload:

- The EFI El Torito FAT32 image contains the architecture's Linux EFI-stub installer kernel.
- The kernel embeds a target-native Debian 13 initramfs which runs the installer from RAM.
- The ISO9660 data area contains a target-native Debian 13 rootfs archive, the kernel intended for the installed system, and the persistent-root initramfs.
- The installed system boots through its own ESP and GRUB fallback loader; it does not need the installation ISO after installation.

## Disk layout and safety

The initial installation layout is intentionally small and explicit:

1. GPT partition table.
2. 512 MiB FAT32 EFI System Partition, filesystem label `AURA_EFI`.
3. One ext4 root partition using the remaining disk space, filesystem label `AURA_ROOTFS`.

The installer lists eligible whole disks and does not choose a target automatically. It excludes the installer medium and its block-device ancestry, disks with mounted descendants, read-only disks, disks with active swap on a descendant partition, disks or partitions held by device-mapper/LVM/RAID/multipath consumers, and disks smaller than 4 GiB. The device identity, mount state, swap state, holder state, read-only flag, and minimum size are checked again after the two confirmations immediately before the first write. Before writing, the operator must select a disk number, type the exact `ERASE /dev/...` phrase, and then type `INSTALL AURA`.

**All existing data on the confirmed target disk is destroyed.** The installer does not provide a partition-preservation mode, encryption, LVM, separate home/data/swap partitions, or rollback. Do not test on a disk containing data you need.

## Installable-media build and QEMU test

The `Aura installable UEFI media` workflow builds each target independently. Its steps include:

1. Build and validate the upstream Linux kernel and persistent-root initramfs.
2. Bootstrap and validate the Debian 13 (trixie) base rootfs, including architecture-matched GRUB EFI modules, the `grub2-common` package providing `grub-install`, and FAT formatting tools.
3. Create the separate in-memory installer rootfs/initramfs and installer EFI-stub kernel.
4. Build a separate GRUB-loaded kernel for the installed system; its boot command line and initramfs are supplied from GRUB rather than forced into the kernel.
5. Build the installable ISO and record its SHA-256, El Torito report, and provenance.
6. Attach the ISO and a disposable second disk to QEMU, perform the interactive install, shut down, remove the ISO, and boot from the installed disk.
7. Verify root UUID discovery against `/etc/fstab` and the installation manifest, ESP UUID and mounted fallback loader, systemd, first administrator creation, serial login, sudo, DHCP/default route/DNS, and clean shutdown. Rootfs, installed-kernel, and persistent-initramfs payload checksums are verified before target-disk selection.

Per-architecture artifacts retain the ISO, checksums, rootfs, installer initramfs, kernel provenance, and QEMU logs. Passing the existing prototype ISO workflow does not imply that the new installer workflow has passed.

## Existing boot-only prototype

The original `Aura multi-architecture UEFI ISO boot` workflow passed all three QEMU UEFI boot jobs on 2026-11-21 in [Actions run #33](https://github.com/nebula-INE/aura_os/actions/runs/44902232448). Those artifacts remain boot-validation prototypes; the old images contain no installer and do not write disks.

## Local prerequisites

The CI workflow uses Ubuntu 24.04 and installs these categories of tools: build-essential, Linux kernel dependencies, mmdebstrap, qemu-user-static/binfmt support, dosfstools, mtools, xorriso, per-architecture cross compilers, QEMU, and architecture-matched UEFI firmware.

A local installable build is resource-intensive and must use the same target-native rootfs and kernel sequence as the workflow. The exact commands are maintained in `.github/workflows/installer-iso.yml`; prefer running that workflow rather than assembling payloads manually.

## Support boundary

The first installer milestone validates the three QEMU firmware profiles. It does not claim compatibility with every PC, ARM board, or RISC-V board; nor does it establish Secure Boot, legacy BIOS, Wi-Fi, graphics/desktop support, encryption, upgrade/rollback, or physical-device support. These require separate reference hardware and release tests.
