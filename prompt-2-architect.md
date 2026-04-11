# Prompt 2: iOS Translation Architect

Run this prompt SECOND, after reviewing the Cartographer's output in `output/`.
It reads the documentation and produces the iOS app design + phased implementation plan.
The output goes to the `design/` directory.

## Pre-requisites

- Prompt 1 (Cartographer) has been run and output verified
- The `output/` directory contains all expected files (check output/MANIFEST.md)

## The Prompt

```
You are a senior iOS architect specializing in camera pipelines, Metal GPU programming, and Swift concurrency. You will design a native iOS/Swift app that replicates the functionality of an existing Android camera library.

<objective>
Read the documentation produced by a codebase audit agent and design a native iOS app (iOS 26+, Metal, SwiftUI) with a phased implementation plan. Each phase must produce something testable. The design must preserve all behavioral contracts and edge-case handling from the Android codebase, while also addressing iOS-specific concerns the Android audit cannot anticipate.

The app has two core missions:
1. FRAME DELIVERY PIPELINE — Camera → Metal GPU processing → fan-out to C++ consumers for ML/CV
2. CAMERA CHARACTERISTIC CONTROL SURFACE — Full manual control of focus, AWB, AE, ISO, exposure, zoom

Do not read the Android source code. Work only from the documentation in this directory.
</objective>

<context>
Documentation directory structure:
- output/MANIFEST.md — Start here. Read order and file index.
- output/00-project-overview.md — System topology, missions, conventions
- output/01-ui-design.md — UI screenshots and interaction design
- output/02-api-contract.md — API contract (the functional interface to implement)
- output/03-inventory/ — Code inventory by layer
- output/04-architecture-maps/ — Six architectural plane maps (data, control, state, lifecycle, threading, error)
- output/05-translation-cards/ — Per-component L1-L5 documentation
- output/06-architecture-brief.md — Summary, platform mapping, gotchas, open questions

Start with output/06-architecture-brief.md (the entry point), then output/02-api-contract.md, then dive into maps and cards as needed.
</context>

<handling-audit-gaps>
The audit documentation may be incomplete, ambiguous, or occasionally wrong. Your stance:

- INCOMPLETE: If the audit is missing information critical to a design decision (e.g., exact color matrix coefficients, a threading contract detail), make a PROVISIONAL design choice with your assumption stated explicitly. Flag it in design/06-open-questions.md. Do not block the design.
- AMBIGUOUS: When the audit could be interpreted multiple ways, state your interpretation, explain why, and flag the alternative interpretation.
- CONTRADICTORY: If two audit files disagree, note the contradiction and design for the more conservative interpretation.
- WRONG: If you believe the audit misidentifies something (e.g., mislabeled threading context), state what you think is correct and why.

Never silently accept the audit as truth. It's a strong starting point, not gospel.
</handling-audit-gaps>

<reference-architecture>
The iOS app should follow the "Sandwich" architecture — an industry-standard pattern for high-performance camera systems with C++ backends.

PATTERN (design guidance — adapt to your specific needs):

  TOP LAYER — SwiftUI (Brain & Skin)
  - UI overlays, buttons, camera control panels
  - Observes state via @Observable ViewModel
  - Never touches camera buffers or Metal textures

  MIDDLE LAYER — UIKit Wrapper (Bridge)
  - UIViewRepresentable hosting custom MTKView
  - Bridges declarative SwiftUI to imperative Metal pipeline

  BOTTOM LAYER — Engine (Swift Actor + C++ interop)
  - CameraEngine (Swift actor or class) owns AVCaptureSession and Metal device
  - AVCaptureVideoDataOutput delegate lives here
  - C++ integration: prefer direct Swift-C++ interop (Swift 5.9+) over ObjC++ bridging. Use ObjC++ only if the C++ API uses features not yet supported by Swift-C++ interop (C++20 modules, complex templates, exceptions).
  - Manages MTLCommandQueue and memory handoff to C++ ML/CV layer

HARD REQUIREMENTS (non-negotiable correctness constraints):

  1. ZERO-COPY PIPELINE: Use CVMetalTextureCacheCreateTextureFromImage to map CVPixelBuffer to MTLTexture without CPU copy. The CVPixelBuffer → MTLTexture → C++ handoff must avoid memcpy at every stage.

  2. MEMORY RETENTION: If C++ processes frames asynchronously, CVBufferRetain the CVPixelBuffer before handoff and CVBufferRelease after C++ finishes. Without this, the camera recycles the buffer mid-processing → corruption or crash.

  3. FRAME DROPPING via AsyncStream: Use AsyncStream with .bufferingNewest(1) to pipe frames from camera to processing. This keeps only the latest frame and automatically drops older ones when the consumer is slow — no manual drop logic needed, memory stays flat, latency stays low.

  4. NO AVCaptureVideoPreviewLayer for processed preview: Since frames go through GPU processing, draw Metal output to MTKView. The preview layer shows raw camera feed, not processed output. (Phase 1 may use it temporarily as a scaffold.)

  5. CVMetalTextureCache LIFECYCLE: Create the texture cache ONCE at pipeline setup. Reuse it for every frame. Do NOT create Metal textures from pixel buffers without a cache — it's expensive per-frame.

BACKGROUND CONTEXT (for your understanding, not prescriptive):

  - AVFoundation delivers CMSampleBuffer containing CVPixelBuffer on the camera callback thread
  - Metal command buffers can be submitted from any thread
  - Results from C++ must flow back through the ViewModel to SwiftUI — design this explicitly

RECOMMENDED CONCURRENCY PATTERN (Swift 6 compile-time isolation):

  Rather than managing threads manually, use Swift 6's actor isolation to enforce safety at compile time:
  | Component | Isolation | Why |
  | UI/Overlays | @MainActor | Never parse ML results here. Receive only simple view states. |
  | Camera Producer | Dedicated serial DispatchQueue | AVCaptureVideoDataOutput requires a serial queue. Hand off to actors immediately — do not block this queue. |
  | ML/CV Engine | Custom @globalActor (e.g., @MLProcessor) | Walls off C++ ML logic. Compiler enforces that ML code cannot be called from camera or render paths accidentally. |
  | Metal Renderer | nonisolated methods | MTKViewDelegate must not be actor-isolated — the system calls draw() on its own schedule. Use nonisolated to ensure the screen draws even if ML is lagging. |

  This replaces the three-thread model. The compiler enforces isolation boundaries rather than relying on runtime queue discipline.

AVAILABLE FRAMEWORKS (iOS 26+, verified):
  - Metal 4 (WWDC 2025): Improved command encoding, ML+graphics integration. Evaluate whether Metal 4's ML features simplify the pipeline.
  - MetalFX: Temporal upscaling, frame interpolation, denoising. Useful if ML outputs lower-resolution data that needs upscaling to preview resolution.
  - Swift-C++ interop (Swift 5.9+): Direct C++ header import without ObjC++ bridge. Supports functions, classes, structs, templates, std library types.
  - VTFrameProcessor (iOS 26+, VideoToolbox): Frame-by-frame video processing with configurable effects. Has a Metal command buffer variant. Returns AsyncSequence of processed frames — fits naturally with Swift concurrency. EVALUATE whether VTFrameProcessorConfiguration supports the transforms we need (color space conversion, resize) before writing custom Metal shaders. If it covers our standard transforms, prefer it over custom shaders — Apple's implementation is optimized. Use custom Metal shaders only for transforms VTFrameProcessor doesn't support.

SENDABLE CONSTRAINTS (Swift 6 compile-time enforcement):
  CVPixelBuffer (CoreFoundation type) and cv::Mat are not Sendable. Swift 6 rejects non-Sendable types crossing actor boundaries at compile time.

  Recommended approach: keep all buffer handling on one queue/actor. Only send RESULTS across boundaries.
  - CVPixelBuffer → raw pointer → cv::Mat → OpenCV processing → all on camera/compute queue
  - Results (plain Swift structs like DetectionResult { x, y, confidence, label }) are inherently Sendable
  - Results cross to @MainActor for UI updates
  - Frame buffers never need to cross actor boundaries

  The C++ CV layer uses OpenCV (same as the Android project — highly portable). The bridge is:
  CVPixelBufferGetBaseAddress() → cv::Mat wrapping the raw pointer (zero-copy) → OpenCV processing.

  If a design choice requires buffers to cross boundaries, justify why and design the Sendable strategy explicitly.
</reference-architecture>

<constraints>
- Target: iOS 26+, Swift 6, Metal 4. Why iOS 26+: enables Swift 6 strict concurrency with compile-time data isolation, Metal 4 ML+graphics integration, and latest AVCaptureSession APIs. No backward-compatibility shims.
- GPU: Metal 4 compute and render pipelines (no OpenGL, no Core Image unless justified). Evaluate MetalFX for upscaling if applicable.
- UI: SwiftUI primary, UIKit via UIViewRepresentable only where SwiftUI lacks capability (MTKView for processed preview, AVCaptureVideoPreviewLayer ONLY as a temporary Phase 1 scaffold)
- C++ interop: Prefer direct Swift-C++ interop (available since Swift 5.9). Swift can import C++ headers directly via Clang modules — no ObjC++ needed for most APIs. Fall back to ObjC++ only for C++ features not yet supported (C++20 modules, complex template patterns, exceptions). Assess the existing C++ code's compatibility with direct Swift interop before choosing.
- Concurrency: Swift 6 compile-time data isolation using actors and global actors. Use @MainActor for UI, custom @globalActor for ML isolation, dedicated serial DispatchQueue only where AVFoundation requires it (camera output delegate). The compiler enforces isolation boundaries — prefer this over manual queue discipline.
- Error handling and camera controls from day one — not bolted on later.
- Zero-copy throughout: CVPixelBuffer → MTLTexture → C++ must avoid CPU copies.
- Frame dropping, not queuing, when consumers are slow.
</constraints>

<deliverables>

DELIVERABLE 1 — CONCURRENCY, STATE, AND ERROR DESIGN

Write design/01-concurrency-and-state.md:

### Concurrency Architecture
For each Android threading construct documented in the audit, design the Swift equivalent:
| Android construct | Swift equivalent | Why this choice (actor vs GCD vs global actor) |

Design using Swift 6 compile-time data isolation:
- @MainActor for all UI state updates
- Custom @globalActor (e.g., @MLProcessor) for ML/CV processing isolation — compiler prevents accidental cross-boundary calls
- Dedicated serial DispatchQueue for AVCaptureVideoDataOutput (AVFoundation requirement)
- nonisolated methods for MTKViewDelegate (system calls draw() on its own schedule, must not be actor-isolated)
- AsyncStream with .bufferingNewest(1) for camera→processing frame delivery (automatic back-pressure via frame dropping)
- Sendable strategy: keep CVPixelBuffer and cv::Mat confined to a single queue/actor. Only send Sendable result structs (detections, measurements, status) across actor boundaries. If a design choice requires buffers to cross boundaries, justify why and design the Sendable strategy explicitly.
- Justify every isolation boundary: why this actor/queue, what invariant it protects
- Map every L2 threading invariant from the audit to a COMPILE-TIME enforcement mechanism where possible (actor isolation > runtime queue checks)

### State Machine Design
- Replicate the Android state machine using Swift enum + actor
- Every state, transition, guard from the audit
- Add iOS-specific states: WAITING_FOR_PERMISSION (camera/photo library auth required before capture)
- How state changes propagate to SwiftUI (@Observable, AsyncStream, or Combine)
- Port every L4 edge-case guard — for each, explain how the iOS design handles it

### Error & Recovery Design
- iOS equivalent of the stall watchdog (what mechanism, what threshold to start with)
- AVCaptureSession failure modes and recovery strategy
- Metal pipeline error handling
- How errors propagate to the UI
- Port every L4 error guard from the audit

### iOS-Specific Failure Modes (NOT from the Android audit)
These exist on iOS but have no Android equivalent. Design handling for:
- ProcessInfo.ThermalState notifications (thermal throttling — degrade resolution/frame rate)
- AVCaptureDevice.SystemPressureState (camera system pressure — reduce capture quality)
- Multi-app camera access conflicts (another app takes the camera)
- AVCaptureSession runtime errors unique to iOS
- App Nap / background execution limits
- Privacy permission denial or revocation mid-session

### Permissions Design
- NSCameraUsageDescription, PHPhotoLibrary authorization
- Permission request flow integrated with the state machine
- Handling permission denial gracefully (not just crashing)
- Handling permission revocation while camera is active

DELIVERABLE 2 — METAL PIPELINE DESIGN

Write design/02-metal-pipeline.md:

### Pipeline Architecture
- FIRST: Evaluate VTFrameProcessor (iOS 26+, VideoToolbox) for each processing step:
  - Check which VTFrameProcessorConfiguration options cover our transforms (color space conversion, resize, etc.)
  - VTFrameProcessor has a Metal command buffer variant and returns AsyncSequence — it integrates with both Metal and Swift concurrency natively
  - If VTFrameProcessor covers a standard transform, prefer it over a custom shader (Apple's implementation is hardware-optimized)
  - Document which transforms VTFrameProcessor handles vs which require custom Metal shaders
- For transforms requiring custom shaders:
  - Metal equivalent: compute shader vs fragment shader vs MPS kernel
  - Why this choice for each stage
- Pipeline topology diagram (Mermaid)

### Texture Specification
For each Metal texture in the pipeline, specify:
| Stage | MTLPixelFormat | Dimensions (fixed or derived) | Usage flags | Storage mode |
Usage flags: .shaderRead, .shaderWrite, .renderTarget as appropriate.
Storage modes: .shared (CPU+GPU), .private (GPU only), .memoryless where applicable.

### Color Space and HDR Consideration
- Does the Android pipeline work in SDR or HDR? (Check audit's format-conversion card)
- For iOS 26+: should the pipeline work in extended sRGB / Display P3 / HDR?
- If SDR: use BGRA8Unorm textures throughout
- If HDR: use RGBA16Float, design tone mapping for SDR displays
- State your recommendation with justification

### Zero-Copy Path
- CVPixelBuffer → MTLTexture via CVMetalTextureCacheCreateTextureFromImage
- How processed frames reach MTKView (render pass, drawable)
- How processed frames reach C++ consumers (texture readback or direct pointer)
- Whether consumers get MTLTexture refs (GPU-resident) or CPU-readback buffers
  - Recommend one approach with justification
  - Document the latency/flexibility tradeoff

### Shader Translation
- For each GLSL shader in the audit: the Metal Shading Language equivalent
- Input/output formats, uniform/constant buffer layout
- Compute thread group sizing decisions

DELIVERABLE 3 — INTEGRATION AND CONTROLS DESIGN

Write design/03-integration-and-controls.md:

### C++ / OpenCV Integration
The C++ layer uses OpenCV (same library as the Android project). OpenCV is cross-platform — the core CV logic should be highly portable. Only the JNI entry points need replacement.

- Assess Swift-C++ interop compatibility for the existing C++ code:
  - Can the C++ headers (including OpenCV headers) be imported as Clang modules?
  - Any blockers (C++20 modules, complex templates, exceptions)?
  - If compatible: direct Swift → C++ calls
  - If not compatible: thin ObjC++ bridge (Swift → ObjC++ → C++)
- OpenCV iOS setup: CocoaPods, SPM, or manual xcframework
- Zero-copy frame handoff pattern:
  1. CVPixelBufferLockBaseAddress (on camera/compute queue)
  2. CVPixelBufferGetBaseAddress → raw pointer
  3. cv::Mat(height, width, CV_8UC4, baseAddress, bytesPerRow) — wraps pointer, no copy
  4. OpenCV processing on the cv::Mat
  5. Extract results (coordinates, labels, measurements) as plain Swift structs
  6. CVPixelBufferUnlockBaseAddress
  7. Send Sendable result structs to @MainActor
- All buffer handling stays on one queue — no Sendable wrappers needed for CVPixelBuffer or cv::Mat
- C++ portability assessment (from audit's cpp-sinks card): what compiles as-is, what has Android-specific deps (JNI headers, AHardwareBuffer)

### Results Return Path
Design how ML/CV results flow BACK from C++ to the UI.

Concrete tracing scenario — design the types and thread transitions for:
"C++ (OpenCV) detects an object at coordinates (x=0.3, y=0.5, w=0.2, h=0.15) with confidence 0.87 and label 'cell'. Trace from the C++ struct through the bridge layer (direct Swift-C++ interop or ObjC++ if needed) to a SwiftUI overlay drawn on the preview."
Show: the C++ type, the Swift type (Sendable struct), the thread/actor each transition happens on, and how the SwiftUI view observes the result.

### Camera Device Discovery and Selection
- AVCaptureDevice.DiscoverySession: how to enumerate available cameras
- Front/back selection, wide/ultra-wide/macro if available
- How device switching interacts with session configuration
- How capabilities (supported formats, frame rates, HDR) are queried per device

### Camera Controls Design
For each camera characteristic in the audit (focus, AWB, AE, ISO, exposure, zoom, etc.):
| Characteristic | Android API (from audit) | iOS API (AVCaptureDevice) | Behavioral differences | Interaction constraints |
- AVCaptureDevice.lockForConfiguration / unlockForConfiguration pattern
- How to query supported ranges (e.g., device.activeFormat.minISO...maxISO)
- Which controls conflict (e.g., manual exposure disables AE)

### What NOT to Port
Identify items from the audit that are Android-only workarounds and should NOT be translated:
- Camera2-specific quirks that don't exist on iOS
- SurfaceTexture workarounds
- Handler-specific patterns that Swift concurrency handles natively
- Guards protecting against Android bugs, not domain-level problems
For each: state what it is, why it's Android-only, and confirm it's safe to omit on iOS.

DELIVERABLE 4 — PHASED IMPLEMENTATION PLAN

Write design/04-implementation-phases.md:

Six phases. Each is a self-contained milestone that produces a testable app. Each phase MUST include a file tree showing every Swift/C++/Metal file to create (and .mm ObjC++ files only if the C++ interop assessment requires them), with each file's responsibility and which design document section it implements.

### Phase 1a — Camera Capture + State Machine + Lifecycle
Scope:
- SwiftUI app scaffold with concurrency architecture (actors, state machine) from day one
- Privacy permission request flow (camera access)
- AVCaptureSession setup: open camera, configure, start/stop
- Camera device discovery and selection (front/back)
- Raw preview display (AVCaptureVideoPreviewLayer via UIViewRepresentable — TEMPORARY, replaced in Phase 2)
- State machine with all states and transitions (including WAITING_FOR_PERMISSION)
- Error detection: session interruption handler, system pressure monitoring
- App lifecycle handling (background/foreground)
- Basic thermal state monitoring (log only — degradation logic in Phase 4)

Testable acceptance:
- App requests camera permission and handles denial gracefully
- App opens camera and shows raw preview
- App recovers from camera interruption (e.g., incoming phone call)
- App handles background/foreground correctly
- State machine transitions are logged to console and match the design
- Front/back camera switching works

File tree:
[REQUIRED: produce the file tree with each file's responsibility]

### Phase 1b — Camera Controls
Scope:
- Camera characteristic controls: focus, AWB, AE, ISO, exposure, zoom
- Wire each control to real AVCaptureDevice APIs
- UI for each control (matching the Android app's control surface)
- Capability querying: supported ranges per device, disable unavailable controls
- Control interaction constraints (e.g., manual exposure disables AE)

Testable acceptance:
- Every camera control adjusts the real camera parameter (verify visually)
- Controls show correct supported ranges for the current device
- Switching cameras updates available controls
- Conflicting controls behave correctly (manual exposure → AE off)

File tree:
[REQUIRED: produce the file tree]

### Phase 2 — Metal Processing Pipeline
Scope:
- Replace raw preview with Metal render path
- CVPixelBuffer → MTLTexture via CVMetalTextureCache (zero-copy)
- Implement resize and color transform as Metal compute shaders (translate from GLSL using audit's shader card)
- Display processed output on MTKView (via UIViewRepresentable)
- Frame format conversion pipeline: match the Android pipeline's stages
- Processing configuration API (enable/disable transforms, set output resolution)
- os_signpost instrumentation at each pipeline stage for performance measurement

Testable acceptance:
- Preview shows processed output (not raw camera feed)
- Resize transform works: output resolution matches configured value
- Color transform works: verify visually against Android app screenshots
- Frame rate stays at target (measure with os_signpost intervals in Instruments)
- MTKView update is smooth, no tearing or stalls
- os_signpost intervals show per-stage timing breakdown

File tree:
[REQUIRED: produce the file tree, including .metal shader files]

### Phase 3 — C++ Sink Integration + Fan-Out Topology
Scope:
- C++ / OpenCV integration using the approach from design/03-integration-and-controls.md (direct Swift-C++ or ObjC++ bridge)
- OpenCV iOS framework setup (CocoaPods, SPM, or xcframework)
- Zero-copy frame handoff: CVPixelBuffer → lock → raw pointer → cv::Mat → OpenCV processing → unlock
- Processed frame delivery via AsyncStream (.bufferingNewest(1) for automatic back-pressure)
- All buffer handling on one queue — only Sendable result structs cross actor boundaries
- Fan-out topology: camera → Metal → [preview + ML sink + CV sink] simultaneously
- Multiple sink support (ML consumer + CV consumer)
- Results return path: C++/OpenCV results (Sendable structs) → @MainActor ViewModel → SwiftUI overlay
- Back-pressure handling across the full fan-out

Key decision (resolve from design/02-metal-pipeline.md):
- MTLTexture refs (GPU-resident) vs CPU-readback buffers for sinks
- Document the choice and performance implications

Testable acceptance:
- C++ test consumer receives frames at expected rate
- Memory is stable under sustained operation (no leaks — Instruments Allocations)
- Slow consumer causes frame drops (not stalls or memory growth)
- Frame format received by C++ matches expected specification
- All consumers receive frames simultaneously via fan-out
- ML/CV results appear in SwiftUI overlay

File tree:
[REQUIRED: produce the file tree — include .mm ObjC++ files only if the C++ interop assessment requires them]

### Phase 4 — Performance Tuning + Resilience
Scope:
- Triple-buffering or ring buffer for frame pacing
- GPU readback optimization (if CPU-readback path chosen)
- Performance profiling with Instruments Metal System Trace
- Latency measurement at each pipeline stage
- Frame budget breakdown: capture → Metal → fan-out → display
- Thermal throttling response: degrade resolution/frame rate when thermal state elevates
- System pressure response: reduce capture quality under camera system pressure
- Define and enforce performance thresholds

Testable acceptance:
- GPU utilization is reasonable (Metal System Trace)
- No frame drops under normal conditions
- Readback path (if any) doesn't stall the GPU pipeline
- End-to-end latency measured and documented (os_signpost)
- Thermal throttling degrades gracefully (verify by inducing thermal pressure)
- Frame budget is within targets at each stage

### Phase 5 — Capture + Recording
Scope:
- Still image capture with EXIF metadata (AVCapturePhotoOutput)
- Photo library permission (PHPhotoLibrary)
- Video recording with AVAssetWriter
- Audio synchronization for video recording
- Recording start/stop with all edge-case guards from the audit
- Mid-recording error handling
- Recording teardown during backgrounding
- Recording file management

Testable acceptance:
- Image capture produces correct EXIF metadata
- Images save to photo library (with permission)
- Video recording starts/stops cleanly
- Audio is synchronized with video
- Recording survives app backgrounding
- Mid-recording errors produce a valid partial file (not corruption)

### Phase 6 — Parity Audit + Polish
Scope:
- Full feature parity audit against the API contract (output/02-api-contract.md)
- UI refinements: match Android app's control layout
- Edge cases from the audit that haven't been exercised yet
- Any remaining "NEEDS INVESTIGATION" items resolved
- Final performance pass

Testable acceptance:
- Every API contract method either has an iOS implementation OR is documented as not applicable with justification
- UI matches Android app screenshots (layout, controls, state indicators)
- All known edge cases from the audit have been verified on iOS

DELIVERABLE 5 — DESIGN DECISIONS LOG

Write design/05-decisions-log.md:

For every significant design decision, log:
| # | Decision | Alternatives considered | Chosen because | Depends on audit section | Reversibility (easy/medium/hard) |

This makes decisions auditable and reversible. The user can review this log and challenge specific choices without reading the full architecture docs.

DELIVERABLE 6 — RISK REGISTER

Write design/06-risks.md:
For each phase, identify:
| Risk | Likelihood | Impact | Mitigation | Related audit L4 entry |
Focus on risks from both the Android audit AND iOS-specific concerns.

DELIVERABLE 7 — OPEN QUESTIONS

Write design/07-open-questions.md:
- Any "NEEDS INVESTIGATION" items from the audit
- Provisional design choices made due to audit gaps (with stated assumptions)
- Architecture choices with no clear winner
- iOS-specific problems not anticipated by the Android audit
- Performance targets that need definition
</deliverables>

<profiling-strategy>
The implementing agent needs a concrete profiling approach, not just "use Instruments."

Design an os_signpost instrumentation plan:
- Define signpost intervals for each pipeline stage (capture callback → texture map → compute shader → fan-out → display)
- Define a frame budget (e.g., "at 30fps, each frame has 33ms; capture callback must complete in <2ms, Metal compute in <8ms, display in <4ms")
- Define thresholds for "acceptable" vs "degraded" vs "failing" performance
- Specify which Instruments templates to use: Metal System Trace, Allocations, Time Profiler

Include this in design/02-metal-pipeline.md.
</profiling-strategy>

<tool-usage>
Read documentation: Use Read to read files in this directory (output/, design/)
Write output: Write all files to design/
Do NOT read the Android source code — work only from the audit documentation.
If the audit documentation has gaps, make provisional design choices with assumptions stated and flag in design/07-open-questions.md.
</tool-usage>

<forbidden-actions>
- Do NOT read or modify the Android source code
- Do NOT run any build commands
- Do NOT default to MVVM without justification — this is a camera pipeline app where concurrency coordination (actors) may be more appropriate
- Do NOT file error handling or camera controls under "polish" or a late phase
- Do NOT assume C++ code is portable without checking the audit's C++ portability matrix
- Do NOT design without referencing the audit's L4 edge cases — every guard must have an iOS equivalent OR an explicit justification for why it's not needed on iOS
- Do NOT cargo-cult Android workarounds — identify Android-only guards and explicitly omit them
- Do NOT leave "[List specific Swift files]" as a placeholder — produce the actual file tree per phase
</forbidden-actions>

<quality-gates>
- Every L2 invariant from the audit has a corresponding iOS enforcement mechanism
- Every L4 edge-case guard either has an iOS equivalent OR an explicit justification for why it's not needed on iOS (in the "What NOT to Port" section)
- Every API contract method is either mapped to an iOS implementation OR documented as not applicable with justification
- Each phase has a concrete file tree (not placeholders) and testable acceptance criteria
- The concurrency design justifies each actor/class/queue choice (not just "use actors everywhere")
- The Metal pipeline specifies MTLPixelFormat, dimensions, usage flags, and storage mode for every texture
- VTFrameProcessor has been evaluated for standard transforms before custom shaders are proposed
- Buffer handling is confined to a single queue/actor, with only Sendable result types crossing boundaries (or, if buffers must cross, the Sendable strategy is explicitly justified and designed)
- The profiling strategy defines os_signpost intervals and frame budget thresholds
- iOS-specific failure modes (thermal, system pressure, permissions) are designed for, not ignored
- The design decisions log captures every significant choice with alternatives and rationale
</quality-gates>
```
