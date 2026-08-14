# Commands and quality gates

Run SwiftPM gates serially from a clean checkout or runtime-owned disposable
worktree:

```sh
swift build
swift test
swift test --enable-code-coverage
python3 -m unittest discover -s Tests/BenchmarkTests
python3 -m unittest discover -s Tests/SkillTests
python3 scripts/check_environment_contract.py
./scripts/test-with-coverage.sh
```

`swift build` is the compile/typecheck gate. `swift test` is the behavioral
gate. The Python suites cover benchmark accounting and the distributable Mac
Control skill contract, including its canonical install and Codex projection.
The coverage-enabled test command produces the Swift profile; the coverage
script additionally exports `coverage/lcov.info`. The environment checker
validates this contract, all routed packets, and the skill's routing and
metadata invariants. There is no
repository formatter/linter dependency; do not claim lint coverage that has
not been installed and executed.

`.github/workflows/ci.yml` runs the same source gates on GitHub's `macos-15`
runner with a SHA-pinned checkout action. CI is deliberately source-only: TCC
permissions, installed LaunchAgent identity, owner-session GUI behavior, and
fresh release receipts remain local owner-controlled gates and must not be
inferred from a green workflow.

Lifecycle mutation commands are interlocked with the live daemon. A healthy
daemon must grant an atomic drain before `macctl install` or `macctl daemon
install|restart|remove` changes state; pending or approved authority, active
execution, and in-flight mutation block the drain. The explicit
`--allow-legacy-idle-snapshot` option is only for the first upgrade from a
pre-interlock daemon after owner-visible idle verification.

Before any Mac Control assessment, use the zero-probe local ledger:
`swift run macctl control limitations --json`. It reports the versioned
`do_not_call`, `handoff_only`, and `call_with_constraints` boundaries without
contacting the daemon, inspecting an app, or walking Accessibility. It is
routing guidance, not execution authority. Only after the ledger permits Mac
Control should an agent run the app/task-specific capability probe.

For read-only runtime diagnostics, use the built CLI only after the package
build: `swift run macctl doctor --json`, `capabilities --json`, `status
--json`, `receipts status --json`, and `release check --json`. Release checks
must not manufacture live evidence or run workflows as a side effect.

For a sensitive-request explanation, use the daemon-only authorization surface:
`control authorization prepare`, `bind`, `list`, and `resolve`. Prepare accepts only
bounded project/task/thread/helper/target/action/summary metadata and an allowlisted
`codex://` source reference; it must not be given raw command text, arguments, prompts,
passwords, tokens, private input, or environment values. `resolve` records completion only.
Inspect authorization notices with `control authorization list --json`; the transient safety
item does not present them. No authorization-notice command approves or denies the native macOS
dialog. General user attention belongs to the independent attention provider.

An owner-local sibling provider can submit a bounded sensitive-plan decision through the daemon
methods `approval.external.prepare`, `approval.external.status`, and
`approval.external.consume`. Prepare accepts only provider identity, provider instance, plan ID,
an exact SHA-256 plan digest, a bounded summary, and risk. The provider receives an operation ID
and decision state, never the private approval token. Review pending decisions with
`macctl approval list`, then use `macctl approval approve <token>` or
`macctl approval deny <token>` through the normal owner-only CLI. Consume must repeat the exact
provider-instance, plan, and digest binding; denial, expiry, mismatch, and replay are terminal.
The transient safety item does not present this queue.

Keyboard diagnostics and control use the daemon-authoritative surface:
`swift run macctl keyboard status --json`, `keyboard setup --json`,
`keyboard enable --confirm --json`, `keyboard inspect --json`, and the
short-lived `keyboard lease acquire|release`, `keyboard navigate`, and
`keyboard send` commands. The input commands require a confirmed lease token;
do not substitute them for the approval-gated workflow `key` or `type` path.
`keyboard lease acquire --scope session --suppress-physical-keyboard` is an
optional interactive mode that requires Accessibility and Input Monitoring;
it also requires `--reason` and explicit confirmation, and must not be used for
app-scoped or unattended workflows. Prefer the separate
`keyboard freeze acquire|status|release` commands when the freeze permission
itself is the requested capability.

Verified semantic control uses the same lease and can inspect or route a
visible action: `swift run macctl control status --json` and
`swift run macctl control perform activate --lease-token <token> --title
<title> --json`. For a task-specific route, use `route benchmark`,
`route inspect`, and `route list`; `route benchmark` executes and verifies the
bounded action samples in the daemon before persistence. Selection requires at
least three verified samples and a fresh context-bound app/task manifest, then
reports the route and declared fallback chain. Capability policy resolves from
declarative archetype and app-overlay profiles before consulting the bounded
session cache. Use `route register` only for explicitly caller-supplied metadata.
Repository ideal-state manifests use `mac-control-task-manifest/v4` to declare
task surfaces and route candidates, never a selected route or self-scoring
criteria. Each task declares its surface kind plus typed semantic evidence for
all eight dimensions. The Mac Control validator enforces the claim shape and
provider boundaries; Quality Runner resolves repository-relative anchors and
evidence tokens before deriving a score. V1 through v3 remain readable
declaration-only formats and score `0/8`. Tasks account only for applicable
states and give reasons for exemptions; target identity, focus policy,
provider/method/interaction mode, and verification oracle remain separate. Each
task also accounts for a verified built-in shortcut, a verified customization
surface, or an explained exemption. An assigned shortcut is a candidate until
the normal independent task oracle and route benchmark pass. Runtime route selection and
latency evidence belong to Mac Control and Quality Runner, not repository
remediation.
`control perform` accepts `--focus-policy automatic|foreground|background` (or
the `--background` shorthand). The CLI sends `automatic` by default. Direct
control resolves it to foreground immediately because only a named task binds
background authority; the daemon reports both requested and effective policy
plus the selection reason. Successful foreground actions include the boundary oracle
`foreground_oracle=target_foreground_unchanged` and
`foreground_state=preserved`. Direct `control.perform` and `control.batch`
remain foreground-bound; an explicit background request fails closed with
`background_unsupported`, `failure_class=action_unavailable`,
`recommended_surface=task.run`, and a named-task next action. Background
execution belongs to an approved task plan so process-directed authority and
unrelated foreground preservation are checked together.
Use `--target-surface web-content` on `control capabilities`, `control perform`,
or `control batch` for rendered page content. Capabilities return the preferred
browser provider; execution returns `provider_handoff_required` with
`recommended_surface=browser_connector` and
`next_action=submit_browser_target_plan` before activation. Omit it, or use
`mac-app-ui`, only for browser chrome or native controls.
The CLI resolves web-content capability and handoff responses locally rather
than sending them to a daemon that may predate this field.
With a current daemon, an execution handoff also returns `result.trace` with a
short-lived completion credential and trace/span IDs. Pass the exact DOM plan
to the external browser provider, require its normal postcondition readback,
then pipe one allowlisted JSON object to the `receipts trace-complete` command
with `--stdin --json`. Required keys are `trace_id`, `completion_token`, `provider`,
`provider_observation_id`, `status`, and `verification_kind`; optional keys are
`foreground_state`, `provider_session_id`, `provider_turn_id`, and
`provider_tab_id`. Do not include URL, title, DOM, page text, selectors, or
credentials. The CLI accepts no trailing arguments and rejects completion stdin
larger than 8 KiB. Inspect the aggregate with the
`receipts trace <trace-id> --json` command. An identical completion retry is
idempotent; a changed observation, status, verification kind, provider identity,
foreground result, or expired token fails closed.
For this provider-boundary probe, `--app Chrome` is normalized to the installed
`Google Chrome` application identity; no alias changes native browser-chrome routing.
System Settings sidebar rows may expose `AXShowDefaultUI` or
`AXShowAlternateUI` on an `AXRow`/`AXOutlineRow` instead of `AXPress`, with no
readable AX title. Those actions are presentation-only, not a verified
activation route. Resolve the row through a bounded `accessibility audit`
locator; `control perform activate` must fail closed with an explicit
`action_unavailable`/`computer_use` handoff and `fresh_state_required: true`.
Rows that expose `AXPress` must still return a verified `selected_pane`
postcondition.
Native `context-menu` verification requires one rendered `AXMenu` candidate with
positive geometry and at least one rendered `AXMenuItem`; zero-sized AX menu
templates and multiple rendered candidates fail closed with
`verification_unavailable` and redacted geometry/ambiguity evidence.
That failure exposes `recommended_provider=computer_use`,
`fresh_state_required=true`, and a fresh-state handoff next action while keeping
`fallback_allowed=false`; do not blindly replay an AX context-menu action that
may already have been dispatched.
Selector metadata
describes addressability but does not create a universal route ladder.
For paired agent benchmarks, `scripts/control_benchmark.py run-mac-focus` also
requires foreground-preservation evidence for every action and inverse reset;
manual lanes must supply the same `foreground_oracle`, `focus_policy`, and
`interaction_mode`, plus an independently verified `foreground_state=preserved`,
before comparison ranking. Use `focus_policy=foreground` when the target must
be frontmost; use `background` only for a named-target fixture whose unrelated
foreground identity is independently preserved. For the broader Computer Use
comparison, use provider-natural pointer/visual, scroll, or drag actions. Keep
Tab/Shift-Tab results as separately labeled `interaction_mode=keyboard` evidence,
not as the representative Computer Use lane.
`control perform scroll --app <app> --role AXScrollArea --identifier <id>
--direction up|down|left|right --amount <n> --confirm --json` is the semantic
scroll path. `accessibility tree` and `accessibility audit` are bounded,
redacted diagnostics; their AX values, private text, screenshots, and OCR are
excluded from responses persisted as receipts. When extending a paired scroll
fixture with `scripts/control_benchmark.py run-mac-scroll`, the runner reads
`control status --json` before and after every action and inverse reset outside
the timed interval. For `focus_policy=foreground`, both snapshots must identify
the named target and remain unchanged; missing target identity, missing status,
or changed identity evidence is unavailable/failed and cannot be ranked. It
stores only `foreground_oracle=foreground_unchanged` and the redacted
`foreground_state` for compatibility with existing fixtures.

Agent-facing control discovery and batching are available through:
`control capabilities --app <app> [--target-surface mac-app-ui|web-content] [--task <id> --target-fingerprint <fingerprint>]`,
`control capability-audit-batch --all-applicable [--run-id <id>] [--max-apps <n>]`,
and `control batch --app <app> --actions-stdin --confirm`. Capability output
classifies the app descriptively and distinguishes fresh daemon-executed routes
from stale or caller-supplied inventory; it does not infer provider parity.
The batch audit is a separate bounded, read-only inventory: it selects at most
24 installed user-facing apps, audits only already-running apps, serializes AX
access, persists one redacted receipt per app, and resumes not-observed or failed
entries by run ID without launching apps or dispatching actions.
The normal fast capability probe may opportunistically schedule one coalesced
bounded audit for an already-running native app when its cached broad profile is
missing or stale. The response remains a fast probe and reports the scheduling
state in `auditOpportunity`; the queued work never launches, activates, or acts
on an app, and never handles `web_content`.
If a recursive deep audit reaches its fixed ceiling, the daemon may use a
bounded window-aware/page traversal of up to 8 windows, 256 pages, and 16,000
total nodes; only complete coverage can promote a profile.
Batching owns one bounded app lease, revalidates every step, stops on the first
unverified action, and releases the lease on every exit path. Semantic scroll
remains an explicit `control perform` action so a Computer Use handoff is visible.
Control responses expose provider-neutral outcome states, including target,
action, verification, foreground-race, and provider-handoff results. When
`recommended_provider` is `computer_use`, the agent must get fresh app state,
locate a fresh target, perform the provider-natural action, and verify the changed
state through Computer Use. Context-menu verification failures additionally expose
`outcome.handoff_plan`; execute its ordered state/target/action/readback steps, do
not replay the native AX action, and use the original request only as ephemeral
selector and expected-label input. The persisted plan contains redacted identity
fields and digests, not raw selectors, labels, or AX references.
The menu-bar item does not announce one-shot focus changes. For a run that spans native actions
or a provider handoff, the caller must explicitly start `control hands-off begin --confirm`, pass its opaque
`session_id` to each `control perform`/`control batch` request, heartbeat before
the returned interval, and call `control hands-off end` on completion. While that
bounded session is active, the transient safety item and popover tell the user
to keep the keyboard and trackpad untouched. Expiry, `control.stop_active`, and
daemon shutdown clear it; no session is inferred from a one-shot action. `Frozen`
remains the stronger visual state when physical keyboard suppression is active.
Active checkpointed task runs project their durable checkpoint into the safety popover as redacted
`Pending`, `Running`, `Verified`, and `Stopped` rows. The projection uses plan step IDs only and
does not expose targets, selectors, inputs, or output. It disappears when input authority is
released; use CLI status and receipts for completed history. Use the stable `macctl.task.progress`,
`macctl.task.progress.count`, and `macctl.task.progress.<step-id>` Accessibility identifiers for
direct native-surface verification.

Native window placement uses `window displays --json`, `window inspect --app
<app> --json`, `window place --app <app> --window focused --display-id <id>
--layout <name> --confirm --json`, and `window restore --restore-token <token>
--confirm --json`. The daemon owns mutation and readback. Callers may select
only an explicit live display ID and an allowlisted named layout; arbitrary
frames, display array indexes, and `NSScreen.main` are not selectors. Placement
is foreground-only, resolves the focused window to a redacted identity digest,
dispatches once, and requires frame plus display readback. Restore tokens are
five-minute, single-use, and process/window/original-display bound. A missing
display or changed process blocks rather than redirecting or replaying.

Use `task displays --json` to list the currently connected display IDs and the
allowlisted `balanced` and `brief-primary` layouts. `task compose focus-session` requires
`--display-id <id> --layout <name>` and is a preview-only showcase surface. Its ordered effects open a
bounded brief, open a bounded scratchpad, and arrange their Preview and TextEdit windows on the
explicitly targeted display. Display array order and `NSScreen.main` are not selectors; a missing
display blocks arrangement without falling back to another panel. The
source verification contract accepts post-dispatch fixture digests and Accessibility window
observations tied to the exact plan digest; it never accepts dispatch results as proof or retains
visible titles, paths, or document contents. Keep the preview non-executable until the live action
routes and observers close MC-2 and MC-3.

Use `task compose focus-session --plan --json` to inspect the executable candidate behind that
preview. Its three product-owned adapter operations accept no request-controlled path, content,
application, script, or frame. The layout operation accepts only the approved numeric display ID
and an allowlisted layout name. Every step has a strict `focus_session_verified` postcondition;
the open steps compare the fixture digest plus either the live AX document URL or, only when that
attribute is absent, an exact in-memory digest of the product-owned public fixture filename; the
layout step reads both window frames back. Raw titles and paths are not retained. Source
availability is not installed proof.
The open-step observer may wait up to two seconds for Accessibility publication, but it must not
redispatch the open operation while polling; the three-action task budget remains one dispatch
per declared effect.
Resolve the unique public fixture across all visible windows in its expected app for both
verification and layout; do not substitute the currently focused window. Resolve the layout
display by ID again immediately before frame mutation and verification; reordered display lists
must not change the target, and a disconnected target is `blocked`.

The Tier-1 gate is defined in `docs/TIER1_RELEASE.md`. Missing live evidence
is a recorded `blocked` result, not permission to weaken a check.

For a `paused`, `blocked`, or `indeterminate` checkpoint, prepare the original full
plan again, approve the returned remaining-plan digest, and use `task resume`. The service must
validate authority against only those remaining steps; the runner separately rechecks the full
plan digest and checkpoint index. Never substitute `task run` for a partial resume.
An `expired` checkpoint is terminal; use a versioned new task identity instead of resetting its
plan-wide deadline.

For the narrow zero-focus agent front door, first discover one exact PID,
`instance_ref`, and `window_ref`, then submit one declarative intent through stdin:

```sh
~/.local/bin/macctl action resolve --intent-stdin --json < /private/tmp/macctl-action-intent.json
~/.local/bin/macctl action run action_RESOLUTION_ID --json
```

The intent schema is `macctl-action-intent/v1` (`schema_version: 1`). It supports only
`action: "press"`, `risk: "safe"`, `focus_policy: "background"`,
`foreground_budget: 0`, an exact application/PID/instance/window tuple, a mutation selector
with `identifier` or `locator_digest`, and a read-only `desired_state.selector`. Resolve
rejects already-satisfied state. The returned resolution is daemon-local, expires after at
most 30 seconds, and is consumed before one AXPress attempt. Run re-resolves the exact tuple
and control, verifies the desired state inside the same opaque window, and proves the
unrelated foreground PID did not change. Ambiguity, disappearance, PID replacement, an AX
graph event, focus theft, or failed readback is terminal; never replay or widen the target.
If native AX dispatch returns non-success after a possible send, run still performs only the
bounded read-only postcondition. Observed desired state reports
`dispatch_status=indeterminate_but_verified`; otherwise the consumed resolution ends as
`dispatch_indeterminate` and cannot be replayed.

Use `scripts/background_action_fixture.py build|launch|status|stop|clean` for live tests. The
fixture owns a uniquely identified app with two visible windows and intentionally repeated
button semantics across them. Select the intended window through read-only discovery and prove
the decoy remains unchanged. `stop` validates exact executable ownership before SIGTERM;
`clean` refuses an active, state-bound, or unmarked bundle.

Exact process/window keyboard mutation is available only as an approved foreground `task.run` key step.
Bind every input step to one `process_id`, launch-bound `instance_ref`, and opaque `window_ref`;
require sensitive risk, an approval reason, strict one-attempt recovery, and an exact-window
Accessibility `element_exists` postcondition. Require the returned input route to be
`exact_foreground`. The task lease must be active, NSWorkspace must report the requested PID as
frontmost, and AX must report the requested window digest as focused immediately before input.
PID-specific AppKit activation and AX raising are actuation attempts, not proof; both independent
oracles remain mandatory.
Missing, ambiguous, stale, non-visible, minimized, or oracle-mismatched windows block before
dispatch. A target race after dispatch is indeterminate and must not be retried. Do not fall back
to background delivery, `control.perform`, another action kind, or application-level targeting.
Postcondition observation must reuse the lease-bound application PID and resolve only inside the
bound `window_ref`; app-name re-resolution and broader process/window searches are forbidden.
Treat `element_exists` as an existential assertion inside that already-unique window: duplicate
matching descendants pass, while ambiguous window identity, disappearance, or an incomplete
bounded search with no match fail closed. This does not relax uniqueness for mutation selectors.
Poll the read-only postcondition oracle within the declared step timeout for asynchronously
published Accessibility state. Polling never redispatches the action, and every observation must
revalidate the exact instance, window, foreground, and lease.

For same-product VS Code verification, use `scripts/vscode_fixture.py` to build
one marked disposable copy with a unique bundle ID, isolated profile,
extensions directory, and workspace. The build requires an unambiguous local
signing identity and a verified copied signature. Use
an explicit inside-out signing walk for every copied Mach-O and nested code
bundle; deprecated `codesign --deep` discovery can miss Electron libraries.
Preserve the source `CFBundleName` and helper-app names; use the copied app
filename plus unique `CFBundleIdentifier` for fixture identity.
Verification must require every code object to share the outer bundle's Team ID.
The legacy `--repair-invalid-nested-signatures` flag is accepted but no longer
changes behavior. For a stopped marker-owned fixture built by the older path,
`repair-signatures --root <root>` re-signs it only with its marker-bound original
identity and verifies the full closure before relaunch. It never signs the source.
Use `--allow-full-copy` only when the caller accepts the bounded storage cost.
LaunchServices may hold the non-notarized modified app for a native first-open
decision. Treat `awaiting_manual_approval_or_startup` as blocked while live and
`stopped_before_ready` as requiring a relaunch before user review. The user must
review that dialog, and an agent must not click it or change Gatekeeper. Proceed
only after fixture `status` is `ready`, then discover the unique bundle ID and
use the unchanged exact PID/instance/window task contract. `stop` validates the
recorded process command before SIGTERM; `clean` refuses an active or unmarked
root.
