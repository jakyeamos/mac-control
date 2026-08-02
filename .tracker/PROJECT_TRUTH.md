# PROJECT_TRUTH.md

## summary

macctl's packaged daemon, owner-only Unix transport, stable bundle identity,
daemon permissions, and receipt storage are live and healthy. The current
foreground-only iPhone Mirroring validation was able to connect to a running
Mirroring window after the iPhone was locked, but the Tinder smoke was blocked
because Tinder was not visible through OCR. The read-only Tier-1 release gate
then reported `passed=false` with `blockerCount=4`.

The source checkout was already dirty before this validation. A bounded host
SwiftPM test against that current working tree completed its debug build but
executed 56 tests with 2 failures in the same checkpoint start-time test. This
source/test result is separate from the live-device blocker and from the
installed daemon's receipt freshness.

## nextStep

Make Tinder visible in the active iPhone Mirroring session, then rerun the
user-gated foreground-only `iphone.open-tinder` workflow with the short-lived
driving lease and rerun `macctl release check --json`. Separately refresh the
missing Mac GUI, keyboard, and approval receipts before treating the Tier-1
gate as complete. Investigate the reproducible checkpoint timestamp test
failure before claiming the current dirty source is green. Rerun the TMCP
local-product re-score only after the release evidence is refreshed.

## blockers

- `live.iphone-mirroring` remains blocked: `iphone.status` reported an
  available, foreground Mirroring window, but workflow operation
  `573832CB-F98D-4734-BC91-554B7FE7FF2D` ended `blocked` with
  `The mirrored iPhone app was not visible through OCR: Tinder`. The driving
  lease was acquired and released successfully; no swipe, message, purchase,
  submission, or account-changing action was performed.
- The current release gate also reports missing fresh evidence for
  `live.mac-workflows` (Finder, TextEdit, System Settings, Google Chrome, and
  Notes), `live.keyboard-control` (Full Keyboard Access, lease acquisition,
  named navigation, focus inspection, and lease release/expiry), and
  `approval.safety` (prepared, HUD-approved, HUD-denied, expired, and direct
  fail-closed evidence). These are receipt-freshness/live-GUI blockers, not
  source-test results.
- Current source/test status is not green: `swift test` completed the debug
  build, then executed 56 tests with 2 failures at
  `Tests/MacCtlCoreTests/MacCtlCoreTests.swift:1749` and `:1763` in
  `testInterruptedRunningCheckpointRequiresExplicitResumeAndPreservesStartTime`.
  A focused rerun reproduced both failures. The observed mismatch is between
  a persisted and in-memory `Date`; the likely local cause is the
  `JSONCodec` ISO-8601 round-trip losing subsecond precision, pending a fix or
  explicit test disposition.

## risks

- The installed daemon and the dirty source checkout are not proven to be the
  same build; do not infer release behavior from source tests or source diffs
  alone.
- TCC authorization remains user-controlled and can require migration if the
  signing certificate, bundle identifier, or install path changes.
- iPhone Mirroring is session-, foreground-, window-, input-, and OCR-dependent;
  no Tinder action beyond foreground/visibility verification is permitted.
- Missing or stale receipt evidence must not be replaced with synthetic
  receipts. Background, keyboard, approval, and Mac GUI evidence each remain
  separate proof layers.

## lastUpdated

2026-07-30

## quality

| check | status | evidence |
| --- | --- | --- |
| formatter/lint | not configured | Swift package has no formatter/linter dependency |
| typecheck/build | passed for debug test build | `swift test --scratch-path /private/tmp/mac-control-source-test.B526Et`; build completed; no release build run |
| tests | failed | 56 tests, 2 failures; focused rerun reproduced the same 2 checkpoint timestamp assertions |
| pre-commit readiness | not run | Current checkout is dirty and no pre-commit gate was requested |
| environment contract | historical only | Prior contract evidence is stale relative to the current dirty context files |
| launchd/socket/transport | passed | Release check: packaged LaunchAgent, owner-only AF_UNIX socket, no network listener |
| receipt storage | passed | `receipts status`: owner-only storage, 305 files, invalid 0, pending prune 0, writable |
| daemon permissions | passed | Release check confirms daemon permission context; receipt permissions report all required grants |
| Mac live smokes | blocked | Release check missing fresh Finder/TextEdit/System Settings/Chrome/Notes receipts |
| iPhone Mirroring | blocked | Mirroring status available; Tinder workflow blocked by OCR visibility; no successful fresh receipt |
| keyboard-first GUI | blocked | Release check missing Full Keyboard Access and all required keyboard smoke evidence |
| approval/HUD/Caps Lock | blocked | Release check missing prepared, HUD approve/deny, expiry, and direct fail-closed evidence |
| Tier-1 release gate | blocked | `blockerCount=4`, `passed=false`, generated `2026-07-30T23:13:01Z` |
| TMCP local-product re-score | pending | Rerun after live release evidence and source/test disposition are refreshed |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: `/Users/jakyeamos/projects/mac-control`
- Branch: `dev`; working tree was dirty before this validation
- CLI: `/Users/jakyeamos/.local/bin/macctl`
- Daemon bundle: `/Users/jakyeamos/.local/share/macctl/macctld.app`
- Socket: `/Users/jakyeamos/Library/Application Support/macctl/macctld.sock`
- Receipts: `/Users/jakyeamos/Library/Application Support/macctl/receipts/`
- Runtime receipt evidence: packaged `com.jakyeamos.macctl.daemon`, signed
  Apple Development identity, process `48187` observed during the live run

## Current Position

- `iphone status` operation `98F6BB96-1EAC-491B-86D2-ABB47D833AAF` succeeded:
  `connectionStatus=available`, `installed=true`, `running=true`,
  `foreground=true`, and `windowDetected=true`.
- Driving lease operation `9C6C52F6-BD91-4E30-B925-2A950538F511` succeeded and
  release operation `669FA92D-15D7-4024-AADF-BDA7F2752A94` succeeded. The lease
  token was not persisted here.
- Foreground workflow `iphone.open-tinder` ran with `focusPolicy=foreground`
  and ended blocked at `2026-07-30T23:12:49Z` with no evidence kinds recorded.
- The release gate passed identity, socket, local-only transport, daemon
  identity, permissions, and receipt storage, while blocking the four live
  evidence dimensions listed above.
- `git diff --check` passed. No source implementation or test fix was made as
  part of this evidence run.

## Recent Progress

- Ran the documented foreground-only Tinder smoke after the iPhone was locked;
  Mirroring connected, OCR visibility did not.
- Released the Mirroring driving lease immediately after the smoke.
- Ran the requested read-only `macctl release check --json` and captured its
  four-blocker result.
- Ran a host SwiftPM source check in a disposable scratch directory; the build
  completed, but the current checkpoint timestamp test failed reproducibly.
