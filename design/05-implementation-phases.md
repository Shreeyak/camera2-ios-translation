# 05 — Implementation Phases

Seven phases. Each produces a testable deliverable. Every file tree is concrete — no placeholders.

File paths use the `Sources/<TargetName>/` SwiftPM layout from D-17. `App/` is a thin shell containing only `@main`, `Info.plist`, and assets; all production code lives in library targets under `Sources/`.

---

## Phase 0 — Package Scaffolding and C++ Core Skeleton

**Goal:** Stand up the SwiftPM package with all target declarations, an empty
`ImagingCore` C++ target with its public header surface, and a passing
`ImagingCoreTests` C++ test. No Swift implementation code yet — this phase
validates that the module boundary is buildable.

### Acceptance Criteria

- `Package.swift` declares all targets: `EvaApp`, `EvaCore`, `CaptureKit`, `PipelineKit`,
  `EncoderKit`, `ImagingCore`, `Interop`, `TestingSupport`, and their test targets
  plus the `opencv2` `binaryTarget`.
- `Sources/ImagingCore/include/imagingcore/` contains the public headers
  (`PixelSink.hpp`, `EdgeDetector.hpp`) with SWIFT_SHARED_REFERENCE annotations, Frame struct,
  StreamId/PixelFormat enums, and C-ABI callback typedefs. None include Apple headers
  or OpenCV — the public surface is C++20 standard library only.
- `Sources/ImagingCore/module.modulemap` exposes the `imagingcore` umbrella to Swift.
- `Sources/ImagingCore/src/PixelSink.cpp` contains a stub `PixelSink` (thread pool
  + per-stream MPSC lanes) that publishes frames without calling OpenCV.
- `Sources/ImagingCore/src/EdgeDetector.cpp` contains a stub `EdgeDetector` that
  subscribes to `StreamId::Tracker` and invokes the callback immediately without
  running Canny — validates the target builds before OpenCV is linked.
- `Tests/ImagingCoreTests/PixelSinkTests.cpp` publishes a synthetic `Frame` to a
  `PixelSink` and asserts the subscriber callback fires on a pool thread.
- **`swift test` succeeds on macOS**, building and running `ImagingCoreTests`
  against the stub implementation.

### File Tree (new files in this phase)

```
CamPlugin/
├── Package.swift                                     # SwiftPM root
├── App/
│   ├── Info.plist                                    # Thin shell
│   └── Assets.xcassets
├── Sources/
│   └── ImagingCore/                                  # C++ only; Apple-free
│       ├── include/imagingcore/
│       │   ├── PixelSink.hpp                         # SWIFT_SHARED_REFERENCE; Frame; StreamId; PixelFormat
│       │   └── EdgeDetector.hpp                      # SWIFT_SHARED_REFERENCE; subscribes to Tracker stream
│       ├── src/
│       │   ├── PixelSink.cpp                         # Thread pool + MPSC lanes; stub; OpenCV not needed
│       │   └── EdgeDetector.cpp                      # Stub callback; cv::Canny wired in Phase 3
│       └── module.modulemap
├── Tests/
│   └── ImagingCoreTests/
│       ├── PixelSinkTests.cpp                        # Publish Frame → assert subscriber callback fires
│       └── EdgeDetectorTests.cpp                     # Placeholder; golden fixture tests in Phase 3
└── Frameworks/
    └── opencv2.xcframework                           # Downloaded; referenced by binaryTarget
```

### Key Implementation Notes

- `Package.swift` sets `platforms: [.iOS(.v26)]`, `cxxLanguageStandard: .cxx20`, and `.interoperabilityMode(.Cxx)` on the Swift targets that import `ImagingCore`.
- `ImagingCore` has no Swift files. The only Swift-visible artifact is the Clang module produced from `module.modulemap`.
- `ImagingCore` is **independently testable** because it is a standalone SwiftPM target with no Apple-framework dependencies in its public headers. `ImagingCoreTests` can run `EdgeDetector` against in-memory fixtures without a camera, Metal, AVFoundation, or an Xcode project.
- No `EvaCore`, `CaptureKit`, `PipelineKit`, `EncoderKit`, `Interop`, or `TestingSupport` in this phase — they come online in subsequent phases. The `Package.swift` can declare them as empty targets (one placeholder `.swift` file each) so the build graph is complete from day one.

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
│   └── CamPluginApp.swift                           # @main; scenePhase lifecycle; WindowGroup
├── Sources/
│   ├── EvaCore/
│   │   ├── CameraView.swift                         # Root view; placeholder split layout; permission request view
│   │   ├── CameraViewModel.swift                    # @Observable; default MainActor isolation via SE-0466
│   │   ├── PermissionView.swift                     # Shown when .waitingForPermission or .permissionDenied
│   │   ├── StateOverlayView.swift                   # Overlay for opening/recovering/error states
│   │   ├── CaptureBanner.swift                      # Transient banner (placeholder; wired in Phase 5)
│   │   └── PreviewLayerWrapper.swift                # UIViewRepresentable wrapping AVCaptureVideoPreviewLayer (Phase 1a temporary; removed in Phase 2)
│   ├── CaptureKit/
│   │   ├── CaptureActor.swift                       # Serial actor; AVCaptureSession lifecycle
│   │   ├── SessionStateMachine.swift                # SessionState enum + transition validation
│   │   ├── DeviceStateStream.swift                  # KVO → AsyncStream<CameraState.Snapshot>
│   │   ├── CameraDeviceDiscovery.swift              # AVCaptureDevice: back-facing main lens selector
│   │   ├── PermissionManager.swift                  # AVCaptureDevice.authorizationStatus + requestAccess
│   │   ├── SystemPressureMonitor.swift              # AVCaptureDevice.systemPressureState KVO observer
│   │   └── SettingsPersistence.swift                # UserDefaults + Codable for CameraSettings + ProcessingParameters
│   ├── PipelineKit/
│   │   ├── StallWatchdog.swift                      # GPU (3s) + capture-result (5s) watchdogs; Task-based timers
│   │   └── ThermalMonitor.swift                     # ProcessInfo.thermalStateDidChangeNotification → banner-only v1
│   └── Interop/
│       └── MLProcessor.swift                        # @globalActor definition (empty in Phase 1a; wired in Phase 3)
```

### Key Implementation Notes

- `CaptureActor` is a Swift actor from day one — no "convert to actor later"
- `EvaCore` uses SE-0466 default MainActor isolation; `CaptureKit`, `PipelineKit`, and `Interop` use explicit isolation (actors, nonisolated delivery queue)
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
└── Sources/
    ├── EvaCore/
    │   ├── ControlsPanel.swift                      # Expanded/collapsed bottom bar; ISO, shutter, focus, zoom
    │   ├── ColorCalibrationSidebar.swift            # GPU params sidebar; brightness/contrast/saturation/gamma/blackbalance
    │   ├── ZoomSlider.swift                         # Custom slider with pinch gesture recognizer
    │   ├── ISOExposureControl.swift                 # Coupled ISO + exposure toggle/slider component
    │   ├── FocusControl.swift                       # Auto/manual focus control; diopter display
    │   ├── WhiteBalanceControl.swift                # Auto/locked/manual WB; R, G, B sliders
    │   └── ResolutionLabel.swift                    # Text label showing current resolution (e.g., "4160×3120")
    └── CaptureKit/
        ├── CameraSettings+Apply.swift               # AVCaptureDevice configuration extension; applies CameraSettings
        ├── ISOExposureCoupling.swift                # Merge + coupling logic (domain/03 §ISO and Exposure Coupling)
        └── AEConvergenceMonitor.swift               # 5s AE convergence watchdog
# (no new files in ImagingCore/, Interop/, or PipelineKit/ in this phase)
```

### Key Implementation Notes

- `AVCaptureDevice` locking: `lockForConfiguration()` / `unlockForConfiguration()` wraps all hardware setting changes; performed inside `CaptureActor`
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
└── Sources/
    └── PipelineKit/
        ├── FramePipeline.swift                      # nonisolated; 6-pass command graph; AVCaptureVideoDataOutputSampleBufferDelegate
        ├── MetalViewWrapper.swift                   # UIViewRepresentable → MTKView (processed)
        ├── NaturalMetalViewWrapper.swift            # UIViewRepresentable → MTKView (natural)
        ├── MetalRenderer.swift                      # MTKViewDelegate; nonisolated; draws processedTexture
        ├── TexturePoolManager.swift                 # naturalTex / processedTex / trackerTex pool lifecycle
        ├── Shaders.metal                            # Passes 1–5: crop_yuv8_to_rgba16f, color_transform, rgba16f_to_yuv8, lanczos via MPS
        ├── ColorTransformUniforms.swift             # Swift mirror of CropUniforms + ColorUniforms (MemoryLayout alignment)
        └── MetalPipelineBuilder.swift               # MTLComputePipelineState factory for all passes
```

### Key Implementation Notes

- `AVCaptureVideoPreviewLayer` wrapper is removed; `CameraView.swift` updated to use `MetalViewWrapper`
- `MetalRenderer` is `nonisolated`; it holds a `MTLTexture?` in an `OSAllocatedUnfairLock`-protected slot updated by `FramePipeline`
- **Capture pixel format is `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange`** (8-bit YUV biplanar). Pass 1 (`crop_yuv8_to_rgba16f`) performs the zero-copy CVMetalTextureCache wrap + BT.709 YUV→RGBA16F conversion + center crop. All subsequent passes operate in `rgba16Float`. See `03-metal-pipeline.md §Texture Specification` for the full table.
- `MTKView.colorPixelFormat = .bgra10_xr` (wide-gamut drawable); Pass 3 renders `processedTex` to the drawable
- `FramePipeline` is `nonisolated` and acts as the `AVCaptureVideoDataOutputSampleBufferDelegate` — no `Task {}` wrapping on the frame path
- Sensor orientation: `AVCaptureConnection.videoRotationAngle` set at configuration time; verified on target hardware

---

## Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out

**Goal:** Wire up the `ImagingCore` C++ consumer with real OpenCV edge detection,
via direct Swift ↔ C++ interop (no `.mm` files). Fan-out from `CaptureActor`
(in `CaptureKit`) through `PixelSinkFacade` (in `Interop`) to the C++
`EdgeDetector` with zero-copy IOSurface frame handoff.

### Acceptance Criteria

- `opencv2.xcframework` declared as SwiftPM `binaryTarget` and linked into `ImagingCore`. `swift build` succeeds.
- `EdgeDetector.cpp` replaces the Phase 0 stub with the full pipeline: IOSurfaceLock(readOnly) → cv::Mat CV_16FC4 alias (zero-copy over IOSurface) → cv::transform with BT.709 weights `(0.2126, 0.7152, 0.0722, 0.0)` (channel order R,G,B,A — NOT BGRA) → cv::Canny → composite edges onto tracker frame in C++ → IOSurfaceUnlock → write composited result to shared MTLTexture (.shared storage) → invoke C-ABI EdgeResultCallback. Every cv:: call is wrapped in try/catch.
- `EdgeDetectorFacade` wraps `imagingcore::EdgeDetector` as a SWIFT_SHARED_REFERENCE object. `subscribe()`/`unsubscribe()` called at session start/stop. C-ABI callback routes `EdgeResult` to `@MLProcessor` via `Task { await MLProcessor.shared.handle(result) }`. **No `.mm` files exist in the project.**
- `PixelSinkFacade.publish()` called from GPU completion handler (delivery queue) with IOSurface-backed Frame structs. Non-blocking C++ call — no Swift actor involved.
- `EdgeOverlayView` (MTKView wrapping shared MTLTexture) renders the composited edge overlay. **Not a SwiftUI Canvas.**
- Memory stays flat under sustained load (Allocations: no growth after 60s).
- Slow consumer drops frames without blocking preview (PixelSink 1-slot mailbox overwrites; verify: add 100ms delay in EdgeDetector — preview unaffected).
- `ImagingCoreTests`: golden IOSurface fixture test — create IOSurface with synthetic RGBA16F data, publish via PixelSink, assert EdgeDetector callback fires with expected contour count. Runs via `swift test` on macOS.
- `InteropTests`: `EdgeDetectorFacadeTests.swift` — configure EdgeDetectorFacade with fixture MTLTexture, verify EdgeResult arrives at @MLProcessor.

### File Tree (new files in this phase)

```
CamPlugin/
├── Package.swift                                    # UPDATED: binaryTarget("opencv2") + ImagingCore dep
├── Sources/
│   ├── ImagingCore/
│   │   └── src/
│   │       └── EdgeDetector.cpp                     # UPDATED: full cv::Canny + composite + shared MTLTexture write
│   ├── Interop/
│   │   ├── PixelSinkFacade.swift                    # SWIFT_SHARED_REFERENCE wrapper; publish IOSurface frames
│   │   ├── EdgeDetectorFacade.swift                 # SWIFT_SHARED_REFERENCE wrapper; C-ABI callback → MLProcessor
│   │   ├── EdgeResult.swift                         # Sendable structs: EdgePoint, EdgeContour, EdgeResult
│   │   └── MLProcessor.swift                        # UPDATED: handle(EdgeResult) wired
│   └── EvaCore/
│       └── EdgeOverlayView.swift                    # MTKView rendering shared MTLTexture from EdgeDetector
└── Tests/
    ├── ImagingCoreTests/
    │   └── EdgeDetectorTests.cpp                    # UPDATED: golden IOSurface fixture + poison test
    └── InteropTests/
        └── EdgeDetectorFacadeTests.swift            # Swift Testing; IOSurface fixture → EdgeDetectorFacade → EdgeResult
```

### Build Configuration Notes

- `Package.swift` adds `.binaryTarget(name: "opencv2", path: "Frameworks/opencv2.xcframework")` and makes `ImagingCore` depend on it.
- `ImagingCore` uses `cxxLanguageStandard: .cxx20` (declared at the package level).
- `Interop` target sets `.swiftSettings: [.interoperabilityMode(.Cxx)]` — this is what enables `import ImagingCore` to see C++ types directly.
- **There is no `CamPlugin.xcconfig`, no `HEADER_SEARCH_PATHS` hand-wiring, no bridging header, and no `.mm` file.** OpenCV is a private dependency of `ImagingCore` and is never exposed outside `Sources/ImagingCore/src/`.

---

## Phase 4 — Performance + Resilience

**Goal:** Full thermal throttling + system pressure response; frame pacing; all performance thresholds verified.

### Acceptance Criteria

- Instruments `Time Profiler`: capture callback → display commit < 16ms under normal load at 30fps
- `Allocations`: flat memory after Phase 3 warmup (no growing heap)
- Thermal `.serious`/`.critical` → warning banner displayed in UI; no pipeline degradation in v1
- Preview surface rebind: verified by simulating 3 consecutive drawable failures (inject fault in debug build)
- HAL error threshold: 5 consecutive `captureOutput(_:didDrop:from:)` → non-fatal recovery; count resets on success
- FPS monitoring: every 30 frames, compute fps from `frameDurationNs`; 3 consecutive < 15fps → `FPS_DEGRADED`
- All exponential backoff delays correct (500ms / 1s / 2s / 4s / 8s); max 5 retries before fatal

### File Tree (new files in this phase)

```
CamPlugin/
└── Sources/
    └── CaptureKit/
        ├── FPSDegradationMonitor.swift              # 30-frame heartbeat; 15fps threshold; 3-streak detection
        └── PreviewSurfaceRebinder.swift             # 3-consecutive-failure detector; requests new MTKView drawable
# (no new files in PipelineKit/ or EvaCore/ — instrumentation hooks added to existing files)
```

### Frame Pacing Strategy

The Metal pipeline uses **double-buffered readback** (two `MTLBuffer` objects, alternating). This is sufficient for 30fps because:
- Frame N is being read from readback buffer A while frame N+1's blit writes to buffer B
- The `completedHandler` fires when the blit is done — never blocks the render loop
- Triple buffering is not needed because the display path (MTKView) manages its own swapchain

---

## Phase 5 — Capture + Recording + Inspector Window

**Goal:** Still capture (both paths), silent video recording (video-only, no audio track), EXIF metadata, media library integration, **plus the iPadOS 26 secondary Inspector window** for capture history and live histogram.

**Audio is explicitly out of scope.** The product does not capture or record audio. `AVCaptureAudioDataOutput`, `AVAudioSession`, and microphone permission are all NOT used. Recordings are silent video tracks only. `NSMicrophoneUsageDescription` is NOT added to `Info.plist`.

**Capture Controls API (WWDC25 / `AVCaptureControl`) is explicitly out of scope.** No hardware-button trigger requirement exists for this app.

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
- `captureImage()`: 8-bit TIFF output via Pass 6 blit; system media library path returned
- One-capture-at-a-time guard: concurrent `captureNaturalPicture()` calls → one succeeds, one returns `INVALID_STATE`
- EXIF contains: ISO, exposure time, focal length, aperture, focus distance, flash state, white balance, exposure program, pixel dimensions, orientation, timestamp
- EXIF user comment contains: non-standard fields serialized as JSON under app-specific key
- Video recording: HEVC 8-bit (device does not support 10-bit Main10); MP4 container; **video track only** (no audio track)
- Recording indicator updates in UI; elapsed timer starts on `"recording"` callback
- `stopRecording()` drain timeout: 5s; `RECORDING_TRUNCATED` emitted if exceeded; URI still returned
- Recording stops automatically on `pause()` or `backgroundSuspend()`; `"idle"` recording state emitted
- `startRecording()` returns `"<uri>|<displayName>"` format (split on first `|`)
- GPU capture: `captureImage()` reads from Metal readback buffer (current frame); no extra GPU operation
- `Info.plist` contains `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription`; does NOT contain `NSMicrophoneUsageDescription` (verified during App Store submission prep)
- **Inspector window:** `@main App` declares both `WindowGroup { RootView() }` and `Window("Inspector", id: "inspector") { InspectorView() }`. A toolbar button in the root view calls `@Environment(\.openWindow) private var openWindow` → `openWindow(id: "inspector")`. Window position and size persist via `@SceneStorage`. iPadOS 26 multi-window is assumed — no fallback for older iPadOS.
- **Inspector content:** capture history list (thumbnails + timestamps + EXIF summary) and a live histogram of the current GPU-processed frame (reads from the Metal readback buffer; updates at 3 Hz to match `FrameResult` cadence).

### File Tree (new files in this phase)

```
CamPlugin/
└── Sources/
    ├── EncoderKit/                                  # NEW — was CaptureKit
    │   ├── RecordingActor.swift                     # Actor; AVAssetWriter + HEVC 8-bit; 8-bit YUV biplanar adaptor pool
    │   ├── StillWriter.swift                        # Actor; in-flight guard; 8-bit TIFF via Pass 6 blit readback
    │   ├── EXIFWriter.swift
    │   └── PhotoLibraryWriter.swift
    └── EvaCore/
        ├── RecordingIndicator.swift                 # Red dot + MM:SS timer
        ├── CaptureButton.swift
        └── Inspector/
            ├── InspectorView.swift
            ├── CaptureHistoryList.swift
            └── HistogramView.swift
```

### Key Implementation Notes

- `AVCapturePhotoOutput` is configured at session creation (Phase 1a) but not in this file tree — `StillWriter` owns its `AVCapturePhotoOutput` and adds it to the session
- Hardware ISP capture: `AVCapturePhotoOutput.capturePhoto(with:delegate:)` — listener installed BEFORE trigger (race condition prevention, per domain spec)
- `captureImage()`: Pass 6 blit readback → 8-bit TIFF (device does not support 16-bit TIFF); no additional render pass beyond the blit
- `RecordingActor` creates `AVAssetWriter` with a single `AVAssetWriterInput` of media type `.video`. HEVC 8-bit only; 8-bit YUV biplanar adaptor pool feeds the writer input. No audio input. No `AVCaptureAudioDataOutput` is added to the capture session. No `AVAudioSession` is configured — the system default session is untouched, so starting a recording does NOT interrupt other audio apps (the recorded video file simply has no audio track).
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
└── Sources/
    ├── CaptureKit/
    │   ├── CameraAvailabilityMonitor.swift          # AVCaptureDevice KVO observer for self-healing
    │   ├── SampleCenterPatch.swift                  # 96×96 Metal readback + histogram trimmed mean
    │   └── ResolutionChanger.swift                  # setResolution flow: session-only teardown + resize + restart
    ├── EvaCore/
    │   ├── ErrorAlertView.swift                     # Modal alert for fatal errors with retry button
    │   └── NonFatalBanner.swift                     # Toast-style banner for non-fatal error codes
    └── TestingSupport/
        ├── SyntheticFrameProvider.swift             # AVAssetReader-backed fake sampleBufferDelegate
        └── GoldenFrameFixtures.swift                # RGBAHalf16 reference tiles for CI replay
```

**`TestingSupport.SyntheticFrameProvider` is a Phase 6 deliverable** because it enables deterministic end-to-end testing without a physical camera. It replays a recorded ProRes (or half-float) file through the same `sampleBufferDelegate` path the live camera uses, letting CI verify the full capture → Metal → Interop → ImagingCore → result path at commit time.

**No new files beyond the above** — all other features are implemented in prior phases.

### API Contract Coverage Table

| Domain method | iOS implementation | Status |
|---|---|---|
| `open()` | `CaptureActor.open(cameraId:enableNaturalStream:naturalStreamHeight:)` | Phase 1a |
| `close()` | `CaptureActor.close()` | Phase 1a |
| `pause()` | `CaptureActor.pause()` | Phase 1a |
| `resume()` | `CaptureActor.resume()` | Phase 1a |
| `backgroundSuspend()` | `CaptureActor.backgroundSuspend()` — triggered by `scenePhase == .background` | Phase 1a |
| `backgroundResume()` | `CaptureActor.backgroundResume()` — triggered by `scenePhase == .active` | Phase 1a |
| `updateSettings()` | `CaptureActor.updateSettings(_:)` — merges + applies via `CameraSettings+Apply` | Phase 1b |
| `setProcessingParameters()` | `FramePipeline.updateUniforms(_:)` — updates Metal uniforms | Phase 2 |
| `getPersistedProcessingParameters()` | `SettingsPersistence.loadProcessingParameters()` | Phase 1b |
| `sampleCenterPatch()` | `SampleCenterPatch.sample(from:)` — GPU readback + histogram | Phase 6 |
| `captureNaturalPicture()` | `StillWriter.requestNaturalCapture()` | Phase 5 |
| `captureImage()` | `StillWriter.requestGPUCapture(outputDirectory:fileName:)` | Phase 5 |
| `startRecording()` | `RecordingActor.start(outputDirectory:fileName:bitrate:fps:)` | Phase 5 |
| `stopRecording()` | `RecordingActor.stop()` | Phase 5 |
| `setResolution()` | `ResolutionChanger.setResolution(width:height:)` | Phase 6 |
| `getNativePipelineHandle()` | `PixelSinkFacade` handle (non-null when session is streaming) | Phase 3 |
| `onStateChanged` | `CaptureActor.stateStream: AsyncStream<SessionState>` → `CameraViewModel` | Phase 1a |
| `onError` | `CaptureActor.errorStream: AsyncStream<CameraError>` → `CameraViewModel` | Phase 1a |
| `onFrameResult` | `CaptureActor.frameResultStream: AsyncStream<FrameResult>` @ 3 Hz | Phase 1a |
| `onRecordingStateChanged` | `RecordingActor.recordingStateStream: AsyncStream<RecordingState>` | Phase 5 |
