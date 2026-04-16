# ADR-001 — Eva iPad Imaging Pipeline Architecture

**Status:** Accepted
**Date:** 2026-04-16
**Deciders:** Shrek
**Supersedes:** —
**Related:** `android-to-ios-swiftui-porting-research.md`, `docs/ios-wsi-best-practices.md`

---

## 1. Context

Eva is an iPad application that performs real-time imaging with a fan-out pipeline: camera frames are color-transformed in Metal, delivered to a C++ engine for OpenCV edge detection, previewed live, and optionally recorded as HEVC 10-bit video or archived as 16-bit TIFF stills. The app is the iOS successor to an existing Android/Camera2/OpenGL ES/OpenCV implementation.

The core engineering challenge is not SwiftUI; it is a tight camera → GPU → C++ pipeline that must sustain 30fps at full-sensor resolution on an iPad A16 while preserving a zero-copy data path from camera hardware through Metal to the C++ edge-detection stage.

This ADR records the architecture decisions that shape the pipeline, concurrency model, and module boundaries.

---

## 2. Hard constraints (input to design)

| # | Constraint |
|---|---|
| C1 | Metal shaders apply color transforms to camera frames |
| C2 | Manual camera controls: focus lock, exposure duration, white balance gains; each with auto/manual toggle |
| C3 | Zero-copy from camera → Metal → C++ (copy only when C++ mutates) |
| C4 | Swift 6+, iPadOS 26+ |
| C5 | Data flow: configure camera → camera hardware → Metal → C++ sink → OpenCV edge detection |
| C6 | Metal output feeds preview; preview and C++ engine see the same pixels |
| C7 | 60fps target — **overridden by operator decision** in favor of full-sensor resolution; cadence is 30fps (see §4.1) |
| C8 | Camera output interpreted as 10-bit YUV → Metal converts to RGBA16F for downstream passes |
| C9 | Recording and still capture from Metal-processed frames |
| C10 | Concurrency and parallelism wherever possible |
| C11 | Three-way C++ sink fanout: natural (pre-transform), processed (post-transform, full-res), tracker (processed, 480p) |
| C12 | UI: manual controls with auto toggles; two previews (natural PiP + processed); capture and record buttons operating on processed frames |

---

## 3. Decisions

### 3.1 Platform baseline

- **Target device:** iPad A16 (11th generation, 2025)
- **OS floor:** iPadOS 26
- **Swift:** 6.2 with C++ interoperability enabled at module level (`.interoperabilityMode(.Cxx)`)
- **Metal:** Metal 3 baseline, Metal 4 features `#available`-gated
- **Build system:** Swift Package Manager as primary; Xcode project generated from the package for app shell

Rationale: iPadOS 26 unlocks Swift 6.2 approachable concurrency, `Span`/`MutableSpan` C++ interop, `InlineArray`, and Metal 4 tensor/residency primitives the app does not yet use but may adopt later. A16 is the minimum declared hardware.

### 3.2 Module split

```
EvaApp              @main SwiftUI app target; thin UI over facades
├── AppCore         Navigation, top-level @Observable coordinator state
├── CaptureKit      CaptureActor wrapping AVCaptureSession + AVCaptureDevice,
│                   KVO → AsyncStream adapter for live device state
├── PipelineKit     FramePipeline: CVPixelBufferPools, MTLCommandBuffer
│                   orchestration, IOSurface fanout dispatch
├── ShaderLib       .metal sources and MTLLibrary bootstrap
├── EncoderKit      RecordingActor (AVAssetWriter HEVC 10-bit BT.2020 HLG),
│                   StillWriter (16-bit TIFF), PhotosMigrator
├── Interop         Swift-facing facade over EvaCore; POD Sendable payloads
├── EvaCore         C++ (cxx-interop). PixelSink + EdgeDetector public;
│                   OpenCV strictly private in .cpp sources
└── TestingSupport  SyntheticFrameProvider replays pre-recorded .mov files
                    through the sample-buffer delegate for deterministic CI
```

Each module is a separate SPM target. `EvaCore` is the only C++ target; every other target is pure Swift. `EvaCore`'s public headers (exposed to Swift via its module map) include only POD structs, `SWIFT_SHARED_REFERENCE`-annotated classes (`PixelSink`, `EdgeDetector`), enums, and a C-ABI callback typedef. OpenCV headers are private includes in `.cpp` files, never in public headers.

Rationale: hard boundary between Swift and OpenCV keeps Swift compile times reasonable (OpenCV headers slow down Swift cxx-interop substantially) and keeps the public C++ API small enough to audit for thread-safety.

### 3.3 Pixel-data representation

**Camera output format:** `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange` (BT.2020), delivered by `AVCaptureVideoDataOutput` with `kCVPixelBufferMetalCompatibilityKey = true`. Frames arrive as IOSurface-backed `CVPixelBuffer`s. `CVMetalTextureCache` wraps the Y and CbCr planes as two zero-copy `MTLTexture`s (`r16Uint` and `rg16Uint`).

**Working format:** RGBA16F (half-float) in `MTLTexture`s backed by `CVPixelBuffer`s from three `CVPixelBufferPool`s (one per stream). Each pool is configured with `kCVPixelBufferPixelFormatTypeKey = kCVPixelFormatType_64RGBAHalf`, `kCVPixelBufferIOSurfacePropertiesKey`, and `kCVPixelBufferMetalCompatibilityKey`. This gives us IOSurface-backed half-float textures that can be handed to C++ zero-copy.

**Why RGBA16F:** matches constraint C8. The A16 GPU processes half-float natively at full speed. Downstream color transforms, downscale, and RGBA16F→YUV10 recording conversion all benefit from the extra precision versus 8-bit.

### 3.4 Camera format: full-sensor at 30fps

**Decision:** the camera is configured to the largest full-sensor 30fps format that supports 10-bit YUV output. The Metal pipeline center-crops to 1600×1200 in its first pass.

Startup procedure:
1. `AVCaptureDevice.DiscoverySession` locates `.builtInWideAngleCamera` at position `.back`.
2. Enumerate `device.formats`; filter for: 10-bit YUV 4:2:0 biplanar, supports 30fps, dimensions ≥ 1600×1200.
3. Select the highest resolution among survivors — expected 4160×3120 on A16 but adapts to whatever the actual device offers.
4. Lock the device and set `activeFormat`, `activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)`, `activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)`.
5. Verify `device.isLockingFocusWithCustomLensPositionSupported == true`; throw `CameraCapabilityError.customLensPositionUnsupported` otherwise.

Rationale: the operator has chosen full-sensor fidelity over 60fps motion smoothness. The Metal crop kernel parameterizes origin and size as uniforms, so the crop adapts automatically to whatever camera format is active. The preview cadence at 30fps on a 60Hz display produces 2 display frames per camera frame — acceptable visual judder for a live imaging workflow.

### 3.5 Per-frame GPU command graph

One `MTLCommandBuffer` per camera frame (30Hz). Passes are gated by pipeline mode to skip work that is not currently needed.

```
Input: CMSampleBuffer (10-bit YUV, ~4160×3120)
       │
       ▼
CVMetalTextureCache yields yTex (r16Uint), cbcrTex (rg16Uint)
       │
       ▼
[commandBuffer begin]

Pass 1  compute   crop_yuv10_to_rgba16f
                  reads yTex at (cropX, cropY) size (1600, 1200)
                  reads cbcrTex at (cropX/2, cropY/2) size (800, 600)
                  applies BT.2020 YUV→RGB matrix + EOTF
                  writes naturalTex (1600×1200 RGBA16F)

Pass 2  compute   color_transform_scaffold
                  reads naturalTex + ColorParamsUniform
                  writes processedTex (1600×1200 RGBA16F)
                  [initially passthrough; real transforms plugged in later]

Pass 3a render    overlay_composite (fragment shader)
                  reads processedTex + edgeMaskTex + OverlayUniform
                  writes processedPreviewDrawable (large preview)

Pass 3b blit      naturalTex → naturalPreviewDrawable (small PiP)
                  (blit scales via setSource/DestinationSize)

Pass 4  compute   lanczos_downscale_4:3         [gated: !recording]
                  reads processedTex
                  writes trackerTex (640×480 RGBA16F)

Pass 5  compute   rgba16f_to_yuv10              [gated: recording]
                  reads processedTex
                  writes AssetWriter adaptor CVPixelBuffer
                  (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

Pass 6  blit      processedTex → readback PB    [gated: still requested]
                  readback PB is RGBA16F, flagged for CPU access

[commandBuffer commit + present drawables + addCompletedHandler]
       │
       ▼
On GPU completion handler (arbitrary background queue):
  Publish IOSurfaceRefs to C++ PixelSink lanes:
    • .natural   ← naturalTex.iosurface
    • .processed ← processedTex.iosurface
    • .tracker   ← trackerTex.iosurface   [skipped during recording]
  Each publish retains the backing CVPixelBuffer; the C++ consumer
  releases it via a C-ABI callback when done.
```

**Guarantees:**
- The pixels the C++ `.processed` sink sees are bit-identical to the pixels in `processedPreviewDrawable` (constraint C6) — both come from the same `processedTex` in the same command buffer, before any subsequent frame touches it.
- Every intermediate texture is IOSurface-backed (constraint C3). The only copy in steady state is when C++ runs `cv::cvtColor` + `cv::Canny` into a fresh `cv::Mat` in Pass 4's consumer — which constraint C3 explicitly allows.

### 3.6 C++ PixelSink and EdgeDetector

```cpp
// EvaCore/include/eva/PixelSink.hpp  — PUBLIC, visible to Swift
namespace eva {

enum class StreamId : uint8_t { Natural = 0, Processed = 1, Tracker = 2 };
enum class PixelFormat : uint8_t { RGBA16F = 0 };

struct Frame {
    uint64_t presentationTimeNs;
    int32_t width;
    int32_t height;
    PixelFormat fmt;
    void*    iosurface;   // IOSurfaceRef; Swift-side retains/releases
};

using ConsumerCallback = void (*)(void* context, const Frame* frame);

class SWIFT_SHARED_REFERENCE(eva_pixel_sink_retain, eva_pixel_sink_release)
      PixelSink {
public:
    PixelSink();
    ~PixelSink();

    void subscribe(StreamId stream, const char* id,
                   ConsumerCallback cb, void* context);
    void unsubscribe(StreamId stream, const char* id);

    // Platform adapter calls this on GPU completion.
    void publish(const Frame& frame);

private:
    struct Impl;
    Impl* impl_;
};

} // namespace eva
```

```cpp
// EvaCore/include/eva/EdgeDetector.hpp — PUBLIC
namespace eva {

struct CannyParams {
    double lowThreshold;
    double highThreshold;
    int32_t kernelSize;     // 3, 5, or 7
    bool l2Gradient;
};

using EdgeResultCallback = void (*)(void* context,
                                    uint64_t presentationTimeNs,
                                    const uint8_t* edges,
                                    int32_t width,
                                    int32_t height,
                                    int32_t bytesPerRow);

class SWIFT_SHARED_REFERENCE(eva_edge_detector_retain,
                             eva_edge_detector_release)
      EdgeDetector {
public:
    EdgeDetector();
    ~EdgeDetector();

    void setParams(const CannyParams& params);    // thread-safe, atomic swap
    void attachToSink(PixelSink* sink, StreamId stream);
    void setResultCallback(EdgeResultCallback cb, void* context);

private:
    struct Impl;   // includes OpenCV headers in .cpp only
    Impl* impl_;
};

} // namespace eva
```

Rationale: the public surface is POD + opaque reference types. OpenCV is transitively hidden. Swift imports these as ARC-managed classes via `SWIFT_SHARED_REFERENCE`. No `.mm` layer needed.

**Thread model inside C++:** a fixed-size thread pool (`std::min(4, hw_concurrency)`) processes consumer callbacks. Each stream lane has its own MPSC queue; publishers drop into their lane without blocking each other. Consumer callbacks run in parallel across lanes. Back-pressure: each lane is bounded at 4 frames; on overflow, the oldest is dropped (suitable for live preview, not for recording — which is why recording uses the direct Metal → AssetWriter path, bypassing the sink).

### 3.7 Edge-overlay feedback loop

`EdgeDetector` consumes `.tracker` frames (640×480 RGBA16F) off the C++ thread pool:

1. `IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr)`
2. Construct `cv::Mat` aliasing the locked bytes as `CV_16FC4`
3. `cv::cvtColor` → 8-bit grayscale
4. `cv::Canny` → 8-bit single-channel mask
5. `IOSurfaceUnlock`
6. Invoke `EdgeResultCallback` (C-ABI function pointer) with `presentationTimeNs` + mask pointer + dimensions
7. Swift callback uploads mask bytes into a persistent `edgeMaskTex` (`.r8Unorm`, 640×480) via `replaceRegion`
8. Next `overlay_composite` pass samples this texture

Latency budget on A16: IOSurface lock ~negligible, cvtColor ~1.5ms, Canny ~2ms, unlock + callback + upload ~1ms. Total ~4-5ms, well inside the 33ms frame budget. Overlay appears 1 frame behind the live pixels in steady state; up to 2 frames during thermal transients. Swift stores "latest mask" keyed by PTS; on each overlay pass the latest mask is used regardless of age. If the overlay feature is toggled off in the UI, Pass 4 skips and `edgeMaskTex` is cleared — Pass 3a's fragment shader short-circuits when `OverlayUniform.opacity == 0`.

During recording, Pass 4 and the `.tracker` sink are both gated off. The overlay continues to display the last edge mask captured before recording started, or disables based on the UI toggle.

### 3.8 Concurrency topology

| Domain | Isolation | Work |
|---|---|---|
| `@MainActor` | Actor | SwiftUI views, `CameraControlViewModel`, `RecordingViewModel`, `CameraState` (observed) |
| `CaptureActor` | Serial actor | `AVCaptureSession` reconfiguration, `AVCaptureDevice.lockForConfiguration()` windows, manual-control writes |
| Camera delivery queue | `DispatchQueue(label: "eva.camera.delivery", qos: .userInteractive)` | `AVCaptureVideoDataOutputSampleBufferDelegate` callback, CVMetalTextureCache wraps, command buffer build + commit |
| GPU completion handler | Runs on Metal's internal queue; trampolines back to delivery queue for publish | IOSurface handoff to `PixelSink` |
| `PixelSink` thread pool | C++ pool, 3 lane queues | Natural consumer, Processed consumer, Tracker consumer (Canny) |
| `RecordingActor` | Serial actor | `AVAssetWriter` state, finalize + Photos migration |
| Photos writes | `PHPhotoLibrary.shared().performChanges { }` | Migrate temp .mov and temp .tiff into library |

**Key property:** nothing on the 30Hz frame clock hops an actor boundary. The sample buffer delegate is `nonisolated` and runs on the delivery queue. It builds and commits the command buffer inline. UI state updates to `@MainActor` are batched (coalesced per frame) and scheduled via a single `Task { @MainActor in vm.update(stats) }` call at the end of the delegate method.

**Swift 6 strict concurrency:** all SPM targets opt in (`.swiftLanguageMode(.v6)`). Approachable Concurrency (SE-0466) enables default `@MainActor` isolation in the `EvaApp`, `AppCore`, and Interop targets. `CaptureKit`, `PipelineKit`, and `EncoderKit` use explicit isolation (no default `@MainActor`) to prevent accidental hops. `EvaCore` types bridge via `@unchecked Sendable` facades documented with explicit thread-safety contracts.

### 3.9 Manual camera controls and device state

Controls exposed in UI:
- **ISO** — auto / manual; manual slider bounded by `activeFormat.minISO…maxISO`
- **Exposure duration** — auto / manual; manual slider bounded by `activeFormat.minExposureDuration…maxExposureDuration`
- **Focus** — auto / manual (custom lens position); manual slider `0.0…1.0`
- **White balance gains** — auto / manual; manual sliders per R/G/B bounded by `1.0…device.maxWhiteBalanceGain`

All bounds are fetched live from the device — never hardcoded. The `CameraControlViewModel` binds sliders to `CameraState`'s `@Observable` properties. User interactions coalesce at 60Hz through a small debouncer and commit to `CaptureActor`, which performs the `lockForConfiguration()` / `setExposureModeCustom` / `setWhiteBalanceModeLocked` / `setFocusModeLocked` calls.

State is streamed back to the UI via KVO on the device. An adapter wraps KVO observations as `AsyncStream`:

```swift
final class DeviceStateStream: @unchecked Sendable {
    func states() -> AsyncStream<CameraState.Snapshot> { … }
}
```

The stream is consumed by a `@MainActor`-isolated task in `CameraState` which mirrors values into `@Observable` properties. Mode toggles (auto/manual) are UI-state only; switching to `.auto` calls the device's `continuousAutoExposure` / `continuousAutoFocus` / `continuousAutoWhiteBalance` modes and stops commiting manual values.

### 3.10 Recording

- Codec: `AVVideoCodecType.hevc`, Main10 profile
- Color: BT.2020 primaries, HLG transfer, BT.2020 YCbCr matrix (`AVVideoColorPropertiesKey`)
- Resolution: 1600×1200 (matches processedTex)
- Frame rate: 30fps
- Audio: none
- Container: `.mov`
- Staging: `FileManager.default.temporaryDirectory`
- Writer pool format: `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange`
- GPU→encoder conversion: Pass 5 compute kernel `rgba16f_to_yuv10` writes directly into the adaptor's buffer

On stop (`RecordingActor.stop()`):
1. `writerInput.markAsFinished()` → `writer.finishWriting { … }`
2. `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: movURL, options: nil) }`
3. On success, delete the temp .mov; publish `.savedToPhotos` event to UI

On interruption mid-recording: the same finalization runs, triggered from the interruption handler (see §3.12). The partial file is saved; a user-facing alert surfaces on resume.

### 3.11 Still capture

Pipeline:
1. User taps shutter → `PipelineKit` sets `stillRequested = true` flag (read on next frame)
2. Next frame's Pass 6 blits `processedTex` into a dedicated CPU-readable `CVPixelBuffer` (RGBA16F, 1600×1200, pool of size 2)
3. `commandBuffer.addCompletedHandler` → `StillWriter.encode(pixelBuffer:, pts:)`
4. `StillWriter`:
   - Locks the CVPixelBuffer for read
   - Builds a `CGImage` with `kCGBitmapByteOrder16Little | kCGImageByteOrderDefault | .floatComponents`, BT.2020 linear color space
   - Writes to a temp `.tiff` via `CGImageDestinationCreateWithURL(tempURL, UTType.tiff.identifier, 1, nil)`, setting `kCGImagePropertyColorModel = kCGImagePropertyColorModelRGB`, `kCGImagePropertyDPIWidth = 72`, `kCGImageDestinationLossyCompressionQuality = 1.0`
   - `PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: tiffURL) }`
5. On success, delete temp .tiff; publish `.savedToPhotos` event

Caveat: Photos' built-in share sheet may transcode 16-bit TIFF to JPEG/HEIC when exporting to third-party apps; the archival data is preserved in the library but not always when re-exported. Documented in the user-facing help.

### 3.12 Session interruptions and app lifecycle

Observed events:
- `AVCaptureSession.wasInterruptedNotification` (camera taken by FaceTime, etc.)
- `AVCaptureSession.interruptionEndedNotification`
- `UIApplication.didEnterBackgroundNotification` / `.willEnterForegroundNotification`
- `scenePhase` transitions (`.active` / `.inactive` / `.background`)

On any "session going away" event (interrupted OR backgrounded):
1. If recording: `RecordingActor.stop()` finalizes and migrates the partial .mov to Photos
2. `PipelineKit.teardown()` releases texture caches, pixel buffer pools, `edgeMaskTex`
3. `CaptureActor.stop()` calls `session.stopRunning()`
4. `CameraState.status = .interrupted(reason)`

On resume:
1. `CaptureActor.start()` reconfigures session (format, inputs, outputs)
2. Reapply cached manual settings (ISO, exposure, focus position, WB gains, mode toggles)
3. `PipelineKit.rebuild()` creates fresh pools + textures
4. `session.startRunning()`
5. If partial recording was saved during the interruption: `CameraState.pendingAlert = .recordingSaved(url:...)`; the UI shows a modal on first frame

Brief (~500ms) black frame during rebuild is expected.

### 3.13 Thermal monitoring

`ProcessInfo.processInfo.thermalState` is observed via `ProcessInfo.thermalStateDidChangeNotification`. The value is mirrored to a `@MainActor` `@Observable ThermalBanner` state. UI shows a non-intrusive banner when state ≥ `.serious`. No pipeline adaptation in v1. A `ThermalObserver` interface is wired in but currently only logs — this is an explicit revisit-later slot (see §7).

### 3.14 Debug panel

Visible button in the main UI, compile-gated to Debug and TestFlight builds via:

```swift
#if DEBUG
static let isEnabled = true
#else
static let isEnabled = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
```

(TestFlight receipts live at `sandboxReceipt`.)

Debug sheet contents:
- Canny params (`lowThreshold`, `highThreshold`, `kernelSize`) — sliders commit to `EdgeDetector.setParams`
- Overlay uniform (color RGB, opacity, threshold) — sliders commit to `PipelineKit`
- Active camera format readout (dimensions, fps, pixel format, color space)
- Per-stream FPS + drop counters (from `PipelineKit.stats`)
- Thermal state + memory pressure
- Command buffer timings (from `addScheduledHandler` / `addCompletedHandler` deltas)

### 3.15 Testing strategy

- **Swift Testing** (`@Test`), not XCTest
- `SyntheticFrameProvider` reads a pre-recorded `.mov` via `AVAssetReader` and drives the `sampleBufferDelegate` with deterministic timestamps — used for CI + local dev without real hardware
- Shader tests render to offscreen `MTLTexture`, read back, compare against golden RGBA16F TIFFs in `Tests/EvaAppTests/golden/`, with per-channel tolerance (`epsilon = 1/2048` for f16)
- C++ tests directly instantiate `PixelSink` and `EdgeDetector` from Swift test code via cxx-interop; no separate C++ test harness needed
- Camera/permissions paths tested via a `MockCaptureSession` protocol conformance (the real `CaptureActor` wraps a protocol, enabling injection)

Coverage priorities:
1. Command-graph correctness (golden-frame comparison on known inputs) — highest priority
2. Interruption/recovery state machine (property-based tests on state transitions)
3. EdgeDetector result stability (same input → same mask ± tolerance)
4. UI + control debouncing behavior (screenshot snapshots)

---

## 4. Trade-offs

### 4.1 30fps over 60fps (constraint C7)

**Chosen:** full-sensor 30fps.
**Alternative:** 60fps at a smaller format (likely 3840×2160), center-crop to 1600×1200.
**Trade:** lose motion smoothness and halve the per-frame GPU budget's headroom; gain the full 4160×3120 sensor as source material for the 1600×1200 crop (≈2.6× oversampling per axis), preserving fine detail.
**Revisit if:** a future hardware target (M-series iPad) can sustain full-sensor 60fps.

### 4.2 RGBA16F working format everywhere

**Chosen:** RGBA16F for natural, processed, tracker.
**Alternative:** RGBA8 for tracker (halves bandwidth).
**Trade:** cost ≈ 4× bandwidth vs RGBA8 on the tracker path, but Canny runs on 8-bit grayscale downstream regardless, so the end-to-end fidelity benefit is minor. RGBA16F is kept for uniformity — every sink sees the same format; the C++ Frame struct is one shape.
**Revisit if:** thermal throttling on A16 becomes a field problem. Downgrading tracker to RGBA8 is a 30-line change.

### 4.3 Edge overlay feedback through Metal

**Chosen:** Canny output uploaded back to GPU as `edgeMaskTex`; overlay composited by fragment shader.
**Alternative 1:** Return bounding boxes/contours as Sendable geometry; draw with SwiftUI `Path`s over the preview view.
**Alternative 2:** No overlay at all; edges consumed only internally.
**Trade:** option 1 costs ~300KB upload + a fragment sample per preview pixel. Geometry delivery (alt 1) is cheaper per frame but changes the UI from a Metal fragment overlay to a SwiftUI Canvas, which layers differently over a Metal view and can look less integrated.
**Revisit if:** adding richer annotations (labels, hover interactions) where geometry semantics beat raw pixels.

### 4.4 Direct Swift ↔ C++ interop (no .mm shim)

**Chosen:** cxx-interop throughout; `SWIFT_SHARED_REFERENCE` for sink/detector.
**Alternative:** Objective-C++ facade exposed to Swift.
**Trade:** interop is newer and occasionally rejects templates that a `.mm` bridge would accept. Mitigated by keeping OpenCV strictly private to `.cpp` — its templates never reach the Swift compiler.
**Revisit if:** a future public C++ API needs templates that interop rejects.

### 4.5 Three CVPixelBufferPools

**Chosen:** distinct pool per stream (natural/processed/tracker).
**Alternative:** one pool of maximum-size buffers, slice views for tracker.
**Trade:** slight memory overhead (3 pools × 4 buffers × format size). Gain: C++ consumer holding a tracker frame for too long starves only its pool, not the main pipeline.
**Revisit if:** memory pressure becomes significant — on A16, current design costs ~35 MB of IOSurface memory; well within budget.

### 4.6 Photos library for TIFF stills

**Chosen:** Photos via `PHAssetCreationRequest.addResource(.photo, fileURL:)`.
**Alternative:** app Documents directory, exposed to Files app.
**Trade:** Photos preserves original TIFF bytes but the share sheet may transcode on export. Documents is more archival-safe but less discoverable.
**Revisit if:** user feedback indicates TIFF export from Photos is degrading fidelity for downstream tools.

---

## 5. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A16 camera format list does not actually include 4160×3120 @ 30fps 10-bit YUV | Medium | Design assumes full-sensor format; pipeline adapts to whatever is available because crop is parameterized | Enumerate formats at startup; pick best available that meets ≥1600×1200 crop requirement; fail explicit if none |
| A16 thermal throttling on sustained 30fps full-sensor + CV | Medium | Frame drops, UI jank, user complaints | Thermal banner + adaptive degradation planned as follow-on; baseline pipeline keeps running (drops are graceful) |
| TIFF in Photos transcoded on export | Low | Archival fidelity lost when user shares to third-party apps | Document workaround (direct file access via Photos app's export-original); provide in-app export to Files if needed |
| Swift cxx-interop template rejection on a future OpenCV-adjacent API | Low | Forced to add a .mm shim | Public C++ API is intentionally narrow and POD; revisit adds hours, not days |
| GPU completion handler races with `PipelineKit.teardown()` during interruption | Medium | Crash on use-after-free of texture cache | All completion handlers capture weak pipeline reference; teardown waits for in-flight command buffers via `commandQueue.insertDebugCaptureBoundary()` and per-buffer `waitUntilCompleted()` |
| KVO observations leak across device reconfiguration | Low | Stale values in UI | `DeviceStateStream` invalidates and restarts on device change; `AsyncStream` terminates cleanly |

---

## 6. Non-goals

- Supporting multiple cameras simultaneously. A16 has a single rear wide camera; `AVCaptureMultiCamSession` not used.
- OpenGL ES fallback. Metal-only.
- Background recording. Session stops on background per constraint; no `BGTaskScheduler` integration for capture.
- DICOM / WSI tile file format I/O. Out of scope for this imaging pipeline ADR; lives in future WSI-specific ADR.
- On-device ML inference inside the color-transform pipeline. Slot exists in Pass 2 for future integration but no model is shipped initially.
- Audio capture or processing.

---

## 7. Follow-on decisions / revisit triggers

- **Thermal-adaptive degradation.** Measure under load; add rules (drop Canny to 15Hz at `.serious`; disable overlay at `.critical`).
- **Capture Controls API (iOS 26).** Add `AVCaptureControl` bindings so hardware buttons trigger shutter / recording — follow-up once MVP ships.
- **Metal 4 residency sets / sparse tiles.** If WSI features land and we need streaming from multi-GB tile pyramids, this is the ADR to file.
- **Adaptive camera format.** If field hardware varies (older iPads without full-sensor 30fps), consider runtime selection with UI-surfaced mode indicator.
- **Real color transforms.** Pass 2 is scaffold only. When a concrete transform (3D LUT, matrix+curve, stain normalization) lands, file a separate ADR if it changes the pipeline shape.
- **External display output.** iPadOS 26 supports treating external displays as first-class scenes. Revisit if clinical review monitors enter scope.

---

## 8. References

### Primary
- [Apple — AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession)
- [Apple — AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice)
- [Apple — AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)
- [Apple — CVMetalTextureCache](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache)
- [Apple — PHAssetCreationRequest](https://developer.apple.com/documentation/photokit/phassetcreationrequest)
- [Apple — ProcessInfo.ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate)
- [Swift.org — C++ Interoperability](https://www.swift.org/documentation/cxx-interop/)
- [Swift.org — Safe Interop](https://www.swift.org/documentation/cxx-interop/safe-interop/)
- [SE-0466 — Control default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
- [forums.swift.org — Safely use AVCaptureSession + Swift 6.2 Concurrency](https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622)
- [WWDC25 session 205 — Discover Metal 4](https://developer.apple.com/videos/play/wwdc2025/205/)
- [WWDC25 session 253 — Enhancing your camera experience with capture controls](https://developer.apple.com/videos/play/wwdc2025/253/)
- [WWDC23 session 10172 — Mix Swift and C++](https://developer.apple.com/videos/play/wwdc2023/10172/)

### Project research
- [android-to-ios-swiftui-porting-research.md](../android-to-ios-swiftui-porting-research.md)
- [docs/ios-wsi-best-practices.md](./ios-wsi-best-practices.md)
