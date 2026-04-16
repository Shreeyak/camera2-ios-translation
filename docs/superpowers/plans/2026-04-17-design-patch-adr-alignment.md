# Design Patch: ADR Alignment

> **For agentic workers:** This is a documentation-only patch (markdown edits to `design/`). No Swift code, no build. Use superpowers:executing-plans to apply edits task-by-task.

**Goal:** Align `design/` with the ADR (`reference/architecture-adr-direct-swift.md`) and 23 user feedback items from the 2026-04-17 review session.

**Architecture:** documentation patch to 8 design files + diagrams. No code.

**Tech Stack:** markdown, mermaid, d2

---

## Changes by feedback item

### Capture format (F1) — affects 03, 04, 05, 06, 09, README, diagrams

**From:** `kCVPixelFormatType_64RGBAHalf` (half-float RGBA from AVFoundation)
**To:** `kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange` (lossless hardware-compressed 8-bit YCbCr 4:2:0, full range)

- Camera delivers 8-bit YUV biplanar, IOSurface-backed
- Metal wraps as Y plane (R8Unorm) + CbCr plane (RG8Unorm) via CVMetalTextureCache
- Pass 1 compute kernel: crop + BT.709 YUV→RGB conversion → RGBA16F output
- **Working format stays RGBA16F** (D-18 rationale unchanged for color-transform precision)
- D-18 reframed: "capture format is 8-bit YUV; working format is RGBA16F"
- The `FrameData.pixels` type in C++ consumer interface changes: IOSurface-backed RGBA16F (from PipelineKit's pool, not from camera directly)

### Center crop (F2) — affects 03, 05

- Metal Pass 1: YUV→RGB conversion includes a center-crop parameterized by uniforms (cropX, cropY, cropW, cropH)
- User sets capture resolution (e.g. 4160×3120) and crop resolution (e.g. 1600×1200)
- All subsequent passes operate at crop resolution (dramatically reduces GPU workload)
- Camera format selection: user chooses resolution; default is largest native sensor format

### Recording format (F3) — affects 03, 05, 06

- HEVC 8-bit (device only supports 8-bit output)
- Encoder pool: 8-bit YUV (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`)
- Compute pass: `rgba16f_to_yuv8` downcasts half-float → 8-bit YUV on GPU
- Update D-18 to note 8-bit encoder output (not Main10)

### Still capture (F4) — affects 03, 05

- 8-bit, 3-channel TIFF via CGImageDestination
- processedTex (RGBA16F) → readback → 8-bit RGB conversion → TIFF write

### Module rename + split (F5, F21, F22, F23) — affects ALL files

**New module layout:**
```
EvaApp/                           # @main shell (was App/)
├── Sources/
│   ├── EvaCore/                  # SwiftUI, ViewModels, navigation (was AppCore)
│   ├── CaptureKit/               # AVFoundation + device only (stripped down)
│   ├── PipelineKit/              # Command buffer orchestration, pools, fanout (NEW, extracted from CaptureKit)
│   ├── EncoderKit/               # VideoRecorder, StillWriter, EXIFWriter, PhotoLibraryWriter (NEW, extracted)
│   ├── Interop/                  # Swift facade over ImagingCore; POD Sendable payloads (was ImagingBridge)
│   ├── ImagingCore/              # C++ only (unchanged name)
│   └── TestingSupport/           # (unchanged)
```

### Edge overlay (F6, F7, F14) — affects 01, 04, 05

- Do NOT adopt Metal fragment shader overlay
- C++ EdgeDetector: receives tracker frame (640×480 RGBA16F), runs Canny, **composites edges onto the tracker image in C++**
- Result written to a shared MTLTexture (.shared storage, with mipmap levels)
- Swift renders a fullscreen quad sampling this texture with a pan/zoom transform matrix
- EdgeDetector also returns an EdgeResult object with: status, contour list (for future features), framePTS, processingTime
- The contour list is for future features (ROI labels, hover, annotation export) — not for rendering

### KVO → AsyncStream (F8) — affects 02

- Adopt. Wrap AVCaptureDevice KVO observations as AsyncStream inside CaptureKit
- CameraEngine actor (now CaptureActor in CaptureKit) still emits state via its own AsyncStreams for session-level events

### Pass gating (F9) — affects 03

- No explicit gating. Implicit (if no recorder, no recording blit; if no consumer, no tracker downscale)
- Document this in 03-metal-pipeline.md

### Lanczos downscale (F10) — affects 03, 05

- MPSImageLanczosScale for tracker downscale (confirmed available on device)

### SWIFT_SHARED_REFERENCE (F11) — affects 04

- PixelSink and EdgeDetector annotated with SWIFT_SHARED_REFERENCE(retain_fn, release_fn)
- Swift imports them as ARC-managed reference types

### C++ thread pool (F12) — affects 01, 04

- ImagingCore owns a C++ thread pool (std::min(4, hw_concurrency))
- Per-stream lane with 1-slot mailbox (drop-on-busy)
- PixelSink manages the pool; consumers subscribe and run on pool threads
- ConsumerRegistry actor in Interop/ImagingBridge is removed; replaced by PixelSink's internal dispatch

### Inspector Window (F13) — no change needed (already in design)

### Thermal throttling (F15) — affects 02, 07

- Banner-only in v1. Full adaptive throttling explicitly deferred.

### backgroundSuspend() drain (F16) — no change needed (already in design)

### Startup capability check (F17) — affects 05, 07

- Check `isLockingFocusWithCustomLensPositionSupported` at startup
- Named error if unsupported

### Adaptive camera format (F18) — affects 05

- User chooses resolution via UI control
- Default: largest native sensor format (~4160×3120)

### Debug panel (F19) — affects 05

- Compile-gated to Debug + TestFlight
- Single section of app
- Phase 6 deliverable

### External display (F20) — affects 07

- No support. Remove any follow-on notes.

---

## Task list

### Task 1: Update module layout in 01-architecture.md
- Rename AppCore → EvaCore, App/ → EvaApp/
- Add PipelineKit, EncoderKit, Interop modules
- Remove ImagingBridge (replaced by Interop)
- Update layer diagram to show C++ thread pool in ImagingCore
- Update edge overlay to show C++ compositing + shared MTLTexture + pan/zoom quad
- Update sequence diagrams

### Task 2: Update 03-metal-pipeline.md
- Change capture format to Lossless_420YpCbCr8BiPlanarFullRange
- Restore Y + CbCr biplanar input textures
- Add Pass 1: crop + YUV→RGB (BT.709) → RGBA16F
- Add crop uniforms (user-defined region)
- Update recording path: rgba16f_to_yuv8 → 8-bit YUV → HEVC 8-bit
- Update still capture: 8-bit 3-channel TIFF
- Document implicit pass gating
- MPSImageLanczosScale for tracker
- Update texture spec table
- Update all code examples

### Task 3: Update 04-opencv-integration.md
- Rename modules (ImagingBridge → Interop, AppCore → EvaCore)
- Add SWIFT_SHARED_REFERENCE on PixelSink and EdgeDetector
- Replace ConsumerRegistry with C++ PixelSink thread pool + 1-slot mailbox
- Update edge overlay: C++ composites edges, writes to shared MTLTexture
- Update EdgeResult to include status + contour list
- Update ImagingCoreFacade → PixelSinkFacade / EdgeDetectorFacade in Interop
- Update thread transitions diagram

### Task 4: Update 02-concurrency.md
- Add KVO → AsyncStream adapter in CaptureKit (DeviceStateStream)
- CaptureActor (renamed from CameraEngine where it refers to AVCaptureSession ownership)
- Thermal: banner-only in v1; deferred full throttling
- Update actor topology table with new modules

### Task 5: Update 05-implementation-phases.md
- All phase file trees updated to new module layout
- Phase 0: updated for new module names
- Phase 1a: CaptureKit + CaptureActor; adaptive format selection; capability check
- Phase 2: PipelineKit with crop + YUV→RGB pass; MPSImageLanczosScale
- Phase 3: ImagingCore with PixelSink + C++ thread pool + EdgeDetector + compositing
- Phase 5: EncoderKit (HEVC 8-bit, 8-bit TIFF); Inspector Window
- Phase 6: Debug panel; TestingSupport

### Task 6: Update 06-decisions-log.md
- D-18 reframed: capture is 8-bit YUV, working is RGBA16F
- Add D-23: C++ thread pool (replaces Swift DispatchQueue per consumer)
- Add D-24: Edge compositing in C++ (mirrors future app development)
- Add D-25: Center crop in Metal Pass 1
- Add D-26: PixelSink + SWIFT_SHARED_REFERENCE architecture
- Add D-27: KVO → AsyncStream for device state

### Task 7: Update 07-ios-specific-risks.md
- Thermal: banner-only v1, full throttling deferred
- Remove external display follow-on
- Add risk: 8-bit YUV precision loss in capture → mitigated by RGBA16F working format
- Update startup capability check
- Module name updates

### Task 8: Update README.md
- Module layout summary refreshed
- Capture format updated
- Non-goals section added (no external display, no multi-cam, no audio, etc.)

### Task 9: Update diagrams (mmd + d2) + re-render
- Update pixel format labels in 03, 04, 07 diagrams
- Update module names in 01, 07 diagrams
- Re-render all Mermaid and D2 diagrams

### Task 10: Write Agent 3 regeneration note
- Separate file at `design/AGENT3-REGEN-NOTES.md`
- Lists all feedback items that should be injected into prompt-3-design.md for clean-room regeneration
- Captures the expertise injection delta (what Agent 3's prompt needs to know that it doesn't currently)

---

## Verification

```bash
# Pipeline invariants still hold
grep -rn -E 'Camera2|CameraCaptureSession|CaptureRequest|HandlerThread|SurfaceTexture' domain/
# Expect: 0

grep -rn -E 'iOS|Swift|Metal|AVCapture|CVPixelBuffer|UIKit|SwiftUI' audit/
# Expect: 0

# Design internal consistency
grep -rn 'kCVPixelFormatType_64RGBAHalf' design/
# Expect: 0 (removed everywhere; only historical references in decisions log)

grep -rn 'Lossless_420YpCbCr8BiPlanarFullRange' design/
# Expect: referenced in 03, 04, 05, README

grep -rn 'Sources/EvaCore\|Sources/PipelineKit\|Sources/EncoderKit\|Sources/Interop\|Sources/CaptureKit\|Sources/ImagingCore' design/
# Expect: non-zero, consistent

grep -rn 'AppCore\|ImagingBridge' design/
# Expect: 0 (renamed to EvaCore and Interop respectively, except historical superseded entries)
```
