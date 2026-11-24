# ADR 0014: External backup from Offline Rescue

- **Status:** Proposed
- **Date:** 2026-11-25
- **Scope:** Root filesystem and EFI file export from the installer ISO's offline rescue environment

## Context

Offline Rescue can mount installed Aura filesystems read-only, but a safe
repair workflow must first provide an independent backup. The first backup
increment should avoid formatting the destination or modifying the source.

## Decision

Provide an explicit backup wizard that exports:
- the selected installed ext4 root filesystem to a compressed tar archive;
- the corresponding EFI system partition, when its UUID is listed in the
  selected root's fstab and it is mounted read-only;
- SHA-256 checksum files and a plain-text manifest.

The destination must be an existing, unmounted, writable ext4 filesystem on a
different physical block-device ancestry from the source root. No formatting
is performed. The user selects the source and destination, confirms the exact
destination path, and enters a second explicit confirmation before writing.

The source filesystems remain read-only. Transient /dev, /proc, /sys, /run,
and /tmp contents are excluded from the root archive. The archives are
verified with gzip and tar listing checks before a completed backup
directory is published.

CI must boot the installer ISO on x86-64, AArch64, and RV64GC, attach a
separate backup disk, create a backup, verify the backup manifest/archive on
the destination image, and prove the source image SHA-256 is unchanged.

## Safety and limitations

- The destination is never formatted.
- A destination sharing a physical ancestor with the source root is rejected.
- A destination already mounted or read-only is rejected.
- The source must still be mounted read-only after confirmation.
- The destination filesystem is ext4 only in this increment.
- No restore, automatic repair, bootloader recreation, encryption recovery,
  credential reset, or data recovery from failing media is implemented.
- Users must retain an independent second copy and test restoration before
  relying on a backup.
