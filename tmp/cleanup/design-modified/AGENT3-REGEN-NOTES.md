# Agent 3 (DESIGN) Regeneration Notes

**Date:** 2026-04-17
**Purpose:** When `prompt-3-design.md` is updated and Agent 3 is re-run against
`domain/`, these notes capture the expertise injection delta -- what Agent 3's
prompt needs to know that it doesn't currently. Feed these into the Agent 3
prompt as additional iOS expertise context.

---

## 1. Hardware constraints (verified on device)

**Device:** iPad A16 (11th generation, 2025)
**OS floor:** iPadOS 26
**Swift:** 6.2 with C++ interoperability enabled (`.interoperabilityMode(.Cxx)`)
**Metal:** Metal 3 baseline; Metal 4 features `#available`-gated

**Camera hardware capabilities (verified, not assumed):**

- The device does NOT support 10-bit or 12-bit capture output.
- The device does NOT support `kCVPixelFormatType_64RGBAHalf` as an
  `AVCaptureVideoDataOutput` format. Half-float RGBA is a CoreImage/Metal
  working format, not a capture format.
- **Supported capture format:** `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange`
  (lossless hardware-compressed 8-bit YCbCr 4:2:0, full range). This is the
  most data-efficient format the device supports -- hardware compression reduces
  memory bandwidth with no fidelity loss.
- **Recording codec:** HEVC 8-bit only. Device does not support 10-bit HEVC
  Main10 encoding.
- **Still capture:** 8-bit, 3-channel TIFF.
- **Full-sensor resolution:** ~4160x3120 at 30fps (verify via `device.formats`
  enumeration at runtime -- adapt to whatever is available).
- Manual lens position locking: verify `isLockingFocusWithCustomLensPositionSupported`
  at startup; throw a named error if unsupported.

**Camera format selection procedure (startup):**

1. `AVCaptureDevice.DiscoverySession` locates `.builtInWideAngleCamera` at position `.back`.
2. Enumerate `device.formats`; filter for: 8-bit YUV 4:2:0 biplanar (lossless variant
   if available), supports 30fps, dimensions >= 1600x1200.
3. Select the highest resolution among survivors -- expected 4160x3120 on A16 but adapts
   to whatever the actual device offers.
4. Lock the device and set `activeFormat`, `activeVideoMinFrameDuration = CMTime(value: 1,
   timescale: 30)`, `activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)`.
5. Verify `device.isLockingFocusWithCustomLensPositionSupported == true`; throw
   `CameraCapabilityError.customLensPositionUnsupported` otherwise.

---

## 2. Pipeline architecture: Capture to Metal to C++ to Display

### 2.1 Capture to working format

**Capture format:** 8-bit YUV biplanar (`Lossless_420YpCbCr8BiPlanarFullRange`).
Camera delivers IOSurface-backed CVPixelBuffers. CVMetalTextureCache wraps as
two zero-copy MTLTextures: Y plane (R8Unorm) + CbCr plane (RG8Unorm).

**Working format:** RGBA16F (half-float, Metal `.rgba16Float`). Metal Pass 1
does crop + BT.709 YUV-to-RGB conversion to RGBA16F. All subsequent GPU passes
operate in half-float. `half` math runs at full rate on Apple Silicon.

**Rationale for RGBA16F working format:** the 5-stage color-transform chain
(black balance to brightness to contrast to saturation to gamma) compounds
quantization error at 8-bit. Half-float has ~11 bits of mantissa precision and
preserves inter-stage values without banding.

**Center crop:** Pass 1 crops the full-sensor input to a user-defined region
(e.g. 4160x3120 to 1600x1200). Crop origin and size are compute uniforms. This
reduces the GPU workload for color transforms, readback, and encoding by ~6.5x
compared to processing at full sensor resolution.

### 2.2 Channel order at each pipeline stage

Different pipeline stages use different pixel formats and channel orders.
This must be unambiguous because incorrect channel order produces silently
wrong results (no crash, no error).

| Stage | Format | Channel order | Used by |
|---|---|---|---|
| Capture input | 8-bit YUV biplanar | Y plane + CbCr plane (not interleaved RGBA) | CVMetalTextureCache wrap |
| Working textures (naturalTex, processedTex, trackerTex) | RGBA16F | R, G, B, A | Metal passes, PixelSink IOSurface fanout |
| Encoder adaptor pool (recording path only) | 8-bit YUV biplanar | Y plane + CbCr plane | Pass 5 rgba16f_to_yuv8 compute kernel |

All three PixelSink streams (natural, processed, tracker) are RGBA16F with
R,G,B,A channel order. The EdgeDetector receives the tracker stream and must
use BT.709 weights in RGBA order: `(0.2126, 0.7152, 0.0722, 0.0)`. BGRA never
appears in any stream that C++ consumers touch.

### 2.3 6-pass Metal command graph

```
Input: CMSampleBuffer (8-bit YUV Lossless, ~4160x3120)
  -> CVMetalTextureCache: yTex (R8Unorm), cbcrTex (RG8Unorm)

Pass 1 (compute): crop_yuv8_to_rgba16f
  reads yTex + cbcrTex at user-defined crop region
  BT.709 YUV->RGB matrix
  writes naturalTex (cropW x cropH RGBA16F)

Pass 2 (compute): color_transform
  reads naturalTex + ColorParamsUniform
  5-stage: black balance -> brightness -> contrast -> saturation -> gamma
  writes processedTex (cropW x cropH RGBA16F)

Pass 3 (render): preview
  processedTex -> processedPreviewDrawable
  naturalTex -> naturalPreviewDrawable (PiP)

Pass 4 (compute): lanczos_downscale [gated: tracker consumer subscribed]
  MPSImageLanczosScale: processedTex -> trackerTex (640x480 RGBA16F)

Pass 5 (compute): rgba16f_to_yuv8 [gated: recording active]
  reads processedTex, writes 8-bit YUV adaptor buffer for HEVC 8-bit encoder

Pass 6 (blit): still readback [gated: stillRequested flag]
  blits processedTex -> CPU-readable CVPixelBuffer

[commandBuffer commit + present + addCompletedHandler]

On GPU completion:
  Publish IOSurfaces to ImagingCore::PixelSink:
    * .natural  <- naturalTex.iosurface
    * .processed <- processedTex.iosurface
    * .tracker  <- trackerTex.iosurface
```

Pass gating is implicit. If no recorder is active, Pass 5 does not execute.
If no consumer is subscribed to tracker, Pass 4 does not execute. If no still
is requested, Pass 6 does not execute.

---

## 3. Module layout (9 targets)

```
EvaApp/                         @main shell; WindowGroup + Window("Inspector")
+-- EvaCore                     SwiftUI views, ViewModels, navigation, edge overlay view
|                               Opts into SE-0466 default @MainActor isolation
+-- CaptureKit                  CaptureActor (serial actor), AVCaptureSession, DeviceStateStream
|                               KVO -> AsyncStream adapter. AVFoundation ONLY -- no Metal, no C++
+-- PipelineKit                 FramePipeline (command buffer orchestration), TexturePoolManager,
|                               MetalRenderer, Shaders.metal, StallWatchdog, ThermalMonitor
|                               Metal + pools + fanout. No AVFoundation, no C++
+-- EncoderKit                  RecordingActor (HEVC 8-bit), StillWriter (8-bit TIFF),
|                               EXIFWriter, PhotoLibraryWriter
+-- Interop                     Swift facade over ImagingCore. PixelSinkFacade,
|                               EdgeDetectorFacade (SWIFT_SHARED_REFERENCE wrappers),
|                               EdgeResult (Sendable), MLProcessor (@globalActor)
|                               Only module besides ImagingCore with .interoperabilityMode(.Cxx)
+-- ImagingCore                 C++ only; Apple-free public headers
|                               PixelSink (C++ thread pool + 1-slot mailbox per stream)
|                               EdgeDetector (subscribes to PixelSink, runs Canny, composites
|                               edges onto tracker image, writes to shared MTLTexture)
|                               OpenCV private in src/*.cpp only
|                               SWIFT_SHARED_REFERENCE on PixelSink and EdgeDetector
+-- TestingSupport              SyntheticFrameProvider (AVAssetReader replay)
```

Build system: SwiftPM `Sources/<TargetName>/` layout. ImagingCore independently
testable on macOS host via `swift test`.

---

## 4. C++ architecture: PixelSink + EdgeDetector

### 4.1 PixelSink

`SWIFT_SHARED_REFERENCE(retain_fn, release_fn)` -- ARC-managed in Swift.

- Owns a C++ thread pool (`std::min(4, hw_concurrency)`)
- Per-stream MPSC lane queues with 1-slot mailbox (drop-on-busy, newest overwrites)
- `subscribe(StreamId, callback, context)` / `unsubscribe` / `publish(Frame)`
- Frame struct: `{ uint64_t presentationTimeNs, int32_t width, height, PixelFormat fmt, void* iosurface }`
- StreamId enum: Natural, Processed, Tracker
- Publishing is non-blocking; each lane dispatch is independent
- PixelSink manages all dispatch in C++ -- there is no Swift ConsumerRegistry actor

### 4.2 EdgeDetector

`SWIFT_SHARED_REFERENCE(retain_fn, release_fn)` -- ARC-managed in Swift.

EdgeDetector MUST subscribe to `StreamId::Tracker` (the 640x480 downscaled
stream), NOT `StreamId::Processed` (full crop resolution).

**Performance budget (load-bearing for 16ms frame target):**

| Stream | Resolution | Pixels/frame | Canny CPU cost (est.) | Fits 16ms? |
|---|---|---|---|---|
| Processed | ~1600x1200 | ~1.9M | 15-25 ms/frame on A16 | Marginal |
| Tracker | 640x480 | ~0.3M | 2-4 ms/frame on A16 | Yes |

Canny is `O(pixels)` dominated by Gaussian blur + Sobel gradient. The tracker
stream is specifically designed for per-frame CV consumers.

**Processing pipeline on each frame:**

1. IOSurfaceLock(readOnly)
2. cv::Mat alias as CV_16FC4 (zero-copy over the RGBA16F IOSurface data)
3. cv::transform with BT.709 weights `(0.2126, 0.7152, 0.0722, 0.0)` to grayscale
   (the channel order is R,G,B,A -- not BGRA)
4. convertTo CV_8U (Canny requires 8-bit input)
5. cv::Canny to produce edge mask
6. Composite edges onto the original tracker image (colored overlay in C++)
7. IOSurfaceUnlock
8. Write composited result to a pre-allocated shared MTLTexture (.shared storage, mipmap levels)
9. Invoke C-ABI callback with EdgeResult { status, contour list, framePTS, processingTime }

**Why compositing happens in C++:** This is intentionally less efficient than a
Metal-overlay approach. It mirrors the future architecture where C++ will
perform complex multi-layer overlays, stain normalization previews, and ROI
annotations.

**Edge overlay display (Swift side):** EvaCore hosts an MTKView that renders a
fullscreen quad sampling the shared MTLTexture with a pan/zoom transform matrix.
Mipmap levels provide filtering quality when zoomed out. Resolution is small
(640x480) but intentional -- the overlay shows processed edges, not the raw feed.

### 4.3 EdgeResult

- status: enum (ok, error)
- contour list: `[EdgeContour]` with `[EdgePoint]` -- for future features (ROI
  labels, hover, annotation export), NOT for rendering
- framePTS: presentation timestamp for frame alignment
- processingTime: ms

### 4.4 Interop rules

- `setParams(CannyParams)` for runtime threshold adjustment
- No Objective-C++ (.mm) files anywhere. Direct Swift-C++ interop via `.interoperabilityMode(.Cxx)`
- OpenCV headers are private to `.cpp` files inside ImagingCore

---

## 5. Concurrency model

| Domain | Isolation | Module |
|---|---|---|
| `@MainActor` | Global actor | EvaCore (views, ViewModels) |
| `CaptureActor` | Serial actor | CaptureKit |
| Camera delivery queue | DispatchQueue (.userInteractive) | PipelineKit (FramePipeline runs here) |
| Metal GPU completion | Metal internal queue -> trampolines to delivery queue for publish | PipelineKit |
| PixelSink thread pool | C++ pool, per-stream lanes | ImagingCore |
| `RecordingActor` | Serial actor | EncoderKit |
| `MLProcessor` | @globalActor | Interop |

**Key:** nothing on the 30Hz frame clock hops a Swift actor boundary. The sample
buffer delegate is `nonisolated`, runs on the delivery queue, and builds/commits
the command buffer inline. PixelSink::publish is called from the GPU completion
handler (also trampolined to the delivery queue). C++ consumers run on their own
pool threads. Results return to Swift via C-ABI callbacks that hop to @MLProcessor
then to @MainActor.

**KVO to AsyncStream for device state:** CaptureKit includes `DeviceStateStream`
wrapping AVCaptureDevice KVO observations (isAdjustingExposure, exposureDuration,
iso, whiteBalanceGains, lensPosition) as `AsyncStream<CameraState.Snapshot>`.
Consumed by @MainActor CameraControlViewModel in EvaCore. This coexists with
CaptureActor's own AsyncStreams for session-level events (state changes, errors,
frame results) -- different concerns, same delivery mechanism.

---

## 6. Correctness pitfalls (mandatory -- breakage if omitted)

### 6.1 GPU-to-encoder path: true zero-copy via IOSurface

The encoder path MUST be true zero-copy. `MTLTexture.getBytes` is forbidden
on the recording path. The mechanism:

1. `RecordingActor` (in `EncoderKit`) creates an
   `AVAssetWriterInputPixelBufferAdaptor` with a pixel buffer pool configured
   with `kCVPixelBufferIOSurfacePropertiesKey: [:]` and
   `kCVPixelBufferMetalCompatibilityKey: true`. This makes every pool buffer
   IOSurface-backed.
2. Each frame: dequeue a `CVPixelBuffer` from the pool, wrap it as an
   `MTLTexture` via `CVMetalTextureCache`, run the `rgba16f_to_yuv8` compute
   pass writing into that texture (GPU-local, stays in IOSurface memory).
3. In the command buffer's `addCompletedHandler`: append the pixel buffer to
   the adaptor -- VideoToolbox reads the same IOSurface for encoding. No CPU copy.

Pool exhaustion (`kCVReturnWouldBlock`): drop the recording frame (not the
preview frame), log a counter. Preview continues at full rate.

### 6.2 Completion handler re-entrancy guard

Between `commandBuffer.commit()` and the `addCompletedHandler` firing, the
actor may have serviced other messages: `close()`, `backgroundSuspend()`,
`setResolution()`. Any of these may have released GPU resources.

**Required pattern:** capture `sessionState` at commit time as
`frameSessionState`. In the completion handler, check
`sessionState == frameSessionState && sessionState == .streaming` before
touching any readback buffer. If the state changed, drop the frame silently.

```swift
let frameSessionState = sessionState
commandBuffer.addCompletedHandler { [weak self] cb in
    if cb.status == .error, let err = cb.error {
        Task { await self?.handleMetalCommandBufferError(err) }
        return
    }
    Task { await self?.onFrameReadbackComplete(
        readIndex: readIndex,
        expectedState: frameSessionState
    )}
}
```

### 6.3 Metal command buffer error check

Every `commandBuffer.addCompletedHandler` closure MUST check `cb.status == .error`
and inspect `cb.error`. Without this check, GPU faults (OOM, timeout, invalid
state) are only surfaced by the 3-second stall watchdog -- too slow.

On error: increment a Metal-error counter, emit a non-fatal error to the state
machine, tear down the current command queue.

### 6.4 CVMetalTextureCache nil-texture guard

`CVMetalTextureCacheCreateTextureFromImage` can return `kCVReturnSuccess` and
still produce a `CVMetalTexture` whose `CVMetalTextureGetTexture` returns `nil`
under memory pressure. Force-unwrapping crashes.

**Required pattern:** check both `CVReturn == kCVReturnSuccess` AND
`CVMetalTextureGetTexture(tex) != nil`. On failure: drop the frame, increment
the metal-wrap-failure counter, and continue.

### 6.5 AVCaptureSession.startRunning() off-main

`startRunning()` blocks for 100-500ms waiting for hardware readiness. It MUST
run inside `CaptureActor` (a Swift actor, off-main by construction). Explicitly
banned from any `@MainActor` context. Add `#assert(!Thread.isMainThread)` in
DEBUG builds.

### 6.6 AVCaptureSession must stop before background (App Store policy)

This is an App Store policy requirement, not just a runtime optimization.
The camera-in-use indicator in the status bar must disappear within ~1 second
of backgrounding. On `scenePhase == .background`, `CaptureActor.backgroundSuspend()`
MUST call `session.stopRunning()` inside the actor before the view-layer task
returns. Failure is an App Store rejection, not a runtime bug.

### 6.7 Photo output + video data output resolution interaction

Attaching `AVCapturePhotoOutput` to the same `AVCaptureSession` at high
resolution (~4000x3000) may cause iOS to silently downgrade the
`AVCaptureVideoDataOutput` resolution. Phase 5 acceptance criterion: verify
that after attaching photo output, `CVPixelBufferGetWidth/Height` on video
sample buffers still matches the configured format. If iOS downgrades, evaluate
`isHighResolutionCaptureEnabled` and whether photo output must be disconnected
during recording.

### 6.8 PHPhotoLibrary authorization flow

`PHPhotoLibrary.performChanges` called without authorization crashes on iOS 14+.
Before `performChanges`:

1. Check `PHPhotoLibrary.authorizationStatus(for: .addOnly)`.
2. If `.notDetermined`: call `requestAuthorization(for: .addOnly)` via async
   continuation wrapper.
3. If `.denied` or `.restricted`: fall back to temp-directory path and surface
   non-fatal `PHOTO_LIBRARY_DENIED` error.

---

## 7. Recording and capture

### 7.1 Video recording (silent, no audio)

The app does NOT capture or record audio. This is a load-bearing design constraint:

- No `AVCaptureAudioDataOutput` added to the capture session.
- No `AVAudioSession` configuration. The system default session is untouched,
  so starting a recording does NOT interrupt other audio apps.
- No `NSMicrophoneUsageDescription` in `Info.plist`. Adding this key without
  actually accessing the microphone triggers App Store review rejection for
  misleading usage.
- Recordings are silent video tracks (single `AVAssetWriterInput` of media
  type `.video`; no audio input).

Codec: HEVC 8-bit. Resolution: matches processedTex (e.g. 1600x1200). Frame
rate: 30fps. Container: `.mov`. Staging: `FileManager.default.temporaryDirectory`.

The GPU-to-encoder zero-copy path is described in section 6.1.

### 7.2 Still capture

1. User taps shutter; `PipelineKit` sets `stillRequested = true` flag (read on next frame).
2. Next frame's Pass 6 blits `processedTex` into a dedicated CPU-readable CVPixelBuffer
   (RGBA16F, 1600x1200, pool of size 2).
3. `commandBuffer.addCompletedHandler` -> `StillWriter.encode(pixelBuffer:, pts:)`.
4. StillWriter locks the CVPixelBuffer, quantizes from RGBA16F to 8-bit
   (the device does not support 16-bit TIFF encoding), builds a CGImage
   (8-bit, 3-channel), writes to a temp `.tiff` via CGImageDestination,
   then migrates to Photos via `PHPhotoLibrary.shared().performChanges`.
5. On success, delete temp .tiff; publish `.savedToPhotos` event.

### 7.3 backgroundSuspend() recording drain with beginBackgroundTask

When the app transitions to `.background`, iOS gives the process a short window
before suspending. If recording is active, the AVAssetWriter drain (stop writer,
finalize MP4 atom/moov, flush pixel buffer pool) can take several seconds. If
suspended mid-drain, the MP4 file is permanently corrupted (moov atom never written).

**Required pattern:**

1. Request `UIApplication.shared.beginBackgroundTask` BEFORE starting the drain.
2. Drain the recorder synchronously (`RecordingActor.stop()` calls
   `assetWriter.finishWriting`).
3. End the background task AFTER the drain completes.
4. Expiration handler: cancel the writer rather than finalize (partial file is
   marked incomplete but the pool is released cleanly).

---

## 8. Session interruption and app lifecycle

**Reference:** `design-modified/ios-lifecycle-reference.md` — read that file in full.
This section is the design decision summary; the reference file has the rationale and code patterns.

### 8.1 Two orthogonal signal sources — do not conflate

| Source | Signal | Response |
|---|---|---|
| View lifecycle | View appears / disappears | `startRunning()` / `stopRunning()` on sessionQueue |
| System interruptions | `AVCaptureSessionWasInterrupted` / `InterruptionEnded` | Observe, classify, show UI |

**Critical:** do NOT call `stopRunning()` in `didEnterBackground` when `wasInterrupted` has
already fired for `videoDeviceNotAvailableInBackground`. These race. View lifecycle drives
start/stop; by the time `didEnterBackground` fires, `viewWillDisappear` has already stopped
the session cleanly.

`AVCaptureSession` is created **once** per `open()`. `startRunning()`/`stopRunning()` toggle it.
Recreating `AVCaptureSession()` in `viewWillAppear` is the forbidden pattern — full hardware
re-init latency on every foreground.

All `AVCaptureSession` interaction runs on `CaptureActor` (a Swift actor, serial, off-main).
`startRunning()` blocks 100–500ms; calling it on `@MainActor` triggers the purple runtime warning.

### 8.2 Five interruption reasons and handling policy

| Reason | Response |
|---|---|
| `videoDeviceNotAvailableInBackground` | No-op. Await `interruptionEnded`. Auto-resume. |
| `videoDeviceInUseByAnotherClient` | Show **Resume** button. Await user intent. |
| `audioDeviceInUseByAnotherClient` | Show **Resume** button. Await user intent. |
| `videoDeviceNotAvailableWithMultipleForegroundApps` | Show "camera unavailable" label. Cannot be resolved programmatically. |
| `videoDeviceNotAvailableDueToSystemPressure` | Show "camera unavailable" label. Await `interruptionEnded`. |

### 8.3 GPU submission gating (Metal background rule)

Metal apps cannot submit GPU commands in the background — violation causes `MTLCommandBufferErrorNotPermitted`
("IOAF code 6") and process termination. This is a hard platform constraint, not a convention.

**Gate edge: `.inactive`, not `.background`.**
`.inactive` fires when the scene leaves active state (system alert, app switcher, notification,
backgrounding preamble). `.background` is too late — GPU may already be revoked.

UIKit equivalent: `applicationWillResignActive`, not `applicationDidEnterBackground`.

**Implementation:**

```swift
// Atomic flag — visible to scene observer (@MainActor) and capture delegate (video queue)
var gpuSubmissionEnabled = ManagedAtomic<Bool>(true)

// ScenePhase observer
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .inactive:
        gpuSubmissionEnabled.store(false, ordering: .releasing)
        lastCommittedCommandBuffer?.waitUntilScheduled()  // NOT waitUntilCompleted()
    case .active:
        gpuSubmissionEnabled.store(true, ordering: .releasing)
    default: break
    }
}

// captureOutput(_:didOutput:from:) — right before commit, after CPU work
guard gpuSubmissionEnabled.load(ordering: .acquiring) else { return }
commandBuffer.commit()
lastCommittedCommandBuffer = commandBuffer
```

`waitUntilScheduled()` ensures committed work has been handed to the GPU driver (not that it has
completed). `waitUntilCompleted()` blocks until GPU execution finishes — too strong.

### 8.4 What survives a background trip

**Retain across background:** `MTLDevice`, `MTLCommandQueue`, compiled pipeline states,
`CVMetalTextureCache`, texture/buffer pools. Holding these is not GPU submission.

**Do not retain:** in-flight command buffers not yet committed.

### 8.5 Backgrounding sequence (revised)

```
scenePhase → .inactive
  1. gpuSubmissionEnabled = false
  2. lastCommandBuffer?.waitUntilScheduled()
  3. (capture delegate drops subsequent frames at the gate)

scenePhase → .background
  4. If recording active: beginBackgroundTask → RecordingActor.stop() → endBackgroundTask
  5. session.stopRunning() if viewWillDisappear hasn't already done it

wasInterrupted (fires concurrently for videoDeviceNotAvailableInBackground)
  → no-op; system has already handled the camera

GPU resources (textures, pools, cache) are NOT released.
```

On foreground:
```
scenePhase → .active
  1. gpuSubmissionEnabled = true

viewWillAppear / interruptionEnded
  2. session.startRunning() (on CaptureActor/sessionQueue)
  3. Reapply persisted settings (ISO, exposure, WB, focus, processing params)
  4. First frame arrives → encode-and-commit resumes normally
```

No `PipelineKit.rebuild()` on normal foreground. Rebuild only on resolution change or fatal error.
The ~500ms black frame mentioned in the prior version of this section was caused by unnecessary
full teardown — it should not occur with the correct shallow-resume pattern.

### 8.6 `.inactive` policy choice

`.inactive` also fires for notification banners, Control Center, and the app switcher — where the
user is still "in" the app. Two reasonable policies:

- **Strict** (recommended for this app): gate on `.inactive`. Brief preview freeze during
  notification banners is acceptable for a scientific/microscopy use case.
- **Loose**: gate on `.inactive` + check `UIApplication.shared.applicationState != .active`
  before actually setting the flag. Avoids freeze for transient system UI.

Default: strict.

---

## 9. UI features

### 9.1 Inspector Window (iPadOS 26)

Secondary `Window("Inspector", id: "inspector")` for capture history + live
histogram. Uses iPadOS 26 real windowing. Toolbar button opens it via
`@Environment(\.openWindow)`. Capture history is owned by the ViewModel and
persists across window close/reopen.

### 9.2 Debug panel (Phase 6)

Compile-gated to Debug + TestFlight builds. Contains:

- Canny params sliders (lowThreshold, highThreshold, kernelSize)
- Overlay uniform sliders (color, opacity)
- Active camera format readout
- Per-stream FPS + drop counters
- Thermal state + memory pressure
- Command buffer timings

### 9.3 Thermal handling (v1)

Banner-only. Observe `ProcessInfo.thermalState`; show a non-intrusive banner at
`.serious` or higher. No automatic pipeline degradation in v1. Full adaptive
throttling (fps reduction at `.serious`, pipeline suspend at `.critical`) is
explicitly deferred to a follow-on version.

---

## 10. Decisions summary

| Decision | Summary |
|---|---|
| D-16 | No ObjC++ anywhere. Direct Swift-C++ interop. OpenCV private in .cpp. |
| D-17 | SwiftPM `Sources/<TargetName>/` layout. ImagingCore independently testable. |
| D-18 | Capture: 8-bit YUV lossless. Working: RGBA16F. Recording: HEVC 8-bit. Still: 8-bit TIFF. |
| D-23 | C++ PixelSink thread pool replaces Swift ConsumerRegistry. 1-slot mailbox. |
| D-24 | Edge compositing in C++. Intentionally mirrors future complex overlay patterns. |
| D-25 | Center crop in Metal Pass 1. User-defined crop region via uniforms. |
| D-26 | SWIFT_SHARED_REFERENCE on PixelSink + EdgeDetector. ARC-managed in Swift. |
| D-27 | KVO -> AsyncStream for device state (DeviceStateStream in CaptureKit). |

---

## 11. VTFrameProcessor

**Verdict (confirmed 2026-04-16 after re-check against WWDC25 sessions): do not use.**
VTFrameProcessor exposes system-defined effects only (motion deblur, super-res,
noise reduction). It does not support custom per-channel color-transform pipelines.
Custom Metal compute shaders are the correct approach.

---

## 12. Non-goals

- No external display support
- No multi-camera simultaneous capture
- No audio capture or recording (see section 7.1 for the detailed rationale
  and App Store implications)
- No background recording
- No Capture Controls API (hardware button triggers)
- No full adaptive thermal throttling in v1
- No Linux CI / CMake build for ImagingCore (testable on macOS host via swift test only)
- No DICOM / WSI tile I/O
- No on-device ML inference in the color-transform pipeline
