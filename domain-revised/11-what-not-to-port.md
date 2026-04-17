# 11 — What Not to Port

This file lists items from the Android audit that are **Android-specific implementation details**.
They must NOT be carried forward as requirements. The downstream architect should solve these
problems from first principles using the target platform's native capabilities.

Each item includes a brief explanation of why it is Android-specific.

---

## Threading Primitives (Android Message-Dispatch Mechanism)

The audit describes a pattern where every camera operation is posted to a named background thread via a platform-specific message-dispatch mechanism, and every UI callback is posted back to the main thread via the same mechanism.

**Why not to port:** This is a specific concurrency mechanism tied to the Android runtime's message-passing model. The behavioral invariant — that camera state mutations are serialized and UI callbacks arrive on the main execution context — is a domain requirement (see `04-concurrency-invariants.md`). The specific mechanism is not.

[audit: 02-threading-model.md]

---

## JNI (Java Native Interface)

The native bridge between the managed-runtime controller layer and the C++ layer uses JNI entry points with specific naming conventions (`nativeInit`, `nativeGpuDrawAndReadback`, etc.) and flat-array metadata transfer to minimize per-call overhead.

**Why not to port:** JNI is specific to the Java Virtual Machine / Android Runtime. The behavioral requirement — that the managed controller layer communicates with a C++ GPU and pipeline layer via an efficient native bridge — is platform-neutral. The JNI mechanism itself is not. [audit: 01-system-topology.md, 03-capture-pipeline.md §JNI-metadata-transfer]

---

## Flutter Pigeon Codegen

The API contract is defined using a Flutter code-generation tool (Pigeon) that produces matched Dart and managed-runtime classes from a single source file. A wrapper script patches a recurring type-cast bug in generated code.

**Why not to port:** Pigeon is a Flutter-specific code generation tool. The API contract it encodes — the method signatures, data types, and callback protocol — is a domain requirement (see `10-api-contract.md`). The codegen tool and its bug workarounds are not. [audit: 04-pigeon-api.md, 11-build-config.md §Pigeon Codegen]

---

## SharedPreferences for Settings Persistence

Settings (`CamSettings`) and GPU processing parameters (`CamProcessingParams`) are persisted using the platform's key-value storage with a workaround to serialize `double` values as `long` bit patterns because the storage API does not natively support floating-point types.

**Why not to port:** SharedPreferences is Android's key-value persistence API. The bit-packing workaround for doubles is specific to that API's limitations. The behavioral requirement — that settings survive session teardown and are restored on reopen — is a domain requirement (see `05-resource-lifecycle.md`). [audit: 09-camera-controls.md §Settings Persistence]

---

## MediaStore Integration

Still images and video recordings are written to the system media library using a two-phase write pattern: first insert a pending entry, write data to the provided file descriptor, then clear the pending flag. The content URI is returned to the caller; the absolute path is resolved from the media library after the write completes.

**Why not to port:** MediaStore is Android's media content provider. The two-phase write pattern (`IS_PENDING`) is specific to Android 10+ media insertion APIs. The behavioral requirement — that captured media is saved to a system-managed location accessible to gallery apps and is not visible until the write is complete — is a domain requirement (see `08-capture-and-recording.md`). [audit: 10-capture-recording.md §Still Capture: captureImage]

---

## Android Manifest and Permission Model

Camera access requires a declared `CAMERA` permission in the app manifest. The system prompts the user at runtime. On some vendor implementations, a `SecurityException` may be thrown after keyguard dismiss even when permission is granted (OEM bug).

**Why not to port:** Android manifest declarations and the specific permission system are Android-specific. The behavioral requirement — that the system must handle permission denial gracefully and notify the caller — is a domain requirement (see `06-error-and-recovery.md`). The OEM bug workaround (catching `SecurityException` as non-fatal) may have platform-equivalent edge cases but the mechanism differs. [audit: 08-error-recovery.md, 11-build-config.md §Android Manifest]

---

## Android-Specific Capture Request Templates

The capture pipeline uses named request templates from the Android camera hardware abstraction layer to initialize capture parameters for different modes. The template choice affects ISP tuning for preview vs. recording modes.

**Why not to port:** The template identifiers are specific to the Android camera API. The behavioral requirement — that capture parameters are tuned differently for preview vs. recording — is a domain requirement (see `03-camera-control.md`). Still capture does not use a distinct request mode; it reads GPU-processed output from the running repeating request. [audit: 09-camera-controls.md §capture-mode-templates]

---

## Gradle / NDK / CMake Build Configuration

Build toolchain: Gradle with DSL scripting, NDK version 27.0.12077973 (originally chosen for OpenCV prebuilt compatibility, now retained historically), CMake 3.22.1, `arm64-v8a` ABI only, C++17 with shared `libc++`, `RelWithDebInfo` build type.

**Why not to port:** Entirely Android/NDK-specific. The target platform has its own build system. Note: NDK version was retained after OpenCV removal for historical reasons only — the constraint no longer applies. [audit: 11-build-config.md]

---

## ADB Broadcast Receivers for Debug Control

Two broadcast receivers exist for debug-only control: one for adjusting log levels via ADB intent, one for triggering video recording via ADB intent. The log-level receiver is present in release builds but guarded by a runtime debuggable flag check.

**Why not to port:** Android broadcast intents are platform-specific. The debug control pattern (runtime flag for log verbosity) is a domain concern addressed by `09-ui-behaviors.md` where applicable. [audit: 01-system-topology.md, 11-build-config.md §Android Manifest]

---

## ProcessLifecycleOwner (onStop / onStart)

The system releases the camera when the app transitions to fully-invisible (`onStop`) and reopens it when returning to visible (`onStart`). The explicit choice of `onStop`/`onStart` over `onPause`/`onResume` is deliberate — prevents releasing on partial occlusion.

**Why not to port:** `ProcessLifecycleOwner` is an Android Jetpack lifecycle component. The behavioral requirement — that the camera is released when the app becomes fully invisible and reopened on return — is a domain requirement (see `05-resource-lifecycle.md`). The specific lifecycle event names are Android-specific. [audit: 07-state-machine.md §Background Suspend/Resume, 12-git-archaeology.md]

---

## Android-Specific Camera Availability Notification for Self-Healing

When in the terminal error state and another app releases the camera, the Android system delivers a camera availability notification, and the plugin autonomously restarts the open sequence.

**Why not to port:** The camera availability notification mechanism is a construct of the Android camera API. The behavioral requirement — that the system can self-heal from camera-in-use errors without user action when the camera becomes available — is a domain requirement (see `06-error-and-recovery.md`). The target platform may have a different mechanism (or none) for detecting camera availability changes. [audit: 07-state-machine.md §self-healing]

---

## OpenGL ES Specifics (PBOs, FBOs, EGL Context, Shader API)

The GPU pipeline uses OpenGL ES 3.0 constructs: pixel buffer objects for asynchronous readback, framebuffer objects as render targets, EGL context/surface management, sync fence objects, an external OES texture for camera input, and inline GLSL shader source strings.

**Why not to port:** These are OpenGL ES / EGL API specifics. The behavioral requirements — that GPU frame processing is asynchronous, that readback does not stall the render loop, that multiple render targets are supported (preview, encoder, raw, tracker) — are domain requirements (see `02-frame-delivery.md`, `07-performance-budgets.md`). The specific API constructs are not. The target platform's GPU API (Metal, Vulkan, or others) will have different primitives. [audit: 05-gpu-opengl.md]

---

## UV Rotation Matrix (90° CW Landscape Normalization)

The GPU vertex shader applies a 90° clockwise UV rotation matrix (`uUvTransform`) per frame to normalize the camera's physical sensor orientation to landscape-right display orientation.

**Why not to port:** This is a workaround for the specific sensor mounting angle of the Android test device. The behavioral requirement — that the preview displays with correct orientation relative to the UI — is a domain requirement. The specific rotation angle depends on the physical camera hardware used in the target deployment and must be re-determined for the target platform. [audit: 03-capture-pipeline.md §GpuPipeline, 05-gpu-opengl.md]

---

## Encoder Output Drain Loop Pattern

The video encoder output is drained by a dedicated loop on a separate execution context that polls the encoder output queue with a platform-specific poll interval and writes encoded packets to the container muxer.

**Why not to port:** The polling drain loop is specific to the Android codec API's synchronous polling model. The behavioral requirement — that encoded video output is drained continuously without blocking the GPU render loop — is a domain requirement (see `08-capture-and-recording.md`). [audit: 02-threading-model.md §drain-thread]

---

## Pigeon Binary Messenger Thread Affinity

All callbacks from native to the application layer must be posted to the main thread because the inter-layer messaging runtime requires main-thread access.

**Why not to port:** This is a Flutter/Android runtime constraint. The behavioral requirement — that state change events and error notifications arrive on the UI execution context — is a domain requirement (see `04-concurrency-invariants.md`). The specific mechanism (posting to a platform message handler) is not. [audit: 02-threading-model.md §Main Thread]

---

## HEVC/H.264 Android Codec Identifier Strings

The Android video encoder uses codec name strings (`"video/hevc"`, `"video/avc"`) for capability query and codec selection.

**Why not to port:** The codec identifier strings are Android `MediaCodec` API specifics. The domain requirement (HEVC 8-bit encoding, no fallback) is stated in `08-capture-and-recording.md`. Target platform codec lookup is platform-specific. [audit: 10-capture-recording.md §Codec Selection]

---

## libjpeg-turbo Build-from-Source via ExternalProject_Add

JPEG encoding uses libjpeg-turbo 3.0.3, built from source as a CMake external project and statically linked.

**Why not to port:** Build configuration detail. The behavioral requirement — that JPEG capture produces high-quality output at quality level 90 — is a domain requirement (see `08-capture-and-recording.md`). The specific library and build method are implementation choices. [audit: 11-build-config.md §libjpeg-turbo]

---

## fpng Third-Party PNG Encoder

PNG encoding uses the bundled `fpng` library (single-file C++ encoder).

**Why not to port:** Implementation choice. The behavioral requirement — that PNG capture produces lossless output — is a domain requirement. [audit: 06-cpp-sinks.md §JPEG and PNG Encoding]

---

## Android-Specific White Balance Gain Vector Encoding

Manual white balance is applied by setting a four-element gain vector `(red, greenEven, greenOdd, blue)` where both green channels use the same value. The redundant green-odd parameter exists because the Android camera hardware abstraction layer models the Bayer pattern's two green photosites separately.

**Why not to port:** The four-element Bayer-aware gain vector is a data type specific to the Android camera API. The behavioral requirement — that manual white balance accepts independent R, G, B gain values — is a domain requirement (see `03-camera-control.md`). The four-element encoding is Android HAL-specific. [audit: 09-camera-controls.md §White Balance]

---

## Host Unit Tests (GTest, Non-Android Build)

The C++ library has a host-build path that compiles without Android toolchain for running GTest unit tests covering tracker dimension math and sink routing.

**Why not to port:** Build configuration. The behavioral requirements under test (tracker resolution formula, consumer dispatch correctness) are domain requirements. The test infrastructure is implementation detail. [audit: 11-build-config.md §Host Tests]
