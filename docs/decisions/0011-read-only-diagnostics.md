# ADR 0011: Read-only system diagnostics and support bundles

- **Status:** Accepted for the first diagnostics increment; bootable recovery and repair remain deferred
- **Date:** 2026-11-24
- **Scope:** Base-userspace troubleshooting and privacy-aware diagnostic export

## Context

Aura OS has a target-native Debian 13 base for x86-64, AArch64, and RV64GC.
The initial system provides systemd, util-linux, iproute2, ext4 tools, wired
networking, and a persistent installation manifest, but does not yet have
a consistent support-report interface.

A recovery feature must not conflate information collection with destructive
repair. A support archive can also disclose host identifiers, IP addresses,
disk UUIDs, mount topology, or private log entries.

## Decision

Add `aura-diagnose` as a POSIX shell utility installed at
`/usr/bin/aura-diagnose` in every architecture's base root filesystem.

- Keep the default operation strictly read-only.
- Collect bounded summaries of OS/kernel identity, uptime and memory,
  systemd state and failed units, storage topology and mounts, disk space,
  installation manifest, network addresses/routes, resolver state, and
  network-link state.
- Record missing commands and non-zero command statuses without aborting the
  remainder of the report.
- Export individual text sections plus an index in a gzip-compressed tar
  archive, normally under `/var/tmp`.
- Create report files with restrictive permissions and refuse to overwrite
  an existing destination.
- Do not collect password databases, shell history, process environments, or
  user document contents.
- Exclude the system journal by default. Include at most 200 current-boot
  warning-or-higher entries only when the operator explicitly supplies
  `--include-journal`.
- Include a privacy notice in every archive and document that the result must
  be reviewed before it is shared.
- Do not run repair actions, change system configuration, restart services,
  install packages, or write to storage devices.

The tool uses existing base commands and does not introduce a Python runtime
dependency into the minimal root filesystem.

## Rationale

A read-only report is useful even before a bootable rescue environment exists.
Using the existing shell and base utilities keeps the same interface across
amd64, arm64, and riscv64 without increasing the base image with a scripting
runtime. Explicit journal opt-in and an in-archive privacy notice reduce the
chance of unintentionally disclosing log contents.

Keeping repair out of scope prevents a diagnostic report from silently
modifying a system that may already be in a degraded state.

## Validation

The base-userspace CI runs dedicated tests for archive creation, private file
permissions, no-overwrite behavior, journal opt-in, invalid options, and
continued collection when an individual command fails. The base-rootfs
validator verifies that the executable is present in every generated rootfs.

## Deferred work

- A bootable recovery/rescue environment that can operate when the installed
  userspace does not start.
- Recovery-mode bootloader integration across UEFI profiles.
- Filesystem repair, bootloader repair, or configuration rollback. These need
  a separate threat model, explicit user confirmation, and a dry-run/backup
  contract.
- A/B system updates or filesystem snapshots. The current single ext4 root
  layout does not provide an established rollback primitive.
