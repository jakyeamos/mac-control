import importlib.util
import json
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

    def test_schema_v2_context_round_trips_without_sensitive_data(self):
        record = benchmark.make_record(
            task="focus-next-control",
            lane="mac-control",
            phase="measured",
            sample=1,
            duration_ms=12.3456,
            tool_calls=1,
            recoveries=0,
            verified=True,
            user_help=False,
            status="passed",
            oracle="focus changed",
            comparison_id="focus-system-settings-v1",
            app="System Settings",
            target_fingerprint="system-settings-focus-v1",
            state_fingerprint="system-settings-ready-v1",
            implementation_id="mac-control",
            build_id="daemon-build-a",
            timing_scope="command_round_trip",
            provenance="daemon_executed",
        )
        self.assertEqual(record["schema_version"], 2)
        self.assertEqual(record["comparison_id"], "focus-system-settings-v1")
        self.assertEqual(record["build_id"], "daemon-build-a")
        self.assertNotIn("lease_token", record)

    def test_hybrid_lane_is_an_explicit_provider_handoff_lane(self):
        record = benchmark.make_record(
            task="scroll-main",
            lane="hybrid",
            phase="measured",
            sample=1,
            duration_ms=25.0,
            tool_calls=4,
            recoveries=1,
            verified=True,
            user_help=False,
            status="passed",
            oracle="viewport changed after provider handoff",
            comparison_id="scroll-finder-hybrid-v1",
            app="Finder",
            target_fingerprint="finder-main-scroll-v1",
            state_fingerprint="finder-main-ready-v1",
            implementation_id="mac-control-computer-use-hybrid",
            build_id="hybrid-current",
            timing_scope="end_to_end_verified_action",
            provenance="provider_handoff",
        )
        self.assertEqual(record["lane"], "hybrid")
        self.assertEqual(record["provenance"], "provider_handoff")

    def test_pairwise_summary_separates_context_and_build_variants(self):
        def sample(lane, duration, *, build, target="target-a"):
            return benchmark.make_record(
                task="focus-next-control",
                lane=lane,
                phase="measured",
                sample=sample.index,
                duration_ms=duration,
                tool_calls=1,
                recoveries=0,
                verified=True,
                user_help=False,
                status="passed",
                oracle="focus changed",
                comparison_id="focus-system-settings-v1",
                app="System Settings",
                target_fingerprint=target,
                state_fingerprint="state-a",
                implementation_id="mac-control" if lane == "mac-control" else "direct",
                build_id=build,
                timing_scope="command_round_trip",
                provenance="daemon_executed" if lane == "mac-control" else "direct_system",
                route="keyboard" if lane == "mac-control" else "defaults",
            )

        records = []
        sample.index = 1
        for build, duration in (("daemon-old", 100.0), ("daemon-new", 80.0)):
            for _ in range(3):
                records.append(sample("mac-control", duration, build=build))
                sample.index += 1
        for _ in range(3):
            records.append(sample("agent-baseline", 120.0, build="direct-current"))
            sample.index += 1
        records.append(sample("mac-control", 90.0, build="daemon-new", target="target-b"))

        summary = benchmark.summarize_records(records)
        comparable = [item for item in summary["comparisons"] if item["status"] == "comparable"]
        self.assertEqual(len(comparable), 1)
        self.assertEqual(comparable[0]["variant_count"], 3)
        self.assertEqual(comparable[0]["fastest"]["build_id"], "daemon-new")
        separate = [item for item in summary["comparisons"] if item["target_fingerprint"] == "target-b"]
        self.assertEqual(len(separate), 1)
        self.assertEqual(separate[0]["status"], "insufficient_evidence")

    def test_summarize_merges_multiple_inputs_for_pairing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = []
            for lane, implementation, build, duration in (
                ("agent-baseline", "defaults", "direct-current", 10.0),
                ("mac-control", "macctld", "daemon-current", 20.0),
            ):
                input_path = root / f"{lane}.jsonl"
                inputs.append(input_path)
                for sample in range(1, 4):
                    benchmark.append_record(
                        input_path,
                        benchmark.make_record(
                            task="inspect-full-keyboard-access",
                            lane=lane,
                            phase="measured",
                            sample=sample,
                            duration_ms=duration,
                            tool_calls=1,
                            recoveries=0,
                            verified=True,
                            user_help=False,
                            status="passed",
                            oracle="Full Keyboard Access is enabled",
                            comparison_id="fka-status-v1",
                            app="macOS",
                            target_fingerprint="fka-v1",
                            state_fingerprint="login-session-v1",
                            implementation_id=implementation,
                            build_id=build,
                            timing_scope="command_round_trip",
                            provenance="direct_system" if lane == "agent-baseline" else "daemon_executed",
                            route="defaults" if lane == "agent-baseline" else "macctld",
                        ),
                    )

            json_output = root / "summary.json"
            markdown_output = root / "summary.md"
            args = benchmark.build_parser().parse_args(
                [
                    "summarize",
                    "--input",
                    str(inputs[0]),
                    "--input",
                    str(inputs[1]),
                    "--json-output",
                    str(json_output),
                    "--markdown-output",
                    str(markdown_output),
                ]
            )
            self.assertEqual(benchmark.summarize(args), 0)
            summary = json.loads(json_output.read_text(encoding="utf-8"))
            comparison = summary["comparisons"][0]
            self.assertEqual(comparison["status"], "comparable")
            self.assertEqual(comparison["variant_count"], 2)
            self.assertEqual(comparison["fastest"]["build_id"], "direct-current")
            self.assertIn("Pairwise comparisons", markdown_output.read_text(encoding="utf-8"))

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
        self.assertIn("Pairwise comparisons", table)

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

    def test_semantic_scroll_verification_requires_verified_daemon_outcome(self):
        payload = {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {"route": "scroll", "verification": "passed"},
            "outcome": {
                "state": "verified_success",
                "route": "scroll",
                "verification": "passed",
            },
        }
        self.assertTrue(benchmark.semantic_scroll_verified(payload))

        payload["outcome"]["state"] = "no_observed_change"
        self.assertFalse(benchmark.semantic_scroll_verified(payload))
        payload["outcome"]["state"] = "verified_success"
        payload["result"]["route"] = "input_scroll"
        self.assertFalse(benchmark.semantic_scroll_verified(payload))

    def test_mac_scroll_runner_times_only_verified_action_and_cleanup(self):
        calls = []
        payload = {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {"route": "scroll", "verification": "passed"},
            "outcome": {
                "state": "verified_success",
                "route": "scroll",
                "verification": "passed",
            },
        }

        def fake_run_json(command):
            calls.append(command)
            return payload, 12.3456

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="Finder",
                role="AXScrollArea",
                identifier="_NS:23",
                direction="down",
                amount=1,
                reset_direction="up",
                reset_amount=1,
                warmups=0,
                samples=1,
                sample_offset=0,
                output=Path(directory) / "raw.jsonl",
                comparison_id="scroll-finder-e2e-v1",
                target_fingerprint="finder-main-scroll-v1",
                state_fingerprint="finder-main-ready-v1",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_scroll(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["duration_ms"], 12.346)
            self.assertEqual(records[0]["timing_scope"], "end_to_end_verified_action")
            self.assertEqual(records[0]["tool_calls"], 1)
            self.assertTrue(records[0]["verified"])

        self.assertEqual(len(calls), 4)
        self.assertEqual(
            [command[command.index("--direction") + 1] for command in calls],
            ["down", "up", "down", "up"],
        )
        self.assertIn("--identifier", calls[0])
        self.assertNotIn("--lease-token", calls[0])

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

    def test_mac_focus_rejects_readable_but_unchanged_prime(self):
        payload = {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {
                "route": "keyboard",
                "verification": {
                    "state": "foreground_only",
                    "focusChanged": False,
                    "focusBefore": {"role": "AXScrollArea"},
                    "focusAfter": {"role": "AXScrollArea"},
                },
            },
        }
        args = SimpleNamespace(
            macctl="/tmp/macctl",
            app="System Settings",
            warmups=0,
            samples=1,
            sample_offset=0,
            output=Path(tempfile.mkdtemp()) / "raw.jsonl",
        )
        with patch.object(benchmark, "run_json", return_value=(payload, 1.0)):
            self.assertEqual(benchmark.run_mac_focus(args), 1)
        records = benchmark.load_records(args.output)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["status"], "blocked")
        self.assertEqual(records[0]["tool_calls"], 1)
        self.assertIn("focus-changing precondition", records[0]["notes"])

    def test_mac_focus_persists_command_failure_as_blocked_evidence(self):
        args = SimpleNamespace(
            macctl="/tmp/macctl",
            app="Notes",
            warmups=0,
            samples=1,
            sample_offset=0,
            output=Path(tempfile.mkdtemp()) / "raw.jsonl",
        )
        with patch.object(
            benchmark,
            "run_json",
            side_effect=RuntimeError("command failed with exit 1"),
        ):
            self.assertEqual(benchmark.run_mac_focus(args), 1)
        record = benchmark.load_records(args.output)[0]
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(record["tool_calls"], 1)
        self.assertIn("command failed with exit 1", record["notes"])

    def test_mac_batch_focus_uses_one_daemon_batch_per_phase_action(self):
        calls = []

        def fake_run_json(command, *, input_text=None):
            calls.append((command, input_text))
            actions = json.loads(input_text)
            return (
                {
                    "status": "succeeded",
                    "evidence": [{"source": "macctld"}],
                    "result": {
                        "actionCount": len(actions),
                        "completedCount": len(actions),
                        "leaseReleased": True,
                        "steps": [
                            {
                                "action": item["action"],
                                "route": "keyboard",
                                "verification": "passed",
                                "fallbackUsed": False,
                            }
                            for item in actions
                        ],
                    },
                },
                1.0,
            )

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="System Settings",
                steps=2,
                warmups=0,
                samples=1,
                sample_offset=0,
                output=Path(directory) / "raw.jsonl",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_batch_focus(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["task"], "focus-next-control-batch-2")
            self.assertEqual(records[0]["route"], "batch")

        self.assertEqual(len(calls), 4)
        self.assertEqual(
            [json.loads(input_text)[0]["action"] for _, input_text in calls],
            ["next-control", "previous-control", "next-control", "previous-control"],
        )
        self.assertEqual(len(json.loads(calls[2][1])), 2)
        self.assertIn("control", calls[2][0])
        self.assertIn("batch", calls[2][0])
        self.assertNotIn("--lease-token", calls[2][0])

    def test_direct_focus_uses_independent_system_events_and_verifies_samples(self):
        commands = []

        def fake_run(command, *, capture_output, text, check):
            commands.append(command)
            return SimpleNamespace(returncode=0, stdout="passed\n")

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                app="System Settings",
                warmups=0,
                samples=1,
                sample_offset=0,
                osascript="/usr/bin/osascript",
                output=Path(directory) / "raw.jsonl",
            )
            with patch.object(benchmark.subprocess, "run", side_effect=fake_run):
                self.assertEqual(benchmark.run_direct_focus(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["lane"], "agent-baseline")
            self.assertEqual(records[0]["route"], "system-events")
            self.assertEqual(records[0]["provenance"], "direct_ui_scripting")

        self.assertEqual(len(commands), 4)
        self.assertNotIn("macctl", " ".join(commands[0]))
        self.assertIn("AXFocusedUIElement", commands[2][2])
        self.assertIn("key code 48", commands[2][2])
        self.assertIn('return "passed"', commands[2][2])

    def test_direct_batch_focus_repeats_key_and_records_batch_lane(self):
        commands = []

        def fake_run(command, *, capture_output, text, check):
            commands.append(command)
            return SimpleNamespace(returncode=0, stdout="passed\n")

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                app="System Settings",
                steps=2,
                warmups=0,
                samples=1,
                sample_offset=0,
                osascript="/usr/bin/osascript",
                output=Path(directory) / "raw.jsonl",
            )
            with patch.object(benchmark.subprocess, "run", side_effect=fake_run):
                self.assertEqual(benchmark.run_direct_batch_focus(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["lane"], "agent-baseline")
            self.assertEqual(records[0]["route"], "system-events-batch")

        self.assertEqual(len(commands), 4)
        self.assertIn("repeat 2 times", commands[2][2])
        self.assertIn("key code 48", commands[2][2])
        self.assertIn("shift down", commands[3][2])

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
