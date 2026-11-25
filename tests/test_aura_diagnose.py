from __future__ import annotations

import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "system/base/diagnostics/aura-diagnose"


class AuraDiagnoseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.output_dir = self.root / "out"
        self.output_dir.mkdir()
        self.archive = self.output_dir / "diagnostics.tar.gz"
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}/usr/bin:/bin",
                "TMPDIR": str(self.root),
                "LC_ALL": "C",
            }
        )
        for name in (
            "uname",
            "hostname",
            "uptime",
            "systemctl",
            "systemd-analyze",
            "lsblk",
            "findmnt",
            "df",
            "ip",
            "resolvectl",
            "networkctl",
            "journalctl",
        ):
            self._write_command(name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_command(self, name: str, output: str | None = None, exit_code: int = 0) -> None:
        text = output if output is not None else f"mock-{name}"
        escaped = text.replace("'", "'\\''")
        path = self.bin_dir / name
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '{escaped}'\n"
            f"exit {exit_code}\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", str(SCRIPT), *args],
            text=True,
            capture_output=True,
            env=self.env,
            timeout=15,
            check=False,
        )

    def _archive_names(self) -> set[str]:
        with tarfile.open(self.archive, "r:gz") as archive:
            return set(archive.getnames())

    def _read_archive_file(self, name: str) -> str:
        with tarfile.open(self.archive, "r:gz") as archive:
            member = archive.extractfile(f"./{name}")
            self.assertIsNotNone(member)
            assert member is not None
            return member.read().decode("utf-8")

    def test_creates_private_read_only_report_without_journal_by_default(self) -> None:
        result = self._run("--output", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.archive.is_file())
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o600)

        names = self._archive_names()
        self.assertIn("./README.txt", names)
        self.assertIn("./services-failed.txt", names)
        self.assertIn("./storage-block-devices.txt", names)
        self.assertIn("./network-routes.txt", names)
        self.assertNotIn("./journal-current-boot.txt", names)

        readme = self._read_archive_file("README.txt")
        self.assertIn("Diagnostics mode: read-only", readme)
        self.assertIn("No repair", readme)
        self.assertIn("Review all files", readme)

    def test_journal_is_collected_only_after_explicit_opt_in(self) -> None:
        self._write_command("journalctl", "mock warning journal entry")
        result = self._run("--output", str(self.archive), "--include-journal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("./journal-current-boot.txt", self._archive_names())
        journal = self._read_archive_file("journal-current-boot.txt")
        self.assertIn("mock warning journal entry", journal)

    def test_refuses_to_overwrite_existing_archive(self) -> None:
        self.archive.write_bytes(b"keep-me")
        result = self._run("--output", str(self.archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.archive.read_bytes(), b"keep-me")
        self.assertIn("refusing to overwrite", result.stderr)

    def test_rejects_unknown_options(self) -> None:
        result = self._run("--repair")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown option", result.stderr)

    def test_command_failures_are_recorded_without_aborting_collection(self) -> None:
        self._write_command("resolvectl", "resolver unavailable", exit_code=1)
        result = self._run("--output", str(self.archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        resolver = self._read_archive_file("network-resolver.txt")
        self.assertIn("resolver unavailable", resolver)
        self.assertIn("exit_status=1", resolver)
        self.assertIn("Aura OS diagnostics saved", result.stdout)


if __name__ == "__main__":
    unittest.main()
