# Stage 09 — Completion guard + stall watchdogs + recovery state machine (MIGRATION)

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 01, Stage 04
Retires scaffolding from: Stage 01 (skip-completion-guard)

## 2. Starting state
Scaffolding still live: 01:skip-completion-guard
What's built (permanent): Package.swift; `CameraEngine` (open/close/background*/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/captureImage/getNativePipelineHandle/stateStream/frameResultStream); full Pass 1 + Pass 2 + Pass 3 + Pass 4 + Pass 6; `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata` + `FrameSet`; three-pool trio + still-capture pool; `ConsumerRegistry` actor with Swift-facade `subscribe(stream:)` + C-ABI `registerCallback(stream:callbacks:)` both over the same C++ `PixelSinkPool` (D-01); OpenCV-backed Canny stub consumer (ADR-29); `std::atomic<bool>` capture-in-flight guard (C++); TIFF capture + EXIF + Photos authorization + documents fallback; tracker thumbnail + debug overlay; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz; `CameraKitCxx` + `CameraKitInterop` targets.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `captureImage(outputPath:)`, `getNativePipelineHandle()`, `stateStream()`, `frameResultStream()`, `ConsumerRegistry.subscribe(stream:)`, `ConsumerRegistry.registerCallback(stream:callbacks:)`, `ConsumerRegistry.unregister(token:)`.

## 3. Goal
- Adds: D-10 completion-handler re-entrancy guard on every `MTLCommandBuffer`; `Watchdog` pair (GPU + capture-result) with `ManagedAtomic<UInt64>` timestamps, captured-`sessionToken` identity (Inv 12), and `disarmAll()` as step 1 of recovery (D-13); `RecoveryCoordinator` implementing `02-concurrency.md` §Sequence C with exponential backoff from `RECOVERY_BACKOFF_*`; self-heal for `CAMERA_IN_USE` via `AVCaptureSessionInterruptionEnded` + reason `videoDeviceInUseByAnotherClient` (D-14); `errorStream()` live; AE convergence + FPS degradation notifications per constants.
- Removes: 01:skip-completion-guard.
- Behavior preserved: color pipeline golden-frame rendering (04:color-pipeline-golden-frame); live preview (01:preview-renders-first-frame).

## 4. Files to create / modify / delete
- create: Sources/CameraKit/Watchdog.swift (permanent) — `Watchdog` with `ManagedAtomic<UInt64>` last-kick timestamp, captured `sessionToken: UInt64` at arm, thresholds `STALL_GPU_THRESHOLD_MS` / `STALL_CAPTURE_THRESHOLD_MS`; a GPU watchdog instance (3s notify-only) and a capture-result watchdog instance (5s triggers recovery); `disarmAll()` static helper.
- create: Sources/CameraKit/RecoveryCoordinator.swift (permanent) — exponential backoff schedule `RECOVERY_BACKOFF_1..5_PLUS_MS`; `HW_ERROR_THRESHOLD_CONSECUTIVE = 5`; `RECOVERY_MAX_RETRIES = 5` → `MAX_RETRIES_EXCEEDED` fatal; owns the pending retry `Task?` per ADR-23 and cancels on `close()` / `backgroundSuspend()`.
- modify: Sources/CameraKit/CameraEngine.swift — install D-10 completion-handler re-entrancy guard on every `commandBuffer.addCompletedHandler`: the handler captures `sessionState` at commit and no-ops if it diverges by handler-time; implement `errorStream()` real body; wire AE convergence (`AE_CONVERGENCE_TIMEOUT_MS`) + FPS degradation (`FPS_DEGRADED_THRESHOLD_FPS`, `FPS_DEGRADED_STREAK_COUNT`, `FPS_MEASUREMENT_WINDOW_FRAMES`) emissions on the error stream (non-fatal).
- modify: Sources/CameraKit/MetalPipeline.swift — remove `scaffolding:01:skip-completion-guard` comment(s); every `addCompletedHandler` closure now takes the D-10 guard; handler-time `sessionState` divergence → handler no-ops and releases the readback buffer slot.
- modify: Sources/CameraKit/CaptureDelegate.swift — kick the GPU watchdog on every frame arrival; kick the capture-result watchdog; on `AVCaptureSession`-level capture failure, increment consecutive-HW-error counter on the engine actor.
- modify: Sources/CameraKit/CameraSession.swift — observe `AVCaptureSessionInterruptionEnded`; when reason is `videoDeviceInUseByAnotherClient`, `RecoveryCoordinator` returns the engine to `"closed"` (D-14, OQ-04); re-entry to `"streaming"` requires an explicit host `open()`.
- modify: Sources/CameraKit/Errors.swift — add `CameraError` taxonomy (code + message + isFatal) for wire-format `errorStream` payload; `ErrorCode` enum with `CAPTURE_FAILURE`, `CAMERA_IN_USE`, `AE_CONVERGENCE_TIMEOUT`, `FPS_DEGRADED`, `MAX_RETRIES_EXCEEDED`; `EngineError.fatal(CameraError)` variant.
- modify: Sources/CameraKit/CameraView.swift — recovery banner for non-fatal recovery; blocking fatal-error dialog (polish is Stage 11; this stage just plumbs the signal).
- modify: Sources/CameraKit/ViewModel.swift — `for await error in engine.errorStream()` → update `@Observable` `currentError` binding.
- create: Tests/CameraKitTests/Stage09Tests.swift — see §8.

## 5. Architecture refs
- architecture/09-errors-and-recovery.md#classification
- architecture/09-errors-and-recovery.md#recovery-state-machine
- architecture/09-errors-and-recovery.md#d-13-watchdog-disarm-precedes-all-recovery-actions
- architecture/09-errors-and-recovery.md#d-14-self-healing-scope-and-mechanism
- architecture/09-errors-and-recovery.md#stall-watchdogs
- architecture/09-errors-and-recovery.md#ae-convergence-notification
- architecture/09-errors-and-recovery.md#fps-degradation-notification
- architecture/09-errors-and-recovery.md#hardware-error-threshold
- architecture/09-errors-and-recovery.md#metal-level-errors
- architecture/09-errors-and-recovery.md#resource-cleanup-on-error-paths
- architecture/02-concurrency.md#cross-subsystem-sequencing
- architecture/02-concurrency.md#d-10-completion-handler-re-entrancy-guard
- architecture/04-metal-pipeline.md#command-graph

## 6. Domain refs
- domain-revised/06-error-and-recovery.md
- domain-revised/04-concurrency-invariants.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/07-performance-budgets.md

## 7. Contracts & invariants
- Every `MTLCommandBuffer.addCompletedHandler` captures the engine's `sessionState` (or `sessionToken`) at `commit()` time; if the handler-time value diverges, the handler no-ops and the readback-buffer slot is released (D-10; G-20 avoidance).
- Watchdogs use `ManagedAtomic<UInt64>` for the last-kick timestamp; a captured `sessionToken` compared at fire time guards against double-recovery (Inv 12).
- Step 1 of recovery is `Watchdog.disarmAll()` — before any state transition (D-13); a late-firing watchdog compares its captured session-token to the current and no-ops.
- Exponential backoff schedule: 500ms, 1s, 2s, 4s, 8s (clamp); `HW_ERROR_THRESHOLD_CONSECUTIVE = 5`; `RECOVERY_MAX_RETRIES = 5` → fatal.
- Self-heal for `CAMERA_IN_USE` uses `AVCaptureSessionInterruptionEnded` reason `videoDeviceInUseByAnotherClient` → engine returns to `"closed"`; re-entry to `"streaming"` requires an explicit host `open()` (D-14, OQ-04).
- AE convergence timeout emits `AE_CONVERGENCE_TIMEOUT` (non-fatal) after `AE_CONVERGENCE_TIMEOUT_MS`.
- FPS degradation emits after `FPS_DEGRADED_STREAK_COUNT` consecutive windows below `FPS_DEGRADED_THRESHOLD_FPS` (window size `FPS_MEASUREMENT_WINDOW_FRAMES`).
- Completion-handler handlers never touch engine actor state directly; they call `Task { await engine.… }` only after the D-10 guard passes (or simply no-op).
- `errorStream()` uses `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` (ADR-22) — every error must be delivered.

## 8. Tests to write
- TESTABLE: 09:completion-guard-no-ops-after-close — inject a synthetic `CMSampleBuffer` so the GPU completion handler will fire after a `close()`; the handler observes `sessionState` divergence, returns early, and does not access released readback-buffer state (verified via a test-only `didNoOpCount` metric).
- TESTABLE: 09:watchdog-captured-token-survives-retry — arm a watchdog with token `T1`; `close()` increments session-token to `T2`; the still-scheduled `T1` callback fires → observes mismatch → no-ops (no `disarmAll` race).
- TESTABLE: 09:exponential-backoff-schedule-matches-constants — synthetic `CAPTURE_FAILURE` stream at 6 consecutive arrivals (exceeds `HW_ERROR_THRESHOLD_CONSECUTIVE`); retry timestamps are 500, 1000, 2000, 4000, 8000 ms from the prior retry's completion (within ±50 ms scheduling jitter); 6th failure emits fatal `MAX_RETRIES_EXCEEDED`.
- TESTABLE: 09:camera-in-use-self-heal-to-closed — inject `AVCaptureSessionWasInterruptedNotification` with reason `videoDeviceInUseByAnotherClient` followed by `AVCaptureSessionInterruptionEndedNotification`; engine transitions to `.closed` without host action; a subsequent host `open()` re-enters `.streaming`.
- TESTABLE: 09:disarm-before-state-transition — instrumented recovery sequence: `Watchdog.disarmAll()` is observed to return before the first `stateStream` transition into recovery (D-13 step order).
- TESTABLE: 09:ae-convergence-timeout-emits — fake device in AE-searching for > `AE_CONVERGENCE_TIMEOUT_MS`; `errorStream` yields a non-fatal `AE_CONVERGENCE_TIMEOUT` error exactly once.
- TESTABLE: 09:fps-degraded-requires-streak — injected sample-buffer cadence of 12fps for 2 windows then 25fps; no `FPS_DEGRADED` emitted (streak not reached); three consecutive low windows → `FPS_DEGRADED` emitted.
- TESTABLE: 09:error-stream-delivers-every-transition — emit five distinct errors rapidly (≤ buffer size); subscriber receives all five in order (`.bufferingOldest(64)` semantics).
- TESTABLE: 04:color-pipeline-golden-frame — carried forward; the completion guard is transparent to correct-path rendering.
- TESTABLE: 01:preview-renders-first-frame — carried forward; the completion guard is transparent to first-frame rendering.
- HITL: 09:recovery-banner-on-simulated-capture-failure — force a `CAPTURE_FAILURE` via a test harness toggle; UI shows recovery banner; after 5 retries shows fatal dialog; device: iPad Pro M1.
- HITL: 09:camera-in-use-self-heal-device — open FaceTime while app is in foreground; observe interruption; close FaceTime; app auto-returns to `.closed`; user taps Resume; preview returns; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
- 04:color-pipeline-golden-frame
- 01:preview-renders-first-frame

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged (including the two §9 preserved tests).
- [ ] New TESTABLE tests pass.
- [ ] HITL tests confirmed on iPad Pro M1.
- [ ] `grep -rn '01:skip-completion-guard' Sources/` returns 0 hits.
- [ ] `grep -rn -E '01:|04:|06:|07:' Sources/` returns 0 hits (all prior-stage scaffolds retired; current session tracks no new scaffolds).

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-9]Tests"`
- Scaffold inventory: no scaffolds live (clean slate through Stage 09).
- Device smoke on iPad Pro M1: simulate `CAPTURE_FAILURE` via the debug toggle; observe backoff sequence; receive and clear the banner; trigger `CAMERA_IN_USE` via FaceTime; confirm self-heal flow.
- Instruments: log `sessionState` at commit vs handler time across 60s; assert 0 re-entrancy violations.

## 12. State.md updates (Claude Code writes these)
- Retires: 01:skip-completion-guard.
- Adds (permanent): D-10 completion-handler re-entrancy guard on every `MTLCommandBuffer`; `Watchdog` pair with `ManagedAtomic<UInt64>` timestamps + captured `sessionToken` (Inv 12); `RecoveryCoordinator` with exponential backoff + retry-task management; AE convergence + FPS degradation notifications; self-heal for `CAMERA_IN_USE` via `AVCaptureSessionInterruptionEnded` (D-14); `CameraError` + `ErrorCode` + `EngineError.fatal`; recovery banner + fatal-error dialog plumbing.
- Adds (public API): `errorStream()`.
- Evidence: HITL 09:recovery-banner-on-simulated-capture-failure, 09:camera-in-use-self-heal-device — `measurements/stage-09/recovery.md`.
