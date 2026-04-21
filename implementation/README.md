# implementation/

Pipeline artifacts for turning `domain-revised/` + `ios-platform-guide/` into per-stage implementation briefs for Claude Code CLI.

Designed per `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`.

## Subdirectories

- `prompts/` — system prompts for Agent 3 (Architect + Stage Mapper), Agent 4 (Architecture Review), Agent 5 (Brief Writer).
- `scripts/` — mechanical verification scripts (`verify-architecture.sh`, `verify-briefs.sh`) and fixtures.
- `architecture/` — Agent 3 output. 9 concern files + 4 register files + api-skeletons SwiftPM target.
- `stages/` — Agent 3 output. `stage-index.md` with YAML frontmatter per stage.
- `review/` — Agent 4 output. Green/Yellow/Red verdict + findings.
- `briefs/` — Agent 5 output. `stage-NN.md` corpus + `state-template.md` + `README.md` + `EXPECTATIONS.md` (human-facing per-stage verification guide).
- `building-prompts/` — session-boot prompts for the downstream Swift repo (Stage 01 / Stage 02 implementation, plus target-repo CLAUDE.md rewrite). Consumed by a fresh Claude Code session running in the implementation repo.

## Pipeline run order

1. Agent 3 produces `architecture/` and `stages/stage-index.md`.
2. `scripts/verify-architecture.sh` runs mechanical checks M1-M8. Must pass before Agent 4.
3. Agent 4 runs judgement-level review J1-J5; emits verdict in `review/`. Must be Green before Agent 5.
4. Agent 5 produces `briefs/`.
5. `scripts/verify-briefs.sh` runs mechanical checks M1-M5.
6. Claude Code (separate repo) consumes `briefs/` + reads `architecture/`, `domain-revised/`, and `ios-platform-guide/` as external reference.


## Simple explanation

Here's what was built in implementation/ — in plain terms.

  The problem being solved

  You have two inputs that describe what to build:
  - domain-revised/ — what the app should do (platform-neutral behavior: camera, processing, recording).
  - ios-platform-guide/ — how iOS does things (ADRs and gotchas for Swift 6, Metal, AVFoundation, etc.).

  What was missing: a way to turn those into per-stage build instructions that a coding agent (Claude Code CLI) can execute one stage at a time in a separate Swift repo — without the coding agent having to
   re-read and re-decide everything from scratch each stage.

  What was built

  A three-agent pipeline that produces those per-stage build instructions, plus two checker scripts that catch mistakes before a human ever has to.

  domain-revised/ + ios-platform-guide/
          │
          ▼
     Agent 3 (Architect)
          │  produces: architecture/ (9 concern files + 4 register files
          │            + a compiling Swift skeleton) and stages/stage-index.md
          ▼
     verify-architecture.sh  ← mechanical checks (M1–M8)
          │
          ▼
     Agent 4 (Reviewer)
          │  emits Green / Yellow / Red verdict
          ▼
     Agent 5 (Brief Writer)
          │  produces: briefs/ (one file per build stage)
          ▼
     verify-briefs.sh  ← mechanical checks (M1–M5)
          │
          ▼
     Claude Code CLI (separate repo) builds the Swift app stage-by-stage

  What's actually in the directory

  - implementation/prompts/ — three LLM system prompts: the Architect, the Reviewer, the Brief Writer.
  - implementation/scripts/ — two bash scripts (verify-architecture.sh, verify-briefs.sh) plus shared helpers. They're "grep-based test suites" for the agent outputs.
  - implementation/scripts/fixtures/ — tiny example directories used to test the scripts. One "good" example that should pass every check, plus one "bad" example per check that should fail just that one
  check (TDD).
  - implementation/architecture/, stages/, review/, briefs/ — populated by the pipeline. `architecture/` holds the 9 concern files + 4 register files + the compiling Swift skeleton; `stages/stage-index.md` is the 12-stage ordered walk; `review/` carries the Green verdict; `briefs/` carries the 12 per-stage implementation briefs + `EXPECTATIONS.md`.
  - implementation/building-prompts/ — consumer-side session-boot prompts for the downstream Swift repo.

  The clever bits

  1. Mechanical vs judgement split. The scripts enforce things machines can check (file exists, YAML is valid, Swift compiles, cross-references resolve). Agent 4 only has to judge the things machines can't
   (is this decision sound? are these interactions real or contrived?).
  2. A compiling Swift skeleton. Agent 3 doesn't just write prose about types — it emits a SwiftPM package with real actor / func declarations (bodies stubbed with fatalError("Stage N")). swift build runs
  against it, so signatures can't silently drift.
  3. Scaffolding pairs. Each build stage can introduce a "temporary crutch" (e.g., "just stop the camera on background") as long as a later stage explicitly retires it and replaces it with the real thing.
  The script checks that every introduced scaffold has a retirement.
  4. Per-stage test classes. Every test is tagged TESTABLE, FLAGGED (can't test yet, retry in stage N), HITL (needs a physical device), or DEFERRED. No silent "tests skipped."
