# 03 — Camera Control

This file specifies the behavioral requirements for camera parameter control — valid ranges,
interaction constraints, and how settings are applied.

---

## Settings Model

Camera settings use a **partial-update (merge) model**. Each `updateSettings()` call provides a
`CameraSettings` object where null fields mean "do not change." The system maintains a persisted
settings state and merges each call's non-null fields before applying the combined state.

Settings are persisted to local storage on every successful update and restored at session open time.

[audit: 09-camera-controls.md §Settings Persistence, 04-pigeon-api.md §CamSettings]

---

## ISO

| Property | Value |
|---|---|
| Mode values | `"auto"` \| `"manual"` |
| Manual range | Device-dependent (read from sensor capabilities) |
| Default | `"auto"` |

In `"auto"` mode, the auto-exposure system controls sensor sensitivity. In `"manual"` mode, the caller provides an explicit integer ISO value.

**Coupling constraint**: ISO mode is coupled to exposure mode (see §ISO and Exposure Coupling).

[audit: 09-camera-controls.md, 04-pigeon-api.md §CamSettings]

---

## Exposure

| Property | Value |
|---|---|
| Mode values | `"auto"` \| `"manual"` |
| Manual field | `exposureTimeNs`: sensor exposure duration in nanoseconds |
| Default | `"auto"` |

In `"auto"` mode, the auto-exposure system controls the shutter duration. In `"manual"` mode, the caller provides the exact exposure duration in nanoseconds.

**Coupling constraint**: Exposure mode is coupled to ISO mode (see §ISO and Exposure Coupling).

[audit: 09-camera-controls.md, 04-pigeon-api.md §CamSettings]

---

## ISO and Exposure Coupling

ISO and exposure share a single auto-exposure enable flag in the underlying camera system. The following rules are enforced **after merging** the incoming settings onto the persisted state:

**Rule 1 — Auto is contagious:** If either `isoMode` or `exposureMode` is `"auto"` after merge, both are resolved to `"auto"`.

**Rule 2 — Auto wins over manual:** If one is `"auto"` and the other is `"manual"` after merge, both resolve to `"auto"`.

**Rule 3 — Manual latches from last sensor readback:** If transitioning to manual mode and only one field is explicitly set (e.g., setting ISO to manual without specifying exposure):
- The unspecified partner is auto-filled from the most recent sensor readback snapshot.
- If no sensor readback has been received yet (session just started), the call fails with `SETTINGS_CONFLICT` error.

**Consequence:** Switching ISO to auto always switches exposure to auto, and vice versa. There is no mode where ISO is manual and exposure is auto (or the reverse).

[audit: 09-camera-controls.md §ISO + Exposure Coupling, 04-pigeon-api.md §ISO + Exposure Coupling Rules]

---

## Focus

| Property | Value |
|---|---|
| Mode values | `"auto"` \| `"manual"` |
| Manual field | `focusDistance`: lens focus distance, normalized `[0.0, 1.0]` (units are platform-defined; normalized range ensures portability) |
| Auto behavior | Continuous autofocus |
| Default | `"auto"` |

In `"auto"` mode, the autofocus system continuously adjusts focus. In `"manual"` mode, the lens is set to the specified normalized distance value and held fixed.

**`focusDistance` during autofocus**: When autofocus is actively scanning, the `focusDistance` field in `FrameResult` callbacks is null. A numeric value is only reported when focus is locked (settled). See `09-ui-behaviors.md` for UI implications.

[audit: 09-camera-controls.md, 04-pigeon-api.md §CamSettings]

---

## White Balance

| Property | Value |
|---|---|
| Mode values | `"auto"` \| `"locked"` \| `"manual"` |
| Manual fields | `wbGainR`, `wbGainG`, `wbGainB` |

- `"auto"`: The auto-white-balance system continuously adjusts.
- `"locked"`: White balance is frozen at its current auto-computed values.
- `"manual"`: Independent per-channel (R, G, B) gain values are applied.

**White balance calibration flow**: The UI provides a "Calibrate" button that samples the center of the current GPU-processed frame (`sampleCenterPatch()`), computes correction gains, and sets white balance to `"manual"` with those gains. This is a user-driven one-shot calibration, not automatic.

[audit: 09-camera-controls.md, 04-pigeon-api.md §CamSettings, 12-git-archaeology.md §Phase 9]

---

## Zoom

| Property | Value |
|---|---|
| Field | `zoomRatio`: double |
| Minimum | `1.0` (no zoom) |
| Maximum | Device-dependent |
| Default | `1.0` |

Digital zoom is applied by narrowing the field of view. The system uses the most capable zoom API available on the device (direct zoom ratio when supported, crop-region fallback for older devices). The behavioral outcome — a narrowed field of view at the specified magnification — is the same regardless of mechanism.

[audit: 09-camera-controls.md §Zoom Implementation]

---

## EV Compensation

| Property | Value |
|---|---|
| Field | `evCompensation`: integer |
| Unit | EV steps (device-dependent step size) |
| Applicable | Auto-exposure mode only |

When auto-exposure is active, EV compensation biases the exposure target. This field has no effect in manual exposure mode.

[audit: 09-camera-controls.md, 04-pigeon-api.md §CamSettings]

---

## GPU Color Processing Parameters

These parameters control the GPU shader applied to every frame in the processed stream. They are separate from camera hardware settings and take effect without session teardown.

| Parameter | Range | Default | Semantics |
|---|---|---|---|
| `brightness` | `[-1.0, 1.0]` | `0.0` | 0 = no change; piecewise formula |
| `contrast` | `[0.0, 2.0]` | `1.0` | 1.0 = no change; piecewise sigmoid |
| `saturation` | `[-1.0, 1.0]` | `0.0` | 0 = no change; Rec.709 luma weighting |
| `blackR` | unbounded | `0.0` | Per-channel black level offset, red |
| `blackG` | unbounded | `0.0` | Per-channel black level offset, green |
| `blackB` | unbounded | `0.0` | Per-channel black level offset, blue |
| `gamma` | > 0.0 | `1.0` | Gamma exponent; values near 0 are clamped |

**Processing order** (applied sequentially within each frame):
1. Black balance: per-channel offset subtracted, result rescaled to [0,1].
2. Brightness: piecewise formula (positive branch uses power curve; negative branch uses linear scale).
3. Contrast: piecewise sigmoid around 0.5 midpoint.
4. Saturation: luma-based mixing using Rec.709 coefficients (0.2126 R, 0.7152 G, 0.0722 B).
5. Gamma: power law `output = input^(1/gamma)`.

[audit: 05-gpu-opengl.md §Processed Fragment Shader, 04-pigeon-api.md §CamProcessingParams]

---

## AE Convergence Timeout

See `06-error-and-recovery.md` for detection thresholds and recovery behavior.

[audit: 08-error-recovery.md §AE Convergence Timeout, 07-state-machine.md §Key Constants]

---

## Resolution Selection

**Default resolution**: The largest 4:3 aspect ratio resolution supported by the camera sensor.
- Selection criterion: `width × 3 == height × 4` (exact 4:3 ratio).
- Sort order: descending by total pixel count.
- Fallback: 1280×960 if no 4:3 resolution is available.

**Caller-requested resolution** (`setResolution()`):
- Resolution must be in the list returned by `open()` (`supportedSizes`).
- Invalid resolutions are rejected with an error.
- Changing resolution tears down and reinitializes the capture session (not the camera device). See `05-resource-lifecycle.md` for teardown ordering.

[audit: 03-capture-pipeline.md §stream-configuration, 09-camera-controls.md §setResolution Flow]

---

## Capture Mode for Repeating Requests

The system uses different optimization settings for the two types of repeating capture requests:

- **Preview mode**: Optimized for continuous viewfinder use.
- **Recording mode**: Optimized for stable video encoding (see §AE FPS Range and `08-capture-and-recording.md`).

These mode changes are handled transparently by the system — the caller does not need to switch modes manually.

Still image capture does not use a distinct capture request mode. The camera runs its ordinary repeating request; `captureImage()` reads a snapshot of the GPU-processed output at the moment of capture. See `08-capture-and-recording.md` for the full still-capture contract.

[audit: 09-camera-controls.md §capture-mode-templates]

---

## Settings Persistence

Camera settings (`CameraSettings`) and GPU processing parameters (`ProcessingParameters`) are persisted to local storage on every update.

On session open, previously persisted settings are applied to the initial capture request instead of the default (all-auto) configuration. This means the camera reopens with the same settings the user configured in the previous session.

Processing parameters can be read from local storage via `getPersistedProcessingParameters()` without an active streaming session — this allows the UI to initialize sliders to their last-used values before the camera is opened.

[audit: 09-camera-controls.md §Settings Persistence]
