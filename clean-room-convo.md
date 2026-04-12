# Clean Room Prompt Redesign — Conversation Summary

A long, iterative design session that went from "write a prompt for iOS translation" to a fully-implemented 4-agent clean room pipeline, committed and ready to run. This summary captures the major branches, decision points, and things we learned along the way.

## Starting Point

**Initial request** (via `/prompt-architect`): Design a prompt that guides an AI agent to read a Flutter/Android camera library, map every class and method, and produce a plan to translate it to a native iOS/Swift app.

**Project reality** (discovered early):
- Flutter demo app with Android platform plugin
- Camera2 API + OpenGL ES GPU processing + generic C++ consumer sink pattern
- Pigeon-generated Dart↔Kotlin bridge
- App has two core missions: (1) deliver camera frames to ML/CV consumers, (2) UI test harness for camera characteristic controls
- Target iOS stack: iOS 26+, Swift 6, Metal 4, SwiftUI

---

## Branch 1: Two-Prompt Strategy (first design)

**Framework**: RISEN (multi-step procedure with phases)

**Decision**: Split into two prompts — a Cartographer (audit) and an Architect (design). Driven by the user's feedback that a single monolithic prompt would mix concerns.

**Clarifying Q&A**:
- Full native rewrite, not Flutter plugin
- Metal 4 for GPU
- Both tables AND flow diagrams (frame data + command/parameter flow)
- iOS 26+ (bleeding edge — unlocks Swift 6 strict concurrency)

**Key innovations in this branch**:
- **L1-L5 documentation format** — Purpose / Contracts / Decisions / Edge Cases / Android Reference. Discipline for capturing behavioral knowledge at multiple layers.
- **Three-source strategy** — screenshots for UI, Pigeon definitions for API contract, native code for behavioral extraction. Screenshots replace reading Dart widget code.
- **Git archaeology** — mine commit history and code comments for WHY decisions exist (not just what the code does).
- **Six architectural planes** instead of two ad hoc flow categories: data, control, state, resource lifecycle, threading, error/recovery.

---

## Branch 2: Iterative Refinement (feedback rounds)

Multiple rounds of external feedback on the two prompts.

### Round 2a: Cartographer feedback
- Phase ordering creates rework
- Phase 3 inventory is busywork
- Phases 4 and 5 overlap
- No performance budget
- Screenshot gaps not actionable
- Git calls too token-heavy
- Output volume problem (50,000+ words)

**Fix**: Added `<output-priority>` section, made translation cards reference architecture maps instead of duplicating, relaxed stop conditions to `NEEDS INVESTIGATION`, shortened git guidance.

### Round 2b: Architect feedback
- Reference architecture section doing too much work
- Assumes audit is complete and correct
- Deliverable 1 monolithic
- No device discovery / HDR / profiling strategy
- Phase 1 overloaded
- iOS 26+ aggressive (pushed back — user chose it deliberately)
- "Files to create" placeholder should be required output

**Fix**: Split architecture doc into 3 files, added `<handling-audit-gaps>` section, split Phase 1 into 1a/1b, made file tree a required output per phase.

### Round 2c: iOS reference architecture research
- User shared Swift 6 concurrency patterns
- Verified which claims are real: Metal 4 ✅, Swift-C++ direct interop ✅, MetalFX ✅, `@globalActor` ✅
- **Initially called VTFrameProcessor hallucinated** — turned out it IS real (iOS 26+ VideoToolbox API). Corrected.
- "Concurrent Actor" flagged as not a real Swift concept.
- Swift `sending` annotation (SE-0430) added as an option.

### Round 2d: OpenCV correction
- User: "The Android app does not have OpenCV, just a C++ sink where consumers can register"
- For iOS: add a new OpenCV edge detection consumer as proof-of-concept to validate the integration path
- This flipped OpenCV from "Android already uses it" to "new iOS capability"
- Memory file corrected, downstream instructions updated

### Round 2e: CVPixelBuffer / Sendable question
- User asked: "do we need CVPixelBuffer is an ObjC type?"
- Clarified: CVPixelBuffer is CoreFoundation, not Obj-C
- Explored 4 architectural options for handling non-Sendable buffers across actor boundaries
- Winner: **Option C — keep buffers on one queue, only send Sendable result structs across actor boundaries**. OpenCV needs CPU pixels via raw pointer, so the other options don't even match how OpenCV works.

### Round 2f: Failure point and over-guarding audit
- Identified unnecessary "DO NOT" guards that protected against problems a sensible agent wouldn't cause
- Rewrote both prompts with positive instructions
- Prompt 1 shrank from 429 → ~300 lines, Prompt 2 shrank from 508 → ~300 lines

---

## Branch 3: Clean Room Redesign (major pivot)

**Trigger**: User invoked `/superpowers:brainstorming` with the framing: *"The design doc needs enough detail that an implementing agent can build without ambiguity, but it must not be an Android port wearing iOS clothes. Domain knowledge is gold; structural decisions are Android-specific and should be left behind."*

**Key insight that emerged**: **Organizational structure leaks into thinking.** Our current translation cards were organized around Android components (`camera-lifecycle.md`, `gpu-pipeline.md`, `shaders.md`) — even when we told the agent "don't cargo-cult," the *shape* of what it read was Android, so the design came out Android-shaped.

### Decision points in the brainstorming session

**Q1 — Interpretation of "clean room":**
- A: Strict (agent never sees Android)
- **B: Structured separation** ← chosen
- C: Two-stage relay with translator

**Q2 — How to implement the separation:**
- A: Replace Prompt 1 entirely
- B: Add an Extractor between Cartographer and Architect
- **C: Complete redesign from scratch** ← chosen

**Q3 — Number of agents:**
- **4 agents** ← chosen (with Reviewer as first-class)

**Q4 — Reviewer stance:**
- **C: Both correctness AND adversarial** ← chosen

**Q5 — Reviewer scope:**
- **X: Domain + Design only (never audit/)** ← chosen

**Q6 — Iteration model:**
- **P: One-shot (user re-runs if needed)** ← chosen

### Final architecture

```
Android source ──▶ [1 AUDIT] ──▶ audit/      (Android-structured facts, 12 files)
                                    │
                                    ▼
                              [2 EXTRACT] ──▶ domain/    (platform-neutral, 13 files)
                                    │
                                    ▼
         iOS expertise ──▶ [3 DESIGN] ──▶ design/        (iOS architecture, 9 files)
         (injected)           │    │
                              │    └─── audit/ escape hatch (logged)
                              ▼
                         [4 REVIEW] ──▶ review/          (correctness + adversarial, 3 files)
                         reads domain/ + design/ only
```

### Five rules

1. Language discipline in `domain/` (no Android API names, self-audit grep)
2. Different organizational structures enforce separation (audit/ by Android component, domain/ by behavioral concern)
3. iOS expertise is injected (Metal 4, Sendable, VTFrameProcessor from prompt, not audit)
4. OpenCV is NEW for iOS (edge detection consumer as proof-of-concept)
5. Escape hatch is logged, never silent (design/08-audit-lookups.md)
6. Reviewer lives in iOS domain (never reads audit/)
7. Positive instructions over defensive guards

---

## Branch 4: Spec and Implementation Plan

**Spec written**: `docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md`
- Self-reviewed, fixed inline issues (status, language-rules clarity, iOS expertise injection mechanism)
- User approved

**Plan written** (via `/superpowers:writing-plans`): `docs/superpowers/plans/2026-04-12-clean-room-prompt-redesign.md`
- 10 tasks, Task 2 (Agent 2 EXTRACT) first because it's the most novel
- Dry-run validation for Agent 2 specifically
- Every commit step gated on user approval (project rule: "never commit without asking")

---

## Branch 5: Implementation via Subagent-Driven Development

**Execution via `/superpowers:subagent-driven-development`** — dispatched fresh subagents per task, two-stage review after each (spec + quality).

### Task 2: Agent 2 (EXTRACT) — Four review/fix rounds
1. **Spec review 1**: Missing forbidden identifiers in grep (`MessageQueue`, `SurfaceView`, etc.)
2. **Spec review 2**: Missing `\bSurface\b`
3. **Quality review**: `\bSurface\b` and `\bImage\b` are false-positive traps for common English words at sentence starts. Grep would either over-rewrite valid text or trigger rationalization.
4. **Spec deviation found**: Fix removed these from forbidden list entirely, but the spec listed them as Android class names. Restored with context-sensitive rule (LLM judgment for common-word vs class-name usage, grep for unambiguous compound forms).
5. **Dry-run validation**: Found "background thread" in allowed list encodes Android's thread model. Added counter-example (Example 5) showing Android-shaped but grep-compliant prose as a failure mode.

### Task 3: Agent 1 (AUDIT) — Two critical issues
1. **No Pigeon API phase** — Agent 2 needs method-level Pigeon details to write `domain/10-api-contract.md`, but the audit had no phase for this. **Added 12th audit file: `04-pigeon-api.md`** (deviation from spec's 11-file tree, documented).
2. **OpenCV contradiction** — Prompt said "Android does NOT use OpenCV" but CLAUDE.md says "The native pipeline uses OpenCV." Resolved with nuanced framing: the C++ sink layer is generic/pluggable; OpenCV may appear in build config as one consumer but is not "the" pattern.

### Task 4: Agent 3 (DESIGN) — Four important issues
1. Phase 1a/4 thermal boundary undefined (monitoring vs degradation response)
2. `domain/06-error-and-recovery.md` had no explicit owner deliverable
3. VTFrameProcessor had no fallback path (what if API doesn't match description?)
4. No traceability artifact for Agent 4 (added DOMAIN COVERAGE table requirement)

### Task 5: Agent 4 (REVIEW) — Two important issues
1. "Suggested fix" field in finding template contradicted the no-patching rule → renamed to "Routing"
2. Red threshold too permissive for core missions (could miss `domain/02-frame-delivery.md` completely and only flag Yellow) → added explicit core-mission files to Red criterion

### Task 8: Cross-prompt consistency check
- All I/O consistent across 4 agents
- One minor gap: Agent 4 didn't explicitly check for `design/07-ios-specific-risks.md` existence → added to quality gates

### Task 9: Dry-run validation surfaced architectural leakage
- "background thread" and "serial queue" in allowed-language list encode Android's thread-based concurrency model
- Fixed by removing them and adding a CAUTION block with the alternative framing

---

## Branch 6: Commits

**Six semantic commits** to the ios-translation repo (separate from main Flutter repo):

1. `docs`: spec + plan
2. `feat`: Agent 1 (AUDIT) prompt
3. `feat`: Agent 2 (EXTRACT) prompt
4. `feat`: Agent 3 (DESIGN) prompt
5. `feat`: Agent 4 (REVIEW) prompt
6. `chore`: archive old prompts + rewrite README

Ordered docs → features → chore so `git log` reads as a coherent redesign narrative.

---

## Branch 7: Orchestrator Prompt (final artifact)

**Trigger**: User asked for a meta-prompt that drives the 4-agent pipeline end to end using subagents (always sonnet).

**Framework**: RISEN for phase structure + ReAct for per-phase subagent dispatch loop.

**Defaults baked in**:
- Pause between agents for user review
- Never auto-retry BLOCKED subagents
- Never auto-rerun on Yellow/Red verdicts (escalate to user)
- Halt if screenshots directory empty
- Hard halt on language-discipline failures (iOS leakage in audit/, Android API leakage in domain/)
- Always use sonnet, never opus

**Output**: a pastable orchestrator prompt with 8 phases (Pre-flight, Setup, Screenshots, Agent 1-4, Final Report), verification greps between each phase, and structured status reporting.

---

## What We Learned Along the Way

1. **Organizational structure leaks into thinking.** The biggest insight. If the iOS designer reads Android-component-organized docs, the design comes out Android-shaped. Clean room requires different shape, not just filtered content.

2. **Over-guarding wastes tokens and signals defensiveness.** Many "DO NOT" instructions existed because of our conversation history, not because a fresh agent would have those failure modes. Positive instructions work better.

3. **Grep enforcement has false-positive traps.** Words like "Handler", "Surface", "Image", "Message" are both Android class names AND common English. A grep can't tell the difference. Solution: keep them in the forbidden list for LLM judgment, keep them OUT of the grep (which is best-effort, not complete).

4. **Architectural leakage is harder to catch than terminological leakage.** "Background thread" passes every grep but encodes Android's threading model. The dry-run validation caught this only because it asked "would the downstream agent produce Android-shaped output?" rather than "does the prompt use forbidden words?"

5. **Waterfall designs need feedback loops.** The Architect had no way to ask the Cartographer for more detail. Fix: gap analysis phase at the start of the Architect that identifies missing info and makes provisional choices with stated assumptions.

6. **The "why" is the hardest thing to capture.** Git log, code comments, and design plans contain the rationale that's invisible in the current code. Mining them is a first-class audit activity, not an afterthought.

7. **iOS expertise must be injected, not extracted.** Metal 4, Sendable, VTFrameProcessor, thermal throttling can't come from the Android audit. They're embedded in the design agent's prompt as reference architecture.

8. **VTFrameProcessor humility lesson.** I dismissed it as hallucinated after failing to verify via WebFetch (Apple docs need JavaScript). The user corrected me with the actual documentation. Lesson: when a search returns nothing, it might be search failure rather than nonexistence.

9. **Subagent-driven development catches real issues.** Every review round on every task found genuine problems. Rubber-stamping reviewers would have shipped broken prompts. The cost of iteration is real but the quality gain is higher.

10. **Commit-ask discipline matters.** "Never commit without asking" was already a project rule. It let the user review 6 semantically grouped commits instead of one giant drop, and kept the git history readable.

---

## Current State

**Repo**: `/Users/shrek/work/cambrian/ios-translation/` (separate git repo from the main Flutter demo)

**Files**:
```
ios-translation/
├── README.md                              # Pipeline overview
├── setup.sh                               # Pre-step: repomix + reference docs
├── prompt-1-audit.md                      # Agent 1 — 298 lines
├── prompt-2-extract.md                    # Agent 2 — 252 lines
├── prompt-3-design.md                     # Agent 3 — 464 lines
├── prompt-4-review.md                     # Agent 4 — 282 lines
├── prompt-1-cartographer.md.archived      # old 2-prompt pipeline
├── prompt-2-architect.md.archived         # old 2-prompt pipeline
├── docs/superpowers/
│   ├── specs/2026-04-12-clean-room-prompt-redesign-design.md
│   └── plans/2026-04-12-clean-room-prompt-redesign.md
├── audit/ domain/ design/ review/         # empty, ready for agent runs
├── packed/                                # Repomix output (populated by setup.sh)
├── screenshots/                           # User-provided
└── reference/                             # Architecture docs copied by setup.sh
```

**Git log**:
```
73b571f chore(ios-translation): archive 2-prompt pipeline and update README
6c91466 feat(ios-translation): add Agent 4 (REVIEW) prompt for clean room pipeline
dcd2c87 feat(ios-translation): add Agent 3 (DESIGN) prompt for clean room pipeline
0209350 feat(ios-translation): add Agent 2 (EXTRACT) prompt for clean room pipeline
97e2d4e feat(ios-translation): add Agent 1 (AUDIT) prompt for clean room pipeline
d31aa58 docs(ios-translation): add clean room prompt redesign spec and plan
```

**Ready to run**. Next action: run `setup.sh`, add screenshots, then either run agents manually or use the orchestrator prompt (not yet saved to a file) to drive the whole pipeline.
