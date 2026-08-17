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

Lifecycle mutation commands are interlocked with the live daemon. A healthy
daemon must grant an atomic drain before `macctl install` or `macctl daemon
install|restart|remove` changes state; pending or approved authority, active
execution, and in-flight mutation block the drain. The explicit
`--allow-legacy-idle-snapshot` option is only for the first upgrade from a
pre-interlock daemon after owner-visible idle verification.

For read-only runtime diagnostics, use the built CLI only after the package
build: `swift run macctl doctor --json`, `capabilities --json`, `status
--json`, `receipts status --json`, and `release check --json`. Release checks
must not manufacture live evidence or run workflows as a side effect.

For a sensitive-request explanation, use the daemon-only authorization surface:
`control authorization prepare`, `bind`, `list`, and `resolve`. Prepare accepts only
bounded project/task/thread/helper/target/action/summary metadata and an allowlisted
`codex://` source reference; it must not be given raw command text, arguments, prompts,
passwords, tokens, private input, or environment values. `resolve` records completion only.
The status item and Control Center are the fallback when local notification permission is
unavailable. No authorization-notice command approves or denies the native macOS dialog.

Keyboard diagnostics and control use the daemon-authoritative surface:
`swift run macctl keyboard status --json`, `keyboard setup --json`,
`keyboard enable --json`, `keyboard inspect --json`, and the
short-lived `keyboard lease acquire|release`, `keyboard navigate`, and
`keyboard send` commands. The input commands require an execution lease token;
do not substitute them for the structured workflow or task `key` and `type` path.
`keyboard lease acquire --scope session --suppress-physical-keyboard` is an
optional interactive mode that requires Accessibility and Input Monitoring;
it also requires `--reason`, and must not be used for
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
execution belongs to an exact named task plan so process-directed authority and
unrelated foreground preservation are checked together.
Use `--target-surface web-content` on `control capabilities`, `control perform`,
or `control batch` for rendered page content. Capabilities return the preferred
browser provider; execution returns `provider_handoff_required` with
`recommended_surface=browser_connector` and
`next_action=submit_browser_target_plan` before activation. Omit it, or use
`mac-app-ui`, only for browser chrome or native controls.
The CLI resolves web-content capability and handoff responses locally rather
than sending them to a daemon that may predate this field.
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
--direction up|down|left|right --amount <n> --json` is the semantic
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
and `control batch --app <app> --actions-stdin`. Capability output
classifies the app descriptively and distinguishes fresh daemon-executed routes
from stale or caller-supplied inventory; it does not infer provider parity.
The batch audit is a separate bounded, read-only inventory: it selects at most
24 installed user-facing apps, audits only already-running apps, serializes AX
access, persists one redacted receipt per app, and resumes not-observed or failed
entries by run ID without launching apps or dispatching actions.
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
The menu-bar Control Center exposes foreground movement to the user: a light-blue
`Focusing` pill precedes a foreground handoff and `Focused` identifies a one-shot
target notice. For a run that spans native actions or a provider handoff, the caller
must explicitly start `control hands-off begin`, pass its opaque
`session_id` to each `control perform`/`control batch` request, heartbeat before
the returned interval, and call `control hands-off end` on completion. While that
bounded session is active, the persistent `Hands Off` pill and popover tell the user
to keep the keyboard and trackpad untouched. Expiry, `control.stop_active`, and
daemon shutdown clear it; no session is inferred from a one-shot action. `Frozen`
remains the stronger visual state when physical keyboard suppression is active.
Checkpointed task runs project their durable checkpoint into the Control Center as redacted
`Pending`, `Running`, `Verified`, and `Stopped` rows. The projection uses plan step IDs only and
does not expose targets, selectors, inputs, or output. Completed and stopped outcomes remain
available for 60 seconds after input authority is released, so a failed later step cannot hide
earlier verified actions. Use the stable `macctl.task.progress`,
`macctl.task.progress.count`, and `macctl.task.progress.<step-id>` Accessibility identifiers for
direct native-surface verification.

`task compose focus-session` is an executable showcase surface. Its ordered effects open a
bounded brief, open a bounded scratchpad, and arrange their Preview and TextEdit windows. The
source verification contract accepts post-dispatch fixture digests and Accessibility window
observations tied to the exact plan digest; it never accepts dispatch results as proof or retains
visible titles, paths, or document contents. The returned preview is `ready`, executable, has an
empty `blocked_by`, and exposes the exact `plan_digest` used by the runnable plan.

Use `task compose focus-session --plan --json` to inspect the executable candidate behind that
preview. Its three product-owned adapter operations accept no request-controlled path, content,
application, script, or frame. Every step has a strict `focus_session_verified` postcondition;
the open steps compare the fixture digest plus either the live AX document URL or, only when that
attribute is absent, an exact in-memory digest of the product-owned public fixture filename; the
layout step reads both window frames back. Raw titles and paths are not retained. Source
availability is not installed proof.
The open-step observer may wait up to two seconds for Accessibility publication, but it must not
redispatch the open operation while polling; the three-action task budget remains one dispatch
per declared effect.
Resolve the unique public fixture across all visible windows in its expected app for both
verification and layout; do not substitute the currently focused window.

The Tier-1 gate is defined in `docs/TIER1_RELEASE.md`. Missing live evidence
is a recorded `blocked` result, not permission to weaken a check.

For a `paused`, `blocked`, or `indeterminate` checkpoint, resubmit the original full
plan with `task resume`. The service establishes a fresh run-scoped execution lease, then
revalidates the full plan digest, checkpoint index, exact targets, remaining preconditions, and
the caller-declared deadline before dispatch. Never substitute `task run` for a partial resume.
An `expired` checkpoint is terminal; use a versioned new task identity instead of resetting its
plan-wide deadline.
