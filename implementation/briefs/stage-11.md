# Stage 11 — UI polish — full bar, calibration sidebar, state-driven UI, toasts

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 03, Stage 04, Stage 10

## 2. Starting state
Scaffolding still live: 10:synchronous-drain-pause
What's built (permanent): Package.swift (+ `CameraKitCxx` + `CameraKitInterop`); `CameraEngine` with full public surface (open/close/background*/pause/resume/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/captureImage/startRecording/stopRecording/getNativePipelineHandle/stateStream/frameResultStream/errorStream/recordingStateStream); full Pass 1 + 2 + 3 + 4 + 5 + 6; `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata` + `FrameSet`; three-pool trio + still-capture pool + encoder pool; C++ `PixelSinkPool` with C-ABI callbacks + Canny stub; D-10 completion-handler re-entrancy guard; `Watchdog` pair + `RecoveryCoordinator` + AE/FPS notifications; self-heal for `CAMERA_IN_USE`; TIFF capture + HEVC MP4 recording; AE frame-rate-range toggle; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz; initial bottom bar with record/capture buttons; tracker thumbnail + debug overlay.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `pause()`, `resume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `captureImage(outputPath:)`, `startRecording(options:)`, `stopRecording()`, `getNativePipelineHandle()`, `stateStream()`, `frameResultStream()`, `errorStream()`, `recordingStateStream()`, `ConsumerRegistry.subscribe(stream:)`, `ConsumerRegistry.registerCallback(stream:callbacks:)`, `ConsumerRegistry.unregister(token:)`.

## 3. Goal
The full UI matches `domain-revised/09-ui-behaviors.md` — split preview, full bottom bar (Settings / Calibrate / Capture / Record / Resolution), expanded bar with ISO/Shutter/Focus/Zoom, color-calibration sidebar with WB/BB Calibrate buttons, recording indicator, capture banner, error toast (non-fatal) + blocking dialog (fatal), state-driven enable/disable across all controls, landscape-right lock.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/CameraView.swift — full bottom bar with five primary buttons (Settings / Calibrate / Capture / Record / Resolution); Expanded bar (ISO / Shutter / Focus / Zoom) sliding up from Settings; Color-calibration sidebar (brightness / contrast / saturation / gamma / per-channel black balance) with WB Calibrate + BB Calibrate buttons; Recording indicator (red dot + timer) when `.recording`; Capture banner with 3s auto-dismiss; Error toast for non-fatal `CameraError` (auto-dismiss); Blocking error dialog for `isFatal == true`; enforce `landscape-right-only` orientation lock; apply Liquid Glass styling per iOS 26 conventions.
- modify: Sources/CameraKit/ViewModel.swift — add WB-Calibrate + BB-Calibrate actions: both call `engine.sampleCenterPatch()` → compute white-balance gains / black-balance offsets → `engine.updateSettings(_:)` (WB path) or `engine.setProcessingParameters(_:)` (BB path); slider coalescing at 60 Hz via a debouncer `Task` (cancels pending partial updates); state-driven `isEnabled` flags for every control derived from `SessionState` + `RecordingState`; `FrameDeliveryStats` long-press overlay hook (stream emitter is stubbed — empty counts until Stage 12).
- create: Sources/CameraKit/CalibrationCompute.swift (permanent) — from `RgbSample` centre patch: gray-world WB gains (1/normalized channel average); black-balance offsets (per-channel mean of a dark patch).
- modify: Sources/CameraKit/Settings.swift — ensure `WhiteBalanceGains` is publicly constructible from a `RgbSample`.
- modify: Sources/CameraKit/CameraView.swift — FPS overlay + latency stats debug surface (bound to `FrameDeliveryStats` — stream is empty this stage; Stage 12 populates).
- modify: Info.plist — orientation lock restricted to landscape-right only.
- create: Tests/CameraKitTests/Stage11Tests.swift — see §8.

## 5. Architecture refs
- architecture/08-ui.md#view-topology
- architecture/08-ui.md#bottom-bar
- architecture/08-ui.md#expanded-bar
- architecture/08-ui.md#color-calibration-sidebar
- architecture/08-ui.md#recording-indicator
- architecture/08-ui.md#capture-banner
- architecture/08-ui.md#state-driven-ui-behavior
- architecture/08-ui.md#error-display
- architecture/08-ui.md#frameresult-display
- architecture/08-ui.md#debug-surface-development-builds-only
- architecture/07-settings.md#calibration-flows
- architecture/07-settings.md#settings-conflict-cases
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/09-ui-behaviors.md
- domain-revised/03-camera-control.md
- domain-revised/10-api-contract.md
- domain-revised/12-unresolved.md

## 7. Contracts & invariants
- WB Calibrate: `sampleCenterPatch()` → gray-world `WhiteBalanceGains = 1 / normalizeChannelAverages(sample)` → `updateSettings(whiteBalance: .custom(gains))`.
- BB Calibrate: `sampleCenterPatch()` on a dark patch → `ProcessingParameters.blackBalance = sample` → `setProcessingParameters(_:)`.
- Slider coalescing: a per-control debouncer `Task` issues at most one `updateSettings` / `setProcessingParameters` per 60 Hz frame; cancels pending partial updates.
- State-driven enable/disable: every control's `isEnabled` binding derives from `SessionState` + `RecordingState`; e.g. Record is disabled unless `.streaming`, Capture is disabled while `.recording`, Resolution is disabled while `.recording` per U-18 and domain 09.
- Error display: non-fatal `CameraError` → transient toast (auto-dismiss ≥ 3s); fatal → blocking dialog (only Reset / Report options).
- FrameResult display: scanning animation binds to `SessionState` / `isAdjustingFocus`, not to `focusDistance` nilness (ui×state J4 resolution).
- Orientation is locked to landscape-right via Info.plist + the view controller's `supportedInterfaceOrientations`.
- `FrameDeliveryStats` long-press overlay is stubbed — the stream is not populated until Stage 12.

## 8. Tests to write
- TESTABLE: 11:wb-calibrate-applies-computed-gains — fake `sampleCenterPatch()` returns `RgbSample(r: 0.5, g: 1.0, b: 0.8)`; WB Calibrate action computes `WhiteBalanceGains` = gray-world reciprocal; observes `updateSettings(whiteBalance: .custom(...))` called with those gains.
- TESTABLE: 11:bb-calibrate-updates-processing-params — fake `sampleCenterPatch()` returns a dark-patch sample; BB Calibrate triggers `setProcessingParameters(blackBalance: sample)`.
- TESTABLE: 11:slider-coalescing-60hz — rapid 240 Hz slider input over 1 second produces ≤ 61 engine calls (60 Hz debounce tolerance); final committed value equals the last slider reading.
- TESTABLE: 11:state-driven-control-enable-disable — for each of (`.closed`, `.opening`, `.streaming`, `.paused`, `.closing`, `.recording`), assert the expected `isEnabled` map across Record / Capture / Resolution / Settings / Calibrate.
- TESTABLE: 11:non-fatal-error-shows-toast — emit a non-fatal `CameraError`; ViewModel's `currentToast` property becomes non-nil for ≥ 3s then clears.
- TESTABLE: 11:fatal-error-shows-blocking-dialog — emit `isFatal = true`; ViewModel's `fatalDialog` property becomes non-nil and does not auto-dismiss.
- TESTABLE: 11:scanning-animation-binds-to-session-state — not to `focusDistance` nilness; a frame with numeric `focusDistance` but `SessionState` indicates scanning → scanning animation visible (ui×state J4 resolution).
- HITL: 11:full-bar-and-sidebar-match-domain-09 — visual sweep against `domain-revised/09-ui-behaviors.md` reference; device: iPad Pro M1.
- HITL: 11:liquid-glass-and-landscape-lock — rotate device through every orientation; UI remains landscape-right; Liquid Glass visual treatment applied per iOS 26; device: iPad Pro M1.
- DEFERRED: 11:accessibility-voiceover-pass — VoiceOver labels exist on every interactive control; evidence recorded manually.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL tests confirmed on iPad Pro M1; visual evidence recorded.
- [ ] DEFERRED VoiceOver pass recorded.
- [ ] `grep -rn '10:synchronous-drain-pause' Sources/` ≥1 hit (no new scaffolds introduced; existing one still live).

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage1[01]Tests"` and full sweep.
- Scaffold inventory: only `10:synchronous-drain-pause` live.
- Device smoke on iPad Pro M1: visual pass across `domain-revised/09-ui-behaviors.md`; stress sliders for coalescing; force non-fatal + fatal errors via debug toggles; VoiceOver sweep.
- Screenshot comparison: side-by-side against a reference screenshot set (store under `measurements/stage-11/screenshots/`).

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): full bottom bar (Settings / Calibrate / Capture / Record / Resolution); Expanded bar (ISO / Shutter / Focus / Zoom); color-calibration sidebar with WB/BB Calibrate; recording indicator + timer; capture banner; error toast + blocking dialog; state-driven enable/disable across all controls; landscape-right orientation lock; Liquid Glass styling; slider debouncer; scanning-animation binding to `SessionState`; `CalibrationCompute` helpers; `FrameDeliveryStats` long-press overlay stub.
- Adds (public API): (none — UI-only stage).
- Evidence: HITL 11:full-bar-and-sidebar-match-domain-09, 11:liquid-glass-and-landscape-lock; DEFERRED 11:accessibility-voiceover-pass — `measurements/stage-11/ui.md`.
