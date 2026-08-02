# Mac Control comparison results

Run date: 2026-08-02

Host: macOS 26.5.2 (25F84), arm64

Repository state at report generation: `49c73ea` on `dev`

Computer Use runtime: `1.0.1000502`

Installed artifacts used by the Mac Control lane:

- CLI SHA-256: `dc311fe48d67a160d3d6d7de4eccd3ee2ae3dab79dcd2bbec84af69581745c4c`
- Daemon SHA-256: `0835b26495468ed8ca1ae17fb7a0290d875486b26c36c7804b9f5b6a42066ebd`
- Daemon permission context: live `macctld`; Accessibility, Input Monitoring,
  Post Events, Screen Recording, and Full Keyboard Access were observed ready.

Each lane began with one warmup and three externally timed measured samples.
The Mac Control focus lane was expanded to seven measured samples because its
initial three-sample coefficient of variation exceeded 15%. One-time
initialization and state reset were excluded. Every measured result includes
its lane's oracle check. See `raw.jsonl` for individual samples and
`summary.json` for the machine-readable aggregation.

## Results

| Task | Lane | Median | Calls | Verified | Recoveries | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Inspect Full Keyboard Access | Agent baseline | 12.510 ms | 1 | 3/3 | 0 | Passed |
| Inspect Full Keyboard Access | Mac Control | 71.241 ms | 1 | 3/3 | 0 | Passed |
| Inspect Full Keyboard Access | Generic GUI | 1,978.639 ms | 4 | 3/3 | 0 | Passed |
| Move focus to next control | Generic GUI | 782.932 ms | 2 | 3/3 | 0 | Passed |
| Move focus to next control | Mac Control | 255.726 ms | 1 | 7/7 | 0 | Passed |

For Full Keyboard Access inspection, Mac Control was about 27.8 times faster
than generic GUI control and used one call instead of four. The best non-Mac
Control baseline remained about 5.7 times faster than Mac Control because a
direct macOS preference read is sufficient for this narrow fact.

For the interactive task, the best agent method without Mac Control was the
generic GUI lane because no mature CLI or API performs a semantic move to the
next macOS control. Mac Control was about 3.1 times faster than that baseline,
used one tool call instead of two, and verified all seven focus transitions.
Its measured interval is intentionally end-to-end: target activation, two
stable foreground reads, ephemeral app-scoped lease acquisition, keyboard
action, Accessibility verification, and guaranteed lease invalidation are all
included.

## Interpretation

The answer is task-dependent, but the keyboard-speed hypothesis is now
supported for a workflow without a mature direct interface:

- A mature direct read still wins: `defaults read` was 5.7 times faster than
  Mac Control for the Full Keyboard Access preference.
- Against generic GUI control, Mac Control was 27.8 times faster for structured
  inspection and 3.1 times faster for a verified keyboard focus transition.
- The prior interactive failure was not keystroke latency. Separate
  app-open, lease-acquire, and navigate requests allowed the provider to regain
  foreground between requests. The daemon now owns that entire lifecycle in
  one request while preserving the fail-closed `keyboard_focus_changed` guard.

The resulting routing rule is: use a mature CLI or API when one exists; then
Mac Control semantic Accessibility actions; then Mac Control keyboard
sequences; then generic Accessibility interaction; and finally screenshot or
coordinate control.

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
- The final daemon status showed `keyboardLeaseActive: false` after both the
  three-sample run and the four-sample expansion.
- The lifecycle fix is covered by source tests for delayed activation,
  foreground theft before execution, absent initial Accessibility focus,
  unchanged readable focus, explicit authority/confirmation, and cleanup on
  success and failure.
