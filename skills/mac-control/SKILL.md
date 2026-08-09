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

Visual and coordinate candidates require explicit task-manifest opt-in. Only a declared
fallback may run after a pre-action target-not-found result. Stop on ambiguity, possible side
effects, action failure, or failed verification. Read [references/routing.md](references/routing.md)
when the route is ambiguous, the task spans applications, or the action carries approval or
private-input risk.

When a redacted Accessibility tree or ideal-state manifest exposes one unique
`AXTextField` with subrole `AXSearchField` alongside a repeated list, prefer the atomic
semantic `search` action with the declared `search_shortcut`/`keyboard` route before serial
navigation. The query is ephemeral and existing search text is replaced by default; the
action's verified completion is only `search_field_focused` after query entry. Finding,
selecting, or opening a result must be represented by a later declared predicate or action.
If the field is missing or ambiguous, or the named shortcut cannot be verified to focus the
declared field, stop and report the blocker or indeterminate result. Never fall back to
repeated `next-control`/Tab traversal.

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

## Execute the smallest verified action

For one visible action, use the atomic app-scoped form. It activates the target, waits for
stable foreground, creates an ephemeral lease, performs and verifies the action, and releases
the lease before returning. If the exact target process is already foreground, the daemon may
skip redundant activation, but it still performs the stable foreground reads and all lease,
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
owner-only receipts. It may read a cached broad profile, but never walks the Accessibility tree
or dispatches an action. Before reusing a locator, inspect matching blocker observations for the
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
the latency, p95, recovery, and freshness metadata. `macctl route register` remains an explicit
caller-supplied metadata path and is not equivalent to a live benchmark.
The benchmark response also reports `foreground_fast_path_samples`; its timings cover daemon
route execution rather than CLI process or socket startup.
For semantic scrolling, benchmark with `--action scroll --route scroll`, a unique `AXScrollArea`
selector, `--direction`, and `--amount`. An identifier is preferred but optional when role-only
resolution returns exactly one container. Repeated warmups or samples must declare the exact
opposite `--reset-direction` and bounded `--reset-amount`, so each measured scroll starts from a
known viewport state. The daemon measures the AX scroll route itself and persists no manifest when
any reset or measured invocation fails verification.

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
packaged daemon. The `agent.contract` check proves that outcomes, capability discovery,
  bounded batching, and daemon-executed route provenance are exposed. It does not prove that
  live Finder, browser, task-control, or approval-HUD workflows have been exercised; those
  remain separate user-controlled evidence dimensions.
