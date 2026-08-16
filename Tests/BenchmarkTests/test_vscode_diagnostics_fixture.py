from __future__ import annotations

import importlib.util
import json
import plistlib
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "vscode_diagnostics_fixture.py"
SPEC = importlib.util.spec_from_file_location("vscode_diagnostics_fixture", SCRIPT)
assert SPEC and SPEC.loader
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class VSCodeFixtureTests(unittest.TestCase):
    def test_fixture_id_policy_is_lowercase_and_non_traversable(self) -> None:
        self.assertTrue(fixture.is_valid_fixture_id("problems_fixture-1"))
        for value in ("../escape", "_leading", "-leading", "UPPER", "a/b", ""):
            self.assertFalse(fixture.is_valid_fixture_id(value))

    def test_find_vscode_app_accepts_bundle_declared_code_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Visual Studio Code.app"
            contents = app / "Contents"
            executable = contents / "MacOS" / "Code"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture executable")
            with (contents / "Info.plist").open("wb") as stream:
                plistlib.dump(
                    {"CFBundleExecutable": "Code", "CFBundleIdentifier": fixture.DEFAULT_BUNDLE_ID},
                    stream,
                )

            self.assertEqual(fixture.find_vscode_app(str(app)), app.resolve())
            self.assertEqual(fixture.app_executable_path(app), executable.resolve())

    def test_snapshot_ready_accepts_redacted_fresh_positive_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "fixture"
            directory.mkdir()
            (directory / "workspace").mkdir()
            (directory / "fixture-marker.json").write_text(
                json.dumps({"fixture_id": "fixture", "purpose": "test"}),
                encoding="utf-8",
            )
            payload = {
                "schema_version": 1,
                "provider": fixture.SNAPSHOT_PROVIDER,
                "fixture_id": "fixture",
                "bundle_id": fixture.DEFAULT_BUNDLE_ID,
                "workspace_digest": fixture.workspace_digest(directory, "fixture"),
                "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "diagnostics": [
                    {
                        "severity": "error",
                        "source": "macctl-fixture",
                        "code": "MACCTL",
                        "line": 0,
                        "column": 0,
                    }
                ],
            }
            (directory / "diagnostics.json").write_text(json.dumps(payload), encoding="utf-8")
            self.assertTrue(fixture.snapshot_ready(directory, "fixture", fixture.DEFAULT_BUNDLE_ID))

    def test_snapshot_ready_rejects_stale_private_and_ambiguous_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "fixture"
            directory.mkdir()
            (directory / "workspace").mkdir()
            (directory / "fixture-marker.json").write_text(
                json.dumps({"fixture_id": "fixture", "purpose": "test"}),
                encoding="utf-8",
            )
            base = {
                "schema_version": 1,
                "provider": fixture.SNAPSHOT_PROVIDER,
                "fixture_id": "fixture",
                "bundle_id": fixture.DEFAULT_BUNDLE_ID,
                "workspace_digest": fixture.workspace_digest(directory, "fixture"),
                "generated_at": "2000-01-01T00:00:00Z",
                "diagnostics": [],
            }
            path = directory / "diagnostics.json"
            path.write_text(json.dumps(base), encoding="utf-8")
            self.assertFalse(fixture.snapshot_ready(directory, "fixture", fixture.DEFAULT_BUNDLE_ID))

            private_payload = dict(base)
            private_payload["generated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            private_payload["diagnostics"] = [{"severity": "error", "line": 0, "column": 0, "message": "private"}]
            path.write_text(json.dumps(private_payload), encoding="utf-8")
            self.assertFalse(fixture.snapshot_ready(directory, "fixture", fixture.DEFAULT_BUNDLE_ID))

            self.assertFalse(fixture.snapshot_ready(directory, "other", fixture.DEFAULT_BUNDLE_ID))
            with self.assertRaises(fixture.FixtureError):
                fixture.fixture_directory(Path(temporary), "../escape")

    def test_create_status_and_cleanup_are_bounded_to_exact_fixture_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            created = fixture.create_fixture(root, "fixture", SCRIPT.parent.parent / "fixtures/vscode-problems-extension")
            self.assertEqual(created["state"], "prepared")
            status = fixture.status_fixture(root, "fixture")
            self.assertEqual(status["visual_acceptance"], "unverified")
            self.assertEqual(status["frontmost_proof"], "not_claimed")
            removed = fixture.cleanup_fixture(root, "fixture")
            self.assertTrue(removed["removed"])
            self.assertFalse((root / "fixture").exists())


if __name__ == "__main__":
    unittest.main()
