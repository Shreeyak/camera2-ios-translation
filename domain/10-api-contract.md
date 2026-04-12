# 10 — API Contract

This file describes the functional interface between the application layer and the camera plugin.
All names below are behavioral descriptions, not implementation identifiers. The interface is
structured as: host methods (application calls into the plugin) and callbacks (plugin calls back to
the application).

---

## Data Types

### Size (width × height)
A discrete frame dimension: integer width and height in pixels.

[audit: 04-pigeon-api.md §CamSize]

---

### CameraSettings
A partial-update settings object. Every field is optional (null means "do not change this setting").

| Field | Type | Values / Range | Description |
|---|---|---|---|
| `isoMode` | string? | `"auto"` \| `"manual"` | Whether sensor sensitivity is controlled by auto-exposure or set manually |
| `iso` | int? | device-dependent | Sensor sensitivity in ISO units (manual mode only) |
| `exposureMode` | string? | `"auto"` \| `"manual"` | Whether exposure duration is auto or set manually |
| `exposureTimeNs` | int? | device-dependent | Sensor exposure duration in nanoseconds (manual mode only) |
| `focusMode` | string? | `"auto"` \| `"manual"` | Whether focus is continuously driven or set manually |
| `focusDistanceDiopters` | double? | `0.0` = optical infinity | Lens focus distance in diopters (manual mode only) |
| `wbMode` | string? | `"auto"` \| `"locked"` \| `"manual"` | White balance mode |
| `wbGainR` | double? | — | Red channel gain (manual white balance only) |
| `wbGainG` | double? | — | Green channel gain (manual white balance only) |
| `wbGainB` | double? | — | Blue channel gain (manual white balance only) |
| `zoomRatio` | double? | `1.0` = no zoom | Digital zoom factor |
| `noiseReductionMode` | int? | device-dependent | Sensor noise reduction intensity passthrough |
| `edgeMode` | int? | device-dependent | Edge enhancement level passthrough |
| `evCompensation` | int? | device-dependent | Auto-exposure EV compensation steps (auto AE only) |

**Partial-update semantics:** A null field leaves the current value unchanged. The system merges each call's non-null fields onto the persisted settings state before applying.

[audit: 04-pigeon-api.md §CamSettings]

---

### ProcessingParameters
GPU color-processing shader parameters. All fields are required (no nulls).

| Field | Type | Range | Default | Description |
|---|---|---|---|---|
| `brightness` | double | `[-1.0, 1.0]` | `0.0` | Brightness adjustment (0 = no change) |
| `contrast` | double | `[0.0, 2.0]` | `1.0` | Contrast multiplier (1.0 = no change) |
| `saturation` | double | `[-1.0, 1.0]` | `0.0` | Saturation adjustment (0 = no change) |
| `blackR` | double | — | `0.0` | Black level offset, red channel |
| `blackG` | double | — | `0.0` | Black level offset, green channel |
| `blackB` | double | — | `0.0` | Black level offset, blue channel |
| `gamma` | double | — | `1.0` | Gamma exponent (1.0 = no change) |

[audit: 04-pigeon-api.md §CamProcessingParams]

---

### SessionCapabilities
Returned by `open()` to describe what the opened session supports.

| Field | Type | Description |
|---|---|---|
| `supportedSizes` | `Size[]` | All supported capture resolutions |
| `previewTextureId` | int | Opaque identifier for the GPU-processed preview surface, usable by the UI layer |
| `naturalTextureId` | int | Opaque identifier for the natural (unprocessed) preview surface (0 if natural stream disabled) |
| `naturalWidth` | int | Natural stream pixel width (0 if disabled) |
| `naturalHeight` | int | Natural stream pixel height (0 if disabled) |

[audit: 04-pigeon-api.md §CamCapabilities]

---

### SessionState
An enum emitted on every state transition.

| Value | Meaning |
|---|---|
| `"opening"` | The system is acquiring the camera device |
| `"streaming"` | Frames are flowing; session is active |
| `"recovering"` | A non-fatal error was detected; retry is scheduled |
| `"paused"` | The capture session is torn down; the device is retained |
| `"error"` | A fatal error occurred; no further recovery |
| `"closed"` | The session has been fully released |

[audit: 04-pigeon-api.md §CamStateUpdate, 07-state-machine.md §States]

---

### ErrorCode
An enum identifying the category of error.

| Code | Fatal? | Meaning |
|---|---|---|
| `CAMERA_NOT_FOUND` | yes | No camera matching the requested ID exists |
| `CAMERA_IN_USE` | no | Camera is held by another process |
| `PERMISSION_DENIED` | yes | User denied camera access |
| `CAMERA_ACCESS_ERROR` | no | General camera access failure |
| `CAMERA_DISCONNECTED` | no | Camera hardware disconnected |
| `CONFIGURATION_FAILED` | no | Capture session configuration was rejected |
| `CAPTURE_FAILURE` | no | Consecutive hardware-level frame capture failures |
| `RECORDING_START_FAILED` | yes | Video encoder or muxer initialization failed |
| `RECORDING_FAILED` | yes | Recording pipeline failed mid-session |
| `RECORDING_TRUNCATED` | no | EOS drain timed out; recording may be incomplete |
| `FRAME_STALL` | no | No frames delivered for the stall timeout duration |
| `MAX_RETRIES_EXCEEDED` | yes | Retry budget exhausted after repeated non-fatal errors |
| `UNKNOWN_ERROR` | no | Unclassified error |
| `SETTINGS_CONFLICT` | no | Settings combination is internally inconsistent |
| `INVALID_FORMAT` | no | Requested file format is not supported |
| `FPS_DEGRADED` | no | Sustained frame rate has dropped below the acceptable threshold |
| `AE_CONVERGENCE_TIMEOUT` | no | Auto-exposure has not converged within the timeout window |
| `INVALID_STATE` | no | Operation attempted in an incompatible session state |
| `HAL_ERROR` | no | Camera hardware abstraction layer reported an error |

[audit: 04-pigeon-api.md §CamErrorCode]

---

### Error
A structured error notification.

| Field | Type | Description |
|---|---|---|
| `code` | ErrorCode | The error category |
| `message` | string | Human-readable detail |
| `isFatal` | bool | If true, no further recovery is possible; the session is in terminal error state |

[audit: 04-pigeon-api.md §CamError]

---

### FrameResult
Periodic sensor metadata readback delivered at approximately 3 Hz during active streaming.

| Field | Type | Description |
|---|---|---|
| `iso` | int? | Current sensor sensitivity |
| `exposureTimeNs` | int? | Current sensor exposure duration in nanoseconds |
| `focusDistanceDiopters` | double? | Current lens focus distance in diopters (null during autofocus scan) |
| `wbGainR` | double? | Current red channel white balance gain |
| `wbGainG` | double? | Current green channel white balance gain |
| `wbGainB` | double? | Current blue channel white balance gain |

**Note:** `focusDistanceDiopters` is null whenever the autofocus system is actively scanning. It is only populated when focus is locked or passively settled.

[audit: 04-pigeon-api.md §CamFrameResult, 09-camera-controls.md §CamFrameResult Delivery]

---

### RgbSample
Result of a center-patch color sample operation.

| Field | Type | Range | Description |
|---|---|---|---|
| `r` | double | `[0.0, 1.0]` | Mean red value in sampled patch |
| `g` | double | `[0.0, 1.0]` | Mean green value in sampled patch |
| `b` | double | `[0.0, 1.0]` | Mean blue value in sampled patch |

[audit: 04-pigeon-api.md §CamRgbSample]

---

## Host Methods (Application → Plugin)

The plugin manages a single camera session. The session is identified by an opaque integer handle returned by `open()`. All subsequent method calls include this handle. Only one session may be active at a time — the product uses exactly one physical camera (device back-facing main lens) [resolves U-17].

### open
```
open(cameraId: String?, enableNaturalStream: Bool, naturalStreamHeight: Int) → SessionCapabilities
```
Opens the camera and initializes the full capture pipeline. Returns session capabilities including the preview texture identifier(s) for the UI layer to render.

- `cameraId`: Identifies the physical camera to open. Null selects the device's back-facing main lens (the only supported camera for this product — telephoto, ultra-wide, and front-facing lenses are explicitly out of scope).
- `enableNaturalStream`: If true, an additional unprocessed ("natural") frame stream is initialized. "Natural" denotes a passthrough stream that skips GPU color-adjustment; it is not photography RAW.
- `naturalStreamHeight`: Pixel height of the natural stream (used to compute width preserving aspect ratio). Ignored if `enableNaturalStream` is false.

The method returns when the session is fully initialized. The returned `previewTextureId` can immediately be used by the UI layer.

[audit: 04-pigeon-api.md §CameraHostApi]

---

### close
```
close(handle: Int) → void
```
Orderly release of all camera resources. Emits state `"closed"`. Ongoing recording is stopped.

[audit: 04-pigeon-api.md §CameraHostApi]

---

### pause
```
pause(handle: Int) → void
```
Tears down the active capture session while retaining the underlying camera device. Transitions to state `"paused"`. Ongoing recording is stopped before the session is released.

[audit: 04-pigeon-api.md §CameraHostApi, 07-state-machine.md]

---

### resume
```
resume(handle: Int) → void
```
Restarts the capture session after a `pause`. Transitions to `"opening"` → `"streaming"`.

[audit: 04-pigeon-api.md §CameraHostApi]

---

### backgroundSuspend
```
backgroundSuspend(handle: Int) → void
```
Called when the application becomes fully invisible. Releases all camera resources without emitting a user-visible state change. Suppresses any pending recovery retry.

[audit: 04-pigeon-api.md §CameraHostApi, 07-state-machine.md §Background Suspend/Resume]

---

### backgroundResume
```
backgroundResume(handle: Int) → void
```
Called when the application returns to visible. If a camera was previously open, reopens it.

[audit: 04-pigeon-api.md §CameraHostApi]

---

### updateSettings
```
updateSettings(handle: Int, settings: CameraSettings) → void
```
Merges non-null fields from `settings` onto the persisted settings state and applies them to the active capture session. ISO and exposure mode coupling rules apply (see `03-camera-control.md`).

[audit: 04-pigeon-api.md §CameraHostApi]

---

### setProcessingParameters
```
setProcessingParameters(handle: Int, params: ProcessingParameters) → void
```
Updates all GPU shader parameters immediately. Takes effect on the next rendered frame.

[audit: 04-pigeon-api.md §CameraHostApi]

---

### getPersistedProcessingParameters
```
getPersistedProcessingParameters(handle: Int) → ProcessingParameters?
```
Returns the last saved GPU processing parameters from persistent local storage. Returns null if no parameters have ever been saved. Usable without an active streaming session for UI initialization.

[audit: 04-pigeon-api.md §CameraHostApi, 09-camera-controls.md §Settings Persistence]

---

### sampleCenterPatch
```
sampleCenterPatch(handle: Int) → RgbSample
```
Samples a 96×96 pixel patch from the center of the most recently rendered GPU-processed frame. Computes R, G, B mean values using a histogram trimmed mean (discarding the top and bottom 10% of intensity distribution).

[audit: 04-pigeon-api.md §CameraHostApi, 05-gpu-opengl.md §sampleCenterPatch]

---

### captureNaturalPicture
```
captureNaturalPicture(handle: Int) → String (file path)
```
Triggers a hardware ISP still capture — the sensor's native JPEG output with no GPU post-processing applied. EXIF metadata is written. Returns the file path where the image was saved.

Only one capture may be in flight at a time; concurrent calls are rejected.

[audit: 04-pigeon-api.md §CameraHostApi, 10-capture-recording.md §Still Capture: captureNaturalPicture]

---

### captureImage
```
captureImage(handle: Int, outputDirectory: String?, fileName: String?) → String (file path)
```
Captures a still image from the current GPU-processed frame — the image exactly matches what the processed preview displays (including all color adjustments). Format is determined by `fileName` extension: `.jpg`/`.jpeg` for JPEG (quality 90), `.png` for lossless PNG.

- `outputDirectory` null: saves to the system media library under the app's designated pictures folder.
- `outputDirectory` non-null: saves directly to the specified path.

Returns the saved file path.

[audit: 04-pigeon-api.md §CameraHostApi, 10-capture-recording.md §Still Capture: captureImage]

---

### startRecording
```
startRecording(handle: Int, outputDirectory: String?, fileName: String?, bitrate: Int?, fps: Int?) → String
```
Starts video recording. The GPU-processed frame stream is routed to the video encoder. Returns an opaque result string containing the output URI and display name (separated by `|` at the first occurrence, to handle `|` in filenames).

- Default bitrate: 50 Mbps
- Default fps: 30
- Default output: system media library under the app's designated video folder

The repeating capture request is rebuilt in recording-optimized mode, which allows the auto-exposure system to reduce frame rate in low-light scenes while maintaining the encoder's configured upper frame rate bound.

[audit: 04-pigeon-api.md §CameraHostApi, 10-capture-recording.md §startRecording() Flow]

---

### stopRecording
```
stopRecording(handle: Int) → String (content URI)
```
Stops the active video recording. Signals end-of-stream to the encoder, drains remaining encoded output (up to 5 seconds), finalizes the container, and returns the output URI. If the drain times out, a non-fatal `RECORDING_TRUNCATED` error is emitted before returning.

[audit: 04-pigeon-api.md §CameraHostApi, 10-capture-recording.md §stopRecording() Flow]

---

### setResolution
```
setResolution(handle: Int, width: Int, height: Int) → void
```
Changes the capture resolution without closing the camera device. Tears down only the active capture session and GPU pipeline, resizes, then restarts the session. Width and height must both be positive. The resize operation has a 5-second timeout; failure is non-fatal (returns to previous state).

[audit: 04-pigeon-api.md §CameraHostApi, 09-camera-controls.md §setResolution Flow]

---

### getNativePipelineHandle
```
getNativePipelineHandle(handle: Int) → Int?
```
Returns an opaque integer representing the C++ pipeline object pointer. Intended for use by external C++ consumers (e.g., a tracker module) that need to register directly with the frame dispatch pipeline. Returns null if the pipeline is not initialized.

[audit: 04-pigeon-api.md §CameraHostApi, 06-cpp-sinks.md §Sink Registration]

---

## Callbacks (Plugin → Application)

### onStateChanged
```
onStateChanged(handle: Int, state: SessionState)
```
Emitted on every session state transition. The application layer should update UI and drive lifecycle decisions based on these events.

[audit: 04-pigeon-api.md §CameraFlutterApi]

---

### onError
```
onError(handle: Int, error: Error)
```
Emitted when an error is detected. If `error.isFatal` is true, no further recovery will occur and the session should be considered closed. If false, the system is attempting recovery and will emit further state changes.

[audit: 04-pigeon-api.md §CameraFlutterApi]

---

### onFrameResult
```
onFrameResult(handle: Int, result: FrameResult)
```
Emitted approximately 3 times per second with actual sensor readback values. The application layer uses this to update UI displays of current ISO, exposure, focus distance, and white balance gains.

[audit: 04-pigeon-api.md §CameraFlutterApi, 09-camera-controls.md §CamFrameResult Delivery]

---

### onRecordingStateChanged
```
onRecordingStateChanged(handle: Int, state: String)
```
Emitted when recording starts (`"recording"`) or stops (`"idle"`). The application layer uses this to update UI recording indicators (elapsed time counter, stop/record button state).

[audit: 04-pigeon-api.md §CameraFlutterApi]

---

## Native Consumer Registration (C++ API)

External C++ consumers can register directly with the frame dispatch pipeline using the opaque handle returned by `getNativePipelineHandle()`. The C++ API provides:

- **Consumer roles:** Full-resolution GPU-processed frames, or downscaled tracker frames (fixed 480px height). The natural (unprocessed) stream is display-only and cannot register C++ consumers [resolves U-13].
- **Registration:** `addSink(config)` — provides a role and a callback.
- **Deregistration:** `removeSink(role)` — removes a consumer by role.
- **Frame hook:** `setFrameHook(role, hook)` — optional per-role pre-dispatch transform, applied before the frame is delivered to consumers.
- **Capture to file:** `captureToFile(path, quality)` and `captureToFd(fd, isJpeg, quality)` — one-shot frame capture from the pipeline.

Frame data in consumer callbacks is valid only for the duration of the callback. Consumers must copy the pixel data if they need to retain it beyond the callback scope.

[audit: 06-cpp-sinks.md §Public Consumer API, §Sink Registration]
