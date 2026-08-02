# Commands and quality gates

Run SwiftPM gates serially from a clean checkout or runtime-owned disposable
worktree:

```sh
swift build
swift test
swift test --enable-code-coverage
python3 scripts/check_environment_contract.py
./scripts/test-with-coverage.sh
```

`swift build` is the compile/typecheck gate. `swift test` is the behavioral
gate. The coverage-enabled test command produces the Swift profile; the
coverage script additionally exports `coverage/lcov.info`. The environment
checker validates this contract and all routed packets. There is no
repository formatter/linter dependency; do not claim lint coverage that has
not been installed and executed.

For read-only runtime diagnostics, use the built CLI only after the package
build: `swift run macctl doctor --json`, `capabilities --json`, `status
--json`, `receipts status --json`, and `release check --json`. Release checks
must not manufacture live evidence or run workflows as a side effect.

Keyboard diagnostics and control use the daemon-authoritative surface:
`swift run macctl keyboard status --json`, `keyboard setup --json`,
`keyboard enable --confirm --json`, `keyboard inspect --json`, and the
short-lived `keyboard lease acquire|release`, `keyboard navigate`, and
`keyboard send` commands. The input commands require a confirmed lease token;
do not substitute them for the approval-gated workflow `key` or `type` path.

Verified semantic control uses the same lease and can inspect or route a
visible action: `swift run macctl control status --json` and
`swift run macctl control perform activate --lease-token <token> --title
<title> --json`. The router prefers Accessibility, then keyboard navigation,
then explicit visual/coordinate fallback, and verifies foreground/focus state
after the action.

The Tier-1 gate is defined in `docs/TIER1_RELEASE.md`. Missing live evidence
is a recorded `blocked` result, not permission to weaken a check.
