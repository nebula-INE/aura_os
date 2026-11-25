from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallerContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_installer_never_selects_a_target_automatically(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("Select the target disk number:", installer)
        self.assertIn('ERASE $TARGET_DISK', installer)
        self.assertIn('INSTALL AURA', installer)
        self.assertIn("MEDIA_ANCESTRY", installer)
        self.assertIn("zram*|loop*|ram*|nbd*|fd*", installer)
        self.assertIn("mounted filesystem", installer)
        self.assertIn("4294967296", installer)
        self.assertIn('lsblk --list --noheadings --paths --output MOUNTPOINTS "$disk"', installer)
        self.assertIn("sha256sum --check --status", installer)
        self.assertIn("/holders/", installer)
        self.assertIn("TARGET_DEVICE_ID", installer)
        self.assertIn("immediately before the first disk write", installer)

    def test_installer_creates_gpt_esp_and_ext4_root(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("label: gpt", installer)
        self.assertIn(",512M,U", installer)
        self.assertIn("mkfs.fat -F 32 -n AURA_EFI", installer)
        self.assertIn("mkfs.ext4 -F -m 0 -L AURA_ROOTFS", installer)

    def test_installer_writes_uuid_fstab_and_grub_fallback(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("UUID=$ROOT_UUID / ext4", installer)
        self.assertIn("UUID=$ESP_UUID /boot/efi vfat", installer)
        self.assertIn("--no-nvram", installer)
        self.assertIn("--removable", installer)
        self.assertIn("root=UUID=$ROOT_UUID aura.rootfs=1", installer)
        for loader in ("BOOTX64.EFI", "BOOTAA64.EFI", "BOOTRISCV64.EFI"):
            self.assertIn(loader, installer)

    def test_installer_adds_a_separate_authenticated_recovery_entry(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("menuentry 'Aura OS (Recovery Mode)'", installer)
        self.assertIn("systemd.unit=aura-recovery.target", installer)
        self.assertIn("root=UUID=$ROOT_UUID aura.rootfs=1", installer)
        self.assertEqual(installer.count("${GRUB_INITRD_LINE}"), 2)
        self.assertIn("aura-recovery.target", installer)

    def test_installer_rootfs_archive_is_separate_from_live_initramfs(self) -> None:
        builder = self.read("scripts/build-installer-initramfs.sh")
        self.assertIn("BASE_ARCHIVE=", builder)
        self.assertIn('"$ROOTFS_DIR/init"', builder)
        iso_builder = self.read("scripts/build-uefi-iso.sh")
        self.assertIn('$STAGING_DIR/rootfs/aura-base-$TARGET_ARCH.tar.gz', iso_builder)
        self.assertIn('boot/vmlinuz-$TARGET_ARCH', iso_builder)
        self.assertIn('boot/initramfs-$TARGET_ARCH.cpio.gz', iso_builder)
        self.assertIn('initramfs-$TARGET_ARCH.cpio.gz.sha256', iso_builder)
        self.assertIn('aura-base-$TARGET_ARCH.tar.gz.sha256', iso_builder)

    def test_build_uses_architecture_matched_grub_modules(self) -> None:
        builder = self.read("scripts/build-base-rootfs.sh")
        self.assertIn("grub-efi-amd64-bin", builder)
        self.assertIn("grub-efi-arm64-bin", builder)
        self.assertIn("grub-efi-riscv64-bin", builder)
        self.assertIn("dosfstools", builder)
        self.assertIn("fdisk", builder)
        self.assertIn("grub2-common", builder)

    def test_kernel_has_installer_media_and_gpt_support(self) -> None:
        for relative in (
            "kernel/configs/x86_64_qemu.fragment",
            "kernel/configs/aarch64_qemu.fragment",
            "kernel/configs/riscv64_qemu.fragment",
        ):
            config = self.read(relative)
            self.assertIn("CONFIG_ISO9660_FS=y", config)
            self.assertIn("CONFIG_VFAT_FS=y", config)
            self.assertIn("CONFIG_EFI_PARTITION=y", config)
            self.assertIn("CONFIG_NLS=y", config)
            self.assertIn("CONFIG_NLS_CODEPAGE_437=y", config)
            self.assertIn("CONFIG_NLS_ISO8859_1=y", config)

        builder = self.read("scripts/build-kernel.sh")
        for option in ("CONFIG_NLS", "CONFIG_NLS_CODEPAGE_437", "CONFIG_NLS_ISO8859_1"):
            self.assertIn(option, builder)

    def test_qemu_install_test_checks_the_installed_uuid_and_efi_loader(self) -> None:
        qemu_test = self.read("scripts/test-installer-qemu.py")
        self.assertIn("AURA_ROOT_UUID_FSTAB_ESP_OK", qemu_test)
        self.assertIn("findmnt -n -o UUID /", qemu_test)
        self.assertIn("findmnt -n -o UUID /boot/efi", qemu_test)
        self.assertIn("/boot/efi/$loader", qemu_test)
        self.assertIn("Kernel panic", qemu_test)
        self.assertIn('initramfs_mode = "embedded-in-kernel"', qemu_test)
        self.assertIn('initramfs_mode={initramfs_mode}', qemu_test)
        self.assertIn("grub_initrd_check", qemu_test)
        self.assertIn("pexpect.EOF", qemu_test)

    def test_installed_kernel_uses_architecture_appropriate_initramfs(self) -> None:
        builder = self.read("scripts/build-installed-kernel.sh")
        self.assertIn("EMBED_INITRAMFS=0", builder)
        self.assertIn("EMBED_INITRAMFS=1", builder)
        self.assertIn('INITRAMFS_ROOTFS="$ROOT_DIR/build/initramfs/rootfs"', builder)
        self.assertIn('--set-str INITRAMFS_SOURCE "$INITRAMFS_ROOTFS"', builder)
        self.assertIn("--enable INITRAMFS_COMPRESSION_GZIP", builder)
        self.assertIn('--set-str INITRAMFS_SOURCE ""', builder)
        self.assertIn("--disable CMDLINE_OVERRIDE", builder)
        self.assertIn("--disable CMDLINE_FORCE", builder)
        self.assertIn('BASE_OUT_DIR="$ROOT_DIR/build/kernel"', builder)
        self.assertIn('OUT_DIR="$ROOT_DIR/build/kernel-installed-build/$TARGET_ARCH"', builder)
        self.assertIn('cp "$BASE_OUT_DIR/.config" "$OUT_DIR/.config"', builder)

        installer = self.read("system/base/installer/install.sh")
        riscv_case = installer.split("    riscv64)", 1)[1].split(";;", 1)[0]
        self.assertIn('GRUB_INITRD_LINE=""', riscv_case)
        self.assertIn("${GRUB_INITRD_LINE}", installer)
        self.assertIn('GRUB_INITRD_LINE="initrd /boot/aura-initramfs.cpio.gz"', installer)
        self.assertIn("initramfs_mode=embedded-in-kernel", installer)
        self.assertIn("initramfs_mode=external", installer)



if __name__ == "__main__":
    unittest.main()
