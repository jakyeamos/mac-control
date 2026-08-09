# Architecture and boundaries

`macctl` is a command-first local macOS control plane. The `MacCtlCore`
library owns workflow validation, approval plans, receipts, release checks,
and platform adapters. `macctl` is the user-facing CLI. `macctld` is the
per-user daemon that owns the GUI session and serves an owner-only Unix socket.

The daemon is the authority for live permissions, transport, receipt storage,
and execution. The CLI may prepare, request, and inspect operations but must
not bypass daemon validation. Apple frameworks are the platform boundary:
AppKit, ApplicationServices, CoreGraphics, ScreenCaptureKit, Vision, and
Foundation. There are no third-party runtime dependencies in the baseline.

The workflow boundary is `prepare -> approve -> execute -> verify`. Receipts
are the durable evidence boundary. TCC permissions, launchd, and the Aqua
session remain user-controlled external systems; unsupported providers are not
silently substituted into this boundary.

Do not make AIOS, Career Ops, a remote API, or a TCP listener a runtime
dependency. Callers may invoke this local control plane; ownership of their
workflow and credentials remains outside this repository.
