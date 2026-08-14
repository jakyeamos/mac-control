#!/usr/bin/env python3
"""Build and own an isolated, uniquely addressable VS Code test instance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Sequence


SCHEMA = "macctl-vscode-fixture/v1"
ROOT_PREFIX = "macctl-vscode-fixture-"
APP_NAME = "MacCtl VS Code Fixture.app"
MARKER_NAME = ".macctl-vscode-fixture.json"
DEFAULT_SOURCE_APP = Path("/Applications/Visual Studio Code.app")
FIXTURE_ID_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xbe\xba\xfe\xca",
    b"\xbf\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
}
CODE_BUNDLE_SUFFIXES = {
    ".app",
    ".appex",
    ".bundle",
    ".framework",
    ".mdimporter",
    ".plugin",
    ".qlgenerator",
    ".saver",
    ".xpc",
}


class FixtureError(RuntimeError):
    """A fail-closed fixture lifecycle error."""


def _json(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, sort_keys=True))


def _resolved_absolute(path: Path) -> Path:
    if not path.is_absolute():
        raise FixtureError(f"path must be absolute: {path}")
    return path.resolve(strict=False)


def validate_new_root(root: Path) -> Path:
    root = _resolved_absolute(root)
    if not root.name.startswith(ROOT_PREFIX):
        raise FixtureError(f"fixture root basename must start with {ROOT_PREFIX}")
    if root.exists() or root.is_symlink():
        raise FixtureError(f"fixture root already exists: {root}")
    if not root.parent.is_dir():
        raise FixtureError(f"fixture root parent does not exist: {root.parent}")
    return root


def bundle_id_for(fixture_id: str) -> str:
    if FIXTURE_ID_PATTERN.fullmatch(fixture_id) is None:
        raise FixtureError("fixture id must match [a-z][a-z0-9-]{0,31}")
    component = fixture_id.replace("-", "")
    return f"com.jakyeamos.macctl.fixture.vscode.{component}"


def _marker_path(root: Path) -> Path:
    return root / MARKER_NAME


def _write_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def _load_marker(root: Path) -> tuple[Path, dict[str, Any]]:
    root = _resolved_absolute(root)
    if not root.name.startswith(ROOT_PREFIX):
        raise FixtureError(f"fixture root basename must start with {ROOT_PREFIX}")
    marker_path = _marker_path(root)
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"fixture marker is missing or invalid: {error.__class__.__name__}") from error
    if marker.get("schema") != SCHEMA or marker.get("root") != str(root):
        raise FixtureError("fixture marker does not own this exact root")
    if marker.get("app") != str(root / APP_NAME):
        raise FixtureError("fixture marker app path is invalid")
    return root, marker


def _run(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _clone_bundle(source: Path, destination: Path, allow_full_copy: bool) -> str:
    same_device = source.stat().st_dev == destination.parent.stat().st_dev
    if not same_device and not allow_full_copy:
        raise FixtureError("source and fixture root are on different filesystems; rerun with --allow-full-copy")
    clone = _run(["/bin/cp", "-cR", str(source), str(destination)])
    if clone.returncode == 0:
        return "apfs_clone_requested" if same_device else "full_copy_allowed"
    if destination.exists():
        shutil.rmtree(destination)
    if not allow_full_copy:
        detail = (clone.stderr or clone.stdout).strip() or "copy-on-write clone failed"
        raise FixtureError(f"APFS clone unavailable; rerun with --allow-full-copy: {detail}")
    copied = _run(["/usr/bin/ditto", "--noqtn", "--norsrc", str(source), str(destination)])
    if copied.returncode != 0:
        detail = (copied.stderr or copied.stdout).strip() or "full copy failed"
        raise FixtureError(f"VS Code copy failed: {detail}")
    return "full_copy"


def _available_signing_identities() -> list[str]:
    result = _run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    if result.returncode != 0:
        return []
    return re.findall(r'^\s*\d+\)\s+([0-9A-F]+)\s+"', result.stdout, flags=re.MULTILINE)


def _resolve_signing_identity(requested: str | None, ad_hoc_sign: bool) -> str:
    if requested and ad_hoc_sign:
        raise FixtureError("choose either --signing-identity or --ad-hoc-sign")
    if requested:
        return requested
    if ad_hoc_sign:
        return "-"
    identities = _available_signing_identities()
    if len(identities) == 1:
        return identities[0]
    if not identities:
        raise FixtureError("no valid code-signing identity found; use --ad-hoc-sign only for a manually approved local probe")
    raise FixtureError("multiple code-signing identities found; select one with --signing-identity")


def _is_macho(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def _nested_code_paths(app: Path) -> list[Path]:
    targets = [
        path
        for path in app.rglob("*")
        if _is_macho(path)
        or (
            path.is_dir()
            and not path.is_symlink()
            and path.suffix.lower() in CODE_BUNDLE_SUFFIXES
        )
    ]
    return sorted(
        set(targets),
        key=lambda path: (len(path.parts), path.is_file(), str(path)),
        reverse=True,
    )


def _sign_code(path: Path, signing_identity: str) -> None:
    command = [
        "/usr/bin/codesign",
        "--force",
        "--sign",
        signing_identity,
        "--timestamp=none",
        "--options",
        "runtime",
    ]
    if signing_identity != "-":
        command.append("--preserve-metadata=entitlements")
    command.append(str(path))
    signed = _run(command)
    if signed.returncode != 0:
        detail = (signed.stderr or signed.stdout).strip() or "codesign failed"
        raise FixtureError(f"fixture code signing failed for {path.name}: {detail}")


def _sign_bundle(app: Path, signing_identity: str) -> None:
    # `codesign --deep` does not discover Electron's Framework/Libraries
    # Mach-O files and is deprecated for signing. Sign every copied Mach-O and
    # code bundle inside-out so each enclosing signature seals its children.
    for path in _nested_code_paths(app):
        _sign_code(path, signing_identity)
    _sign_code(app, signing_identity)


def _team_identifier(path: Path) -> str | None:
    described = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    if described.returncode != 0:
        raise FixtureError(f"could not inspect fixture signature: {path.name}")
    description = f"{described.stdout}\n{described.stderr}"
    match = re.search(r"^TeamIdentifier=(.+)$", description, flags=re.MULTILINE)
    if match is None or match.group(1) == "not set":
        return None
    return match.group(1).strip()


def _verify_bundle(app: Path, expected_bundle_id: str) -> None:
    for path in [*_nested_code_paths(app), app]:
        verified = _run(["/usr/bin/codesign", "--verify", "--strict", str(path)])
        if verified.returncode != 0:
            detail = (verified.stderr or verified.stdout).strip() or "codesign verification failed"
            raise FixtureError(f"fixture signature is invalid for {path.name}: {detail}")
    described = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)])
    description = f"{described.stdout}\n{described.stderr}"
    if described.returncode != 0 or f"Identifier={expected_bundle_id}" not in description:
        raise FixtureError("fixture signing identity does not match the requested bundle id")
    expected_team = _team_identifier(app)
    mismatches = [
        path.relative_to(app).as_posix()
        for path in _nested_code_paths(app)
        if _team_identifier(path) != expected_team
    ]
    if mismatches:
        preview = ", ".join(mismatches[:3])
        suffix = "" if len(mismatches) <= 3 else f" (+{len(mismatches) - 3} more)"
        raise FixtureError(f"fixture contains mixed Team IDs: {preview}{suffix}")


def _restore_source_product_names(app: Path, source_app: Path) -> None:
    source_info_path = source_app / "Contents" / "Info.plist"
    fixture_info_path = app / "Contents" / "Info.plist"
    try:
        with source_info_path.open("rb") as handle:
            source_info = plistlib.load(handle)
        with fixture_info_path.open("rb") as handle:
            fixture_info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise FixtureError(f"could not restore source product names: {error.__class__.__name__}") from error
    for key in ("CFBundleName", "CFBundleDisplayName"):
        value = source_info.get(key)
        if isinstance(value, str) and value:
            fixture_info[key] = value
        else:
            fixture_info.pop(key, None)
    with fixture_info_path.open("wb") as handle:
        plistlib.dump(fixture_info, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)


def build_fixture(
    root: Path,
    fixture_id: str,
    source_app: Path = DEFAULT_SOURCE_APP,
    allow_full_copy: bool = False,
    repair_invalid_nested_signatures: bool = False,
    signing_identity: str | None = None,
    ad_hoc_sign: bool = False,
) -> dict[str, Any]:
    root = validate_new_root(root)
    source_app = _resolved_absolute(source_app)
    info_path = source_app / "Contents" / "Info.plist"
    executable = source_app / "Contents" / "MacOS" / "Code"
    if not source_app.is_dir() or not info_path.is_file() or not executable.is_file():
        raise FixtureError(f"source is not a supported Visual Studio Code bundle: {source_app}")
    bundle_id = bundle_id_for(fixture_id)
    resolved_signing_identity = _resolve_signing_identity(signing_identity, ad_hoc_sign)
    app = root / APP_NAME
    root.mkdir(mode=0o700)
    try:
        copy_mode = _clone_bundle(source_app, app, allow_full_copy)
        fixture_info_path = app / "Contents" / "Info.plist"
        with fixture_info_path.open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleIdentifier"] = bundle_id
        with fixture_info_path.open("wb") as handle:
            plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)
        _sign_bundle(app, resolved_signing_identity)
        _verify_bundle(app, bundle_id)
        (root / "profile" / "User").mkdir(parents=True)
        (root / "extensions").mkdir()
        (root / "workspace").mkdir()
        _write_json(
            root / "profile" / "User" / "settings.json",
            {
                "extensions.autoCheckUpdates": False,
                "extensions.autoUpdate": False,
                "security.workspace.trust.enabled": False,
                "telemetry.telemetryLevel": "off",
                "update.mode": "none",
                "workbench.startupEditor": "none",
            },
        )
        marker = {
            "schema": SCHEMA,
            "root": str(root),
            "app": str(app),
            "bundle_id": bundle_id,
            "fixture_id": fixture_id,
            "source_app": str(source_app),
            "copy_mode": copy_mode,
            "nested_signatures_repaired": True,
            "signing_kind": "ad_hoc" if resolved_signing_identity == "-" else "development",
            "signing_identity_sha256": hashlib.sha256(
                resolved_signing_identity.encode("utf-8")
            ).hexdigest(),
            "created_at": datetime.now(UTC).isoformat(),
            "pid": None,
            "process_command_sha256": None,
        }
        _write_json(_marker_path(root), marker)
        return marker
    except BaseException:
        shutil.rmtree(root, ignore_errors=True)
        raise


def repair_fixture_signatures(
    root: Path,
    signing_identity: str | None = None,
    ad_hoc_sign: bool = False,
) -> dict[str, Any]:
    root, marker = _load_marker(root)
    active, _ = _live_process(marker)
    executable = root / APP_NAME / "Contents" / "MacOS" / "Code"
    if active or _pids_for_executable(executable):
        raise FixtureError("fixture must be stopped before signature repair")
    resolved_signing_identity = _resolve_signing_identity(signing_identity, ad_hoc_sign)
    identity_digest = hashlib.sha256(resolved_signing_identity.encode("utf-8")).hexdigest()
    if identity_digest != marker.get("signing_identity_sha256"):
        raise FixtureError("signature repair must use the fixture's original signing identity")
    app = root / APP_NAME
    raw_source_app = marker.get("source_app")
    if not isinstance(raw_source_app, str):
        raise FixtureError("fixture marker does not record its source app")
    source_app = _resolved_absolute(Path(raw_source_app))
    _restore_source_product_names(app, source_app)
    _sign_bundle(app, resolved_signing_identity)
    _verify_bundle(app, marker["bundle_id"])
    marker["nested_signatures_repaired"] = True
    marker["signatures_repaired_at"] = datetime.now(UTC).isoformat()
    marker["startup_state"] = "stopped"
    marker["pid"] = None
    marker["process_command_sha256"] = None
    _write_json(_marker_path(root), marker)
    return {
        "schema": SCHEMA,
        "status": "signatures_repaired",
        "bundle_id": marker["bundle_id"],
        "app": marker["app"],
    }


def _extension_destination_name(package: dict[str, Any]) -> str:
    values = [package.get(key) for key in ("publisher", "name", "version")]
    if not all(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9._-]+", value) for value in values):
        raise FixtureError("extension package.json requires safe publisher, name, and version fields")
    return f"{values[0]}.{values[1]}-{values[2]}"


def _tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def install_extension(root: Path, extension: Path) -> Path:
    root, _ = _load_marker(root)
    extension = _resolved_absolute(extension)
    package_path = extension / "package.json"
    try:
        package = json.loads(package_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"extension package.json is missing or invalid: {error.__class__.__name__}") from error
    destination = root / "extensions" / _extension_destination_name(package)
    if destination.exists() or destination.is_symlink():
        if destination.is_dir() and _tree_digest(destination) == _tree_digest(extension):
            return destination
        raise FixtureError(f"extension destination already exists with different content: {destination.name}")
    shutil.copytree(extension, destination, symlinks=True)
    return destination


def _command_for_pid(pid: int) -> str | None:
    result = _run(["/bin/ps", "-p", str(pid), "-o", "command="])
    if result.returncode != 0:
        return None
    command = result.stdout.strip()
    return command or None


def _command_digest(command: str) -> str:
    return hashlib.sha256(command.encode("utf-8")).hexdigest()


def _pids_for_executable(executable: Path) -> list[int]:
    result = _run(["/bin/ps", "-ax", "-o", "pid=,command="])
    if result.returncode != 0:
        raise FixtureError("could not inspect running processes before fixture launch")
    prefix = f"{executable} "
    pids: list[int] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or (fields[1] != str(executable) and not fields[1].startswith(prefix)):
            continue
        try:
            pids.append(int(fields[0]))
        except ValueError:
            continue
    return sorted(pids)


def _child_process_count(pid: int) -> int:
    result = _run(["/bin/ps", "-ax", "-o", "ppid="])
    if result.returncode != 0:
        raise FixtureError("could not inspect fixture child processes")
    count = 0
    for line in result.stdout.splitlines():
        try:
            if int(line.strip()) == pid:
                count += 1
        except ValueError:
            continue
    return count


def _live_process(marker: dict[str, Any]) -> tuple[bool, str | None]:
    pid = marker.get("pid")
    expected = marker.get("process_command_sha256")
    if not isinstance(pid, int) or not isinstance(expected, str):
        return False, None
    command = _command_for_pid(pid)
    if command is None:
        return False, None
    if _command_digest(command) != expected:
        raise FixtureError("recorded PID now belongs to a different process")
    return True, command


def _record_stopped_before_ready(
    root: Path,
    marker: dict[str, Any],
    candidate_pid: int | None = None,
) -> dict[str, Any]:
    marker["pid"] = None
    marker["process_command_sha256"] = None
    if candidate_pid is None:
        marker.pop("last_candidate_pid", None)
    else:
        marker["last_candidate_pid"] = candidate_pid
    marker["launched_at"] = datetime.now(UTC).isoformat()
    marker["startup_state"] = "stopped_before_ready"
    marker.pop("ready_at", None)
    marker.pop("stopped_at", None)
    _write_json(_marker_path(root), marker)
    return {
        "schema": SCHEMA,
        "status": "stopped_before_ready",
        "bundle_id": marker["bundle_id"],
        "app": marker["app"],
        "pid": None,
        "child_process_count": 0,
        "manual_approval_required": False,
        "next_action": "relaunch_and_review_native_approval",
    }


def launch_fixture(root: Path, workspace: Path | None, extension: Path | None) -> dict[str, Any]:
    root, marker = _load_marker(root)
    active, _ = _live_process(marker)
    if active:
        raise FixtureError("fixture is already running")
    if extension is not None:
        install_extension(root, extension)
    workspace = _resolved_absolute(workspace) if workspace is not None else root / "workspace"
    if not workspace.is_dir():
        raise FixtureError(f"workspace directory does not exist: {workspace}")
    executable = root / APP_NAME / "Contents" / "MacOS" / "Code"
    command = [
        "--user-data-dir",
        str(root / "profile"),
        "--extensions-dir",
        str(root / "extensions"),
        "--new-window",
        str(workspace),
    ]
    before = set(_pids_for_executable(executable))
    if before:
        raise FixtureError("an unrecorded fixture process is already running")
    opened = _run(["/usr/bin/open", "-n", "-a", str(root / APP_NAME), "--args", *command])
    if opened.returncode != 0:
        detail = (opened.stderr or opened.stdout).strip() or "LaunchServices open failed"
        raise FixtureError(f"fixture launch failed: {detail}")
    deadline = time.monotonic() + 10
    new_pids: list[int] = []
    while time.monotonic() < deadline:
        new_pids = [pid for pid in _pids_for_executable(executable) if pid not in before]
        if len(new_pids) == 1:
            break
        time.sleep(0.1)
    if not new_pids:
        return _record_stopped_before_ready(root, marker)
    if len(new_pids) != 1:
        raise FixtureError(f"LaunchServices produced {len(new_pids)} candidate fixture processes")
    pid = new_pids[0]
    observed = _command_for_pid(pid)
    if observed is None:
        return _record_stopped_before_ready(root, marker, pid)
    if not observed.startswith(str(executable)):
        raise FixtureError("could not bind the launched PID to the fixture executable")
    marker["pid"] = pid
    marker["process_command_sha256"] = _command_digest(observed)
    marker["launched_at"] = datetime.now(UTC).isoformat()
    child_count = _child_process_count(pid)
    marker["startup_state"] = (
        "ready" if child_count else "awaiting_manual_approval_or_startup"
    )
    if child_count:
        marker["ready_at"] = datetime.now(UTC).isoformat()
    else:
        marker.pop("ready_at", None)
    marker.pop("stopped_at", None)
    _write_json(_marker_path(root), marker)
    return {
        "schema": SCHEMA,
        "status": marker["startup_state"],
        "bundle_id": marker["bundle_id"],
        "app": marker["app"],
        "pid": pid,
        "child_process_count": child_count,
        "manual_approval_required": child_count == 0,
    }


def fixture_status(root: Path) -> dict[str, Any]:
    root, marker = _load_marker(root)
    active, _ = _live_process(marker)
    child_count = _child_process_count(marker["pid"]) if active else 0
    if active and child_count:
        status = "ready"
        if marker.get("startup_state") != status:
            marker["startup_state"] = status
            marker["ready_at"] = datetime.now(UTC).isoformat()
            _write_json(_marker_path(root), marker)
    elif active:
        status = "awaiting_manual_approval_or_startup"
    elif marker.get("startup_state") in {
        "awaiting_manual_approval_or_startup",
        "stopped_before_ready",
    } or (
        isinstance(marker.get("pid"), int)
        and isinstance(marker.get("launched_at"), str)
        and not isinstance(marker.get("ready_at"), str)
    ):
        status = "stopped_before_ready"
    else:
        status = "stopped"
    return {
        "schema": SCHEMA,
        "status": status,
        "bundle_id": marker["bundle_id"],
        "app": marker["app"],
        "pid": marker.get("pid") if active else None,
        "child_process_count": child_count,
        "manual_approval_required": status == "awaiting_manual_approval_or_startup",
        "next_action": (
            "relaunch_and_review_native_approval"
            if status == "stopped_before_ready"
            else None
        ),
    }


def stop_fixture(root: Path, timeout: float = 10.0) -> dict[str, Any]:
    root, marker = _load_marker(root)
    active, _ = _live_process(marker)
    if not active:
        marker["pid"] = None
        marker["process_command_sha256"] = None
        marker["startup_state"] = "stopped"
        marker["stopped_at"] = datetime.now(UTC).isoformat()
        _write_json(_marker_path(root), marker)
        return {"schema": SCHEMA, "status": "already_stopped"}
    pid = marker["pid"]
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _command_for_pid(pid) is None:
            marker["pid"] = None
            marker["process_command_sha256"] = None
            marker["startup_state"] = "stopped"
            marker["stopped_at"] = datetime.now(UTC).isoformat()
            _write_json(_marker_path(root), marker)
            return {"schema": SCHEMA, "status": "stopped", "pid": pid}
        time.sleep(0.1)
    raise FixtureError("fixture did not stop after SIGTERM; no stronger signal was sent")


def clean_fixture(root: Path) -> dict[str, Any]:
    root, marker = _load_marker(root)
    active, _ = _live_process(marker)
    if active:
        raise FixtureError("fixture is still running; stop it before cleanup")
    removed = str(root)
    shutil.rmtree(root)
    return {"schema": SCHEMA, "status": "removed", "root": removed}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--root", type=Path, required=True)
    build.add_argument("--fixture-id", required=True)
    build.add_argument("--source-app", type=Path, default=DEFAULT_SOURCE_APP)
    build.add_argument("--allow-full-copy", action="store_true")
    build.add_argument(
        "--repair-invalid-nested-signatures",
        action="store_true",
        help="deprecated compatibility option; copied signature-closure repair is always enabled",
    )
    signing = build.add_mutually_exclusive_group()
    signing.add_argument("--signing-identity")
    signing.add_argument("--ad-hoc-sign", action="store_true")
    repair = subparsers.add_parser("repair-signatures")
    repair.add_argument("--root", type=Path, required=True)
    repair_signing = repair.add_mutually_exclusive_group()
    repair_signing.add_argument("--signing-identity")
    repair_signing.add_argument("--ad-hoc-sign", action="store_true")
    launch = subparsers.add_parser("launch")
    launch.add_argument("--root", type=Path, required=True)
    launch.add_argument("--workspace", type=Path)
    launch.add_argument("--extension", type=Path)
    for name in ("status", "stop", "clean"):
        command = subparsers.add_parser(name)
        command.add_argument("--root", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "build":
            payload = build_fixture(
                args.root,
                args.fixture_id,
                args.source_app,
                args.allow_full_copy,
                args.repair_invalid_nested_signatures,
                args.signing_identity,
                args.ad_hoc_sign,
            )
        elif args.command == "launch":
            payload = launch_fixture(args.root, args.workspace, args.extension)
        elif args.command == "repair-signatures":
            payload = repair_fixture_signatures(
                args.root,
                args.signing_identity,
                args.ad_hoc_sign,
            )
        elif args.command == "status":
            payload = fixture_status(args.root)
        elif args.command == "stop":
            payload = stop_fixture(args.root)
        else:
            payload = clean_fixture(args.root)
        _json(payload)
        return 0
    except (FixtureError, OSError, plistlib.InvalidFileException) as error:
        _json({"schema": SCHEMA, "status": "blocked", "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
