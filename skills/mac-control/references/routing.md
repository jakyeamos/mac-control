# Mac Control routing cases

Use these cases when the correct control surface is not obvious. The first principle is to
choose the highest-confidence, lowest-overhead route that can perform and verify the exact
task.

## Route matrix

| Situation | Route | Reason |
| --- | --- | --- |
| A mature CLI or API performs the exact operation | Direct interface | Avoid GUI activation and input overhead. |
| A browser DOM connector can identify and verify the page element | Browser DOM | Keep semantic web actions in the DOM. |
| A native app exposes a declared typed Mac Control adapter | Mac Control adapter | Use the narrow declared operation and its verification. |
| A task has a fresh measured candidate for this app/version/target | The eligible manifest candidate | Rank complete-action latency, p95 latency, then recoveries after all gates pass. |
| Fast capability discovery is needed before routing | `control capabilities` | Probe route metadata and read a cached broad profile without walking AX. |
| A broad profile is missing, stale, or explicitly needed for planning | `control capability-audit` | Perform one bounded, read-only AX/provider audit and persist stable descriptors. |
| A bounded inventory is needed across installed applicable apps | `control capability-audit-batch` | Audit up to 24 already-running apps, persist resumable per-app receipts, and never launch or dispatch input. |
| Several verified actions target one foreground app | `control batch` | Hold one bounded app lease, cache only the route lookup, and revalidate every step. |
| A native control has stable role, title, or identifier addressability | The explicitly requested semantic route | Use the stable address, without assuming it outranks another route globally. |
| A native context menu must be opened and observed | Accessibility `context-menu` | Resolve one target, expose `AXShowMenu`, and require the menu plus expected labels before reporting success. |
| A redacted tree or manifest exposes one unique `AXTextField`/`AXSearchField` beside a repeated list | Atomic `search` with `search_shortcut` and the `keyboard` route | Resolve the structural field, use the named search shortcut once, replace ephemeral query text, and verify focus before completing query entry. |
| The task is a shortcut, menu, focus move, or repeated navigation | The declared named keyboard candidate | Use bounded named input with foreground and focus verification when that candidate is selected. |
| A target requires generic Accessibility observation | The declared Accessibility candidate | Preserve semantic targeting with bounded observation and post-action verification. |
| Only pixels or visual text identify the target | An explicitly opted-in visual or coordinate candidate | Use it only when registered for the task and verify the resulting state. |
| Browser chrome is blocked at a tab-strip context menu, but the ordinary app menu exposes an exact equivalent command | Exact App Shortcut plus browser-connector target selection/readback | Promote the static menu command to an app-scoped actuator, revalidate contextual enablement, and verify the browser-native result. |

## Positive and negative examples

- Read `AppleKeyboardUIMode`: use `/usr/bin/defaults read`; the direct read fully covers the
  fact and is faster than daemon-backed control.
- Move focus to the next control in System Settings: use atomic `macctl control perform
  next-control --app "System Settings" --confirm --json`; there is no mature direct interface
  for that visible focus transition.
- Activate a known Save button in a native app: use semantic Accessibility with the button's
  stable role and title before sequential Tab navigation.
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
- `control.batch` is deliberately not a universal action ladder. It rejects semantic scroll,
  stops on the first unverified step, and always reports completed count and lease release.
- Full Keyboard Access or a required TCC grant is missing: report `blocked` and the exact user
  action. Do not silently enable or bypass it.

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
latencies cover daemon route execution, not CLI process or socket startup.

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

## Evidence basis

The 2026-08-02 local benchmark found that a direct preference read beat Mac Control for a
structured fact, while atomic Mac Control focus navigation beat generic GUI control for a
workflow without a mature direct interface. Treat those timings as host-specific evidence,
not a universal constant. Persist new measurements under the exact app/task/version/target
manifest and rebenchmark when the control surface or provider runtime changes.
