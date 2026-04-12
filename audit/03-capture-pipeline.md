# 03 — Capture Pipeline

## Frame Path Overview

```
Camera2 HAL
    │  YUV_420_888 (largest 4:3 size)
    ↓
SurfaceTexture (OES texture) ← GpuPipeline.cameraSurface
    │  OnFrameAvailableListener fires on GL thread
    ↓
GpuRenderer.drawAndReadback()   [GL thread]
    │  glDrawArrays (OES → FBO → processed RGBA)
    │  PBO readback (async, double-buffered)
    ↓
ImagePipeline::deliverFullResRgba()
ImagePipeline::deliverTrackerRgba()
ImagePipeline::deliverRawRgba()    [raw path: direct glReadPixels]
    │
    ↓ SharedFrame (shared_ptr, zero copy per consumer)
ProcessingStage hook thread (per consumer role)
    │
    ↓
Consumer SinkCallback (registered via addSink())
```

## Camera2 Configuration

### Stream Format
- Format: `ImageFormat.YUV_420_888`
- Resolution: largest 4:3 YUV size reported by `SCALER_STREAM_CONFIGURATION_MAP`.
  - Filter: `width * 3 == height * 4`
  - Sort: descending by pixel count
  - Fallback: `1280×960` (4:3) if no 4:3 YUV sizes advertised
- Caller-requested resolution is validated against supported sizes; throws `IllegalArgumentException` if not supported.

### Session Surfaces
`CaptureSession` is created with two `OutputConfiguration` targets:
1. `gpuPipeline.cameraSurface` — GpuPipeline's SurfaceTexture surface (receives every preview frame)
2. `jpegReader.surface` — Pre-allocated `ImageReader` (JPEG, 1 buffer); targeted only by one-shot still capture requests

### Repeating Request
- Template: `TEMPLATE_PREVIEW` (not recording) or `TEMPLATE_RECORD` (recording).
- Anti-banding: `CONTROL_AE_ANTIBANDING_MODE_AUTO`.
- AE FPS range:
  - Preview: highest sustained range (locked lower == upper preferred).
  - Recording: `[targetFps/2, targetFps]` — allows AE to slow in dark scenes while keeping upper bound aligned with encoder fps.

## GpuPipeline (Kotlin Wrapper)

- Creates a `HandlerThread("GpuPipeline-GL")`.
- On start: calls `nativeGpuInit()` via JNI, which calls `GpuRenderer::init()` — creates EGL display, context, pbuffer surface, and GL objects.
- `cameraSurface`: the `Surface` from GpuRenderer's `SurfaceTexture`. Camera2 writes frames here.
- `SurfaceTexture.OnFrameAvailableListener` posts `nativeGpuDrawAndReadback()` to the GL thread.
- After each drawAndReadback, GpuPipeline optionally calls `nativeGpuSampleCenterPatch()` if requested.
- UV rotation matrix: 90° CW rotation applied to the OES texture to normalize landscape-right orientation.

## GpuRenderer Frame Sequence (per frame)

Documented in `GpuRenderer.cpp` comments. Steps per `drawAndReadback()`:

1. **Update OES texture**: `surfaceTexture->updateTexImage()` — latches the latest camera frame into the OES texture.
2. **Wait for previous PBO fence**: Check the sync fence for the PBO that was submitted in the prior frame. 8ms timeout; if expired, log warning and perform a blocking `glFinish()`.
3. **Bind processed-path FBO**: Render OES texture → color-processed RGBA via fragment shader into `fboTextures_[current]`.
4. **Swap preview surface**: `eglSwapBuffers()` to the preview EGLSurface (Flutter's `SurfaceProducer`). If swap fails consecutively (`kSwapFailureThreshold=3`), trigger `onPreviewRebindNeeded` callback.
5. **Blit to encoder surface** (if recording): `eglSwapBuffers()` to `eglEncoderSurface_` while encoder EGL surface is current.
6. **Issue PBO readback**: `glReadPixels()` targeting the alternate (idle) PBO — this is asynchronous because a PBO is bound.
7. **Insert GL fence**: `glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE)` on the PBO just submitted.
8. **Map completed PBO**: Map the PBO that finished in the prior frame, copy bytes to `SharedFrame`, deliver to `ImagePipeline`.

## PBO Double-Buffer

Two PBOs (`pboIds_[2]`) and two sync fences (`pboFences_[2]`) alternate each frame.

- Frame N: submit readback into PBO[0], insert fence[0].
- Frame N+1: wait for fence[0], map PBO[0] → copy → deliver; submit readback into PBO[1], insert fence[1].
- This means frame delivery is always one frame behind the rendered frame.

The sync fence wait uses `GL_TIMEOUT_EXPIRED` with a zero timeout to non-blockingly poll. If expired, falls back to an 8ms `glClientWaitSync` call. If still not signaled, logs a timeout error and calls `glFinish()`.

## Tracker Downscale

The tracker-resolution RGBA is produced by a second render pass into a smaller FBO:
- Height: `kTrackerHeight = 480` pixels (static constexpr in `GpuRenderer.h`)
- Width: `((streamWidth * kTrackerHeight / streamHeight) + 1) & ~1` — rounded up to even number

The tracker FBO uses the same fragment shader (processed RGBA), just at a smaller output size.

## Raw Stream Path

When `enableRawStream=true`:
- A second `SurfaceProducer` (`rawSurfaceProducer`) is created.
- GpuRenderer's `kRawFragSrc` shader (passthrough — no color adjustments) renders into a raw FBO.
- Raw FBO is blitted to `eglRawSurface_` per frame.
- Raw stream dimensions: `rawH = rawStreamHeight`, `rawW = ((streamWidth * rawH / streamHeight) + 1) & ~1`.
- `rawSurfaceProducer` has its own Flutter `Texture` ID; Dart reads it via a separate texture widget.
- If the raw EGL surface is lost (app backgrounding), `GpuRenderer::rebindRawSurface()` recreates `eglRawSurface_` from a new `Surface` provided by `onSurfaceAvailable`.

## Frame Delivery to C++

`nativeGpuDrawAndReadback()` in `CameraBridge.cpp`:
```
GpuRenderer::drawAndReadback(width, height, metadata_longs, metadata_ints)
```
Returns the RGBA buffer pointer; `CameraBridge` wraps it as a `SharedFrame` and calls `ImagePipeline::deliverFullResRgba()` / `deliverTrackerRgba()` / `deliverRawRgba()`.

## JNI Metadata Transfer

Per-frame metadata is transferred via flat arrays to avoid per-field JNI overhead:

`MetadataLayout.kt` / C++ header:
- `long[5]` (LONG_COUNT=5): sensor timestamp ns, exposure time ns, frame duration ns, ISO, focus distance
- `int[4]` (INT_COUNT=4): AE state, AF state, AWB state, flash state

## Stall Watchdog

Two independent stall detection mechanisms:

### GpuPipeline Stall (GL-thread level)
- `STALL_THRESHOLD_MS = 3000`
- `STALL_CHECK_INTERVAL_MS = 1000`
- `lastFrameTimestampMs` is updated by `onFrameAvailable` on the GL thread.
- A periodic `Runnable` on the GL thread checks elapsed time.
- On stall: calls `onStallDetected(elapsedMs)` callback. `CameraController` posts `flutterApi.onError(FRAME_STALL)` to main thread.

### CameraController Stall (capture-result level)
- `stallTimeoutMs = 5000`
- `stallCheckIntervalMs = 3000`
- `lastCaptureResultMs` is updated by `onCaptureCompleted` on the background thread.
- `stallWatchdog` Runnable is posted to `backgroundHandler` after each check.
- Initialized to `SystemClock.elapsedRealtime()` at session start (in `onConfigured`) to prevent false positives on first frame.
- On stall: calls `handleNonFatalError(FRAME_STALL, ...)` → recovery.
