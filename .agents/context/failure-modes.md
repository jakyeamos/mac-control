# Failure modes and recovery

Expected safety outcomes are explicit:

- `blocked`: a required permission, approval, live receipt, or Aqua session is
  unavailable. Preserve the reason and obtain the missing user-controlled
  evidence before retrying.
- `unknown`: the daemon or socket cannot establish authoritative state. Do not
  infer permission or successful execution from a CLI fallback.
- `approval_expired` or `approval_denied`: create a new plan; never reuse or
  mutate an old token.
- foreground/focus mismatch: stop the workflow, record verification failure,
  and investigate the named-app or focus policy rather than retrying global
  input.
- `target_changed`: treat the captured target as terminal, refresh the target
  identity, and never replay the stale action.
- `vscode_diagnostics_blocked`: stop when the disposable VS Code fixture,
  extension snapshot, exact PID/bundle/path, freshness, or redaction proof is
  missing. The native diagnostics route is preferred; do not substitute global
  keyboard input. If visual Problems-panel acceptance is requested, require a
  fresh exact frontmost and focused observation; otherwise report the visual
  proof as unverified and do not retry blindly.
- receipt/storage failure: stop before execution when durable evidence cannot
  be written with owner-only permissions.
- signing identity, bundle identifier, or install-path change: perform the
  documented TCC migration and re-run the full release gate.

Use `doctor --json`, `status --json`, `receipts status --json`, and
`release check --json` for diagnosis. Recovery may rebuild/reinstall the
packaged daemon and restart the user LaunchAgent, but must not manufacture
receipts or alter a device/account to make a gate green. Unsupported provider
surfaces remain blocked; do not replace them with an unverified local route or
manufacture live evidence. A foreground handoff, if still necessary, is
explicit: prepare, target, reverify identity/frontmost/focus, perform the
minimum input, verify the result, and optionally restore the prior app/window.
