from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFY_SCRIPT = ROOT / "system/base/installer/verify-media.sh"


class InstallerSigningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.media = self.base / "media"
        self.media.mkdir()
        self.private_key = self.base / "release-private.pem"
        self.public_key = self.base / "release-public.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.private_key)],
            check=True,
            capture_output=True,
            timeout=15,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(self.private_key), "-pubout", "-out", str(self.public_key)],
            check=True,
            capture_output=True,
            timeout=15,
        )
        self.expected = {
            "rootfs/aura-base-x86_64.tar.gz": b"rootfs payload",
            "boot/vmlinuz-x86_64": b"kernel payload",
            "boot/initramfs-x86_64.cpio.gz": b"initramfs payload",
            "boot/efi.img": b"EFI boot image",
        }
        for relative, data in self.expected.items():
            path = self.media / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.manifest = self.media / "aura-payloads.sha256"
        self.signature = self.media / "aura-payloads.sha256.sig"
        self._write_manifest()
        self._sign_manifest()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_manifest(self) -> None:
        rows = []
        for relative in sorted(self.expected):
            payload = self.media / relative
            digest = subprocess.run(
                ["sha256sum", str(payload)],
                check=True,
                capture_output=True,
                text=True,
                timeout=15,
            ).stdout.split()[0]
            rows.append(f"{digest}  {relative}")
        self.manifest.write_text("\n".join(rows) + "\n", encoding="ascii")

    def _sign_manifest(self) -> None:
        subprocess.run(
            [
                "openssl", "pkeyutl", "-sign", "-rawin",
                "-inkey", str(self.private_key),
                "-in", str(self.manifest),
                "-out", str(self.signature),
            ],
            check=True,
            capture_output=True,
            timeout=15,
        )

    def _verify(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "AURA_TARGET_ARCH": "x86_64",
                "AURA_RELEASE_PUBLIC_KEY_FILE": str(self.public_key),
                "LC_ALL": "C",
            }
        )
        return subprocess.run(
            ["/bin/sh", str(VERIFY_SCRIPT), str(self.media)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )

    def test_valid_signed_manifest_and_all_payload_hashes_are_accepted(self) -> None:
        result = self._verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AURA_MEDIA_SIGNATURE_OK", result.stdout)

    def test_modified_payload_is_rejected_even_when_manifest_signature_is_valid(self) -> None:
        (self.media / "boot/vmlinuz-x86_64").write_bytes(b"tampered kernel")
        result = self._verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 verification", result.stderr)

    def test_modified_manifest_is_rejected_by_signature_verification(self) -> None:
        with self.manifest.open("a", encoding="ascii") as stream:
            stream.write("# modified\n")
        result = self._verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature is invalid", result.stderr)

    def test_manifest_cannot_add_unlisted_paths_or_duplicate_payloads(self) -> None:
        original = self.manifest.read_text(encoding="ascii")
        self.manifest.write_text(
            original + original.splitlines()[0] + "\n",
            encoding="ascii",
        )
        self._sign_manifest()
        result = self._verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected or duplicate entries", result.stderr)


if __name__ == "__main__":
    unittest.main()
