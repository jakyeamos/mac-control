# Security and approval constraints

The daemon uses a per-user owner-only Unix socket. It must not expose TCP,
accept credentials, or accept secret values in command-line arguments. TCC
permissions (Accessibility, Input Monitoring, Post Events, Screen Recording)
remain user-controlled; the tool reports missing grants and never bypasses
them.

Sensitive workflows require `prepare -> approve -> execute -> verify` with a
short-lived, single-use token. Background mode must name a target app and
must preserve the foreground application; it cannot fall back to global input,
activation, or coordinate clicks. Ephemeral text may arrive
only over the owner-only socket and must not be returned or persisted.

Atomic native window placement is separately guarded by explicit `--confirm`
and daemon-side validation. The caller cannot supply coordinates or window
titles. The daemon retains raw Accessibility identity attributes only in memory,
returns and receipts only their digest, and permits a restore token for at most
five minutes and one successful use. Restore remains bound to the original PID,
window digest, frame, and display ID; relaunch, ambiguity, expiry, replay, or a
disconnected display fails closed.

Direct keyboard navigation is a separate fast path bounded by an explicit,
short-lived, single-active lease. App-scoped leases bind to the foreground
application and process; session-scoped leases follow foreground changes only
when that state can be read. Every key revalidates lease expiry, Post Events,
and focus scope. Full Keyboard Access is never enabled at daemon startup;
`keyboard enable --confirm` writes and then verifies the user preference.
Bare printable keys are rejected from raw keyboard sequences so text and
credentials remain on ephemeral-input plus approval. Focus inspection returns
only role, subrole, identifier, title, and target application.

Global keyboard input additionally fails closed unless the exact process/PID and
application path are still frontmost and the focused target is readable
immediately before dispatch and immediately after every focus-changing event.
The VS Code Problems route does not use this input path: its disposable
same-bundle fixture extension owns a native `vscode.languages.getDiagnostics`
snapshot, and the daemon accepts only a fresh, redacted summary tied to the
exact fixture ID, bundle, PID, application path, workspace digest, and
provider. Diagnostic messages and private document content never cross that
snapshot or receipt boundary. Visual Problems-panel acceptance remains a
separate live GUI proof.

An opt-in physical-input mode is available only on a session lease. It uses a
bounded macOS session event tap, requires user-granted Accessibility and Input
Monitoring access, fails closed when the tap cannot be installed, and releases
on lease cleanup or daemon shutdown. It is not a hardware lock; mouse input
remains available for the status-item emergency quit path, and agent-generated
events are explicitly marked to pass through the tap.

Receipts and logs are owner-only, atomic, retention-bounded, and redacted.
Receipt publication is serialized across daemon/CLI processes and writes a
`0600` temporary file before content, flushes it, then atomically renames it.
Release-relevant receipts additionally populate a bounded hidden archive with
the newest proof per exact release dimension; this archive is not a second
unbounded log and does not change ordinary receipt-list retention.
Never persist credentials, OCR text, screenshots, image bytes, message bodies,
sources for permissions or secrets.

Authorization notices are a separate short-lived owner-only store, bounded to pending
requests and replay guards. They accept only safe summaries and allowlisted `codex://`
source references; raw commands, arguments, prompt bodies, passwords, tokens, private input,
and inherited environment values never cross this boundary. Socket peer PID, executable, and
signing metadata are daemon-observed and remain distinct from caller-declared context.
Missing or mismatched peer identity is `unverified`; `attested` is origin correlation only,
never a safety or approval decision. `resolve` records completion and never operates a native
Allow/Deny control. Inspect authorization context through the owner-only CLI; the transient
safety item does not display it or open a source.

External provider approvals are separately session-only and accept only a bounded provider,
provider instance, plan ID, exact SHA-256 plan digest, summary, risk, and expiry. The provider
receives only an operation ID and state. The private approval token stays inside Mac Control's
owner-only review path, and consumption repeats the exact binding before one successful use.
Denial, expiry, mismatch, and replay fail closed. These records never authorize browser
execution by themselves and are not presented by the transient menu-bar safety item.

Warm-path manifests are owner-only, app/task/version/target scoped, and retain
only route metrics, permission names, freshness, and verification metadata.
Unmeasured or stale candidates are not eligible. Accessibility tree and audit
responses are bounded and redacted; AX values, private text, screenshots, and
OCR are excluded, and receipt persistence retains only their evidence kinds.
A normal capability probe may queue a coalesced read-only audit only after it
observes a running native app. It cannot launch or activate an app, dispatch an
action or input, inspect `web_content`, or grant execution authority.

Browser DOM automation is outside mac-control. iPhone Mirroring is not a
supported mac-control surface; do not infer provider parity or lease ownership
for it.

Cross-provider trace completion is correlation, not execution authority. Its
random credential is short-lived, permits one logical completion with identical
idempotent retry, crosses only the owner socket through stdin, and is stored only
as a SHA-256 digest in an owner-only bounded store. The CLI caps completion stdin
at 8 KiB and accepts no trailing arguments. Completion accepts an exact metadata
allowlist and persists digests of
provider observation/session/turn/tab identifiers; raw URLs, titles, DOM,
page content, selectors, credentials, and provider IDs are rejected or never
persisted. A browser completion is `orchestrator_declared`, not
`browser_provider_attested`, until the browser provider supplies its own signed
or transport-attested evidence.
