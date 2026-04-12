# Audit: cambrian_camera Android Plugin

This directory contains a complete factual audit of the `cambrian_camera` Flutter plugin for Android,
located at `/Users/shrek/work/cambrian/camera2_flutter_demo`.

## Contents

| File | Topic |
|------|-------|
| `01-system-topology.md` | Layer architecture, file map, and UI overview |
| `02-threading-model.md` | All threads, their ownership, and cross-thread call rules |
| `03-capture-pipeline.md` | Frame path from Camera2 through GPU to consumer sinks |
| `04-pigeon-api.md` | Full Pigeon API surface: data types, host methods, Flutter callbacks |
| `05-gpu-opengl.md` | EGL context, shader programs, PBO double-buffer, sync fences |
| `06-cpp-sinks.md` | IImagePipeline, SinkRole, consumer dispatch, ProcessingStage |
| `07-state-machine.md` | CameraController state transitions and invariants |
| `08-error-recovery.md` | Non-fatal/fatal error paths, exponential backoff, watchdogs |
| `09-camera-controls.md` | CamSettings fields, 3A coupling rules, Camera2 request keys |
| `10-capture-recording.md` | Still capture paths, video recording, MediaCodec surface mode |
| `11-build-config.md` | Gradle, NDK, CMake, native dependencies, manifest |
| `12-git-archaeology.md` | Architectural evolution timeline from git history |

## Source Codebase

```
/Users/shrek/work/cambrian/camera2_flutter_demo/
  lib/                        Dart application layer
  packages/cambrian_camera/   Plugin package
    lib/                      Dart SDK
    android/src/main/
      kotlin/com/cambrian/camera/   Kotlin plugin layer
      cpp/                          C++ JNI layer (CMake)
    pigeons/camera_api.dart   Pigeon definitions (source of truth)
```

## Audit Date

2026-04-13
