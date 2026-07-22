# PROJECT_TRUTH.md

## summary

Tier-1 local-product hardening is implemented in commit `ef2a1b6` on `dev`.
The packaged `macctld.app` is the active launchd executable, the daemon uses
an owner-only AF_UNIX socket, operation receipts are durable/redacted, and a
machine-readable release gate now fails closed. The verified gate is not yet
release-ready because this machine lacks fresh daemon TCC authorization,
Safari, an active iPhone Mirroring session, and live approval evidence.
AIOS and career-ops were not modified.

## nextStep

Re-authorize the exact packaged daemon at
`/Users/jakyeamos/.local/share/macctl/macctld.app` in macOS Privacy & Security,
then rerun `doctor`, input/capture/OCR, approval HUD, and Caps Lock smokes.
Provide Safari or an approved replacement environment for `safari.open`, start
an active consumer iPhone Mirroring session, run the user-gated Tinder
foreground-only workflow, and rerun the release gate and the TMCP
local-product re-score. The final TMCP run is recorded as blocked until those
live conditions change.

## blockers

- `macctl release check --json` is blocked with 4 checks: daemon Accessibility,
  Input Monitoring, Post Events, and Screen Recording are missing; `safari.open`
  is unavailable because Safari is not installed; iPhone Mirroring reports
  `running=false` and `windowDetected=false`; live approval receipts for
  prepared/approved/denied/fail-closed paths are missing.
- The four other Mac foreground smokes (Finder, TextEdit, System Settings,
  Notes) passed with fresh receipts. Unit tests cover approval expiry/reuse and
  Caps Lock timing, but GUI HUD/Caps Lock evidence has not been exercised.

## risks

- TCC authorization is user-controlled and can be invalidated when the
  ad-hoc-signed packaged daemon is rebuilt or replaced.
- iPhone Mirroring is session- and window-discovery-dependent; no Tinder action
  beyond foreground/visibility verification is permitted.
- Safari, scriptable-app, and custom-rendered-app live evidence must not be
  represented by synthetic receipts.

## lastUpdated

2026-07-22

## quality

| check | status | evidence |
| --- | --- | --- |
| formatter/lint | not configured | Swift package has no formatter/linter dependency |
| typecheck/build | passed | `swift build -c release` completed successfully |
| tests | passed | `swift test`: 18 tests, 0 failures |
| pre-commit readiness | passed | commit `ef2a1b6` Pre-CR gate passed |
| launchd/socket/transport | passed | packaged identity active; socket mode 0600; no TCP listener |
| receipt storage | passed | owner-only 0700/0600, atomic writes, retention 1,000, invalid count 0 |
| daemon permissions | failed | fresh daemon-authoritative doctor reports four required permissions missing |
| Mac live smokes | blocked | Finder/TextEdit/System Settings/Notes passed; Safari absent |
| iPhone Mirroring | blocked | no active session/window; Tinder smoke not run |
| approval/HUD/Caps Lock | blocked | live prepare/approve/deny/fail-closed evidence not present |
| Tier-1 release gate | blocked | `blockerCount=4`, `passed=false`, generated 2026-07-22T04:49:09Z |
| TMCP local-product re-score | blocked | `public_sector_readiness`: governance 3, security 2, auditability 3, operational 1, accessibility 2; legal calculation safety N/A; receipt `tmcp-review-plan-b25509ba` |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: `dev`
- Latest implementation commit: `ef2a1b6`
- Runtime: Swift Package Manager, macOS native frameworks first
- CLI: `/Users/jakyeamos/.local/bin/macctl`
- Daemon bundle: `/Users/jakyeamos/.local/share/macctl/macctld.app`
- Daemon executable: `/Users/jakyeamos/.local/share/macctl/macctld.app/Contents/MacOS/macctld`
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
with PID 38476; the daemon answered through the owner-only socket. No changes
were pushed. Release readiness remains blocked by the live conditions recorded
above, not by stale metadata. Final TMCP artifacts are in
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
- Recorded Safari unavailable (`Application not found: Safari`) and iPhone Mirroring inactive (`running=false`, `windowDetected=false`) without fabricating evidence.
- Ran `swift test` with 18/18 passing and committed the implementation as `ef2a1b6`.
- Ran the final TMCP `expert_rubric_remediation_v1` review against the local-product/public-sector rubric; the blocked score and explicit legal-calculation N/A mapping are recorded in `/private/tmp/macctl-tmcp-tier1-final-local/`.
