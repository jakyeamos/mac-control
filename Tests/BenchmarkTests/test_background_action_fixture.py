import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "background_action_fixture.py"
SPEC = importlib.util.spec_from_file_location("background_action_fixture", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BackgroundActionFixtureTests(unittest.TestCase):
    def test_bundle_contract_is_unique_and_task_owned(self):
        self.assertEqual(
            MODULE.BUNDLE_ID,
            "com.jakyeamos.macctl.background-action-fixture",
        )
        self.assertIn("BackgroundActionFixture", str(MODULE.SOURCE))
        self.assertTrue(MODULE.SOURCE.is_file())

    def test_executable_path_is_bounded_by_supplied_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            executable = MODULE.executable_for(app)
            self.assertTrue(executable.is_relative_to(app))
            self.assertEqual(executable.name, "BackgroundActionFixture")

    def test_clean_refuses_an_unmarked_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Fixture.app"
            app.mkdir()
            with self.assertRaisesRegex(SystemExit, "unmarked"):
                MODULE.clean(app, Path(directory) / "fixture-state.json")

    def test_fixture_contains_two_windows_with_duplicate_semantic_button(self):
        source = MODULE.SOURCE.read_text(encoding="utf-8")
        self.assertIn("Mac Control Background Action Fixture", source)
        self.assertIn("Mac Control Background Action Decoy", source)
        self.assertEqual(source.count('setAccessibilityIdentifier("macctl-fixture-run")'), 1)
        self.assertIn("decoy: false", source)
        self.assertIn("decoy: true", source)

    def test_launch_preserves_foreground_without_hiding_the_fixture(self):
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('["/usr/bin/open", "-g", "-n"', script)
        self.assertNotIn('["/usr/bin/open", "-g", "-j"', script)


if __name__ == "__main__":
    unittest.main()
