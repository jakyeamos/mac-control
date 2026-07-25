# Repository context index

Load this index first, then read only the packet needed for the task. The
packets are the maintained machine-facing contract; README and Tier-1 policy
remain the detailed product references.

- `architecture.md` — targets, process boundaries, and data ownership.
- `commands.md` — build, test, coverage, diagnostics, and release checks.
- `conventions.md` — Swift and CLI implementation conventions.
- `security.md` — credentials, TCC, approval, transport, and redaction rules.
- `failure-modes.md` — blocked states, diagnostics, and recovery boundaries.
- `examples.md` — canonical implementation and evidence patterns.
- `done.md` — acceptance, quality gates, and evidence requirements.
- `deployment.md` — install ownership, release gate, rollback, and live checks.
- `README.md` — repository overview and entry points.
- Root `AGENTS.md` — always-loaded operating invariants.

Never dump the repository into context. Follow the narrowest packet route and
use the commands packet before running a gate. `last_reviewed: 2026-07-25`.
