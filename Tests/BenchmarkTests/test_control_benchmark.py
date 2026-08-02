import importlib.util
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / "scripts" / "control_benchmark.py"
SPEC = importlib.util.spec_from_file_location("control_benchmark", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(benchmark)


class ControlBenchmarkTests(unittest.TestCase):
    def test_sensitive_fields_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "sensitive field"):
            benchmark.assert_safe({"metadata": {"lease_token": "do-not-store"}})

    def test_append_uses_owner_only_file_and_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "raw.jsonl"
            record = benchmark.make_record(
                task="focus-next-control",
                lane="generic-gui",
                phase="measured",
                sample=1,
                duration_ms=12.3456,
                tool_calls=1,
                recoveries=0,
                verified=True,
                user_help=False,
                status="passed",
                oracle="focus changed",
            )
            benchmark.append_record(path, record)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(benchmark.load_records(path)[0]["duration_ms"], 12.346)

    def test_summary_marks_noisy_three_sample_group_for_expansion(self):
        records = []
        for sample, duration in enumerate((10.0, 10.0, 20.0), 1):
            records.append(
                benchmark.make_record(
                    task="task-a",
                    lane="agent-baseline",
                    phase="measured",
                    sample=sample,
                    duration_ms=duration,
                    tool_calls=1,
                    recoveries=0,
                    verified=True,
                    user_help=False,
                    status="passed",
                    oracle="done",
                )
            )
        summary = benchmark.summarize_records(records)
        self.assertTrue(summary["groups"][0]["expand_to_seven"])

    def test_close_lanes_are_both_marked_for_expansion(self):
        records = []
        for lane, duration in (("agent-baseline", 100.0), ("mac-control", 105.0)):
            for sample in range(1, 4):
                records.append(
                    benchmark.make_record(
                        task="task-a",
                        lane=lane,
                        phase="measured",
                        sample=sample,
                        duration_ms=duration,
                        tool_calls=1,
                        recoveries=0,
                        verified=True,
                        user_help=False,
                        status="passed",
                        oracle="done",
                    )
                )
        summary = benchmark.summarize_records(records)
        self.assertTrue(all(group["expand_to_seven"] for group in summary["groups"]))

    def test_markdown_has_requested_comparison_columns(self):
        summary = {
            "groups": [
                {
                    "task": "task-a",
                    "lane": "mac-control",
                    "samples": 3,
                    "median_ms": 5.0,
                    "mean_tool_calls": 1.0,
                    "recoveries": 0,
                    "verified": 3,
                    "user_help": 0,
                    "status": "passed",
                    "expand_to_seven": False,
                }
            ]
        }
        table = benchmark.markdown_summary(summary)
        for heading in ("Task", "Lane", "Median", "Tool calls", "Recoveries", "Verified", "User help", "Interpretation"):
            self.assertIn(heading, table)

    def test_mac_focus_reestablishes_foreground_before_lease(self):
        calls = []

        def fake_run_json(command):
            calls.append(command)
            if command[1:3] == ["app", "open"]:
                return ({"status": "succeeded", "result": {"name": "System Settings", "isRunning": True}}, 1.0)
            if command[1:4] == ["keyboard", "lease", "acquire"]:
                return ({"status": "succeeded", "result": {"lease": {"token": "memory-only"}}}, 1.0)
            raise AssertionError(f"unexpected measured command: {command}")

        args = SimpleNamespace(
            macctl="/tmp/macctl",
            app="System Settings",
            seconds=60,
            warmups=0,
            samples=0,
            output=Path("/tmp/not-written.jsonl"),
        )
        with patch.object(benchmark, "run_json", side_effect=fake_run_json), patch.object(
            benchmark.subprocess, "run"
        ) as release:
            self.assertEqual(benchmark.run_mac_focus(args), 0)

        self.assertEqual(calls[0][1:4], ["app", "open", "System Settings"])
        self.assertEqual(calls[1][1:4], ["keyboard", "lease", "acquire"])
        release.assert_called_once()


if __name__ == "__main__":
    unittest.main()
