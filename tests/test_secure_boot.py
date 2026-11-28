from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "scripts/prepare-uefi-secureboot-key.sh"


class UefiSecureBootKeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_prepare(self, output: Path, **extra_env: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(extra_env)
        env["GITHUB_ENV"] = str(self.root / "github-env")
        return subprocess.run(
            ["bash", str(PREPARE), str(output)],
            cwd=ROOT,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_ci_generates_private_rsa_key_and_exportable_db_certificate(self) -> None:
        output = self.root / "generated"
        result = self.run_prepare(output, GITHUB_REF="refs/pull/42/merge")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        private_key = output / "private-key.pem"
        certificate = output / "certificate.pem"
        certificate_der = output / "certificate.der"
        self.assertTrue(private_key.is_file())
        self.assertTrue(certificate.is_file())
        self.assertTrue(certificate_der.is_file())
        self.assertEqual(private_key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(certificate_der.stat().st_mode & 0o777, 0o644)

        key_info = subprocess.run(
            ["openssl", "rsa", "-in", str(private_key), "-text", "-noout"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        ).stdout
        self.assertIn("Private-Key: (3072 bit", key_info)
        fingerprint = hashlib.sha256(certificate_der.read_bytes()).hexdigest().upper()
        env_text = (self.root / "github-env").read_text(encoding="utf-8")
        self.assertIn(f"AURA_UEFI_SECURE_BOOT_CERT_SHA256={fingerprint}", env_text)
        self.assertIn("AURA_UEFI_SECURE_BOOT_MODE=ci-ephemeral", env_text)
        self.assertIn("Prepared UEFI Secure Boot signing identity (ci-ephemeral", result.stdout)

    def test_signed_image_and_report_are_readable_by_later_unprivileged_steps(self) -> None:
        output = self.root / "signed"
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        input_image = self.root / "BOOTX64.EFI"
        input_image.write_bytes(b"MZ\\x00mock EFI PE image")
        private_key = self.root / "private.pem"
        certificate = self.root / "certificate.pem"
        subprocess.run(
            ["openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-sha256", "-days", "30", "-keyout", str(private_key),
             "-out", str(certificate), "-subj", "/CN=Aura test signing/"],
            check=True, capture_output=True, timeout=30,
        )
        sbsign = binary_dir / "sbsign"
        sbsign.write_text(
            """#!/bin/sh
output=
input=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) shift; output="$1" ;;
    *) input="$1" ;;
  esac
  shift
done
cp "$input" "$output"
""",
            encoding="utf-8",
        )
        sbverify = binary_dir / "sbverify"
        sbverify.write_text(
            """#!/bin/sh
case " $* " in
  *" --list "*) printf '%s\\n' 'signature 1' ;;
esac
""",
            encoding="utf-8",
        )
        sbsign.chmod(0o755)
        sbverify.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{binary_dir}:{env['PATH']}"
        env["AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_FILE"] = str(private_key)
        env["AURA_UEFI_SECURE_BOOT_CERT_FILE"] = str(certificate)
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/sign-efi-image.sh"), str(input_image), str(output)],
            cwd=ROOT, env=env, check=False, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o644)
        self.assertEqual(Path(str(output) + ".secureboot.txt").stat().st_mode & 0o777, 0o644)

    def test_release_fails_closed_without_configured_signing_identity(self) -> None:
        output = self.root / "release"
        result = self.run_prepare(output, GITHUB_REF="refs/tags/v0.1.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tagged releases require", result.stderr)
        self.assertFalse((output / "private-key.pem").exists())

    def test_release_rejects_mismatched_private_key_and_certificate(self) -> None:
        output = self.root / "mismatch"
        key_a = self.root / "a.pem"
        key_b = self.root / "b.pem"
        cert_a = self.root / "a-cert.pem"
        for key in (key_a, key_b):
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(key)],
                check=True,
                capture_output=True,
                timeout=30,
            )
        subprocess.run(
            [
                "openssl", "req", "-new", "-x509", "-key", str(key_a), "-sha256", "-days", "30",
                "-subj", "/CN=Aura test certificate/", "-addext", "basicConstraints=critical,CA:FALSE",
                "-addext", "keyUsage=critical,digitalSignature", "-addext", "extendedKeyUsage=codeSigning",
                "-out", str(cert_a),
            ],
            check=True,
            capture_output=True,
            timeout=20,
        )
        expected = hashlib.sha256(subprocess.run(
            ["openssl", "x509", "-in", str(cert_a), "-outform", "DER"],
            check=True,
            capture_output=True,
            timeout=15,
        ).stdout).hexdigest().upper()
        result = self.run_prepare(
            output,
            GITHUB_REF="refs/tags/v0.1.0",
            AURA_UEFI_SECURE_BOOT_PRIVATE_KEY_PEM=key_b.read_text(encoding="utf-8"),
            AURA_UEFI_SECURE_BOOT_CERT_PEM=cert_a.read_text(encoding="utf-8"),
            AURA_UEFI_SECURE_BOOT_CERT_SHA256=expected,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
