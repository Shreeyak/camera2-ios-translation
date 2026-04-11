# iOS Translation Audit — Agent Prompt

## Context

This prompt is for a Claude Code agent that will audit the Flutter/Android camera library codebase and produce structured documentation files. A **separate downstream agent** will read these files to design and build a pure native iOS/Swift app (iOS 26+, Metal, no Flutter).

The prompt uses three sources: UI screenshots, Pigeon API definitions, and native code behavioral extraction with L1-L5 layered detail.

Note: Mining Claude Code conversation history for design decisions is handled by a separate script/prompt — not in scope here.

---

## The Prompt

```
You are a senior systems architect specializing in mobile camera pipelines, Metal GPU programming, and cross-platform migration. You have deep expertise in Camera2, AVFoundation, OpenGL ES, Metal, and C++/Swift interop.

<objective>
Audit this Flutter/Android camera library and produce structured documentation files. A separate downstream agent will read these files to design and build a native iOS/Swift app (iOS 26+, Metal, no Flutter).

Your documentation must be thorough enough that the downstream agent never needs to re-read this source code. Capture behavioral knowledge, design rationale, and edge-case handling — not just API surface.

This app has two core missions:
1. FRAME DELIVERY PIPELINE — Camera sensor → GPU processing (resize, color transform) → fan-out to C++ consumers for ML/CV inference. The entire architecture exists to serve this pipeline with minimal latency and configurable format/resolution.
2. CAMERA CHARACTERISTIC CONTROL SURFACE — Full manual control of focus, AWB, AE, ISO, exposure time, zoom, and other camera parameters. The UI is a test/demo harness to verify that every controllable characteristic works — not a consumer camera app.

The downstream agent must understand both missions to make correct design decisions.
</objective>

<starting-state>
Project structure:
- lib/ — Dart application code (Flutter UI, state management)
- packages/ — The camera library plugin (Dart API + Kotlin native)
- android/ — Android-specific app configuration
- docs/architecture.md — Plugin architecture, data flow, component relationships
- docs/usage-guide.md — Public API and usage patterns
- CLAUDE.md — Accumulated project knowledge and conventions
- docs/plans/ — Design plans with rationale
- screenshots/ — UI screenshots (placed here by user before running this prompt)

Sources of design rationale (mine these):
- Git commit messages — often detailed, explain WHY changes were made
- Inline code comments — extensive, explain edge cases and design choices
- docs/plans/*.md — Design plans capturing alternatives considered
- CLAUDE.md — Project conventions and hard-won rules
</starting-state>

<target-state>
A directory docs/ios-translation/ containing structured analysis files organized by the file tree specified in the Output Structure section. Every file follows the L1-L5 documentation format. A MANIFEST.md index tells the downstream agent what exists and in what order to read it.
</target-state>

<three-source-strategy>
This audit uses three complementary sources. Do NOT read Flutter widget code to understand the UI — use screenshots. Do NOT trace method calls through Dart→Pigeon→Kotlin to understand the API contract — read the Pigeon definitions directly.

Source 1: UI SCREENSHOTS (in screenshots/ directory)
- Read each screenshot image file
- Document: what screen/state it shows, interactive elements, what each element triggers
- Annotate non-obvious UX behavior (e.g., long press vs tap distinctions)
- This replaces reading Dart widget code for UI understanding

Source 2: PIGEON API DEFINITIONS (the formal Dart↔Native contract)
- Find and read the Pigeon source .dart files (the input to code generation)
- These define: every data class, every HostApi method (Dart→Native), every FlutterApi method (Native→Dart), every enum
- Extract and document the complete API surface verbatim — this IS the contract the iOS app must implement
- Note which methods are async, which have callbacks, which stream data

Source 3: NATIVE LAYER BEHAVIORAL EXTRACTION (Kotlin + C++ + shaders)
- Read the native code to extract behavior, contracts, edge cases, and design rationale
- Use the L1-L5 documentation format (defined below) for each component
- Mine git log and inline code comments for WHYs
- Focus on WHAT the code does and WHY, not HOW Android implements it (though Android mechanism goes in L5 for reference)
</three-source-strategy>

<l1-l5-documentation-format>
For each major component, document at five layers of detail:

## L1: Purpose & Architectural Role
Why this component exists. How it serves the two missions (frame delivery pipeline + camera control surface). Where it sits in the system. What depends on it.

## L2: Behavioral Contracts & Invariants
Table format:
| Invariant | What breaks if violated | Severity |
These are hard rules the iOS implementation MUST replicate. Not suggestions — violations cause crashes, corruption, or incorrect behavior.

## L3: Design Decisions & Tradeoffs
Table format:
| Decision | Chosen approach | Rejected alternative | Why | Source |
Source = git commit hash, code comment reference, or docs/plans/ file.
Use `git log -p --follow <file>` and `git log --all --grep="<keyword>"` to find commit messages explaining WHY changes were made. Read inline code comments carefully — they often explain edge cases and rationale.

## L4: Edge Cases & Guards
Table format:
| Guard/Handler | Trigger condition | Failure mode without it | Timing/threshold values (with why) | Domain-level or platform-specific? | Will this same problem exist on iOS? |
This is where hard-won iteration knowledge lives. Every guard, watchdog, timeout, retry, fallback, and special-case handler must be documented here with its rationale.

## L5: Android Implementation Reference
Brief description of how Android implements this component. NOT for direct translation — the iOS agent designs its own implementation from L1-L4. This section provides context so the iOS agent can understand WHY certain guards or patterns exist by seeing the Android mechanism they protect against.

## L6: iOS Translation Constraints (derived from L1-L4)
What the L2 contracts + L3 decisions + L4 edge cases mean for the iOS implementation:
- Which problems are domain-level (cameras do this on all platforms) and MUST be handled on iOS
- Which are Android-specific and can be dropped
- Which iOS APIs are the natural equivalents
- Any iOS-specific problems that don't exist on Android but should be anticipated
</l1-l5-documentation-format>

<phases>
Complete each phase fully and write output files before moving to the next.

PHASE 0 — ORIENTATION

Read these documents first to build your mental model before touching any code:
1. CLAUDE.md (project conventions, accumulated knowledge)
2. docs/architecture.md (system architecture, data flow, component relationships)
3. docs/usage-guide.md (public API, usage patterns)
4. docs/plans/*.md (design plans with rationale)
5. git log --oneline -50 (recent project history)

Write docs/ios-translation/00-project-overview.md capturing:
- The two missions of the app (frame delivery + camera control)
- High-level system topology (what are the major components, how do they connect)
- The frame delivery pipeline at the highest level (sensor → GPU → consumers)
- The control surface at the highest level (UI → Dart → Pigeon → Kotlin → Camera2)
- Key project conventions from CLAUDE.md that affect architecture

PHASE 1 — UI CAPTURE FROM SCREENSHOTS

Read every image file in screenshots/.
Write docs/ios-translation/01-ui-design.md containing:
- For each screenshot: what screen/state it shows
- Interactive elements and what they trigger
- Camera control parameters visible in the UI
- UX behaviors and interaction patterns
- Notes on what the downstream agent needs to replicate vs what is Flutter-specific chrome

PHASE 2 — PIGEON API CONTRACT

Find the Pigeon source definition files (the .dart inputs to pigeon code generation, NOT the generated output).
Write docs/ios-translation/02-api-contract.md containing:
- Every data class with all fields, types, and nullability
- Every HostApi method (Dart→Native): name, parameters, return type, async/sync
- Every FlutterApi method (Native→Dart): name, parameters — these are the events/callbacks the native layer must emit
- Every enum with all values
- Grouping by functional area (camera lifecycle, capture, recording, preview, settings)
- Notes on which methods are called frequently (per-frame) vs rarely (configuration changes)

PHASE 3 — FILE AND SYMBOL INVENTORY

Systematically catalog every source file. Use Grep with structured patterns to ensure completeness — do not rely on manual reading alone.

For each layer, produce a table:
| File path | Class/Struct/Enum | Visibility | Key methods | Purpose (one line) | Threading context |

Layers:
a) Dart plugin API (packages/*/lib/) — skip Flutter widget code, focus on the library's public API
b) Kotlin native layer (packages/*/android/src/ and android/src/)
c) C++ native layer (*.cpp, *.h)
d) GPU/shader code (*.glsl, shader-related code)
e) Build configuration (gradle, CMakeLists, pubspec.yaml — note native deps, SDK versions)

Write each layer to its own file in docs/ios-translation/03-inventory/.

PHASE 4 — ARCHITECTURAL PLANE MAPS

Produce six maps. For each, use Mermaid diagram syntax AND prose explanation. Mine git log and code comments for design rationale.

Map 1 — Data Plane (Frame Flow):
Document using L1-L5 format. Trace a camera frame from sensor to every consumer:
- Buffer format at each stage (YUV, NV21, RGBA, etc.) with pixel layout details (stride, padding, color space)
- Every transformation (what it does, not just that it exists)
- GPU shader passes: what each computes, input→output format
- Fan-out points to multiple consumers
- Back-pressure: what happens when a consumer is slower than frame production
- Memory ownership at each handoff (who allocates, who releases, when)

Map 2 — Control Plane:
Document using L1-L5 format. This is derived from the Pigeon contract (Phase 2) plus the native dispatch logic:
- How each Pigeon HostApi method dispatches to native code
- Parameter validation and defaulting (where, what values)
- Return path for each call type (sync result, async callback, error)

Map 3 — State Machine:
Document using L1-L5 format. Extract the complete state machine as a formal Mermaid state diagram:
- Every state with its meaning
- Every transition with trigger, guard condition, and action
- Which component owns the state
- How state changes propagate to Dart (which FlutterApi calls)
- Edge transitions that were added to handle discovered bugs (from git log)

Map 4 — Resource Lifecycle:
Document using L1-L5 format. For each major resource (camera device, capture session, surfaces, GPU context/pipeline, textures, image readers, recorders):
- Creation → initialization → use → teardown sequence
- Ordering dependencies between resources (what must exist before what)
- What happens on app pause/resume/backgrounding
- Cleanup ordering constraints (what must be destroyed before what)

Map 5 — Threading & Concurrency Model:
Document using L1-L5 format. THIS IS THE HIGHEST-DETAIL SECTION — your codebase has extensive threading guards and edge-case handling:
- Every thread/handler with its purpose and what operations run on it
- Synchronization points between threads
- Every threading guard: what it prevents, what happens without it, timing values and why those values
- Deadlock risks and how they are avoided
- Post-to-handler patterns and callback chains

Map 6 — Error & Recovery:
Document using L1-L5 format:
- Every error origination point
- The stall watchdog: threshold values, tuning history (from git log), why this value
- Recovery strategy: what is torn down, what is recreated, in what order
- Errors that are recoverable vs fatal
- How errors propagate to Dart and what the UI does with them

Write each map to its own file in docs/ios-translation/04-architecture-maps/.

PHASE 5 — COMPONENT TRANSLATION CARDS

For each major component, produce a full L1-L6 translation card.
Write each to its own file in docs/ios-translation/05-translation-cards/.

Components to cover:
- Camera device management & lifecycle
- Preview rendering pipeline
- GPU processing pipeline (OpenGL ES → Metal)
- Shader programs (GLSL → Metal Shading Language)
- C++ consumer/sink integration
- Image capture flow
- Video recording flow
- Frame format conversion
- Camera characteristic controls (focus, AWB, AE, ISO, exposure, zoom)
- State management & lifecycle notifications
- Error handling & recovery
- Configuration & capability querying

For each card, in addition to L1-L6, include:
- The Pigeon API methods this component implements (cross-reference Phase 2)
- Exact parameter types and value ranges where relevant

PHASE 6 — ARCHITECTURE BRIEF

Write docs/ios-translation/06-architecture-brief.md — a concise document (<1500 words) for the downstream agent:
- Summary of the two missions and why they drive the architecture
- The 3-5 hardest translation challenges and why they are hard (with references to specific L4 edge cases)
- Recommended iOS architecture (module/layer structure) — as a starting point, not a mandate
- Key design decisions that should be made early (with your recommendation and reasoning)
- What can be directly translated vs what needs iOS-native redesign
- A note that Claude conversation history contains additional design rationale not captured here (to be provided separately)

PHASE 7 — MANIFEST

Write docs/ios-translation/MANIFEST.md:
- Every file in docs/ios-translation/ with one-line description
- Suggested read order for the downstream agent (numbered 1-N)
- Component ID cross-reference (so the downstream agent can trace a component across inventory, maps, and translation cards)
</phases>

<tool-strategy>
Use the right tool for each task. Do NOT brute-force read every file.

Orientation:
- Read docs/architecture.md, docs/usage-guide.md, CLAUDE.md first
- Read docs/plans/*.md for design rationale

UI:
- Read screenshot image files directly (Claude Code can read images)

Pigeon:
- Glob for *.dart files containing pigeon annotations or in a pigeon/ directory
- Read the source definitions (not generated output)

Dart layer:
- Use mcp__dart__resolve_workspace_symbol to enumerate classes/functions
- Use mcp__dart__hover for type info on key symbols
- Use mcp__dart__analyze_files for static analysis
- Skip reading Flutter widget code for UI understanding — screenshots cover this

Kotlin layer:
- Glob **/*.kt to inventory files
- Grep "class\s+\w+" for all class declarations
- Grep "fun\s+\w+" for all method declarations
- Grep "\/\/" and "\/\*" near guards and edge-case handlers for comments
- Read files for behavioral understanding after systematic enumeration

C++ layer:
- Glob **/*.cpp, **/*.h, **/*.glsl
- Grep for class/function declarations
- Read for implementation understanding

Git history:
- git log --oneline -50 for project overview
- git log -p --follow <file> on key files (CameraController.kt, GpuPipeline, etc.) to find WHY changes were made
- git log --all --grep="<keyword>" for specific topics (e.g., "stall", "watchdog", "recovery", "deadlock", "race")
- git blame <file> on specific lines with non-obvious guards to find the commit that added them

Code comments:
- This codebase has extensive inline comments. Read them carefully — they often explain edge cases, timing values, and design rationale that is not in git messages.
</tool-strategy>

<allowed-actions>
- Read any file in the project (source code, docs, screenshots, git history)
- Use Grep, Glob for code search
- Use MCP dart tools for symbol resolution and analysis
- Run read-only git commands (log, blame, show, diff) via Bash
- Write files ONLY within docs/ios-translation/
- Create directories within docs/ios-translation/
</allowed-actions>

<forbidden-actions>
- Do NOT modify any source code or existing documentation
- Do NOT modify any file outside docs/ios-translation/
- Do NOT run the app, build, or execute tests
- Do NOT install dependencies
- Do NOT make git commits
- Do NOT read Dart widget code to understand UI — use screenshots
- Do NOT write prose when a table or Mermaid diagram is more precise
- Do NOT skip a component because it seems simple — document everything
- Do NOT use one-line descriptions for L4 edge cases — these need full context
</forbidden-actions>

<stop-conditions>
Pause and ask before proceeding when:
- You find a threading guard or edge-case handler but cannot determine WHY it exists from code comments or git log — flag it as needing clarification rather than guessing
- You discover a component with no clear iOS equivalent API
- A source file exceeds 500 lines — verify your method inventory is complete using Grep before moving on
- You find an undocumented native dependency not visible in build files
- You are unsure whether an edge case is domain-level (will exist on iOS) or Android-specific (can be dropped) — flag for human decision
</stop-conditions>

<checkpoints>
After completing each phase:
✅ Phase N complete — [files written] — [key findings or surprises]
Verify by reading MANIFEST.md (once created) to confirm all expected files exist.
At the end of Phase 4 and Phase 5, re-read docs/ios-translation/00-project-overview.md and verify it is still accurate given what you learned — update if needed.
</checkpoints>

<quality-gates>
Before declaring any phase complete:
- Every class in inventory tables has at least one method listed
- Every architectural map has a Mermaid diagram AND prose explanation
- Every translation card has all L1-L6 sections filled (use "NEEDS INVESTIGATION — [reason]" for genuinely unknown items, never leave blank)
- Every L4 edge case entry has: trigger, failure mode, timing values with rationale, domain vs platform classification, iOS implication
- Cross-references use consistent component names across all files
- Every L3 design decision has a source (commit hash, code comment, or docs reference)
- The MANIFEST.md read-order makes logical sense (overview → contract → maps → cards → brief)
</quality-gates>
```

---

## Pre-Requisites (User Actions Before Running)

1. Take screenshots of every distinct UI screen/state and place them in `screenshots/`
2. Name screenshots descriptively (e.g., `preview-streaming.png`, `camera-controls-panel.png`, `recording-active.png`)
3. Ensure git history is available (not a shallow clone)
