# ADR 0008: Initial persistent storage image contract

- **Status:** Accepted for the QEMU bring-up baseline
- **Date:** 2026-11-20
- **Scope:** The first shared root-volume image format for x86-64, AArch64, and RV64GC

## Context

Aura OS now builds target-native Debian 13 root filesystems and boots them through a small static initramfs into systemd under QEMU. The current emulator contract attaches the root image as a virtio block device and mounts /dev/vda directly. The image builder formats the entire image file as ext4; it is not a partitioned disk.

The three-architecture QEMU workflow validates systemd startup, wired networking, DNS, and the interactive first-user/login path. A successful mount alone does not prove that the generated filesystem has the expected identity or is clean before boot.

Changing to GPT partitions now would also require coordinated changes to the image builder, kernel partition support, initramfs device discovery, and boot/installer design. That is a separate migration, not a safe incidental change to the current root-volume format.

## Decision

Keep the existing raw whole-device ext4 image as the initial QEMU root-volume format.

The image contract is:

- The entire image is an ext4 filesystem, not a partition table containing an ext4 partition.
- The filesystem label is AURA_ROOTFS.
- The filesystem has a valid UUID.
- Before the image is handed to QEMU or packaged, blkid -p must identify it as ext4 with the expected label.
- e2fsck -f -n must complete with exit code zero. This is a forced, read-only consistency check; the validator never repairs or modifies an image.
- The validator emits a machine-readable JSON report with image size, filesystem type, label, UUID, layout, and integrity-check result.
- QEMU supplies the filesystem UUID with the standard `root=UUID=` kernel argument. The initramfs searches `/sys/class/block` and mounts the matching ext4 block device; tests no longer depend on the device being named `/dev/vda`.

The checks are shared by every target architecture and run as part of image creation and CI. Unit tests cover missing/empty images, wrong filesystem type or label, invalid UUIDs, unrecognized images, and failed filesystem checks.

## Consequences

- The existing x86-64, AArch64, and RV64GC QEMU boot path remains compatible.
- Image identity and filesystem integrity become explicit, repeatable quality gates before boot.
- A raw filesystem image is useful for the current emulator bring-up but is not a complete installable disk.
- The layout does not yet provide a GPT/MBR partition table, EFI System Partition, swap, separate data/home volume, encryption, removable-media layout, or installer.
- The initramfs currently discovers unencrypted ext4 filesystems by filesystem UUID. GPT partitioning, partition UUID selection, encrypted-volume activation, LVM/device-mapper activation, and hotplug-driven device discovery remain future work.
- The read-only check detects filesystem inconsistencies; it does not provide backup, snapshot, rollback, or recovery semantics.

## Acceptance

The baseline is accepted when:

1. The storage image validator's unit tests pass.
2. The image builder validates each generated image after unmounting it.
3. The QEMU rootfs matrix passes on x86-64, AArch64, and RV64GC using the unchanged /dev/vda handoff.
4. Each CI artifact includes the ext4 image, SHA-256 checksum, and storage JSON report.

Passing these checks establishes the initial emulated ext4 root-volume contract only. It does not establish support for physical disks or an end-user installer.
