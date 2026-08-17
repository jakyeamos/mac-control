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


LANES = {"agent-baseline", "generic-gui", "hybrid", "mac-control"}
PHASES = {"warmup", "measured"}
STATUSES = {"passed", "failed", "blocked"}
FOREGROUND_STATES = {"preserved", "changed", "unavailable"}
FOCUS_POLICIES = {"foreground", "background"}
INTERACTION_MODES = {"keyboard", "pointer", "scroll", "drag", "mixed"}
CONTEXT_FIELDS = (
    "comparison_id",
    "app",
    "target_fingerprint",
    "state_fingerprint",
    "implementation_id",
    "build_id",
    "timing_scope",
    "focus_policy",
    "interaction_mode",
    "foreground_oracle",
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
    focus_policy: str | None = None,
    interaction_mode: str | None = None,
    foreground_oracle: str | None = None,
    foreground_state: str | None = None,
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
    if focus_policy is not None and focus_policy not in FOCUS_POLICIES:
        raise ValueError(f"unknown focus policy: {focus_policy}")
    if interaction_mode is not None and interaction_mode not in INTERACTION_MODES:
        raise ValueError(f"unknown interaction mode: {interaction_mode}")
    if foreground_state is not None and foreground_state not in FOREGROUND_STATES:
        raise ValueError(f"unknown foreground state: {foreground_state}")
    if (foreground_oracle is None) != (foreground_state is None):
        raise ValueError("foreground oracle and foreground state must be supplied together")
    context = {
        "comparison_id": comparison_id,
        "app": app,
        "target_fingerprint": target_fingerprint,
        "state_fingerprint": state_fingerprint,
        "implementation_id": implementation_id,
        "build_id": build_id,
        "timing_scope": timing_scope,
        "focus_policy": focus_policy,
        "interaction_mode": interaction_mode,
        "foreground_oracle": foreground_oracle,
        "provenance": provenance,
    }
    for key in CONTEXT_FIELDS:
        value = context[key]
        if value is not None:
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{key} must be a non-empty string")
            context[key] = value.strip()

    record: dict[str, Any] = {
        "schema_version": (
            4
            if focus_policy is not None or interaction_mode is not None
            else (
                3
                if foreground_state is not None or foreground_oracle is not None
                else (2 if any(value is not None for value in context.values()) else 1)
            )
        ),
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
    if foreground_state is not None:
        record["foreground_state"] = foreground_state
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
    focus_policy: str | None = None,
    interaction_mode: str | None = None,
    foreground_oracle: str | None = None,
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
        "focus_policy": (
            focus_policy
            if focus_policy is not None
            else getattr(args, "focus_policy", None)
        ),
        "interaction_mode": (
            interaction_mode
            if interaction_mode is not None
            else getattr(args, "interaction_mode", None)
        ),
        "foreground_oracle": (
            foreground_oracle
            if foreground_oracle is not None
            else getattr(args, "foreground_oracle", None)
        ),
        "provenance": getattr(args, "provenance", None) or provenance,
    }


class CommandFailure(RuntimeError):
    """A command returned a structured provider failure response."""

    def __init__(self, returncode: int, payload: dict[str, Any] | None = None):
        self.returncode = returncode
        self.payload = payload
        super().__init__(f"command failed with exit {returncode}")


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
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        if completed.returncode != 0:
            raise RuntimeError(f"command failed with exit {completed.returncode}") from error
        raise RuntimeError("command did not return JSON") from error
    if not isinstance(payload, dict):
        if completed.returncode != 0:
            raise RuntimeError(f"command failed with exit {completed.returncode}")
        raise RuntimeError("command did not return a JSON object")
    if completed.returncode != 0:
        raise CommandFailure(completed.returncode, payload)
    return payload, duration_ms


def summarize_command_failure(error: CommandFailure) -> str:
    """Return bounded machine-readable failure metadata for a benchmark note."""

    payload = error.payload or {}
    error_object = payload.get("error") if isinstance(payload.get("error"), dict) else {}
    details = error_object.get("details") if isinstance(error_object.get("details"), dict) else {}
    outcome = payload.get("outcome") if isinstance(payload.get("outcome"), dict) else {}
    fields = [
        ("code", error_object.get("code")),
        ("failure_class", details.get("failure_class") or outcome.get("failure_class")),
        ("route", details.get("route") or outcome.get("route")),
        ("verification", details.get("verification") or outcome.get("verification")),
        ("outcome", outcome.get("state")),
        (
            "fresh_state_required",
            details.get("fresh_state_required")
            if "fresh_state_required" in details
            else outcome.get("fresh_state_required"),
        ),
        ("fallback_allowed", outcome.get("fallback_allowed")),
        ("recommended_provider", outcome.get("recommended_provider")),
        ("next_action", outcome.get("next_action")),
    ]
    rendered = [f"{key}={value}" for key, value in fields if value is not None]
    if rendered:
        return "provider failure: " + ", ".join(rendered)
    return str(error)


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
        and foreground_preserved(payload)
    )


def _foreground_identity(application: dict[str, Any]) -> tuple[str, str] | None:
    for key in ("bundleID", "path"):
        value = application.get(key)
        if isinstance(value, str) and value.strip():
            return key, value.strip()
    return None


def foreground_state(payload: dict[str, Any]) -> str:
    """Classify foreground evidence without treating missing fields as success."""

    result = payload.get("result")
    verification = result.get("verification") if isinstance(result, dict) else None
    if not isinstance(verification, dict):
        return "unavailable"
    before = verification.get("foregroundBefore")
    after = verification.get("foregroundAfter")
    if not isinstance(before, dict) or not isinstance(after, dict):
        return "unavailable"
    before_identity = _foreground_identity(before)
    after_identity = _foreground_identity(after)
    if before_identity is None or after_identity is None:
        return "unavailable"
    reported_changed = verification.get("foregroundChanged")
    if not isinstance(reported_changed, bool):
        return "unavailable"
    if reported_changed or before_identity != after_identity:
        return "changed"
    return "preserved"


def foreground_preserved(payload: dict[str, Any]) -> bool:
    return foreground_state(payload) == "preserved"


def foreground_status_identity(payload: dict[str, Any]) -> tuple[str, str] | None:
    """Read only the redacted foreground identity from ``control status``."""

    if payload.get("status") != "succeeded" or not daemon_provenance(payload):
        return None
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    application = result.get("foregroundApplication")
    if not isinstance(application, dict):
        application = result.get("foreground_application")
    return _foreground_identity(application) if isinstance(application, dict) else None


def foreground_status_application(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Return the redacted foreground application metadata for target matching."""

    if payload.get("status") != "succeeded" or not daemon_provenance(payload):
        return None
    result = payload.get("result")
    if not isinstance(result, dict):
        return None
    application = result.get("foregroundApplication")
    if not isinstance(application, dict):
        application = result.get("foreground_application")
    return application if isinstance(application, dict) else None


def foreground_status_matches_target(payload: dict[str, Any], target: str) -> bool:
    """Require the status snapshot to identify the named target as frontmost."""

    application = foreground_status_application(payload)
    normalized_target = target.strip().casefold()
    if application is None or not normalized_target:
        return False
    for key in ("name", "bundleID", "path"):
        value = application.get(key)
        if isinstance(value, str) and value.strip().casefold() == normalized_target:
            return True
    return False


def foreground_status_state(before: dict[str, Any], after: dict[str, Any]) -> str:
    """Compare status snapshots without persisting app names, titles, or content."""

    before_identity = foreground_status_identity(before)
    after_identity = foreground_status_identity(after)
    if before_identity is None or after_identity is None:
        return "unavailable"
    return "preserved" if before_identity == after_identity else "changed"


def combined_foreground_state(*states: str) -> str:
    """Collapse an action/reset pair conservatively; changed beats unavailable."""

    if "changed" in states:
        return "changed"
    if "unavailable" in states:
        return "unavailable"
    return "preserved"


def focus_established(payload: dict[str, Any]) -> bool:
    result = result_object(payload)
    verification = result.get("verification")
    return (
        daemon_provenance(payload)
        and result.get("route") == "keyboard"
        and isinstance(verification, dict)
        and isinstance(verification.get("focusAfter"), dict)
    )


FOCUS_ACTION_PAIRS = {
    "next-control": ("previous-control", "Accessibility focus changed to the next control"),
    "previous-control": ("next-control", "Accessibility focus changed to the previous control"),
    "next-item": ("previous-item", "Accessibility focus changed to the next item"),
    "previous-item": ("next-item", "Accessibility focus changed to the previous item"),
}


def focus_action_metadata(action: str, reset_action: str | None = None) -> tuple[str, str, str]:
    normalized_action = action.strip().lower().replace("_", "-")
    try:
        default_reset, oracle = FOCUS_ACTION_PAIRS[normalized_action]
    except KeyError as error:
        raise ValueError(f"unsupported focus action: {action}") from error

    normalized_reset = (reset_action or default_reset).strip().lower().replace("_", "-")
    if normalized_reset not in FOCUS_ACTION_PAIRS:
        raise ValueError(f"unsupported focus reset action: {reset_action}")
    if normalized_reset == normalized_action:
        raise ValueError("focus reset action must differ from the measured action")
    return normalized_action, normalized_reset, oracle


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
    locator_digest = getattr(args, "locator_digest", None)
    ancestor_digest = getattr(args, "ancestor_digest", None)
    if not args.identifier and not locator_digest:
        raise ValueError("scroll benchmark requires a stable target identifier or locator digest")

    # Keep the corpus task identity explicit when a fixture is more specific
    # than the historical scroll-main task. The default preserves the original
    # command contract while allowing daemon-executed samples to append to a
    # named paired comparison without caller-supplied timing.
    task = getattr(args, "task", None) or "scroll-main"
    record_route = getattr(args, "record_route", None) or "scroll"
    oracle = getattr(args, "oracle", None) or f"{args.app} main content viewport changed"
    context = record_context(
        args,
        task=task,
        app=args.app,
        implementation_id="mac-control",
        timing_scope="end_to_end_verified_action",
        focus_policy="foreground",
        interaction_mode="scroll",
        foreground_oracle="foreground_unchanged",
        provenance="daemon_executed",
    )
    command_count = 0

    def read_foreground_status() -> dict[str, Any]:
        payload, _ = run_json([args.macctl, "control", "status", "--json"])
        return payload

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
            "--direction",
            direction,
            "--amount",
            str(amount),
            "--confirm",
            "--json",
        ]
        if args.identifier:
            command[command.index("--direction"):command.index("--direction")] = [
                "--identifier",
                args.identifier,
            ]
        if locator_digest:
            command[command.index("--direction"):command.index("--direction")] = [
                "--locator-digest",
                locator_digest,
            ]
        if ancestor_digest:
            command[command.index("--direction"):command.index("--direction")] = [
                "--ancestor-digest",
                ancestor_digest,
            ]
        geometry_digest = getattr(args, "geometry_digest", None)
        if geometry_digest:
            command[command.index("--direction"):command.index("--direction")] = [
                "--geometry-digest",
                geometry_digest,
            ]
        if getattr(args, "window_title", None):
            command[command.index("--direction"):command.index("--direction")] = [
                "--window-title",
                args.window_title,
            ]
        return run_json(command)

    def perform_with_foreground(
        direction: str,
        amount: int,
    ) -> tuple[dict[str, Any], float, str, bool]:
        """Keep status probes outside the timed daemon action interval."""

        before = read_foreground_status()
        payload, duration_ms = perform(direction, amount)
        after = read_foreground_status()
        state = foreground_status_state(before, after)
        target_verified = (
            foreground_status_matches_target(before, args.app)
            and foreground_status_matches_target(after, args.app)
        )
        if state == "preserved" and not target_verified:
            state = "unavailable"
        return payload, duration_ms, state, target_verified

    def blocked(reason: str, state: str = "unavailable") -> int:
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
                route=record_route,
                notes=reason,
                foreground_state=state,
                **context,
            ),
        )
        return 1

    try:
        # Establish a known, non-boundary starting point before timing. The
        # first direction must change the viewport so the opposite reset is
        # observable and verified rather than assumed.
        primed, _, primed_foreground_state, primed_target_verified = perform_with_foreground(
            args.direction,
            args.amount,
        )
        if (
            not semantic_scroll_verified(primed)
            or primed_foreground_state != "preserved"
            or not primed_target_verified
        ):
            return blocked(
                "semantic scroll could not establish a verified precondition with the named target frontmost",
                primed_foreground_state,
            )
        restored, _, restored_foreground_state, restored_target_verified = perform_with_foreground(
            args.reset_direction,
            args.reset_amount,
        )
        if (
            not semantic_scroll_verified(restored)
            or restored_foreground_state != "preserved"
            or not restored_target_verified
        ):
            return blocked(
                "semantic scroll precondition reset did not verify with the named target frontmost",
                restored_foreground_state,
            )

        for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
            for sample in range(1, count + 1):
                payload, duration_ms, action_foreground_state, action_target_verified = perform_with_foreground(
                    args.direction,
                    args.amount,
                )
                action_verified = (
                    semantic_scroll_verified(payload)
                    and action_foreground_state == "preserved"
                    and action_target_verified
                )
                reset, _, reset_foreground_state, reset_target_verified = perform_with_foreground(
                    args.reset_direction,
                    args.reset_amount,
                )
                reset_verified = (
                    semantic_scroll_verified(reset)
                    and reset_foreground_state == "preserved"
                    and reset_target_verified
                )
                sample_foreground_state = combined_foreground_state(
                    action_foreground_state,
                    reset_foreground_state,
                )
                verified = action_verified and reset_verified
                cleanup_ok = reset_verified
                status = "passed" if verified and cleanup_ok else "failed"
                notes = None
                if not verified:
                    if not semantic_scroll_verified(payload):
                        notes = "semantic scroll did not reach verified_success"
                    elif not action_target_verified or not reset_target_verified:
                        notes = "named target was not frontmost for the bounded action or reset"
                    elif action_foreground_state != "preserved":
                        notes = "timed action did not preserve the foreground identity"
                    elif not semantic_scroll_verified(reset):
                        notes = "timed action verified but required reset did not reach verified_success"
                    else:
                        notes = "timed action or reset did not preserve the foreground identity"
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
                        route=record_route,
                        notes=notes,
                        foreground_state=sample_foreground_state,
                        **context,
                    ),
                )
                if not verified or not cleanup_ok:
                    return 1
    except CommandFailure as error:
        return blocked(summarize_command_failure(error))
    except (OSError, RuntimeError, ValueError) as error:
        return blocked(f"benchmark setup or execution blocked: {error}")
    return 0


def run_mac_focus(args: argparse.Namespace) -> int:
    if args.sample_offset < 0:
        raise ValueError("sample offset must be non-negative")

    action, reset_action, default_oracle = focus_action_metadata(
        getattr(args, "action", "next-control"),
        getattr(args, "reset_action", None),
    )
    task = getattr(args, "task", None) or f"focus-{action}"
    oracle = getattr(args, "oracle", None) or default_oracle
    context = record_context(
        args,
        task=task,
        app=args.app,
        implementation_id="mac-control",
        timing_scope="command_round_trip",
        focus_policy="foreground",
        interaction_mode="keyboard",
        foreground_oracle="foreground_unchanged",
        provenance="daemon_executed",
    )
    command_count = 0

    def perform(action_name: str) -> tuple[dict[str, Any], float]:
        nonlocal command_count
        command_count += 1
        return run_json(
            [
                args.macctl,
                "control",
                "perform",
                action_name,
                "--app",
                args.app,
                "--confirm",
                "--json",
            ]
        )

    def blocked(reason: str, state: str = "unavailable") -> int:
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
                route="keyboard",
                notes=reason,
                foreground_state=state,
                **context,
            ),
        )
        return 1

    try:
        # An app activation can legitimately restore the window without an AX
        # focused control. Prime that precondition outside the timer. Each action is
        # nevertheless self-contained: the daemon reasserts stable foreground,
        # acquires an ephemeral app lease, verifies, and releases before replying.
        primed, _ = perform(action)
        primed_foreground_state = foreground_state(primed)
        if not focus_verified(primed):
            if primed_foreground_state == "changed":
                return blocked("Mac Control changed the foreground during the focus precondition", primed_foreground_state)
            if focus_established(primed):
                return blocked(
                    "Mac Control could not establish a focus-changing precondition with foreground preservation",
                    primed_foreground_state,
                )
            return blocked(
                "Mac Control could not establish a readable focus and foreground precondition",
                primed_foreground_state,
            )
        restored, _ = perform(reset_action)
        restored_foreground_state = foreground_state(restored)
        if not focus_verified(restored):
            return blocked("precondition focus and foreground reset did not verify", restored_foreground_state)

        for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
            for sample in range(1, count + 1):
                payload, duration_ms = perform(action)
                action_foreground_state = foreground_state(payload)
                action_verified = focus_verified(payload)
                if not action_verified:
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
                            verified=False,
                            user_help=False,
                            status="failed",
                            oracle=oracle,
                            route="keyboard",
                            notes="focus action did not reach the focus-plus-foreground oracle",
                            foreground_state=action_foreground_state,
                            **context,
                        ),
                    )
                    return 1

                reset, _ = perform(reset_action)
                reset_foreground_state = foreground_state(reset)
                reset_verified = focus_verified(reset)
                sample_foreground_state = combined_foreground_state(
                    action_foreground_state,
                    reset_foreground_state,
                )
                sample_verified = action_verified and reset_verified
                notes = None if sample_verified else "timed action verified but required focus and foreground reset did not verify"
                append_record(
                    args.output,
                    make_record(
                        task=task,
                        lane="mac-control",
                        phase=phase,
                        sample=sample + args.sample_offset,
                        duration_ms=duration_ms,
                        tool_calls=1,
                        recoveries=0 if reset_verified else 1,
                        verified=sample_verified,
                        user_help=False,
                        status="passed" if sample_verified else "failed",
                        oracle=oracle,
                        route="keyboard",
                        notes=notes,
                        foreground_state=sample_foreground_state,
                        **context,
                    ),
                )
                if not sample_verified:
                    return 1
    except CommandFailure as error:
        return blocked(summarize_command_failure(error))
    except (OSError, RuntimeError, ValueError) as error:
        return blocked(f"benchmark setup or execution blocked: {error}")
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
        focus_policy="foreground",
        interaction_mode="keyboard",
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
        focus_policy="foreground",
        interaction_mode="keyboard",
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
        focus_policy="foreground",
        interaction_mode="keyboard",
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
            foreground_state=args.foreground_state,
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
            if record.get("schema_version") not in {1, 2, 3, 4}:
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
        record.get("focus_policy"),
        record.get("interaction_mode"),
        record.get("foreground_oracle"),
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
        "focus_policy": comparison[6],
        "interaction_mode": comparison[7],
        "foreground_oracle": comparison[8],
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
            "foreground_preserved": sum(
                sample.get("foreground_state") == "preserved" for sample in samples
            ),
            "foreground_complete": (
                None
                if group_context(key).get("foreground_oracle") is None
                else (
                    bool(samples)
                    and group_context(key).get("focus_policy") in FOCUS_POLICIES
                    and all(sample.get("foreground_state") == "preserved" for sample in samples)
                )
            ),
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
                "foreground_preserved": 0,
                "foreground_complete": (
                    None
                    if group_context(key).get("foreground_oracle") is None
                    else False
                ),
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
            group["focus_policy"],
            group["interaction_mode"],
            group["foreground_oracle"],
        )
        by_comparison.setdefault(key, []).append(group)

    comparisons: list[dict[str, Any]] = []
    for key, variants in sorted(by_comparison.items(), key=lambda item: str(item[0])):
        eligible = [
            group for group in variants
            if group["samples"] > 0
            and group["status"] == "passed"
            and group["verified"] == group["samples"]
            and (
                group["foreground_oracle"] is None
                or group["foreground_complete"] is True
            )
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
                "focus_policy": key[6],
                "interaction_mode": key[7],
                "foreground_oracle": key[8],
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
                        "foreground_preserved": group["foreground_preserved"],
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
                group["focus_policy"],
                group["interaction_mode"],
                group["foreground_oracle"],
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

        if group["foreground_oracle"] is not None and group["foreground_complete"] is not True:
            group["interpretation"] = "focus policy or foreground-preservation oracle not satisfied"
        elif group["expand_to_seven"]:
            group["interpretation"] = "expand to 7 samples"
        elif group["status"] == "passed":
            group["interpretation"] = "passed"

    return {
        "schema_version": 4,
        "generated_at": utc_now(),
        "groups": groups,
        "comparisons": comparisons,
    }


def markdown_summary(summary: dict[str, Any]) -> str:
    lines = [
        "| Comparison | Task | App | Lane | Build | Focus policy | Interaction | Median | Tool calls | Recoveries | Verified | Foreground | User help | Interpretation |",
        "| --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | ---: | --- |",
    ]
    for group in summary["groups"]:
        median = "—" if group["median_ms"] is None else f"{group['median_ms']:.3f} ms"
        tool_calls = "—" if group["mean_tool_calls"] is None else f"{group['mean_tool_calls']:.2f}"
        comparison_id = group.get("comparison_id") or group["task"]
        app = group.get("app") or "—"
        build = group.get("build_id") or "—"
        focus_policy = group.get("focus_policy") or "unspecified"
        interaction_mode = group.get("interaction_mode") or "unspecified"
        foreground = (
            "not recorded"
            if group.get("foreground_oracle") is None
            else f"{group['foreground_preserved']}/{group['samples']} preserved"
        )
        lines.append(
            f"| {comparison_id} | {group['task']} | {app} | {group['lane']} | {build} | "
            f"{focus_policy} | {interaction_mode} | {median} | "
            f"{tool_calls} | {group['recoveries']} | "
            f"{group['verified']}/{group['samples']} | {foreground} | "
            f"{group['user_help']} | {group['interpretation']} |"
        )
    lines.extend([
        "",
        "### Pairwise comparisons",
        "",
        "| Comparison | Task | App | Focus policy | Interaction | Status | Variants | Fastest |",
        "| --- | --- | --- | --- | --- | --- | ---: | --- |",
    ])
    for comparison in summary.get("comparisons", []):
        fastest = comparison.get("fastest")
        fastest_label = "—" if fastest is None else (
            f"{fastest.get('lane')} / {fastest.get('build_id') or 'unidentified'} "
            f"({fastest.get('median_ms')} ms)"
        )
        lines.append(
            f"| {comparison['comparison_id']} | {comparison['task']} | "
            f"{comparison.get('app') or '—'} | {comparison.get('focus_policy') or 'unspecified'} | "
            f"{comparison.get('interaction_mode') or 'unspecified'} | {comparison['status']} | "
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
    parser.add_argument(
        "--focus-policy",
        choices=sorted(FOCUS_POLICIES),
        help="whether the named target must be foreground or may remain background",
    )
    parser.add_argument(
        "--interaction-mode",
        choices=sorted(INTERACTION_MODES),
        help="task action family used by every paired provider lane",
    )
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

    focus = subparsers.add_parser(
        "run-mac-focus",
        help="measure atomic named keyboard focus navigation",
    )
    focus.add_argument("--app", required=True)
    focus.add_argument(
        "--action",
        choices=sorted(FOCUS_ACTION_PAIRS),
        default="next-control",
        help="named keyboard focus action to measure",
    )
    focus.add_argument(
        "--reset-action",
        choices=sorted(FOCUS_ACTION_PAIRS),
        help="opposite named action used to restore the starting focus",
    )
    focus.add_argument("--task", help="task identity used for the benchmark record")
    focus.add_argument("--oracle", help="postcondition description for the benchmark record")
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
    scroll.add_argument("--identifier")
    scroll.add_argument("--locator-digest")
    scroll.add_argument("--ancestor-digest")
    scroll.add_argument("--geometry-digest")
    scroll.add_argument("--window-title")
    scroll.add_argument("--direction", required=True, choices=["up", "down", "left", "right"])
    scroll.add_argument("--amount", type=int, default=1)
    scroll.add_argument("--reset-direction", required=True, choices=["up", "down", "left", "right"])
    scroll.add_argument("--reset-amount", type=int, default=1)
    scroll.add_argument("--warmups", type=int, default=1)
    scroll.add_argument("--samples", type=int, default=3)
    scroll.add_argument("--sample-offset", type=int, default=0)
    scroll.add_argument(
        "--task",
        help="task identity for the record (defaults to scroll-main)",
    )
    scroll.add_argument(
        "--record-route",
        help="route label for the record (defaults to scroll)",
    )
    scroll.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    scroll.add_argument("--output", required=True, type=Path)
    scroll.add_argument("--oracle", help="redacted postcondition description")
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
    manual.add_argument(
        "--foreground-oracle",
        help="foreground postcondition shared by all paired lanes, such as foreground_unchanged",
    )
    manual.add_argument(
        "--foreground-state",
        choices=sorted(FOREGROUND_STATES),
        help="observed foreground result for this externally timed trial",
    )
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
