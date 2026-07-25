#!/usr/bin/env python3
"""Validate macctl's routed environment contract without executing workflows."""

from __future__ import annotations

import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PACKETS = {
    "architecture": ("boundary", "MacCtlCore", "macctld"),
    "commands": ("swift build", "swift test", "coverage", "release check"),
    "conventions": ("Swift", "typed", "fail closed", "XCTest"),
    "security": ("credentials", "TCC", "approval", "redact"),
    "failure-modes": ("blocked", "unknown", "recovery", "diagnos"),
    "examples": ("ReleaseGate", "ReceiptStore", "canonical", "regression"),
    "done": ("acceptance", "evidence", "blocked", "provenance"),
    "deployment": ("rollback", "launchd", "release check", "audit runtime"),
}
REQUIRED_FILES = (
    "AGENTS.md",
    "README.md",
    "Package.swift",
    ".pre-cr.json",
    "docs/TIER1_RELEASE.md",
    ".agents/context/README.md",
    "scripts/check_environment_contract.py",
)


def _errors_for_files() -> list[str]:
    return [relative for relative in REQUIRED_FILES if not (ROOT / relative).is_file()]


def _errors_for_packets() -> list[str]:
    errors: list[str] = []
    context_root = ROOT / ".agents" / "context"
    for name, markers in PACKETS.items():
        path = context_root / f"{name}.md"
        if not path.is_file():
            errors.append(f"missing context packet: {path.relative_to(ROOT)}")
            continue
        text = path.read_text(encoding="utf-8").lower()
        missing = [marker for marker in markers if marker.lower() not in text]
        if missing:
            errors.append(f"packet {name}.md missing markers: {', '.join(missing)}")
    return errors


def _errors_for_links() -> list[str]:
    index = (ROOT / ".agents" / "context" / "README.md").read_text(encoding="utf-8")
    errors: list[str] = []
    for target in re.findall(r"`([^`]+\.md)`", index):
        if target in {"README.md", "AGENTS.md"}:
            continue
        if target.startswith("/") or not (ROOT / ".agents" / "context" / target).is_file():
            errors.append(f"invalid context link: {target}")
    reviewed = re.search(r"last_reviewed:\s*(\d{4}-\d{2}-\d{2})", index)
    if reviewed is None:
        errors.append("context index has no last_reviewed date")
    else:
        review_date = dt.date.fromisoformat(reviewed.group(1))
        if (dt.date.today() - review_date).days > 35:
            errors.append(f"context index is stale: {reviewed.group(1)}")
    return errors


def _errors_for_contract() -> list[str]:
    try:
        contract: dict[str, Any] = json.loads(
            (ROOT / ".pre-cr.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        return [f"invalid .pre-cr.json: {error.__class__.__name__}"]
    expected_commands = {
        "swift build",
        "swift test",
        "swift test --enable-code-coverage",
        "python3 scripts/check_environment_contract.py",
    }
    commands = set(item for item in contract.get("qualityCommands", []) if isinstance(item, str))
    errors = [f"missing quality command: {command}" for command in sorted(expected_commands - commands)]
    adapters = contract.get("qualityAdapters", [])
    if not any(
        isinstance(adapter, dict)
        and "environment-contract" in str(adapter.get("name", "")).lower()
        for adapter in adapters
    ):
        errors.append("environment-contract quality adapter is not configured")
    if contract.get("checks", {}).get("security") is not True:
        errors.append("security check is not enabled")
    return errors


def _tracked_path_errors() -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        return ["git tracked-file inspection failed"]
    suspicious = {
        ".env",
        ".env.local",
        "id_rsa",
        "id_ed25519",
        "credentials.json",
    }
    paths = [item for item in result.stdout.decode("utf-8").split("\0") if item]
    return [f"secret-looking tracked path: {path}" for path in paths if Path(path).name in suspicious]


def validate() -> list[str]:
    """Return contract findings in deterministic order."""

    errors = _errors_for_files() + _errors_for_packets()
    if (ROOT / ".agents" / "context" / "README.md").is_file():
        errors.extend(_errors_for_links())
    if (ROOT / ".pre-cr.json").is_file():
        errors.extend(_errors_for_contract())
    errors.extend(_tracked_path_errors())
    return sorted(set(errors))


def main() -> int:
    errors = validate()
    payload = {"status": "fail" if errors else "pass", "error_count": len(errors)}
    if errors:
        payload["errors"] = errors
    print(json.dumps(payload, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
