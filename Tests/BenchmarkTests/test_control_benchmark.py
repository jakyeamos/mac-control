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
    @staticmethod
    def foreground_status_payload(bundle_id="com.example.ForegroundApp", name="ForegroundApp"):
        return {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {
                "foregroundApplication": {
                    "name": name,
                    "bundleID": bundle_id,
                    "path": "/Applications/Foreground.app",
                }
            },
        }

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

    def test_focus_policy_and_interaction_mode_are_versioned_and_validated(self):
        record = benchmark.make_record(
            task="focus-next-control",
            lane="mac-control",
            phase="measured",
            sample=1,
            duration_ms=12.0,
            tool_calls=1,
            recoveries=0,
            verified=True,
            user_help=False,
            status="passed",
            oracle="focus changed",
            focus_policy="foreground",
            interaction_mode="keyboard",
        )
        self.assertEqual(record["schema_version"], 4)
        self.assertEqual(record["focus_policy"], "foreground")
        self.assertEqual(record["interaction_mode"], "keyboard")
        with self.assertRaisesRegex(ValueError, "unknown focus policy"):
            benchmark.make_record(
                task="task-a",
                lane="mac-control",
                phase="measured",
                sample=1,
                duration_ms=1.0,
                tool_calls=1,
                recoveries=0,
                verified=True,
                user_help=False,
                status="passed",
                oracle="done",
                focus_policy="implicit",
            )
        with self.assertRaisesRegex(ValueError, "unknown interaction mode"):
            benchmark.make_record(
                task="task-a",
                lane="mac-control",
                phase="measured",
                sample=1,
                duration_ms=1.0,
                tool_calls=1,
                recoveries=0,
                verified=True,
                user_help=False,
                status="passed",
                oracle="done",
                interaction_mode="vision-only",
            )

    def test_summary_separates_foreground_and_background_focus_policies(self):
        records = []
        for sample, focus_policy in enumerate(("foreground", "background"), 1):
            records.append(
                benchmark.make_record(
                    task="focus-next-control",
                    lane="mac-control",
                    phase="measured",
                    sample=sample,
                    duration_ms=10.0,
                    tool_calls=1,
                    recoveries=0,
                    verified=True,
                    user_help=False,
                    status="passed",
                    oracle="focus changed",
                    comparison_id="focus-policy-v1",
                    app="Target",
                    target_fingerprint="target-v1",
                    state_fingerprint="state-v1",
                    implementation_id="mac-control",
                    build_id=f"daemon-{focus_policy}",
                    timing_scope="end_to_end_verified_action",
                    focus_policy=focus_policy,
                    interaction_mode="keyboard",
                    foreground_oracle="foreground_unchanged",
                    foreground_state="preserved",
                    provenance="daemon_executed",
                )
            )
        summary = benchmark.summarize_records(records)
        self.assertEqual(len(summary["comparisons"]), 2)
        self.assertTrue(all(item["variant_count"] == 1 for item in summary["comparisons"]))
        self.assertTrue(all(item["status"] == "insufficient_evidence" for item in summary["comparisons"]))

    def test_summary_separates_keyboard_parity_from_provider_natural_pointer_mode(self):
        records = []
        for sample, interaction_mode in enumerate(("keyboard", "pointer"), 1):
            records.append(
                benchmark.make_record(
                    task="focus-or-pointer-action",
                    lane="generic-gui",
                    phase="measured",
                    sample=sample,
                    duration_ms=10.0,
                    tool_calls=1,
                    recoveries=0,
                    verified=True,
                    user_help=False,
                    status="passed",
                    oracle="target postcondition changed",
                    comparison_id="provider-natural-v1",
                    app="Target",
                    target_fingerprint="target-v1",
                    state_fingerprint="state-v1",
                    implementation_id="computer-use-agent",
                    build_id="computer-use-v1",
                    timing_scope="end_to_end_verified_action",
                    focus_policy="foreground",
                    interaction_mode=interaction_mode,
                    provenance="computer_use",
                )
            )
        summary = benchmark.summarize_records(records)
        self.assertEqual(len(summary["comparisons"]), 2)
        self.assertEqual(
            {item["interaction_mode"] for item in summary["comparisons"]},
            {"keyboard", "pointer"},
        )

    def test_foreground_evidence_without_focus_policy_is_not_promoted(self):
        record = benchmark.make_record(
            task="focus-next-control",
            lane="mac-control",
            phase="measured",
            sample=1,
            duration_ms=10.0,
            tool_calls=1,
            recoveries=0,
            verified=True,
            user_help=False,
            status="passed",
            oracle="focus changed",
            comparison_id="focus-legacy-v1",
            target_fingerprint="target-v1",
            state_fingerprint="state-v1",
            foreground_oracle="foreground_unchanged",
            foreground_state="preserved",
        )
        group = benchmark.summarize_records([record])["groups"][0]
        self.assertFalse(group["foreground_complete"])
        self.assertIn("focus policy", group["interpretation"])

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
        status_payload = self.foreground_status_payload(name="Finder")

        def fake_run_json(command):
            calls.append(command)
            if command[1:3] == ["control", "status"]:
                return status_payload, 0.25
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

        action_calls = [command for command in calls if command[1:3] == ["control", "perform"]]
        status_calls = [command for command in calls if command[1:3] == ["control", "status"]]
        self.assertEqual(len(action_calls), 4)
        self.assertEqual(len(status_calls), 8)
        self.assertEqual(
            [command[command.index("--direction") + 1] for command in action_calls],
            ["down", "up", "down", "up"],
        )
        self.assertIn("--identifier", action_calls[0])
        self.assertNotIn("--lease-token", action_calls[0])

    def test_mac_scroll_runner_preserves_fixture_task_identity(self):
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
        status_payload = self.foreground_status_payload(name="System Settings")

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="System Settings",
                role="AXScrollArea",
                identifier="settings-scroll",
                direction="down",
                amount=1,
                reset_direction="up",
                reset_amount=1,
                warmups=0,
                samples=1,
                sample_offset=3,
                task="system-settings-accessibility-pane-scroll",
                record_route="accessibility-scroll",
                output=Path(directory) / "raw.jsonl",
                comparison_id="phase3-system-settings-accessibility-scroll-v2",
                target_fingerprint="system-settings-accessibility-content-scroll-v1",
                state_fingerprint="system-settings-accessibility-top-v1",
            )
            def fake_run_json(command):
                if command[1:3] == ["control", "status"]:
                    return status_payload, 0.25
                return payload, 7.25

            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_scroll(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["task"], args.task)
            self.assertEqual(records[0]["sample"], 4)
            self.assertEqual(records[0]["route"], args.record_route)

    def test_mac_scroll_runner_accepts_locator_digest_and_window_scope(self):
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
        status_payload = self.foreground_status_payload(name="Pronto")

        def fake_run_json(command):
            calls.append(command)
            if command[1:3] == ["control", "status"]:
                return status_payload, 0.25
            return payload, 8.0

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="Pronto",
                role="AXScrollArea",
                identifier=None,
                locator_digest="redacted-locator-digest",
                ancestor_digest="redacted-ancestor-digest",
                geometry_digest="redacted-geometry-digest",
                window_title="Pronto",
                oracle="Pronto viewport changed",
                direction="down",
                amount=1,
                reset_direction="up",
                reset_amount=1,
                warmups=0,
                samples=1,
                sample_offset=0,
                output=Path(directory) / "raw.jsonl",
                comparison_id="scroll-pronto-e2e-v1",
                target_fingerprint="pronto-main-scroll-v1",
                state_fingerprint="pronto-main-ready-v1",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_scroll(args), 0)

            records = benchmark.load_records(args.output)
            self.assertEqual(records[0]["oracle"], "Pronto viewport changed")

        action_calls = [command for command in calls if command[1:3] == ["control", "perform"]]
        self.assertIn("--locator-digest", action_calls[0])
        self.assertIn("--ancestor-digest", action_calls[0])
        self.assertIn("--geometry-digest", action_calls[0])
        self.assertIn("--window-title", action_calls[0])
        self.assertNotIn("--identifier", action_calls[0])

    def test_foreground_status_comparison_is_redacted_and_fail_closed(self):
        before = self.foreground_status_payload()
        after = self.foreground_status_payload()
        self.assertEqual(benchmark.foreground_status_identity(before), ("bundleID", "com.example.ForegroundApp"))
        self.assertEqual(benchmark.foreground_status_state(before, after), "preserved")
        self.assertTrue(benchmark.foreground_status_matches_target(before, "ForegroundApp"))
        self.assertTrue(benchmark.foreground_status_matches_target(before, "com.example.ForegroundApp"))
        self.assertFalse(benchmark.foreground_status_matches_target(before, "OtherApp"))
        self.assertEqual(
            benchmark.foreground_status_state(
                before,
                self.foreground_status_payload("com.example.OtherApp"),
            ),
            "changed",
        )
        self.assertEqual(
            benchmark.foreground_status_state(before, {"status": "succeeded"}),
            "unavailable",
        )

    def test_mac_scroll_runner_requires_named_target_to_be_frontmost(self):
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
        status_payload = self.foreground_status_payload(name="OtherApp")

        def fake_run_json(command):
            if command[1:3] == ["control", "status"]:
                return status_payload, 0.25
            return payload, 7.25

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="Finder",
                role="AXScrollArea",
                identifier="settings-scroll",
                direction="down",
                amount=1,
                reset_direction="up",
                reset_amount=1,
                warmups=0,
                samples=1,
                sample_offset=0,
                output=Path(directory) / "raw.jsonl",
                comparison_id="scroll-frontmost-v1",
                target_fingerprint="finder-scroll-v1",
                state_fingerprint="finder-ready-v1",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_scroll(args), 1)

            record = benchmark.load_records(args.output)[0]
            self.assertEqual(record["status"], "blocked")
            self.assertFalse(record["verified"])
            self.assertEqual(record["foreground_state"], "unavailable")
            self.assertIn("named target", record["notes"])

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
                                "foregroundBefore": {
                                    "bundleID": "com.apple.systempreferences",
                                    "path": "/System/Applications/System Settings.app",
                                },
                                "foregroundAfter": {
                                    "bundleID": "com.apple.systempreferences",
                                    "path": "/System/Applications/System Settings.app",
                                },
                                "foregroundChanged": False,
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
        self.assertEqual(calls[0][4:6], ["--app", "System Settings"])
        self.assertNotIn("--confirm", calls[0])
        self.assertNotIn("--lease-token", calls[0])
        self.assertEqual(
            [command[3] for command in calls],
            ["next-control", "previous-control", "next-control", "previous-control"],
        )

    def test_mac_focus_supports_named_item_navigation_with_explicit_reset(self):
        calls = []

        def fake_run_json(command):
            calls.append(command)
            return (
                {
                    "status": "succeeded",
                    "evidence": [{"source": "macctld"}],
                    "result": {
                        "route": "keyboard",
                        "verification": {
                            "state": "passed",
                            "focusChanged": True,
                            "focusAfter": {"role": "AXButton"},
                            "foregroundBefore": {
                                "bundleID": "com.apple.Notes",
                                "path": "/System/Applications/Notes.app",
                            },
                            "foregroundAfter": {
                                "bundleID": "com.apple.Notes",
                                "path": "/System/Applications/Notes.app",
                            },
                            "foregroundChanged": False,
                        },
                    },
                },
                1.0,
            )

        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(
                macctl="/tmp/macctl",
                app="Notes",
                action="next-item",
                reset_action="previous-item",
                task="focus-next-notes-item-v1",
                oracle="Accessibility focus changed to the next Notes item",
                warmups=0,
                samples=1,
                sample_offset=0,
                output=Path(directory) / "raw.jsonl",
                comparison_id="phase2-focus-notes-v1",
                target_fingerprint="notes-focus-v1",
                state_fingerprint="notes-focus-ready-v1",
            )
            with patch.object(benchmark, "run_json", side_effect=fake_run_json):
                self.assertEqual(benchmark.run_mac_focus(args), 0)
            record = benchmark.load_records(args.output)[0]

        self.assertEqual(record["task"], "focus-next-notes-item-v1")
        self.assertEqual(record["oracle"], "Accessibility focus changed to the next Notes item")
        self.assertEqual(record["focus_policy"], "foreground")
        self.assertEqual(record["interaction_mode"], "keyboard")
        self.assertEqual(
            [command[3] for command in calls],
            ["next-item", "previous-item", "next-item", "previous-item"],
        )

    def test_mac_focus_rejects_same_action_as_reset(self):
        args = SimpleNamespace(
            sample_offset=0,
            action="next-item",
            reset_action="next-item",
        )
        with self.assertRaisesRegex(ValueError, "must differ"):
            benchmark.run_mac_focus(args)

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

    def test_run_json_preserves_structured_provider_failure_metadata(self):
        payload = {
            "status": "blocked",
            "error": {
                "code": "control_verification_unavailable",
                "details": {
                    "failure_class": "verification_unavailable",
                    "route": "keyboard",
                    "verification": "foreground_only",
                    "fresh_state_required": True,
                },
            },
            "outcome": {
                "state": "verification_unavailable",
                "provider": "mac_control",
                "next_action": "refresh_state_before_retrying",
            },
        }
        completed = SimpleNamespace(returncode=1, stdout=json.dumps(payload), stderr="")
        with patch.object(benchmark.subprocess, "run", return_value=completed):
            with self.assertRaises(benchmark.CommandFailure) as raised:
                benchmark.run_json(["/tmp/macctl", "control", "perform", "next-control", "--json"])

        self.assertEqual(raised.exception.payload, payload)
        note = benchmark.summarize_command_failure(raised.exception)
        self.assertIn("code=control_verification_unavailable", note)
        self.assertIn("failure_class=verification_unavailable", note)
        self.assertIn("fresh_state_required=True", note)
        self.assertIn("next_action=refresh_state_before_retrying", note)

    def test_mac_focus_records_structured_provider_failure_without_raw_output(self):
        payload = {
            "status": "blocked",
            "error": {
                "code": "control_verification_unavailable",
                "details": {
                    "failure_class": "verification_unavailable",
                    "route": "keyboard",
                    "verification": "foreground_only",
                    "fresh_state_required": True,
                },
            },
            "outcome": {
                "state": "verification_unavailable",
                "next_action": "refresh_state_before_retrying",
            },
        }
        args = SimpleNamespace(
            macctl="/tmp/macctl",
            app="WhatsApp",
            warmups=0,
            samples=1,
            sample_offset=0,
            output=Path(tempfile.mkdtemp()) / "raw.jsonl",
        )
        with patch.object(
            benchmark,
            "run_json",
            side_effect=benchmark.CommandFailure(1, payload),
        ):
            self.assertEqual(benchmark.run_mac_focus(args), 1)

        record = benchmark.load_records(args.output)[0]
        self.assertEqual(record["status"], "blocked")
        self.assertIn("failure_class=verification_unavailable", record["notes"])
        self.assertIn("fresh_state_required=True", record["notes"])
        self.assertIn("next_action=refresh_state_before_retrying", record["notes"])
        self.assertIn("verification=foreground_only", record["notes"])

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

    def test_foreground_state_is_fail_closed_and_detects_identity_change(self):
        payload = {
            "status": "succeeded",
            "evidence": [{"source": "macctld"}],
            "result": {
                "route": "keyboard",
                "verification": {
                    "state": "passed",
                    "focusChanged": True,
                    "foregroundBefore": {"bundleID": "com.example.target", "path": "/Target.app"},
                    "foregroundAfter": {"bundleID": "com.example.target", "path": "/Target.app"},
                    "foregroundChanged": False,
                },
            },
        }
        self.assertEqual(benchmark.foreground_state(payload), "preserved")
        self.assertTrue(benchmark.focus_verified(payload))

        payload["result"]["verification"]["foregroundAfter"] = {
            "bundleID": "com.example.other",
            "path": "/Other.app",
        }
        self.assertEqual(benchmark.foreground_state(payload), "changed")
        self.assertFalse(benchmark.focus_verified(payload))

        del payload["result"]["verification"]["foregroundBefore"]
        self.assertEqual(benchmark.foreground_state(payload), "unavailable")

    def test_foreground_required_group_cannot_rank_without_preserved_samples(self):
        records = [
            benchmark.make_record(
                task="focus-next-control",
                lane="mac-control",
                phase="measured",
                sample=1,
                duration_ms=10.0,
                tool_calls=1,
                recoveries=0,
                verified=True,
                user_help=False,
                status="passed",
                oracle="focus changed",
                comparison_id="focus-foreground-v1",
                app="Target",
                target_fingerprint="target-v1",
                state_fingerprint="state-v1",
                implementation_id="mac-control",
                build_id="daemon-v1",
                timing_scope="end_to_end_verified_action",
                foreground_oracle="foreground_unchanged",
                foreground_state="unavailable",
                provenance="daemon_executed",
            )
        ]
        summary = benchmark.summarize_records(records)
        group = summary["groups"][0]
        comparison = summary["comparisons"][0]
        self.assertFalse(group["foreground_complete"])
        self.assertEqual(group["interpretation"], "focus policy or foreground-preservation oracle not satisfied")
        self.assertEqual(comparison["status"], "insufficient_evidence")


if __name__ == "__main__":
    unittest.main()
