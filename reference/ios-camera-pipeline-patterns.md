# iOS Camera Pipeline Architecture Patterns

Reference material for the iOS Translation Architect. These patterns inform the Sandwich architecture used in Prompt 2.

## The Sandwich Architecture

For high-performance camera systems with C++ backends:

**Top Layer (SwiftUI)** — Brain & Skin
- UI overlays, buttons, camera control panels
- Communicates via ViewModel that observes state
- Never touches camera buffers or Metal textures

**Middle Layer (UIKit Wrapper)** — Bridge
- UIViewRepresentable hosting custom MTKView
- Bridges declarative SwiftUI to imperative Metal pipeline

**Bottom Layer (ObjC++ & Metal)** — Engine
- CameraEngine class owns AVCaptureSession and Metal device
- AVCaptureVideoDataOutput delegates live here
- Manages MTLCommandQueue and memory handoff to C++ ML/CV layer

## Zero-Copy Frame Pipeline

1. **Capture**: AVFoundation delivers CMSampleBuffer containing CVPixelBuffer
2. **Metal Texture Mapping**: `CVMetalTextureCacheCreateTextureFromImage` creates a Metal texture pointing directly to existing camera memory — no CPU copy
3. **GPU Processing**: Metal compute/render shaders process the texture
4. **C++ Handoff**: Pass CVPixelBuffer or MTLTexture pointer to ObjC++ layer — zero-copy

## Critical: Do Not Use AVCaptureVideoPreviewLayer

Since frames go through GPU processing, the preview must show the Metal pipeline OUTPUT. Draw to MTKView instead of using the standard preview layer.

## Three-Thread Model

- **Main Thread**: SwiftUI UI updates only
- **Camera Thread**: AVCaptureSession delegate callbacks
- **Compute Thread**: Metal work and C++ ML processing

## Back-Pressure: Drop, Don't Queue

If ML/CV layer is still processing when a new frame arrives, drop the new frame immediately. Queuing causes memory exhaustion and latency spikes.

## Memory Retention for Async C++ Processing

If C++ processes asynchronously, explicitly retain the CVPixelBuffer:
- `CVBufferRetain` / `CVBufferRelease` (or `CFRetain` / `CFRelease`)
- Prevents camera from recycling the buffer before C++ finishes

## Results Return Path

ML/CV results flow back: C++ → ObjC++ → ViewModel → SwiftUI overlay
- Results originate on compute thread, UI updates on MainActor
- Consider throttling to avoid UI churn
