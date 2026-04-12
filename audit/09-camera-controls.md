# 09 — Camera Controls

## CamSettings Fields and Camera2 Mapping

| CamSettings Field | Mode String | Camera2 Key | Notes |
|------------------|------------|-------------|-------|
| `isoMode` + `iso` | `"auto"` | `CONTROL_AE_MODE = ON` | AE controls ISO |
| | `"manual"` | `CONTROL_AE_MODE = OFF`, `SENSOR_SENSITIVITY = iso` | |
| `exposureMode` + `exposureTimeNs` | `"auto"` | `CONTROL_AE_MODE = ON` | AE controls shutter |
| | `"manual"` | `CONTROL_AE_MODE = OFF`, `SENSOR_EXPOSURE_TIME = exposureTimeNs` | |
| `focusMode` + `focusDistanceDiopters` | `"auto"` | `CONTROL_AF_MODE = CONTINUOUS_PICTURE` | |
| | `"manual"` | `CONTROL_AF_MODE = OFF`, `LENS_FOCUS_DISTANCE = focusDistanceDiopters` | 0.0 = optical infinity |
| `wbMode` | `"auto"` | `CONTROL_AWB_MODE = AUTO`, `CONTROL_AWB_LOCK = false` | |
| | `"locked"` | `CONTROL_AWB_LOCK = true` | Freeze current WB |
| | `"manual"` | `CONTROL_AWB_MODE = OFF`, `COLOR_CORRECTION_MODE = TRANSFORM_MATRIX`, `COLOR_CORRECTION_GAINS = RggbChannelVector(R, Ge, Go, B)` | Ge == Go (symmetric Bayer green) |
| `zoomRatio` | n/a | `CONTROL_ZOOM_RATIO` (API 30+) or `SCALER_CROP_REGION` (fallback) | |
| `noiseReductionMode` | n/a | `NOISE_REDUCTION_MODE` | Integer passthrough |
| `edgeMode` | n/a | `EDGE_MODE` | Integer passthrough |
| `evCompensation` | n/a | `CONTROL_AE_EXPOSURE_COMPENSATION` | Only effective when AE is ON |

## ISO + Exposure Coupling (Camera2 Constraint)

Camera2 ties ISO and exposure to a single `CONTROL_AE_MODE` flag:
- `CONTROL_AE_MODE = ON` → AE controls both
- `CONTROL_AE_MODE = OFF` → Manual: set `SENSOR_SENSITIVITY` and `SENSOR_EXPOSURE_TIME` directly

Rules enforced in `updateSettings()` (applied to merged settings before building request):

1. **Auto is contagious**: `iso=auto` → `exposure=auto`; `exposure=auto` → `iso=auto`.
2. **Auto wins over manual**: if either is `"auto"` post-merge, both resolve to `"auto"`.
3. **Manual latches from last AE values**:
   - `iso=manual, exposure=null` → auto-fills `exposureTimeNs` from `lastCaptureSnapshot.exposureTimeNs`.
   - `exposure=manual, iso=null` → auto-fills `iso` from `lastCaptureSnapshot.iso`.
   - If no snapshot yet: returns `SETTINGS_CONFLICT` error.

## Settings Persistence

`SettingsStore` (SharedPreferences) persists:
- `CamSettings` — saved on every `updateSettings()` call.
- `CamProcessingParams` — saved on every `setProcessingParams()` call.

On `open()`, `SettingsStore.loadSettings()` provides `pendingSettings`. On `onConfigured`, if `pendingSettings != null`, it is used for the initial repeating request instead of the default auto-everything request.

`getPersistedProcessingParams()` — loads saved GPU params from SharedPreferences (for UI slider initialization without requiring a streaming session).

`SettingsStore` stores `Double` values as raw IEEE 754 bits in `Long` (via `java.lang.Double.doubleToRawLongBits`) to work around SharedPreferences not supporting `Double` directly.

## CaptureRequest Templates

| State | Template | Reason |
|-------|----------|--------|
| Preview (not recording) | `TEMPLATE_PREVIEW` | Optimized for continuous viewfinder |
| Recording active | `TEMPLATE_RECORD` | Optimized for stable video encode |
| Still capture | `TEMPLATE_STILL_CAPTURE` | One-shot; only for `captureNaturalPicture()` |

## AE FPS Range Selection

Computed in `createRepeatingRequestBuilder()`:

**Preview**: Selects from `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` the range with the highest sustained fps — prefers ranges where `lower == upper` (fixed-fps) to prevent frame rate drops.

**Recording**: Selects range `[targetFps/2, targetFps]` — allows AE to reduce fps in dark scenes (longer exposure) while keeping the upper bound aligned with the encoder fps setting.

Fallback: if no matching range, uses minimum available range.

## Zoom Implementation

```kotlin
settings.zoomRatio?.let { zoom ->
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {  // API 30+
        set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
    } else {
        applyZoomViaCropRegion(this, zoom)  // crop from sensor center
    }
}
```

Crop region fallback:
```kotlin
val cropW = (sensorSize.width() / ratio).toInt()
val cropH = (sensorSize.height() / ratio).toInt()
val offsetX = (sensorSize.width() - cropW) / 2
val offsetY = (sensorSize.height() - cropH) / 2
builder.set(CaptureRequest.SCALER_CROP_REGION, Rect(offsetX, offsetY, offsetX+cropW, offsetY+cropH))
```

## White Balance (Manual Mode — RggbChannelVector)

Camera2 `COLOR_CORRECTION_GAINS` takes `RggbChannelVector(red, greenEven, greenOdd, blue)`.
The Bayer pattern has two green photosites per 2×2 tile. The plugin uses the same `gainG` for both
`greenEven` and `greenOdd` — appropriate since most sensors have symmetric green response.

## CamFrameResult Delivery

Sent at ~3 Hz in `onCaptureCompleted` (every 10th result at 30fps):
```
CamFrameResult(
    iso                   = SENSOR_SENSITIVITY
    exposureTimeNs        = SENSOR_EXPOSURE_TIME
    focusDistanceDiopters = LENS_FOCUS_DISTANCE (null during AF scan)
    wbGainR               = COLOR_CORRECTION_GAINS.red
    wbGainG               = (greenEven + greenOdd) / 2
    wbGainB               = COLOR_CORRECTION_GAINS.blue
)
```

`focusDistanceDiopters` is only populated when `AF_STATE` is `PASSIVE_FOCUSED` or `FOCUSED_LOCKED`.
During `PASSIVE_SCAN`, null is emitted so the UI does not thrash.

## 3A State Logging

`onCaptureCompleted` logs 3A state transitions at INFO level unconditionally:
- `[AE]` transitions: includes ISO and exposure time
- `[AF]` transitions: includes focus distance
- `[AWB]` transitions: includes WB gains (R, Ge, Go, B)

Heartbeat (every 30 results) logs FPS and full 3A summary only when `CambrianCameraConfig.verboseDiagnostics == true`.

## setResolution Flow

`setResolution(handle, width, height)`:
1. Validates `width > 0` and `height > 0`.
2. Calls `backgroundHandler.post { teardownSession(); pipeline.resize(width, height); startCaptureSession() }`.
3. `GpuPipeline.resize()` — calls `nativeGpuResize()` JNI, which recreates FBOs and PBOs at the new size. Wait timeout: 5s.
4. After resize, a new `CaptureSession` is created (session-only teardown, device stays open).
5. State transitions: STREAMING → (teardown) → STREAMING (new session).

Default resolution selection (when not set): largest 4:3 YUV size from `SCALER_STREAM_CONFIGURATION_MAP`.
