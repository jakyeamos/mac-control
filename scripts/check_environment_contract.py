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
    "scripts/install_mac_control_skill.py",
    "skills/mac-control/SKILL.md",
    "skills/mac-control/agents/openai.yaml",
    "skills/mac-control/references/routing.md",
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
    targets = [
        target
        for match in re.findall(r"\[[^\]]+\]\(([^)]+)\)|`([^`]+\.md)`", index)
        for target in (match[0] or match[1],)
    ]
    for target in targets:
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
        "python3 -m unittest discover -s Tests/BenchmarkTests",
        "python3 -m unittest discover -s Tests/SkillTests",
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


def _errors_for_mac_control_skill() -> list[str]:
    skill_path = ROOT / "skills" / "mac-control" / "SKILL.md"
    routing_path = ROOT / "skills" / "mac-control" / "references" / "routing.md"
    metadata_path = ROOT / "skills" / "mac-control" / "agents" / "openai.yaml"
    if not all(path.is_file() for path in (skill_path, routing_path, metadata_path)):
        return ["Mac Control skill source is incomplete"]

    skill = skill_path.read_text(encoding="utf-8")
    routing = routing_path.read_text(encoding="utf-8")
    metadata = metadata_path.read_text(encoding="utf-8")
    errors: list[str] = []
    if "TODO" in skill:
        errors.append("Mac Control skill contains TODO text")
    if not re.match(r"^---\nname: mac-control\ndescription: .+\n---\n", skill):
        errors.append("Mac Control skill frontmatter is invalid")
    required_skill_markers = (
        "mature direct CLI, API, typed connector, or browser DOM route",
        "task-specific rather than a fixed",
        "fresh manifest exists for the exact app identity",
        "selector's addressability metadata",
        "Visual and coordinate candidates require explicit task-manifest opt-in",
        "mac-control-task-manifest/v4",
        "Every task also declares shortcut acceleration",
        "keyboard_focus_changed",
        "lease_released",
        "result.verification.state",
        "task-owned unique-bundle fixture",
        "awaiting_manual_approval_or_startup",
    )
    missing = [marker for marker in required_skill_markers if marker not in skill]
    if missing:
        errors.append(f"Mac Control skill missing markers: {', '.join(missing)}")
    for marker in ("Positive and negative examples", "Ambiguous cases", "Evidence basis"):
        if marker not in routing:
            errors.append(f"Mac Control routing reference missing marker: {marker}")
    for marker in ('display_name: "Mac Control"', "$mac-control"):
        if marker not in metadata:
            errors.append(f"Mac Control OpenAI metadata missing marker: {marker}")
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
    errors.extend(_errors_for_mac_control_skill())
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
