from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts/build-kernel-apt-repository.sh"
VERSION = "6.18.64+aura1"
IMAGE_PACKAGE = "aura-kernel-image-6.18.64"


class SignedKernelAptRepositoryTests(unittest.TestCase):
    signing_passphrase = "aura-ci-repository-test-passphrase"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.packages = self.root / "input-packages"
        self.repository = self.root / "repository"
        self.packages.mkdir()
        self.gnupg = self.root / "gnupg"
        self.gnupg.mkdir(mode=0o700)

        subprocess.run(
            [
                "gpg",
                "--homedir",
                str(self.gnupg),
                "--batch",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                self.signing_passphrase,
                "--quick-generate-key",
                "Aura OS APT test <apt-test@example.invalid>",
                "ed25519",
                "sign",
                "1d",
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
        self.fingerprint = self._fingerprint(self.gnupg)
        self.private_key = self.root / "private.asc"
        self.public_key = self.root / "public.asc"
        self.private_key.write_bytes(
            subprocess.run(
                [
                    "gpg",
                    "--homedir",
                    str(self.gnupg),
                    "--batch",
                    "--pinentry-mode",
                    "loopback",
                    "--passphrase",
                    self.signing_passphrase,
                    "--armor",
                    "--export-secret-keys",
                    self.fingerprint,
                ],
                check=True,
                capture_output=True,
                timeout=15,
            ).stdout
        )
        self.public_key.write_bytes(
            subprocess.run(
                [
                    "gpg",
                    "--homedir",
                    str(self.gnupg),
                    "--batch",
                    "--armor",
                    "--export",
                    self.fingerprint,
                ],
                check=True,
                capture_output=True,
                timeout=15,
            ).stdout
        )
        for architecture in ("amd64", "arm64", "riscv64"):
            self._make_deb(
                IMAGE_PACKAGE,
                VERSION,
                architecture,
                "kmod",
                f"boot/vmlinuz-aura-6.18.64-{architecture}",
            )
            self._make_deb(
                "aura-kernel",
                VERSION,
                "all",
                f"{IMAGE_PACKAGE} (= {VERSION}), apt, grub2-common, systemd",
                f"usr/share/aura-kernel/repository-test-{architecture}",
            )

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _fingerprint(home: Path) -> str:
        output = subprocess.run(
            ["gpg", "--homedir", str(home), "--batch", "--with-colons", "--list-keys"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout
        for line in output.splitlines():
            fields = line.split(":")
            if fields[0] == "fpr":
                return fields[9].upper()
        raise AssertionError("GPG did not report a primary-key fingerprint")

    def _make_deb(
        self,
        package: str,
        version: str,
        architecture: str,
        depends: str,
        payload_path: str,
    ) -> None:
        root = self.root / f"stage-{package}-{architecture}-{payload_path.replace('/', '-')}"
        (root / "DEBIAN").mkdir(parents=True)
        (root / Path(payload_path).parent).mkdir(parents=True, exist_ok=True)
        (root / "DEBIAN/control").write_text(
            f"Package: {package}\n"
            f"Version: {version}\n"
            f"Architecture: {architecture}\n"
            "Maintainer: Aura OS test suite\n"
            f"Depends: {depends}\n"
            f"Description: Test package for {package}\n",
            encoding="utf-8",
        )
        (root / payload_path).write_text("test payload\n", encoding="utf-8")
        filename = f"{package}-{architecture}-{len(list(self.packages.glob('*.deb')))}.deb"
        subprocess.run(
            [
                "dpkg-deb",
                "--root-owner-group",
                "--build",
                str(root),
                str(self.packages / filename),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )

    def _build(self) -> None:
        env = os.environ.copy()
        env.update(
            {
                "AURA_APT_REPOSITORY_PRIVATE_KEY_FILE": str(self.private_key),
                "AURA_APT_REPOSITORY_PUBLIC_KEY_FILE": str(self.public_key),
                "AURA_APT_REPOSITORY_FINGERPRINT": self.fingerprint,
                "AURA_APT_REPOSITORY_SIGNING_KEY_PASSPHRASE": self.signing_passphrase,
                "AURA_APT_GNUPGHOME": str(self.gnupg),
            }
        )
        result = subprocess.run(
            ["bash", str(BUILDER), str(self.packages), str(self.repository)],
            cwd=ROOT,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            raise AssertionError(
                "APT repository builder failed with status "
                f"{result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )

    def test_repository_contains_signed_architecture_filtered_indexes(self) -> None:
        self._build()
        self.assertTrue((self.repository / "dists/stable/InRelease").is_file())
        self.assertTrue((self.repository / "dists/stable/Release").is_file())
        self.assertTrue((self.repository / "dists/stable/Release.gpg").is_file())

        exported_key = self.root / "trusted.gpg"
        exported_key.write_bytes(
            subprocess.run(
                [
                    "gpg",
                    "--homedir",
                    str(self.gnupg),
                    "--batch",
                    "--export",
                    self.fingerprint,
                ],
                check=True,
                capture_output=True,
                timeout=15,
            ).stdout
        )
        subprocess.run(
            [
                "gpgv",
                "--keyring",
                str(exported_key),
                str(self.repository / "dists/stable/InRelease"),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )

        for architecture in ("amd64", "arm64", "riscv64"):
            index = (
                self.repository
                / "dists/stable/main"
                / f"binary-{architecture}/Packages"
            )
            text = index.read_text(encoding="utf-8")
            self.assertIn(f"Package: {IMAGE_PACKAGE}", text)
            self.assertIn(f"Architecture: {architecture}", text)
            self.assertIn("Package: aura-kernel", text)
            self.assertIn("Architecture: all", text)
            other_arches = {"amd64", "arm64", "riscv64"} - {architecture}
            for other in other_arches:
                self.assertNotIn(f"Architecture: {other}\n", text)
            self.assertTrue(index.with_name("Packages.gz").is_file())

        release = (self.repository / "dists/stable/Release").read_text(
            encoding="utf-8"
        )
        self.assertIn("Origin: Aura OS", release)
        self.assertIn("Architectures: amd64 arm64 riscv64", release)
        self.assertIn(self.fingerprint, (self.repository / "KEY-FINGERPRINT.txt").read_text())

        # Release must hash the exact generated indexes, not a stale or
        # self-referential Release file retained from a previous publication.
        self.assertIn("SHA256:\n", release, "Release is missing its SHA256 index section")
        sha_section = release.split("SHA256:\n", 1)[1]
        sha_entries: dict[str, tuple[str, int]] = {}
        for line in sha_section.splitlines():
            if not line.startswith(" "):
                break
            digest, size, filename = line.split()
            sha_entries[filename] = (digest, int(size))
        for architecture in ("amd64", "arm64", "riscv64"):
            for index_name in ("Packages", "Packages.gz"):
                filename = f"main/binary-{architecture}/{index_name}"
                index_path = self.repository / "dists/stable" / filename
                data = index_path.read_bytes()
                self.assertEqual(
                    sha_entries.get(filename),
                    (hashlib.sha256(data).hexdigest(), len(data)),
                )
        self.assertNotIn("Release", sha_entries)
        self.assertNotIn("InRelease", sha_entries)
        self.assertNotIn("Release.gpg", sha_entries)

        debs = list((self.repository / "pool").rglob("*.deb"))
        self.assertEqual(len(debs), 4, "three image packages and one deduplicated meta package")

    def test_apt_get_accepts_the_repository_with_the_pinned_key(self) -> None:
        self._build()
        keyring = self.root / "aura-apt-keyring.gpg"
        subprocess.run(
            ["gpg", "--batch", "--yes", "--dearmor", "--output", str(keyring), str(self.public_key)],
            check=True,
            capture_output=True,
            timeout=15,
        )
        apt_root = self.root / "apt-state"
        lists = apt_root / "lists"
        (lists / "partial").mkdir(parents=True)
        cache = apt_root / "cache"
        (cache / "archives/partial").mkdir(parents=True)
        status = apt_root / "status"
        status.write_text("", encoding="utf-8")
        source = apt_root / "sources.list"
        source.write_text(
            f"deb [arch=amd64 signed-by={keyring}] file:{self.repository} stable main\n",
            encoding="utf-8",
        )
        command = [
            "apt-get",
            "-o",
            f"Dir::Etc::sourcelist={source}",
            "-o",
            "Dir::Etc::sourceparts=-",
            "-o",
            f"Dir::State::lists={lists}",
            "-o",
            f"Dir::State::status={status}",
            "-o",
            f"Dir::Cache={cache}",
            "-o",
            f"Dir::Cache::archives={cache / 'archives'}",
            "-o",
            f"Dir::Cache::archives::partial={cache / 'archives/partial'}",
            "-o",
            "Debug::NoLocking=1",
            "-o",
            "Acquire::Languages=none",
            "update",
        ]
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(list(lists.glob("*_InRelease")) or list(lists.glob("*_Release")))

    def test_apt_install_resolves_meta_package_and_matching_kernel_image(self) -> None:
        """Resolve both Aura kernel packages through the authenticated APT source."""
        self._build()
        keyring = self.root / "aura-apt-keyring.gpg"
        subprocess.run(
            [
                "gpg",
                "--batch",
                "--yes",
                "--dearmor",
                "--output",
                str(keyring),
                str(self.public_key),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )

        apt_root = self.root / "apt-install-state"
        lists = apt_root / "lists"
        (lists / "partial").mkdir(parents=True)
        cache = apt_root / "cache"
        (cache / "archives/partial").mkdir(parents=True)
        status = apt_root / "status"
        # The test repository intentionally contains only Aura kernel packages.
        # Mark their normal base-system dependencies as already installed so
        # APT must resolve and download the two-package Aura kernel dependency
        # graph without consulting any network or host package sources.
        status.write_text(
            "Package: apt\n"
            "Status: install ok installed\n"
            "Architecture: amd64\n"
            "Version: 2.7.14\n\n"
            "Package: grub2-common\n"
            "Status: install ok installed\n"
            "Architecture: amd64\n"
            "Version: 2.12-1\n\n"
            "Package: systemd\n"
            "Status: install ok installed\n"
            "Architecture: amd64\n"
            "Version: 256-1\n\n"
            "Package: kmod\n"
            "Status: install ok installed\n"
            "Architecture: amd64\n"
            "Version: 32+20240611-1\n",
            encoding="utf-8",
        )
        source = apt_root / "sources.list"
        source.write_text(
            f"deb [arch=amd64 signed-by={keyring}] file:{self.repository} stable main\n",
            encoding="utf-8",
        )
        common_options = [
            "-o",
            f"Dir::Etc::sourcelist={source}",
            "-o",
            "Dir::Etc::sourceparts=-",
            "-o",
            f"Dir::State::lists={lists}",
            "-o",
            f"Dir::State::status={status}",
            "-o",
            f"Dir::Cache={cache}",
            "-o",
            "Debug::NoLocking=1",
            "-o",
            "Acquire::Languages=none",
            "-o",
            "APT::Architecture=amd64",
        ]
        update = subprocess.run(
            ["apt-get", *common_options, "update"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(update.returncode, 0, update.stdout + update.stderr)
        index_files = sorted(item.name for item in lists.iterdir() if item.is_file())
        package_indexes = [name for name in index_files if "Packages" in name]
        self.assertTrue(
            package_indexes,
            "APT accepted InRelease but did not fetch a Packages index. "
            f"Files: {index_files!r}\nstdout:\n{update.stdout}\nstderr:\n{update.stderr}",
        )

        install = subprocess.run(
            [
                "apt-get",
                *common_options,
                "install",
                "--download-only",
                "--yes",
                "--no-install-recommends",
                "aura-kernel",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(install.returncode, 0, install.stdout + install.stderr)

        # A file: repository is already local, so APT may reference package
        # archives in place and report 0 bytes to download. Validate the
        # solver's actual install plan (package, architecture, and version)
        # rather than expecting duplicate .deb files in the download cache.
        install_output = install.stdout + install.stderr
        self.assertIn("The following NEW packages will be installed:", install_output)
        self.assertIn(IMAGE_PACKAGE, install_output)
        self.assertIn("aura-kernel", install_output)
        self.assertIn(f"{IMAGE_PACKAGE} amd64 {VERSION}", install_output)
        self.assertIn(f"aura-kernel all {VERSION}", install_output)
        self.assertIn("Download complete and in download only mode", install_output)


    def test_wrong_public_key_cannot_verify_the_repository(self) -> None:
        self._build()
        wrong_home = self.root / "wrong-gnupg"
        wrong_home.mkdir(mode=0o700)
        subprocess.run(
            [
                "gpg",
                "--homedir",
                str(wrong_home),
                "--batch",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--quick-generate-key",
                "Wrong APT test key <wrong@example.invalid>",
                "ed25519",
                "sign",
                "1d",
            ],
            check=True,
            capture_output=True,
            timeout=30,
        )
        wrong_keyring = self.root / "wrong.gpg"
        wrong_keyring.write_bytes(
            subprocess.run(
                ["gpg", "--homedir", str(wrong_home), "--batch", "--export"],
                check=True,
                capture_output=True,
                timeout=15,
            ).stdout
        )
        result = subprocess.run(
            [
                "gpgv",
                "--keyring",
                str(wrong_keyring),
                str(self.repository / "dists/stable/InRelease"),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
