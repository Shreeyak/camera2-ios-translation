# 08 — Error Recovery

## Error Classification

Errors are classified as fatal or non-fatal at the point they are detected.

**Non-fatal (recoverable)**
- `CaptureSession.onConfigureFailed` — session configuration failed
- `CameraDevice.onDisconnected` — device disconnected
- `CameraDevice.onError` — most error codes (see below)
- `CameraAccessException` — most cases (see below)
- `SecurityException` on `openCamera()` — OEM bug after keyguard dismiss; treated non-fatal
- HAL capture failure threshold — 5 consecutive `REASON_ERROR` failures
- Stall watchdog timeout — no capture results for 5s
- AE convergence timeout — AE stuck in SEARCHING for 5s (non-fatal, no recovery)
- FPS degradation — 3 consecutive heartbeats below 15 fps (non-fatal, no recovery)

**Fatal (terminal)**
- `CameraDevice.ERROR_CAMERA_DISABLED` — device policy or MDM
- `CameraAccessException.CAMERA_DISABLED`
- `maxRetries exceeded` (5 retries without success)

## handleNonFatalError()

Called on `backgroundHandler`.

```kotlin
fun handleNonFatalError(code: CamErrorCode, message: String) {
    if (state == State.ERROR) return
    if (backgroundSuspended) {
        setState(State.CLOSED)
        return
    }
    val delayMs = backoffDelaysMs[min(retryCount, backoffDelaysMs.size - 1)]
    setState(State.RECOVERING)
    emitState("recovering")
    mainHandler.post { flutterApi.onError(handle, CamError(code, message, false)) {} }
    if (retryCount >= maxRetries) {
        handleFatalError(MAX_RETRIES_EXCEEDED, ...)
        return
    }
    retryCount++
    // Cancel any pending retry (prevents duplicate retries)
    pendingRetryRunnable?.let { backgroundHandler.removeCallbacks(it) }
    // Schedule retry
    backgroundHandler.postDelayed(retryRunnable, delayMs)
}
```

The retry `Runnable` calls `teardown()` then `doReopenCamera()`.

## handleFatalError()

```kotlin
fun handleFatalError(code: CamErrorCode, message: String) {
    teardown()
    setState(State.ERROR)
    emitState("error")
    mainHandler.post { flutterApi.onError(handle, CamError(code, message, true)) {} }
}
```

No further state transitions are possible. `isFatal = true` is set in `CamError`.

## Exponential Backoff

| retryCount | delay |
|-----------|-------|
| 0 | 500 ms |
| 1 | 1000 ms |
| 2 | 2000 ms |
| 3 | 4000 ms |
| 4 | 8000 ms |
| 5+ | 8000 ms (clamped to last element) |

`retryCount` is incremented after `retryCount >= maxRetries` check passes, so the sequence is:
- First attempt: delay[0] = 500ms
- Second attempt: delay[1] = 1000ms
- …
- Fifth attempt: delay[4] = 8000ms
- On 6th attempt: `retryCount=5 >= maxRetries=5` → `handleFatalError`

`retryCount` is reset to 0 in `CameraDevice.StateCallback.onOpened` (successful open).

## Stall Watchdog (CameraController)

Located in `CameraController.kt` as a `Runnable` posted to `backgroundHandler`.

```kotlin
val stallWatchdog = Runnable {
    val now = SystemClock.elapsedRealtime()
    val elapsed = now - lastCaptureResultMs
    if (elapsed >= stallTimeoutMs && state == State.STREAMING) {
        handleNonFatalError(CamErrorCode.FRAME_STALL, "No frames for ${elapsed}ms")
    } else {
        backgroundHandler.postDelayed(stallWatchdog, stallCheckIntervalMs)
    }
}
```

`lastCaptureResultMs` is:
- Initialized to `SystemClock.elapsedRealtime()` in `onConfigured`, immediately before posting the watchdog.
- Updated in `onCaptureCompleted` on `backgroundHandler`.
- Zeroed by `teardownSession()` and `teardown()`.

The watchdog is removed by `backgroundHandler.removeCallbacks(stallWatchdog)` in both `teardown()` and `teardownSession()`.

## Stall Watchdog (GpuPipeline)

Separate from the CameraController watchdog. Monitors frame arrival at the GL thread level.

- `STALL_THRESHOLD_MS = 3000`
- `STALL_CHECK_INTERVAL_MS = 1000`
- On stall: fires `onStallDetected(elapsedMs)`. `CameraController` posts non-fatal error to Dart but does NOT trigger recovery (separate from the 5s CameraController watchdog).

## HAL Error Threshold

In `repeatingCaptureCallback.onCaptureFailed`:
```kotlin
if (state == State.RECOVERING) return  // suppress duplicates
if (failure.reason == REASON_ERROR) {
    consecutiveHalErrors++
    if (consecutiveHalErrors >= HAL_ERROR_THRESHOLD) {
        consecutiveHalErrors = 0
        handleNonFatalError(CamErrorCode.CAPTURE_FAILURE, ...)
    }
}
```
`REASON_FLUSHED` is not counted (expected during teardown). `consecutiveHalErrors` is reset to 0 on every `onCaptureCompleted`.

## AE Convergence Timeout

Not a recovery trigger — informational only.

In `onCaptureCompleted`:
- When `AE_STATE` transitions to `SEARCHING`: record `aeSearchingStartMs = SystemClock.elapsedRealtime()`.
- Each subsequent `onCaptureCompleted`: if still `SEARCHING` and `elapsed >= AE_CONVERGENCE_TIMEOUT_MS (5000ms)`: post `flutterApi.onError(AE_CONVERGENCE_TIMEOUT, ..., isFatal=false)`.
- Resets `aeSearchingStartMs = 0L` after firing to prevent repeated notifications.

## FPS Degradation

Not a recovery trigger — informational only.

In `onCaptureCompleted` heartbeat (every 30 results):
- `fpsValue = 1_000_000_000.0 / frameDurationNs`
- If `fpsValue < LOW_FPS_THRESHOLD (15.0)`: `lowFpsStreak++`
- If `lowFpsStreak == LOW_FPS_STREAK_LIMIT (3)`: post `flutterApi.onError(FPS_DEGRADED, ..., isFatal=false)`
- Else (fps acceptable): `lowFpsStreak = 0`

## CameraManager.AvailabilityCallback (Self-Healing)

When `state == State.ERROR` and `cameraAvailabilityCallback.onCameraAvailable(id)` fires for the active camera ID:
- Resets `state = State.CLOSED` (suppresses the `ERROR` guard in `handleNonFatalError`).
- Calls `doReopenCamera()` → full reopen sequence.

This allows recovery from `ERROR_CAMERA_IN_USE` (another app released the camera) without requiring user action.

## teardown() vs teardownSession()

| `teardown()` | `teardownSession()` |
|-------------|-------------------|
| Closes `cameraDevice` | Does NOT close `cameraDevice` |
| Releases `videoRecorder` | Does not touch `videoRecorder` |
| Stops active recording | Does not stop recording |
| Used by: `close()`, `release()`, recovery retry, `handleFatalError()`, `backgroundSuspend()` | Used by: `pause()` |
| Zeroes all counters | Zeroes `captureResultCount`, `lastCaptureResultMs` |

Both remove stall watchdog callbacks, close `captureSession`, `imageReader`, `gpuPipeline`, `jpegImageReader`, and release `nativePipelinePtr`.
