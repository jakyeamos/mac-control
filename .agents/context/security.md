# Security and execution constraints

The daemon uses a per-user owner-only Unix socket. It must not expose TCP,
accept credentials, or accept secret values in command-line arguments. TCC
permissions (Accessibility, Input Monitoring, Post Events, Screen Recording)
remain user-controlled; the tool reports missing grants and never bypasses
them.

Mac Control does not create an additional execution-consent layer. The calling
agent applies its ordinary human-interruption policy before dispatch, including
for private data, destructive or external effects, credentials, permission or
security changes, and materially ambiguous targets. The daemon enforces exact
targets and plan digests, caller-declared finite deadlines, replay resistance,
pre-dispatch state validation, cancellation, postconditions, and redacted
receipts. Background mode must name a target app and preserve the foreground
application; it cannot fall back to global input, activation, or coordinate
clicks. Ephemeral text may arrive only over the owner-only socket and must not
be returned or persisted.

Direct keyboard navigation is a separate fast path bounded by an explicit,
short-lived, single-active lease. App-scoped leases bind to the foreground
application and process; session-scoped leases follow foreground changes only
when that state can be read. Every key revalidates lease expiry, Post Events,
and focus scope. Full Keyboard Access is never enabled at daemon startup;
`keyboard enable` writes and then verifies the user preference. Mac Control
does not add a confirmation shim; the governing agent policy owns any required
conversation with the user before invoking it.
Bare printable keys are rejected from raw keyboard sequences so text and
credentials remain on the structured ephemeral-input path. Focus inspection returns
only role, subrole, identifier, title, and target application.

An opt-in physical-input mode is available only on a session lease. It uses a
bounded macOS session event tap, requires user-granted Accessibility and Input
Monitoring access, fails closed when the tap cannot be installed, and releases
on lease cleanup or daemon shutdown. It is not a hardware lock; mouse input
remains available for the status-item emergency quit path, and agent-generated
events are explicitly marked to pass through the tap.

Receipts and logs are owner-only, atomic, retention-bounded, and redacted.
Never persist credentials, OCR text, screenshots, image bytes, message bodies,
sources for permissions or secrets.

Authorization notices are a separate short-lived owner-only store, bounded to pending
requests and replay guards. They accept only safe summaries and allowlisted `codex://`
source references; raw commands, arguments, prompt bodies, passwords, tokens, private input,
and inherited environment values never cross this boundary. Socket peer PID, executable, and
signing metadata are daemon-observed and remain distinct from caller-declared context.
Missing or mismatched peer identity is `unverified`; `attested` is origin correlation only,
never a safety or approval decision. `resolve` records completion and never operates a native
Allow/Deny control. The Control Center may open a source only through a registered Codex
opener, and otherwise displays the reference without opening it.

Warm-path manifests are owner-only, app/task/version/target scoped, and retain
only route metrics, permission names, freshness, and verification metadata.
Unmeasured or stale candidates are not eligible. Accessibility tree and audit
responses are bounded and redacted; AX values, private text, screenshots, and
OCR are excluded, and receipt persistence retains only their evidence kinds.

Browser DOM automation is outside mac-control. iPhone Mirroring is not a
supported mac-control surface; do not infer provider parity or lease ownership
for it.
