# Initial Mac Control comparison results

Run date: 2026-08-02

Host: macOS 26.5.2 (25F84), arm64

Repository state at report generation: `09ea448` on `dev`

Computer Use runtime: `1.0.1000502`

Installed artifacts used by the Mac Control lane:

- CLI SHA-256: `1cd17386938963f5cd99b4d7c23ca5ce0eba558bc149f8c75ab71cfcea8b1941`
- Daemon SHA-256: `6c8bd55028cbb01a0dbf77a900f9a681095a5086e3acad4983f1410ffbdd2c4d`
- Daemon permission context: live `macctld`; Accessibility, Input Monitoring,
  Post Events, Screen Recording, and Full Keyboard Access were observed ready.

Each successful lane used one warmup and three externally timed measured
samples. One-time initialization and state reset were excluded. Every measured
result includes its lane's oracle check. See `raw.jsonl` for individual samples
and `summary.json` for the machine-readable aggregation.

## Results

| Task | Lane | Median | Calls | Verified | Recoveries | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Inspect Full Keyboard Access | Agent baseline | 12.510 ms | 1 | 3/3 | 0 | Passed |
| Inspect Full Keyboard Access | Mac Control | 71.241 ms | 1 | 3/3 | 0 | Passed |
| Inspect Full Keyboard Access | Generic GUI | 1,978.639 ms | 4 | 3/3 | 0 | Passed |
| Move focus to next control | Generic GUI | 782.932 ms | 2 | 3/3 | 0 | Passed |
| Move focus to next control | Mac Control | — | — | 0/0 | 2 | Blocked before measurement |

For Full Keyboard Access inspection, Mac Control was about 27.8 times faster
than generic GUI control and used one call instead of four. The best non-Mac
Control baseline remained about 5.7 times faster than Mac Control because a
direct macOS preference read is sufficient for this narrow fact.

The interactive result went the other direction. Generic GUI control completed
and verified all three focus transitions. Mac Control could not produce a valid
measured sample: a provider handoff first restored ChatGPT to the foreground;
after adding explicit app activation, `macctl app open` succeeded but the
immediate app-scoped lease still blocked with `keyboard_focus_changed`. A
separate attempt reached navigation but returned `foreground_only`, correctly
failing the strict focus-change oracle.

## Interpretation

Mac Control makes structured, daemon-owned inspection materially easier and
faster than generic GUI control, though it does not beat the best direct agent
method for this particular preference. It does not yet make interactive
keyboard focus work easier: the safety boundary correctly fails closed, but
foreground ownership is not stable across the agent/tool lifecycle.

The current answer is therefore task-dependent, not a general win:

- **Promising:** structured status and other semantic/read-only operations.
- **Not ready:** leased interactive actions launched across provider/tool
  handoffs.
- **Next defect to fix:** make foreground activation observable and stable as
  part of app-scoped lease acquisition, or provide a single daemon operation
  that activates, waits for the target foreground identity, and acquires the
  lease without an inter-process race.

The planned app/window-management task was not forced after this blocker. Its
core prerequisite—stable foreground transfer—was the failing condition, so a
timing number would have measured retries rather than successful equivalent
work. No lane was expanded to seven samples: successful groups were neither
noisy nor near-tied, and the interactive Mac Control lane was blocked rather
than statistically ambiguous.

## Evidence boundaries

- `raw.jsonl` stores outcome metadata only and is owner-readable (`0600`).
- No lease or approval capability value, screenshot, selector, or application
  content is stored in the result set.
- Computer Use initialization and two pre-warmup invocation-shape recoveries
  are excluded from measured generic GUI timings but retained in raw metadata.
- Command-sandbox socket denial was rerun in the live owner context and is not
  counted as a Mac Control product failure.
- Hands-off confirmations were coordination windows, not task intervention;
  measured samples required no user help.
