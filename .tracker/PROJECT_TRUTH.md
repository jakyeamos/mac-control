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
as separate redacted operation records. The latest gate status is recorded
below and must be treated as authoritative for release readiness.
The isolated `macctl/mirroring-focus-fix` slice hardens window focus, Spotlight
field targeting, off-screen recovery, and physical-keycode typing; its live
Tinder smoke remains unverified because another active Codex task is driving
the shared Mirroring surface. The latest release check also could not reach the
daemon-authoritative doctor/status endpoints, so the current gate is not
admissible even though launchd still reports the packaged daemon running. AIOS
and career-ops were not modified.

## nextStep

Wait until the concurrent Mac UI task has released the Mirroring surface and
the daemon socket is responsive. Integrate this branch, reverify daemon-only
doctor/status permissions, refresh approval safety evidence, then run the
user-gated `iphone.open-tinder` foreground-only workflow. Rerun
`macctl release check --json` and the TMCP local-product re-score only after
those checks pass. Normal rebuilds and reinstalls can reuse the persisted
signing identity without another TCC grant while the certificate, bundle ID,
and installation path stay stable.

## blockers

- The latest `macctl release check --json` at `2026-07-22T19:26:40Z` reports
  `blockerCount=5`: daemon socket response, daemon identity, daemon
  permissions, fresh `iphone.open-tinder` evidence, and the `prepared` approval
  receipt are blocked or missing. `launchctl print` still reports the packaged
  daemon executable running as PID 9750, but that does not substitute for a
  successful daemon-authoritative response.
- Current receipt inspection contains HUD approval, denial, expiry, and
  fail-closed records, but no retained `workflow.prepare` record matching the
  approval gate. Do not manufacture one while another task controls the UI.
- Finder, TextEdit, System Settings, Google Chrome, and Notes workflows pass
  with fresh evidence. Caps Lock timing/state-preservation remains covered by
  the unit test contract.

## risks

- TCC authorization is user-controlled and can require migration if the signing
  certificate, bundle identifier, or installation path changes; unchanged
  stable-signed rebuilds were verified to retain the grants.
- iPhone Mirroring is session- and window-discovery-dependent; no Tinder action
  beyond foreground/visibility verification is permitted. Live evidence is
  not attributable while another task controls the same mirrored window.
- Scriptable-app and custom-rendered-app live evidence must not be
  represented by synthetic receipts.

## lastUpdated

2026-07-22

## quality

| check | status | evidence |
| --- | --- | --- |
| formatter/lint | not configured | Swift package has no formatter/linter dependency |
| typecheck/build | passed | isolated `swift build -c release` completed successfully |
| tests | passed | isolated `swift test`: 23 tests, 0 failures |
| pre-commit readiness | passed | commit `bff0f60` Pre-CR gate passed |
| launchd/socket/transport | blocked | launchd identity and socket mode 0600 pass, but the current release check could not obtain a daemon response; no TCP listener |
| receipt storage | passed | owner-only 0700/0600, atomic writes, retention 1,000, 168 files, invalid count 0, pending prune 0 |
| daemon permissions | blocked | daemon-authoritative doctor/status could not be reached; permission context is unknown for the current gate |
| Mac live smokes | passed | Finder/TextEdit/System Settings/Google Chrome/Notes passed |
| iPhone Mirroring | blocked | Focus/field/keycode fix is built and installed, but live evidence is not attributable while another active task changes the shared Mirroring query; no Tinder action was attempted |
| approval/HUD/Caps Lock | blocked | HUD approve/deny, expiry, and direct fail-closed records exist, but the current gate is missing fresh `workflow.prepare` evidence; Caps Lock timing/state-preservation tests pass |
| Tier-1 release gate | blocked | `blockerCount=5`, `passed=false`, generated 2026-07-22T19:26:40Z; daemon response/permissions, Tinder, and approval-prepared evidence are unresolved |
| TMCP local-product re-score | pending | rerun after the current daemon, approval, and iPhone evidence blockers are cleared; prior blocked receipt remains `tmcp-review-plan-b25509ba` |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: `macctl/mirroring-focus-fix` (isolated worktree; integration target `dev`)
- Latest implementation commit: `bff0f60`
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

The packaged daemon is installed and launchd reports the packaged executable
and bundle identity with PID 9750. The latest release check could not obtain a
daemon-authoritative response, so current permission state is unknown despite
the earlier stable-signing/TCC verification. Receipt storage is healthy. No
changes were pushed or merged. Release readiness remains blocked by the
daemon-response, approval-evidence, and unattributable live iPhone conditions
recorded above. Final TMCP artifacts are in
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
- Added precise iPhone Mirroring recovery diagnostics; current state is safely blocked until a clean Mirroring session is available and no other task controls the shared UI.
- Replaced ad-hoc signing with a persisted Apple Development identity; re-registered the four daemon permissions once and verified they survived a fresh build/install/restart cycle.
- Added isolated Mirroring focus, visible-window recovery, Spotlight field targeting, direct result clicking, and physical-keycode ASCII typing; committed as `bff0f60`.
- Ran isolated `swift test` with 23/23 passing and `swift build -c release`; installed and restarted the packaged daemon for live verification.
- Refreshed the Tier-1 gate: latest check reports `blockerCount=5` because daemon-only doctor/status did not answer, Tinder evidence is absent, and the retained approval records lack a matching prepared receipt.
- Ran the final TMCP `expert_rubric_remediation_v1` review against the local-product/public-sector rubric; the blocked score and explicit legal-calculation N/A mapping are recorded in `/private/tmp/macctl-tmcp-tier1-final-local/`.
