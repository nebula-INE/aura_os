#!/usr/bin/env python3
"""Validate the PE/COFF EFI stub embedded in a Linux arm64 Image.

The generic `file` utility may identify this file as a Linux ARM64 Image
instead of PE32+. Linux arm64 stores the PE header offset in the boot header
at 0x3c, alongside the ARM64_IMAGE_MAGIC at 0x38.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path
from typing import Any

ARM64_IMAGE_MAGIC = b"ARM\x64"
PE_SIGNATURE = b"PE\0\0"
IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x020B
IMAGE_SUBSYSTEM_EFI_APPLICATION = 10
ARM64_HEADER_SIZE = 0x40
PE_COFF_HEADER_SIZE = 24
OPTIONAL_HEADER_SUBSYSTEM_OFFSET = 68


def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def _u64(data: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def validate_image_bytes(data: bytes) -> dict[str, Any]:
    """Validate an AArch64 Linux Image and its EFI application header."""
    if len(data) < ARM64_HEADER_SIZE:
        raise ValueError("image is too small to contain the Linux arm64 boot header")

    if data[0x38:0x3C] != ARM64_IMAGE_MAGIC:
        raise ValueError("Linux arm64 Image magic is missing at offset 0x38")

    image_size = _u64(data, 0x10)
    if image_size == 0:
        raise ValueError("Linux arm64 Image header reports an empty image")

    pe_offset = _u32(data, 0x3C)
    if pe_offset < ARM64_HEADER_SIZE:
        raise ValueError(
            f"invalid PE header offset in Linux arm64 boot header: 0x{pe_offset:x}"
        )
    if pe_offset > len(data) - PE_COFF_HEADER_SIZE:
        raise ValueError("PE/COFF header offset is outside the kernel image")

    if data[pe_offset : pe_offset + 4] != PE_SIGNATURE:
        raise ValueError("PE/COFF signature was not found at the Linux arm64 header offset")

    coff_offset = pe_offset + 4
    machine = _u16(data, coff_offset)
    section_count = _u16(data, coff_offset + 2)
    optional_header_size = _u16(data, coff_offset + 16)

    if machine != IMAGE_FILE_MACHINE_ARM64:
        raise ValueError(f"PE machine is 0x{machine:04x}, expected ARM64 (0xaa64)")
    if section_count == 0:
        raise ValueError("PE/COFF image has no sections")

    optional_offset = pe_offset + PE_COFF_HEADER_SIZE
    if optional_header_size <= OPTIONAL_HEADER_SUBSYSTEM_OFFSET + 1:
        raise ValueError("PE optional header is too small for a subsystem field")
    if optional_offset + optional_header_size > len(data):
        raise ValueError("PE optional header extends beyond the kernel image")

    optional_magic = _u16(data, optional_offset)
    if optional_magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC:
        raise ValueError(
            f"PE optional-header magic is 0x{optional_magic:04x}, expected PE32+ (0x020b)"
        )

    subsystem = _u16(data, optional_offset + OPTIONAL_HEADER_SUBSYSTEM_OFFSET)
    if subsystem != IMAGE_SUBSYSTEM_EFI_APPLICATION:
        raise ValueError(
            f"PE subsystem is {subsystem}, expected EFI application (10)"
        )

    return {
        "architecture": "aarch64",
        "format": "PE32+",
        "machine": f"0x{machine:04x}",
        "subsystem": "EFI_APPLICATION",
        "section_count": section_count,
        "image_size": image_size,
        "pe_header_offset": pe_offset,
    }


def validate_image(path: str | Path) -> dict[str, Any]:
    image_path = Path(path)
    try:
        data = image_path.read_bytes()
    except OSError as exc:
        raise ValueError(f"cannot read kernel image {image_path}: {exc}") from exc
    result = validate_image_bytes(data)
    result["path"] = str(image_path)
    result["file_size"] = len(data)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the PE32+ EFI application header in a Linux AArch64 Image."
    )
    parser.add_argument("image", type=Path, help="path to arch/arm64/boot/Image")
    parser.add_argument(
        "--json", action="store_true", help="print machine-readable JSON"
    )
    args = parser.parse_args()

    try:
        result = validate_image(args.image)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(
            "Valid Linux AArch64 EFI image: "
            f"{result['format']} / {result['subsystem']} "
            f"(PE offset 0x{result['pe_header_offset']:x}, "
            f"{result['section_count']} sections, "
            f"{result['file_size']} bytes)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
