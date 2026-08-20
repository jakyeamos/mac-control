# Mac Control routing cases

Use these cases when the correct control surface is not obvious. The first principle is to
choose the highest-confidence, lowest-overhead route that can perform and verify the exact
task.

## Known-limitations preflight

Run `macctl control limitations --json` before choosing a Mac Control route. The local
`mac-control-limitations/v1` ledger is the first routing check and distinguishes
`do_not_call`, `handoff_only`, and `call_with_constraints`. It prevents known dead ends from
turning into live capability reconstruction; it does not grant execution authority.

If a fresh observation finds a boundary missing from the ledger, record a candidate rather than
reconstructing it on the next task:

```sh
macctl control limitations propose --stdin --json
macctl control limitations proposals --json
```

This is a local, owner-only, append-only review lane. Candidates are forced to `unproven` and
never affect routing or execution. Promotion requires a reviewed source-controlled ledger,
documentation, and test change.

| Ledger trigger | Mac Control disposition | Preferred route |
| --- | --- | --- |
| A mature direct interface covers the exact task | `do_not_call` | Direct CLI/API/typed connector/browser DOM |
| Target is rendered webpage content | `do_not_call` | Browser connector with tab/frame and DOM readback |
| No unique verified scroll viewport or presentation-only row | `handoff_only` | Computer Use or another provider with fresh state |
| Background mutation, exact keyboard, or visual/coordinate target | `call_with_constraints` | Exact named task/action front door or explicit manifest route |
| Stale, ambiguous, unmeasured, or possibly dispatched route | `call_with_constraints` | Fresh provider route; never a universal fallback ladder |

## Route matrix

| Situation | Route | Reason |
| --- | --- | --- |
| A mature CLI or API performs the exact operation | Direct interface | Avoid GUI activation and input overhead. |
| A browser DOM connector can identify and verify the page element | Browser DOM | Keep semantic web actions in the DOM. |
| An ideal-state manifest claims web content through native Accessibility | Reject the manifest claim and use a browser connector | A native route observing browser chrome does not prove semantic control of rendered page content. |
| A native app exposes a declared typed Mac Control adapter | Mac Control adapter | Use the narrow declared operation and its verification. |
| One safe button press is uniquely addressable inside an exact non-frontmost native window and has a verifiable desired state | `action resolve` then one-shot `action run` | Preserve unrelated foreground focus while binding PID, instance, window, control, and postcondition; fail closed without replay. |
| VS Code Problems data is needed semantically | `adapter diagnostics` for the exact disposable diagnostics fixture | Read the extension-owned `vscode.languages.getDiagnostics` snapshot; do not open Problems with global keyboard input. |
| A task has a fresh measured candidate for this app/version/target | The eligible manifest candidate | Rank complete-action latency, p95 latency, then recoveries after all gates pass. |
| An ideal-state task has a stable built-in shortcut or exact customizable command surface | Declare shortcut acceleration and a shortcut candidate when assigned | Preserve semantic command identity, contextual availability, conflict handling, reversible custom assignment, and the same independent task oracle. |
| Fast capability discovery is needed before routing | `control capabilities` | Probe route metadata and read a cached broad profile without walking AX. |
| A fresh native task surface needs bounded verification before routing | `control capability-verify` | Observe one bounded structural AX surface; require an exact postcondition digest before readiness and preserve Computer Use for candidate, ambiguous, or unsupported results. |
| Live app process state is needed for targeting | Daemon-backed `app list` or exact `app instances` | A socket-unavailable or sandbox-blind catalog is unknown/blocked, never evidence that the app is stopped. |
| Known limitation preflight is needed before considering Mac Control | `control limitations` | Read the local versioned call/no-call ledger without daemon or Accessibility probing. |
| A new boundary was observed and should be retained for review | `control limitations propose --stdin` | Append one owner-only `unproven` candidate without mutating the canonical ledger. |
| Review candidates already recorded by agents | `control limitations proposals` | Read the append-only candidate store; candidates have no routing or execution authority. |
| Rendered browser page content is the target | Browser connector handoff | Declare `target_surface=web_content`; Mac Control returns a tab-addressed provider handoff without activating browser UI. |
| A broad profile is missing, stale, or explicitly needed for planning | `control capability-audit` | Perform one bounded, read-only AX/provider audit and persist stable descriptors. |
| A bounded inventory is needed across installed applicable apps | `control capability-audit-batch` | Audit up to 24 already-running apps, persist resumable per-app receipts, and never launch or dispatch input. |
| Several verified actions target one foreground app | `control batch` | Hold one bounded app lease, cache only the route lookup, and revalidate every step. |
| A native control has stable role, title, or identifier addressability | The explicitly requested semantic route | Use the stable address, without assuming it outranks another route globally. |
| A native context menu must be opened and observed | Accessibility `context-menu` | Resolve one target, expose `AXShowMenu`, and require one rendered menu candidate, rendered items, and expected labels before reporting success. |
| A redacted tree or manifest exposes one unique `AXTextField`/`AXSearchField` beside a repeated list | Atomic `search` with `search_shortcut` and the `keyboard` route | Resolve the structural field, use the named search shortcut once, replace ephemeral query text, and verify focus before completing query entry. |
| The task is a shortcut, menu, focus move, or repeated navigation | The declared named keyboard candidate | Use bounded named input with foreground and focus verification when that candidate is selected. |
| A target requires generic Accessibility observation | The declared Accessibility candidate | Preserve semantic targeting with bounded observation and post-action verification. |
| Only pixels or visual text identify the target | An explicitly opted-in visual or coordinate candidate | Use it only when registered for the task and verify the resulting state. |
| Browser chrome is blocked at a tab-strip context menu, but the ordinary app menu exposes an exact equivalent command | Exact App Shortcut plus browser-connector target selection/readback | Promote the static menu command to an app-scoped actuator, revalidate contextual enablement, and verify the browser-native result. |

## Positive and negative examples

- Read `AppleKeyboardUIMode`: use `/usr/bin/defaults read`; the direct read fully covers the
  fact and is faster than daemon-backed control.
- Before any Mac Control assessment, read `control limitations --json`. A `do_not_call` entry
  ends Mac Control routing; `handoff_only` transfers dispatch and verification; and
  `call_with_constraints` requires its exact route and oracle.
- A v3 repository manifest says all eight criteria are true: report eight legacy declarations,
  score `0/8`, and migrate each task to typed v4 semantic claims with source grounding.
- Move focus to the next control in System Settings: use atomic `macctl control perform
  next-control --app "System Settings" --confirm --json`; there is no mature direct interface
  for that visible focus transition.
- Activate a known Save button in a native app: use semantic Accessibility with the button's
  stable role and title before sequential Tab navigation.
- Verify a current native task surface without acting: use `control capability-verify` with
  a stable structural selector. Supply the exact postcondition kind and SHA-256 digest before
  treating a unique actionable target as ready; otherwise preserve the redacted Computer Use
  handoff and do not replay a native action.
- Press one identifier-addressable control in a known background window: use the action-intent
  front door only when the exact PID/instance/window tuple and a same-window desired-state
  selector are available; consume the short-lived resolution once and do not fall back.
- Search a repeated native list when the redacted Accessibility tree exposes one unique
  `AXTextField`/`AXSearchField`: use the atomic `search` task/action and verify
  `search_field_focused`; selecting or opening a result is a separate declared step.
- Trigger a native menu shortcut repeatedly: use a bounded named keyboard route under an
  app-scoped lease.
- Group a Chrome tab when the tab-strip context menu is unreliable but `Tab->Group Tab` is
  exposed in Chrome's application menu: select the disposable or intended tab through the
  browser connector, invoke the exact verified shortcut once, verify the focused
  `AXTextField` named `Tab-group title`, and require group-label readback after naming it.
- Open a native context menu with a known target: use `control perform context-menu` with a
  window-scoped selector when needed; do not infer that this mutates browser tabs or groups.
- If the context-menu postcondition reports zero rendered geometry or ambiguous menu
  candidates, treat the native observation as unavailable and hand off to the eligible
  provider after refreshing state; the outcome should recommend `computer_use` with
  `fresh_state_required=true` and `fallback_allowed=false`; do not treat `AXShowMenu` or
  `visible=true` alone as proof or blindly replay the native action. If
  `outcome.handoff_plan` is present, execute its ordered fresh-state steps using the
  original request as ephemeral input; the plan contains only redacted target identity
  fields and expected-item digests.
- Click a webpage button when a healthy browser DOM connector can identify it: use the browser
  connector, not Mac Control.
- Enter a password or other private text: do not use raw keyboard send; use an approval-gated
  input path.
- Act on an element that is only visually distinguishable: use a visual or coordinate route
  only when the task manifest explicitly opts in and records the route.

## Ambiguous cases

- A CLI exists but only reads state while the task must mutate it: the CLI is not a mature
  route for that action; apply the Mac Control task manifest and eligibility gates.
- A known target is many focus moves away: prefer direct semantic Accessibility. Keyboard
  wins most often for shortcuts and repetitive navigation, not every distant known target.
- A task can accept a custom shortcut but none is assigned: record the verified customization
  surface without claiming a runnable shortcut candidate. Add the candidate only after an
  assigned chord is read back and can use the task's independent postcondition.
- A search field is missing, ambiguous, not structurally addressable, or the named shortcut
  does not verify focus: stop. Do not approximate search with repeated `Tab`/`next-control`
  actions, and do not treat a dispatched shortcut as completion.
- The provider can reclaim foreground between calls: prefer one atomic app-scoped action or a
  declared checkpointed task. Do not weaken `keyboard_focus_changed`.
- A command succeeds but verification reports `foreground_only`: classify the action as
  unverified and do not claim task completion.
- An exact static menu command is disabled in the current state: classify it as contextual,
  not missing. Require an explicit proposal with a declared postcondition, then execute only
  after the target state makes the item enabled. Hidden, dynamic, or still-disabled commands
  remain blocked.
- Chrome `Tab->Group Tab` opens a semantic group editor but may leave its menu state unchanged.
  Reject `menu_item_state=disabled` as its postcondition; use the focused `Tab-group title`
  field for immediate verification and browser-native group-label readback for task completion.
- A Chrome context menu is visible but the requested tab/group mutation is not exposed as a
  typed provider capability: report `chrome_tab_group_mutation` unsupported and hand the task to
  an authorized browser/UI provider; do not synthesize completion from menu visibility.
- A control response includes `outcome`: use its state, provider, verification, and
  `recommended_provider` fields as the machine contract. `verified_success` requires a
  passed verification state; all other states remain incomplete or blocked until the
  returned recovery condition is satisfied.
- Semantic AX scrolling that returns `scroll_fallback_required` or
  `scroll_verification_unavailable`: read `failure_class`, `fallback_allowed`, and
  `recommended_provider`. When the provider is `computer_use`, refresh app state, locate a
  fresh scrollable element, scroll with Computer Use, and verify a changed state. The local
  `input_scroll` route is only a declared fallback and is successful only when its returned
  verification state is `passed`.
- If the handoff requires Computer Use, do not pass the stale AX target across providers:
  call `get_app_state`, perform a fresh unique-element lookup, call `sky.scroll`, then
  re-read and verify the viewport. If the target is ambiguous, stop instead.
- If the user must remain hands-off across multiple actions or providers, start one explicit
  bounded `control hands-off begin --confirm` session before the run. Pass its opaque
  `session_id` to each native action or batch, heartbeat before the advertised interval, and
  end it after the final verification. `Hands Off` keeps the transient safety item visible for
  the bounded session. One-shot focus changes are not presented there; use the independent
  attention provider when a cooperative announcement is needed. Expiry, Stop & Release, or
  shutdown clears the session.
- `control.batch` is deliberately not a universal action ladder. It rejects semantic scroll,
  stops on the first unverified step, and always reports completed count and lease release.
- Full Keyboard Access or a required TCC grant is missing: report `blocked` and the exact user
  action. Do not silently enable or bypass it.
- A same-product VS Code test would collide with existing user windows: use the repository's
  marker-bound unique-bundle fixture with isolated profile/extensions/workspace. Continue only
  when fixture status is `ready`. If macOS reports `awaiting_manual_approval_or_startup`, require
  the user's native first-open decision. If it reports `stopped_before_ready`, relaunch before
  that user review; never approve it for them or fall back to another Code process.
- A VS Code diagnostics fixture is exact but not proven frontmost/focused, or its native snapshot
  is stale, private, ambiguous, or identity-mismatched: report `vscode_diagnostics_blocked` for
  the affected claim, stop, and do not relaunch or replay input blindly.

## App archetypes and capability boundaries

`control capabilities` classifies the app as `native_appkit`, `swiftui`, `electron_chromium`,
`browser`, `system_settings`, or `unknown` from descriptive bundle/name
metadata. SwiftUI/AppKit classification is a hint, not framework-level proof; the broad audit
records observed AX structure instead of claiming a framework can be inferred from every tree.
The classification helps the agent choose what to inspect next; it is not a claim that AX,
keyboard, visual, adapter, or Computer Use control is supported. Route eligibility still
requires the exact app identity, version, task, target fingerprint, permissions, fresh
daemon-executed measurement, and verification oracle.

The lifecycle is intentionally separate: fast route probe -> cached broad profile ->
task-specific verification -> profile update or invalidation. A changed app version, OS,
provider state, or audited tree invalidates the matching profile. Stale elements, failed
actions, and failed verification demote or stale the relevant profile; ambiguous targets remain
candidates. Cached entries contain stable identity descriptors and digests, not raw AX objects.
The broad audit may also emit generic `capabilityLeads` from app-owned menus, controls, dialogs,
help, onboarding, and accessibility disclosures without an app overlay. These leads retain only
normalized shortcut and signal categories, confidence, verification requirements, and locator
digests. Ordinary content text is excluded, conflicting shortcuts stay ambiguous, and no lead is
route authority until task verification and normal measured-route admission both succeed.
If a recursive deep audit reaches its bounded ceiling, the daemon may partition discovered AX
windows into bounded top-level pages. Complete window/page coverage can promote the broad profile;
omitted windows, omitted pages, or a truncated page remain stale and are surfaced as audit evidence.

For a machine-wide inventory, use `control capability-audit-batch --all-applicable` or
`--apps`. It audits at most 24 installed user-facing apps that are already running, serializes
AX access, persists one redacted resumable receipt per app, and leaves not-observed or failed
entries resumable. It never launches applications or dispatches input; an unobserved app is not
negative capability evidence.

For repeated navigation, send a JSON array through `control batch` and keep the batch bounded
to one app. The daemon reports per-step route, verification, fallback, and route-cache-hit
metadata. Use `control perform` for scroll or any step that may require a provider handoff.

The outcome states provide first-class recovery categories:

- `target_missing`: refresh the target lookup; use a declared fallback only when allowed.
- `target_ambiguous`: refine identity and stop before dispatch.
- `target_changed`: treat the snapshot as terminal; refresh target identity before any
  retry and never replay the stale action.
- `no_observed_change` or `verification_unavailable`: refresh state and verify again through
  the recommended provider; do not blindly replay the action.
- `foreground_race`: retry through an atomic app-scoped action or checkpointed task.
- `permission_blocked`: request the documented user permission; do not bypass it.

## Benchmark evidence

Use daemon-executed `route benchmark` for route ranking. It runs the exact action and route
under bounded warmups and samples, measures the complete execution path, and persists metrics
only when every measured sample reaches `verification.state == passed`:

```sh
macctl route benchmark --app "System Settings" \
  --task focus-next-control --target-fingerprint "settings-pane" \
  --action next-control --route keyboard \
  --verification-oracle "focus changed" --samples 5 --warmups 1 --confirm --json
```

The response reports `foreground_fast_path_samples` so activation avoidance is observable;
latencies cover daemon route execution, not CLI process or socket startup. Selection uses the
median action latency and requires at least three verified samples. The manifest is bound to the
app/version, OS version, provider state, task, target fingerprint, and verification oracle, plus
the Accessibility tree signature when one was audited. A context mismatch requires rebenchmarking.
When a native app does not expose a useful plain-Tab transition, use the repository comparison
runner's named focus action with its explicit inverse reset, such as
`run-mac-focus --action next-item --reset-action previous-item`; pair it with the same fresh-state
focus oracle in the non-Mac-Control lane. The runner's oracle includes foreground preservation:
every daemon response must provide matching `foregroundBefore` and `foregroundAfter` identities
with `foregroundChanged == false`, including the inverse reset. Missing evidence is unavailable,
and a foreground change invalidates the sample. Manual/provider-handoff records must use the same
`foreground_oracle` and explicitly report `foreground_state=preserved` before they can join a
foreground-safe comparison; old records without that field are not retroactively promoted.
The benchmark comparison key also includes `focus_policy` (`foreground` or
`background`) and `interaction_mode` (`keyboard`, `pointer`, `scroll`, `drag`,
or `mixed`). A foreground policy requires the named target to be frontmost;
a background policy is only valid when the unrelated foreground identity is
preserved. Use provider-natural Computer Use pointer/visual, scroll, or drag
actions for the broad comparison. Keep Tab/Shift-Tab as separately labeled
keyboard-task evidence rather than treating it as representative Computer Use.

For semantic scroll, benchmark the exact AX route rather than registering caller-supplied timing.
The identifier is optional when role-only resolution returns exactly one scroll area:

```sh
macctl route benchmark --app "Chrome" \
  --task scroll-main --target-fingerprint "scroll-v1" \
  --action scroll --route scroll --role AXScrollArea --identifier main-scroll \
  --direction down --amount 1 --reset-direction up --reset-amount 1 \
  --verification-oracle "viewport changed" --samples 5 --warmups 1 --confirm --json
```

The reset direction must be the exact opposite of the measured direction when more than one
invocation runs. This keeps scroll ranking reproducible and prevents a manifest from being written
from a stale or cumulatively shifted viewport.

Use `route register` only when explicitly recording external metadata; its
`measurement_source` remains `caller_supplied` and is not equivalent to a live benchmark.
Caller-supplied candidates remain inventory-only and cannot win warm-path selection. The
daemon-executed benchmark measures the complete action, including route dispatch, verification,
and cleanup, so warm-path ranking is not based on caller-reported timings.
The repository end-to-end comparison runner also accepts `--task` on
`run-mac-scroll` (default `scroll-main`) so a live daemon sample can extend a
task-specific paired fixture without changing its comparison identity. Its
optional `--record-route` only preserves a historical redacted label; it does
not change the executed daemon route. The runner samples the redacted
foreground identity through `macctl control status --json` before and after
each action and inverse reset, outside the timed route. For a foreground
fixture, both snapshots must identify the named target and remain unchanged;
missing target identity, missing status, or a changed identity fails closed.
It records `foreground_oracle=foreground_unchanged` for compatibility with
existing fixtures, so every ranked scroll sample remains foreground-comparable
with the paired provider lane.

App routing policy comes from a provider-neutral archetype profile plus declarative bundle
overlays. The current-session cache stores the selected route and stable identity descriptors,
not live AX objects or replayable coordinates. The same lease, per-step revalidation, fallback,
and invalidation rules apply to every profile. A stale element, action failure, or verification
failure immediately demotes the selected route and removes its lease cache entry. Browser DOM,
CDP, and Computer Use preferences declare a handoff to the owning provider rather than an
executable Mac Control route.

## Evidence basis

The 2026-08-02 local benchmark found that a direct preference read beat Mac Control for a
structured fact, while atomic Mac Control focus navigation beat generic GUI control for a
workflow without a mature direct interface. Treat those timings as host-specific evidence,
not a universal constant. Persist new measurements under the exact app/task/version/target
manifest and rebenchmark when the control surface or provider runtime changes.
