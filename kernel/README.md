# Linux kernel integration

Aura OS uses the upstream Linux kernel. The kernel source is fetched during the build and is not vendored into this repository.

## Pinned bring-up baseline

- Version: `6.18.64` (longterm series)
- Source: `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.64.tar.xz`
- Initial architecture: x86-64
- Initial target: QEMU `q35`
- Configuration: `kernel/configs/x86_64_qemu.fragment`

The version is a reproducible bring-up baseline, not a promise to stay on this patch release. Security updates must be reviewed and the pin advanced deliberately. Check the current supported longterm releases at [kernel.org](https://www.kernel.org/).

## Build

On Debian/Ubuntu, install the build dependencies:

```sh
sudo apt-get update
sudo apt-get install -y build-essential bc bison flex libelf-dev libssl-dev libncurses-dev
```

Then run:

```sh
bash scripts/build-kernel.sh
```

The script downloads the pinned upstream source, creates an x86-64 QEMU configuration based on `x86_64_defconfig`, and builds `arch/x86/boot/bzImage`. Outputs are written to `build/kernel/`.

For a faster local iteration, set `JOBS` (for example, `JOBS=4 bash scripts/build-kernel.sh`). The default is the number of available processors.

## Source authenticity

The upstream release provides detached OpenPGP signatures alongside release tarballs. Before using a downloaded source archive for a release build, verify its `.tar.sign` file against a trusted Linux stable maintainer key obtained and validated independently. The initial convenience build script does not establish maintainer-key trust automatically; CI build success is not a substitute for signature verification.

## Scope

This is the first kernel build integration only. It does not yet create an initramfs, bootable disk image, installer, or a complete Aura userspace. Those are subsequent milestones. Do not install this development kernel on the host machine.
