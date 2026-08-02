# Mac Control comparison benchmark

This benchmark compares three ways an agent can complete the same macOS task:

1. `agent-baseline`: the best available method excluding Mac Control.
2. `generic-gui`: accessibility/screenshot-driven computer control without Mac Control.
3. `mac-control`: the installed, daemon-backed Mac Control surface with Full Keyboard Access.

The initial suite uses one warmup and three measured samples per lane. Expand a
lane to seven measured samples when its three-sample coefficient of variation
exceeds 15%, or when the two fastest lane medians are within 10%.

## Timing and oracle contract

- Put every lane in the same documented starting state.
- Exclude one-time runtime initialization and state reset from the task timer.
- Start an external monotonic timer immediately before the first task action.
- Stop only after the lane's result has been checked against the shared oracle.
- Record setup/reset failures as recoveries, even though reset time is excluded.
- A trial passes only when the shared oracle is satisfied. A successful API call
  without observed task completion is not verification.
- Record tool calls, recoveries, user help, and verification alongside time.

The first tasks are:

| Task | Starting state | Shared oracle |
| --- | --- | --- |
| `inspect-full-keyboard-access` | Logged-in macOS session | Full Keyboard Access is enabled |
| `focus-next-control` | System Settings foreground with a focusable control | Accessibility focus changes to the next control |
| `activate-system-settings` | Finder foreground | System Settings becomes the observed foreground app |

## Safety and provenance

The raw JSONL contains outcome metadata only. Do not store command output,
screenshots, application content, selectors, credentials, approval tokens, or
keyboard lease tokens. The recorder rejects sensitive field names. The Mac
Control focus runner holds its lease token in memory, suppresses release output,
and releases in a `finally` block. It also re-establishes the requested
foreground app through `macctl app open` immediately before lease acquisition;
that provider-handoff setup is excluded from the measured action interval.
After activation, it performs one unmeasured navigation precondition check. If
the window has no readable focused control, that action establishes one. If
focus was already present and moved, the runner restores it before timing. A
trial never passes unless both the before and after focus states are observed.

Mac Control samples require live `macctld` evidence and never accept a local
fallback as a valid result. Generic GUI samples must use the Computer Use
control surface. The baseline may use any faster available method except Mac
Control or the generic GUI surface.

## Commands

Run the two read-only Full Keyboard Access lanes:

```sh
python3 scripts/control_benchmark.py run-fka-readonly \
  --lane agent-baseline --output benchmarks/results/raw.jsonl
python3 scripts/control_benchmark.py run-fka-readonly \
  --lane mac-control --output benchmarks/results/raw.jsonl
```

With System Settings foreground and the user hands off the keyboard and
trackpad, run the leased focus samples:

```sh
python3 scripts/control_benchmark.py run-mac-focus \
  --app "System Settings" --output benchmarks/results/raw.jsonl
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
