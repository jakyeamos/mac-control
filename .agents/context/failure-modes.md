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
- receipt/storage failure: stop before execution when durable evidence cannot
  be written with owner-only permissions.
- signing identity, bundle identifier, or install-path change: perform the
  documented TCC migration and re-run the full release gate.

Use `doctor --json`, `status --json`, `receipts status --json`, and
`release check --json` for diagnosis. Recovery may rebuild/reinstall the
packaged daemon and restart the user LaunchAgent, but must not manufacture
receipts or alter a device/account to make a gate green. Unsupported provider
surfaces remain blocked; do not replace them with an unverified local route or
manufacture live evidence.
