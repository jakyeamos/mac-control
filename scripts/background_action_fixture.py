#!/usr/bin/env python3
"""Build and own the disposable two-window exact background-action fixture."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Tests" / "Fixtures" / "BackgroundActionFixture" / "main.swift"
BUNDLE_ID = "com.jakyeamos.macctl.background-action-fixture"
APP_NAME = "Mac Control Background Action Fixture"
MARKER_NAME = ".macctl-background-action-fixture.json"


def executable_for(app: Path) -> Path:
    return app / "Contents" / "MacOS" / "BackgroundActionFixture"


def marker_for(app: Path) -> Path:
    return app / "Contents" / "Resources" / MARKER_NAME


def build(app: Path) -> dict[str, object]:
    app = app.resolve()
    if app.suffix != ".app":
        raise SystemExit("--app must end in .app")
    if app.exists() and not marker_for(app).is_file():
        raise SystemExit("refusing to overwrite an unmarked app bundle")
    executable = executable_for(app)
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = app / "Contents" / "Resources"
    resources.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "/usr/bin/xcrun",
            "swiftc",
            str(SOURCE),
            "-framework",
            "AppKit",
            "-o",
            str(executable),
        ],
        check=True,
    )
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": executable.name,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=True)
    marker_for(app).write_text(
        json.dumps({"schema_version": 1, "bundle_id": BUNDLE_ID}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return {"app": str(app), "executable": str(executable), "bundle_id": BUNDLE_ID}


def matching_pids(executable: Path) -> list[int]:
    result = subprocess.run(
        ["/bin/ps", "-ax", "-o", "pid=", "-o", "command="],
        check=True,
        capture_output=True,
        text=True,
    )
    expected = str(executable.resolve())
    pids: list[int] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[1] == expected:
            pids.append(int(fields[0]))
    return pids


def launch(app: Path, state: Path) -> dict[str, object]:
    executable = executable_for(app)
    if not executable.is_file():
        raise SystemExit("fixture app is not built")
    if matching_pids(executable):
        raise SystemExit("fixture already has a running task-owned process")
    subprocess.run(["/usr/bin/open", "-g", "-n", str(app.resolve())], check=True)
    deadline = time.monotonic() + 5
    pids: list[int] = []
    while time.monotonic() < deadline:
        pids = matching_pids(executable)
        if len(pids) == 1:
            break
        time.sleep(0.05)
    if len(pids) != 1:
        raise SystemExit(f"expected one fixture process, observed {len(pids)}")
    payload = {
        "schema_version": 1,
        "app": str(app.resolve()),
        "executable": str(executable.resolve()),
        "bundle_id": BUNDLE_ID,
        "pid": pids[0],
    }
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    return payload


def load_owned(state: Path) -> dict[str, object]:
    payload = json.loads(state.read_text(encoding="utf-8"))
    executable = Path(str(payload["executable"])).resolve()
    pid = int(payload["pid"])
    if pid not in matching_pids(executable):
        raise SystemExit("recorded fixture process is no longer running")
    return payload


def stop(state: Path) -> dict[str, object]:
    payload = load_owned(state)
    pid = int(payload["pid"])
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    executable = Path(str(payload["executable"]))
    while time.monotonic() < deadline and pid in matching_pids(executable):
        time.sleep(0.05)
    if pid in matching_pids(executable):
        raise SystemExit("fixture did not terminate after SIGTERM")
    state.unlink(missing_ok=True)
    return {"stopped": True, "pid": pid}


def clean(app: Path, state: Path) -> dict[str, object]:
    app = app.resolve()
    marker = marker_for(app)
    if app.suffix != ".app" or not marker.is_file():
        raise SystemExit("refusing to clean an unmarked fixture app")
    marker_payload = json.loads(marker.read_text(encoding="utf-8"))
    if marker_payload.get("bundle_id") != BUNDLE_ID:
        raise SystemExit("fixture marker bundle identity does not match")
    executable = executable_for(app)
    if matching_pids(executable):
        raise SystemExit("refusing to clean a running fixture")
    if state.exists():
        raise SystemExit("refusing to clean while fixture state remains; run stop first")
    shutil.rmtree(app)
    parent = app.parent
    if parent != Path("/") and parent.exists() and not any(parent.iterdir()):
        parent.rmdir()
    return {"cleaned": True, "app": str(app)}


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    build_parser = sub.add_parser("build")
    build_parser.add_argument("--app", type=Path, required=True)
    launch_parser = sub.add_parser("launch")
    launch_parser.add_argument("--app", type=Path, required=True)
    launch_parser.add_argument("--state", type=Path, required=True)
    status_parser = sub.add_parser("status")
    status_parser.add_argument("--state", type=Path, required=True)
    stop_parser = sub.add_parser("stop")
    stop_parser.add_argument("--state", type=Path, required=True)
    clean_parser = sub.add_parser("clean")
    clean_parser.add_argument("--app", type=Path, required=True)
    clean_parser.add_argument("--state", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        result = build(args.app)
    elif args.command == "launch":
        result = launch(args.app, args.state)
    elif args.command == "status":
        result = load_owned(args.state)
    elif args.command == "stop":
        result = stop(args.state)
    else:
        result = clean(args.app, args.state)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
