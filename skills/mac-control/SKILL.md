---
name: mac-control
description: Route and execute verified macOS UI work through the installed macctl control plane. Use when a task needs a visible macOS app, native control, menu, focus movement, keyboard shortcut, or iPhone Mirroring; when no mature CLI, API, typed app connector, or browser DOM route covers the exact action; or when choosing among Mac Control semantic Accessibility, keyboard navigation, generic GUI, and visual or coordinate interaction. Prefer a mature direct interface when it fully covers the task, and do not use Mac Control merely for read-only settings or state that a direct macOS command can answer.
---

# Mac Control

Choose the highest-confidence, lowest-overhead route that can verify the result. Use Mac
Control to extend an agent's speed and reach; do not use it merely because a task happens on
a Mac.

Load this packet once. If the source, canonical installation, or provider projection resolves
to the same skill, do not load another copy.

## Route before acting

Apply this order:

1. Use a mature direct CLI, API, typed connector, or browser DOM route when it covers the
   exact action and exposes a verification result.
2. Use a declared Mac Control adapter or semantic Accessibility target for a known native
   control.
3. Use a named Mac Control keyboard action for shortcuts, focus movement, menus, or repeated
   navigation.
4. Use generic Accessibility GUI control when Mac Control lacks the required semantic action.
5. Use screenshot, OCR, or coordinates only when stronger routes cannot identify the target.

Treat a direct interface as mature only when it is installed, healthy, authorized, exact for
the task, and independently verifiable. Do not count a read-only interface as coverage for a
required mutation. Read [references/routing.md](references/routing.md) when the route is
ambiguous, the task spans applications, or the action carries approval or private-input risk.

For a read-only Full Keyboard Access status check, use the direct preference read:

```sh
/usr/bin/defaults read -g AppleKeyboardUIMode
```

Do not run `macctl doctor`, `macctl capabilities`, or `macctl control status` merely to answer
that preference question. A missing key or unreadable result is unknown, not disabled.

## Reconcile the live prerequisite only for a Mac Control route

Stop here when the direct route fully covers the task. Run the following checks only after
selecting a Mac Control route that will send or prepare synthetic input:

Resolve the installed command and inspect the live control plane before input:

```sh
command -v macctl
macctl --help
macctl doctor --json
macctl capabilities --json
macctl control status --json
```

Prefer the resolved command. If `macctl` is not on `PATH`, check the documented installed
path at `~/.local/bin/macctl`. A missing daemon, permission, foreground, or Full Keyboard
Access prerequisite is `blocked`; follow the returned recovery instructions. Do not enable
Full Keyboard Access, change TCC permissions, or install persistent components without the
user's authority.

## Execute the smallest verified action

For one visible action, use the atomic app-scoped form. It activates the target, waits for
stable foreground, creates an ephemeral lease, performs and verifies the action, and releases
the lease before returning:

```sh
macctl control perform next-control \
  --app "System Settings" --confirm --json
```

For a known control, provide stable semantic identity rather than coordinates:

```sh
macctl control perform activate \
  --app "TextEdit" --confirm --role AXButton --title "Save" --json
```

Require a succeeded response and `result.verification.state` equal to `passed`. For atomic
app-scoped actions, also require evidence that `lease_released` is true. A response with
`foreground_only`, unchanged readable focus, an ambiguous target, or an error is not task
completion.

For several consecutive actions in one already-foreground app, acquire the narrowest app
lease, pass its token to every action, and release it in every outcome. Prefer atomic actions
or a declared checkpointed task when the provider may reclaim foreground between requests.
Never compose `app open`, lease acquisition, and the first input as an assumed atomic unit.

## Preserve the safety boundary

- Keep `keyboard_focus_changed` fail-closed. Reassert the target through an atomic action;
  never weaken foreground verification.
- Use app-scoped leases by default. Use a session lease only for an intentional cross-app
  workflow whose foreground changes are part of the plan.
- Keep hands off the shared keyboard and trackpad during synthetic input and tell the user
  before an interactive run needs an exclusive-input window.
- Never send credentials, private text, or bare printable input through raw keyboard
  sequences. Use the approval-gated workflow or task path.
- Keep browser DOM automation on a mature browser route. Use Mac Control for browser chrome,
  OS-level dialogs, shortcuts, or controls outside the DOM.
- Treat iPhone Mirroring as a separate shared-input surface with its own driving lease and
  live visual evidence.
- Never manufacture a successful receipt or substitute build/test evidence for a live GUI
  result.

## Recover without blind retries

On `keyboard_focus_changed`, `foreground_only`, or a foreground race, stop the split sequence
and retry only through atomic app-scoped control or a declared task plan. On an ambiguous
Accessibility target, refine stable role, title, or identifier evidence before retrying. On a
sandbox socket denial, distinguish sandbox policy from product failure and request the
documented live owner context when authorized.

Report the chosen route, action status, verification state, and any blocked prerequisite.
When comparing speed, time the complete action including activation, lease handling,
verification, and cleanup against the best non-Mac-Control baseline.
