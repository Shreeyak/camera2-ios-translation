# 07 — Settings

Primary-owner file for the **settings model**: partial-update merge, ISO/exposure coupling,
processing-parameter update path, persistence. Hardware commit windows are in
`03-camera-session.md` §Configuration windows; UI slider coalescing is in `08-ui.md`.

---

## Merge model

`CameraSettings` is a partial-update shape — every field is optional; a null field means
"do not change" per `domain-revised/03-camera-control.md` §Settings Model. On every
`updateSettings(_:)` call the engine actor:

1. Loads the **persisted snapshot** (the authoritative "current" values).
2. Overlays the incoming non-nil fields.
3. Evaluates coupling rules (below).
4. Commits the merged snapshot to the hardware via `sessionQueue` per
   `03-camera-session.md` §Configuration windows.
5. On successful commit, writes the merged snapshot back to persistence.

The merge is synchronous inside the engine actor; the hardware commit hops to
`sessionQueue` with a timeout per ADR-30 but does not block the actor's mailbox.

`SETTINGS_CONFLICT` rejections (see §Coupling rule 3) happen at step 3 and cause the merge
to abort with `EngineError.settingsConflict`; no state transition, no retry, persistence
is not mutated (domain 06 §Synchronous call rejection).

---

## ISO + exposure coupling

Per `domain-revised/03-camera-control.md` §ISO and Exposure Coupling. Applied **after merge**
on the engine actor:

### Rule 1 — Auto is contagious

If `isoMode == .auto` **or** `exposureMode == .auto` after merge, both resolve to `.auto`.
Any explicit `iso` / `exposureTimeNs` value on the auto branch is ignored for that call.

### Rule 2 — Auto wins over manual

If one mode is `.auto` and the other `.manual` after merge, both resolve to `.auto`.
Equivalent to Rule 1 stated across asymmetric merges — the rule exists separately in the
domain for clarity.

### Rule 3 — Manual latches from last sensor readback

If transitioning to manual and only one of `iso` / `exposureTimeNs` is provided:
- The unspecified partner is auto-filled from the most recent `DeviceStateSnapshot` per
  `03-camera-session.md` §Device capability checks at startup.
- If no snapshot has been received yet (pre-first-frame window), fail with
  `EngineError.settingsConflict(reason: "no sensor readback available")`.

The engine stores the last `DeviceStateSnapshot` in its actor state; it is updated by the
KVO-driven `AsyncStream<DeviceStateSnapshot>` per `02-concurrency.md` §KVO → AsyncStream
adapter.

### Commit shape

After merge + coupling, the resulting pair is committed as exactly one of:
- `(continuousAutoExposure)` — both auto.
- `setExposureModeCustom(durationNs: ..., iso: ...)` — both manual; coupled commit via
  AVFoundation's single API per `ios-platform-guide/04-avfoundation.md` §Device configuration
  windows.

There is no mode where ISO is manual and exposure is auto (or the reverse) — this is
structurally enforced by AVFoundation's API shape (`03-camera-session.md` §ISO and exposure
coupling).

---

## Focus

`focusMode == .auto` commits `continuousAutoFocus`. `focusMode == .manual` commits
`setFocusModeLocked(lensPosition:)` with `Float(focusDistance ?? lastLensPosition)` per D-07.

During auto scanning, the engine publishes `FrameResult.focusDistance == nil` per domain
03 §Focus. The UI reflects this by showing a scanning indicator per `08-ui.md` §FrameResult
display.

---

## White balance

Modes map per `03-camera-session.md` §White balance:
- `.auto` → `continuousAutoWhiteBalance`.
- `.locked` → `whiteBalanceLocked` (freezes current auto-computed gains).
- `.manual` → `setWhiteBalanceModeLocked(gains:)` with per-channel clamping per G-10.

Manual gain inputs are a three-tuple `(red, green, blue)`.

---

## Zoom / EV / minor settings

Each commits inside the same `lockForConfiguration()` window as the primary settings
change.
- `zoomRatio` → `device.videoZoomFactor = ratio`. Clamped to
  `[1.0, device.maxAvailableVideoZoomFactor]`.
- `evCompensation` → `device.setExposureTargetBias(_:)`. Only effective in auto mode per
  domain 03 §EV Compensation.

---

## ProcessingParameters — GPU shader parameters

Separate from `CameraSettings`. Non-nullable, fully populated; no merge rule — every call
replaces the snapshot wholesale:

```
CameraEngine.setProcessingParameters(_ params: ProcessingParameters)
```

### Processing order

Applied sequentially in the Pass 2 compute kernel per `04-metal-pipeline.md` §Command graph
step 4. Order departs from the Android-source chain recorded in domain 03 §GPU Color
Processing Parameters; black balance applies last instead of first per **D-18** below.

1. Brightness — piecewise formula; positive branch power curve, negative branch linear
   scale.
2. Contrast — piecewise sigmoid around 0.5 midpoint.
3. Saturation — luma-based mixing using `constants.md#COLOR_LUMA_WEIGHT_R / _G / _B` in
   RGBA channel order (G-18).
4. Gamma — power law `output = input^(1/gamma)`, gamma clamped at `> 0.0`.
5. Black balance — subtract `blackR`, `blackG`, `blackB` per channel; clamp to `[0, 1]`.

### Update path

- Slider input in `08-ui.md` coalesces at the Hz rate and calls
  `engine.setProcessingParameters(_:)`.
- Engine actor takes `OSAllocatedUnfairLock<UniformStorage>`, writes the new struct,
  releases.
- Pass 2 on the next frame reads the lock, snapshots into the per-frame `MTLBuffer`, and
  encodes (`04-metal-pipeline.md` §Shader uniforms).
- `FrameSet.processing` for that frame carries the same snapshot so consumers see exactly
  the parameters that produced the frame.

No hardware commit, no `sessionQueue` hop — processing parameters do not touch
`AVCaptureDevice`.

---

## Persistence

Settings (`CameraSettings`) and processing parameters (`ProcessingParameters`) are persisted
to local storage on every successful update per `domain-revised/03-camera-control.md`
§Settings Persistence.

### Storage shape

`UserDefaults` (standard domain) keyed under a module-scoped prefix (e.g.
`"com.cambrian.camera.v1.settings"` / `".processingParameters"`). `UserDefaults` stores all
field types in both structs natively, including `Double` and `Int64`.

Serialization: JSON-encode via `Codable`. Both structs are `Codable`. Partial `CameraSettings`
is serialized as a fully-populated snapshot — the persisted value is always the resolved
"current" state, never a partial. `ProcessingParameters` is always fully populated by API
contract.

### Load path

- `open()` (`03-camera-session.md` §Session object lifetime): after device acquisition +
  format selection, engine loads persisted `CameraSettings` and `ProcessingParameters`;
  applies via the normal merge + commit + shader-update paths before transitioning to
  `.streaming`.
- `getPersistedProcessingParameters()`: returns the current persisted
  `ProcessingParameters?` without requiring an active session. Implemented as a static /
  nonisolated accessor so the UI can pre-populate sliders before `open()`. The engine
  actor does not need to be alive.

### Write path

After a successful merge commit, the engine writes the new snapshot to `UserDefaults`. On
`SETTINGS_CONFLICT`, no write occurs. No explicit `synchronize` call needed (`UserDefaults`
persists asynchronously; `open()` reads the latest committed value).

---

## Frame-result heartbeat

Per domain 02-frame-delivery §Frame Result Heartbeat, the engine emits `FrameResult` at
`constants.md#FRAME_RESULT_HEARTBEAT_HZ` — one per
`constants.md#FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES` frames at the target frame rate. The
payload is derived from the most-recent `DeviceStateSnapshot` (KVO stream), not from the
incoming `CameraSettings` — the hardware may not apply settings exactly as requested (domain
09 §FrameResult Display).

Delivered via `CameraEngine.frameResultStream()` — `.bufferingNewest(1)` per ADR-22
(frame-rate stream). The UI layer consumes on `@MainActor` per ADR-28 / ADR-21.

`focusDistance` is `nil` whenever `device.isAdjustingFocus == true`; else
`Double(device.lensPosition)`.

---

## Calibration flows

### White-balance calibrate

Driven by `08-ui.md` §Color calibration sidebar. The UI calls `engine.sampleCenterPatch()`
to read mean R, G, B; computes the gains needed to equalize them; then calls
`engine.updateSettings(.init(wbMode: .manual, wbGainR: ..., wbGainG: ..., wbGainB: ...))`.
The engine does not embed the gain-computation math — that is UI logic.

### Black-balance calibrate

Same shape: UI samples center patch, computes per-channel offsets (`blackR`, `blackG`,
`blackB`), and calls `engine.setProcessingParameters(...)`. Again, gain computation is UI
logic; the engine only applies.

---

## Settings-conflict cases

Per domain 10 §CameraSettings + §ErrorCode, `SETTINGS_CONFLICT` covers:
- Rule 3 failure (manual-only field supplied pre-first-readback).
- Non-manual fields supplied while in non-matching mode (e.g. `iso: 400` without
  `isoMode: .manual` after merge). Treated as a conflict only if the mode after merge is
  not manual and an explicit numeric value is present; the architecture is lenient in the
  reverse direction (a nil numeric value in manual mode is filled from last readback per
  Rule 3).
- Focus distance outside `[0.0, 1.0]`.
- White-balance gain below 1.0 (G-10).

`updateSettings` throws `EngineError.settingsConflict(reason:)` with a human-readable
reason; the error surfaces as `ErrorCode.settingsConflict` on `errorStream` only if the
caller re-raises through the UI — `SETTINGS_CONFLICT` is a synchronous rejection per domain
06 §Synchronous call rejection, not a state-machine event.

---

## D-18 — Black balance applied last (post-gamma)

Consequential. Owning file: `07-settings.md` (this file). Cross-references
`04-metal-pipeline.md` §Command graph step 4.

### Context

`domain-revised/03-camera-control.md` §GPU Color Processing Parameters records the Android
source as applying black balance first (BB → Br → Co → Sa → Ga). The motivation in the
source pipeline is that BB acts as a sensor-floor offset on linear capture data prior to
color-space work. In this architecture, Pass 1 (`04-metal-pipeline.md` §Passes) hands Pass
2 a YUV→RGB-converted signal already in `[0, 1]` working RGBA16F, so the linear-sensor-data
assumption that motivates source-order BB does not apply.

### Options

1. Match the Android source: BB → Br → Co → Sa → Ga. Faithful to the upstream shader;
   preserves the "subtract sensor-floor offset before color work" intent that no longer
   matches this pipeline's Pass 1 output.
2. BB last: Br → Co → Sa → Ga → BB. Treats `blackR/G/B` as a final-stage per-channel
   offset on the display-encoded signal.

### Decision

Option 2. Pass 2 applies BB after gamma as a per-channel post-grading offset; the four
BCSG steps run on the working RGBA16F signal first, then BB subtracts and clamps to
`[0, 1]`. `blackR/G/B` API shape, range, and persistence schema are unchanged
(§ProcessingParameters table); only the order in which the shader applies them differs.

### Consequences

- §Black-balance calibrate UI math operates on the post-gamma signal. Calibration values
  computed under the source-order chain are not numerically portable; the calibration flow
  re-samples and re-computes from current frames, so no migration step is required.
- Domain ↔ architecture order divergence is recorded only in this D-## entry;
  `domain-revised/03-camera-control.md` remains the faithful description of the Android
  source.
- `04-metal-pipeline.md` §Command graph step 4 cites this D-## as the authority for shader
  order.

### Reversibility

Single-line shader-step reorder; no impact on `ProcessingParameters` shape, persistence
schema, or UI surface. Reverting requires invalidating any persisted `blackR/G/B` produced
under the divergent chain (calibration re-run by the user).
