# Linux kernel integration

Aura OS uses the upstream Linux kernel. Kernel source is fetched at build time and is not vendored into this repository.

## Pinned bring-up baseline

- Version: 6.18.64 (stable series)
- Git tag: v6.18.64 in the official Linux stable repository
- Repository: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
- Tag signer: Greg Kroah-Hartman (gregkh@kernel.org)
- Pinned signer fingerprint: 647F28654894E3BD457199BE38DBBDC86092693E
- Initial architecture: x86-64
- Initial target: QEMU q35
- Configuration: kernel/configs/x86_64_qemu.fragment

The version is a reproducible bring-up baseline, not a promise to stay on this patch release. Security updates must be reviewed and the pin advanced deliberately. Check supported stable releases at https://www.kernel.org/.

## Source verification

The build does not trust a downloaded archive or an unverified moving branch. It fetches the exact v6.18.64 Git tag from the official stable repository and verifies the annotated tag signature before compiling.

The build imports gregkh@kernel.org through the kernel.org OpenPGP Web Key Directory (WKD), checks that the imported key contains the pinned full fingerprint, runs git verify-tag, and requires the VALIDSIG fingerprint to match. A missing key, unexpected key fingerprint, unsigned tag, invalid signature, or signer mismatch stops the build.

The pinned fingerprint is published on https://www.kernel.org/signature.html. Review that page and the key's trust/revocation status when updating the kernel pin. Git tag verification follows the kernel maintainer PGP guidance: https://www.kernel.org/doc/html/latest/process/maintainer-pgp-guide.html.

## Build the kernel

On Debian/Ubuntu, install the build and verification dependencies:

~~~sh
sudo apt-get update
sudo apt-get install -y build-essential bc bison flex libelf-dev libssl-dev libncurses-dev git gnupg
~~~

Then run:

~~~sh
bash scripts/build-kernel.sh
~~~

The script verifies the signed source tag, creates an x86-64 QEMU configuration based on x86_64_defconfig, and builds arch/x86/boot/bzImage. Kernel outputs and a source-verification record are written to build/kernel/.

For faster local iteration, set JOBS (for example, JOBS=4 bash scripts/build-kernel.sh). The default is the number of available processors.

## Build the minimal initramfs

Install a static BusyBox and archive tools:

~~~sh
sudo apt-get install -y busybox-static cpio gzip
~~~

Then run:

~~~sh
bash scripts/build-initramfs.sh
~~~

The builder rejects a dynamically linked BusyBox so the initramfs does not silently depend on host libraries. It creates a small root filesystem with /init, devtmpfs, procfs, sysfs, a BusyBox shell, and a CI-only clean poweroff path. The compressed archive and SHA-256 file are written to build/initramfs/.

## Boot test in QEMU

Install QEMU's x86 system emulator:

~~~sh
sudo apt-get install -y qemu-system-x86
~~~

Run:

~~~sh
bash scripts/test-kernel-qemu.sh
~~~

The smoke test boots the actual kernel and initramfs using QEMU q35 with TCG, captures serial output, and requires both AURA_INIT_OK and AURA_QEMU_TEST_PASS before accepting the guest poweroff. The serial log is saved under build/qemu/.

## CI

The Linux kernel workflow verifies the upstream signature, builds the kernel and initramfs, boots them in QEMU, and uploads the kernel, config, source verification record, initramfs, checksums, and serial log as a short-lived artifact.

## Scope

This is the first bootable kernel bring-up path only. It does not yet create a bootable disk image, installer, package system, or complete Aura userspace. Do not install this development kernel on the host machine.
