# Scoped adapter discovery

Implementation scope: the existing VS Code `diagnostics.summary` read operation.
The operation owns its invocation contract and parameter validation. Discovery
may inspect the existing redacted fixture reader; it never grants execution
authority or establishes visual Problems-panel acceptance.

## Change custody

- Lane: `short_lived`, because this changes a public machine-readable schema.
- Owner: Codex chat `01a1a263-93dd-7221-90eb-061027277ed6`.
- Base: `4578f7108be7423c68b888887ce0cd8233f261cd`; integration target: `dev`.
- Preserve the original checkout's untracked `.quality-runner/` evidence.
- Fold condition: reviewed implementation, required source and live command
  checks, exact-current Quality Runner release eligibility, and projection checks.

## Test value (recorded before test changes)

| Test | Protected behavior and credible regression | Oracle and coverage gap | Durability and cost |
| --- | --- | --- | --- |
| Fresh fixture discovery to invocation (extend existing positive fixture test) | An agent can form the advertised request and receive the redacted counts; schema edits could drift from execution. | Independent fixture has one error and one warning; compare actual result fields to advertised types. Existing test reaches only the reader. | Public service boundary, tiny filesystem fixture; no UI timing or implementation snapshots. |
| Scoped discovery and blockers | An adapter filter must exclude unrelated apps; absent context must not be advertised as runnable; stale/missing fixtures must carry stable blockers. Filtering and status mapping can accidentally promote declarations to availability. | Explicit requested scope, missing descriptor, and controlled stale reader outcomes. Existing tests do not cover discovery. | Public request/response seam; deterministic injected reader, no network. |
| Shared parameter admission | Execution and task validation must reject the same invalid fixture IDs, ages, and caller-supplied snapshots. Separate validation previously allowed drift. | Public documented bounds and forbidden payloads; existing tests cover reader checks, not both entry points. | Small table at service/task boundaries; no generic JSON Schema engine or source-text assertions. |

The fresh-fixture test also makes the snapshot stale after discovery and checks
that the previously advertised invocation is blocked, protecting against reuse
of a discovery result as cached execution authority. This adds one file write
and one service call using the same independent clock/fixture oracle.

Legacy unfiltered catalog shape and legacy operation decoding remain covered by
existing tests and direct CLI comparison. No new benchmark suite is required;
record bounded live payload size/call-count evidence without claiming general
latency improvement.

## Consumer workflow

```sh
macctl adapter capabilities --adapter-id vscode --operation diagnostics.summary --json
macctl adapter capabilities --adapter-id vscode --operation diagnostics.summary --fixture-id <id> --json
macctl adapter diagnostics --adapter-id vscode --fixture-id <id> --json
```

The first response declares the invocation contract; it does not inspect a
fixture. With an exact fixture, discovery reports `available` or a stable
`blocked` reason. A consumer can obtain the method, CLI template, parameter
constants, required fields, defaults, and successful result schema from the
operation's `contract`. The schemas describe method parameters and the response
`result`, not the outer transport envelope.

Discovery does not create a fixture, refresh its snapshot, activate VS Code,
grant permission, or cache authority. A snapshot can expire between discovery
and execution. The read repeats the same identity, freshness, and redaction
checks and returns `stale_snapshot` when necessary. Other adapters remain
`unverified` until they own a complete invocation contract.

## Decisions and limits

- Reuse `adapter capabilities` instead of adding another registry or an SDK.
  The existing adapter owns the schema, validator, and read path; this avoids
  duplicate operation catalogs. Confidence is high for this bounded fixture;
  generalizing to other adapters remains separate work.
- Use the existing normalized running-application catalog for exact PID and
  bundle matching. The fixture reader still checks the expected application
  path and workspace identity. No Accessibility or input route is added.
- Keep availability advisory. A successful declaration or probe never replaces
  execution checks, task approvals, or visual acceptance evidence.
- Extend the accepted Compass source association for the new discovery source
  and directly affected documentation. This is necessary consequence closure
  within the existing product intent; no child draft, new purpose, or persistent
  service is accepted by that metadata change.
- The change is additive at the catalog boundary. Reverting the implementation
  removes scoped discovery; existing unfiltered consumers retain `manifests`
  and `automation_permissions`, and legacy operations decode without a contract.

## Verification snapshot: 2026-11-03

- All 344 Swift tests passed with coverage enabled; the coverage script also
  passed 55 benchmark-fixture and seven skill tests. The environment check and
  skill structural validator passed.
- A fresh CLI consumer, given only discovery metadata and a disposable fixture
  ID, constructed the advertised command and read one error, warning,
  information item, and hint. Invalid age was rejected; reusing the same command
  after expiry returned `stale_snapshot`. Missing-fixture discovery remained a
  typed blocker. This is a fresh-process workflow check, not an independent
  language-model trigger evaluation.
- The live scoped result was 3,320 serialized bytes. Payload reduction is
  bounded to this fixture/catalog comparison; no latency claim is established.
- One earlier coverage run was invalidated when fixture startup changed the
  foreground during a focus-preservation test. Rerunning with stable foreground
  passed; the test and focus policy were not weakened.
- Source CLI checks used the permitted local read-only fallback because the
  installed LaunchAgent was not registered. Native semantic readback does not
  establish running-daemon parity, keyboard authority, or visual Problems-panel
  acceptance. Persistent registration remains a separate owner-controlled step.
- Pronto's exact repository route was blocked by an expired inventory scan and
  two historical workspaces whose ownership could not be established. Those
  records were preserved; direct source, custody, and Compass checks remain
  separate evidence. The unavailable Attentiond skill was not reconstructed.

Authoritative Quality Runner, installed command/skill projection, and final
integration receipts are recorded in the task handoff. This snapshot does not
promote missing live Tier-1 release evidence to passing.
