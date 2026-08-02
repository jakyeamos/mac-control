from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "mac-control" / "SKILL.md"
ROUTING = ROOT / "skills" / "mac-control" / "references" / "routing.md"
INSTALLER = ROOT / "scripts" / "install_mac_control_skill.py"


class MacControlSkillTests(unittest.TestCase):
    def test_route_order_and_completion_guards_are_explicit(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        self.assertNotIn("TODO", text)
        ordered = [
            "mature direct CLI, API, typed connector, or browser DOM route",
            "Mac Control adapter or semantic Accessibility target",
            "named Mac Control keyboard action",
            "generic Accessibility GUI control",
            "screenshot, OCR, or coordinates",
        ]
        positions = [text.index(marker) for marker in ordered]
        self.assertEqual(positions, sorted(positions))
        for marker in (
            "keyboard_focus_changed",
            "foreground_only",
            "lease_released",
            "result.verification.state",
            "approval-gated",
        ):
            self.assertIn(marker, text)

    def test_reference_has_positive_negative_and_ambiguous_cases(self) -> None:
        text = ROUTING.read_text(encoding="utf-8")
        for marker in (
            "Read `AppleKeyboardUIMode`",
            "Move focus to the next control",
            "Click a webpage button",
            "Enter a password",
            "A CLI exists but only reads state",
            "verification reports `foreground_only`",
        ):
            self.assertIn(marker, text)

    def test_installer_creates_verified_canonical_and_codex_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_home:
            install_result = subprocess.run(
                ["python3", str(INSTALLER), "install", "--home", temporary_home],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(install_result.returncode, 0, install_result.stderr)
            installed = json.loads(install_result.stdout)
            self.assertEqual(installed["status"], "pass")
            self.assertTrue(installed["canonicalMatches"])
            self.assertTrue(installed["codexProjected"])

            check_result = subprocess.run(
                ["python3", str(INSTALLER), "check", "--home", temporary_home],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(check_result.returncode, 0, check_result.stderr)
            checked = json.loads(check_result.stdout)
            self.assertEqual(checked["sourceSha256"], checked["canonicalSha256"])

            second_install = subprocess.run(
                ["python3", str(INSTALLER), "install", "--home", temporary_home],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(second_install.returncode, 0, second_install.stderr)
            self.assertEqual(json.loads(second_install.stdout)["rollbacks"], [])

    def test_installer_detects_canonical_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_home:
            subprocess.run(
                ["python3", str(INSTALLER), "install", "--home", temporary_home],
                check=True,
                capture_output=True,
                text=True,
            )
            canonical_skill = (
                Path(temporary_home) / ".agents" / "skills" / "mac-control" / "SKILL.md"
            )
            canonical_skill.write_text(
                canonical_skill.read_text(encoding="utf-8") + "\nlocal drift\n",
                encoding="utf-8",
            )
            check_result = subprocess.run(
                ["python3", str(INSTALLER), "check", "--home", temporary_home],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(check_result.returncode, 1)
            checked = json.loads(check_result.stdout)
            self.assertFalse(checked["canonicalMatches"])


if __name__ == "__main__":
    unittest.main()
