# Agent operating contract

Read this router before repository work.

- Read `.agents/context/README.md` before searching broadly.
- Load only the routed packet needed for the task; do not dump the repository.
- For agent-facing macOS control routing or live `macctl` use, load
  `skills/mac-control/SKILL.md`; a mature direct CLI, API, typed connector, or browser DOM
  route remains preferred when it covers the exact task.
- Before assessing Mac Control, read `macctl control limitations --json` (the local
  versioned call/no-call ledger). Treat `do_not_call` and `handoff_only` entries as routing
  boundaries, and treat `call_with_constraints` entries as requiring their listed exact
  route and postcondition; the ledger never grants execution authority.
- When a fresh observation reveals a boundary not yet in the ledger, record it with
  `macctl control limitations propose --stdin --json`; inspect candidates with
  `macctl control limitations proposals --json`. Proposals are owner-only, append-only,
  forced to `unproven`, and never change routing or execution authority until a reviewed
  source/docs/test change promotes them into the canonical ledger.
- Agent-facing Mac Control skill, workflow, or trigger changes are incomplete until the
  source skill is projected through `scripts/install_mac_control_skill.py` into
  `~/.agents/skills/mac-control/SKILL.md`, `scripts/check_global_mac_control_projection.py`
  passes, and the installed `macctl` command surface is checked; repository-local
  instructions alone are not a completed trigger.
- Exact process and window identities remain read-only for direct app-level
  commands. For a safe, zero-focus semantic button press, use the separate
  `action.resolve --intent-stdin` then `action.run <resolution-id>` front door.
  It is restricted to an exact PID/instance/window, a stable unique control,
  one `AXPress`, a declared desired-state readback, a short-lived one-shot
  resolution, and an unchanged unrelated foreground PID. Never activate,
  replay, widen, or fall back after a possible dispatch.
- For an unregistered development process, use `app bind --app <expected>
  --process-id <pid>` before AX inspection. Process discovery, daemon health,
  and permission checks do not prove addressability. A failed AX root probe is
  `blocked_unsupported`; use an explicit registered `.app` development build
  through `app open <absolute-app-path>`, then rediscover and bind its PID.
  Installed app control remains supported.
- Exact keyboard input remains available only through an approved foreground
  `task.run` key step bound to `process_id`, launch-bound `instance_ref`, and
  opaque `window_ref`. It requires an exclusive task keyboard lease plus independent
  NSWorkspace frontmost-PID and AX focused-window-digest agreement, requires an
  exact-window `element_exists` postcondition, and is strict single-dispatch.
  PID-specific AppKit activation and AX raising are actuators only; neither can
  satisfy or replace either foreground oracle.
  Never widen keyboard input to background delivery, `control perform`, another
  action kind, or an application-level fallback.
- Agent-facing behavior or contract additions must update the relevant repository agent
  documentation, user-facing contract documentation, and routed skill together. For the
  keyboard navigation lease, the contract is session-only, opt-in with
  `--navigation-mode --from-pass-through`, caller-asserted because pass-through has no readback,
  and restoration-owned through release, expiry, or shutdown.
- Declare `target_surface=web_content` for rendered page content. Mac Control must return a
  typed browser-provider handoff before activating browser UI; tab identity, connector health,
  and DOM postconditions remain owned by the browser provider.
- When that handoff includes a joined-trace context, keep its completion credential in memory,
  complete it only after browser-owned readback through the bounded stdin schema, and preserve
  the receipt's per-provider provenance; correlation never grants browser execution authority.
- Background task/workflow actions may use only one named non-foreground process through
  Accessibility click/type, replace-only search, verified semantic scroll, process-directed
  keys, or an adapter operation explicitly declared `background_safe`. Full Keyboard Access,
  global pointer input, activation, ambiguous targets, and unverified mutations stay foreground-only.
- Agent-facing CLI requests default to `focus_policy=automatic`: select a verified background
  route before dispatch when eligible, otherwise use foreground immediately. Do not queue,
  batch, or defer foreground work, and never replay a possibly dispatched background mutation.
  Keep the requested approval policy separate from the effective execution policy in evidence.
- The menu-bar item is a transient safety surface, not an approval queue, attention center,
  or task-history view. It stays hidden while idle and appears only for active execution,
  hands-off or keyboard-freeze authority, daemon lifecycle drain, or degraded health. General
  attention and focus-change announcements belong to the independent attention provider.
- Use documented commands and repository-local quality gates.
- Preserve unrelated dirty work and use a disposable worktree for risky changes.
- Keep credentials, secrets, deployments, merges, and destructive operations behind explicit approval.
- Treat missing live GUI/device evidence as `blocked`, never as a reason to weaken a gate.
- Validate behavior and record the evidence needed for the task handoff.
