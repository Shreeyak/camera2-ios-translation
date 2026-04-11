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
Read the documentation produced by a codebase audit agent and design a native iOS app (iOS 26+, Metal, SwiftUI) with a phased implementation plan. Each phase must produce something testable. The design must preserve all behavioral contracts, edge-case handling, and design rationale from the Android codebase.

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
- output/02-api-contract.md — Pigeon API contract (the functional interface)
- output/03-inventory/ — Code inventory by layer
- output/04-architecture-maps/ — Six architectural plane maps (data, control, state, lifecycle, threading, error)
- output/05-translation-cards/ — Per-component L1-L5 documentation
- output/06-architecture-brief.md — Summary, platform mapping, open questions

Read the MANIFEST first, then follow its recommended read order.
</context>

<constraints>
- Target: iOS 26+, Swift 6, Metal 3
- GPU: Metal compute and render pipelines (no OpenGL, no Core Image unless justified)
- UI: SwiftUI primary, UIKit via UIViewRepresentable only where SwiftUI lacks capability (AVCaptureVideoPreviewLayer, MTKView)
- C++ interop: ObjC++ bridging layer (Swift → ObjC++ → C++). Use Objective-C ONLY for this bridge and for Apple frameworks that lack Swift-native API.
- Concurrency: Swift structured concurrency (actors, async/await, TaskGroups). Do NOT default to GCD unless actors are inappropriate for a specific case — justify the choice.
- Error handling from day one — not bolted on later. The Android codebase has a stall watchdog, RECOVERING state, and recording teardown guards. The iOS design must handle equivalent failure modes from Phase 1.
- Camera controls from day one — not added as an afterthought. Manual control of camera characteristics is half the app's purpose.
</constraints>

<deliverables>

DELIVERABLE 1 — iOS ARCHITECTURE DESIGN

Write design/01-architecture.md:

### Module/Layer Diagram (Mermaid)
- App layer (SwiftUI views, view models or observable state)
- Camera engine layer (AVCaptureSession, device management)
- Metal processing layer (compute/render pipelines, texture management)
- C++ bridge layer (ObjC++ wrappers)
- How layers communicate (protocols, AsyncStream, delegate, Combine)

### Concurrency Architecture
For each Android threading construct documented in the audit, design the Swift equivalent:
| Android construct | Swift equivalent | Why this choice |
- Where actors are used vs classes
- Which operations are @MainActor
- How AVCaptureSession delegate callbacks feed into actors
- Back-pressure strategy when consumers are slower than frame production
- Map every L2 threading invariant from the audit to a Swift enforcement mechanism

### State Machine Design
- Replicate the Android state machine using Swift enum + actor
- Every state, transition, guard from the audit
- How state changes propagate to SwiftUI (Observable, AsyncStream, etc.)
- Port every L4 edge-case guard — for each, explain how the iOS design handles it

### Error & Recovery Design
- iOS equivalent of the stall watchdog (what mechanism, what threshold to start with)
- AVCaptureSession failure modes and recovery strategy
- Metal pipeline error handling
- How errors propagate to the UI
- Port every L4 error guard from the audit

### Metal Pipeline Design
- For each Android GPU processing step (from the shader translation card):
  - Metal equivalent: compute shader vs fragment shader vs MPS
  - Input/output texture formats
  - How to achieve zero-copy: CVPixelBuffer → MTLTexture via CVMetalTextureCache
- Fan-out design: how processed frames reach both MTKView preview and C++ consumers
- Whether consumers get MTLTexture refs (GPU-resident) or CPU-readback buffers
  - Recommend one approach with justification
  - Document the latency/flexibility tradeoff

### C++ Integration Design
- ObjC++ bridge pattern: Swift → ObjC++ wrapper → C++ consumer
- Memory ownership: who allocates pixel buffers, who frees them, when
- Threading contract: which queue delivers frames to C++, synchronous vs async
- Which parts of the existing C++ are portable vs need Android-specific code removed

### Camera Controls Design
- For each camera characteristic in the audit (focus, AWB, AE, ISO, exposure, zoom, etc.):
  | Characteristic | Android API | iOS API (AVCaptureDevice) | Behavioral differences |
- How to expose manual control: AVCaptureDevice.lockForConfiguration, set property, unlock
- Interaction constraints: which controls conflict (e.g., manual exposure vs auto-exposure)
- How to query supported ranges and capabilities

DELIVERABLE 2 — PHASED IMPLEMENTATION PLAN

Write design/02-implementation-phases.md:

Five phases. Each is a self-contained milestone that produces a testable app. The key principle: each phase must RUN and be VERIFIABLE before the next phase starts.

### Phase 1 — Camera Capture + Controls + State Machine
Scope:
- SwiftUI app scaffold with the concurrency architecture (actors, state machine) from day one
- AVCaptureSession setup: open camera, configure, start/stop
- Raw preview display (AVCaptureVideoPreviewLayer via UIViewRepresentable)
- Camera characteristic controls: focus, AWB, AE, ISO, exposure, zoom — wired to real AVCaptureDevice APIs
- State machine with all states and transitions (even if some transitions aren't exercised yet)
- Error detection and basic recovery (session interruption handler)
- App lifecycle handling (background/foreground)

Testable acceptance:
- App opens camera and shows preview
- Every camera control adjusts the real camera parameter (verify visually)
- App recovers from camera interruption (e.g., incoming phone call)
- App handles background/foreground correctly
- State machine transitions are logged and match the design

Why controls are in Phase 1: Camera controls are half the app's purpose and require AVCaptureDevice configuration that interacts with session setup. Designing them later means retrofitting the camera engine.

Why error handling is in Phase 1: The Android codebase learned through painful iteration that error handling is architectural, not cosmetic. Bolting it on later means redesigning the state machine.

Files to create:
[List specific Swift files, their responsibilities, and which design/01-architecture.md section they implement]

### Phase 2 — Metal Processing Pipeline
Scope:
- Replace raw preview with Metal render path
- CVPixelBuffer → MTLTexture via CVMetalTextureCache (zero-copy)
- Implement resize and color transform as Metal compute shaders (translate from GLSL)
- Display processed output on MTKView (via UIViewRepresentable)
- Frame format conversion pipeline: match the Android pipeline's stages
- Processing configuration API (enable/disable transforms, set output resolution)

Testable acceptance:
- Preview shows processed output (not raw camera feed)
- Resize transform works: output resolution matches configured value
- Color transform works: verify visually against Android app
- Frame rate stays at target (measure with os_signpost or Instruments)
- MTKView update is smooth, no tearing or stalls

Files to create:
[List Metal shader files, pipeline classes, texture management]

### Phase 3 — C++ Sink Integration
Scope:
- ObjC++ bridge layer: Swift → ObjC++ → C++ consumer interface
- Processed frame delivery to C++ sinks
- Memory ownership implementation (from design/01-architecture.md)
- Threading contract: frames delivered on designated queue
- Multiple sink support (ML consumer + CV consumer)
- Back-pressure handling when sinks are slow

Key decision (resolve from design):
- Do sinks get MTLTexture refs or CPU-readback buffers?
- Document the choice and its performance implications

Testable acceptance:
- C++ test consumer receives frames at expected rate
- Memory is stable (no leaks — profile with Instruments Allocations)
- Slow consumer doesn't stall the pipeline or drop preview frames
- Frame format received by C++ matches expected specification

Files to create:
[List ObjC++ bridge files, C++ consumer interface]

### Phase 4 — Pipeline Fan-Out + Performance
Scope:
- Wire up full topology: camera → Metal → preview + ML sink + CV sink simultaneously
- Triple-buffering or ring buffer for frame pacing
- GPU readback optimization (if CPU-readback path chosen)
- Performance profiling and optimization
- Latency measurement at each pipeline stage

Testable acceptance:
- All consumers receive frames simultaneously
- GPU utilization is reasonable (profile with Metal System Trace)
- No frame drops under normal conditions
- Readback path (if any) doesn't stall the GPU pipeline
- End-to-end latency from capture to C++ delivery is measured and documented

### Phase 5 — Capture, Recording, and Parity
Scope:
- Still image capture with EXIF metadata
- Video recording (AVAssetWriter)
- Recording start/stop with all edge-case guards from the audit
- Recording teardown during backgrounding
- Thermal throttling detection and response
- UI refinements: match Android app's control layout
- Full feature parity audit against the API contract (output/02-api-contract.md)

Testable acceptance:
- Image capture produces correct EXIF metadata
- Video recording starts/stops cleanly
- Recording survives app backgrounding
- Thermal throttling degrades gracefully (lower resolution/frame rate)
- Every API contract method has an iOS equivalent implemented

DELIVERABLE 3 — RISK REGISTER

Write design/03-risks.md:
For each phase, identify:
| Risk | Likelihood | Impact | Mitigation | Related audit L4 entry |
Focus on risks identified in the audit's edge cases and guards.

DELIVERABLE 4 — OPEN QUESTIONS

Write design/04-open-questions.md:
Questions that need human decision or investigation:
- Any "NEEDS INVESTIGATION" items from the audit
- Architecture choices with no clear winner
- iOS-specific problems not present on Android
- Performance targets that need definition
</deliverables>

<tool-usage>
Read documentation: Use Read to read files in this directory (output/, design/)
Write output: Write all files to design/
Do NOT read the Android source code — work only from the audit documentation.
If the audit documentation has gaps (marked "NEEDS INVESTIGATION"), flag them in design/04-open-questions.md rather than guessing.
</tool-usage>

<forbidden-actions>
- Do NOT read or modify the Android source code
- Do NOT run any build commands
- Do NOT default to MVVM without justification — this is a camera pipeline app where concurrency coordination (actors) may be more appropriate than view-model binding
- Do NOT file error handling or camera controls under "polish" or a late phase
- Do NOT assume C++ code is portable without checking the audit's C++ inventory for Android-specific dependencies
- Do NOT design without referencing the audit's L4 edge cases — every guard must have an iOS equivalent in the design
</forbidden-actions>

<quality-gates>
- Every L2 invariant from the audit has a corresponding iOS enforcement mechanism
- Every L4 edge-case guard has an iOS equivalent or an explicit justification for why it's not needed on iOS
- Every API contract method is mapped to an iOS implementation in the phased plan
- Each phase has specific files to create and testable acceptance criteria
- The concurrency design justifies each actor/class/queue choice
- The Metal pipeline design specifies texture formats at every stage
</quality-gates>
```
