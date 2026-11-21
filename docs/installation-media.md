# Aura OS bootable ISO prototype

Aura OS publishes architecture-specific UEFI ISO prototypes through the **Aura multi-architecture UEFI ISO boot** GitHub Actions workflow.

## Current scope

These are real ISO9660 images with a UEFI El Torito boot catalog and a FAT32 EFI System Partition:

| Architecture | ISO filename | UEFI fallback loader | QEMU firmware |
|---|---|---|---|
| x86-64 | aura-os-x86_64-uefi.iso | EFI/BOOT/BOOTX64.EFI | OVMF |
| AArch64 | aura-os-aarch64-uefi.iso | EFI/BOOT/BOOTAA64.EFI | AAVMF |
| RV64GC | aura-os-riscv64-uefi.iso | EFI/BOOT/BOOTRISCV64.EFI | EDK2 RISC-V via QEMU virt firmware |

The workflow builds an EFI-stub Linux kernel with a target-native initramfs embedded, assembles the ISO, then boots it as virtual CD-ROM media under the matching UEFI firmware. A successful prototype boot emits AURA_INIT_OK and AURA_QEMU_TEST_PASS before powering off.

**Important:** the current images are boot-validation prototypes, not installation ISOs. They do not show an installer, write to a target disk, install a root filesystem, create a user, or launch a desktop. Do not use them to install Aura OS on a PC.

## Download

1. Open the repository's Actions tab.
2. Select **Aura multi-architecture UEFI ISO boot**.
3. Open a successful run and download the matching artifact:
   - aura-os-uefi-iso-x86_64
   - aura-os-uefi-iso-aarch64
   - aura-os-uefi-iso-riscv64
4. Extract the ZIP downloaded by GitHub Actions; it contains the actual .iso, its .sha256 checksum, JSON provenance, and boot logs.

GitHub wraps Actions artifacts in a ZIP for download. The ISO inside that ZIP is the bootable optical-disc image; the ZIP itself is not an ISO.

## Build locally

On an Ubuntu 24.04 or Linux Mint host, install the native and cross toolchains, QEMU firmware, and image tools:

~~~
sudo apt update
sudo apt install -y \
  build-essential bc bison flex libelf-dev libssl-dev libncurses-dev \
  git gnupg curl cpio gzip binutils file mtools xorriso \
  qemu-system-x86 ovmf \
  qemu-system-arm qemu-efi-aarch64 gcc-aarch64-linux-gnu \
  qemu-system-misc opensbi qemu-efi-riscv64 gcc-riscv64-linux-gnu
~~~

Build one architecture after checking out the repository:

~~~
TARGET_ARCH=x86_64 bash scripts/build-kernel.sh
TARGET_ARCH=x86_64 bash scripts/build-initramfs-target.sh
TARGET_ARCH=x86_64 bash scripts/build-kernel-efi-iso.sh
TARGET_ARCH=x86_64 bash scripts/build-uefi-iso.sh
~~~

Change TARGET_ARCH to aarch64 or riscv64 for the other images. Kernel compilation is resource intensive. The ISO is written to build/iso/aura-os-<architecture>-uefi.iso.

To boot the ISO in the matching QEMU firmware profile:

~~~
TARGET_ARCH=x86_64 bash scripts/test-uefi-iso-qemu.sh
~~~

The QEMU validation script is intended for CI diagnostics and exits after the initramfs powers off.

## Next milestone

Issue #12 tracks the installer runtime, GPT partition layout, installation to a disposable target disk, and post-install boot verification. Those features must pass independently before these images are called install media.
