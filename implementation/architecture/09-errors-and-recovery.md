# 09 — Errors and Recovery

Primary-owner file for **error classification**, **recovery state machine**, **watchdog
discipline**, and **self-healing**. Teardown ordering is in `03-camera-session.md`; the
cross-subsystem error → recovery sequence is in `02-concurrency.md` §Sequence C.

---

## Classification

Every error is classified at detection time. The `CameraError` (`api-skeletons/Sources/CameraKit/Errors.swift`)
carries `code: ErrorCode`, `message: String`, `isFatal: Bool`. The engine emits errors on
`errorStream()` per `02-concurrency.md` §Streams owned by the engine.

### Fatal (terminal) codes

| Code | Trigger |
|---|---|
| `CAMERA_NOT_FOUND` | No device matches `.builtInWideAngleCamera` + `.back` |
| `CAMERA_IN_USE` | `AVCaptureSessionWasInterrupted` reason = `videoDeviceInUseByAnotherClient` |
| `PERMISSION_DENIED` | `AVCaptureDevice.authorizationStatus` == `.denied` or `.restricted` (G-16 / ADR-08) |
| `RECORDING_START_FAILED` | `AVAssetWriter.startWriting` fails |
| `RECORDING_FAILED` | `AVAssetWriter.status == .failed` during recording |
| `MAX_RETRIES_EXCEEDED` | Recovery retry count reaches `constants.md#RECOVERY_MAX_RETRIES` |

### Non-fatal (recoverable) codes

| Code | Trigger | Recovery |
|---|---|---|
| `CONFIGURATION_FAILED` | `session.canAddInput/Output` false, or configuration commit throws | Full teardown + reopen |
| `CAMERA_DISCONNECTED` | `AVCaptureSessionWasInterrupted` with device-loss semantics | Full teardown + reopen |
| `CAMERA_ACCESS_ERROR` | General access failure during lock window | Full teardown + reopen |
| `CAPTURE_FAILURE` | `constants.md#HW_ERROR_THRESHOLD_CONSECUTIVE` consecutive frame-level failures | Full teardown + reopen |
| `FRAME_STALL` (capture-level, 5s) | `constants.md#STALL_CAPTURE_THRESHOLD_MS` elapsed without a capture-result | Full teardown + reopen |
| `UNKNOWN_ERROR` | Any unclassified `MTLCommandBuffer.error` / Metal / AVFoundation error | Full teardown + reopen with backoff |

### Synchronous-rejection (no state transition, no retry)

| Code | Trigger |
|---|---|
| `SETTINGS_CONFLICT` | ISO + exposure coupling violation (Rule 3) / out-of-range values (`07-settings.md`) |

### Notification-only (no recovery)

| Code | Trigger |
|---|---|
| `FRAME_STALL` (GPU-level, 3s) | `constants.md#STALL_GPU_THRESHOLD_MS` elapsed at GPU watchdog |
| `AE_CONVERGENCE_TIMEOUT` | AE searching past `constants.md#AE_CONVERGENCE_TIMEOUT_MS` |
| `FPS_DEGRADED` | Below `constants.md#FPS_DEGRADED_THRESHOLD_FPS` for `constants.md#FPS_DEGRADED_STREAK_COUNT` streak |
| `RECORDING_TRUNCATED` | Drain timed out during stop; file exists but may be incomplete |

`FRAME_STALL` disambiguation: which watchdog fired is carried in the error's `message`
string (prefixed with `"gpu:"` or `"capture:"`) so the UI can distinguish; domain 06 §Frame
Stall Detection specifies the two watchdogs' semantics differ but the code is the same.

### `EngineError` vs `CameraError`

- `EngineError` is the typed-throws surface on `CameraEngine` methods per ADR-25.
  Structural: distinguishes metal / interop / recording / fatal buckets for exhaustive
  switch at the call site.
- `CameraError` is the `onError` payload emitted on `errorStream` — matches the domain
  wire format. The engine maps `EngineError` to `CameraError` for emission.

---

## Recovery state machine

```
.streaming ──(non-fatal error)──► .recovering ──(retry fires)──► .streaming
                                  │                              │
                                  └─(retry budget exhausted)─► .error (fatal)
                                  │
                                  └─(close or bgSuspend)──► .closed / (retained)
```

Full state machine lives on the engine actor. Transitions emit on `stateStream`.

### Non-fatal recovery sequence

Cross-cited from `02-concurrency.md` §Sequence C. Primary-owner file (this one). Executed
on the engine actor as a single actor-serialized method:

1. **Disarm watchdogs** (step 1, before any state change) — see D-13 below.
2. Check terminal state: if `sessionState == .error`, exit. No duplicate recovery.
3. Check background suspension: if `isBackgroundSuspended == true`, transition to
   `.closed` silently and exit. Recovery does not run in background.
4. Transition `sessionState` to `.recovering`; emit on `stateStream`.
5. Emit `CameraError(code: ..., message: ..., isFatal: false)` on `errorStream`.
6. Increment retry count. If `retryCount > constants.md#RECOVERY_MAX_RETRIES`, transition
   to fatal `MAX_RETRIES_EXCEEDED` (see §Fatal sequence).
7. Cancel any pending retry `Task` (Invariant 9; idempotent cancel is safe).
8. Schedule new retry `Task` with delay
   `constants.md#RECOVERY_BACKOFF_<n>_MS` (where `<n>` is the current retry count, clamped
   to `RECOVERY_BACKOFF_5_PLUS_MS`). The task body:
   - `try? await Task.sleep(for: .milliseconds(delayMs))`
   - `try? Task.checkCancellation()`
   - Double-check `sessionState == .recovering` (Inv 9 — cancellation may have fired during
     the sleep).
   - Run full teardown (`03-camera-session.md` §Full teardown) then reopen (`open()` path).
   - On successful open, reset retry count to 0 per domain 06 §Exponential Backoff.
   - On open failure: recursively invoke recovery with the new error (the retry count
     advances).

### Fatal sequence

1. Run full teardown (same sequence as non-fatal, but no reopen).
2. Transition `sessionState` to `.error`.
3. Emit `.error` on `stateStream`.
4. Emit `CameraError(code: ..., isFatal: true)` on `errorStream`.
5. No further state transitions from `.error` except via self-healing (D-14) for
   `CAMERA_IN_USE` only.

### Duplicate-recovery suppression

Per domain 06 §Duplicate Recovery Suppression:
- If a recovery retry is already pending and a new non-fatal error arrives, the pending
  retry is cancelled and a new one scheduled with the fresh delay. Prevents stacking
  retries.
- If a hardware-level frame failure arrives while `sessionState == .recovering`, it is
  silently discarded (no counter increment).

### Recovery cancellation

Per domain 06 §Recovery Cancellation and Invariant 9:
- `close()` cancels the retry `Task` via `.cancel()`; the task's cancellation check aborts
  the teardown-reopen.
- `backgroundSuspend()` cancels the retry `Task` for the same reason; the engine still runs
  `close()`-equivalent teardown on resume? **No** — per domain 05, background does not
  teardown; the session is interrupted. The retry stays cancelled; on foreground, the
  system interruption-ended signal restarts the session without a retry attempt (if the
  cause was background interruption). If the original error is still present on resume, a
  fresh error detection kicks off a new recovery cycle.

---

## D-13 — Watchdog disarm precedes all recovery actions

Minor. Primary-owner file for the watchdog-first step of recovery.

### Context

Domain 06 §Non-Fatal Recovery Sequence step 1 requires disarming both watchdogs before
*any* state transition or further classification. Invariant 12 requires that a watchdog
callback observing a session other than its armed-time session is a no-op.

### Implementation

`Watchdog.disarmAll()` is the first action in recovery. The watchdog pair
(GPU-level at `constants.md#STALL_GPU_THRESHOLD_MS`, capture-result-level at
`constants.md#STALL_CAPTURE_THRESHOLD_MS`) is implemented as two `DispatchSourceTimer`s or
`Task.sleep`-based schedulers, each carrying a captured session-token.

- `Watchdog.armGPU()` / `.armCapture()` — set the next-fire time; increment the session
  token the watchdog is bound to.
- `Watchdog.refresh()` — called on each successful frame observation (GPU) or each
  capture-result completion (capture); sets last-observed timestamp via
  `ManagedAtomic<UInt64>` so the watchdog reader is lock-free (Inv 11).
- `Watchdog.disarmAll()` — invalidates the timers. Any still-pending callback compares its
  captured token against the current one and no-ops on mismatch (Inv 12).

Watchdogs are **dormant** until the first observation per domain 02 §Watchdog lifecycle —
arming the watchdog only starts the timer after first frame / first capture-result.

Disarm is also step 1 of full teardown per `03-camera-session.md` §Full teardown (which
hosts the authoritative sequence; this file owns the invariant `"disarm first"`).

---

## D-14 — Self-healing scope and mechanism

Minor. Primary-owner file (this one) for the self-healing path.

### Context

Domain 06 §Self-Healing requires that `CAMERA_IN_USE` terminal error self-heals when the
camera becomes available. On iOS the availability signal is
`AVCaptureSessionInterruptionEnded` with reason `videoDeviceInUseByAnotherClient`; per
`ios-platform-guide/04-avfoundation.md` §Interruption reasons, **user intent is required**
for auto-resume on that reason.

### Decision

Two-phase self-healing:
1. **Automatic state reset**: on `interruptionEnded` with reason
   `videoDeviceInUseByAnotherClient` while `sessionState == .error`, the engine's interruption
   observer calls `engine.resetFromTerminal()` which transitions state `.error → .closed`.
2. **Manual `open()`**: the host (UI) observes the `.closed` state and prompts a "Resume"
   button or auto-triggers based on product-level UX choice. Re-entry into `.opening` is
   the standard `engine.open(configuration:)` path.

This preserves the domain's self-healing intent (no user action inside the camera layer for
state reset) while honouring iOS policy (host must drive resume). See
`open-questions.md` §OQ-04 for the full disposition.

### Scope

Applies only to `CAMERA_IN_USE` terminal error. Other fatal states (`PERMISSION_DENIED`,
`RECORDING_START_FAILED`, `MAX_RETRIES_EXCEEDED`, `CAMERA_NOT_FOUND`) require a fresh
`close() + open()` and do not auto-reset.

---

## Stall watchdogs

### GPU watchdog (3s)

- Armed when `sessionState == .streaming` and the first frame has arrived (domain 02
  §Watchdog Lifecycle).
- Fires if no frame has arrived in `constants.md#STALL_GPU_THRESHOLD_MS`.
- Emits `FRAME_STALL` with `message` prefixed `"gpu:"`; `isFatal: false`. No recovery
  triggered.
- Re-armed on each frame arrival (timestamp refresh via atomic).

### Capture-result watchdog (5s)

- Armed when the capture session reports successful configuration (i.e. after
  `commitConfiguration()` returns), not at session open.
- Fires if no capture-result completion has arrived in
  `constants.md#STALL_CAPTURE_THRESHOLD_MS`.
- Emits `FRAME_STALL` with `message` prefixed `"capture:"`; `isFatal: false`; **triggers
  full recovery** per domain 06 §Frame Stall Detection.

Both watchdogs are disarmed as step 1 of teardown and recovery per D-13. Callbacks
scoped to originating session via captured token per Invariant 12.

---

## AE convergence notification

Tracked via `DeviceStateSnapshot.isAdjustingExposure`. When the value transitions `false →
true`, start a `Task` that sleeps `constants.md#AE_CONVERGENCE_TIMEOUT_MS`; if
`isAdjustingExposure` is still `true` at wake, emit `AE_CONVERGENCE_TIMEOUT` (non-fatal,
notification-only). Reset the timer on each transition.

Fires once per convergence cycle (domain 06 §AE Convergence Notification).

---

## FPS degradation notification

Every `constants.md#FPS_MEASUREMENT_WINDOW_FRAMES` frames, compute instantaneous FPS from
`frameDurationNs` in the most recent `CaptureMetadata` (or from measured frame arrivals).
If the computed rate is below `constants.md#FPS_DEGRADED_THRESHOLD_FPS`, increment a streak
counter; on hitting `constants.md#FPS_DEGRADED_STREAK_COUNT`, emit `FPS_DEGRADED`
(non-fatal). Streak resets on any above-threshold measurement.

No recovery — notification-only per domain 06 §FPS Degradation Notification.

---

## Hardware-error threshold

Consecutive frame-level capture failures are tracked via a counter. Each successful frame
resets to 0. On reaching `constants.md#HW_ERROR_THRESHOLD_CONSECUTIVE`, emit
`CAPTURE_FAILURE` (non-fatal) and enter the recovery sequence.

Failures during `.recovering` are discarded (not counted) per domain 06 §Hardware Error
Threshold.

---

## Metal-level errors

Per G-02 / ADR-15, every `MTLCommandBuffer` installs `addCompletedHandler` that checks
`buffer.status == .error`. On `.error`:
- Classify via the buffer's `.error` property into `MetalError.commandBufferFailed(code:)`.
- Emit as `UNKNOWN_ERROR` (non-fatal) with a descriptive message; the error text carries
  the Metal-level code for diagnostics.
- Enter the recovery sequence.

The completion-handler re-entrancy guard (D-10 in `02-concurrency.md`) applies — a Metal
error arriving after `close()` / `backgroundSuspend()` no-ops silently.

---

## Pool exhaustion

`CVPixelBufferPoolCreatePixelBuffer` returning
`kCVReturnWouldExceedAllocationThreshold` is **not** a recovery trigger. Per
`04-metal-pipeline.md` §Pool configuration and ADR-19, the frame is dropped (no commit);
`poolExhaustion` counter increments; warning is logged identifying the lane with the oldest
outstanding reference. If pool exhaustion becomes persistent (many consecutive frames), the
GPU watchdog catches it via no-frame-arrival and emits `FRAME_STALL` informationally.

---

## Resource cleanup on error paths

Per domain 06 §Resource Cleanup on Error Paths. Every code path that acquires a GPU
resource (IOSurface lock, `CVMetalTexture` wrap, Metal-pool dequeue) must release on **all**
paths. Implemented via:

- Swift `defer { CVPixelBufferUnlockBaseAddress(...) }` patterns.
- `MTLResource` held by `let` locals that go out of scope at function return; ARC releases
  automatically.
- C++ side uses RAII wrappers (`std::lock_guard`, `IOSurfaceGuard`) — no manual `acquire /
  release` sequences in hot paths.

A "silent hang" from a permanently-pinned IOSurface slot is a correctness bug, not a
degradation — caught by the GPU watchdog and surfaced as `FRAME_STALL`.

---

## Recovery interaction with other actors

- With `sessionQueue`: the retry task dispatches teardown + `open()` work that internally
  hops to `sessionQueue` via the async-with-timeout adapter. Timeouts on `sessionQueue`
  operations during recovery escalate to a non-fatal `CAMERA_ACCESS_ERROR` and feed the
  next retry with a fresh backoff.
- With the consumer registry: teardown cancels all consumer `Task`s; fresh `open()`
  re-registers. Consumers observe the `.recovering` / `.streaming` transitions on
  `stateStream` and pause their `for await` during recovery via `Task.checkCancellation()`.
- With recording: if recording is active at error time, it is stopped before teardown per
  `03-camera-session.md` §Full teardown step 2; the output URI is returned via
  `recordingStateStream` as the transition to `.idle`.
