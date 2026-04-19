# Architecture — Fixture

## Primary-owner rule
Every architectural decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content.

## Phase coverage table
| domain file | primary concern(s) | implementing stage(s) |
|---|---|---|
| 01-system-purpose.md | 01-system-shape | 01 |

## Interactions considered

- Some interaction without a shape tag.
