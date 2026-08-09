# Commands and quality gates

Run SwiftPM gates serially from a clean checkout or runtime-owned disposable
worktree:

```sh
swift build
swift test
swift test --enable-code-coverage
python3 -m unittest discover -s Tests/BenchmarkTests
python3 -m unittest discover -s Tests/SkillTests
python3 scripts/check_environment_contract.py
./scripts/test-with-coverage.sh
```

`swift build` is the compile/typecheck gate. `swift test` is the behavioral
gate. The Python suites cover benchmark accounting and the distributable Mac
Control skill contract, including its canonical install and Codex projection.
The coverage-enabled test command produces the Swift profile; the coverage
script additionally exports `coverage/lcov.info`. The environment checker
validates this contract, all routed packets, and the skill's routing and
metadata invariants. There is no
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
`keyboard lease acquire --scope session --suppress-physical-keyboard` is an
optional interactive mode that requires Accessibility and Input Monitoring;
it also requires `--reason` and explicit confirmation, and must not be used for
app-scoped or unattended workflows. Prefer the separate
`keyboard freeze acquire|status|release` commands when the freeze permission
itself is the requested capability.

Verified semantic control uses the same lease and can inspect or route a
visible action: `swift run macctl control status --json` and
`swift run macctl control perform activate --lease-token <token> --title
<title> --json`. For a task-specific route, use `route benchmark`,
`route inspect`, and `route list`; `route benchmark` executes and verifies the
bounded action samples in the daemon before persistence. Selection requires a
fresh measured app/task manifest and reports the route and declared fallback
chain. Use `route register` only for explicitly caller-supplied metadata.
Selector metadata
describes addressability but does not create a universal route ladder.
`control perform scroll --app <app> --role AXScrollArea --identifier <id>
--direction up|down|left|right --amount <n> --confirm --json` is the semantic
scroll path. `accessibility tree` and `accessibility audit` are bounded,
redacted diagnostics; their AX values, private text, screenshots, and OCR are
excluded from responses persisted as receipts.

Agent-facing control discovery and batching are available through:
`control capabilities --app <app> [--task <id> --target-fingerprint <fingerprint>]`,
`control capability-audit-batch --all-applicable [--run-id <id>] [--max-apps <n>]`,
and `control batch --app <app> --actions-stdin --confirm`. Capability output
classifies the app descriptively and distinguishes fresh daemon-executed routes
from stale or caller-supplied inventory; it does not infer provider parity.
The batch audit is a separate bounded, read-only inventory: it selects at most
24 installed user-facing apps, audits only already-running apps, serializes AX
access, persists one redacted receipt per app, and resumes not-observed or failed
entries by run ID without launching apps or dispatching actions.
If a recursive deep audit reaches its fixed ceiling, the daemon may use a
bounded window-aware/page traversal of up to 8 windows, 256 pages, and 16,000
total nodes; only complete coverage can promote a profile.
Batching owns one bounded app lease, revalidates every step, stops on the first
unverified action, and releases the lease on every exit path. Semantic scroll
remains an explicit `control perform` action so a Computer Use handoff is visible.
Control responses expose provider-neutral outcome states, including target,
action, verification, foreground-race, and provider-handoff results. When
`recommended_provider` is `computer_use`, the agent must get fresh app state,
locate a fresh target, scroll, and verify the changed state through Computer Use.

The Tier-1 gate is defined in `docs/TIER1_RELEASE.md`. Missing live evidence
is a recorded `blocked` result, not permission to weaken a check.
