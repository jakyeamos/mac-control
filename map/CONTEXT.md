# mac-control system map

Status: proposal catalog; no child Compass has been ratified from this map.

## Decision record

- Selected form: ICM System map. mac-control combines guarded invocation,
  focus/display sessions, diagnostics/provider evidence, and distribution/
   agent contract surfaces.
- Rejected smaller form: root context alone. The owner-only safety and
  provider-evidence boundary needs an explicit walkable catalog.
- Authority: the root Compass, source contracts, tests, and direct runtime
  evidence.
- Existing user gate: the active mac-control root quiz remains the intent gate.

## Universe inventory

- **live candidates:** `Sources/`, `Tests/`, `docs/`, `scripts/`, `skills/`,
  fixtures, and benchmarks.
- **unknown:** whether guarded invocation and focus/display should be separate
  child Compasses, and where provider evidence belongs.
- **support layers:** tests, fixtures, benchmarks, docs, and scripts are not
  children by directory presence alone.
- **ghost:** no ghost implementation is asserted here.

## Proposed target tree

```text
map/
├── AGENTS.md
├── CONTEXT.md
├── _meta/schema.md
├── _templates/object.md
└── objects/
    ├── CONTEXT.md
    └── _index.md
```

Candidate clusters:

- **guarded-invocation** — owner-only command routing and guarded execution.
- **focus-display-sessions** — focus, display, and session state boundaries.
- **diagnostics-provider-evidence** — diagnostics and provider-specific
  evidence without treating providers as visible-behavior authority.
- **distribution-agent-contract** — skills, docs, packaging, and agent-facing
  contract surfaces.

## First-order impact

- **Hits:** changes to authorization, visible control, evidence provenance, or
  distribution contracts hit the relevant cluster and root Compass.
- **Does not hit:** provider evidence alone does not prove visible behavior.

## Open decisions

1. Which candidate clusters have independently meaningful purposes?
2. Should native app and CLI remain one invocation plane?
3. What provider boundary is authoritative for visible verification?

