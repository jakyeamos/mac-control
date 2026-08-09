# macctl Tier-1 local-product gate

This repository uses a project-scoped local-product policy. The applicable
release dimensions are governance/policy, security/privacy,
auditability/provenance, operational release readiness, and
accessibility/public use. `legal_calculation_safety` is explicitly **N/A**:
macctl has no legal or calculation subsystem, does not calculate legal
outcomes, and does not publish legal advice.

## Required evidence

Run the following after building and installing the packaged daemon:

```sh
swift build
swift test
~/.local/bin/macctl doctor --json
~/.local/bin/macctl capabilities --json
~/.local/bin/macctl status --json
~/.local/bin/macctl receipts status --json
~/.local/bin/macctl release check --json
```

`release check` is read-only. It fails closed when launchd identity, daemon
permissions, socket ownership, receipt storage, approval safety, Mac GUI
smokes are missing. It does not launch a workflow or alter a device to
manufacture evidence.

The release report also includes `agent.contract`. That check requires the
provider-neutral outcome surface, capability discovery, bounded control batch,
and daemon-executed route-benchmark provenance to be present in the live daemon
capability report. Passing it proves contract exposure only; it does not replace
the separate live GUI, task-control, keyboard, or approval-HUD evidence
dimensions below.

## Stable daemon identity

The packaged daemon is installed at
`~/.local/share/macctl/macctld.app` and is signed with a persistent local
Apple Development or Developer ID Application identity. macctl stores the
selected certificate hash and name in
`~/Library/Application Support/macctl/signing-identity.json` with mode `0600`.
Each later install reuses that identity, so normal rebuilds replace the
executable without requiring another Accessibility, Input Monitoring, Post
Events, or Screen Recording grant. `MACCTL_CODESIGN_IDENTITY` may override the
stored selector with a certificate hash or exact name for an intentional
migration.

Installation fails closed when no persistent signing identity is available;
ad-hoc signing is not used. A certificate replacement, bundle identifier
change, or installation under a different path can still require a one-time
macOS permission migration.

## Evidence recorded by the daemon

Every request receives a durable receipt under
`~/Library/Application Support/macctl/receipts/`. A receipt includes the
operation/request IDs, method/workflow, target surface, risk, approval state,
execution result, verification result, plan digest, daemon runtime identity,
permission snapshot, status, redacted evidence kinds, and timestamps. It never
includes credentials, ephemeral input, OCR text, screenshots, image bytes,
message bodies, or selector values.

The receipt directory is owner-only (`0700`), receipt files are owner-only
(`0600`), writes are atomic, and retention is bounded to the newest 1,000
records. `macctl receipts list` and `macctl receipts status` are read-only
diagnostics.

## Manual live checks

The live gate requires a logged-in Aqua session and user-controlled privacy
permissions. Run the reversible Finder, TextEdit, System Settings, Google Chrome,
and Notes workflows. Missing GUI permissions, capture, input, window discovery,
or verification produces a blocked result.

Approval HUD approve/deny/expiry behavior and Caps Lock double-tap activation
must be exercised by a user in the GUI session using the built-in
`approval.smoke` workflow. That workflow waits for 0.2 seconds and performs no
external input or account change, but is classified as sensitive to exercise
the approval boundary. The release gate requires fresh receipts for:

```sh
~/.local/bin/macctl workflow prepare approval.smoke --json
~/.local/bin/macctl workflow run approval.smoke --json
```

The first command must be followed by a HUD approve, a second prepare followed
by a HUD deny, a third prepare left open until the 120-second token expires and
then an expiry attempt from the HUD or daemon CLI, and the second command must
be blocked because no approval token was supplied. Approve and deny receipts
must identify the HUD as their source; the expiry receipt may identify the HUD
or CLI because expiry is a backend state transition. Caps Lock only brings the
HUD forward and never approves an operation.

## Keyboard-first evidence

The keyboard release dimension is separate from generic workflow-key approval.
After Full Keyboard Access is enabled
by the user, the live smoke run is:

```sh
~/.local/bin/macctl keyboard status --json
~/.local/bin/macctl keyboard lease acquire \
  --scope app --app "Google Chrome" --seconds 30 --confirm --json
~/.local/bin/macctl keyboard navigate commands-help --lease-token "$TOKEN" --json
~/.local/bin/macctl keyboard inspect --json
~/.local/bin/macctl keyboard send escape --lease-token "$TOKEN" --json
~/.local/bin/macctl keyboard lease release "$TOKEN" --json
```

The Tier-1 gate requires fresh evidence for Full Keyboard Access status,
successful lease acquisition, named navigation, focused-element inspection,
lease release or expiry, and receipt redaction. Receipts may prove that an
operation occurred and which evidence kind it produced, but must not contain
raw keys, lease tokens, AX values, private text, screenshots, or OCR text.
Source XCTest results, daemon receipt evidence, and manual GUI response are
reported as distinct proof layers. The release check is read-only and never
manufactures keyboard evidence. Browser DOM automation remains outside this
surface.

The standard Tier-1 smoke intentionally uses the default `shared` physical
input mode. Physical keyboard suppression is an opt-in, session-only event-tap
capability and is not treated as live evidence until a human deliberately
exercises it. When testing that path, use a short lease and the mouse or the
status-item `Quit daemon` action as the recovery path:

```sh
~/.local/bin/macctl keyboard lease acquire \
  --scope session --seconds 30 --suppress-physical-keyboard \
  --reason "interactive keyboard freeze test" --confirm --json
```

The daemon emits the normal `keyboard_lease`,
`keyboard_physical_suppression`, and `keyboard_freeze` evidence so the
existing lease gate remains meaningful while the optional behavior is
identifiable. The compatibility alias is still session-only and reason-bound.

Semantic-control checks are available during manual GUI validation:

```sh
~/.local/bin/macctl control status --json
~/.local/bin/macctl control perform next-control --lease-token "$TOKEN" --json
```

The atomic app-scoped form owns activation and lease cleanup within one daemon
request, avoiding foreground handoff between separate client calls:

```sh
~/.local/bin/macctl control perform next-control \
  --app "System Settings" --confirm --json
```

These responses distinguish the selected route (`accessibility`, `keyboard`,
`visual`, `normalized_coordinate`, `raw_coordinate`, or `scroll`) from the
post-action verification state. A warm-path selection is eligible only when
the app identity/version, target fingerprint, permissions, freshness, and
verification oracle match. Only explicitly declared pre-action fallbacks may
run; ambiguous targets, possible side effects, and failed verification block
without retry. Raw and visual routes require manifest opt-in.

Tree and audit responses are bounded, redacted, local-only diagnostics. They
exclude AX values, private text, screenshots, and OCR, and receipts retain only
the evidence kind. Semantic scroll requires a unique `AXScrollArea` identifier
and re-resolves the container after the action.

`control.capabilities` is the latency-sensitive route probe: it may read a
cached broad profile but never walks the Accessibility tree. The separate
`control.capability_audit` surface performs one bounded, read-only AX/provider
audit and persists only stable, redacted locator descriptors keyed by app
identity/version, OS/provider state, and tree signature. It does not dispatch
actions and is not route-ranking authority.

`control.capability_audit_batch` is a separate bounded inventory surface. It
audits at most 24 explicit or catalog-selected installed apps, only when they
are already running; it serializes AX access, persists one redacted resumable
receipt per app, and never launches applications or dispatches input. An
unobserved app is resumable, not negative capability evidence.

When semantic scroll returns `scroll_fallback_required` or
`scroll_verification_unavailable`, the response contains a machine-readable
provider handoff. For `recommended_provider: computer_use`, the required
recovery is fresh `get_app_state`, fresh unique scroll-target lookup,
Computer Use `sky.scroll`, and post-scroll state verification. Ambiguous
targets and failed verification remain blocked; the release gate does not
count a dispatched input event as a successful scroll.

## Checkpointed task and adapter evidence

The task-control release dimension covers the structured `task.prepare`,
`task.run`, `task.status`, `task.resume`, and `task.cancel` methods plus the
allowlisted application-adapter manifests. A release candidate must show:

- a prepared approval bound to the exact plan, target, risk, recovery policy,
  and ephemeral-input digest;
- a completed safe task or an explicit blocked/paused result with a durable
  redacted checkpoint;
- fresh lease, permission, target, timeout, cancellation, and action-budget
  revalidation at each dispatch boundary;
- explicit fresh authority and a new approval for resume after interruption;
- adapter capability and Automation-permission diagnostics, including an
  unsupported-operation block; and
- receipts/checkpoints containing only task/step IDs, plan digest, route,
  recovery class, lifecycle state, hashes, timestamps, and redacted
  verification results.

The lifecycle states `paused`, `blocked`, `indeterminate`, `completed`,
`cancelled`, and `expired` must remain distinguishable. Safe recovery is
bounded to three attempts, reversible recovery to two, and sensitive actions
to one dispatch; an uncertain sensitive result is indeterminate and is never
retried. Automatic resume is disabled. The original plan is required again on
resume, and any mutation of it invalidates the previous approval.

The first adapter set is Finder, System Settings, Terminal, TextEdit, Preview,
Mail, Calendar, Notes, and Messages. Only declared typed operations may use
AppleScript/JXA routes; arbitrary script or shell execution is not exposed.
Read-only observation may be exercised without input authority, while every
adapter mutation shares keyboard leases and target revalidation. Browser DOM
automation remains outside this task surface.

For safe live proof, use a visible Finder/System Settings/TextEdit flow with
no private content, then a read-only adapter inspection or empty draft route
only when Automation permission is present. Record four layers separately:
XCTest results, daemon receipts, redacted checkpoints, and manual GUI response.
Do not use a successful source test or stale daemon receipt as proof that the
current Mac GUI responded. Missing Automation, ambiguous or stale targets,
expired authority, modal/unreadable focus, and unsupported operations are
valid blocked evidence.
