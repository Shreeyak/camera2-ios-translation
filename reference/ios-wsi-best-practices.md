# iPad WSI App — Best Practices Reference

**Target:** iPadOS 26+, Swift 6+, SwiftUI, Metal, heavy C++ core, camera-driven imaging
**Compiled:** April 2026
**Scope:** Swift/C++ interop, AVFoundation camera pipeline, SwiftUI + Swift 6 concurrency, plus iOS 16/17 foundational features still load-bearing on iOS 26.

Every external link is tagged **(Primary)** — Apple, Swift.org, Swift Evolution, WWDC, forums.swift.org, github.com/swiftlang — or **(Secondary)** — blogs, Medium, community writeups.

---

## Table of contents

1. [Architecture overview](#1-architecture-overview)
2. [Swift ↔ C++ interop](#2-swift--c-interop)
3. [AVFoundation camera pipeline](#3-avfoundation-camera-pipeline)
4. [SwiftUI + Swift 6 concurrency architecture](#4-swiftui--swift-6-concurrency-architecture)
5. [What's new in iOS 26 / iPadOS 26 / Swift 6.2–6.3](#5-whats-new-in-ios-26--ipados-26--swift-6263)
6. [Foundational features from iOS 16 & 17 still relevant](#6-foundational-features-from-ios-16--17-still-relevant)
7. [Known unknowns as of April 2026](#7-known-unknowns-as-of-april-2026)

---

## 1. Architecture overview

Recommended module split for a WSI app with a heavy C++ core:

```
WSIApp (app target, @main, SwiftUI)
 ├── AppCore (Swift module) — navigation, models, coordinators, @Observable state
 ├── CaptureKit (Swift module) — AVFoundation, MetalFX, preview layers
 ├── RenderKit (Swift + Metal) — tile renderer, shaders, MTKView host
 ├── ImagingCore (C++ module, cxx-interop enabled) — decoders, tile cache, colorspace
 ├── ImagingBridge (Swift, imports ImagingCore) — safe Swift facade over C++
 └── TestingSupport (Swift) — synthetic frame provider, mocks
```

Key design principles:

- **One Swift facade per C++ subsystem.** Never let SwiftUI views touch `ImagingCore` directly — they see only `ImagingBridge` types that are `Sendable` or actor-isolated.
- **Three isolation domains.** `@MainActor` for UI, a `CaptureActor` for AVFoundation, a `ProcessingActor` (or C++-owned thread pool) for tile decode/processing.
- **Zero-copy where it counts.** Camera → `IOSurface`-backed `CVPixelBuffer` → `MTLTexture` → Metal renderer, and optionally → C++ via raw `IOSurfaceRef` pointer — never through Swift arrays.

---

## 2. Swift ↔ C++ interop

### 2.1 State of play (April 2026)

- Swift 6.2–6.3 + the C++ Interoperability Workgroup have made direct C++ type import, `Span<T>`/`MutableSpan<T>` safe views, `SWIFT_SHARED_REFERENCE` refcounted classes, and basic reverse interop production-ready.
- Gaps: C++ exception bridging, complex callback ergonomics, and zero-copy `std::vector` iteration are still in flux.
- Canonical reference: [Mixing Swift and C++ | Swift.org](https://www.swift.org/documentation/cxx-interop/) **(Primary)**. Track the workgroup vision at [using-c++-from-swift.md](https://github.com/apple/swift-evolution/blob/main/visions/using-c%2B%2B-from-swift.md) **(Primary)**.
- Status matrix: [Supported Features and Constraints](https://www.swift.org/documentation/cxx-interop/status/) **(Primary)**.

### 2.2 Project / target structure

- **SwiftPM** — Enable interop per-target in `Package.swift`:
  ```swift
  .target(
    name: "ImagingCore",
    cxxLanguageStandard: .cxx20,
    swiftSettings: [.interoperabilityMode(.Cxx)]
  )
  ```
- **Xcode framework target** — Set *C++ and Objective-C Interoperability* → *C++ / Objective-C++* in Build Settings. This transitively enables interop for dependents.
- **libc++ is the default and only supported stdlib on Apple platforms.** Don't mix libstdc++ in.
- **Prebuilt third-party C++** — Use SwiftPM `binaryTarget` with `.xcframework`, and set `.headerSearchPath("include")` plus `.unsafeFlags(["-Xcc", "-stdlib=libc++"])` where needed.
- **Mixing `.mm` and `.cpp`** — Keep a thin Objective-C++ layer only when you need to bridge to `UIImage`, `CIImage`, or catch `std::exception` for conversion into `NSError`. Prefer direct C++/Swift interop otherwise.

Sources:
- [Setting Up Mixed-Language Swift and C++ Projects](https://www.swift.org/documentation/cxx-interop/project-build-setup/) **(Primary)**
- [SwiftPM issue — C++ interop linking](https://github.com/swiftlang/swift-package-manager/issues/6564) **(Primary)**

### 2.3 Ownership, lifetimes, safety

- Annotate C++ classes exposed as reference types:
  ```cpp
  class SWIFT_SHARED_REFERENCE(retainImageBuffer, releaseImageBuffer) ImageBuffer { … };
  ImageBuffer* SWIFT_RETURNS_RETAINED makeBuffer();
  ```
  Swift imports `ImageBuffer` as an ARC-managed class.
- Use `SWIFT_IMMORTAL_REFERENCE` only for genuine global singletons.
- Small POD structs (tile coordinates, bounding boxes) can be exposed as Swift value types directly — C++ move semantics map to Swift copy-on-write.
- Prefer `Span<T>` / `MutableSpan<T>` over `UnsafeBufferPointer`. Annotate C++ pointer parameters with `__attribute__((counted_by(size), noescape))` to enable safe overload generation.

Sources:
- [Safely Mixing Swift and C/C++](https://www.swift.org/documentation/cxx-interop/safe-interop/) **(Primary)**
- [C++ shared reference ownership thread](https://forums.swift.org/t/c-shared-reference-ownership/66146) **(Primary)**
- [Doug Gregor — Swift for C++ practitioners: Reference Types](https://www.douggregor.net/posts/swift-for-cxx-practitioners-reference-types/) **(Secondary)**

### 2.4 `std::` type cheatsheet

| C++ type          | Swift-side behavior                                          | Recommendation for WSI                                                                 |
| ----------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `std::string`     | Imported as C++ struct; no auto-bridge to `String`           | Avoid across boundary; return `const char*` + length, or a tiny status enum            |
| `std::vector<T>`  | Conforms to `RandomAccessCollection`, but iteration deep-copies in release | Prefer returning `Span<T>` from a method that exposes vector's backing storage        |
| `std::span<T>`    | Maps to Swift `Span<T>` (non-escapable)                      | **Preferred** for tile pixel data                                                       |
| `std::unique_ptr` | Unmanaged pointer on Swift side                              | Wrap in `SWIFT_SHARED_REFERENCE` class                                                  |
| `std::shared_ptr` | Unmanaged unless wrapped                                     | Wrap in `SWIFT_SHARED_REFERENCE` w/ `enable_shared_from_this`                           |
| `std::optional`   | Maps directly to Swift `Optional`                            | Use freely                                                                              |
| `std::map`        | `Collection` conformance, iteration only                     | Read-only access; mutations via explicit C++ methods                                    |

Sources:
- [Accessing Underlying Memory of Data in C++ with New Span APIs](https://forums.swift.org/t/accessing-underlying-memory-of-data-in-c-with-new-span-apis/80403) **(Primary)**
- [Span (Swift 6.2 introduction)](https://medium.com/@abdiel.sba/span-cd798c39a83d) **(Secondary)**

### 2.5 Swift 6 strict concurrency × C++

- C++ types are **not** `Sendable` by default. You have three options when crossing actor boundaries:
  1. Wrap access in a Swift `actor`.
  2. Mark a Swift facade `@unchecked Sendable` if you've manually audited thread safety.
  3. Mark static singletons `nonisolated(unsafe)` and document the thread-safety contract.
- Pattern for a C++ engine with its own thread pool (e.g., tile loader) delivering back to the main actor:
  1. C++ calls a C-ABI completion callback.
  2. Swift wraps the C++ engine in an `actor` that adapts the callback into `withCheckedContinuation` / `AsyncChannel`.
  3. SwiftUI consumes via `.task { for await tile in loader.tiles { … } }`.
- Never capture a Swift closure and store it long-term on the C++ side unless you retain it with `Unmanaged.passRetained` and release explicitly.

Sources:
- [Safely use AVCaptureSession + Swift 6.2 Concurrency](https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622) **(Primary)**
- [Complete concurrency enabled by default — Swift 6](https://www.hackingwithswift.com/swift/6.0/concurrency) **(Secondary)**
- [`nonisolated(unsafe)` incremental adoption](https://medium.com/@aliyasirali/understanding-nonisolated-unsafe-in-swift-incremental-adoption-of-strict-concurrency-2cbb61c9adf4) **(Secondary)**

### 2.6 Reverse interop (Swift ← C++)

- Swift 6.3's `@c` attribute on a Swift function generates a C++ declaration in a generated header. Practical for simple callouts.
- Complex Swift closures and `async` functions are **not** directly callable from C++. Use C-ABI function pointer callbacks + `Unmanaged` to bridge.
- Don't expect to call `@MainActor` Swift async functions from C++; bridge through a completion callback → continuation.

Sources:
- [Mix Swift and C++ — WWDC23 session 10172](https://developer.apple.com/videos/play/wwdc2023/10172/) **(Primary)**
- [Calling Swift Code from C++ (Swift forums discussion)](https://forums.swift.org/t/calling-swift-code-from-c/38792) **(Primary)**

### 2.7 Zero-copy buffer sharing

- Use `IOSurface` as the shared backing store between AVFoundation, Metal, and C++.
- Camera → `CVPixelBuffer` (IOSurface-backed) → `CVMetalTextureCache` → `MTLTexture`. Same physical pages, no copy.
- To hand the same pixels to C++, extract via `CVPixelBufferGetIOSurface(pixelBuffer)` and pass the `IOSurfaceRef` pointer. The C++ side calls `IOSurfaceLock` / `IOSurfaceUnlock` around reads.
- Never iterate a C++ `std::vector<uint8_t>` in Swift's `for-in` for tile bytes — deep copy. Use `Span` instead.

Sources:
- [Display HDR video in EDR with AVFoundation and Metal — WWDC22 session 110565](https://developer.apple.com/videos/play/wwdc2022/110565/) **(Primary)**
- [CVMetalTextureCache documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache) **(Primary)**
- [Metal camera tutorial — sample buffer → Metal texture](https://navoshta.com/metal-camera-part-2-metal-texture/) **(Secondary)**

### 2.8 Error handling across the boundary

- C++ exceptions do **not** propagate to Swift. An uncaught exception crossing the boundary aborts.
- Pattern: wrap every C++ API that can throw in a C function returning an error code + out-parameter, then expose a `throws` Swift method that checks the code.
- If you already have a `.mm` layer, you can catch `std::exception` and translate to `NSError` → `Error`.

Sources:
- [Doug Gregor — Error Handling](https://www.douggregor.net/posts/swift-for-cxx-practitioners-error-handling/) **(Secondary, authoritative author)**
- [Handling C++ exceptions (Swift forums)](https://forums.swift.org/t/handling-c-exceptions/34823) **(Primary)**

### 2.9 Testing

- Use **Swift Testing** (not XCTest) for new test targets. Imports work the same way.
- Test C++ through Swift: instantiate C++ classes directly from Swift test code with interop enabled.
- Define a Swift `protocol` over the C++ engine and mock it for SwiftUI unit tests — avoids instantiating the full C++ stack in UI tests.

Sources:
- [Swift Testing documentation](https://developer.apple.com/documentation/testing) **(Primary)**
- [Swift Testing basics — Donny Wals](https://www.donnywals.com/swift-testing-basics-explained/) **(Secondary)**

---

## 3. AVFoundation camera pipeline

### 3.1 Session setup on iPadOS 26

- `AVCaptureSession` with `.photo` preset is appropriate when you want full-sensor still captures alongside a video preview. Don't use `.high`/`.medium` — they impose compression you can't undo.
- For iPad Pro (M-series) with dual rear cameras, use `AVCaptureDevice.DiscoverySession` and pin to `.builtInWideAngleCamera`. Lock `primaryConstituentDeviceSwitchingBehavior = .restricted` so the system doesn't silently swap lenses mid-scan.
- Base iPad has a single rear camera — just enumerate and pick.
- Stage Manager / multitasking: set `UIRequiresFullscreen` to `false` only if you can tolerate losing the session in split windows. Handle `AVCaptureSession.wasInterruptedNotification` with `interruptionReasonKey`.
- Run `startRunning()` / `stopRunning()` on a background queue — they block.

Sources:
- [AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession) **(Primary)**
- [Setting up a capture session](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session) **(Primary)**
- [AVCam: Building a camera app](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) **(Primary)**
- [Accessing the camera while multitasking on iPad](https://developer.apple.com/documentation/avkit/accessing-the-camera-while-multitasking-on-ipad) **(Primary)**

### 3.2 Outputs: photos vs video data vs movie file

- For WSI: **run two outputs concurrently**.
  - `AVCapturePhotoOutput` — archival stills. Set `maxPhotoQualityPrioritization = .quality`. Request ProRAW where supported for 12-bit DNG.
  - `AVCaptureVideoDataOutput` — live preview + frame feed into the C++ core. Set `videoSettings[kCVPixelBufferMetalCompatibilityKey] = true` so buffers are IOSurface-backed.
- `AVCaptureMovieFileOutput` only if you need ProRes video archival of a scan session.

Sources:
- [AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput) **(Primary)**
- [Capturing photos in RAW and Apple ProRAW formats](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats) **(Primary)**
- [What's new in camera capture — WWDC21 session 10047](https://developer.apple.com/videos/play/wwdc2021/10047/) **(Primary)**

### 3.3 Manual control for microscopy-style capture

- `lockForConfiguration()` then set:
  - `focusMode = .locked`, optionally `setFocusModeLocked(lensPosition:)` for deterministic near-focus.
  - `exposureMode = .custom`, `setExposureModeCustom(duration:iso:)` — keep ISO at minimum supported (usually 100) and vary shutter for SNR.
  - `whiteBalanceMode = .locked`; for H&E / IHC, calibrate against a white reference tile and then apply `setWhiteBalanceModeLocked(with:)` with explicit gains.
- Pick `activeFormat` where `isVideoBinned == false` so you get full-sensor native resolution. Binned formats combine pixels for low light — bad for resolution-critical WSI.
- Disable continuous autofocus — focus hunt ruins structured scans.
- Query `isMacroFocusSupported` / `macroFocusRingValue` on supported iPads for close-focus work.

Sources:
- [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice) **(Primary)**
- [AVCaptureDevice.Format](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format) **(Primary)**
- [Camera Capture on iOS — objc.io](https://www.objc.io/issues/21-camera-and-photos/camera-capture-on-ios/) **(Secondary)**

### 3.4 Color, HDR, calibration

- Query `activeFormat.supportedColorSpaces`. Prefer **P3-D65** on iPad Pro for stained-tissue fidelity; fall back to sRGB on base iPad.
- 10-bit formats: `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange` (YCbCr) or `kCVPixelFormatType_64RGBALE` (RGBA float on Apple Silicon) — use if your Metal shaders and C++ decoder handle it end-to-end.
- `AVCameraCalibrationData` gives intrinsic/extrinsic matrices. Usable as a seed, but published calibration is approximate (~7% focal-length error reported on 5th-gen iPads). For WSI, prefer geometric calibration against a known test slide.
- For HDR archival, ProRAW preserves the most; for scanning throughput, stay SDR 10-bit.

Sources:
- [supportedColorSpaces](https://developer.apple.com/documentation/avfoundation/avcapturedeviceformat/supportedcolorspaces) **(Primary)**
- [AVCameraCalibrationData](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata) **(Primary)**
- [Display HDR video in EDR with AVFoundation and Metal — WWDC22 session 110565](https://developer.apple.com/videos/play/wwdc2022/110565/) **(Primary)**

### 3.5 Zero-copy frame delivery

The canonical pipeline:

```
AVCaptureVideoDataOutput
   │ sampleBufferDelegate (background queue)
   ▼
CMSampleBuffer ──► CVPixelBuffer (IOSurface-backed)
                        │
         ┌──────────────┼─────────────────┐
         ▼              ▼                 ▼
   CVMetalTextureCache  IOSurfaceRef   (optional: CIImage)
         │              │
         ▼              ▼
   MTLTexture       C++ processor (locks surface, reads bytes)
         │
         ▼
   MTKView drawable (preview)
```

- Preferred pixel format for WSI: `kCVPixelFormatType_32BGRA` if you can afford bandwidth; `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` otherwise (do YUV→RGB in a Metal shader).
- One `CVMetalTextureCache` per `MTLDevice`; reuse it.
- Keep the `CVPixelBuffer` alive while C++ reads its IOSurface — retain the `CMSampleBuffer` in a pool and release only after the C++ processor signals completion.

Sources:
- [CVMetalTextureCache](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache) **(Primary)**
- [Image properties and efficient processing in iOS, part 2 — Lightricks Tech Blog](https://medium.com/lightricks-tech-blog/efficient-image-processing-in-ios-part-2-a96f0343e6f0) **(Secondary)**
- [Metal Camera Tutorial Part 2 — Rational Matter](https://navoshta.com/metal-camera-part-2-metal-texture/) **(Secondary)**

### 3.6 Threading under Swift 6 strict concurrency

- `AVCaptureSession` is thread-safe but not `Sendable`. Wrap it in a `nonisolated` class or an `actor`.
- `sampleBufferDelegate` callbacks fire on the queue you set — keep them off `MainActor`. Mark the delegate method `nonisolated`.
- Do **not** feed a 30–60 fps camera into an unbuffered `AsyncStream`. Overhead and scheduling jitter show up as dropped frames. Use either:
  - a lock-free ring buffer polled by the renderer, or
  - `AsyncChannel` from [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) **(Primary)** for backpressure-aware delivery.
- For UI state updates from the capture queue, hop with `Task { @MainActor in … }`.

Sources:
- [Safely use AVCaptureSession + Swift 6.2 Concurrency](https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622) **(Primary)**
- [AVCaptureSession and concurrency](https://forums.swift.org/t/avcapturesession-and-concurrency/72681) **(Primary)**
- [SE-0406: Backpressure support for AsyncStream](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0406-async-stream-backpressure.md) **(Primary)**

### 3.7 SwiftUI integration

- For preview-only UI: wrap `AVCaptureVideoPreviewLayer` in `UIViewRepresentable`.
- For WSI, you almost certainly want a custom `MTKView`-based preview so you can overlay focus peaking, grid guides, and annotation — wrap `MTKView` in `UIViewRepresentable`.
- Lifecycle: observe `@Environment(\.scenePhase)` and stop/start the session on `.background` / `.active`. Don't keep the session running on background — you'll be interrupted anyway and it drains battery.
- External displays (connected pathology monitor): add a second `AVCaptureVideoPreviewLayer` or a second `MTKView` on an external `UIScreen`. Both can share the capture session.

Sources:
- [AVCam sample code](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) **(Primary)**
- [scenePhase lifecycle](https://developer.apple.com/documentation/swiftui/scenephase) **(Primary)**

### 3.8 iOS 26 / WWDC 25 additions

- **Capture Controls API** — `AVCaptureControl` + `AVCaptureSessionControlsDelegate` let you bind hardware camera buttons (and iPad Pro's lock-screen camera) to in-app controls. For WSI, bind the hardware button to "capture tile at current position". [Enhancing your camera experience with capture controls — WWDC25 session 253](https://developer.apple.com/videos/play/wwdc2025/253/) **(Primary)**.
- **Cinematic Video API** — [WWDC25 session 319](https://developer.apple.com/videos/play/wwdc2025/319/) **(Primary)**. Not applicable to flat slides.
- **Deferred photo processing** shipped in iOS 17 and has been stable since — keeps the shutter responsive, finishes processing off-session. Useful if you batch-capture many tiles.

### 3.9 Permissions

- `NSCameraUsageDescription` in Info.plist is mandatory.
- Request with `AVCaptureDevice.requestAccess(for: .video)` on first use; always handle denial without crashing.
- Lock orientation to landscape in `SceneDelegate` / scene configuration for WSI — operators work landscape.

### 3.10 Testing the camera pipeline

- The iOS simulator has **no camera**. Develop on device.
- Build a `SyntheticFrameProvider` that drives your `sampleBufferDelegate` from an `AVAssetReader` over a recorded video — same code path, deterministic, usable in CI.
- Record real scans as ProRes during development so replay is bit-exact.

Sources:
- [AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader) **(Primary)**
- [iCimulator (simulator camera mock)](https://github.com/YuigaWada/iCimulator) **(Secondary)**

---

## 4. SwiftUI + Swift 6 concurrency architecture

### 4.1 Strict concurrency baseline

- Xcode 26 ships new projects with strict concurrency enabled. For SwiftPM modules, set `.enableUpcomingFeature("StrictConcurrency")` or `.swiftLanguageMode(.v6)`.
- Incremental migration path: module-by-module, enable at warning level first, then fix and promote to error.
- Key tools:
  - `Sendable` — value types and final immutable classes cross actor boundaries freely.
  - `@unchecked Sendable` — manual audit escape hatch; document the reason.
  - `nonisolated` — opt out of caller-inherited isolation.
  - `nonisolated(unsafe)` — for module-global state with external synchronization (e.g., a C++ singleton).
  - `isolated(any)` — propagate isolation through generic APIs.

Sources:
- [Adopting strict concurrency in Swift 6 apps](https://developer.apple.com/documentation/swift/adoptingswift6) **(Primary)**
- [SE-0337: Incremental migration to concurrency checking](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md) **(Primary)**
- [The Swift Programming Language — Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency) **(Primary)**

### 4.2 Actor design for an imaging pipeline

- Prefer **discrete actors** (`CaptureActor`, `ProcessingActor`, `TileCacheActor`) over one global actor. Global actors serialize everything across the app — that's rarely what you want.
- Actors are **reentrant** at every `await`. If you hold logical invariants across awaits, either restructure or use a non-reentrant lock inside.
- `MainActor.assumeIsolated` is a last-resort compatibility bridge — use `Task { @MainActor in … }` in new code.
- Cross-actor messages go through `Sendable` struct payloads (`struct FrameMetadata: Sendable`), never through C++-backed types directly.

Sources:
- [Actor isolation diagnostics](https://github.com/swiftlang/swift/blob/main/userdocs/diagnostics/actor-isolated-call.md) **(Primary)**
- [SE-0316: Global actors](https://github.com/apple/swift-evolution/blob/main/proposals/0316-global-actors.md) **(Primary)**

### 4.3 Observation framework

- `@Observable` on your models (not `ObservableObject`). SwiftUI tracks reads on the current view body automatically and re-renders only affected views.
- `@Bindable` in child views for two-way binding to an observable parent.
- `@Environment` for dependency injection of observable roots — preferred over `@EnvironmentObject` for `@Observable` types.
- For values produced off-MainActor (e.g., a tile from a background actor), mirror them into a `@MainActor` `@Observable` model before reading from a view.

Sources:
- [Observation framework](https://developer.apple.com/documentation/observation) **(Primary)**
- [Migrating from ObservableObject to @Observable](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro) **(Primary)**

### 4.4 Scene / app lifecycle on iPadOS 26

- Use `WindowGroup` for ad-hoc multi-window, or `DocumentGroup` if a WSI session is a document (`.svs`, `.ndpi`, custom container). Each window gets independent `@State`.
- Persist viewport position per window with `@SceneStorage`.
- Handle `@Environment(\.scenePhase)` transitions to stop capture on background.
- Stage Manager windows on iPadOS 26 size primarily `.regular` — still respect size classes for adaptive layout.

Sources:
- [WindowGroup](https://developer.apple.com/documentation/swiftui/windowgroup) **(Primary)**
- [DocumentGroup](https://developer.apple.com/documentation/swiftui/documentgroup) **(Primary)**
- [scenePhase](https://developer.apple.com/documentation/swiftui/scenephase) **(Primary)**

### 4.5 Navigation

- `NavigationSplitView` is mandatory for an iPad-first app. On narrower iPads in a slim Stage Manager window it collapses to a stack cleanly.
- Make the navigation type-safe with a `Hashable` enum stored in a `NavigationPath`.
- Persist via `@SceneStorage` for state restoration.
- Do **not** use `NavigationView` — deprecated since iOS 16.

Sources:
- [Migrating to new navigation types](https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types) **(Primary)**
- [SwiftUI cookbook for navigation — WWDC22 session 10054](https://developer.apple.com/videos/play/wwdc2022/10054/) **(Primary)**

### 4.6 Data flow: vanilla Observation vs TCA

- Mainstream 2026 stance: **vanilla `@Observable` + discrete per-feature models** is the default for mid-sized apps. Reach for TCA only if you need exhaustive testability across 5+ deeply-interdependent screens.
- "Reducer-lite" works well: methods on an `@Observable` class that mutate state and spawn `Task`s. Keep models flat — avoid deeply nested observable graphs.

Sources:
- [The Composable Architecture (github)](https://github.com/pointfreeco/swift-composable-architecture) **(Secondary)**
- [Point-Free case studies](https://www.pointfree.co/) **(Secondary)**

### 4.7 Bridging long-running work into SwiftUI

- For camera frame delivery: **don't** use an unbounded `AsyncStream`. Use `AsyncChannel` (backpressure) or a frame-request model where the renderer pulls.
- Use `.task(id:)` on views so pipelines cancel automatically when view identity changes.
- Use `withTaskCancellationHandler` to guarantee cleanup (close files, release buffers) on cancellation.
- For periodic work, prefer `CADisplayLink` wrapped in an `AsyncSequence` over `Task.sleep` — `sleep` drifts.

Sources:
- [AsyncStream](https://developer.apple.com/documentation/swift/asyncstream) **(Primary)**
- [swift-async-algorithms — AsyncChannel](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Channel.md) **(Primary)**
- [SE-0406: Backpressure for AsyncStream](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0406-async-stream-backpressure.md) **(Primary)**

### 4.8 Performance pitfalls under 30–60 fps

- Observation re-evaluates a view body whenever a property it reads changes. At 60 fps, touching one published property per frame can thrash. Mitigations:
  - Split heavy views so the hot path only invalidates a small leaf view.
  - Keep per-frame values in a dedicated small `@Observable` model scoped to the renderer.
  - Move heavy rendering to `MTKView` — SwiftUI is the container, not the renderer.
- Profile with the new Instruments SwiftUI templates — `View Body`, `Hangs`, and the cause-and-effect graph from WWDC25.

Sources:
- [Optimize SwiftUI performance with Instruments — WWDC25 session 306](https://developer.apple.com/videos/play/wwdc2025/306/) **(Primary)**
- [Demystify SwiftUI performance — WWDC23 session 10160](https://developer.apple.com/videos/play/wwdc2023/10160/) **(Primary)**

### 4.9 Testing

- Swift Testing is the default for new code. Async tests are first-class — no `XCTestExpectation`.
- Preview-driven development: use `#Preview { … }` with injected fakes for observable models.
- For SwiftUI snapshot testing, community libraries are maturing — comparing serialized model state (deterministic JSON) is a safer pattern than pixel-compare.

Sources:
- [Swift Testing](https://developer.apple.com/documentation/testing) **(Primary)**
- [Meet Swift Testing — WWDC24 session 10179](https://developer.apple.com/videos/play/wwdc2024/10179/) **(Primary)**

### 4.10 iPad input & Apple Pencil

- `@FocusState` for external-keyboard focus. `.keyboardShortcut` on common actions (pan, zoom ±, capture, next tile) — essential for pathology workflows.
- Apple Pencil hover (iPadOS 17+, refined on 26) via `.hoverEffect()` and `.pointerStyle()` — good for an annotation crosshair preview before touch-down.
- Apple Pencil Pro barrel-roll and squeeze gestures available through standard Pencil APIs — no custom handling needed unless you're mapping pressure curves.
- Pointer support on iPad (trackpad / mouse) comes for free when you use standard SwiftUI gestures.

Sources:
- [Pencil interactions](https://developer.apple.com/documentation/uikit/pencil_interactions) **(Primary)**
- [keyboardShortcut(_:modifiers:)](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:modifiers:)) **(Primary)**

---

## 5. What's new in iOS 26 / iPadOS 26 / Swift 6.2–6.3

iOS 26 shipped fall 2025 alongside Swift 6.2; Swift 6.3 followed in late 2025. All WWDC 2025 sessions referenced below are available. WWDC 2026 has not yet occurred at time of writing (April 16, 2026) — nothing below is speculation.

### 5.1 Camera / AVFoundation

- **Capture Controls API** — `AVCaptureControl` and `AVCaptureSessionControlsDelegate` let you bind system-provided controls (zoom slider, exposure bias) and your own custom controls into the capture session. The OS exposes them through the Camera Control button on compatible hardware and, on iPad, through system-surfaced UI + hardware pass-through (volume buttons, connected accessories). Relevant for WSI: bind a physical button to "capture current tile" so the operator can keep both hands on the stage. [Enhancing your camera experience with capture controls — WWDC25 253](https://developer.apple.com/videos/play/wwdc2025/253/) **(Primary)**; [AVCaptureControl](https://developer.apple.com/documentation/avfoundation/avcapturecontrol) **(Primary)**.
- **Cinematic Video API for third parties** — [WWDC25 319](https://developer.apple.com/videos/play/wwdc2025/319/) **(Primary)**. Not applicable to flat slides; ignore unless you add Z-stack / volumetric capture later.
- **Constant color capture, HDR photo improvements** — incremental refinements. No breaking changes, no new pixel formats specifically mandated for iOS 26. Monitor [Apple sample code updates](https://developer.apple.com/documentation/avfoundation) **(Primary)**.
- **LockedCameraCapture** — no iOS 26 evolution; stable since iOS 18. Skip unless you add a Lock Screen widget.
- **Reaction effects** — built into the system camera only; third-party capture sessions are unaffected. No disable API needed.

### 5.2 Metal 4

- **Unified command encoders + tensors as first-class shader primitives** — Metal 4 folds compute/blit/render encoders into a cleaner command model and makes tensors native in MSL. For WSI, the tensor types pay off if you inline ML (e.g., a focus-quality network, a stain-normalization network) into shaders instead of hopping through Core ML. [Discover Metal 4 — WWDC25 205](https://developer.apple.com/videos/play/wwdc2025/205/) **(Primary)**; [What's new in Metal — WWDC25 dev docs](https://developer.apple.com/metal/) **(Primary)**.
- **Residency sets + sparse resources** — explicit control over what's resident in GPU memory. This is the killer feature for WSI: an open slide can be hundreds of GB of tiles; only the visible pyramid level × viewport fraction should be resident. Implement tile pages as sparse-backed `MTLTexture`s and use residency sets to page in/out as the viewport moves.
- **Tile shading improvements** — per-tile workgroup memory and reduced barrier costs. Use for per-tile histograms, per-tile focus scoring, per-tile color correction. Avoids a full global pass.
- **MetalFX Frame Interpolation** — synthesizes intermediate frames for smooth zoom/pan at high magnification. Use for UX; don't use during archival capture.
- **Machine Learning on GPU** — tighter MPSGraph / Metal integration; run small inference networks inside the render loop without a CPU round-trip. [MLX / MPSGraph updates](https://developer.apple.com/documentation/metalperformanceshadersgraph) **(Primary)**.
- **Indirect command buffers, ray tracing denoiser** — not directly relevant for 2D WSI, but note they exist if you add 3D volumetric visualization.

### 5.3 SwiftUI & design language

- **Liquid Glass material** — the 2025 visual language, translucent with real-time light lensing. Use `.glassBackgroundEffect()` / `.liquidGlass` style on floating overlays (measurement toolbars, annotation popovers). Don't apply over the slide canvas itself — it reduces color accuracy, which matters for pathology. [Build a SwiftUI app with the new design — WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) **(Primary)**; [What's new in SwiftUI — WWDC25 256](https://developer.apple.com/videos/play/wwdc2025/256/) **(Primary)**.
- **TabView `.sidebarAdaptable`** — tabs adapt to sidebar/floating bar based on size class. Good fit for a Scan / Review / Export top-level split on iPad.
- **`tabViewBottomAccessory`** — persistent control strip below tabs; useful for a always-on capture button or focus indicator.
- **Chart3D in Swift Charts** — new 3D chart type. Secondary priority for WSI; useful if you visualize stain density across Z or focus confidence across a grid.
- **WebView (SwiftUI-native)** — if you embed institutional LIS/report viewers. [WebView docs](https://developer.apple.com/documentation/swiftui/webview) **(Primary)**.
- **Rich text editing / `AttributedString`** — improved SwiftUI-native rich text editing for annotations and slide notes.
- **`@Observable` refinements** — tighter view-body tracking, fewer false invalidations. No API change, just better performance — profile before/after a Xcode 26 upgrade.

### 5.4 Swift 6.2 / 6.3 language

- **"Approachable Concurrency" (Swift 6.2)** — opt-in default `@MainActor` isolation for modules, so UI-first modules no longer need `@MainActor` on every view. Nonisolated async functions inherit the caller's isolation by default (avoids needless hops). Strongly recommended for the app target; keep capture/processing modules with their own explicit isolation. [What's new in Swift — WWDC25 245](https://developer.apple.com/videos/play/wwdc2025/245/) **(Primary)**; [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/) **(Primary)**; [SE-0466: Control default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) **(Primary)**.
- **`@concurrent` attribute** — explicitly marks a function as running off the current actor, complementing default isolation. Useful at the C++ bridge for tile-decode calls.
- **`InlineArray<T, N>`** — stack-allocated fixed-size array, zero heap allocation. Good for small pixel tiles, SIMD staging buffers, transient LUTs. [SE-0453: InlineArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md) **(Primary)**.
- **`Span<T>` / `MutableSpan<T>` stabilization** — non-escapable views over contiguous memory. Use for zero-copy exposure of Metal buffer contents and C++ `std::span` interop.
- **Strict concurrency default for new projects in Xcode 26** — Xcode's new-project template enables `-swift-version 6` with complete checking on. Existing projects keep their current setting until you migrate.
- **C++ interop — `@c` attribute (Swift 6.3)** — annotate a Swift function with `@c` to auto-generate a C declaration consumable from C/C++. Makes reverse interop (C++ calling into Swift for tile metadata, focus scores, logging) practical without manual header writing. [Swift 6.3 @c attribute forum thread](https://forums.swift.org/t/new-little-gem-in-swift-6-3-85621) **(Primary)**.
- **Embedded Swift improvements** — not relevant for a WSI iPad app, noted for completeness.

### 5.5 Xcode 26 & tooling

- **Explicit modules GA** — faster and more deterministic builds, big impact on mixed Swift/C++/Metal shader projects. Enabled by default; no opt-in needed. [What's new in Xcode 26 — WWDC25 247](https://developer.apple.com/videos/play/wwdc2025/247/) **(Primary)**.
- **Processor Trace instrument** — zero-overhead CPU trace (Apple Silicon only). Use for profiling the C++ tile decode hot path.
- **SwiftUI cause-and-effect Instruments template** — shows exactly which state change triggered which view body re-evaluation. Point this at your 30–60 fps preview view first — it's the likeliest hang source.
- **Power Profiler** — essential for long scanning sessions that must stay under thermal/battery budgets.
- **Predictive code completion / Swift Assist** — on-device intelligence integrations in Xcode. Optional; lower priority for imaging work.

### 5.6 iPadOS 26 windowing & UX

- **Real windowing model** — Stage Manager has evolved into free-form resizable windows with a macOS-like menu bar (swipe or pointer at top). Unlimited windows (hardware permitting), Exposé for overview, universal across all current iPads. For WSI, this means: main viewport window + metadata inspector window + annotation list window can coexist and be resized arbitrarily. [iPadOS 26 Newsroom](https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-features-that-push-ipad-even-further/) **(Primary)**.
- **Menu bar on iPad** — expose classic menus via SwiftUI `commands { … }` in your `WindowGroup`. Operators used to pathology workstations will expect File / Edit / View / Tools menus; ship them.
- **`Window` + auxiliary windows** — use `Window("Inspector", id: "inspector") { InspectorView() }` for a singleton secondary window, and `openWindow(id:)` from the environment to summon it.
- **External display improvements** — cleaner external-display story; treat the external screen as a first-class `Scene` rather than a mirrored layer. Useful for wiring an iPad to a clinical review monitor.
- **Apple Pencil Pro** — barrel roll, haptic squeeze, double-tap. Relevant only if you ship annotation/markup; opt in via standard Pencil APIs.
- **Background processing** — no dramatic change for camera workloads; the system still suspends camera sessions in background. Continue to stop capture on `scenePhase == .background`.

### 5.7 Priority checklist for your WSI app

Highest leverage, in rough order:

1. Adopt **Metal 4 sparse resources / residency sets** for gigapixel tile streaming — this alone justifies the iOS 26 target.
2. Turn on **Swift 6.2 approachable concurrency** for the app target; keep Capture/Processing modules at explicit isolation.
3. Use **`Span<T>` / `MutableSpan<T>`** across every C++ boundary where you currently pass `UnsafeBufferPointer`.
4. Implement **Capture Controls API** so hardware buttons trigger tile capture.
5. Adopt the **iPadOS 26 windowing model** with a proper menu bar — pathologists expect it.
6. Profile with the **SwiftUI cause-and-effect Instruments template** before launch.
7. Plan to adopt the **`@c` attribute in Swift 6.3** for any Swift-to-C++ reverse calls.

---

## 6. Foundational features from iOS 16 & 17 still relevant

iOS 26 is the target, but much of the API surface you'll use daily shipped in iOS 16 and 17 and hasn't been meaningfully replaced. Summary of what still matters.

### 5.1 iOS 16 (WWDC 2022)

| Feature | Why it still matters | Source |
| --- | --- | --- |
| **NavigationStack / NavigationSplitView** | The navigation primitives. Baseline for all iPad apps; no replacement. | [Migrating to new navigation types](https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types) **(Primary)**; [WWDC22 10054](https://developer.apple.com/videos/play/wwdc2022/10054/) **(Primary)** |
| **Swift Concurrency maturity (Sendable checking levels)** | iOS 16 introduced minimal/targeted/complete Sendable checking — the precursor to Swift 6 enforcement. Codebases that adopted "complete" early had trivial Swift 6 migrations. | [Eliminate data races using Swift Concurrency — WWDC22 110351](https://developer.apple.com/videos/play/wwdc2022/110351/) **(Primary)** |
| **Metal 3 + MTLBinaryArchive** | Offline shader compilation → deterministic startup for a tile renderer. | [Target and optimize GPU binaries — WWDC22 10102](https://developer.apple.com/videos/play/wwdc2022/10102/) **(Primary)**; [MTLBinaryArchive](https://developer.apple.com/documentation/metal/mtlbinaryarchive) **(Primary)** |
| **MetalFX spatial upscaling** | Render at lower resolution, upscale to display — reduces GPU load on dense tile mosaics. | [MetalFX](https://developer.apple.com/documentation/metalfx) **(Primary)** |
| **Core Image EDR / HDR** | ~150 CIFilters handle EDR pixel formats. Relevant if you use Core Image for colorspace correction. | [Explore EDR on iOS — WWDC22 10113](https://developer.apple.com/videos/play/wwdc2022/10113/) **(Primary)**; [Display EDR with Core Image, Metal, SwiftUI — WWDC22 10114](https://developer.apple.com/videos/play/wwdc2022/10114/) **(Primary)** |
| **Swift Charts** | Useful for diagnostic overlays — stain density histograms, focus quality plots. | [Swift Charts: Raise the bar — WWDC22 10137](https://developer.apple.com/videos/play/wwdc2022/10137/) **(Primary)** |

Not relevant or superseded for WSI: RegexBuilder, ShareLink, PhotosPicker, Transferable — general-purpose APIs that don't touch the hot path.

### 5.2 iOS 17 (WWDC 2023)

| Feature | Why it still matters | Source |
| --- | --- | --- |
| **Observation framework (`@Observable`)** | The modern state model. Replaces `ObservableObject`/`@Published`. Foundational for all new SwiftUI. | [Observation](https://developer.apple.com/documentation/observation) **(Primary)**; [Discover Observation in SwiftUI — WWDC23 10149](https://developer.apple.com/videos/play/wwdc2023/10149/) **(Primary)** |
| **Swift 5.9 — macros, if/switch expressions, ownership (`consume`/`borrow`)** | Macros power `@Observable`, `@Model`, and Swift Testing. `consume`/`borrow` give you more predictable performance at the C++ boundary. | [Write Swift macros — WWDC23 10166](https://developer.apple.com/videos/play/wwdc2023/10166/) **(Primary)**; [What's new in Swift 5.9](https://www.hackingwithswift.com/articles/258/whats-new-in-swift-5-9) **(Secondary)** |
| **Stable C++ interop** | Shipped stable at WWDC23. Everything in §2 builds on this. | [Mix Swift and C++ — WWDC23 10172](https://developer.apple.com/videos/play/wwdc2023/10172/) **(Primary)**; [Swift.org C++ interop](https://www.swift.org/documentation/cxx-interop/) **(Primary)** |
| **Deferred photo processing (`AVCapturePhotoOutput`)** | Shutter stays responsive during high-res captures; processing finishes async. Relevant for tile batch capture. | [Create a more responsive camera experience — WWDC23 10105](https://developer.apple.com/videos/play/wwdc2023/10105/) **(Primary)** |
| **ScrollView refinements — `scrollPosition`, `scrollTargetBehavior`** | Clean API for programmatic scrolling and snap behavior in tile grids and thumbnail strips. | [Beyond scroll views — WWDC23 10159](https://developer.apple.com/videos/play/wwdc2023/10159/) **(Primary)**; [scrollTargetBehavior](https://developer.apple.com/documentation/swiftui/scrolltargetbehavior) **(Primary)** |
| **Swift 5.9 strict concurrency warnings** | Immediate ancestor of Swift 6 errors. | [Concurrency migration](https://developer.apple.com/documentation/swift/migratingtoswift6) **(Primary)** |

**Honest take on SwiftData (iOS 17):** not recommended for a WSI catalog. Slide metadata needs complex queries, fulltext search, and bulk export — use Core Data or a direct SQLite wrapper (e.g., GRDB) instead. SwiftData is fine for app preferences and simple lists.

---

## 7. Known unknowns as of April 2026

- **C++ exception bridging to Swift** — still not stabilized. Wrap in C-ABI error codes.
- **Zero-copy `std::vector` iteration from Swift** — deep copy in release builds is not yet fixed at the language level. Use `Span<T>`.
- **Swift → C++ async / closure callbacks** — only simple C-ABI function pointers are ergonomic today.
- **SwiftUI Observation performance at sustained 60 fps** — theoretically tracked at the property-read level, but empirical performance depends on view graph shape. Measure under load, don't assume.
- **iOS 26 camera API gaps beyond WWDC 25** — the Capture Controls API is the headline. Spatial capture on iPad is rumored for future hardware; no shipped AVFoundation API yet.
- **Third-party SwiftUI snapshot testing integrated with Swift Testing** — ecosystem is still maturing; prefer serialized-state comparison today.

---

## Appendix: consolidated source index

### Primary — Apple & Swift.org

- Swift C++ interop: [overview](https://www.swift.org/documentation/cxx-interop/), [safe interop](https://www.swift.org/documentation/cxx-interop/safe-interop/), [project build setup](https://www.swift.org/documentation/cxx-interop/project-build-setup/), [status](https://www.swift.org/documentation/cxx-interop/status/)
- Swift Evolution: [SE-0337 incremental concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md), [SE-0316 global actors](https://github.com/apple/swift-evolution/blob/main/proposals/0316-global-actors.md), [SE-0406 AsyncStream backpressure](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0406-async-stream-backpressure.md), [using-c++-from-swift vision](https://github.com/apple/swift-evolution/blob/main/visions/using-c%2B%2B-from-swift.md)
- Swift forums: [C++ shared reference ownership](https://forums.swift.org/t/c-shared-reference-ownership/66146), [Safely use AVCaptureSession + Swift 6.2](https://forums.swift.org/t/safely-use-avcapturesession-swift-6-2-concurrency/83622), [AVCaptureSession and concurrency](https://forums.swift.org/t/avcapturesession-and-concurrency/72681)
- Apple docs: [AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession), [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice), [AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput), [AVCameraCalibrationData](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata), [CVMetalTextureCache](https://developer.apple.com/documentation/corevideo/cvmetaltexturecache), [Observation](https://developer.apple.com/documentation/observation), [Swift Testing](https://developer.apple.com/documentation/testing), [WindowGroup](https://developer.apple.com/documentation/swiftui/windowgroup), [DocumentGroup](https://developer.apple.com/documentation/swiftui/documentgroup), [Adopting strict concurrency](https://developer.apple.com/documentation/swift/adoptingswift6)
- Sample code: [AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app), [AVMultiCamPiP](https://developer.apple.com/documentation/avfoundation/cameras_and_media_capture/avmulticampip_capturing_from_multiple_cameras)
- WWDC: [22/10054 Navigation cookbook](https://developer.apple.com/videos/play/wwdc2022/10054/), [22/10102 Metal binaries](https://developer.apple.com/videos/play/wwdc2022/10102/), [22/110351 Data races](https://developer.apple.com/videos/play/wwdc2022/110351/), [22/110565 HDR video in EDR](https://developer.apple.com/videos/play/wwdc2022/110565/), [23/10105 Responsive camera](https://developer.apple.com/videos/play/wwdc2023/10105/), [23/10149 Observation](https://developer.apple.com/videos/play/wwdc2023/10149/), [23/10159 Beyond scroll views](https://developer.apple.com/videos/play/wwdc2023/10159/), [23/10160 Demystify SwiftUI perf](https://developer.apple.com/videos/play/wwdc2023/10160/), [23/10166 Swift macros](https://developer.apple.com/videos/play/wwdc2023/10166/), [23/10172 Mix Swift and C++](https://developer.apple.com/videos/play/wwdc2023/10172/), [24/10179 Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/), [25/205 Discover Metal 4](https://developer.apple.com/videos/play/wwdc2025/205/), [25/245 What's new in Swift](https://developer.apple.com/videos/play/wwdc2025/245/), [25/247 What's new in Xcode 26](https://developer.apple.com/videos/play/wwdc2025/247/), [25/253 Capture controls](https://developer.apple.com/videos/play/wwdc2025/253/), [25/256 What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/), [25/306 SwiftUI perf with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/), [25/319 Cinematic video](https://developer.apple.com/videos/play/wwdc2025/319/), [25/323 Build with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- Apple Newsroom / platform pages: [iPadOS 26 introduces new features](https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-features-that-push-ipad-even-further/), [Apple supercharges developer tools](https://www.apple.com/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/)
- Swift Evolution (iOS 26 era): [SE-0466 Control default actor isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md), [SE-0453 InlineArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0453-vector.md); [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/); [Swift 6.3 @c attribute thread](https://forums.swift.org/t/new-little-gem-in-swift-6-3-85621)

### Secondary — community

- [Hacking with Swift — Swift 6 concurrency](https://www.hackingwithswift.com/swift/6.0/concurrency), [What's new in Swift 5.9](https://www.hackingwithswift.com/articles/258/whats-new-in-swift-5-9)
- [Doug Gregor — Reference Types](https://www.douggregor.net/posts/swift-for-cxx-practitioners-reference-types/), [Error Handling](https://www.douggregor.net/posts/swift-for-cxx-practitioners-error-handling/) (author is a Swift compiler engineer; borderline primary)
- [Lightricks Tech — Efficient image processing, part 2](https://medium.com/lightricks-tech-blog/efficient-image-processing-in-ios-part-2-a96f0343e6f0)
- [Rational Matter — Metal Camera Tutorial Part 2](https://navoshta.com/metal-camera-part-2-metal-texture/)
- [objc.io — Camera Capture on iOS](https://www.objc.io/issues/21-camera-and-photos/camera-capture-on-ios/)
- [Donny Wals — Swift Testing basics](https://www.donnywals.com/swift-testing-basics-explained/), [Profile SwiftUI with Instruments](https://www.donnywals.com/using-instruments-to-profile-a-swiftui-app/)
- [Jesse Squires — ScenePhase pitfalls](https://www.jessesquires.com/blog/2024/06/29/swiftui-scene-phase/)
- [Point-Free — TCA](https://www.pointfree.co/)
