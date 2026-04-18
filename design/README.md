# Design — Native iOS / Swift 6 / Metal Architecture

## Summary

This design realizes the camera-to-ML-pipeline behaviors specified in `domain-revised/`
as a native iOS 26+ / Swift 6.2 / Metal 3 app. The architectural core is a
two-isolation-domain model (`@MainActor` UI + `actor CameraEngine` state) in which
the 30 Hz capture-to-Metal-to-consumer path runs on a dedicated serial
`DispatchQueue` without hopping any Swift actor boundary (ADR-02, ADR-10). A single
`MTLCommandBuffer` per frame produces three IOSurface-backed output sinks (natural,
processed, tracker), each of which supports N async consumers via per-lane
latest-wins mailboxes (ADR-18, ADR-19). The three named sinks are published as one
atomic `FrameSet` unit so any consumer correlating two sinks observes a consistent
pair. Textures serving C++ PixelSink subscribers flip dynamically between `.private`
and `.shared` (IOSurface-backed) storage modes per ADR-20, avoiding the G-25 silent
drop that would otherwise occur on `.private` textures.

OpenCV is introduced as a **new iOS-only capability** (not a port) via an
edge-detection proof-of-concept consumer that validates the async-consumer path and
the Swift ↔ C++ direct-interop (ADR-11, ADR-12). Video recording uses
`AVAssetWriter` + compute-kernel RGBA16F→NV12 conversion into an IOSurface-backed
pool (ADR-06, ADR-16) with a drain deadline to protect against corrupt MP4 on
backgrounding (G-08). Still capture uses Metal readback from `processedTex` — **not**
`AVCapturePhotoOutput` — so the captured image exactly matches the processed
preview (domain §01 invariant 1). Audio is deliberately absent end-to-end (G-12,
G-24); the 12 domain concurrency invariants are each mapped to a structural iOS
mechanism (actor, atomic, DispatchQueue, or Apple-API guarantee) in design/02 §6.

## File Index

| File | One-line description |
|---|---|
| `README.md` | This file — summary, read order, domain coverage |
| `01-architecture.md` | iOS module/layer diagram, FrameSet frame path, results return path |
| `02-concurrency.md` | Actor topology, sessionQueue/deliveryQueue, state machine, Sendable strategy, lockForConfiguration bracket, domain-invariant mapping |
| `03-metal-pipeline.md` | Per-frame command graph, shader types, texture spec table (storage-mode discipline), 3 CVPixelBufferPools, profiling |
| `04-opencv-integration.md` | `PixelSink` interface, OpenCV xcframework, zero-copy IOSurface handoff, shared canny texture, pan/zoom render |
| `05-implementation-phases.md` | Six phases with concrete file trees and testable acceptance criteria |
| `06-decisions-log.md` | D-01 to D-09 product decisions, each citing followed/deviated ADRs |
| `07-ios-specific-risks.md` | 21 platform risks + domain edge-case mapping table |
| `08-audit-lookups.md` | Escape-hatch log (no lookups required) |

## Suggested Read Order

For an engineer implementing this design from scratch:

1. **`README.md`** (this file) — orient on scope and file structure.
2. **`01-architecture.md`** — understand the two-isolation-domain model and the
   FrameSet data flow.
3. **`02-concurrency.md`** — internalize the actor/queue topology, Sendable rules,
   and `lockForConfiguration` bracket before writing any AVFoundation code.
4. **`03-metal-pipeline.md`** — per-frame command graph and texture spec; reference
   during Phase 2.
5. **`04-opencv-integration.md`** — read before Phase 3.
6. **`05-implementation-phases.md`** — the build plan. Follow phases in order.
7. **`06-decisions-log.md`** — understand *why* each product-specific choice was
   made; revisit whenever a decision needs to be challenged.
8. **`07-ios-specific-risks.md`** — skim on first pass; return to whenever a
   new iOS behavior (thermal, interruption, permission) affects the code.
9. **`08-audit-lookups.md`** — (no reads; escape hatch unused).

## Escape Hatch Usage

- **Total audit lookups: 0.**
- **Sections accessed: none.**
- **Design decisions changed by audit lookups: none.**

`domain-revised/` (behavior) + `ios-platform-guide/` (platform) were sufficient for
every decision. Numeric thresholds required by the design (3 s GPU stall, 5 s capture
stall, 5 consecutive HW errors, 500–8000 ms backoff, 5 s drain timeout, 3-failure
surface rebind, 96×96 center patch, 480 px tracker height, default 1600×1200 crop,
largest-4:3 capture selection, `TARGET_BITRATE_MBPS` as a domain parameter) all come
directly from `domain-revised/02`, `domain-revised/05`, `domain-revised/06`, and
`domain-revised/08`.

## Domain Coverage Table

| Domain file | Addressed in | Coverage notes |
|---|---|---|
| `domain-revised/01-system-purpose.md` | `design/01-architecture.md` §1, §2, §3, §6 | Six top-level behaviors mapped to modules; four-layer topology mapped to two-isolation-domain + sessionQueue/deliveryQueue; single-session + back-facing-main-lens constraint codified in `open()` |
| `domain-revised/02-frame-delivery.md` | `design/03-metal-pipeline.md` §2–§7; `design/01-architecture.md` §4 | 30 fps target; 10-step GPU pipeline → Pass 1–6 command graph; RGBA16F working format (ADR-05); three subscribable streams via FrameSet (ADR-18); 480 px tracker; drop-on-busy mailboxes (ADR-19); metadata in FrameSet; both stall watchdogs in design/07 domain-edge-case table |
| `domain-revised/03-camera-control.md` | `design/02-concurrency.md` §4 (device configuration window); `design/05-implementation-phases.md` Phase 1b | ISO/exposure coupled via `setExposureModeCustom`; manual latches from readback → SETTINGS_CONFLICT before first readback; focus/zoom/WB each independent commits inside same lock; GPU color chain in Pass 2 in domain-required order; persistence in UserDefaults |
| `domain-revised/04-concurrency-invariants.md` | `design/02-concurrency.md` §6 (domain invariant → iOS mechanism table) | All 12 invariants mapped structurally: 1 → actor, 2 → deliveryQueue, 3 → AsyncStream to @MainActor, 4 → ARC + Unmanaged box, 5 → C++ lock order, 6 → MTLBuffer single-writer by queue, 7/8 → ManagedAtomic, 9 → Task cancellation, 10 → 1-slot mailbox, 11/12 → atomic timestamp + session token |
| `domain-revised/05-resource-lifecycle.md` | `design/02-concurrency.md` §5 (state machine); `design/05-implementation-phases.md` Phase 1a, Phase 4 | Full and session-only teardown orderings; watchdogs disarmed first; recording stopped before other resources; background recording drain (ADR-16 + G-08); preview surface rebind via MTKView drawable recreation; self-healing via AVCaptureSessionInterruptionEnded |
| `domain-revised/06-error-and-recovery.md` | `design/07-ios-specific-risks.md` §Domain Edge-Case Mapping; `design/02-concurrency.md` §5 state machine | Full error code table ported 1:1; non-fatal recovery sequence (disarm → check terminal → check suspended → transition → emit → retry check → cancel → schedule); exponential backoff schedule; HAL threshold = 5; dual stall watchdogs (3 s informational / 5 s recovery) |
| `domain-revised/07-performance-budgets.md` | `design/03-metal-pipeline.md` §8 | (Mostly stub in domain; numeric thresholds inlined elsewhere in domain.) Frame-budget sub-buckets at 30 fps; acceptable ≤ 15 ms / degraded 15–25 ms / failing > 25 ms; Instruments Metal System Trace template |
| `domain-revised/08-capture-and-recording.md` | `design/05-implementation-phases.md` Phase 5; `design/03-metal-pipeline.md` Pass 5 / Pass 6 | Still capture via Metal readback from processedTex (**not** AVCapturePhotoOutput); 8-bit TIFF via CGImageDestination; EXIF tags with CamPlugin/v1 JSON (U-09 partial); HEVC 8-bit via AVAssetWriter + NV12 IOSurface-backed pool (ADR-06, ADR-16); no audio (G-12); 5 s drain deadline; backgrounding guard is corruption-prevention (not continue-recording) |
| `domain-revised/09-ui-behaviors.md` | `design/05-implementation-phases.md` Phase 1a + Phase 6; `design/01-architecture.md` §4 | Split-screen natural/processed MTKView pair; bottom bar + expanded ISO/Shutter/Focus/Zoom; color calibration sidebar; recording indicator (MM:SS); capture confirmation banner; state-driven UI; landscape-right orientation locked |
| `domain-revised/10-api-contract.md` | `design/05-implementation-phases.md` Phase 6; `design/01-architecture.md` §3 (engine's public surface) | All 16 host methods and 4 callbacks covered; Consumer Registration API via `engine.attach(consumer:, to:)` mapped to three `StreamId`s; data types (CameraSettings, ProcessingParameters, SessionCapabilities, SessionState, ErrorCode, Error, FrameResult, RgbSample) modeled as Sendable Swift types |
| `domain-revised/11-what-not-to-port.md` | `design/06-decisions-log.md` (implicit everywhere) | Every Android-specific mechanism (HandlerThread, JNI, Pigeon, SharedPreferences, MediaStore, OpenGL ES, PBO, EGL, ProcessLifecycleOwner, camera availability callback, codec strings) is **replaced** by a native iOS equivalent in the design; the design file explicitly does not reference any Android API. D-01 through D-09 codify each of these as positive choices. OpenCV specifically is called out as a **new iOS capability**, not a port (domain §01 invariant 6) |
| `domain-revised/12-unresolved.md` | `design/07-ios-specific-risks.md` (U-09, U-11, U-16); Phase 1a/1b/5 acceptance criteria | U-08 capability discovery → `device.formats` enumeration in Phase 1a; U-09 EXIF schema → R-17 deferred to Phase 5; U-11 lensPosition → R-13 (label as "relative focus", G-11); U-16 AE FPS fallback → R-14 (empirical Phase 1b); U-18 pause-during-recording → minimum behavior per Phase 5 acceptance |
