# iOS Design: Camera-to-ML-Pipeline

## Architecture Summary

The iOS design uses the **Sandwich pattern**: a three-layer stack separating SwiftUI (`@Observable` ViewModel, `@MainActor` only), a Metal/UIKit bridge (`MTKView` via `UIViewRepresentable`, `nonisolated`), and a `CameraEngine` Swift actor (owns `AVCaptureSession`, `MTLDevice`, `ConsumerRegistry`, and `SessionStateMachine`). Data flows down as `Sendable` command types; results flow up as `Sendable` value structs via `AsyncStream`. No layer reaches past its adjacent neighbor; no pixel data ever crosses into `@MainActor` code.

The GPU pipeline uses Metal compute shaders with `CVMetalTextureCache` zero-copy (`CVPixelBuffer` → `MTLTexture` without a CPU copy) for the 5-stage color transform (black balance → brightness → contrast → saturation → gamma). A double-buffered `MTLBuffer` readback strategy provides asynchronous consumer handoff with one-frame lag. C++ consumers receive frames via a generic `IFrameConsumer` C++ interface; the first concrete implementation is an OpenCV edge detection consumer bridged through ObjC++ (`.mm` files). The entire design is iOS-native — it does not replicate any Android construct.

---

## File Index

| File | Description |
|---|---|
| `README.md` | This file — architecture summary, file index, read order, domain coverage |
| `01-architecture.md` | Sandwich pattern layers, module layout, Mermaid layer diagram, frame delivery and result return sequence diagrams |
| `02-concurrency.md` | Actor topology, all 11 domain invariant mappings to Swift mechanisms, Sendable strategy, `AsyncStream` back-pressure, state machine diagram, iOS-specific lifecycle states |
| `03-metal-pipeline.md` | VTFrameProcessor evaluation (not used), custom Metal compute shader design, texture spec table, zero-copy path, GPU-to-encoder path, profiling strategy with frame budget table |
| `04-opencv-integration.md` | Generic `IFrameConsumer` C++ interface, `ConsumerRegistry` actor, Swift-C++ interop assessment, OpenCV xcframework setup, zero-copy `cv::Mat` handoff, edge detection consumer, `EdgeDetectionResult` Sendable struct, full thread transition diagram, SwiftUI overlay |
| `05-implementation-phases.md` | Six phases with concrete file trees and acceptance criteria; API contract coverage table (all 16 methods + 4 callbacks) |
| `06-decisions-log.md` | 15 significant design decisions with alternatives considered and reversibility |
| `07-ios-specific-risks.md` | 20 risk entries; domain error-case → iOS handling mapping table; domain/11 "not to port" confirmation table; NEEDS INVESTIGATION items |
| `08-audit-lookups.md` | No audit lookups required — all requirements satisfied from domain/ |

---

## Suggested Read Order (for implementing engineer)

1. **`README.md`** (this file) — orientation and domain coverage
2. **`01-architecture.md`** — understand the three layers and communication contracts before touching any code
3. **`02-concurrency.md`** — read the invariant mapping table; every actor and queue in the system is explained here
4. **`03-metal-pipeline.md`** — understand the GPU pipeline, zero-copy path, and frame budget before writing any Metal code
5. **`04-opencv-integration.md`** — C++ consumer interface and OpenCV bridge design; critical for Phase 3
6. **`05-implementation-phases.md`** — implementation order; start with Phase 1a file tree
7. **`06-decisions-log.md`** — read when a decision seems questionable; alternatives are documented
8. **`07-ios-specific-risks.md`** — check the NEEDS INVESTIGATION items before starting Phase 1b and Phase 5

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
| `domain/02-frame-delivery.md` | `design/03-metal-pipeline.md §Per-Frame Render Sequence`, `§Parallel Stream Outputs (Tracker Dimension Formula)`, `design/02-concurrency.md §Invariant 10` | All 8 pipeline steps mapped to Metal; 4 streams (processed, tracker, natural, encoder); drop-on-busy via `AsyncStream.bufferingNewest(1)`; stall detection in `StallWatchdog` |
| `domain/03-camera-control.md` | `design/05-implementation-phases.md §Phase 1b`, `design/06-decisions-log.md D-13`, `design/07-ios-specific-risks.md R-19, R-20` | All controls mapped; ISO/exposure coupling in `ISOExposureCoupling.swift`; diopter convention deviation documented; AE convergence timeout in `AEConvergenceMonitor` |
| `domain/04-concurrency-invariants.md` | `design/02-concurrency.md §Domain Invariant Mapping` | All 11 invariants individually mapped to named Swift enforcement mechanisms (actor, `@MainActor`, atomic, `sending`, `Task`) |
| `domain/05-resource-lifecycle.md` | `design/02-concurrency.md §Invariant 4`, `design/05-implementation-phases.md §Phase 1a`, `design/07-ios-specific-risks.md R-05, R-06` | 6-step init order; 8-step full teardown; session-only teardown; GPU release safety (actor isolation = Metal context always active); self-healing in Phase 6 |
| `domain/06-error-and-recovery.md` | `design/07-ios-specific-risks.md §Domain Edge Case → iOS Handling Mapping`, `design/02-concurrency.md §Invariant 9` | All 19 error codes mapped; all recovery paths; exponential backoff via `Task.sleep` in `CameraEngine`; recovery cancellation via `Task.cancel()` |
| `domain/07-performance-budgets.md` | `design/03-metal-pipeline.md §Frame Budget`, `design/04-opencv-integration.md §os_signpost`, `design/05-implementation-phases.md §Phase 4 Acceptance Criteria` | All numerical thresholds reproduced; `os_signpost` on all intervals; frame budget table with acceptable/degraded/failing thresholds |
| `domain/08-capture-and-recording.md` | `design/05-implementation-phases.md §Phase 5`, `design/03-metal-pipeline.md §GPU-to-Encoder Path` | Both still capture paths; EXIF requirements; HEVC/H.264 codec selection; recording state machine; drain timeout (5s); **video-only** recording (audio explicitly out of scope — no `AVCaptureAudioDataOutput`, no `NSMicrophoneUsageDescription`) |
| `domain/09-ui-behaviors.md` | `design/01-architecture.md §Module Layout (UI/)`, `design/05-implementation-phases.md §Phase 1a, 1b, 5, 6` | Split-screen preview; bottom bar (5 controls); expanded controls bar; color calibration sidebar; recording indicator; capture banner; state-driven UI; landscape-only |
| `domain/10-api-contract.md` | `design/05-implementation-phases.md §Phase 6 API Contract Coverage Table` | All 7 data types mapped to Swift structs/enums; all 16 host methods mapped to Swift implementations; all 4 callbacks via `AsyncStream` |
| `domain/11-what-not-to-port.md` | `design/07-ios-specific-risks.md §Domain/11 "What Not to Port" — Confirmation of Absence` | All 21 items confirmed absent from iOS design with replacement mechanism named |
| `domain/12-unresolved.md` | `design/02-concurrency.md §iOS-Specific Concurrency States`, `design/06-decisions-log.md D-08, D-13, D-14`, `design/07-ios-specific-risks.md §NEEDS INVESTIGATION` | U-01: `PermissionManager`; U-02: Metal; U-03: `AVAssetWriter`; U-04: `MTKView`; U-05: `ThermalMonitor`; U-06: Swift actors; U-07: `scenePhase == .background`; U-08: `AVCaptureDevice.formats`; U-09: `CGImageDestination`; U-10: `videoRotationAngle`; U-11: documented deviation; U-12: N/A (front camera out of scope); U-13: natural = display-only; U-14: Metal GPU timer; U-15: 480px constant preserved; U-16: `activeVideoMinFrameDuration`; U-17: single session |
