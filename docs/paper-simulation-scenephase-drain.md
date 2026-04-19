# Paper Simulation — scenePhase .inactive gate and background recording drain

> Date: 2026-04-19
> Method: Trace one real domain requirement through every schema slot the implementation-pipeline spec defines. Flag gaps, double-homes, and ambiguities.

## Requirement traced

Compound requirement drawn from `domain-revised/05-resource-lifecycle.md` §§115–129 and `ios-platform-guide/02-concurrency.md` ADR-08/09:

1. On `scenePhase → .inactive`, **gate Metal GPU submission** (set `gpuSubmissionEnabled = false`), then `waitUntilScheduled()` on the last committed command buffer. Do not stop the session.
2. On `scenePhase → .background`, `session.stopRunning()` on `sessionQueue`. Do not release the `CVMetalTextureCache` / `MTLDevice`.
3. If recording is active when backgrounding begins, **request a platform background-execution extension, drain the encoder, finalize the file**. If the drain window expires before finalization, **cancel the write** rather than leave a corrupt `moov`.

Chosen because it's compound, cross-cutting (concurrency, Metal, camera session, recording, UI binding), and has real ADR coverage + real hidden constants.

---

## Schema-by-schema walkthrough

### 1. `architecture/` concern-file ownership

| Sub-behavior | Primary owner (proposed) | Cross-referenced by |
|---|---|---|
| `.inactive` → gate atomic + `waitUntilScheduled` | `02-concurrency.md` | `04-metal-pipeline.md` (says "submission is gated; see 02#scenePhase-gate") |
| `.background` → `sessionQueue.async { stopRunning() }` | `03-camera-session.md` | `02-concurrency.md` (sequencing policy) |
| Retain `CVMetalTextureCache` / `MTLDevice` across backgrounding | `04-metal-pipeline.md` | — |
| Recording drain with `beginBackgroundTask` + timeout cancellation | `06-capture-and-recording.md` | `02-concurrency.md` (ordering with session stop) |
| **Ordering policy: gate first → stop session → drain recording** | **??? no clear home** | — |

**First ambiguity surfaced.** Three primary owners each hold a piece; the *sequence* among them has no home in the schema. See Finding 1.

### 2. Decisions (ADR / D-##)

| Decision | Cite | Location |
|---|---|---|
| Gate on `.inactive` not `.background` | ADR-08, ADR-09 | Inline in `02-concurrency.md`; listed one-liner in `decisions.md` |
| Retain GPU resources across backgrounding | ADR-09 "Resource handling" | Inline in `04-metal-pipeline.md` |
| `stopRunning()` dispatched on `sessionQueue` | ADR-07 (sessionQueue) | Inline in `03-camera-session.md` |
| Drain timeout cancel-rather-than-corrupt | No ADR (domain-level decision) | Inline in `06-capture-and-recording.md`; full ADR-style `D-##` in `decisions.md` (consequential, irreversible) |
| Drain timeout **value** (T seconds) | Not specified anywhere | **??? no home** — see Finding 2 |

**Second ambiguity.** The "cancel rather than corrupt" *policy* has a home; the *timeout value* does not.

### 3. `api-skeletons/`

Load-bearing types that would need to be locked:

```swift
// Sources/CameraKit/CameraEngine.swift
actor CameraEngine {
    private let gpuSubmissionEnabled = ManagedAtomic<Bool>(true)
    private let sessionQueue: DispatchSerialQueue
    private var lastCommittedCommandBuffer: MTLCommandBuffer?

    func handleScenePhase(_ phase: ScenePhase) async { fatalError("Stage N") }
    func backgroundSuspend() async { fatalError("Stage N") }
    func backgroundResume() async { fatalError("Stage N") }
}

// Sources/CameraKit/CameraView.swift
struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    // onChange(of: scenePhase) → engine.handleScenePhase(...)
}
```

Skeleton for recording:
```swift
// Sources/CameraKit/RecordingCoordinator.swift
actor RecordingCoordinator {
    func drainForBackgrounding(timeout: TimeInterval) async throws { fatalError("Stage N") }
}
```

**Third ambiguity.** The drain timeout is a parameter here. If `api-skeletons/` locks the signature, the *value* still floats free. Finding 2 again.

### 4. `stages/stage-index.md`

Minimum plausible decomposition:

| Stage | Type | Title | `touches:` | Notes |
|---|---|---|---|---|
| 01 | FEATURE | Bare preview on screen | `[03, 08]` | no scenePhase handling |
| 02 | FEATURE | Actor-owned camera lifecycle | `[02, 03]` | open/close; **introduces scaffold**: `.inactive → session.stopRunning()` (crude) |
| 05 | MIGRATION | Proper scenePhase gate | `[02, 04, 08]` | **retires** stage 2's crude stop; introduces `gpuSubmissionEnabled` atomic + `waitUntilScheduled` |
| 08 | FEATURE | Video recording | `[06, 04, 02]` | introduces encoder pipeline |
| 11 | FEATURE | Background-drain for recording | `[06, 02]` | introduces `beginBackgroundTask` + timeout cancel |

`depends_on:` for stage 05 = `[02]`; for stage 11 = `[08]`. Stage 05's `scaffolding_retired:` = `[02:crude-inactive-stop]`.

**Observation.** Stage 05's `touches:` has three concern files — right at the boundary of what's reasonable. Works.

### 5. Per-stage brief (stage 05 — Proper scenePhase gate)

Tracing the 12-section template for the migration stage:

```
# Stage 05 — Proper scenePhase gate

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 02
Retires scaffolding from: Stage 02 (crude .inactive → stopRunning)

## 2. Starting state
- CameraEngine actor owns session open/close (Stage 02)
- Preview rendered via MTKView (Stage 03)
- Stage 02 scaffolding: .inactive currently triggers session.stopRunning()
  (WRONG — policy is to gate GPU, not stop session)

## 3. Goal
Replace crude .inactive → stopRunning with the correct gate (atomic + wait).
Behavior preserved from user POV: preview freezes briefly on notification
banners; camera hardware remains running.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/CameraEngine.swift (add gpuSubmissionEnabled atomic, wait helper)
- modify: Sources/CameraKit/CameraView.swift (onChange(of: scenePhase) dispatch)
- delete: nothing yet — Stage 02 scaffolding replaced in-place

## 5. Architecture refs
- architecture/02-concurrency.md#scenephase-gate
- architecture/04-metal-pipeline.md#gpu-submission-gate
- architecture/08-ui.md#scenephase-binding

## 6. Domain refs
- domain-revised/05-resource-lifecycle.md#system-initiated-lifecycle

## 7. Contracts & invariants
- GPU submission guarded by `gpuSubmissionEnabled` atomic (ADR-09)
- Gate does NOT silence async consumers (ADR-09)
- `.inactive` MUST NOT stop the session (ADR-08)
- `scenePhase → .active` flips gate back on (ADR-08)

## 8. Tests to write
- TESTABLE: gate flips false on handleScenePhase(.inactive)
- TESTABLE: gate flips true on handleScenePhase(.active)
- TESTABLE: async consumer callback still fires while gated (mock)
- HITL (device: iPad Pro M1): backgrounding during preview doesn't crash; resume restores preview within 500ms
- HITL (device: iPad Pro M1): notification banner pauses preview; dismissing banner resumes within one frame

## 9. Tests preserved (must still pass)
- Stage 02: engine-transitions-to-streaming
- Stage 02: engine-closes-on-explicit-close
- Stage 03: preview-visible-within-2s

## 10. Acceptance criteria
- [ ] swift build passes, no new warnings
- [ ] all prior-stage tests pass
- [ ] new TESTABLE tests pass
- [ ] Stage 02's crude .inactive → stopRunning line is gone (grep check)
- [ ] HITL device check recorded in state.md

## 11. Verification steps
- swift test --filter ScenePhaseGateTests
- On iPad Pro M1: open camera, pull notification banner down, verify preview freezes not closes, dismiss, verify resume
- On iPad Pro M1: backgroundHome, return, verify preview resumes within 500ms

## 12. State.md updates
- Retires: Stage 02:crude-inactive-stop
- Adds: gpuSubmissionEnabled atomic (load-bearing for later recording drain)
- Records HITL evidence path (screenshot + device ID)
```

**Works cleanly.** Every section has a clear answer. The contracts-and-invariants section (§7) is where ADR citations cluster — good.

**Fourth ambiguity.** The crude `.inactive → stopRunning` scaffolding introduced in Stage 02 has to be named in Stage 02's `scaffolding_introduced:` YAML field. The spec's YAML example uses `[01:AVCaptureVideoPreviewLayer]` — a short slug. What does Agent 3 write for "crude .inactive → stopRunning"? A slug like `02:crude-inactive-stop`? Conventions for scaffolding IDs are undefined.

### 6. `state.md` evolution

Assuming we adopt F3.6 simplification (no "Tests on file"; Swift tests are source of truth):

**After Stage 02:**
```
## Scaffolding still live
- 02:crude-inactive-stop — .inactive triggers session.stopRunning(); wrong but testable end-to-end. Retires in Stage 05.

## Decisions taken that weren't in briefs
- (none)

## HITL / DEFERRED evidence
- (none yet)

## Open questions for next stage
- (none)
```

**After Stage 05:**
```
## Scaffolding still live
- (Stage 02 scaffold retired)

## What's built (permanent)
- gpuSubmissionEnabled: ManagedAtomic<Bool> on CameraEngine (ADR-09)
- handleScenePhase(_:) on CameraEngine
- onChange(of: scenePhase) wiring in CameraView

## HITL / DEFERRED evidence
- evidence/stage-05-notification-banner-test.png (iPad Pro M1, 2026-04-??)
- evidence/stage-05-background-resume.mov

## Open questions for next stage
- (none)
```

**Works.** The simplified state.md carries exactly the cross-stage facts future briefs need.

### 7. FLAGGED retry / HITL / DEFERRED threading

This requirement has two HITL tests and no FLAGGED ones. The spec handles HITL cleanly.

**Ambiguity check.** Is "command buffer reaches .scheduled" HITL or FLAGGED? Per the platform guide ADR-09, the wait can be asserted in-process via `waitUntilScheduled()` — so it's TESTABLE with a mock. Good — no overlap.

But consider a different test: "GPU trace shows no submissions after .inactive." That requires Instruments GPU trace. Is that HITL (needs device) or FLAGGED (needs tooling)? It's both: needs device AND needs Instruments. The spec's four classes don't have a "HITL+FLAGGED" composite. See Finding 6.

---

## Schema findings

### Finding 1 — Cross-subsystem sequencing policy has no home

The scenePhase → .background transition triggers actions in multiple subsystems in a specific order (gate, then stop session, then drain recording). Each sub-behavior has a primary-owner concern file, but the *ordering* across subsystems has no designated location.

**Fix (spec change):** Add a required `## Cross-subsystem sequencing` subsection to `architecture/02-concurrency.md`. Ordering policies that span ≥2 concern files live there with references to each participant. Alternative: put it in `architecture/README.md` under the cross-file interaction map. Pick one and mandate it.

### Finding 2 — Load-bearing constants have no home

Timing constants (drain window T, backoff delays, watchdog intervals) are load-bearing but don't belong in prose-shaped concern files, can't live in `api-skeletons/` (which lock signatures, not values), and aren't `open-questions.md` material if they're decided.

**Fix:** Add a register file `architecture/constants.md` — table format: `Name | Value | Cite | Owning concern | Rationale`. Non-numeric prefix (register kind). Concern files cite `constants.md#drain-timeout` rather than inlining values.

### Finding 3 — "Primary owner" rule must be stated explicitly

Several decisions have plausible homes in multiple concern files (scenePhase gate, recovery+backgroundSuspend, still-capture readback). Without a primary-owner rule, Agent 3 double-homes.

**Fix (already flagged by Feedback 2):** In `architecture/README.md`, state the rule: "Every decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content."

### Finding 4 — Scaffolding ID convention undefined

YAML `scaffolding_introduced: [02:crude-inactive-stop]` uses slugs, but no convention is specified. Agent 3 could drift into `[02:AVCaptureVideoPreviewLayer]`, `[02:hack-stop]`, `[02:temp-inactive-handling]` — all for the same scaffold. Agent 5's retirement check (M-bar) relies on string match.

**Fix:** Mandate `<stage-number>:<kebab-case-slug>` and require the slug to appear as a heading or comment in the scaffold code. Agent 5 and Claude Code both cite by slug.

### Finding 5 — Migration-stage "Goal" needs a template

For a migration stage, "behavior preserved; structure moves toward target" is vague. Claude Code needs a crisper contract: (a) what primitive is added, (b) what scaffold is removed, (c) which prior-stage tests must still pass unmodified.

**Fix:** Tighten brief §3 (Goal) template for migration stages:
```
## 3. Goal
- Adds: <primitive>
- Removes: <scaffold ID>
- Behavior preserved: <list>
```

### Finding 6 — Four testability classes don't cover composite cases

"Requires both a real device AND Instruments GPU trace" is HITL+FLAGGED. The current 4-class system doesn't compose.

**Fix (lightweight):** Allow tests to carry multiple classes joined with `+`: `HITL+FLAGGED: GPU trace shows no submissions after .inactive — retry in stage NN, device: iPad Pro M1`. Mechanical check becomes "every class is one of {TESTABLE, FLAGGED, HITL, DEFERRED}; compound classes allowed via `+`."

### Finding 7 — Architecture-amendment artifact format undefined

F2.5 (adopted) says unscripted implementation decisions should amend the architecture. The spec says this happens but doesn't say *how*. A commit to the artifacts repo can amend prose, but:
- Does it create a new `D-##` or patch existing rationale?
- Does it update `decisions.md` register?
- Does it run Agent 4 review again?

**Fix:** Define the amendment artifact format: a new `D-##` entry in `decisions.md` with `Source: stage-NN-field-finding`, full ADR-style Context/Options/Consequences/Reversibility, plus inline update to the owning concern file. Re-running Agent 4 optional; a dedicated amendment-review checklist runs instead (faster, narrower).

### Finding 8 — `touches:` vs cross-references

Stage 05's `touches:` = `[02, 04, 08]` covers primary changes. But the stage might also read (not modify) `06-capture-and-recording.md` to make sure the eventual recording drain can plug into the new gate. Should this count as `touches:` or a separate field like `reads:`?

**Fix (light):** Keep `touches:` as write-only. Architecture refs cited in brief §5 serve as the "reads" set.

### Finding 9 — HITL / DEFERRED evidence location rule

State.md under F3.6 drops "Tests on file". Where do evidence paths for HITL tests live? The simulation above used a `## HITL / DEFERRED evidence` section, but that's not specified in the spec.

**Fix:** Add `## Manual test evidence` as a named section in `state-template.md`. Format: one line per piece of evidence: `<test-name> — <device> — <evidence-path> — <date>`.

---

## Schemas that held up

- **12-section brief template.** Every section had a clear answer for this cross-cutting requirement. The numbered schema + grep-check is a real ergonomic improvement.
- **`api-skeletons/` for signatures.** Locks the `handleScenePhase(_:)` and `drainForBackgrounding(timeout:)` contract without committing to implementations.
- **ADR citation discipline.** ADR-08/09 covered the gate cleanly; no D-## needed for the gate. The D-## was reserved for the one genuinely irreversible choice (cancel-rather-than-corrupt).
- **Feature/migration + scaffolding pair.** The Stage 02 → Stage 05 scaffolding retirement worked cleanly; the pair gave Claude Code a definite "done" signal.
- **HITL class.** Captured the device-required tests correctly.

---

## Net assessment

The schemas mostly hold. **Nine findings, most minor.** Three are worth adopting before Agent 3 ever runs:

1. **Finding 2** (`constants.md` register) — closes a genuine hole.
2. **Finding 1** (cross-subsystem sequencing home) — prevents the recurring "which file owns ordering" question.
3. **Finding 3** (primary-owner rule) — already in Feedback 2, now confirmed by walkthrough.

Findings 4, 5, 6, 7, 9 are small template tightenings that go in at the same edit. Finding 8 (cross-reference `reads:` vs `touches:`) is a non-issue — don't add it.

The walkthrough also confirmed the F3.6 state.md simplification is correct: every cross-stage fact the simulation needed fit into the smaller shape, and removing "Tests on file" didn't lose anything (Swift test files carry that information natively).
