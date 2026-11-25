from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ensure-ubuntu-apt-sources.sh"


class UbuntuAptSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def test_runner_mirrorlist_sources_are_disabled_before_update(self) -> None:
        self.assertIn("mirror\\+file:/etc/apt/apt-mirrors\\.txt", self.script)
        self.assertIn('disabled_file="${source_file}.disabled"', self.script)
        self.assertLess(
            self.script.index("disable_unreliable_runner_mirrorlists"),
            self.script.index("apt_update_with_retries 2"),
        )

    def test_apt_update_has_network_and_process_deadlines(self) -> None:
        self.assertIn('timeout --foreground --signal=TERM --kill-after=10s', self.script)
        self.assertIn('"${timeout_seconds}s"', self.script)
        self.assertIn("-o Acquire::http::Timeout=20", self.script)
        self.assertIn("-o Acquire::https::Timeout=20", self.script)
        self.assertIn("-o Acquire::Retries=1", self.script)

    def test_fallback_uses_official_signed_https_sources(self) -> None:
        self.assertIn("URIs: https://archive.ubuntu.com/ubuntu", self.script)
        self.assertIn("URIs: https://security.ubuntu.com/ubuntu", self.script)
        self.assertIn("Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg", self.script)


if __name__ == "__main__":
    unittest.main()
