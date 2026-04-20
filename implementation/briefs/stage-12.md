# Stage 12 — Background recording drain + observability (MIGRATION)

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 06, Stage 08, Stage 10
Retires scaffolding from: Stage 10 (synchronous-drain-pause)

## 2. Starting state
Scaffolding still live: 10:synchronous-drain-pause
What's built (permanent): Package.swift (+ `CameraKitCxx` + `CameraKitInterop`); `CameraEngine` full public surface; full Pass 1 + 2 + 3 + 4 + 5 + 6; `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata` + `FrameSet`; three-pool trio + still-capture pool + encoder pool; C++ `PixelSinkPool` with C-ABI callbacks + Canny stub; D-10 completion-handler re-entrancy guard; `Watchdog` pair + `RecoveryCoordinator` + AE/FPS notifications; self-heal for `CAMERA_IN_USE`; TIFF capture + HEVC MP4 recording; AE frame-rate-range toggle; full UI polish per `domain-revised/09-ui-behaviors.md` including sidebar / toast / blocking dialog / landscape-right lock / slider debouncer / Liquid Glass; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz; `FrameDeliveryStats` long-press overlay (stream empty until now).
Public API exposed so far: full surface from Stage 11.

## 3. Goal
- Adds: `UIApplication.beginBackgroundTask` around the recording drain per `06-capture-and-recording.md` §Background drain; the expiration handler calls `writer.cancelWriting()` (never `finishWriting()`) per ADR-16 / G-08; `FrameDeliveryStats` emission plumbed from the C++ pool (`mailbox_overwrite_count`) via a C-ABI metrics callback and merged with Swift-side per-lane counters per D-11; quality-gate assertion — `PixelSink` registration without an `onOverwrite` callback is rejected (G-26 avoidance per D-11).
- Removes: 10:synchronous-drain-pause.
- Behavior preserved: record-start-stop-happy-path (10:record-start-stop-happy-path) and truncation on finalize timeout (10:recording-truncated-on-deadline).

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/Recording.swift — wrap the recording drain (triggered by `pause()`-during-recording, `backgroundSuspend()`-during-recording, or `stopRecording()` at scenePhase `.background`) with `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`; the expiration handler invokes `writer.cancelWriting()` (not `finishWriting()`); every path `endBackgroundTask(_:)` on completion.
- modify: Sources/CameraKit/CameraEngine.swift — remove the `scaffolding:10:synchronous-drain-pause` comment; `pause()` during recording now schedules the finalize via the background-task-wrapped drain; `backgroundSuspend()` during recording kicks the same path.
- create: Sources/CameraKitCxx/include/PixelSinkMetrics.h (permanent) — C header with `PixelSinkMetrics` struct + metrics-callback function-pointer type carrying `mailbox_overwrite_count` per stream ID.
- modify: Sources/CameraKitCxx/PixelSinkPool.cpp — accumulate per-lane `mailbox_overwrite_count` atomically; invoke the registered metrics callback on a cadence (one per FPS window); assert in `registerCallbacks` that `on_overwrite != nullptr` else reject with an error code that Swift surfaces as `InteropError.missingOnOverwrite` (G-26 / D-11 quality gate).
- modify: Sources/CameraKit/Consumer.swift — surface the C++ pool's metrics-callback wiring; add `ConsumerRegistry.metricsStream() -> AsyncStream<FrameDeliveryStats>` aggregating Swift-side per-lane drop counters + C++ `mailbox_overwrite_count` values per D-11; `registerCallback(stream:callbacks:)` additionally rejects callbacks with `on_overwrite == nil`.
- modify: Sources/CameraKit/FrameSet.swift — ensure `FrameDeliveryStats` value type exports the merged counters.
- modify: Sources/CameraKit/CameraView.swift — wire the `FrameDeliveryStats` long-press overlay (stubbed since Stage 11) to the real stream; overlay now displays live per-lane overwrite counts from both sides.
- modify: Sources/CameraKit/ViewModel.swift — `for await stats in consumers.metricsStream()` updates the overlay binding.
- create: Tests/CameraKitTests/Stage12Tests.swift — see §8.

## 5. Architecture refs
- architecture/06-capture-and-recording.md#recording-sink-back-pressure
- architecture/06-capture-and-recording.md#pause-crop-resolution-interactions
- architecture/06-capture-and-recording.md#mode-switching-preview-recording
- architecture/06-capture-and-recording.md#teardown
- architecture/05-consumers.md#d-11-framedeliverystats-aggregates-swift-c-counters-via-a-single-stream
- architecture/05-consumers.md#observability
- architecture/05-consumers.md#quality-gate-g-26-avoidance
- architecture/02-concurrency.md#cross-subsystem-sequencing
- architecture/08-ui.md#debug-surface-development-builds-only

## 6. Domain refs
- domain-revised/08-capture-and-recording.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/06-error-and-recovery.md
- domain-revised/02-frame-delivery.md

## 7. Contracts & invariants
- The recording drain runs inside `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` per `06-capture-and-recording.md` §Background drain; expiration → `writer.cancelWriting()` (never `finishWriting()`; ADR-16, G-08) producing an empty file rather than corrupt MP4.
- `endBackgroundTask(_:)` is called on every exit path (success, expiry, error).
- `FrameDeliveryStats` aggregates Swift-side per-lane drop counters and C++ `PixelSinkPool` `mailbox_overwrite_count` via a C-ABI metrics callback into a single `AsyncStream<FrameDeliveryStats>` (D-11).
- `PixelSink` registration without an `onOverwrite` callback is rejected at `registerCallback` (G-26 avoidance, per D-11) — the pool cannot silently drop frames with no observability.
- The emitted `FrameDeliveryStats` cadence is one sample per FPS measurement window (`FPS_MEASUREMENT_WINDOW_FRAMES`); consumers receive counter deltas, not cumulative.
- Background-task expiration handler runs on an arbitrary queue; it schedules `cancelWriting` through a non-blocking path that does not require the engine actor.

## 8. Tests to write
- TESTABLE: 12:background-task-drain-produces-finalized-mp4 — synthesize a `scenePhase` `.background` transition while recording; fake `UIApplication` hands out a background-task identifier; the drain calls `finishWriting` within the fake's budget → final `.mp4` produced; `endBackgroundTask` called exactly once.
- TESTABLE: 12:expiration-handler-cancels-not-finishes — fake `UIApplication` fires the expiration handler while the drain is in flight; `writer.cancelWriting()` is called; `writer.finishWriting` is NOT called after expiration; the file is empty per ADR-16.
- TESTABLE: 12:pixel-sink-registration-without-on-overwrite-rejected — `ConsumerRegistry.registerCallback(stream:callbacks:)` with `callbacks.on_overwrite = nil` throws `InteropError.missingOnOverwrite`; registration with a non-nil `on_overwrite` succeeds.
- TESTABLE: 12:frame-delivery-stats-merges-swift-and-cpp-counters — inject synthetic drops on both Swift and C++ lanes; `metricsStream()` yields a `FrameDeliveryStats` whose fields reflect both sides within one `FPS_MEASUREMENT_WINDOW_FRAMES`.
- TESTABLE: 12:end-background-task-called-on-all-paths — assert `endBackgroundTask` is called in: (a) normal finalize, (b) expiration cancel, (c) writer-error path; a test-visible counter reaches 1 per scenario.
- TESTABLE: 10:record-start-stop-happy-path — carried forward; still passes with the background-task wrapping in place.
- TESTABLE: 10:recording-truncated-on-deadline — carried forward; still passes via the `cancelWriting` path now reachable via two triggers (finalize-timeout OR expiration).
- HITL: 12:home-button-drain-produces-finalized-mp4-device — start recording, home-button to background mid-recording; final `.mp4` lands in Photos (up to the background-task budget) OR if budget exceeded, an empty file is recorded (never corrupt); device: iPad Pro M1.
- HITL: 12:debug-overlay-shows-live-overwrite-counts — long-press debug overlay while a slow subscriber causes drops; counts update live from both Swift and C++ sides; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
- 10:record-start-stop-happy-path
- 10:recording-truncated-on-deadline

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged (including the two §9 preserved tests).
- [ ] New TESTABLE tests pass.
- [ ] HITL 12:home-button-drain-produces-finalized-mp4-device and 12:debug-overlay-shows-live-overwrite-counts confirmed on iPad Pro M1.
- [ ] `grep -rn '10:synchronous-drain-pause' Sources/` returns 0 hits.
- [ ] `grep -rn -E '01:|04:|06:|07:|10:' Sources/` returns 0 hits (every scaffold across the corpus is retired).

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test` (full sweep, all stages).
- Scaffold inventory: no scaffolds live.
- Device smoke on iPad Pro M1: home-button during 10s recording (ensure finalized `.mp4`); force low-memory expiration via debug harness; confirm empty file not corrupt; slow-subscriber stress with overlay visible; landscape-right still enforced.
- Instruments: Time Profiler across a 30s background-drain; ensure `endBackgroundTask` invariant holds and no leaked UIBackgroundTaskIdentifier.

## 12. State.md updates (Claude Code writes these)
- Retires: 10:synchronous-drain-pause.
- Adds (permanent): `UIApplication.beginBackgroundTask` wrapping the recording drain; expiration-handler `cancelWriting()` path; `PixelSinkMetrics` C-ABI metrics callback with merged `FrameDeliveryStats` stream (D-11); `G-26`-avoidance quality gate rejecting `on_overwrite == nil` registrations; debug overlay now live-populated.
- Adds (public API): `ConsumerRegistry.metricsStream() -> AsyncStream<FrameDeliveryStats>`.
- Evidence: HITL 12:home-button-drain-produces-finalized-mp4-device, 12:debug-overlay-shows-live-overwrite-counts — `measurements/stage-12/observability.md`.
