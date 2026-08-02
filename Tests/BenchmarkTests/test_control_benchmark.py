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
                    "interpretation": "passed",
                }
            ]
        }
        table = benchmark.markdown_summary(summary)
        for heading in ("Task", "Lane", "Median", "Tool calls", "Recoveries", "Verified", "User help", "Interpretation"):
            self.assertIn(heading, table)

    def test_blocked_lane_without_measurements_remains_in_summary(self):
        record = benchmark.make_record(
            task="focus-next-control",
            lane="mac-control",
            phase="warmup",
            sample=1,
            duration_ms=0,
            tool_calls=2,
            recoveries=1,
            verified=False,
            user_help=False,
            status="blocked",
            oracle="focus changed",
            notes="lease blocked",
        )
        summary = benchmark.summarize_records([record])
        group = summary["groups"][0]
        self.assertEqual(group["samples"], 0)
        self.assertIsNone(group["median_ms"])
        self.assertEqual(group["status"], "blocked")
        self.assertIn("lease blocked", group["interpretation"])

    def test_mac_focus_uses_atomic_app_control_for_prime_and_samples(self):
        calls = []

        def fake_run_json(command):
            calls.append(command)
            if command[1:3] == ["control", "perform"]:
                return (
                    {
                        "status": "succeeded",
                        "evidence": [{"source": "macctld"}],
                        "result": {
                            "route": "keyboard",
                            "verification": {
                                "state": "passed",
                                "focusChanged": True,
                                "focusAfter": {"role": "AXTextField"},
                            },
                        },
                    },
                    1.0,
                )
            raise AssertionError(f"unexpected measured command: {command}")

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="System Settings",
                warmups=0,
                samples=1,
                sample_offset=3,
                output=Path(directory) / "raw.jsonl",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_focus(args), 0)
            self.assertEqual(benchmark.load_records(args.output)[0]["sample"], 4)

        self.assertEqual(calls[0][1:4], ["control", "perform", "next-control"])
        self.assertEqual(calls[0][4:7], ["--app", "System Settings", "--confirm"])
        self.assertNotIn("--lease-token", calls[0])
        self.assertEqual(
            [command[3] for command in calls],
            ["next-control", "previous-control", "next-control", "previous-control"],
        )

    def test_mac_focus_rejects_negative_sample_offset(self):
        args = SimpleNamespace(sample_offset=-1)
        with self.assertRaisesRegex(ValueError, "sample offset"):
            benchmark.run_mac_focus(args)

    def test_focus_precondition_requires_observed_focus_after(self):
        payload = {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {
                "route": "keyboard",
                "verification": {"state": "foreground_only", "focusChanged": False},
            },
        }
        self.assertFalse(benchmark.focus_established(payload))
        payload["result"]["verification"]["focusAfter"] = {"role": "AXTextField"}
        self.assertTrue(benchmark.focus_established(payload))


if __name__ == "__main__":
    unittest.main()
