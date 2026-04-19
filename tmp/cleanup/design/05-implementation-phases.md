# 05 — Implementation Phases

Six phases, each with a concrete file tree (no placeholders) and testable acceptance
criteria. Phase order is driven by dependency: later phases cannot begin until
earlier phases pass their acceptance gate.

---

## Phase 1a — Camera Capture + State Machine + Lifecycle + Permissions

Goal: a working `AVCaptureSession` with preview, permission handling, and the full
domain state machine — before any Metal work. Uses `AVCaptureVideoPreviewLayer` for
preview (replaced in Phase 2).

### Files

- `CambrianiOS/App/CambrianiOSApp.swift` — `@main` struct; `scenePhase` routing
  (ADR-08).
- `CambrianiOS/Views/ContentView.swift` — top-level SwiftUI view; holds the
  `CameraControlViewModel`.
- `CambrianiOS/Views/CameraPreviewView.swift` — `UIViewRepresentable` wrapping
  `AVCaptureVideoPreviewLayer` (temporary preview for Phase 1; replaced by
  `MetalPreviewView` in Phase 2).
- `CambrianiOS/ViewModels/CameraControlViewModel.swift` — `@Observable`; subscribes
  to engine's AsyncStreams; owns permission UI state.
- `CambrianiOS/Engine/CameraEngine.swift` — `actor CameraEngine`; open/close/pause/
  resume/backgroundSuspend/backgroundResume surface.
- `CambrianiOS/Engine/CameraStateMachine.swift` — state enum + transition table
  matching domain §06 + iOS-specific states (INTERRUPTED, THROTTLED,
  WAITING_FOR_PERMISSION, RESUME_PENDING).
- `CambrianiOS/Engine/PermissionHandler.swift` — `AVCaptureDevice.authorizationStatus`
  / `requestAccess(for: .video)` (G-16); no microphone permission (G-12, G-24).
- `CambrianiOS/Engine/SessionInterruptionHandler.swift` — observers for
  `.AVCaptureSessionWasInterrupted` / `.InterruptionEnded`; reason-based policy
  table per `ios-platform-guide/04`.
- `CambrianiOS/Engine/ThermalMonitor.swift` — hooks only; observes
  `ProcessInfo.thermalStateDidChangeNotification`; full throttling in Phase 4.
- `CambrianiOS/Engine/SystemPressureMonitor.swift` — KVO on
  `device.systemPressureState`; hooks only.
- `CambrianiOS/Models/CameraState.swift` — `enum CameraState: Sendable` matching
  domain §10 SessionState + iOS-specific states.

### Acceptance Criteria

- Fresh install grants camera permission; preview visible within 1 s.
- Permission denied → app surfaces a blocking UI with "Open Settings" action; no
  crash.
- Background → foreground → preview restores within 1 s (G-07: session is **not**
  recreated; `stopRunning` on `.background`, `startRunning` on `.active`).
- Session interruption by FaceTime produces a Resume button (manual intent;
  `videoDeviceInUseByAnotherClient`); resume on user tap works.
- State machine logs exactly one transition per event (unit test with fake KVO
  source).
- `backgroundSuspend` cancels any pending recovery timer (domain §06 Recovery
  Cancellation; invariant 9).
- Memory stable over a 30-minute idle session at preview-only load.

---

## Phase 1b — Camera Controls (ISO, Exposure, Focus, Zoom, WB)

Goal: every slider in domain §09 drives real hardware. Settings persistence applied
at session open (domain §03 / §05).

### Files

- `CambrianiOS/Engine/DeviceController.swift` — the `sessionQueue.async` wrapper for
  every `lockForConfiguration/defer unlock` bracket (design/02 §4); ISO+exposure
  coupled commit via `setExposureModeCustom(duration:iso:)`.
- `CambrianiOS/Models/CameraControls.swift` — `MergedSettings` struct + merge
  semantics (domain §03 "null means do not change", "Auto is contagious",
  "Manual latches from last readback").
- `CambrianiOS/Models/DeviceCapabilities.swift` — ranges read from
  `device.activeFormat.{min,max}ISO`, `.{min,max}ExposureDuration`,
  `device.maxWhiteBalanceGain` (never hardcoded — `ios-platform-guide/04 §Device
  configuration windows`, G-10, G-22).
- `CambrianiOS/Views/Controls/FocusControlView.swift`
- `CambrianiOS/Views/Controls/ExposureControlView.swift`
- `CambrianiOS/Views/Controls/ISOControlView.swift` — toggle auto/manual paired
  with ExposureControlView (domain §03 coupling rule).
- `CambrianiOS/Views/Controls/AWBControlView.swift` — three per-channel gains +
  Calibrate button stub (full calibrate flow requires Phase 2 sampleCenterPatch).
- `CambrianiOS/Views/Controls/ZoomControlView.swift` — slider + pinch gesture (HIG:
  min 44 pt touch target).
- `CambrianiOS/Extensions/AVCaptureDevice+Configuration.swift` — safe wrappers
  around `setExposureModeCustom`, `setFocusModeLocked`,
  `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains`, `videoZoomFactor`, each
  asserting it's called on `sessionQueue`.

### Acceptance Criteria

- Every slider in the UI moves a real value on a physical device (iPhone 15 Pro or
  later per the A16-class assumption).
- First ISO change after launch does **not** raise `NSGenericException` (proves the
  `lockForConfiguration/defer unlock` bracket is correct on device;
  `ios-platform-guide/04`).
- ISO auto ↔ manual flip coupled with exposure: flipping ISO to manual
  automatically flips exposure to manual (domain §03 Rule 1/2/3).
- Attempting to set manual ISO before first sensor readback returns
  `SETTINGS_CONFLICT` (domain §03 Rule 3).
- Lens position range in the UI matches `0.0 ... 1.0` (G-11); label reads
  "relative focus", never "diopters".
- White balance gain input clamped to `[1.0, device.maxWhiteBalanceGain]` before
  set (G-10).
- Settings persist across `close()` → `open()` (UserDefaults write on every
  successful update; domain §03 Settings Persistence).

---

## Phase 2 — Metal Processing Pipeline

Goal: replace Phase 1's `AVCaptureVideoPreviewLayer` with the full Metal pipeline.
Implements Pass 1–4 of the per-frame command graph (design/03 §2). No consumers
yet; Pass 5/6 stubs.

### Files

- `CambrianiOS/Metal/MetalEngine.swift` — `MTLDevice`, `MTLCommandQueue`, pipeline
  state cache; owns `CVMetalTextureCache` (ADR-04).
- `CambrianiOS/Metal/TextureCacheManager.swift` — zero-copy wrap of biplanar YUV
  (ADR-04, ADR-15 nil-check); `CVMetalTextureCacheFlush` on memory warning.
- `CambrianiOS/Metal/MetalRenderer.swift` — per-frame command-buffer assembly;
  `os_signpost` boundaries per design/03 §8; `addCompletedHandler` for error
  check (G-02, ADR-15); G-20 re-entrancy guard.
- `CambrianiOS/Metal/Shaders/CropColorOps.metal` — Pass 1 (crop + BT.709 YUV→RGB) +
  Pass 2 (color chain in domain §03 order).
- `CambrianiOS/Metal/Shaders/TrackerDownsample.metal` — Pass 4 downsample to 480p.
- `CambrianiOS/Metal/Shaders/Preview.metal` — passthrough fragment for Pass 3a/3b
  fallback (only used if blit path needs a precision conversion).
- `CambrianiOS/Views/MetalPreviewView.swift` — `UIViewRepresentable` wrapping
  `MTKView` for natural + processed preview panes; split-screen layout (domain
  §09). Replaces `CameraPreviewView.swift` in the view hierarchy.
- `CambrianiOS/Models/FrameSet.swift` — the `FrameSet` struct from ADR-18.
- `CambrianiOS/Metal/FrameSetAllocator.swift` — the three `CVPixelBufferPool`s
  (design/03 §5); allocates shared canny texture placeholder (filled in Phase 3).

### Acceptance Criteria

- Split-screen preview (left natural, right processed) visible at 30 fps on
  iPhone 15 Pro.
- Moving the brightness slider visibly affects the right pane within one frame; the
  left pane is unchanged (domain §01 invariants 1 + 5).
- `Instruments → Metal System Trace` shows `CaptureCallback`, `MetalEncode`,
  `MetalScheduled`, `MetalCompleted` signpost intervals on every frame.
- Frame-budget totals ≤ 15 ms under acceptable conditions (design/03 §8).
- `CVMetalTextureGetTexture` nil-check path exercised by a memory-warning
  stress test — frames drop gracefully, no crash (ADR-15, G-01).
- Memory stable under 30-minute streaming stress (no texture-cache leak;
  `CVMetalTexture` released per frame, G-15).

---

## Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out (ADR-13)

Goal: the consumer fan-out path from ADR-13/18/19. Includes the OpenCV
edge-detection proof-of-concept. Phase 2's Pass 4 becomes subscriber-gated; Pass 5/6
remain stubs.

### Files

- `CambrianiOS/Cpp/PixelSink.h` — generic consumer interface per design/04 §1.
- `CambrianiOS/Cpp/FrameSetBridge.h` — POD mirror of `FrameSet` for the C++ side
  (opaque IOSurface handle, metadata scalars).
- `CambrianiOS/Cpp/EdgeDetectionConsumer.h` — public POD header (no OpenCV).
- `CambrianiOS/Cpp/EdgeDetectionConsumer.cpp` — `cv::Canny` + composite; writes
  shared IOSurface; C-ABI write-complete callback (design/04 §5-§7).
- `CambrianiOS/Cpp/ConsumerRegistry.cpp` — C++ side; `std::mutex`; drop-on-busy
  thread pool (`std::min(4, hardware_concurrency())`); lock-order per invariant 5.
- `CambrianiOS/Metal/SharedTextureAllocator.swift` — the one-time allocation of
  the shared canny texture (design/04 §6); full-res, mipmapped, IOSurface-backed.
- `CambrianiOS/Metal/MipmapBlitHelper.swift` — dedicated `mipmapBlitQueue`;
  `MTLBlitCommandEncoder.generateMipmaps(for:)` on write-complete.
- `CambrianiOS/Metal/Shaders/CannyPanZoom.metal` — fragment sampling mipmapped
  shared texture with pan/zoom uniforms.
- `CambrianiOS/Views/CannyPreviewView.swift` — `UIViewRepresentable` wrapping
  `MTKView`; `isPaused = true`; `setNeedsDisplay()` on write-complete; pan/zoom
  gesture handling bound to ViewModel.
- `CambrianiOS/Engine/ConsumerRegistry.swift` — Swift side; bridges to C++
  `ConsumerRegistry`; triggers ADR-20 storage-mode flip on first subscribe /
  last unsubscribe.
- `CambrianiOS/Cpp/module.modulemap` — module map exposing `PixelSink.h`,
  `EdgeDetectionConsumer.h`, `FrameSetBridge.h`, `WriteCompleteCallback.h`.
- `CambrianiOS/Cpp/WriteCompleteCallback.h` — C-ABI `void (*)(void* ctx,
  uint64_t frameNumber)` typedef (ADR-13 §C-ABI callback pattern).

### Acceptance Criteria

- C++ edge consumer attaches to `.tracker` via `engine.attach(consumer:, to:)`;
  `overwriteCount_[2]` reachable via `drainStats(.Tracker)` at 1 Hz (G-26).
- Composited full-res frame appears in the canny `MTKView` with correct edges.
- Slow consumer test: introduce `std::this_thread::sleep_for(50ms)` inside
  `processFrame`; natural + processed previews remain at 30 fps; canny view
  degrades to ~20 fps; `overwriteCount_[2]` increments monotonically (domain
  invariant 10; ADR-13).
- Memory flat under 30-minute sustained load (shared canny texture is allocated
  once per design/04 §6 — verified by Instruments Allocations).
- Pinch-to-zoom in the canny view is smooth; pan gesture tracks correctly.
- Natural preview (left pane) frame rate independent of canny consumer state
  (per ADR-13 preview-inviolable, ADR-03 direct GPU output).
- ADR-20 flip verified: attaching a `.processed` subscriber rotates
  `processedTex` from `.private` to `.shared`; before subscribe,
  `processedTex.iosurface` is `nil` (G-25 silent-drop scenario reproduced and
  verified fixed).

---

## Phase 4 — Performance + Resilience

Goal: thermal + system-pressure degradation responses; 15 fps FPS_DEGRADED
notification (domain §06); watchdog implementation (GPU 3 s, capture 5 s).

### Files

- `CambrianiOS/Engine/ThermalThrottleController.swift` — observes
  `ProcessInfo.thermalState` + `device.systemPressureState`; reduces capture fps,
  disables tracker consumer, or transitions to `THROTTLED` per policy.
- `CambrianiOS/Engine/FramePacingController.swift` — owns
  `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` commits per
  preview vs. recording mode (domain §02; U-16 partial).
- `CambrianiOS/Engine/SystemPressureResponder.swift` — handles
  `.serious`/`.critical`/`.shutdown` levels; `.shutdown` → fatal; others degrade.
- `CambrianiOS/Models/PerformanceThresholds.swift` — 15 fps degradation threshold,
  3 heartbeat streak counter (domain §06 FPS Degradation); 3/5 s stall watchdog
  thresholds.

Plus extensions to Phase 1a files:
- `CameraEngine.swift` adds `StallWatchdog` (`DispatchSourceTimer`) armed per
  domain §05 step 6 + §02 Watchdog Lifecycle; disarmed before teardown/recovery.

### Acceptance Criteria

- 3 s without GPU frame arrival → informational `FRAME_STALL` emitted; no recovery
  (domain §06 disambiguation).
- 5 s without capture-result → recovery triggered; full teardown + reopen after
  backoff (500/1000/2000/4000/8000 ms per domain §06).
- 5 consecutive hardware errors → `CAPTURE_FAILURE` recovery (domain §06 HAL
  threshold).
- Sustained 15 fps or below for 3 heartbeats → `FPS_DEGRADED` notification; no
  recovery (domain §06).
- `systemPressureState == .serious` → capture preset drops one step (e.g.
  disables tracker consumer); `UI` shows "camera throttled" banner.
- `systemPressureState == .shutdown` → session transitions to fatal `ERROR` with
  platform equivalent of `CAMERA_DISCONNECTED`.
- Recovery after 5 failed retries → `MAX_RETRIES_EXCEEDED` fatal.
- All domain §07 performance-budget thresholds measured via Instruments and meet
  spec on target hardware.

---

## Phase 5 — Capture + Recording

Goal: still capture via Metal readback + HEVC recording via `AVAssetWriter` (ADR-16)
with zero-copy GPU→encoder (ADR-06). **Still capture uses Metal readback from
`processedTex` — NOT `AVCapturePhotoOutput`** (per ADR-03 §Direct GPU outputs,
domain §01 invariant 1 "preview is consumer output").

### Files

- `CambrianiOS/Capture/StillCaptureController.swift` — sets atomic
  `stillRequested` (invariant 8); on next frame, `MetalEngine` appends Pass 6;
  after commit, `CVPixelBufferLockBaseAddress` for CPU read; `CGImageDestination`
  writes TIFF (U-09 partial: `kCGImagePropertyExifDictionary` + JSON blob under
  `"CamPlugin/v1"`).
- `CambrianiOS/Capture/VideoRecorder.swift` — state machine from domain §08
  (IDLE → PREPARING → RECORDING → STOPPING → IDLE); drives Pass 5 gating; drain
  deadline (ADR-16).
- `CambrianiOS/Capture/AssetWriterWrapper.swift` — `AVAssetWriter` + HEVC
  settings (`AVVideoCodecType.hevc`, configurable bitrate, 30 fps default);
  `AVAssetWriterInputPixelBufferAdaptor` with `kCVPixelFormatType_420YpCbCr8
  BiPlanarVideoRange` source pixel-buffer attributes (ADR-06, ADR-16); NO audio
  input (G-12, `ios-platform-guide/04 §No-audio`).
- `CambrianiOS/Capture/EXIFWriter.swift` — tags from `FrameSet.capture`:
  ISO, exposure time, focal length (from device), aperture, focus distance,
  flash state (always off), white balance (hardware gains), exposure program,
  pixel dimensions, orientation (ADR-17 — `AVCaptureConnection.videoRotationAngle`,
  not shader UV), capture timestamp. Non-standard fields JSON-serialized under
  `kCGImagePropertyExifUserComment` key `"CamPlugin/v1"` (U-09 partial).
- `CambrianiOS/Metal/Shaders/ReadbackBlit.metal` — Pass 6 compute kernel: RGBA16F
  → BGRA8 into an IOSurface-backed, CPU-readable `CVPixelBuffer`.

### Notes

- Still capture uses **Metal readback from `processedTex`** (ADR-03 §Direct GPU
  outputs) — this matches domain §01 invariant "the user gets what they see"
  and §08 "exact processed output at the time of capture".
  `AVCapturePhotoOutput` is **NOT** used: it bypasses Metal and would write the
  raw sensor output, violating domain invariant 5.
- Recording is **video-only, no audio** (`ios-platform-guide/04 §No-audio`;
  domain §08; G-12).
- `AVAssetWriter.finishWriting` has a 5 s deadline per ADR-16; expiry →
  `cancelWriting()` yields an empty file, not a corrupt one (G-08). This satisfies
  domain §05 "background drain: a corrupted output file is worse than no file".
- `UIApplication.beginBackgroundTask` used when recording is active at
  backgrounding; expiration handler calls `cancelWriting()`. **Backgrounding guard
  is to prevent corruption (missing `moov` atom), NOT to continue recording.**

### Acceptance Criteria

- Still image pixel-accurate to processed preview (visual diff test with fixture
  image).
- EXIF tags readable with `exiftool`; rotation matches display orientation
  (ADR-17); custom `"CamPlugin/v1"` JSON parses.
- `startRecording` → `stopRecording` produces a playable HEVC `.mov` file.
- Recording for 60 s produces a file ≈ `60 × configured_bitrate / 8` bytes.
- `pause()` during recording finalizes the file (U-18 left partially open: minimum
  behavior = stop encoder, finalize container, emit fatal-finalization-failure via
  `onError` if it fails; per domain §08).
- Recording-drop stress test: `AVAssetWriterInputPixelBufferAdaptor.isReadyForMoreMediaData`
  check drops frames at the recording sink without affecting preview or other
  consumers (domain §08 Recording-Sink Back-Pressure).
- Backgrounding during active recording: file is fully finalized (has `moov` atom)
  OR file is empty (not corrupt) — never a partially-written truncated-MP4 (G-08).

---

## Phase 6 — Parity + Polish

Goal: complete API-contract coverage + UI polish; confirm no regressions from
Phase 4 baselines.

### Files

No new files. Modifications only:
- `CameraControlViewModel` exposes any remaining host methods as `async` functions
  bound to UI actions.
- `CameraEngine` completes: `getNativePipelineHandle` (returns an opaque UInt —
  used by external C++ consumers registering directly via the `Cpp` module;
  domain §10), `setCropRegion` (commits new crop uniforms on next frame with
  brief drop OK per domain §10), `getPersistedProcessingParameters`
  (UserDefaults read, no session required).
- `ContentView` adds: Recording timer overlay (MM:SS, domain §09), capture
  confirmation banner (domain §09), fatal/non-fatal error dialog per domain §09
  (state-driven UI table).
- Localization pass; Dynamic Type support on all text; VoiceOver labels on all
  custom controls (`ios-hig` accessibility).

### Acceptance Criteria

- Every API method in `domain-revised/10-api-contract.md` has implementation
  status "implemented" or "deferred with rationale" (the latter only for U-18
  synchronous-return semantics).
- Every callback in domain §10 fires correctly under its documented trigger.
- Phase 4 performance baselines hold (no regression).
- UI passes HIG spot-check: all touch targets ≥ 44 pt; Dynamic Type scales; Dark
  Mode + Increase Contrast tested; Reduce Motion respects animation preferences.
- Landscape-right orientation locked (domain §09); no portrait layout.
- Accessibility: VoiceOver announces every control; Dynamic Type renders up to
  `AX5`.

## Cited ADRs

ADR-01 (two-file baseline extended per domain triggers; Phase 1a/1b/2/6),
ADR-02 (single heavy isolation domain; Phase 1a),
ADR-04/05 (Phase 2), ADR-06 + ADR-16 (Phase 5 — recording),
ADR-08/09 (Phase 1a scenePhase routing, Phase 4 pressure-gated GPU),
ADR-11/12/13 (Phase 3 C++ interop + async consumers),
ADR-17 (Phase 5 EXIF orientation), ADR-18/19 (Phase 2 FrameSet + pools, Phase 3
consumer fan-out), ADR-20 (Phase 3 storage-mode flip + G-25 verification),
ADR-15 (Phase 2 Metal error handling).
