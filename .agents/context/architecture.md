# Architecture and boundaries

`macctl` is a command-first local macOS control plane. The `MacCtlCore`
library owns workflow validation, approval plans, receipts, release checks,
and platform adapters. `macctl` is the user-facing CLI. `macctld` is the
per-user daemon that owns the GUI session and serves an owner-only Unix socket.

The daemon is the authority for live permissions, transport, receipt storage,
and execution. The CLI may prepare, request, and inspect operations but must
not bypass daemon validation. Apple frameworks are the platform boundary:
AppKit, ApplicationServices, CoreGraphics, ScreenCaptureKit, Vision, and
Foundation. There are no third-party runtime dependencies in the baseline.

Native window placement is a daemon-owned Accessibility boundary. The display
catalog preserves Core Graphics display identity and converts AppKit usable
insets into Accessibility coordinates. The public surface accepts named layouts
only. A placement binds one foreground process and focused-window identity,
performs one position/size dispatch, and requires frame and destination-display
readback. Its in-memory restore authority is short-lived, single-use, and bound
to the original process, window digest, frame, and display; it is not durable
workflow approval or a third-party window-manager adapter.

Read-only native targeting resolves process identity before Accessibility
traversal. `app.instances` enumerates regular registered GUI processes
and returns a launch-bound opaque `instance_ref`; `app.bind --app <expected>
--process-id <pid>` additionally admits a same-user process discovered by PID,
keeps the expected app name/path conjunctive, and independently proves that
the exact PID exposes an addressable `AXApplication` root. Process discovery,
daemon health, and Accessibility permission are not substitutes for that probe.
An unbundled process whose AX root is unavailable is typed as
`development_binary_not_registered_as_accessibility_application` with a
registered `.app` development fallback; installed app support is unchanged.
`window.list` returns title-free opaque
`window_ref` values within one resolved PID. Every supplied app, PID, instance,
and window field is conjunctive. Ambiguity, disappearance, PID reuse, or stale
window identity fails closed without falling back to the first bundle match,
focused process, or focused window. These discovery routes never activate or
mutate a window.

The agent action front door is a separate, narrow background boundary:
`action.resolve` accepts one declarative safe `press` intent bound to the exact
application, PID, `instance_ref`, `window_ref`, stable control identity, and
desired-state selector. It requires `focus_policy=background` and
`foreground_budget=0`. The daemon resolves the whole target from fresh state,
records only opaque/redacted identity in an event-invalidated in-memory graph,
and returns a short-lived one-shot resolution. `action.run` consumes that
resolution before dispatch, re-resolves every identity, performs exactly one
window-scoped `AXPress`, and succeeds only after fresh desired-state readback
while the unrelated foreground PID remains unchanged. Ambiguity,
disappearance, PID replacement, graph invalidation, foreground change, or
unavailable verification fails closed. There is no activation, keyboard,
pointer, arbitrary AX action, replay, app-level fallback, or persistent AX
handle in this surface.
Because an AX server may return a non-success status after accepting a press,
the native status is dispatch evidence, not completion evidence. The daemon
never retries it: a subsequently observed desired state is
`indeterminate_but_verified`; absent desired state is terminal indeterminate.

A different exact mutation boundary exists inside an approved foreground task: the daemon
acquires the exclusive task keyboard lease, requests activation from the exact
`NSRunningApplication` PID, raises only AX objects created for that PID, and
blocks input until NSWorkspace reports that PID as
frontmost while AX independently reports the requested window digest as the
focused window. The plan must be sensitive, strict, single-attempt, and include
an exact-window `element_exists` postcondition. A pre-dispatch identity or
oracle failure is blocked; a race after dispatch is indeterminate and never
retried. That route does not broaden the action front door or expose an app-level fallback.

The workflow boundary is `prepare -> approve -> execute -> verify`. Receipts
are the durable evidence boundary. TCC permissions, launchd, and the Aqua
session remain user-controlled external systems; unsupported providers are not
silently substituted into this boundary.

Local sibling providers may use `approval.external.prepare -> status -> consume`
for the same human-decision boundary without receiving Mac Control's private
approval token. The daemon retains a session-only record bound to the exact
provider, provider instance, plan ID, and SHA-256 plan digest. Human review uses
the existing owner-only `macctl approval list|approve|deny` lifecycle; denial,
expiry, binding mismatch, and replay fail closed. The transient menu-bar safety
item remains outside this queue.

Credential and permission prompts use a separate explanatory boundary:
`control.authorization.prepare -> bind -> list -> resolve`. Authorization notices are
short-lived, bounded, owner-only records and are never workflow approval tokens. The daemon
keeps caller-declared project/thread/helper metadata separate from the observed Unix-socket
peer identity and reports `attested`, `declared`, or `unverified` provenance. The daemon exposes
that context through the CLI only; the transient safety item does not present authorization
notices or open their sources. External, unannounced dialogs remain outside Mac Control
attribution.

Rendered web content is a provider boundary, not a second macOS focus model.
`target_surface=web_content` produces a typed `browser_dom`/`cdp_dom` handoff
before any browser activation; the browser provider owns connector health,
exact tab/frame identity, dispatch, and DOM readback. Browser chrome and native
dialogs remain macOS app UI. Background native execution is admitted only for
one named process and a selector- or manifest-addressed route whose foreground
preservation and postcondition can be checked.

The CLI keeps the browser handoff local, then opens a separate owner-socket
trace with `receipts.trace.begin`; it never sends the original web-content
mutation to the daemon. The daemon records the Mac Control routing observation,
returns a short-lived completion credential, and accepts one bounded
`receipts.trace.complete` observation after browser readback. Raw provider IDs
are hashed before persistence. The joined view from `receipts.trace` preserves
provider-specific provenance: Mac Control routing is `mac_control_attested`,
while browser completion is `orchestrator_declared` until a browser-owned
attestation interface exists.

The VS Code Problems route is a native adapter boundary rather than a keyboard
workflow. A disposable same-bundle fixture identifies one workspace, profile,
extension, window title, bundle, and PID. Its extension writes only a fresh,
redacted diagnostics summary sourced from `vscode.languages.getDiagnostics`.
The daemon verifies the exact identity and digest before returning the summary;
it never uses the fixture as proof of frontmost/focus or visual acceptance.

Focus routing is background-first and foreground-on-demand. Agent-facing CLI
requests default to `automatic`: the daemon selects a verified background route
when the exact workflow, task, or app-open operation is eligible, otherwise it
immediately executes through the existing foreground authority. There is no
idle scheduler, focus queue, or focus-change batching. Explicit `background`
remains fail-closed and explicit `foreground` remains forced. The requested
policy stays in the approval digest; the effective policy is separate runtime
evidence (`requested_focus_policy`, `focus_policy`,
`focus_selection_reason`, and optional `background_unavailable_reason`). A
background failure after possible dispatch is never blindly replayed in the
foreground.

The menu-bar item is a transient safety surface. It stays hidden while idle and does not present
approval state, authorization notices, one-shot focus announcements, or completed task history.
It appears for active execution, a bounded hands-off session, physical keyboard suppression,
daemon lifecycle drain, or degraded health. A caller that needs the user to remain hands-off
across a run must explicitly own the session, pass its opaque ID through native actions and
provider handoffs, heartbeat it, and end it. The visible `Hands Off` state clears on end, expiry,
Stop & Release, or daemon shutdown; it is never inferred from an individual action. General
attention and focus-change announcements are owned by the independent attention provider.

Capability discovery has a separate boundary: fast route probe -> cached broad
profile -> task-specific verification -> profile update or invalidation. The
broad audit may infer redacted, generic `capabilityLeads` from app-owned
menus, controls, dialogs, help, onboarding, and accessibility disclosures, but
those leads are candidate planning evidence only. They never dispatch input or
admit a route without independent measured-route evidence.

`control.capability_verify` is the bounded task-specific observation edge in that
sequence. It reads a fresh redacted Accessibility tree for one already-running
native app, matches structural selector fields, and requires both a precise
postcondition kind and SHA-256 digest before returning `ready_for_measurement`.
It never launches, activates, dispatches input, promotes a profile, or replays a
native action. Missing, incomplete, ambiguous, presentation-only, unsupported,
or unobserved targets remain candidates and carry a fresh Computer Use handoff
with `native_action_replay_allowed=false`; rendered web content remains owned by
the browser provider.

Before that discovery boundary, `control limitations` exposes the local,
versioned call/no-call ledger. It records known direct-provider boundaries,
typed handoff-only cases, and constrained Mac Control routes so an agent does
not spend live-probe time rediscovering a known dead end. The ledger is static
routing guidance, not a capability profile, permission result, route authority,
or substitute for current task-specific verification.

The ledger has a separate contribution edge. `macctl control limitations propose --stdin` writes
one owner-only JSON candidate per observation under the local limitation-proposals directory;
`macctl control limitations proposals` reads that append-only store. The store assigns identity
and time, forces candidates to `unproven`, and is intentionally local-only rather than a daemon
execution method. Candidates never override the reviewed ledger or authorize a route. Promotion
is a reviewed source-controlled change across the ledger, agent contract, skill, and tests.

Do not make AIOS, Career Ops, a remote API, or a TCP listener a runtime
dependency. Callers may invoke this local control plane; ownership of their
workflow and credentials remains outside this repository.
