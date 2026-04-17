# 06 — Error and Recovery

This file specifies error classification, recovery contracts, and the conditions under which errors
are fatal (terminal) vs. recoverable.

---

## Error Classification

Every error is classified as either **fatal** or **non-fatal** at the point it is detected.

### Fatal Errors (Terminal)

Fatal errors place the session in the `"error"` state with no further recovery. The application must explicitly create a new session (close + open) to resume camera operation.

| Condition | Error Code |
|---|---|
| Camera access disabled by device policy | `PERMISSION_DENIED` or platform equivalent |
| Maximum retry budget exhausted | `MAX_RETRIES_EXCEEDED` |
| Video encoder or muxer initialization failure | `RECORDING_START_FAILED` |
| Video recording pipeline failure mid-session | `RECORDING_FAILED` |

[audit: 08-error-recovery.md §Error Classification, 04-pigeon-api.md §CamErrorCode]

---

### Non-Fatal Errors (Recoverable)

Non-fatal errors trigger the recovery path (exponential backoff retry) unless suppressed.

| Condition | Error Code | Recovery action |
|---|---|---|
| Capture session configuration rejected | `CONFIGURATION_FAILED` | Full teardown and reopen |
| Camera device disconnected | `CAMERA_DISCONNECTED` | Full teardown and reopen |
| Camera device access error | `CAMERA_ACCESS_ERROR` | Full teardown and reopen |
| Platform-specific security bug after keyguard dismiss | `CAMERA_ACCESS_ERROR` | Full teardown and reopen |
| 5 consecutive hardware-level frame failures | `CAPTURE_FAILURE` | Full teardown and reopen |
| No frames for 5000ms (capture-result stall) | `FRAME_STALL` | Full teardown and reopen |

**Recovery-suppressed (informational only):**

| Condition | Error Code | Action |
|---|---|---|
| No frames at GPU level for 3000ms | `FRAME_STALL` | Notify application only; no recovery |
| AE not converged within 5000ms | `AE_CONVERGENCE_TIMEOUT` | Notify application only; no recovery |
| Frame rate below 15fps for 3 heartbeats | `FPS_DEGRADED` | Notify application only; no recovery |
| EOS drain timed out during recording stop | `RECORDING_TRUNCATED` | Notify application; return output URI |

[audit: 08-error-recovery.md]

---

## Non-Fatal Recovery Sequence

When a non-fatal error is detected, the following sequence executes:

1. **Disarm watchdogs**: Both stall watchdogs (GPU-level and capture-result-level) are disarmed before any further action. This prevents a watchdog callback from firing mid-recovery and triggering a second recovery path.
2. **Check terminal state**: If the session is already in terminal error state, exit immediately (no additional actions).
3. **Check background suspension**: If the application is suspended (fully invisible), transition to closed state silently and exit.
4. **Transition state to `"recovering"`**: Emit `"recovering"` state notification to the application layer.
5. **Emit error event**: Notify the application layer with the error code and `isFatal: false`.
6. **Check retry budget**: If the retry count has reached the maximum (5 retries), transition to fatal error.
7. **Cancel duplicate retries**: If a retry is already pending, cancel it before scheduling the new one.
8. **Schedule retry**: Post a retry after the backoff delay for the current retry count.

The retry action performs full teardown followed by a reopen attempt.

[audit: 08-error-recovery.md §handleNonFatalError()]

---

## Fatal Error Sequence

When a fatal error is detected:

1. Full teardown (all camera and GPU resources released).
2. Transition state to `"error"`.
3. Emit `"error"` state notification.
4. Emit error event with `isFatal: true`.
5. No further state transitions are possible from this state.

The only exit from terminal error state is the **self-healing path** (see below).

[audit: 08-error-recovery.md §handleFatalError()]

---

## Exponential Backoff

Retry delays follow this schedule, indexed by retry attempt number:

| Attempt | Delay |
|---|---|
| 1 | 500ms |
| 2 | 1000ms |
| 3 | 2000ms |
| 4 | 4000ms |
| 5 | 8000ms |
| 6+ | 8000ms (clamped) |

After 5 failed retries (6th attempt), the session transitions to fatal error with code `MAX_RETRIES_EXCEEDED`.

Retry count resets to 0 on every successful camera device open.

[audit: 08-error-recovery.md §Exponential Backoff]

---

## Duplicate Recovery Suppression

The recovery system suppresses duplicate recovery triggers:

- If a recovery retry is already pending when a new non-fatal error is detected, the pending retry is cancelled and a new one is scheduled. (This prevents accumulating multiple concurrent retry attempts.)
- If a hardware-level frame failure arrives while the session is already in `"recovering"` state, it is silently discarded.

[audit: 08-error-recovery.md §HAL Error Threshold, 07-state-machine.md §State Consistency Rules]

---

## Recovery Cancellation

Scheduled recovery retries are cancelled when:

- `close()` is called explicitly.
- `backgroundSuspend()` is called (app becomes invisible).

In both cases, the retry Runnable checks the current state before executing and exits without action if the state is no longer `"recovering"`.

[audit: 07-state-machine.md §State Consistency Rules, 08-error-recovery.md]

---

## HAL Error Threshold

Transient hardware-level frame capture failures are tolerated without triggering recovery. Recovery is triggered only after **5 consecutive** failures (without any successful frame in between).

Each successful frame resets the consecutive failure counter to 0.

Note: failures that occur during an already-recovering session are discarded (not counted).

[audit: 08-error-recovery.md §HAL Error Threshold]

---

## Frame Stall Detection

Two independent stall detection mechanisms run concurrently. Their semantics differ:

**GPU-level stall (3000ms threshold)**:
- Detects absence of frame arrivals at the GPU pipeline.
- Emits `FRAME_STALL` to the application layer as informational.
- Does not trigger the recovery path.
- The camera-result-level watchdog (below) handles the actual recovery decision.

**Capture-result-level stall (5000ms threshold)**:
- Detects absence of camera hardware completion notifications.
- Emits `FRAME_STALL` and triggers full recovery.
- The watchdog timer is initialized at session configuration time (not at device open time) to prevent false stalls during the initialization window before the first frame arrives.
- The watchdog is cancelled during both types of teardown.

[audit: 08-error-recovery.md §Stall Watchdog (CameraController), §Stall Watchdog (GpuPipeline)]

---

## AE Convergence Notification

When auto-exposure transitions to a "searching" state and remains in that state for more than **5000ms**, a non-fatal `AE_CONVERGENCE_TIMEOUT` error is emitted. This notification fires once per convergence cycle (the timer resets when AE begins searching again from a new trigger). No recovery is attempted — this is purely informational.

[audit: 08-error-recovery.md §AE Convergence Timeout]

---

## FPS Degradation Notification

Every 30 frames, the system computes the current frame rate from the sensor-reported frame duration. If the computed rate is below **15.0 fps** for **3 consecutive** measurement intervals, a non-fatal `FPS_DEGRADED` error is emitted. The streak counter resets on any measurement above threshold. No recovery is attempted.

[audit: 08-error-recovery.md §FPS Degradation]

---

## Self-Healing from Camera-in-Use Error

If the session enters the terminal error state due to the camera being held by another process, the system registers for camera availability notifications. When the camera becomes available:

1. Internal state resets from terminal-error to closed.
2. The camera open sequence begins automatically.
3. No user action is required.

This path allows recovery from `"error"` state in the specific case of camera-in-use conflicts, without the user having to restart the app.

[audit: 08-error-recovery.md §self-healing]

---

## teardown vs. teardownSession

The system has two teardown depths:

| Full teardown | Session-only teardown |
|---|---|
| Closes camera device | Retains camera device |
| Stops and releases active recording | Does not touch recording |
| Used by: `close()`, recovery, fatal error, background suspend | Used by: `pause()` |
| Resets all counters | Resets capture-session-level counters only |

Both teardown paths:
- Cancel stall watchdog.
- Close capture session.
- Stop GPU pipeline.
- Release pipeline object (platform-defined mutual exclusion with in-flight captures).

[audit: 08-error-recovery.md §teardown() vs teardownSession()]
