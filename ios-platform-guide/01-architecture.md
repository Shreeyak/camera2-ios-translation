# 01 — Core Architecture

The minimal correct architecture for an iOS app with the shape: camera → Metal processing
→ SwiftUI preview, optionally with C++ image analysis.

**Starting point: two files. Extend only when a domain requirement demands it.**

---

## ADR-01: Two-file baseline

The whole thing fits in two files. Every additional file you introduce should map to a
genuine boundary in the domain, not to a textbook layer name.

```
Sources/
├── CameraView.swift                     ~150 lines
│   ├── struct CameraView: View              // SwiftUI root
│   ├── struct MetalCameraView:              // inline UIViewRepresentable
│   │     UIViewRepresentable
│   └── @Observable final class ViewModel    // receives Sendable results
│
└── CameraEngine.swift                   ~250 lines
    ├── actor CameraEngine                   // all state
    ├── final class CaptureDelegate:         // NSObject, runs on
    │     NSObject, AVCaptureVideo...        //   serial session queue
    └── struct DetectionResult: Sendable     // Sendable boundary type
```

### The four moving parts

1. **SwiftUI View** — overlays, buttons, labels. Owns an `@Observable` view model.
   Never sees a pixel buffer.
2. **`UIViewRepresentable` wrapping `MTKView`** — the bridge. Creates the `MTKView`,
   hands it to `CameraEngine` so the engine can draw into it. Lives in the same file
   as the SwiftUI view — it's an implementation detail, not a layer.
3. **`actor CameraEngine`** — owns everything stateful and dangerous:
   `AVCaptureSession`, `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`, the
   capture delegate. All threading rules live inside one type.
4. **`AsyncStream<T: Sendable>`** — the one-way pipe out. Engine yields Sendable
   structs. View model `for await`s them on `@MainActor`. No buffers, no Metal
   objects, no C++ types ever cross this boundary.

### What the original three-layer "sandwich" pattern gets wrong

A separate `UIKit middle layer`, a separate `@MLProcessor global actor`, and
retain/release handshakes for async C++ are pattern-theater for a problem that
collapses:

- The `UIViewRepresentable` is ~30 lines and belongs next to the view that uses it.
- There's only one isolation domain that needs to own state, so there's no reason to
  split it into two actors.
- Retain/release dances around `CVPixelBuffer` disappear when pixel buffers are
  confined to the engine.

Use the three-layer shape only if you find yourself *actually* needing the boundary
it encodes. Don't introduce it speculatively.

---

## ADR-02: Single heavy isolation domain

```
┌─────────────────────────┐         ┌────────────────────────────┐
│  @MainActor             │         │  actor CameraEngine        │
│                         │         │                            │
│  • ViewModel            │         │  • AVCaptureSession        │
│  • SwiftUI Views        │         │  • Metal objects           │
│  • Overlay state        │         │  • Texture cache           │
│                         │         │  • Capture delegate        │
│  receives:              │◄────────│    (serial session queue)  │
│  Sendable results       │  only   │                            │
│                         │  Sendable                            │
└─────────────────────────┘         └────────────────────────────┘

        UI thread                        everything heavy
    (nothing hot here)                   (one isolation domain)
```

The Sendable problem disappears because nothing non-Sendable ever tries to cross.
Full Sendable rules in `02-concurrency.md` ADR-10.

Note: the `AVCaptureSession` itself must be driven from a dedicated serial `DispatchQueue`,
not from inside the actor directly — see `ADR-07`. The engine actor *coordinates* with
that queue; it does not *replace* it.

---

## ADR-03: Direct GPU outputs vs async consumers

Not everything downstream of Metal is a "consumer." Two distinct categories with very
different timing contracts.

### Direct GPU outputs (sinks)

Metal writes to these on the frame clock. They **never** block or drop — preview
smoothness depends on them keeping up. Implemented as passes or blits inside the
per-frame command buffer.

| Sink | Mechanism |
|---|---|
| Processed preview | `MTKView` drawable (composite + overlay) |
| Natural preview | Second `MTKView` drawable (blit) |
| Video encoder | `AVAssetWriterInputPixelBufferAdaptor` + IOSurface pool (blit; gated on `isRecording`) — see ADR-06 |
| Still capture readback | CPU-readable `CVPixelBuffer` (blit; gated on `stillRequested`) |

All of these see bit-identical pixels from the same `processedTex` in the same command
buffer (before the next frame touches it).

### Async consumers

Things that **might** be slow and must not block preview. Delivered via a separate
async path with drop-on-busy semantics.

Typical consumers: C++ CV pipelines (edge detection, tracking, classification)
receiving processed full-res frames or a downscaled tracker stream.

**Rule: consumers are always async. Synchronous dispatch inside the capture delegate
is not acceptable** — if a consumer takes longer than the frame budget, AVFoundation
drops frames coarsely and the preview hitches. See ADR-13 in `05-interop.md` for the
dispatch mechanism.

---

## Per-frame command graph

One `MTLCommandBuffer` per camera frame. Passes are gated implicitly: if the feature
driving a pass is off (no recording, no tracker consumer, no still requested), that
pass is skipped. Gating is by conditional append, not by stub shaders.

```
CMSampleBuffer (8-bit biplanar YUV from capture)
   │
   ▼
CVMetalTextureCache → yTex (R8Unorm), cbcrTex (RG8Unorm)  [zero-copy; ADR-04]
   │
   ▼
[commandBuffer begin]

Pass 1  compute   crop + YUV8 → RGBA16F → naturalTex        per ADR-05
                  (BT.709 YUV-to-RGB; crop origin/size as uniforms)
Pass 2  compute   color transforms → processedTex
Pass 3  render    naturalTex   → naturalMTKView drawable
                  processedTex → processedMTKView drawable (+ overlay)
Pass 4  compute   processedTex → trackerTex (480p)          [gated: consumer subscribed]
Pass 5  compute   rgba16f → yuv8 → encoder pool buffer      [gated: recording]
Pass 6  blit      processedTex → still readback buffer      [gated: still requested]

[commit + present drawables + addCompletedHandler]
   │
   ▼
On GPU completion handler:
   publish IOSurface refs to async consumers (see ADR-13)
```

**Frame clock rule: nothing on the 30Hz frame clock hops a Swift actor boundary.**
The capture-delegate method is `nonisolated`, runs on the delivery queue, and builds
+ commits the command buffer inline. Completion-handler consumer publishing runs on
the delivery queue. UI updates are coalesced to one `Task { @MainActor in ... }` at
the end of the delegate method.

**Channel order is load-bearing.** Every texture in the consumer path
(`naturalTex`, `processedTex`, `trackerTex`) is `RGBA16F` with **R, G, B, A** channel
order. BGRA never appears in any stream a consumer touches — it only appears at the
encoder edge (Pass 5 output format). A consumer applying BT.709 luma weights must
use `(0.2126, 0.7152, 0.0722, 0.0)` in RGBA order; BGRA coefficients produce silently
wrong grayscale with no crash and no error. See G-18.

**Guarantees:**
- The pixels the async processed consumer sees are bit-identical to the pixels
  drawn to the processed preview `MTKView` — both come from the same `processedTex`
  in the same command buffer.
- Every intermediate texture is IOSurface-backed (ADR-06). The only copy in steady
  state is whatever the consumer does with the frame (e.g. `cv::cvtColor` into a
  fresh `cv::Mat`).
- Tracker stream is ~480p for a reason: Canny on full processed resolution
  (~1.9M px) costs 15–25ms per frame on A16-class hardware; on 480p
  (~0.3M px) it costs 2–4ms. The downscale is what makes per-frame CV fit the
  frame budget. Don't run CV on the full-resolution processed stream.

---

## Extending the baseline

The 2-file model is a starting point. Extensions that are **always** justified for a
real camera product:

- **Split preview:** two `MTKView` instances wrapped by two `UIViewRepresentable`s
  inside `CameraView.swift`. Still one file.
- **Multiple async consumers:** consumer registry lives inside the engine actor OR
  inside a C++ pool the engine owns. Mechanism in ADR-13.
- **Recording:** Metal blit pass + `AVAssetWriter` coordination. Stays inside the
  engine. See ADR-06, ADR-16.
- **Still capture:** Metal blit pass + CPU readback. Stays inside the engine.

Extensions that need a **domain trigger** before being taken:

- Separate `RecordingActor`: only if recording teardown needs to outlive a scene
  transition and the engine's lifetime doesn't cover it.
- Separate pipeline module: only once the per-frame graph has >4 real
  domain-driven passes and the command-buffer orchestration no longer fits in the
  engine.
- Objective-C++ layer: never. See ADR-11.
