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
when iPhone Mirroring is active. The Tinder check verifies foreground/visible
state only; it does not swipe, message, purchase, submit, or change account
state. Missing Mirroring, capture, input, or window discovery produces a
blocked result.

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
