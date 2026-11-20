#!/usr/bin/env python3
"""Validate Aura OS raw ext4 root-volume images before QEMU boot or packaging."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

EXPECTED_LABEL = "AURA_ROOTFS"


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command, check=False, capture_output=True, text=True
        )
    except OSError as exc:
        raise ValueError(f"could not execute {command[0]}: {exc}") from exc


def _parse_blkid_export(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def verify_storage_image(image: str | Path) -> dict[str, Any]:
    path = Path(image)
    if not path.is_file():
        raise ValueError(f"storage image does not exist or is not a regular file: {path}")

    size_bytes = path.stat().st_size
    if size_bytes <= 0:
        raise ValueError(f"storage image is empty: {path}")

    probe = _run(["blkid", "-p", "-o", "export", str(path)])
    if probe.returncode != 0:
        detail = (probe.stderr or probe.stdout).strip()
        raise ValueError(f"blkid could not identify the storage image: {detail}")

    fields = _parse_blkid_export(probe.stdout)
    filesystem = fields.get("TYPE")
    if filesystem != "ext4":
        raise ValueError(
            f"storage image filesystem is {filesystem!r}, expected 'ext4'"
        )

    label = fields.get("LABEL")
    if label != EXPECTED_LABEL:
        raise ValueError(
            f"storage image label is {label!r}, expected {EXPECTED_LABEL!r}"
        )

    try:
        normalized_uuid = str(uuid.UUID(fields.get("UUID", "")))
    except (ValueError, AttributeError) as exc:
        raise ValueError("storage image must have a valid filesystem UUID") from exc

    if fields.get("USAGE") not in (None, "filesystem"):
        raise ValueError(
            f"blkid usage is {fields.get('USAGE')!r}, expected a filesystem"
        )

    # -n is read-only; a non-zero status rejects a dirty or inconsistent image.
    fsck = _run(["e2fsck", "-f", "-n", str(path)])
    if fsck.returncode != 0:
        detail = "\n".join(
            part.strip() for part in (fsck.stdout, fsck.stderr) if part.strip()
        )
        raise ValueError(
            f"ext4 integrity check failed with exit code {fsck.returncode}: {detail}"
        )

    return {
        "status": "ok",
        "image": path.name,
        "image_size_bytes": size_bytes,
        "layout": "whole-device-ext4",
        "filesystem": filesystem,
        "label": label,
        "uuid": normalized_uuid,
        "integrity_check": "e2fsck -f -n passed (read-only)",
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate the filesystem contract of an Aura OS storage image."
    )
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = verify_storage_image(args.image)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(
            "Valid Aura OS storage image: "
            f"{result['filesystem']} label={result['label']} "
            f"uuid={result['uuid']} size={result['image_size_bytes']} bytes"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
