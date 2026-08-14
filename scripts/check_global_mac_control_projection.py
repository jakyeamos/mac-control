#!/usr/bin/env python3
"""Verify that the globally loaded Mac Control skill carries its triggers."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "skills" / "mac-control" / "SKILL.md"
GLOBAL = Path.home() / ".agents" / "skills" / "mac-control" / "SKILL.md"
MARKERS = (
    "## Record a newly observed boundary",
    "Record a proposal when a real task observation reveals",
    "Do not submit a one-off failure",
    "Agents may submit a candidate without maintainer approval",
    "macctl control limitations propose --stdin --json",
    "macctl control limitations proposals --json",
    "forces the candidate\nstate to `unproven`",
    "Treat proposals as review evidence only.",
    "If the proposal store is unavailable",
)


def main() -> int:
    errors: list[str] = []
    if not SOURCE.is_file():
        errors.append(f"source skill is missing: {SOURCE}")
    if not GLOBAL.is_file():
        errors.append(f"global skill projection is missing: {GLOBAL}")

    source_text = SOURCE.read_text(encoding="utf-8") if SOURCE.is_file() else ""
    global_text = GLOBAL.read_text(encoding="utf-8") if GLOBAL.is_file() else ""
    if source_text and global_text and source_text != global_text:
        errors.append("global Mac Control skill projection differs from the source skill")
    for marker in MARKERS:
        if marker not in global_text:
            errors.append(f"global skill projection is missing marker: {marker}")

    payload = {
        "global": str(GLOBAL),
        "source": str(SOURCE),
        "status": "pass" if not errors else "fail",
    }
    if errors:
        payload["errors"] = errors
    print(json.dumps(payload, sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
