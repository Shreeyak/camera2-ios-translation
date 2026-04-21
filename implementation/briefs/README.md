# Briefs — implementation-stage corpus

## Contents

- `stage-01.md` … `stage-12.md` — twelve per-stage briefs, 12-section schema each. Authoritative spec for the stage an agent is implementing.
- `state-template.md` — initial `state.md` shape. Claude Code seeds `CameraKit/state.md` from this at Stage 01.
- `EXPECTATIONS.md` — human-facing per-stage verification guide. Distills each stage's "What you'll see / How to verify / Regression signals" from the briefs' §3 / §8 / §10 / §11, written for a reviewer who is not going to open the full brief. Use this for PR review and device walkthroughs; it is not a substitute for the brief when implementing.
- `README.md` — this file.

## Source of truth

For stage N, your current brief (`stage-NN.md`) is the authoritative source for this stage. If the brief references an architecture anchor or domain section, read it. If a prior brief or the architecture appears to contradict the current brief, the current brief wins — note the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed with the current brief.

## Implementer read-path

For stage N, your context budget is: this brief + cited architecture refs + cited domain refs + `api-skeletons/` files for files you'll touch + `state.md` from the prior stage. Reading more is not forbidden; it is simply not necessary and will dilute focus.

## Stage-kickoff template

At the start of every stage, Claude Code:
1. Reads `state.md` (from prior stage).
2. Runs pre-flight check: for every entry under "Scaffolding still live" in state.md, `grep -r <slug> Sources/` must find the slug in code. Mismatch → halt, escalate.
3. Reads the current brief.
4. Reads cited architecture + domain refs + `api-skeletons/` for named files.
5. Implements per the brief.
6. Runs the per-stage verification gate (build + tests).
7. Updates `state.md` per §12 of the brief.
8. Commits.

## Glossary

- **scaffold slug** — a short kebab-case identifier (e.g., `02:crude-inactive-stop`) naming a temporary implementation crutch introduced in stage NN and removed in a later MIGRATION stage. Format is `NN:slug`. The slug appears as a code comment wherever the scaffold lives in source.
- **migration stage** — a stage of `type: MIGRATION` in stage-index.md. Its purpose is to replace ≥1 scaffold with a production primitive. It does not add user-visible features; it preserves all prior behavior while retiring scaffolding.
- **TESTABLE** — a test that can be written and run automatically in this stage with the current build target and simulator.
- **FLAGGED** — a test whose automation prerequisites (type, API, or device) do not exist yet; must be retried in a specified future stage (syntax: `FLAGGED: <test> — retry in stage NN`).
- **HITL** — Human-In-The-Loop: a test requiring a physical device or manual observation. Must carry `device: <model>`.
- **DEFERRED** — a test that cannot be automated and will not become automatable within the stage corpus; evidence recorded manually.
