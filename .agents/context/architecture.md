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

The workflow boundary is `prepare -> approve -> execute -> verify`. Receipts
are the durable evidence boundary. TCC permissions, launchd, and the Aqua
session remain user-controlled external systems; unsupported providers are not
silently substituted into this boundary.

Credential and permission prompts use a separate explanatory boundary:
`control.authorization.prepare -> bind -> list -> resolve`. Authorization notices are
short-lived, bounded, owner-only records and are never workflow approval tokens. The daemon
keeps caller-declared project/thread/helper metadata separate from the observed Unix-socket
peer identity and reports `attested`, `declared`, or `unverified` provenance. The Control
Center can surface context and a registered Codex source opener, but it cannot approve or deny
the native macOS prompt. External, unannounced dialogs remain outside Mac Control attribution.

Rendered web content is a provider boundary, not a second macOS focus model.
`target_surface=web_content` produces a typed `browser_dom`/`cdp_dom` handoff
before any browser activation; the browser provider owns connector health,
exact tab/frame identity, dispatch, and DOM readback. Browser chrome and native
dialogs remain macOS app UI. Background native execution is admitted only for
one named process and a selector- or manifest-addressed route whose foreground
preservation and postcondition can be checked.

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

The Control Center has two distinct focus signals. `Focusing` and `Focused` are
short one-shot notices emitted around a foreground handoff. A caller that needs
the user to remain hands-off across a run must explicitly own a bounded
hands-off session, pass its opaque ID through native actions and provider
handoffs, heartbeat it, and end it. The persistent `Hands Off` state clears on
end, expiry, Stop & Release, or daemon shutdown; it is never inferred from an
individual action. Physical keyboard `Frozen` remains the higher-salience state.

Capability discovery has a separate boundary: fast route probe -> cached broad
profile -> task-specific verification -> profile update or invalidation. The
broad audit may infer redacted, generic `capabilityLeads` from app-owned
menus, controls, dialogs, help, onboarding, and accessibility disclosures, but
those leads are candidate planning evidence only. They never dispatch input or
admit a route without independent measured-route evidence.

Do not make AIOS, Career Ops, a remote API, or a TCP listener a runtime
dependency. Callers may invoke this local control plane; ownership of their
workflow and credentials remains outside this repository.
