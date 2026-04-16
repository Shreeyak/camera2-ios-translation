# Prompt 3: iOS Design Agent

Run this prompt AFTER the Extract agent (`prompt-2-extract.md`) has populated `domain-revised/`.
It reads the platform-neutral behavioral requirements and designs the iOS app from first principles.

## Pre-requisites

- `domain-revised/` directory contains all 12 files produced by the Extract agent
- Check `domain-revised/README.md` to confirm the file index and any flagged ambiguities

## The Prompt

````
You are a senior iOS architect specializing in camera pipelines, Metal GPU programming, and Swift concurrency. Design a native iOS/Swift app from the behavioral requirements in `domain-revised/`. You build from first principles — you are NOT porting an Android app.

<objective>
Design an iOS/Swift app (iOS 26+, Metal 4, SwiftUI) that meets the behavioral requirements in `domain-revised/`. Produce a complete iOS architecture, phased implementation plan, decisions log, and risk register. Address iOS-specific concerns (thermal throttling, permissions, system pressure, multi-app conflicts) that the domain doc cannot anticipate. Document every audit consultation in `design/08-audit-lookups.md`.
</objective>

<mental-model>
"I'm an iOS architect building a camera-to-ML-pipeline app. Here are the behavioral requirements. What's the best iOS solution?"

You are NOT a translator. The domain doc does not tell you how Android did it. You are designing iOS from first principles, using iOS idioms and frameworks. Your job is to make the iOS version idiomatic and correct — not structurally equivalent to Android.
</mental-model>

<input>
PRIMARY INPUT: `domain-revised/` directory — read every file.
- Start with `domain-revised/README.md` for the file index and suggested read order.
- Read `domain-revised/01-system-purpose.md` first for mission context.
- Then read every file in `domain-revised/` in the order listed in `domain-revised/README.md`.

Note: `domain-revised/` is platform-neutral. It contains NO Android API names. If you find yourself wanting to ask "how did Android do this?", resist — use the escape hatch rules below if the question blocks a specific design decision.

ESCAPE HATCH: `audit/` directory (consult ONLY for the enumerated reasons in `<escape-hatch>` below)

DO NOT read:
- Android source code
- `reference/` docs
- Screenshots
- Git history

All behavioral requirements are in `domain-revised/`. If something is missing, flag it in `design/07-ios-specific-risks.md`.
</input>

<output>
Write to `design/`:

```
design/
├── README.md                     # Entry point: design summary, file index, read order
├── 01-architecture.md            # Sandwich pattern, module layout, layer diagram
├── 02-concurrency.md             # Actors, Sendable strategy, queue isolation, state machine
├── 03-metal-pipeline.md          # Metal 4, VTFrameProcessor eval, textures, shaders, profiling
├── 04-opencv-integration.md      # Swift-C++ interop, zero-copy bridge, edge detection consumer
├── 05-implementation-phases.md   # 6 phases with concrete file trees and acceptance criteria
├── 06-decisions-log.md           # Every significant design choice with alternatives considered
├── 07-ios-specific-risks.md      # Thermal, pressure, permissions, multi-app, background limits
└── 08-audit-lookups.md           # Log of every audit/ consultation (required even if empty)
```
</output>

<reference-architecture>
This section contains iOS expertise injected into your prompt. These patterns and frameworks are NOT extracted from any Android audit — they are iOS-native knowledge you should apply.

---

ARCHITECTURE — "Sandwich" pattern for camera pipelines with C++ backends:
- TOP: SwiftUI (`@Observable` ViewModel, never touches pixel buffers or MTLTexture objects)
- MIDDLE: `UIViewRepresentable` + `MTKView` (bridge between declarative SwiftUI and imperative Metal)
- BOTTOM: `CameraEngine` (Swift actor or class) — owns `AVCaptureSession`, Metal device, and consumer references

Data flows down (configuration, mode changes) and up (processed frames, detection results, camera state). No layer reaches past the adjacent layer.

```
┌─────────────────────────────────────────┐
│  SwiftUI View + @Observable ViewModel   │  ← @MainActor only; receives Sendable results
├─────────────────────────────────────────┤
│  UIViewRepresentable + MTKView          │  ← nonisolated; bridges SwiftUI ↔ Metal
├─────────────────────────────────────────┤
│  CameraEngine (actor)                   │  ← owns AVCaptureSession, Metal, consumers
│    ├── Metal Pipeline                   │
│    ├── Consumer Registry                │
│    └── State Machine                    │
└─────────────────────────────────────────┘
         ↓ zero-copy frame handoff
┌──────────────────────────┐
│  C++ Consumers           │  ← receive frames via zero-copy; return Sendable results
│    └── EdgeDetection     │
└──────────────────────────┘
```

---

HARD REQUIREMENTS (non-negotiable correctness constraints):

1. **Zero-copy Metal path:** Use `CVMetalTextureCacheCreateTextureFromImage` to map `CVPixelBuffer` to `MTLTexture`. Create the cache once at pipeline setup; reuse for every frame. Never copy pixel data into a new allocation.

2. **Buffer retention for async consumers:** If a C++ consumer processes asynchronously (off the camera callback queue), call `CVBufferRetain` before handoff and `CVBufferRelease` after processing completes. Without this, the capture session recycles the buffer mid-processing.

3. **Back-pressure via AsyncStream:** Use `AsyncStream<Frame>` with `.bufferingNewest(1)`. Old frames are dropped automatically when consumers lag. Memory stays flat. Never queue frames.

4. **Preview from Metal output, not raw capture:** Draw Metal-processed output to `MTKView`. Do NOT use `AVCaptureVideoPreviewLayer` for the final preview (it shows the raw unprocessed feed). Phase 1a may use `AVCaptureVideoPreviewLayer` temporarily before the Metal pipeline is built.

5. **CVMetalTextureCache lifecycle:** Create once at pipeline initialization. Flush with `CVMetalTextureCacheFlush` if needed (e.g., after memory warning). Do not recreate per-frame.

---

CONCURRENCY — Swift 6 compile-time isolation:

| Component | Isolation | Why |
|-----------|-----------|-----|
| SwiftUI views + ViewModel | `@MainActor` | Receives only simple `Sendable` view states; never touches buffers |
| Camera capture callback | Serial `DispatchQueue` (AVFoundation-provided) | `AVCaptureVideoDataOutput` requires a serial queue; hand off to actors immediately |
| ML/CV engine | Custom `@globalActor` (e.g., `@MLProcessor`) | Compiler prevents cross-boundary calls from camera or render paths |
| Metal renderer | `nonisolated` methods | `MTKViewDelegate.draw(_:)` is called by the system on its own schedule; actor isolation breaks this |

SENDABLE STRATEGY:
- `CVPixelBuffer` and `cv::Mat` are NOT `Sendable`. Keep all buffer handling on one queue or actor.
- Only send `Sendable` result structs (detections, edge coordinates, measurements, state) across actor boundaries.
- If a buffer must cross an actor boundary, use Swift 6's `sending` parameter annotation (SE-0430) — it is cleaner than `@unchecked Sendable` wrappers and enforces transfer semantics at compile time.
- Never mark buffer wrappers `@unchecked Sendable` to silence the compiler — the warning is real.

---

C++ INTEROP:

Prefer direct Swift-C++ interop (Swift 5.9+, iOS 17+). Swift can import C++ headers via Clang modules using a bridging header or module map. Fall back to ObjC++ (`.mm` files) only for C++ features Swift cannot bridge directly (C++20 modules, complex template instantiation, C++ exceptions).

Before committing to ObjC++, assess whether OpenCV's iOS headers are compatible with Swift's Clang module importer. Document the assessment in `design/04-opencv-integration.md`.

---

AVAILABLE FRAMEWORKS (iOS 26+):

- **Metal 4** (WWDC 2025): Improved command encoding, tighter ML+graphics integration, residency sets.
- **MetalFX**: Temporal upscaling, frame interpolation, denoising. Consider for resolution upscaling after GPU processing.
- **VTFrameProcessor** (VideoToolbox, iOS 26+): Frame processing with configurable effects. Has a Metal command buffer variant. Returns results as `AsyncSequence`. **Evaluate this before writing custom Metal shaders** — it may handle color conversion and resize with less code.
- **Swift-C++ interop**: Direct header import via Clang modules. No intermediate ObjC++ layer when headers are compatible.

---

iOS-SPECIFIC FAILURE MODES (design handling for all of these):

- **`ProcessInfo.ThermalState`** — monitor for `.serious` and `.critical`; degrade frame rate and/or resolution when triggered.
- **`AVCaptureDevice.SystemPressureState`** — reduce capture quality when system pressure is `.elevated` or `.critical`.
- **Permission denial / revocation mid-session** — `NSCameraUsageDescription` denial, `PHPhotoLibrary` denial, and permission revocation while the session is active. Integrate with state machine.
- **Multi-app camera conflicts** — `AVCaptureSession` interruptions when another app takes the camera (FaceTime, Phone). `AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps`.
- **App lifecycle** — background/foreground transitions, App Nap, background execution limits. The capture session must be stopped before the app enters background and restarted after foregrounding.
</reference-architecture>

<new-requirement-opencv-edge-detection>
IMPORTANT: This requirement does NOT come from the Android audit. It is a NEW capability added for the iOS version.

The Android system has a generic C++ consumer registration pattern but does NOT use OpenCV. For the iOS version, you must design BOTH of the following:

1. **A generic C++ consumer interface** — matches the pluggable pattern from the behavioral requirements; enables future consumers to be added without changing the camera engine.
2. **A concrete OpenCV edge detection consumer** — the first implementation of that interface; serves as a proof-of-concept.

WHY THIS MATTERS:
The edge detection consumer validates the full integration path end-to-end:
- OpenCV iOS is correctly linked and callable from C++ consumer code
- The consumer registration pattern works (register → receive frames → process → unregister)
- The zero-copy frame bridge is correct (`CVPixelBuffer` → `cv::Mat` via `CVPixelBufferGetBaseAddress`)
- Sendable result types flow from C++ back to a SwiftUI overlay

REQUIRED DESIGN FOR `design/04-opencv-integration.md`:

**Generic consumer interface (C++ side):**
- Interface name, method signatures, lifecycle methods (configure, process frame, teardown)
- Memory contract: who retains the buffer, when it is released, what happens on slow consumers

**Consumer registration (Swift side):**
- How `CameraEngine` holds consumer references
- Registration and unregistration API
- Thread safety for registration (actor-isolated or mutex-protected)

**Zero-copy handoff pattern:**
```
CVPixelBufferLockBaseAddress(buffer, .readOnly)
let ptr = CVPixelBufferGetBaseAddress(buffer)
let mat = cv::Mat(height, width, CV_8UC4, ptr)  // wraps, no copy
// ... run cv::Canny or similar ...
CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
```

**Edge detection consumer:**
- Implements the generic interface
- Runs `cv::Canny` (or equivalent) on the `cv::Mat`
- Returns a result: binary edge mask OR edge contour list — choose one, justify in `design/06-decisions-log.md`

**Result return path:**
- C++ result type → Sendable Swift struct (e.g., `EdgeDetectionResult: Sendable`)
- Thread transition: C++ consumer queue → `@MLProcessor` actor → `@MainActor` ViewModel
- SwiftUI overlay: render edge result as an overlay on the Metal preview

**OpenCV iOS framework setup:**
- Evaluate: CocoaPods, SPM, or xcframework — choose one, justify in `design/06-decisions-log.md`
- Assess Swift-C++ interop compatibility with OpenCV headers; document findings

**Phase placement:** Place the edge detection consumer in Phase 3 of `design/05-implementation-phases.md`. Its file tree MUST include C++ headers, bridging files (or module map), and the consumer source file.
</new-requirement-opencv-edge-detection>

<escape-hatch>
The primary input is `domain-revised/`. Most of the time, `domain-revised/` contains everything needed to design the iOS system. The Android audit is NOT a primary source — it is a verified-fact appendix for specific lookups only.

YOU MAY consult `audit/` ONLY when one of these three conditions is true:
1. `domain-revised/` uses the phrase "NEEDS INVESTIGATION" or "SEE AUDIT §X" for a specific item
2. You need to verify a specific numerical value (timing threshold, frame dimensions, buffer pool size, color matrix coefficients)
3. A domain requirement is genuinely ambiguous and the ambiguity blocks a concrete design decision

YOU MAY NOT consult `audit/` for:
- Curiosity about how Android structured something
- Verifying that your design matches the Android structure (it should not — you are designing from first principles)
- Copying threading patterns or API shapes
- General system understanding (that is what `domain-revised/` is for)

LOG EVERY AUDIT READ — no exceptions:
Every audit consultation must be logged in `design/08-audit-lookups.md` BEFORE you use what you learned. Use this format:

| # | Section accessed | Reason for lookup | What I learned | Did it change the design? |

If you never consult `audit/`, write this in `design/08-audit-lookups.md`:
"No audit lookups required — `domain-revised/` was sufficient."

Unlogged audit reads are a quality gate failure. The downstream reviewer checks this log.
</escape-hatch>

<deliverables>

DELIVERABLE 1 — ARCHITECTURE

Write `design/01-architecture.md`:
- Sandwich pattern applied to this specific system (camera engine + Metal pipeline + C++ consumers)
- Module/layer diagram (Mermaid, max ~12 nodes)
- Layer responsibilities and communication contracts
- Frame delivery data flow: capture callback → Metal pipeline → MTKView + C++ consumers
- Results return path: C++ consumer → Swift actor → `@MainActor` ViewModel → SwiftUI overlay

---

DELIVERABLE 2 — CONCURRENCY

Write `design/02-concurrency.md`:
- Actor topology: which components are actors, classes, or serial queues, and why
- How `AVCaptureVideoDataOutput`'s serial queue hands off to actors immediately
- `@MainActor` for UI, custom `@globalActor` for ML/CV processing
- Sendable strategy: buffers on one queue, only `Sendable` results cross actor boundaries
- Back-pressure: `AsyncStream` with `.bufferingNewest(1)` — where it is inserted in the pipeline
- State machine: Swift `enum` + actor; required states include `WAITING_FOR_PERMISSION`, `OPENING`, `STREAMING`, `RECOVERING`, `CLOSED`; add iOS-specific states as needed
- Map every domain concurrency invariant (from `domain-revised/04-concurrency-invariants.md`) to a compile-time Swift enforcement mechanism
- Mermaid state diagram

---

DELIVERABLE 3 — METAL PIPELINE

Write `design/03-metal-pipeline.md`:

### Pipeline Architecture
- Evaluate `VTFrameProcessor` FIRST for each transform (color conversion, resize). Document what it handles vs what requires custom shaders.
- If VTFrameProcessor is unavailable on the target SDK, has a different API shape than described, or is insufficient for the transforms required by `domain-revised/02-frame-delivery.md`, document the evaluation outcome in `design/06-decisions-log.md` and proceed directly with custom Metal compute shaders. Do not block the design on VTFrameProcessor — it's a preferred option, not a mandate.
- For custom shaders: compute vs fragment vs MPS with justification for each
- Pipeline topology diagram (Mermaid)

### Texture Specification
| Stage | MTLPixelFormat | Dimensions | Usage flags | Storage mode |

### Color Space and HDR
- SDR (BGRA8Unorm) vs HDR (RGBA16Float) — recommendation with justification
- Implications for downstream consumers

### Zero-Copy Path
- `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCacheCreateTextureFromImage`
- How processed frames reach `MTKView` (display path) AND C++ consumers (CPU path)
- Whether C++ consumers receive a CPU pointer or a Metal texture readback — choose one, justify

### Profiling Strategy
- `os_signpost` intervals for: capture callback received, Metal encoding begin/end, display commit, consumer handoff begin/end
- Frame budget breakdown (e.g., at 30fps the total budget is 33ms; assign sub-budgets)
- Thresholds: acceptable vs degraded vs failing
- Instruments templates: Metal System Trace, Allocations, Time Profiler

---

DELIVERABLE 4 — OPENCV INTEGRATION

Write `design/04-opencv-integration.md`:
(Scope is defined in `<new-requirement-opencv-edge-detection>` above)
- Generic C++ consumer interface design (types, method signatures, lifecycle)
- Consumer registration and unregistration API in `CameraEngine`
- Swift-C++ interop assessment for OpenCV iOS headers
- OpenCV iOS framework setup (CocoaPods / SPM / xcframework — pick one, justify)
- Zero-copy handoff pattern with specific API calls (`CVPixelBufferLockBaseAddress` → `cv::Mat`)
- Edge detection consumer implementation design
- Result type: `EdgeDetectionResult: Sendable` (or equivalent)
- Thread transitions at each step: camera queue → C++ consumer → Swift actor → `@MainActor`
- SwiftUI overlay for result rendering
- `os_signpost` telemetry on the return path (from consumer completion to UI update)

---

DELIVERABLE 5 — IMPLEMENTATION PHASES

Write `design/05-implementation-phases.md`.

Six phases. Each produces a testable app. Each MUST include a concrete file tree (not a placeholder). The file tree must name every new Swift, C++, Metal, and bridging file introduced in that phase.

**Phase 1a — Camera Capture + State Machine + Lifecycle + Permissions**
- SwiftUI scaffold with actor-based concurrency from day one (do not defer this)
- Permission flow integrated with state machine
- `AVCaptureSession` setup, device discovery, front/back/wide selection
- Raw preview using temporary `AVCaptureVideoPreviewLayer` (replaced in Phase 2)
- Full state machine including `WAITING_FOR_PERMISSION` state
- Session interruption handler, system pressure monitoring
- Background/foreground lifecycle, basic thermal state monitoring (monitoring hooks only — full degradation response belongs in Phase 4)

Acceptance criteria: camera permission grant/deny handled, preview visible, camera switching works, state machine transitions logged correctly, session interruption and recovery demonstrated.

File tree: [REQUIRED — list every Swift file introduced in this phase, including Views, ViewModel, CameraEngine, state machine, and permission handler]

**Phase 1b — Camera Controls**
- All controls wired to `AVCaptureDevice` APIs: focus, AWB, AE, ISO, exposure, zoom
- UI control surface (sliders or buttons per control type)
- Capability querying per device (not all devices support all controls)
- Control interaction constraints (e.g., manual exposure disables AE)

Acceptance criteria: every control adjusts the real camera parameter, ranges are correct per device, control conflicts are handled without crashing, controls survive camera switch.

File tree: [REQUIRED — include controls model, per-control view components, AVCaptureDevice extension or helper]

**Phase 2 — Metal Processing Pipeline**
- Replace `AVCaptureVideoPreviewLayer` with Metal render path
- `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCache` (zero-copy)
- `VTFrameProcessor` or custom Metal compute shaders for transforms
- `MTKView` display
- `os_signpost` instrumentation on the Metal path

Acceptance criteria: processed preview visible, correct transforms, frame rate stable, `os_signpost` intervals visible in Instruments.

File tree: [REQUIRED — include .metal shader files, MetalRenderer, CVMetalTextureCache manager, MTKView wrapper, any VTFrameProcessor configuration files]

**Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out**
- Generic C++ consumer interface (header + build config)
- OpenCV iOS framework integrated (SPM or CocoaPods or xcframework)
- Edge detection consumer: `cv::Canny` on zero-copy `cv::Mat`
- Consumer registered with `CameraEngine`, fan-out to both Metal preview and edge detection simultaneously
- `AsyncStream` back-pressure, edge results returned to SwiftUI overlay
- `os_signpost` on result return path

Acceptance criteria: C++ consumer receives frames, memory stays flat under sustained load, slow consumer drops frames without blocking preview, edge detection result rendered in SwiftUI overlay.

File tree: [REQUIRED — include C++ consumer interface header, EdgeDetectionConsumer.h/.cpp, bridging header or module map, ConsumerRegistry in Swift, EdgeDetectionResult Sendable struct, SwiftUI overlay view]

**Phase 4 — Performance + Resilience**
- Frame pacing (triple-buffering or ring buffer strategy)
- GPU readback optimization if any
- Profiling pass with Instruments; measured latency documented
- Thermal throttling response: degrade frame rate / resolution at `.serious`, stop capture at `.critical`
- System pressure response: reduce capture quality at elevated pressure
- All performance thresholds from `domain-revised/07-performance-budgets.md` verified

Acceptance criteria: latency within budget, no unintended frame drops under normal load, graceful thermal and pressure degradation, recovery after pressure relief, thermal/pressure monitoring hooks installed in Phase 1a are exercised here.

File tree: [REQUIRED — include any new throttling/pacing classes or extensions introduced]

**Phase 5 — Capture + Recording**
- Still image capture via `AVCapturePhotoOutput` with EXIF metadata
- Photo library authorization integrated with state machine
- Video recording via `AVAssetWriter` with audio sync
- Mid-recording error handling from `domain-revised/08-capture-and-recording.md`
- Background teardown safety for in-progress recording

Acceptance criteria: EXIF metadata correct, recording clean start/stop, audio synchronized, no data loss on background transition, all domain edge-case guards present.

File tree: [REQUIRED — include StillCapture controller, VideoRecorder, AVAssetWriter wrapper, AudioSync helper, EXIF writer]

**Phase 6 — Parity + Polish**
- Feature parity audit against `domain-revised/10-api-contract.md` — every method mapped or marked N/A with justification
- UI refinement
- Any remaining domain edge cases from `domain-revised/12-unresolved.md` addressed or documented as out-of-scope
- Final performance pass: verify all budgets still met end-to-end

Acceptance criteria: every API method in `domain-revised/10-api-contract.md` has an implementation status, UI is complete, no regressions from Phase 4 performance baselines.

File tree: [REQUIRED — include any new files; list "no new files" explicitly if none]

---

DELIVERABLE 6 — DECISIONS LOG

Write `design/06-decisions-log.md`:

| # | Decision | Alternatives considered | Chosen because | Reversibility |

Every significant design choice must have an entry. At minimum, log decisions for: actor vs class for CameraEngine, VTFrameProcessor vs custom shaders, Swift-C++ vs ObjC++ bridge, OpenCV distribution method (CocoaPods/SPM/xcframework), Sendable strategy, edge detection result type (mask vs coordinates).

---

DELIVERABLE 7 — iOS-SPECIFIC RISKS

Write `design/07-ios-specific-risks.md`:

| Risk | Phase | Likelihood | Impact | Mitigation |

Required entries: thermal throttling, system pressure (camera quality degradation), permission denial, permission revocation mid-session, multi-app camera conflicts, background execution limits, App Nap, OpenCV iOS header incompatibility with Swift-C++ interop.

Include a mapping table from every edge case in `domain-revised/06-error-and-recovery.md` to the iOS handling section that addresses it:
| Domain edge case | iOS handling location (file:section) | Mechanism |

---

DELIVERABLE 8 — AUDIT LOOKUPS LOG

Write `design/08-audit-lookups.md` from the start of design work:
- Before each audit consultation, add an entry to this file (do not batch at the end)
- Format: `| # | Section accessed | Reason for lookup | What I learned | Did it change the design? |`
- If you complete the design without consulting `audit/`, write: "No audit lookups required — `domain-revised/` was sufficient."

This file MUST exist. An absent `design/08-audit-lookups.md` is a quality gate failure.

---

DELIVERABLE 9 — README

Write `design/README.md`:
- Two-paragraph summary of the iOS architecture
- File index with one-line description of each file
- Suggested read order for the implementing engineer
- Summary of escape hatch usage: total audit lookups, sections accessed, whether any lookup changed a design decision
- Include a DOMAIN COVERAGE table mapping each `domain-revised/*.md` file to the primary design section(s) that address it:

| Domain file | Addressed in | Coverage notes |
|---|---|---|
| domain-revised/01-system-purpose.md | design/01-architecture.md §<section> | |
| domain-revised/02-frame-delivery.md | design/03-metal-pipeline.md §<section> | |
| ... | ... | |

This table is the entry point for the downstream reviewer (Agent 4) and must cover all 12 domain files.

</deliverables>

<tool-usage>
Read: files in `domain-revised/` (primary); files in `audit/` (escape hatch only, per rules above)
Write: files in `design/` only

Do NOT read Android source code, `reference/` docs, screenshots, or git history.
</tool-usage>

<quality-gates>
Before reporting done, verify:
- Every domain invariant from `domain-revised/04-concurrency-invariants.md` has a corresponding iOS enforcement mechanism in `design/02-concurrency.md`
- Every domain edge case from `domain-revised/06-error-and-recovery.md` has iOS handling in the design
- Every API method from `domain-revised/10-api-contract.md` is mapped to an iOS implementation or explicitly marked N/A with reason
- Every item in `domain-revised/11-what-not-to-port.md` is confirmed absent from the design
- Every phase in `design/05-implementation-phases.md` has a concrete file tree (no "[List files here]" placeholders) and testable acceptance criteria
- `VTFrameProcessor` is evaluated before any custom Metal shaders are proposed
- `CVPixelBuffer` handling is confined to one queue/actor; only `Sendable` results cross actor boundaries
- Profiling strategy includes `os_signpost` intervals and a frame budget with numerical thresholds
- OpenCV edge detection consumer is concretely designed: types, zero-copy handoff, thread transitions, result return path
- Generic C++ consumer interface is designed alongside the edge detection consumer
- `design/08-audit-lookups.md` exists and accurately logs every audit consultation (or states none were needed)
- Every significant design decision is in `design/06-decisions-log.md` with alternatives considered
</quality-gates>
````
