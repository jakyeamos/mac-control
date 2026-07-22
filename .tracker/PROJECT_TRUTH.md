# PROJECT_TRUTH.md

## summary

Tier-1 local-product hardening plus stable daemon signing is implemented in
commit `81924c8` on `dev`. The packaged `macctld.app` is the active launchd
executable, signed by the persistent Apple Development identity
`2C99DA3591BF6BD4BA2E0D8B552933E35BADD8D3`, and the daemon uses an owner-only
AF_UNIX socket with durable/redacted receipts. Accessibility, Input Monitoring,
Post Events, and Screen Recording were re-registered once for that identity and
remained granted after a fresh rebuild, reinstall, and launchd restart. The
receipt lifecycle now preserves prepare, approval, denial, and expiry evidence
as separate records, and the approval safety gate passes with fresh evidence.
The approval HUD now schedules token-scoped expiry and removes the panel when a
pending approval expires, implemented in commit `de7d5f4`.
The verified gate remains blocked only by the physical iPhone Mirroring/Tinder
smoke. AIOS and career-ops were not modified.

## nextStep

Lock the physical iPhone so the active consumer Mirroring session can connect,
then run the user-gated `iphone.open-tinder` foreground-only workflow. Rerun
`macctl release check --json` and the TMCP local-product re-score after the
fresh Tinder receipt exists. Normal rebuilds and reinstalls can now reuse the
persisted signing identity without another TCC grant, provided the certificate,
bundle ID, and installation path stay stable.

## blockers

- `macctl release check --json` is blocked with 1 check: fresh
  `iphone.open-tinder` evidence is missing because iPhone Mirroring reports
  that the iPhone is in use and must be locked to connect.
- Finder, TextEdit, System Settings, Google Chrome, and Notes workflows pass
  with fresh evidence. Approval HUD, denial, expiry, and fail-closed evidence
  now pass the release gate; Caps Lock timing/state-preservation remains covered
  by the unit test contract.

## risks

- TCC authorization is user-controlled and can require migration if the signing
  certificate, bundle identifier, or installation path changes; unchanged
  stable-signed rebuilds were verified to retain the grants.
- iPhone Mirroring is session- and window-discovery-dependent; no Tinder action
  beyond foreground/visibility verification is permitted.
- Scriptable-app and custom-rendered-app live evidence must not be
  represented by synthetic receipts.

## lastUpdated

2026-07-22

## quality

| check | status | evidence |
| --- | --- | --- |
| formatter/lint | not configured | Swift package has no formatter/linter dependency |
| typecheck/build | passed | `swift build -c release` completed successfully for `de7d5f4` |
| tests | passed | `./scripts/test-with-coverage.sh`: 22 tests, 0 failures |
| pre-commit readiness | passed | commit `de7d5f4` Pre-CR gate passed |
| launchd/socket/transport | passed | Apple Development identity active; socket mode 0600; no TCP listener |
| receipt storage | passed | owner-only 0700/0600, atomic writes, retention 1,000, 143 files, invalid count 0, pending prune 0 |
| daemon permissions | passed | daemon-authoritative doctor reports Accessibility/Input Monitoring/Post Events/Screen Recording granted after reinstall |
| Mac live smokes | passed | Finder/TextEdit/System Settings/Google Chrome/Notes passed |
| iPhone Mirroring | blocked | Mirroring window detected but connection is paused because the iPhone is in use; lock it and rerun the foreground-only Tinder smoke |
| approval/HUD/Caps Lock | passed | `approval.smoke` prepare, HUD approve/deny, expiry, and direct fail-closed evidence are fresh; Caps Lock timing/state-preservation tests pass |
| Tier-1 release gate | blocked | `blockerCount=1`, `passed=false`, generated 2026-07-22T17:08:23Z; only `live.iphone-mirroring` is blocked |
| TMCP local-product re-score | pending | rerun after the two remaining live evidence blockers are cleared; prior blocked receipt remains `tmcp-review-plan-b25509ba` |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: `dev`
- Latest implementation commit: `de7d5f4`
- Runtime: Swift Package Manager, macOS native frameworks first
- CLI: `/Users/jakyeamos/.local/bin/macctl`
- Daemon bundle: `/Users/jakyeamos/.local/share/macctl/macctld.app`
- Daemon executable: `/Users/jakyeamos/.local/share/macctl/macctld.app/Contents/MacOS/macctld`
- Signing selector: `/Users/jakyeamos/Library/Application Support/macctl/signing-identity.json` (mode 0600)
- Signing identity: Apple Development: jason.b.amos@gmail.com (49B2F5JPK8), TeamIdentifier `L57266QNR3`
- LaunchAgent: `~/Library/LaunchAgents/com.jakyeamos.macctl.daemon.plist`
- Socket: `~/Library/Application Support/macctl/macctld.sock` with mode 0600
- Receipts: `~/Library/Application Support/macctl/receipts/` with mode 0700 and files mode 0600
- Log: `~/Library/Logs/macctl/macctld.log` with mode 0600
- Scope: local CLI, per-user daemon, app/Accessibility/CGEvent control,
  screenshot/OCR/image-anchor fallback, approval HUD/menu-bar/Caps Lock
  front-door, workflows, receipts, release gate, and consumer iPhone Mirroring
  adapter

## Current Position

The packaged daemon is installed and loaded in the logged-in Aqua session. The
last verified launchd status matched the packaged executable and bundle identity
with PID 10958; the daemon answered through the owner-only socket and retained
all four required TCC grants after reinstall. Receipt storage is healthy and the
approval safety evidence is complete. No changes were pushed. Release readiness
remains blocked by the live iPhone condition recorded above, not by stale
metadata. The source-only ApprovalHUD expiry fix was built and tested, but the
packaged daemon was not reinstalled in this turn, so live GUI evidence still
refers to the prior installed build. Final TMCP artifacts are in
`/private/tmp/macctl-tmcp-tier1-final-local/`; the advisory TMCP receipt is
`/Users/jakyeamos/.tmcp/receipts/2026-07/tmcp-review-plan-b25509ba-dcc090fbb1386edb0eddec27dd93f662-1c251938a5-f145b4cdee644a84b032bfb99f94ffc8.json`.

## Recent Progress

- Added launchd `bootout -> bootstrap -> print` reconciliation and runtime identity checks.
- Made doctor/status permission and runtime reporting daemon-authoritative and fail closed when unavailable.
- Added schema-versioned atomic redacted receipts, backward-compatible decoding, retention, listing, diagnostics, and operation/request-keyed lifecycle records.
- Added the machine-readable Tier-1 release gate for identity, transport, TCC, receipts, live smokes, iPhone Mirroring, and approval safety.
- Added local-product policy documentation with explicit legal-calculation N/A mapping.
- Rebuilt and installed the packaged binaries; verified launchd identity, socket ownership, and receipt compliance.
- Recorded fresh successful Finder, TextEdit, System Settings, Google Chrome, and Notes receipts.
- Added the no-input `approval.smoke` workflow and recorded fresh prepared, HUD-approved, HUD-denied, expired, and direct fail-closed evidence.
- Added precise iPhone Mirroring recovery diagnostics; current state is safely blocked until the physical iPhone is locked.
- Replaced ad-hoc signing with a persisted Apple Development identity; re-registered the four daemon permissions once and verified they survived a fresh build/install/restart cycle.
- Ran `swift test` with 22/22 passing and committed the implementation as `81924c8`.
- Refreshed the Tier-1 gate: `blockerCount=1`; approval evidence now passes and only iPhone Mirroring Tinder evidence remains.
- Ran the final TMCP `expert_rubric_remediation_v1` review against the local-product/public-sector rubric; the blocked score and explicit legal-calculation N/A mapping are recorded in `/private/tmp/macctl-tmcp-tier1-final-local/`.
- Added automatic ApprovalHUD dismissal at approval-token expiry and committed it as `de7d5f4`; release build, coverage tests, and Pre-CR passed.
