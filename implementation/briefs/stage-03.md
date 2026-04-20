# Stage 03 — Camera controls + settings merge + persistence

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 01

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard
What's built (permanent): Package.swift; `CameraEngine` (open/close/backgroundSuspend/backgroundResume/stateStream); `CameraSession`; `CaptureDelegate`; `CaptureDeviceProviding` + `DeviceStateSnapshot` types; `Capabilities`, `SessionState`, `StreamId`, `EngineError`, `FrameSet` (stub), `Constants`; `CameraView` + `ViewModel` + MTKView wrapper; `AsyncWithTimeout`; ManagedAtomic<Bool> gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `stateStream()`.

## 3. Goal
The expanded bottom bar exposes ISO, shutter, focus, and zoom controls. Toggling ISO or shutter to manual auto-switches the other; restarting the app restores the last configured values.

## 4. Files to create / modify / delete
- create: Sources/CameraKit/Settings.swift (permanent) — `CameraSettings` struct with non-nil-field merge; `ProcessingParameters` placeholder (populated in Stage 04); ISO/exposure coupling Rules 1/2/3; `WhiteBalanceMode`, `CameraMode`, `WhiteBalanceGains`, `TrackerQuality`, `CameraPosition` enums.
- create: Sources/CameraKit/SettingsPersistence.swift (permanent) — `UserDefaults` adapter keyed by `"CameraKit.CameraSettings"`; encode/decode via `Codable`; never touched from the engine actor directly — always via a `nonisolated` helper.
- modify: Sources/CameraKit/CameraEngine.swift — implement `updateSettings(_:)`; implement `setResolution(size:)` (session-only teardown + pool resize budget `RESOLUTION_RESIZE_TIMEOUT_SECONDS` — pool resize placeholder until Stage 06 introduces the trio); implement `frameResultStream()` emitting at `FRAME_RESULT_HEARTBEAT_HZ` (every `FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES`).
- modify: Sources/CameraKit/CameraSession.swift — add `lockForConfiguration()`-wrapped commits for ISO (`setExposureModeCustom(durationNs:iso:)`), focus (`setFocusModeLocked(lensPosition:)`), white balance, zoom (`videoZoomFactor`), EV compensation — all on `sessionQueue`.
- create: Sources/CameraKit/KVOAsyncStream.swift (permanent) — `KVO → AsyncStream<DeviceStateSnapshot>` adapter per ADR-14; `Tokens` box owns observation lifetime; emits on every AVCaptureDevice KVO change (ISO, exposureDuration, lensPosition, whiteBalanceGains).
- modify: Sources/CameraKit/CaptureDeviceProviding.swift — `DeviceStateSnapshot` becomes the latched value used by Rule 3 (manual latches from last readback); production impl constructs `KVOAsyncStream` and surfaces its last value.
- modify: Sources/CameraKit/CameraView.swift — expanded bottom bar with ISO / Shutter / Focus / Zoom controls (initial form; polish is Stage 11); bindings via ViewModel.
- modify: Sources/CameraKit/ViewModel.swift — add `@Observable` properties for `CameraSettings` and `DeviceStateSnapshot`; wire sliders to `engine.updateSettings(_:)`; `for await` `frameResultStream()`.
- modify: Sources/CameraKit/Capabilities.swift — include format-supported ISO / exposure-duration ranges in `SessionCapabilities`.
- create: Tests/CameraKitTests/Stage03Tests.swift — see §8.

## 5. Architecture refs
- architecture/03-camera-session.md#configuration-windows
- architecture/03-camera-session.md#iso-and-exposure-coupling
- architecture/03-camera-session.md#focus
- architecture/03-camera-session.md#d-07-focusdistance-maps-1-1-to-lensposition
- architecture/03-camera-session.md#white-balance
- architecture/03-camera-session.md#zoom
- architecture/03-camera-session.md#ev-compensation
- architecture/07-settings.md#merge-model
- architecture/07-settings.md#iso-exposure-coupling
- architecture/07-settings.md#focus
- architecture/07-settings.md#persistence
- architecture/07-settings.md#frame-result-heartbeat
- architecture/02-concurrency.md#kvo-asyncstream-adapter-adr-14
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/03-camera-control.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/10-api-contract.md

## 7. Contracts & invariants
- Merge is non-nil-field overlay; fields left `nil` in the incoming `CameraSettings` are not touched (07-settings.md §Merge model).
- ISO + exposure coupling Rules 1/2/3: toggling ISO or shutter to manual auto-switches the other; Rule 3 latches the inactive side from the most recent `DeviceStateSnapshot` (07-settings.md §ISO + exposure coupling).
- All device commits occur inside a single `lockForConfiguration()` window on `sessionQueue`; `setExposureModeCustom(durationNs:iso:)` structurally enforces coupling (iOS API shape).
- `focusDistance` ∈ [0.0, 1.0] maps 1:1 to `AVCaptureDevice.lensPosition` (D-07, G-11); `FrameResult.focusDistance` is `nil` while AF is scanning.
- KVO observation lifetime is owned by a `Tokens` reference-type box; cancellation on `close()` is deterministic (ADR-14).
- Persisted settings round-trip through `Codable`; the key `"CameraKit.CameraSettings"` is stable.
- `frameResultStream()` uses `.bufferingNewest(1)` (ADR-22); emission cadence `FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES`.
- Internally inconsistent updates throw `EngineError.settingsConflict` without modifying device state.

## 8. Tests to write
- TESTABLE: 03:settings-merge-non-nil-fields — prior settings `{iso: 200, ev: 0}` + incoming `{iso: nil, zoom: 2.0}` → merged `{iso: 200, ev: 0, zoom: 2.0}`; nil preserves prior.
- TESTABLE: 03:iso-shutter-auto-switch — Rule 1 (toggle ISO to manual → shutter becomes manual); Rule 2 (toggle shutter to manual → ISO becomes manual).
- TESTABLE: 03:rule3-manual-latch-from-last-readback — `DeviceStateSnapshot` stream emits ISO=400; caller toggles shutter-manual with null ISO; the ISO committed to the device is 400 (the latched sensor readback).
- TESTABLE: 03:userdefaults-persistence-roundtrip — `CameraSettings` saved via `SettingsPersistence.save` → `SettingsPersistence.load` returns the identical struct; a fresh `UserDefaults` (empty) returns nil.
- TESTABLE: 03:kvo-asyncstream-adapter-emits-on-change — fake `AVCaptureDevice` KVO source; adapter yields one `DeviceStateSnapshot` per KVO change; cancel the `Task` → `Tokens` box is released (observed via weak ref in test).
- TESTABLE: 03:focus-distance-identity — `updateSettings(focusDistance: 0.5)` commits `setFocusModeLocked(lensPosition: 0.5)` through a fake `CaptureDeviceProviding`; `FrameResult.focusDistance` is `nil` when `focusMode == .continuousAutoFocus` and mid-scan.
- TESTABLE: 03:settings-conflict-throws — `updateSettings(iso: 10, shutter: 1_000_000_000)` outside the device's supported ranges throws `EngineError.settingsConflict`; no partial device mutation.
- HITL: 03:iso-slider-updates-exposure-live — move ISO slider; preview luminance changes smoothly; device: iPad Pro M1.
- HITL: 03:restart-restores-settings — set ISO+shutter+focus, quit, relaunch; values restored; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests (`01:*`, `02:*`) pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL tests confirmed on iPad Pro M1; evidence recorded.
- [ ] `grep -rn '04:\|05:\|06:\|07:\|08:\|09:\|10:\|11:\|12:' Sources/` returns 0 hits (no unexpected scaffolds).

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[123]Tests"`
- Scaffold inventory: unchanged from Stage 02 (same two scaffolds live).
- Device smoke on iPad Pro M1: exercise each slider, confirm Rule 1/2/3 coupling visually, force-quit and relaunch to verify persistence, rotate device (still landscape-right-only).
- Persistence check: inspect `UserDefaults.standard.dictionaryRepresentation()` via LLDB between launches; confirm `"CameraKit.CameraSettings"` entry.

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): `Settings` (CameraSettings, ProcessingParameters placeholder, WB/Camera/Tracker/Position enums, WhiteBalanceGains); `SettingsPersistence` (UserDefaults); KVO→AsyncStream adapter + `DeviceStateSnapshot` live value; ISO/exposure/focus/WB/zoom/EV device-commit paths inside `lockForConfiguration()`; frame-result heartbeat emission at 3Hz; expanded bottom bar (initial); resolution-resize session-only teardown (pool resize is placeholder until Stage 06).
- Adds (public API): `updateSettings(_:)`, `setResolution(size:)`, `frameResultStream()`.
- Adds (scaffolding): (none).
- Evidence: HITL 03:iso-slider-updates-exposure-live and 03:restart-restores-settings — `measurements/stage-03/controls.md`.
