from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class InstallerContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_offline_backup_requires_separate_disk_and_preserves_source(self) -> None:
        backup = self.read("system/base/installer/backup.sh")
        builder = self.read("scripts/build-installer-initramfs.sh")
        qemu_test = self.read("scripts/test-installer-qemu.py")
        rescue = self.read("system/base/installer/rescue.sh")

        self.assertIn("findmnt", backup)
        self.assertIn('*,ro,*)', backup)
        self.assertIn("lsblk --inverse --list", backup)
        self.assertIn("DEST_DEVICE_ID", backup)
        self.assertIn("destination device identity changed during confirmation", backup)
        self.assertIn("destination now shares a physical disk with the source", backup)
        self.assertIn('case "$dest_label" in', backup)
        self.assertIn("TYPE=ext4", backup)
        self.assertIn("Type BACKUP TO %s to confirm", backup)
        self.assertIn("CREATE BACKUP", backup)
        self.assertIn("--create --gzip", backup)
        self.assertIn("sha256sum", backup)
        self.assertIn("repair_performed=no", backup)
        self.assertIn('mv "$TEMP_DIR" "$final_dir"', backup)
        self.assertIn("backup.sh", builder)
        self.assertIn("du df date sync mktemp", builder)
        self.assertIn("/usr/lib/aura/installer/backup.sh", rescue)
        self.assertIn("run_offline_rescue", qemu_test)
        self.assertIn("AURA_RESCUE_ESP_RO_OK", qemu_test)
        self.assertIn("AURA_BACKUP_COMPLETE", qemu_test)
        self.assertIn("aura-efi-", qemu_test)
        self.assertIn("mkfs.vfat", qemu_test)
        self.assertIn("debugfs", qemu_test)
        self.assertIn("source disk image", qemu_test)
        self.assertIn("EFI source disk image", qemu_test)
        self.assertIn("EXPECTED_ESP_UUID", backup)
        self.assertIn("EFI_ANCESTRY", backup)
        self.assertIn("source root or EFI partition", backup)
        self.assertIn("gzip", qemu_test)
        self.assertIn("sha256sum", qemu_test)


    def test_offline_restore_is_uuid_locked_verified_and_double_confirmed(self) -> None:
        restore = self.read("system/base/installer/restore.sh")
        builder = self.read("scripts/build-installer-initramfs.sh")
        rescue = self.read("system/base/installer/rescue.sh")
        qemu_test = self.read("scripts/test-installer-qemu.py")

        self.assertIn("ro,noload,nodev,nosuid,noexec", restore)
        self.assertIn("AURA_ROOTFS", restore)
        self.assertIn("AURA_EFI", restore)
        self.assertIn("source_uuid", restore)
        self.assertIn("cross-device relocation is not supported", restore)
        self.assertIn("sha256sum", restore)
        self.assertIn("gzip --test", restore)
        self.assertIn("RESTORE TO %s", restore)
        self.assertIn("RESTORE AURA", restore)
        self.assertIn(".aura-restore-stage", restore)
        self.assertIn("--extract --gzip", restore)
        self.assertIn("AURA_RESTORE_COMPLETE", restore)
        self.assertIn("could not recheck target root disk ancestry", restore)
        self.assertIn("could not recheck backup disk ancestry", restore)
        self.assertIn("--verify-only", restore)
        self.assertIn("AURA_BACKUP_VERIFY_COMPLETE", restore)
        self.assertIn("verify_only=True", qemu_test)
        self.assertIn("CANCEL RESTORE", qemu_test)
        self.assertIn("AURA_RESTORE_CANCELLED_OK", qemu_test)
        self.assertIn("--no-same-owner", restore)
        self.assertIn('chmod 1777 "$TARGET_MOUNT/tmp"', restore)
        self.assertIn("restore.sh", builder)
        self.assertIn("dirname find", builder)
        self.assertIn("/usr/lib/aura/installer/restore.sh", rescue)
        self.assertIn("run_offline_restore", qemu_test)
        self.assertIn("AURA-RESTORE-ROOT-CORRUPTED", qemu_test)
        self.assertIn("AURA-RESTORE-EFI-CORRUPTED", qemu_test)
        self.assertIn("mtype", qemu_test)

    def test_offline_rescue_is_explicit_and_read_only(self) -> None:
        installer_init = self.read("system/base/installer/init")
        rescue = self.read("system/base/installer/rescue.sh")
        builder = self.read("scripts/build-installer-initramfs.sh")
        qemu_test = self.read("scripts/test-installer-qemu.py")

        self.assertIn("Choose boot mode", installer_init)
        self.assertIn("r|R|rescue|RESCUE", installer_init)
        self.assertIn("/usr/lib/aura/installer/rescue.sh", installer_init)
        self.assertIn("verify-media.sh /run/aura-media", installer_init)
        self.assertLess(installer_init.index("verify-media.sh /run/aura-media"), installer_init.index("Choose boot mode"))

        self.assertIn("LABEL=AURA_ROOTFS", rescue)
        self.assertIn("ro,noload,nodev,nosuid,noexec", rescue)
        self.assertIn("LABEL=AURA_EFI", rescue)
        self.assertIn("ro,nodev,nosuid,noexec", rescue)
        self.assertIn("AURA_RESCUE_READY", rescue)
        self.assertIn("e2fsck -fn", rescue)
        self.assertIn("No filesystem repair", rescue)

        self.assertIn("system/base/installer/rescue.sh", builder)
        self.assertIn("findmnt e2fsck", builder)
        self.assertIn("run_offline_rescue", qemu_test)
        self.assertIn("AURA_RESCUE_READ_ONLY_OK", qemu_test)
        self.assertIn("offline rescue mode modified the source disk image", qemu_test)


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
        self.assertEqual(installer.count("verify-media.sh"), 1)
        self.assertNotIn("sha256sum --check", installer)
        verifier = self.read("system/base/installer/verify-media.sh")
        self.assertIn("openssl pkeyutl -verify", verifier)
        self.assertIn("sha256sum --check --strict", verifier)
        self.assertIn("/holders/", installer)
        self.assertIn("TARGET_DEVICE_ID", installer)
        self.assertIn("immediately before the first disk write", installer)

    def test_installer_creates_gpt_esp_and_ext4_root(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("label: gpt", installer)
        self.assertIn(",512M,U", installer)
        self.assertIn("mkfs.fat -F 32 -n AURA_EFI", installer)
        self.assertIn("mkfs.ext4 -F -m 1 -L AURA_ROOTFS", installer)
        disk_builder = self.read("scripts/build-base-rootfs-disk.sh")
        self.assertIn('mkfs.ext4 -F -m 1 -L AURA_ROOTFS "$OUTPUT_IMAGE"', disk_builder)

    def test_installer_writes_uuid_fstab_and_grub_fallback(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        self.assertIn("UUID=$ROOT_UUID / ext4 defaults,noatime,errors=remount-ro 0 1", installer)
        self.assertIn("UUID=$ESP_UUID /boot/efi vfat", installer)
        self.assertIn("--no-nvram", installer)
        self.assertIn("--removable", installer)
        self.assertIn('KERNEL_CMDLINE="aura.rootfs=1', installer)
        generator = self.read("system/base/kernel/update-grub-menu")
        self.assertIn("root=UUID=$ROOT_UUID", generator)
        for loader in ("BOOTX64.EFI", "BOOTAA64.EFI", "BOOTRISCV64.EFI"):
            self.assertIn(loader, installer)

    def test_installer_adds_a_separate_authenticated_recovery_entry(self) -> None:
        installer = self.read("system/base/installer/install.sh")
        generator = self.read("system/base/kernel/update-grub-menu")
        self.assertIn("systemd.unit=aura-recovery.target", generator)
        self.assertIn("Aura OS ($version, Recovery Mode)", generator)
        self.assertIn("aura-recovery.target", generator)
        self.assertNotIn("GRUB_INITRD_LINE", installer)
        self.assertIn("aura-kernel-image-$ARCH.deb", installer)
        self.assertIn("chroot \"$ROOT_MNT\" /usr/bin/dpkg -i", installer)

    def test_installer_rootfs_archive_is_separate_from_live_initramfs(self) -> None:
        builder = self.read("scripts/build-installer-initramfs.sh")
        self.assertIn("BASE_ARCHIVE=", builder)
        self.assertIn('"$ROOTFS_DIR/init"', builder)
        iso_builder = self.read("scripts/build-uefi-iso.sh")
        self.assertIn('$STAGING_DIR/rootfs/aura-base-$TARGET_ARCH.tar.gz', iso_builder)
        self.assertIn('boot/aura-kernel-image-$TARGET_ARCH.deb', iso_builder)
        self.assertIn('boot/aura-kernel-$TARGET_ARCH.deb', iso_builder)
        self.assertIn('aura-base-$TARGET_ARCH.tar.gz.sha256', iso_builder)
        self.assertIn("aura-payloads.sha256.sig", iso_builder)
        self.assertIn('"$OUTPUT_ISO.sha256.sig"', iso_builder)
        self.assertIn("AURA_RELEASE_PRIVATE_KEY_FILE", iso_builder)

    def test_qemu_smoke_path_requires_explicit_target(self) -> None:
        builder = self.read("scripts/build-base-rootfs-disk.sh")
        qemu = self.read("scripts/test-base-rootfs-qemu.sh")
        self.assertIn("aura-qemu-smoke.target", builder)
        self.assertIn("WantedBy=aura-qemu-smoke.target", builder)
        self.assertIn('aura-qemu-smoke.target.wants/aura-rootfs-smoke.service', builder)
        self.assertNotIn('multi-user.target.wants/aura-rootfs-smoke.service', builder)
        self.assertEqual(qemu.count("systemd.unit=aura-qemu-smoke.target"), 3)
        self.assertEqual(builder.count("multi-user.target.wants/aura-rootfs-smoke.service"), 0)

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
        installer = self.read("system/base/installer/install.sh")
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

        package_builder = self.read("scripts/build-kernel-package.sh")
        self.assertIn("INITRAMFS_MODE=external", package_builder)
        self.assertIn("INITRAMFS_MODE=embedded", package_builder)
        generator = self.read("system/base/kernel/update-grub-menu")
        self.assertIn("external)", generator)
        self.assertIn("embedded)", generator)
        self.assertIn("/boot/aura-initramfs-$version.cpio.gz", generator)
        self.assertIn("initramfs_mode=embedded-in-kernel", installer)
        self.assertIn("initramfs_mode=external", installer)
        self.assertIn("aura-kernel-confirm.service", package_builder)



if __name__ == "__main__":
    unittest.main()
