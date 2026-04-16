# Porting a Camera-Heavy Android App to iOS/SwiftUI — Deep Research Report

**Project:** eva-app (Whole Slide Imaging, iPad)
**Date:** 2026-04-16
**Scope:** Port an existing Android app — Camera2 + OpenGL ES shaders + OpenCV (C++ native) + C++ data sinks + multi-stream GPU preview — to native iOS using SwiftUI. No cross-platform frameworks (React Native, Flutter, KMP-Compose-Multiplatform) are in scope.

---

## 1. TL;DR — the shape of the port

Your Android app is not a "UI app." It is a real-time imaging pipeline with a thin UI on top. That changes everything about how to approach the port.

A naive Android→iOS port assumes UI is the hard part. For your app, the UI is the easy part. The hard part is re-expressing a tightly integrated camera + GPU + C++ pipeline in Apple's equivalents, where:

- **Camera2** becomes **AVFoundation** (`AVCaptureSession` / `AVCaptureMultiCamSession`). Similar conceptual model, different ergonomics.
- **OpenGL ES** is deprecated on iOS. You must rewrite shaders in **Metal Shading Language (MSL)** and target **Metal** (Metal 3 baseline, Metal 4 where it helps). There is no "keep using OpenGL ES" option that is future-proof.
- **OpenCV C++** runs fine on iOS — Apple ships a prebuilt OpenCV framework pattern, and you can keep your `.cpp/.hpp` sources as-is. The work is in **how Swift calls that C++**.
- **Your C++ "sinks"** (multi-consumer data distribution) can be reused nearly verbatim. The novelty on iOS is how you *feed* the sinks (`CMSampleBuffer` → `CVPixelBuffer` → `IOSurface` → `MTLTexture`, zero-copy) and how multiple SwiftUI views *consume* the output.
- **SwiftUI** maps cleanly onto Jetpack Compose concepts but does not have a camera/Metal story out of the box. You bridge UIKit (`UIViewRepresentable`) for the preview surfaces and SwiftUI for everything else.

The best mental model: **you are porting a C++/GPU app that happens to have an Android UI, to a C++/GPU app that happens to have a SwiftUI UI.** Treat the C++ core as the *crown jewel* — don't rewrite it; bridge it.

Estimated effort breakdown for an app with your characteristics (very rough):

| Area | % of total effort |
|---|---|
| Camera pipeline (Camera2 → AVFoundation) | 20–25% |
| GPU shader port (GLSL → MSL) + Metal plumbing | 25–30% |
| C++/OpenCV reuse + Swift interop layer | 10–15% |
| Multi-stream preview architecture | 10–15% |
| SwiftUI views, navigation, state | 10–15% |
| Build system, packaging, TestFlight, QA | 10–15% |

---

## 2. Architecture mapping at a glance

| Android concept | iOS equivalent | Notes |
|---|---|---|
| Kotlin | Swift 5.9+ | Close semantic match; Swift has property wrappers, structured concurrency |
| Jetpack Compose | SwiftUI | Both declarative; state models differ (see §4) |
| Activity / Fragment | `UIViewController` / SwiftUI `App`+`Scene` | SwiftUI's `App` protocol is the entry point |
| ViewModel (AAC) | `ObservableObject` / `@Observable` / `@StateObject` | Swift's `@Observable` macro (iOS 17+) is the modern pattern |
| Kotlin `Flow` / `StateFlow` | `AsyncSequence` / `@Published` Combine / `AsyncStream` | Combine is stable but being de-emphasized in favor of async/await |
| `LaunchedEffect` | `.task { }` or `.onAppear { }` on a SwiftUI view | `.task` is lifecycle-aware and cancels automatically |
| Camera2 API | AVFoundation (`AVCaptureSession`, `AVCaptureMultiCamSession`) | MultiCam session enables simultaneous front+back+telephoto etc. |
| `Surface` / `SurfaceTexture` | `CVPixelBuffer` + `IOSurface` + `MTLTexture` | IOSurface is the zero-copy backing store |
| `GLSurfaceView` / custom OpenGL view | `MTKView` (`MetalKit`) or custom `CAMetalLayer`-backed `UIView` | Both exposed to SwiftUI via `UIViewRepresentable` |
| GLSL ES shaders | Metal Shading Language (MSL, C++14-based) | Syntactic conversion mostly mechanical; semantics overlap ~85% |
| EGL / context sharing | `MTLDevice` is process-wide; no EGL contexts needed | Huge simplification |
| NDK / JNI / C++ | Clang C++ compiled directly; no bridge language needed | Swift 5.9+ has direct C++ interop; Objective-C++ (`.mm`) is the classic path |
| OpenCV (Android NDK) | OpenCV built as xcframework | Same `.cpp` sources; different build |
| Gradle | Xcode project / Swift Package Manager / CocoaPods | SPM is first-class in 2026 |
| AndroidManifest permissions | `Info.plist` keys + runtime request via `AVCaptureDevice.requestAccess(for:)` | `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` |
| ProGuard/R8 | N/A (LLVM compiled) | Shipping binaries are already stripped |
| Espresso / UI tests | XCUITest | Similar model, different API |
| Play Store | App Store (+ TestFlight for beta) | Review policies differ; medical apps need extra care |

---

## 3. Project setup and tooling

### 3.1 Xcode project layout

For an app with a substantial C++ core, the pragmatic layout is:

```
eva-ios/
├── eva-ios.xcodeproj/               (or Package.swift if going full SPM)
├── EvaApp/                          # Swift app target
│   ├── EvaApp.swift                 # @main App
│   ├── Views/                       # SwiftUI views
│   ├── ViewModels/
│   ├── Camera/                      # AVFoundation wrappers
│   ├── Rendering/                   # MTKView hosts, shader pipeline
│   ├── Interop/                     # Swift<->C++ bridge
│   └── Resources/                   # .metal shader sources, .xcassets
├── EvaCore/                         # Static lib / xcframework target
│   ├── include/                     # Public C++ headers (umbrella)
│   ├── src/                         # C++ sources (shared with Android)
│   ├── opencv/                      # Vendored OpenCV xcframework or SPM ref
│   └── EvaCore.modulemap            # Clang module map for Swift import
├── EvaShaders/                      # .metal files (or keep under EvaApp/)
├── EvaAppTests/
└── EvaAppUITests/
```

Keep the `C++ core` in a framework target (not directly in the app target). This:

- enforces a clean header boundary,
- lets you reuse the exact same `.cpp` files with the Android build (same source of truth),
- keeps Swift build times reasonable (C++ compile is slow when mixed into every Swift build).

### 3.2 Tooling baseline (2026)

- **Xcode 16+** (required for Metal 4, modern Swift C++ interop, iOS 18 SDK baseline)
- **Swift 6.x** with C++ interop enabled (`SWIFT_OBJC_INTEROP_MODE` + `-cxx-interoperability-mode=default`)
- **iOS deployment target**: 17.0 is a sane floor for 2026 (Metal 3 baseline, `@Observable` macro, improved AVFoundation APIs). 16.0 if you need broader iPad reach. Avoid <15.
- **Swift Package Manager** as primary dependency manager. CocoaPods is in long-tail maintenance mode; avoid new projects on it.
- **Git LFS** if you vendor large OpenCV xcframeworks or sample slide images.

### 3.3 Deployment target decision

For a medical/iPad WSI app you likely want:

- **iPad Pro M-series** as the primary target (best GPU, USB-C external displays, maximum RAM).
- **iOS 17 minimum** gives you `@Observable`, improved `AVCaptureSession` reconfiguration, Metal 3 compute shaders, and `AsyncStream` maturity.
- **No simulator for camera**: the iOS Simulator has no camera or Metal-class GPU. Budget for on-device dev from day 1. Plan to hardware-gate features that require MultiCam or specific cameras.

---

## 4. UI layer: Jetpack Compose → SwiftUI

The declarative model is the same; the state primitives differ. Map your Compose code like this:

| Compose | SwiftUI |
|---|---|
| `@Composable fun Foo()` | `struct FooView: View { var body: some View { … } }` |
| `remember { mutableStateOf(x) }` | `@State private var x = …` |
| `ViewModel` + `StateFlow.collectAsState()` | `@Observable` class + `@State var vm = VM()` |
| `LaunchedEffect(key) { … }` | `.task(id: key) { … }` |
| `DisposableEffect` | `.onAppear`/`.onDisappear` or `.task`'s cancellation |
| `Modifier.padding(8.dp)` | `.padding(8)` |
| `Column { … }` / `Row { … }` | `VStack { … }` / `HStack { … }` |
| `Box` | `ZStack` |
| `LazyColumn` | `List` or `LazyVStack` (in `ScrollView`) |
| `CompositionLocalProvider` | `Environment` + `@Environment` property wrapper |
| `NavHost` / `composable("route")` | `NavigationStack` + `navigationDestination(for:)` (iOS 16+) |
| `CoroutineScope.launch { }` | `Task { }` (structured concurrency) |
| `remember { } saveable` | `@SceneStorage` / `@AppStorage` |

**Recommended state-management pattern for 2026:** use the new `@Observable` macro (iOS 17+) instead of `ObservableObject` + `@Published`. It eliminates the boilerplate, plays well with `@State var vm = VM()`, and tracks property reads at the view level (more Compose-like performance characteristics).

```swift
@Observable
final class CameraViewModel {
    var isRunning = false
    var currentFrameTimestamp: CMTime = .zero
    // …
}

struct CameraScreen: View {
    @State private var vm = CameraViewModel()
    var body: some View {
        CameraPreview(vm: vm)
            .task { await vm.start() }
    }
}
```

**Important gotcha:** SwiftUI is *not* a drop-in UI framework for anything that needs a raw drawing surface. Camera preview and Metal rendering require UIKit escape hatches. This is covered in §6 and §7.

---

## 5. Camera: Camera2 → AVFoundation

### 5.1 Conceptual mapping

| Camera2 | AVFoundation |
|---|---|
| `CameraManager` | `AVCaptureDevice.DiscoverySession` |
| `CameraDevice` | `AVCaptureDevice` |
| `CameraCaptureSession` | `AVCaptureSession` or `AVCaptureMultiCamSession` |
| `CaptureRequest.Builder` | Per-output config + `AVCaptureSession.Preset` or manual `activeFormat` |
| `Surface` (preview / encoder / ImageReader) | `AVCaptureVideoDataOutput`, `AVCapturePhotoOutput`, `AVCaptureMovieFileOutput`, `AVCaptureVideoPreviewLayer` |
| Repeating request | `startRunning()` (session is inherently repeating) |
| Template (PREVIEW/RECORD/STILL) | Session preset + per-output configuration |
| `CaptureResult` (metadata per frame) | Delegate callback `didOutput sampleBuffer:` — metadata is attached to `CMSampleBuffer` attachments |
| 3A controls (AE/AF/AWB) | `AVCaptureDevice` lock + `focusMode`, `exposureMode`, `whiteBalanceMode`; advanced: `setFocusModeLocked(lensPosition:)`, `setExposureModeCustom(duration:iso:)` |
| YUV_420_888 `ImageReader` | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` on `AVCaptureVideoDataOutput` |
| RAW | `AVCapturePhotoOutput` with `rawPhotoPixelFormatType` (Bayer RAW, DNG) |

### 5.2 The session model (crucial for multi-stream apps)

Camera2 lets you attach multiple `Surface`s to a single `CameraCaptureSession` and have the camera fan out frames to all of them. iOS does the same thing, but via distinct *outputs* on one session:

- `AVCaptureVideoPreviewLayer` — a `CALayer` subclass that renders directly (your "preview straight to display" path).
- `AVCaptureVideoDataOutput` — delivers `CMSampleBuffer` to your delegate; this is your "consumer sink" path (feed OpenCV, feed Metal for custom shading).
- `AVCapturePhotoOutput` — still capture.
- `AVCaptureMovieFileOutput` — H.264/HEVC file recording.
- `AVCaptureAudioDataOutput` — audio samples.

**One session, many outputs** is the equivalent of one `CameraCaptureSession` with many `Surface`s. You do not need multiple sessions for multiple consumers.

### 5.3 Multi-cam (simultaneous front + back + telephoto)

If your Android app uses logical/multi-camera features, the iOS equivalent is `AVCaptureMultiCamSession` (iOS 13+, hardware-gated to iPhone XS/XR and iPad Pro onward). It supports simultaneous capture from multiple inputs of the same media type — separate video data outputs, separate preview layers, separate photo outputs, separate metadata outputs all from different cameras concurrently ([Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession)).

Check `AVCaptureMultiCamSession.isMultiCamSupported` before trying it on an older iPad. Budget per-format trade-offs: MultiCam caps per-stream resolution/FPS based on hardware envelope — you cannot ask two cameras for 4K60 each.

### 5.4 The custom-preview-via-Metal path (which is what you're doing)

You said your Android app sends preview straight to display via GPU surfaces and textures — i.e., you are *not* using the default camera preview view, you're running frames through your own GLSL pipeline first, then drawing the shaded output.

Do **not** use `AVCaptureVideoPreviewLayer` for this. That's the "convenient" preview for apps that don't custom-render. Your path is:

```
AVCaptureVideoDataOutput (delegate)
   → CMSampleBuffer
   → CVImageBuffer (CVPixelBuffer) [IOSurface-backed]
   → CVMetalTextureCache → MTLTexture  [zero-copy]
   → your Metal render pipeline (compute + fragment shaders)
   → drawable on CAMetalLayer / MTKView
```

Request the `AVCaptureVideoDataOutput`'s sample buffer in a Metal-compatible pixel format (BGRA or biplanar YUV), and use `CVMetalTextureCache` — `CVMetalTextureCacheCreateTextureFromImage` wraps the `CVPixelBuffer`'s IOSurface as an `MTLTexture` with **no copy** ([Apple Developer — CVMetalTextureCache](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:))).

This is the iOS analog of a `SurfaceTexture` bound to an OpenGL texture ID — but more robust, because IOSurface is a process-wide zero-copy primitive that Metal, CoreImage, CoreVideo, AVFoundation, and VideoToolbox all speak natively. IOSurface-backed `CVPixelBuffer`s let the GPU read the camera's output directly without any CPU-side copy ([IOSurface integration with Metal](https://developer.apple.com/documentation/corevideo/cvpixelbuffer)).

### 5.5 Sample delegate pattern

```swift
final class FrameConsumer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let textureCache: CVMetalTextureCache // create once with MTLDevice
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Wrap as MTLTexture (zero-copy, IOSurface-backed)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer), 0, &cvTex)
        guard let cvTex, let mtlTex = CVMetalTextureGetTexture(cvTex) else { return }
        // Dispatch into the renderer and into the C++ sink fan-out here.
    }
}
```

Attach this on a dedicated serial `DispatchQueue` (e.g., `DispatchQueue(label: "camera.frames", qos: .userInteractive)`). Never touch `AVCaptureSession` configuration from that queue — use a separate config queue.

### 5.6 Camera permissions and lifecycle

- Add `NSCameraUsageDescription` (and microphone if relevant) to `Info.plist` with a plain-English reason. App Review will reject vague strings.
- Gate start with `AVCaptureDevice.requestAccess(for: .video)` on first run.
- Respect `AVAudioSession` interruptions (`.interruptionNotification`) and app lifecycle transitions. Background mode for camera is essentially non-existent on iOS; if the app backgrounds, you stop the session and restart on foreground.
- For iPad specifically: handle Stage Manager / multi-window — your `AVCaptureSession` is not tied to a window, so split-view is fine, but be ready for the session to receive `AVCaptureSession.wasInterruptedNotification` if a higher-priority client (e.g., FaceTime) takes the camera.

---

## 6. GPU: OpenGL ES → Metal

This is the other big lift. OpenGL ES has been deprecated on iOS since iOS 12 (2018) and does not receive new features; Apple has been explicit that Metal is the go-forward API. Metal 4 shipped recently as part of iOS 19/macOS 26 — per [Apple's Metal overview](https://developer.apple.com/metal/), Metal 4 adds first-class machine-learning integration (native tensor support in both the API and shading language), faster shader compilation via a dedicated compilation context, and explicit argument tables for resource binding. For your WSI pipeline, **Metal 3 features are sufficient**; Metal 4's ML integration is interesting if you plan on-device inference, but it raises your deployment-target floor. Default to Metal 3 and opt into Metal 4 features guarded by `#if available`.

### 6.1 GLSL ES → MSL conversion

Metal Shading Language is a C++14-based dialect. Mechanical conversion is straightforward; semantic review is essential. Rough translation table:

| GLSL ES | MSL |
|---|---|
| `attribute` / `in` (vertex) | `struct VertexIn { … [[attribute(n)]] … }` |
| `varying` / `out`…`in` | `struct V2F { … [[user(locn0)]] or just named … }` |
| `uniform mat4 u_xform` | `constant float4x4 &u_xform [[buffer(0)]]` |
| `sampler2D` | `texture2d<float, access::sample>` + `sampler` |
| `texture2D(s, uv)` | `tex.sample(smp, uv)` |
| `gl_FragColor` | return from `fragment half4 …` |
| `gl_Position` | return `float4` from `vertex …` |
| `dFdx`/`dFdy` | `dfdx` / `dfdy` |
| `precision mediump float` | `half` (use liberally; half-precision is the GPU default on Apple silicon and is faster) |
| Preprocessor `#version` | N/A — just `#include <metal_stdlib>` |
| Shader compile at load | Compiled offline in the Xcode build (`.metallib`), plus online via `makeLibrary(source:options:)` |

**Automated help**: tools like `spirv-cross` can transpile GLSL → SPIR-V → MSL. For a hand-maintained pipeline as sophisticated as yours, the transpiler output is a useful *draft*, not a finished port. Hand-tune for:

- Color-space semantics (BT.601 vs BT.709 vs sRGB vs Display-P3 — iPad Pro is a P3 display; your color transforms must be P3-aware).
- Precision promotion (Apple GPUs reward `half` heavily — you'll often gain perf by demoting `float` to `half` in intermediate computations).
- Resource binding model (Metal uses explicit argument tables; GLSL is uniform-block based). Metal 4 makes argument tables an explicit object model — worth considering ([Metal 4 overview](https://developer.apple.com/metal/whats-new/)).

### 6.2 Render pipeline sketch

A Metal render pipeline for a "camera frame → shader → display" path:

```swift
// One-time setup
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeDefaultLibrary(bundle: .main) // loads .metal files
let queue = device.makeCommandQueue()!
let pipeline = try device.makeRenderPipelineState(descriptor: /* vertex+fragment fn */)
let textureCache: CVMetalTextureCache = /* create once */

// Per-frame (called on camera delegate queue or a dedicated render queue)
guard let drawable = metalLayer.nextDrawable() else { return }
let commandBuffer = queue.makeCommandBuffer()!
let rpd = MTLRenderPassDescriptor()
rpd.colorAttachments[0].texture = drawable.texture
rpd.colorAttachments[0].loadAction = .dontCare
rpd.colorAttachments[0].storeAction = .store
let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
encoder.setRenderPipelineState(pipeline)
encoder.setFragmentTexture(cameraMTLTexture, index: 0)
encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
encoder.endEncoding()
commandBuffer.present(drawable)
commandBuffer.commit()
```

### 6.3 MTKView vs CAMetalLayer

- **`MTKView`** (from MetalKit) is a ready-made `UIView` that manages the display link, drawable loop, and `CAMetalLayer`. Good for most cases.
- **Custom `UIView` with `CAMetalLayer` as backing layer** gives you control over the drawable cadence (e.g., drive it from the camera frame arrival, not from CADisplayLink). This matches what you're doing on Android with surfaces driven by camera frames rather than the UI thread.

For your app: use the `CAMetalLayer` path for the main camera preview (so cadence = camera), and `MTKView` for any secondary panels that should redraw on the display refresh rate.

### 6.4 Color management on WSI

Whole slide imaging has strict color fidelity requirements (clinicians calibrate for specific color spaces). Metal + iOS give you:

- Native **P3** display pipeline (iPad Pro is P3).
- `CAMetalLayer.colorspace` (set to `CGColorSpace(name: CGColorSpace.displayP3)`) to render wide-gamut.
- `MTKView.colorPixelFormat = .bgra10_xr` for 10-bit-per-channel wide-gamut rendering.
- Use ICC profiles carefully — if your Android shaders assume sRGB, you must explicitly tag/convert on iOS.

---

## 7. Native C++ and OpenCV reuse

This is where iOS is far friendlier than you might expect. You have three options for calling C++ from Swift.

### 7.1 Option A — Direct Swift ↔ C++ interop (Swift 5.9+, recommended for new glue code)

Swift 5.9 introduced direct C++ interoperability — a substantial set of C++ APIs, including most STL collections, function templates, and class template specializations, can be called from Swift without a bridge language ([Swift.org C++ Interop](https://www.swift.org/documentation/cxx-interop/), [Swift forum announcement](https://forums.swift.org/t/c-interoperability-in-swift-5-9/65369)). Xcode 15+ auto-imports C++ headers when interop is enabled, no bridging header required.

Enable in a Swift Package target:

```swift
.target(
    name: "EvaCore",
    dependencies: [],
    swiftSettings: [.interoperabilityMode(.Cxx)]
)
```

Or in an Xcode project: **Build Settings → C++ and Objective-C Interoperability → C++/Objective-C++**.

Pros: no Objective-C++ wrapper layer; full STL support; jump-to-definition across languages.
Cons: interop is still maturing — some templates and SFINAE patterns don't import; you may still need a thin C or C++ header that presents a "Swift-friendly" subset of your API.

### 7.2 Option B — Objective-C++ bridge (`.mm` files, the classic path)

Rename `.m` → `.mm` to compile as Objective-C++. From there, `#include` any C++ header and wrap the pieces you need in Objective-C classes, which Swift can import transparently via the auto-generated bridging header.

Pros: 15+ years of production hardening; works with any C++ codebase; most OpenCV-on-iOS tutorials use this path ([Toptal OpenCV + Swift guide](https://www.toptal.com/opencv/object-detection-opencv-swift), [OpenCV iOS install docs](https://docs.opencv.org/4.x/d5/da3/tutorial_ios_install.html)).
Cons: extra layer of hand-written boilerplate; Objective-C types at the boundary.

### 7.3 Option C — Plain C shim

Expose a narrow C API (`extern "C"`) from your C++ core, and let Swift import it via a module map. Use this when you want maximum stability or plan to ship the core as a reusable binary framework to third parties.

### 7.4 Recommendation for eva-app

Use **Option A for most new bridging code** and keep a small **Option B layer** specifically for OpenCV (because OpenCV headers are heavy and slow to compile, and many templates still cause interop issues). This mirrors the split you already have on Android — JNI for OpenCV, higher-level code somewhere else — but much thinner on iOS.

Structure:

```
EvaCore (framework target, C++ interop enabled)
├── include/
│   ├── eva/PixelSink.hpp        ← your existing multi-consumer sink API
│   ├── eva/ColorTransform.hpp
│   └── eva/EvaCore.modulemap     ← expose these to Swift
├── src/
│   ├── PixelSink.cpp            ← unchanged from Android
│   └── ColorTransform.cpp       ← unchanged from Android
└── opencv_bridge/
    ├── OCVBridge.h              ← Objective-C façade
    └── OCVBridge.mm             ← .mm: includes <opencv2/opencv.hpp>
```

### 7.5 OpenCV on iOS — packaging

You have three ways to ship OpenCV:

1. **Prebuilt `.xcframework`** from `opencv.org`'s iOS release — quickest to integrate. Covers iOS + Mac Catalyst + Simulator.
2. **Build from source** using OpenCV's `platforms/ios/build_framework.py` — needed if you use non-default modules (e.g., `opencv_contrib` for SIFT, `aruco`, etc.) or want size-optimized builds.
3. **SPM packages** wrapping the binary, e.g., [`r0ml/OpenCV`](https://github.com/r0ml/OpenCV) or the binary-only [`JustTheBinary`](https://github.com/r0ml/JustTheBinary). These are community-maintained and update on a slower cadence than upstream OpenCV; pin versions.

For a medical app, **option 2 is worth the effort**: you control the module list (drop what you don't use, meaningfully shrinking binary size), the optimization flags, and the iOS deployment target. You also avoid pulling in GPLv3-contaminated contrib modules by accident. Build universal framework covering iOS, iPadOS, and Simulators ([2024 LightBuzz guide on building OpenCV universally](https://lightbuzz.com/opencv/)).

### 7.6 Thread model for the C++ core

Keep your C++ core threading unchanged. Swift's structured concurrency (actors, `Task`, `TaskGroup`) is interop-friendly: you can call C++ from inside `async` functions. The typical pattern is:

```swift
actor FrameProcessor {
    let core: evacore.PixelPipeline  // C++ object (interop)
    func process(_ texture: MTLTexture) async -> Result { … }
}
```

One non-obvious gotcha: `Sendable` checking. C++ types do not automatically conform to `Sendable`. You'll mark interop types as `@unchecked Sendable` where you know concurrency is safe in the C++ code. Do this carefully.

---

## 8. The C++ "sink" pattern — multi-consumer data distribution

You described a C++ sink architecture where anyone can consume camera data. This is a good architecture and it ports cleanly to iOS. What changes is what enters and exits the sink.

### 8.1 What feeds the sink on iOS

The source of truth is `CMSampleBuffer` from `AVCaptureVideoDataOutput`. From there:

- For **CPU consumers** (e.g., OpenCV's `cv::Mat`): lock the `CVPixelBuffer`'s base address with `CVPixelBufferLockBaseAddress(… , .readOnly)` and construct a `cv::Mat` that *aliases* the pixel buffer (no copy). Unlock when done. This is the direct analog of `ImageReader` → `ByteBuffer` → JNI pointer.
- For **GPU consumers**: wrap the same pixel buffer as an `MTLTexture` via `CVMetalTextureCache`. Zero-copy (§5.4).
- For **multiple consumers of the same frame**: the `CVPixelBuffer` ref-counts; you can hand it to N consumers simultaneously without copying.
- For **async consumers** (consumer runs slower than camera FPS): the sample buffer arrives on a delegate queue; your sink should decide drop-vs-queue policy. Don't back up the delegate queue — the camera will drop frames or stall.

### 8.2 Recommended sink API shape

```cpp
// Shared with Android; platform provides the buffers
class PixelSink {
public:
  using Consumer = std::function<void(const Frame&)>;
  void subscribe(std::string_view id, Consumer consumer);
  void unsubscribe(std::string_view id);
  void publish(const Frame& frame); // called by platform adapter
};

struct Frame {
  uint64_t presentationTimestampNs;
  int width, height;
  PixelFormat fmt;
  // One of:
  void* cpuBase;         // CPU pointer (valid only within publish())
  void* gpuTextureOpaque;// Platform-specific handle; on iOS, id<MTLTexture> bridged
};
```

The iOS platform adapter (new code) publishes frames from the `AVCaptureVideoDataOutput` delegate. Consumers that need ownership beyond the delegate call retain the underlying `CVPixelBuffer` (via `CFRetain` / Swift ARC) before returning.

### 8.3 Back-pressure

On Android with Camera2 + ImageReader, frames drop when your reader can't keep up. On iOS, set `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true` (the default) — this matches typical Android behavior. For a WSI app doing ML or heavy CV on every frame, this is what you want. If you need every frame (e.g., recording), set it `false` and handle queue pressure explicitly.

---

## 9. Multi-stream preview (multiple views from one camera)

You mentioned the Android app configures multiple preview streams, sent straight to the display via surfaces and textures. Two patterns on iOS, depending on what "multiple previews" means:

### 9.1 Pattern A — one camera source, multiple display views

For example: main viewport, a thumbnail/navigator, and a zoom-loupe, all showing the live camera feed differently. iOS:

- One `AVCaptureSession` with one `AVCaptureVideoDataOutput`.
- Your Metal renderer has N `CAMetalLayer`-backed views; each frame, you render N command buffers (or one command buffer with N render encoders) — each writing to a different drawable.
- Because the source `MTLTexture` (the camera frame) is shared, this is effectively free on the GPU; the cost is just running N shader passes with different transforms / ROIs.
- **Do not** create multiple `AVCaptureVideoPreviewLayer`s hoping the system will do the fan-out — that only works for untouched preview. For your custom-shaded path, you control the fan-out in Metal.

SwiftUI layout:

```swift
HStack {
    MainPreview(texture: vm.latestTexture)   // Full-res shader pipeline
        .frame(maxWidth: .infinity)
    VStack {
        NavigatorPreview(texture: vm.latestTexture) // downsampled overview
        LoupePreview(texture: vm.latestTexture, roi: vm.loupeROI)
    }.frame(width: 260)
}
```

Each `*Preview` is a `UIViewRepresentable` wrapping a `CAMetalLayer`-backed view. The view model holds the shared texture (weak-wrapped so it can be recycled into the texture cache).

### 9.2 Pattern B — genuinely different camera streams (multi-cam)

Front + back + ultra-wide simultaneously: `AVCaptureMultiCamSession` with one `AVCaptureDeviceInput` per camera and one `AVCaptureVideoDataOutput` per camera. Each output has its own delegate queue (or share a queue — be careful about serialization). Fan each into its own Metal pipeline, or into your C++ sink with distinct stream IDs.

### 9.3 Pattern C — the system preview layer (when you *don't* need custom shading)

For simple uses, `AVCaptureVideoPreviewLayer` delivers hardware-accelerated preview with essentially zero CPU cost. Keep this in mind for secondary views that don't need shader treatment. Wrap it in `UIViewRepresentable` — this is the common iOS pattern for camera in SwiftUI ([createwithswift guide](https://www.createwithswift.com/integrating-device-camera-in-swiftui-apps/), [canopas walkthrough](https://canopas.com/ios-how-to-integrate-camera-apis-using-swiftui-ea604a2d2d0f)). The pattern is: a `UIView` subclass whose `layerClass` is `AVCaptureVideoPreviewLayer`, wrapped by a `UIViewRepresentable` struct. Frame updates happen automatically via AutoLayout when the SwiftUI view resizes.

### 9.4 The general rule

On iOS, the cost of "multiple views of a camera" is almost entirely in **Metal shader work**, not in camera plumbing. One session, one video data output, one shared `MTLTexture`, and N render passes. This is *simpler* than Camera2's Surface-per-consumer model, because the zero-copy primitive (IOSurface) is shared at the system level — you aren't juggling `Surface` lifecycles.

---

## 10. Threading, concurrency, memory

### 10.1 Queue model

- **Session config queue** (serial): `AVCaptureSession.beginConfiguration()` / `commitConfiguration()` calls.
- **Camera delivery queue** (serial, `.userInteractive`): receives `didOutput sampleBuffer:`. Do the zero-copy `CVPixelBuffer` → `MTLTexture` wrap here. Don't do heavy work.
- **Render queue**: can be the same as delivery (if you render immediately on arrival) or a separate queue driven by `CADisplayLink` / `MTKView` callback.
- **C++ worker pool**: your existing thread pool for OpenCV work. Keep it.
- **Main actor**: SwiftUI state updates. Always hop with `await MainActor.run { … }` or mark methods `@MainActor`.

### 10.2 Structured concurrency

Swift's `Task`/`async`/`await` is nicer than Kotlin coroutines in that `Task` tree cancellation is automatic and tied to view lifecycles via `.task { }`. But be aware:

- `Task { … }` is **unstructured** unless used inside another task. Prefer `.task { }` in views or `TaskGroup` for concurrent work.
- `AsyncStream` replaces a lot of what `Flow` does.
- `actor` isolates mutable state. Don't overuse it — for hot loops (camera delivery), plain serial `DispatchQueue` is still often better.

### 10.3 Memory model — watch for these

- iPad has a lot of RAM (8–16 GB on recent M-series iPad Pros) but your app can still be jetsammed if memory pressure is high. Keep a memory watermark and degrade gracefully (lower preview resolution, free shader caches, release overview textures). Register for `UIApplication.didReceiveMemoryWarningNotification`.
- `CVPixelBuffer` pools: if you allocate pixel buffers yourself (e.g., for downsampled copies), use `CVPixelBufferPool` — allocating fresh buffers every frame fragments memory and thrashes IOSurface.
- `MTLHeap` for transient render textures: cheaper than individual texture allocations.
- Image memory mapping: OpenCV's `cv::Mat` aliasing a `CVPixelBuffer` is free; copying is expensive. Be explicit.

---

## 11. Dependencies — what to pick

SwiftUI/iOS-native substitutes for common Android libraries you probably have:

| Android | iOS |
|---|---|
| Retrofit / OkHttp | `URLSession` + `async/await` (no 3rd-party needed for most cases); `Alamofire` if you want sugar |
| Kotlinx Serialization / Moshi / Gson | `Codable` (built-in) |
| Room | Core Data (mature) or SwiftData (iOS 17+, sugar over Core Data; still maturing) or GRDB.swift (community SQLite wrapper) |
| WorkManager | `BGTaskScheduler` (BackgroundTasks framework) |
| Hilt / Dagger | Manual dependency injection, `@Environment` for app-wide services, or Swift Factory / Resolver |
| Glide / Coil | `AsyncImage` (built-in) or Nuke / Kingfisher |
| OkHttp logging interceptor | `URLSession` with custom `URLProtocol` or a network debugger like Proxyman |
| Timber | `os.Logger` (os/log, unified logging) |
| LeakCanary | Instruments (Allocations + Leaks) |
| Firebase Analytics / Crashlytics | Firebase iOS SDK (same product) |
| Retrofit + Flow streaming | `URLSession.bytes(for:)` returning `AsyncSequence` |
| ExoPlayer | `AVPlayer` / `AVPlayerViewController` |

For a WSI app specifically:

- **DICOM**: use `dcmtk` (C++, builds on iOS) or `DCMTK-iOS` community wrapper. Keep DICOM handling in your C++ core for cross-platform parity.
- **Large tiled image formats (Aperio SVS, Hamamatsu NDPI, OME-TIFF)**: OpenSlide is the standard. Builds on iOS with some effort; vendor as a framework.
- **Pencil / Apple Pencil**: `PencilKit` for annotations with pressure/azimuth. No Android analog — this is a feature you'd *add* on iPad, not port.

---

## 12. Testing and CI

- **Unit tests**: `XCTest` (being supplemented by `swift-testing` in Swift 6 — prefer the new macro-based `@Test` for new tests). Target the C++ core with its own `XCTest` target that compiles the C++ sources.
- **UI tests**: `XCUITest`. Accessibility identifiers on SwiftUI views (`.accessibilityIdentifier(…)`) are how UI tests find elements.
- **Snapshot tests**: `swift-snapshot-testing` (Point-Free) — good for SwiftUI views and for golden-frame shader output comparisons.
- **Shader tests**: render to an offscreen `MTLTexture`, read back, compare to a golden PNG. Flaky across hardware generations — use tolerances, run on the iPad Pro model you're shipping on.
- **Camera tests**: hardware-only. Plan to emulate by feeding pre-recorded `CMSampleBuffer` streams into the pipeline for deterministic testing. This pattern pays for itself.
- **CI**: GitHub Actions with macOS runners, or Xcode Cloud. For device tests, you need a Mac mini / Mac Studio with attached iPads; Firebase Test Lab does not cover iOS devices for physical-camera tests.

---

## 13. Recommended porting workflow (phased)

A "big bang" rewrite of an imaging pipeline is high-risk. Phases:

**Phase 0 — Spike (1–2 weeks)**
Confirm feasibility on one iPad Pro model. Get a single-camera AVFoundation session → Metal preview → one ported GLSL→MSL shader rendering to screen. Wire up a trivial C++ call from Swift (interop). This is the "risk reduction" phase; no product value yet.

**Phase 1 — Core port (4–8 weeks)**
Build the platform adapter layer around your existing C++ core:
- Package the C++ core as `EvaCore.xcframework`.
- Build the C++ sink integration on iOS side.
- Stand up one AVFoundation session with the same output configurations as the Android app.
- Port 1–2 high-value shaders end-to-end as a quality bar.
- No UI yet beyond a debug harness.

**Phase 2 — Feature parity for core pipeline (6–10 weeks)**
- Port remaining shaders.
- Implement multi-stream preview.
- OpenCV integration (framework build, CV tasks wired into the sink).
- RAW / still capture parity.

**Phase 3 — SwiftUI application (4–8 weeks)**
- Screen-by-screen port of UI. SwiftUI is fast to build; this phase is mostly about matching Android behavior and iPad-specific UX (Split View, Stage Manager, keyboard shortcuts, Pencil).
- Integrate analytics, error reporting, crash reporting.

**Phase 4 — Hardening and release (3–6 weeks)**
- App Store metadata, screenshots, privacy manifest (required since 2024).
- Accessibility audit.
- Medical device compliance review if applicable (HIPAA BAAs, audit logs, FDA 510(k) considerations for WSI diagnostic use — out of scope here but time-consuming).
- TestFlight external testing.

**Ongoing — parallel development**
Consider freezing the Android side during Phase 1–2 to avoid chasing a moving target. If that isn't possible, the C++ core becomes even more important: every change on Android that lives in C++ comes over for free.

---

## 14. Gotchas specific to your stack

- **No OpenGL ES**. There's no "port OpenGL ES first, Metal later" shortcut — OpenGL ES works today but is deprecated, incurs a large translation overhead, and locks out Metal-only features (compute, tile memory, tensor ops). Go direct to Metal.
- **`glBlitFramebuffer` / `glReadPixels`-style patterns** are slower on iOS than the equivalent `MTLBlitCommandEncoder` or `MTLTexture.getBytes`. Audit assumptions.
- **Camera2 `TotalCaptureResult.get(key)` → AVFoundation**: metadata is sparser and lives in different places. Sensor data like AE/AF state is in `AVCaptureMetadataOutput` or per-frame `CMSampleBuffer` attachments (use `CMGetAttachment`). Timestamps are in `CMSampleBufferGetPresentationTimeStamp` (host time nanoseconds, use `CMClockGetTime(CMClockGetHostTimeClock())` for correlation).
- **YUV formats differ in byte order conventions**. Android's `YUV_420_888` is flexible; on iOS you typically request `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (NV12) or `kCVPixelFormatType_32BGRA`. Port shader color conversion accordingly. For HDR support use `…BiPlanarFullRange` variants and 10-bit formats.
- **`AVCaptureSession` takes a few hundred ms to start** on cold launch. Start it eagerly in the view model's `init`, not in a button handler, or users will perceive the app as slow.
- **Screen recording restrictions**: `AVCaptureVideoPreviewLayer` and `CAMetalLayer` content can be screen-captured. If you have clinical-data protection requirements, consider `isSecure` / `flags` on relevant views.
- **App Review and camera**: Apple requires that camera permission prompts fire only in response to user action. Don't auto-start the capture session on first launch before the user takes any action if the permission dialog would appear. Design a first-run onboarding screen with an explicit "Start imaging" button.
- **WSI + App Review**: If the app is marketed as a diagnostic aid, App Review will scrutinize medical claims. If it's "for research use only," that phrase must appear in-app. US/EU medical-device labelling applies regardless of App Store.
- **Swift C++ interop template compile times**: the first time you `import EvaCore` into a Swift file, Xcode has to compile the C++ headers through Clang. Budget for this; keep the public C++ header surface as narrow as possible.
- **The Simulator lies about GPU performance** — a shader that runs at 60fps in the simulator can be 5fps on an iPad A-series chip. Test on device constantly.

---

## 15. WSI / iPad-specific notes

These are not directly "porting" concerns but will affect the iOS version's architecture and UX.

- **External displays**: iPad Pro (USB-C) supports external displays at up to 6K/60. `UIScreen` and `UIWindowScene` give you multi-display APIs. A second display for a "reference" view next to the iPad's working view is a compelling feature and practically free on iPadOS.
- **Stage Manager / Split View**: your app should survive being 2/3 width. Test layout at compact size classes and at ultra-wide (external display). Don't hard-code `UIScreen.main.bounds`.
- **Apple Pencil (Pro)**: PencilKit for annotations; Apple Pencil Pro has barrel roll and squeeze gestures (iOS 17.5+) — annotation-heavy workflows should consider them.
- **Display calibration**: iPad Pro M-series displays can be color-calibrated with the Apple Pro Display XDR reference modes. For diagnostic WSI work, document your calibration target (P3 D65 is typical).
- **File sharing**: use the Files app integration (`UIDocumentBrowserViewController` / `UIDocumentPickerViewController`, or SwiftUI's `.fileImporter`). Large WSI files (10–50 GB each) may need streaming — consider piecewise download + tile-on-demand rather than loading whole slides into memory.
- **Privacy manifest**: iOS requires a `PrivacyInfo.xcprivacy` since 2024. Declare camera usage, any "required reason" APIs (timestamp, file path, etc.), and third-party SDKs.
- **Privacy nutrition labels** on the App Store: list every piece of data the app collects, why, and whether it's linked to the user.

---

## 16. A concrete skeleton to start from

```
// EvaApp/EvaApp.swift
import SwiftUI

@main
struct EvaApp: App {
    @State private var services = AppServices()
    var body: some Scene {
        WindowGroup { RootView().environment(services) }
    }
}

// EvaApp/AppServices.swift
import Observation

@Observable
final class AppServices {
    let camera: CameraController
    let renderer: MetalRenderer
    let core: EvaCoreFacade    // wraps the C++ core
    init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.renderer = MetalRenderer(device: device)
        self.camera = CameraController(renderer: renderer)
        self.core = EvaCoreFacade()
    }
}

// EvaApp/Views/RootView.swift
struct RootView: View {
    @Environment(AppServices.self) private var services
    var body: some View {
        HStack(spacing: 0) {
            MetalPreview(renderer: services.renderer, stream: .main)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SidePanel().frame(width: 320)
        }
        .task { await services.camera.start() }
        .onDisappear { services.camera.stop() }
    }
}

// EvaApp/Rendering/MetalPreview.swift
import SwiftUI
import MetalKit

struct MetalPreview: UIViewRepresentable {
    let renderer: MetalRenderer
    let stream: StreamID
    func makeUIView(context: Context) -> PreviewView {
        PreviewView(renderer: renderer, stream: stream)
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override static var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    init(renderer: MetalRenderer, stream: StreamID) {
        super.init(frame: .zero)
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra10_xr      // wide gamut
        metalLayer.framebufferOnly = false
        renderer.attach(layer: metalLayer, stream: stream)
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

The important pattern: the SwiftUI layer is a thin view of state owned by non-UI objects (`CameraController`, `MetalRenderer`, `EvaCoreFacade`). State ownership looks like Compose, but the camera and rendering are driven by their own queues and hand textures into the SwiftUI view via direct references, not state bindings. SwiftUI only re-renders when UI-relevant things change (status text, a slider value), not on every frame.

---

## 17. What not to do

- **Don't** try to use MoltenVK (Vulkan-on-Metal) to avoid rewriting shaders. App Store review allows it but the translation layer overhead and the loss of Metal-specific features cost more than a proper MSL port.
- **Don't** use `GLKView` on iOS — it's OpenGL ES and deprecated.
- **Don't** port the Android camera state machine verbatim. Camera2 has explicit `State` callbacks for open/close/configure; AVFoundation hides most of that behind `startRunning()` + notifications. Trying to force Camera2's state model on top of AVFoundation leads to race conditions.
- **Don't** use the iOS simulator as your primary dev environment. No camera, no Metal feature parity, misleading performance.
- **Don't** rewrite the C++ core in Swift "for purity." Your crown-jewel code should stay in C++ because it's the only way to keep Android+iOS parity cheap.
- **Don't** skip the privacy manifest. App Store will reject.

---

## 18. Reading list / primary sources

Apple primary:

- [AVCaptureMultiCamSession — Apple Developer](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession)
- [AVMultiCamPiP sample — capturing from multiple cameras](https://developer.apple.com/documentation/AVFoundation/avmulticampip-capturing-from-multiple-cameras)
- [Introducing Multi-Camera Capture for iOS — WWDC19](https://developer.apple.com/videos/play/wwdc2019/249/)
- [CVPixelBuffer — Apple Developer](https://developer.apple.com/documentation/corevideo/cvpixelbuffer)
- [CVMetalTextureCacheCreateTextureFromImage — Apple Developer](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:))
- [Metal — Apple Developer](https://developer.apple.com/metal/)
- [What's New in Metal — Apple Developer](https://developer.apple.com/metal/whats-new/)
- [Metal documentation](https://developer.apple.com/documentation/metal)
- [Metal Performance Shaders](https://developer.apple.com/documentation/metalperformanceshaders)
- [Mix Swift and C++ — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10172/)

Swift C++ interop:

- [Mixing Swift and C++ — Swift.org](https://www.swift.org/documentation/cxx-interop/)
- [Supported Features and Constraints — Swift.org](https://www.swift.org/documentation/cxx-interop/status/)
- [Setting Up Mixed-Language Swift and C++ Projects — Swift.org](https://www.swift.org/documentation/cxx-interop/project-build-setup/)
- [C++ Interoperability in Swift 5.9 — Swift Forums](https://forums.swift.org/t/c-interoperability-in-swift-5-9/65369)
- [Swift 5.9 Brings a Macro System and C++ Interoperability — InfoQ](https://www.infoq.com/news/2023/10/swift-5-9-released/)

OpenCV on iOS:

- [OpenCV: Installation in iOS (official docs)](https://docs.opencv.org/4.x/d5/da3/tutorial_ios_install.html)
- [Detecting Objects Using OpenCV and Swift — Toptal](https://www.toptal.com/opencv/object-detection-opencv-swift)
- [r0ml/OpenCV — Swift Package for OpenCV](https://github.com/r0ml/OpenCV)
- [Legoless/LegoCV — Native OpenCV Swift Framework](https://github.com/Legoless/LegoCV)
- [OpenCV for Apple Vision Pro, iPhone, iPad, Mac, and Simulators — LightBuzz (2024)](https://lightbuzz.com/opencv/)

SwiftUI + camera/Metal bridging:

- [Integrating Device Camera in SwiftUI Apps — createwithswift](https://www.createwithswift.com/integrating-device-camera-in-swiftui-apps/)
- [iOS — How to Integrate Camera APIs using SwiftUI — canopas](https://canopas.com/ios-how-to-integrate-camera-apis-using-swiftui-ea604a2d2d0f)
- [Live camera feed in SwiftUI with AVCaptureVideoPreviewLayer — neuralception](https://neuralception.com/detection-app-tutorial-camera-feed/)
- [Metal Camera Tutorial Part 2: CMSampleBuffer → MTLTexture — Rational Matter](https://navoshta.com/metal-camera-part-2-metal-texture/)
- [Image properties and efficient processing in iOS, part 2 — Lightricks](https://medium.com/lightricks-tech-blog/efficient-image-processing-in-ios-part-2-a96f0343e6f0)

Jetpack Compose → SwiftUI migration:

- [SwiftUI for Jetpack Compose developers — State — Chris Banes](https://chrisbanes.me/posts/swiftui-for-jetpack-compose-devs-state/)
- [SwiftUI to Jetpack Compose (and vice versa): Reference Guide — Medium](https://medium.com/@omz1990/swiftui-to-jetpack-compose-and-vice-vera-reference-guide-0b293e5a013f)
- [Fundamental Differences of Compose and SwiftUI — MateeDevs](https://medium.com/mateedevs/fundamental-differences-of-compose-and-swiftui-2dc0cdd0b37)

Metal 4 context (for forward planning):

- [Getting Started with Metal 4 — Metal by Example](https://metalbyexample.com/metal-4/)
- [Apple's Metal 4 — DEV](https://dev.to/shiva_shanker_k/apples-metal-4-is-here-and-its-actually-mind-blowing-no-really-322p)

---

## 19. Key decisions you need to make up-front

Before writing a line of code, resolve these:

1. **Minimum iPad model**. M1 iPad Pro? M4 iPad Pro? This sets your Metal feature floor and your MultiCam ceiling.
2. **Minimum iOS version**. iOS 17 if you want `@Observable`; iOS 18 for newest AVFoundation niceties.
3. **OpenCV build strategy**. Prebuilt xcframework now, custom later, or custom from day 1?
4. **C++ interop flavor**. Direct Swift↔C++ as the primary path vs Objective-C++ as the primary path. (Recommendation in §7.4: hybrid.)
5. **Shader porting approach**. Hand port vs `spirv-cross` transpile-and-audit. (For your pipeline, hand port — the shaders are the performance-critical heart of the app.)
6. **Parallel Android development freeze**. Will the Android version keep evolving during the iOS port, or will you freeze it so the two stay in sync when iOS catches up?
7. **Medical/regulatory scope**. "Research use only" vs diagnostic claim. This changes App Review, marketing, and testing requirements.
8. **Team composition**. Is there at least one engineer with shipped iOS app experience? If not, hiring or contracting for the first 3–6 months is the highest-leverage investment.

---

## 20. Bottom line

The mechanical parts of the port — UI layer, lifecycle, permissions, build system — are a matter of weeks, not months. The substantive parts are the GPU pipeline (GLSL ES → Metal), the camera pipeline (Camera2 → AVFoundation with zero-copy `CVPixelBuffer` → `MTLTexture`), and the multi-stream architecture. Your C++ core and OpenCV layer are the highest-leverage thing you have: they are portable as-is, and a clean cross-platform C++ boundary will be the single biggest determinant of how cheap the port is — and how cheap ongoing parallel development stays after launch.

Plan the port around **preserving the C++ core** and **rebuilding the iOS-specific plumbing around it** — not around rewriting the app. That framing changes the estimate from "a 9-month rewrite" to "a 4–6 month platform adapter + UI build."
