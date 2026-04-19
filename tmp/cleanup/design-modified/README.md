# iOS Design: Camera-to-ML-Pipeline

## Architecture Summary

**Targets:** Swift 6+, iOS/iPadOS 26+, iPad primary (A16).

The project is a **SwiftPM package** (`Package.swift` at the root) with a thin `EvaApp/` shell and eight library targets under `Sources/`:

- **`EvaCore`** (Swift) — SwiftUI views, `@Observable` view models, Inspector window, edge overlay view (MTKView with pan/zoom). Opts into SE-0466 default `@MainActor` isolation.
- **`CaptureKit`** (Swift) — `CaptureActor` (serial actor); owns `AVCaptureSession`, device KVO → `AsyncStream` adapter (`DeviceStateStream`), `SessionStateMachine`. AVFoundation only — no Metal, no C++.
- **`PipelineKit`** (Swift + Metal) — `FramePipeline` (command buffer orchestration), `TexturePoolManager`, `MetalRenderer`, `Shaders.metal`, `StallWatchdog`, `ThermalMonitor`. No AVFoundation, no C++.
- **`EncoderKit`** (Swift) — `RecordingActor` (HEVC 8-bit via AVAssetWriter), `StillWriter` (8-bit 3-channel TIFF), `EXIFWriter`, `PhotoLibraryWriter`.
- **`Interop`** (Swift) — Swift facade over `ImagingCore`; `PixelSinkFacade`, `EdgeDetectorFacade` (both wrapping `SWIFT_SHARED_REFERENCE`-annotated C++ classes), `EdgeResult` (Sendable), `MLProcessor` (@globalActor). Only module that enables `.interoperabilityMode(.Cxx)` besides `ImagingCore` itself.
- **`ImagingCore`** (C++ only, Apple-free) — `PixelSink` (C++ thread pool with per-stream 1-slot mailbox), `EdgeDetector` (subscribes to PixelSink, runs Canny, composites edges onto tracker image, writes to shared MTLTexture). OpenCV is private to `src/*.cpp` and banned from all public headers. Independently testable via `swift test`.
- **`TestingSupport`** (Swift) — synthetic frame provider via `AVAssetReader` for deterministic CI replay without a physical camera.

The iOS design uses the **Sandwich pattern**: declarative UI (`EvaCore`, `@MainActor`), imperative GPU pipeline (`PipelineKit`, `nonisolated` on camera delivery queue), camera session management (`CaptureKit`, `CaptureActor`), and a C++ processing core (`ImagingCore`, own thread pool). Data flows down as `Sendable` command types; results flow up as `Sendable` value structs via `AsyncStream` and C-ABI callbacks. No layer reaches past its adjacent neighbor; no pixel data crosses into `@MainActor` code.

**Capture format:** `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange` (lossless hardware-compressed 8-bit YCbCr 4:2:0, full range). The device does not support 10-bit, 12-bit, or half-float capture output — verified on A16 hardware. Metal Pass 1 crops the full-sensor input to a user-defined region and converts YUV → RGBA16F (BT.709). **Working format** is RGBA16F (half-float) throughout the GPU pipeline for precision preservation across the 5-stage color-transform chain (see D-18). **Recording** is HEVC 8-bit via a `rgba16f_to_yuv8` compute pass (device only supports 8-bit output). **Still capture** is 8-bit 3-channel TIFF. C++ consumers receive frames as IOSurface-backed RGBA16F textures via the `PixelSink`. **There is no Objective-C++ layer.** The entire design is iOS-native — it does not replicate any Android construct.

---

## Non-Goals

The following are explicitly out of scope for v1:

- Multi-camera simultaneous capture (`AVCaptureMultiCamSession`). A16 has a single rear wide camera.
- OpenGL ES fallback. Metal-only.
- Audio capture or recording. Recordings are silent video tracks only.
- Background recording. Session stops on background; no `BGTaskScheduler` for capture.
- External display output. iPadOS 26 supports it but it is not a product requirement.
- DICOM / WSI tile file format I/O.
- On-device ML inference inside the color-transform pipeline.
- Full adaptive thermal throttling. v1 shows a banner only; adaptive degradation is deferred.
- Capture Controls API (hardware button triggers). Deferred.

---

## File Index

| File | Description |
|---|---|
| `README.md` | This file — architecture summary, file index, read order, domain coverage |
| `01-architecture.md` | Sandwich pattern layers, module layout, Mermaid layer diagram, frame delivery and result return sequence diagrams |
| `02-concurrency.md` | Actor topology, all 11 domain invariant mappings to Swift mechanisms, Sendable strategy, back-pressure via C++ PixelSink, state machine diagram, iOS-specific lifecycle states |
| `03-metal-pipeline.md` | VTFrameProcessor evaluation (not used), 6-pass Metal command graph (crop+YUV→RGB, color transform, preview, Lanczos downscale, encoder conversion, still readback), texture spec table, zero-copy path, GPU-to-encoder path, profiling strategy |
| `04-opencv-integration.md` | `PixelSink` + `EdgeDetector` C++ classes (`SWIFT_SHARED_REFERENCE`), C++ thread pool with 1-slot mailbox, IOSurface-based zero-copy, edge compositing in C++, shared MTLTexture for pan/zoom overlay, `EdgeResult` with status + contour list, OpenCV as SwiftPM `binaryTarget` |
| `05-implementation-phases.md` | Seven phases with concrete file trees and acceptance criteria; API contract coverage table |
| `06-decisions-log.md` | 27 significant design decisions with alternatives considered and reversibility |
| `07-ios-specific-risks.md` | Risk register; domain error-case → iOS handling mapping table; domain/11 "not to port" confirmation table; NEEDS INVESTIGATION items |
| `08-audit-lookups.md` | No audit lookups required — all requirements satisfied from domain/ |
| `09-architecture-diagrams.md` | Mermaid reference companion: 5 architecture/flow diagrams + 5 sequence diagrams |
| `diagrams/` | Pre-rendered Mermaid sidecars — 10 `.mmd` sources + 10 `.png` files |
| `diagrams-d2/` | Parallel D2 authoring of the same 10 diagrams |

---

## Suggested Read Order (for implementing engineer)

1. **`README.md`** (this file) — orientation, non-goals, domain coverage
2. **`01-architecture.md`** — understand the module layout and layer communication contracts
3. **`02-concurrency.md`** — read the invariant mapping table; every actor, queue, and C++ thread in the system is explained here
4. **`03-metal-pipeline.md`** — understand the 6-pass GPU command graph, zero-copy path, and frame budget
5. **`04-opencv-integration.md`** — PixelSink + EdgeDetector architecture, C++ thread pool, edge compositing; critical for Phase 3
6. **`05-implementation-phases.md`** — implementation order; start with Phase 0 package scaffolding
7. **`06-decisions-log.md`** — read when a decision seems questionable; alternatives are documented
8. **`07-ios-specific-risks.md`** — check the NEEDS INVESTIGATION items before starting Phase 1b and Phase 5
9. **`09-architecture-diagrams.md`** — visual companion; use alongside 01–04

---

## Escape Hatch Usage Summary

| Metric | Value |
|---|---|
| Total audit lookups | 0 |
| Audit sections accessed | None |
| Lookups that changed a design decision | 0 |

`domain/` was sufficient to produce the complete iOS design. All 12 domain files were read in the order specified by `domain/README.md`. No escape-hatch audit consultation was required.

---

## Domain Coverage Table

| Domain file | Addressed in | Coverage notes |
|---|---|---|
| `domain/01-system-purpose.md` | `design/01-architecture.md §Overview`, `§Layer Responsibilities`, `§Key Architectural Invariants (iOS mapping)` | All 6 missions mapped to iOS components; session model (single session, back-facing main) addressed |
| `domain/02-frame-delivery.md` | `design/03-metal-pipeline.md §Per-Frame Command Graph`, `§Tracker Dimension Formula`, `design/02-concurrency.md §Invariant 10` | 6-pass command graph mapped to Metal; 3 output streams (processed, tracker, natural) + encoder; drop-on-busy via PixelSink 1-slot mailbox; stall detection in `StallWatchdog` |
| `domain/03-camera-control.md` | `design/05-implementation-phases.md §Phase 1b`, `design/06-decisions-log.md D-13`, `design/07-ios-specific-risks.md R-19, R-20` | All controls mapped; ISO/exposure coupling; diopter convention deviation documented; AE convergence timeout |
| `domain/04-concurrency-invariants.md` | `design/02-concurrency.md §Domain Invariant Mapping` | All 11 invariants individually mapped to Swift actors, C++ PixelSink thread pool, `sending`, `Task` |
| `domain/05-resource-lifecycle.md` | `design/02-concurrency.md §Invariant 4`, `design/05-implementation-phases.md §Phase 1a`, `design/07-ios-specific-risks.md R-05, R-06` | 6-step init order; 8-step full teardown; session-only teardown; GPU release safety (actor isolation); self-healing in Phase 6 |
| `domain/06-error-and-recovery.md` | `design/07-ios-specific-risks.md §Domain Edge Case → iOS Handling Mapping`, `design/02-concurrency.md §Invariant 9` | All 19 error codes mapped; all recovery paths; exponential backoff via `Task.sleep` in `CaptureActor`; recovery cancellation via `Task.cancel()` |
| `domain/07-performance-budgets.md` | `design/03-metal-pipeline.md §Frame Budget`, `design/04-opencv-integration.md §os_signpost`, `design/05-implementation-phases.md §Phase 4 Acceptance Criteria` | All numerical thresholds reproduced; `os_signpost` on all intervals; frame budget table |
| `domain/08-capture-and-recording.md` | `design/05-implementation-phases.md §Phase 5`, `design/03-metal-pipeline.md §GPU-to-Encoder Path` | Both still capture paths; EXIF requirements; HEVC 8-bit codec; recording state machine; drain timeout (5s); **video-only** recording (audio out of scope) |
| `domain/09-ui-behaviors.md` | `design/01-architecture.md §Module Layout (EvaCore/)`, `design/05-implementation-phases.md §Phase 1a, 1b, 5, 6` | Split-screen preview; bottom bar (5 controls); expanded controls bar; color calibration sidebar; recording indicator; capture banner; state-driven UI; landscape-only |
| `domain/10-api-contract.md` | `design/05-implementation-phases.md §Phase 6 API Contract Coverage Table` | All 7 data types mapped to Swift structs/enums; all 16 host methods mapped to Swift implementations; all 4 callbacks via `AsyncStream` |
| `domain/11-what-not-to-port.md` | `design/07-ios-specific-risks.md §Domain/11 "What Not to Port" — Confirmation of Absence` | All 21 items confirmed absent from iOS design with replacement mechanism named |
| `domain/12-unresolved.md` | `design/02-concurrency.md §iOS-Specific Concurrency States`, `design/06-decisions-log.md D-08, D-13, D-14`, `design/07-ios-specific-risks.md §NEEDS INVESTIGATION` | All unresolved items resolved or documented as deviations |
