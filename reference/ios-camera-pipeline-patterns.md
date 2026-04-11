# iOS Camera Pipeline Architecture Patterns

Reference material for the iOS Translation Architect. These patterns inform the architecture used in Prompt 2.

## The Sandwich Architecture

For high-performance camera systems with C++ backends:

**Top Layer (SwiftUI)** — Brain & Skin
- UI overlays, buttons, camera control panels
- Observes state via @Observable ViewModel
- Never touches camera buffers or Metal textures

**Middle Layer (UIKit Wrapper)** — Bridge
- UIViewRepresentable hosting custom MTKView
- Bridges declarative SwiftUI to imperative Metal pipeline

**Bottom Layer (Engine)** — Swift Actor + C++ interop
- CameraEngine manages AVCaptureSession and Metal device
- AVCaptureVideoDataOutput delegate lives here
- C++ integration via direct Swift-C++ interop (Swift 5.9+) or ObjC++ bridge
- Manages MTLCommandQueue and memory handoff to C++ ML/CV layer

## Swift 6 Concurrency Model (Compile-Time Data Isolation)

Instead of managing threads manually, use Swift 6's actor isolation:

| Component | Isolation | Why |
|-----------|-----------|-----|
| UI/Overlays | @MainActor | Never parse ML results here. Receive only simple view states. |
| Camera Producer | Dedicated serial DispatchQueue | AVCaptureVideoDataOutput requires a serial queue. Hand off to actors immediately. |
| ML/CV Engine | Custom @globalActor (@MLProcessor) | Walls off C++ ML logic. Compiler enforces isolation. |
| Metal Renderer | nonisolated methods | MTKViewDelegate must not be actor-isolated — system calls draw() on its own schedule. |

**Key**: The compiler enforces isolation boundaries at compile time. This replaces runtime queue discipline and eliminates "mystery crashes" from concurrent buffer access.

## Zero-Copy Frame Pipeline

1. **Capture**: AVFoundation delivers CMSampleBuffer containing CVPixelBuffer
2. **Metal Texture Mapping**: `CVMetalTextureCacheCreateTextureFromImage` creates a Metal texture pointing to existing camera memory — no CPU copy. Create the cache ONCE, reuse per-frame.
3. **GPU Processing**: Metal compute/render shaders
4. **C++ Handoff**: Pass CVPixelBuffer pointer to C++ layer — zero-copy. Use CVPixelBufferGetBaseAddress for raw pointer access in C++.

## Back-Pressure: AsyncStream with .bufferingNewest(1)

```swift
let (stream, continuation) = AsyncStream.makeStream(
    of: CVPixelBuffer.self,
    bufferingPolicy: .bufferingNewest(1)
)
```

If camera produces 60fps but ML handles 30fps, the stream automatically keeps only the latest frame and drops older ones. Memory stays flat, latency stays low. No manual drop logic needed.

## Memory Retention for Async C++ Processing

If C++ processes asynchronously:
1. `CVPixelBufferRetain()` before handoff to C++
2. C++ processes the frame
3. C++ executes a callback to Swift when done
4. Swift calls `CVPixelBufferRelease()`

Without this, the camera recycles the buffer mid-processing. If the camera runs out of available buffers in the pool, it stops delivering frames entirely.

## Critical: Do Not Use AVCaptureVideoPreviewLayer

Since frames go through GPU processing, the preview must show Metal pipeline OUTPUT. Draw to MTKView instead.

## Swift-C++ Direct Interop (Swift 5.9+)

Swift can import C++ headers directly via Clang modules — no ObjC++ needed for most APIs.

**Supported**: functions, member functions, classes, structs, enums, templates (instantiated), std::vector/string/optional
**Not supported**: C++20 modules, some complex template patterns, exceptions

Prefer direct interop. Fall back to ObjC++ only if the C++ code uses unsupported features.

## Available Frameworks (iOS 26+, verified)

| Framework | Status | Relevance |
|-----------|--------|-----------|
| Metal 4 | WWDC 2025 | Improved command encoding, ML+graphics integration |
| MetalFX | Active | Temporal upscaling, frame interpolation, denoising |
| MPS (Metal Performance Shaders) | Active | Optimized compute kernels |
| Swift-C++ interop | Stable (Swift 5.9+) | Direct C++ calls without ObjC++ bridge |

**NOTE**: VTFrameProcessor does NOT exist — it is a fabricated API. Use Metal compute shaders for color/resize transforms.

## Results Return Path

ML/CV results flow back: C++ → Swift actor → ViewModel → SwiftUI overlay
- Results originate on @MLProcessor actor
- ViewModel receives results and publishes to @MainActor
- SwiftUI views observe ViewModel and update overlays
- Consider throttling to avoid UI churn (e.g., cap at 30 updates/sec)

## iOS-Specific Concerns (Not Present on Android)

- **Thermal throttling**: Monitor `ProcessInfo.processInfo.thermalState`. At `.serious`, degrade resolution/frame rate.
- **System pressure**: Monitor `AVCaptureDevice.SystemPressureState`. Reduce capture quality under pressure.
- **Multi-app camera**: Another app can take the camera. Handle `AVCaptureSession.wasInterruptedNotification`.
- **Permissions**: NSCameraUsageDescription required. Handle denial gracefully.
- **App Nap**: Background execution limits affect camera session lifecycle.
