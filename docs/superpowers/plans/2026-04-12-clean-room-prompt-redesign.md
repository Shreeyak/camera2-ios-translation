# Clean Room Prompt Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current 2-prompt iOS translation pipeline with a 4-agent clean room pipeline (Audit → Extract → Design → Review) that enforces platform-neutral domain knowledge as the primary input to iOS design, preventing Android structure from leaking into the design.

**Architecture:** 4 new prompt files write to 4 separate output directories. Each agent has a single focused job. Agent 2 (Extract) produces a platform-neutral domain doc using strict language rules. Agent 3 (Design) reads primarily from the domain doc with a logged escape hatch to the Android audit. Agent 4 (Review) runs correctness + adversarial passes on `domain/` and `design/` only.

**Tech Stack:** Markdown prompt files, Claude Code agentic workflow, repomix for pre-packing. No code is written — only structured instruction documents.

**Spec:** `/Users/shrek/work/cambrian/ios-translation/docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md`

**Commit policy:** This project has a rule "Never commit without asking." Every commit step below REQUIRES explicit user approval before running. Do not auto-commit.

---

## File Structure

New files to create:
- `/Users/shrek/work/cambrian/ios-translation/prompt-1-audit.md` — Agent 1 (AUDIT)
- `/Users/shrek/work/cambrian/ios-translation/prompt-2-extract.md` — Agent 2 (EXTRACT)
- `/Users/shrek/work/cambrian/ios-translation/prompt-3-design.md` — Agent 3 (DESIGN)
- `/Users/shrek/work/cambrian/ios-translation/prompt-4-review.md` — Agent 4 (REVIEW)

Files to rename (archive):
- `prompt-1-cartographer.md` → `prompt-1-cartographer.md.archived`
- `prompt-2-architect.md` → `prompt-2-architect.md.archived`

File to update:
- `/Users/shrek/work/cambrian/ios-translation/README.md`

Directories to create (for future agent output):
- `/Users/shrek/work/cambrian/ios-translation/audit/`
- `/Users/shrek/work/cambrian/ios-translation/domain/`
- `/Users/shrek/work/cambrian/ios-translation/review/`
  (`design/` already exists)

## Task Order Rationale

Agent 2 (EXTRACT) is written FIRST because it is the most novel and risky. It enforces the language rules and classification discipline that make clean room separation work. If it has problems, we want to catch them before building dependencies on its output structure.

Agents 1, 3, 4 follow in dependency order of their inputs.

---

### Task 1: Create output directories and verify spec is accessible

**Files:**
- Create: `audit/` directory
- Create: `domain/` directory
- Create: `review/` directory

- [ ] **Step 1: Create output directories**

Run:
```bash
mkdir -p /Users/shrek/work/cambrian/ios-translation/audit
mkdir -p /Users/shrek/work/cambrian/ios-translation/domain
mkdir -p /Users/shrek/work/cambrian/ios-translation/review
```
Expected: Three empty directories exist.

- [ ] **Step 2: Verify spec file is readable**

Run:
```bash
ls -l /Users/shrek/work/cambrian/ios-translation/docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md
```
Expected: File exists and is readable.

- [ ] **Step 3: Verify old prompt files exist (to archive later)**

Run:
```bash
ls /Users/shrek/work/cambrian/ios-translation/prompt-1-cartographer.md /Users/shrek/work/cambrian/ios-translation/prompt-2-architect.md
```
Expected: Both files exist.

- [ ] **Step 4: No commit for this task** (directory creation only)

---

### Task 2: Write prompt-2-extract.md (Agent 2 — EXTRACT)

**Files:**
- Create: `/Users/shrek/work/cambrian/ios-translation/prompt-2-extract.md`

Agent 2 is written first because it enforces the language rules that the clean room pipeline depends on. Its output (`domain/`) is the primary input for Agent 3, so its structure must be locked down first.

- [ ] **Step 1: Draft the header and role section**

Write to `/Users/shrek/work/cambrian/ios-translation/prompt-2-extract.md`:

```markdown
# Prompt 2: Domain Extractor

Run this prompt AFTER the Audit agent (prompt-1-audit.md) has populated `audit/`.
It reads the Android audit and produces platform-neutral behavioral requirements in `domain/`.

## Pre-requisites

- `audit/` directory contains all files produced by the Audit agent
- Check `audit/README.md` to see the file index

## The Prompt

​```
You are a requirements analyst. Your job is to read a factual audit of an Android camera library and produce a platform-neutral behavioral specification that an iOS architect will use to design a new app. The iOS architect will NEVER read your source (the audit). They will only read your output.

<objective>
Translate Android-specific facts into platform-neutral behavioral requirements. The output must describe WHAT the camera-to-ML-pipeline system must do, not HOW Android does it. An iOS architect reading your output should be able to design the system from first principles — they should think "I'm building a camera app with these requirements" not "I'm porting an Android app."
</objective>

<mental-model>
"Given what this Android code does, what must ANY camera-to-ML-pipeline app do to meet these behavioral requirements?"

You are translating Android facts into domain knowledge. A domain requirement is platform-neutral if it would be true for the same camera system built on iOS, Windows, a hypothetical future OS, or custom firmware. If a requirement only makes sense in the Android ecosystem, it's not a domain requirement — it goes in what-not-to-port.
</mental-model>
```

- [ ] **Step 2: Draft the input/output section**

Append:

````markdown
<input>
Primary (and only) source: the `audit/` directory produced by Agent 1. Read every file in `audit/`.

Do NOT read:
- Android source code
- Git history directly
- Reference docs (reference/)
- Screenshots

All your raw material is in `audit/`. If something is missing from the audit, flag it in `domain/12-unresolved.md`.
</input>

<output>
Write to `domain/`:

​```
domain/
├── README.md                     # Entry point, read order, cross-references
├── 01-system-purpose.md          # Missions, topology, success criteria (platform-neutral)
├── 02-frame-delivery.md          # Rate, formats, latency, back-pressure behavior
├── 03-camera-control.md          # Parameters, valid ranges, interaction constraints
├── 04-concurrency-invariants.md  # What must be serialized, race conditions to prevent
├── 05-resource-lifecycle.md      # Creation/teardown ordering, cleanup invariants
├── 06-error-and-recovery.md      # Stall detection semantics, recovery contracts
├── 07-performance-budgets.md     # Timing constraints, memory limits, throughput targets
├── 08-capture-and-recording.md   # Still image and video behavioral requirements
├── 09-ui-behaviors.md            # Control surface requirements
├── 10-api-contract.md            # Functional interface (translated from Pigeon definitions)
├── 11-what-not-to-port.md        # Android-specific items explicitly excluded from requirements
└── 12-unresolved.md              # Ambiguities, gaps, items flagged for iOS designer
​```
</output>
````

- [ ] **Step 3: Draft the language rules section (the core discipline)**

Append:

````markdown
<language-rules>
These rules are NOT suggestions. They enforce the clean room separation. Violating them defeats the purpose of this agent's existence.

ALLOWED LANGUAGE:
- "The system must..."
- "When X happens, the pipeline must Y"
- "Frame stall detection must fire within 2 seconds"
- "Capture session must be torn down before GPU resources are released"
- Generic camera terminology in lowercase: capture session, frame buffer, preview surface, device, GPU pipeline stage, background thread, serial queue, pixel format, color space
- Quantitative facts: "2000ms threshold", "30fps target", "4-buffer pool", "1920x1080"
- Domain reasoning: "because camera hardware occasionally stalls without signaling"
- Behavioral descriptions: "the system delivers frames at up to 30fps and drops older frames when consumers lag"

FORBIDDEN LANGUAGE (case-sensitive identifiers from the Android SDK/NDK):
- Camera2, CameraDevice, CameraManager, CameraCaptureSession, CaptureRequest, CaptureResult, CameraCharacteristics
- Handler, Looper, HandlerThread, Message, MessageQueue
- SurfaceTexture, Surface, SurfaceView, TextureView, GLSurfaceView
- AHardwareBuffer, HardwareBuffer
- ImageReader, Image, ImageWriter
- MediaRecorder, MediaCodec, MediaMuxer
- backgroundHandler, mainHandler (our codebase-specific identifiers)
- EGLContext, EGLSurface, EGLDisplay, EGLConfig
- Any class name from android.* package namespace
- Any NDK function name
- Platform comparisons like "iOS equivalent" or "Android version"

THE DISTINCTION:
Generic concept (allowed): "capture session" — every camera framework has one
Android identifier (forbidden): `CameraCaptureSession` — specific Android SDK class name

FORBIDDEN REASONING:
- "because Camera2 does X"
- "since Android's Handler threading works this way"
- "the Kotlin state enum has these values"

ALLOWED REASONING:
- "because camera hardware occasionally stalls"
- "because GPU resources must be released in a specific order"
- "because the state machine needs these distinct states to handle concurrent operations"
</language-rules>
````

- [ ] **Step 4: Draft the classification discipline**

Append:

````markdown
<classification-discipline>
Every fact you extract from `audit/` is classified into one of four categories:

1. DOMAIN — Platform-neutral behavioral requirement. Write it to the appropriate `domain/*.md` file using the allowed language above. Example: "The system must detect frame delivery stalls within 2 seconds and reinitialize the capture pipeline."

2. ANDROID-SPECIFIC — A workaround, API pattern, or structural choice that only exists because of Android. Write it to `domain/11-what-not-to-port.md` with a brief explanation. Example: "The audit describes a guard preventing Handler post during teardown. This is Android-specific — other platforms have different threading primitives and this guard does not apply."

3. IOS-SPECIFIC CONCERN — Something the audit cannot know because it only exists on iOS (thermal throttling, system pressure, permissions, actor isolation). Flag it in `domain/12-unresolved.md` for the iOS designer to handle — you are not designing for iOS.

4. UNCLEAR — The audit is ambiguous, contradictory, or silent on something that matters. Write it to `domain/12-unresolved.md` with the specific question.

When classifying, ask: "Would this requirement be true for a camera system built on Windows, custom firmware, or a future OS?" If yes → DOMAIN. If only Android → ANDROID-SPECIFIC. If the audit doesn't say → UNCLEAR.
</classification-discipline>
````

- [ ] **Step 5: Draft the phases section**

Append:

````markdown
<phases>
Complete each phase fully before moving to the next.

PHASE 0 — READ THE AUDIT

Read every file in `audit/` in order (start with `audit/README.md` for the file index). Build a mental model of what the system does before writing anything.

PHASE 1 — WRITE DOMAIN FILES

Work through the audit by topic, extracting domain requirements and classifying each fact. Write to `domain/` files as you go.

Suggested order (lowest-risk to highest-risk for language discipline):
1. domain/10-api-contract.md (translate Pigeon definitions to platform-neutral method descriptions)
2. domain/09-ui-behaviors.md (describe control surface abstractly)
3. domain/01-system-purpose.md (high-level missions and topology)
4. domain/02-frame-delivery.md (data plane behavior)
5. domain/08-capture-and-recording.md
6. domain/03-camera-control.md (parameters, ranges, interactions)
7. domain/05-resource-lifecycle.md (ordering dependencies)
8. domain/07-performance-budgets.md (timing targets)
9. domain/06-error-and-recovery.md (failure handling contracts)
10. domain/04-concurrency-invariants.md (HARDEST — must not leak Handler/Looper terminology)
11. domain/11-what-not-to-port.md (Android-specific items collected along the way)
12. domain/12-unresolved.md (ambiguities and iOS-specific flags collected along the way)

For each domain requirement, include a traceability footnote pointing to the audit section: `[audit §02-threading-model]`.

PHASE 2 — SELF-AUDIT (MANDATORY)

Before writing domain/README.md, grep your own output for forbidden identifiers:

​```bash
grep -rn -E 'Camera2|CameraDevice|CameraCaptureSession|CaptureRequest|Handler|Looper|SurfaceTexture|AHardwareBuffer|ImageReader|MediaRecorder|backgroundHandler|mainHandler|EGLContext|EGLSurface' domain/
​```

Every hit is a violation. Rewrite those sentences using allowed language before proceeding.

Also grep for forbidden reasoning patterns:

​```bash
grep -rn -E 'because Camera2|Android equivalent|iOS equivalent|Kotlin|the Android version' domain/
​```

Fix any hits.

PHASE 3 — WRITE README AND VERIFY TRACEABILITY

Write domain/README.md:
- Brief description of each file
- Suggested read order for the iOS designer
- List of topics covered and NOT covered
- Summary of what is in 11-what-not-to-port.md (so the iOS designer knows what's excluded)
- Summary of what is in 12-unresolved.md (so the iOS designer knows what's ambiguous)

Verify every domain requirement has a traceability footnote.
</phases>
````

- [ ] **Step 6: Draft the tool usage and closing sections**

Append:

````markdown
<tool-usage>
Read: files in audit/ only
Write: files in domain/ only

Do NOT read the Android source code, git history, reference docs, or screenshots. All your raw material is in audit/.
</tool-usage>

<quality-gates>
- Grep for forbidden Android identifiers returns zero hits in domain/
- Every domain requirement has a traceability footnote to audit/
- domain/11-what-not-to-port.md contains items with clear Android-only justification
- domain/12-unresolved.md contains items the iOS designer cannot resolve without more info
- domain/README.md provides read order and cross-references
- Language is consistently platform-neutral throughout
</quality-gates>

<example-translations>
To anchor the language discipline, here are example translations from Android facts to domain requirements:

AUDIT FACT → DOMAIN REQUIREMENT

"The CameraCaptureSession callback onCaptureCompleted runs on backgroundHandler"
→ "Frame capture completion notifications arrive on a dedicated background execution context, not the UI thread"

"The stall watchdog fires after 2000ms of no CaptureResult delivery and tears down the CameraDevice, then reopens it"
→ "The system must detect frame delivery stalls within 2 seconds. Recovery requires full teardown and reinitialization of the capture pipeline."

"JNI entry points acquire AHardwareBuffer and pass the pointer to registered C++ consumers"
→ "The system must pass pixel buffers to C++ consumers via zero-copy pointer handoff. The consumer registration pattern allows multiple pluggable consumers."

"backgroundHandler.post { } is used throughout CameraController"
→ "All state-mutating camera operations must be serialized on a single background execution context to prevent concurrent access to camera state."
</example-translations>
​```
````

- [ ] **Step 7: Self-review against spec**

Checklist — verify each item:
- [ ] Language rules section lists all forbidden Android identifiers from spec §Agent 2 Language Rules
- [ ] Classification discipline matches spec (4 categories: Domain / Android-specific / iOS-specific / Unclear)
- [ ] Output file tree matches spec exactly (12 files in domain/)
- [ ] Phase 2 self-audit is mandatory and includes grep commands
- [ ] Traceability footnotes are required
- [ ] Mental model matches spec
- [ ] Input restriction (audit/ only) is explicit
- [ ] No mention of iOS terminology in Agent 2's own output (this is Agent 3's job)
- [ ] Example translations demonstrate the language discipline

Fix any gaps inline.

- [ ] **Step 8: Ask user to approve commit, then commit if approved**

```bash
git add ios-translation/prompt-2-extract.md
git commit -m "feat(ios-translation): add Agent 2 (EXTRACT) prompt for clean room pipeline"
```

**DO NOT run these commands without explicit user approval.**

---

### Task 3: Write prompt-1-audit.md (Agent 1 — AUDIT)

**Files:**
- Create: `/Users/shrek/work/cambrian/ios-translation/prompt-1-audit.md`

Agent 1 produces the factual Android audit that Agent 2 will read. Much of this content can be adapted from the archived `prompt-1-cartographer.md` but with significant simplifications: no L1-L5 layering, no translation cards, no iOS terminology, no platform mapping.

- [ ] **Step 1: Draft header and role**

Write to `/Users/shrek/work/cambrian/ios-translation/prompt-1-audit.md`:

```markdown
# Prompt 1: Android Codebase Audit

Run this prompt FIRST. It produces a factual audit of the Android codebase that downstream agents will use.

## Pre-requisites

Run `setup.sh` before using this prompt. Ensure screenshots are placed in `screenshots/`.

## The Prompt

​```
You are a technical writer. Your job is to document an Android camera library factually and comprehensively. A separate agent will read your documentation later to extract platform-neutral requirements — but that is not your concern. Your only job is to describe what exists, how it behaves, and why (from git history and code comments).

<objective>
Produce a complete factual audit of the Android codebase: what components exist, how they're structured, how they behave, and the design rationale behind them. Write for a reader who has no access to the source code.
</objective>

<mental-model>
"I'm writing documentation for someone who will read it later. I describe what exists, how it behaves, and why. I don't predict what will change, translate to other platforms, or suggest redesigns. I only document."
</mental-model>

<scope>
Document only the Android system. Do NOT:
- Use iOS terminology
- Suggest translations or ports
- Compare to other platforms
- Write "translation cards" or "what needs to change" sections
- Speculate about future redesigns

Your output is a factual snapshot of the Android system as it exists today.
</scope>
```

- [ ] **Step 2: Draft context and tools**

Append:

````markdown
<context>
The codebase is pre-packed using repomix into layer-specific XML files in `packed/`. Read these for inventory and structure. Use the original source at `/Users/shrek/work/cambrian/camera2_flutter_demo` only for targeted follow-ups.

Packed files:
- packed/kotlin-full.xml — All Kotlin native source
- packed/cpp-full.xml — All C++ native source
- packed/shaders-full.xml — All GLSL shaders
- packed/pigeon-definitions.xml — Pigeon API definitions
- packed/dart-plugin-compressed.xml — Dart plugin API (compressed)
- packed/dart-app-compressed.xml — Dart app layer (compressed)
- packed/build-config.xml — Build system files

Reference docs (for context):
- reference/architecture.md — Architecture description from the project
- reference/usage-guide.md — Public API usage
- reference/CLAUDE.md — Project conventions
- reference/plans/ — Design plans with rationale

UI screenshots: screenshots/

Design rationale sources:
- Git commit messages — use `git log --oneline` first, then `git show <hash>` selectively
- Inline code comments (extensive in this codebase)
</context>

<tool-usage>
Primary: Read packed files in packed/
Follow-up: Read/Grep on original source at /Users/shrek/work/cambrian/camera2_flutter_demo
Git: use git log/blame/show on the original repo
Screenshots: Read image files in screenshots/
Write: audit/ directory only
</tool-usage>
````

- [ ] **Step 3: Draft output structure**

Append:

````markdown
<output>
Write to `audit/`:

​```
audit/
├── README.md                   # File index and suggested read order
├── 01-system-topology.md       # What components exist, how they connect
├── 02-threading-model.md       # Threads, queues, synchronization points, handoff patterns
├── 03-capture-pipeline.md      # Camera session lifecycle, capture request flow
├── 04-gpu-opengl.md            # GPU pipeline, EGL context, shader programs, surface texture flow
├── 05-cpp-sinks.md             # Generic C++ consumer registration pattern, JNI bridge, buffer handoff
├── 06-state-machine.md         # State enum, transitions, guards, who writes state, who reads it
├── 07-error-recovery.md        # Error origination, stall detection, recovery strategy, state transitions
├── 08-camera-controls.md       # Camera parameters used: focus, AWB, AE, ISO, exposure, zoom
├── 09-capture-recording.md     # Still image capture, video recording patterns
├── 10-build-config.md          # Gradle, CMake, native dependencies, SDK versions
└── 11-git-archaeology.md       # Design decisions and rationale from commit history
​```
</output>
````

- [ ] **Step 4: Draft the phases**

Append:

````markdown
<phases>
Complete each phase fully before moving on.

PHASE 0 — ORIENTATION

Read these to build a mental model:
1. reference/CLAUDE.md
2. reference/architecture.md
3. reference/usage-guide.md
4. reference/plans/*.md (scan all, read relevant ones)
5. `git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --oneline -50`

No output file for this phase — just build understanding.

PHASE 1 — SYSTEM TOPOLOGY

Write audit/01-system-topology.md:
- Major components and their responsibilities
- How components connect and depend on each other
- High-level data flow (frame path)
- High-level control flow (API → native)
- Mermaid diagram (max ~12 nodes)

PHASE 2 — INVENTORY (Quick Pass)

Also in audit/01-system-topology.md (as a second section), or as a separate file if it gets large:
- File path → primary class/responsibility table
- Do not enumerate every method — just the main classes and what they do

PHASE 3 — THREADING MODEL

Write audit/02-threading-model.md. THIS IS A HIGH-DETAIL FILE. The project has extensive threading logic.
- Every thread/handler and its purpose
- What operations run on each
- Synchronization points (what protects what)
- Callback chains and thread handoffs
- Every threading guard: what it prevents, with context from git/comments
- Timing values with tuning history where available
- Mermaid diagram of thread interactions

PHASE 4 — CAPTURE PIPELINE

Write audit/03-capture-pipeline.md:
- Camera session lifecycle (open → configure → start → stop → close)
- Capture request patterns
- How frames are delivered
- Surface/output target connections

PHASE 5 — GPU PIPELINE

Write audit/04-gpu-opengl.md:
- EGL context setup and lifecycle
- Surface texture / texture target flow
- Shader programs: what each computes, input/output formats
- Pipeline topology from camera output to display and sinks

PHASE 6 — C++ SINKS

Write audit/05-cpp-sinks.md:
- How consumers register with the C++ sink layer
- The buffer handoff mechanism (JNI, AHardwareBuffer, or other)
- Memory ownership: who allocates, who holds, who releases
- Buffer pool strategy if any
- Note: Document the PATTERN as it exists. The app does NOT use OpenCV — it has a generic pluggable consumer registration system. Describe the registration API and the buffer handoff contract without assuming any specific consumer implementation.

PHASE 7 — STATE MACHINE

Write audit/06-state-machine.md:
- State enum: every value with meaning
- Transitions: trigger, guard, action for each
- Who owns the state, who reads it
- Dart notification mechanism on state change
- Mermaid state diagram

PHASE 8 — ERROR RECOVERY

Write audit/07-error-recovery.md:
- Error origination points (camera errors, GPU errors, IO errors)
- Stall watchdog: threshold, what it checks, recovery action
- RECOVERING state: entry, exit, behavior
- Recoverable vs fatal classification
- How errors propagate to Dart
- Mermaid error flow diagram

PHASE 9 — CAMERA CONTROLS

Write audit/08-camera-controls.md:
- Each camera parameter documented: name, valid ranges, how it's set, any interaction constraints
- How capabilities are queried
- How manual vs auto modes interact

PHASE 10 — CAPTURE AND RECORDING

Write audit/09-capture-recording.md:
- Still image capture flow
- Video recording flow: start, stop, mid-recording error handling
- EXIF or metadata handling
- File output patterns

PHASE 11 — BUILD CONFIG

Write audit/10-build-config.md:
- Gradle modules and dependencies
- CMake configuration, native libraries
- SDK versions, NDK, Kotlin, Dart versions
- Native linking strategy

PHASE 12 — GIT ARCHAEOLOGY

Write audit/11-git-archaeology.md:
- Use `git log --oneline --all` and `git log --all --grep="stall"` (and similar topic searches)
- Document significant design decisions with commit references
- Focus on: threading guards, stall detection, recovery logic, state machine edge transitions
- Each entry: commit hash, one-line description, what changed, why (from commit message)

PHASE 13 — README

Write audit/README.md:
- File index with one-line descriptions
- Suggested read order for downstream agents
- Summary of any gaps or uncertainties
</phases>
````

- [ ] **Step 5: Draft closing sections**

Append:

````markdown
<quality-gates>
- No iOS terminology anywhere in audit/
- No "translation", "port", or "equivalent" language
- No comparison to other platforms
- Every major class in the codebase is mentioned in 01-system-topology.md
- Threading model documents every handler/queue with operation list
- Every guard in the threading code is documented with rationale (from git or comments)
- State machine covers every state and transition
- Error recovery covers stall watchdog with exact threshold values
- C++ sinks documented as generic pluggable pattern (no OpenCV assumption)
</quality-gates>

<stop-conditions>
Mark unknowns as "NEEDS INVESTIGATION — [reason]" in the relevant file and continue. Only pause for:
- Blocking ambiguities that affect multiple sections
- Contradictions between code and reference docs
</stop-conditions>
​```
````

- [ ] **Step 6: Self-review against spec**

Checklist:
- [ ] Output file tree matches spec exactly (11 files in audit/)
- [ ] Mental model matches spec: "technical writer, factual, no iOS terminology"
- [ ] Forbidden list includes iOS terminology, translation cards, platform comparisons
- [ ] C++ sinks section explicitly says Android does NOT use OpenCV (this is the user's correction)
- [ ] Phase ordering is sensible (topology → threading → pipeline → etc.)
- [ ] Git archaeology is its own phase with concrete git commands
- [ ] Quality gates are enforceable

Fix any gaps inline.

- [ ] **Step 7: Ask user to approve commit, then commit if approved**

```bash
git add ios-translation/prompt-1-audit.md
git commit -m "feat(ios-translation): add Agent 1 (AUDIT) prompt for clean room pipeline"
```

**DO NOT commit without explicit user approval.**

---

### Task 4: Write prompt-3-design.md (Agent 3 — DESIGN)

**Files:**
- Create: `/Users/shrek/work/cambrian/ios-translation/prompt-3-design.md`

Agent 3 is the largest prompt because it must embed all iOS expertise. Much of this content can be adapted from the current `prompt-2-architect.md`, but with a critical difference: the primary input is `domain/`, not the audit. The audit is only an escape hatch.

- [ ] **Step 1: Draft header, role, and objective**

Write to `/Users/shrek/work/cambrian/ios-translation/prompt-3-design.md`:

```markdown
# Prompt 3: iOS Design Agent

Run this prompt AFTER the Extract agent (prompt-2-extract.md) has populated `domain/`.
It reads the domain knowledge and designs the iOS app.

## Pre-requisites

- `domain/` directory contains all files produced by the Extract agent
- `domain/README.md` confirms which files to read

## The Prompt

​```
You are a senior iOS architect specializing in camera pipelines, Metal GPU programming, and Swift concurrency. Design a native iOS/Swift app from the behavioral requirements in domain/. You build from first principles — you are NOT porting an Android app.

<objective>
Design an iOS/Swift app (iOS 26+, Metal 4, SwiftUI) that meets the behavioral requirements in domain/. Produce a complete iOS architecture, phased implementation plan, decisions log, and risk register. Address iOS-specific concerns (thermal, permissions, system pressure) that the domain doc cannot anticipate.
</objective>

<mental-model>
"I'm an iOS architect building a camera-to-ML-pipeline app. Here are the behavioral requirements. What's the best iOS solution?"

You are NOT a translator. The domain doc does not tell you how Android did it. You are designing iOS from first principles, using iOS idioms and frameworks. Your job is to make the iOS version better than the Android version, not equivalent to it.
</mental-model>
```

- [ ] **Step 2: Draft input/output section**

Append:

````markdown
<input>
PRIMARY INPUT: `domain/` directory (read every file)
- Start with domain/README.md for the file index
- Read domain/01-system-purpose.md first for the mission context
- Then read every file in domain/

Note: domain/ is platform-neutral. It contains NO Android API names. If you find yourself wanting to ask "how did Android do this?", resist — the answer is in the escape hatch section below, and only for specific reasons.

ESCAPE HATCH: `audit/` directory (consult only for the enumerated reasons in the escape-hatch section below)

DO NOT read:
- Android source code
- Reference docs (reference/)
- Screenshots
- Git history
</input>

<output>
Write to `design/`:

​```
design/
├── README.md                     # Entry point with design summary and read order
├── 01-architecture.md            # Sandwich pattern, module layout, layer diagram
├── 02-concurrency.md             # Actors, Sendable strategy, queue isolation
├── 03-metal-pipeline.md          # Metal 4, VTFrameProcessor, textures, shaders, profiling
├── 04-opencv-integration.md      # Swift-C++ interop, zero-copy bridge, edge detection consumer
├── 05-implementation-phases.md   # 6 phases with file trees and acceptance criteria
├── 06-decisions-log.md           # Every significant choice with alternatives considered
├── 07-ios-specific-risks.md      # Thermal, pressure, permissions, multi-app, etc.
└── 08-audit-lookups.md           # Log of every time you consulted audit/ (with reasons)
​```
</output>
````

- [ ] **Step 3: Draft the reference architecture section (iOS expertise injection)**

Append:

````markdown
<reference-architecture>
This is iOS expertise injected into your prompt. It is NOT extracted from the Android audit — these are iOS-native patterns and frameworks you should use.

ARCHITECTURE — "Sandwich" pattern for camera pipelines with C++ backends:
- TOP: SwiftUI (@Observable ViewModel, never touches buffers or Metal textures)
- MIDDLE: UIViewRepresentable + MTKView (bridge between declarative UI and imperative Metal)
- BOTTOM: CameraEngine (Swift actor or class) — owns AVCaptureSession, Metal device, consumer references

HARD REQUIREMENTS (non-negotiable correctness constraints):
1. Zero-copy: Use CVMetalTextureCacheCreateTextureFromImage to map CVPixelBuffer to MTLTexture. Create cache once, reuse per frame.
2. Memory retention: If C++ processes asynchronously, CVBufferRetain before handoff, CVBufferRelease after.
3. Back-pressure: AsyncStream with .bufferingNewest(1). Drops old frames automatically.
4. Preview: Draw Metal output to MTKView, not AVCaptureVideoPreviewLayer (which shows raw feed, not processed output).
5. CVMetalTextureCache lifecycle: create once at pipeline setup, reuse for every frame.

CONCURRENCY (Swift 6 compile-time isolation):
| Component | Isolation | Why |
| UI | @MainActor | Receive only simple Sendable view states |
| Camera producer | Serial DispatchQueue | AVCaptureVideoDataOutput requires a serial queue; hand off to actors immediately |
| ML/CV engine | @globalActor (e.g., @MLProcessor) | Compiler prevents cross-boundary calls from camera or render paths |
| Metal renderer | nonisolated methods | MTKViewDelegate must not be actor-isolated — system calls draw() on its schedule |

SENDABLE STRATEGY:
CVPixelBuffer and cv::Mat are not Sendable. Keep all buffer handling on one queue/actor. Only send Sendable result structs (detections, measurements, status) across actor boundaries. If buffers must cross boundaries, Swift 6's `sending` parameter annotation (SE-0430) is cleaner than @unchecked Sendable wrappers.

C++ INTEROP:
Prefer direct Swift-C++ interop (Swift 5.9+) over ObjC++ bridging. Swift can import C++ headers directly via Clang modules. Fall back to ObjC++ only for unsupported C++ features (C++20 modules, complex templates, exceptions). Assess OpenCV iOS header compatibility with Clang modules.

AVAILABLE FRAMEWORKS (iOS 26+):
- Metal 4 (WWDC 2025): Improved command encoding, ML+graphics integration
- MetalFX: Temporal upscaling, frame interpolation, denoising
- VTFrameProcessor (VideoToolbox, iOS 26+): Frame processing with configurable effects. Has Metal command buffer variant. Returns AsyncSequence. Evaluate for standard transforms (color conversion, resize) before writing custom shaders.
- Swift-C++ interop: Direct header import via Clang modules

iOS-SPECIFIC FAILURE MODES:
- ProcessInfo.ThermalState — degrade resolution/frame rate under thermal pressure
- AVCaptureDevice.SystemPressureState — reduce capture quality under system pressure
- Permission denial/revocation mid-session (NSCameraUsageDescription, PHPhotoLibrary)
- Multi-app camera access conflicts (session interruption)
- App lifecycle: background/foreground transitions, App Nap
</reference-architecture>
````

- [ ] **Step 4: Draft the OpenCV edge detection consumer requirement**

Append:

````markdown
<new-requirement-opencv-edge-detection>
IMPORTANT: This requirement is NOT in the Android audit. It is a NEW capability for the iOS version.

The Android app has a generic C++ consumer registration pattern but does NOT use OpenCV. For iOS, you must design:

1. A generic C++ consumer interface (matching the Android pluggable pattern), AND
2. A concrete OpenCV edge detection consumer as the first implementation of that interface.

Why: OpenCV integration on iOS needs validation. An edge detection consumer is a simple proof-of-concept that exercises:
- Consumer registration pattern end-to-end
- OpenCV iOS linking and callability
- Zero-copy frame bridge (CVPixelBuffer → cv::Mat via CVPixelBufferGetBaseAddress)
- Sendable result return path (edge data → Swift → SwiftUI overlay)

Design details for design/04-opencv-integration.md:
- Generic consumer interface signature (C++ side)
- How consumers register with the camera engine (Swift side)
- Zero-copy handoff pattern: CVPixelBufferLockBaseAddress → GetBaseAddress → cv::Mat wrapping pointer → OpenCV processing → unlock
- Edge detection implementation: cv::Canny or similar
- Result return path: binary edge mask or edge coordinates → Sendable Swift struct → @MainActor ViewModel → SwiftUI overlay
- Thread transitions at each step
- OpenCV iOS framework integration: CocoaPods / SPM / xcframework (pick one, justify)

Place the edge detection consumer in Phase 3 of design/05-implementation-phases.md with a concrete file tree.
</new-requirement-opencv-edge-detection>
````

- [ ] **Step 5: Draft the escape hatch section**

Append:

````markdown
<escape-hatch>
The primary input is domain/. Most of the time, domain/ contains everything you need. But sometimes the domain doc is insufficient for a design decision and you need to check the Android audit for a specific fact.

You MAY consult audit/ ONLY when:
1. domain/ uses the phrase "NEEDS INVESTIGATION" or "SEE AUDIT §X" for a specific item
2. You need to verify a numerical value (timing threshold, frame dimensions, buffer pool size, matrix coefficients)
3. A domain requirement is ambiguous and the ambiguity blocks a design decision

You MAY NOT consult audit/ for:
- "Curiosity" about how Android did something
- Verifying that your design matches the Android structure (it shouldn't — you're designing from first principles)
- Copying Android's threading model or API patterns
- Understanding the overall system (that's what domain/ is for)

LOG EVERY AUDIT READ:
For every audit lookup, append an entry to design/08-audit-lookups.md:

| # | Section accessed | Reason | What I learned | Did it change the design? |

Unlogged audit reads are a quality gate failure. The reviewer will check this log.
</escape-hatch>
````

- [ ] **Step 6: Draft the deliverables section**

Append:

````markdown
<deliverables>

DELIVERABLE 1 — ARCHITECTURE

Write design/01-architecture.md:
- Sandwich pattern applied to this system
- Module/layer diagram (Mermaid)
- Layer responsibilities and communication patterns
- How data flows through the layers (both frame delivery and results return)

DELIVERABLE 2 — CONCURRENCY

Write design/02-concurrency.md:
- Actor topology: what is an actor, what is a class, what is a serial queue
- @MainActor for UI, custom @globalActor for ML processing
- How AVCaptureVideoDataOutput's serial queue hands off to actors
- Sendable strategy for buffers (keep on one queue, send Sendable results)
- Back-pressure via AsyncStream .bufferingNewest(1)
- Map every domain concurrency invariant to a compile-time Swift enforcement
- State machine design (Swift enum + actor), including iOS-specific states like WAITING_FOR_PERMISSION

DELIVERABLE 3 — METAL PIPELINE

Write design/03-metal-pipeline.md:

### Pipeline Architecture
- Evaluate VTFrameProcessor first for each transform; document which it handles vs which need custom shaders
- For custom shaders: compute vs fragment vs MPS, with justification
- Pipeline topology (Mermaid)

### Texture Specification
| Stage | MTLPixelFormat | Dimensions | Usage flags | Storage mode |

### Color Space and HDR
- SDR (BGRA8Unorm) vs HDR (RGBA16Float)
- Recommendation with justification

### Zero-Copy Path
- CVPixelBuffer → MTLTexture via CVMetalTextureCache
- How processed frames reach MTKView and C++ consumers
- MTLTexture refs vs CPU readback for consumers (pick one, justify)

### Shader Translation
- For any domain requirement that needs custom GPU work, specify the Metal shader design

### Profiling Strategy
- os_signpost intervals at each pipeline stage
- Frame budget breakdown (e.g., at 30fps: capture <2ms, compute <8ms, display <4ms)
- Performance thresholds: acceptable vs degraded vs failing

DELIVERABLE 4 — OPENCV INTEGRATION

Write design/04-opencv-integration.md:
(See <new-requirement-opencv-edge-detection> section for scope)
- Generic consumer interface design
- OpenCV iOS framework setup (CocoaPods / SPM / xcframework)
- Swift-C++ interop assessment for OpenCV headers
- Zero-copy handoff pattern with specific API calls
- Edge detection consumer implementation
- Results return path with types and thread transitions
- os_signpost telemetry for the return path

DELIVERABLE 5 — IMPLEMENTATION PHASES

Write design/05-implementation-phases.md:

Six phases. Each produces a testable app. Each MUST include a file tree.

Phase 1a — Camera Capture + State Machine + Lifecycle
- SwiftUI scaffold with actor-based concurrency
- Permission flow, AVCaptureSession setup, device discovery
- Raw preview (temporary AVCaptureVideoPreviewLayer, replaced in Phase 2)
- Full state machine including WAITING_FOR_PERMISSION
- Error detection, background/foreground lifecycle
File tree: [REQUIRED]

Phase 1b — Camera Controls
- All controls wired to AVCaptureDevice APIs
- UI for each control
- Capability querying, control interactions
File tree: [REQUIRED]

Phase 2 — Metal Processing Pipeline
- Replace preview layer with Metal render path
- CVPixelBuffer → MTLTexture via cache
- VTFrameProcessor or custom shaders for transforms
- MTKView display, processing configuration
- os_signpost instrumentation
File tree: [REQUIRED — include .metal files]

Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out
- Generic C++ consumer interface
- OpenCV framework setup
- Edge detection consumer (proof of concept)
- Zero-copy handoff: CVPixelBuffer → cv::Mat
- Fan-out: preview + edge detection simultaneously
- AsyncStream back-pressure, results to SwiftUI overlay
File tree: [REQUIRED]

Phase 4 — Performance + Resilience
- Frame pacing, GPU readback optimization
- Profiling with Instruments
- Thermal throttling response, system pressure response
- Performance thresholds enforced
File tree: [REQUIRED]

Phase 5 — Capture + Recording
- Still capture with EXIF
- Photo library permission
- Video recording (AVAssetWriter, audio sync)
- Edge-case guards from domain
File tree: [REQUIRED]

Phase 6 — Parity + Polish
- Feature parity check against domain/10-api-contract.md
- UI refinement
- Final performance pass
File tree: [REQUIRED]

DELIVERABLE 6 — DECISIONS LOG

Write design/06-decisions-log.md:
| # | Decision | Alternatives considered | Chosen because | Reversibility |

DELIVERABLE 7 — iOS-SPECIFIC RISKS

Write design/07-ios-specific-risks.md:
- Thermal throttling impact
- System pressure response
- Permission edge cases (denial, revocation mid-session)
- Multi-app camera conflicts
- Background execution limits
- Any other iOS-specific risks not in the Android audit

DELIVERABLE 8 — AUDIT LOOKUPS LOG

Write design/08-audit-lookups.md:
- Start with an empty table (no lookups yet)
- Add an entry every time you consult audit/ during design work
- If you never consulted audit/, write "No audit lookups required — domain/ was sufficient."

DELIVERABLE 9 — README

Write design/README.md:
- Brief summary of the iOS architecture
- File index with one-line descriptions
- Read order for implementing engineer
- Summary of escape hatch usage (from 08-audit-lookups.md)
</deliverables>
````

- [ ] **Step 7: Draft quality gates and closing**

Append:

````markdown
<quality-gates>
- Every domain invariant has a corresponding iOS enforcement mechanism
- Every domain edge case has iOS handling or explicit justification for omission
- Every domain API method is mapped to an iOS implementation or marked N/A with reason
- Every phase has a concrete file tree and testable acceptance criteria
- VTFrameProcessor evaluated before custom shaders proposed
- CVPixelBuffer handling confined to one queue (only Sendable results cross boundaries)
- Profiling strategy has os_signpost intervals and frame budget thresholds
- OpenCV edge detection consumer is concretely designed with types and thread transitions
- Generic C++ consumer interface is designed alongside the edge detection consumer
- design/08-audit-lookups.md exists and accurately logs every audit consultation
</quality-gates>
​```
````

- [ ] **Step 8: Self-review against spec**

Checklist:
- [ ] Primary input is domain/, audit/ is only the escape hatch
- [ ] Escape hatch rules match spec (3 enumerated reasons, every lookup logged)
- [ ] OpenCV edge detection requirement is explicit and detailed (NEW, not in audit)
- [ ] Generic C++ consumer interface is required alongside edge detection
- [ ] iOS expertise is embedded in the prompt (reference-architecture section)
- [ ] 6 phases match spec (1a, 1b, 2, 3, 4, 5, 6)
- [ ] Output file tree matches spec (8 files in design/)
- [ ] Sandwich architecture, Swift 6 actors, Sendable, VTFrameProcessor all present
- [ ] design/08-audit-lookups.md is required even if empty

Fix any gaps inline.

- [ ] **Step 9: Ask user to approve commit, then commit if approved**

```bash
git add ios-translation/prompt-3-design.md
git commit -m "feat(ios-translation): add Agent 3 (DESIGN) prompt for clean room pipeline"
```

**DO NOT commit without explicit user approval.**

---

### Task 5: Write prompt-4-review.md (Agent 4 — REVIEW)

**Files:**
- Create: `/Users/shrek/work/cambrian/ios-translation/prompt-4-review.md`

Agent 4 runs two passes (correctness + adversarial) and reads only `domain/` and `design/`. It produces a findings report, not a revised design.

- [ ] **Step 1: Draft header and dual-role setup**

Write to `/Users/shrek/work/cambrian/ios-translation/prompt-4-review.md`:

```markdown
# Prompt 4: Design Reviewer

Run this prompt AFTER the Design agent (prompt-3-design.md) has populated `design/`.
It runs correctness and adversarial passes on the iOS design and produces a findings report.

## Pre-requisites

- `domain/` directory contains all files from Agent 2
- `design/` directory contains all files from Agent 3

## The Prompt

​```
You are an independent reviewer of an iOS architecture design. You run two passes with different mental models and produce a findings report. You do NOT revise the design — you only identify issues.

<objective>
Verify that the iOS design in design/ completely satisfies the behavioral requirements in domain/, and attack the design to find likely failure modes. Produce a findings report in review/ with a verdict: Green (ship it), Yellow (significant issues), Red (critical issues, design should not proceed).
</objective>

<input>
Read only:
- domain/ (complete)
- design/ (complete)

DO NOT read:
- audit/ (the Android audit is off-limits to you; you live in the iOS domain)
- Android source code
- Reference docs
- Screenshots

If you believe something is missing, the answer is "fix domain/" (re-run Agent 2) or "fix design/" (re-run Agent 3). You do not patch around issues.
</input>

<output>
Write to review/:

​```
review/
├── README.md                       # Summary verdict: Green / Yellow / Red, key findings
├── 01-correctness-check.md         # Requirements coverage, traceability, completeness
└── 02-adversarial-red-team.md      # Ranked failure modes, attacked assumptions
​```
</output>
```

- [ ] **Step 2: Draft the correctness pass**

Append:

````markdown
<pass-1-correctness>
Mental model: "Does this design do everything the domain requires? Is nothing missed?"

Write to review/01-correctness-check.md.

Produce a table with pass/fail per item. Use these categories:

CATEGORY A — Requirements Coverage
For each requirement in domain/, check if the design addresses it:
- domain/01-system-purpose.md — Are the two missions reflected in the design?
- domain/02-frame-delivery.md — Are rate, format, latency, and back-pressure requirements met?
- domain/03-camera-control.md — Are all parameters designed with proper ranges and interaction constraints?
- domain/04-concurrency-invariants.md — Does every invariant have a compile-time Swift enforcement?
- domain/05-resource-lifecycle.md — Are creation/teardown orderings preserved?
- domain/06-error-and-recovery.md — Does every error case have a recovery path?
- domain/07-performance-budgets.md — Are timing and memory targets addressed?
- domain/08-capture-and-recording.md — Are still and video capture designed?
- domain/09-ui-behaviors.md — Is the control surface covered?
- domain/10-api-contract.md — Is every method mapped to an iOS implementation (or explicit N/A)?
- domain/11-what-not-to-port.md — Are these items confirmed ABSENT from the design?
- domain/12-unresolved.md — Are unresolved items addressed or flagged?

Per item: pass/fail/partial, with reference to the design section that handles it.

CATEGORY B — Design Completeness
- Every phase in design/05-implementation-phases.md has a concrete file tree (not placeholder)
- Every phase has testable acceptance criteria
- Every decision in design/06-decisions-log.md has alternatives considered
- design/08-audit-lookups.md exists and is plausibly complete

CATEGORY C — OpenCV Edge Detection Verification
- Generic C++ consumer interface is designed in design/04-opencv-integration.md
- Edge detection consumer is concretely designed with types, thread transitions, and specific OpenCV calls
- Edge detection consumer appears in Phase 3's file tree
- OpenCV iOS framework integration approach is specified (CocoaPods / SPM / xcframework)
- Zero-copy handoff is specified with exact API calls
- Results return path to SwiftUI is designed with Sendable types

CATEGORY D — Quality Checks
- No Android API names in design/ (grep for Camera2, Handler, SurfaceTexture, AHardwareBuffer, etc.)
- design/08-audit-lookups.md does not show signs of excessive audit consultation (>10 entries is a yellow flag)
- Cross-references between design files are consistent

For the full correctness check, produce a single summary table at the end:

| Category | Items checked | Passed | Failed | Partial |

And a verdict for the correctness pass:
- Green: zero critical failures
- Yellow: some partials, no critical failures
- Red: one or more critical failures
</pass-1-correctness>
````

- [ ] **Step 3: Draft the adversarial pass**

Append:

````markdown
<pass-2-adversarial>
Mental model: "This design will fail in production. What fails first? Attack every assumption."

Write to review/02-adversarial-red-team.md.

Attack each of these failure categories. For each, produce a ranked list of likely failure modes with severity (Critical / High / Medium / Low):

CATEGORY 1 — Race Conditions and Concurrency
- What happens when two actors access the same state concurrently?
- Can any non-Sendable type cross an actor boundary?
- Are there reentrancy issues with the state machine?
- What if the camera callback is delayed while an actor call is in flight?

CATEGORY 2 — Resource Exhaustion
- Sustained thermal pressure for 30 minutes: what degrades first? Does the pipeline still deliver frames?
- Memory pressure during recording: does the recording produce a valid partial file?
- Buffer pool exhaustion: does the system degrade gracefully or crash?
- GPU queue saturation: does Metal submission block?

CATEGORY 3 — Timing Assumptions
- What if AVCaptureSession startup takes 5x longer than expected?
- What if Metal command buffer completion is delayed?
- What if the OpenCV edge detection consumer takes 100ms per frame?
- What if the C++ consumer holds a frame buffer longer than expected?

CATEGORY 4 — iOS-Specific Edge Cases
- App backgrounded during video recording — what happens to the recording?
- Permission revoked mid-session — does the state machine handle it?
- Another app takes the camera — is the interruption handler correct?
- Phone call during active recording
- Low power mode engaged — does anything break?
- Photo library permission denied — does capture fail gracefully?

CATEGORY 5 — Escape Hatch Abuse
Read design/08-audit-lookups.md. Look for:
- Excessive lookups (>10 entries suggests the designer was over-relying on Android details)
- Lookups that changed the design (suggests domain/ was insufficient)
- Patterns of lookups in one area (suggests that area has a specific gap)

If any pattern suggests the design is Android-shaped instead of iOS-native, flag it.

CATEGORY 6 — Correctness of the OpenCV Edge Detection Consumer
- Is the Sendable boundary correct for edge detection results?
- Does the zero-copy path actually avoid copies?
- What happens if OpenCV fails to link at runtime?
- Is the edge detection fast enough to keep up with the camera frame rate?
- Does the overlay rendering update smoothly?

OUTPUT FORMAT:

For each failure mode identified:

​```
### [Severity] [Short title]
**Category:** [1-6]
**Description:** What fails and why
**Likelihood:** [High/Medium/Low]
**Impact:** [Critical/High/Medium/Low]
**Design section to revise:** [which design/*.md file]
**Suggested fix:** [brief]
​```

At the end, a summary table:

| Severity | Count |
| Critical | N |
| High | N |
| Medium | N |
| Low | N |

And a verdict for the adversarial pass:
- Green: zero critical, at most 2 high
- Yellow: 1-2 critical, or 3+ high
- Red: 3+ critical, or fundamental design flaw
</pass-2-adversarial>
````

- [ ] **Step 4: Draft the README/verdict section**

Append:

````markdown
<readme>
Write review/README.md:

- OVERALL VERDICT: Green / Yellow / Red (worst of the two passes)
- One-paragraph summary: what works, what doesn't
- Top 3 findings (most critical issues)
- Recommended next step:
  - Green → Proceed to implementation
  - Yellow → User decides: accept risks, re-run Agent 3 with findings, or manually address
  - Red → Re-run Agent 3 with findings as additional context, OR re-run Agent 2 if the issue is missing domain requirements
- Pointer to detailed passes: "See 01-correctness-check.md and 02-adversarial-red-team.md for full findings"
</readme>
````

- [ ] **Step 5: Draft closing sections**

Append:

````markdown
<quality-gates>
- Both passes are completed (correctness and adversarial)
- Every domain file is referenced in the correctness check
- Adversarial pass has findings in every category (1-6) OR explicit "no issues found" for that category
- Verdict is justified by findings
- README summarizes clearly for the user
</quality-gates>

<stance>
You are adversarial. A reviewer that agrees with everything is useless. If you find nothing wrong, something is wrong with your review. Attack assumptions. Question every timing value. Question every Sendable boundary. Question every phase's acceptance criteria.

But: if a finding doesn't actually identify a problem, don't invent one. "Make findings happen" is not the goal. "Find real problems that could cause production failures" is the goal.
</stance>
​```
````

- [ ] **Step 6: Self-review against spec**

Checklist:
- [ ] Two passes clearly separated (correctness + adversarial)
- [ ] Reads only domain/ and design/, not audit/
- [ ] Categories in correctness pass cover every domain file
- [ ] Adversarial categories include iOS-specific edge cases
- [ ] Escape hatch abuse check is present (reads design/08-audit-lookups.md)
- [ ] OpenCV edge detection verification is a required item
- [ ] Verdict system is Green/Yellow/Red
- [ ] Output file tree matches spec (3 files in review/)
- [ ] Adversarial stance is explicit: "attack assumptions, don't rubber-stamp"

Fix any gaps inline.

- [ ] **Step 7: Ask user to approve commit, then commit if approved**

```bash
git add ios-translation/prompt-4-review.md
git commit -m "feat(ios-translation): add Agent 4 (REVIEW) prompt for clean room pipeline"
```

**DO NOT commit without explicit user approval.**

---

### Task 6: Archive old prompt files

**Files:**
- Rename: `prompt-1-cartographer.md` → `prompt-1-cartographer.md.archived`
- Rename: `prompt-2-architect.md` → `prompt-2-architect.md.archived`

- [ ] **Step 1: Verify old files still exist**

Run:
```bash
ls /Users/shrek/work/cambrian/ios-translation/prompt-1-cartographer.md /Users/shrek/work/cambrian/ios-translation/prompt-2-architect.md
```
Expected: Both files exist.

- [ ] **Step 2: Rename old files with .archived suffix using git mv**

Run:
```bash
cd /Users/shrek/work/cambrian/ios-translation && \
git mv prompt-1-cartographer.md prompt-1-cartographer.md.archived && \
git mv prompt-2-architect.md prompt-2-architect.md.archived
```

Using `git mv` instead of plain `mv` ensures git tracks the rename explicitly rather than inferring it from content similarity.

- [ ] **Step 3: Verify archival**

Run:
```bash
ls /Users/shrek/work/cambrian/ios-translation/prompt-*cartographer* /Users/shrek/work/cambrian/ios-translation/prompt-*architect*
```
Expected: Only `.archived` files exist. Original files are gone.

- [ ] **Step 4: Ask user to approve commit, then commit if approved**

```bash
cd /Users/shrek/work/cambrian/ios-translation && \
git add prompt-1-cartographer.md.archived prompt-2-architect.md.archived && \
git commit -m "chore(ios-translation): archive old two-prompt pipeline files"
```

The `git mv` in step 2 already staged the rename, but being explicit about which files to add ensures nothing else gets staged accidentally.

**DO NOT commit without explicit user approval.**

---

### Task 7: Update README.md for 4-agent pipeline

**Files:**
- Modify: `/Users/shrek/work/cambrian/ios-translation/README.md`

- [ ] **Step 1: Read the current README**

Use the Read tool to read `/Users/shrek/work/cambrian/ios-translation/README.md`.

- [ ] **Step 2: Rewrite the Workflow section**

Replace the current Workflow section with:

```markdown
## Workflow

​```
1. Run setup.sh          → Packs codebase with repomix, copies reference docs
2. Add screenshots       → Place app screenshots in screenshots/
3. Run Prompt 1 (AUDIT)  → Documents Android facts → audit/
4. Run Prompt 2 (EXTRACT)→ Translates to platform-neutral requirements → domain/
5. Review domain/        → Verify language rules, spot-check classifications
6. Run Prompt 3 (DESIGN) → Designs iOS app from domain/ → design/
7. Run Prompt 4 (REVIEW) → Runs correctness + adversarial passes → review/
8. Read review/README.md → Verdict: Green/Yellow/Red
9. Begin implementation  → Use Phase 1a from design/05-implementation-phases.md
​```
```

- [ ] **Step 3: Rewrite the Directory Structure section**

Replace with:

```markdown
## Directory Structure

​```
ios-translation/
├── README.md
├── setup.sh                        # Run first — packs code, copies docs
├── prompt-1-audit.md               # Agent 1: Android audit (run second)
├── prompt-2-extract.md             # Agent 2: Platform-neutral extraction (run third)
├── prompt-3-design.md              # Agent 3: iOS design (run fourth)
├── prompt-4-review.md              # Agent 4: Review (run fifth)
├── packed/                         # Repomix-packed source (generated by setup.sh)
├── screenshots/                    # App UI screenshots (add manually)
├── reference/                      # Existing Android docs (copied by setup.sh)
├── audit/                          # Agent 1 output — Android-structured facts
├── domain/                         # Agent 2 output — platform-neutral requirements
├── design/                         # Agent 3 output — iOS architecture + phased plan
└── review/                         # Agent 4 output — correctness + adversarial findings

Archived (from previous two-prompt pipeline):
├── prompt-1-cartographer.md.archived
└── prompt-2-architect.md.archived
​```
```

- [ ] **Step 4: Rewrite the Key Architecture Decisions section**

Replace with:

```markdown
## Key Architecture Decisions

- **Clean room separation**: Agent 3 reads platform-neutral `domain/` as primary input; `audit/` is an escape hatch only
- **Language discipline**: `domain/` contains zero Android API names (enforced by self-audit grep)
- **Different organizational structures**: `audit/` by Android component, `domain/` by behavioral concern
- **iOS expertise injected**: Metal 4, Swift 6 actors, Sendable, VTFrameProcessor, OpenCV iOS — from Agent 3's prompt, not the audit
- **OpenCV edge detection**: NEW iOS requirement (not in Android) — proof-of-concept consumer that validates OpenCV iOS + consumer registration + zero-copy bridge + Sendable return path
- **Two-pass review**: Correctness (every requirement met?) + Adversarial (what fails in production?)
- **Escape hatch logged**: Every time Agent 3 consults `audit/`, it's logged in `design/08-audit-lookups.md`
```

- [ ] **Step 5: Rewrite the Development Phases section**

Replace with:

```markdown
## iOS Implementation Phases (produced by Agent 3)

1a. Camera capture + state machine + lifecycle + permissions
1b. Camera controls (focus, AWB, AE, ISO, exposure, zoom)
2. Metal processing pipeline (replace raw preview with MTKView)
3. C++ integration + OpenCV edge detection consumer + fan-out topology
4. Performance tuning + thermal/pressure resilience
5. Capture + recording (AVAssetWriter, EXIF)
6. Parity audit + polish
```

- [ ] **Step 6: Update the Target Stack section (if present)**

If the Target Stack section exists, verify it mentions:
- iOS 26+, Swift 6, Metal 4
- SwiftUI + UIKit (UIViewRepresentable for MTKView)
- Swift-C++ direct interop (ObjC++ only if needed)
- OpenCV NEW for iOS (Android doesn't use it — this is additive)
- Swift 6 actor isolation (compile-time data race prevention)

If absent, add it.

- [ ] **Step 7: Ask user to approve commit, then commit if approved**

```bash
git add ios-translation/README.md
git commit -m "docs(ios-translation): update README for 4-agent clean room pipeline"
```

**DO NOT commit without explicit user approval.**

---

### Task 8: Cross-prompt consistency check

**Files:** (no file changes unless issues found)

- [ ] **Step 1: Verify I/O consistency across prompts**

Check that the output directory of each agent exactly matches the input expectations of the next:

- Agent 1 writes `audit/` → Agent 2 reads `audit/` ✓
- Agent 2 writes `domain/` → Agent 3 reads `domain/` (primary) and `audit/` (escape hatch) ✓
- Agent 3 writes `design/` → Agent 4 reads `design/` and `domain/` ✓

Verify each prompt references the same file structure (e.g., Agent 2's `domain/01-system-purpose.md` is referenced consistently in Agents 3 and 4).

- [ ] **Step 2: Grep all four prompts for file path consistency**

Run:
```bash
grep -n "audit/0" /Users/shrek/work/cambrian/ios-translation/prompt-*.md
grep -n "domain/0" /Users/shrek/work/cambrian/ios-translation/prompt-*.md
grep -n "design/0" /Users/shrek/work/cambrian/ios-translation/prompt-*.md
grep -n "review/0" /Users/shrek/work/cambrian/ios-translation/prompt-*.md
```

Expected: File paths are consistent. If `audit/01-system-topology.md` appears in Agent 1 with one name and in Agent 2 with a different name, that's a bug.

- [ ] **Step 3: Verify the OpenCV edge detection requirement is consistent**

Agent 1 prompt: Must say Android does NOT use OpenCV, document generic consumer pattern.
Agent 2 prompt: Must not assume OpenCV exists when extracting domain requirements.
Agent 3 prompt: Must require OpenCV edge detection consumer as NEW iOS capability.
Agent 4 prompt: Must verify edge detection consumer is concretely designed.

Spot-check each prompt for this consistency.

- [ ] **Step 4: Verify escape hatch logging is consistent**

Agent 3 prompt: Requires logging in `design/08-audit-lookups.md`.
Agent 4 prompt: Checks `design/08-audit-lookups.md` for abuse patterns.

These must agree on the file name and purpose.

- [ ] **Step 5: Fix any inconsistencies inline**

If any inconsistencies found in steps 1-4, edit the relevant prompt files to fix them.

- [ ] **Step 6: Ask user to approve commit if any fixes were made**

```bash
git add ios-translation/prompt-*.md
git commit -m "fix(ios-translation): resolve cross-prompt consistency issues"
```

If no fixes needed, skip the commit step.

---

### Task 9: Dry-run validation of Agent 2 (most critical)

**Files:** (no file changes — verification only)

Agent 2 is the riskiest because it enforces the language rules that the clean room pipeline depends on. A quick dry-run validates that the prompt would produce clean output.

- [ ] **Step 1: Dispatch a subagent to review the Agent 2 prompt**

Use the Agent tool to dispatch a general-purpose subagent with this prompt:

```
Read the file at /Users/shrek/work/cambrian/ios-translation/prompt-2-extract.md

This is a prompt for an AI agent that will translate an Android codebase audit into platform-neutral domain requirements. The key discipline is: the output domain/ directory must contain ZERO Android API names (Camera2, Handler, SurfaceTexture, etc.).

Your job: given this prompt, would an AI agent following it produce output that actually meets this discipline? Specifically:

1. Are the language rules clear and actionable?
2. Is the self-audit (grep for forbidden names) mandatory and enforceable?
3. Are the example translations in the prompt sufficient to anchor the format?
4. Could an agent misinterpret "allowed" vs "forbidden" terminology?
5. Is the classification discipline (Domain / Android-specific / iOS-specific / Unclear) clear?
6. Would the output actually be usable as input for an iOS designer who never reads Android source?

Produce a short (under 300 words) critique. Flag any issues with severity (critical/high/medium/low). Do not write any code or modify files.
```

- [ ] **Step 2: Review the subagent's feedback**

Read the subagent's response. Identify any critical or high-severity issues.

- [ ] **Step 3: Apply fixes if needed**

If the subagent flagged critical or high issues, edit `prompt-2-extract.md` to address them. If only medium/low issues, note them but don't block.

- [ ] **Step 4: Ask user to approve commit if any fixes were made**

```bash
git add ios-translation/prompt-2-extract.md
git commit -m "fix(ios-translation): address Agent 2 prompt review feedback"
```

If no fixes needed, skip the commit step.

---

### Task 10: Final verification

**Files:** (no file changes)

- [ ] **Step 1: Verify all files exist**

Run:
```bash
ls /Users/shrek/work/cambrian/ios-translation/prompt-1-audit.md \
   /Users/shrek/work/cambrian/ios-translation/prompt-2-extract.md \
   /Users/shrek/work/cambrian/ios-translation/prompt-3-design.md \
   /Users/shrek/work/cambrian/ios-translation/prompt-4-review.md \
   /Users/shrek/work/cambrian/ios-translation/prompt-1-cartographer.md.archived \
   /Users/shrek/work/cambrian/ios-translation/prompt-2-architect.md.archived
```
Expected: All 6 files exist.

- [ ] **Step 2: Verify README is updated**

Run:
```bash
grep -c "Agent 1 (AUDIT)" /Users/shrek/work/cambrian/ios-translation/README.md
grep -c "Agent 2 (EXTRACT)" /Users/shrek/work/cambrian/ios-translation/README.md
grep -c "domain/" /Users/shrek/work/cambrian/ios-translation/README.md
grep -c "clean room" /Users/shrek/work/cambrian/ios-translation/README.md
```
Expected: Each grep returns at least 1.

- [ ] **Step 3: Final spec coverage check**

Re-read `/Users/shrek/work/cambrian/ios-translation/docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md` and verify:
- Every section of the spec is addressed by at least one prompt file or the README update
- The 4-agent pipeline is correctly implemented
- The language rules in Agent 2 match the spec's rules exactly
- The escape hatch rules in Agent 3 match the spec
- The two-pass review in Agent 4 matches the spec

- [ ] **Step 4: Report completion to user**

Write a brief summary:
- "Implementation complete. 4 new prompts created, 2 old prompts archived, README updated."
- List the files
- Note any remaining uncommitted changes
- Suggest next step: "Ready to run. Start with setup.sh, then Agent 1."

---

## Summary

| # | Task | Files Touched | Commits |
|---|------|---------------|---------|
| 1 | Create output directories | `audit/`, `domain/`, `review/` | 0 |
| 2 | Write Agent 2 (EXTRACT) prompt | `prompt-2-extract.md` | 1 |
| 3 | Write Agent 1 (AUDIT) prompt | `prompt-1-audit.md` | 1 |
| 4 | Write Agent 3 (DESIGN) prompt | `prompt-3-design.md` | 1 |
| 5 | Write Agent 4 (REVIEW) prompt | `prompt-4-review.md` | 1 |
| 6 | Archive old prompts | Rename 2 files | 1 |
| 7 | Update README | `README.md` | 1 |
| 8 | Cross-prompt consistency check | (verification) | 0-1 |
| 9 | Dry-run validation of Agent 2 | (verification) | 0-1 |
| 10 | Final verification | (none) | 0 |

**Total new files:** 4 prompt files (+ this plan)
**Total modified files:** 1 README
**Total renamed files:** 2 old prompts archived
**Total commits:** 6-8 (each requires user approval per project rule)
