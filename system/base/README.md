# Aura OS base userspace bootstrap

This directory defines the first common userspace package set for Aura OS.
It is deliberately not the final desktop installation.

- Base distribution: Debian 13 (trixie)
- Architectures: x86-64 (`amd64`), AArch64 (`arm64`), RISC-V 64 (`riscv64`)
- Bootstrap: `mmdebstrap --variant=minbase`
- Init/service manager: systemd via `systemd-sysv`
- Package format and manager: Debian packages with apt/dpkg
- Default desktop: none
- Root credentials: the root account remains locked; on normal first boot, a local-console wizard creates one administrator in the `sudo` group and securely prompts for that account's password. No shared/default password is configured.

## Build one architecture

On Debian or Ubuntu, install the bootstrap and foreign-architecture emulation tools:

~~~sh
sudo apt-get update
sudo apt-get install -y mmdebstrap qemu-user-static binfmt-support curl gnupg
sudo systemctl restart systemd-binfmt.service
# Confirm both foreign architectures use a chroot-safe (F / fix-binary) handler.
grep -E '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64
grep -E '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-riscv64
sudo bash scripts/prepare-debian-trixie-keyring.sh
~~~

Build an architecture-specific root filesystem:

~~~sh
sudo env TARGET_ARCH=x86_64 bash scripts/build-base-rootfs.sh
sudo env TARGET_ARCH=aarch64 bash scripts/build-base-rootfs.sh
sudo env TARGET_ARCH=riscv64 bash scripts/build-base-rootfs.sh
~~~

The helper fetches the three Trixie signing keys from Debian's official FTP master. It verifies the published SHA-256 digests for the archive and security keys, checks all three primary-key fingerprints, and writes a dedicated keyring for mmdebstrap. The target root filesystem also installs debian-archive-keyring so apt can authenticate updates after first boot.

Foreign-architecture builds require working QEMU user-mode binfmt support. `mmdebstrap` uses it to run maintainer scripts for the target architecture.

The output is written to `build/base-userspace/<target>/` and includes:

- `rootfs/` — unpacked target root filesystem
- `aura-base-<target>.tar.gz` — root filesystem archive
- `aura-base-<target>.tar.gz.sha256` — archive checksum
- `packages.tsv` — installed package names, versions, and Debian architectures
- `build-provenance.txt` — selected suite, architecture mapping, package-management and init policy

## Persistent-root QEMU integration

The repository adds an automated integration workflow, `.github/workflows/base-rootfs-qemu.yml`, that builds the pinned Linux kernel and a static initramfs, places the generated Debian rootfs on a raw ext4 disk image, and boots it under QEMU for each architecture.

The test kernel command line includes `aura.rootfs=1`. In this mode, the PID 1 initramfs program mounts `/dev/vda`, moves `/dev`, `/proc`, and `/sys` into the new root, uses the classic `switch_root` overmount/chroot sequence, and executes `/sbin/init`. The Debian rootfs contains a first-boot account setup service and a one-shot systemd test service. The QEMU smoke command line includes `aura.firstboot.skip`, which bypasses the interactive account wizard only for automation; the test service writes `AURA_SYSTEMD_ROOTFS_OK` and `AURA_ROOTFS_QEMU_PASS` to the serial console before requesting poweroff. The older initramfs-only kernel and UEFI smoke tests remain on their original path when `aura.rootfs=1` is absent.

Run the integration workflow from a pull request or GitHub Actions after the base userspace is available. Its artifact includes the kernel, initramfs, ext4 image, serial log, and checksums. Passing this QEMU path demonstrates boot into the Debian userspace under the emulator profile; it does not yet establish a login-ready, installable, or hardware-supported OS.

## Scope and safety

The image is a build artifact, not an installer or a complete bootable disk. A normal boot can create one local console administrator; it does not install a desktop session, display manager, network manager, firmware bundle, bootloader, or application set. The test-only `aura.firstboot.skip` argument bypasses this prompt. Do not install it over a host filesystem.

The package manifest is intentionally small. Add components only with a reason and validate their availability on all three Debian architectures. The 512 MiB idle desktop RAM target is a stretch goal, not a current measurement or promise; systemd and glibc memory costs must be measured on representative hardware before the service and desktop set is finalized.
