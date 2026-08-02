# Mac Control routing cases

Use these cases when the correct control surface is not obvious. The first principle is to
choose the highest-confidence, lowest-overhead route that can perform and verify the exact
task.

## Route matrix

| Situation | Route | Reason |
| --- | --- | --- |
| A mature CLI or API performs the exact operation | Direct interface | Avoid GUI activation and input overhead. |
| A browser DOM connector can identify and verify the page element | Browser DOM | Keep semantic web actions in the DOM. |
| A native app exposes a declared typed Mac Control adapter | Mac Control adapter | Use the narrow declared operation and its verification. |
| A native control has stable role, title, or identifier evidence | Mac Control semantic Accessibility | Target the known control without sequential focus movement. |
| The task is a shortcut, menu, focus move, or repeated navigation | Mac Control keyboard | Use bounded named input with foreground and focus verification. |
| Mac Control has no suitable semantic or named action, but Accessibility can identify the control | Generic Accessibility GUI | Preserve semantic targeting even with additional observation calls. |
| Only pixels or visual text identify the target | Screenshot, OCR, or coordinates | Use the weakest route last and verify the resulting state. |

## Positive and negative examples

- Read `AppleKeyboardUIMode`: use `/usr/bin/defaults read`; the direct read fully covers the
  fact and is faster than daemon-backed control.
- Move focus to the next control in System Settings: use atomic `macctl control perform
  next-control --app "System Settings" --confirm --json`; there is no mature direct interface
  for that visible focus transition.
- Activate a known Save button in a native app: use semantic Accessibility with the button's
  stable role and title before sequential Tab navigation.
- Trigger a native menu shortcut repeatedly: use a bounded named keyboard route under an
  app-scoped lease.
- Click a webpage button when a healthy browser DOM connector can identify it: use the browser
  connector, not Mac Control.
- Enter a password or other private text: do not use raw keyboard send; use an approval-gated
  input path.
- Act on an element that is only visually distinguishable: use generic GUI or visual fallback
  only after semantic Mac Control routes are unavailable.

## Ambiguous cases

- A CLI exists but only reads state while the task must mutate it: the CLI is not a mature
  route for that action; continue down the route order.
- A known target is many focus moves away: prefer direct semantic Accessibility. Keyboard
  wins most often for shortcuts and repetitive navigation, not every distant known target.
- The provider can reclaim foreground between calls: prefer one atomic app-scoped action or a
  declared checkpointed task. Do not weaken `keyboard_focus_changed`.
- A command succeeds but verification reports `foreground_only`: classify the action as
  unverified and do not claim task completion.
- Full Keyboard Access or a required TCC grant is missing: report `blocked` and the exact user
  action. Do not silently enable or bypass it.

## Evidence basis

The 2026-08-02 local benchmark found that a direct preference read beat Mac Control for a
structured fact, while atomic Mac Control focus navigation beat generic GUI control for a
workflow without a mature direct interface. Treat those timings as host-specific evidence,
not a universal constant. Preserve the routing order and remeasure representative workflows
when the control surface or provider runtime changes.
