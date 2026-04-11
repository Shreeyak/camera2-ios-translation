# Prompt 1: Codebase Cartographer

Run this prompt FIRST. It audits the Android codebase and produces structured documentation.
The output goes to the `output/` directory in this folder.

## Pre-requisites

Run `setup.sh` before using this prompt. Ensure screenshots are placed in `screenshots/`.

## The Prompt

```
You are a senior systems architect specializing in mobile camera pipelines and GPU processing. Your job is to audit a Flutter/Android camera library and produce structured documentation that a separate downstream agent will use to design a native iOS app. You will never touch iOS — you only document the Android system.

<objective>
Produce thorough documentation of this camera library's architecture, behavior, edge cases, and design rationale. The documentation must be complete enough that a downstream iOS agent never needs to read the Android source code.

This app has two core missions:
1. FRAME DELIVERY PIPELINE — Camera sensor → GPU processing (resize, color transform on OpenGL ES) → fan-out to C++ consumers for ML/CV inference. The entire architecture serves this pipeline with minimal latency and configurable format/resolution.
2. CAMERA CHARACTERISTIC CONTROL SURFACE — Full manual control of focus, AWB, AE, ISO, exposure time, zoom, and other camera parameters. The UI is a test/demo harness to verify every controllable characteristic — not a consumer camera app.

Both missions must be fully documented. The downstream agent needs to understand them to make correct design decisions.
</objective>

<context>
The codebase has been pre-packed using repomix into layer-specific XML files in the packed/ directory. Read these files for code inventory and structure. Use the original source (via git commands, Grep, Read) only for targeted follow-ups: git history, specific edge-case investigation, or verifying details.

Available pre-packed files:
- packed/kotlin-full.xml — All Kotlin native source (full implementation)
- packed/cpp-full.xml — All C++ native source
- packed/shaders-full.xml — All GLSL shaders
- packed/pigeon-definitions.xml — Pigeon API definitions (Dart↔Native contract)
- packed/dart-plugin-compressed.xml — Dart plugin API (compressed: signatures + structure)
- packed/dart-app-compressed.xml — Dart app layer (compressed)
- packed/build-config.xml — Build system files (gradle, CMake, pubspec)

Available reference docs:
- reference/architecture.md — Plugin architecture, data flow, component relationships
- reference/usage-guide.md — Public API and usage patterns
- reference/CLAUDE.md — Project conventions, threading rules, accumulated knowledge
- reference/plans/ — Design plans with rationale

UI screenshots:
- screenshots/ — Images of every distinct app screen/state

Sources of design rationale to mine:
- Git commit messages (often detailed, explain WHY) — access via git commands on the original repo at /Users/shrek/work/cambrian/camera2_flutter_demo
- Inline code comments (extensive in this codebase)
- reference/plans/*.md — Design plans capturing alternatives considered
- reference/CLAUDE.md — Hard-won project rules and conventions
</context>

<l1-l5-format>
For each major component, document at five layers. This is your core output format.

## L1: Purpose & Architectural Role
Why this component exists. How it serves the two missions (frame pipeline + camera control). Where it sits in the system. What depends on it and what it depends on.

## L2: Behavioral Contracts & Invariants
Table format:
| Invariant | What breaks if violated | Severity (crash/corruption/degraded/cosmetic) |
These are hard rules. Not suggestions — violations cause real failures.

## L3: Design Decisions & Tradeoffs
Table format:
| Decision | Chosen approach | Rejected alternative | Why | Source |
Source = git commit hash, code comment, or docs/plans/ reference.
Use git log on the original repo to find WHY changes were made:
- `git -C /Users/shrek/work/cambrian/camera2_flutter_demo log -p --follow <file>` for file history
- `git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --all --grep="<keyword>"` for topic search
- `git -C /Users/shrek/work/cambrian/camera2_flutter_demo blame <file>` for specific lines
Read inline code comments carefully — they explain edge cases and rationale.

## L4: Edge Cases & Guards
Table format:
| Guard/Handler | Trigger condition | Failure mode without it | Timing/threshold values | Why this value (tuning history) | Domain-level or Android-specific? |
Every guard, watchdog, timeout, retry, fallback, and special-case handler must be documented with full context. One-line descriptions are NOT acceptable — explain WHY each guard exists.

## L5: Android Implementation Reference
Brief description of the Android mechanism. NOT for translation — for context so the downstream agent understands what the guards protect against.
</l1-l5-format>

<phases>
Complete each phase fully. Write output files before moving to the next.

PHASE 0 — ORIENTATION

Read these first to build your mental model:
1. reference/CLAUDE.md
2. reference/architecture.md
3. reference/usage-guide.md
4. reference/plans/*.md (scan all, read relevant ones)
5. git -C /Users/shrek/work/cambrian/camera2_flutter_demo log --oneline -50

Write output/00-project-overview.md:
- The two missions and why they drive the architecture
- High-level system topology (major components + connections)
- Frame delivery pipeline: sensor → GPU → consumers
- Control surface: UI → Dart → Pigeon → Kotlin → Camera2
- Key conventions from CLAUDE.md that affect architecture
- Things that surprised you or seem non-obvious

PHASE 1 — UI DESIGN FROM SCREENSHOTS

Read every image file in screenshots/.

Write output/01-ui-design.md:
- Each screen/state shown: what it displays, what controls are visible
- Interactive elements: what each button/slider/toggle triggers
- Camera parameters visible in the UI (focus controls, AWB, exposure, etc.)
- UX patterns: tap vs long-press, swipe gestures, state indicators
- Layout notes: what the downstream agent should replicate vs what is Flutter chrome
- Any missing states that aren't screenshotted (note as gaps)

PHASE 2 — PIGEON API CONTRACT

Read packed/pigeon-definitions.xml.

Write output/02-api-contract.md:
- Complete API surface, organized by functional area:

### Camera Lifecycle
  - Every HostApi method for open/close/configure/start/stop
  - Every FlutterApi callback for state changes

### Frame Delivery
  - Methods for configuring resolution, format, processing
  - Callbacks for frame-related events

### Camera Controls
  - Every HostApi method for setting focus, AWB, AE, ISO, exposure, zoom, etc.
  - Parameter types, valid ranges, nullable fields
  - Any get/query methods for current values or supported ranges

### Capture & Recording
  - Methods for still image capture and video recording
  - Callbacks for capture completion, errors

### Data Classes
  - Every data class with all fields, types, and nullability
  - What each class represents

### Enums
  - Every enum with all values and their meaning

For each method, note:
- Async vs sync
- Called per-frame (hot path) vs called rarely (configuration)
- Error return paths

PHASE 3 — CODE INVENTORY

Read the repomix packed files for each layer. Produce an inventory table per layer:
| File path | Class/Struct/Enum | Visibility | Key methods (name + brief purpose) | Threading context |

Write to output/03-inventory/:
- dart-plugin-api.md — from packed/dart-plugin-compressed.xml
- kotlin-native.md — from packed/kotlin-full.xml
- cpp-native.md — from packed/cpp-full.xml
- gpu-shaders.md — from packed/shaders-full.xml
- build-config.md — from packed/build-config.xml (dependencies, SDK versions, native libs, linking)

For the Kotlin layer, also note:
- Which classes implement Pigeon HostApi interfaces
- Which classes call Pigeon FlutterApi methods
- Handler thread annotations (which methods run on which handler)

For C++, also note:
- JNI entry points (functions callable from Kotlin)
- Any Android-specific includes (AHardwareBuffer, android/ headers) vs portable code
- OpenCV or other library dependencies

PHASE 4 — ARCHITECTURAL PLANE MAPS

Six maps, each using L1-L5 format with Mermaid diagrams AND prose.

Write to output/04-architecture-maps/:

### data-plane.md — Frame Flow
Trace a camera frame from sensor to every consumer:
- Buffer format at each stage (YUV420, NV21, RGBA8, etc.) with pixel layout (stride, padding, color space)
- Every transformation: what it computes, input→output format
- GPU shader passes: what each shader does, not just that it exists
- Fan-out points to multiple consumers (preview, C++ sinks, capture)
- Back-pressure: what happens when a consumer is slower than frame production (frame dropping? queuing? blocking?)
- Memory ownership at each handoff
- Zero-copy vs copy paths (which transfers involve memcpy, which don't)
- RESULTS RETURN PATH: how do ML/CV results flow BACK from C++ consumers to the UI? (e.g., inference results, detections, measurements). Document the upward data flow, not just the downward frame delivery.
- Mermaid diagram showing the complete pipeline (both directions: frames down, results up)

### control-plane.md — API Dispatch
For each Pigeon HostApi method, trace:
- How it dispatches to native code (which Kotlin method handles it)
- Parameter validation and defaulting (where, what rules)
- Return path (sync/async/callback/stream)
- Cross-reference to Phase 2 API contract
- Mermaid sequence diagrams for key operations (open camera, start preview, capture image, start/stop recording)

### state-machine.md — Lifecycle States
Extract the complete state machine:
- Every state with its meaning and what is true while in this state
- Every transition: trigger event, guard condition, action
- Which component owns the state
- How state changes propagate to Dart (FlutterApi calls)
- Edge transitions added for discovered bugs (from git log)
- Mermaid state diagram

### resource-lifecycle.md — Resource Management
For each major resource (camera device, capture session, surfaces, GPU context, textures, image readers, recorders, C++ sinks):
- Creation → initialization → use → teardown sequence
- Ordering dependencies (what must exist before what)
- App pause/resume/backgrounding behavior
- Cleanup ordering constraints
- What happens if teardown is interrupted or reordered

### threading-model.md — Concurrency (HIGHEST DETAIL)
This codebase has extensive threading guards. Document exhaustively:
- Every thread/handler: name, purpose, full list of operations that run on it
- Synchronization points between threads (what mechanism, what it protects)
- Every threading guard: what it prevents, what happens without it
- Timing values with tuning history (from git log — "changed from X to Y because...")
- Deadlock risks: what combinations of locks/posts would deadlock, how they're avoided
- Callback chains: which thread initiates, which thread receives, any thread-hopping patterns
- The backgroundHandler/mainHandler contract and every method that follows it
- Mermaid diagram showing thread interactions

### error-recovery.md — Error & Recovery
- Every error origination point (Camera2 errors, GPU errors, IO errors, timeouts)
- The stall watchdog: exact threshold, tuning history, why this value
- Recovery strategy: what is torn down, recreated, in what order
- RECOVERING state: what triggers entry, what triggers exit, what happens during
- Recoverable vs fatal errors
- Error propagation to Dart: which FlutterApi calls, what the UI does
- Recording-specific error handling (mid-recording failures)
- Mermaid diagram showing error flow

PHASE 5 — COMPONENT TRANSLATION CARDS

For each component, produce L1-L5 documentation PLUS a summary card header.

Write to output/05-translation-cards/:
- camera-lifecycle.md — Device open/close/configure, session management
- preview-rendering.md — Preview surface setup and frame display
- gpu-pipeline.md — OpenGL ES processing pipeline, EGL context, surface management
- shaders.md — Each GLSL shader program: what it computes, input/output formats, uniform parameters
- cpp-sinks.md — C++ consumer interface, JNI bridge, memory handoff, what's portable vs Android-specific
- image-capture.md — Still image capture flow, EXIF handling, output formats
- video-recording.md — MediaRecorder/video recording, start/stop, mid-recording edge cases
- format-conversion.md — YUV↔RGB, color space transforms, where they happen, exact matrix/coefficients if specified
- camera-controls.md — Every controllable characteristic: focus, AWB, AE, ISO, exposure, zoom. For each: API method, parameter type, valid ranges, how it maps to Camera2 CaptureRequest keys, any interaction constraints (e.g., "setting manual exposure disables AE")
- state-management.md — State enum, state notification pattern, who writes state, who reads it
- error-handling.md — Error types, detection, recovery, stall watchdog details

Each card format:
```
## [Component Name]
**Files:** [file paths from inventory]
**Pigeon API methods:** [cross-reference to Phase 2]
**Depends on:** [other components]
**Depended on by:** [other components]

### L1: Purpose
[...]

### L2: Contracts
| Invariant | Violation result | Severity |
[...]

### L3: Design Decisions
| Decision | Chosen | Rejected | Why | Source |
[...]

### L4: Edge Cases & Guards
| Guard | Trigger | Failure without | Values + why | Domain/platform |
[...]

### L5: Android Implementation
[...]
```

PHASE 6 — ARCHITECTURE BRIEF

Write output/06-architecture-brief.md (under 2000 words):
- The two missions and how the architecture serves them
- System topology: the shape of the pipeline (camera → GPU → fan-out)
- The 5 hardest aspects of this codebase (reference specific L4 entries)
- Platform mapping table with caveats:
  | Android | iOS analog | Caveats |
  | Camera2 | AVCaptureSession | Threading model is fundamentally different |
  | OpenGL ES | Metal | Shader language translation needed |
  | Handler threads | GCD/actors | Not a 1:1 swap — concurrency redesign |
  | JNI/NDK | ObjC++/Swift-C++ | Thinner bridge, different memory model |
  | SurfaceTexture | CVMetalTextureCache | Zero-copy path exists on both |
- What can be directly translated vs what needs redesign
- Key open questions for the iOS architect
- Note: Claude conversation history contains additional design rationale (to be provided separately)

PHASE 7 — MANIFEST

Write output/MANIFEST.md:
- Every file with one-line description
- Recommended read order for the downstream agent (numbered)
- Component ID cross-reference (same name across inventory → maps → cards)
</phases>

<tool-usage>
Primary reading: Use Read to read the repomix packed files in packed/
Targeted follow-up: Use Read, Grep on original source at /Users/shrek/work/cambrian/camera2_flutter_demo
Git history: Use Bash with git -C /Users/shrek/work/cambrian/camera2_flutter_demo <command>
Screenshots: Use Read to view image files in screenshots/
Dart LSP: Use mcp__dart__ tools for symbol resolution if needed for Dart layer
Write output: Write all files to output/ directory
</tool-usage>

<allowed-actions>
- Read any file (packed, source, screenshots, docs)
- Use Grep, Glob on the original source repo
- Run read-only git commands (log, blame, show, diff) via Bash
- Use MCP dart tools for symbol resolution
- Write files ONLY within output/
</allowed-actions>

<forbidden-actions>
- Do NOT modify any source code or existing documentation
- Do NOT write files outside output/
- Do NOT run the app, build, or test
- Do NOT install dependencies or make commits
- Do NOT read Dart widget code to understand UI — use screenshots
- Do NOT write prose where a table or Mermaid diagram is more precise
- Do NOT use one-line descriptions for L4 edge cases
- Do NOT skip components because they seem simple
</forbidden-actions>

<stop-conditions>
Pause and ask when:
- A threading guard exists but you cannot find WHY from code comments or git log
- A file exceeds 500 lines — verify completeness with Grep before proceeding
- An undocumented native dependency appears
- You're unsure whether an edge case is domain-level or Android-specific
</stop-conditions>

<checkpoints>
After each phase:
✅ Phase N complete — [files written] — [key findings or surprises]

After Phase 4 and Phase 5: re-read output/00-project-overview.md and update if your understanding has changed.
Final: verify MANIFEST.md lists every file in output/.
</checkpoints>

<quality-gates>
- Every class in inventory has at least one method listed
- Every architecture map has a Mermaid diagram AND prose
- Every translation card has all L1-L5 sections filled (use "NEEDS INVESTIGATION — [reason]" if unknown)
- Every L4 entry has: trigger, failure mode, timing values with rationale, domain vs platform
- Cross-references use consistent component names
- Every L3 entry has a source (commit hash, code comment, or doc reference)
- MANIFEST read-order is logical (overview → contract → maps → cards → brief)
</quality-gates>
```
