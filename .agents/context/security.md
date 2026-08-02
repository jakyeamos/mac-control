# Security and approval constraints

The daemon uses a per-user owner-only Unix socket. It must not expose TCP,
accept credentials, or accept secret values in command-line arguments. TCC
permissions (Accessibility, Input Monitoring, Post Events, Screen Recording)
remain user-controlled; the tool reports missing grants and never bypasses
them.

Sensitive workflows require `prepare -> approve -> execute -> verify` with a
short-lived, single-use token. Background mode must name a target app and
must preserve the foreground application; it cannot fall back to global input,
activation, coordinate clicks, or iPhone Mirroring. Ephemeral text may arrive
only over the owner-only socket and must not be returned or persisted.

Direct keyboard navigation is a separate fast path bounded by an explicit,
short-lived, single-active lease. App-scoped leases bind to the foreground
application and process; session-scoped leases follow foreground changes only
when that state can be read. Every key revalidates lease expiry, Post Events,
and focus scope. Full Keyboard Access is never enabled at daemon startup;
`keyboard enable --confirm` writes and then verifies the user preference.
Bare printable keys are rejected from raw keyboard sequences so text and
credentials remain on ephemeral-input plus approval. Focus inspection returns
only role, subrole, identifier, title, and target application.

Receipts and logs are owner-only, atomic, retention-bounded, and redacted.
Never persist credentials, OCR text, screenshots, image bytes, message bodies,
sources for permissions or secrets.

Browser DOM automation is outside mac-control. iPhone Mirroring is a separate
shared-input surface with its own lease and does not inherit keyboard leases.
