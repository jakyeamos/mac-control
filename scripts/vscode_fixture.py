#!/usr/bin/env python3
"""Create and inspect an isolated VS Code Problems-panel fixture.

The fixture is intentionally a harness, not a GUI automation fallback. The
extension owns the semantic diagnostics snapshot; this script owns the exact
fixture directory and launch-process bookkeeping. Neither one claims that the
window is frontmost or that a Problems-panel interaction was visually
accepted. Those proofs require a live Mac Control observation.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path.home() / "Library/Application Support/macctl/vscode-fixtures"
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EXTENSION_PATH = REPO_ROOT / "fixtures/vscode-problems-extension"
DEFAULT_BUNDLE_ID = "com.microsoft.VSCode"
FIXTURE_SCHEMA_VERSION = 1
SNAPSHOT_PROVIDER = "vscode.languages.getDiagnostics"
FIXTURE_ID_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]{0,47}\Z")


class FixtureError(RuntimeError):
    """A typed, fail-closed fixture problem."""

    def __init__(self, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


def is_valid_fixture_id(fixture_id: str) -> bool:
    return bool(FIXTURE_ID_PATTERN.fullmatch(fixture_id))


def fixture_directory(root: Path, fixture_id: str) -> Path:
    if not is_valid_fixture_id(fixture_id):
        raise FixtureError("invalid_fixture_id", "fixture id is invalid or attempts path traversal")
    root = root.expanduser().resolve()
    directory = (root / fixture_id).resolve()
    if directory != root and root not in directory.parents:
        raise FixtureError("invalid_fixture_id", "fixture directory escapes the owner-only fixture root")
    return directory


def descriptor_path(directory: Path) -> Path:
    return directory / "fixture.json"


def snapshot_path(directory: Path) -> Path:
    return directory / "diagnostics.json"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(value: Any) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError("invalid_fixture_state", f"could not read {path.name}") from error
    if not isinstance(value, dict):
        raise FixtureError("invalid_fixture_state", f"{path.name} must contain an object")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def descriptor(
    fixture_id: str,
    *,
    state: str,
    bundle_id: str,
    process_id: int | None,
    app_path: str | None,
    workspace_path: Path,
    profile_path: Path,
    extension_path: Path,
    window_title: str,
    last_error: str | None = None,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "schema_version": FIXTURE_SCHEMA_VERSION,
        "fixture_id": fixture_id,
        "state": state,
        "bundle_id": bundle_id,
        "pid": process_id,
        "app_path": app_path,
        "workspace_path": str(workspace_path),
        "profile_path": str(profile_path),
        "extension_path": str(extension_path),
        "window_title": window_title,
    }
    if last_error:
        value["last_error"] = last_error
    return value


def load_descriptor(root: Path, fixture_id: str) -> tuple[Path, dict[str, Any]]:
    directory = fixture_directory(root, fixture_id)
    path = descriptor_path(directory)
    if not path.is_file():
        raise FixtureError("fixture_descriptor_missing", "fixture descriptor is missing")
    value = read_json(path)
    if value.get("schema_version") != FIXTURE_SCHEMA_VERSION or value.get("fixture_id") != fixture_id:
        raise FixtureError("invalid_fixture_state", "fixture descriptor identity does not match the request")
    return directory, value


def bundle_id_from_app(app_path: Path) -> str:
    info_path = app_path / "Contents/Info.plist"
    try:
        import plistlib

        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
        value = info.get("CFBundleIdentifier")
    except (OSError, ValueError, KeyError):
        value = None
    return value if isinstance(value, str) and value else DEFAULT_BUNDLE_ID


def find_vscode_app(explicit: str | None) -> Path:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get("VSCODE_APP"):
        candidates.append(Path(os.environ["VSCODE_APP"]).expanduser())
    candidates.extend(
        [
            Path("/Applications/Visual Studio Code.app"),
            Path.home() / "Applications/Visual Studio Code.app",
            Path("/Applications/Visual Studio Code - Insiders.app"),
            Path.home() / "Applications/Visual Studio Code - Insiders.app",
        ]
    )
    for candidate in candidates:
        if (candidate / "Contents/MacOS/Electron").is_file():
            return candidate.resolve()
    raise FixtureError("vscode_unavailable", "a Visual Studio Code app with Contents/MacOS/Electron was not found")


def command_line(process_id: int) -> str | None:
    result = subprocess.run(
        ["ps", "-p", str(process_id), "-o", "command="],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def process_is_exact(process_id: int | None, descriptor_value: dict[str, Any]) -> bool:
    if not isinstance(process_id, int) or process_id <= 0:
        return False
    command = command_line(process_id)
    if not command:
        return False
    app_path = descriptor_value.get("app_path")
    workspace_path = descriptor_value.get("workspace_path")
    profile_path = descriptor_value.get("profile_path")
    extension_path = descriptor_value.get("extension_path")
    required = [workspace_path, profile_path, extension_path]
    if not all(isinstance(item, str) and item for item in required):
        return False
    if app_path and not str(app_path) in command:
        return False
    return all(str(item) in command for item in required)


def snapshot_ready(directory: Path, fixture_id: str, bundle_id: str) -> bool:
    path = snapshot_path(directory)
    if not path.is_file():
        return False
    try:
        value = read_json(path)
    except FixtureError:
        return False
    generated = parse_iso(value.get("generated_at"))
    diagnostics = value.get("diagnostics")
    if not isinstance(diagnostics, list) or generated is None:
        return False
    age = (utc_now() - generated).total_seconds()
    if age < -1 or age > 60:
        return False
    if value.get("schema_version") != FIXTURE_SCHEMA_VERSION:
        return False
    if value.get("provider") != SNAPSHOT_PROVIDER:
        return False
    if value.get("fixture_id") != fixture_id or value.get("bundle_id") != bundle_id:
        return False
    digest = value.get("workspace_digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return False
    try:
        expected_digest = workspace_digest(directory, fixture_id)
    except (OSError, UnicodeError):
        return False
    if digest != expected_digest:
        return False
    for record in diagnostics:
        if not isinstance(record, dict):
            return False
        if set(record) - {"severity", "source", "code", "line", "column"}:
            return False
        if any(key in record and not isinstance(record[key], (str, int, type(None))) for key in record):
            return False
        if record.get("severity") not in {"error", "warning", "info", "hint"}:
            return False
        if not isinstance(record.get("line"), int) or record["line"] < 0:
            return False
        if not isinstance(record.get("column"), int) or record["column"] < 0:
            return False
        for key in ("source", "code"):
            if record.get(key) is not None and len(str(record[key])) > 80:
                return False
        if any(key in record for key in ("message", "message_text", "detail")):
            return False
    return True


def workspace_digest(directory: Path, fixture_id: str) -> str:
    marker = directory / "fixture-marker.json"
    workspace = directory / "workspace"
    payload = f"{fixture_id}|{workspace.resolve()}|{marker.read_text(encoding='utf-8')}".encode()
    return hashlib.sha256(payload).hexdigest()


def ensure_extension(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not (path / "package.json").is_file() or not (path / "extension.js").is_file():
        raise FixtureError("fixture_extension_missing", "VS Code fixture extension is incomplete")
    return path


def create_fixture(root: Path, fixture_id: str, extension_path: Path) -> dict[str, Any]:
    directory = fixture_directory(root, fixture_id)
    if directory.exists():
        raise FixtureError("fixture_exists", "fixture directory already exists; cleanup it before recreating")
    extension_path = ensure_extension(extension_path)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    directory.mkdir(mode=0o700)
    workspace = directory / "workspace"
    profile = directory / "profile"
    extensions = directory / "extensions"
    (workspace / ".vscode").mkdir(parents=True, mode=0o700)
    profile.mkdir(mode=0o700)
    extensions.mkdir(mode=0o700)
    fixture_title = f"macctl VS Code Problems Fixture — {fixture_id}"
    (workspace / "fixture.ts").write_text(
        "export const macctlFixture = 'diagnostics are owned by the extension';\n",
        encoding="utf-8",
    )
    (workspace / ".vscode/settings.json").write_text(
        json.dumps(
            {
                "window.title": fixture_title,
                "macctl.fixtureId": fixture_id,
                "macctl.expectedDiagnostics": True,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    write_json(
        directory / "fixture-marker.json",
        {
            "schema_version": FIXTURE_SCHEMA_VERSION,
            "fixture_id": fixture_id,
            "workspace_path": str(workspace.resolve()),
            "window_title": fixture_title,
            "purpose": "macctl-vscode-problems-fixture",
        },
    )
    write_json(
        descriptor_path(directory),
        descriptor(
            fixture_id,
            state="prepared",
            bundle_id=DEFAULT_BUNDLE_ID,
            process_id=None,
            app_path=None,
            workspace_path=workspace.resolve(),
            profile_path=profile.resolve(),
            extension_path=extension_path,
            window_title=fixture_title,
        ),
    )
    return {
        "fixture_id": fixture_id,
        "state": "prepared",
        "bundle_id": DEFAULT_BUNDLE_ID,
        "workspace_path": str(workspace.resolve()),
        "profile_path": str(profile.resolve()),
        "extension_path": str(extension_path),
        "window_title": fixture_title,
        "visual_acceptance": "unverified",
    }


def launch_fixture(root: Path, fixture_id: str, app_path: str | None, wait_seconds: float) -> dict[str, Any]:
    directory, value = load_descriptor(root, fixture_id)
    if value.get("state") == "ready" and process_is_exact(value.get("pid"), value):
        if snapshot_ready(directory, fixture_id, str(value.get("bundle_id"))):
            return status_fixture(root, fixture_id)
        raise FixtureError(
            "fixture_not_ready",
            "the exact fixture process exists but its semantic diagnostics snapshot is not ready; inspect status",
        )
    if value.get("pid") and process_is_exact(value.get("pid"), value):
        raise FixtureError(
            "fixture_not_ready",
            "the exact fixture process is already running but is not ready; no blind relaunch was attempted",
        )

    app = find_vscode_app(app_path)
    bundle_id = bundle_id_from_app(app)
    if bundle_id not in {"com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"}:
        raise FixtureError("identity_mismatch", f"unsupported VS Code bundle identity: {bundle_id}")
    extension = Path(str(value["extension_path"])).resolve()
    workspace = Path(str(value["workspace_path"])).resolve()
    profile = Path(str(value["profile_path"])).resolve()
    command = [
        str(app / "Contents/MacOS/Electron"),
        "--new-window",
        f"--user-data-dir={profile}",
        f"--extensions-dir={directory / 'extensions'}",
        f"--extensionDevelopmentPath={extension}",
        "--disable-workspace-trust",
        str(workspace),
    ]
    updated = descriptor(
        fixture_id,
        state="launching",
        bundle_id=bundle_id,
        process_id=None,
        app_path=str(app),
        workspace_path=workspace,
        profile_path=profile,
        extension_path=extension,
        window_title=str(value["window_title"]),
    )
    write_json(descriptor_path(directory), updated)
    env = os.environ.copy()
    env["MACCTL_VSCODE_FIXTURE_ID"] = fixture_id
    env["MACCTL_VSCODE_FIXTURE_ROOT"] = str(root.expanduser().resolve())
    env["MACCTL_VSCODE_BUNDLE_ID"] = bundle_id
    try:
        process = subprocess.Popen(command, cwd=str(directory), env=env)
    except OSError as error:
        failed = dict(updated)
        failed["state"] = "blocked"
        failed["last_error"] = "vscode_launch_failed"
        write_json(descriptor_path(directory), failed)
        raise FixtureError("vscode_launch_failed", f"could not launch the isolated VS Code process: {error}") from error
    updated["pid"] = process.pid
    write_json(descriptor_path(directory), updated | {"state": "launching"})

    deadline = time.monotonic() + max(0.5, min(wait_seconds, 120))
    while time.monotonic() < deadline:
        current = read_json(descriptor_path(directory))
        exact = process_is_exact(process.pid, current)
        if exact and snapshot_ready(directory, fixture_id, bundle_id):
            ready = dict(current)
            ready["state"] = "ready"
            ready.pop("last_error", None)
            write_json(descriptor_path(directory), ready)
            return status_fixture(root, fixture_id)
        if process.poll() is not None and not exact:
            failed = dict(current)
            failed["state"] = "blocked"
            failed["last_error"] = "fixture_not_ready"
            write_json(descriptor_path(directory), failed)
            raise FixtureError("fixture_not_ready", "VS Code exited before its exact process and diagnostics snapshot were ready")
        time.sleep(0.25)

    failed = read_json(descriptor_path(directory))
    failed["state"] = "blocked"
    failed["last_error"] = "fixture_not_ready"
    write_json(descriptor_path(directory), failed)
    raise FixtureError(
        "fixture_not_ready",
        "VS Code did not produce a fresh extension-owned diagnostics snapshot before the bounded wait expired; no retry was attempted",
        retryable=False,
    )


def status_fixture(root: Path, fixture_id: str) -> dict[str, Any]:
    directory, value = load_descriptor(root, fixture_id)
    bundle_id = str(value.get("bundle_id"))
    exact = process_is_exact(value.get("pid"), value)
    snapshot = snapshot_ready(directory, fixture_id, bundle_id)
    if exact and snapshot:
        semantic_state = "ready"
    elif not exact:
        semantic_state = "blocked_identity_mismatch"
    else:
        semantic_state = "blocked_snapshot_not_ready"
    return {
        "fixture_id": fixture_id,
        "state": value.get("state", "unknown"),
        "semantic_diagnostics": semantic_state,
        "process_identity": "exact" if exact else "not_proven",
        "pid_present": isinstance(value.get("pid"), int),
        "bundle_id": bundle_id,
        "window_title": value.get("window_title"),
        "visual_acceptance": "unverified",
        "frontmost_proof": "not_claimed",
        "focus_proof": "not_claimed",
        "next_action": "Use Mac Control target/frontmost/focus verification before any foreground input; do not retry blindly",
    }


def cleanup_fixture(root: Path, fixture_id: str) -> dict[str, Any]:
    directory, value = load_descriptor(root, fixture_id)
    process_id = value.get("pid")
    if process_id and process_is_exact(process_id, value):
        try:
            os.kill(process_id, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process_is_exact(process_id, value):
            time.sleep(0.1)
        if process_is_exact(process_id, value):
            os.kill(process_id, signal.SIGKILL)
    elif process_id and command_line(process_id):
        raise FixtureError("identity_mismatch", "refusing cleanup because the recorded PID no longer has the exact fixture command line")
    shutil.rmtree(directory)
    return {"fixture_id": fixture_id, "removed": True, "recoverable": False}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    subcommands = result.add_subparsers(dest="command", required=True)

    create = subcommands.add_parser("create")
    create.add_argument("fixture_id")
    create.add_argument("--extension-path", type=Path, default=DEFAULT_EXTENSION_PATH)

    launch = subcommands.add_parser("launch")
    launch.add_argument("fixture_id")
    launch.add_argument("--app-path")
    launch.add_argument("--wait-seconds", type=float, default=20)

    status = subcommands.add_parser("status")
    status.add_argument("fixture_id")

    cleanup = subcommands.add_parser("cleanup")
    cleanup.add_argument("fixture_id")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = args.root.expanduser()
    try:
        if args.command == "create":
            result = create_fixture(root, args.fixture_id, args.extension_path)
        elif args.command == "launch":
            if not args.wait_seconds > 0:
                raise FixtureError("invalid_wait", "--wait-seconds must be positive")
            result = launch_fixture(root, args.fixture_id, args.app_path, args.wait_seconds)
        elif args.command == "status":
            result = status_fixture(root, args.fixture_id)
        elif args.command == "cleanup":
            result = cleanup_fixture(root, args.fixture_id)
        else:
            raise FixtureError("invalid_command", "unknown fixture command")
    except FixtureError as error:
        print(
            json.dumps(
                {
                    "ok": False,
                    "failure_class": error.code,
                    "retryable": error.retryable,
                    "message": str(error),
                },
                sort_keys=True,
            )
        )
        return 1
    print(json.dumps({"ok": True, **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
