# Canonical implementation examples

Use these maintained surfaces as references rather than copying ad hoc code:

- `Sources/MacCtlCore/ReleaseGate.swift` — deterministic, fail-closed checks
  with reasoned JSON evidence.
- `Sources/MacCtlCore/ReceiptStore.swift` — atomic, redacted, owner-only,
  retention-bounded evidence storage.
- `Sources/MacCtlCore/WorkflowValidator.swift` — conservative workflow and
  focus-policy validation before approval.
- `Sources/MacCtlCore/ApprovalStore.swift` — short-lived, single-use approval
  lifecycle and explicit expiry/denial states.
- `docs/TIER1_RELEASE.md` — canonical release evidence and manual live-check
  contract.

An implementation is canonical when it preserves the package boundary,
returns a stable status/reason, records provenance without sensitive payloads,
and has a focused regression test. Do not treat a passing unit test as proof
of a live TCC, launchd, Aqua, or installed-app condition.
