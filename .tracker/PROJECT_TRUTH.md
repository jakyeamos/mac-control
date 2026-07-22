# PROJECT_TRUTH.md

## summary

Standalone native Swift command-first Mac control plane implemented on \`dev\`.
\`macctl\` is the CLI, \`macctld\` is the packaged per-user AppKit daemon, and
the runtime uses an owner-only Unix socket with fail-closed GUI, approval,
capture, and iPhone Mirroring boundaries. AIOS and career-ops were not
modified.

## nextStep

Rerun the live semantic-input, OCR, Caps Lock, approval-panel, and paired
iPhone Mirroring smokes now that all required daemon permissions are granted.
Integrate existing automation only after this generic utility is proven.

## blockers

- No current TCC blocker observed; Automation remains user-approved on first
  AppleScript use and iPhone Mirroring remains session-dependent.

## risks

- iPhone Mirroring remains a custom-rendered, device/session-dependent surface.
- Image anchors use an in-memory native pixel matcher and should be validated
  against each app's scale/theme before being used in a consequential workflow.
- Approval HUD behavior needs a real user click or explicit CLI approval; Caps
  Lock only brings the panel forward and never approves.

## lastUpdated

2026-07-21

## quality

| check | status | evidence |
| --- | --- | --- |
| formatter/lint | not configured | Swift package has no formatter/linter dependency |
| typecheck/build | passed | \`swift build\` completed without warnings |
| tests | passed | \`swift test\`: 12 tests, 0 failures |
| pre-commit readiness | passed | \`pre-cr\`: Swift coverage wrapper, lcov, and anti-slop passed |
| dead-code/safety scan | passed | \`rg\` scan; no TODO/FIXME/fatalError or raw OCR result field |
| installed smoke | passed | packaged daemon/status succeeded; Accessibility, Post Events, Input Monitoring, and Screen Recording granted |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: \`dev\`
- Runtime: Swift Package Manager, macOS native frameworks first
- CLI: \`/Users/jakyeamos/.local/bin/macctl\`
- Daemon bundle: \`/Users/jakyeamos/.local/share/macctl/macctld.app\`
- Daemon executable: \`/Users/jakyeamos/.local/share/macctl/macctld.app/Contents/MacOS/macctld\`
- LaunchAgent: \`~/Library/LaunchAgents/com.jakyeamos.macctl.daemon.plist\`
- Socket: \`~/Library/Application Support/macctl/macctld.sock\` with mode 0600
- Log: \`~/Library/Logs/macctl/macctld.log\` with mode 0600
- Scope: local CLI, per-user daemon, app/Accessibility/CGEvent control,
  screenshot/OCR/image-anchor fallback, approval HUD/menu-bar/Caps Lock
  front-door, workflows, and consumer iPhone Mirroring adapter

## Current Position

The initial implementation is committed as \`a68e2d4\`, and the packaged daemon
slice is committed as \`002efc2\` on \`dev\`; neither has been pushed. The
LaunchAgent is installed and loaded in the logged-in Aqua session and targets
the packaged executable. The daemon reports arm64/macOS 26.5.2, advertises all
three surfaces, and has a live owner-only socket. All four required daemon TCC
checks are granted; the remaining validation is the live semantic and iPhone
Mirroring smoke pass.

## Recent Progress

- Created the standalone Swift package and \`dev\` branch outside AIOS.
- Added JSON envelopes, owner-only Unix socket, structured operation evidence,
  daemon lifecycle, and LaunchAgent installation.
- Added native app discovery, Accessibility selectors, CGEvent input, display
  and window-relative coordinate mapping, Vision OCR, and image anchors.
- Added conservative risk classification, stdin-only ephemeral input binding,
  short-lived plan-bound approval tokens, HUD/menu-bar fallback, and Caps Lock
  front-door activation.
- Added Finder/TextEdit/System Settings/Safari/Notes recipes and the
  user-gated iPhone Mirroring Tinder foreground/visibility recipe.
- Verified \`swift build\`, \`swift test\` (12/12), LaunchAgent/socket permissions,
  daemon status, doctor diagnostics, Finder success, and Tinder fail-closed
  behavior; restored Finder afterward.
- Packaged \`macctld\` as a signed \`macctld.app\` with stable bundle identity,
  moved LaunchAgent execution to its bundled executable, removed the legacy
  bare daemon, and verified the installed bundle plus 12 passing tests.
- Authenticated the new bundle in System Settings, added it to Accessibility,
  and verified the packaged daemon reports all four required TCC checks granted.
