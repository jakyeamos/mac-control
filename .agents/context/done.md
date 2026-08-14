# Definition of done

A change is complete only when:

1. The affected behavior has focused XCTest coverage or an explicit live-gate
   evidence requirement.
2. `swift build`, `swift test`, and
   `python3 scripts/check_environment_contract.py` pass from the intended
   checkout; run coverage when the change affects measured behavior.
3. Approval, redaction, transport, and fail-closed boundaries remain intact.
4. Required receipts, status/reason fields, and provenance are present for
   observable behavior.
   Cross-provider browser handoffs additionally require a joined trace with
   explicit per-provider provenance, redaction, bounded replay protection, and
   foreground/latency metrics; separate uncorrelated receipts are partial.
5. `macctl release check --json` is rerun for release-facing changes. Missing
   user-controlled evidence remains `blocked` and is recorded as such.
6. The diff is reviewed for unintended target, credential, generated-file,
   deployment, and private-data changes.
7. The implementation commit and the corresponding live project snapshot are
   separate coherent commits.

For native window placement, completion additionally requires live packaged-
daemon evidence for one successful placement and restore, plus negative evidence
for confirmation, token replay, and an unavailable display. Multi-monitor
support is behavior-verified only after a real second display run; geometry
tests and a single-display run remain source evidence, not multi-monitor proof.

The acceptance claim must distinguish source tests, local daemon evidence, and
manual GUI/device evidence. No synthetic receipt, guessed permission, or
unverified public claim satisfies this definition.
