# Repository context index

Load this index first, then read only the packet needed for the task. The
packets are the maintained machine-facing contract; README and Tier-1 policy
remain the detailed product references.

- [Architecture and boundaries](architecture.md) — targets, process boundaries, and data ownership.
- [Commands and quality gates](commands.md) — build, test, coverage, diagnostics, and release checks.
- [Implementation conventions](conventions.md) — Swift and CLI implementation conventions.
- [Security and approval](security.md) — credentials, TCC, approval, transport, and redaction rules.
- [Failure modes and recovery](failure-modes.md) — blocked states, diagnostics, and recovery boundaries.
- [Canonical examples](examples.md) — canonical implementation and evidence patterns.
- [Definition of done](done.md) — acceptance, quality gates, and evidence requirements.
- [Deployment and rollback](deployment.md) — install ownership, release gate, rollback, and live checks.
- `README.md` — repository overview and entry points.
- Root `AGENTS.md` — always-loaded operating invariants.

Never dump the repository into context. Follow the narrowest packet route and
use the commands packet before running a gate. `last_reviewed: 2026-08-13`.
