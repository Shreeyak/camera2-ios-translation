# Stage 10 — Video recording (HEVC MP4) + AE frame-rate range

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 04, Stage 09, Stage 02

## 2. Starting state
Scaffolding still live: (none)
What's built (permanent): Package.swift (+ `CameraKitCxx` + `CameraKitInterop`); `CameraEngine` (open/close/background*/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/captureImage/getNativePipelineHandle/stateStream/frameResultStream/errorStream); full Pass 1 + Pass 2 + Pass 3 + Pass 4 + Pass 6; `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata` + `FrameSet`; three-pool trio + still-capture pool; C++ `PixelSinkPool` (Mechanism A, D-01) with C-ABI callbacks (D-03); Canny stub consumer (ADR-29); `std::atomic<bool>` capture-in-flight guard (C++); TIFF capture + EXIF + Photos authorization + documents fallback; D-10 completion-handler re-entrancy guard; `Watchdog` pair + `RecoveryCoordinator` + AE/FPS notifications; self-heal for `CAMERA_IN_USE`; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz; tracker thumbnail + debug overlay.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `captureImage(outputPath:)`, `getNativePipelineHandle()`, `stateStream()`, `frameResultStream()`, `errorStream()`, `ConsumerRegistry.subscribe(stream:)`, `ConsumerRegistry.registerCallback(stream:callbacks:)`, `ConsumerRegistry.unregister(token:)`.

## 3. Goal
Pressing Record begins a timer and writes an `.mp4`. Stop finalizes and the recording appears in Photos. During recording, the preview remains at the target frame rate; low-light tests confirm AE drops below 30fps per the recording-mode frame-rate range.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/MetalPipeline.swift — add Pass 5 (RGBA16F → NV12 compute conversion) writing into IOSurface-backed encoder pool buffers per ADR-06; the encoder pool is separate from the three consumer pools (NV12 `ENCODER_PIXEL_FORMAT`); Pass 5 runs only while recording.
- create: Sources/CameraKit/Recording.swift (permanent) — `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` coordinator; HEVC codec + MP4 container (D-04); `startRecording(options:)` / `stopRecording()` flows per `06-capture-and-recording.md`; `finishWriting` invoked with `RECORDING_FINISH_TIMEOUT_SECONDS` deadline; expiry path invokes `cancelWriting()` (not `finishWriting`) to avoid corrupt MP4 (ADR-16, G-08); `DRAIN_TIMEOUT_SECONDS` governs EOS drain.
- modify: Sources/CameraKit/CameraEngine.swift — implement `startRecording(options:) -> RecordingStart`; `stopRecording() -> String` returning the final URI; `pause()` and `resume()` implementations:
  - `pause()` during recording synchronously awaits `finishWriting` on the engine actor without `UIApplication.beginBackgroundTask` (scaffolding:10:synchronous-drain-pause — background drain lands in Stage 12);
  - `pause()` outside recording tears down the session per `03-camera-session.md` §Teardown (session-only teardown, device retained);
  - `resume()` restarts the session;
  - implement `recordingStateStream()` as `.bufferingOldest(64)` per ADR-22.
- modify: Sources/CameraKit/CameraSession.swift — AE frame-rate range: preview mode `activeVideoMinFrameDuration = activeVideoMaxFrameDuration = 1/FRAME_RATE_TARGET_FPS`; recording mode `activeVideoMaxFrameDuration = 1/FRAME_RATE_RECORDING_MIN_FPS` (allows AE to halve); commits inside `lockForConfiguration()` on `sessionQueue`.
- modify: Sources/CameraKit/CaptureDelegate.swift — while recording, submit each converted NV12 buffer to `AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)` with the capture PTS; drop frames if the adaptor reports `isReadyForMoreMediaData == false` (D-10 guard continues to protect completion handlers).
- modify: Sources/CameraKit/Errors.swift — add `RecordingError` variants: `notReadyForMoreMediaData`, `finalizeTimeout`, `finalizeFailed`, `cancelledByPause`; `RecordingState` enum (`idle` / `recording` / `finalizing` / `paused`); `EngineError.recording(RecordingError)`.
- modify: Sources/CameraKit/TexturePoolManager.swift — add encoder `CVPixelBufferPool` (NV12) sized per `POOL_MIN_BUFFER_COUNT` with IOSurface backing + Metal compatibility.
- modify: Sources/CameraKit/CameraView.swift — record/stop button + timer in the bottom bar; recording indicator (red dot) (polish is Stage 11).
- modify: Sources/CameraKit/ViewModel.swift — record-button action calls `engine.startRecording(options:)` / `stopRecording()`; `for await` on `recordingStateStream()`; timer increments while `.recording`.
- create: Tests/CameraKitTests/Stage10Tests.swift — see §8.

## 5. Architecture refs
- architecture/06-capture-and-recording.md#video-recording
- architecture/06-capture-and-recording.md#d-04-recording-container-and-codec-hevc-in-mp4
- architecture/06-capture-and-recording.md#recording-sink-back-pressure
- architecture/06-capture-and-recording.md#pause-crop-resolution-interactions
- architecture/06-capture-and-recording.md#mode-switching-preview-recording
- architecture/04-metal-pipeline.md#command-graph
- architecture/03-camera-session.md#interruption-handling
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/08-capture-and-recording.md
- domain-revised/02-frame-delivery.md
- domain-revised/09-ui-behaviors.md

## 7. Contracts & invariants
- Recording container is MP4 (`AVFileType.mp4`) with HEVC 8-bit; no MOV, no H.264 fallback (D-04, OQ-03).
- `AVAssetWriter.finishWriting` runs with `RECORDING_FINISH_TIMEOUT_SECONDS = 5` deadline; expiry path invokes `cancelWriting()` (not `finishWriting`) producing an empty file rather than a corrupt MP4 (ADR-16, G-08).
- NV12 destination is IOSurface-backed `CVPixelBuffer` dequeued from the encoder pool; Pass 5 compute conversion from RGBA16F (`WORKING_PIXEL_FORMAT`) to NV12 (`ENCODER_PIXEL_FORMAT`) per ADR-06.
- AE frame-rate range: preview fixed at `FRAME_RATE_TARGET_FPS`; recording `(FRAME_RATE_RECORDING_MIN_FPS, FRAME_RATE_TARGET_FPS)`; commits on `sessionQueue` inside `lockForConfiguration()` (U-16).
- Pause-during-recording drives finalize-then-teardown on `sessionQueue` (U-18); `pause()` returns only after `stateStream` reaches `.paused`.
- `10:synchronous-drain-pause` — `pause()` during recording synchronously awaits `finishWriting` on the engine actor; background-task integration lands in Stage 12 where the scaffold retires.
- Fatal finalization failure (encoder error, disk full) emits `onError(RECORDING_FAILED, isFatal: true)` before the state transition.
- `recordingStateStream()` uses `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` (ADR-22) — every transition must be delivered.
- Adaptor back-pressure: when `isReadyForMoreMediaData == false`, the frame is dropped and the drop surfaces via `FrameDeliveryStats` once Stage 12 wires it; the encoder pool never grows beyond its cap.

## 8. Tests to write
- TESTABLE: 10:record-start-stop-happy-path — fake `AVAssetWriter`; `startRecording(options:)` transitions `.idle` → `.recording`; 30 injected frames appended; `stopRecording()` → `.finalizing` → `.idle` with a final URI; the returned URI points to an `.mp4` file.
- TESTABLE: 10:recording-truncated-on-deadline — fake `AVAssetWriter` where `finishWriting` hangs past `RECORDING_FINISH_TIMEOUT_SECONDS`; the coordinator calls `cancelWriting()` (not `finishWriting`); emits `onError(RECORDING_TRUNCATED, isFatal: false)`; the file is empty (0 bytes or invalid MP4 header, depending on writer — verify with `AVAssetExportSession` refusing to open).
- TESTABLE: 10:ae-frame-rate-range-toggles-on-mode — fake `AVCaptureDevice` observing `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` writes; preview commits `(1/30, 1/30)`; start recording commits `(1/30, 1/15)`; stop recording reverts to `(1/30, 1/30)`.
- TESTABLE: 10:nv12-encoder-pass-byte-layout — inject a known RGBA16F texture; Pass 5 output `CVPixelBuffer` plane-0 (Y) and plane-1 (UV interleaved) byte layout matches the closed-form YUV conversion; both planes are IOSurface-backed.
- TESTABLE: 10:pause-during-recording-finalizes-synchronously — call `pause()` while recording; the returned `pause()` Task completes only after the writer has finalized (or cancelled on timeout); `stateStream` observes `.paused`; `recordingStateStream` observes `.idle` with final URI.
- TESTABLE: 10:resume-from-pause-restarts-session — `pause()` then `resume()`; `sessionState` returns to `.streaming`; the next frame's `FrameSet` publishes successfully.
- TESTABLE: 10:adaptor-not-ready-drops-frame — fake adaptor reports `isReadyForMoreMediaData = false` for 3 frames; those frames are dropped; writer output contains 27 samples out of 30 injected (or equivalent back-pressure metric).
- TESTABLE: 10:fatal-finalize-emits-recording-failed — fake writer returns `.failed` status on `finishWriting`; `errorStream` yields `RECORDING_FAILED` with `isFatal = true` before the state transition.
- HITL: 10:mp4-plays-in-photos — record 10s on device; confirm Photos lists the `.mp4`; playback plays; metadata shows HEVC codec; device: iPad Pro M1.
- HITL: 10:low-light-ae-drops-below-30fps — cover sensor while recording; AE allows frame rate to drop toward 15fps as documented; preview visible frame rate decreases; device: iPad Pro M1.
- DEFERRED: 10:empirical-format-fps-range-fallback — if the target hardware's active format does not support exact `(1/30, 1/30)`, record the fallback behavior (closest range or error); evidence in `measurements/` (U-16).

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL 10:mp4-plays-in-photos and 10:low-light-ae-drops-below-30fps confirmed on iPad Pro M1.
- [ ] `grep -rn '10:synchronous-drain-pause' Sources/` ≥1 hit; no other scaffolds live.
- [ ] DEFERRED 10:empirical-format-fps-range-fallback recorded in `measurements/stage-10/`.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage[01][0-9]Tests"` (runs stages 01–10).
- Scaffold inventory: only `10:synchronous-drain-pause` live.
- Device smoke on iPad Pro M1: record 10s MP4, play back in Photos; cover sensor for low-light test; pause-during-recording; confirm finalized file in Photos; resume.
- Disk inspection: `mediainfo` or `ffprobe` on the produced `.mp4` — codec `HEVC`, container `MP4`.

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): Pass 5 RGBA16F→NV12 compute; encoder `CVPixelBufferPool` (IOSurface-backed NV12); `Recording` coordinator (`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`, HEVC-in-MP4); `RECORDING_FINISH_TIMEOUT_SECONDS` deadline + `cancelWriting()` expiry path; AE frame-rate-range toggle preview↔recording; `RecordingState` enum + `RecordingError` variants; record/stop UI + timer + recording indicator (initial).
- Adds (public API): `startRecording(options:)`, `stopRecording()`, `pause()`, `resume()`, `recordingStateStream()`.
- Adds (scaffolding): 10:synchronous-drain-pause.
- Evidence: HITL 10:mp4-plays-in-photos, 10:low-light-ae-drops-below-30fps, DEFERRED 10:empirical-format-fps-range-fallback — `measurements/stage-10/recording.md`.
