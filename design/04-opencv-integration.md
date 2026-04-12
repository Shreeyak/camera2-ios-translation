# 04 — OpenCV Integration

This file covers the generic C++ consumer interface, OpenCV iOS framework setup,
the edge detection consumer implementation, and the full result return path.

**Note:** OpenCV edge detection is a NEW capability added for the iOS version.
It does NOT exist in the Android source — this is not a port.

---

## Generic C++ Consumer Interface

### Design Rationale

The interface is designed so that adding a new consumer (e.g., a tracker, a depth estimator) requires no changes to `CameraEngine` or `ConsumerRegistry`. Consumers register themselves and the engine calls back via the interface.

### `IFrameConsumer` — C++ Pure-Virtual Interface

```cpp
// File: Consumers/IFrameConsumer.hpp
#pragma once
#include <cstdint>

struct FrameMetadata {
    int64_t  sensorTimestampNs;
    int64_t  exposureTimeNs;
    int64_t  frameDurationNs;
    int64_t  iso;
    float    focusDistanceDiopters;
    int32_t  aeState;
    int32_t  afState;
    int32_t  awbState;
    int32_t  flashState;
};

struct FrameData {
    const uint8_t*   pixels;        // RGBA8888; valid only for duration of onFrame()
    int              width;
    int              height;
    int              bytesPerRow;   // stride; may be > width * 4
    FrameMetadata    metadata;
    uint64_t         frameIndex;    // monotonically increasing
};

// Consumer roles supported by the pipeline
enum class ConsumerRole {
    ProcessedFullResolution,  // GPU-processed full-res stream
    Tracker,                  // Downscaled 480px height stream
    // Note: Natural stream is display-only and has NO consumer registration path (U-13)
};

class IFrameConsumer {
public:
    virtual ~IFrameConsumer() = default;

    // Called once before the consumer receives frames.
    // Returns false if the consumer failed to initialize.
    virtual bool configure(ConsumerRole role, int width, int height) = 0;

    // Called for each frame. The pixel pointer in |frame| is valid ONLY for the
    // duration of this call. If the consumer needs the data beyond this call,
    // it must copy it. This method must return quickly — slow consumers drop frames.
    virtual void onFrame(const FrameData& frame) = 0;

    // Called when the consumer is being unregistered or the session is ending.
    virtual void teardown() = 0;

    // Returns a human-readable identifier for logging.
    virtual const char* name() const = 0;
};
```

### Memory Contract

- The `pixels` pointer in `FrameData` is valid **only for the duration of `onFrame()`**.
- The underlying `CVPixelBuffer` is retained (via `CVBufferRetain`) before `onFrame()` is called and released after `onFrame()` returns (via `CVBufferRelease`).
- If a consumer needs to retain pixel data beyond `onFrame()`, it must copy the data before returning.
- The `onFrame()` call is delivered to the consumer's own `DispatchQueue` (not the camera or GPU thread). Drop-on-busy: if the previous `onFrame()` has not returned by the time the next frame arrives, the new frame overwrites the pending slot.

---

## Consumer Registration — Swift Side

### `ConsumerRegistry` Actor

```swift
// File: Consumers/ConsumerRegistry.swift
import Foundation

actor ConsumerRegistry {
    private var consumers: [ConsumerRole: ConsumerEntry] = [:]

    struct ConsumerEntry {
        let bridge: ConsumerBridge  // ObjC++ wrapper around IFrameConsumer
        let queue: DispatchQueue
        var pendingFrame: FramePacket?  // 1-slot mailbox
        var isProcessing: Bool = false
    }

    // Register a consumer for a specific role.
    // Thread-safe: actor-isolated.
    func register(_ bridge: ConsumerBridge, for role: ConsumerRole) {
        let queue = DispatchQueue(
            label: "com.camplugin.consumer.\(role.rawValue)",
            qos: .userInitiated
        )
        consumers[role] = ConsumerEntry(bridge: bridge, queue: queue)
    }

    func unregister(role: ConsumerRole) {
        consumers.removeValue(forKey: role)
    }

    // Non-blocking dispatch. Drops frame if consumer is busy.
    // Called from CameraEngine.processFrame (actor-isolated).
    func dispatch(frame: FramePacket, to role: ConsumerRole) {
        guard var entry = consumers[role] else { return }

        if entry.isProcessing {
            // Consumer is busy. Overwrite the 1-slot mailbox with the newest frame.
            // The previous pendingFrame (if any) is silently dropped — this is the
            // domain "drop-on-busy" back-pressure policy. markIdle() will pick up
            // this latest pendingFrame after the current onFrame() returns.
            entry.pendingFrame = frame
            consumers[role] = entry
            return
        }

        // Consumer is idle. Dispatch immediately. Clear any stale pendingFrame
        // (there should not be one, but the invariant is preserved explicitly so
        // that markIdle() never re-dispatches a frame we are about to process).
        entry.isProcessing = true
        entry.pendingFrame = nil
        consumers[role] = entry

        entry.queue.async { [weak self] in
            entry.bridge.processFrame(frame)
            Task { await self?.markIdle(role: role) }
        }
    }

    // Called on the consumer's queue after bridge.processFrame returns.
    // Hops back to the actor to check for a pending frame.
    private func markIdle(role: ConsumerRole) {
        guard var entry = consumers[role] else { return }

        if let nextFrame = entry.pendingFrame {
            // A newer frame arrived while the previous one was being processed.
            // Clear the slot, keep isProcessing = true, dispatch the newest frame.
            entry.pendingFrame = nil
            // isProcessing stays true
            consumers[role] = entry
            entry.queue.async { [weak self] in
                entry.bridge.processFrame(nextFrame)
                Task { await self?.markIdle(role: role) }
            }
        } else {
            // No pending frame. Mark consumer idle.
            entry.isProcessing = false
            consumers[role] = entry
        }
    }
}
```

---

## Swift-C++ Interop Assessment for OpenCV

### Assessment

Swift's direct C++ interop (Swift 5.9+, Clang module importer) works well with simple C++ headers:
- Plain types, structs, non-template classes: **compatible**
- `std::vector`, `std::string` with explicit `Sendable` bridging: **compatible with effort**
- OpenCV's `cv::Mat`, `cv::Size`, core headers: **NOT directly compatible**

**Why OpenCV headers are incompatible with direct Swift-C++ interop:**
- OpenCV extensively uses C++ templates (`cv::Mat_<T>`, `InputArray`, `OutputArray`)
- OpenCV uses C++ exceptions — Swift cannot propagate C++ exceptions
- OpenCV headers include complex macro chains (`CV_EXPORTS`, `CV_OVERRIDE`) that confuse the Clang module importer
- `cv::Mat`'s reference-counting model (`UMatData`) is incompatible with Swift's `Sendable` requirements

**Conclusion:** A two-layer bridge architecture is required:
1. **Direct Swift-C++ interop:** Used for the generic `IFrameConsumer` interface and `FrameData`/`ConsumerRole` types — these are simple C++ constructs that Swift can bridge directly
2. **ObjC++ bridge (.mm files):** Used for all OpenCV-specific code — the ObjC++ layer imports OpenCV headers and wraps the results in Objective-C types that Swift can call

This is documented as design decision D-04 in `design/06-decisions-log.md`.

---

## OpenCV iOS Framework Setup

### Chosen Distribution: xcframework (pre-built)

**Chosen:** xcframework from OpenCV's official release (opencv2.xcframework)

**Alternatives considered:**
- **CocoaPods:** `pod 'OpenCV'` — easiest setup; creates large dependency; 2026 CocoaPods deprecation trajectory is a risk; adds build-time dependency
- **SPM:** OpenCV does not have an official SPM package as of 2026; third-party wrappers exist but introduce maintenance risk
- **Build from source:** Maximum control, smallest footprint, but requires maintaining a complex CMake build configuration for multiple architectures

**Chosen because:** xcframework provides:
- Official, pre-built, Apple-signed framework from opencv.org
- Supports arm64 (device) and x86_64/arm64 (simulator) in a single bundle
- No Xcode cloud/SPM dependency
- Straightforward "drag into Xcode" integration
- Clear version pinning via filename and hash verification

**Integration steps:**
1. Download `opencv-4.x.y-ios-framework.zip` from opencv.org releases
2. Unzip to `Frameworks/opencv2.xcframework`
3. Add to "Frameworks, Libraries, and Embedded Content" in Xcode target settings
4. Set "Embed & Sign" for device builds
5. In `EdgeDetectionBridge.mm`, add `#import <opencv2/opencv.hpp>`

**Note:** OpenCV iOS xcframework includes arm64 (device), arm64 simulator, and x86_64 simulator slices. No special build flags required for Swift Package Manager or Xcode 26.

---

## Zero-Copy Frame Handoff Pattern

The `CVPixelBuffer` arriving from Metal readback contains RGBA8888 data. The handoff to OpenCV uses `CVPixelBufferLockBaseAddress` to get the CPU pointer without copying:

```objc
// File: EdgeDetectionBridge.mm

- (void)processFrame:(FramePacket *)packet {
    CVPixelBufferRef buffer = packet.pixelBuffer;
    
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    
    void *baseAddress = CVPixelBufferGetBaseAddress(buffer);
    int width  = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    int bytesPerRow = (int)CVPixelBufferGetBytesPerRow(buffer);
    
    // Wrap in cv::Mat — no copy; pixels are the same memory.
    // The buffer is BGRA8Unorm (Metal's native pixel format on iOS). Channel order
    // in memory is B, G, R, A. Do NOT use COLOR_RGBA2GRAY — the luminance weights
    // applied to R and B are asymmetric (0.299 vs 0.114) and swapping them produces
    // silently-wrong grayscale on every frame. No crash, no error — just wrong edges.
    cv::Mat bgra(height, width, CV_8UC4, baseAddress, bytesPerRow);

    // Convert BGRA → grayscale for Canny
    cv::Mat gray;
    cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);
    
    // Run Canny edge detection
    cv::Mat edges;
    cv::Canny(gray, edges, _lowThreshold, _highThreshold);
    
    // Extract contours for Sendable result
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    
    // Convert result to Swift-friendly type and dispatch to @MLProcessor
    [self deliverResult:contours frameIndex:packet.frameIndex processingStart:packet.captureTimestamp];
}
```

---

## Edge Detection Consumer Implementation

### Role Selection: `Tracker` (480px), NOT `ProcessedFullResolution`

The `EdgeDetectionConsumer` registers for `ConsumerRole::Tracker` (the downscaled 480px-height stream), not `ConsumerRole::ProcessedFullResolution`. This is load-bearing for the 16ms frame budget:

| Role | Resolution | Pixels/frame | Canny CPU cost (est.) | Fits 16ms budget? |
|---|---|---|---|---|
| ProcessedFullResolution | ~4000×3000 | ~12M | 80–120 ms/frame on A17 | **No** (5–7× over budget) |
| Tracker | 640×480 (aspect-rounded) | ~0.3M | 2–4 ms/frame on A17 | **Yes** (with headroom) |

Canny edge detection is `O(pixels)` dominated by the Gaussian blur and Sobel gradient passes. At full sensor resolution (~12M pixels) it is prohibitively expensive to run per-frame on the CPU, even with OpenCV's SIMD optimizations. The tracker-resolution stream is specifically designed for per-frame ML / CV consumers — 480px height is a fixed compile-time value (see `domain/12-unresolved.md §U-15 RESOLVED`) precisely because this is the intended downsampling target for consumers.

The edge overlay is drawn on the preview in SwiftUI `Canvas` at display resolution, so the visual fidelity loss from detecting at 480px and rendering the resulting contours at ~3000px is negligible — edges are scaled up as `Path` strokes, not as bitmap edges.

**Registration contract:** `EdgeDetectionConsumer::configure()` asserts that `role == ConsumerRole::Tracker` and returns `false` for any other role. The Swift-side registration call passes `.tracker` explicitly:

```swift
// In CameraEngine setup:
let edgeBridge = EdgeDetectionBridge(lowThreshold: 50, highThreshold: 150)
await consumerRegistry.register(edgeBridge, for: .tracker)
```

Registering the edge consumer for `.processedFullResolution` is an implementation error and must trigger an assertion failure in DEBUG builds.

### `EdgeDetectionConsumer` — C++ Class

```cpp
// File: Consumers/EdgeDetectionConsumer.hpp
#pragma once
#include "IFrameConsumer.hpp"
#include <cassert>

class EdgeDetectionConsumer final : public IFrameConsumer {
public:
    EdgeDetectionConsumer();
    ~EdgeDetectionConsumer() override = default;

    // Accepts ONLY ConsumerRole::Tracker. Returns false for any other role.
    bool configure(ConsumerRole role, int width, int height) override {
        if (role != ConsumerRole::Tracker) {
            // Canny on ProcessedFullResolution (~12M pixels) exceeds the 16ms frame
            // budget by 5–7×. The tracker role (480px height) is the only supported
            // input for this consumer.
            assert(false && "EdgeDetectionConsumer only supports ConsumerRole::Tracker");
            return false;
        }
        _width  = width;
        _height = height;  // Expected: 480; width derived from aspect ratio
        return true;
    }

    void onFrame(const FrameData& frame) override;
    void teardown() override;
    const char* name() const override { return "EdgeDetectionConsumer"; }

    // Canny thresholds — settable from Swift via ObjC++ bridge
    void setThresholds(double low, double high);

private:
    double _lowThreshold  = 50.0;
    double _highThreshold = 150.0;
    int _width  = 0;
    int _height = 0;   // Always 480 (per U-15 RESOLVED)
    // Result callback — called on consumer's thread
    std::function<void(/* edge result */)> _resultCallback;
};
```

### Result Type Choice: Edge Contour List (not binary mask)

**Chosen: `[EdgeContour]` — array of contour point arrays**

**Alternatives considered:**
- **Binary edge mask (pixel buffer):** A 1-bit or 8-bit mask at full resolution. Pros: dense, easy to overlay. Cons: 49.5 MB at full resolution is expensive to transfer across the Swift-C++ boundary; requires a SwiftUI `Canvas` or Metal overlay to render.
- **Edge contour list:** `cv::findContours` produces compact vector of point arrays. Pros: small (`O(edges)` not `O(pixels)`); `Sendable` struct of `[SIMD2<Int32>]` arrays; easy to render in SwiftUI `Canvas` with `Path`. Cons: loses interior edge information; requires `cv::findContours` in addition to `cv::Canny`.

**Chosen because:** Contour list is small, `Sendable`, and renders efficiently in SwiftUI. The binary mask would require either a separate `MTLTexture` (adds complexity) or an RGBA `CVPixelBuffer` transfer (expensive). For the proof-of-concept purpose of this consumer (validate the full integration path), contours are sufficient.

This decision is logged in `design/06-decisions-log.md` entry D-06.

---

## Edge Detection Result — Sendable Swift Struct

```swift
// File: Consumers/EdgeDetectionResult.swift

struct EdgePoint: Sendable {
    let x: Int32
    let y: Int32
}

struct EdgeContour: Sendable {
    let points: [EdgePoint]
}

struct EdgeDetectionResult: Sendable {
    let frameIndex: UInt64
    let contours: [EdgeContour]
    let processingTimeMs: Double
    let frameTimestampNs: Int64  // sensor timestamp for frame alignment
}
```

---

## ObjC++ Bridge

```objc
// File: Consumers/EdgeDetectionBridge.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FramePacket : NSObject
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) uint64_t frameIndex;
@property (nonatomic, assign) int64_t captureTimestamp;
@end

typedef void (^EdgeResultCallback)(NSArray<NSArray<NSValue *> *> *contours,
                                   uint64_t frameIndex,
                                   double processingTimeMs);

@interface EdgeDetectionBridge : NSObject
- (instancetype)initWithResultCallback:(EdgeResultCallback)callback;
- (void)processFrame:(FramePacket *)packet;
- (void)setLowThreshold:(double)low highThreshold:(double)high;
@end

NS_ASSUME_NONNULL_END
```

---

## Thread Transitions

```
AVFoundation capture queue
  → CameraEngine actor (await processFrame)
      → Metal compute (synchronous in actor)
      → commandBuffer.completedHandler (Metal internal thread)
          → Task { await engine.onFrameReadbackComplete }
              → CameraEngine actor (dispatch to ConsumerRegistry)
                  → ConsumerRegistry actor (non-blocking yield)
                      → Consumer DispatchQueue (own thread)
                          → EdgeDetectionBridge.processFrame (ObjC++)
                              → cv::Canny (on consumer thread)
                                  → EdgeResultCallback
                                      → Task { await MLProcessor.shared.handle(result) }
                                          → @MLProcessor actor
                                              → Task { @MainActor viewModel.edgeResult = result }
                                                  → @MainActor CameraViewModel
                                                      → SwiftUI re-render (EdgeDetectionOverlay)
```

**Key isolation boundaries:**
- `CameraEngine` → `ConsumerRegistry`: actor-to-actor (async call)
- `ConsumerRegistry` → consumer queue: actor → `DispatchQueue` (non-blocking)
- Consumer thread → `@MLProcessor`: raw thread → Swift global actor (via `Task { await ... }`)
- `@MLProcessor` → `@MainActor`: global actor → main actor (via `Task { @MainActor ... }`)

---

## SwiftUI Overlay for Edge Detection Results

```swift
// File: UI/EdgeDetectionOverlay.swift

struct EdgeDetectionOverlay: View {
    let result: EdgeDetectionResult?
    let frameSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let result else { return }
            let scaleX = size.width / frameSize.width
            let scaleY = size.height / frameSize.height

            for contour in result.contours {
                guard contour.points.count >= 2 else { continue }
                var path = Path()
                let first = contour.points[0]
                path.move(to: CGPoint(
                    x: CGFloat(first.x) * scaleX,
                    y: CGFloat(first.y) * scaleY
                ))
                for point in contour.points.dropFirst() {
                    path.addLine(to: CGPoint(
                        x: CGFloat(point.x) * scaleX,
                        y: CGFloat(point.y) * scaleY
                    ))
                }
                context.stroke(path, with: .color(.green), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)  // Overlay is non-interactive
    }
}
```

---

## `os_signpost` on Return Path

```swift
// MLProcessor.swift
@globalActor
actor MLProcessor {
    static let shared = MLProcessor()
    private let log = OSLog(subsystem: "com.camplugin.ml", category: .pointsOfInterest)

    func handle(_ result: EdgeDetectionResult) async {
        os_signpost(.begin, log: log, name: "EdgeResultToUI",
                    "frameIndex: %llu", result.frameIndex)
        await MainActor.run {
            // Update CameraViewModel.edgeResult
        }
        os_signpost(.end, log: log, name: "EdgeResultToUI")
    }
}
```

Instruments will show the `EdgeResultToUI` interval spanning from C++ result delivery to `@MainActor` update completion. Target: < 5ms (well within the 33ms frame budget).

---

## `os_signpost` on Consumer Processing

```objc
// EdgeDetectionBridge.mm
#include <os/signpost.h>

- (void)processFrame:(FramePacket *)packet {
    os_signpost_id_t signpostID = os_signpost_id_generate(self.log);
    os_signpost_interval_begin(self.log, signpostID, "EdgeDetection",
                               "frameIndex: %llu", packet.frameIndex);
    
    // ... cv::Canny ...
    
    os_signpost_interval_end(self.log, signpostID, "EdgeDetection");
}
```

Target processing time: < 16ms per frame (to allow frame-rate-paced processing at 30fps on fast consumer; slow consumer drops frames gracefully via 1-slot mailbox).
