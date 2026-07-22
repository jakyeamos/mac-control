# macctl

`macctl` is a command-first macOS control plane. A per-user `macctld` daemon
owns the GUI session and exposes a local, owner-only Unix socket to the CLI.

The implementation deliberately starts with Apple frameworks: AppKit,
ApplicationServices (Accessibility), CoreGraphics, ScreenCaptureKit, Vision,
Foundation, and `launchd`. Third-party event or OCR helpers are not required by
the baseline.

## Build

```sh
swift build
swift test
```

The built binaries are under `.build/`:

```sh
swift run macctl doctor --json
swift run macctl capabilities --json
swift run macctl app list --json
```

`capabilities` and the read-only workflow/app listings can report locally when
the daemon is not running. `doctor` and `status` are daemon-authoritative:
when the socket is unavailable they return a blocked response with an explicit
unknown permission/runtime context.

The installed command path is:

```sh
swift run macctl install
~/.local/bin/macctl daemon install
```

The first command installs `macctl` at `~/.local/bin/macctl` and packages the
daemon at `~/.local/share/macctl/macctld.app`. The second command installs and
loads the user LaunchAgent, which executes the bundle's
`Contents/MacOS/macctld` binary. Use `~/.local/bin/macctl daemon restart` after
rebuilding and reinstalling.

## Daemon lifecycle

```sh
swift run macctl install
~/.local/bin/macctl daemon install
swift run macctl daemon status
~/.local/bin/macctl daemon restart
~/.local/bin/macctl daemon remove
```

Installation writes the user LaunchAgent at
`~/Library/LaunchAgents/com.jakyeamos.macctl.daemon.plist` and uses only the
user `gui/<uid>` launchd domain. The socket is
`~/Library/Application Support/macctl/macctld.sock` and is never exposed over
TCP. The daemon app bundle has the stable identifier
`com.jakyeamos.macctl.daemon`; add the packaged `macctld.app` itself in macOS
Privacy & Security settings.

Useful read-only commands include:

```sh
~/.local/bin/macctl doctor --json
~/.local/bin/macctl capabilities --json
~/.local/bin/macctl status --json
~/.local/bin/macctl app list --json
~/.local/bin/macctl workflow list --json
~/.local/bin/macctl iphone status --json
~/.local/bin/macctl receipts status --json
~/.local/bin/macctl receipts list --json
~/.local/bin/macctl release check --json
```

`macctl release check --json` is the Tier-1 machine-readable gate. It checks
the packaged launchd identity, live daemon permissions, owner-only transport,
receipt storage/retention, fresh Mac GUI smoke receipts, fresh iPhone
Mirroring Tinder evidence, and approval/fail-closed evidence. It does not run
workflows as a side effect; missing live evidence is reported as `blocked`.

Receipts are schema-versioned JSON records in
`~/Library/Application Support/macctl/receipts/`. The daemon retains the
newest 1,000 records, writes the directory with mode `0700` and files with
mode `0600`, and stores execution/verification results plus redacted evidence
metadata. Credentials, ephemeral text, OCR text, screenshots, image bytes,
message bodies, and sensitive selector values are not persisted.

## Safety boundary

Workflows use `prepare -> approve -> execute -> verify`. Sensitive actions must
be prepared first and approved through a short-lived, single-use token. The
daemon never accepts credentials or other secrets as command-line arguments,
and screenshot/OCR frames are held in memory only for the requested operation.

Generic workflow JSON files may be placed in
`~/Library/Application Support/macctl/workflows/`. Accessibility, keyboard,
and mouse input actions are classified conservatively: click, key, and type
actions require a sensitive approval plan; scroll is reversible. Type actions
must declare `text_source=ephemeral` and receive their value only through an
owner-only socket request. The CLI supports this without putting the value in
the process arguments:

```sh
secret-producing-command | ~/.local/bin/macctl workflow prepare my.workflow --ephemeral-stdin
```

The stdin body must be a JSON object whose values are strings. After the visible
approval, execute the exact prepared plan with
`~/.local/bin/macctl approval approve <token>`; the token is single-use and the
ephemeral input is never returned by the daemon or written to its log.

macOS Accessibility, Input Monitoring, Screen Recording, and Automation
permissions remain user-controlled. `macctl doctor --json` reports what is
available and returns instructions; it does not attempt to bypass TCC.

After migrating from an older bare `macctld` executable, remove the old
`macctld` entry from Accessibility, Screen Recording, and Input Monitoring if
it remains, then add `~/.local/share/macctl/macctld.app` to each list and
restart the daemon. TCC permissions are attached to the packaged application
identity, not granted automatically by the installer.

The iPhone Mirroring backend is intentionally layered on top of the same
Accessibility, window capture, OCR, and normalized-coordinate primitives. It
does not treat `devicectl` as the consumer iPhone control path.

The user-gated smoke path is:

```sh
~/.local/bin/macctl workflow run iphone.open-tinder --json
```

It activates iPhone Mirroring, locates Tinder through an ephemeral OCR frame,
and verifies visibility. It does not swipe, message, purchase, or submit. If
Screen Recording, input, or a paired Mirroring session is unavailable, it
returns a blocked result instead of attempting a best-effort click.

The project does not modify AIOS or career-ops. Integration adapters remain a
later step after this standalone control plane is permissioned and proven.
