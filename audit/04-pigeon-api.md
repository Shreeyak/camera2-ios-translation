# 04 — Pigeon API

Source of truth: `packages/cambrian_camera/pigeons/camera_api.dart`
Generated Kotlin: `Messages.g.kt`
Generated Dart: `src/generated/messages.g.dart`

Codegen: Always use `scripts/regenerate_pigeon.sh` (patches a recurring type-cast bug in Pigeon ≤ v26.3.3; never run `dart run pigeon` directly).

## Data Classes

### CamSize
```
width: int
height: int
```

### CamSettings
All fields nullable — null means "do not change this setting".
```
isoMode: String?           "auto" | "manual" | null
iso: int?                  sensor sensitivity (manual only)
exposureMode: String?      "auto" | "manual" | null
exposureTimeNs: int?       sensor exposure time in nanoseconds (manual only)
focusMode: String?         "auto" | "manual" | null
focusDistanceDiopters: double?   lens focus distance (manual only, 0.0 = infinity)
wbMode: String?            "auto" | "locked" | "manual" | null
wbGainR: double?           red channel gain (manual WB only)
wbGainG: double?           green channel gain (manual WB only)
wbGainB: double?           blue channel gain (manual WB only)
zoomRatio: double?         digital zoom (1.0 = no zoom)
noiseReductionMode: int?   Camera2 NOISE_REDUCTION_MODE integer
edgeMode: int?             Camera2 EDGE_MODE integer
evCompensation: int?       AE EV compensation steps (auto AE only)
```

### CamProcessingParams
GPU shader uniform values.
```
brightness: double   range [-1.0, 1.0]
contrast: double     range [0.0, 2.0] (1.0 = no change)
saturation: double   range [-1.0, 1.0] (0.0 = no change)
blackR: double       black level offset for red channel
blackG: double       black level offset for green channel
blackB: double       black level offset for blue channel
gamma: double        gamma exponent (1.0 = no change)
```

### CamCapabilities
Returned by `open()` to describe what the session supports.
```
supportedSizes: List<CamSize>   supported YUV_420_888 output sizes
previewTextureId: int           Flutter Texture registry ID for processed preview
rawTextureId: int               Flutter Texture registry ID for raw preview (0 if disabled)
rawWidth: int                   raw stream width (0 if disabled)
rawHeight: int                  raw stream height (0 if disabled)
```

### CamStateUpdate
```
state: String   "opening" | "streaming" | "recovering" | "paused" | "error" | "closed"
```

### CamErrorCode (enum, 19 values)
```
CAMERA_NOT_FOUND
CAMERA_IN_USE
PERMISSION_DENIED
CAMERA_ACCESS_ERROR
CAMERA_DISCONNECTED
CONFIGURATION_FAILED
CAPTURE_FAILURE
RECORDING_START_FAILED
RECORDING_FAILED
RECORDING_TRUNCATED
FRAME_STALL
MAX_RETRIES_EXCEEDED
UNKNOWN_ERROR
SETTINGS_CONFLICT
INVALID_FORMAT
FPS_DEGRADED
AE_CONVERGENCE_TIMEOUT
INVALID_STATE
HAL_ERROR
```

### CamError
```
code: CamErrorCode
message: String
isFatal: bool
```

### CamFrameResult
Sent at ~3 Hz (every 10th capture result at 30 fps) with actual sensor values.
```
iso: int?
exposureTimeNs: int?
focusDistanceDiopters: double?   null during AF scan (only when locked)
wbGainR: double?
wbGainG: double?
wbGainB: double?
```

### CamRgbSample
Result of `sampleCenterPatch()`.
```
r: double   mean red in [0.0, 1.0]
g: double   mean green
b: double   mean blue
```

## CameraHostApi (Dart → Native)

16 methods. `@HostApi(dartHostTestHandler: 'TestCameraHostApi')`

| Method | Parameters | Returns | Notes |
|--------|-----------|---------|-------|
| `open` | `cameraId: String?, enableRawStream: bool, rawStreamHeight: int` | `CamCapabilities` | Opens camera; returns texture IDs |
| `close` | `handle: int` | `void` | Orderly close; emits "closed" state |
| `pause` | `handle: int` | `void` | Tears down session; keeps device open |
| `resume` | `handle: int` | `void` | Restarts session after pause |
| `backgroundSuspend` | `handle: int` | `void` | ProcessLifecycleOwner onStop — releases camera |
| `backgroundResume` | `handle: int` | `void` | ProcessLifecycleOwner onStart — reopens camera |
| `updateSettings` | `handle: int, settings: CamSettings` | `void` | Merge-and-apply camera settings |
| `setProcessingParams` | `handle: int, params: CamProcessingParams` | `void` | GPU shader uniforms |
| `getPersistedProcessingParams` | `handle: int` | `CamProcessingParams?` | Load from SharedPreferences |
| `sampleCenterPatch` | `handle: int` | `CamRgbSample` | Sample 96×96 center of latest GPU frame |
| `captureNaturalPicture` | `handle: int` | `String` | JPEG via Camera2 ISP ImageReader; returns path |
| `captureImage` | `handle: int, outputDirectory: String?, fileName: String?` | `String` | GPU-processed JPEG or PNG; returns path |
| `startRecording` | `handle: int, outputDirectory: String?, fileName: String?, bitrate: int?, fps: int?` | `String` | Returns `uri|displayName` |
| `stopRecording` | `handle: int` | `String` | Returns content URI |
| `setResolution` | `handle: int, width: int, height: int` | `void` | Session-only teardown + pipeline.resize() |
| `getNativePipelineHandle` | `handle: int` | `int?` | Returns opaque C++ pointer as int64 (for external consumers) |

## CameraFlutterApi (Native → Dart)

4 callbacks. `@FlutterApi()`

| Method | Parameters | Notes |
|--------|-----------|-------|
| `onStateChanged` | `handle: int, state: CamStateUpdate` | Emitted on every state transition |
| `onError` | `handle: int, error: CamError` | `isFatal=true` → no further recovery |
| `onFrameResult` | `handle: int, result: CamFrameResult` | ~3 Hz sensor readback |
| `onRecordingStateChanged` | `handle: int, state: String` | "recording" or "idle" |

## Handle System

Each `open()` call returns a `handle` (int64 — the native `CameraSession` handle from `CambrianCameraPlugin`).
All subsequent calls to `CameraHostApi` include this handle to identify the session.
`CambrianCameraPlugin` maintains a `sessions: Map<Long, CameraSession>` and looks up the `CameraController` by handle.

## ISO + Exposure Coupling Rules

Enforced in `CameraController.updateSettings()` before applying to Camera2:

1. **Auto is contagious**: if either `isoMode` or `exposureMode` is `"auto"` after merge, both are set to `"auto"`.
2. **Auto wins over manual**: if one is `"auto"` and one is `"manual"` post-merge, both pull to `"auto"`.
3. **Manual latches from last AE values**: if only one field transitions to `"manual"`, the partner is seeded from `lastCaptureSnapshot`. If no snapshot exists yet, returns `SETTINGS_CONFLICT` error.
