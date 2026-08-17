# Definition of done

A change is complete only when:

1. The affected behavior has focused XCTest coverage or an explicit live-gate
   evidence requirement.
2. `swift build`, `swift test`, and
   `python3 scripts/check_environment_contract.py` pass from the intended
   checkout; run coverage when the change affects measured behavior.
3. Agent-policy interruption, daemon execution enforcement, redaction,
   transport, and fail-closed boundaries remain intact.
4. Required receipts, status/reason fields, and provenance are present for
   observable behavior.
5. `macctl release check --json` is rerun for release-facing changes. Missing
   user-controlled evidence remains `blocked` and is recorded as such.
6. The diff is reviewed for unintended target, credential, generated-file,
   deployment, and private-data changes.
7. The implementation commit and the corresponding live project snapshot are
   separate coherent commits.

The acceptance claim must distinguish source tests, local daemon evidence, and
manual GUI/device evidence. No synthetic receipt, guessed permission, or
unverified public claim satisfies this definition.
