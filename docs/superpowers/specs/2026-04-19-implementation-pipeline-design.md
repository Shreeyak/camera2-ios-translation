# Implementation Pipeline Design

> Status: draft, awaiting user review
> Date: 2026-04-19
> Precedes: implementation plan (to be written via `superpowers:write-plan`)
> Target model: Opus 4.7 with 1M context window

## Problem

The repo has an upstream 2.5-agent pipeline that ends at `domain-revised/` (manually reviewed, platform-neutral behavioral requirements):

- **Agent 1 (AUDIT)** — Android source → `audit/`
- **Agent 2 (EXTRACT)** — `audit/` → `domain/`
- **(manual review)** — `domain/` → `domain-revised/`

This spec defines the three agents that come next:

- **Agent 3 (ARCHITECT + STAGE MAPPER)** — reads `domain-revised/` + `ios-platform-guide/`, produces `architecture/` (target iOS design) and `stages/stage-index.md` (ordered stage journey). Runs in two sequential phases within one prompt: architecture-first, then stages.
- **Agent 4 (ARCHITECTURE REVIEW)** — gated by a mechanical-verification script; if the script passes, Agent 4 runs judgement-level review and emits a Green/Yellow/Red verdict in `review/`.
- **Agent 5 (BRIEF WRITER)** — reads reviewed architecture + stage index, produces `briefs/stage-NN.md` corpus as a single coherent run (or chunked if N > 12).

Claude Code CLI then implements the app stage-by-stage in a **separate repository**, reading `implementation/` and `ios-platform-guide/` from this repo as external reference.

## Scope and non-scope

**In scope**
- Defining Agents 3, 4, 5: inputs, outputs, quality bars, failure modes.
- Defining the stage-brief schema, `state.md` handoff, and per-stage gate.
- Defining the architecture-amendment path when implementation discovers gaps.
- Defining the `implementation/` directory layout in this repo.

**Out of scope**
- The upstream Agent 1/2 pipeline.
- The Swift implementation repository itself (separate project).
- Concrete system prompts for Agents 3/4/5 (produced in the implementation plan).
- The target iOS architecture content (produced by Agent 3 at runtime).

## Constraints

1. Coding agent is **Claude Code CLI** running **Opus 4.7 with 1M context window**. All design choices assume abundant context; fragmentation is not a concern, but per-stage context *budget* still matters for focus.
2. **Hard gate per stage**: build + unit tests must pass before the next stage begins. Tests that aren't possible at a given stage are explicitly flagged with one of four classes (TESTABLE / FLAGGED / HITL / DEFERRED), not silently skipped.
3. **Heavy upfront design**: architecture + stage journey + review happen before any Swift is written.
4. **Starts from `domain-revised/`**. Upstream pipeline is fixed.
5. **Target devices**: iPad Pro M1, iPad 11 (A16). HITL tests specify which device.

## Pipeline shape

```
domain-revised/ + ios-platform-guide/
    │
    ▼
[Agent 3: Architect + Stage Mapper]
    Phase A: architecture (freeze)
    Phase B: stages
    │
    ├── architecture/   (9 concern + 4 registers + api-skeletons/)
    └── stages/stage-index.md
    │
    ▼
[verify-architecture.sh]            ← mechanical gate; LLMs are bad at counting
    │  if FAIL → Agent 3 reruns
    │  if PASS ↓
    ▼
[Agent 4: Architecture Review]
    judgement-level only (J-bars)
    │
    └── review/   (Green / Yellow / Red verdict + findings)
    │  ≥3 consecutive Yellow iterations → human review gate
    ▼  (gate: verdict must be Green)
    │
[Agent 5: Brief Writer]
    single coherent run if N ≤ 12;
    chunked run with explicit handoff if N > 12
    │
    └── briefs/   (stage-01.md … stage-N.md + state-template.md + README.md)
    │
    ▼
[Claude Code, stage loop, in separate repo]
    │  any unscripted decision touching a load-bearing concern
    │  triggers an architecture amendment commit back here
    └──────────────► (loop back to verify-architecture.sh for amended section)
```

### Why Agent 5 is a single run (bounded)

Stages are deeply interconnected: stage 3's scaffolding is retired in stage 7, stage 7's `Tests preserved:` list must name stage 3's actual tests, and each stage's `Starting state:` depends on what prior stages left behind. A single run threads scaffolding→migration pairs, predicts entry `state.md` per stage, and avoids cross-stage contradictions.

**Chunking fallback:** If Agent 3 produces N > 12 stages, Agent 5 runs in two chunks (stages 1..⌈N/2⌉, then ⌈N/2⌉+1..N). The second chunk receives the full first-chunk output as context plus an explicit handoff doc summarizing: final-state after chunk 1, live scaffolds at chunk boundary, tests-on-file at chunk boundary, unretired scaffolding IDs. Cross-chunk invariants (scaffolding retirement, tests preserved) are re-verified after both chunks complete.

### Stage structure (walking skeleton)

Stages are hybrid: some are **feature stages** (add user-visible capability, possibly via scaffolding shortcuts), some are **migration stages** (behavior preserved; structure moves toward target architecture).

**Cadence — starting heuristic, revisit after first end-to-end run:**
- Prefer no more than 2 consecutive FEATURE stages before a MIGRATION, OR
- Prefer no stage enters with more than 3 live scaffolds.
- These are preferences, not hard rules. Agent 3 may violate them with a one-line justification in the stage-index prose body.

Stage 1 must produce something visible (e.g., bare camera preview on screen with an empty bottom bar).

### Scaffolding ID convention

Every scaffold has an ID of the form `<stage-number>:<kebab-case-slug>` (e.g., `02:crude-inactive-stop`). The slug must appear:
- in the stage's `scaffolding_introduced:` YAML list,
- as a comment or heading in the scaffold code (for grep-findability),
- in the retiring stage's `scaffolding_retired:` field.

## Agent 3 — Architect + Stage Mapper

### Sequential-phase prompt discipline

Agent 3 works in two **internally sequential phases** within one prompt:

- **Phase A: Architecture.** Produce all files under `architecture/`. Freeze. No stage thinking.
- **Phase B: Stage mapping.** Given the frozen architecture, produce `stages/stage-index.md`. May reference architecture anchors; may not revise architecture content.

Agent 4 can issue Yellow on Phase B alone, in which case Agent 3 reruns Phase B only (architecture stays frozen).

### Inputs
- `domain-revised/*.md` (12 files + README + CHANGES)
- `ios-platform-guide/*.md` (files + README + CHANGELOG)
- System prompt: mapping rules, ADR citation/deviation discipline, cross-input interaction surfacing, scaffolding ID convention, sequential-phase discipline. Lists three canonical interaction examples.

### Outputs — `architecture/`

Nine **concern files** (numeric prefix, prose + decisions inline) + four **register files** (no numeric prefix, structural indexes) + **`api-skeletons/`** (compiling stubs):

| File/dir | Kind | Purpose |
|---|---|---|
| `README.md` | register | Nav, cross-file interaction map, "Interactions considered" subsection, **Phase coverage table**, **Primary-owner rule** |
| `01-system-shape.md` | concern | Swift module/file map, target layout, public vs internal boundary |
| `02-concurrency.md` | concern | Actor topology, queues, scenePhase gate, 12 domain invariants → Swift 6 primitives. Includes **concurrency contract table** and **cross-subsystem sequencing** subsections. |
| `03-camera-session.md` | concern | `AVCaptureSession` config, device/format selection, resolution, orientation, interruption, self-healing, background suspend/resume |
| `04-metal-pipeline.md` | concern | Per-frame Metal command graph, texture cache, RGBA16F, `FrameSet`, tracker downsample |
| `05-consumers.md` | concern | `PixelSink` registration, C++ interop, pool sizing, latest-wins, `.private`→`.shared` |
| `06-capture-and-recording.md` | concern | Still + video: `AVAssetWriter`, IOSurface pool, NV12 compute, state machine, drain, HEVC-only |
| `07-settings.md` | concern | Partial-update merge, ISO/exposure coupling, persistence |
| `08-ui.md` | concern | SwiftUI, ViewModel, two `MTKView`s, split preview, calibration sidebar |
| `09-errors-and-recovery.md` | concern | Error taxonomy, recovery state machine, backoff, dual watchdog |
| `api-surface.md` | register | Swift SDK signatures index (prose summary + pointers into `api-skeletons/`) |
| `decisions.md` | register | Hybrid: one-line for minor deviations; full ADR-style (Context / Options / Consequences / Reversibility) for consequential ones |
| `constants.md` | register | Table: `Name \| Value \| Cite \| Owning concern \| Rationale`. All load-bearing numeric values (drain timeout, backoff delays, watchdog intervals) live here; concern files cite `constants.md#<name>`. |
| `open-questions.md` | register | Deferred U-## items |
| `api-skeletons/` | compilable | SwiftPM target: Swift/C++ stubs with `fatalError("Stage N")` bodies. `swift build` passes. |

**Principles:**
- Organize by iOS framework/subsystem.
- Register files are structural indexes (non-numeric prefix).
- Decisions inline in concern files + index in `decisions.md`.
- Numeric values live exclusively in `constants.md`.
- `api-skeletons/` locks signatures + isolation annotations, not behavior.

### Outputs — `stages/stage-index.md`

Single ordered file. Each stage is a YAML-frontmatter block + prose body:

```yaml
---
stage: 05
title: Proper scenePhase gate
type: MIGRATION          # FEATURE | MIGRATION
depends_on: [02]         # must include any stage referenced in scaffolding_retired
touches: [02-concurrency, 04-metal-pipeline, 08-ui]
scaffolding_introduced: []
scaffolding_retired: [02:crude-inactive-stop]
tests_preserved: [02:engine-transitions-to-streaming, 03:preview-visible-within-2s]
---
```

Prose body holds `Visible:` description and (if cadence heuristic violated) a one-line justification.

### Cross-subsystem sequencing (required subsection of `02-concurrency.md`)

Any policy that orders actions across ≥2 concern files (e.g., `.background` → gate → stop session → drain recording) lives here. Format: named sequence with each step citing the subsystem's concern file.

### Concurrency contract table (required subsection of `02-concurrency.md`)

Three columns; rows not fixed to invariants 1:1.

| Mechanism | Invariants enforced | Failure mode if violated |
|---|---|---|
| (example) `CameraEngine` actor | I-1, I-2 | Concurrent `open()` races |

Every row cites `ADR-##` or `D-##`. No blank cells.

### Interactions considered (required subsection of `README.md`)

≥3 entries spanning ≥2 interaction shapes. Each entry must carry an explicit shape tag from: `concurrency×lifecycle`, `storage×consumer`, `error×recovery`, `resource×teardown`, `settings×session`, `ui×state`. Entries may be "no interaction found" for a shape.

System prompt names three canonical examples:
- **concurrency×lifecycle**: scenePhase `.inactive` × outstanding `MTLCommandBuffer` → Metal background rule (ADR-09).
- **storage×consumer**: U-13 × ADR-20 × G-25 → consumer-registration must handle `.private`→`.shared` transition.
- **error×recovery**: HAL error × backoff × watchdog lifecycle → recovery must disarm watchdog before retry.

### Primary-owner rule (required in `README.md`)

Verbatim text:

> Every architectural decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content.

### Phase coverage table (required in `README.md`)

Schema: `domain file | primary concern(s) | implementing stage(s)`. Every `domain-revised/NN-*.md` file appears as one row. Used by Agent 4 (J1) and Claude Code (scope sanity check).

### Forbidden
- No Swift code in prose files (signatures allowed in `api-surface.md`; stubs in `api-skeletons/`).
- No reading of other directories.
- No silent deviations from `ios-platform-guide` ADRs.
- No numeric values inline in concern files — cite `constants.md#<name>` instead.

### Quality bars

Split into **mechanical** (checked by `verify-architecture.sh` before Agent 4 runs) and **judgement** (Agent 4 checks). Each judgement bar names its mechanical proxy if one exists.

**Mechanical (M1-M8) — scripted**
- M1. Every file in the outputs table exists with the expected prefix.
- M2. Every `D-##` in `decisions.md` has a matching inline anchor in its owning concern file (grep).
- M3. `swift build --package-path architecture/api-skeletons/` exits 0. Package uses Swift 6 language mode with strict concurrency.
- M4. Every stage YAML `touches:` names a real concern file.
- M5. Every `scaffolding_introduced: [S:slug]` has a matching `scaffolding_retired: [S:slug]` in a later stage; no cycles in `depends_on`.
- M6. Every `scaffolding_retired: [S:slug]` implies S ∈ `depends_on` for that stage.
- M7. `constants.md` has no entries with blank cells.
- M8. Every "Interactions considered" entry carries a shape tag from the allowed list.

**Judgement (J1-J5) — Agent 4**
- J1. Every `domain-revised/*` requirement maps to at least one architecture section (proxy: Phase coverage table filled for every domain file).
- J2. Every architecture decision cites `ADR-##` or creates a `D-##` with rationale (proxy: grep for decision verbs like `chose`, `must`, `selected`, `requires`, `uses`, `prefers` and flag any such paragraph without a nearby `ADR-##`/`D-##`).
- J3. `02-concurrency.md` concurrency contract table rows are plausible (primitives match Swift 6 idioms; no obvious miscitations).
- J4. "Interactions considered" entries are real, not contrived; ≥3 entries spanning ≥2 shape tags.
- J5. Migration stages' `tests_preserved` name tests that are plausible to exist by that stage.

## Agent 4 — Architecture Review

### Inputs
- `architecture/` (all files, after `verify-architecture.sh` passes)
- `stages/stage-index.md`
- `domain-revised/` + `ios-platform-guide/` (for J1-J5 verification)
- `review/mechanical.md` (output of `verify-architecture.sh`)

### Outputs — `review/`

```
review/
├── README.md           # top-level Green/Yellow/Red verdict + summary
├── mechanical.md       # verify-architecture.sh output (produced before Agent 4 runs)
├── judgement.md        # J1-J5 per-bar assessment with evidence
└── findings.md         # actionable issues (Yellow/Red only)
```

### Verdict rubric
- **Green**: `verify-architecture.sh` passes AND all J1-J5 pass. Agent 5 may run.
- **Yellow**: script passes; at least one J-bar flagged as "marginal" but none are Red. Agent 3 reruns the relevant phase (A or B) with findings; Agent 5 blocked.
- **Red**: script fails OR any J-bar is Red. Agent 3 reruns.

### Iteration bound

After **3 consecutive Yellow verdicts** on the same run, the pipeline halts and flags a **human-review gate**. The human either:
- overrides the Yellow to Green (documenting why in `review/findings.md`), or
- replaces one or more J-bars with a narrower, more mechanical check, or
- kicks the spec back (not the agent run) for schema changes.

This prevents Yellow oscillation on fuzzy J-bars.

### What Agent 4 does NOT do
- Does not re-run mechanical checks (the script already did).
- Does not read the Swift implementation repo (there is none yet).
- Does not re-decide architecture — flags in `findings.md`; Agent 3 reruns.

## Agent 5 — Brief Writer

### Inputs
- `architecture/` (Green-verdict version)
- `stages/stage-index.md`
- `review/` (context)
- `domain-revised/` (citation only)

### Outputs — `briefs/`

- `README.md` — source-of-truth paragraph, implementer read-path, stage-kickoff template, glossary
- `stage-01.md … stage-N.md` — one per stage, numbered 12-section schema
- `state-template.md` — initial shape for `state.md`

### Source-of-truth paragraph (required in `briefs/README.md`)

Verbatim (positive constraint, not negative):

> **For stage N, your current brief (`stage-NN.md`) is the authoritative source for this stage.** If the brief references an architecture anchor or domain section, read it. If a prior brief or the architecture appears to contradict the current brief, **the current brief wins** — note the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed with the current brief. Your stage's context budget is: this brief + cited architecture refs + cited domain refs + `api-skeletons/` for files you'll touch + `state.md` from the prior stage. Reading more is not forbidden; it is simply not necessary and will dilute focus.

### Stage-kickoff template (required in `briefs/README.md`)

At the start of every stage, Claude Code:
1. Reads `state.md` (from prior stage).
2. Runs pre-flight check: for every entry in `state.md` "Scaffolding still live", verify the scaffold slug is present in the codebase (`grep -r <slug> Sources/`). Mismatch → halt, escalate.
3. Reads the current brief.
4. Reads cited architecture + domain refs + relevant `api-skeletons/` files.
5. Implements per the brief.
6. Runs the per-stage verification gate.
7. Updates `state.md` per §12 of the brief.
8. Commits.

### Per-stage brief schema (numbered, 12 sections, verbatim headings)

```
# Stage NN — <title>

## 1. Frontmatter
Type: FEATURE | MIGRATION
Depends on: Stage X, Stage Y
Retires scaffolding from: Stage Z (scaffold slug)   # migration only

## 2. Starting state
<what state.md should say entering this stage>

## 3. Goal

<For FEATURE stages:>
<one-sentence user-visible goal>

<For MIGRATION stages:>
- Adds: <primitive/type being added>
- Removes: <scaffold slug being retired>
- Behavior preserved: <list of behaviors that must remain unchanged>

## 4. Files to create / modify / delete
- create: Sources/... (permanent | scaffolding:<slug>)
- modify: Sources/...
- delete: ...

## 5. Architecture refs
- architecture/XX-<name>.md#<anchor>

## 6. Domain refs
- domain-revised/XX-<name>.md

## 7. Contracts & invariants
- <invariant>  (ADR-## or G-## or D-##)

## 8. Tests to write
- TESTABLE: <test>
- FLAGGED: <test> — reason; retry in stage NN
- HITL: <test> — device: iPad Pro M1 (or iPad 11 A16)
- DEFERRED: <test> — manual; record evidence
- HITL+FLAGGED: <test> — compound classes allowed; must satisfy both class requirements

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
- Retires: <scaffold slug>   # if any
- Adds: <permanent entry>
- Evidence: <HITL/DEFERRED result path if applicable>
```

### Testability classes (four + composites)

- **TESTABLE** — unit/integration; runs in stage; blocks gate on failure.
- **FLAGGED** — possible but needs tooling the stage lacks (e.g., Instruments). Specifies retry stage.
- **HITL** — requires a real device (not simulator). Specifies `device:`.
- **DEFERRED** — inherently manual, non-device (e.g., "output file has valid EXIF"). Evidence recorded.
- **Composite** — classes joined with `+` (e.g., `HITL+FLAGGED`). Test must satisfy both class requirements (both retry stage and device, etc.).

### Forbidden
- No Swift code (api-skeletons + Claude Code do this).
- No re-deciding architecture — escalate if unclear.
- No bundling multiple stages into one brief.

### Quality bars

**Mechanical (M1-M5) — scripted via `verify-briefs.sh`**
- M1. Every brief file contains all 12 numbered section headings, in order, verbatim.
- M2. Every architecture ref anchor resolves.
- M3. Every `Retires scaffolding from: S (slug)` matches a `scaffolding_introduced: [S:slug]` entry in the stage-index.
- M4. Every test line matches one of the four classes (or a composite); HITL/HITL+* lines have a `device:` field; FLAGGED/FLAGGED+* lines have a retry stage.
- M5. Every `FLAGGED: <test> retry in stage NN` has a matching `TESTABLE: <same test>` in stage NN's brief.

**Judgement (J1-J3) — Agent 4 or human**
- J1. Every brief's "Starting state" is derivable from prior briefs' "State.md updates" (chain consistency).
- J2. Every migration stage's `Tests preserved:` names real prior-stage tests.
- J3. Coverage: every `domain-revised/*` requirement is referenced by at least one brief by the final stage.

## The handoff document — `state.md`

Lives in the implementation repo (the separate Swift project). Seeded from `state-template.md` at stage 1. Claude Code appends/updates at end of every stage. Committed per stage.

### Simplified shape (per Feedback 3)

State.md is **human-LLM communication only**. Swift test files are the authoritative source for test status; Claude Code does not mirror test names into state.md.

```
# state.md

## Current stage
Stage NN complete. Next: Stage NN+1.

## Scaffolding still live
- <stage-slug> — <one-line description>
- ...

## What's built (permanent)
- <entry>   (append-only; removed only via explicit Retires)
- ...

## Public API exposed so far
- <entry>

## Manual test evidence
- <test-name> — <device> — evidence/<path> — <date>

## Decisions taken that weren't in briefs
- <one-line decision> — <rationale> — ref: <architecture amendment filing if any>

## Open questions for next stage
- <question>
```

### Rules
- Append-only for "What's built" and "Scaffolding still live"; entries mutate only via explicit `Retires:` in a brief's §12.
- Any decision not in the brief is logged under "Decisions taken that weren't in briefs".
- Committed after every stage.

### Pre-flight check (minimal, per Feedback 2.4)

At stage entry, the stage-kickoff template requires Claude Code to grep `Sources/` for every slug under "Scaffolding still live". Mismatch (scaffold entry in state.md but slug missing from code, or vice versa) → halt, escalate. Cheap, catches state.md drift before Swift is written.

## Architecture amendment path (per Feedback 2.5)

When Claude Code at some stage discovers the architecture is wrong (misread platform constraint, unforeseen framework behavior, wrong assumption about `AVCaptureSession` / Metal), the "Decisions taken that weren't in briefs" entry is not enough — the architecture itself drifts from reality.

**Trigger**: any stage logging ≥2 unscripted decisions OR any decision touching `02-concurrency.md` or `03-camera-session.md` (load-bearing concerns).

**Required action** before the next stage starts:
1. Create a new `D-##` entry in `decisions.md` with `Source: stage-NN-field-finding`, full ADR-style (Context / Options / Consequences / Reversibility).
2. Patch the owning concern file's inline rationale to match the new `D-##`.
3. Update `constants.md` if a value changed.
4. Re-run `verify-architecture.sh` (mechanical checks only — script passes in seconds).
5. Human decides whether to rerun Agent 4 for the amended section (usually optional for minor amendments; required for Red-rank findings).
6. If amendment changes future stages' contracts, Agent 5 reruns for the affected briefs only.

Commit goes into the artifacts repo (`ios-translation/implementation/architecture/`), not the implementation repo. Diffable.

## Verification gate (Phase 2, per stage)

Enforced by Claude Code at the end of each stage in the implementation repo:

1. `swift build` / Xcode build — must pass, no new warnings.
2. `swift test` — all prior + new unit tests pass.
3. Static checks if configured.
4. Manual verification for FLAGGED / HITL / DEFERRED items — evidence recorded in `state.md`.
5. Pre-flight check (next stage) runs at next stage entry, not as gate step here.

## Repo layout

```
ios-translation/                      (this repo)
├── domain-revised/                   (existing — input to Agent 3)
├── ios-platform-guide/               (existing — input to Agent 3; read by Claude Code)
├── implementation/                   (new — everything for this pipeline)
│   ├── prompts/
│   │   ├── agent-3-architect.md
│   │   ├── agent-4-review.md
│   │   └── agent-5-brief-writer.md
│   ├── scripts/
│   │   ├── verify-architecture.sh    (mechanical checks M1-M8)
│   │   └── verify-briefs.sh          (mechanical checks M1-M5 for Agent 5 output)
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
│   │   ├── constants.md
│   │   ├── open-questions.md
│   │   └── api-skeletons/
│   │       ├── Package.swift         (Swift 6 strict concurrency)
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
│       ├── README.md                 (source-of-truth + read-path + kickoff template)
│       ├── stage-01.md … stage-N.md
│       └── state-template.md
└── CLAUDE.md                         (existing)

<separate-repo>/                      (the Swift implementation, external)
├── Package.swift
├── Sources/CameraKit/...
├── Sources/CameraApp/...
├── Tests/...
├── evidence/                         (HITL / DEFERRED artifacts: screenshots, traces, logs)
└── state.md                          (Claude Code maintains per stage)
```

## Known risks — mitigations and deferrals

### Addressed upfront
1. **`02-concurrency.md` is load-bearing** — concurrency contract table + J3.
2. **Cross-input interactions** — "Interactions considered" + 3 canonical examples + shape-tag mechanical check (M8).
3. **Unknown stage count** — YAML frontmatter + chunking fallback for N > 12.
4. **Signature misreading by Claude Code** — `api-skeletons/` + M3 Swift-strict-concurrency build.
5. **Context bloat per stage** — source-of-truth framing in `briefs/README.md`.
6. **Mechanical bars in LLM hands** — extracted to `verify-architecture.sh` / `verify-briefs.sh`.
7. **Yellow-verdict oscillation** — 3-iteration human-review gate.
8. **FLAGGED retry accountability** — M5 enforces matching TESTABLE in target stage.
9. **state.md drift** — simplified state.md + pre-flight grep at stage entry.
10. **Architecture drift from implementation reality** — amendment path with D-## + concern-file patch + mechanical re-verify.
11. **Cross-subsystem ordering (no home)** — required subsection in `02-concurrency.md`.
12. **Load-bearing constants (no home)** — `constants.md` register.
13. **Double-homed decisions** — primary-owner rule in `architecture/README.md`.

### Deferred until first-run evidence
14. **Cadence heuristic numbers** — 2-consecutive-feature / 3-live-scaffold are starting heuristics, not hard rules. Revisit after first end-to-end run.
15. **Full architecture re-review after minor amendments** — currently optional; may need to be mandatory if amendment-induced bugs appear.

## Success criteria

1. `verify-architecture.sh` passes on first or second Agent-3 run.
2. Agent 4 emits a Green verdict within ≤2 non-human iterations (no human-review gate hit).
3. `verify-briefs.sh` passes on first or second Agent-5 run.
4. `swift build` passes on `architecture/api-skeletons/` at Agent 3 completion.
5. Claude Code implements stage 1 to a visible preview on simulator within one session.
6. Full stage sequence completes with at most one human intervention per stage.
7. Every `domain-revised` requirement has at least one test in `briefs/` that verifies it.
8. Paper-simulation rerun on a different requirement after spec lock still shows no material schema gaps.
