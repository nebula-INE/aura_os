from __future__ import annotations

import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "system/base/installer/diagnose.sh"


class OfflineDiagnoseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.mount_base = self.base / "mnt" / "aura-rescue"
        self.root = self.mount_base / "root-1"
        self.run_dir = self.base / "run"
        self.bin_dir = self.base / "bin"
        self.bin_dir.mkdir()
        self.root.mkdir(parents=True)
        self.run_dir.mkdir()

        (self.root / "etc").mkdir()
        (self.root / "usr/lib").mkdir(parents=True)
        (self.root / "var/lib/aura").mkdir(parents=True)
        (self.root / "var/lib/dpkg").mkdir(parents=True)
        (self.root / "etc/systemd/system/multi-user.target.wants").mkdir(parents=True)
        (self.root / "boot/grub").mkdir(parents=True)
        (self.root / "var/log/journal/mock-machine-id").mkdir(parents=True)

        (self.root / "etc/os-release").write_text(
            'PRETTY_NAME="Aura OS Test"\nID=aura\n', encoding="utf-8"
        )
        (self.root / "usr/lib/os-release").write_text(
            'PRETTY_NAME="Aura OS Test"\nID=aura\n', encoding="utf-8"
        )
        (self.root / "etc/fstab").write_text(
            "UUID=mock-root / ext4 defaults 0 1\n", encoding="utf-8"
        )
        (self.root / "etc/aura-release").write_text("Aura OS test build\n", encoding="utf-8")
        (self.root / "var/lib/aura/install-manifest").write_text(
            "architecture=x86_64\nroot_uuid=mock-root\n", encoding="utf-8"
        )
        (self.root / "var/lib/dpkg/status").write_text(
            "Package: systemd\nStatus: install ok installed\n\n"
            "Package: aura-base\nStatus: install ok installed\n",
            encoding="utf-8",
        )
        (self.root / "etc/systemd/system/multi-user.target.wants/network.service").symlink_to(
            "/usr/lib/systemd/system/network.service"
        )
        (self.root / "boot/grub/grub.cfg").write_text(
            "search --fs-uuid --set=root mock-root\n", encoding="utf-8"
        )
        (self.root / "var/log/syslog").write_text("sample log inventory only\n", encoding="utf-8")
        (self.root / "etc/hostname").symlink_to("/etc/passwd")

        self.journal_marker = self.base / "journal-called"
        self._write_command(
            "findmnt",
            r'''case "$*" in
  *"--target $AURA_RESCUE_RUN_DIR"*) echo tmpfs ;;
  *"--mountpoint $AURA_RESCUE_ROOT_MOUNT_BASE/root-1"*) exit 0 ;;
  *"--target $AURA_RESCUE_ROOT_MOUNT_BASE/root-1"*)
    case "$*" in
      *"FSTYPE"*) echo ext4 ;;
      *"OPTIONS"*) echo "$MOCK_ROOT_OPTIONS" ;;
      *"SOURCE"*) echo /dev/mockroot ;;
    esac
    ;;
  *) exit 1 ;;
esac
''',
        )
        self._write_command(
            "blkid",
            r'''if [ "$1" = "-s" ] && [ "$2" = "UUID" ]; then
  echo mock-root
else
  echo "/dev/mockroot: UUID=mock-root TYPE=ext4 LABEL=AURA_ROOTFS"
fi
''',
        )
        self._write_command("lsblk", 'printf \'{"blockdevices":[]}\\n\'\n')
        self._write_command(
            "journalctl",
            'printf "offline warning journal\\n"\n'
            'touch "$JOURNAL_MARKER"\n',
        )

        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}/usr/bin:/bin",
                "AURA_RESCUE_ROOT_MOUNT_BASE": str(self.mount_base),
                "AURA_RESCUE_RUN_DIR": str(self.run_dir),
                "MOCK_ROOT_OPTIONS": "ro,noload,relatime",
                "JOURNAL_MARKER": str(self.journal_marker),
                "LC_ALL": "C",
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_command(self, name: str, body: str) -> None:
        path = self.bin_dir / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        path.chmod(0o755)

    def _run(self, *args: str, options: str | None = None) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if options is not None:
            env["MOCK_ROOT_OPTIONS"] = options
        return subprocess.run(
            ["/bin/sh", str(SCRIPT), *args],
            input="1\n",
            text=True,
            capture_output=True,
            env=env,
            timeout=15,
            check=False,
        )

    def _archive(self, name: str = "rescue-report.tar.gz") -> tarfile.TarFile:
        return tarfile.open(self.run_dir / name, "r:gz")

    def test_creates_private_report_from_read_only_root_without_running_target_files(self) -> None:
        result = self._run("--output", "rescue-report.tar.gz")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.run_dir / "rescue-report.tar.gz"
        self.assertTrue(report.is_file())
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.run_dir / "rescue-report.tar.gz.sha256").is_file())
        self.assertFalse(self.journal_marker.exists())

        with self._archive() as archive:
            names = set(archive.getnames())
            self.assertIn("./README.txt", names)
            self.assertIn("./os-release.txt", names)
            self.assertIn("./installed-packages.txt", names)
            self.assertIn("./systemd-unit-links.txt", names)
            self.assertNotIn("./offline-journal-warnings.txt", names)

            readme = archive.extractfile("./README.txt")
            self.assertIsNotNone(readme)
            content = readme.read().decode("utf-8")  # type: ignore[union-attr]
            self.assertIn("Collection mode: offline, read-only", content)
            self.assertIn("No target OS executable", content)
            self.assertIn("mock-root", content)

            hostname = archive.extractfile("./hostname.txt")
            self.assertIsNotNone(hostname)
            hostname_content = hostname.read().decode("utf-8")  # type: ignore[union-attr]
            self.assertIn("symlink-not-followed", hostname_content)
            self.assertIn("/etc/passwd", hostname_content)
            self.assertNotIn("root:x:", hostname_content)

            packages = archive.extractfile("./installed-packages.txt")
            self.assertIsNotNone(packages)
            packages_content = packages.read().decode("utf-8")  # type: ignore[union-attr]
            self.assertIn("systemd", packages_content)
            self.assertIn("aura-base", packages_content)

    def test_journal_is_collected_only_with_explicit_opt_in(self) -> None:
        result = self._run("--output", "with-journal.tar.gz", "--include-journal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.journal_marker.exists())
        with self._archive("with-journal.tar.gz") as archive:
            journal = archive.extractfile("./offline-journal-warnings.txt")
            self.assertIsNotNone(journal)
            content = journal.read().decode("utf-8")  # type: ignore[union-attr]
            self.assertIn("offline warning journal", content)

    def test_refuses_root_filesystem_that_is_not_read_only(self) -> None:
        result = self._run("--output", "unsafe.tar.gz", options="rw,relatime")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.run_dir / "unsafe.tar.gz").exists())
        self.assertIn("no mounted read-only ext4", result.stderr)

    def test_refuses_paths_that_could_write_to_a_target_disk(self) -> None:
        result = self._run("--output", "/mnt/aura-rescue/root-1/report.tar.gz")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("filename, not a path", result.stderr)

    def test_rejects_unknown_options(self) -> None:
        result = self._run("--repair")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown option", result.stderr)


if __name__ == "__main__":
    unittest.main()
