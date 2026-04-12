# Prompt 1: Android Codebase Audit

Run this prompt FIRST. It produces a factual audit of the Android codebase that downstream agents will use.
The output goes to the `audit/` directory.

## Pre-requisites

Run `setup.sh` before using this prompt. Ensure screenshots are placed in `screenshots/`.

## The Prompt

````
You are a technical writer. Your job is to document an Android camera library factually and comprehensively. A separate agent will read your documentation later to extract platform-neutral requirements — but that is not your concern. Your only job is to describe what exists, how it behaves, and why (from git history and code comments).

<objective>
Produce a complete factual audit of the Android codebase: what components exist, how they are structured, how they behave, and the design rationale behind them. Write for a reader who has no access to the source code.

This app has two core missions:
1. FRAME DELIVERY PIPELINE — Camera sensor → GPU processing (resize, color transform on OpenGL ES) → fan-out to registered C++ consumers for ML/CV inference. Minimal latency, configurable format and resolution.
2. CAMERA CHARACTERISTIC CONTROL SURFACE — Full manual control of focus, AWB, AE, ISO, exposure time, zoom. The UI is a test/demo harness, not a consumer camera app.
</objective>

<mental-model>
"I'm writing documentation for someone who will read it later. I describe what exists, how it behaves, and why (from git history and inline comments). I do not predict what will change, translate to other platforms, or suggest redesigns. I only document."
</mental-model>

<scope>
Document only the Android system as it currently exists. Do NOT:
- Use iOS terminology
- Suggest translations or ports
- Compare to other platforms
- Write "translation cards" or "what needs to change" sections
- Speculate about future redesigns
- Use L1-L5 layering format

Your output is a factual snapshot of the Android system.
</scope>

<context>
The codebase is pre-packed using repomix into layer-specific XML files in `packed/`. Read these for inventory and structure. Use the original source at `/Users/shrek/work/cambrian/camera2_flutter_demo` only for targeted follow-ups: git history, edge-case investigation, or verifying details.

Packed files:
- `packed/kotlin-full.xml` — All Kotlin native source
- `packed/cpp-full.xml` — All C++ native source
- `packed/shaders-full.xml` — All GLSL shaders
- `packed/pigeon-definitions.xml` — Pigeon API definitions (Dart ↔ Native contract)
- `packed/dart-plugin-compressed.xml` — Dart plugin API (compressed)
- `packed/dart-app-compressed.xml` — Dart app layer (compressed)
- `packed/build-config.xml` — Build system files

Reference docs (for context and design rationale):
- `reference/architecture.md` — Architecture description from the project
- `reference/usage-guide.md` — Public API usage patterns
- `reference/CLAUDE.md` — Project conventions and threading rules
- `reference/plans/` — Design plans with rationale

UI screenshots: `screenshots/`

Design rationale sources (read in this order of reliability):
- Inline code comments (extensive in this codebase)
- Git commit messages (often detailed) — use `git log --oneline`, then `git show <hash>` selectively
- `reference/plans/*.md`
- `reference/CLAUDE.md`
</context>

<tool-usage>
Primary: Read packed files in `packed/`
Follow-up: Read/Grep on original source at `/Users/shrek/work/cambrian/camera2_flutter_demo`
Git: use `git log`/`git blame`/`git show` on the original repo — start with `--oneline`, then `git show <hash>` selectively
Screenshots: Read image files in `screenshots/`
Write: `audit/` directory only

Use git lookups throughout all phases where rationale matters (threading, state machine, error recovery, GPU pipeline, C++ sinks). The dedicated git archaeology phase is a broad sweep for design decisions not captured in earlier phases — not a replacement for targeted lookups during earlier phases.
</tool-usage>

<output>
Write to `audit/`:

```
audit/
├── README.md                   # File index and suggested read order
├── 01-system-topology.md       # What components exist, how they connect
├── 02-threading-model.md       # Threads, queues, synchronization points, handoff patterns
├── 03-capture-pipeline.md      # Camera session lifecycle, capture request flow
├── 04-pigeon-api.md            # Pigeon API contract: methods, data classes, enums, direction, threading
├── 05-gpu-opengl.md            # GPU pipeline, EGL context, shader programs, surface texture flow
├── 06-cpp-sinks.md             # Generic C++ consumer registration pattern, JNI bridge, buffer handoff
├── 07-state-machine.md         # State enum, transitions, guards, who writes state, who reads it
├── 08-error-recovery.md        # Error origination, stall detection, recovery strategy, state transitions
├── 09-camera-controls.md       # Camera parameters: focus, AWB, AE, ISO, exposure, zoom
├── 10-capture-recording.md     # Still image capture, video recording patterns
├── 11-build-config.md          # Gradle, CMake, native dependencies, SDK versions
└── 12-git-archaeology.md       # Design decisions and rationale from commit history
```

**Deviation from original spec:** This adds a 12th numbered file (`04-pigeon-api.md`) beyond the original 11-file spec, to ensure the Pigeon API contract is fully documented for downstream agents.
</output>

<phases>
Complete each phase fully before moving to the next.

PHASE 0 — ORIENTATION

Read these to build a mental model before writing anything:
1. `reference/CLAUDE.md`
2. `reference/architecture.md`
3. `reference/usage-guide.md`
4. `reference/plans/*.md` (scan all, read relevant ones)
5. `git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --oneline -50`

No output file for this phase — just build understanding.

PHASE 1 — SYSTEM TOPOLOGY

Write `audit/01-system-topology.md`:
- Major components and their responsibilities
- How components connect and depend on each other
- High-level data flow (frame path: sensor → GPU → consumers)
- High-level control flow (API → Dart → Pigeon → Kotlin → Camera2)
- File-path-to-class inventory table: `| File path | Class/Struct/Enum | Responsibility | Threading context |`
  (Do not enumerate every method — just the main classes and what they do)
- Mermaid diagram of component relationships (max ~12 nodes; split into sub-diagrams if larger)

PHASE 2 — THREADING MODEL

Write `audit/02-threading-model.md`. This is a HIGH-DETAIL file. The project has extensive threading logic.
- Every thread/handler and its purpose
- What operations run on each thread
- Synchronization points (what protects what, and how)
- Callback chains and thread handoffs
- Every threading guard: what it prevents, with context from git history or inline comments
- Timing values (e.g., watchdog thresholds) with tuning history where available
- Mermaid diagram of thread interactions

PHASE 3 — CAPTURE PIPELINE

Write `audit/03-capture-pipeline.md`:
- Camera session lifecycle: open → configure → start → stop → close
- CaptureRequest construction and repeating request pattern
- How camera frames are delivered from sensor to the GPU pipeline
- Surface/output target connections and their roles
- Any back-pressure or drop behavior
- Record all quantitative performance targets mentioned anywhere in the code or docs: target frame rate, per-frame latency budget, buffer pool sizes, stall detection threshold, memory ceilings, timeout values with rationale where available.

PHASE 4 — PIGEON API

Write `audit/04-pigeon-api.md`. Read `packed/pigeon-definitions.xml` as the primary source:
- Every method in the Pigeon definition:
  - Full method signature (name, parameters with types, return type)
  - Direction: Dart→native (HostApi) or native→Dart (FlutterApi / callbacks)
  - Error reporting convention for the method
  - Threading context if known from the Kotlin implementation
- Every data class with all fields, types, and nullability
- Every enum with all values and their meanings

PHASE 5 — GPU PIPELINE

Write `audit/05-gpu-opengl.md`:
- EGL context setup and lifecycle
- SurfaceTexture / texture target flow from camera to GL
- Shader programs: what each computes, input formats, output formats
- Pipeline topology: from camera output surface through GPU transforms to display and downstream sinks
- Buffer format conversions at each stage (YUV, NV21, RGBA8, etc.)

PHASE 6 — C++ SINKS

Write `audit/06-cpp-sinks.md`:
- How C++ consumers register with the sink layer (registration API)
- The buffer handoff mechanism: JNI entry points, buffer pointer passing, memory ownership
- Who allocates buffers, who holds them, who releases them
- Buffer pool strategy, if any
- "Done" signaling: how the consumer signals it is finished with a buffer
- Any back-pressure or queuing at the sink boundary

CRITICAL: The C++ sink layer is a GENERIC PLUGGABLE CONSUMER REGISTRATION PATTERN. Your job is to document how C++ consumers register, how they receive buffer handoffs, and how they signal completion. Do NOT describe any specific consumer implementation as "the" pattern.

OpenCV may appear in the build config or native dependencies (see reference/CLAUDE.md). If it does, document it accurately as one possible consumer linked via the sink layer — but the audit's job is to describe the generic registration interface, not OpenCV's API.

If you find no concrete consumer wired through the sink layer in the source, document the empty/abstract state honestly. If you find a concrete consumer (OpenCV or other), document what it does without making it the template.

PHASE 7 — STATE MACHINE

Write `audit/07-state-machine.md`:
- State enum: every value with its meaning
- Transitions: trigger, guard condition, and action for each
- Who owns the state variable, who reads it
- How state changes are notified to the Dart layer
- Edge cases and guards from git history (bug fixes that added new transitions)
- Mermaid state diagram

PHASE 8 — ERROR RECOVERY

Write `audit/08-error-recovery.md`:
- Error origination points (Camera2 errors, GPU errors, IO errors)
- Stall watchdog: the exact threshold value, what it monitors, what action it takes on trigger
- RECOVERING state: how the system enters it, what happens during recovery, how it exits
- Recoverable vs fatal error classification
- How errors propagate to the Dart layer
- Recording-specific error handling
- Mermaid error flow diagram

PHASE 9 — CAMERA CONTROLS

Write `audit/09-camera-controls.md`:
- Each camera parameter: name, valid ranges, how it is set via the API, any interaction constraints
- How camera capabilities are queried at open time
- How manual vs auto modes interact (e.g., manual focus vs AF, manual exposure vs AE)
- The Camera2 CaptureRequest keys used for each parameter

PHASE 10 — CAPTURE AND RECORDING

Write `audit/10-capture-recording.md`:
- Still image capture flow: trigger → callback → file or buffer delivery
- Video recording flow: start, stop, mid-recording error handling
- EXIF or metadata handling
- File output patterns (paths, naming, format)
- Any differences in capture request configuration for still vs video

PHASE 11 — BUILD CONFIG

Write `audit/11-build-config.md`:
- Gradle modules and inter-module dependencies
- CMake configuration and native library linking strategy
- SDK versions: minSdk, targetSdk, compileSdk
- NDK version and ABI filters
- Kotlin, Dart, and Flutter SDK versions
- Key third-party dependencies and their versions

PHASE 12 — GIT ARCHAEOLOGY

Write `audit/12-git-archaeology.md`:
- Run `git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --oneline --all` to get the full history
- Search for topic-relevant commits:
  ```bash
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="stall" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="recover" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="thread" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="state" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="fix" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="GPU" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="EGL" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="pipeline" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="capture" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="record" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="JNI" --oneline
  git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="sink" --oneline
  ```
- For each significant commit: hash, one-line description, what changed, why (from the commit message)
- Focus areas: threading guards, stall detection tuning, recovery logic, state machine edge transitions, API contract evolution
- Entry format:
  ```
  ### <hash> — <one-line subject>
  **What changed:** ...
  **Why (from commit message):** ...
  **Affected components:** ...
  ```

PHASE 13 — SCREENSHOTS

Read every image in `screenshots/`. Document in `audit/01-system-topology.md` (append a section "UI Overview"):
- Each visible screen or state: what it shows, which camera parameters are exposed
- Interactive elements and their apparent function
- Any state indicators visible in the UI
- Flag states not covered by screenshots as "NOT SCREENSHOTTED — infer from Pigeon API or state machine"

(If this section grows large, it may be moved to a separate `audit/00-ui-overview.md`, but only if needed.)

PHASE 14 — README

Write `audit/README.md`:
- File index with one-line description of each file
- Suggested read order for downstream agents
- Summary of any gaps, uncertainties, or items marked "NEEDS INVESTIGATION"
- Brief note on which reference docs were checked and whether they matched the code
</phases>

<quality-gates>
Before reporting done, verify:
- No iOS terminology anywhere in `audit/`
- No "translation," "port," "equivalent," or "when we port" language
- No comparison to other platforms
- Every major class in the codebase is mentioned in `01-system-topology.md`
- Threading model documents every handler and queue with a list of operations that run on each
- Every threading guard is documented with its rationale (from git history or inline comments)
- State machine covers every state value and every transition
- Error recovery covers the stall watchdog with exact threshold values
- C++ sinks file documents the GENERIC pluggable consumer registration pattern — accurately reflects any concrete consumers found in the source (including OpenCV if present); does not treat any single consumer as "the" pattern
- All 12 numbered files plus `README.md` are present in `audit/`
- Git archaeology phase ran actual git commands (not guessed from reading code)
- Performance targets (frame rate, latency budget, stall threshold, buffer pool sizes, timeout values) are captured in the capture pipeline phase and referenced consistently across phases
</quality-gates>

<stop-conditions>
Mark unknowns as "NEEDS INVESTIGATION — [reason]" in the relevant file and continue. Only pause for:
- Blocking ambiguities that affect multiple sections
- Contradictions between code and reference docs that cannot be resolved by reading both carefully
</stop-conditions>
````
