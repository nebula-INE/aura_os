# Aura OS diagnostics

## Current capability

The base Debian userspace includes `aura-diagnose`, a read-only diagnostic
bundle generator intended for support requests and local troubleshooting.

Run:

```sh
sudo aura-diagnose
```

The default output is a timestamped archive under `/var/tmp`. Select an
explicit destination with:

```sh
sudo aura-diagnose --output /var/tmp/aura-report.tar.gz
```

The command refuses to overwrite an existing file. The report is created with
owner-only permissions. The archive contains individual text files and a
`README.txt` index.

## Collected information

The default report collects:

- OS release, hostname, kernel version, uptime, and memory summary
- systemd overall state, failed units, core network/time service state, and
  boot-time summary
- block-device layout and filesystem identifiers, mounted filesystems, and
  disk-space usage
- the Aura installation manifest when one exists
- interface addresses, routes, resolver state, and networkd link state

Commands that are missing or return a non-zero exit status are recorded in the
report; they do not stop collection of the remaining sections.

The tool does not read password databases, shell history, environment
variables, or user document contents. It does not restart services, install
packages, repair filesystems, edit configuration, or write to block devices.

## Journal collection and privacy

Journal collection is deliberately disabled by default. Enable it only when
needed:

```sh
sudo aura-diagnose --include-journal
```

The optional section contains up to 200 warning-or-higher priority entries
from the current boot. Logs can contain usernames, IP addresses, application
details, or other private information.

Even without the journal, the archive can contain hostnames, IP and interface
information, disk models, filesystem UUIDs, and mount points. Review the
archive before sharing it publicly or attaching it to a support request.

## Scope and limitations

This is an information-gathering tool, not a repair utility or a replacement
for a bootable recovery environment. It requires a running Aura OS userspace
and the existing Debian base commands (systemd, util-linux, iproute2, tar, and
gzip). It is architecture-independent and does not require Python.

Aura OS also has separate installed-system Recovery Mode and installer-media
Offline Rescue workflows. The base `aura-diagnose` command only collects from
a running userspace; it does not run in the installer environment.

When the installed system cannot boot, enter **Offline Rescue** from the
installer ISO and run:

```sh
sh /usr/lib/aura/installer/diagnose.sh
```

This offline collector inspects one selected, already-mounted `AURA_ROOTFS`
filesystem. It requires ext4 and a verified read-only mount, does not chroot,
and never executes programs from the installed system. It records static OS,
package, fstab, boot, and systemd enablement metadata alongside the rescue
environment's block-device inventory. Journal contents are excluded unless
`--include-journal` is explicitly supplied.

The owner-only `.tar.gz` report and `.sha256` file are written to the
installer's verified `/run` tmpfs, never to the installed root filesystem.
They are lost when the rescue environment shuts down. Review the report's
privacy notice before copying it to separate media or sharing it. Backup,
restore, and any future repair operations retain their own independent safety
checks and confirmation requirements.
