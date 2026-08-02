#!/usr/bin/env python3
"""Install or verify the provider-neutral Mac Control agent skill."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from datetime import UTC, datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "skills" / "mac-control"


def tree_digest(root: Path) -> str | None:
    """Return a stable digest for regular files in a skill directory."""

    if not root.is_dir():
        return None
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file())
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def locations(home: Path) -> tuple[Path, Path, Path]:
    canonical = home / ".agents" / "skills" / "mac-control"
    projection = home / ".codex" / "skills" / "mac-control"
    rollback_root = home / ".agents" / "rollback"
    return canonical, projection, rollback_root


def projection_matches(projection: Path, canonical: Path) -> bool:
    if not projection.is_symlink():
        return False
    try:
        return projection.resolve(strict=True) == canonical.resolve(strict=True)
    except OSError:
        return False


def status_payload(home: Path) -> dict[str, object]:
    canonical, projection, _ = locations(home)
    source_digest = tree_digest(SOURCE)
    canonical_digest = tree_digest(canonical)
    canonical_matches = source_digest is not None and source_digest == canonical_digest
    projected = projection_matches(projection, canonical)
    return {
        "status": "pass" if canonical_matches and projected else "fail",
        "source": str(SOURCE),
        "canonical": str(canonical),
        "codexProjection": str(projection),
        "sourceSha256": source_digest,
        "canonicalSha256": canonical_digest,
        "canonicalMatches": canonical_matches,
        "codexProjected": projected,
    }


def rollback_path(rollback_root: Path, label: str) -> Path:
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    candidate = rollback_root / f"mac-control-skill-{stamp}-{label}"
    suffix = 1
    while candidate.exists() or candidate.is_symlink():
        candidate = rollback_root / f"mac-control-skill-{stamp}-{label}-{suffix}"
        suffix += 1
    return candidate


def move_to_rollback(path: Path, rollback_root: Path, label: str) -> Path:
    rollback_root.mkdir(parents=True, exist_ok=True)
    destination = rollback_path(rollback_root, label)
    shutil.move(str(path), str(destination))
    return destination


def install(home: Path) -> dict[str, object]:
    canonical, projection, rollback_root = locations(home)
    if tree_digest(SOURCE) is None:
        raise RuntimeError(f"skill source is missing: {SOURCE}")

    canonical.parent.mkdir(parents=True, exist_ok=True)
    projection.parent.mkdir(parents=True, exist_ok=True)
    rollbacks: list[str] = []

    source_digest = tree_digest(SOURCE)
    if tree_digest(canonical) != source_digest:
        previous_canonical: Path | None = None
        with tempfile.TemporaryDirectory(prefix=".mac-control-stage-", dir=canonical.parent) as temp:
            staged = Path(temp) / "mac-control"
            shutil.copytree(SOURCE, staged)
            if canonical.exists() or canonical.is_symlink():
                previous_canonical = move_to_rollback(canonical, rollback_root, "canonical")
                rollbacks.append(str(previous_canonical))
            try:
                os.replace(staged, canonical)
            except OSError:
                if previous_canonical is not None and not canonical.exists():
                    shutil.move(str(previous_canonical), str(canonical))
                    rollbacks.remove(str(previous_canonical))
                raise

    if not projection_matches(projection, canonical):
        previous_projection: Path | None = None
        if projection.exists() or projection.is_symlink():
            previous_projection = move_to_rollback(projection, rollback_root, "codex")
            rollbacks.append(str(previous_projection))
        try:
            projection.symlink_to(canonical, target_is_directory=True)
        except OSError:
            if previous_projection is not None and not projection.exists():
                shutil.move(str(previous_projection), str(projection))
                rollbacks.remove(str(previous_projection))
            raise

    payload = status_payload(home)
    payload["rollbacks"] = rollbacks
    if payload["status"] != "pass":
        raise RuntimeError("installed skill did not pass identity and projection verification")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("install", "check"))
    parser.add_argument(
        "--home",
        type=Path,
        default=Path.home(),
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        payload = install(args.home) if args.mode == "install" else status_payload(args.home)
    except (OSError, RuntimeError) as error:
        print(json.dumps({"status": "fail", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(payload, sort_keys=True))
    return 0 if payload["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
