# Stage 01 — Walking skeleton — bare natural preview on screen

## 1. Frontmatter
Type: FEATURE
Depends on: (none)

## 2. Starting state
Scaffolding still live: (none)
What's built (permanent): (none)
Public API exposed so far: (none)

## 3. Goal
The user launches the app and sees a live camera preview filling the screen, with an empty bottom bar — no color processing, no recording, no controls wired.

## 4. Files to create / modify / delete
- create: Package.swift (permanent) — transplanted from `architecture/api-skeletons/Package.swift`; single `CameraKit` library target + unit test target using `swift-testing`.
- create: Sources/CameraKit/CameraEngine.swift (permanent) — actor `CameraEngine` per ADR-02; implements `init(device:consumers:)`, `open(configuration:)`, `close()`, `stateStream()` only. Other methods remain `fatalError("Stage N")` stubs.
- create: Sources/CameraKit/CameraSession.swift (permanent) — `AVCaptureSession` configuration driven on `sessionQueue` (ADR-07); wires `.builtInWideAngleCamera` back-facing (D-08), largest 4:3 format at 30fps (G-17), landscape-right rotation 90° via `AVCaptureConnection.videoRotationAngle` (ADR-17), `AVCaptureVideoDataOutput` with lossless 8-bit biplanar YUV (CAPTURE_PIXEL_FORMAT).
- create: Sources/CameraKit/CaptureDelegate.swift (permanent) — `nonisolated` `AVCaptureVideoDataOutputSampleBufferDelegate` on `delivery` queue (ADR-07, ADR-02); Pass-1 compute encode + commit inline per ADR-10.
- create: Sources/CameraKit/MetalPipeline.swift (scaffolding:01:simple-metal-passthrough) — Pass-1 crop + YUV→RGBA compute shader only; no Pass 2/3/4/5/6; the completion handler does NOT gate on `sessionState` (tracked as `01:skip-completion-guard`).
- create: Sources/CameraKit/TexturePoolManager.swift (scaffolding:01:simple-metal-passthrough) — single IOSurface-backed `naturalTex` via `kCVPixelBufferMetalCompatibilityKey: true`; `CVMetalTextureCache` per ADR-04.
- create: Sources/CameraKit/CaptureDeviceProviding.swift (permanent) — protocol seam per ADR-32; default impl wraps `AVCaptureDevice`; `DeviceStateSnapshot` type defined but KVO stream unused until Stage 03.
- create: Sources/CameraKit/Capabilities.swift (permanent) — `OpenConfiguration`, `SessionCapabilities`, `Size`, `Rect` value types.
- create: Sources/CameraKit/SessionState.swift (permanent) — `SessionState`, `StreamId` enums.
- create: Sources/CameraKit/Errors.swift (permanent) — `EngineError` typed-throws enum per ADR-25 (only `.alreadyOpen`, `.notOpen`, `.cameraUnavailable` variants needed this stage).
- create: Sources/CameraKit/FrameSet.swift (permanent) — `FrameSet` struct stub; full construction arrives in Stage 06.
- create: Sources/CameraKit/Constants.swift (permanent) — mirrors `constants.md` numeric values; Stage 01 uses FRAME_RATE_TARGET_FPS, CAPTURE_PIXEL_FORMAT, WORKING_PIXEL_FORMAT, CAPTURE_DEFAULT_*_PX, CAPTURE_FALLBACK_*_PX, CROP_DEFAULT_*_PX, CAPTURE_ORIENTATION_ANGLE_DEG.
- create: Sources/CameraKit/CameraView.swift (permanent) — SwiftUI root + `UIViewRepresentable<MTKView>` wrapper (ADR-01); empty bottom bar placeholder.
- create: Sources/CameraKit/ViewModel.swift (permanent) — `@Observable @MainActor` ViewModel (ADR-21) holding `CameraEngine`; `for await` on `stateStream()`; `onChange(of: scenePhase)` emits `sessionQueue.async { stop }` on `.background` (scaffolding:01:naive-scenephase-stop — no gate, no `waitUntilScheduled()`, no `beginBackgroundTask`).
- create: Sources/CameraKit/PixelSink.swift (permanent, stub) — `ConsumerRegistry` stub type; no subscribe/register bodies yet (all `fatalError("Stage 06")` / `fatalError("Stage 08")`).
- create: Tests/CameraKitTests/Stage01Tests.swift — see §8.

## 5. Architecture refs
- architecture/01-system-shape.md#swift-module-layout
- architecture/01-system-shape.md#ownership-of-top-level-types
- architecture/01-system-shape.md#dispatch-queues-non-actor-isolation-boundaries
- architecture/01-system-shape.md#package-swift-operative-shape
- architecture/03-camera-session.md#session-object-lifetime
- architecture/03-camera-session.md#device-selection
- architecture/03-camera-session.md#format-selection
- architecture/03-camera-session.md#orientation
- architecture/03-camera-session.md#capture-output-configuration
- architecture/08-ui.md#view-topology
- architecture/08-ui.md#uiviewrepresentable-mtkview-wrappers
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/01-system-purpose.md
- domain-revised/09-ui-behaviors.md
- domain-revised/10-api-contract.md
- domain-revised/12-unresolved.md

## 7. Contracts & invariants
- CameraEngine is the single heavy isolation domain — one actor per lifecycle (ADR-02).
- All `AVCaptureSession` config + `AVCaptureDevice.lockForConfiguration()` runs on `sessionQueue`; never on the engine actor directly (ADR-07).
- `AVCaptureVideoDataOutput` sample-buffer delegate is `nonisolated` on the `delivery` queue; Metal encode + commit inline per frame (ADR-02, ADR-10).
- Device selection is `.builtInWideAngleCamera` back-facing; telephoto / ultra-wide / front are out of scope (D-08).
- Capture format is 8-bit biplanar YUV (lossless preferred) at 30fps; 10-bit and half-float are not supported on `AVCaptureVideoDataOutput` (G-17).
- Orientation is landscape-right via `AVCaptureConnection.videoRotationAngle = 90` (ADR-17).
- `open()` while already open throws `EngineError.alreadyOpen`; caller must `close()` first.
- `stateStream()` uses `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` (ADR-22).
- `CaptureDeviceProviding` is the test seam (ADR-32); production code never constructs `AVCaptureDevice` directly.

## 8. Tests to write
- TESTABLE: 01:engine-open-close-transitions — fake `CaptureDeviceProviding` returning canned formats; `open()` emits `.opening` then `.streaming` on `stateStream()`; a second `open()` throws `EngineError.alreadyOpen`; `close()` emits `.closing` then `.closed`; a third `open()` after close succeeds.
- TESTABLE: 01:capture-device-provider-seam — `CaptureDeviceProviding` protocol returns `SessionCapabilities.supportedFormats` from the fake; production impl is not constructed in the test.
- TESTABLE: 01:largest-4x3-format-selected — fake provider returns a 4:3 format and a 16:9 format at 30fps; the 4:3 format is chosen; no 4:3 present → `CAPTURE_FALLBACK_WIDTH_PX × CAPTURE_FALLBACK_HEIGHT_PX` fallback is selected.
- TESTABLE: 01:landscape-right-rotation-applied — `AVCaptureConnection.videoRotationAngle` is asserted to `CAPTURE_ORIENTATION_ANGLE_DEG` on the session's video data output connection after `open()`.
- HITL: 01:preview-renders-first-frame — app launches; live preview fills the screen within 2s; no color processing visible; empty bottom bar; device: iPad Pro M1.
- DEFERRED: 01:empirical-format-enumeration — record the `AVCaptureDevice.formats` list (capture dimensions, frame-rate ranges, `formatDescription`) on the target hardware during bring-up (Phase-1a measurement per `open-questions.md` §U-08); evidence in `measurements/`.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build --package-path .` passes under Swift 6 language mode + strict concurrency; no new warnings.
- [ ] `swift test --filter Stage01Tests` passes all TESTABLE entries.
- [ ] On iPad Pro M1, HITL test 01:preview-renders-first-frame visually confirmed; evidence recorded.
- [ ] Measurement 01:empirical-format-enumeration recorded under `measurements/`.
- [ ] Every scaffold slug is present as a source comment: `grep -r '01:naive-scenephase-stop' Sources/` and the two `01:simple-metal-passthrough` / `01:skip-completion-guard` greps each return ≥1 hit.

## 11. Verification steps
- Build: `swift build --package-path .`
- Unit tests: `swift test --filter Stage01Tests`
- Scaffold inventory: `grep -rn '01:naive-scenephase-stop\|01:simple-metal-passthrough\|01:skip-completion-guard' Sources/`
- Device smoke test on iPad Pro M1: launch app from Xcode, confirm live preview fills screen, confirm landscape-right orientation, rotate device to portrait (preview stays landscape-right).
- Instruments Time Profiler one-shot capture (30s) on iPad Pro M1 confirming the delivery queue is the one calling `commit`, not the engine actor.

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): Package.swift; `CameraEngine` actor (open/close/stateStream); `CameraSession`; `CaptureDelegate`; `CaptureDeviceProviding` + `DeviceStateSnapshot` types; `Capabilities`, `SessionState`, `StreamId`, `EngineError`, `FrameSet` (stub), `Constants`; `CameraView` + `ViewModel` + MTKView wrapper; `ConsumerRegistry` stub.
- Adds (public API): `CameraEngine.init(device:consumers:)`, `open(configuration:)`, `close()`, `stateStream()`.
- Adds (scaffolding): 01:naive-scenephase-stop, 01:simple-metal-passthrough, 01:skip-completion-guard.
- Evidence: HITL 01:preview-renders-first-frame — record screenshot + brief note under `measurements/stage-01/preview.md`. DEFERRED 01:empirical-format-enumeration — record format list under `measurements/stage-01/formats.md`.
