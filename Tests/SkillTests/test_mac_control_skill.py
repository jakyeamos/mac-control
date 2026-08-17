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
    def test_task_specific_route_selection_and_completion_guards_are_explicit(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        self.assertNotIn("TODO", text)
        for marker in (
            "task-specific rather than a fixed",
            "fresh manifest exists for the exact app identity",
            "`mac-control-task-manifest/v4`",
            "self-attested `criteria` booleans",
            "Quality Runner must resolve\nevery source reference to an implementation file",
            "Treat v1 through v3 as declaration-only migration formats",
            "Keep rendered web content on a browser connector",
            "Accessibility candidates need a stable identifier",
            "require\nan explicit fresh-state handoff",
            "selector's addressability metadata",
            "one unique\n`AXTextField` with subrole `AXSearchField`",
            "Never fall back to\nrepeated `next-control`/Tab traversal",
            "Unmeasured or stale candidates are",
            "unproven and must be rebenchmarked",
            "Visual and coordinate candidates require explicit task-manifest opt-in",
            "Only a declared\nfallback may run after a pre-action target-not-found result",
        ):
            self.assertIn(marker, text)
        self.assertNotIn("Apply this order:", text)
        for marker in (
            "keyboard_focus_changed",
            "foreground_only",
            "lease_released",
            "result.verification.state",
            "structured ephemeral-input",
            "skip redundant activation",
            "daemon-executed",
            "route register",
            "action scroll",
            "reset-direction",
            "AXScrollArea",
            "control capabilities",
            "recentBlockers",
            "do not replay the same locator",
            "selector field names",
            "freshUntil",
            "capability-audit",
            "fast route probe",
            "cached broad profile",
            "control.batch",
            "provider-neutral `outcome`",
            "verified_success",
            "target_ambiguous",
            "get_app_state",
            "sky.scroll",
            "agent.contract",
            "Before declaring browser chrome blocked",
            "Tab->Group Tab",
            "browser connector select the tab and read back",
            "Tab-group title",
            "menu item's enabled state as the postcondition",
            "Mac Control is an execution extension, not a second permission system",
            "routine visible reversible actions",
            "Do not call `approval.*` for new task, workflow, or shortcut work",
            "status=ready",
            "task.run` without an\napproval token",
        ):
            self.assertIn(marker, text)

    def test_direct_status_queries_do_not_trigger_macctl_preflight(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        direct = "/usr/bin/defaults read -g AppleKeyboardUIMode"
        self.assertIn(direct, text)
        self.assertIn("Stop here when the direct route fully covers the task", text)
        self.assertIn(
            "Run the following checks only after\nselecting a Mac Control route",
            text,
        )
        self.assertIn(
            "Do not run `macctl doctor`, `macctl capabilities`, or `macctl control status` merely to answer",
            text,
        )

    def test_skill_is_loaded_only_once_across_projections(self) -> None:
        text = SKILL.read_text(encoding="utf-8")
        self.assertIn("Load this packet once", text)
        self.assertIn("do not load another copy", text)

    def test_reference_has_positive_negative_and_ambiguous_cases(self) -> None:
        text = ROUTING.read_text(encoding="utf-8")
        for marker in (
            "Read `AppleKeyboardUIMode`",
            "claims web content through native Accessibility",
            "score `0/8`",
            "typed v4 semantic claims with source grounding",
            "Move focus to the next control",
            "one unique `AXTextField`/`AXSearchField`",
            "Do not approximate search with repeated `Tab`/`next-control`",
            "Click a webpage button",
            "Enter a password",
            "A CLI exists but only reads state",
            "verification reports `foreground_only`",
            "daemon-executed `route benchmark`",
            "verification.state == passed",
            "--action scroll --route scroll",
            "--reset-direction up",
            "control capabilities",
            "control capability-audit",
            "swiftui",
            "cached broad profile",
            "control batch",
            "recommended_provider",
            "target_ambiguous",
            "get_app_state",
            "sky.scroll",
            "caller-supplied",
            "tab-strip context menu",
            "group-label readback",
            "classify it as contextual",
            "focused `Tab-group title`",
            "menu state unchanged",
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
