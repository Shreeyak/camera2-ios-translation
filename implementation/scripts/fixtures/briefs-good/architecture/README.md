# Architecture — Fixture

## Primary-owner rule
Every architectural decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content.

## Phase coverage table
| domain file | primary concern(s) | implementing stage(s) |
|---|---|---|
| 01-system-purpose.md | 01-system-shape | 01 |

## Interactions considered
- **concurrency×lifecycle**: scenePhase `.inactive` × outstanding `MTLCommandBuffer` → gate GPU submission (ADR-09). Shape: `concurrency×lifecycle`.
- **storage×consumer**: consumer registration × texture storage mode → transition on attach. Shape: `storage×consumer`.
- **error×recovery**: watchdog × retry → disarm before retry. Shape: `error×recovery`.
