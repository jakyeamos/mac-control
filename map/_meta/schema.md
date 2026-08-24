# mac-control map schema

| Field | Allowed values | Meaning |
| --- | --- | --- |
| `type` | `cluster`, `object`, `source-layer`, `support-layer`, `unknown` | Catalog noun kind |
| `universe` | `live`, `leftover`, `ghost`, `unknown` | Whether the source is in force |
| `status` | `stub`, `verified`, `stale` | Citation/freshness state |
| `access_tier` | `owner-only`, `private`, `unknown` | Distribution boundary |

Provider evidence must identify its provider and cannot be upgraded to direct
visible-behavior proof without exercising the claimed surface.

