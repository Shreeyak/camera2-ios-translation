# implementation/

Pipeline artifacts for turning `domain-revised/` + `ios-platform-guide/` into per-stage implementation briefs for Claude Code CLI.

Designed per `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`.

## Subdirectories

- `prompts/` — system prompts for Agent 3 (Architect + Stage Mapper), Agent 4 (Architecture Review), Agent 5 (Brief Writer).
- `scripts/` — mechanical verification scripts (`verify-architecture.sh`, `verify-briefs.sh`) and fixtures.
- `architecture/` — Agent 3 output. 9 concern files + 4 register files + api-skeletons SwiftPM target.
- `stages/` — Agent 3 output. `stage-index.md` with YAML frontmatter per stage.
- `review/` — Agent 4 output. Green/Yellow/Red verdict + findings.
- `briefs/` — Agent 5 output. `stage-NN.md` corpus + `state-template.md` + `README.md`.

## Pipeline run order

1. Agent 3 produces `architecture/` and `stages/stage-index.md`.
2. `scripts/verify-architecture.sh` runs mechanical checks M1-M8. Must pass before Agent 4.
3. Agent 4 runs judgement-level review J1-J5; emits verdict in `review/`. Must be Green before Agent 5.
4. Agent 5 produces `briefs/`.
5. `scripts/verify-briefs.sh` runs mechanical checks M1-M5.
6. Claude Code (separate repo) consumes `briefs/` + reads `architecture/` and `ios-platform-guide/` as external reference.
