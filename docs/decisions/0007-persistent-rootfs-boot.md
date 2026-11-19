# ADR 0007: Persistent Debian rootfs handoff from initramfs

- **Status:** Proposed; three-architecture QEMU integration CI pending
- **Date:** 2026-11-19
- **Scope:** First transition from the temporary kernel initramfs into the target-native Debian root filesystem

## Context

ADR 0006 establishes Debian 13 (trixie), systemd, and glibc as the first shared base userspace and the bootstrap workflow creates target-native rootfs trees for amd64, arm64, and riscv64. The earlier kernel smoke tests stop inside a temporary initramfs; they do not prove that the real Debian root filesystem can be mounted or that its systemd binary can run as PID 1.

## Decision

Use a small statically linked C program as the first-stage initramfs PID 1. Keep the existing initramfs-only smoke path as the default for the kernel and AArch64 UEFI tests. Enable the persistent-root path only when the explicit kernel command-line argument `aura.rootfs=1` is present.

The persistent-root handoff performs the following steps:

1. Mount devtmpfs, proc, and sysfs in the initramfs.
2. Wait for the QEMU virtio block device `/dev/vda`.
3. Mount the raw ext4 root filesystem image at `/newroot`.
4. Move `/dev`, `/proc`, and `/sys` mount points into the new root.
5. Call `pivot_root` and detach the old initramfs.
6. Execute `/sbin/init`, which the Debian base validator confirms resolves to systemd.

The QEMU integration workflow creates the ext4 disk image from the generated Debian rootfs and adds a dedicated one-shot systemd service. That service prints `AURA_SYSTEMD_ROOTFS_OK` and `AURA_ROOTFS_QEMU_PASS` to the serial console, then requests guest poweroff. The test accepts a boot only when the initramfs marker, both systemd service markers, and a clean QEMU exit are present and no kernel panic is reported.

The kernel configuration enables ext4, the virtio block transport used by each QEMU machine, cgroup v2, and the core filesystems/controllers required by systemd. x86-64 uses virtio PCI; AArch64 and RV64GC use virtio MMIO.

## Rationale

- A small initramfs PID 1 avoids needing BusyBox or a second shell in each cross-architecture image.
- `pivot_root` and `execve(/sbin/init)` are explicit and auditable, keeping the switch-root logic consistent across architectures.
- The opt-in kernel argument preserves the existing kernel-only and UEFI smoke tests.
- A systemd service marker proves the test reached the real Debian userspace; an initramfs marker alone would not be sufficient.

## Limitations

- The current QEMU profile uses a raw ext4 root image on virtio block and direct kernel loading. It does not validate a partition table, installer, GRUB/systemd-boot, Secure Boot, encryption, removable media, or physical firmware.
- The test service powers off automatically; it does not demonstrate interactive login, user provisioning, networking, persistent upgrade behavior, or desktop startup.
- `/dev/vda` is an explicit first-emulator contract. A later general boot flow must discover the root device by stable identifiers or a configurable kernel command line.
- Hardware compatibility remains separate from architecture compilation and QEMU boot validation.

## Acceptance

This decision is accepted for the initial emulator handoff only after the three matrix jobs in `.github/workflows/base-rootfs-qemu.yml` all:
1. Build a target-native Linux kernel and static initramfs.
2. Build and verify the Debian rootfs and ext4 image.
3. Reach `AURA_SYSTEMD_ROOTFS_OK` and `AURA_ROOTFS_QEMU_PASS` through the persistent-root path.
4. Power off cleanly with no kernel panic.
5. Upload the boot log, kernel, initramfs, disk image, and checksums.

After that, add a separate first-user provisioning design and interactive login test before claiming a usable bootable Aura OS base.
