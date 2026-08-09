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

Install the provider-neutral agent skill and its Codex projection separately:

```sh
python3 scripts/install_mac_control_skill.py install
python3 scripts/install_mac_control_skill.py check
```

The repository copy under `skills/mac-control/` is the distribution source.
The installer writes the live provider-neutral skill to
`~/.agents/skills/mac-control` and creates the Codex discovery symlink at
`~/.codex/skills/mac-control`. It preserves replaced payloads under
`~/.agents/rollback/` and verifies source identity plus projection after every
install.

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
~/.local/bin/macctl receipts status --json
~/.local/bin/macctl receipts list --json
~/.local/bin/macctl release check --json
```

`macctl release check --json` is the Tier-1 machine-readable gate. It checks
the packaged launchd identity, live daemon permissions, owner-only transport,
receipt storage/retention, fresh Mac GUI smoke receipts, and approval/fail-closed
evidence. It does not run workflows as a side effect; missing live evidence is
reported as `blocked`.

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
visual selectors, coordinate fallbacks, and foreground assertions. This keeps a
workflow from silently falling back to global mouse or
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
default `shared` mode is a logical safety boundary; it leaves the physical
keyboard available and cannot stop a person from pressing a key at the same
time. For an intentional, interactive session you can opt into software
suppression of physical keyboard events:

```sh
~/.local/bin/macctl keyboard lease acquire \
  --scope session --seconds 120 --suppress-physical-keyboard \
  --reason "interactive keyboard freeze" --confirm --json
```

Suppression is session-scoped and is available only on a session lease. It
requires user-granted Accessibility and Input Monitoring access, fails closed
if macOS cannot install the event tap, and ends on release, lease expiry, or
daemon shutdown. It is not a hardware or driver lock: the mouse remains
available for the status-item `Quit daemon` emergency path, and synthetic
`macctl` keyboard events are marked so the agent's own input can still run.
Use the default shared mode for app-scoped or unattended workflows.

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

Accessibility selectors can be scoped to one uniquely titled or identified
window. This prevents a duplicate control in another Chrome window from being
treated as the target. A native context menu can be opened and verified by
requiring the expected menu labels:

```sh
~/.local/bin/macctl control perform context-menu \
  --app "Google Chrome" --confirm \
  --role AXButton --identifier tab-group \
  --window-title "Project - Google Chrome" \
  --expected-menu-items "Add tab to new group" --json
```

`foreground_only` is evidence that the app remained foreground, not proof that
the action completed; the service returns it as blocked with
`control_verification_unavailable`. The provider exposes verified native
context-menu capability, but it does not implement Chrome tab/group mutation.
`control capabilities --app "Google Chrome" --json` reports that boundary as
`unsupportedCapabilities: ["chrome_tab_group_mutation"]`.

Mac Control does not assume one route is fastest for every app. For a known
task, execute bounded daemon samples for the exact app version, target
fingerprint, action, route, and verification oracle, then inspect the selected
route:

```sh
~/.local/bin/macctl route benchmark --app "System Settings" \
  --task focus-next-control --target-fingerprint "settings-pane" \
  --action next-control --route keyboard \
  --verification-oracle "focus changed" --samples 5 --warmups 1 \
  --confirm --json
~/.local/bin/macctl route inspect --app "System Settings" \
  --task focus-next-control --target-fingerprint "settings-pane" --json
```

Semantic scroll routes can be benchmarked by the daemon as well. Use a unique, readable
`AXScrollArea` identifier and reset to the opposite direction before each repeated invocation:

```sh
~/.local/bin/macctl route benchmark --app "Chrome" \
  --task scroll-main --target-fingerprint "scroll-v1" \
  --action scroll --route scroll --role AXScrollArea --identifier main-scroll \
  --direction down --amount 1 --reset-direction up --reset-amount 1 \
  --verification-oracle "viewport changed" --samples 5 --warmups 1 \
  --confirm --json
```

The benchmark measures the daemon's semantic AX scroll route, verifies every bounded invocation,
and persists no warm-path manifest when reset or measured scrolling is unverified.

Safety, permission, target-uniqueness, freshness, and verification gates run
before speed ranking. The fastest fresh measured candidate wins by complete
action latency, then p95 latency and recoveries. Unmeasured or stale paths are
unproven and require rebenchmarking. Visual and coordinate routes require
explicit manifest opt-in. Only a declared pre-action target-not-found failure
may advance through a fallback chain; possible side effects and failed
verification stop the action. Every response reports the selected route and
fallback chain without persisting selector values, AX values, private text,
screenshots, OCR, or raw key sequences.

Use `route register` only for explicitly caller-supplied external metadata; it
is not equivalent to the daemon-executed benchmark.

Agents can inspect the route contract before acting and batch verified navigation
within one foreground app:

```sh
~/.local/bin/macctl control capabilities --app "Chrome" \
  --task focus-next --target-fingerprint focus-v1 --json
~/.local/bin/macctl control capability-audit --app "Chrome" \
  --max-nodes 500 --max-depth 8 --json
~/.local/bin/macctl control capability-audit-batch --all-applicable --json
printf '%s\n' '[{"action":"next-control"},{"action":"next-control"}]' | \
  ~/.local/bin/macctl control batch --app "Chrome" --actions-stdin --confirm --json
```

The fast capability probe reports app archetype plus fresh measured, stale, and
caller-supplied route inventory and may read a cached broad profile without
walking AX. The separate `capability-audit` command performs one bounded,
read-only AX/provider audit and persists a profile keyed by app install
identity/version, OS/provider state, and UI-tree signature. It stores stable
redacted locator descriptors rather than raw AX elements. Positive, negative,
and ambiguous evidence promotes, demotes, or leaves capabilities as candidates;
task verification can update or invalidate the profile after execution. The
archetype is descriptive and never grants provider parity. Do not run the deep
audit before every action. After recursive retries reach the fixed ceiling, a
    separate bounded window-aware/page traversal may inspect up to 8 windows, 256
top-level pages, and 16,000 total nodes. Only complete coverage promotes the
profile; omitted or truncated pages keep it stale and are reported as evidence.
A batch holds one bounded app lease, revalidates
every step, stops on an unverified step, and releases the lease. Scroll is
intentionally kept on `control perform` so a provider handoff remains explicit.

For a machine-wide inventory, `capability-audit-batch --all-applicable` selects
up to 24 installed user-facing applications from the catalog and audits only
applications that are already running. It never launches an app or dispatches
input. Each app gets a durable redacted receipt and an unresolved or failed app
remains resumable with `--run-id`; AX access is serialized for predictable
provider behavior. Use `--apps` to provide an explicit subset.

Every control response exposes a provider-neutral `outcome`. Only
`verified_success` with `verification: passed` is completion. For semantic
scroll failures that recommend Computer Use, the agent must call
`get_app_state`, locate a fresh unique scroll target, use `sky.scroll`, and
verify a changed state; it must not replay a stale AX target or treat a
dispatched event as success.

For a bounded structural Accessibility check, inspect or audit the running app
without reading AX values or private content:

```sh
~/.local/bin/macctl accessibility tree --app "System Settings" --json
~/.local/bin/macctl accessibility audit --app "System Settings" \
  --manifest ./accessibility-manifest.json --json
```

### Mac Control ideal-state audits

Repositories that expose a supported Mac Control task surface can own a
versioned `.mac-control/ideal-state.json` manifest. The manifest describes the
stable target, semantic action, observable postcondition, state contract,
navigation strategy, and eligible routes for each supported task. Validate the
manifest without touching a running app:

```sh
~/.local/bin/macctl ideal-state validate \
  --manifest /path/to/repository/.mac-control/ideal-state.json --json
```

An explicitly authorized live structural lane validates the manifest and
checks its declared Accessibility controls in the named app. It returns only
redacted structural findings:

```sh
~/.local/bin/macctl ideal-state audit \
  --app "System Settings" \
  --manifest /path/to/repository/.mac-control/ideal-state.json --json
```

This audit does not invent task success from a tree inspection. Measured task
attempts, selected routes, and readable postconditions remain backed by the
normal approval-gated `task.*` or route receipts. Quality Runner consumes those
redacted measurements as `mac-control-task-evidence/v1` sidecars and keeps the
static, live structural, and task-execution evidence distinct.

When a target lives inside a readable scroll container, use semantic scrolling
with a unique `AXScrollArea` selector. An identifier is preferred, but optional
when role-only resolution returns exactly one container; Mac Control verifies
that the container can still be resolved after the action:

```sh
~/.local/bin/macctl control perform scroll --app "System Settings" \
  --role AXScrollArea --identifier settings-list --direction down \
  --amount 1 --confirm --json
```

If AX cannot perform the action or cannot verify a changed viewport, the response is blocked
with machine-readable `failure_class`, `fallback_allowed`, and (when appropriate)
`recommended_provider: computer_use` plus `fresh_state_required: true`. The agent should then
refresh app state, find a fresh scrollable element, use Computer Use scroll, and verify the
changed state. The Mac Control low-level input route is opt-in and fail-closed:

```sh
~/.local/bin/macctl control perform scroll --app "System Settings" \
  --role AXScrollArea --identifier settings-list --direction down \
  --amount 1 --fallback input-scroll --confirm --json
```

An input event that was merely dispatched is reported as unverified; it is not treated as
completion unless the returned verification state is `passed`.

Repeated keyboard navigation remains available when a fresh warm path proves
it is the fastest verified route. The named `search` and `commands-help`
actions cover command-palette or keyboard-help surfaces when an app exposes
them; app-specific command-palette identifiers belong in that app's manifest.

For a searchable native list, prefer the generic atomic `search` action when a
redacted Accessibility tree or manifest exposes one unique `AXTextField` with
subrole `AXSearchField`. It uses the named `Tab-F` shortcut only when the
declared keyboard route is eligible, replaces ephemeral query text by default,
and verifies `search_field_focused`. Missing or ambiguous fields and failed
focus verification block the action; serial `Tab` traversal is never an
implicit fallback. Result finding, selection, and opening remain separate
declared task actions or predicates.

For safe manual smoke evidence, put Chrome or System Settings in the
foreground, acquire a short app lease, run `commands-help` or
`next-control`, inspect focus, close any help UI with `Escape`, and release
the lease. Keep this separate in the evidence record: XCTest proves source
behavior, daemon receipts prove lease/input/redaction events, and the manual
 GUI run proves the current Mac actually responded. Browser DOM automation is
 outside `mac-control`.

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
