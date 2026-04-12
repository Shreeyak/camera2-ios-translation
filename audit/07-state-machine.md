# 07 — State Machine

## States

```kotlin
enum class State { CLOSED, OPENING, STREAMING, RECOVERING, PAUSED, ERROR }
```

| State | Meaning | Dart string emitted |
|-------|---------|-------------------|
| `CLOSED` | No camera device open; initial state | `"closed"` |
| `OPENING` | `cameraManager.openCamera()` in flight | `"opening"` |
| `STREAMING` | `CaptureSession` active; frames flowing | `"streaming"` |
| `RECOVERING` | Error detected; retry scheduled | `"recovering"` |
| `PAUSED` | Session torn down; device kept open (see note) | `"paused"` |
| `ERROR` | Fatal error; no recovery | `"error"` |

Note: After the transition to PAUSED state, the cameraDevice may still be open but the
CaptureSession and GPU pipeline are released. `teardownSession()` is called, not `teardown()`.

## State Transitions

```
                                  open() called
CLOSED ──────────────────────────────────────────→ OPENING
                                                      │
                              onOpened callback        │
                              (CameraDevice)           │
                                                      ↓
                         onConfigured callback    STREAMING ←──────────────┐
                         (CaptureSession)              │                    │
                                                       │                    │
                                      non-fatal        │                    │
                                      error            │    backgroundResume│
                                                       ↓                    │
RECOVERING ←─────────────────────────────────────────────────────┐         │
     │                                                            │         │
     │ retry after backoff delay                                  │         │
     │ (doReopenCamera → OPENING → STREAMING)                     │         │
     │                                                            │         │
     │ maxRetries exceeded → fatal                                │         │
     │                                                            │         │
     ↓                                                            │         │
ERROR (terminal)                                                  │         │
                                                                  │         │
STREAMING ────────────────────────── pause() ──────────────→ PAUSED ────────┘
                                                     (teardownSession)
                                                                            
STREAMING or RECOVERING ──────── close() ──────────────────→ CLOSED
                                                     (teardown + emitState)
```

## Transition Triggers

| From | To | Trigger |
|------|----|---------|
| Any | OPENING | `open()` or `doReopenCamera()` called |
| OPENING | STREAMING | `CaptureSession.onConfigured` |
| OPENING | RECOVERING | `CaptureSession.onConfigureFailed`, `CameraDevice.onDisconnected`, `CameraDevice.onError` (non-fatal) |
| OPENING | ERROR | `CameraDevice.onError` (fatal: `ERROR_CAMERA_DISABLED`) |
| STREAMING | RECOVERING | Stall watchdog timeout, HAL error threshold (5 consecutive), `CameraAccessException` in session setup |
| STREAMING | PAUSED | `pause()` called |
| STREAMING | CLOSED | `close()` called |
| RECOVERING | OPENING | Retry `Runnable` fires (after backoff delay), calls `doReopenCamera()` |
| RECOVERING | ERROR | `retryCount >= maxRetries (5)` |
| RECOVERING | CLOSED | `backgroundSuspend()` called while recovering (suppress recovery) |
| PAUSED | STREAMING | `resume()` or `backgroundResume()` → `startCaptureSession()` → `onConfigured` |
| Any | ERROR | `handleFatalError()` — no further transitions possible |

## Key Constants

| Constant | Value | Purpose |
|---------|-------|---------|
| `backoffDelaysMs` | `[500, 1000, 2000, 4000, 8000]` ms | Retry delays indexed by `retryCount` |
| `maxRetries` | `5` | After this many retries, transition to ERROR |
| `HAL_ERROR_THRESHOLD` | `5` | Consecutive `REASON_ERROR` capture failures before recovery |
| `stallTimeoutMs` | `5000` ms | CameraController stall detection timeout |
| `stallCheckIntervalMs` | `3000` ms | CameraController stall check interval |
| `AE_CONVERGENCE_TIMEOUT_MS` | `5000` ms | Time in AE_STATE_SEARCHING before non-fatal error |
| `LOW_FPS_THRESHOLD` | `15.0` fps | FPS below this counts toward degradation streak |
| `LOW_FPS_STREAK_LIMIT` | `3` | Consecutive heartbeats below threshold before FPS_DEGRADED error |
| `RESIZE_TIMEOUT_SECONDS` | `5` | `GpuPipeline.resize()` wait timeout |

## State Consistency Rules

1. `state` field is only written on `backgroundHandler`. No exceptions.
2. All `emitState()` calls are followed immediately (or shortly after on same thread) by `mainHandler.post { flutterApi.onStateChanged(...) }`.
3. `handleNonFatalError()` exits immediately if `state == State.ERROR` (terminal).
4. `handleNonFatalError()` exits with `setState(CLOSED)` if `backgroundSuspended == true` (suppress recovery for intentional background release).
5. `handleNonFatalError()` exits without scheduling retry if `state == State.RECOVERING` — duplicate recovery is suppressed. (Note: enforced in `onCaptureFailed`; `handleNonFatalError` itself only guards against `state == ERROR`.)
6. `doReopenCamera()` is a no-op if `resolvedCameraId == null`.
7. Recovery retry `Runnable` checks `state != State.RECOVERING` before running — cancelled by explicit `close()` or `backgroundSuspend()`.

## Background Suspend/Resume

`backgroundSuspend()` (called by `ProcessLifecycleOwner.onStop`):
- Sets `backgroundSuspended = true`.
- Calls `teardown()` to release all Camera2 resources.
- Sets `state = CLOSED` (no emitState — no user-visible transition).

`backgroundResume()` (called by `ProcessLifecycleOwner.onStart`):
- Clears `backgroundSuspended = false`.
- If `resolvedCameraId != null`, calls `doReopenCamera()`.

The plugin uses `onStop`/`onStart` (not `onPause`/`onResume`) to only release when the app is fully invisible.

## CameraManager.AvailabilityCallback

Registered for `state == State.ERROR` only:
- `onCameraAvailable(id)`: if `id == resolvedCameraId` and `state == State.ERROR`, resets `state` to `CLOSED` and calls `doReopenCamera()`. This allows self-healing when another app releases the camera.
- `onCameraUnavailable(id)`: no action (already in ERROR).
