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


## Offline Rescue Mode

The installer ISO now offers a separate **Offline Rescue** choice before the
installer starts. Boot the matching Aura OS UEFI ISO and select **R** at the
boot-mode prompt. The rescue environment runs from the in-memory Debian 13
initramfs, so it does not depend on the installed root filesystem being
bootable.

The first rescue increment is inspection-only:

- Lists block devices, filesystem labels/UUIDs, and active mounts.
- Mounts every filesystem labelled **AURA_ROOTFS** as ext4 with
  **ro,noload,nodev,nosuid,noexec**. The **noload** option prevents ext4 journal
  replay during inspection.
- Mounts every filesystem labelled **AURA_EFI** read-only with
  **nodev,nosuid,noexec**.
- Does not run filesystem repair, rewrite GRUB, reset credentials, install
  packages, or modify installed configuration.
- Verifies and reports read-only mount options before exposing the shell.

Mounted root filesystems are available under
**/mnt/aura-rescue/root-1**, **root-2**, and so on. EFI partitions are available
under **/mnt/aura-rescue/esp-1**, **esp-2**, and so on. Useful inspection
commands include **lsblk -f**, **blkid**, **findmnt**, and
**e2fsck -fn /dev/DEVICE**. Run filesystem checks only on an unmounted device.
Rescue mode makes no automatic repairs; copy important data to a separate
backup device before attempting a future repair workflow.

This is an offline inspection environment, not yet a complete repair/rescue
product. Automatic repair, bootloader recreation, encryption recovery,
credential reset, backup tooling, and recovery from damaged media firmware
remain deferred. The installed-system **Recovery Mode** described above is a
different feature and still boots from the installed root filesystem.
