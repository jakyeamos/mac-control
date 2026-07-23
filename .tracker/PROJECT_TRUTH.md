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
as separate records. Fresh `approval.smoke` prepared and HUD-denial evidence
now passes the approval safety gate.
The approval HUD now schedules token-scoped expiry and removes the panel when a
pending approval expires, implemented in commit `de7d5f4`.
Focus-preserving background workflows are implemented in commit `5a153f3`:
foreground is the default, background app launch is non-activating, named
macOS app actions use Accessibility or process-targeted input, focus changes
fail closed, and approval/report/receipt provenance includes the policy. The
The live background smoke now passes in the installed Aqua daemon: Calculator
ran as a named macOS app target while the focus guard recorded
`com.openai.codex` as both the initial and final foreground app. AIOS and
career-ops were not modified; Career Ops can invoke mac-control when it needs
local macOS interaction.

## nextStep

Lock the physical iPhone so the active consumer Mirroring session can connect,
then rerun the user-gated `iphone.open-tinder` foreground-only workflow and
`macctl release check --json`. The background and approval workflow runtime
evidence is fresh; rerun the TMCP local-product re-score after the remaining
release gate is refreshed.

## blockers

- `macctl release check --json` is blocked with 1 check: fresh
  `iphone.open-tinder` evidence is missing because iPhone Mirroring reports
  that the iPhone is in use and must be locked to connect.
- Finder, TextEdit, System Settings, Google Chrome, and Notes workflows pass
  with fresh evidence. Approval HUD, denial, expiry, and fail-closed behavior
  remain covered by implementation/tests and fresh receipts; `approval.safety`
  now passes in the current release window.

## risks

- TCC authorization is user-controlled and can require migration if the signing
  certificate, bundle identifier, or installation path changes; unchanged
  stable-signed rebuilds were verified to retain the grants.
- The live background check covered a safe named-app launch and wait on
  Calculator. Accessibility click/type/key and named-app capture/OCR remain
  narrower paths that still need their own live coverage before being treated
  as broadly validated.
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
| typecheck/build | passed | `swift build -c release` completed successfully for `5a153f3` |
| tests | passed | `swift test`: 26 tests, 0 failures |
| pre-commit readiness | passed | commit `5a153f3` Pre-CR gate passed |
| launchd/socket/transport | passed | Apple Development identity active; socket mode 0600; no TCP listener |
| receipt storage | passed | owner-only 0700/0600, atomic writes, retention 1,000, 209 files, invalid count 0, pending prune 0 |
| daemon permissions | passed | daemon-authoritative doctor reports Accessibility/Input Monitoring/Post Events/Screen Recording granted after reinstall |
| Mac live smokes | passed | Finder/TextEdit/System Settings/Google Chrome/Notes passed |
| iPhone Mirroring | blocked | Mirroring window detected but connection is paused because the iPhone is in use; lock it and rerun the foreground-only Tinder smoke |
| approval/HUD/Caps Lock | passed | `approval.smoke` prepare, HUD approve/deny, expiry, and direct fail-closed evidence are fresh; Caps Lock timing/state-preservation tests pass |
| background workflow contract | passed | Live installed-daemon Calculator launch/wait preserved `com.openai.codex` foreground focus before and after; receipt records background policy, daemon context, signed identity, and target PID 8554 |
| Tier-1 release gate | blocked | `blockerCount=1`, `passed=false`, generated 2026-07-22T22:48:40Z; only `live.iphone-mirroring` remains blocked |
| TMCP local-product re-score | pending | rerun after the iPhone Mirroring gate is refreshed; prior blocked receipt remains `tmcp-review-plan-b25509ba` |
| legal calculation safety | N/A | macctl has no legal or calculation subsystem |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: `dev`
- Latest implementation commit: `5a153f3`
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
  front-door, foreground/background workflows, receipts, release gate, and
  consumer iPhone Mirroring adapter

## Current Position

The packaged daemon built from `5a153f3` is installed and loaded in the logged-in
Aqua session with PID 3578. Daemon-authoritative doctor/status checks confirm
the signed packaged identity, owner-only socket, all four required TCC grants,
and healthy owner-only receipt storage. The live background workflow receipt
records Calculator PID 8554, `background` focus policy, and the unchanged
`com.openai.codex` foreground app before and after execution; the temporary
workflow was removed and Calculator was closed after the smoke. No changes were
pushed. Release readiness remains blocked only by the iPhone condition recorded
above. Final TMCP artifacts are in
`/private/tmp/macctl-tmcp-tier1-final-local/`; the advisory TMCP receipt is
`/Users/jakyeamos/.tmcp/receipts/2026-07/tmcp-review-plan-b25509ba-dcc090fbb1386edb0eddec27dd93f662-1c251938a5-f145b4cdee644a84b032bfb99f94ffc8.json`.

## Recent Progress

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
- Added focus-preserving background workflows, fail-closed global-input validation, policy-bound approvals/receipts, CLI flags, and token-admission regression coverage in `5a153f3`; release build, 26 tests, and Pre-CR passed.
- Installed and restarted the `5a153f3` packaged daemon; daemon-authoritative checks passed, and the live Calculator background smoke preserved `com.openai.codex` foreground focus before and after execution.
- Refreshed `approval.smoke` prepared evidence and completed HUD denial; `approval.safety` now passes and only the iPhone Mirroring gate remains blocked.
- Added the minimal agent operating contract and context index in `e0f2d90`; the repository now has a bounded default context route for future work.
