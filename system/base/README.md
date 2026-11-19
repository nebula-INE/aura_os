# Aura OS base userspace bootstrap

This directory defines the first common userspace package set for Aura OS.
It is deliberately not the final desktop installation.

- Base distribution: Debian 13 (trixie)
- Architectures: x86-64 (`amd64`), AArch64 (`arm64`), RISC-V 64 (`riscv64`)
- Bootstrap: `mmdebstrap --variant=minbase`
- Init/service manager: systemd via `systemd-sysv`
- Package format and manager: Debian packages with apt/dpkg
- Default desktop: none
- Root credentials: the root account remains locked; the bootstrap does not create a shared password or first user.

## Build one architecture

On Debian or Ubuntu, install the bootstrap and foreign-architecture emulation tools:

~~~sh
sudo apt-get update
sudo apt-get install -y mmdebstrap qemu-user qemu-user-binfmt binfmt-support
sudo systemctl restart systemd-binfmt.service
~~~

Build an architecture-specific root filesystem:

~~~sh
sudo env TARGET_ARCH=x86_64 bash scripts/build-base-rootfs.sh
sudo env TARGET_ARCH=aarch64 bash scripts/build-base-rootfs.sh
sudo env TARGET_ARCH=riscv64 bash scripts/build-base-rootfs.sh
~~~

Foreign-architecture builds require working QEMU user-mode binfmt support. `mmdebstrap` uses it to run maintainer scripts for the target architecture.

The output is written to `build/base-userspace/<target>/` and includes:

- `rootfs/` — unpacked target root filesystem
- `aura-base-<target>.tar.gz` — root filesystem archive
- `aura-base-<target>.tar.gz.sha256` — archive checksum
- `packages.tsv` — installed package names, versions, and Debian architectures
- `build-provenance.txt` — selected suite, architecture mapping, package-management and init policy

## Scope and safety

The image is a build artifact, not an installer or a complete bootable disk. No user account, password, desktop session, display manager, network manager, firmware bundle, bootloader, or application set is configured. Do not install it over a host filesystem.

The package manifest is intentionally small. Add components only with a reason and validate their availability on all three Debian architectures. The 512 MiB idle desktop RAM target is a stretch goal, not a current measurement or promise; systemd and glibc memory costs must be measured on representative hardware before the service and desktop set is finalized.
