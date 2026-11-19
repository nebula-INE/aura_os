import struct
import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from verify_aarch64_efi_image import validate_image_bytes  # noqa: E402


def make_valid_image() -> bytearray:
    data = bytearray(0x300)
    data[0x38:0x3C] = b"ARM\x64"
    struct.pack_into("<Q", data, 0x10, len(data))
    pe_offset = 0x80
    struct.pack_into("<I", data, 0x3C, pe_offset)
    data[pe_offset : pe_offset + 4] = b"PE\0\0"

    coff_offset = pe_offset + 4
    struct.pack_into("<H", data, coff_offset, 0xAA64)
    struct.pack_into("<H", data, coff_offset + 2, 2)
    struct.pack_into("<H", data, coff_offset + 16, 240)

    optional_offset = pe_offset + 24
    struct.pack_into("<H", data, optional_offset, 0x020B)
    struct.pack_into("<H", data, optional_offset + 68, 10)
    return data


class AArch64EFIImageTests(unittest.TestCase):
    def test_accepts_valid_linux_arm64_efi_image(self) -> None:
        result = validate_image_bytes(bytes(make_valid_image()))
        self.assertEqual(result["architecture"], "aarch64")
        self.assertEqual(result["format"], "PE32+")
        self.assertEqual(result["subsystem"], "EFI_APPLICATION")
        self.assertEqual(result["section_count"], 2)

    def test_rejects_regular_arm64_image_without_pe_header(self) -> None:
        data = bytearray(0x200)
        data[0x38:0x3C] = b"ARM\x64"
        struct.pack_into("<Q", data, 0x10, len(data))
        with self.assertRaisesRegex(ValueError, "PE header offset"):
            validate_image_bytes(bytes(data))

    def test_rejects_wrong_architecture(self) -> None:
        data = make_valid_image()
        struct.pack_into("<H", data, 0x84, 0x8664)
        with self.assertRaisesRegex(ValueError, "expected ARM64"):
            validate_image_bytes(bytes(data))

    def test_rejects_non_pe32_plus_optional_header(self) -> None:
        data = make_valid_image()
        struct.pack_into("<H", data, 0x80 + 24, 0x010B)
        with self.assertRaisesRegex(ValueError, "expected PE32"):
            validate_image_bytes(bytes(data))

    def test_rejects_non_efi_subsystem(self) -> None:
        data = make_valid_image()
        struct.pack_into("<H", data, 0x80 + 24 + 68, 3)
        with self.assertRaisesRegex(ValueError, "expected EFI application"):
            validate_image_bytes(bytes(data))

    def test_rejects_out_of_bounds_pe_offset(self) -> None:
        data = make_valid_image()
        struct.pack_into("<I", data, 0x3C, len(data) - 8)
        with self.assertRaisesRegex(ValueError, "outside the kernel image"):
            validate_image_bytes(bytes(data))

    def test_rejects_truncated_image(self) -> None:
        with self.assertRaisesRegex(ValueError, "too small"):
            validate_image_bytes(b"ARM")


if __name__ == "__main__":
    unittest.main()
