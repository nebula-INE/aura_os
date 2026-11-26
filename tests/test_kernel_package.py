from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts/build-kernel-package.sh"
GRUB_GENERATOR = ROOT / "system/base/kernel/update-grub-menu"
KERNEL_VERSION = "6.18.64"


class KernelPackageBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "packages"
        self.kernel = self.root / "vmlinuz"
        self.initramfs = self.root / "initramfs.cpio.gz"
        self.modules_root = self.root / "modules-root"
        self.modules_tree = self.modules_root / "lib/modules" / KERNEL_VERSION
        self.modules_tree.mkdir(parents=True)
        (self.modules_tree / "kernel/test-driver.ko").parent.mkdir(parents=True)
        (self.modules_tree / "kernel/test-driver.ko").write_bytes(b"test module")
        (self.modules_tree / "modules.dep").write_text(
            "kernel/test-driver.ko:\n", encoding="ascii"
        )
        self.modules_enabled = self.root / "modules-enabled"
        self.modules_enabled.write_text("1\n", encoding="ascii")
        self.kernel.write_bytes(b"test kernel image")
        self.initramfs.write_bytes(b"test persistent root initramfs")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def build(self, architecture: str) -> tuple[Path, Path]:
        env = os.environ.copy()
        env.update(
            {
                "TARGET_ARCH": architecture,
                "KERNEL_IMAGE": str(self.kernel),
                "INITRAMFS_IMAGE": str(self.initramfs),
                "OUTPUT_DIR": str(self.output),
                "KERNEL_RELEASE": KERNEL_VERSION,
                "MODULES_ROOT": str(self.modules_root),
                "MODULES_ENABLED_FILE": str(self.modules_enabled),
            }
        )
        subprocess.run(
            ["bash", str(BUILDER)],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return (
            self.output / f"aura-kernel-image-{architecture}.deb",
            self.output / f"aura-kernel-{architecture}.deb",
        )

    def test_package_omits_modules_when_kernel_config_disables_them(self) -> None:
        self.modules_enabled.write_text("0\n", encoding="ascii")
        image, _meta = self.build("x86_64")
        extracted = self.root / "extract-no-modules"
        extracted.mkdir()
        subprocess.run(
            ["dpkg-deb", "--extract", str(image), str(extracted)],
            check=True,
            capture_output=True,
            timeout=15,
        )
        config = (
            extracted
            / "usr/share/aura-kernel"
            / f"{KERNEL_VERSION}.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("AURA_KERNEL_MODULES=0", config)
        self.assertFalse((extracted / "lib/modules").exists())

    def field(self, package: Path, name: str) -> str:
        return subprocess.run(
            ["dpkg-deb", "-f", str(package), name],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout.strip()

    def test_builds_native_image_package_and_architecture_independent_meta_package(self) -> None:
        expected = {
            "x86_64": "amd64",
            "aarch64": "arm64",
            "riscv64": "riscv64",
        }
        for architecture, deb_arch in expected.items():
            with self.subTest(architecture=architecture):
                image, meta = self.build(architecture)
                self.assertTrue(image.is_file())
                self.assertTrue(meta.is_file())
                self.assertEqual(
                    self.field(image, "Package"),
                    f"aura-kernel-image-{KERNEL_VERSION}",
                )
                self.assertEqual(self.field(image, "Version"), f"{KERNEL_VERSION}+aura1")
                self.assertEqual(self.field(image, "Architecture"), deb_arch)
                self.assertEqual(self.field(image, "Depends"), "kmod")
                self.assertEqual(self.field(meta, "Package"), "aura-kernel")
                self.assertEqual(self.field(meta, "Architecture"), "all")
                self.assertIn(
                    f"aura-kernel-image-{KERNEL_VERSION} (= {KERNEL_VERSION}+aura1)",
                    self.field(meta, "Depends"),
                )

                extracted = self.root / f"extract-{architecture}"
                extracted.mkdir()
                subprocess.run(
                    ["dpkg-deb", "--extract", str(image), str(extracted)],
                    check=True,
                    capture_output=True,
                    timeout=15,
                )
                kernel_path = extracted / "boot" / f"vmlinuz-aura-{KERNEL_VERSION}"
                self.assertEqual(kernel_path.read_bytes(), self.kernel.read_bytes())
                config = (
                    extracted
                    / "usr/share/aura-kernel"
                    / f"{KERNEL_VERSION}.conf"
                ).read_text(encoding="utf-8")
                expected_mode = "embedded" if architecture == "riscv64" else "external"
                self.assertIn(f"AURA_KERNEL_ARCH={architecture}", config)
                self.assertIn(f"AURA_INITRAMFS_MODE={expected_mode}", config)
                self.assertIn("AURA_KERNEL_MODULES=1", config)
                module_path = (
                    extracted
                    / "lib/modules"
                    / KERNEL_VERSION
                    / "kernel/test-driver.ko"
                )
                self.assertEqual(module_path.read_bytes(), b"test module")
                self.assertTrue(
                    (
                        extracted
                        / "lib/modules"
                        / KERNEL_VERSION
                        / "modules.dep"
                    ).is_file()
                )
                initrd_path = (
                    extracted
                    / "boot"
                    / f"aura-initramfs-{KERNEL_VERSION}.cpio.gz"
                )
                self.assertEqual(initrd_path.is_file(), architecture != "riscv64")


class KernelGrubMenuTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "etc/aura-kernel").mkdir(parents=True)
        (self.root / "boot/grub").mkdir(parents=True)
        (self.root / "usr/share/aura-kernel").mkdir(parents=True)
        (self.root / "etc/fstab").write_text(
            "UUID=01234567-89ab-cdef-0123-456789abcdef / ext4 defaults 0 1\n",
            encoding="utf-8",
        )
        (self.root / "etc/aura-kernel/cmdline").write_text(
            "aura.rootfs=1 console=ttyS0,115200n8\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_generator(self) -> str:
        env = os.environ.copy()
        env["AURA_ROOT"] = str(self.root)
        subprocess.run(
            ["/bin/sh", str(GRUB_GENERATOR)],
            cwd=ROOT,
            env=env,
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
        return (self.root / "boot/grub/grub.cfg").read_text(encoding="utf-8")

    def test_external_kernel_versions_keep_normal_and_recovery_entries(self) -> None:
        (self.root / "etc/aura-kernel/architecture").write_text("x86_64\n", encoding="ascii")
        for version in ("6.18.64", "6.18.63", "6.18.64-custom1"):
            (self.root / "boot" / f"vmlinuz-aura-{version}").write_bytes(b"kernel")
            (self.root / "boot" / f"aura-initramfs-{version}.cpio.gz").write_bytes(b"initrd")
            (self.root / "usr/share/aura-kernel" / f"{version}.conf").write_text(
                "AURA_KERNEL_ARCH=x86_64\nAURA_INITRAMFS_MODE=external\nAURA_KERNEL_MODULES=0\n",
                encoding="ascii",
            )
        config = self.run_generator()
        self.assertIn('set default="${saved_entry}"', config)
        self.assertIn('if [ -n "$next_entry" ]', config)
        self.assertIn("save_env next_entry", config)
        self.assertIn("root=UUID=01234567-89ab-cdef-0123-456789abcdef", config)
        self.assertIn("console=ttyS0,115200n8", config)
        self.assertIn("--id 'aura-6.18.64'", config)
        self.assertIn("--id 'aura-6.18.63'", config)
        self.assertIn("--id 'aura-6.18.64-custom1'", config)
        self.assertIn("Aura OS (6.18.64, Recovery Mode)", config)
        self.assertIn("systemd.unit=aura-recovery.target", config)
        self.assertIn("initrd /boot/aura-initramfs-6.18.64.cpio.gz", config)
        self.assertIn("initrd /boot/aura-initramfs-6.18.63.cpio.gz", config)
        self.assertIn("initrd /boot/aura-initramfs-6.18.64-custom1.cpio.gz", config)

    def test_riscv_embedded_initramfs_does_not_emit_an_external_initrd(self) -> None:
        (self.root / "etc/aura-kernel/architecture").write_text("riscv64\n", encoding="ascii")
        (self.root / "boot/vmlinuz-aura-6.18.64").write_bytes(b"kernel")
        (self.root / "usr/share/aura-kernel/6.18.64.conf").write_text(
            "AURA_KERNEL_ARCH=riscv64\nAURA_INITRAMFS_MODE=embedded\nAURA_KERNEL_MODULES=0\n",
            encoding="ascii",
        )
        config = self.run_generator()
        self.assertIn("Aura OS (6.18.64)", config)
        self.assertIn("systemd.unit=aura-recovery.target", config)
        self.assertNotIn("initrd /boot/", config)


if __name__ == "__main__":
    unittest.main()
