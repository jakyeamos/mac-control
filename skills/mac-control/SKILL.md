---
name: mac-control
description: Route and execute verified macOS UI work through the installed macctl control plane. Use when a task needs a visible macOS app, native control, menu, focus movement, or keyboard shortcut; when no mature CLI, API, typed app connector, or browser DOM route covers the exact action; or when choosing among Mac Control semantic Accessibility, keyboard navigation, generic GUI, and visual or coordinate interaction. Prefer a mature direct interface when it fully covers the task, and do not use Mac Control merely for read-only settings or state that a direct macOS command can answer.
---

# Mac Control

Choose the highest-confidence, lowest-overhead route that can verify the result. Use Mac
Control to extend an agent's speed and reach; do not use it merely because a task happens on
a Mac.

Load this packet once. If the source, canonical installation, or provider projection resolves
to the same skill, do not load another copy.

## Known limitations ledger — read before routing

Before assessing Mac Control or running a capability probe, read the local ledger:

```sh
macctl control limitations --json
```

This command is a fast, local preflight. It does not contact the daemon, inspect an app,
walk Accessibility, request permissions, or authorize execution. The
`mac-control-limitations/v1` ledger is a versioned call/no-call contract, not a substitute for
task-specific live evidence. Apply its posture:

- `do_not_call`: use the named direct provider or stop; do not spend time reconstructing a
  Mac Control route (`direct-interface-first`, `rendered-web-content`,
  `unregistered-development-process`, `read-only-settings-query`).
- `handoff_only`: Mac Control may describe the boundary, but the preferred provider owns
  dispatch and fresh-state verification (`semantic-scroll-without-verified-viewport`,
  `presentation-only-accessibility-row`).
- `call_with_constraints`: Mac Control is eligible only through the listed exact route,
  authority, and postcondition (`no-universal-fallback-ladder`, `direct-background-control`,
  `exact-keyboard-input`, `visual-or-coordinate-only-target`).

Do not launch `control capabilities`, `control capability-audit`, or a live GUI assessment
merely to rediscover a ledger entry. After the ledger allows Mac Control, use the fast
task/app-specific probe and current provider state below; a ledger entry never promotes a
stale, caller-supplied, or unverified route.

## Route before acting

Use a mature direct CLI, API, typed connector, or browser DOM route when it covers the exact
action and exposes a verification result. Treat it as mature only when it is installed,
healthy, authorized, exact for the task, and independently verifiable. Do not count a
read-only interface as coverage for a required mutation.

When Mac Control is the selected surface, route choice is task-specific rather than a fixed
Accessibility-to-keyboard-to-visual ladder. First apply the safety, permission, target
uniqueness, and verification gates. If a fresh manifest exists for the exact app identity,
version, task, and target fingerprint, choose the fastest eligible measured candidate by
complete-action latency, then p95 latency and recoveries. Unmeasured or stale candidates are
unproven and must be rebenchmarked. Otherwise use the explicitly requested route or the
selector's addressability metadata as a single route; do not invent a fallback.

A repository-owned `mac-control-task-manifest/v4` declares eligible task surfaces and
provider/method/interaction-mode candidates; it never declares `selected_route` or scores
self-attested `criteria` booleans. Keep target identity, foreground focus policy, execution
candidate, and independent verification oracle separate. Declare `surface_kind`, then provide
typed, criterion-specific semantic claims and repository-relative source references for stable
identity, correct semantics, observable state, useful hierarchy, efficient navigation,
verifiable outcomes, route flexibility, and stable change behavior. Quality Runner must resolve
every source reference to an implementation file and find its evidence tokens near one unique
anchor before a dimension scores; docs, tests, fixtures, snapshots, and symlinks do not count.
Require the claim to agree with the task's selector, navigation strategy, direct entry point,
verification expectation, readback provider, distinct fallback provider, fallback policy, and
typed failure behavior. Treat v1 through v3 as declaration-only migration formats, even if all
eight legacy booleans are true.

Provider claims must match the surface. Keep rendered web content on a browser connector, use a
native semantic provider for native app UI, and require both for a hybrid transition.
Accessibility candidates need a stable identifier. Visual, pointer, and drag candidates require
an explicit fresh-state handoff. State declarations are task-specific and every omitted standard
state needs an explicit exemption reason. Every task also declares shortcut acceleration as a verified
built-in binding, a verified customization surface, or an explained exemption. A shortcut
capability requires stable command identity, contextual availability, conflict handling, and
the task's normal independent oracle; a customizable macOS App Shortcut also carries an exact
menu path and reversible assignment. Shortcut availability makes a route eligible for setup or
measurement but never makes it the static winner.
Human accessibility coverage is not live agent-operability or
performance evidence. Do not prefer universal AX scrolling, Command-K, serial Tab traversal,
or visual fallback merely to improve a static score; live route evidence must select and
measure the provider-natural action.

When a local sibling provider needs the same human decision before its own sensitive plan, it may
use Mac Control's `approval.external.prepare`, `approval.external.status`, and
`approval.external.consume` daemon methods. Accept only bounded provider identity, provider
instance, plan ID, exact SHA-256 plan digest, summary, and risk. Review pending records through
the owner-only `macctl approval list|approve|deny` lifecycle; never return or forward the private
approval token to the sibling provider. Consumption must repeat the exact binding and is
single-use. Denial, expiry, mismatch, and replay are terminal. The transient menu-bar safety item
does not present approvals, and an unavailable broker does not authorize the provider action.

Visual and coordinate candidates require explicit task-manifest opt-in. Only a declared
fallback may run after a pre-action target-not-found result. Stop on ambiguity, possible side
effects, action failure, or failed verification. Read [references/routing.md](references/routing.md)
when the route is ambiguous, the task spans applications, or the action carries approval or
private-input risk.

Before declaring browser chrome blocked because the tab strip or its context menu is not
addressable, inspect the running browser's ordinary application menus with `macctl shortcut
audit`. Look for an exact static command that performs the missing operation, such as Chrome's
`Tab->Group Tab`. Treat a static item that is disabled only in the current app state as a
contextual candidate, not proof of absence. Provision it only through an exact App Shortcut
proposal with a declared behavior postcondition; execution must revalidate enablement, app
focus, and target identity. Let the browser connector select the tab and read back the resulting
group label when those are its stronger interfaces. A shortcut dispatch without that readback
does not prove general tab-strip mutation support.

If the target is rendered webpage content, declare that boundary before any native action:

```sh
macctl control capabilities --app "Chrome" --target-surface web-content --json
```

Treat `provider_handoff_required` as a successful routing decision, not a Mac Control failure.
Submit the exact tab/frame/DOM plan to the recommended browser provider and let that provider
refresh connector health, dispatch, and verify the page postcondition. Never retry with
`control perform` or activate Chrome merely to reach ordinary DOM content. Use
`--target-surface mac-app-ui` only for browser chrome, native menus, and OS dialogs.
The CLI resolves this web-content branch locally so an older daemon cannot
ignore the field and activate the browser.
The web-content capability boundary accepts `--app Chrome` as the common alias for the
installed `Google Chrome` identity. This does not relax the browser provider's fresh tab,
frame, connector-health, or DOM postcondition checks.
For Chrome `Tab->Group Tab`, verify the immediate result as a focused `AXTextField` whose
accessible name is `Tab-group title`, then name the group and require browser-native group-label
readback. Do not use the menu item's enabled state as the postcondition: Chrome can keep the
command structurally enabled after opening the group editor.

When a redacted Accessibility tree or ideal-state manifest exposes one unique
`AXTextField` with subrole `AXSearchField` alongside a repeated list, prefer the atomic
semantic `search` action with the declared `search_shortcut`/`keyboard` route before serial
navigation. The query is ephemeral and existing search text is replaced by default; the
action's verified completion is only `search_field_focused` after query entry. Finding,
selecting, or opening a result must be represented by a later declared predicate or action.
If the field is missing or ambiguous, or the named shortcut cannot be verified to focus the
declared field, stop and report the blocker or indeterminate result. Never fall back to
repeated `next-control`/Tab traversal.

For a background task or workflow, the same search target may use direct Accessibility value
setting only with `replace_existing=true`, one named non-foreground app, and ephemeral input.
A semantic background scroll additionally requires one unique `AXScrollArea` and a verified
bounded state change. Typed adapters are background-eligible only when the operation manifest
reports `focusSupport=background_safe`; absence of that declaration means foreground-only.
Do not reinterpret these routes as multiple macOS first responders: Full Keyboard Access,
global pointer input, activation, visual/coordinate targeting, and ambiguous controls still
require the foreground path.

For a read-only Full Keyboard Access status check, use the direct preference read:

```sh
/usr/bin/defaults read -g AppleKeyboardUIMode
```

Do not run `macctl doctor`, `macctl capabilities`, or `macctl control status` merely to answer
that preference question. A missing key or unreadable result is unknown, not disabled.

## Reconcile the live prerequisite only for a Mac Control route

Stop here when the direct route fully covers the task. Run the following checks only after
selecting a Mac Control route that will send or prepare synthetic input:

Resolve the installed command and inspect the live control plane before input:

```sh
command -v macctl
macctl --version
macctl --help
macctl doctor --json
macctl capabilities --json
macctl control status --json
```

Prefer the resolved command. If `macctl` is not on `PATH`, check the documented installed
path at `~/.local/bin/macctl`. A missing daemon, permission, foreground, or Full Keyboard
Access prerequisite is `blocked`; follow the returned recovery instructions. Do not enable
Full Keyboard Access, change TCC permissions, or install persistent components without the
user's authority.

For the bounded showcase target, preview the product-owned synthetic research-session plan
before attempting any live action:

```sh
macctl task displays --json
macctl task compose focus-session \
  --display-id <connected-display-id> --layout balanced \
  --request "Prepare my research session" --json
```

Require `status=preview_only`, `executable=false`, the three ordered effects, their rollback
and verification notes, and a stable `approval_digest`. This command is planning evidence
only. Do not pass its output to `task.prepare` or claim live capability until the named
`blocked_by` implementation and verification gaps have been closed.

Use `task compose focus-session --plan --json` to inspect the exact executable candidate.
Accept it only when its three actions are the allowlisted `document.open-focus-brief`,
`document.open-focus-scratchpad`, and `workspace.arrange-focus-session` operations; no path,
content, application override, script, or frame may be caller-provided. The layout action must
carry the approved numeric `display_id` and one allowlisted `layout_name` (`balanced` or
`brief-primary`); display order and main-screen state are not authority. Each step must have a
strict `focus_session_verified` postcondition. Do not run or describe the candidate as live
until the exact installed daemon passes the positive, partial-failure, and stale-state paths.

The three effects are opening the bounded brief, opening its bounded scratchpad, and arranging
both windows. Verification must come from post-dispatch fixture digests and Accessibility
window observations tied to the exact plan digest. Prefer exact `AXDocument` URL equality; when
an app omits that attribute, require exact in-memory digest equality with the product-owned public
fixture filename as well as the content digest and visible focused window. Never treat an action
return value as proof, and never retain visible window titles, file paths, or document contents
in the receipt.
Allow at most two seconds of read-only polling for Accessibility window publication after an
open completes. Never redispatch the open operation inside that observer wait; the three-action
budget remains one dispatch per declared effect.
For verification and layout, resolve the unique matching public fixture across all visible
windows in the expected app. Never assume the fixture is whichever window is focused.
Resolve the approved display ID from the current connected set immediately before layout and
verification. Reordered display enumeration must not change the target; a missing or ambiguous
display blocks the step without falling back to another screen.

For general window placement, use the native daemon surface instead of a
Rectangle, Loop, keyboard-shortcut, pointer-drag, or raw-coordinate route:

```sh
macctl app instances --app "<app>" --json
macctl app bind --app "<expected-name-or-path>" --process-id <pid> --json
macctl window displays --json
macctl window list --app "<app>" \
  --process-id <pid> --instance-ref <instance-ref> --json
macctl accessibility tree --app "<app>" \
  --process-id <pid> --instance-ref <instance-ref> \
  --window-ref <window-ref> --json
macctl window inspect --app "<app>" --json
macctl window place --app "<app>" --window focused \
  --display-id <connected-display-id> --layout right-half --confirm --json
macctl window restore --restore-token <token> --confirm --json
```

When multiple regular registered GUI processes share an app or bundle identity, first
use `app instances` and then bind read-only window/tree inspection to the
returned PID and, when present, launch-bound `instance_ref`. For a development
process that is discoverable by PID but absent from the registered app catalog,
use `app bind` with the expected executable name or exact path. The command
keeps that identity conjunctive and independently probes the exact PID's
`AXApplication` root. A process, healthy daemon, and granted Accessibility
permission do not establish AX addressability.

If binding reports
`development_binary_not_registered_as_accessibility_application`, classify Mac
Control as `blocked_unsupported` for that unregistered target while preserving
installed-app support. Do not retry by app name or widen to another PID. Build
a real `.app` with an Info.plist and normal application activation policy, use
`app open <absolute-app-path>` to launch that exact development bundle, then
rediscover and bind its PID. Mac Control does not wrap a bare executable as an
application.

Treat PID, instance, and window references as conjunctive: `target_missing`, `target_ambiguous`, or
`target_changed` is terminal for that snapshot, and must never fall back to a
different process or focused window. `window list` is read-only and returns
opaque title-free references; refresh it when a window reference becomes stale.

Exact identities remain read-only on direct app-level surfaces. App-level
activation and AX raising do not independently prove foreground input ownership.
Do not use `control perform` or another app-level mutation route as an
exact-target fallback.

For one safe semantic button press that must preserve an unrelated foreground
app, use the separate agent front door: discover the exact PID,
launch-bound `instance_ref`, and opaque `window_ref`; submit a complete
`macctl-action-intent/v1` object to `action resolve --intent-stdin`; then pass
the returned one-shot ID directly to `action run`. Require
`focus_policy=background`, `foreground_budget=0`, `risk=safe`, a mutation
selector with `identifier` or `locator_digest`, and a desired-state selector
inside the same window. Resolve must reject already-satisfied state. Run must
consume before dispatch, freshly re-resolve the tuple and unique AXPress target,
dispatch once, verify declared state through bounded readback, and prove the
unrelated foreground PID is unchanged. Treat expiry, replay, ambiguity,
disappearance, PID replacement, AX invalidation, foreground change, or failed
readback as terminal. Never activate, retry, send keys/pointer input, widen the
target, or fall back after possible dispatch.
Treat a non-success native AX return after possible dispatch as indeterminate,
not as proof that nothing happened. Continue only the bounded read-only
postcondition: observed state may complete as `indeterminate_but_verified`;
otherwise stop as `dispatch_indeterminate`. Never replay the resolution.

For the narrow exact keyboard mutation contract, use only an approved foreground
`task.run` key step whose target carries the conjunctive `process_id`,
launch-bound `instance_ref`, and opaque `window_ref`. Every exact input step must
carry the same tuple; never mix exact and application-level inputs. Require
`risk: sensitive`, a non-empty approval reason, strict recovery with one
attempt, and an Accessibility `element_exists` postcondition that can be
evaluated inside the exact window. The daemon must return
`exact_foreground`, hold the exclusive task keyboard lease, prove NSWorkspace
frontmost PID equality, and independently prove that AX's focused window digest
matches the requested window. PID-specific AppKit activation and AX raising are
actuation only and never satisfy either oracle. Treat a pre-dispatch missing, ambiguous, stale,
or oracle-mismatched binding as blocked. Treat any target race detected after
dispatch as indeterminate and do not retry. Never substitute background
delivery, click, type, scroll, adapter, or a broader process/application route.
Require postcondition observation to reuse the lease-bound PID and resolve only
inside the bound `window_ref`; never let it re-resolve `Code` by name or widen to
another process or window. Evaluate `element_exists` existentially inside that
already-unique window: one or more matching descendants pass. Ambiguous window
identity, disappearance, or an incomplete bounded search with no match must
fail closed, and mutation selectors must remain unique.
Poll only the read-only postcondition oracle within the declared step timeout
when Accessibility state may publish asynchronously. Polling never authorizes
another mutation; every observation must revalidate the exact instance,
window, foreground, and lease.

For a same-product VS Code acceptance test, never reuse or mutate an existing
`Code` process. Build a task-owned unique-bundle fixture with the repository
`scripts/vscode_fixture.py` lifecycle, an isolated profile, extensions
directory, and workspace. A valid local signing identity must be unambiguous;
ad-hoc signing is only a local probe. The builder must sign every copied Mach-O
and nested code bundle inside-out and verify one Team ID across the closure;
do not rely on deprecated `codesign --deep`, which can miss Electron framework
libraries. Preserve the source `CFBundleName` because Electron uses it to locate
its helper apps; only the copied app filename and `CFBundleIdentifier` become
fixture-specific. The legacy `--repair-invalid-nested-signatures` flag is compatibility
syntax only. A stopped marker-owned fixture from the older path may use
`repair-signatures --root <root>` only with its original signing identity; never
repair or sign the source app. A cross-filesystem full copy requires explicit
`--allow-full-copy`.

After launch, require fixture `status=ready` before discovery or input. Treat
`awaiting_manual_approval_or_startup` and `stopped_before_ready` as hard stops;
the latter requires relaunch before the user personally reviews the native
first-open code-evaluation dialog. Never click that approval, weaken Gatekeeper,
or fall back to another Code PID/window. Once ready, discover
the fixture's unique bundle ID, then bind its PID, `instance_ref`, and
`window_ref` through the unchanged exact foreground `task.run` contract. On
completion, stop and clean only through the marker-bound fixture lifecycle.

Select only a display ID returned by the fresh catalog and one layout returned
in its `layouts` array. Placement is foreground-only and may target only the
focused window of the named app. Require `outcome.state=verified_success`,
`route=native_accessibility`, and frame plus destination-display readback.
Never retry a placement after dispatch may have occurred. The returned restore
token is five-minute, single-use authority bound to the original process,
window identity, frame, and display; do not persist or reuse it. A missing
display, relaunched process, ambiguous identity, unsupported/full-screen
window, or unavailable verification is blocked. This native baseline does not
require or invoke a third-party window manager.

When a task checkpoint is partial, resubmit the original full plan to `task prepare`, approve
the returned digest for only the remaining steps, and continue with `task resume`. Require the
service preflight to bind authority to that remaining plan and the runner to recheck the full
plan plus checkpoint index. Do not use `task run` to continue a blocked or paused checkpoint.
Treat an `expired` checkpoint as terminal and require a versioned new task identity; never reset
the original plan-wide deadline.

## Execute the smallest verified action

For one visible action, use the atomic app-scoped form. It activates the target, waits for
stable foreground, creates an ephemeral lease, performs and verifies the action, and releases
the lease before returning. If the requested app process is already foreground, the daemon may
skip redundant activation, but it still performs stable foreground reads plus the normal lease,
permission, focus, and post-action verification checks:

```sh
macctl control perform next-control \
  --app "System Settings" --confirm --json
```

For a known control, provide stable semantic identity rather than coordinates:

```sh
macctl control perform activate \
  --app "TextEdit" --confirm --role AXButton --title "Save" --json
```

Pass `--focus-policy automatic|foreground|background` (or `--background`) when
the caller needs the focus expectation to be machine-readable. The CLI sends
`automatic` explicitly by default. Automatic prefers a verified background
route for the exact operation and immediately uses foreground when none is
eligible before dispatch. It never waits for idle time, queues focus work, or
consolidates focus changes. Results distinguish requested and effective policy
with `requested_focus_policy`, `focus_policy`, `focus_selection_reason`, and an
optional `background_unavailable_reason`. A successful foreground action reports
`focusPolicy`, `foreground_oracle=target_foreground_unchanged`, and
`foreground_state=preserved`; a changed foreground is a `foreground_race`,
never a successful action. Direct `control.perform` and `control.batch` reject
explicit `background` with an `action_unavailable`/`background_unsupported` handoff to
`task.run` (`recommended_surface=task.run`,
`next_action=submit_named_background_task_plan`) for their existing action
kinds. The separate `action.resolve`/`action.run` front door admits only its
safe exact-window AXPress contract; it does not make app-level direct control
background-safe. Automatic direct control therefore resolves to foreground
immediately; use a declared background task or the exact press front door when
its stricter schema fits. Do not turn this handoff into global keyboard or
mouse input, and never retry a possibly dispatched background mutation in the
foreground.

System Settings sidebar rows may expose `AXShowDefaultUI` or
`AXShowAlternateUI` on an `AXRow`/`AXOutlineRow` instead of `AXPress`, and the
native row may have no readable AX title. Those are presentation-only AX
actions, not a verified click/selection route. Resolve the row through a
bounded `accessibility audit` locator; `control perform activate` must fail
closed with `action_unavailable`, `recommended_provider: computer_use`, and
`fresh_state_required: true`. The agent then gets fresh Computer Use state,
relocates the named row, clicks it visually, and verifies the selected pane.
Rows that expose `AXPress` still require the task-specific `selected_pane`
postcondition before reporting success.

When a native control is repeated across windows, add `--window-title` or
`--window-identifier`; the resolver selects exactly one window before walking
that window's Accessibility subtree. For a native context menu, use the
typed `context-menu` action and require menu labels when they are known:

```sh
macctl control perform context-menu \
  --app "Google Chrome" --confirm --role AXButton --identifier tab-group \
  --window-title "Project - Google Chrome" \
  --expected-menu-items "Add tab to new group" --json
```

This opens and verifies the native menu only. It is not a Chrome tab/group
mutation provider; Chrome capability discovery reports
`chrome_tab_group_mutation` as unsupported.
The verifier requires exactly one rendered `AXMenu` candidate with positive
geometry and at least one rendered `AXMenuItem`. AX menu templates with
zero-sized bounds, missing item geometry, or multiple rendered candidates are
reported as `verification_unavailable`; inspect the postcondition's rendered
menu and ambiguity evidence before choosing a provider handoff.
For this postcondition failure, the machine outcome recommends
`recommended_provider: computer_use`, requires fresh state, and supplies the
`get_app_state`/fresh-target/verification next action. The machine field
`fallback_allowed=false` is intentional: do not blindly retry the AX action
because it may already have been dispatched; complete the provider handoff only
after fresh state is read. When `outcome.handoff_plan` is present, execute its
ordered steps automatically in the receiving provider: `get_app_state`, locate
one unique target from the original request, right-click that fresh target, and
read state again for the rendered menu and foreground-preservation oracle.
Pass the original request's selector values and expected menu labels to the
caller-owned provider, never the stale AX reference. The plan stores only
redacted app/selector identity fields and digests, so it is safe to persist in
the operation receipt; `native_action_replay_allowed=false` is a hard stop. An
ambiguous fresh lookup or failed verification stops
the handoff without another native retry.

Require a succeeded response and `result.verification.state` equal to `passed`. For atomic
app-scoped actions, also require evidence that `lease_released` is true. A response with
`foreground_only`, unchanged readable focus, an ambiguous target, or an error is not task
completion.

For several consecutive actions in one already-foreground app, acquire the narrowest app
lease, pass its token to every action, and release it in every outcome. Prefer atomic actions
or a declared checkpointed task when the provider may reclaim foreground between requests.
Within that bounded lease, repeated task actions may reuse the route manifest lookup for the
same app, task, and target, while rechecking current permissions and lease/focus state for
every action. Never compose `app open`, lease acquisition, and the first input as an assumed
atomic unit.

For agent-facing capability discovery, use the fast route probe before choosing a route:

```sh
macctl control capabilities --app "Chrome" \
  --task focus-next --target-fingerprint focus-v1 --json
```

The fast probe reports a descriptive app archetype, fresh daemon-measured routes, stale or
caller-supplied inventory, supported contract surfaces, and bounded `recentBlockers` from
owner-only receipts. It also reports bundle-scoped `advertisedCapabilities` learned from public
app accessibility, menu, or help disclosures. These are always `candidate_only`: do not dispatch
an advertised shortcut or add it to a warm route merely because it is listed. The response path
may read a cached broad profile but never walks the Accessibility tree or dispatches an action.
When it observes an already-running native app with missing or stale profile evidence, it may
schedule one coalesced bounded read-only audit on a serial utility queue. Inspect
`auditOpportunity` for `scheduled`, `in_progress`, `satisfied`, `not_observed`, or
`not_applicable`. The opportunity never launches or activates an app, dispatches input, handles
`web_content`, or grants action authority. Before
reusing a locator, inspect matching blocker observations for the
exact app version and, when available, task and target fingerprint. If the prior state is
`target_ambiguous`, do not replay the same locator or choose a match by index. Honor `isFresh`
and `freshUntil`; stale blocker evidence requires fresh inspection before it influences routing.
Retrieve bounded fresh state and refine with stable structural fields such as window, identifier, role, or subrole;
then require normal post-action verification. Receipt observations retain selector field names
and digests, not raw labels or values. An archetype or blocker observation is a routing hint, not
evidence that a provider works for that app; only a fresh measured route is eligible.

When the cache is missing, stale, truncated, or marked for refresh, request the separate broad
read-only audit once for planning or a bounded task:

```sh
macctl control capability-audit --app "Chrome" --max-nodes 500 --max-depth 8 --json
```

The deep audit reads a bounded, redacted AX tree and provider/permission state, then persists a
profile keyed by bundle/path/version, OS version, provider-state revision, and tree signature.
It stores hashed labels plus stable locator descriptors, never live AX element references or
private values. Positive observations are promoted, complete negative observations are demoted,
and truncated or provider-unexecuted observations remain candidates. Task verification can
update or demote an existing profile after an action, stale element, failed action, or failed
verification; it never creates broad capability authority from one action. Do not run the deep
audit before every action or use its profile as a substitute for task-specific verification. A
truncated audit may retry within the daemon's fixed 2,000-node/20-level ceiling; the resulting
evidence reports the attempts and effective bounds. If the ceiling is still truncated, keep the
profile stale rather than treating incomplete evidence as capability. The daemon may then use a
separate bounded `windowed_pages` traversal: up to 8 discovered AX windows, 256 top-level pages,
and 16,000 total nodes. Only complete page/window coverage can promote the broad profile; omitted
windows/pages or a truncated page keep it stale and are reported in the audit evidence.

As part of this off-critical-path audit, inspect both the current bundle overlay's declared
app-disclosure signals and general app-owned capability surfaces. The generic scanner recognizes
keyboard navigation, shortcut catalogs, quick switchers, command palettes, keyboard search, and
nearby split keycaps only in menus, controls, dialogs, help, onboarding, or accessibility context.
It ignores ordinary content text and persists only normalized shortcut and signal metadata plus
hashed locator identities, never the disclosure text. Treat every `capabilityLeads` entry as a
candidate. Conflicting shortcuts remain ambiguous; a dismissed surface is not negative evidence.
A matching task-specific verification may promote or demote the cached lead, but only a fresh
measured route can authorize route selection. Bundle declarations are high-confidence
reconciliation hints, not a prerequisite for discovery. Discord's canonical declarations remain
Tab and arrow-key navigation, Command-/ for the shortcut catalog, and Command-K for Quick Switcher.

To inventory the applicable apps without launching or acting on them, use the bounded,
resumable batch audit:

```sh
macctl control capability-audit-batch --all-applicable --json
macctl control capability-audit-batch --run-id <run-id> --max-apps 6 --json
```

`--all-applicable` selects at most 24 installed user-facing apps; `--apps` accepts an explicit
comma-separated subset. The audit is read-only, audits only already-running apps, serializes AX
access, persists one redacted per-app receipt, and leaves not-observed or failed entries
resumable. It stores identity descriptors and profile evidence, never process IDs or live AX
references. Use the returned `run_id` to resume; do not treat an unobserved app as a negative
capability result.

For several verified actions in one app, use the bounded batch surface rather than repeating
client-side activation and lease setup:

```sh
printf '%s\n' '[{"action":"next-control"},{"action":"activate"}]' | \
  macctl control batch --app "System Settings" --actions-stdin --confirm --json
```

`control.batch` accepts at most 32 actions, owns one ephemeral app lease, revalidates the
foreground, lease, permissions, route, and verification for every step, and releases the
lease on success or failure. It stops at the first unverified step. Semantic scroll is kept
on `control.perform` so a provider handoff cannot be hidden inside a batch.

Every control response includes a provider-neutral `outcome` when available. Treat
`verified_success` as completion only when the verification state is `passed`. Treat
`target_missing`, `target_ambiguous`, `action_unavailable`, `action_failed`,
`permission_blocked`, `no_observed_change`, `verification_unavailable`, and
`foreground_race` as distinct states; do not infer retryability from an error string.

For a task-specific route registry, use daemon-executed `macctl route benchmark`, `route inspect`,
and `route list`. Benchmarking runs the exact action and route for bounded warmups/samples,
requires every measured sample to reach `verification.state == passed`, and only then persists
the median latency, p95 latency, recovery, freshness, and current app/OS/provider context.
A route is warm only with at least three verified samples and a context match; a stale element,
failed action, or failed verification expires it and clears the session lease cache entry.
The fast capability probe resolves declarative `archetype -> app overlay -> session cache` layers;
use the separate read-only capability audit for broad discovery. `macctl route register` remains
an explicit caller-supplied metadata path and is not equivalent to a live benchmark.
The benchmark response also reports `foreground_fast_path_samples`; its timings cover daemon
route execution rather than CLI process or socket startup.
For matched agent comparisons, use the repository benchmark runner with the
named keyboard action and an explicit inverse reset when plain Tab is not the
app's useful focus primitive, for example
`run-mac-focus --action next-item --reset-action previous-item`. Require the
same task, target, state, oracle, timing scope, `focus_policy`, and
`interaction_mode` in the Computer Use lane;
an unchanged or unreadable focus is blocked evidence, not a speed sample. The
focus runner also requires the daemon's `foregroundBefore`, `foregroundAfter`,
and `foregroundChanged == false` evidence for every prime, measured action, and
inverse reset. Missing foreground evidence is recorded as `unavailable`, and a
sample with a foreground change cannot be ranked. `focus_policy=foreground`
requires the named target to remain frontmost; `background` is reserved for a
named-target fixture that preserves an unrelated foreground app. A manually
timed comparison must use the same `foreground_oracle`, `focus_policy`, and
`interaction_mode`, and record `foreground_state=preserved` only when the
receiving provider independently verified it. Older records that do not carry
these fields remain historical, not foreground-safe or modality-matched evidence.
For the broader Computer Use comparison, use provider-natural pointer/visual,
scroll, or drag actions. A Tab/Shift-Tab result is a narrow
`interaction_mode=keyboard` keyboard-parity fixture and must remain separately
labeled rather than serving as the representative Computer Use lane.
For semantic scrolling, benchmark with `--action scroll --route scroll`, a unique `AXScrollArea`
selector, `--direction`, and `--amount`. An identifier is preferred but optional when role-only
resolution returns exactly one container. Repeated warmups or samples must declare the exact
opposite `--reset-direction` and bounded `--reset-amount`, so each measured scroll starts from a
known viewport state. The daemon measures the AX scroll route itself and persists no manifest when
any reset or measured invocation fails verification.
The repository's end-to-end comparison runner accepts an optional `--task` on
`run-mac-scroll` (default `scroll-main`) so task-specific daemon samples remain
pairable with provider-natural Computer Use records. Its optional
`--record-route` preserves a historical redacted route label when extending an
existing fixture; it does not change the executed daemon route. Before and
after every prime, timed action, and inverse reset, the runner reads the
foreground identity from `macctl control status --json` outside the timed
interval. For `focus_policy=foreground`, both snapshots must identify the
named target and remain unchanged; missing target identity, missing status, or
a changed identity fails closed. It records
`foreground_oracle=foreground_unchanged` for compatibility with existing
fixtures while keeping incomplete samples out of the ranked comparison.

Use `macctl accessibility tree` for a bounded, redacted structural snapshot and
`macctl accessibility audit` for duplicate identity, action, scroll-semantic, and
unverifiable-control checks. Tree output excludes AX values, private text, screenshots, and
OCR, and receipt persistence keeps only the evidence kind. When a target is inside a unique
readable `AXScrollArea`, prefer the semantic `control perform scroll` action; it re-resolves
the container after scrolling and compares bounded structural viewport metadata. If the
response is `scroll_fallback_required` or `scroll_verification_unavailable`, inspect the
machine-readable failure details. A `recommended_provider` of `computer_use` means the agent
must initialize fresh app state, locate a fresh scrollable element, use Computer Use scroll,
and verify a changed state. Do not retry AX when `fallback_allowed` is false. The low-level
`input_scroll` fallback is available only when explicitly declared with
`--fallback input-scroll`; a dispatched event is not completion unless its verification state
is `passed`.

The required Computer Use handoff is:

1. call Computer Use `get_app_state`;
2. locate a fresh, unique scrollable element in that state;
3. call Computer Use `sky.scroll` on that element;
4. read state again and verify a changed viewport or bounded structural state.

If the outcome says `target_ambiguous`, stop and refine the target. If it says
`no_observed_change` or `verification_unavailable`, require fresh state before any provider
handoff and never claim completion. A foreground race is recovered through one atomic
app-scoped action or a declared task plan, not by replaying a split sequence.

## Preserve the safety boundary

- When Codex may trigger a Keychain, credential, or permission prompt, inspect the
  short-lived authorization notice in `macctl control authorization list --json`. Use its
  project/repository, task/thread, helper, target, action, expiry,
  and provenance to decide whether the native macOS prompt is expected. `ATTESTED` is only
  local origin correlation; `DECLARED` and `UNVERIFIED` are warnings, not approval states.
  Mac Control never supplies the native Allow/Deny decision, and an external unannounced
  dialog cannot be attributed in v1.
- Authorization notice input is metadata-only. Never pass raw commands, arguments, prompt
  bodies, passwords, tokens, private input, or inherited environment values to the notice
  routes. Source opening is allowed only through the registered Codex opener; if unavailable,
  show the `codex://` reference without attempting to open it.
- Keep `keyboard_focus_changed` fail-closed. Reassert the target through an atomic action;
  never weaken foreground verification.
- Use app-scoped leases by default. Use a session lease only for an intentional cross-app
  workflow whose foreground changes are part of the plan.
- Keep hands off the shared keyboard and trackpad during synthetic input and tell the user
  before an interactive run needs an exclusive-input window.
- Physical keyboard suppression is an explicit session-only opt-in, not a default lease mode;
  use it only when the user deliberately wants an interactive exclusive-keyboard window, keep
  the mouse available for the status-item quit path, provide a human reason and bounded expiry,
  and never use it for app-scoped or unattended workflows. Prefer the explicit
  `keyboard freeze acquire|status|release` surface; the legacy suppression flag is only a
  compatibility alias and is reported as `keyboard_freeze` evidence.
- Never send credentials, private text, or bare printable input through raw keyboard
  sequences. Use the approval-gated workflow or task path.
- Keep browser DOM automation on a mature browser route. Use Mac Control for browser chrome,
  OS-level dialogs, shortcuts, or controls outside the DOM.
- For a `web_content` handoff that returns `result.trace`, keep its completion token in memory,
  execute and verify the exact plan through the external browser provider, then pipe one bounded
  completion object to `macctl receipts trace-complete --stdin --json`. Inspect the joined record
  with `macctl receipts trace <trace-id> --json`. Never put the token in arguments, environment,
  shell history, or a file; never include URL, title, DOM, page text, selector, credential, or raw
  provider IDs in completion metadata. Treat `mac_control_attested` as evidence only for routing
  and `orchestrator_declared` as the browser completion provenance until a browser-owned
  attestation interface exists. An expired token or mismatched replay is terminal; do not replay
  the browser mutation merely to obtain a receipt.
- The menu-bar item does not announce one-shot focus changes; use the independent attention
  provider when a cooperative announcement is needed. For a run spanning native actions or a
  provider handoff, explicitly start the bounded
  `control hands-off begin --confirm` session, pass its opaque `session_id` to every action or
  batch, heartbeat before the returned interval, and end it when the run is complete. The
  visible `Hands Off` pill/popover is the user-facing hands-off guarantee; it says to keep the
  keyboard and trackpad untouched and clears on end, expiry, Stop & Release, or shutdown. A
  session is never inferred from one action, and the action still needs its normal foreground and
  postcondition checks. Physical keyboard `Frozen` remains higher-salience than focus.
- When inspecting Mac Control's transient native safety item, prefer its published Accessibility
  identifiers: `macctl.control-safety.status`, `macctl.control-safety.window`, and
  `macctl.control-safety.health`. The item is hidden while idle and appears only for active
  execution, hands-off or keyboard-freeze authority, daemon lifecycle drain, or degraded health.
  It never presents approvals, authorization notices, focus-only announcements, or completed
  task history. For an active checkpointed task, inspect
  `macctl.task.progress`, `macctl.task.progress.count`, and the redacted
  `macctl.task.progress.<step-id>` rows. Treat only `Verified` rows as completed while the task
  remains active; inspect CLI status and receipts after authority is released.
- Never manufacture a successful receipt or substitute build/test evidence for a live GUI
  result.

## Recover without blind retries

On `keyboard_focus_changed`, `foreground_only`, or a foreground race, stop the split sequence
and retry only through atomic app-scoped control or a declared task plan. On an ambiguous
Accessibility target, refine stable role, title, or identifier evidence before retrying. On a
sandbox socket denial, distinguish sandbox policy from product failure and request the
documented live owner context when authorized.

Report the chosen route, action status, verification state, and any blocked prerequisite.
When comparing speed, time the complete action including activation, lease handling,
verification, and cleanup against the best non-Mac-Control baseline.

For release evidence, run `macctl release check --json` after installing and reloading the
packaged daemon. The check reads the rolling owner-only receipts plus a bounded atomic hidden
archive containing only the newest proof for each exact release dimension; diagnostic ring
eviction therefore cannot erase the last retained release proof. The `agent.contract` check
proves that outcomes, capability discovery,
  bounded batching, and daemon-executed route provenance are exposed. It does not prove that
  live Finder, browser, task-control, or menu-bar safety-item workflows have been exercised; those
  remain separate user-controlled evidence dimensions.
