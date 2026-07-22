# PROJECT_TRUTH.md

## summary

Tier-1 local-product hardening plus stable daemon signing is implemented in
commit `dabe3a9` on `dev`. The packaged `macctld.app` is the active launchd
executable, signed by the persistent Apple Development identity
`2C99DA3591BF6BD4BA2E0D8B552933E35BADD8D3`, and the daemon uses an owner-only
AF_UNIX socket with durable/redacted receipts. Accessibility, Input Monitoring,
Post Events, and Screen Recording were re-registered once for that identity and
remained granted after a fresh rebuild, reinstall, and launchd restart. The
verified gate remains blocked only by fresh iPhone Mirroring/Tinder evidence
and live approval evidence. AIOS and career-ops were not modified.

## nextStep

Run the user-gated `iphone.open-tinder` foreground-only workflow with an active
iPhone Mirroring session, then exercise the approval HUD and Caps Lock
bring-to-front evidence. Rerun `macctl release check --json` and the TMCP
local-product re-score after those live receipts exist. Normal rebuilds and
reinstalls can now reuse the persisted signing identity without another TCC
grant, provided the certificate, bundle ID, and installation path stay stable.

## blockers

- `macctl release check --json` is blocked with 2 checks: fresh
  `iphone.open-tinder` evidence is missing, and live approval receipts for
  prepared/approved/denied/fail-closed paths are missing.
- Finder, TextEdit, System Settings, Google Chrome, and Notes workflows pass
  with fresh evidence. Unit tests cover approval expiry/reuse and Caps Lock
  timing, but GUI HUD/Caps Lock evidence has not been exercised.

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
| typecheck/build | passed | `swift build -c release` completed successfully |
| tests | passed | `swift test`: 20 tests, 0 failures |
| pre-commit readiness | passed | commit `dabe3a9` Pre-CR gate passed |
| launchd/socket/transport | passed | Apple Development identity active; socket mode 0600; no TCP listener |
| receipt storage | passed | owner-only 0700/0600, atomic writes, retention 1,000, invalid count 0 |
| daemon permissions | passed | daemon-authoritative doctor reports Accessibility/Input Monitoring/Post Events/Screen Recording granted after reinstall |
| Mac live smokes | passed | Finder/TextEdit/System Settings/Google Chrome/Notes passed |
| iPhone Mirroring | blocked | fresh Tinder foreground evidence is missing |
| approval/HUD/Caps Lock | blocked | live prepare/approve/deny/fail-closed evidence not present |
| Tier-1 release gate | blocked | `blockerCount=2`, `passed=false`, generated 2026-07-22T15:50:03Z |
| TMCP local-product re-score | pending | rerun after the two remaining live evidence blockers are cleared; prior blocked receipt remains `tmcp-review-plan-b25509ba` |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: `dev`
- Latest implementation commit: `dabe3a9`
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
with PID 88573; the daemon answered through the owner-only socket and retained
all four required TCC grants after reinstall. No changes were pushed. Release
readiness remains blocked by the live conditions recorded above, not by stale
metadata. Final TMCP artifacts are in
`/private/tmp/macctl-tmcp-tier1-final-local/`; the advisory TMCP receipt is
`/Users/jakyeamos/.tmcp/receipts/2026-07/tmcp-review-plan-b25509ba-dcc090fbb1386edb0eddec27dd93f662-1c251938a5-f145b4cdee644a84b032bfb99f94ffc8.json`.

## Recent Progress

- Added launchd `bootout -> bootstrap -> print` reconciliation and runtime identity checks.
- Made doctor/status permission and runtime reporting daemon-authoritative and fail closed when unavailable.
- Added schema-versioned atomic redacted receipts, backward-compatible decoding, retention, listing, and diagnostics.
- Added the machine-readable Tier-1 release gate for identity, transport, TCC, receipts, live smokes, iPhone Mirroring, and approval safety.
- Added local-product policy documentation with explicit legal-calculation N/A mapping.
- Rebuilt and installed the packaged binaries; verified launchd identity, socket ownership, and receipt compliance.
- Recorded fresh successful Finder, TextEdit, System Settings, and Notes receipts.
- Replaced Safari with Google Chrome in the required safe workflow set and recorded fresh Mac workflow evidence.
- Replaced ad-hoc signing with a persisted Apple Development identity; re-registered the four daemon permissions once and verified they survived a fresh build/install/restart cycle.
- Ran `swift test` with 20/20 passing and committed the implementation as `dabe3a9`.
- Refreshed the Tier-1 gate: `blockerCount=2`; only iPhone Mirroring Tinder evidence and live approval evidence remain.
- Ran the final TMCP `expert_rubric_remediation_v1` review against the local-product/public-sector rubric; the blocked score and explicit legal-calculation N/A mapping are recorded in `/private/tmp/macctl-tmcp-tier1-final-local/`.
