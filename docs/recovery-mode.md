# Aura OS installed-system Recovery Mode

## Entering Recovery Mode

1. Restart the installed system.
2. In the GRUB menu, select **Aura OS (Recovery Mode)**.
3. Sign in with the local administrator account created during first boot.

Recovery Mode is selected by the boot argument
`systemd.unit=aura-recovery.target`. The normal **Aura OS** menu entry remains
the default.

On a device that has not completed first boot, the existing local-console
first-user wizard runs before the login prompt. The root account remains
password-locked. Recovery Mode does not enable automatic login or a shared
recovery password.

## What starts

Recovery Mode starts the essential systemd base, device enumeration,
`systemd-user-sessions.service`, and the local console getty. It deliberately
does not activate the normal `multi-user.target`, wired networking services,
or the normal multi-user service set. This reduces the number of running
components while the administrator investigates a boot or service problem.

Useful read-only checks include:

~~~sh
systemctl --failed
journalctl -b -p warning
findmnt
lsblk -f
ip address
~~~

The installed system's GRUB entry, kernel, and root UUID are the same as the
normal boot path. The installer creates the Recovery menu entry for x86-64,
AArch64, and RV64GC; each architecture retains its existing external or
embedded initramfs handoff.

## Scope and safety boundary

This is an **installed-system recovery target**, not an offline rescue image.
The installed root filesystem is still mounted using its normal filesystem
configuration. The target does not run filesystem repair, rewrite the
bootloader, change account credentials, or modify system configuration
automatically. Administrators must deliberately run any privileged command.

This mode can help when the installed Debian userspace can still mount and
start systemd but normal services interfere with troubleshooting. It cannot
recover a missing or corrupt root filesystem, a broken initramfs, or a kernel
that cannot boot. For those cases, Aura OS still needs a separate bootable
offline rescue environment.

There is no auto-login and no default root password. Physical access to the
GRUB menu is not treated as an authentication boundary; local account
authentication is still required before an interactive shell is available.
