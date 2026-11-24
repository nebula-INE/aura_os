# ADR 0013: Inspection-only Offline Rescue Mode

- **Status:** Proposed
- **Date:** 2026-11-24
- **Scope:** Offline inspection from the architecture-specific Aura OS installer ISO

## Context

The installed-system aura-recovery.target requires the installed root
filesystem, kernel, and initramfs to boot. It cannot help when the root
filesystem is damaged or the installed system cannot start systemd. Aura OS
already has a Debian 13 installer initramfs that boots independently from
installation media and contains storage inspection utilities.

## Decision

Add an explicit **Offline Rescue** choice to the installer ISO boot flow.
The rescue environment runs from the in-memory installer root filesystem and
does not invoke the disk installer.

The first increment is inspection-only:

1. Inventory block devices, filesystem signatures, UUIDs, and current mounts.
2. Mount AURA_ROOTFS ext4 filesystems with
   ro,noload,nodev,nosuid,noexec.
3. Mount AURA_EFI filesystems read-only with nodev,nosuid,noexec.
4. Verify mount options before exposing the root shell.
5. Never run repair, formatting, bootloader installation, credential reset, or
   configuration mutation automatically.

The QEMU integration test creates a disposable ext4 AURA_ROOTFS image,
boots rescue mode on each supported architecture, verifies its mount is
read-only, powers off, and compares the image SHA-256 before and after.

## Safety

- The installer ISO remains mounted read-only.
- Ext4 uses noload to avoid journal replay during read-only inspection.
- EFI filesystems are mounted read-only.
- No disk-write command is issued by the rescue entry point.
- Filesystem repair is not offered in this increment. A future repair workflow
  must require a verified backup destination, explicit target identity, clear
  data-loss warnings, and a second confirmation immediately before writes.
- Users must not run e2fsck against a mounted filesystem; the documented
  e2fsck -fn check is read-only and must target an unmounted filesystem.

## Consequences

The rescue shell can inspect installed-system files even when the installed
OS cannot boot. It does not recover missing/corrupt kernels, initramfs or
firmware, perform automatic data recovery, decrypt encrypted volumes, or
repair bootloaders. Those capabilities remain separate follow-up work.

This is not a replacement for the authenticated installed-system Recovery
Mode; the two environments address different failure classes.
