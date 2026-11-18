# Linux kernel integration

Aura OS uses the upstream Linux kernel. Kernel source is fetched at build time and is not vendored into this repository.

## Pinned bring-up baseline

- Version: 6.18.64 (stable series)
- Git tag: v6.18.64 (signed release tag)
- Fetch mirror: https://github.com/gregkh/linux (read-only stable-tree mirror maintained by Greg Kroah-Hartman)
- Canonical upstream: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git
- Tag signer: Greg Kroah-Hartman (gregkh@kernel.org)
- Pinned signer fingerprint: 647F28654894E3BD457199BE38DBBDC86092693E
- Initial architecture: x86-64
- Initial target: QEMU q35
- Configuration: kernel/configs/x86_64_qemu.fragment

The version is a reproducible bring-up baseline, not a promise to stay on this patch release. Security updates must be reviewed and the pin advanced deliberately. Check supported stable releases at https://www.kernel.org/.

## Source verification

The build does not trust a downloaded archive or an unverified moving branch. To avoid depending on direct git.kernel.org connectivity in CI, it fetches the exact v6.18.64 tag from Greg Kroah-Hartman's read-only GitHub mirror. This mirror is used only as a transport source: the annotated release tag's OpenPGP signature is independently verified against the pinned stable maintainer key before any source is compiled. The same verification therefore rejects an unsigned or altered tag even when fetched from the mirror.

The build first tries gregkh@kernel.org through the kernel.org OpenPGP Web Key Directory (WKD). When WKD is unreachable, it retrieves the key by its 16-character key ID from the kernel.org-maintained PGP keyring, then falls back to keyserver.ubuntu.com. It checks that an imported key contains the pinned full fingerprint before running git verify-tag, and requires the tag's VALIDSIG fingerprint to match. A missing key, unexpected key fingerprint, unsigned tag, invalid signature, or signer mismatch stops the build.

The pinned fingerprint is published on https://www.kernel.org/signature.html. Review that page and the key's trust/revocation status when updating the kernel pin. Git tag verification follows the kernel maintainer PGP guidance: https://www.kernel.org/doc/html/latest/process/maintainer-pgp-guide.html.

## Build the kernel

On Debian/Ubuntu, install the build and verification dependencies:

~~~sh
sudo apt-get update
sudo apt-get install -y build-essential bc bison flex libelf-dev libssl-dev libncurses-dev git gnupg curl
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
sudo apt-get install -y qemu-system-x86 ovmf grub-efi-amd64-bin mtools parted
~~~

Run:

~~~sh
bash scripts/test-kernel-qemu.sh
~~~

The smoke test creates a GPT-partitioned FAT32 EFI system partition containing a standalone x86-64 GRUB loader, the kernel, and initramfs. It verifies the copied files with mtools, searches for `/vmlinuz` at GRUB startup to select the EFI partition as its root, then boots the image through OVMF UEFI on QEMU q35 using the fixed qemu64 CPU model and TCG. The test records the QEMU version, OVMF package version, firmware checksums, and ESP checksum in build/qemu/firmware-provenance.txt. It captures the serial log, rejects kernel panics, and requires both AURA_INIT_OK and AURA_QEMU_TEST_PASS before accepting guest poweroff. The serial log is saved under build/qemu/.

## CI

The Linux kernel workflow verifies the upstream signature, builds the kernel and initramfs, boots them in QEMU, and uploads the kernel, config, source verification record, initramfs, checksums, and serial log as a short-lived artifact.

## RV64GC and AArch64 QEMU bring-up (early validation)

The verified kernel builder also accepts the cross-architecture targets. Install the matching cross compiler and QEMU emulator on Debian/Ubuntu:

~~~sh
# RV64GC
sudo apt-get install -y gcc-riscv64-linux-gnu qemu-system-misc
TARGET_ARCH=riscv64 bash scripts/build-kernel.sh
TARGET_ARCH=riscv64 bash scripts/build-initramfs-target.sh
TARGET_ARCH=riscv64 bash scripts/test-kernel-qemu-multiarch.sh

# AArch64
sudo apt-get install -y gcc-aarch64-linux-gnu qemu-system-arm
TARGET_ARCH=aarch64 bash scripts/build-kernel.sh
TARGET_ARCH=aarch64 bash scripts/build-initramfs-target.sh
TARGET_ARCH=aarch64 bash scripts/test-kernel-qemu-multiarch.sh
~~~

Both paths use the same pinned and signature-verified Linux source. The kernel builder selects an architecture-specific defconfig fragment and cross compiler, then records the compiler, target, source revision, signer fingerprint, and image checksum under `build/kernel/`.

The multi-architecture initramfs compiles `initramfs/init.c` as a statically linked target-native ELF executable. It mounts devtmpfs, opens `/dev/console`, emits `AURA_INIT_OK` and `AURA_QEMU_TEST_PASS`, then requests a clean guest poweroff. This is a boot-test init only; it does not select Aura's eventual init/service manager.

Boot reference profiles:

- **RV64GC:** QEMU `virt`, `rv64` CPU, QEMU's default OpenSBI firmware, generated device tree, and 16550 serial console. The test uses `qemu-system-riscv64`.
- **AArch64:** QEMU `virt`, `cortex-a57` CPU, PL011 serial console, and QEMU's direct Linux `Image` loader. The current smoke test does not exercise UEFI or a physical board. The test uses `qemu-system-aarch64`.

The cross-architecture jobs run independently of the existing x86-64 OVMF/UEFI job. Passing them demonstrates kernel compilation and first userspace execution in the specified emulators only. It does not yet demonstrate an installable disk image, UEFI boot on AArch64, physical-board compatibility, a complete userspace, or usable desktop hardware.

## Scope

This is the first bootable kernel bring-up path only. It does not yet create a bootable disk image, installer, package system, or complete Aura userspace. Do not install this development kernel on the host machine.
