# ADR 0007: Persistent Debian rootfs handoff from initramfs

- **Status:** Accepted for the three-architecture QEMU integration baseline
- **Date:** 2026-11-19
- **Scope:** First transition from the temporary kernel initramfs into the target-native Debian root filesystem on the pinned Linux 6.18.64 line

## Context

ADR 0006 establishes Debian 13 (trixie), systemd, and glibc as the first shared base userspace and the bootstrap workflow creates target-native rootfs trees for amd64, arm64, and riscv64. Earlier kernel smoke tests stop inside a temporary initramfs; they do not prove that the real Debian root filesystem can be mounted or that its systemd binary can run as PID 1.

A root handoff must match the exact kernel line being tested. Linux 6.18.64 uses the traditional mutable ramfs/tmpfs rootfs. The kernel's `Documentation/filesystems/ramfs-rootfs-initramfs.rst` describes rootfs as always present and not unmountable, and the `pivot_root(2)` error contract rejects calls when the current root is on the initial rootfs. A newer nullfs-based root hierarchy introduced on the Linux 7.0 development line changes this behavior, but Aura's pinned 6.18.64 baseline must not assume that newer facility.

## Decision

Use a small statically linked C program as the first-stage initramfs PID 1. Keep the existing initramfs-only smoke path as the default for kernel and AArch64 UEFI tests. Enable the persistent-root path only when the explicit kernel command-line argument `aura.rootfs=1` is present.

The persistent-root handoff uses the classic `switch_root` overmount/chroot sequence:

1. Mount devtmpfs, proc, and sysfs in the initramfs.
2. Read the standard `root=UUID=<filesystem-uuid>` kernel argument. Enumerate `/sys/class/block`, open visible block devices, and compare the ext4 superblock UUID at its defined offset. Wait for device discovery within a bounded deadline.
3. Mount the matching raw ext4 root filesystem image at `/newroot`. A legacy `/dev/vda` fallback is retained only when no `root=` argument is supplied.
4. Move `/dev`, `/proc`, and `/sys` mount points into the new root.
5. Remove the known, empty temporary initramfs directories and unlink the running `/init` pathname. The running process remains alive until it is replaced by `execve`.
6. Change the current working directory to `/newroot`, move that mount over `/`, then `chroot(".")` into it.
7. Execute `/sbin/init`, which the Debian base validator confirms resolves to systemd.

This is deliberately not a `pivot_root()` call: the pinned 6.18.64 rootfs contract requires the traditional switch-root method.

The QEMU integration workflow creates the raw whole-device ext4 disk image from the generated Debian rootfs and adds a dedicated one-shot systemd service. The service verifies networkd, resolved, timesyncd activation, Ethernet enumeration, DHCPv4, the default route, IPv6 link-local addressing, and DNS resolution before printing the success markers and requesting guest poweroff. The separate interactive first-boot test also verifies user creation, serial login, sudo authentication, root lock, and repeat-boot persistence.

The kernel configuration enables ext4, the virtio block transport used by each QEMU machine, cgroup v2, and the core filesystems/controllers required by systemd. x86-64 uses virtio PCI; AArch64 and RV64GC use virtio MMIO.

## Rationale

- The static initramfs PID 1 avoids needing BusyBox or a second shell in each cross-architecture image.
- The overmount/chroot handoff is compatible with the pinned 6.18.64 rootfs semantics and follows the conventional `switch_root` model.
- The explicit `aura.rootfs=1` flag preserves existing kernel-only and UEFI smoke tests. Persistent-root QEMU tests pass the filesystem UUID via `root=UUID=...`; initramfs resolves that UUID without depending on a particular block-device name.
- A systemd service marker proves the test reached the real Debian userspace; an initramfs marker alone would not be sufficient.

## Limitations

- The current QEMU profile uses a raw ext4 root image on virtio block and direct kernel loading. It does not validate a partition table, installer, GRUB/systemd-boot, Secure Boot, encryption, removable media, or physical firmware.
- The non-interactive network smoke service powers off automatically. Interactive login and first-user provisioning are tested separately. These emulator tests do not demonstrate persistent upgrade behavior, desktop startup, or physical-hardware compatibility.
- The initial UUID resolver recognizes unencrypted ext4 filesystems visible through `/sys/class/block`. Encrypted containers, device-mapper/LVM discovery before activation, network root filesystems, and a full initramfs device-event manager remain out of scope.
- The traditional switch-root flow leaves the kernel's special rootfs mount underneath the overmounted Debian root. It removes the temporary archive's known contents but does not claim that the rootfs mount itself is detached.
- Hardware compatibility remains separate from architecture compilation and QEMU boot validation.

## Acceptance

This decision is accepted for the initial emulator handoff after all three matrix jobs in `.github/workflows/base-rootfs-qemu.yml` passed in CI run 44646382671. The jobs:
1. Build a target-native Linux kernel and static initramfs, including the tested root UUID parser.
2. Build and verify the Debian rootfs and ext4 image.
3. Resolve `root=UUID=...` to the matching ext4 block device and reach the systemd, network, DNS, and NTP-service-activation success markers through the switch-root path.
4. Pass first-user setup, interactive serial login, sudo authentication, and repeat-boot checks.
5. Power off cleanly with no kernel panic.
6. Upload the boot log, kernel, initramfs, disk image, and checksums.

After that, add a separate first-user provisioning design and interactive login test before claiming a usable bootable Aura OS base.
