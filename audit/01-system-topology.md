# 01 — System Topology

## Layer Architecture

The plugin is a 6-layer stack. Each layer has a single language and communicates with its neighbors
through a defined interface.

```
L1  Dart Application (lib/)
       ↕  public Dart API (CambrianCamera class)
L2  Dart Plugin SDK (packages/cambrian_camera/lib/)
       ↕  Pigeon-generated channels
L3  Kotlin FlutterPlugin (CambrianCameraPlugin.kt)
       ↕  direct Kotlin calls
L4  Kotlin CameraController (CameraController.kt)
       ↕  JNI (CameraBridge.cpp)
L5  C++ JNI Bridge (CameraBridge.cpp)
       ↕  C++ method calls
L6  C++ ImagePipeline / GpuRenderer (ImagePipeline.cpp, GpuRenderer.cpp)
```

| Layer | Language | Key Files | Role |
|-------|----------|-----------|------|
| L1 | Dart | `lib/main.dart`, `lib/camera_screen.dart` | App UI, Flutter widgets |
| L2 | Dart | `packages/cambrian_camera/lib/cambrian_camera.dart` | Public SDK surface |
| L3 | Kotlin | `CambrianCameraPlugin.kt` | FlutterPlugin, session map |
| L4 | Kotlin | `CameraController.kt`, `GpuPipeline.kt`, `VideoRecorder.kt` | Camera2 orchestration |
| L5 | C++ | `CameraBridge.cpp` | JNI glue; opaque pipeline handle |
| L6 | C++ | `GpuRenderer.cpp`, `ImagePipeline.cpp` | OpenGL ES rendering, sink dispatch |

## File Map

### Dart SDK (`packages/cambrian_camera/lib/`)
- `cambrian_camera.dart` — `CambrianCamera` class (open, close, pause, resume, etc.)
- `src/generated/messages.g.dart` — Pigeon-generated Dart (data classes, channel stubs)

### Pigeon Definitions
- `packages/cambrian_camera/pigeons/camera_api.dart` — source of truth for all data types and API methods

### Kotlin (`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/`)
- `CambrianCameraPlugin.kt` — `FlutterPlugin` + `ActivityAware` + `CameraHostApi`; session map
- `CameraController.kt` — Camera2 lifecycle; state machine; capture, recording, settings
- `GpuPipeline.kt` — GL HandlerThread wrapper; stall detection; JNI stub declarations
- `VideoRecorder.kt` — MediaCodec surface-input mode; drain HandlerThread; MediaMuxer
- `SettingsStore.kt` — SharedPreferences persistence for settings and processing params
- `MetadataLayout.kt` — Shared flat-array layout constants for JNI metadata transfer
- `CaptureResultSnapshot.kt` — Immutable snapshot of TotalCaptureResult
- `CambrianCameraConfig.kt` — Global volatile diagnostic flags
- `LogLevelReceiver.kt` — ADB broadcast receiver (debug-build restricted)
- `VideoRecordingReceiver.kt` — ADB broadcast receiver for recording control (debug only, `src/debug/`)
- `Messages.g.kt` — Pigeon-generated Kotlin (data classes, `CameraHostApi` interface, `CameraFlutterApi`)

### C++ (`packages/cambrian_camera/android/src/main/cpp/`)
- `CameraBridge.cpp` — JNI entry points (`nativeInit`, `nativeGpuInit`, `nativeGpuDrawAndReadback`, etc.)
- `src/GpuRenderer.cpp` / `GpuRenderer.h` — EGL context, GLSL shaders (inline), PBO pipeline, sync fences
- `src/ImagePipeline.cpp` / `ImagePipeline.h` — Consumer sink dispatch, ProcessingStage hook threads
- `include/cambrian_camera_native.h` — Public consumer API (`IImagePipeline`, `SinkRole`, `SinkConfig`, etc.)
- `fpng.cpp` / `fpng.h` — Third-party PNG encoder
- External: `libjpeg-turbo 3.0.3` — JPEG encoder (built from source via `ExternalProject_Add`)

### Application Layer (`lib/`)
- `main.dart` — App entry point, `MaterialApp`
- `camera_screen.dart` — Main camera view, Flutter `Texture` widget for preview
- `gpu_controls_sidebar.dart` — Brightness/contrast/saturation/gamma sliders
- `camera_controls_bar.dart` — Bottom bar (Settings, Calibrate Color, Capture, Record, resolution display)

## Key Architectural Invariants

- **Preview = consumer output**: The preview `Texture` widget displays GPU-processed frames, not raw camera frames.
- **1 memcpy per frame**: Camera2 delivers YUV_420_888 to GpuPipeline via SurfaceTexture/OES; the GPU reads it and writes RGBA to a PBO. The single memcpy is from PBO → consumer vector.
- **No per-consumer copies**: ImagePipeline wraps the readback buffer as a `shared_ptr<Frame>` and sends the same pointer to every registered consumer.
- **null = don't change**: In `CamSettings`, all fields are nullable. Null means "do not modify this setting."
- **ISO/exposure coupled**: Camera2 ties both to `CONTROL_AE_MODE`. Setting either to "auto" propagates to the other.
- **Recording encodes GPU output directly**: MediaCodec receives tone-mapped frames via an EGL surface; no CPU YUV copy.
- **No OpenCV in pipeline**: OpenCV was removed in commit `7e77250`. The current pipeline uses `std::vector<uint8_t>` throughout.

## UI Overview

The demo application runs in landscape orientation. All five screenshots were captured at 02:54–02:55.

**flutter_01.png — Main camera view (collapsed controls bar)**

The main view shows a split-screen preview: left half is the raw/unprocessed stream; right half shows
the GPU-processed (tone-mapped) stream. The bottom bar shows five items:
- SETTINGS (equalizer icon)
- CALIBRATE COLOR (color wheel icon)
- CAPTURE (camera icon)
- RECORD (circle icon)
- Resolution display: `4160x3120`

**flutter_02.png — Camera controls expanded**

The bottom controls bar has expanded to show individual camera parameter controls:
- ISO: `1600`
- SHUTTER: `1/33`
- FOCUS: `AUTO`
- ZOOM: `1.0x`

A collapse arrow is visible at the left. The split-screen live preview continues in the background.

**flutter_03.png — Calibrate Color panel**

A left sidebar panel labeled "Calibrate Color" is open. It contains:
- WHITE BALANCE section with a "Calibrate" button
- BLACK BALANCE section with a lock icon and "Calibrate" button
- Brightness slider (0.00)
- Contrast slider (1.00)
- Saturation slider (1.00)
- Gamma slider (1.00)
- "Reset all" button

The split-screen live preview is visible to the right.

**flutter_04.png — After still capture**

Same Calibrate Color panel is open. A status banner at the bottom reads:
`Image saved: /storage/emulated/0/Pictures/CambrianCamera/capture_1776029093325.png`

This confirms the `captureImage()` path writes to `MediaStore.Images` under `Pictures/CambrianCamera/`.

**flutter_05.png — Active video recording**

The Calibrate Color panel is closed. The bottom bar shows STOP instead of RECORD. A red recording
indicator shows `00:01` elapsed. The split-screen live preview continues. The RECORD button icon is
now a filled square (stop icon).
