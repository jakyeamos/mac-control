#!/usr/bin/env python3
"""Record and summarize controlled comparisons of macOS interaction lanes.

The benchmark intentionally stores only outcome metadata. Command output, lease
tokens, selector values, screenshots, and application content are never written
to the JSONL result stream.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LANES = {"agent-baseline", "generic-gui", "mac-control"}
PHASES = {"warmup", "measured"}
STATUSES = {"passed", "failed", "blocked"}
CONTEXT_FIELDS = (
    "comparison_id",
    "app",
    "target_fingerprint",
    "state_fingerprint",
    "implementation_id",
    "build_id",
    "timing_scope",
    "provenance",
)
SENSITIVE_KEYS = {
    "approval_token",
    "lease",
    "lease_token",
    "password",
    "secret",
    "token",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sensitive_key(path: str) -> bool:
    normalized = path.lower().replace("-", "_")
    return any(part in SENSITIVE_KEYS for part in normalized.split("."))


def assert_safe(value: Any, path: str = "record") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if sensitive_key(child_path):
                raise ValueError(f"sensitive field is not permitted: {child_path}")
            assert_safe(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            assert_safe(child, f"{path}[{index}]")


def append_record(path: Path, record: dict[str, Any]) -> None:
    assert_safe(record)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
    flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, payload.encode("utf-8"))
    finally:
        os.close(descriptor)


def make_record(
    *,
    task: str,
    lane: str,
    phase: str,
    sample: int,
    duration_ms: float,
    tool_calls: int,
    recoveries: int,
    verified: bool,
    user_help: bool,
    status: str,
    oracle: str,
    route: str | None = None,
    notes: str | None = None,
    comparison_id: str | None = None,
    app: str | None = None,
    target_fingerprint: str | None = None,
    state_fingerprint: str | None = None,
    implementation_id: str | None = None,
    build_id: str | None = None,
    timing_scope: str | None = None,
    provenance: str | None = None,
) -> dict[str, Any]:
    if lane not in LANES:
        raise ValueError(f"unknown lane: {lane}")
    if phase not in PHASES:
        raise ValueError(f"unknown phase: {phase}")
    if status not in STATUSES:
        raise ValueError(f"unknown status: {status}")
    if sample < 1 or duration_ms < 0 or tool_calls < 0 or recoveries < 0:
        raise ValueError("sample and metric counts must be non-negative")
    context = {
        "comparison_id": comparison_id,
        "app": app,
        "target_fingerprint": target_fingerprint,
        "state_fingerprint": state_fingerprint,
        "implementation_id": implementation_id,
        "build_id": build_id,
        "timing_scope": timing_scope,
        "provenance": provenance,
    }
    for key in CONTEXT_FIELDS:
        value = context[key]
        if value is not None:
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{key} must be a non-empty string")
            context[key] = value.strip()

    record: dict[str, Any] = {
        "schema_version": 2 if any(value is not None for value in context.values()) else 1,
        "recorded_at": utc_now(),
        "task": task,
        "lane": lane,
        "phase": phase,
        "sample": sample,
        "duration_ms": round(duration_ms, 3),
        "tool_calls": tool_calls,
        "recoveries": recoveries,
        "verified": verified,
        "user_help": user_help,
        "status": status,
        "oracle": oracle,
    }
    if route:
        record["route"] = route
    if notes:
        record["notes"] = notes
    record.update({key: value for key, value in context.items() if value is not None})
    return record


def record_context(
    args: argparse.Namespace,
    *,
    task: str,
    app: str | None = None,
    implementation_id: str | None = None,
    timing_scope: str | None = None,
    provenance: str | None = None,
) -> dict[str, str | None]:
    """Return redacted context that makes a comparison pairable and auditable."""

    return {
        "comparison_id": getattr(args, "comparison_id", None) or task,
        "app": app if app is not None else getattr(args, "app", None),
        "target_fingerprint": getattr(args, "target_fingerprint", None),
        "state_fingerprint": getattr(args, "state_fingerprint", None),
        "implementation_id": getattr(args, "implementation_id", None) or implementation_id,
        "build_id": getattr(args, "build_id", None),
        "timing_scope": getattr(args, "timing_scope", None) or timing_scope,
        "provenance": getattr(args, "provenance", None) or provenance,
    }


def run_json(command: list[str], *, input_text: str | None = None) -> tuple[dict[str, Any], float]:
    started = time.perf_counter_ns()
    completed = subprocess.run(
        command,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    duration_ms = (time.perf_counter_ns() - started) / 1_000_000
    if completed.returncode != 0:
        raise RuntimeError(f"command failed with exit {completed.returncode}")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("command did not return JSON") from error
    return payload, duration_ms


def result_object(payload: dict[str, Any]) -> dict[str, Any]:
    result = payload.get("result")
    if payload.get("status") != "succeeded" or not isinstance(result, dict):
        raise RuntimeError("macctl response was not a successful result")
    return result


def daemon_provenance(payload: dict[str, Any]) -> bool:
    evidence = payload.get("evidence")
    return isinstance(evidence, list) and any(
        isinstance(item, dict) and item.get("source") == "macctld" for item in evidence
    )


def run_fka_readonly(args: argparse.Namespace) -> int:
    task = "inspect-full-keyboard-access"
    for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
        for sample in range(1, count + 1):
            if args.lane == "agent-baseline":
                started = time.perf_counter_ns()
                completed = subprocess.run(
                    ["/usr/bin/defaults", "read", "-g", "AppleKeyboardUIMode"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                duration_ms = (time.perf_counter_ns() - started) / 1_000_000
                verified = completed.returncode == 0 and completed.stdout.strip() == "2"
                route = "defaults"
                implementation_id = "defaults"
                provenance = "direct_system"
            else:
                payload, duration_ms = run_json([args.macctl, "keyboard", "status", "--json"])
                result = result_object(payload)
                verified = (
                    result.get("fullKeyboardAccessEnabled") is True
                    and daemon_provenance(payload)
                )
                route = "macctld"
                implementation_id = "macctld"
                provenance = "daemon_executed"
            append_record(
                args.output,
                make_record(
                    task=task,
                    lane=args.lane,
                    phase=phase,
                    sample=sample,
                    duration_ms=duration_ms,
                    tool_calls=1,
                    recoveries=0,
                    verified=verified,
                    user_help=False,
                    status="passed" if verified else "failed",
                    oracle="Full Keyboard Access is enabled",
                    route=route,
                    **record_context(
                        args,
                        task=task,
                        implementation_id=implementation_id,
                        timing_scope="command_round_trip",
                        provenance=provenance,
                    ),
                ),
            )
            if not verified:
                return 1
    return 0


def focus_verified(payload: dict[str, Any]) -> bool:
    result = result_object(payload)
    verification = result.get("verification")
    return (
        daemon_provenance(payload)
        and result.get("route") == "keyboard"
        and isinstance(verification, dict)
        and verification.get("state") == "passed"
        and verification.get("focusChanged") is True
    )


def focus_established(payload: dict[str, Any]) -> bool:
    result = result_object(payload)
    verification = result.get("verification")
    return (
        daemon_provenance(payload)
        and result.get("route") == "keyboard"
        and isinstance(verification, dict)
        and isinstance(verification.get("focusAfter"), dict)
    )


def semantic_scroll_verified(payload: dict[str, Any]) -> bool:
    """Require daemon, route, result, and provider-neutral success evidence."""

    result = payload.get("result")
    outcome = payload.get("outcome")
    return (
        payload.get("status") == "succeeded"
        and daemon_provenance(payload)
        and isinstance(result, dict)
        and result.get("route") == "scroll"
        and result.get("verification") == "passed"
        and isinstance(outcome, dict)
        and outcome.get("state") == "verified_success"
        and outcome.get("route") == "scroll"
        and outcome.get("verification") == "passed"
    )


def run_mac_scroll(args: argparse.Namespace) -> int:
    """Measure one atomic, daemon-executed semantic scroll end to end."""

    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")
    if args.warmups < 0 or args.samples < 1:
        raise ValueError("warmups must be non-negative and samples must be positive")
    if args.amount < 1 or args.reset_amount < 1:
        raise ValueError("scroll amounts must be positive")
    if args.direction == args.reset_direction:
        raise ValueError("reset direction must differ from scroll direction")
    if not args.identifier:
        raise ValueError("scroll benchmark requires a stable target identifier")

    task = "scroll-main"
    oracle = "Finder main content viewport changed"
    context = record_context(
        args,
        task=task,
        app=args.app,
        implementation_id="mac-control",
        timing_scope="end_to_end_verified_action",
        provenance="daemon_executed",
    )
    command_count = 0

    def perform(direction: str, amount: int) -> tuple[dict[str, Any], float]:
        nonlocal command_count
        command_count += 1
        command = [
            args.macctl,
            "control",
            "perform",
            "scroll",
            "--app",
            args.app,
            "--role",
            args.role,
            "--identifier",
            args.identifier,
            "--direction",
            direction,
            "--amount",
            str(amount),
            "--confirm",
            "--json",
        ]
        return run_json(command)

    def blocked(reason: str) -> int:
        append_record(
            args.output,
            make_record(
                task=task,
                lane="mac-control",
                phase="warmup",
                sample=max(1, args.sample_offset + 1),
                duration_ms=0,
                tool_calls=command_count,
                recoveries=1,
                verified=False,
                user_help=False,
                status="blocked",
                oracle=oracle,
                route="scroll",
                notes=reason,
                **context,
            ),
        )
        return 1

    try:
        # Establish a known, non-boundary starting point before timing. The
        # first direction must change the viewport so the opposite reset is
        # observable and verified rather than assumed.
        primed, _ = perform(args.direction, args.amount)
        if not semantic_scroll_verified(primed):
            return blocked("semantic scroll could not establish a verified precondition")
        restored, _ = perform(args.reset_direction, args.reset_amount)
        if not semantic_scroll_verified(restored):
            return blocked("semantic scroll precondition reset did not verify")

        for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
            for sample in range(1, count + 1):
                payload, duration_ms = perform(args.direction, args.amount)
                verified = semantic_scroll_verified(payload)
                reset, _ = perform(args.reset_direction, args.reset_amount)
                reset_verified = semantic_scroll_verified(reset)
                cleanup_ok = reset_verified
                status = "passed" if verified and cleanup_ok else "failed"
                notes = None
                if not verified:
                    notes = "semantic scroll did not reach verified_success"
                elif not cleanup_ok:
                    notes = "timed action verified but required reset did not verify"
                append_record(
                    args.output,
                    make_record(
                        task=task,
                        lane="mac-control",
                        phase=phase,
                        sample=sample + args.sample_offset,
                        duration_ms=duration_ms,
                        tool_calls=1,
                        recoveries=0 if cleanup_ok else 1,
                        verified=verified,
                        user_help=False,
                        status=status,
                        oracle=oracle,
                        route="scroll",
                        notes=notes,
                        **context,
                    ),
                )
                if not verified or not cleanup_ok:
                    return 1
    except (OSError, RuntimeError, ValueError) as error:
        return blocked(f"benchmark setup or execution blocked: {error}")
    return 0


def run_mac_focus(args: argparse.Namespace) -> int:
    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")

    context = record_context(
        args,
        task="focus-next-control",
        app=args.app,
        implementation_id="mac-control",
        timing_scope="command_round_trip",
        provenance="daemon_executed",
    )

    def perform(action: str) -> tuple[dict[str, Any], float]:
        return run_json(
            [
                args.macctl,
                "control",
                "perform",
                action,
                "--app",
                args.app,
                "--confirm",
                "--json",
            ]
        )

    # An app activation can legitimately restore the window without an AX
    # focused control. Prime that precondition outside the timer. Each action is
    # nevertheless self-contained: the daemon reasserts stable foreground,
    # acquires an ephemeral app lease, verifies, and releases before replying.
    primed, _ = perform("next-control")
    if not focus_verified(primed):
        if focus_established(primed):
            raise RuntimeError("Mac Control could not establish a focus-changing precondition")
        raise RuntimeError("Mac Control could not establish a readable focus precondition")
    restored, _ = perform("previous-control")
    if not focus_verified(restored):
        raise RuntimeError("precondition focus reset did not verify")

    for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
        for sample in range(1, count + 1):
            payload, duration_ms = perform("next-control")
            verified = focus_verified(payload)
            append_record(
                args.output,
                make_record(
                    task="focus-next-control",
                    lane="mac-control",
                    phase=phase,
                    sample=sample + args.sample_offset,
                    duration_ms=duration_ms,
                    tool_calls=1,
                    recoveries=0,
                    verified=verified,
                    user_help=False,
                    status="passed" if verified else "failed",
                    oracle="Accessibility focus changed to the next control",
                    route="keyboard",
                    **context,
                ),
            )
            if not verified:
                return 1

            reset, _ = perform("previous-control")
            if not focus_verified(reset):
                raise RuntimeError("focus reset did not verify")
    return 0


def batch_input(action: str, count: int) -> str:
    if count < 1:
        raise ValueError("batch action count must be positive")
    return json.dumps([{"action": action} for _ in range(count)]) + "\n"


def batch_verified(
    payload: dict[str, Any],
    *,
    actions: list[str],
    route: str = "keyboard",
) -> bool:
    result = result_object(payload)
    steps = result.get("steps")
    return (
        daemon_provenance(payload)
        and result.get("actionCount") == len(actions)
        and result.get("completedCount") == len(actions)
        and result.get("leaseReleased") is True
        and isinstance(steps, list)
        and len(steps) == len(actions)
        and all(
            isinstance(step, dict)
            and step.get("action") == action
            and step.get("route") == route
            and step.get("verification") == "passed"
            and step.get("fallbackUsed") is False
            for step, action in zip(steps, actions)
        )
    )


def run_mac_batch_focus(args: argparse.Namespace) -> int:
    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")
    if args.steps < 1 or args.steps > 32:
        raise ValueError("steps must be between 1 and 32")

    task = f"focus-next-control-batch-{args.steps}"
    context = record_context(
        args,
        task=task,
        app=args.app,
        implementation_id="mac-control-batch",
        timing_scope="command_round_trip",
        provenance="daemon_executed",
    )

    def perform(action: str, count: int) -> tuple[dict[str, Any], float]:
        return run_json(
            [
                args.macctl,
                "control",
                "batch",
                "--app",
                args.app,
                "--actions-stdin",
                "--confirm",
                "--json",
            ],
            input_text=batch_input(action, count),
        )

    primed, _ = perform("next-control", 1)
    if not batch_verified(primed, actions=["next-control"]):
        raise RuntimeError("Mac Control batch could not establish a focus-changing precondition")
    restored, _ = perform("previous-control", 1)
    if not batch_verified(restored, actions=["previous-control"]):
        raise RuntimeError("Mac Control batch precondition focus reset did not verify")

    actions = ["next-control"] * args.steps
    reset_actions = ["previous-control"] * args.steps
    for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
        for sample in range(1, count + 1):
            payload, duration_ms = perform("next-control", args.steps)
            verified = batch_verified(payload, actions=actions)
            append_record(
                args.output,
                make_record(
                    task=task,
                    lane="mac-control",
                    phase=phase,
                    sample=sample + args.sample_offset,
                    duration_ms=duration_ms,
                    tool_calls=1,
                    recoveries=0,
                    verified=verified,
                    user_help=False,
                    status="passed" if verified else "failed",
                    oracle=f"Accessibility focus advanced through {args.steps} controls",
                    route="batch",
                    **context,
                ),
            )
            if not verified:
                return 1

            reset, _ = perform("previous-control", args.steps)
            if not batch_verified(reset, actions=reset_actions):
                raise RuntimeError("Mac Control batch focus reset did not verify")
    return 0


def direct_focus_script(action: str, count: int = 1) -> str:
    if action not in {"next-control", "previous-control"}:
        raise ValueError(f"unsupported direct focus action: {action}")
    if count < 1:
        raise ValueError("focus action count must be positive")
    key_event = "key code 48 using {shift down}" if action == "previous-control" else "key code 48"
    return f'''tell application "System Events"
    set targetProcess to process "System Settings"
    set frontmost of targetProcess to true
    delay 0.05
    tell targetProcess
        try
            set beforeElement to value of attribute "AXFocusedUIElement"
        on error
            return "blocked"
        end try
    end tell
    repeat {count} times
        {key_event}
        delay 0.02
    end repeat
    delay 0.02
    tell targetProcess
        set stillFrontmost to frontmost
        try
            set afterElement to value of attribute "AXFocusedUIElement"
        on error
            return "failed"
        end try
    end tell
    if stillFrontmost and (beforeElement is not afterElement) then
        return "passed"
    end if
    return "failed"
end tell'''


def run_direct_batch_focus(args: argparse.Namespace) -> int:
    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")
    if args.steps < 1 or args.steps > 32:
        raise ValueError("steps must be between 1 and 32")
    if args.app != "System Settings":
        raise ValueError("direct focus benchmark currently supports System Settings only")

    task = f"focus-next-control-batch-{args.steps}"
    context = record_context(
        args,
        task=task,
        app=args.app,
        implementation_id="system-events-batch",
        timing_scope="command_round_trip",
        provenance="direct_ui_scripting",
    )

    def perform(action: str, count: int) -> tuple[bool, float]:
        started = time.perf_counter_ns()
        completed = subprocess.run(
            [args.osascript, "-e", direct_focus_script(action, count)],
            capture_output=True,
            text=True,
            check=False,
        )
        verified = completed.returncode == 0 and completed.stdout.strip() == "passed"
        duration_ms = (time.perf_counter_ns() - started) / 1_000_000
        return verified, duration_ms

    primed, _ = perform("next-control", 1)
    if not primed:
        raise RuntimeError("direct UI scripting could not establish a focus-changing precondition")
    restored, _ = perform("previous-control", 1)
    if not restored:
        raise RuntimeError("direct UI scripting batch precondition focus reset did not verify")

    for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
        for sample in range(1, count + 1):
            verified, duration_ms = perform("next-control", args.steps)
            append_record(
                args.output,
                make_record(
                    task=task,
                    lane="agent-baseline",
                    phase=phase,
                    sample=sample + args.sample_offset,
                    duration_ms=duration_ms,
                    tool_calls=1,
                    recoveries=0,
                    verified=verified,
                    user_help=False,
                    status="passed" if verified else "failed",
                    oracle=f"Accessibility focus advanced through {args.steps} controls",
                    route="system-events-batch",
                    **context,
                ),
            )
            if not verified:
                return 1

            reset, _ = perform("previous-control", args.steps)
            if not reset:
                raise RuntimeError("direct focus batch reset did not verify")
    return 0


def run_direct_focus(args: argparse.Namespace) -> int:
    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")
    if args.app != "System Settings":
        raise ValueError("direct focus benchmark currently supports System Settings only")

    context = record_context(
        args,
        task="focus-next-control",
        app=args.app,
        implementation_id="system-events",
        timing_scope="command_round_trip",
        provenance="direct_ui_scripting",
    )

    def perform(action: str) -> tuple[bool, float]:
        started = time.perf_counter_ns()
        completed = subprocess.run(
            [args.osascript, "-e", direct_focus_script(action)],
            capture_output=True,
            text=True,
            check=False,
        )
        verified = completed.returncode == 0 and completed.stdout.strip() == "passed"
        duration_ms = (time.perf_counter_ns() - started) / 1_000_000
        return verified, duration_ms

    # Establish a readable focus and restore the caller's starting control
    # outside the timer. Every measured direct action still includes activation,
    # event dispatch, independent AX verification, and subprocess cleanup.
    primed, _ = perform("next-control")
    if not primed:
        raise RuntimeError("direct UI scripting could not establish a focus-changing precondition")
    restored, _ = perform("previous-control")
    if not restored:
        raise RuntimeError("direct UI scripting precondition focus reset did not verify")

    for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
        for sample in range(1, count + 1):
            verified, duration_ms = perform("next-control")
            append_record(
                args.output,
                make_record(
                    task="focus-next-control",
                    lane="agent-baseline",
                    phase=phase,
                    sample=sample + args.sample_offset,
                    duration_ms=duration_ms,
                    tool_calls=1,
                    recoveries=0,
                    verified=verified,
                    user_help=False,
                    status="passed" if verified else "failed",
                    oracle="Accessibility focus changed to the next control",
                    route="system-events",
                    **context,
                ),
            )
            if not verified:
                return 1

            reset, _ = perform("previous-control")
            if not reset:
                raise RuntimeError("direct focus reset did not verify")
    return 0


def record_manual(args: argparse.Namespace) -> int:
    append_record(
        args.output,
        make_record(
            task=args.task,
            lane=args.lane,
            phase=args.phase,
            sample=args.sample,
            duration_ms=args.duration_ms,
            tool_calls=args.tool_calls,
            recoveries=args.recoveries,
            verified=args.verified,
            user_help=args.user_help,
            status=args.status,
            oracle=args.oracle,
            route=args.route,
            notes=args.notes,
            **record_context(
                args,
                task=args.task,
                implementation_id="manual",
                timing_scope="external_manual",
                provenance="caller_supplied",
            ),
        ),
    )
    return 0


def load_records(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            record = json.loads(line)
            assert_safe(record)
            if record.get("schema_version") not in {1, 2}:
                raise ValueError(f"unsupported schema on line {line_number}")
            records.append(record)
    return records


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def comparison_key(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        record.get("comparison_id") or record["task"],
        record["task"],
        record.get("app"),
        record.get("target_fingerprint"),
        record.get("state_fingerprint"),
        record.get("timing_scope"),
    )


def variant_key(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        record["lane"],
        record.get("implementation_id"),
        record.get("build_id"),
        record.get("route"),
        record.get("provenance"),
    )


def group_context(key: tuple[tuple[Any, ...], tuple[Any, ...]]) -> dict[str, Any]:
    comparison, variant = key
    return {
        "comparison_id": comparison[0],
        "task": comparison[1],
        "app": comparison[2],
        "target_fingerprint": comparison[3],
        "state_fingerprint": comparison[4],
        "timing_scope": comparison[5],
        "lane": variant[0],
        "implementation_id": variant[1],
        "build_id": variant[2],
        "route": variant[3],
        "provenance": variant[4],
    }


def summarize_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    measured = [record for record in records if record["phase"] == "measured"]
    grouped: dict[tuple[tuple[Any, ...], tuple[Any, ...]], list[dict[str, Any]]] = {}
    all_grouped: dict[tuple[tuple[Any, ...], tuple[Any, ...]], list[dict[str, Any]]] = {}
    for record in records:
        key = (comparison_key(record), variant_key(record))
        all_grouped.setdefault(key, []).append(record)
    for record in measured:
        key = (comparison_key(record), variant_key(record))
        grouped.setdefault(key, []).append(record)

    groups: list[dict[str, Any]] = []
    for key, samples in sorted(grouped.items(), key=lambda item: str(item[0])):
        durations = [float(sample["duration_ms"]) for sample in samples]
        median = statistics.median(durations)
        coefficient = statistics.pstdev(durations) / median if median else 0.0
        group = {
            **group_context(key),
            "samples": len(samples),
            "median_ms": round(median, 3),
            "p95_ms": round(percentile(durations, 0.95), 3),
            "range_ms": round(max(durations) - min(durations), 3),
            "mean_tool_calls": round(statistics.mean(s["tool_calls"] for s in samples), 2),
            "recoveries": sum(s["recoveries"] for s in samples),
            "verified": sum(bool(s["verified"]) for s in samples),
            "user_help": sum(bool(s["user_help"]) for s in samples),
            "status": "passed" if all(s["status"] == "passed" for s in samples) else "mixed",
            "expand_to_seven": len(samples) < 3 or (len(samples) == 3 and coefficient > 0.15),
            "interpretation": "passed",
        }
        groups.append(group)

    measured_keys = set(grouped)
    for key, attempts in sorted(all_grouped.items(), key=lambda item: str(item[0])):
        if key in measured_keys:
            continue
        latest = max(attempts, key=lambda record: record["recorded_at"])
        status = "blocked" if any(record["status"] == "blocked" for record in attempts) else "failed"
        reason = latest.get("notes", "no measured sample satisfied the oracle")
        groups.append(
            {
                **group_context(key),
                "samples": 0,
                "median_ms": None,
                "p95_ms": None,
                "range_ms": None,
                "mean_tool_calls": None,
                "recoveries": sum(sample["recoveries"] for sample in attempts),
                "verified": 0,
                "user_help": sum(bool(sample["user_help"]) for sample in attempts),
                "status": status,
                "expand_to_seven": False,
                "interpretation": f"{status} before measurement: {reason}",
            }
        )

    groups.sort(key=lambda group: (
        group["comparison_id"],
        group["task"],
        group["app"] or "",
        group["lane"],
        group["implementation_id"] or "",
        group["build_id"] or "",
    ))

    by_comparison: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for group in groups:
        key = (
            group["comparison_id"],
            group["task"],
            group["app"],
            group["target_fingerprint"],
            group["state_fingerprint"],
            group["timing_scope"],
        )
        by_comparison.setdefault(key, []).append(group)

    comparisons: list[dict[str, Any]] = []
    for key, variants in sorted(by_comparison.items(), key=lambda item: str(item[0])):
        eligible = [
            group for group in variants
            if group["samples"] > 0
            and group["status"] == "passed"
            and group["verified"] == group["samples"]
        ]
        fastest = min(eligible, key=lambda group: group["median_ms"]) if eligible else None
        comparisons.append(
            {
                "comparison_id": key[0],
                "task": key[1],
                "app": key[2],
                "target_fingerprint": key[3],
                "state_fingerprint": key[4],
                "timing_scope": key[5],
                "status": "comparable" if len(eligible) >= 2 else "insufficient_evidence",
                "variant_count": len(eligible),
                "fastest": None if fastest is None else {
                    "lane": fastest["lane"],
                    "implementation_id": fastest["implementation_id"],
                    "build_id": fastest["build_id"],
                    "median_ms": fastest["median_ms"],
                },
                "variants": [
                    {
                        "lane": group["lane"],
                        "implementation_id": group["implementation_id"],
                        "build_id": group["build_id"],
                        "route": group["route"],
                        "provenance": group["provenance"],
                        "samples": group["samples"],
                        "median_ms": group["median_ms"],
                        "p95_ms": group["p95_ms"],
                        "verified": group["verified"],
                        "recoveries": group["recoveries"],
                    }
                    for group in variants
                ],
            }
        )

    for group in groups:
        comparison_variants = by_comparison[
            (
                group["comparison_id"],
                group["task"],
                group["app"],
                group["target_fingerprint"],
                group["state_fingerprint"],
                group["timing_scope"],
            )
        ]
        ranked = sorted(
            (candidate for candidate in comparison_variants if candidate["median_ms"] is not None),
            key=lambda candidate: candidate["median_ms"],
        )
        if len(ranked) >= 2 and ranked[1]["median_ms"]:
            gap = (ranked[1]["median_ms"] - ranked[0]["median_ms"]) / ranked[1]["median_ms"]
            if gap < 0.10:
                ranked[0]["expand_to_seven"] = True
                ranked[1]["expand_to_seven"] = True

        if group["expand_to_seven"]:
            group["interpretation"] = "expand to 7 samples"
        elif group["status"] == "passed":
            group["interpretation"] = "passed"

    return {
        "schema_version": 2,
        "generated_at": utc_now(),
        "groups": groups,
        "comparisons": comparisons,
    }


def markdown_summary(summary: dict[str, Any]) -> str:
    lines = [
        "| Comparison | Task | App | Lane | Build | Median | Tool calls | Recoveries | Verified | User help | Interpretation |",
        "| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for group in summary["groups"]:
        median = "—" if group["median_ms"] is None else f"{group['median_ms']:.3f} ms"
        tool_calls = "—" if group["mean_tool_calls"] is None else f"{group['mean_tool_calls']:.2f}"
        comparison_id = group.get("comparison_id") or group["task"]
        app = group.get("app") or "—"
        build = group.get("build_id") or "—"
        lines.append(
            f"| {comparison_id} | {group['task']} | {app} | {group['lane']} | {build} | {median} | "
            f"{tool_calls} | {group['recoveries']} | "
            f"{group['verified']}/{group['samples']} | {group['user_help']} | {group['interpretation']} |"
        )
    lines.extend([
        "",
        "### Pairwise comparisons",
        "",
        "| Comparison | Task | App | Status | Variants | Fastest |",
        "| --- | --- | --- | --- | ---: | --- |",
    ])
    for comparison in summary.get("comparisons", []):
        fastest = comparison.get("fastest")
        fastest_label = "—" if fastest is None else (
            f"{fastest.get('lane')} / {fastest.get('build_id') or 'unidentified'} "
            f"({fastest.get('median_ms')} ms)"
        )
        lines.append(
            f"| {comparison['comparison_id']} | {comparison['task']} | "
            f"{comparison.get('app') or '—'} | {comparison['status']} | "
            f"{comparison['variant_count']} | {fastest_label} |"
        )
    return "\n".join(lines) + "\n"


def summarize(args: argparse.Namespace) -> int:
    records = [
        record
        for input_path in args.input
        for record in load_records(input_path)
    ]
    summary = summarize_records(records)
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_output.write_text(markdown_summary(summary), encoding="utf-8")
    return 0


def add_context_options(parser: argparse.ArgumentParser, *, include_app: bool) -> None:
    parser.add_argument("--comparison-id", help="stable ID for the same task/state across lanes or builds")
    if include_app:
        parser.add_argument("--app", help="redacted app identity used by the task")
    parser.add_argument("--target-fingerprint", help="redacted stable target identity")
    parser.add_argument("--state-fingerprint", help="redacted starting-state identity")
    parser.add_argument("--implementation-id", help="route/provider implementation identity")
    parser.add_argument("--build-id", help="opaque build or artifact identity")
    parser.add_argument("--timing-scope", help="timing boundary, such as command_round_trip")
    parser.add_argument("--provenance", help="measurement provenance, such as daemon_executed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fka = subparsers.add_parser("run-fka-readonly", help="measure the read-only FKA task")
    fka.add_argument("--lane", required=True, choices=["agent-baseline", "mac-control"])
    fka.add_argument("--warmups", type=int, default=1)
    fka.add_argument("--samples", type=int, default=3)
    fka.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    fka.add_argument("--output", required=True, type=Path)
    add_context_options(fka, include_app=True)
    fka.set_defaults(handler=run_fka_readonly)

    focus = subparsers.add_parser("run-mac-focus", help="measure atomic next-control navigation")
    focus.add_argument("--app", required=True)
    focus.add_argument("--warmups", type=int, default=1)
    focus.add_argument("--samples", type=int, default=3)
    focus.add_argument("--sample-offset", type=int, default=0)
    focus.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    focus.add_argument("--output", required=True, type=Path)
    add_context_options(focus, include_app=False)
    focus.set_defaults(handler=run_mac_focus)

    scroll = subparsers.add_parser(
        "run-mac-scroll",
        help="measure atomic semantic scroll including target resolution and verification",
    )
    scroll.add_argument("--app", required=True)
    scroll.add_argument("--role", default="AXScrollArea")
    scroll.add_argument("--identifier", required=True)
    scroll.add_argument("--direction", required=True, choices=["up", "down", "left", "right"])
    scroll.add_argument("--amount", type=int, default=1)
    scroll.add_argument("--reset-direction", required=True, choices=["up", "down", "left", "right"])
    scroll.add_argument("--reset-amount", type=int, default=1)
    scroll.add_argument("--warmups", type=int, default=1)
    scroll.add_argument("--samples", type=int, default=3)
    scroll.add_argument("--sample-offset", type=int, default=0)
    scroll.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    scroll.add_argument("--output", required=True, type=Path)
    add_context_options(scroll, include_app=False)
    scroll.set_defaults(handler=run_mac_scroll)

    batch_focus = subparsers.add_parser(
        "run-mac-batch-focus",
        help="measure bounded multi-step focus navigation through one Mac Control lease",
    )
    batch_focus.add_argument("--app", required=True)
    batch_focus.add_argument("--steps", type=int, default=2)
    batch_focus.add_argument("--warmups", type=int, default=1)
    batch_focus.add_argument("--samples", type=int, default=3)
    batch_focus.add_argument("--sample-offset", type=int, default=0)
    batch_focus.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    batch_focus.add_argument("--output", required=True, type=Path)
    add_context_options(batch_focus, include_app=False)
    batch_focus.set_defaults(handler=run_mac_batch_focus)

    direct_focus = subparsers.add_parser(
        "run-direct-focus",
        help="measure independent System Events focus navigation",
    )
    direct_focus.add_argument("--app", required=True, choices=["System Settings"])
    direct_focus.add_argument("--warmups", type=int, default=1)
    direct_focus.add_argument("--samples", type=int, default=3)
    direct_focus.add_argument("--sample-offset", type=int, default=0)
    direct_focus.add_argument("--osascript", default="/usr/bin/osascript")
    direct_focus.add_argument("--output", required=True, type=Path)
    add_context_options(direct_focus, include_app=False)
    direct_focus.set_defaults(handler=run_direct_focus)

    direct_batch_focus = subparsers.add_parser(
        "run-direct-batch-focus",
        help="measure independent System Events multi-step focus navigation",
    )
    direct_batch_focus.add_argument("--app", required=True, choices=["System Settings"])
    direct_batch_focus.add_argument("--steps", type=int, default=2)
    direct_batch_focus.add_argument("--warmups", type=int, default=1)
    direct_batch_focus.add_argument("--samples", type=int, default=3)
    direct_batch_focus.add_argument("--sample-offset", type=int, default=0)
    direct_batch_focus.add_argument("--osascript", default="/usr/bin/osascript")
    direct_batch_focus.add_argument("--output", required=True, type=Path)
    add_context_options(direct_batch_focus, include_app=False)
    direct_batch_focus.set_defaults(handler=run_direct_batch_focus)

    manual = subparsers.add_parser("record", help="append an externally timed trial")
    manual.add_argument("--task", required=True)
    manual.add_argument("--lane", required=True, choices=sorted(LANES))
    manual.add_argument("--phase", required=True, choices=sorted(PHASES))
    manual.add_argument("--sample", required=True, type=int)
    manual.add_argument("--duration-ms", required=True, type=float)
    manual.add_argument("--tool-calls", required=True, type=int)
    manual.add_argument("--recoveries", required=True, type=int)
    manual.add_argument("--status", required=True, choices=sorted(STATUSES))
    manual.add_argument("--oracle", required=True)
    manual.add_argument("--route")
    manual.add_argument("--notes")
    manual.add_argument("--verified", action=argparse.BooleanOptionalAction, default=False)
    manual.add_argument("--user-help", action=argparse.BooleanOptionalAction, default=False)
    manual.add_argument("--output", required=True, type=Path)
    add_context_options(manual, include_app=True)
    manual.set_defaults(handler=record_manual)

    report = subparsers.add_parser("summarize", help="write JSON and Markdown summaries")
    report.add_argument(
        "--input",
        required=True,
        action="append",
        type=Path,
        metavar="PATH",
        help="raw JSONL input; repeat to compare lanes or builds",
    )
    report.add_argument("--json-output", required=True, type=Path)
    report.add_argument("--markdown-output", required=True, type=Path)
    report.set_defaults(handler=summarize)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.handler(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1)
