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

## AArch64 UEFI boot (separate EFI-stub validation)

The direct QEMU Linux loader test remains in place. A second path validates the AArch64 UEFI handoff using the Linux kernel's EFI stub rather than a separately installed GRUB binary.

On Ubuntu 24.04, install the AArch64 UEFI firmware and image tools:

~~~sh
sudo apt-get install -y qemu-efi-aarch64 mtools parted file
~~~

The workflow first builds the target-native static initramfs, then runs:

~~~sh
bash scripts/build-kernel-aarch64-uefi.sh
bash scripts/test-kernel-qemu-aarch64-uefi.sh
~~~

The EFI-specific kernel is built in a separate output tree so the ordinary AArch64 `Image` used by direct boot is preserved. The builder takes the already-built AArch64 kernel configuration, enables the EFI stub, embeds the target-native initramfs directory into the kernel, and forces the serial-console/test command line. The resulting PE/COFF AArch64 kernel is placed at the removable-media fallback path `EFI/BOOT/BOOTAA64.EFI` on a GPT/FAT32 EFI System Partition.

The test first validates the embedded EFI structure with `scripts/verify_aarch64_efi_image.py`. This parses the Linux ARM64 boot header and checks the PE/COFF signature, ARM64 machine type, PE32+ optional header, and EFI Application subsystem; it does not rely on the generic `file` output, which may identify the binary only as a Linux ARM64 Image. The test then boots that image through the AAVMF firmware pair `AAVMF_CODE.fd` and a disposable copy of `AAVMF_VARS.fd` on QEMU `virt` with a fixed `cortex-a57` CPU and TCG. It records firmware and image hashes, captures the serial log, rejects kernel panics, and requires both Aura success markers.

This test exercises UEFI firmware → AArch64 Linux EFI stub → embedded initramfs `/init`. It is still an emulator reference profile only; it does not establish physical-device compatibility, Secure Boot trust policy, an installer, or a complete bootable system image. The UEFI-specific build and boot must pass in CI before this profile is considered verified.

## Versioned installed-kernel Debian packages

After building the persistent-root initramfs and the GRUB-loaded installed
kernel for a target architecture, run:

~~~sh
TARGET_ARCH=x86_64 bash scripts/build-kernel.sh
TARGET_ARCH=x86_64 bash scripts/build-initramfs-target.sh
TARGET_ARCH=x86_64 bash scripts/build-installed-kernel.sh
TARGET_ARCH=x86_64 bash scripts/build-kernel-package.sh
~~~

Repeat with aarch64 or riscv64 for the other targets. The installed-kernel
builder records the exact output of make kernelrelease; the package builder
uses that release to create an architecture-native
aura-kernel-image-<release> package and the architecture-independent
aura-kernel lifecycle package. The first package carries versioned /boot
files and a matched external initramfs where applicable. If the kernel
configuration enables loadable modules, the same package also carries the
matching /lib/modules/<release> tree and generated modules.dep index. RV64GC
retains its embedded initramfs design.

The lifecycle package generates versioned GRUB normal and Recovery Mode
entries, keeps the previous known-good kernel as the saved default during a
candidate update, and asks GRUB to try the candidate for one boot. The boot
confirmation service changes the saved default only when the running
uname -r matches the pending release. Kernel package removal hooks protect
the pending, known-good, and last installed images.

The installer ISO builder includes both .deb files in the signed payload
manifest and the installer installs them through dpkg. A signed APT
repository is not published yet, so this package foundation does not mean
that apt upgrade can already download Aura kernel updates. See ADR 0016.

## Scope

This repository now includes the installable ISO flow and an initial versioned kernel .deb lifecycle. Signed APT repository publication, failed-boot QEMU injection, Secure Boot, physical-board validation, and a complete Aura userspace remain unfinished. Do not install this development kernel on the host machine.
