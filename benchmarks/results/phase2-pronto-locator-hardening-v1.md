# Phase 2 Pronto locator-hardening evidence

Date: 2026-08-10

## Read-only audit

- Application: Pronto
- Audit depth: `deep_read_only`
- Audit state: `valid`
- Tree nodes: 8,659
- Tree truncated: `false`
- Reported actionable `AXScrollArea` locator count: 1
- Locator identity digest: `d5badfe1c715e234f13e1ce5b05d18e3d2222978a6b320a47472554f5c222a9f`
- Ancestor digest: `fd5c184a2eeafe32e1070cf08a26abb192c390c562c29ae6daf3eca3850f9c6f`
- Geometry digest: `091d3ef3d7889e329b2f4545d38bed76d2a4411cec9087b3a890f87c63d626a6`

The audit persisted only redacted identity, ancestor, and geometry digests.
No app was launched and no input was dispatched by the audit.

## Live action probe

The selector was re-resolved with role `AXScrollArea` plus all three digests.
The daemon uniquely resolved the target, then returned `scroll_fallback_required`
with `failure_class: action_unavailable`, `fallback_allowed: true`,
`fresh_state_required: true`, `recommended_provider: computer_use`, and
`local_fallback_dispatched: false`. No local scroll action occurred.

## Interpretation

The geometry discriminator, application-window alias guard, bounded-resolution
error, and duplicate-promotion guard are covered by focused regression tests.
The complete read-only audit and live resolver now agree on one redacted
`AXScrollArea` locator. The profile deliberately keeps semantic scroll as a
candidate because the target exposes no directional AX scroll action; the live
action therefore reaches the provider boundary and emits the explicit
Computer Use handoff. This remains insufficient evidence for a Mac Control
scroll speed comparison because Mac Control produced zero verified samples.
