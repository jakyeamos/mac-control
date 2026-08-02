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
) -> dict[str, Any]:
    if lane not in LANES:
        raise ValueError(f"unknown lane: {lane}")
    if phase not in PHASES:
        raise ValueError(f"unknown phase: {phase}")
    if status not in STATUSES:
        raise ValueError(f"unknown status: {status}")
    if sample < 1 or duration_ms < 0 or tool_calls < 0 or recoveries < 0:
        raise ValueError("sample and metric counts must be non-negative")
    record: dict[str, Any] = {
        "schema_version": 1,
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
    return record


def run_json(command: list[str]) -> tuple[dict[str, Any], float]:
    started = time.perf_counter_ns()
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
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
            else:
                payload, duration_ms = run_json([args.macctl, "keyboard", "status", "--json"])
                result = result_object(payload)
                verified = (
                    result.get("fullKeyboardAccessEnabled") is True
                    and daemon_provenance(payload)
                )
                route = "macctld"
            append_record(
                args.output,
                make_record(
                    task="inspect-full-keyboard-access",
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
                ),
            )
            if not verified:
                return 1
    return 0


def extract_lease_token(payload: dict[str, Any]) -> str:
    lease = result_object(payload).get("lease")
    if not isinstance(lease, dict) or not isinstance(lease.get("token"), str):
        raise RuntimeError("lease acquisition response did not contain an in-memory token")
    return lease["token"]


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


def run_mac_focus(args: argparse.Namespace) -> int:
    # Computer-control providers commonly restore their own app to the foreground
    # when a tool call returns. Re-establish the benchmark app inside this same
    # process immediately before acquiring the app-scoped lease. This is setup,
    # so it remains outside the measured action interval.
    opened, _ = run_json([args.macctl, "app", "open", args.app, "--json"])
    opened_app = result_object(opened)
    if opened_app.get("name") != args.app or opened_app.get("isRunning") is not True:
        raise RuntimeError("Mac Control did not establish the requested foreground app")

    acquire, _ = run_json(
        [
            args.macctl,
            "keyboard",
            "lease",
            "acquire",
            "--scope",
            "app",
            "--app",
            args.app,
            "--seconds",
            str(args.seconds),
            "--confirm",
            "--json",
        ]
    )
    lease_token = extract_lease_token(acquire)
    try:
        for phase, count in (("warmup", args.warmups), ("measured", args.samples)):
            for sample in range(1, count + 1):
                payload, duration_ms = run_json(
                    [
                        args.macctl,
                        "keyboard",
                        "navigate",
                        "next-control",
                        "--lease-token",
                        lease_token,
                        "--json",
                    ]
                )
                verified = focus_verified(payload)
                append_record(
                    args.output,
                    make_record(
                        task="focus-next-control",
                        lane="mac-control",
                        phase=phase,
                        sample=sample,
                        duration_ms=duration_ms,
                        tool_calls=1,
                        recoveries=0,
                        verified=verified,
                        user_help=False,
                        status="passed" if verified else "failed",
                        oracle="Accessibility focus changed to the next control",
                        route="keyboard",
                    ),
                )
                if not verified:
                    return 1

                reset, _ = run_json(
                    [
                        args.macctl,
                        "keyboard",
                        "navigate",
                        "previous-control",
                        "--lease-token",
                        lease_token,
                        "--json",
                    ]
                )
                if not focus_verified(reset):
                    raise RuntimeError("focus reset did not verify")
    finally:
        # Keep the capability-bearing value in memory only and always release it.
        subprocess.run(
            [args.macctl, "keyboard", "lease", "release", lease_token, "--json"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
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
            if record.get("schema_version") != 1:
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


def summarize_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    measured = [record for record in records if record["phase"] == "measured"]
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for record in measured:
        grouped.setdefault((record["task"], record["lane"]), []).append(record)

    groups: list[dict[str, Any]] = []
    for (task, lane), samples in sorted(grouped.items()):
        durations = [float(sample["duration_ms"]) for sample in samples]
        median = statistics.median(durations)
        coefficient = statistics.pstdev(durations) / median if median else 0.0
        groups.append(
            {
                "task": task,
                "lane": lane,
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
            }
        )

    by_task: dict[str, list[dict[str, Any]]] = {}
    for group in groups:
        by_task.setdefault(group["task"], []).append(group)
    for task_groups in by_task.values():
        ranked = sorted(task_groups, key=lambda group: group["median_ms"])
        if len(ranked) >= 2 and ranked[1]["median_ms"]:
            gap = (ranked[1]["median_ms"] - ranked[0]["median_ms"]) / ranked[1]["median_ms"]
            if gap < 0.10:
                ranked[0]["expand_to_seven"] = True
                ranked[1]["expand_to_seven"] = True

    return {"schema_version": 1, "generated_at": utc_now(), "groups": groups}


def markdown_summary(summary: dict[str, Any]) -> str:
    lines = [
        "| Task | Lane | Median | Tool calls | Recoveries | Verified | User help | Interpretation |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for group in summary["groups"]:
        interpretation = "expand to 7 samples" if group["expand_to_seven"] else group["status"]
        lines.append(
            f"| {group['task']} | {group['lane']} | {group['median_ms']:.3f} ms | "
            f"{group['mean_tool_calls']:.2f} | {group['recoveries']} | "
            f"{group['verified']}/{group['samples']} | {group['user_help']} | {interpretation} |"
        )
    return "\n".join(lines) + "\n"


def summarize(args: argparse.Namespace) -> int:
    summary = summarize_records(load_records(args.input))
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_output.write_text(markdown_summary(summary), encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    fka = subparsers.add_parser("run-fka-readonly", help="measure the read-only FKA task")
    fka.add_argument("--lane", required=True, choices=["agent-baseline", "mac-control"])
    fka.add_argument("--warmups", type=int, default=1)
    fka.add_argument("--samples", type=int, default=3)
    fka.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    fka.add_argument("--output", required=True, type=Path)
    fka.set_defaults(handler=run_fka_readonly)

    focus = subparsers.add_parser("run-mac-focus", help="measure leased next-control navigation")
    focus.add_argument("--app", required=True)
    focus.add_argument("--seconds", type=int, default=60)
    focus.add_argument("--warmups", type=int, default=1)
    focus.add_argument("--samples", type=int, default=3)
    focus.add_argument("--macctl", default=str(Path.home() / ".local/bin/macctl"))
    focus.add_argument("--output", required=True, type=Path)
    focus.set_defaults(handler=run_mac_focus)

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
    manual.set_defaults(handler=record_manual)

    report = subparsers.add_parser("summarize", help="write JSON and Markdown summaries")
    report.add_argument("--input", required=True, type=Path)
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
