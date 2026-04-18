# 04 — OpenCV Integration (New iOS Capability)

OpenCV is **not ported from Android.** `domain-revised/01 §Key Invariants` #6
explicitly states: "There is no OpenCV or similar CPU-based image processing in the
current pipeline." The iOS design introduces OpenCV as a **new iOS-only capability** —
an edge-detection proof-of-concept consumer that validates the async consumer path
(ADR-13) and the zero-copy IOSurface handoff (ADR-18, ADR-20). Nothing in the core
camera pipeline depends on it; removing the consumer leaves the pipeline fully
functional.

This design is grounded in ADR-11 (direct Swift-C++ interop), ADR-12 (exception
discipline), ADR-13 (async consumers, drop-on-busy), and ADR-20/G-25 (IOSurface-backed
storage mode).

## 1. Generic `PixelSink` Interface

The C++ facade is pure POD + `enum class` + C-ABI callbacks — no OpenCV types in the
public header (ADR-11 §"keep problematic headers out of Swift's view").

```cpp
// Cpp/PixelSink.h — PUBLIC; Swift-safe, no OpenCV
#pragma once
#include <atomic>
#include <cstdint>

namespace cam {

enum class StreamId : uint8_t {
    Natural   = 0,
    Processed = 1,
    Tracker   = 2
};

enum class ErrorCode : int32_t {
    Ok               = 0,
    InternalFailure  = 1,
    OpenCVFailure    = 2,
    NotConfigured    = 3,
    ShuttingDown     = 4
};

struct FrameRef {
    // Opaque; Swift provides; C++ never constructs. Holds a retained IOSurface.
    void*   surfaceHandle;      // IOSurfaceRef (bridge-retained for callback duration)
    int32_t width;
    int32_t height;
    int32_t bytesPerRow;
    int32_t pixelFormatFourCC;  // RGBA16F fourCC ('RGhA' or similar)
    uint64_t frameNumber;
    int64_t  presentationTimeNs;
};

struct StreamStats {
    uint64_t frames_received;
    uint64_t frames_processed;
    uint64_t mailbox_overwrites;
    uint64_t errors;
};

class SWIFT_SHARED_REFERENCE(pixel_sink_retain, pixel_sink_release) PixelSink {
public:
    PixelSink() noexcept;
    virtual ~PixelSink() noexcept;

    // Required by G-26: one counter per stream subscribed.
    std::atomic<uint64_t> overwriteCount_[3] {0, 0, 0};

    virtual ErrorCode configure(int32_t width, int32_t height, int32_t fourCC) noexcept = 0;
    virtual void     processFrame(StreamId sid, const FrameRef& frame) noexcept = 0;
    virtual void     teardown() noexcept = 0;

    // Returns current stats AND atomically resets mailbox_overwrites.
    // Called at 1 Hz by the Swift stats poller (ADR-19, G-26).
    virtual StreamStats drainStats(StreamId sid) noexcept = 0;
};

extern "C" {
    void pixel_sink_retain (PixelSink*) noexcept;
    void pixel_sink_release(PixelSink*) noexcept;
}

}  // namespace cam
```

**Quality gate checklist (G-26):**
- Every `PixelSink`-derived consumer has `std::atomic<uint64_t> overwriteCount_[3]`
  (present).
- `drainStats(sid)` atomically reads-and-resets the overwrite counter (spec'd above
  via `fetch_and(0)` in implementation).
- The counter is polled at 1 Hz by Swift via C-ABI and folded into
  `FrameDeliveryStats` alongside the Swift-side per-lane counters (ADR-19).

## 2. Consumer Registration API in `CameraEngine`

```swift
extension CameraEngine {
    // Called from the engine actor; thread-safe because subscribe/unsubscribe hop
    // to sessionQueue before touching the C++ registry.
    public func attach(consumer: PixelSink, to stream: StreamId) async

    public func detach(consumer: PixelSink, from stream: StreamId) async
}
```

Implementation:

1. Engine actor holds a `ConsumerRegistry` (Swift-side map
   `[StreamId: [ObjectIdentifier: PixelSink]]`) **and** forwards to the C++
   `ConsumerRegistry` for pool dispatch.
2. On `attach`, if this is the first subscriber for `.natural` or `.processed`,
   TexturePoolManager flips that stream's `MTLTexture` from `.private` to `.shared`
   (ADR-20). Rotation takes one frame to allow the in-flight `.private` command
   buffer to drain before the next pass writes into a `.shared` replacement —
   **do not swap mid-frame** (ADR-20).
3. On `detach`, if this leaves zero subscribers for that stream, rotate back to
   `.private` over one frame boundary to recover DRAM bandwidth (ADR-20).
4. `trackerTex` is always `.shared`; attaching/detaching tracker consumers doesn't
   rotate.
5. Thread safety: the Swift side runs inside the actor (serialized). The C++ side
   takes `ConsumerRegistry::mutex_` (lock order 1 per invariant 5 — held only during
   subscribe/unsubscribe, never during `processFrame` dispatch).

## 3. Swift-C++ Interop Assessment

Per **ADR-11** / **D-03**: **direct Swift-C++ interop via
`.interoperabilityMode(.Cxx)`** with `cxxLanguageStandard: .cxx20`. **No
Objective-C++ (`.mm`).** The repo contains zero `.mm` files.

- Public `Cpp/PixelSink.h` contains only POD structs, `enum class`, C-ABI function
  pointer typedefs, and `SWIFT_SHARED_REFERENCE` reference classes (ADR-11
  contract).
- OpenCV headers (`<opencv2/core.hpp>`, `<opencv2/imgproc.hpp>`) live **only** in
  `Cpp/EdgeDetectionConsumer.cpp`. Swift never imports them (ADR-11 §"keep
  problematic headers out of Swift's view").
- pimpl in the public class: `struct Impl; Impl* impl_;` in `.h`; full definition in
  `.cpp`.

**Constrained interop scope.** `.interoperabilityMode(.Cxx)` is enabled only on the
`Cpp` SPM target and the thin `InteropFacade` Swift module that sits between it and
the app. The main app target, ViewModels, and views are pure Swift — clean Sendable
inference, no `@unchecked Sendable` leaks (ADR-13 §"Keep `.interoperabilityMode(.Cxx)`
contained").

## 4. OpenCV iOS Framework Setup — D-04

Per **D-04** (decisions log): **OpenCV distributed as a pre-built `xcframework`**
(iOS device arm64 + iOS simulator arm64/x86_64 slices). Rationale:

- **SPM (binary target with `.xcframework`)** is the winning distribution: binary
  artifact URL pinned to a specific OpenCV release (≥ 4.10.x), Swift Package Manager
  handles integration into the Xcode project, no CocoaPods Ruby dependency.
- **CocoaPods (`OpenCV` pod):** rejected — adds Ruby toolchain, CocoaPods-specific
  workspace surgery, version-lock churn from pod spec drift.
- **Building from source via CMake External Project:** rejected — a week of setup for
  arm64 + simulator slices, bitcode flags, signing entitlements; offers no benefit
  over a pinned `.xcframework` for a POC consumer.

The `.xcframework` is referenced in `Package.swift` as a `.binaryTarget(name: "opencv2",
url: ..., checksum: ...)` linked into the `Cpp` target. Swift does not depend on
`opencv2` — only `Cpp` does.

## 5. Zero-Copy Handoff Pattern

The C++ consumer receives a `FrameRef` with an IOSurface handle. Lock for CPU read,
wrap as `cv::Mat`, run Canny, unlock. No memcpy for the input:

```cpp
// Cpp/EdgeDetectionConsumer.cpp — PRIVATE implementation
#include "EdgeDetectionConsumer.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <IOSurface/IOSurface.h>
#include <CoreVideo/CVPixelBuffer.h>

ErrorCode EdgeDetectionConsumer::processFrame(StreamId sid, const FrameRef& frame) noexcept {
    if (sid != StreamId::Tracker) return ErrorCode::Ok;  // only tracker interests us
    try {
        auto surface = reinterpret_cast<IOSurfaceRef>(frame.surfaceHandle);
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
        void* base = IOSurfaceGetBaseAddress(surface);

        // RGBA16F = 4 channels × 2 bytes = 8 bpp.
        // OpenCV type CV_16FC4 (half-float 4 channel).
        cv::Mat trackerMat(frame.height, frame.width, CV_16FC4, base, frame.bytesPerRow);

        // Convert half-float to 8U gray for Canny:
        cv::Mat gray;
        cv::cvtColor(trackerMat, gray, cv::COLOR_RGBA2GRAY);     // mat writes to temp
        gray.convertTo(gray, CV_8U, 255.0);                      // half [0,1] → byte
        cv::Mat edges;
        cv::Canny(gray, edges, kCannyLow_, kCannyHigh_);

        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);

        // Composite and write (see §6) …
        writeCompositeToSharedSurface(frame, edges);
        return ErrorCode::Ok;
    } catch (const cv::Exception&)   { return ErrorCode::OpenCVFailure; }
      catch (const std::exception&)  { return ErrorCode::InternalFailure; }
      catch (...)                    { return ErrorCode::InternalFailure; }
}
```

`processFrame` is `noexcept` (ADR-12). All OpenCV calls are inside `try/catch`;
`cv::Exception` is translated to `ErrorCode::OpenCVFailure`. Uncaught exceptions
crossing into Swift would abort the process (ADR-12).

## 6. Edge Detection Consumer Design

**Input.** `FrameSet.tracker` (RGBA16F, ≈480 px tall, width preserving aspect) —
domain §02 specifies the tracker as the downsampled stream. Per G-23, Canny on full-res
(~1.9 M px) would cost 15–25 ms per frame and miss the 33 ms budget; at ~480p
(~0.3 M px) it costs 2–4 ms.

**Composite source.** Per **D-06** (decisions log): the full-res base image is
**`FrameSet.processed`**, not `FrameSet.natural`. Rationale:
- The UI's "what the user sees" contract (domain §08 still capture) is the processed
  preview. Showing Canny edges on the natural image would diverge from the user's
  mental model of the adjusted pipeline.
- The domain specifies preview = processed output (invariant 1).
- If the natural base were needed (e.g. for validating that color ops aren't
  amplifying noise that Canny then picks up), D-06 can be revisited without changing
  the architecture.

**Output.** A composited RGBA image at full resolution — edges overlaid (color-keyed
green, say) on the processed base. Written into a pre-allocated shared `MTLTexture`.

**Pre-allocated shared texture (allocated ONCE at engine setup):**

```swift
// Swift-side: SharedTextureAllocator.swift, called from MetalEngine setup
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float,
    width:  cropW,
    height: cropH,
    mipmapped: true
)
desc.storageMode = .shared
desc.usage = [.shaderRead, .renderTarget]

// Back by IOSurface-dequeued CVPixelBuffer so C++ can write via IOSurfaceLock/memcpy.
var cv: CVPixelBuffer?
CVPixelBufferPoolCreatePixelBuffer(nil, cannyCompositePool, &cv)
guard let cv,
      let surface = CVPixelBufferGetIOSurface(cv)
else { throw EngineError.cannyTextureAlloc }

let sharedCannyTex = metalDevice.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
```

**One allocation, one lifetime.** The shared canny texture + its `CVPixelBuffer`
live for the engine's lifetime. **No per-frame allocation.** The C++ consumer
rewrites the surface in place every output; mipmaps are regenerated on the Swift
side.

**Write path (C++, per frame):**

```cpp
void EdgeDetectionConsumer::writeCompositeToSharedSurface(
        const FrameRef& tracker, const cv::Mat& edges) noexcept
{
    // Obtain the shared composite IOSurface (set once at configure()).
    IOSurfaceLock(compositeSurface_, 0, nullptr);           // write mode
    void* dst  = IOSurfaceGetBaseAddress(compositeSurface_);
    size_t dstStride = IOSurfaceGetBytesPerRow(compositeSurface_);

    // Read the full-res processed frame (ARC-retained CVPixelBuffer passed via
    // FrameRef for this case — here we assume the consumer subscribes to both
    // .processed (for base) and .tracker (for Canny input) — see §2 registration).
    //
    // cv::Mat processed(fullH, fullW, CV_16FC4, processedBase, processedStride);
    // Upscale edges to fullH × fullW:
    cv::Mat edgesFull;
    cv::resize(edges, edgesFull, cv::Size(fullW, fullH), 0, 0, cv::INTER_NEAREST);

    // Composite: memcpy processed → dst, overlay edges:
    // (detail omitted; composite routine writes RGBA16F pixels where edgesFull>0
    //  and copies processed pixels elsewhere)
    compositeHalfFloat(processedBase, processedStride, edgesFull, dst, dstStride,
                       fullW, fullH);

    IOSurfaceUnlock(compositeSurface_, 0, nullptr);

    // Signal Swift via C-ABI callback:
    if (writeCompleteCb_) writeCompleteCb_(cbContext_, tracker.frameNumber);
}
```

**Swift response to write-complete callback:**

```swift
// WriteCompleteCallback.swift — C-ABI glue.
let cb: WriteCompleteCallback = { ctx, frameNumber in
    let engine = Unmanaged<CameraEngine>.fromOpaque(ctx!).takeUnretainedValue()
    Task.detached {       // NOT @MainActor — Metal blit runs off main
        await engine.mipmapBlitQueue.submit {
            engine.metalEngine.generateMipmaps(for: engine.sharedCannyTexture)
            engine.cannyViewTrigger.requestRender(frameNumber: frameNumber)
        }
    }
}
```

Metal blit (`generateMipmaps(for:)`) runs on a dedicated `mipmapBlitQueue` serial
`DispatchQueue`. The `CannyPreviewView`'s `MTKView` draws at the next vsync using the
mipmapped shared texture + pan/zoom uniforms.

**No Sendable result struct crosses the boundary for the canny pane.** C++ drives
render content by writing the shared IOSurface. This matches ADR-13 §"What never
crosses the consumer boundary" — only sendable refs (IOSurface handles via
`CVPixelBuffer`) and POD structs are exchanged.

## 7. Canny MTKView Render

Dedicated `CannyPreviewView` (UIViewRepresentable wrapping an `MTKView`) renders the
mipmapped shared texture with pan/zoom uniforms:

```metal
// Cpp/../Shaders/CannyPanZoom.metal
#include <metal_stdlib>
using namespace metal;

struct PanZoomUniforms {
    float2 originNormalized;   // top-left in [0,1]
    float2 scale;              // zoom factor (1 = fit, >1 = zoomed in)
};

fragment float4 cannyPanZoomFrag(VertexOut in [[stage_in]],
    texture2d<half, access::sample> sharedTex [[texture(0)]],
    constant PanZoomUniforms& u [[buffer(0)]])
{
    constexpr sampler s(address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 uv = u.originNormalized + in.uv / u.scale;
    return float4(sharedTex.sample(s, uv));
}
```

- `mip_filter::linear` samples the mipmap chain for quality at any zoom level
  (necessary because users can zoom out beyond 1:1).
- Pan/zoom gesture state lives in the **ViewModel (`@MainActor`)**: `@Observable
  class CanvasViewModel { var origin: CGPoint; var zoom: CGFloat }`. A
  `SwiftUI.MagnificationGesture` + `SwiftUI.DragGesture` write to the ViewModel;
  the Representable reads on `updateUIView` and passes as uniforms on each draw.
- **Render rate matches Canny throughput, NOT 30 Hz.** The `MTKView.isPaused = true`;
  `setNeedsDisplay()` called only when the write-complete callback fires. Latest-wins
  mailbox means the view always shows the most recent Canny result without blocking
  the natural preview (domain invariant 10).

## 8. Thread Model (End-to-End)

```
AVCaptureVideoDataOutput delegate queue (= deliveryQueue, serial DispatchQueue)
    │
    ├─ Pass 1–6 Metal encode + commit
    ├─ FrameSet built; mailbox swap into tracker lane's 1-slot mailbox
    │      (per-consumer; C++ side)
    │
    ▼ (atomic swap; never blocks)
C++ thread pool (std::min(4, hardware_concurrency()) threads)
    │
    ├─ consumer thread pulls FrameSet from mailbox
    ├─ processFrame(.tracker, …) runs:
    │      cv::Canny (2–4 ms on A16 at 480p)
    │      composite full-res (reads processed ref from same FrameSet)
    │      IOSurfaceLock/memcpy/Unlock into shared canny texture
    │
    ▼ (C-ABI write-complete callback)
mipmapBlitQueue (Swift-side serial DispatchQueue)
    │
    ├─ MTLBlitCommandEncoder.generateMipmaps(for: sharedCannyTexture)
    ├─ commit
    │
    ▼
CannyPreviewView.MTKView draw (next vsync; isPaused=true, setNeedsDisplay)
    │
    ├─ Render pass samples mipmapped sharedCannyTexture with pan/zoom uniforms
    └─ present(drawable:)
```

**Non-blocking property (domain invariant 10).** If the C++ thread pool is saturated
(edge detection running slow under thermal throttling), new FrameSets overwrite the
pending mailbox entry (`overwriteCount_[Tracker]++`); the publisher never waits. The
natural and processed MTKView previews continue rendering at 30 fps because their
paths (direct GPU outputs, ADR-03) do not wait on the consumer.

## 9. `os_signpost` Telemetry

Signposts around every hop in the edge consumer path (emitted via C-ABI `os_signpost`
wrappers in the `Cpp` target + Swift-side `OSSignposter` on the blit path):

| Interval | Begin | End | Emitter |
|---|---|---|---|
| `EdgeCannyCpp` | consumer callback entry | `processFrame` return | C++ (via C-ABI wrapper around `os_signpost_interval_begin/end`) |
| `CannyComplete` | `cv::Canny` return | — | C++ point event |
| `CompositeComplete` | composite fn return | — | C++ point event |
| `IOSurfaceWriteComplete` | IOSurfaceUnlock | — | C++ point event |
| `MipmapBlit` | `generateMipmaps` encode | `addCompletedHandler` | Swift |
| `CannyPresent` | `present(drawable:)` | `addPresentedHandler` | Swift |

Instruments Metal System Trace + Points of Interest show the full chain per frame;
gaps in the chain surface immediately under thermal stress (G-26 scenario).

## Cited ADRs

ADR-11 (direct Swift-C++ interop, no ObjC++), ADR-12 (`noexcept` facade + exception
translation), ADR-13 (async consumers, drop-on-busy mailbox), ADR-18 (FrameSet as
the handoff unit), ADR-19 (`overwriteCount` published via `FrameDeliveryStats`),
ADR-20 (shared storage mode when subscriber attached). G-25 (`.private` nil
`.iosurface` — motivates ADR-20), G-26 (per-stream drop counter required).
