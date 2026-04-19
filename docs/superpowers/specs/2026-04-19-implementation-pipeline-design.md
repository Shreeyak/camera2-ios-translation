# Implementation Pipeline Design

> Status: draft, awaiting user review
> Date: 2026-04-19
> Precedes: implementation plan (to be written via `superpowers:write-plan`)

## Problem

The repo has an upstream 2.5-agent pipeline that ends at `domain-revised/` (manually reviewed, platform-neutral behavioral requirements):

- **Agent 1 (AUDIT)** — Android source → `audit/`
- **Agent 2 (EXTRACT)** — `audit/` → `domain/`
- **(manual review)** — `domain/` → `domain-revised/`

This spec defines the three agents that come next, replacing the current Agent 3 and Agent 4 prompts and introducing a new Agent 5:

- **Agent 3 (ARCHITECT + STAGE MAPPER)** — reads `domain-revised/` + `ios-platform-guide/`, produces `architecture/` (target iOS design) and `stages/stage-index.md` (ordered stage journey).
- **Agent 4 (ARCHITECTURE REVIEW)** — reads Agent 3's output, runs grep-based mechanical checks and judgement-based review, emits a Green/Yellow/Red verdict in `review/`. Gates Agent 5.
- **Agent 5 (BRIEF WRITER)** — reads reviewed architecture + stage index, produces `briefs/stage-NN.md` corpus as a single coherent run.

Claude Code CLI then implements the app stage-by-stage in a **separate repository**, reading `implementation/` and `ios-platform-guide/` from this repo as external reference.

## Scope and non-scope

**In scope**
- Defining Agents 3, 4, 5: inputs, outputs, quality bars, failure modes.
- Defining the stage-brief schema, `state.md` handoff, and per-stage gate.
- Defining the `implementation/` directory layout in this repo.

**Out of scope**
- The upstream Agent 1/2 pipeline.
- The Swift implementation repository itself (separate project).
- Concrete system prompts for Agents 3/4/5 (produced in the implementation plan).
- The target iOS architecture content (produced by Agent 3 at runtime).

## Constraints

1. Coding agent is **Claude Code CLI**. It reads briefs and architecture from `implementation/`, writes Swift and tests in a separate repo, runs builds, commits.
2. **Hard gate per stage**: build + unit tests must pass before the next stage begins. Tests that aren't possible at a given stage are explicitly flagged (not silently skipped).
3. **Heavy upfront design**: architecture + stage journey + review happen before any Swift is written.
4. **Starts from `domain-revised/`**. Upstream pipeline is fixed.

## Pipeline shape

```
domain-revised/ + ios-platform-guide/
    │
    ▼
[Agent 3: Architect + Stage Mapper]
    │
    ├── architecture/   (9 concern + 3 registers + api-skeletons/)
    └── stages/stage-index.md
    │
    ▼
[Agent 4: Architecture Review]
    │  runs: (a) mechanical grep checks, (b) judgement-based review
    └── review/   (Green / Yellow / Red verdict + findings)
    │
    ▼  (gate: verdict must be Green)
    │
[Agent 5: Brief Writer — single coherent run]
    │
    └── briefs/   (stage-01.md … stage-N.md + state-template.md + README.md)
    │
    ▼
[Claude Code, stage loop, in separate repo]
```

### Why Agent 5 is a single run, not per-stage

Stages are deeply interconnected: stage 3's scaffolding is retired in stage 7, stage 7's `Tests preserved:` list must name stage 3's actual tests, and each stage's `Starting state:` depends on what prior stages left behind. A Brief Writer running per-stage in parallel has no cross-stage context. A single run threads scaffolding→migration pairs, predicts entry `state.md` per stage, and avoids cross-stage contradictions.

### Stage structure (walking skeleton)

Stages are hybrid: some are **feature stages** (add user-visible capability, possibly via scaffolding shortcuts), some are **migration stages** (behavior preserved; structure moves toward target architecture).

**Cadence heuristic** (Agent 3 follows):
- No more than **2 consecutive FEATURE stages** before a MIGRATION stage, OR
- No stage may enter with more than **3 live scaffolds** in `state.md`.

Stage 1 must produce something visible (e.g., bare camera preview on screen with an empty bottom bar). Later stages rewire the walking skeleton toward the target architecture and add features incrementally.

## Agent 3 — Architect + Stage Mapper

### Inputs
- `domain-revised/*.md` (12 files + README + CHANGES)
- `ios-platform-guide/*.md` (6 files)
- System prompt: mapping rules, ADR citation/deviation discipline, cross-input interaction surfacing. Lists **three** canonical interaction examples (see "Interactions considered" below).

### Outputs — `architecture/`

Nine **concern files** (numeric prefix, prose + decisions inline) + three **register files** (no numeric prefix, structural indexes) + **`api-skeletons/`** (compiling stubs):

| File/dir | Kind | Purpose |
|---|---|---|
| `README.md` | register | Nav, cross-file interaction map, "Interactions considered" subsection, **Phase coverage table** (every `domain-revised/*` → stages that implement it) |
| `01-system-shape.md` | concern | Swift module/file map, target layout, public vs internal boundary, where each top-level type lives. **Most-cited file.** |
| `02-concurrency.md` | concern | Actor topology, queues, scenePhase gate, 12 domain invariants mapped to Swift 6 primitives. **Load-bearing.** Must include the concurrency contract table. |
| `03-camera-session.md` | concern | `AVCaptureSession` config, device/format selection, resolution, orientation, interruption, self-healing, background suspend/resume |
| `04-metal-pipeline.md` | concern | Per-frame Metal command graph, `CVMetalTextureCache`, RGBA16F working format, color-transform shader order, `FrameSet` schema, tracker downsample |
| `05-consumers.md` | concern | `PixelSink` registration, C++ interop, pool sizing, latest-wins mailboxes, natural-stream subscription with `.private`→`.shared` interaction |
| `06-capture-and-recording.md` | concern | Still capture + video recording (both paths); `AVAssetWriter`, IOSurface pool, NV12 compute pass, state machine, drain timeout, HEVC-only |
| `07-settings.md` | concern | Partial-update merge, ISO/exposure coupling, persistence, `ProcessingParameters` update path |
| `08-ui.md` | concern | SwiftUI root, `@Observable` ViewModel, two `MTKView`s, split preview, bottom bar, calibration sidebar, landscape-right |
| `09-errors-and-recovery.md` | concern | Error taxonomy + fatal/non-fatal classification + recovery state machine + exponential backoff + dual watchdog |
| `api-surface.md` | register | Swift SDK signatures index (data types, 16 methods, 4 callbacks). Prose summary + pointers into `api-skeletons/`. |
| `decisions.md` | register | Hybrid format: one-line entry for minor deviations; **full ADR-style (Context / Options / Consequences / Reversibility)** for consequential ones (load-bearing, irreversible, or structural). Full inline rationale stays in the concern file. |
| `open-questions.md` | register | Deferred U-## items (decided / deferred-to-phase / why). Quarantines what architecture did not decide. |
| `api-skeletons/` | compilable | Swift/C++ stubs with `fatalError("Stage N")` bodies. Locks signatures and isolation annotations, not behavior. Parsed as a SwiftPM target so `swift build` validates structure. |

**Principles:**
- Organize by iOS framework/subsystem, not behavioral concern.
- Three register files are structural indexes (non-numeric prefix signals the difference).
- Decisions inline + index in `decisions.md`.
- `api-skeletons/` converts prose signatures into compilable scaffolding — the single biggest leverage for Claude Code's per-stage job.

### Outputs — `stages/stage-index.md`

Single ordered file. Each stage is a YAML-frontmatter block + prose body:

```yaml
---
stage: 03
title: Rewire preview through Metal
type: MIGRATION          # FEATURE | MIGRATION
depends_on: [01, 02]
touches: [04-metal-pipeline, 08-ui]
scaffolding_introduced: []
scaffolding_retired: [01:AVCaptureVideoPreviewLayer]
tests_preserved: [01:preview-visible-within-2s, 02:engine-transitions-to-streaming]
---
```

Prose body holds `Visible:` description and notes. No `driver.sh` — tooling that needs the count uses `yq` on the frontmatter directly.

### Concurrency contract table (required subsection of `02-concurrency.md`)

Three columns; rows not fixed to invariants 1:1 — one primitive often enforces several.

| Mechanism | Invariants enforced | Failure mode if violated |
|---|---|---|
| (example) `CameraEngine` actor — serial execution context | I-1, I-2 (camera state mutations) | Two concurrent `open()` calls race; session ends in inconsistent state |

Every row must cite `ADR-##` or introduce a `D-##`. Mechanical check: no blank cells, every row cited.

### Interactions considered (required subsection of `README.md`)

5–10 entries. Agent 3's prompt names **three canonical examples** to orient it toward different shapes:

> **Ex1 (concurrency × lifecycle):** scenePhase `.inactive` × `MTLCommandBuffer` submission outstanding → Metal background rule; must gate submission before teardown.
> **Ex2 (storage × consumer):** U-13 natural-stream subscribability reversal × ADR-20 `.private`→`.shared` on consumer attach × G-25 → D-07: consumer registration must handle storage-mode transition or silently drops frames.
> **Ex3 (error × recovery):** HAL `ERROR_CAMERA_DEVICE` × recovery backoff × watchdog lifecycle → recovery must disarm watchdog before retry or self-arms into retry loop.

"No interaction" is a valid outcome.

### Forbidden
- No Swift code in prose files (signatures allowed in `api-surface.md`; full stubs in `api-skeletons/`).
- No reading of other directories.
- No silent deviations from `ios-platform-guide` ADRs.

### Quality bars

Split into two layers: **mechanical** (grep/tool-verifiable, can be run by a shell script) and **judgement** (Agent 4 interprets).

**Mechanical (5)**
- M1. Every file in `architecture/` table exists. Every numeric file has the expected number prefix.
- M2. Every `D-##` in `decisions.md` has a matching inline anchor in its owning concern file.
- M3. `swift build --package-path architecture/api-skeletons/` succeeds.
- M4. Every stage's `touches:` field names a real concern file.
- M5. Every `scaffolding_introduced` entry has a matching `scaffolding_retired` in a later stage's YAML; no cycles in `depends_on`.

**Judgement (5)**
- J1. Every `domain-revised/*` requirement maps to at least one architecture section (verified via Phase coverage table in README).
- J2. Every architecture decision cites an `ADR-##` or creates a `D-##` with rationale inline.
- J3. `02-concurrency.md` concurrency contract table has no blank cells; every row cited; primitives are plausible.
- J4. `README.md` "Interactions considered" has ≥5 entries spanning ≥2 interaction shapes (not all of the same kind).
- J5. Migration stages have non-empty `tests_preserved` and the named tests are plausible to exist by that stage.

## Agent 4 — Architecture Review

### Inputs
- `architecture/` (all files from Agent 3, including `api-skeletons/`)
- `stages/stage-index.md`
- `domain-revised/` + `ios-platform-guide/` (originals, for verification)
- System prompt: review criteria, verdict rubric

### Outputs — `review/`

```
review/
├── README.md         # top-level Green/Yellow/Red verdict + summary
├── mechanical.md     # M1-M5 pass/fail, output of grep/swift-build checks
├── judgement.md      # J1-J5 per-bar assessment with evidence
└── findings.md       # actionable issues (Yellow/Red only)
```

### Verdict rubric
- **Green**: all M1-M5 pass AND all J1-J5 pass. Agent 5 may run.
- **Yellow**: all M1-M5 pass; at least one J-bar is Yellow but none are Red (e.g., Interactions considered has only 4 entries, or one concern file has thin decision rationale). Agent 3 reruns with findings; Agent 5 blocked until Green.
- **Red**: any M-bar fails, OR any J-bar is Red (missing concern file, domain requirement unmapped, cycle in dependencies, `swift build` on api-skeletons fails). Agent 3 reruns.

### What Agent 4 does NOT do
- Does not read the Swift implementation repo (there is none yet).
- Does not re-decide architecture. Flags in `findings.md`; Agent 3 reruns.
- Does not produce briefs or state.md templates.

### Quality bars for Agent 4 itself
- Every M-bar and J-bar is checked, with evidence cited.
- Yellow vs Red distinction is consistent across runs.
- Findings are actionable (name file + section to fix).

## Agent 5 — Brief Writer

### Inputs
- `architecture/` (Green-verdict version only)
- `stages/stage-index.md`
- `review/` (context on what was flagged/fixed)
- `domain-revised/` (citation only)

### Outputs — `briefs/`

- `README.md` — **implementer read-path** (see below), glossary, cross-stage index
- `stage-01.md … stage-N.md` — one per stage, numbered 12-section schema
- `state-template.md` — initial shape for `state.md`

### Implementer read-path (required in `briefs/README.md`)

Hard context budget on what Claude Code reads per stage. One paragraph, verbatim:

> For stage N, read only: (1) this brief (`stage-NN.md`), (2) the architecture refs the brief cites by anchor, (3) the domain refs the brief cites, (4) the `api-skeletons/` files listed under "Files to create/modify", (5) your `state.md` from the prior stage. Do **not** read other briefs, other stage files, or architecture files the brief doesn't cite.

### Per-stage brief schema (numbered, grep-verifiable)

Every brief file has exactly these 12 sections, in this order, with the heading text verbatim:

```
# Stage NN — <title>

## 1. Frontmatter
Type: FEATURE | MIGRATION
Depends on: Stage X, Stage Y
Retires scaffolding from: Stage Z (description)   # migration only

## 2. Starting state
<what state.md should say entering this stage>

## 3. Goal
<what changes this stage; for migration: "behavior preserved">

## 4. Files to create / modify / delete
- create: Sources/... (permanent | scaffolding)
- modify: Sources/...
- delete: ...

## 5. Architecture refs
- architecture/XX-<name>.md#<anchor>

## 6. Domain refs
- domain-revised/XX-<name>.md

## 7. Contracts & invariants
- <invariant>  (ADR-## or G-##)

## 8. Tests to write
- TESTABLE: <test>
- FLAGGED: <test> — reason; retry in stage NN
- DEFERRED: <test> — manual; record evidence in state.md
- HITL: <test> — requires real device; device: iPhone 15 Pro

## 9. Tests preserved (must still pass)
<prior-stage tests by name>   # migration only

## 10. Acceptance criteria
- [ ] swift build passes, no new warnings
- [ ] all prior-stage tests pass
- [ ] new tests pass
- [ ] <stage-specific manual verification>

## 11. Verification steps
<concrete commands, Instruments templates, manual device checks>

## 12. State.md updates (Claude Code writes these)
- <what to append/mark after this stage>
```

Mechanical check (Agent 4 + Agent 5 both run): every stage file contains all 12 numbered headings in order.

### Testability classes (four, not three)

- **TESTABLE** — unit or integration; runs in the stage; blocks the gate if failing.
- **FLAGGED** — possible in principle but requires tooling the stage can't provide (e.g., Instruments). Must name the retry stage.
- **HITL** — requires a real device (not simulator). Must specify `device:` field. Verified manually; evidence recorded in `state.md`.
- **DEFERRED** — inherently manual, non-device (e.g., "output file has valid EXIF"). Evidence recorded in `state.md`.

### Forbidden
- No Swift code (that's what api-skeletons and Claude Code are for).
- No re-deciding architecture (escalate if unclear).
- No bundling multiple stages into one brief.

### Quality bars

**Mechanical (4)**
- M1. Every brief file contains all 12 numbered section headings, in order.
- M2. Every architecture ref anchor resolves (`architecture/*.md#<anchor>` exists).
- M3. Every `Retires scaffolding from:` points at a stage that has the matching `scaffolding_introduced` in its YAML.
- M4. Every test line matches one of the four classes; HITL lines have a `device:` field.

**Judgement (3)**
- J1. Every brief's "Starting state" is derivable from prior briefs' "State.md updates" (chain consistency).
- J2. Every migration stage's `Tests preserved:` names real prior-stage tests.
- J3. Coverage: every `domain-revised/*` requirement is referenced by at least one brief by the final stage.

## The handoff document — `state.md`

Lives in the implementation repo (the separate Swift project). Seeded from `state-template.md` at stage 1 start. Claude Code appends/updates at end of every stage. Committed per stage so it's diffable.

### Shape
- **Current stage:** last completed + next
- **What's built (permanent):** append-only
- **Scaffolding still live:** added by feature stages, removed by migration stages
- **Public API exposed so far:** cumulative
- **Tests on file:** each with status `PASS | FAILING | FLAGGED | HITL | DEFERRED`
- **Known quirks / deviations:** discovered during implementation
- **Decisions taken that weren't in briefs:** escalation trail
- **Open questions for next stage**

### Rules
- Append-only for "What's built" and "Tests on file"; entries mutate only via explicit `Retires:` or status transition.
- Any decision not in the brief is logged.
- Committed after every stage.

## Verification gate (Phase 2, per stage)

Enforced by Claude Code at the end of each stage in the implementation repo:

1. `swift build` / Xcode build — must pass, no new warnings.
2. `swift test` — all prior + new unit tests pass.
3. Static checks if configured.
4. Manual verification for FLAGGED / HITL / DEFERRED items — result recorded in `state.md` with evidence.

## Repo layout

The iOS app is built in a **separate repository**. This repo holds only pipeline artifacts that the implementation project reads as external reference.

```
ios-translation/                      (this repo)
├── domain-revised/                   (existing — input to Agent 3)
├── ios-platform-guide/               (existing — input to Agent 3; read by Claude Code)
├── implementation/                   (new — everything for this pipeline)
│   ├── prompts/
│   │   ├── agent-3-architect.md
│   │   ├── agent-4-review.md
│   │   └── agent-5-brief-writer.md
│   ├── architecture/                 (Agent 3 output)
│   │   ├── README.md
│   │   ├── 01-system-shape.md
│   │   ├── 02-concurrency.md
│   │   ├── 03-camera-session.md
│   │   ├── 04-metal-pipeline.md
│   │   ├── 05-consumers.md
│   │   ├── 06-capture-and-recording.md
│   │   ├── 07-settings.md
│   │   ├── 08-ui.md
│   │   ├── 09-errors-and-recovery.md
│   │   ├── api-surface.md
│   │   ├── decisions.md
│   │   ├── open-questions.md
│   │   └── api-skeletons/
│   │       ├── Package.swift         # makes skeletons parseable via SwiftPM
│   │       ├── Sources/CameraKit/*.swift
│   │       └── Sources/CameraCxx/*.{h,cpp}
│   ├── stages/                       (Agent 3 output)
│   │   └── stage-index.md
│   ├── review/                       (Agent 4 output)
│   │   ├── README.md
│   │   ├── mechanical.md
│   │   ├── judgement.md
│   │   └── findings.md
│   └── briefs/                       (Agent 5 output)
│       ├── README.md
│       ├── stage-01.md … stage-N.md
│       └── state-template.md
└── CLAUDE.md                         (existing)

<separate-repo>/                      (the Swift implementation, external)
├── Package.swift
├── Sources/CameraKit/...
├── Sources/CameraApp/...
├── Tests/...
└── state.md                          (Claude Code maintains here, diffable per stage)
```

Claude Code runs inside `<separate-repo>` and reads `ios-translation/implementation/` + `ios-translation/ios-platform-guide/` as external reference (absolute path or symlink).

## Known risks — mitigations and deferrals

### Addressed upfront
1. **`02-concurrency.md` is load-bearing.** Mitigated by the concurrency contract table + bar J3.
2. **Cross-input interaction surfacing.** Mitigated by required "Interactions considered" subsection + three canonical examples spanning different interaction shapes.
3. **Stage count unknown at design time.** Mitigated by YAML frontmatter in `stage-index.md`; tooling uses `yq`.
4. **Signature misreading by Claude Code.** Mitigated by `api-skeletons/` compilable stubs + bar M3 (`swift build` passes).
5. **Context bloat per stage.** Mitigated by implementer read-path paragraph in `briefs/README.md`.

### Deferred until first-run evidence
6. **HITL test accountability.** Four-class labeling + `state.md` logs is the current containment. Dedicated registry with promotion tracking deferred.
7. **state.md drift.** Chain consistency (Agent 5 J1) + prior tests passing is the current containment. Pre-flight reconciliation grep checks deferred.

### Review posture
After first end-to-end run (Agent 3 → 4 → 5 → Claude Code through stage 1), revisit risks 6 and 7.

## Success criteria

1. Agent 3's output passes all M1-M5 and J1-J5 on first or second run.
2. Agent 4 emits a Green verdict within ≤2 Agent-3 iterations.
3. Agent 5's output passes all M1-M4 and J1-J3.
4. `swift build` passes on `architecture/api-skeletons/` at Agent 3 completion.
5. Claude Code implements stage 1 to a visible preview on simulator within one session.
6. The full stage sequence completes with at most one human intervention per stage.
7. Every `domain-revised` requirement has at least one test in `briefs/` that verifies it.
