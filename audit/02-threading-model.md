# 02 — Threading Model

## Thread Inventory

| Thread | Created By | Name | Ownership | Lifetime |
|--------|-----------|------|-----------|---------|
| Main thread | Android runtime | `main` | Platform | App lifetime |
| Background thread | `CameraController` | `"CameraBackground"` | Per-session | open() → close()/release() |
| GL thread | `GpuPipeline` | `"GpuPipeline-GL"` | Per-session | pipeline.start() → pipeline.stop() |
| Drain thread | `VideoRecorder` | `"RecorderDrain"` | Per recording | start() → stop() |
| ProcessingStage thread | `ProcessingStage` (C++) | (unnamed) | Per sink role | addSink() → removeSink() |

## Thread Roles and Constraints

### Main Thread (`mainHandler`)
- Receives all Dart/Flutter callbacks via Pigeon binary messenger.
- All `flutterApi.*` calls MUST be posted here — the Pigeon binary messenger requires main thread access.
- All `emitState()`, `flutterApi.onStateChanged()`, `flutterApi.onError()`, `flutterApi.onFrameResult()`, `flutterApi.onRecordingStateChanged()` are posted from background thread to `mainHandler`.
- `CambrianCameraPlugin` processes Dart host API calls (`CameraHostApi`) on the main thread, then forwards to `CameraController` methods which immediately post to `backgroundHandler`.

### Background Thread (`backgroundHandler`)
- All Camera2 operations: `cameraManager.openCamera()`, `CameraDevice.*`, `CaptureSession.*`, `CaptureRequest.*`.
- State machine transitions (`state`, `retryCount`, `consecutiveHalErrors`).
- The stall watchdog `Runnable` and recovery retry `Runnable` run here.
- `repeatingCaptureCallback` (`CameraCaptureSession.CaptureCallback`) is registered on this handler.
- `updateSettings()`, `buildCaptureRequest()`, `teardown()`, `teardownSession()`, `startCaptureSession()` all execute on this thread.
- `captureNaturalPicture()` registers the `ImageReader.OnImageAvailableListener` on this handler.
- Pattern for every new public method:
  ```kotlin
  fun myMethod(callback: (Result<Unit>) -> Unit) {
      backgroundHandler.post {
          // Camera2 work here
          mainHandler.post { callback(Result.success(Unit)) }
      }
  }
  ```

### GL Thread (`GpuPipeline`)
- Owned by `GpuPipeline`'s `HandlerThread`.
- EGL context is created and owned by this thread.
- All OpenGL ES calls happen here: `glDrawArrays`, `glReadPixels` (raw path), `glBeginQuery`, PBO mapping, fence creation and waiting.
- `nativeGpuDrawAndReadback()` JNI call is dispatched from this thread.
- `SurfaceTexture.OnFrameAvailableListener` posts work to this thread.
- Stall watchdog is a separate Runnable on `backgroundHandler` that reads `lastFrameTimestampMs` (volatile) set by the GL thread.
- `GpuPipeline.onStallDetected` callback is invoked from the GL thread; `CameraController` receives it and posts `flutterApi.onError()` to `mainHandler`.
- `GpuPipeline.sampleCenterPatch()` posts to the GL thread; result callback is posted back to the calling context via `mainHandler`.

### Drain Thread (`VideoRecorder`)
- Created once per recording session in `VideoRecorder.start()`.
- Polls `MediaCodec.dequeueOutputBuffer()` until `INFO_OUTPUT_FORMAT_CHANGED` (writes MediaMuxer track), then loops draining encoded packets to `MediaMuxer`.
- On `stop()`, sets drain-stop flag and calls `drainThread.quitSafely()`, then joins.
- EOS is signaled by setting `endOfStream = true` and calling `mediaCodec.signalEndOfInputStream()`.
- Drain timeout is 5 seconds; if exceeded, `wasEosDrainTimedOut()` returns true and Dart receives a `RECORDING_TRUNCATED` non-fatal error.

### C++ ProcessingStage Threads
- Each `ProcessingStage` created by `ImagePipeline` has its own `std::thread`.
- Receives frames via a 1-slot mailbox (`pending` + `mu` + `cv`). New frames overwrite unprocessed ones (drop-on-busy).
- Runs the registered hook function (`FrameHookFn`), then dispatches the (possibly modified) frame to the consumer's callback.

## Cross-Thread Communication Patterns

### Dart → Native (Pigeon)
1. Dart calls Pigeon method on main thread.
2. Kotlin `CameraHostApi` implementation receives on main thread.
3. `CameraController` method posts body to `backgroundHandler`.
4. Result/callback posted to `mainHandler`, then returned to Dart.

### Native → Dart (FlutterApi)
1. Event originates on background thread or GL thread.
2. Always wrapped in `mainHandler.post { flutterApi.onXxx(...) {} }`.
3. Pigeon delivers to Dart via binary messenger on main thread.

### GL Thread → C++ Pipeline
1. `GpuPipeline.onFrameAvailable` fires on the GL thread.
2. Calls `nativeGpuDrawAndReadback(pipelinePtr, ...)` via JNI.
3. `GpuRenderer.drawAndReadback()` renders, reads back RGBA.
4. Calls `ImagePipeline::deliverFullResRgba()` / `deliverTrackerRgba()` / `deliverRawRgba()`.
5. `ImagePipeline` sends `SharedFrame` to each registered consumer's ProcessingStage mailbox.
6. Consumer callbacks run on their respective `ProcessingStage` threads.

### Uniform Updates (setAdjustments)
- `CameraController.setProcessingParams()` → `GpuPipeline.setAdjustments()` → posts to GL thread → `nativeGpuSetAdjustments()` JNI → `GpuRenderer::setAdjustments()`.
- `GpuRenderer` protects uniform values with `uniformMu_` mutex, written on calling thread, read on GL thread.

## Lock Ordering (C++)

Documented in `ImagePipeline.h`:
```
fullResConsumersMu_ > ProcessingStage::mu > Consumer::mu
```
Always acquire in this order to prevent deadlock.

## pipelineLock (Kotlin)

`synchronized(pipelineLock)` guards `nativePipelinePtr` in `CameraController`.
- `teardown()` zeroes the pointer under this lock before calling `nativeRelease()`.
- `captureImage()` re-reads the pointer under this lock before passing it to `nativeCaptureImage()`.
This prevents use-after-free if `teardown()` races with a capture in flight.

## Handler Lifecycle

```
backgroundThread.start()         // CameraController constructor
backgroundHandler = Handler(backgroundThread.looper)
// ... open/stream/close ...
backgroundThread.quitSafely()    // release()
```

`GpuPipeline` creates its own `HandlerThread` in `start()` and calls `quit()` in `stop()`.
