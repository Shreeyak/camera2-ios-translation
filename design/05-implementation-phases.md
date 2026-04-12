# 05 — Implementation Phases

Six phases. Each produces a testable app. Every file tree is concrete — no placeholders.

---

## Phase 1a — Camera Capture + State Machine + Lifecycle + Permissions

**Goal:** Running camera preview, actor-based concurrency from day one, full state machine,
permission flow, session interruption handling.

### Acceptance Criteria

- Camera permission grant/deny handled; state machine enters `waitingForPermission` → `opening` → `streaming`
- Permission denied → `permissionDenied` state shown in UI with actionable message
- Temporary `AVCaptureVideoPreviewLayer` preview is visible (replaced in Phase 2)
- State machine transitions logged correctly via `os_log`
- Session interruption (simulated by locking device) shows `recovering` state and recovers automatically
- Background transition (home button / app switcher) → `backgroundSuspended`; return → `opening` → `streaming`
- Thermal state monitoring hooks installed (monitoring only; degradation response in Phase 4)
- System pressure monitoring hooks installed (monitoring only)
- Single session guard: calling `open()` while active returns `INVALID_STATE` error

### File Tree (new files in this phase)

```
CamPlugin/
├── App/
│   ├── CamPluginApp.swift                    # @main; scenePhase lifecycle observer
│   └── AppDelegate.swift                     # UIApplicationDelegate; scene session management
├── UI/
│   ├── CameraView.swift                      # Root view; placeholder split layout; permission request view
│   ├── CameraViewModel.swift                 # @Observable @MainActor; holds SessionState, error, frameResult
│   ├── PermissionView.swift                  # Shown when .waitingForPermission or .permissionDenied
│   ├── StateOverlayView.swift                # Overlay for opening/recovering/error states
│   ├── CaptureBanner.swift                   # Transient banner (placeholder; wired in Phase 5)
│   └── PreviewLayerWrapper.swift             # UIViewRepresentable wrapping AVCaptureVideoPreviewLayer (Phase 1a temporary; removed in Phase 2)
├── Engine/
│   ├── CameraEngine.swift                    # Swift actor; AVCaptureSession lifecycle
│   ├── SessionStateMachine.swift             # SessionState enum + transition validation
│   ├── CameraDeviceDiscovery.swift           # AVCaptureDevice: back-facing main lens selector
│   ├── PermissionManager.swift               # AVCaptureDevice.authorizationStatus + requestAccess
│   ├── StallWatchdog.swift                   # GPU (3s) + capture-result (5s) watchdogs with Task-based timers
│   ├── ThermalMonitor.swift                  # ProcessInfo.thermalStateDidChangeNotification observer
│   ├── SystemPressureMonitor.swift           # AVCaptureDevice.systemPressureState KVO observer
│   └── SettingsPersistence.swift             # UserDefaults + Codable for CameraSettings + ProcessingParameters
└── MLProcessorActor/
    └── MLProcessor.swift                     # @globalActor definition (empty in Phase 1a; wired in Phase 3)
```

### Key Implementation Notes

- `CameraEngine` is a Swift actor from day one — no "convert to actor later"
- `AVCaptureVideoPreviewLayer` is wrapped in a `UIViewRepresentable` (`PreviewLayerWrapper.swift`, added to `CameraView.swift`) — clearly marked as Phase 1a temporary
- `SettingsPersistence` uses `UserDefaults` with `Codable` — no `SharedPreferences` double-as-long workaround needed; Swift's `UserDefaults` natively stores `Double`
- Resolution discovery: `AVCaptureDevice.formats` filtered for `dimensions.width * 3 == dimensions.height * 4` (exact 4:3), sorted by total pixel count descending, fallback to 1280×960

---

## Phase 1b — Camera Controls

**Goal:** All camera hardware controls wired; UI control surface; capability querying per device.

### Acceptance Criteria

- ISO: auto/manual toggle works; manual ISO slider adjusts actual sensor sensitivity
- Exposure: auto/manual toggle works; manual exposure time slider adjusts shutter
- ISO + exposure coupling enforced: switching either to auto propagates to the other
- Focus: continuous auto / manual diopter switch; manual slider sets focus distance
- Zoom: slider and pinch gesture both adjust `AVCaptureDevice.videoZoomFactor`
- White balance: auto / locked / manual (R, G, B sliders) all working
- Noise reduction and edge mode: passthrough integer controls; values mapped to `AVCaptureDevice.noiseReductionMode` and `AVCaptureDevice.sharpnessMode` where available; else no-op with warning logged
- EV compensation: slider wired to `AVCaptureDevice.exposureTargetBias`
- GPU color params (brightness, contrast, saturation, black balance, gamma): sliders in `ColorCalibrationSidebar`; values sent via `setProcessingParameters` (stored but not yet applied to GPU — Metal pipeline not built yet)
- `getPersistedProcessingParameters()` returns persisted values for UI initialization before session open
- Control interaction constraints: manual exposure disables AE slider interaction
- AE convergence timeout (5s): timer fires, non-fatal `AE_CONVERGENCE_TIMEOUT` logged
- Settings persist across app restarts

### File Tree (new files in this phase)

```
CamPlugin/
├── UI/
│   ├── ControlsPanel.swift                   # Expanded/collapsed bottom bar; ISO, shutter, focus, zoom
│   ├── ColorCalibrationSidebar.swift         # GPU params sidebar; brightness/contrast/saturation/gamma/blackbalance
│   ├── ZoomSlider.swift                      # Custom slider with pinch gesture recognizer
│   ├── ISOExposureControl.swift              # Coupled ISO + exposure toggle/slider component
│   ├── FocusControl.swift                    # Auto/manual focus control; diopter display
│   ├── WhiteBalanceControl.swift             # Auto/locked/manual WB; R, G, B sliders
│   └── ResolutionLabel.swift                 # Text label showing current resolution (e.g., "4160×3120")
├── Engine/
│   ├── CameraSettings+Apply.swift            # AVCaptureDevice configuration extension; applies CameraSettings
│   ├── ISOExposureCoupling.swift             # Merge + coupling logic (domain/03 §ISO and Exposure Coupling)
│   └── AEConvergenceMonitor.swift            # 5s AE convergence watchdog
└── (no new files in Consumers/ or Metal/ in this phase)
```

### Key Implementation Notes

- `AVCaptureDevice` locking: `lockForConfiguration()` / `unlockForConfiguration()` wraps all hardware setting changes; performed inside `CameraEngine` actor
- Zoom: `AVCaptureDevice.videoZoomFactor` for digital zoom; max factor from `device.activeFormat.videoMaxZoomFactor`
- White balance: iOS uses `AVCaptureDevice.setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains(_:completionHandler:)` for manual; R, G, B gains mapped to `AVCaptureDevice.WhiteBalanceGains`
- Manual focus: `AVCaptureDevice.setFocusModeLocked(lensPosition:completionHandler:)` with `lensPosition` in `[0.0, 1.0]` (iOS convention). Domain spec uses diopters — must define conversion function. **NEEDS INVESTIGATION (U-11):** iOS uses `lensPosition` (normalized 0–1), not diopters. Conversion requires factory calibration data not available at design time. Design uses `lensPosition` directly with a UI that displays the normalized value; diopter display is approximated or omitted pending hardware characterization.
- EV compensation: `AVCaptureDevice.exposureTargetBias` in EV units, clamped to `device.minExposureTargetBias`...`device.maxExposureTargetBias`

---

## Phase 2 — Metal Processing Pipeline

**Goal:** Replace `AVCaptureVideoPreviewLayer` with Metal render path; full GPU pipeline operational.

### Acceptance Criteria

- GPU-processed preview visible in right half of split screen
- Natural stream preview visible in left half (when `enableNaturalStream: true`)
- Correct color transforms applied (verify with brightness/contrast/saturation sliders)
- Frame rate stable at 30fps under normal conditions
- `os_signpost` intervals visible in Instruments (MetalSystemTrace)
- Double-buffered readback operational (verify via Allocations: no per-frame heap allocs in hot path)
- `CVMetalTextureCacheFlush` called on memory warning
- Tracker texture produced at 480px height (verify dimensions in debug overlay)

### File Tree (new files in this phase)

```
CamPlugin/
├── UI/
│   ├── MetalViewWrapper.swift                # UIViewRepresentable wrapping MTKView (processed)
│   └── NaturalMetalViewWrapper.swift         # UIViewRepresentable wrapping MTKView (natural)
├── Metal/
│   ├── MetalRenderer.swift                   # MTKViewDelegate; nonisolated; draws processedTexture
│   ├── NaturalMetalRenderer.swift            # MTKViewDelegate; nonisolated; draws naturalTexture
│   ├── CVMetalTextureCacheManager.swift      # CVMetalTextureCache lifecycle; singleton per session
│   ├── Shaders.metal                         # Compute kernel: YUV→RGBA + 5-stage color transforms + natural
│   ├── ColorTransformUniforms.swift          # Swift mirror of ColorUniforms Metal struct (MemoryLayout alignment)
│   └── MetalPipelineBuilder.swift            # MTLRenderPipelineState + MTLComputePipelineState factory
└── Engine/
    └── CameraEngine+Metal.swift              # Extension: Metal setup, processFrame, readback, fence handling
```

### Key Implementation Notes

- `AVCaptureVideoPreviewLayer` wrapper is removed; `CameraView.swift` updated to use `MetalViewWrapper`
- `MetalRenderer` is `nonisolated`; it holds a `MTLTexture?` in a thread-safe slot updated by `CameraEngine`
- Readback buffer pair: two `MTLBuffer` objects allocated at session start with `storageMode: .shared`
- Fence: Metal `commandBuffer.addCompletedHandler` is used as the fence — no `MTLFence` object needed for double-buffered readback (the completion handler fires after all commands including the blit complete)
- Sensor orientation: `AVCaptureConnection.videoRotationAngle` set at configuration time; verified on target hardware

---

## Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out

**Goal:** Generic C++ consumer interface; OpenCV iOS linked; edge detection running; fan-out to both
Metal preview and edge detection simultaneously.

### Acceptance Criteria

- C++ consumer receives frames via zero-copy `cv::Mat` wrapping `CVPixelBuffer` base address
- **`EdgeDetectionConsumer` registers for `ConsumerRole::Tracker` (480px stream), NOT `ProcessedFullResolution`** — Canny on full-res would exceed the 16ms budget by 5–7×. Registering this consumer for any other role must fail the configure() call in DEBUG via assertion. See `04-opencv-integration.md §Role Selection`.
- Memory stays flat under sustained load (Allocations instrument: no growth after 60s)
- Slow consumer drops frames without blocking preview (verify: max delay `processFrame` with `sleep(1)` — preview unaffected)
- Edge detection result rendered in SwiftUI `EdgeDetectionOverlay` as green contour lines (contours are detected at 480px and rendered at display resolution as `Path` strokes — no bitmap upscaling)
- `AsyncStream` back-pressure: `bufferingNewest(1)` in `ConsumerRegistry`
- `os_signpost` `EdgeDetection` intervals visible; `EdgeResultToUI` intervals visible in Instruments
- `EdgeDetection` interval must stay under 8 ms on A15+ hardware (measured in Instruments Metal System Trace); if it exceeds 12 ms, either tighten Canny thresholds or reduce tracker height (requires updating the compile-time constant per U-15)
- `ConsumerRegistry` registration/unregistration thread-safe (concurrent register + frame delivery: no crash)
- `getNativePipelineHandle()` returns non-null opaque pointer when session is streaming

### File Tree (new files in this phase)

```
CamPlugin/
├── Consumers/
│   ├── IFrameConsumer.hpp                    # C++ pure-virtual interface (as designed in 04-opencv-integration.md)
│   ├── EdgeDetectionConsumer.hpp             # EdgeDetection class declaration
│   ├── EdgeDetectionConsumer.cpp             # cv::Canny + cv::findContours implementation
│   ├── EdgeDetectionBridge.h                 # ObjC++ header (Obj-C interface for Swift consumption)
│   ├── EdgeDetectionBridge.mm                # ObjC++ implementation; OpenCV imports here
│   ├── ConsumerRegistry.swift                # Actor-based registry (as designed in 04-opencv-integration.md)
│   ├── EdgeDetectionResult.swift             # Sendable structs: EdgePoint, EdgeContour, EdgeDetectionResult
│   └── FramePacket.swift                     # CVPixelBuffer + metadata container for dispatch
├── UI/
│   └── EdgeDetectionOverlay.swift            # SwiftUI Canvas overlay (as designed in 04-opencv-integration.md)
├── MLProcessorActor/
│   └── MLProcessor.swift                     # Updated: handle(EdgeDetectionResult) wired; os_signpost added
├── Frameworks/
│   └── opencv2.xcframework/                  # Pre-built xcframework from opencv.org (arm64 + simulator)
└── CamPlugin.xcconfig                        # Build config: SWIFT_OBJC_INTEROP_MODE=objcxx; OpenCV header search paths
```

### Build Configuration Notes

- `CamPlugin.xcconfig` sets `HEADER_SEARCH_PATHS` to include `$(SRCROOT)/Frameworks/opencv2.xcframework/ios-arm64/opencv2.framework/Headers`
- `EdgeDetectionConsumer.cpp` is compiled as C++17 (`OTHER_CPLUSPLUSFLAGS = -std=c++17`)
- `EdgeDetectionBridge.mm` includes `#import <opencv2/opencv.hpp>` — Obj-C++ file only
- Bridging header (`CamPlugin-Bridging-Header.h`) imports `EdgeDetectionBridge.h`
- Swift sees `EdgeDetectionBridge` as an Objective-C class; no direct Swift-C++ interop needed for OpenCV

### C++ Lock Ordering (Invariant 5 enforcement)

```
ConsumerRegistry actor (Swift)
  → ConsumerEntry.queue (DispatchQueue, async, non-blocking)
      → EdgeDetectionBridge.processFrame (ObjC++, serial per consumer)
          → EdgeDetectionConsumer.onFrame (C++, no locks inside; single-threaded per consumer)
```

There are no multiple C++ locks acquired simultaneously in this design. The `ConsumerRegistry` actor provides the outer serialization; each consumer runs serially on its own `DispatchQueue`. The lock ordering invariant (pipeline > stage > consumer) is satisfied structurally — no code path acquires two locks.

---

## Phase 4 — Performance + Resilience

**Goal:** Full thermal throttling + system pressure response; frame pacing; all performance thresholds verified.

### Acceptance Criteria

- Instruments `Time Profiler`: capture callback → display commit < 16ms under normal load at 30fps
- `Allocations`: flat memory after Phase 3 warmup (no growing heap)
- Thermal `.serious` → frame rate reduced to 15fps; preview continues; non-fatal `FPS_DEGRADED` may fire
- Thermal `.critical` → session suspended (full teardown); restores when thermal returns to `.nominal`/`.fair`
- System pressure `.elevated` → reduce `AVCaptureSession.sessionPreset` to `.medium`
- System pressure `.critical` → stop recording (if active), then reduce capture quality further
- Preview surface rebind: verified by simulating 3 consecutive drawable failures (inject fault in debug build)
- HAL error threshold: 5 consecutive `captureOutput(_:didDrop:from:)` → non-fatal recovery; count resets on success
- FPS monitoring: every 30 frames, compute fps from `frameDurationNs`; 3 consecutive < 15fps → `FPS_DEGRADED`
- All exponential backoff delays correct (500ms / 1s / 2s / 4s / 8s); max 5 retries before fatal

### File Tree (new files in this phase)

```
CamPlugin/
├── Engine/
│   ├── ThermalThrottler.swift                # Full thermal response: frame rate reduction; suspend at .critical
│   ├── SystemPressureHandler.swift           # AVCaptureDevice systemPressureState → quality degradation
│   ├── FPSDegradationMonitor.swift           # 30-frame heartbeat; 15fps threshold; 3-streak detection
│   └── PreviewSurfaceRebinder.swift          # 3-consecutive-failure detector; requests new MTKView drawable
└── (no new files in Metal/ or UI/ — instrumentation hooks added to existing files)
```

### Frame Pacing Strategy

The Metal pipeline uses **double-buffered readback** (two `MTLBuffer` objects, alternating). This is sufficient for 30fps because:
- Frame N is being read from readback buffer A while frame N+1's blit writes to buffer B
- The `completedHandler` fires when the blit is done — never blocks the render loop
- Triple buffering is not needed because the display path (MTKView) manages its own swapchain

---

## Phase 5 — Capture + Recording

**Goal:** Still capture (both paths), silent video recording (video-only, no audio track), EXIF metadata, media library integration.

**Audio is explicitly out of scope.** The product does not capture or record audio. `AVCaptureAudioDataOutput`, `AVAudioSession`, and microphone permission are all NOT used. Recordings are silent video tracks only. `NSMicrophoneUsageDescription` is NOT added to `Info.plist`.

### Info.plist Requirements (Phase 5)

Two entries must be added to the app's `Info.plist`:

| Key | Value (example) | Required for |
|---|---|---|
| `NSCameraUsageDescription` | "CamPlugin needs camera access to provide live preview and capture photos and video." | `AVCaptureDevice.requestAccess(for: .video)` in Phase 1a |
| `NSPhotoLibraryAddUsageDescription` | "CamPlugin needs permission to save photos and videos you capture to your photo library." | `PHPhotoLibrary.requestAuthorization(for: .addOnly)` in Phase 5 `captureImage()` and `startRecording()` media-library paths |

**Explicitly NOT added:**
- `NSMicrophoneUsageDescription` — the app does not record audio. If this key is added without actually accessing the microphone, App Store review flags it as misleading. If audio capture is ever introduced in a future version, adding this key must be accompanied by adding microphone access code.
- `NSPhotoLibraryUsageDescription` — this is the *read* permission key and is not needed. The app only writes to the photo library (`addOnly` scope), which uses the write-only key above.

### Acceptance Criteria

- `captureNaturalPicture()`: hardware ISP JPEG saved to temp directory; EXIF written; correct path returned
- `captureImage()`: GPU-processed frame saved as JPEG (quality 90) or PNG; system media library path returned
- One-capture-at-a-time guard: concurrent `captureNaturalPicture()` calls → one succeeds, one returns `INVALID_STATE`
- EXIF contains: ISO, exposure time, focal length, aperture, focus distance, flash state, white balance, exposure program, pixel dimensions, orientation, timestamp
- EXIF user comment contains: non-standard fields serialized as JSON under app-specific key
- Video recording: HEVC preferred, H.264 fallback; 50 Mbps default; MP4 container; **video track only** (no audio track)
- Recording indicator updates in UI; elapsed timer starts on `"recording"` callback
- `stopRecording()` drain timeout: 5s; `RECORDING_TRUNCATED` emitted if exceeded; URI still returned
- Recording stops automatically on `pause()` or `backgroundSuspend()`; `"idle"` recording state emitted
- `startRecording()` returns `"<uri>|<displayName>"` format (split on first `|`)
- GPU capture: `captureImage()` reads from Metal readback buffer (current frame); no extra GPU operation
- `Info.plist` contains `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription`; does NOT contain `NSMicrophoneUsageDescription` (verified during App Store submission prep)

### File Tree (new files in this phase)

```
CamPlugin/
├── Capture/
│   ├── StillCaptureController.swift          # Actor; AVCapturePhotoOutput; in-flight guard; EXIF
│   ├── GPUCaptureController.swift            # Actor; reads readback buffer; encodes JPEG/PNG; saves file
│   ├── VideoRecorder.swift                   # Actor; AVAssetWriter + AVAssetWriterInput (HEVC/H.264); video-only
│   ├── EXIFWriter.swift                      # CGImageDestination properties dict builder; JSON user comment
│   └── PhotoLibraryWriter.swift              # PHPhotoLibrary.performChanges; authorization flow (addOnly scope)
└── UI/
    ├── RecordingIndicator.swift              # Red dot + MM:SS timer; driven by CameraViewModel.recordingState
    └── CaptureButton.swift                   # Single-tap GPU capture; separate from natural capture
```

### Key Implementation Notes

- `AVCapturePhotoOutput` is configured at session creation (Phase 1a) but not in this file tree — `StillCaptureController` owns its `AVCapturePhotoOutput` and adds it to the session
- Hardware ISP capture: `AVCapturePhotoOutput.capturePhoto(with:delegate:)` — listener installed BEFORE trigger (race condition prevention, per domain spec)
- GPU capture: reads `readbackBuffers[readIndex].contents()` after fence signal; no additional render pass needed
- `VideoRecorder` creates `AVAssetWriter` with a single `AVAssetWriterInput` of media type `.video`. No audio input. No `AVCaptureAudioDataOutput` is added to the capture session. No `AVAudioSession` is configured — the system default session is untouched, so starting a recording does NOT interrupt other audio apps (the recorded video file simply has no audio track).
- HEVC capability check: `AVAssetWriterInput(mediaType: .video, outputSettings:)` with `AVVideoCodecType.hevc`; fall back to `.h264` if `AVOutputSettingsAssistant` reports unsupported
- Photo library authorization: `PHPhotoLibrary.authorizationStatus(for: .addOnly)` checked before `performChanges`; if `.notDetermined`, `requestAuthorization(for: .addOnly)` called via `async` continuation wrapper; if `.denied`, fall back to temp-directory path and emit non-fatal `PHOTO_LIBRARY_DENIED`

---

## Phase 6 — Parity + Polish

**Goal:** Full API contract coverage audit; UI refinement; remaining domain edge cases addressed.

### Acceptance Criteria

- Every method in `domain/10-api-contract.md` has an implementation status in a coverage table
- All 16 host methods implemented or explicitly marked N/A
- All 4 callbacks firing correctly
- `sampleCenterPatch()`: 96×96 patch from center of GPU-processed frame; histogram trimmed mean (10% each tail)
- `getNativePipelineHandle()`: returns opaque integer (Swift `Int` from `ObjectIdentifier`) when streaming
- `setResolution()`: session-only teardown + GPU resize + restart; 5s timeout; non-fatal on failure
- Landscape-only orientation enforced (`UIInterfaceOrientationMask.landscape`)
- Non-fatal errors shown as transient banners; fatal errors shown as blocking alert with retry option
- Self-healing from camera-in-use: `AVCaptureDevice` availability KVO observer installed on `.error` state; restores on camera available
- All `domain/11-what-not-to-port.md` items confirmed absent (see `design/07-ios-specific-risks.md`)
- Final Instruments pass: all performance budgets met end-to-end

### File Tree (new files in this phase)

```
CamPlugin/
├── Engine/
│   ├── CameraAvailabilityMonitor.swift       # AVCaptureDevice KVO observer for self-healing
│   ├── SampleCenterPatch.swift               # 96×96 Metal readback + histogram trimmed mean
│   └── ResolutionChanger.swift               # setResolution flow: session-only teardown + resize + restart
└── UI/
    ├── ErrorAlertView.swift                  # Modal alert for fatal errors with retry button
    └── NonFatalBanner.swift                  # Toast-style banner for non-fatal error codes
```

**No new files beyond the above** — all other features are implemented in prior phases.

### API Contract Coverage Table

| Domain method | iOS implementation | Status |
|---|---|---|
| `open()` | `CameraEngine.open(cameraId:enableNaturalStream:naturalStreamHeight:)` | Phase 1a |
| `close()` | `CameraEngine.close()` | Phase 1a |
| `pause()` | `CameraEngine.pause()` | Phase 1a |
| `resume()` | `CameraEngine.resume()` | Phase 1a |
| `backgroundSuspend()` | `CameraEngine.backgroundSuspend()` — triggered by `scenePhase == .background` | Phase 1a |
| `backgroundResume()` | `CameraEngine.backgroundResume()` — triggered by `scenePhase == .active` | Phase 1a |
| `updateSettings()` | `CameraEngine.updateSettings(_:)` — merges + applies via `CameraSettings+Apply` | Phase 1b |
| `setProcessingParameters()` | `CameraEngine.setProcessingParameters(_:)` — updates Metal uniforms | Phase 2 |
| `getPersistedProcessingParameters()` | `SettingsPersistence.loadProcessingParameters()` | Phase 1b |
| `sampleCenterPatch()` | `SampleCenterPatch.sample(from:)` — GPU readback + histogram | Phase 6 |
| `captureNaturalPicture()` | `StillCaptureController.captureNaturalPicture()` | Phase 5 |
| `captureImage()` | `GPUCaptureController.captureImage(outputDirectory:fileName:)` | Phase 5 |
| `startRecording()` | `VideoRecorder.startRecording(outputDirectory:fileName:bitrate:fps:)` | Phase 5 |
| `stopRecording()` | `VideoRecorder.stopRecording()` | Phase 5 |
| `setResolution()` | `ResolutionChanger.setResolution(width:height:)` | Phase 6 |
| `getNativePipelineHandle()` | `CameraEngine.getNativePipelineHandle()` → `Int(bitPattern: ObjectIdentifier(registry))` | Phase 3 |
| `onStateChanged` | `CameraEngine.stateStream: AsyncStream<SessionState>` → `CameraViewModel` | Phase 1a |
| `onError` | `CameraEngine.errorStream: AsyncStream<CameraError>` → `CameraViewModel` | Phase 1a |
| `onFrameResult` | `CameraEngine.frameResultStream: AsyncStream<FrameResult>` @ 3 Hz | Phase 1a |
| `onRecordingStateChanged` | `VideoRecorder.recordingStateStream: AsyncStream<RecordingState>` | Phase 5 |
