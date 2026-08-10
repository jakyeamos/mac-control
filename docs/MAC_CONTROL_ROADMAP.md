# Mac Control roadmap

Status: Phase 0 complete; Phase 1 active

Mac Control has two equal goals:

1. Make macOS control faster, more accessible, safer, and more reliable for
   an agent.
2. Prove the improvement against equivalent work performed without Mac
   Control.

The unit of progress is a phase exit gate, not a growing list of isolated
fixes. Only one phase is active at a time. Work that does not advance the
active phase is recorded for the owning later phase unless it is a safety or
correctness blocker.

## North-star outcome

For an eligible macOS task, an agent can resolve a named target, choose the
fastest currently verified provider route, execute without unintended focus
changes, verify the task-specific postcondition, and return a redacted,
machine-readable result. If Accessibility is unavailable or produces no
verified change, Mac Control explicitly hands off to Computer Use with fresh
state requirements. The same task can be replayed through Mac Control,
Computer Use, and a hybrid route under a shared oracle.

## Phase 0 — Measurement and contract foundation

Status: completed. Canonical corpus:
[`phase-0-corpus-v1`](../benchmarks/control-comparison/phase-0-corpus-v1.json).
Evidence report:
[`phase-0-baseline-report`](../benchmarks/control-comparison/phase-0-baseline-report.md).

Objective: establish one source of truth for what “faster” and “better” mean.

Goal 1 deliverables:

- Stable action outcomes, provider attribution, verification, focus policy, and
  failure/handoff semantics.
- A clean separation between hot-path probing, broad capability audits, and
  task-specific verification.
- Redacted receipts and versioned context that never persist raw UI content,
  stale AX references, or sensitive selectors.

Goal 2 deliverables:

- A canonical task corpus with documented starting states and shared oracles.
- Three comparable lanes: best non-Mac-Control baseline, Computer Use, and
  Mac Control; add a hybrid lane when fallback behavior is under test.
- End-to-end verified completion time as the primary metric, with median,
  p95, success rate, recoveries, tool calls, and provider handoffs retained.

Exit gate:

- Every benchmark record has matching task, app, target, starting-state,
  timing-scope, implementation, build, and provenance context.
- A run cannot pass from an API success alone; the shared oracle must pass.
- The benchmark can show both a Mac Control improvement-over-time comparison
  and a Mac Control-versus-Computer-Use comparison without mixing the lanes.

Exit evidence: the locked corpus contains five comparable comparison sets and
ten measured lane groups. Every selected measured sample passed its shared
oracle, and the machine summary contains no insufficient-evidence comparison.
Activation and Notes provider-handoff records are explicitly carried into
Phase 1 rather than being counted as Phase 0 success.

## Phase 1 — Capability coverage and accessibility

Status: active. The first work is the sequential app/archetype audit and its
versioned capability-profile evidence.

Objective: make Mac Control know what it can control before it attempts a
consequential action.

Goal 1 deliverables:

- Sequential, read-only deep audits across the applicable app set and major
  app archetypes: AppKit, SwiftUI, Electron, browsers, and System Settings.
- Versioned capability profiles keyed by bundle identity, app version, OS and
  provider state, and UI/tree signature.
- Stable locator and identity descriptors instead of raw AX element caches.
- Explicit promotion, demotion, invalidation, and stale-element handling.
- Provider-aware scroll and action fallback, including Computer Use handoff
  after AX unavailable, ambiguous targeting, or no observed change.

Goal 2 deliverables:

- Positive, negative, and ambiguous capability evidence in the benchmark
  corpus.
- Coverage reports that distinguish verified, proposed, unsupported, and
  blocked capability states.

Exit gate:

- Each audited app has a profile outcome and evidence freshness state.
- A tree truncation, version change, provider change, stale element, failed
  action, or failed verification cannot leave a capability promoted as fresh.
- The audit remains sequential and bounded; it does not open all apps at once
  or dispatch consequential actions merely to discover support.

Phase 1 evidence snapshot:

- The sequential run `815D6B2A-8C7E-4B8C-9787-3F7E478EAD3C` processed all 24
  catalog entries with `max_concurrency: 1`, `read_only: true`, and no app
  launches or dispatched actions.
- Nine targets produced valid, complete broad profiles: Finder, System
  Settings, Notes, Messages, Google Chrome, Discord, Docker, Pronto, and
  WhatsApp. Chrome and Discord used bounded windowed-page traversal after
  recursive traversal was insufficient; their coverage was complete.
- ChatGPT and Spotify initially blocked on manifest version mismatch. Direct
  read-only audits refreshed both identities and persisted valid complete
  profiles for the currently running versions. The stale immutable run remains
  unchanged, preserving the invalidation evidence.
- Thirteen targets were `not_observed` because they were not running. The
  bounded audit did not launch them, so they remain evidence-blocked rather
  than promoted by inference: Terminal, TextEdit, Preview, Mail, Calendar,
  Xcode, Code, Claude, Obsidian, zoom.us, Cursor, Activity Monitor, and
  AirPort Utility.
- A scheduler defect found during the run was fixed: resumable `not_observed`
  entries no longer consume a batch before untouched `pending` entries. The
  pending-first ordering has a regression test and was exercised live when the
  final four targets were classified without launches.
- Current live verification after installation and daemon reload reports a
  healthy, identity-matched daemon with required permissions granted, no active
  lease or action, and ChatGPT preserved as the foreground app.
- Fresh task-specific fast probes were completed sequentially for the 11
  currently running representative apps: Finder, System Settings, Notes,
  Messages, Google Chrome, Discord, Docker, Pronto, WhatsApp, ChatGPT, and
  Spotify. All returned a valid cached profile with a Computer Use handoff
  provider. Semantic scroll was promoted only where the probe had positive
  evidence; ChatGPT and Spotify remain marked for deeper task-specific audit.
- The probes themselves were read-only and dispatched no consequential app
  actions. Separate live task verification exercised System Settings focus and
  Finder scroll. Focus passed through Mac Control, direct UI scripting, and
  Computer Use; Finder scroll failed closed with a machine-readable
  Computer Use recommendation and fresh-state requirement rather than being
  silently retried.

Phase 1 remains active until the not-observed targets have legitimate
already-running evidence and task-specific capability verification is added;
the audit must not launch apps or perform consequential actions merely to close
the coverage count.

## Phase 2 — Fast path and warm performance

Status: benchmark pilot started; Phase 1 remains the active phase until its
coverage exit gate is satisfied.

Objective: make the verified route materially faster without weakening checks.

Goal 1 deliverables:

- The route sequence is: small fast probe, cached broad profile, task-specific
  capability verification, then profile update or invalidation.
- Already-foreground and same-process actions use the shortest safe path.
- App-scoped leases and bounded batches reduce repeated navigation overhead
  while retaining per-step revalidation.
- Route benchmarks execute inside the daemon and report real route provenance.

Goal 2 deliverables:

- Cold, warm, batched, and fallback timings are measured separately.
- p50 and p95 targets are set once for the corpus and applied consistently
  across Mac Control versions.
- Every speed claim includes verified success and safety outcomes, not only
  latency.

Exit gate:

- Warm-path improvements are reproducible across representative archetypes.
- No speed optimization increases focus loss, stale-target execution,
  verification ambiguity, or unsafe provider fallback.
- The Mac Control lane can be compared to Computer Use under the same
  end-to-end timing scope.

Phase 2 pilot evidence:

- The current paired report is
  [`phase2-summary-v3`](../benchmarks/results/phase2-summary-v3.md),
  with raw records retained beside it. The atomic System Settings focus task
  passed 3/3 in each lane: Mac Control median 134.924 ms (p95 135.900),
  direct UI scripting median 479.491 ms (p95 479.767), and Computer Use
  median 11,814.550 ms (p95 12,859.225), all measured with the same
  `agent_action_plus_verification` boundary. Mac Control was 3.55x faster
  than direct UI scripting and 87.56x faster than Computer Use for this
  representative task.
- The two-step System Settings batch task passed 7/7 in both measured lanes:
  Mac Control median 195.968 ms (p95 240.259) versus direct UI scripting
  median 563.045 ms (p95 580.389). Mac Control was 2.87x faster, validating
  the bounded-batch warm-path direction without sacrificing verification.
- Finder semantic scroll remains insufficient evidence: Mac Control returned
  `action_failed` with `fresh_state_required: true` and recommended Computer
  Use; the hybrid lane then stopped because the current Finder main-window
  target was ambiguous. No unverified or caller-supplied scroll duration was
  persisted.
- Google Chrome added a second paired archetype: Mac Control passed 3/3 with
  a 196.584 ms median versus Computer Use at 1,358.977 ms, a 6.91x speedup
  under the same end-to-end timing boundary. Pronto independently passed 3/3
  Mac Control focus samples, but its Computer Use state did not expose a
  stable focused-element oracle, so it remains unpaired evidence.
- Notes exposed a native-app verification gap: the keyboard route returned
  `verification_unavailable`/`foreground_only`. The benchmark harness now
  persists this as a blocked record instead of dropping the failed setup. No
  Computer Use Tab action was dispatched against the focused editable note.

## Phase 3 — Agent orchestration and adaptive provider choice

Objective: make the agent choose and recover from routes intelligently.

Goal 1 deliverables:

- Agent-visible capability and route recommendations with confidence and
  freshness metadata.
- Explicit handoff outcomes such as `action_unavailable`,
  `action_failed`, `no_observed_change`, and `verification_unavailable`.
- Fresh-state Computer Use recovery for provider handoff; no blind universal
  ladder and no hidden global-input fallback.
- Target identity, foreground focus, execution route, and postcondition remain
  separate throughout the action.

Goal 2 deliverables:

- Full-task comparison of Mac Control only, Computer Use only, and hybrid
  orchestration.
- Recovery cost and handoff correctness are reported alongside speed and
  success rate.
- Background-target fixtures prove that the named target changes while an
  unrelated foreground app remains unchanged.

Exit gate:

- The agent selects the provider from current evidence rather than guessing.
- A failed provider produces an actionable handoff, and the receiving
  provider re-resolves and verifies from fresh state.
- Hybrid execution improves verified completion without increasing safety or
  focus-preservation failures.

## Phase 4 — Longitudinal proof and default release posture

Objective: turn Mac Control into a maintained default control plane rather
than a one-time benchmark win.

Goal 1 deliverables:

- Release gates cover packaged identity, daemon health, permissions,
  receipts, focus safety, capability freshness, task control, and approval
  fail-closed behavior.
- The benchmark matrix runs sequentially across apps, tasks, providers, and
  cold/warm states.
- Version changes automatically identify routes and profiles that require
  re-audit or rebenchmarking.

Goal 2 deliverables:

- A longitudinal report shows Mac Control improvements across builds and
  comparative results against Computer Use.
- Claims are limited to task families and app archetypes with live evidence;
  missing GUI/provider evidence remains explicitly blocked.
- The default route policy is based on verified advantage, not preference.

Exit gate:

- Mac Control or the hybrid route wins on verified completion time and/or
  success for the supported task portfolio without a safety regression.
- Regression reports are reproducible from retained redacted benchmark
  records.
- Release eligibility and capability coverage are visible to the agent and to
  maintainers.

## Execution rules

- Phase 0 is closed; Phase 1 is the only active phase.
- The 24-app set is audited sequentially, never as a requirement to launch all
  apps simultaneously.
- “Ideal app state” remediation is outside this roadmap unless a benchmark
  fixture explicitly requires it.
- iPhone Mirroring is outside Mac Control scope.
- Browser DOM/CDP remains in a browser connector; Mac Control owns OS-level
  focus, native controls, dialogs, shortcuts, and verification boundaries.
- Screenshots and Vision are escalation routes, not the default.
- A phase can carry blocked evidence forward, but it cannot silently convert
  blocked or proposed capability into verified support.

## Whole-program success definition

The program is successful when Mac Control is the agent’s normal first choice
for eligible macOS actions, the hybrid route recovers cleanly when needed, and
the benchmark system can demonstrate—task by task and build by build—that this
choice improves verified completion speed, accessibility coverage, and
reliability without sacrificing focus or safety.
