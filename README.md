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
swift run macctl --version
swift run macctl version --json
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

Every binary install, LaunchAgent install, restart, and removal first asks the
live daemon for a short atomic lifecycle drain. Pending proposals,
approved-but-unconsumed authority, active keyboard leases/executions, and
in-flight mutations block the operation. Once admitted, the daemon temporarily
rejects new mutations while the lifecycle command changes installed state. A
healthy daemon whose interlock cannot be reached fails closed; an unhealthy
daemon remains restartable for recovery. Approval and lease tokens are never
persisted or returned by this contract.

The first upgrade from a daemon that predates lifecycle drains requires the
explicit one-time `--allow-legacy-idle-snapshot` flag after the owner confirms
the control center is idle. That compatibility path still blocks visible
pending approvals and execution; after the new daemon is restarted, ordinary
atomic drains are required and the flag is no longer needed.

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
~/.local/bin/macctl --version
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
the packaged launchd identity, installed/runtime artifact parity, live daemon permissions, owner-only transport,
receipt storage/retention, fresh Mac GUI smoke receipts, and approval/fail-closed
evidence. It does not run workflows as a side effect; missing live evidence is
reported as `blocked`.

`macctl install` writes an owner-only build/install identity manifest, and the
daemon writes a separate owner-only process identity at startup. This lets the
release gate and Pronto distinguish an unrebuilt package, an out-of-date
installation, and an installed daemon that still needs a restart. Daemon health
alone is never version parity. Set `MACCTL_SOURCE_REVISION` to the exact Git
revision when installing a package outside its source checkout; an unavailable
revision remains `unverifiable`.

Release-relevant receipts are also projected into a bounded hidden archive
under the receipt directory. The archive keeps only the newest proof for each
required release dimension, so rolling diagnostic retention cannot evict the
last valid release proof. Receipt and archive publication use a cross-process
owner-only lock plus a `0600` temporary file, durable flush, and atomic rename;
`release check` reads the union while ordinary receipt listing remains the
newest 1,000 diagnostic records.

Receipts are schema-versioned JSON records in
`~/Library/Application Support/macctl/receipts/`. The daemon retains the
newest 1,000 records, writes the directory with mode `0700` and files with
mode `0600`, and stores execution/verification results plus redacted evidence
metadata. Credentials, ephemeral text, OCR text, screenshots, image bytes,
message bodies, and sensitive selector values are not persisted. Version 2
control receipts additionally retain the provider-neutral outcome, installed
app identity/version, selector field names, and digests of the app path,
locator, and optional target fingerprint. This supports recurrence detection
without retaining raw selector labels or application paths. Version 3 adds the
requested focus policy, effective focus policy, route-selection reason, and any
background-unavailable reason so an automatic foreground fallback is
explainable without retaining user content.

Version 4 adds joined cross-provider trace metadata for browser handoffs:
opaque trace/span IDs, provider and provenance, digests of provider observation
identifiers, foreground preservation, and millisecond timing fields. A trace
contains a Mac Control-attested handoff observation and, after completion, an
`orchestrator_declared` browser observation. It does not represent browser-owned
attestation until the browser provider exposes such a receipt.

Web-content handoffs include a short-lived, one-completion credential with
idempotent retry for the identical completion.
Keep that credential in memory and submit the bounded completion object only on
stdin; never put it in arguments, shell history, environment variables, or a
file. The CLI rejects trailing arguments and stdin payloads larger than 8 KiB.
Mac Control persists only credential and bounded-completion digests and rejects
raw URL, title, DOM, or page-content fields:

```sh
~/.local/bin/macctl receipts trace <trace-id> --json
browser_completion_json | ~/.local/bin/macctl receipts trace-complete --stdin --json
```

The trace view reports `mac_routing_ms`, `handoff_to_completion_ms`, `total_ms`,
and `focus_interruption_count`. These measure the orchestration boundary, not
browser action latency alone.

## Authorization notices

Codex may prepare a short-lived, explanatory notice before a command that can access a
credential, Keychain item, or permission-protected service. The daemon exposes the notice
lifecycle through the owner-only socket:

```sh
~/.local/bin/macctl control authorization prepare --json \
  --kind credential --project mac-control --action "read credential" \
  --summary "Git credential helper access" \
  --target-service github.com --source-reference codex://thread/<id>
~/.local/bin/macctl control authorization list --json
~/.local/bin/macctl control authorization resolve <request-id> \
  --outcome completed --json
```

Requests contain only bounded safe context: project/repository, task and thread identity,
requesting helper, target service, action, summary, expiry, and an allowlisted `codex://`
source reference. Raw commands, arguments, prompts, passwords, tokens, private input, and
environment values are rejected or omitted. `bind` records a process correlation after launch;
it does not grant access or operate the native macOS prompt.

Inspect notices with `control authorization list --json`. It reports the declared source beside
the daemon-observed peer executable/signing identity and labels provenance as `ATTESTED`,
`DECLARED`, or `UNVERIFIED`. `ATTESTED` means only that the declared helper correlated with the
local socket peer; it is not a safety verdict or approval. The menu-bar safety item does not
present authorization notices or open source references. General attention delivery belongs to
the independent attention provider. An unannounced external dialog remains unverified in v1.

The transient native safety item publishes stable Accessibility identifiers for semantic
inspection: `macctl.control-safety.status`, `macctl.control-safety.window`, and
`macctl.control-safety.health`. Active checkpointed tasks also publish `macctl.task.progress`,
`macctl.task.progress.count`, and one redacted `macctl.task.progress.<step-id>` row per step.
Rows show only plan-derived labels and the states `Pending`, `Running`, `Verified`, or `Stopped`;
targets, selectors, inputs, and output stay out of the snapshot. The item disappears when active
authority ends; use CLI status and receipts for completed task history. It remains hidden for
idle, pending-approval, authorization-notice, and one-shot focus states.

## Safety boundary

Workflows use `prepare -> approve -> execute -> verify`. Sensitive actions must
be prepared first and approved through a short-lived, single-use token. The
daemon never accepts credentials or other secrets as command-line arguments,
and screenshot/OCR frames are held in memory only for the requested operation.

### Focus-preserving background workflows

Agent-facing CLI workflow, app-open, and direct-control requests default to
`focus_policy: "automatic"`. Automatic execution first admits the exact
operation to a verified background route. If no such route is eligible before
dispatch, Mac Control immediately uses the normal foreground path; it does not
wait for idle time, queue the action, or consolidate focus changes. Callers can
still force `focus_policy: "foreground"`, or request fail-closed
`focus_policy: "background"` when preserving focus is mandatory:

```sh
~/.local/bin/macctl workflow validate my.workflow --background --json
~/.local/bin/macctl workflow prepare my.workflow --background --json
~/.local/bin/macctl app open "TextEdit" --background --json
```

The requested policy remains part of the approval digest. Automatic is
resolved only for execution, and results and receipts distinguish
`requested_focus_policy` from effective `focus_policy`, with
`focus_selection_reason` and (for fallback) `background_unavailable_reason`.
This prevents changing approval authority merely because live target state
made one route eligible or ineligible.

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

The stdin body must be a JSON object whose values are strings. The transient menu-bar safety
item does not present or commit approvals. While the legacy approval backend remains during its
separate removal, use its explicit CLI lifecycle; the token is consumed at first dispatch, and
ephemeral input is never returned by the daemon or written to its log.

The menu-bar item does not announce one-shot focus changes. For an agent run that spans multiple
native actions or a Computer Use handoff, explicitly start one bounded hands-off session so the
safety item can truthfully cover the entire run:

```sh
~/.local/bin/macctl control hands-off begin --provider hybrid \
  --app "Google Chrome" --task context-menu --seconds 60 --confirm --json
~/.local/bin/macctl control perform context-menu --app "Google Chrome" \
  --hands-off-session-id <session_id> --confirm --json
~/.local/bin/macctl control hands-off heartbeat --session-id <session_id> --json
~/.local/bin/macctl control hands-off end --session-id <session_id> --json
```

Pass the returned opaque session ID to each native action or batch, and heartbeat before the
reported interval. While active, the pill says `Hands Off` and the safety popover explicitly tells
the user not to use the keyboard or trackpad; expiry, Stop & Release, or daemon shutdown clears it.
The session is caller-owned and never inferred from an individual action. `Frozen` remains the
higher-salience state when physical keyboard suppression is active.

The legacy `approval.smoke` workflow remains a backend release-evidence path while approval
removal is completed separately. It does not use the safety item. The existing installed release
gate still expects its former Control Center receipts and therefore remains blocked until that
gate is migrated or removed with the approval backend; source tests for the safety item do not
substitute for that live evidence.

macOS Accessibility, Input Monitoring, Screen Recording, and Automation
permissions remain user-controlled. `macctl doctor --json` reports what is
available and returns instructions; it does not attempt to bypass TCC.

## Menu commands and app shortcuts

`macctl shortcut` turns exact macOS menu paths into reusable, app-scoped
command bindings. Discovery is read-only and inspects only applications that
are already running:

```sh
~/.local/bin/macctl shortcut audit --app "Finder" --json
~/.local/bin/macctl shortcut propose \
  --app "Finder" --menu-path "View->Show Status Bar" --json
~/.local/bin/macctl shortcut inspect sc_<digest> --json
```

Menu paths use Apple's exact `Menu->Submenu->Command` spelling, including
punctuation and ellipses. Audits reject hidden, dynamic, or ambiguous items.
A static item that is disabled only in the current app state is reported as
`needs_postcondition`, because contextual commands such as Chrome's
`Tab->Group Tab` can become enabled for a valid target. An explicit proposal
for such a command must declare a behavior postcondition, and execution still
revalidates that the item is enabled before dispatch. Audits distinguish
`eligible`, `needs_postcondition`, `conflict`, `unsupported`, and `not_running`.
For Chrome `Tab->Group Tab`, the immediate structural result is the focused
group editor field exposed as `AXTextField` with the accessible name
`Tab-group title`. Use that exact focused-element predicate for shortcut-level
verification, then require browser-native readback of the expected group label
before treating the grouping task as complete. Chrome may leave the menu item's
enabled state unchanged, so `menu_item_state=disabled` is not a valid
postcondition for this command.
Suggestions avoid enabled macOS system
shortcuts, the target app's current menu equivalents, and Mac Control's binding
registry. A suggestion is only a proposal; it is never installed in bulk.

Direct menu activation and shortcut setup, execution, and removal are
sensitive operations. Calling one without authority prepares a digest-scoped,
single-use approval:

```sh
~/.local/bin/macctl shortcut run sc_<digest> --route accessibility --json
~/.local/bin/macctl approval approve <token> --json
~/.local/bin/macctl shortcut run sc_<digest> \
  --route accessibility --approval-token <token> --json
```

The keyboard route additionally requires a configured chord and an app-scoped
keyboard lease. Dispatch occurs at most once; if the declared postcondition is
indeterminate or fails, the binding is not promoted to `behavior_verified` and
the command is never retried automatically.

Before declaring browser chrome blocked because a tab-strip context menu is not
reliably addressable, audit the browser's ordinary application menus for an
equivalent exact command. A verified app shortcut may serve as the actuator
while the browser connector supplies target selection and behavior readback.
This does not imply general tab-strip mutation support: the exact command,
eligible app state, and task postcondition must each pass independently.

For a macOS App Shortcut, `shortcut setup` opens the supported System Settings
surface and reports the exact menu-path text to enter. Rerun setup after the
human step so Mac Control can read the resulting menu key equivalent. Chrome
extension commands use `chrome://extensions/shortcuts` and only target a unique
semantic command field discovered from an already-installed extension's
manifest. If Chrome does not expose one unique field, setup stops with
`handoff_required`; it never traverses the page by blind Tab presses.

Bindings are stored atomically in the owner-only
`~/Library/Application Support/macctl/shortcut-bindings/bindings.json`. The
original chord is retained for exact rollback. `proposed`, `setup_required`,
`configured`, `behavior_verified`, `stale`, and `blocked` remain distinct in
capability and release reports.

The bounded read-only acceptance inventory is:

```sh
scripts/shortcut-smoke.sh
```

It audits Finder, Google Chrome, Cursor, and Xcode only when observable and
does not launch apps, assign shortcuts, approve operations, or dispatch input.

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

If Full Keyboard Access is enabled but the current interaction is in
Pass-Through Mode, an explicitly opted-in session lease can temporarily enter
navigation mode:

```sh
~/.local/bin/macctl keyboard lease acquire \
  --scope session --seconds 120 --navigation-mode \
  --from-pass-through --confirm --json
```

This transition is separate from physical keyboard suppression. The caller
must assert `--from-pass-through`; macOS documents the toggle shortcut but
does not expose a pass-through state property for Mac Control to read back.
The response therefore marks the state source as `caller_asserted`. The lease
owns the inverse toggle and performs it on release, expiry, or daemon
shutdown. If that restoration is ambiguous, the lease is removed but new
navigation leases are blocked and `keyboard.status` reports
`navigationRestorationPending`. There is no safe agent-side clear or
pass-through readback; stop input and hand off to the user to restore the
intended macOS state until an explicit reconciliation path reports the flag
false.
Navigation mode is session-only because Pass-Through Mode is global to the
Full Keyboard Access interaction, so unattended app-scoped leases should use
the default mode.

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

Declare the focus expectation on agent-facing calls. The default is
`focus_policy=automatic`. Direct `control.perform` and `control.batch` do not
own the named-process authority required for background mutation, so automatic
requests on those low-level surfaces immediately resolve to foreground with
`background_unavailable_reason=control_perform_requires_named_task_plan` (or
the batch equivalent). Foreground execution requires the target identity to
remain unchanged across the action boundary and returns that oracle in both
the report and evidence (`foreground_oracle=target_foreground_unchanged`,
`foreground_state=preserved`). `--background` is a shorthand for
`focus_policy=background`, but explicit background still fails closed: use an
approved `task.run` plan for named, process-directed background actions so the
target, authority, expiry, and unrelated foreground oracle are bound together.
A rejected background request is an
`action_unavailable`/`background_unsupported` handoff, not permission to
fall back to global input.

```sh
~/.local/bin/macctl control perform activate \
  --app "Notes" --confirm --focus-policy foreground \
  --role AXButton --title "New Note" --json
~/.local/bin/macctl control perform activate \
  --app "Notes" --confirm --background \
  --role AXButton --title "New Note" --json
```

The second request fails closed with `recommended_surface: task.run` and
`next_action: submit_named_background_task_plan`.

System Settings sidebar rows are a provider-specific boundary: native AX can
expose an `AXRow`/`AXOutlineRow` with `AXShowDefaultUI` or
`AXShowAlternateUI` and no `AXPress` or readable AX title. These are
presentation-only actions, not a verified click/selection route. Use the
stable locator returned by `accessibility audit`; `control perform activate`
returns `action_unavailable` with `recommended_provider: computer_use` and
`fresh_state_required: true`, so the agent can refresh state, relocate the
named row, click it through Computer Use, and verify the selected pane there.
Rows that actually expose `AXPress` still require the task-specific
`selected_pane` postcondition before reporting success.

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
Context-menu verification also requires one rendered `AXMenu` candidate with
positive geometry and at least one rendered `AXMenuItem`; zero-sized menu
templates and multiple rendered candidates remain unverified and report the
geometry/ambiguity evidence in the action postcondition.
When that postcondition is unavailable after the native action, the response
recommends `computer_use` with `fresh_state_required: true` and includes a
machine-readable `outcome.handoff_plan`. Execute its ordered
`get_app_state` -> unique fresh-target -> right-click -> fresh verification
steps, using the original request for selector values and expected labels.
`fallback_allowed: false` and `native_action_replay_allowed: false` mean the
agent must not blindly replay the AX action; the daemon makes the handoff
actionable for the caller without invoking Computer Use or persisting raw
selectors/menu labels.

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

For a matched agent-versus-provider comparison, the repository benchmark
runner accepts the named keyboard focus action and its explicit inverse. This
avoids assuming that plain Tab is the useful navigation primitive in every
native app:

```sh
python3 scripts/control_benchmark.py run-mac-focus \
  --app "Notes" --action next-item --reset-action previous-item \
  --task focus-next-notes-item-v1 --oracle "Accessibility focus changed to the next Notes item" \
  --warmups 1 --samples 3 --output benchmarks/results/notes-focus.jsonl \
  --comparison-id phase2-focus-notes-v1 --target-fingerprint notes-focus-v1 \
  --state-fingerprint notes-focus-ready-v1 --timing-scope agent_action_plus_verification \
  --focus-policy foreground --interaction-mode keyboard \
  --provenance daemon_executed --macctl ~/.local/bin/macctl
```

`run-mac-focus` makes foreground preservation part of the benchmark oracle. Every
prime, measured action, and inverse reset must include matching
`foregroundBefore`/`foregroundAfter` identities and `foregroundChanged: false`;
missing evidence is `foreground_state=unavailable`, and a changed foreground
stops the run. The summary keeps the foreground oracle and `focus_policy` in the
comparison key. `focus_policy=foreground` means the named target must be the
foreground target throughout the action; `focus_policy=background` means the
named target may be addressed without changing the unrelated foreground app.
Both policies still require independently verified `foreground_state=preserved`.
The `interaction_mode` is also part of the key (`keyboard`, `pointer`, `scroll`,
`drag`, or `mixed`), so a provider-natural pointer or visual action cannot be
silently paired with a keyboard-only Tab trial. Historical records without these
fields remain historical and are not upgraded retroactively.

For an externally timed lane, record the bounded foreground result explicitly:

```sh
python3 scripts/control_benchmark.py record \
  --task focus-next-notes-item-v1 --lane generic-gui --phase measured \
  --sample 1 --duration-ms 480 --tool-calls 5 --recoveries 0 \
  --status passed --oracle "Accessibility focus changed to the next Notes item" \
  --foreground-oracle foreground_unchanged --foreground-state preserved \
  --focus-policy foreground --interaction-mode keyboard \
  --verified --output benchmarks/results/manual-focus.jsonl \
  --comparison-id phase2-focus-notes-v1 --app "Notes" \
  --target-fingerprint notes-focus-v1 --state-fingerprint notes-focus-ready-v1 \
  --implementation-id direct-ui-scripting --build-id manual-20260810 \
  --timing-scope agent_action_plus_verification --provenance externally_timed
```

The Computer Use comparison lane must use the provider's natural action for the
task: pointer/visual targeting for pointer tasks, `sky.scroll` for scroll tasks,
and drag actions for drag tasks. A Tab/Shift-Tab run is valid only as a narrow
`interaction_mode=keyboard` keyboard-parity fixture; keep it separately labeled
and do not use it as the representative Computer Use result for the broader
Mac Control-versus-Computer-Use goal.

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
and persists no warm-path manifest when reset or measured scrolling is unverified. A failed or
ambiguous benchmark still records bounded task-specific route-health evidence against the supplied
task and target, when a matching profile or manifest already exists, so the next fast probe can
avoid replaying the failed route; it never creates benchmark metrics from an unverified sample.
The benchmark runner also preserves bounded daemon failure metadata such as the failure class,
fresh-state requirement, and recommended next action when a provider command exits non-zero;
raw command output and UI content remain excluded.

Safety, permission, target-uniqueness, freshness, and verification gates run
before speed ranking. Route policy is layered from a provider-neutral app
archetype, through a declarative bundle overlay, into a bounded current-session
cache. A measured route becomes warm only after at least three verified samples
for the matching app/version, OS version, provider state, task, target
fingerprint, and verification oracle. When present, a tree signature is part of
that context as well. The fastest eligible candidate wins by median action
latency, then p95 latency and recoveries. Unmeasured, stale, or context-mismatched
paths are unproven and require rebenchmarking. A stale element, failed action,
or failed verification immediately expires the selected route and clears its
lease cache entry. Visual and coordinate routes require explicit manifest
opt-in. Only a declared pre-action target-not-found failure may advance through
a fallback chain; possible side effects and failed verification stop the
action. Every response reports the selected route and fallback chain without
persisting selector values, AX values, private text, screenshots, OCR, or raw
key sequences.

`control capabilities` performs the small latency-sensitive probe and exposes
the resolved profile layers, provider preferences, stable anchors,
verification methods, invalidation triggers, app-published candidate
capabilities, and whether the cached route context is current. The separate
bounded capability audit remains the broad read-only discovery path. Browser
DOM, CDP, Computer Use, and app-advertised entries are routing declarations for
their owning providers; they do not turn Mac Control into those providers or
bypass their verification boundaries.

Callers must declare `--target-surface web-content` when the intended target is
inside a rendered page rather than browser chrome. The probe then reports
`providerHandoffRequired`, the preferred `browser_dom`/`cdp_dom` provider, and
`nextAction=submit_browser_target_plan`. Supplying the same surface to
`control perform` or `control batch` fails closed with
`provider_handoff_required` before browser activation. Mac Control cannot
assert connector health, tab identity, or DOM verification; the receiving
browser provider must refresh and verify those facts.
The CLI resolves this branch locally, so a pre-v5 daemon cannot silently ignore
the new field and route the request through foreground Mac control.
When a current daemon is available, the same local branch opens an owner-only
joined trace without sending the native mutation to the daemon. The handoff
returns the trace context needed for browser execution; after DOM readback, the
orchestrator submits one bounded completion observation. Identical completion
retries are idempotent, mismatched replays fail closed, and expired credentials
cannot complete the trace.
At this boundary the common `Chrome` CLI alias resolves to the installed
`Google Chrome` application identity; browser-provider tab and DOM identity
still require fresh verification by the receiving provider.

App overlays may declare an `advertisedCapabilities` list backed by a public
in-app accessibility, menu, or help disclosure. Discord currently declares
Tab/arrow keyboard navigation, Command-/ for its shortcut catalog, and
Command-K for Quick Switcher from its accessibility onboarding. The fast probe
reports these declarations as `candidate_only`; it never dispatches them or
adds them to `freshMeasuredRoutes`.

The deep audit also discovers general `capabilityLeads` without requiring an
app overlay. It recognizes structured keyboard-navigation, shortcut-catalog,
quick-switcher, command-palette, and keyboard-search disclosures only on
app-owned menus, controls, dialogs, help, onboarding, or accessibility surfaces.
It understands nearby split keycaps such as separate `⌘` and `K` AX nodes,
reconciles a generic lead with a matching bundle declaration when available,
and caches only the normalized shortcut, signal categories, confidence,
verification requirements, and hashed locator identities. Raw disclosure text
is never persisted. Conflicting shortcuts remain ambiguous, ordinary content
text is ignored, and every lead starts as a candidate. A matching fresh
task-specific verification can promote or demote the lead in the broad profile,
but route eligibility still requires independent measured-route evidence.
Missing transient UI is absence of evidence rather than negative evidence.

Use `route register` only for explicitly caller-supplied external metadata; it
is not equivalent to the daemon-executed benchmark.

Agents can inspect the route contract before acting and batch verified navigation
within one foreground app:

```sh
~/.local/bin/macctl control capabilities --app "Chrome" \
  --task focus-next --target-fingerprint focus-v1 --json
~/.local/bin/macctl control capabilities --app "Chrome" \
  --target-surface web-content --json
~/.local/bin/macctl control capability-audit --app "Chrome" \
  --max-nodes 500 --max-depth 8 --json
~/.local/bin/macctl control capability-audit-batch --all-applicable --json
printf '%s\n' '[{"action":"next-control"},{"action":"next-control"}]' | \
  ~/.local/bin/macctl control batch --app "Chrome" --actions-stdin --confirm --json
```

The fast capability probe reports app archetype plus fresh measured, stale, and
caller-supplied route inventory and may read a cached broad profile without
walking AX. It also reports a bounded `recentBlockers` list aggregated from
owner-only receipts for the matching app version and, when supplied, the exact
task and target fingerprint. These observations are advisory: an agent should
use the explicit `isFresh`/`freshUntil` fields, refresh stale evidence, refine
an ambiguous locator using stable structural fields, then require normal action
verification before the resolved route can be promoted. The separate
`capability-audit` command performs one bounded,
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
A fresh locator's `identityDigest` can be passed back through
`control perform --locator-digest <digest>` (optionally combined with role,
subrole, identifier, window scope, and the locator's redacted
`ancestorDigest` and optional `geometryDigest`). The ancestor digest
disambiguates repeated local descriptors inside one window, while the geometry
digest is a redacted digest of the element bounds; raw coordinates, visible
ancestor text, and AX element references are never persisted. The daemon
recomputes the complete redacted descriptor, ancestor chain, and geometry from
the live AX tree and fails closed unless exactly one current element matches,
closing the audit-to-action handoff. If duplicate scroll locators remain after
these discriminators, the broad semantic-scroll capability stays a candidate
until task-specific evidence resolves the ambiguity. A role-only
`AXScrollArea` that exposes no directional AX scroll action is also kept as a
candidate; an incidental `AXScrollToVisible` action on a descendant does not
promote semantic scrolling.

When a normal fast probe observes an already-running native app whose broad
profile is missing or stale, it may schedule that same bounded read-only audit
on a serial utility queue after the response path. `auditOpportunity` reports
`scheduled`, `in_progress`, `satisfied`, `not_observed`, or `not_applicable`.
This opportunity never launches an app, activates it, dispatches input, handles
`web_content`, or turns audit evidence into action authority. Duplicate work for
the same app/version/provider context is coalesced, and a later normal probe may
retry if the app closes before observation.
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

For a development process that may not be registered as a normal application,
bind the exact PID before attempting window or tree inspection:

```sh
~/.local/bin/macctl app bind --app "ExampleDev" --process-id 12345 --json
```

The supplied expected identity (bundle ID, name, or exact path) and PID remain
conjunctive. A successful
`macctl-pid-accessibility-binding/v1` response means the exact process exposes
an addressable `AXApplication` root; it does not grant mutation authority. If
the process exists but the AX root is unavailable, Mac Control reports
`classification: blocked_unsupported` and distinguishes
`development_binary_not_registered_as_accessibility_application` from
`accessibility_permission_missing`. Installed app control remains supported.

The durable fallback is to build a real `.app` bundle with an Info.plist and
normal application activation policy, then launch that exact development
bundle through the existing app route and bind its PID:

```sh
~/.local/bin/macctl app open "/absolute/path/to/ExampleDev.app" --json
~/.local/bin/macctl app instances --app "/absolute/path/to/ExampleDev.app" --json
~/.local/bin/macctl app bind --app "/absolute/path/to/ExampleDev.app" \
  --process-id 12345 --json
```

`app open` accepts an explicit existing `.app` path for this fallback; it does
not wrap, register, or reinterpret a bare executable as an application.

When more than one GUI process has the same app identity, discover the live
instances and bind inspection to one process before reading its windows or
Accessibility tree:

```sh
~/.local/bin/macctl app instances --app "Code" --json
~/.local/bin/macctl window list --app "Code" \
  --process-id 12345 --instance-ref "$INSTANCE_REF" --json
~/.local/bin/macctl accessibility tree --app "Code" \
  --process-id 12345 --instance-ref "$INSTANCE_REF" \
  --window-ref "$WINDOW_REF" --json
```

`process_id`, `instance_ref`, and `window_ref` are conjunctive. A missing,
restarted, reused, or ambiguous target fails closed and never redirects to
another process or its focused window. Discovery is read-only: it does not
activate, raise, close, move, or otherwise mutate any window. Window references
are opaque, title-free Accessibility identity digests; refresh the catalog if a
window changes identity.

### Exact zero-focus action intents

For one safe semantic button press in a non-frontmost native window, use the
agent action front door. It is deliberately separate from app-level
`control perform` and from foreground keyboard tasks:

```sh
~/.local/bin/macctl action resolve --intent-stdin --json <<'JSON'
{
  "schema_version": 1,
  "action": "press",
  "focus_policy": "background",
  "foreground_budget": 0,
  "risk": "safe",
  "verification_timeout": 1,
  "target": {
    "application": "com.example.fixture",
    "process_id": 12345,
    "instance_ref": "INSTANCE_REF",
    "window_ref": "WINDOW_REF",
    "selector": {"role": "AXButton", "identifier": "run-action"}
  },
  "desired_state": {
    "selector": {
      "role": "AXStaticText",
      "identifier": "action-status",
      "contains_text": "Completed"
    },
    "exists": true
  }
}
JSON
~/.local/bin/macctl action run action_RESOLUTION_ID --json
```

Resolve reads fresh process, window, control, foreground, and desired-state
identity, then returns an opaque one-shot resolution that expires within 30
seconds. Run consumes it before dispatch, re-resolves the same exact target,
performs one window-scoped `AXPress`, and reports success only when fresh
Accessibility readback observes the desired state and the unrelated foreground
PID has not changed. The surface supports no activation, key or pointer input,
arbitrary AX action, sensitive/destructive risk, persistent AX handle, replay,
or broader fallback. Duplicate controls, stale or missing identity, PID reuse,
window events, focus theft, and unverifiable state all fail closed.
An AX server can return a non-success status after accepting a press. Mac Control
never retries that indeterminate dispatch: it reports
`indeterminate_but_verified` only when the declared desired state is observed;
otherwise the consumed resolution ends as `dispatch_indeterminate`.

App-level activation and AX window raising still do not independently prove
foreground input ownership, so `control perform` remains unsupported for an
exact target. Use the action front door only for its narrow background press
contract.

Exact keyboard mutation is a separate approved foreground `task.run` key step.
Its target must include all three conjunctive fields: `process_id`, the
launch-bound `instance_ref`, and the opaque `window_ref`. The daemon re-resolves
the instance, acquires the exclusive task keyboard lease, requests activation
through the exact `NSRunningApplication` PID, and raises only AX objects created
for that PID. Neither activation mechanism is treated as proof. Input remains blocked until both
NSWorkspace reports that exact PID as frontmost and AX reports the requested
window digest as that process's focused window. The step must be `sensitive`,
use strict single-attempt recovery, and declare an exact-window
`element_exists` postcondition. It receives the distinct `exact_foreground`
input route. Missing or changed identity blocks before input; any detected race
after input is indeterminate and is never retried. Click, type, scroll, adapter,
background, and application-level fallbacks are not permitted.
Postcondition observation reuses the lease-bound application PID and resolves
the selector only inside the bound `window_ref`; it never re-resolves the app
name or widens to another process or window. `element_exists` is existential:
one or more matching descendants inside that unique window pass. Ambiguous
window identity, disappearance, or a bounded search that ends without finding
a match still fail closed. Mutation selectors continue to require uniqueness.
The read-only postcondition oracle polls within the declared step timeout so
asynchronously published Accessibility state can settle. Polling never
redispatches the action, and every observation retains the exact instance,
window, foreground, and lease checks.

For same-product acceptance tests, create a task-owned VS Code fixture with a
different bundle identity instead of targeting an existing `Code` process:

```sh
FIXTURE_ROOT=/private/tmp/macctl-vscode-fixture-quality-lens-c1
python3 scripts/vscode_fixture.py build \
  --root "$FIXTURE_ROOT" --fixture-id quality-lens-c1
python3 scripts/vscode_fixture.py launch \
  --root "$FIXTURE_ROOT" \
  --workspace "$PWD/Tests/Fixtures/VSCodeProblemsWorkspace" \
  --extension "$PWD/Tests/Fixtures/VSCodeProblemsExtension"
python3 scripts/vscode_fixture.py status --root "$FIXTURE_ROOT"
```

The builder requires one valid local code-signing identity by default and rewrites
only the copied outer bundle identifier. It preserves the source product name
because Electron uses `CFBundleName` to locate its unchanged helper-app names;
the fixture app filename and bundle identifier provide the unique identity. It
then signs the copied Electron closure
inside-out, including Mach-O libraries below framework `Libraries` directories
that deprecated `codesign --deep` discovery can miss. Before launch it verifies
every copied code object and requires one Team ID across the closure, preventing
a Hardened Runtime abort from a source-signed library such as `libffmpeg.dylib`.
The legacy `--repair-invalid-nested-signatures` option remains accepted but is no
longer required; closure repair is unconditional and never changes the source app.
Cross-filesystem copies require `--allow-full-copy` so a large storage expansion
is never implicit. `--ad-hoc-sign` is a local probe, not equivalent release
evidence.

If a stopped, marker-owned fixture was created by the older deep-signing path,
repair it in place with the same signing identity before relaunching:

```sh
python3 scripts/vscode_fixture.py repair-signatures --root "$FIXTURE_ROOT"
```

Repair fails closed if the fixture is running, an unrecorded fixture process
exists, or the resolved signing identity differs from the marker-bound original.

The first launch of a modified, non-notarized fixture may stop at macOS code
evaluation. `status` reports `awaiting_manual_approval_or_startup` while that
launch is live, or `stopped_before_ready` with
`next_action=relaunch_and_review_native_approval` if it exits first. No exact
input is allowed in either state. The user must review and approve the native
first-open dialog themselves; an agent must never click it, weaken Gatekeeper,
or redirect to an existing Code window. Continue only after `status` reports
`ready`, then discover the unique bundle ID with `app instances`, bind its PID,
`instance_ref`, and `window_ref`, and use the normal exact foreground
`task.run` contract. Stop and remove only the marked fixture when finished:

```sh
python3 scripts/vscode_fixture.py stop --root "$FIXTURE_ROOT"
python3 scripts/vscode_fixture.py clean --root "$FIXTURE_ROOT"
```

### Mac Control ideal-state audits

Repositories that expose a supported Mac Control task surface can own a
versioned `.mac-control/ideal-state.json` manifest. The current
`mac-control-task-manifest/v4` contract describes task surfaces without choosing
a winner and rejects self-attested `criteria` booleans. Each task declares its
`surface_kind`, stable target identity, focus policy, semantic action,
independent verification oracle, task-specific state requirements and
exemptions, provider/method/interaction-mode route candidates, and typed
`semantic_evidence` for all eight dimensions. Every dimension references
repository-relative source anchors and evidence tokens; Quality Runner resolves
those references only in implementation files and requires the tokens near one
unique anchor before deriving the score. Docs, tests, fixtures, snapshots, and
symlinks cannot score. The Mac Control validator checks the claim shape,
cross-field consistency, source-reference eligibility, and provider boundaries
without claiming that source or a running app has been observed.

Native app UI must expose a native semantic candidate, web content must hand
off to a browser connector, and hybrid transitions must declare both sides.
Accessibility candidates need stable identifiers; visual, pointer, and drag
candidates need explicit fresh-state handoff. The contract also requires every
task to account for shortcut acceleration as `built_in_verified`,
`customizable_verified`, or `not_applicable` with a reason. A usable shortcut
names a stable command, exposes contextual availability, and carries conflict
handling; macOS App Shortcut surfaces additionally preserve the exact menu path
and reversible assignment. V1 through v3 remain readable declaration-only
migration formats and cannot earn semantic implementation points.
Validate the manifest without touching a running app:

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
normal approval-gated `task.*` or route receipts. A v2, v3, or v4 repository manifest must
not contain `selected_route`; Quality Runner adds it only from live task
evidence. Human accessibility metadata, agent task operability, and runtime
performance remain distinct evidence even while the v1 report envelope carries
them together. Quality Runner consumes redacted
measurements as `mac-control-task-evidence/v1` sidecars and keeps the static,
live structural, and task-execution evidence distinct.

When a target lives inside a readable scroll container, use semantic scrolling
with a unique `AXScrollArea` selector. An identifier is preferred, but optional
when role-only resolution returns exactly one container. If repeated scroll
containers share the same local descriptor, pass both the audit's
`identityDigest` and `ancestorDigest`; when the audit reports repeated
structural matches, also pass its redacted `geometryDigest`. Mac Control
verifies that the selected container can still be resolved after the action:

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

## Native window placement

Mac Control includes a Rectangle-independent native baseline for placing the
focused window on an explicitly selected display. List live Core Graphics
display IDs and the named layouts before mutating anything:

```sh
~/.local/bin/macctl window displays --json
~/.local/bin/macctl window list --app "TextEdit" --json
~/.local/bin/macctl window inspect --app "TextEdit" --json
~/.local/bin/macctl window place --app "TextEdit" --window focused \
  --display-id 42 --layout right-half --confirm --json
~/.local/bin/macctl window restore --restore-token "$RESTORE_TOKEN" --confirm --json
```

Layouts are `maximize`, `center`, horizontal and vertical halves, horizontal
thirds and two-thirds, and four quarters. Coordinates are not accepted from
the caller. The daemon activates the named app, binds the currently focused
window by a redacted Accessibility identity digest, resolves the display again,
dispatches position and size once, then reads the exact window frame and
destination display back. A missing display, ambiguous window identity,
unsupported/full-screen window, focus/process change, or unavailable readback
fails closed without replay.

Successful placement returns a five-minute, single-use restore token bound to
the same process, window identity, original frame, and original display. Restore
fails rather than redirecting if the process has relaunched or the original
display disconnected. Rectangle, Loop, and other window managers are not
required and are not invoked by this surface.

## Checkpointed task control

For multi-step work, use `task.*` with a structured plan. A task plan names
typed actions, target identity, preconditions, postconditions, risk,
approval reason, timeout, and its declared recovery policy. It is not free-form
task text and it cannot invoke arbitrary shell commands or AppleScript/JXA:

The bounded showcase composer previews the exact synthetic research-session
target without claiming that its effects are executable. It returns the same
ordered targets, effects, rollback notes, verification requirements, and
approval digest for the same supported request, connected display ID, and
named layout. List the current display IDs and allowlisted layouts first:

```sh
~/.local/bin/macctl task displays --json
```

Display IDs are explicit plan-bound targets; screen order and `NSScreen.main`
are not selectors. A display that disconnects before arrangement blocks that
step instead of falling back to another screen. `balanced` gives both windows
equal width, while `brief-primary` gives the brief sixty percent of the usable
width. The same display can therefore carry independent named plans:

```sh
~/.local/bin/macctl task compose focus-session \
  --display-id 42 --layout balanced \
  --request "Prepare my research session" --json
```

The preview reports `executable=false` and names its remaining implementation
gaps because it is a claim-bound concept surface, not installed proof. The
source build can also emit the exact executable candidate for inspection:

```sh
~/.local/bin/macctl task compose focus-session \
  --display-id 42 --layout balanced \
  --request "Prepare my research session" --plan --json
```

That candidate uses three product-owned allowlisted operations. They accept no
caller-provided path, content, application, script, or frame. Each step is
strict and passes only after an independent post-dispatch check confirms the
fixture document in its expected app or reads both window frames back. A live
`AXDocument` URL is authoritative; when an app omits it, the observer requires
exact in-memory digest equality with the product-owned public fixture filename,
in addition to the fixture-content digest and visible focused window. Treat
the candidate as source-only until the exact packaged daemon passes the live
positive, partial-failure, and stale-state paths.

The source verification contract produces one plan-bound record for the brief,
one for the scratchpad, and one for the two-window layout. It accepts only
post-dispatch fixture and Accessibility observations; action return values are
not a verification source. Receipts retain bundle IDs, fixture/window digests,
and bounded frames, never document contents, visible titles, or file paths.
Because app-open completion can precede Accessibility window publication, the
observer polls that read-only postcondition for at most two seconds; it never
redispatches the open operation during that wait.
Verification and layout resolve the unique matching fixture across every
visible window in the expected app, so repeated demos do not depend on which
window happens to be focused. The layout observer separately resolves the
approved display ID from the live connected set and verifies the approved
layout name, so display enumeration changes cannot redirect the arrangement.

```sh
cat plan.json | ~/.local/bin/macctl task prepare --plan-stdin --json
~/.local/bin/macctl approval approve "$TASK_APPROVAL_TOKEN" --json
cat plan.json | ~/.local/bin/macctl task run --plan-stdin \
  --approval-token "$TASK_APPROVAL_TOKEN" --json
~/.local/bin/macctl task status "$TASK_ID" --json
~/.local/bin/macctl task cancel "$TASK_ID" --json
```

`task.prepare` returns an approval bound to the exact serialized plan,
target, risk, recovery policy, and ephemeral-input digest. Any plan or
ephemeral-input change invalidates it. The daemon automatically grants approved
foreground work a session-scoped execution lease bounded by the task deadline
and the 300-second maximum. `--lease-token` remains an exact-mode compatibility
override and cannot upgrade shared authority into physical-keyboard suppression.
A `focus_policy: "automatic"` task is checked against the same background
validator immediately before dispatch. If eligible and addressable it receives
the background input channel; otherwise it immediately takes the existing
foreground path and reports the reason. An explicit
`focus_policy: "background"` task may receive an in-memory input channel without a keyboard lease
when all input targets name one running application that is not currently in
the foreground. The channel is bound to the exact task, plan digest, process,
and expiry. Accessibility-addressed click/type, replace-only search with AXValue
readback, verified
semantic `AXScrollArea` scroll, explicitly `background_safe` typed adapter
operations, and process-directed key routes are supported. Search text still
comes from ephemeral input; background scroll is successful only when bounded
Accessibility state changes; and an adapter defaults to `foreground_only`
until its operation manifest explicitly opts in. Full Keyboard Access,
activation, global pointer input, arbitrary commands, ambiguous targets, and
visual/coordinate input remain foreground-only. A target-process or unrelated
foreground change blocks dispatch. This is a logical task authority, not a
system-wide virtual HID device, and it does not create multiple macOS first
responders or make task execution parallel. Private text is supplied through
owner-only stdin and is used in memory only.

An exact process/window key step is a narrow foreground task route. Put
`process_id`, `instance_ref`, and `window_ref` in every input
step's `target`; do not mix exact and application-level inputs. Exact plans
support key actions only, require `risk: "sensitive"`, a non-empty
`approval_reason`, `recovery: {"mode":"strict","max_attempts":1}`, and at
least one Accessibility-addressed `element_exists` postcondition. The returned
input channel reports `exact_foreground` plus the bound opaque references.

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
The service preflight validates that approval against the remaining plan while
the runner separately verifies the original full-plan digest and current
checkpoint index. `task.run` is only for a newly prepared task and must not be
used to continue a partial checkpoint.
An `expired` checkpoint is terminal because its plan-wide deadline has elapsed;
start a versioned new task identity rather than resetting that deadline.
No fallback route is invented after an action may already have caused an
external side effect. `task.status` and `task.cancel` remain available without
input authority; cancellation is cooperative and is checked before each
action and at bounded action checkpoints.

### Allowlisted application adapters

`macctl adapter capabilities --json` reports the typed adapter manifests,
routes, read/mutating behavior, required permissions, risk, redacted
observation schema, `focusSupport`, and Automation diagnostics. Operations are
`foreground_only` by default. The initial background-safe allowlist is limited
to the Accessibility-based `inspect.front-window` and `locate.named-object`
operations; every other operation remains foreground-only until independently
verified and explicitly declared. The initial app allowlist covers
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

The safety item does not expose this pending plan. While the legacy backend remains, its state
can be exercised only through the explicit CLI. For expiry, leave an approval untouched until
its 300-second token expires, then run `macctl approval approve <token>` and confirm the result
is `approval_expired`. Finally run
`~/.local/bin/macctl workflow run approval.smoke --json` without a token; it
must be blocked. Caps Lock no longer opens Mac Control UI.

The project does not modify AIOS or career-ops. Career Ops can invoke this
standalone control plane when a local macOS interaction is required.
