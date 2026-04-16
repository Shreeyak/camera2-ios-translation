# 04 — OpenCV Integration

This file covers the C++ consumer architecture (`PixelSink` + `EdgeDetector`), OpenCV iOS
framework setup, the full EdgeDetector processing pipeline, the Interop Swift facade layer,
and the result return path to `@MainActor`.

**Note:** OpenCV edge detection is a NEW capability added for the iOS version.
It does NOT exist in the Android source — this is not a port.

---

## C++ Consumer Architecture: PixelSink + EdgeDetector

### Design Rationale

The previous IFrameConsumer + Swift ConsumerRegistry approach delivered frames via
`CVPixelBuffer + std::span` with per-consumer `DispatchQueue` actors in Swift.
This design replaces it with a fully C++ dispatch model:

| Concern | Old design | New design |
|---|---|---|
| Frame handoff type | CVPixelBuffer + `std::span` (requires lock/unlock) | IOSurface-backed Frame struct (lock only in consumer) |
| Dispatch ownership | Swift `ConsumerRegistry` actor (1-slot mailbox per consumer) | C++ `PixelSink` thread pool (MPSC lane per stream) |
| Drop-on-busy policy | ConsumerRegistry drops at yield point | PixelSink lane overwrites 1-slot mailbox in C++ |
| Swift actor involvement | Required on every frame dispatch | None on frame path; Swift only at subscription time |
| C++ consumer interface | `IFrameConsumer` pure-virtual interface | SWIFT_SHARED_REFERENCE base class with C-ABI callback |

**Key:** nothing on the 30 Hz frame clock hops a Swift actor boundary. PixelSink::publish
is called from the GPU completion handler on the delivery queue; C++ consumers run on their
own pool threads. Results return to Swift via C-ABI callbacks.

### PixelSink — Public Header

```cpp
// File: Sources/ImagingCore/include/imagingcore/PixelSink.hpp
#pragma once
#include <cstdint>

namespace imagingcore {

enum class StreamId : uint8_t {
    Natural   = 0,   // Full-crop RGBA16F stream
    Processed = 1,   // Color-transformed RGBA16F stream
    Tracker   = 2,   // 640×480 RGBA16F downscaled stream (for CV consumers)
};

enum class PixelFormat : uint8_t {
    RGBA16F = 0,   // Half-float RGBA, R,G,B,A channel order, used for all three streams
};

// IOSurface-backed frame descriptor. The iosurface field is an IOSurfaceRef
// (void* to avoid importing <IOSurface/IOSurface.h> in the public header).
// Consumers call IOSurfaceLock/IOSurfaceUnlock directly.
struct Frame {
    uint64_t  presentationTimeNs;   // Monotonic nanoseconds
    int32_t   width;
    int32_t   height;
    PixelFormat format;             // Always RGBA16F in this design
    void*     iosurface;            // IOSurfaceRef; non-owning — PixelSink retains it
};

// C-ABI callback type. Invoked on the PixelSink thread pool after IOSurface
// is available. context is the pointer passed to subscribe().
// The Frame's iosurface is valid until the callback returns.
extern "C" using PixelSinkCallback = void (*)(const Frame*, void* context);

class PixelSink {
public:
    // SWIFT_SHARED_REFERENCE — ARC-managed in Swift.
    // Retain/release functions are defined in PixelSink.cpp.
    static PixelSink* create() noexcept;
    void retain() noexcept;
    void release() noexcept;

    // Subscribe / unsubscribe a consumer for a stream.
    // Thread-safe. callback and context are stored; callback is invoked on
    // pool threads. Subscribing when already subscribed replaces the callback.
    void subscribe(StreamId stream, PixelSinkCallback callback,
                   void* context) noexcept;
    void unsubscribe(StreamId stream) noexcept;

    // Publish a frame to all subscribers of the given stream. Non-blocking.
    // Each subscriber's MPSC lane gets a 1-slot mailbox: newest overwrites pending.
    // Called from the GPU completion handler on the delivery queue.
    void publish(StreamId stream, const Frame& frame) noexcept;

private:
    // Thread pool (std::min(4, hw_concurrency) threads)
    // Per-stream MPSC lane with 1-slot mailbox
    // ... (implementation detail)
};

} // namespace imagingcore
```

**SWIFT_SHARED_REFERENCE annotation** (in Package.swift `cxxSettings` or via a compiler
flag) enables ARC management of `PixelSink*` in Swift. The Swift `Interop` module wraps
it in `PixelSinkFacade` (see below) and calls `subscribe`/`unsubscribe` at session
start/stop.

### EdgeDetector — Public Header

```cpp
// File: Sources/ImagingCore/include/imagingcore/EdgeDetector.hpp
#pragma once
#include "PixelSink.hpp"
#include <cstdint>

namespace imagingcore {

// POD result types — fully importable into Swift via direct C++ interop.
// No cv:: types, no templates, no exceptions.
struct EdgePoint  { int32_t x; int32_t y; };
struct EdgeContour { EdgePoint* points; int32_t count; };  // pool-allocated

enum class EdgeStatus : uint8_t { Ok = 0, Error = 1 };

struct EdgeResult {
    EdgeStatus status;
    EdgeContour* contours;     // pool-allocated array; valid until next onFrame
    int32_t      contourCount;
    int64_t      framePTS;     // presentationTimeNs from Frame
    double       processingTimeMs;
};

// C-ABI callback invoked after each frame is processed.
extern "C" using EdgeResultCallback = void (*)(const EdgeResult*, void* context);

class EdgeDetector {
public:
    // SWIFT_SHARED_REFERENCE — ARC-managed in Swift.
    static EdgeDetector* create(PixelSink* sink) noexcept;
    void retain() noexcept;
    void release() noexcept;

    // Subscribe to StreamId::Tracker on the given PixelSink.
    // Must be called before the capture session starts.
    void subscribe() noexcept;
    void unsubscribe() noexcept;

    // Set Canny thresholds at runtime (thread-safe, atomic store).
    void setThresholds(double low, double high) noexcept;

    // Set callback to invoke after each processed frame.
    void setResultCallback(EdgeResultCallback callback, void* context) noexcept;

    // Shared MTLTexture that EdgeDetector composites into.
    // Swift MTKView reads this texture for edge overlay rendering.
    // id<MTLTexture> as void* to avoid Metal headers in public API.
    void setOutputTexture(void* mtlTexture) noexcept;

private:
    // Subscribed to PixelSink::StreamId::Tracker
    // Owns result contour pool
    // ... (implementation detail)
};

} // namespace imagingcore
```

---

## EdgeDetector Processing Pipeline

EdgeDetector MUST subscribe to `StreamId::Tracker` (640×480 downscaled stream),
NOT `StreamId::Processed` (full crop resolution). This is load-bearing for the
16ms frame budget:

| Stream | Resolution | Pixels/frame | Canny CPU cost (est.) | Fits 16ms? |
|---|---|---|---|---|
| Processed | ~1600×1200 (after crop) | ~1.9M | 15–25 ms/frame on A16 | Marginal |
| Tracker | 640×480 | ~0.3M | 2–4 ms/frame on A16 | Yes |

Canny is `O(pixels)` dominated by Gaussian blur + Sobel gradient. The tracker stream
is specifically sized for per-frame CV consumers.

### Per-Frame Processing (in EdgeDetector.cpp)

```
Frame arrives from PixelSink (StreamId::Tracker, 640×480, RGBA16F, IOSurface-backed)

1. IOSurfaceLock(iosurface, kIOSurfaceLockReadOnly)
2. cv::Mat rgba16f = alias as CV_16FC4 (zero-copy over IOSurface pixel data)
   width=640, height=480, step=bytesPerRow
3. cv::transform(rgba16f, gray16f,
       cv::Matx<float, 1, 4>(0.2126f, 0.7152f, 0.0722f, 0.0f))
   // BT.709 luma; channel order is R,G,B,A — NOT BGRA
4. gray16f.convertTo(gray8u, CV_8U, 255.0)
   // Canny requires CV_8UC1 input
5. cv::Canny(gray8u, edges, lowThreshold_, highThreshold_)
6. cv::findContours(edges, contours, RETR_EXTERNAL, CHAIN_APPROX_SIMPLE)
7. Composite edge overlay onto rgba16f:
   Draw contour paths in green onto the tracker frame (C++ only — no Metal)
8. IOSurfaceUnlock(iosurface, kIOSurfaceLockReadOnly)
9. Write composited result to the shared MTLTexture (pre-allocated .shared storage)
   using Metal's texture.replace(region:...) or a blit pass on the main Metal queue
10. Invoke EdgeResultCallback with EdgeResult { status, contours, framePTS, processingTimeMs }
```

**Channel order note:** IOSurface data is RGBA16F (R, G, B, A). BT.709 weights apply
to (R, G, B) in that order — `(0.2126, 0.7152, 0.0722, 0.0)`. BGRA is never used.

**Why compositing happens in C++:** Intentionally less efficient than a Metal-overlay
approach. It mirrors the future architecture where C++ will perform complex multi-layer
overlays, stain normalization previews, and ROI annotations.

**Shared MTLTexture:** Pre-allocated by `FramePipeline` at session start with
`.shared` storage mode and appropriate mipmap levels. EdgeDetector writes to it;
Swift MTKView reads it. Because the texture has `.shared` storage, CPU writes are
visible to the GPU without a blit. Mipmap levels provide filtering quality when the
overlay is zoomed out.

---

## Swift Interop Layer (Interop Module)

`Sources/Interop/` contains pure Swift. It imports `ImagingCore` via
`.interoperabilityMode(.Cxx)` and `CoreVideo`/`Metal` for texture management.
There are NO `.mm` files anywhere.

### PixelSinkFacade

```swift
// File: Sources/Interop/PixelSinkFacade.swift
import ImagingCore   // Clang module via .interoperabilityMode(.Cxx)
import Metal

// SWIFT_SHARED_REFERENCE makes imagingcore.PixelSink ARC-manageable in Swift.
// PixelSinkFacade is a thin Swift wrapper that owns the C++ PixelSink.
final class PixelSinkFacade {
    private let sink: imagingcore.PixelSink   // ARC-managed via SWIFT_SHARED_REFERENCE

    init() {
        sink = imagingcore.PixelSink.create()
    }

    // Called by FramePipeline GPU completion handler (delivery queue)
    func publish(stream: imagingcore.StreamId, frame: imagingcore.Frame) {
        sink.publish(stream, frame)
    }

    func subscribe(stream: imagingcore.StreamId,
                   callback: imagingcore.PixelSinkCallback,
                   context: UnsafeMutableRawPointer?) {
        sink.subscribe(stream, callback, context)
    }

    func unsubscribe(stream: imagingcore.StreamId) {
        sink.unsubscribe(stream)
    }

    // Raw pointer for passing to EdgeDetector.create()
    var rawSink: imagingcore.PixelSink { sink }
}
```

### EdgeDetectorFacade

```swift
// File: Sources/Interop/EdgeDetectorFacade.swift
import ImagingCore
import Metal

final class EdgeDetectorFacade {
    private let detector: imagingcore.EdgeDetector   // SWIFT_SHARED_REFERENCE
    private var outputTexture: MTLTexture?

    init(pixelSink: PixelSinkFacade) {
        detector = imagingcore.EdgeDetector.create(pixelSink.rawSink)
    }

    // Called once at session start. texture must be .shared storage mode.
    func configure(outputTexture: MTLTexture,
                   lowThreshold: Double = 50,
                   highThreshold: Double = 150) {
        self.outputTexture = outputTexture
        detector.setOutputTexture(Unmanaged.passUnretained(outputTexture as AnyObject)
                                            .toOpaque())
        detector.setThresholds(lowThreshold, highThreshold)
        detector.setResultCallback(edgeResultCallback,
                                   Unmanaged.passRetained(self).toOpaque())
    }

    // Set Canny thresholds at runtime (e.g., from a SwiftUI slider)
    func setThresholds(low: Double, high: Double) {
        detector.setThresholds(low, high)
    }

    func start() { detector.subscribe() }
    func stop()  { detector.unsubscribe() }
}

// C-ABI callback — called on PixelSink pool thread after each frame
private func edgeResultCallback(_ result: UnsafePointer<imagingcore.EdgeResult>?,
                                 context: UnsafeMutableRawPointer?) {
    guard let result, let context else { return }
    let facade = Unmanaged<EdgeDetectorFacade>.fromOpaque(context)
                                              .takeUnretainedValue()
    let swiftResult = EdgeResult(from: result.pointee)
    Task { await MLProcessor.shared.handle(swiftResult) }
}
```

### EdgeResult — Sendable Swift Struct

```swift
// File: Sources/Interop/EdgeResult.swift
struct EdgePoint: Sendable {
    let x: Int32
    let y: Int32
}

struct EdgeContour: Sendable {
    let points: [EdgePoint]
}

struct EdgeResult: Sendable {
    let status:          imagingcore.EdgeStatus
    let contours:        [EdgeContour]
    let framePTS:        Int64    // presentationTimeNs for frame alignment
    let processingTimeMs: Double

    init(from cxx: imagingcore.EdgeResult) {
        status = cxx.status
        framePTS = cxx.framePTS
        processingTimeMs = cxx.processingTimeMs
        contours = (0..<Int(cxx.contourCount)).map { i in
            let c = cxx.contours[i]
            return EdgeContour(points: (0..<Int(c.count)).map { j in
                EdgePoint(x: c.points[j].x, y: c.points[j].y)
            })
        }
    }
}
```

Since all fields are value types conforming to `Sendable`, `EdgeResult` crosses
actor boundaries freely (`@MLProcessor` → `@MainActor`).

---

## Swift-C++ Interop Assessment for OpenCV

Swift 6.2+ with `.interoperabilityMode(.Cxx)` and `cxxLanguageStandard: .cxx20`
supports direct import of:
- Plain POD types, structs, non-template classes
- `SWIFT_SHARED_REFERENCE`-annotated refcounted classes
- Basic enum classes and C-ABI function pointers

OpenCV's `cv::Mat`, `cv::InputArray`, and the heavy template headers remain
problematic for the Clang module importer. **But this only matters if Swift
imports OpenCV headers.** Under this design, **Swift never imports `<opencv2/*>`.**
OpenCV is fully encapsulated as a private implementation detail inside
`Sources/ImagingCore/src/*.cpp`. The public headers under
`Sources/ImagingCore/include/imagingcore/` contain only POD, SWIFT_SHARED_REFERENCE
classes, and C-ABI callback typedefs — exactly what Swift 6.2+ direct interop handles.

**Exception discipline is load-bearing.** An uncaught C++ exception crossing into
Swift aborts the process. Every method in `EdgeDetector.cpp` wraps `cv::` calls in:

```cpp
try { ... }
catch (const cv::Exception& e) { /* log, return */ }
catch (const std::exception& e) { /* log, return */ }
catch (...) { /* log, return */ }
```

This is enforced by code review. There are no `noexcept` qualifiers on private `.cpp`
methods that call OpenCV — the try/catch is load-bearing instead.

---

## OpenCV iOS Framework Setup

### Chosen Distribution: SwiftPM `binaryTarget` wrapping `opencv2.xcframework`

**Chosen:** Official `opencv2.xcframework` from opencv.org releases, wrapped as
a SwiftPM `binaryTarget` in `Package.swift`. `ImagingCore` depends on the
binary target. Alternatives considered: CocoaPods (deprecated trajectory), hand-wired
`.xcconfig` HEADER_SEARCH_PATHS (bypasses SwiftPM graph), build from source via CMake
(maximum control, ~30–50 MB vs 80–120 MB prebuilt — worth revisiting if binary size
is a release blocker).

**Chosen because:** SwiftPM `binaryTarget` is declarative, has no `.xcconfig` files,
and automatically selects the correct slice for device vs simulator.

### Integration (SwiftPM)

```swift
// Package.swift — relevant fragments

let package = Package(
    name: "CamPlugin",
    platforms: [.iOS(.v26)],
    targets: [
        // OpenCV as a SwiftPM binary target.
        .binaryTarget(
            name: "opencv2",
            path: "Frameworks/opencv2.xcframework"
        ),

        // Pure-C++ core. Apple-free public headers. OpenCV is private.
        .target(
            name: "ImagingCore",
            dependencies: ["opencv2"],
            path: "Sources/ImagingCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .define("OPENCV_PRIVATE", to: "1"),
            ]
        ),

        // Swift facade: imports ImagingCore via direct C++ interop.
        // Also imports Metal (for texture handoff).
        .target(
            name: "Interop",
            dependencies: ["ImagingCore"],
            path: "Sources/Interop",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),

        .target(name: "CaptureKit",  dependencies: []),
        .target(name: "PipelineKit", dependencies: ["Interop"]),
        .target(name: "EncoderKit",  dependencies: []),
        .target(name: "EvaCore",     dependencies: ["CaptureKit", "PipelineKit", "EncoderKit"],
                swiftSettings: [.enableExperimentalFeature("DefaultIsolation(MainActor)")]),
        .target(name: "EvaApp",      dependencies: ["EvaCore"]),
        .target(name: "TestingSupport", dependencies: []),
    ],
    cxxLanguageStandard: .cxx20
)
```

The `OPENCV_PRIVATE` define is a belt-and-suspenders signal used by include guards to
assert that OpenCV is a private dependency — no public header under `include/imagingcore/`
may transitively expose it.

### Independent Testability

`ImagingCore` is a standalone SwiftPM library target with no Apple-framework
dependencies in its public headers. `ImagingCoreTests` can run `EdgeDetector`
against in-memory IOSurface fixture buffers via `swift test` on the macOS host —
no Metal, no AVFoundation, no camera required. The test target creates an IOSurface,
writes synthetic RGBA16F pixel data into it, calls through `PixelSink::publish`, and
asserts the resulting `EdgeResult` matches expected contour output.

---

## Edge Overlay Display (MTKView — not SwiftUI Canvas)

EdgeDetector composites its output directly onto a pre-allocated shared `MTLTexture`
(640×480, `.shared` storage mode). The Swift side renders this texture via an `MTKView`
in `EvaCore`, not a SwiftUI `Canvas`.

**Why not SwiftUI Canvas:** Canvas renders contour paths by iterating the `EdgeResult.contours`
array on `@MainActor` — this is fast for a few dozen contours but degrades with complex
scenes. Writing the composited texture directly in C++ and rendering it as a GPU quad is
more consistent and mirrors the future multi-overlay architecture.

```swift
// File: Sources/EvaCore/Views/EdgeOverlayView.swift
import SwiftUI
import MetalKit

// MTKView that renders the EdgeDetector's shared composited texture.
struct EdgeOverlayView: UIViewRepresentable {
    let texture: MTLTexture   // Shared .shared-storage texture from EdgeDetector

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra10_xr
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> EdgeOverlayRenderer {
        EdgeOverlayRenderer(texture: texture)
    }
}

// MTKViewDelegate that blits the shared texture with a pan/zoom matrix uniform.
final class EdgeOverlayRenderer: NSObject, MTKViewDelegate {
    private let texture: MTLTexture
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    // Pan/zoom matrix updated from gesture recognizers on @MainActor
    var transformMatrix: simd_float4x4 = matrix_identity_float4x4

    init(texture: MTLTexture) {
        self.texture = texture
        let device = texture.device
        commandQueue = device.makeCommandQueue()!
        // Full-screen quad pipeline sampling `texture` with pan/zoom matrix
        // ...
        super.init()
    }

    func draw(in view: MTKView) {
        // Render fullscreen quad sampling `texture` with `transformMatrix`
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
```

Mipmap levels on the shared texture provide filtering quality when zoomed out. The
overlay resolution is 640×480 — the edge overlay shows processed edges, not the raw feed.

---

## Thread Transitions

```
AVFoundation delivery queue
  → FramePipeline (nonisolated, runs on delivery queue)
      → commandBuffer.addCompletedHandler (Metal internal thread)
          → PixelSink::publish(.tracker, frame)  [non-blocking C++ call]
              → PixelSink MPSC lane (C++ pool thread)
                  → EdgeDetector callback on PixelSink frame
                      → IOSurfaceLock / cv::Mat alias / cv::Canny / cv::findContours
                      → Composite onto shared MTLTexture
                      → IOSurfaceUnlock
                      → edgeResultCallback (C-ABI, pool thread)
                          → Task { await MLProcessor.shared.handle(result) }
                              → @MLProcessor actor
                                  → Task { @MainActor viewModel.edgeResult = result }
                                      → @MainActor CameraControlViewModel
                                          → EdgeOverlayView re-render (MTKView)
```

**Key isolation boundaries:**
- `FramePipeline` → `PixelSink::publish`: synchronous C++ call, no Swift actor hop
- `PixelSink` pool thread → EdgeDetector: C++ internal, no Swift involvement
- EdgeDetector C-ABI callback → `@MLProcessor`: pool thread → Swift global actor (via `Task`)
- `@MLProcessor` → `@MainActor`: global actor → main actor (via `Task { @MainActor ... }`)

**Nothing on the 30 Hz frame clock hops a Swift actor boundary.**

---

## `os_signpost` on EdgeDetector Processing

`os_signpost` is Apple-only, so it lives in `Interop` (Swift), not inside `ImagingCore`.
The signpost wraps the `edgeResultCallback` invocation observed from Swift:

```swift
// File: Sources/Interop/MLProcessor.swift
@globalActor
actor MLProcessor {
    static let shared = MLProcessor()
    private let log = OSLog(subsystem: "com.camplugin.imaging", category: .pointsOfInterest)

    func handle(_ result: EdgeResult) async {
        os_signpost(.begin, log: log, name: "EdgeResultToUI",
                    "framePTS: %lld", result.framePTS)
        await MainActor.run {
            // Update CameraControlViewModel.edgeResult
        }
        os_signpost(.end, log: log, name: "EdgeResultToUI")
    }
}
```

Target: `EdgeResultToUI` interval < 5ms (well within the 33ms frame budget).
`processingTimeMs` in `EdgeResult` carries the C++ processing time for Instruments
correlation.
