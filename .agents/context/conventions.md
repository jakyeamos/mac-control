# Implementation conventions

- Keep Swift package targets separated by responsibility: shared policy and
  platform behavior in `Sources/MacCtlCore`, CLI translation in
  `Sources/MacCtlCLI`, and daemon/session ownership in `Sources/MacCtlDaemon`.
- Prefer explicit, typed result and receipt models. Preserve schema versions,
  operation/request identifiers, timestamps, status, and provenance when
  extending evidence.
- Keep safety decisions fail closed. A missing permission, approval token,
  foreground invariant, receipt, or verification result is not success.
- Keep ephemeral input in memory and redact it before any receipt or log.
  Never pass secrets through process arguments.
- Keep CLI output machine-readable when `--json` is requested and preserve
  stable status/reason fields for callers.
- Add behavior-focused XCTest coverage for approval, validation, redaction,
  receipt lifecycle, focus policy, and release-gate changes.
- Update the live project snapshot after each coherent implementation commit;
  do not turn `PROJECT_TRUTH.md` into an append-only changelog.
