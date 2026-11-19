# Aura OS first-boot account setup

The Debian base image deliberately ships without a usable root password and
without a pre-created human account. On a normal boot, systemd starts
`aura-firstboot.service` before the login gettys and runs
`/usr/lib/aura/aura-firstboot` on `/dev/console`. The wizard opens `/dev/console` directly for username input and prints each prompt to that same device, rather than relying on a shell prompt being routed through a service's stderr stream.

The setup flow:

1. Prompts locally for one username (lowercase letters, digits, underscore,
   and hyphen; 1–32 characters).
2. Creates a private home directory and a normal `/bin/bash` account.
3. Adds that first administrator to Debian's `sudo` group.
4. Invokes `passwd` interactively so the password is read by the password
   utility and is not passed on a command line or written to a configuration
   file.
5. Writes a root-owned, mode-0600 completion marker only after password setup
   succeeds. Subsequent boots skip the wizard.

The root account remains password-locked. No default password, automatic
login, remote account, or network-exposed setup endpoint is created. If power
is lost after account creation but before password setup succeeds, a
root-only pending marker lets the next boot resume password setup for that
same account rather than creating a second one.

The persistent-root QEMU smoke test adds `aura.firstboot.skip` to its kernel
command line. That test-only argument skips the interactive wizard so the
automated smoke service can verify systemd startup without a human at the
console. Normal boots do not include the argument and will run first-boot
setup. The QEMU integration image adds a test-only agetty on `/dev/console` because some emulator kernels expose the console device without creating the matching `/dev/ttyS0` node expected by the generated serial-getty unit. This extra getty is not installed into normal rootfs images.
