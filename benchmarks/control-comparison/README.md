# Mac Control comparison benchmark

This benchmark compares the available ways an agent can complete the same macOS
task:

1. `agent-baseline`: the best available method excluding Mac Control.
2. `generic-gui`: accessibility/screenshot-driven computer control without Mac Control.
3. `mac-control`: the installed, daemon-backed Mac Control surface with Full Keyboard Access.
4. `hybrid`: Mac Control detects a provider handoff condition, then Computer Use
   performs fresh target discovery, the action, and fresh verification.

The initial suite uses one warmup and three measured samples per lane. Expand a
lane to seven measured samples when its three-sample coefficient of variation
exceeds 15%, or when the two fastest lane medians are within 10%.

The locked Phase 0 corpus is [`phase-0-corpus-v1.json`](./phase-0-corpus-v1.json).
Its canonical interpretation is [`phase-0-baseline-report.md`](./phase-0-baseline-report.md);
the generated machine summary lives in `benchmarks/results/phase-0-baseline-v1.json`
and `.md`. Phase 1 extensions remain explicit when they are blocked or lack a
paired benchmark record.

## Timing and oracle contract

- Put every lane in the same documented starting state.
- Exclude one-time runtime initialization and state reset from the task timer.
- Start an external monotonic timer immediately before the first task action.
- Stop only after the lane's result has been checked against the shared oracle.
- Record setup/reset failures as recoveries, even though reset time is excluded.
- A trial passes only when the shared oracle is satisfied. A successful API call
  without observed task completion is not verification.
- Record tool calls, recoveries, user help, and verification alongside time.

## Pairing and versioned context

The recorder accepts schema v1 records for backward compatibility and writes
schema v2 records when comparison context is supplied. A pair is eligible only
when all of these fields match: `comparison_id`, task, app, target fingerprint,
starting-state fingerprint, and timing scope. The implementation and build
identify the competing variant; route and provenance remain visible so a direct
system call is not confused with a daemon-executed or caller-supplied result.

Use opaque, redacted identities for targets and state. Do not put selectors,
window contents, lease tokens, screenshots, or other private UI data in these
fields. A v1 record without context remains readable but is not silently
paired with a fully identified v2 run.

The first tasks are:

| Task | Starting state | Shared oracle |
| --- | --- | --- |
| `inspect-full-keyboard-access` | Logged-in macOS session | Full Keyboard Access is enabled |
| `focus-next-control` | System Settings foreground with a focusable control | Accessibility focus changes to the next control |
| `focus-next-control-batch-2` | System Settings foreground with a focusable control | Accessibility focus advances through two controls in order |
| `activate-system-settings` | Finder foreground | System Settings becomes the observed foreground app |
| `scroll-main` | Finder main scroll area at the redacted ready state | The main content viewport changes and the result is re-read successfully |

## Safety and provenance

The raw JSONL contains outcome metadata only. Do not store command output,
screenshots, application content, selectors, credentials, approval tokens, or
keyboard lease tokens. The recorder rejects sensitive field names. The Mac
Control focus runner uses one atomic daemon request per action. That request
activates the target, waits for stable foreground, acquires an ephemeral
app-scoped lease, performs and verifies the action, and releases the lease on
every exit path. All of that work is included in the measured action interval.
Before measurement, the runner performs one unmeasured navigation precondition
check. If the window has no readable focused control, that action establishes
one. If focus was already present and moved, the runner restores it. A trial
never passes unless both the before and after focus states are observed.

The Mac Control scroll runner uses the same atomic daemon boundary, but its
timed interval is `end_to_end_verified_action`: target resolution, semantic
scroll dispatch, post-action re-resolution, verification, lease cleanup, and
the CLI/daemon round trip are included. It establishes a non-boundary state
and resets it outside the timer. A failed reset makes the trial failed so a
cleanup failure cannot look like a valid latency sample. The daemon's
`route benchmark` remains a separate route-only metric and must not be mixed
with this end-to-end lane.

Mac Control samples require live `macctld` evidence and never accept a local
fallback as a valid result. Generic GUI samples must use the Computer Use
control surface. Hybrid samples must include the Mac Control outcome that
caused the handoff and the subsequent fresh Computer Use action plus oracle;
they must not hide the provider transition or count a caller-supplied metric.
The baseline may use any faster available method except Mac Control or the
generic GUI surface.

For the deterministic focus task, the repository includes an independent
baseline lane using System Events UI scripting. It activates System Settings,
sends Tab, and verifies a changed `AXFocusedUIElement` reference without
calling `macctl`:

```sh
python3 scripts/control_benchmark.py run-direct-focus \
  --app "System Settings" --comparison-id focus-system-settings-v1 \
  --target-fingerprint system-settings-focus-v1 \
  --state-fingerprint system-settings-ready-v1 \
  --implementation-id system-events --build-id macos-system-events-26.5.2 \
  --timing-scope command_round_trip --provenance direct_ui_scripting \
  --output benchmarks/results/raw-direct-focus.jsonl
```

## Commands

Run the two read-only Full Keyboard Access lanes:

```sh
python3 scripts/control_benchmark.py run-fka-readonly \
  --lane agent-baseline --comparison-id fka-status-v1 --app macOS \
  --target-fingerprint fka-v1 --state-fingerprint login-session-v1 \
  --implementation-id defaults --build-id macos-defaults-current \
  --timing-scope command_round_trip --provenance direct_system \
  --output benchmarks/results/raw.jsonl
python3 scripts/control_benchmark.py run-fka-readonly \
  --lane mac-control --comparison-id fka-status-v1 --app macOS \
  --target-fingerprint fka-v1 --state-fingerprint login-session-v1 \
  --implementation-id macctld --build-id mac-control-current \
  --timing-scope command_round_trip --provenance daemon_executed \
  --output benchmarks/results/raw.jsonl
```

With the user handing off the keyboard and trackpad, run the atomic focus
samples. The daemon reasserts System Settings foreground inside every action:

```sh
python3 scripts/control_benchmark.py run-mac-focus \
  --app "System Settings" --comparison-id focus-system-settings-v1 \
  --target-fingerprint system-settings-focus-v1 \
  --state-fingerprint system-settings-ready-v1 \
  --implementation-id mac-control --build-id mac-control-current \
  --timing-scope command_round_trip --provenance daemon_executed \
  --output benchmarks/results/raw.jsonl
```

For a semantic scroll comparison, use the same redacted context and timing
scope for the Mac Control and Computer Use records. The identifier is accepted
only as a live command argument; it is never written to the raw result:

```sh
python3 scripts/control_benchmark.py run-mac-scroll \
  --app Finder --role AXScrollArea --identifier '_NS:23' \
  --task scroll-main \
  --direction down --amount 1 --reset-direction up --reset-amount 1 \
  --comparison-id scroll-finder-e2e-v1 \
  --target-fingerprint finder-main-scroll-v1 \
  --state-fingerprint finder-main-ready-v1 \
  --implementation-id mac-control --build-id mac-control-current \
  --timing-scope end_to_end_verified_action --provenance daemon_executed \
  --output benchmarks/results/raw-mac-scroll-e2e.jsonl
```

`--task` is optional and defaults to `scroll-main`. Use a task-specific value
when extending an existing paired fixture so daemon-executed samples retain
the same comparison identity; this keeps the timing live without recording
caller-supplied metrics.
`--record-route` is also optional and defaults to `scroll`; use it only when
continuing a fixture whose redacted route label is already established under a
different historical name. The runner samples `macctl control status --json`
before and after each prime, measured action, and inverse reset outside the
timed interval. For `focus_policy=foreground`, both snapshots must identify
the named target and remain unchanged; otherwise the sample is unavailable or
failed and does not join a ranked pair. It records
`foreground_oracle=foreground_unchanged` for compatibility with existing
fixtures while enforcing the stronger target-frontmost check.

Computer Use samples should start the timer before fresh state discovery,
locate the target from that fresh state, scroll once, and stop only after a
fresh state read verifies the same redacted viewport-change oracle. Record
those samples with `record`, `--timing-scope end_to_end_verified_action`,
`--implementation-id computer-use-agent`, and `--provenance computer_use`.

For the multi-step comparison, the Mac Control lane times one bounded batch
request (one app lease, two verified actions) and the direct lane times one
independent System Events script containing the same two key actions:

```sh
python3 scripts/control_benchmark.py run-mac-batch-focus \
  --app "System Settings" --steps 2 --comparison-id focus-system-settings-batch-2-v1 \
  --target-fingerprint system-settings-focus-v1 \
  --state-fingerprint system-settings-ready-v1 \
  --implementation-id mac-control-batch --build-id mac-control-current \
  --timing-scope command_round_trip --provenance daemon_executed \
  --output benchmarks/results/raw-batch-mac-control.jsonl
python3 scripts/control_benchmark.py run-direct-batch-focus \
  --app "System Settings" --steps 2 --comparison-id focus-system-settings-batch-2-v1 \
  --target-fingerprint system-settings-focus-v1 \
  --state-fingerprint system-settings-ready-v1 \
  --implementation-id system-events-batch --build-id macos-system-events-26.5.2 \
  --timing-scope command_round_trip --provenance direct_ui_scripting \
  --output benchmarks/results/raw-batch-direct.jsonl
```

When the first three measured samples trigger the expansion rule, append the
remaining four with unique sample numbers:

```sh
python3 scripts/control_benchmark.py run-mac-focus \
  --app "System Settings" --warmups 0 --samples 4 --sample-offset 3 \
  --comparison-id focus-system-settings-v1 \
  --target-fingerprint system-settings-focus-v1 \
  --state-fingerprint system-settings-ready-v1 \
  --implementation-id mac-control --build-id mac-control-current \
  --timing-scope command_round_trip --provenance daemon_executed \
  --output benchmarks/results/raw.jsonl
```

Append an externally timed generic GUI or other manual sample:

```sh
python3 scripts/control_benchmark.py record \
  --task focus-next-control --lane generic-gui --phase measured --sample 1 \
  --duration-ms 500 --tool-calls 1 --recoveries 0 --verified \
  --status passed --oracle "Accessibility focus changed to the next control" \
  --output benchmarks/results/raw.jsonl
```

Generate both report formats:

```sh
python3 scripts/control_benchmark.py summarize \
  --input benchmarks/results/raw.jsonl \
  --json-output benchmarks/results/summary.json \
  --markdown-output benchmarks/results/summary.md
```

When lanes or builds were recorded into separate raw files, repeat `--input`
so the report can pair them using their versioned task context:

```sh
python3 scripts/control_benchmark.py summarize \
  --input benchmarks/results/raw-direct.jsonl \
  --input benchmarks/results/raw-mac-control.jsonl \
  --json-output benchmarks/results/summary-comparison.json \
  --markdown-output benchmarks/results/summary-comparison.md
```

The summary preserves a lane that blocks before its first measured sample. Its
timing fields remain `null`/`—`, and the interpretation carries the latest
redacted blocker instead of treating absence as success or silently omitting
the lane.
