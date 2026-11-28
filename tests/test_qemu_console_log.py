from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

from normalize_qemu_console_log import normalize_console_log  # noqa: E402


class NormalizeQemuConsoleLogTests(unittest.TestCase):
    def test_removes_terminal_csi_and_osc_sequences_before_markers(self) -> None:
        raw = (
            "\x1b[!p"
            "\x1b]104\x07"
            "\x1b[?7h"
            "\x1b[6n"
            "\x1b[32766;32766H"
            "\x1b[6n"
            "AURA_NETWORK_NTP_ENABLED_OK\r\n"
        )
        self.assertEqual(
            normalize_console_log(raw),
            "AURA_NETWORK_NTP_ENABLED_OK\n",
        )

    def test_preserves_guest_output_and_multiple_exact_markers(self) -> None:
        raw = (
            "AURA_SYSTEMD_ROOTFS_OK\r\n"
            "\x1b[32mAURA_NETWORK_DNS_OK\x1b[0m\r\n"
            "AURA_ROOTFS_QEMU_PASS\r\n"
        )
        self.assertEqual(
            normalize_console_log(raw),
            "AURA_SYSTEMD_ROOTFS_OK\n"
            "AURA_NETWORK_DNS_OK\n"
            "AURA_ROOTFS_QEMU_PASS\n",
        )

    def test_removes_non_printing_control_characters(self) -> None:
        raw = "before\x00\x07\x1fafter\n"
        self.assertEqual(normalize_console_log(raw), "beforeafter\n")


if __name__ == "__main__":
    unittest.main()
