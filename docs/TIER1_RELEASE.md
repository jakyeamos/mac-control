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
permissions. Run the reversible Finder, TextEdit, System Settings, Safari, and
Notes workflows, then run the user-gated `iphone.open-tinder` workflow only
when iPhone Mirroring is active. The Tinder check verifies foreground/visible
state only; it does not swipe, message, purchase, submit, or change account
state. Missing Mirroring, capture, input, or window discovery produces a
blocked result.

Approval HUD approve/deny/expiry behavior and Caps Lock double-tap activation
must be exercised by a user in the GUI session. Caps Lock only brings the HUD
forward and never approves an operation.
