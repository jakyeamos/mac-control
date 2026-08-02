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

### Focus-preserving background workflows

Workflows default to `focusPolicy: "foreground"`. A caller can request
`focus_policy: "background"` for a workflow or app launch when the operation
must not bring its target to the front:

```sh
~/.local/bin/macctl workflow validate my.workflow --background --json
~/.local/bin/macctl workflow prepare my.workflow --background --json
~/.local/bin/macctl app open "TextEdit" --background --json
```

Background workflow execution is deliberately narrower than foreground
execution. It launches apps with a non-activating AppKit configuration, targets
Accessibility actions at a named macOS app process, sends keyboard events to
that process, and checks the foreground application before and after every
action. The focus policy is part of the approval digest and is preserved in
execution reports and receipts.

The background validator rejects activation, scroll, desktop capture/OCR,
iPhone Mirroring, visual selectors, coordinate fallbacks, and foreground
assertions. This keeps a workflow from silently falling back to global mouse or
keyboard input. Background window capture/OCR is available only when it names a
macOS app explicitly. The mode still requires a logged-in Aqua session and the
user-granted Accessibility, Input Monitoring, Post Events, and Screen Recording
permissions; it is focus-preserving in-session execution, not a displayless
server.

True displayless browser/API headless execution remains the responsibility of a
caller such as Career Ops or OpenCLI. Those callers can invoke this local
control plane when they need macOS GUI interaction; the local background
interaction contract stays owned by `mac-control`.

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

The built-in `approval.smoke` workflow is the release-evidence path for this
boundary. It only waits for 0.2 seconds, performs no external input, and is
classified as sensitive solely so the approval lifecycle can be exercised
without changing an app, device, account, or document. The Tier-1 gate accepts
fresh HUD-sourced approve and deny receipts, a fresh expiry receipt from the
HUD or the daemon CLI, and a direct fail-closed run without a token. Expiry is
a backend state transition; the HUD must remain visible and untouched until
the token expires.

macOS Accessibility, Input Monitoring, Screen Recording, and Automation
permissions remain user-controlled. `macctl doctor --json` reports what is
available and returns instructions; it does not attempt to bypass TCC.

## Keyboard-first control

The keyboard surface drives visible macOS applications and browser windows
through Full Keyboard Access and the foreground application's Accessibility
focus. It does not automate browser DOMs, inject text, or replace the
approval-gated workflow `key` and `type` actions.

The named sequences follow [Apple's Full Keyboard Access guide](https://support.apple.com/en-gb/guide/mac-help/-mchlc06d1059/mac), and status verification uses
[`NSApplication.isFullKeyboardAccessEnabled`](https://developer.apple.com/documentation/appkit/nsapplication/isfullkeyboardaccessenabled).

Check or configure Full Keyboard Access with:

```sh
~/.local/bin/macctl keyboard status --json
~/.local/bin/macctl keyboard setup --json
~/.local/bin/macctl keyboard enable --confirm --json
```

`keyboard setup` is non-mutating. It reports the System Settings path and
recovery instructions. `keyboard enable --confirm` is the only command that
writes `AppleKeyboardUIMode`; the daemon never enables the preference at
startup and verifies the resulting AppKit status before reporting success.

Input requires an explicit, in-memory lease. Leases last 120 seconds by
default, may be shortened or extended up to 300 seconds, and only one may be
active in the daemon:

```sh
~/.local/bin/macctl keyboard lease acquire \
  --scope app --app "Google Chrome" --seconds 120 --confirm --json
# pass the returned lease.token to the following commands
~/.local/bin/macctl keyboard navigate commands-help --lease-token "$TOKEN" --json
~/.local/bin/macctl keyboard inspect --json
~/.local/bin/macctl keyboard send escape --lease-token "$TOKEN" --json
~/.local/bin/macctl keyboard lease release "$TOKEN" --json
```

An app lease binds to the named foreground application and its process. A
session lease follows foreground application changes, but blocks when the
foreground process cannot be read. Every key in a sequence revalidates the
lease, Post Events permission, and the applicable foreground condition. The
lease is a logical safety boundary; it cannot stop a person from pressing a
physical key at the same time.

Named navigation commands use Apple's Full Keyboard Access sequences:

| Command | Keys |
| --- | --- |
| `next-control` / `previous-control` | `Tab` / `Shift-Tab` |
| `activate` | `Space` |
| `next-item` / `previous-item` | `Control-Tab` / `Control-Shift-Tab` |
| `search`, `window-chooser`, `application-chooser` | `Tab-F`, `Tab-W`, `Tab-A` |
| `menu-bar`, `dock` | `Fn-Control-F2`, `Fn-A` |
| `control-center`, `notification-center` | `Fn-C`, `Fn-N` |
| `pointer-to-focus`, `commands-help` | `Tab-C`, `Tab-H` |
| `pass-through` | `Control-Option-Command-P` |

`keyboard send` accepts only bounded `KeySpecification` sequences for
non-printable shortcuts and timing. Bare printable characters are rejected;
text, credentials, and ephemeral content remain on the existing
approval-gated path. `keyboard inspect` returns only focused role, subrole,
identifier, title, and target application. It never returns AX values,
document text, screenshots, OCR text, or child trees.

### Verified semantic control

The higher-level control session composes the same lease boundary with a
route-aware action planner. Inspect the current foreground/focus state with:

```sh
~/.local/bin/macctl control status --json
```

Use `control perform` for a visible application action. It requires the same
short-lived keyboard lease and verifies the foreground process after the
action:

```sh
~/.local/bin/macctl control perform activate \
  --lease-token "$TOKEN" --role AXButton --title "Save" --json
```

For a self-contained action, provide the target app and explicit confirmation
instead of a lease token. The daemon activates the app, waits for two stable
foreground reads, acquires an app-scoped ephemeral lease, performs and verifies
the action, and invalidates the lease before replying. Foreground changes still
fail closed with `keyboard_focus_changed`.

```sh
~/.local/bin/macctl control perform next-control \
  --app "System Settings" --confirm --json
```

Routing is ordered by confidence: an Accessibility selector is attempted
first; if the target is not found, the named keyboard command is used; visual
text/image or normalized-coordinate selectors are the last fallback. Raw
coordinates require `--allow-raw-coordinate`. The response reports the route,
whether fallback was used, and redacted focus/foreground verification metadata
without persisting selector values, AX values, private text, screenshots, or
raw key sequences.

For safe manual smoke evidence, put Chrome or System Settings in the
foreground, acquire a short app lease, run `commands-help` or
`next-control`, inspect focus, close any help UI with `Escape`, and release
the lease. Keep this separate in the evidence record: XCTest proves source
behavior, daemon receipts prove lease/input/redaction events, and the manual
GUI run proves the current Mac actually responded. Browser DOM automation is
outside `mac-control`; iPhone Mirroring is a separate shared-input surface
with its own lease and evidence boundary.

## Checkpointed task control

For multi-step work, use `task.*` with a structured plan. A task plan names
typed actions, target identity, preconditions, postconditions, risk,
approval reason, timeout, and its declared recovery policy. It is not free-form
task text and it cannot invoke arbitrary shell commands or AppleScript/JXA:

```sh
cat plan.json | ~/.local/bin/macctl task prepare --plan-stdin --json
~/.local/bin/macctl approval approve "$TASK_APPROVAL_TOKEN" --json
cat plan.json | ~/.local/bin/macctl task run --plan-stdin \
  --approval-token "$TASK_APPROVAL_TOKEN" --lease-token "$LEASE_TOKEN" --json
~/.local/bin/macctl task status "$TASK_ID" --json
~/.local/bin/macctl task cancel "$TASK_ID" --json
```

`task.prepare` returns an approval bound to the exact serialized plan,
target, risk, recovery policy, and ephemeral-input digest. Any plan or
ephemeral-input change invalidates it. Mutating keyboard and adapter steps
also require the short-lived control lease. Private text is supplied through
owner-only stdin and is used in memory only.

Checkpoints are separate from receipts, atomic, owner-only, retention-bounded,
and redacted. They contain task and step identity, hashes, route, attempt
counts, timestamps, lifecycle state, and redacted verification status; they do
not contain selectors, AX values, screenshots, OCR, credentials, private
document/message bodies, lease tokens, or approval tokens. The states are
`prepared`, `running`, `paused`, `blocked`, `indeterminate`, `completed`,
`cancelled`, and `expired`. Safe steps may use at most three bounded attempts,
reversible steps at most two, and sensitive steps dispatch once. An uncertain
sensitive result becomes `indeterminate` and is never retried automatically.

After interruption or daemon restart, automatic resume is disabled. Supply the
original plan again, obtain a fresh lease and permission/target validation,
prepare and approve the remaining checkpointed plan, then call `task.resume`.
No fallback route is invented after an action may already have caused an
external side effect. `task.status` and `task.cancel` remain available without
input authority; cancellation is cooperative and is checked before each
action and at bounded action checkpoints.

### Allowlisted application adapters

`macctl adapter capabilities --json` reports the typed adapter manifests,
routes, read/mutating behavior, required permissions, risk, redacted
observation schema, and Automation diagnostics. The initial allowlist covers
Finder, System Settings, Terminal, TextEdit, Preview, Mail, Calendar, Notes,
and Messages. Adapters prefer native/AppKit, Accessibility, and keyboard
routes; typed AppleScript is available only for declared operations and never
as arbitrary script execution. Unsupported operations, missing Automation,
ambiguous targets, modal dialogs, unreadable focus, and hung applications
block or pause with an explicit capability reason.

Read-only observation may run without input authority. Adapter mutations use
the same lease, foreground, process, window, focused-element, and per-action
revalidation boundary as keyboard control. Credentials and private
document/message content remain ephemeral. Browser DOM automation remains
outside this project: Chrome and Safari are controlled through visible UI.
iPhone Mirroring remains a separate shared-input lease and evidence surface.

For task evidence, keep XCTest behavior, daemon receipts/checkpoint records,
and manual GUI response as separate proof layers. A safe manual smoke can use
Finder or System Settings plus a TextEdit document with no private content,
then a read-only adapter inspection or an empty draft operation only when the
declared Automation permission is available. Missing permission, ambiguous
target, expired authority, and unsupported capability must be recorded as
blocked evidence rather than bypassed.

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

The approval-evidence path is:

```sh
~/.local/bin/macctl workflow prepare approval.smoke --json
```

Use the HUD to approve one prepared plan and deny a second. For expiry, leave
a third HUD panel untouched until its 120-second token expires, then attempt
Approve from the HUD or run `macctl approval approve <token>` and confirm the
result is `approval_expired`. Finally run
`~/.local/bin/macctl workflow run approval.smoke --json` without a token; it
must be blocked. Double-tapping Caps Lock may bring the HUD forward but never
approves a plan or changes the Caps Lock state.

The project does not modify AIOS or career-ops. Career Ops can invoke this
standalone control plane when a local macOS interaction is required.
