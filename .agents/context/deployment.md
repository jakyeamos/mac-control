# Deployment and rollback

The owner-controlled deployment is local package build, install, and LaunchAgent
restart:

```sh
swift build
swift run macctl install
~/.local/bin/macctl daemon install
~/.local/bin/macctl daemon restart
~/.local/bin/macctl release check --json
```

Install, LaunchAgent install, restart, and removal are guarded by the daemon's
atomic lifecycle drain. Let pending legacy approvals expire or deny them through
the documented compatibility lifecycle, finish or stop active execution, and
retry if the command returns `daemon_lifecycle_blocked`. Do not persist legacy
approval or current lease authority across a restart. For the first migration
from a daemon without this method only, confirm the control center is idle and
pass `--allow-legacy-idle-snapshot`; remove the flag after the new daemon has
started.

`macctld.app` is installed under `~/.local/share/macctl/` and launched through
the user `gui/<uid>` `launchd` domain by a LaunchAgent. The stable bundle identity and persisted signing
selector must remain unchanged unless an intentional TCC migration is planned.
Installation, daemon restart, and live GUI/device checks require user control;
they are never run by the repository audit as side effects.

Installation publishes `~/.local/share/macctl/runtime-parity-install.json`
after codesigning and replacing the daemon bundle. Daemon startup publishes
`~/Library/Application Support/macctl/runtime-parity-process.json`; shutdown
removes only the manifest owned by that PID. Both are atomic owner-only files.
The install manifest records both pre-signing package provenance and the
post-signing installed digest. Because signing changes executable bytes, live
parity requires the process and installed executable to match the post-signing
digest; it does not require that digest to equal the pre-signing digest.
The repository's `.pronto/installed-runtime-parity.json` binds these manifests
to the installed executable. A changed install with an older active process is
`restart_required`; missing source provenance is `unverifiable`. When installing
outside the Git checkout, provide the exact revision through
`MACCTL_SOURCE_REVISION`.

Rollback is a forward, reviewable reinstall of the last verified package and
its known-good commit. Stop the user daemon, install the prior packaged build,
restart the LaunchAgent, and rerun `doctor --json`, receipt diagnostics, and
the Tier-1 gate. Do not rewrite Git history or delete receipts. If identity,
path, or permissions changed, record the migration and require fresh evidence.

Release ownership is the repository owner. The audit runtime may build and test
an isolated disposable worktree only; it may not install, launch, merge, push,
publish, or deploy.
