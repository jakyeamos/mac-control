# PROJECT_TRUTH.md

## summary

Standalone native Swift command-first Mac control plane implemented on \`dev\`.
\`macctl\` is the CLI, \`macctld\` is the per-user AppKit daemon, and the runtime
uses an owner-only Unix socket with fail-closed GUI, approval, capture, and
iPhone Mirroring boundaries. AIOS and career-ops were not modified.

## nextStep

Grant the installed \`/Users/jakyeamos/.local/bin/macctld\` the user-approved
Accessibility, Post Events, Screen Recording, and Input Monitoring permissions,
then rerun the live semantic-input, OCR, Caps Lock, approval-panel, and paired
iPhone Mirroring smokes. Integrate existing automation only after this generic
utility is permissioned and proven.

## blockers

- Installed \`macctld\` lacks the four TCC permissions needed for semantic input,
  OCR/capture, and global Caps Lock monitoring; those operations correctly
  return blocked results until the user grants access.

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
| tests | passed | \`swift test\`: 11 tests, 0 failures |
| pre-commit readiness | passed | \`pre-cr\`: Swift coverage wrapper, lcov, and anti-slop passed |
| dead-code/safety scan | passed | \`rg\` scan; no TODO/FIXME/fatalError or raw OCR result field |
| installed smoke | passed with permission gate | doctor/status/Finder succeeded; Tinder blocked at Screen Recording |

## Current State

- Source root: /Users/jakyeamos/projects/mac-control
- Branch: \`dev\`
- Runtime: Swift Package Manager, macOS native frameworks first
- Binaries: \`/Users/jakyeamos/.local/bin/macctl\` and \`macctld\`
- LaunchAgent: \`~/Library/LaunchAgents/com.jakyeamos.macctl.daemon.plist\`
- Socket: \`~/Library/Application Support/macctl/macctld.sock\` with mode 0600
- Log: \`~/Library/Logs/macctl/macctld.log\` with mode 0600
- Scope: local CLI, per-user daemon, app/Accessibility/CGEvent control,
  screenshot/OCR/image-anchor fallback, approval HUD/menu-bar/Caps Lock
  front-door, workflows, and consumer iPhone Mirroring adapter

## Current Position

The initial implementation is committed as \`a68e2d4\` on \`dev\` and has not
been pushed. The LaunchAgent is installed and loaded in the logged-in Aqua session. The
installed daemon reports arm64/macOS 26.5.2, advertises all three surfaces,
and passes the reversible Finder workflow. TCC remains user-controlled and is
the only live blocker for input, capture/OCR, Caps Lock, and the Tinder smoke.

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
- Verified \`swift build\`, \`swift test\` (11/11), LaunchAgent/socket permissions,
  daemon status, doctor diagnostics, Finder success, and Tinder fail-closed
  behavior; restored Finder afterward.
