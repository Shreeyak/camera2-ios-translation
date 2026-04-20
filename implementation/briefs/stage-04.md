# Stage 04 — Color pipeline + processed preview + sample-center-patch

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 01

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard
What's built (permanent): Package.swift; `CameraEngine` (open/close/backgroundSuspend/backgroundResume/updateSettings/setResolution/stateStream/frameResultStream); `CameraSession` with ISO/shutter/focus/WB/zoom/EV commits inside `lockForConfiguration()`; `CaptureDelegate`; `CaptureDeviceProviding` + KVO→AsyncStream adapter + `DeviceStateSnapshot`; `Capabilities`, `SessionState`, `StreamId`, `EngineError`, `FrameSet` (stub), `Constants`, `Settings` (CameraSettings, ProcessingParameters placeholder, WB/Camera/Tracker/Position enums), `SettingsPersistence`; `CameraView` + expanded bottom bar + `ViewModel` + MTKView wrapper; `AsyncWithTimeout`; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `stateStream()`, `frameResultStream()`.

## 3. Goal
The color-calibration sidebar appears on-screen; sliders for brightness, contrast, saturation, gamma, and per-channel black balance update the right-half processed preview in real-time. Reset returns to identity.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/MetalPipeline.swift — add Pass 2 (color-transform compute kernel) after Pass 1; command graph order per `04-metal-pipeline.md` §Command graph; render into a single shared IOSurface-backed `processedTex` (Stage 04 uses one shared processed texture — the pool trio lands in Stage 06); continue to carry `scaffolding:01:simple-metal-passthrough` comment because Pass 3/4/5/6 are not yet wired; add `scaffolding:04:unlocked-uniforms` comment around the engine writing shader uniforms directly without `OSAllocatedUnfairLock<UniformStorage>`.
- modify: Sources/CameraKit/Settings.swift — populate `ProcessingParameters` with brightness, contrast, saturation, gamma, per-channel black balance, WB gains; `setProcessingParameters(_:)` path + persistence key `"CameraKit.ProcessingParameters"`.
- modify: Sources/CameraKit/SettingsPersistence.swift — add `ProcessingParameters` codable save/load.
- modify: Sources/CameraKit/CameraEngine.swift — implement `setProcessingParameters(_:)` (writes uniforms directly without lock — scaffolding:04:unlocked-uniforms); implement `setCropRegion(_:)` (writes crop uniform for Pass 1); implement `sampleCenterPatch()` via Metal reduction kernel over `processedTex` center `CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX` with trimmed mean at `CENTER_PATCH_TRIM_PERCENT`; implement `getPersistedProcessingParameters()` (nonisolated call through `SettingsPersistence`).
- create: Sources/CameraKit/ColorShaders.metal — Pass 2 color-transform kernel operating in RGBA16F (`WORKING_PIXEL_FORMAT`); identity when all params at defaults.
- create: Sources/CameraKit/CenterPatchKernel.metal — parallel reduction computing trimmed mean over the center patch.
- modify: Sources/CameraKit/CameraView.swift — split preview: left half MTKView natural, right half MTKView processed; color-calibration sidebar with brightness/contrast/saturation/gamma/black-balance sliders + Reset button.
- modify: Sources/CameraKit/ViewModel.swift — bindings for `ProcessingParameters`; call `engine.setProcessingParameters(_:)` on slider change; load persisted params on first appear.
- modify: Sources/CameraKit/TexturePoolManager.swift — add a single shared `processedTex` alongside `naturalTex`; still one shared IOSurface each (no pool trio yet — Stage 06).
- create: Tests/CameraKitTests/Stage04Tests.swift — see §8.

## 5. Architecture refs
- architecture/04-metal-pipeline.md#command-graph
- architecture/04-metal-pipeline.md#working-texture-format
- architecture/04-metal-pipeline.md#texture-cache
- architecture/04-metal-pipeline.md#shader-uniforms
- architecture/04-metal-pipeline.md#center-patch-sampling
- architecture/04-metal-pipeline.md#d-02-texture-storage-mode-shared-start-simple
- architecture/07-settings.md#processingparameters-gpu-shader-parameters
- architecture/07-settings.md#persistence
- architecture/08-ui.md#view-topology
- architecture/08-ui.md#color-calibration-sidebar

## 6. Domain refs
- domain-revised/02-frame-delivery.md
- domain-revised/04-concurrency-invariants.md
- domain-revised/07-performance-budgets.md
- domain-revised/09-ui-behaviors.md

## 7. Contracts & invariants
- Working texture format is `WORKING_PIXEL_FORMAT` (rgba16Float) end-to-end for Pass 2 (ADR-05); no 8-bit quantization in the color-transform chain.
- Texture storage mode is `.shared` from Stage 01 onwards (D-02, ADR-20 start-simple default); IOSurface-backed via `kCVPixelBufferMetalCompatibilityKey: true` + `kCVPixelBufferIOSurfacePropertiesKey: [:]`.
- `processedTex` is a single shared IOSurface-backed texture this stage; the `CVPixelBufferPool` trio lands in Stage 06.
- `04:unlocked-uniforms` — engine writes shader uniforms directly; torn writes are possible under rapid slider motion and perceptually benign this stage. The lock (Inv 6) is mandatory for correctness and is installed in Stage 05.
- `sampleCenterPatch()` reads from `processedTex` center `CENTER_PATCH_SIZE_PX × CENTER_PATCH_SIZE_PX`, computes trimmed means with `CENTER_PATCH_TRIM_PERCENT` discarded top/bottom; returns `RgbSample`.
- Identity `ProcessingParameters` produces a byte-for-byte copy of the natural path on `processedTex` (modulo `WORKING_PIXEL_FORMAT` quantization) — the golden-frame test pins this.
- `MTLTexture.getBytes` is forbidden on this path — all CPU access goes through IOSurface-backed `CVPixelBuffer` (ADR-06).

## 8. Tests to write
- TESTABLE: 04:color-pipeline-golden-frame — inject a known-RGBA test pattern via a fake `CaptureDelegate`; apply identity `ProcessingParameters`; assert `processedTex` bytes (read through IOSurface) match the natural-pass output within rgba16Float quantization ULP; apply brightness=+0.2; assert luminance shift matches the closed-form expected output.
- TESTABLE: 04:processing-params-persistence-roundtrip — set non-default `ProcessingParameters`, call `getPersistedProcessingParameters()`, quit-and-restart simulator; load yields the same struct.
- TESTABLE: 04:center-patch-trimmed-mean — inject a `processedTex` with a known gradient; `sampleCenterPatch()` returns the analytic trimmed mean to within 1 ULP of rgba16Float; gradient with 10% outliers confirms `CENTER_PATCH_TRIM_PERCENT` discard.
- TESTABLE: 04:set-crop-region-updates-uniform — `setCropRegion(Rect(...))` writes the expected values into the Pass-1 crop uniform (inspect via test-only accessor on `MetalPipeline`).
- HITL: 04:color-slider-visual-correctness — move brightness/contrast/saturation/gamma/black-balance sliders; right-half preview updates live; Reset returns identity; device: iPad Pro M1.
- HITL: 04:rapid-slider-stress-sees-occasional-torn-frame — deliberately stress sliders at 60 Hz; a single-frame visual glitch may appear (scaffold `04:unlocked-uniforms` — fix in Stage 05); device: iPad Pro M1.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests (`01:*`, `02:*`, `03:*`) pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL 04:color-slider-visual-correctness visually confirmed on iPad Pro M1.
- [ ] HITL 04:rapid-slider-stress-sees-occasional-torn-frame recorded (qualitative; scaffold documented).
- [ ] `grep -rn '04:unlocked-uniforms\|01:simple-metal-passthrough\|01:skip-completion-guard' Sources/` each ≥1 hit.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-4]Tests"`
- Scaffold inventory: three scaffolds live (`01:simple-metal-passthrough`, `01:skip-completion-guard`, `04:unlocked-uniforms`).
- Device smoke on iPad Pro M1: verify split preview, exercise all sliders, press Reset, run 10-second slider-stress session and record any torn-frame incidents.
- Instruments: Metal System Trace capturing 10 seconds of Pass 1 + Pass 2 on iPad Pro M1 confirming per-frame latency below `FRAME_LATENCY_BUDGET_MS`.

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): Pass 2 color-transform kernel; single shared IOSurface-backed `processedTex`; split preview UI + color-calibration sidebar; `ProcessingParameters` complete definition + persistence; `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`; `CenterPatchKernel`.
- Adds (public API): `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`.
- Adds (scaffolding): 04:unlocked-uniforms.
- Evidence: HITL 04:color-slider-visual-correctness and 04:rapid-slider-stress-sees-occasional-torn-frame — `measurements/stage-04/color.md`.
