# Phase 0 baseline report

This is the human-readable interpretation of the locked
[`mac-control-phase-0-v1`](./phase-0-corpus-v1.json) corpus. The machine
aggregation is [`phase-0-baseline-v1.md`](../results/phase-0-baseline-v1.md),
with the same result available as
[`phase-0-baseline-v1.json`](../results/phase-0-baseline-v1.json).

## Evidence status

- Five comparison sets are pairable under the shared context contract.
- Ten lane groups have measured samples.
- Every measured sample passed its task oracle.
- There were no recoveries or user-help events in the selected records.
- No comparison is marked `insufficient_evidence`.

The report intentionally keeps mature direct baselines separate from Computer
Use comparisons. A direct system read is the correct comparator for a narrow
preference query; Computer Use is the correct comparator for interaction tasks
without a mature direct interface.

## Results

| Task family | Comparison | Mac Control median | Comparison median | Result |
| --- | --- | ---: | ---: | --- |
| Full Keyboard Access inspection | Direct system read | 65.142 ms | 10.333 ms | Direct read faster |
| Focus navigation | Computer Use | 140.501 ms | 8,695.778 ms | Mac Control faster |
| Focus navigation | Direct UI scripting | 134.062 ms | 492.089 ms | Mac Control faster |
| Two-step focus batch | Direct UI scripting batch | 182.800 ms | 630.367 ms | Mac Control faster |
| Finder semantic scroll | Computer Use | 553.985 ms | 12,885.493 ms | Mac Control faster |

These are task-specific medians, not a universal speed score. They establish
both required baselines: Mac Control has a longitudinal comparison surface for
future builds, and it has an equivalent Computer Use comparison for agent
tasks.

## Interpretation

The evidence supports the routing principle rather than a blanket “Mac
Control is always faster” claim:

- Use a mature direct interface when it directly answers the task.
- Use Mac Control for verified semantic interaction when no mature direct
  interface exists.
- Preserve Computer Use as an explicit provider fallback when Accessibility is
  unavailable, ambiguous, or produces no observed change.

The report measures end-to-end verified action intervals for the interaction
comparisons. Setup and reset are outside the timer, while oracle verification,
provider execution, and required cleanup remain inside the measured boundary.

## Deliberate Phase 1 extensions

The corpus does not claim evidence for every possible task. App activation has
live foreground readback evidence but does not yet have a canonical paired
benchmark record. Notes semantic scroll has an explicit AX-unavailable result
that recommends Computer Use, but no latency sample. Both are preserved as
Phase 1 coverage and provider-handoff fixtures rather than being counted as
successful Phase 0 comparisons.

Phase 0 is therefore complete as a measurement foundation. Phase 1 owns
capability coverage, fresh audits, profile invalidation, and provider fallback
behavior.
