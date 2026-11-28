#!/usr/bin/env python3
"""Normalize QEMU serial-console output before checking guest status markers."""

from __future__ import annotations

import re
import sys
from pathlib import Path

# CSI (cursor/control), OSC (window/title), and DCS/SOS/PM/APC sequences.
_TERMINAL_SEQUENCE = re.compile(
    r"\x1b(?:"
    r"\[[0-?]*[ -/]*[@-~]"
    r"|\][^\x07]*(?:\x07|\x1b\\)"
    r"|[PX^_].*?\x1b\\"
    r")"
)
_CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def normalize_console_log(raw: str) -> str:
    """Remove terminal control sequences and normalize serial line endings."""
    without_terminal_sequences = _TERMINAL_SEQUENCE.sub("", raw)
    without_control_characters = _CONTROL_CHARACTERS.sub(
        "", without_terminal_sequences
    )
    return without_control_characters.replace("\r", "")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} LOG_FILE", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    try:
        raw = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"error: cannot read QEMU console log {log_path}: {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(normalize_console_log(raw))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
#!/usr/bin/env python3
"""Normalize QEMU serial-console output before checking guest status markers."""

from __future__ import annotations

import re
import sys
from pathlib import Path

# CSI (cursor/control), OSC (window/title), and DCS/SOS/PM/APC sequences.
_TERMINAL_SEQUENCE = re.compile(
    r"\x1b(?:"
    r"\[[0-?]*[ -/]*[@-~]"
    r"|\][^\x07]*(?:\x07|\x1b\\)"
    r"|[PX^_].*?\x1b\\"
    r")"
)
_CONTROL_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def normalize_console_log(raw: str) -> str:
    """Remove terminal control sequences and normalize serial line endings."""
    without_terminal_sequences = _TERMINAL_SEQUENCE.sub("", raw)
    without_control_characters = _CONTROL_CHARACTERS.sub(
        "", without_terminal_sequences
    )
    return without_control_characters.replace("\r", "")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} LOG_FILE", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1])
    try:
        raw = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"error: cannot read QEMU console log {log_path}: {exc}", file=sys.stderr)
        return 1

    sys.stdout.write(normalize_console_log(raw))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
