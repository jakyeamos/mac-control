from __future__ import annotations

import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "vscode_fixture.py"
SPEC = importlib.util.spec_from_file_location("vscode_fixture", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class VSCodeFixtureTests(unittest.TestCase):
    def test_bundle_identity_is_unique_and_bounded(self) -> None:
        self.assertEqual(
            fixture.bundle_id_for("quality-lens-c1"),
            "com.jakyeamos.macctl.fixture.vscode.qualitylensc1",
        )
        for invalid in ("", "Quality-Lens", "1fixture", "a" * 33, "fixture/path"):
            with self.subTest(invalid=invalid), self.assertRaises(fixture.FixtureError):
                fixture.bundle_id_for(invalid)

    def test_root_requires_an_explicit_task_owned_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            with self.assertRaises(fixture.FixtureError):
                fixture.validate_new_root(Path(parent) / "unowned")
            expected = Path(parent) / "macctl-vscode-fixture-c1"
            self.assertEqual(fixture.validate_new_root(expected), expected.resolve())

    def test_build_reidentifies_only_the_outer_bundle_and_writes_marker_last(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            parent_path = Path(parent)
            source = parent_path / "Source Code.app"
            (source / "Contents" / "MacOS").mkdir(parents=True)
            (source / "Contents" / "MacOS" / "Code").write_text("fixture", encoding="utf-8")
            with (source / "Contents" / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "com.microsoft.VSCode",
                        "CFBundleName": "Code",
                        "CFBundleDisplayName": "Code",
                    },
                    handle,
                )
            root = parent_path / "macctl-vscode-fixture-build"

            def copy_bundle(src: Path, dest: Path, _: bool) -> str:
                shutil.copytree(src, dest)
                return "test_copy"

            with (
                patch.object(fixture, "_clone_bundle", side_effect=copy_bundle),
                patch.object(fixture, "_sign_bundle"),
                patch.object(fixture, "_verify_bundle"),
            ):
                result = fixture.build_fixture(
                    root,
                    "quality-lens-c1",
                    source,
                    ad_hoc_sign=True,
                )

            self.assertEqual(result["bundle_id"], fixture.bundle_id_for("quality-lens-c1"))
            marker = json.loads((root / fixture.MARKER_NAME).read_text(encoding="utf-8"))
            self.assertEqual(marker["schema"], fixture.SCHEMA)
            self.assertTrue(marker["nested_signatures_repaired"])
            with (root / fixture.APP_NAME / "Contents" / "Info.plist").open("rb") as handle:
                rewritten = plistlib.load(handle)
            self.assertEqual(rewritten["CFBundleIdentifier"], result["bundle_id"])
            self.assertEqual(rewritten["CFBundleName"], "Code")
            self.assertEqual(rewritten["CFBundleDisplayName"], "Code")

    def test_signing_walks_electron_macho_files_inside_out_without_deep(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            app = Path(parent) / fixture.APP_NAME
            framework = app / "Contents" / "Frameworks" / "Electron Framework.framework"
            library = framework / "Versions" / "A" / "Libraries" / "libffmpeg.dylib"
            library.parent.mkdir(parents=True)
            library.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")

            with patch.object(
                fixture,
                "_run",
                return_value=subprocess.CompletedProcess([], 0, "", ""),
            ) as run:
                fixture._sign_bundle(app, "TEST-IDENTITY")

            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(
                [Path(command[-1]) for command in commands],
                [library, framework, app],
            )
            self.assertTrue(all("--deep" not in command for command in commands))

    def test_verification_rejects_a_nested_macho_with_a_different_team(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            app = Path(parent) / fixture.APP_NAME
            library = app / "Contents" / "Libraries" / "libffmpeg.dylib"
            library.parent.mkdir(parents=True)
            library.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")

            def codesign(command: list[str]) -> subprocess.CompletedProcess[str]:
                if "--verify" in command:
                    return subprocess.CompletedProcess(command, 0, "", "")
                path = Path(command[-1])
                team = "FIXTURETEAM" if path == app else "SOURCETEAM"
                identifier = (
                    "com.jakyeamos.macctl.fixture.vscode.qualitylensc1"
                    if path == app
                    else "libffmpeg"
                )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    "",
                    f"Identifier={identifier}\nTeamIdentifier={team}\n",
                )

            with patch.object(fixture, "_run", side_effect=codesign):
                with self.assertRaisesRegex(fixture.FixtureError, "mixed Team IDs"):
                    fixture._verify_bundle(
                        app,
                        "com.jakyeamos.macctl.fixture.vscode.qualitylensc1",
                    )

    def test_signature_repair_requires_the_original_identity(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            root = (Path(parent) / "macctl-vscode-fixture-signature-repair").resolve()
            executable = root / fixture.APP_NAME / "Contents" / "MacOS" / "Code"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
            (root / fixture.MARKER_NAME).write_text(
                json.dumps(
                    {
                        "schema": fixture.SCHEMA,
                        "root": str(root),
                        "app": str(root / fixture.APP_NAME),
                        "bundle_id": "com.jakyeamos.macctl.fixture.vscode.repair",
                        "pid": None,
                        "process_command_sha256": None,
                        "signing_identity_sha256": "different",
                    }
                ),
                encoding="utf-8",
            )

            with (
                patch.object(fixture, "_pids_for_executable", return_value=[]),
                patch.object(fixture, "_resolve_signing_identity", return_value="TEST-IDENTITY"),
            ):
                with self.assertRaisesRegex(fixture.FixtureError, "original signing identity"):
                    fixture.repair_fixture_signatures(root)

    def test_marker_cannot_claim_a_different_root(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "macctl-vscode-fixture-wrong-root"
            root.mkdir()
            (root / fixture.MARKER_NAME).write_text(
                json.dumps(
                    {
                        "schema": fixture.SCHEMA,
                        "root": str(root.parent / "somewhere-else"),
                        "app": str(root / fixture.APP_NAME),
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(fixture.FixtureError):
                fixture.clean_fixture(root)

    def test_extension_install_requires_safe_package_identity(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            parent_path = Path(parent)
            root = (parent_path / "macctl-vscode-fixture-extension").resolve()
            root.mkdir()
            (root / "extensions").mkdir()
            (root / fixture.MARKER_NAME).write_text(
                json.dumps(
                    {
                        "schema": fixture.SCHEMA,
                        "root": str(root),
                        "app": str(root / fixture.APP_NAME),
                    }
                ),
                encoding="utf-8",
            )
            extension = parent_path / "extension"
            extension.mkdir()
            (extension / "package.json").write_text(
                json.dumps({"publisher": "macctl", "name": "problems-fixture", "version": "0.0.1"}),
                encoding="utf-8",
            )
            installed = fixture.install_extension(root, extension)
            self.assertEqual(installed.name, "macctl.problems-fixture-0.0.1")
            self.assertEqual(fixture.install_extension(root, extension), installed)

    def test_status_preserves_a_pre_ready_exit_as_a_typed_result(self) -> None:
        for startup_state in (
            "awaiting_manual_approval_or_startup",
            "stopped_before_ready",
        ):
            with self.subTest(startup_state=startup_state), tempfile.TemporaryDirectory() as parent:
                root = (Path(parent) / "macctl-vscode-fixture-pre-ready-exit").resolve()
                root.mkdir()
                (root / fixture.MARKER_NAME).write_text(
                    json.dumps(
                        {
                            "schema": fixture.SCHEMA,
                            "root": str(root),
                            "app": str(root / fixture.APP_NAME),
                            "bundle_id": "com.jakyeamos.macctl.fixture.vscode.prereadyexit",
                            "pid": 12345,
                            "process_command_sha256": "digest",
                            "launched_at": "2026-08-13T00:00:00+00:00",
                            "startup_state": startup_state,
                        }
                    ),
                    encoding="utf-8",
                )

                with patch.object(fixture, "_live_process", return_value=(False, None)):
                    result = fixture.fixture_status(root)

                self.assertEqual(result["status"], "stopped_before_ready")
                self.assertFalse(result["manual_approval_required"])
                self.assertEqual(result["next_action"], "relaunch_and_review_native_approval")

    def test_launch_reports_a_process_that_exits_before_binding(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            root = (Path(parent) / "macctl-vscode-fixture-launch-exit").resolve()
            root.mkdir()
            (root / "workspace").mkdir()
            (root / fixture.MARKER_NAME).write_text(
                json.dumps(
                    {
                        "schema": fixture.SCHEMA,
                        "root": str(root),
                        "app": str(root / fixture.APP_NAME),
                        "bundle_id": "com.jakyeamos.macctl.fixture.vscode.launchexit",
                        "pid": None,
                        "process_command_sha256": None,
                    }
                ),
                encoding="utf-8",
            )

            with (
                patch.object(fixture, "_pids_for_executable", side_effect=[[], [12345]]),
                patch.object(
                    fixture,
                    "_run",
                    return_value=subprocess.CompletedProcess([], 0, "", ""),
                ),
                patch.object(fixture, "_command_for_pid", return_value=None),
            ):
                result = fixture.launch_fixture(root, None, None)

            self.assertEqual(result["status"], "stopped_before_ready")
            marker = json.loads((root / fixture.MARKER_NAME).read_text(encoding="utf-8"))
            self.assertEqual(marker["startup_state"], "stopped_before_ready")
            self.assertEqual(marker["last_candidate_pid"], 12345)
            self.assertIsNone(marker["pid"])

    def test_launch_reports_when_code_evaluation_prevents_process_creation(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            root = (Path(parent) / "macctl-vscode-fixture-launch-blocked").resolve()
            root.mkdir()
            (root / "workspace").mkdir()
            (root / fixture.MARKER_NAME).write_text(
                json.dumps(
                    {
                        "schema": fixture.SCHEMA,
                        "root": str(root),
                        "app": str(root / fixture.APP_NAME),
                        "bundle_id": "com.jakyeamos.macctl.fixture.vscode.launchblocked",
                        "pid": None,
                        "process_command_sha256": None,
                    }
                ),
                encoding="utf-8",
            )

            with (
                patch.object(fixture, "_pids_for_executable", side_effect=[[], []]),
                patch.object(
                    fixture,
                    "_run",
                    return_value=subprocess.CompletedProcess([], 0, "", ""),
                ),
                patch.object(fixture.time, "monotonic", side_effect=[0.0, 11.0]),
            ):
                result = fixture.launch_fixture(root, None, None)

            self.assertEqual(result["status"], "stopped_before_ready")
            self.assertEqual(result["next_action"], "relaunch_and_review_native_approval")


if __name__ == "__main__":
    unittest.main()
