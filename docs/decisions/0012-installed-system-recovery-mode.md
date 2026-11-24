# ADR 0012: Authenticated installed-system Recovery Mode

- **Status:** Accepted for the first installed-system recovery increment; offline rescue remains deferred
- **Date:** 2026-11-24
- **Scope:** Minimal systemd target and GRUB recovery entry for installed Aura OS systems

## Context

Aura OS now has a Debian 13 base, a persistent-root initramfs handoff, first-user
provisioning, and a GPT/UEFI installer. Troubleshooting currently requires
booting the normal multi-user system, which can start services that are part
of the problem being investigated.

The project needs a recovery boot choice that does not bypass local account
authentication or unlock the root account.

## Decision

Install an `aura-recovery.target` systemd target and expose it through a
separate GRUB menu entry on every supported installer architecture.

The recovery target:

- Requires the essential `basic.target`.
- Starts local user sessions and the systemd-generated console getty.
- Runs the existing first-user setup before the login getty when provisioning
  has not yet completed.
- Prints recovery instructions to the system console before the login prompt.
- Does not pull in `multi-user.target`, the normal wired networking services,
  or the normal multi-user service set.
- Does not configure an automatic login, shared password, or usable root
  password.
- Does not run repair commands or change filesystem/configuration state.

The normal Aura OS GRUB entry remains first/default. Recovery uses the same
installed kernel, root UUID, and architecture-specific initramfs arrangement:
x86-64/AArch64 continue to use the external initrd line, and RV64GC continues
to use its embedded persistent-root initramfs.

## Rationale

An authenticated minimal target is useful when the persistent root filesystem
and systemd can start but the normal service set prevents troubleshooting.
It is a smaller change than introducing a separate recovery distribution
inside the installer, and it reuses the tested root-UUID path.

Authentication remains delegated to the regular local user accounts. The
firstboot service is also wanted by the recovery target so a newly installed
system does not expose an unusable root-only recovery prompt.

## Validation

The installer workflow validates the unit files and rootfs contract for all
three architectures. The QEMU install test checks that the installed GRUB
configuration contains a separate recovery entry, then boots the installed
kernel directly with `systemd.unit=aura-recovery.target` and verifies the
recovery target, console login, and absence of the normal network services.

## Limitations and deferred work

- The installed root filesystem is mounted normally; this is not an offline
  or guaranteed read-only environment.
- It cannot recover a missing/corrupt root filesystem, initramfs, kernel, or
  bootloader.
- Filesystem repair, bootloader repair, configuration rollback, and snapshot
  restoration are not automated and need a separate threat model, backups,
  dry-run behavior, and explicit confirmation.
- A standalone offline rescue environment that can inspect a damaged or
  unbootable installed root filesystem remains a separate milestone.
