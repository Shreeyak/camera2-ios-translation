# Stage 07 — Still image capture (TIFF) + EXIF envelope

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 04

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard, 06:simple-consumer-swift-only
What's built (permanent): Package.swift; `CameraEngine` with open/close/background*/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/stateStream/frameResultStream; Pass 1 + Pass 2 + Pass 4; `OSAllocatedUnfairLock<UniformStorage>` around uniforms; `ProcessingMetadata` + complete `FrameSet`; three-pool trio (natural/processed/tracker) with `POOL_*` config; `ConsumerRegistry` actor with Swift-only `subscribe(stream:) -> AsyncStream<FrameSet>` + `unregister(token:)`; tracker thumbnail + debug overlay UI paths; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `stateStream()`, `frameResultStream()`, `ConsumerRegistry.subscribe(stream:)`, `ConsumerRegistry.unregister(token:)`.

## 3. Goal
Pressing the capture button writes a `.tif` file; the "Image saved: …" banner appears at the bottom of the screen for three seconds. The TIFF opens in Preview/Photos and matches the on-screen processed preview pixel-for-pixel.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/MetalPipeline.swift — add Pass 6 (blit-to-CPU-readable RGBA16F `CVPixelBuffer`) invoked on the capture path only; destination is a CPU-readable pool-dequeued buffer (not the processed pool); `processedTex` is blit-copied from the most recent completed processed frame.
- modify: Sources/CameraKit/StillCapture.swift — implement still-capture orchestration:
  - `ManagedAtomic<Bool>` capture-in-flight guard (scaffolding:07:swift-side-capture-atomic — CAS to `true` on entry; reject with `StillCaptureError.alreadyInFlight` if already true; CAS back to `false` on completion/error); the architecture's target shape is a C++ atomic in the imaging core (D-05) and migrates in Stage 08.
  - CPU-side RGBA16F → RGB8 conversion via `vImage_Buffer` Accelerate routines (avoids banding; honors `COLOR_LUMA_WEIGHT_*` for derivative ops if needed).
  - `CGImageDestinationCreateWithURL` (`.tiff` UTI); standard EXIF dictionary via `kCGImagePropertyExifDictionary`; non-standard fields serialized as a JSON string under `kCGImagePropertyExifUserComment` keyed by `"CamPlugin/v1"` (D-09; JSON schema deferred per `open-questions.md` §U-09).
  - `PHPhotoLibrary.requestAuthorization(for: .addOnly)`; on denial, write to app documents via `FileManager.default.url(for: .documentDirectory, ...)` (graceful fallback per domain 08-capture-and-recording).
- modify: Sources/CameraKit/CameraEngine.swift — implement `captureImage(outputPath:)` routing through `StillCapture`; typed-throws `EngineError.capture(...)` wrapping `StillCaptureError`.
- modify: Sources/CameraKit/CameraView.swift — add capture button to the bottom bar (polish is Stage 11); "Image saved: …" banner with 3s auto-dismiss bound to the engine's capture result.
- modify: Sources/CameraKit/ViewModel.swift — capture-button action calls `engine.captureImage(outputPath:)` on a `Task`; observes success/failure for the banner.
- modify: Sources/CameraKit/TexturePoolManager.swift — add a dedicated still-capture `CVPixelBufferPool` sized for one in-flight capture; CPU-readable (`kCVPixelBufferCPUReadCompatibilityKey: true`) per ADR-06; no shared storage with the processed pool.
- create: Sources/CameraKit/Info.plist.fragment — `NSPhotoLibraryAddUsageDescription` string; included into the host-app `Info.plist` at Stage 01 transplant time.
- create: Tests/CameraKitTests/Stage07Tests.swift — see §8.

## 5. Architecture refs
- architecture/06-capture-and-recording.md#still-image-capture
- architecture/06-capture-and-recording.md#d-05-direct-metal-blit-readback
- architecture/06-capture-and-recording.md#d-09-exif-camplugin-v1-envelope
- architecture/04-metal-pipeline.md#still-capture-readback
- architecture/05-consumers.md#d-15-native-pipeline-pointer-guard
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/08-capture-and-recording.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/10-api-contract.md
- domain-revised/12-unresolved.md

## 7. Contracts & invariants
- Still capture path is direct Metal blit into a CPU-readable `CVPixelBuffer` (D-05); not a `PixelSink` subscription.
- Invariant 7 (concurrency): at most one `captureImage` in flight; guarded by `ManagedAtomic<Bool>` CAS on the Swift side this stage (scaffolding:07:swift-side-capture-atomic); migrates to C++ atomic in Stage 08 with identical CAS semantics (both lock-free).
- TIFF writer uses `CGImageDestination` with `.tiff` UTI; EXIF goes through `kCGImagePropertyExifDictionary`; custom fields under `kCGImagePropertyExifUserComment` keyed by `"CamPlugin/v1"` (D-09). JSON schema finalization is deferred (U-09).
- PhotoLibrary authorization scope is `.addOnly`; denial falls back to app documents. The app's `Info.plist` must declare `NSPhotoLibraryAddUsageDescription` (G-09).
- `MTLTexture.getBytes` is forbidden (ADR-06); all CPU access goes through IOSurface-backed `CVPixelBuffer`.
- No `AVCapturePhotoOutput` (G-09); stills come from the Metal chain, not a separate AVFoundation output.
- Capture completion path does not mutate engine actor state from the completion handler (`01:skip-completion-guard` still in force; full guard arrives in Stage 09).

## 8. Tests to write
- TESTABLE: 07:still-capture-in-flight-guard — spawn two concurrent `captureImage` tasks; first succeeds; second throws `StillCaptureError.alreadyInFlight`; after the first completes, a third `captureImage` succeeds.
- TESTABLE: 07:tiff-round-trip-matches-processed-preview — inject a known processed-frame pattern; call `captureImage`; decode the resulting TIFF back via `CGImageSourceCreateWithURL`; per-pixel 8-bit RGB matches the RGB8 quantization of the processed frame (within ±1 LSB for rounding).
- TESTABLE: 07:exif-envelope-contains-camplugin-v1 — inspect the written TIFF; `kCGImagePropertyExifUserComment` contains a valid JSON string; the JSON parses and has top-level key `"CamPlugin/v1"`.
- TESTABLE: 07:photo-library-authorization-denied-falls-back — fake `PHPhotoLibrary` returning `.denied`; capture writes to `FileManager.default.url(for: .documentDirectory, ...)`; the returned `StillCaptureOutput.path` points there.
- TESTABLE: 07:exif-standard-dictionary-present — `kCGImagePropertyExifDictionary` contains non-empty sensor-metadata entries (ISO, exposureTime, focalLength) populated from the current `CameraSettings` / `DeviceStateSnapshot`.
- TESTABLE: 07:still-capture-uses-dedicated-pool — during capture, the processed-pool high-water-mark does not increase; the still-capture pool is the one that allocates the CPU-readable buffer.
- HITL: 07:tiff-opens-in-preview-and-photos — press capture on device; open the resulting file in Preview and Photos; visual match to on-screen processed preview; device: iPad Pro M1.
- HITL: 07:saved-banner-appears-three-seconds — capture; banner shows path for exactly ~3s and dismisses; device: iPad Pro M1.
- HITL: 07:authorization-dialog-first-capture — on first launch, OS prompts for Photos (Add Only) authorization; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL tests confirmed on iPad Pro M1; evidence recorded.
- [ ] `grep -rn '07:swift-side-capture-atomic' Sources/` ≥1 hit; `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard\|06:simple-consumer-swift-only' Sources/` each ≥1 hit.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-7]Tests"`
- Scaffold inventory: four scaffolds live (`01:simple-metal-passthrough`, `01:skip-completion-guard`, `06:simple-consumer-swift-only`, `07:swift-side-capture-atomic`).
- Device smoke on iPad Pro M1: press capture twice in quick succession (confirm first succeeds, second rejects); approve Photos authorization; confirm file in Photos; toggle to Documents fallback (revoke authorization in Settings) and re-capture.
- Disk inspection: `xxd` the first 64 bytes of the `.tif` file — valid TIFF magic (`II*\0` or `MM\0*`).

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): Pass 6 blit-to-CPU-readable `CVPixelBuffer`; still-capture pool; `StillCapture` orchestrator; CPU-side `vImage_Buffer` RGBA16F→RGB8; `CGImageDestination` TIFF writer; EXIF dictionary + `"CamPlugin/v1"` JSON envelope; `PHPhotoLibrary` `.addOnly` + documents fallback; `NSPhotoLibraryAddUsageDescription` string.
- Adds (public API): `captureImage(outputPath:)`.
- Adds (scaffolding): 07:swift-side-capture-atomic.
- Evidence: HITL 07:tiff-opens-in-preview-and-photos, 07:saved-banner-appears-three-seconds, 07:authorization-dialog-first-capture — `measurements/stage-07/capture.md`.
