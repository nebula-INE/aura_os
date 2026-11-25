# ADR 0015: Read-only offline diagnostics from Rescue Mode

- **Status:** Proposed
- **Date:** 2026-11-25
- **Scope:** Diagnostic collection for an installed Aura root filesystem from installer-media Offline Rescue

## Context

The installed-system \`aura-diagnose\` command requires a running Aura userspace.
It cannot collect systemd state or inspect an installed root when that system
cannot boot. Offline Rescue already mounts selected \`AURA_ROOTFS\` filesystems
using \`ro,noload,nodev,nosuid,noexec\`, but the current shell exposes only
individual inspection commands.

## Decision

Add \`/usr/lib/aura/installer/diagnose.sh\`, exposed as
\`sh /usr/lib/aura/installer/diagnose.sh\` in Offline Rescue.

The collector:

1. Enumerates only already-mounted ext4 roots under \`/mnt/aura-rescue/root-*\`.
2. Requires the selected mount to remain verified as read-only.
3. Collects static OS release, hostname, fstab, Aura install manifest,
   GRUB configuration, installed package names, boot-file inventory,
   systemd enablement symlinks, and log-file inventory.
4. Collects the current block-device, signature, and mount inventory from
   the rescue environment.
5. Excludes journal contents by default. An explicit
   \`--include-journal\` option asks the rescue environment's \`journalctl\`
   to read the target root's journal, capped to 200 warning-or-higher entries
   from its latest recorded boot.
6. Writes an owner-only tar.gz and SHA-256 sidecar only to a verified tmpfs
   directory under the rescue environment's \`/run\`.

The collector does not chroot, execute target binaries, start target services,
mount or remount filesystems, or invoke repair/package/bootloader tools. Target
symlinks in paths used for static file collection are recorded, not followed.

## Safety and privacy

- The selected source must be ext4 mounted read-only; no read-write fallback
  is attempted.
- Output is restricted to tmpfs so the collector cannot accidentally write
  its report onto the installed root or another persistent block device.
- Existing report names are never overwritten.
- Journal data remains opt-in because it may contain private information.
- The archive can expose UUIDs, hostnames, device names, boot settings, package
  inventory, system paths, and (when enabled) log contents. Users must review
  it before sharing.
- The report is stored in installer RAM and is lost at shutdown. Copy it to
  separate removable media only after review.

## Consequences

Offline Rescue can produce a portable support report even when the installed
Aura userspace does not boot. The report is an offline snapshot of files and
metadata, not a live systemd health check; it cannot determine which services
would currently start or whether the target hardware is functional.

This capability remains inspection-only. Backup, restore, and any future
repair workflow keep their independent safeguards and confirmations.
