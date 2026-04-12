# 12 — Git Archaeology

All data from `git log` run on `/Users/shrek/work/cambrian/camera2_flutter_demo`.
Total commits: 247. Date range: 2026-03-30 to 2026-04-13.

## Architectural Timeline

### Phase 1: Project Skeleton (2026-03-30)

**`a945a84` Phase 1: Plugin skeleton + Dart API (cambrian_camera)**

Created the plugin package structure with Pigeon type-safe channel (messages.g.dart/kt), public Dart API (`CambrianCamera`, `CameraSettings`, `ProcessingParams`, `CameraState`, `CameraError`, `CameraCapabilities`), `CambrianCameraPreview` widget, and 14 unit tests. Platform implementations were stubs at this stage.

**`12878ae` Phase 2: Kotlin plugin shell + demo app camera wiring**

Added `CambrianCameraPlugin.kt` and wired the demo app's camera button.

### Phase 2: Camera2 + JNI Foundation (2026-03-30)

**`f1075e8` Phase 3: Camera2 CameraController + minimal C++ JNI pipeline**

First real implementation: `CameraController.kt` with Camera2 lifecycle, state machine (CLOSED→OPENING→STREAMING→RECOVERING→ERROR), exponential backoff recovery, per-request ISP settings, JPEG capture via hardware ISP ImageReader, and main-thread Pigeon dispatch. Minimal C++ JNI pipeline (no GPU at this point).

**`1e40806` Phase 5: Wire UI controls to camera plugin**

Connected ISO, exposure, focus, and WB UI sliders to `updateSettings()`.

### Phase 3: Plugin Architecture Modernization (2026-03-31)

**`3c99215` Modernise Camera2 session API and fix double-reply crash**

Migrated `createCaptureSession` to `SessionConfiguration` API.

**`e81f81d` Plugin fixes: thread leak, dynamic 4:3 resolution, stream dims to Dart, central config**

Added `CambrianCameraConfig` central volatile flags, dynamic 4:3 resolution selection, thread leak fixes.

### Phase 4: Async C++ Pipeline with OpenCV (2026-03-31)

**`3508e2c` feat(pipeline): async InputRing + OpenCV YUV→BGR + shared_ptr consumer dispatch**

Replaced synchronous per-frame JNI with:
- `InputRing` (4-slot ring buffer) for async YUV delivery
- OpenCV `cvtColorTwoPlane` for YUV→BGR conversion
- `shared_ptr<Frame>` fan-out to consumers (no per-consumer copies)
- 1-slot drop-on-busy mailbox per consumer
- Preview as a built-in consumer (`BGR→RGBA` → `ANativeWindow`)

This was the first use of OpenCV in the pipeline.

### Phase 5: GPU Pipeline (2026-04-01 to 2026-04-04)

**`5a08207` feat: GPU pipeline wiring, color controls UI, and tests**

Replaced YUV `ImageReader` with `GpuPipeline`. Routed `setProcessingParams` to `gpuPipeline.setAdjustments`. Added `GpuControlsSidebar` with brightness/contrast/saturation/gamma/blackR/G/B sliders.

**`8341b28` feat(pigeon): add enableRawStream params to open() and raw stream fields to CamCapabilities**

Added raw stream support to the Pigeon API.

**`ebc504b` feat(C++): GpuRenderer raw stream — passthrough shader, rawFBO, rawPBOs**

Added raw FBO, passthrough shader (`kRawFragSrc`), and raw EGL surface to `GpuRenderer`.

**`2350992` feat: GPU raw stream — Dart SDK, Kotlin wiring, C++ headers, demo**

End-to-end raw stream: `rawTextureId` in `CamCapabilities`, raw `SurfaceProducer`, raw split-screen demo.

**`04bbf69` video reads directly from gpu buffer**

Initial video recording reading directly from GPU output (first wiring of MediaCodec to GPU path).

### Phase 6: Recording, Pigeon Migration, Lifecycle (2026-04-05 to 2026-04-07)

**`6954998` add video recording to cambrian_camera plugin**

`VideoRecorder.kt` with MediaCodec surface-input mode, drain HandlerThread, MediaMuxer.

**`b86fed9` feat(self-healing): implement self-healing camera pipeline (#18)**

`CameraManager.AvailabilityCallback` for recovery from `ERROR_CAMERA_IN_USE`. `PAUSED` state and `pause()`/`resume()` API. Background lifecycle via `ProcessLifecycleOwner.onStop/onStart`.

**`b223472` Merge pull request #15 from Shreeyak/feature/pigeon**

Migrated error codes from strings to typed Pigeon enum (`CamErrorCode`). Added `startRecording`/`stopRecording` bitrate/fps parameters. Added `CamRgbSample` and `sampleCenterPatch`. Added Pigeon codegen wrapper script.

**`2e519c6` feat(lifecycle): add PAUSED state and pause()/resume() to camera pipeline (#19)**

Full lifecycle: `backgroundSuspend()`/`backgroundResume()` wired to `ProcessLifecycleOwner`.

**`3975835` feat(lifecycle): lightweight pause/resume and frame stall watchdog (#20)**

Stall watchdog added to both `GpuPipeline` (GL thread) and `CameraController` (background thread). Lightweight session-only teardown for `pause()`.

**`5e77df9` feat(renderer): add explicit PBO sync with GL fences and timing queries (#22)**

Replaced implicit `GL_MAP_READ_BIT` sync with explicit `glFenceSync`/`glClientWaitSync`. Added `GL_TIME_ELAPSED_EXT` timing queries. Added PBO stall logging. Skip-readback on 8ms fence timeout.

### Phase 7: CPU Pipeline Removal (2026-04-07)

**`7e77250` feat(pipeline): strip CPU pipeline and add ProcessingStage hook (#21)**

Removed `InputRing`, OpenCV dependency, all CPU YUV→BGR conversion code (`applySaturation`, `blitToWindow`, `deliverYuv`). Replaced `cv::Mat` with `std::vector<uint8_t>`. Added `ProcessingStage` per-role hook thread. Simplified `nativeInit()` — no preview surface needed. Removed `nativeSetPreviewWindow`, `nativeDeliverYuv` JNI functions.

This is the current architecture. The CPU pipeline is gone permanently.

**Key before/after**:
- Before: Camera2 → ImageReader → InputRing (C++) → Processing thread (OpenCV YUV→BGR) → Consumer
- After: Camera2 → GpuPipeline (OES → GL → PBO) → ImagePipeline (shared_ptr dispatch) → Consumer

### Phase 8: Diagnostics and Bug Fixes (2026-04-07 to 2026-04-08)

**`ae492f9` fix: pause/recording safety and KDoc accuracy in CameraController (#29)**

`pause()` while recording auto-stops recorder; HAL errors during RECOVERING suppressed.

**`c4edd7e` fix: stall watchdog now fires on zero-frame sessions (#30)**

`lastCaptureResultMs` initialized to `SystemClock.elapsedRealtime()` in `onConfigured`, preventing false stall on first frame.

**`4d5849e` fix: log lifecycle observer failures instead of swallowing them (#27)**

`backgroundSuspend`/`backgroundResume` errors logged at ERROR level.

**`61e063b` Hotfix lifecycle — `CameraManager.AvailabilityCallback`, thread-safe close(), dartPaused flag**

Self-healing from ERROR state when camera becomes available. Thread-safe `close()` post to backgroundHandler. `backgroundSuspended` flag to prevent wasteful reopen.

### Phase 9: Feature Additions (2026-04-08 to 2026-04-13)

**`cf1d3fc` updated gpu shader for saturation, brightness, color, gamma (#32)**

Shader rewrite: piecewise brightness formula, sigmoid contrast, Rec.709 saturation (replaced earlier simpler formulas).

**`faa0afa` feat(plugin): add CamRgbSample and sampleCenterPatch Pigeon method**

96×96 center patch sampling with histogram trimmed mean.

**`1c5240d` Merge pull request #34 from Shreeyak/feature/awb**

AWB calibration, manual WB gains, WB lock. `RggbChannelVector` for Camera2.

**`58eb18b` Merge pull request #35 from Shreeyak/feature/resolution**

`setResolution()` — session-only teardown + `GpuPipeline.resize()` + new CaptureSession.

**`cf193b1` Merge pull request #36 from Shreeyak/featur/capture-image**

`captureImage()` GPU-processed still capture path (JPEG/PNG, `libjpeg-turbo`, `fpng`). `CaptureResultSnapshot` for EXIF. Full `TotalCaptureResult` fields in EXIF UserComment as JSON.

## Key Architecture Decisions Visible in History

| Decision | Commit | Reason |
|----------|--------|--------|
| Removed OpenCV | `7e77250` | GPU pipeline (GpuRenderer) handles all frame processing; no CPU conversion needed |
| Replaced implicit GL sync with fence | `5e77df9` | Hidden driver stalls; `GL_MAP_READ_BIT` blocks until GPU finishes |
| Session-only teardown for pause | `3975835` | Avoid CameraDevice close/open latency on background/foreground |
| Pigeon enum for error codes | `b223472` | Type safety; replaces ad-hoc string constants |
| `onStop`/`onStart` vs `onPause`/`onResume` | `3975835` | Release camera only when fully invisible, not on every partial occlusion |
| `lastCaptureResultMs` init in onConfigured | `c4edd7e` | Prevents false stall trigger before first frame arrives |
| `ProcessingStage` hook thread | `7e77250` | Allow external consumers to run preprocessing per-role without blocking delivery |
| `nativeInit()` returns 0 on failure | PR #21 code review | JNI alloc can throw; must not crash |
| `IS_PENDING` pattern for MediaStore | feature/capture-image | Prevents gallery from indexing partial files during C++ write |
