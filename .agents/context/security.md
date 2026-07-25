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

Receipts and logs are owner-only, atomic, retention-bounded, and redacted.
Never persist credentials, OCR text, screenshots, image bytes, message bodies,
selector values, or private input. AIOS and Career Ops are not authority
sources for permissions or secrets.
