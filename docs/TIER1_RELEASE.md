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
smokes, or the iPhone Mirroring smoke is missing. It does not launch a workflow
or alter a device to manufacture evidence.

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
permissions. Run the reversible Finder, TextEdit, System Settings, Google Chrome, and
Notes workflows, then run the user-gated `iphone.open-tinder` workflow only
when iPhone Mirroring is active and the user has explicitly acquired the
short-lived driving lease. The lease is an in-memory handoff: after
`macctl iphone drive begin`, keep hands off the trackpad, pass the returned
token with `--driving-lease`, and release it with `macctl iphone drive end
<token>`. The daemon does not infer trackpad activity or claim hardware-level
input telemetry. The Tinder check verifies foreground/visible state only; it
does not swipe, message, purchase, submit, or change account state. Missing
Mirroring, capture, input, window discovery, or driving-lease coordination
produces a blocked result.

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

The keyboard release dimension is separate from generic workflow-key approval
and from iPhone Mirroring shared input. After Full Keyboard Access is enabled
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
surface, and iPhone Mirroring remains a separate shared-input product surface.

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
or `visual`) from the post-action verification state. The control session
revalidates the lease and foreground process before and after each action;
session leases may follow an app switch, while app leases fail closed. Raw
coordinate fallback is disabled unless the request explicitly opts in.

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
automation and iPhone Mirroring remain outside this task surface.

For safe live proof, use a visible Finder/System Settings/TextEdit flow with
no private content, then a read-only adapter inspection or empty draft route
only when Automation permission is present. Record four layers separately:
XCTest results, daemon receipts, redacted checkpoints, and manual GUI response.
Do not use a successful source test or stale daemon receipt as proof that the
current Mac GUI responded. Missing Automation, ambiguous or stale targets,
expired authority, modal/unreadable focus, and unsupported operations are
valid blocked evidence.
