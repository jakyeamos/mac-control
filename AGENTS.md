# Agent operating contract

Read this router before repository work.

- Read `.agents/context/README.md` before searching broadly.
- Load only the routed packet needed for the task; do not dump the repository.
- For agent-facing macOS control routing or live `macctl` use, load
  `skills/mac-control/SKILL.md`; a mature direct CLI, API, typed connector, or browser DOM
  route remains preferred when it covers the exact task.
- Agent-facing behavior or contract additions must update the relevant repository agent
  documentation, user-facing contract documentation, and routed skill together. For the
  keyboard navigation lease, the contract is session-only, opt-in with
  `--navigation-mode --from-pass-through`, caller-asserted because pass-through has no readback,
  and restoration-owned through release, expiry, or shutdown.
- Declare `target_surface=web_content` for rendered page content. Mac Control must return a
  typed browser-provider handoff before activating browser UI; tab identity, connector health,
  and DOM postconditions remain owned by the browser provider.
- Background task/workflow actions may use only one named non-foreground process through
  Accessibility click/type, replace-only search, verified semantic scroll, process-directed
  keys, or an adapter operation explicitly declared `background_safe`. Full Keyboard Access,
  global pointer input, activation, ambiguous targets, and unverified mutations stay foreground-only.
- Agent-facing CLI requests default to `focus_policy=automatic`: select a verified background
  route before dispatch when eligible, otherwise use foreground immediately. Do not queue,
  batch, or defer foreground work, and never replay a possibly dispatched background mutation.
  Keep the requested approval policy separate from the effective execution policy in evidence.
- Use documented commands and repository-local quality gates.
- Preserve unrelated dirty work and use a disposable worktree for risky changes.
- Keep credentials, secrets, deployments, merges, and destructive operations behind explicit approval.
- Treat missing live GUI/device evidence as `blocked`, never as a reason to weaken a gate.
- Validate behavior and record the evidence needed for the task handoff.
