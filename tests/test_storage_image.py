from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from verify_storage_image import verify_storage_image  # noqa: E402

VALID_BLKID = (
    "TYPE=ext4\n"
    "LABEL=AURA_ROOTFS\n"
    "UUID=01234567-89ab-cdef-0123-456789abcdef\n"
    "USAGE=filesystem\n"
)


class StorageImageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.image = Path(self.temp_dir.name) / "aura-base.ext4"
        self.image.write_bytes(b"fake ext4 image payload")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _run_success(self, blkid_output: str = VALID_BLKID) -> dict[str, object]:
        def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            if command[0] == "blkid":
                return subprocess.CompletedProcess(command, 0, blkid_output, "")
            if command[0] == "e2fsck":
                return subprocess.CompletedProcess(command, 0, "clean\n", "")
            raise AssertionError(f"unexpected command: {command}")

        with patch("verify_storage_image.subprocess.run", side_effect=fake_run):
            return verify_storage_image(self.image)

    def test_accepts_clean_whole_device_ext4_image(self) -> None:
        result = self._run_success()
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["layout"], "whole-device-ext4")
        self.assertEqual(result["filesystem"], "ext4")
        self.assertEqual(result["label"], "AURA_ROOTFS")
        self.assertEqual(result["uuid"], "01234567-89ab-cdef-0123-456789abcdef")
        self.assertGreater(result["image_size_bytes"], 0)

    def test_rejects_missing_image(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not exist"):
            verify_storage_image(self.image.parent / "missing.ext4")

    def test_rejects_empty_image(self) -> None:
        self.image.write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "empty"):
            verify_storage_image(self.image)

    def test_rejects_non_ext4_filesystem(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected 'ext4'"):
            self._run_success(VALID_BLKID.replace("TYPE=ext4", "TYPE=xfs"))

    def test_rejects_wrong_filesystem_label(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected 'AURA_ROOTFS'"):
            self._run_success(VALID_BLKID.replace("LABEL=AURA_ROOTFS", "LABEL=OTHER"))

    def test_rejects_invalid_uuid(self) -> None:
        with self.assertRaisesRegex(ValueError, "valid filesystem UUID"):
            self._run_success(
                VALID_BLKID.replace(
                    "01234567-89ab-cdef-0123-456789abcdef", "not-a-uuid"
                )
            )

    def test_rejects_unrecognized_image(self) -> None:
        def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 2, "", "not a filesystem")

        with patch("verify_storage_image.subprocess.run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "blkid could not identify"):
                verify_storage_image(self.image)

    def test_rejects_failed_read_only_integrity_check(self) -> None:
        def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            if command[0] == "blkid":
                return subprocess.CompletedProcess(command, 0, VALID_BLKID, "")
            return subprocess.CompletedProcess(command, 4, "errors found\n", "")

        with patch("verify_storage_image.subprocess.run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "integrity check failed"):
                verify_storage_image(self.image)

    def test_uses_read_only_forced_e2fsck(self) -> None:
        commands: list[list[str]] = []

        def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            commands.append(command)
            if command[0] == "blkid":
                return subprocess.CompletedProcess(command, 0, VALID_BLKID, "")
            return subprocess.CompletedProcess(command, 0, "clean\n", "")

        with patch("verify_storage_image.subprocess.run", side_effect=fake_run):
            verify_storage_image(self.image)

        self.assertEqual(commands[1][:3], ["e2fsck", "-f", "-n"])


if __name__ == "__main__":
    unittest.main()
