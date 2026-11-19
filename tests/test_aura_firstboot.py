from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FIRSTBOOT_SCRIPT = REPO_ROOT / "system/base/firstboot/aura-firstboot"
FIRSTBOOT_UNIT = REPO_ROOT / "system/base/firstboot/aura-firstboot.service"


class FirstBootSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.state_dir = self.root / "state"
        self.command_log = self.root / "commands.log"
        self.console_input = self.root / "console-input"
        self.console_output = self.root / "console-output"
        self.existing_users = self.root / "existing-users"
        self.existing_users.write_text("", encoding="utf-8")

        self._write_command("id", 'echo 0\n')
        self._write_command(
            "getent",
            'if [ "$1" = "passwd" ] && [ -f "$AURA_TEST_EXISTING_USERS" ] && '
            'grep -Fxq -- "$2" "$AURA_TEST_EXISTING_USERS"; then exit 0; fi\n'
            "exit 2\n",
        )
        self._write_command(
            "useradd",
            'for username do :; done\n'
            'status="${AURA_TEST_USERADD_EXIT:-0}"\n'
            'if [ "$status" -eq 0 ]; then printf "%s\\n" "$username" >> "$AURA_TEST_EXISTING_USERS"; fi\n'
            'printf "useradd:%s\\n" "$*" >> "$AURA_TEST_COMMAND_LOG"\n'
            'exit "$status"\n',
        )
        self._write_command(
            "sync",
            'printf "sync\\n" >> "$AURA_TEST_COMMAND_LOG"\\n',
        )
        self._write_logged_command("passwd", "AURA_TEST_PASSWD_EXIT")
        self._write_logged_command("userdel", "AURA_TEST_USERDEL_EXIT")

        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}",
                "AURA_FIRSTBOOT_STATE_DIR": str(self.state_dir),
                "AURA_TEST_COMMAND_LOG": str(self.command_log),
                "AURA_TEST_EXISTING_USERS": str(self.existing_users),
                "AURA_FIRSTBOOT_INPUT_PATH": str(self.console_input),
                "AURA_FIRSTBOOT_OUTPUT_PATH": str(self.console_output),
                "AURA_TEST_USERADD_EXIT": "0",
                "AURA_TEST_PASSWD_EXIT": "0",
                "AURA_TEST_USERDEL_EXIT": "0",
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_command(self, name: str, body: str) -> None:
        path = self.bin_dir / name
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def _write_logged_command(self, name: str, exit_env: str) -> None:
        self._write_command(
            name,
            f'printf "%s:%s\\n" "{name}" "$*" >> "$AURA_TEST_COMMAND_LOG"\n'
            f'exit "${{{exit_env}:-0}}"\n',
        )

    def _run_setup(self, input_text: str = "") -> subprocess.CompletedProcess[str]:
        self.console_input.write_text(input_text, encoding="utf-8")
        return subprocess.run(
            ["bash", str(FIRSTBOOT_SCRIPT)],
            input="",
            text=True,
            capture_output=True,
            env=self.env,
            timeout=10,
            check=False,
        )

    def _commands(self) -> str:
        return self.command_log.read_text(encoding="utf-8") if self.command_log.exists() else ""

    def test_creates_one_sudo_administrator_and_is_idempotent(self) -> None:
        result = self._run_setup("auraadmin\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state_dir / "complete").is_file())
        self.assertFalse((self.state_dir / "pending-user").exists())
        marker = (self.state_dir / "complete").read_text(encoding="utf-8")
        self.assertEqual(marker, "version=1\nusername=auraadmin\n")
        self.assertEqual((self.state_dir / "complete").stat().st_mode & 0o777, 0o600)
        commands = self._commands()
        self.assertIn("useradd:", commands)
        # The pending marker must be flushed before useradd persists the account.
        self.assertLess(commands.index("sync\\n"), commands.index("useradd:"))
        self.assertIn("--groups sudo -- auraadmin", commands)
        self.assertIn("passwd:auraadmin", commands)
        self.assertIn("New username", self.console_output.read_text(encoding="utf-8"))

        second = self._run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self._commands(), commands)

    def test_rejects_invalid_username_then_accepts_valid_username(self) -> None:
        result = self._run_setup("Admin\nvalid_user-2\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Invalid username", result.stderr)
        self.assertIn("useradd:", self._commands())
        self.assertIn("valid_user-2", self._commands())
        self.assertNotIn("Admin", self._commands())

    def test_rejects_existing_username(self) -> None:
        self.existing_users.write_text("taken\n", encoding="utf-8")
        result = self._run_setup("taken\nnewadmin\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already exists", result.stderr)
        self.assertIn("newadmin", self._commands())
        self.assertNotIn("taken", self._commands())

    def test_failed_password_can_resume_without_duplicate_user_creation(self) -> None:
        self.env["AURA_TEST_PASSWD_EXIT"] = "1"
        first = self._run_setup("resumeuser\n")
        self.assertNotEqual(first.returncode, 0)
        self.assertTrue((self.state_dir / "pending-user").is_file())
        self.assertFalse((self.state_dir / "complete").exists())
        self.assertIn("resumeuser", self._commands())

        useradd_count = self._commands().count("useradd:")
        self.env["AURA_TEST_PASSWD_EXIT"] = "0"
        resumed = self._run_setup()
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(self._commands().count("useradd:"), useradd_count)
        self.assertTrue((self.state_dir / "complete").is_file())
        self.assertFalse((self.state_dir / "pending-user").exists())

    def test_useradd_failure_does_not_mark_setup_complete(self) -> None:
        self.env["AURA_TEST_USERADD_EXIT"] = "1"
        result = self._run_setup("faileduser\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state_dir / "complete").exists())
        self.assertFalse((self.state_dir / "pending-user").exists())
        self.assertNotIn("passwd:", self._commands())

    def test_systemd_unit_requires_console_and_skips_qemu_smoke_mode(self) -> None:
        unit = FIRSTBOOT_UNIT.read_text(encoding="utf-8")
        self.assertIn("ConditionKernelCommandLine=!aura.firstboot.skip", unit)
        self.assertIn("StandardInput=tty-force", unit)
        self.assertIn("StandardError=tty", unit)
        self.assertIn("TTYPath=/dev/console", unit)
        self.assertIn("Before=systemd-user-sessions.service getty.target", unit)


if __name__ == "__main__":
    unittest.main()
