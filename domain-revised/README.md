# Domain Specification: Camera-to-ML-Pipeline System

This directory contains platform-neutral behavioral requirements extracted from an Android camera
plugin audit. The downstream architect can use these files to design the system from first principles
on any target platform — without reading the Android source or audit.

**Source audit:** `audit/` (produced by Agent 1)
**Author:** Agent 2 (Domain Extractor)
**Date:** 2026-04-13

---

## Suggested Read Order

Read in this sequence to build understanding from high level to implementation detail:

1. `01-system-purpose.md` — Start here. Missions, layered topology, key invariants, success criteria.
2. `10-api-contract.md` — Data types and method signatures for all 16 host methods and 4 callbacks.
3. `09-ui-behaviors.md` — What the control surface must display and how it responds to events.
4. `02-frame-delivery.md` — Frame rate, formats, GPU pipeline stages, consumer dispatch, stall detection.
5. `03-camera-control.md` — ISO, exposure, focus, zoom, white balance, GPU color parameters.
6. `08-capture-and-recording.md` — Still capture (two paths) and video recording behavioral contracts.
7. `05-resource-lifecycle.md` — Creation and teardown ordering; background lifecycle; self-healing.
8. `06-error-and-recovery.md` — Error classification, recovery sequence, backoff schedule.
9. `07-performance-budgets.md` — Timing constraints, memory sizes, throughput targets, thresholds.
10. `04-concurrency-invariants.md` — Read last. Serialization guarantees and race conditions to prevent.
11. `11-what-not-to-port.md` — What is excluded. Read to understand scope boundaries.
12. `12-unresolved.md` — Open questions. Read to understand what the architect must resolve.

---

## File Summaries

### `01-system-purpose.md`
High-level missions (live GPU-processed preview, natural stream, C++ consumer fan-out, still capture, video recording, camera controls). Single session; back-facing main lens only. Six-layer topology. Six key architectural invariants. Success criteria. Architectural evolution context.

### `02-frame-delivery.md`
Frame rate target (30fps). Capture format (8-bit YUV 4:2:0, largest 4:3 resolution) center-cropped to operator-selected region. All delivered streams (natural, processed, tracker) in RGBA16F. Ten-step GPU pipeline sequence including crop + YUV→RGB + color transforms. Asynchronous double-buffered readback; fence resolves within the per-frame budget. Three subscribable streams plus encoder. Preview surface rebind on swap failure. Drop-on-busy consumer dispatch semantics. Per-frame metadata (9 fields). Dual stall watchdog (3s GPU-level, 5s capture-result-level). Watchdog lifecycle rules.

### `03-camera-control.md`
ISO/exposure coupling rules. Focus (auto continuous / manual diopters). White balance (auto/locked/manual per-channel). Zoom (digital). Noise reduction and edge mode (integer passthrough). EV compensation. GPU color processing parameters (brightness, contrast, saturation, black balance, gamma) with processing order. AE convergence timeout (5s). Resolution selection (largest 4:3, fallback 1280×960). Settings persistence.

### `04-concurrency-invariants.md`
11 numbered invariants. Camera state must be exclusively serialized. GPU operations on a single dedicated serialized context. UI callbacks on main execution context. Native pipeline pointer use-after-free prevention. C++ consumer lock ordering (pipeline > stage > consumer). GPU shader uniforms protected against concurrent access. Atomic capture in-flight guard. Lock-free capture check fast path. Recovery cancellation. Non-blocking consumer dispatch. Stall timestamp visibility.

### `05-resource-lifecycle.md`
Full initialization order (6 steps). Full teardown order (8 steps). Session-only teardown order (for pause and resolution change). GPU resource release safety (context must be active). Native pipeline lock protocol. Still-capture reader lifecycle. GPU resize with 5s timeout. Preview surface rebind (3-failure threshold). Background lifecycle integration. Settings persistence on open.

### `06-error-and-recovery.md`
Fatal vs. non-fatal error classification. Full error code table (19 codes). Non-fatal recovery sequence (7 steps). Fatal sequence (4 steps). Exponential backoff table (500ms–8000ms, max 5 retries). Duplicate recovery suppression. Recovery cancellation on close/suspend. HAL error threshold (5 consecutive). Dual stall watchdog semantics. AE convergence and FPS degradation notifications. Self-healing from camera-in-use error.

### `07-performance-budgets.md`
Frame rate (30fps target, 15fps degradation threshold). GPU fence resolves within per-frame budget (specific values in measurements/). Frame delivery lag (1 frame). Stall thresholds (3s GPU, 5s result). Recovery backoff schedule. HAL error threshold (5). AE convergence timeout is a platform measurement. Frame buffer formulas (FRAME_WORKING_MB = crop_w × crop_h × 8). Consumer processing semantics. Resolution resize timeout (5s). Drain timeout (5s). Preview surface failure threshold (3 swaps). Metadata array sizes.

### `08-capture-and-recording.md`
One still capture path (GPU-processed, 8-bit TIFF; two equivalent implementations). One-capture-at-a-time concurrency guard. EXIF metadata requirements. Video encoding: GPU-to-encoder zero-copy, HEVC 8-bit only, MP4 container, TARGET_BITRATE_MBPS. No audio. Recording state machine. Start/stop flows. Drain timeout behavior. Pause-during-recording finalize semantics left to platform (U-18).

### `09-ui-behaviors.md`
Split-screen preview (left natural, right processed). Bottom bar (5 controls). Expanded camera parameter controls (ISO, shutter, focus, zoom). Color calibration sidebar (brightness, contrast, saturation, gamma, black balance, reset). Recording indicator (timer, stop button). Capture banner. State-driven UI. Fatal vs. non-fatal error display. FrameResult update behavior. Landscape-only layout.

### `10-api-contract.md`
7 data types (CameraSettings, ProcessingParameters, SessionCapabilities, SessionState, ErrorCode, Error, FrameResult, RgbSample). 16 host methods (open, close, pause, resume, backgroundSuspend, backgroundResume, updateSettings, setProcessingParameters, getPersistedProcessingParameters, sampleCenterPatch, captureImage, startRecording, stopRecording, setResolution, setCropRegion, getNativePipelineHandle). 4 callbacks (onStateChanged, onError, onFrameResult, onRecordingStateChanged). Consumer registration API (all three streams: natural, processed, tracker).

### `11-what-not-to-port.md`
21 items explicitly excluded from requirements. See summary below.

### `12-unresolved.md`
17 items requiring architect resolution. See summary below.

---

## What Is NOT Covered (see `11-what-not-to-port.md`)

The following Android-specific implementation details are explicitly excluded. The architect must
solve these problems from first principles using the target platform's native capabilities:

- **Android message-dispatch concurrency mechanism** — threading primitive tied to Android runtime
- **JNI** — native bridge specific to Java Virtual Machine / Android Runtime
- **Flutter Pigeon codegen** — Flutter code generation tool and its bug workarounds
- **SharedPreferences persistence API** — Android key-value store including double-as-long workaround
- **MediaStore integration** — Android media content provider, two-phase write, content URI system
- **Android manifest and permission model** — declared permissions, runtime prompts
- **Android-specific capture request templates** — named ISP tuning modes
- **Android-specific integer passthrough for noise/edge** — raw HAL integer values
- **Gradle / NDK / CMake build configuration** — Android build toolchain entirely
- **ADB broadcast receivers** — Android debug control mechanism
- **Android Jetpack lifecycle observer** — `onStop`/`onStart` specifically
- **Android camera availability notification for self-healing** — camera availability callback mechanism
- **OpenGL ES specifics** — PBOs, FBOs, EGL, GLSL — the GPU API constructs (not the behaviors)
- **UV rotation matrix for sensor orientation** — must be re-determined for target hardware
- **Encoder output drain loop pattern** — Android codec synchronous polling model
- **Flutter binary messenger thread affinity** — Flutter runtime main-thread constraint
- **HEVC/H.264 codec name strings** — Android codec identifier strings
- **libjpeg-turbo CMake build** — JPEG library build configuration
- **fpng PNG encoder** — bundled library implementation choice
- **Android-specific white balance gain vector encoding** — four-element Bayer-aware vector
- **Host GTest unit tests** — build infrastructure

---

## Open Questions (see `12-unresolved.md`)

The following items require resolution by the downstream architect before finalizing the design.
Items are numbered for cross-reference:

| # | Topic | iOS Status |
|---|---|---|
| U-01 | Camera permission flow and denial recovery | **Resolved:** `PermissionManager` + `scenePhase`; see design/02-concurrency.md, design/07-ios-specific-risks.md R-03, R-04 |
| U-02 | GPU API and camera-to-GPU frame delivery | **Resolved:** Metal + `CVMetalTextureCache` zero-copy; see design/03-metal-pipeline.md |
| U-03 | GPU-to-encoder zero-copy availability | **Resolved:** IOSurface-backed `CVPixelBufferPool` + `MTLBlitCommandEncoder`; see design/03-metal-pipeline.md |
| U-04 | Preview texture / GPU-to-UI-framework integration | **Resolved:** `MTKView` via `UIViewRepresentable` (two instances); see design/01-architecture.md |
| U-05 | Thermal throttling and system pressure | **Resolved:** `ProcessInfo.thermalStateDidChangeNotification` + `systemPressureState` KVO; see design/02-concurrency.md |
| U-06 | Actor isolation and concurrency model choice | **Resolved:** Swift actors enforce all 11 invariants structurally; see design/02-concurrency.md |
| U-07 | Definition of "fully invisible" in app lifecycle | **Resolved:** `scenePhase == .background` (not `.inactive`); see design/02-concurrency.md, D-08 |
| U-08 | Supported resolution discovery mechanism | **Partial (pre-existing):** 4:3 rationale resolved; iOS API (`AVCaptureDevice.formats`) to be confirmed during Phase 1a |
| U-09 | EXIF metadata writing API | **Partial:** `CGImageDestination` + `"CamPlugin/v1"` key settled; JSON field schema deferred to Phase 5 |
| U-10 | Camera sensor orientation and required transform | **Resolved:** `AVCaptureConnection.videoRotationAngle`; angle value verified empirically in Phase 1a; see design/03-metal-pipeline.md, D-11 |
| U-11 | Focus distance diopter convention on target platform | **Partial:** iOS uses `lensPosition` (0–1); diopter conversion requires per-device calibration; see D-13, R-13 |
| U-12 | Front-facing camera preview mirroring behavior | **Resolved:** front camera out of scope |
| U-13 | Whether C++ consumers can register for natural stream | **Resolved:** no — natural is display-only |
| U-14 | GPU timer / profiling capabilities | **Resolved:** `os_signpost` + Metal System Trace; see design/03-metal-pipeline.md §Profiling Strategy |
| U-15 | Tracker resolution height (480px) rationale | **Resolved:** fixed compile-time value |
| U-16 | AE frame rate range policy for recording | **Partial:** `activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` committed; preview fallback policy needs hardware testing; see R-14 |
| U-17 | Maximum concurrent sessions | **Resolved:** single session; back-facing main lens only |

---

## Traceability

Every requirement in files `01` through `10` includes an `[audit: <filename>]` footnote linking
it to the audit file(s) it was derived from. The downstream architect can consult the corresponding
`audit/` file for the original Android factual basis if additional context is needed.

**Audit files by topic:**

| Audit file | Domain files that cite it |
|---|---|
| `01-system-topology.md` | 01, 09, 10, 11 |
| `02-threading-model.md` | 04, 05, 10, 11 |
| `03-capture-pipeline.md` | 01, 02, 03, 05, 07, 08, 11, 12 |
| `04-pigeon-api.md` | 01, 02, 03, 05, 06, 07, 09, 10, 11, 12 |
| `05-gpu-opengl.md` | 02, 04, 05, 07, 11, 12 |
| `06-cpp-sinks.md` | 02, 04, 07, 10, 11 |
| `07-state-machine.md` | 05, 06, 07, 09, 10, 11 |
| `08-error-recovery.md` | 05, 06, 07, 09, 11, 12 |
| `09-camera-controls.md` | 03, 05, 07, 08, 10, 11, 12 |
| `10-capture-recording.md` | 08, 10, 11, 12 |
| `11-build-config.md` | 07, 11, 12 |
| `12-git-archaeology.md` | 01, 05, 11, 12 |
