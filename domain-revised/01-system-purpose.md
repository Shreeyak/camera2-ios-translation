# 01 — System Purpose

## Mission

The system is a professional camera plugin that exposes a camera-to-ML-pipeline with the following top-level behaviors:

1. **Live GPU-processed preview**: Camera frames are captured at a device-supported resolution, center-cropped to an operator-selected region, then routed through a GPU render stage that applies per-channel color corrections (black balance, brightness, contrast, saturation, gamma) in real time. The processed output is displayed to the user at the crop resolution.
2. **Natural parallel stream**: An unprocessed ("natural") frame stream runs alongside the processed stream, enabling side-by-side comparison of adjusted vs. unadjusted output. The natural stream is the same center-cropped region converted to the working color format but with no color transforms applied. Cropping is not considered "processing" for this purpose. "Natural" is distinct from photography "RAW" (Bayer sensor data).
3. **Consumer fan-out**: Frames are delivered to any number of registered consumers via a latest-only, zero-copy dispatch mechanism. The primary intended use case is ML inference (e.g., object tracking). All three streams (`natural`, `processed`, `tracker`) are subscribable [reverses U-13].
4. **Still image capture**: A single still-capture path produces an 8-bit TIFF image from the processed GPU output. Platforms may implement the path either by consuming a processed-stream subscription or by reading directly from the GPU output buffer; the two implementations are equivalent.
5. **Video recording**: Processed frames are encoded to a compressed video file. No CPU frame copy is required — the encoder receives frames directly from the GPU output. Recordings contain a single video track; the system does not capture audio.
6. **Adjustable camera controls**: ISO, exposure, focus, zoom, white balance, and image quality parameters are controllable at runtime from the application layer.

[audit: 01-system-topology.md §Key Architectural Invariants]

---

## System Topology

The system is structured as a layered stack. Each layer has a well-defined responsibility and communicates with adjacent layers through a specified interface.

```
Application Layer
    ↕ (public SDK API: host methods + callbacks)
Plugin SDK Layer
    ↕ (inter-process channel)
Controller Layer (camera lifecycle orchestration)
    ↕ (native bridge)
C++ GPU and Pipeline Layer
```

**Layer responsibilities:**

| Layer | Responsibility |
|---|---|
| Application Layer | UI, user interaction, high-level session management |
| Plugin SDK Layer | Public API surface; type-safe data classes; session handle management |
| Controller Layer | Camera lifecycle, state machine, settings application, GPU pipeline orchestration |
| C++ GPU Layer | Frame rendering, color processing, asynchronous readback, consumer dispatch |

[audit: 01-system-topology.md §Layer Architecture]

---

## Session Model

Each call to `open()` creates a camera session identified by an opaque integer handle. All subsequent operations reference this handle. Only one concurrent session is supported [resolves U-17]: the app uses exactly one camera — the device's back-facing main lens. Telephoto, ultra-wide, and front-facing lenses are explicitly out of scope. The controller's session map is an implementation structure, not a multi-session feature. Calling `open()` while a session is already active is undefined; downstream design should either reject the call or close the prior session.

[audit: 04-pigeon-api.md §Handle System]

---

## Key Invariants

1. **Preview is consumer output, not sensor output**: The processed preview display always shows GPU-processed frames. The natural stream carries the cropped-but-uncolor-transformed frame; it is never mixed into the processed preview.
2. **Single memcpy per frame**: After GPU readback, the pixel data is copied exactly once into a shared frame buffer. All registered consumers receive a reference to the same buffer — no per-consumer copies.
3. **Null means "do not change"**: In `CameraSettings`, every field is optional. A null field leaves the current value unchanged. This enables incremental settings updates without re-specifying all parameters.
4. **ISO and exposure are coupled**: Setting either ISO or exposure to auto mode propagates to the other. The underlying camera system does not support independent auto/manual for these two parameters (see `03-camera-control.md`).
5. **Recording encodes GPU output directly**: The video encoder receives processed frames from the GPU render pipeline. There is no intermediate CPU-side frame conversion during recording.
6. **No CPU-side image processing**: There is no OpenCV or similar CPU-based image processing in the current pipeline. All per-frame processing is performed on the GPU.
7. **No audio capture**: The system does not open a microphone input, does not record audio, and does not request microphone permission. Video recordings are silent.

[audit: 01-system-topology.md §Key Architectural Invariants, 12-git-archaeology.md §Phase 7]

---

## Success Criteria

The system is functioning correctly when:

- Frames are delivered to the preview at up to 30fps with no visible stutter under normal conditions.
- GPU color adjustments appear on the preview within one frame of being applied.
- Still image capture produces a file within a few seconds and emits the saved path.
- Video recording runs without dropped frames at 30fps under normal operating conditions.
- C++ consumers receive frames concurrently without blocking the preview or each other.
- State transitions (`"streaming"`, `"recovering"`, `"paused"`, `"error"`, `"closed"`) are emitted accurately and promptly.
- Non-fatal errors trigger recovery without user intervention; the system returns to `"streaming"` after recovery.
- Fatal errors are surfaced to the application and no further state transitions occur.

[audit: 04-pigeon-api.md, 07-state-machine.md, 08-error-recovery.md]

---

## Architectural Evolution Context

The current architecture reached its present form through iterative refinement:

- An early CPU-based image processing path (using OpenCV for color conversion) was removed in favor of the GPU pipeline. No CPU image processing remains.
- Implicit GPU synchronization was replaced with explicit fence-based synchronization after discovering hidden driver stalls.
- Session-level teardown (retaining the camera device across pause/resume) was added to avoid the latency of full device close/open on app background/foreground transitions.

These decisions represent deliberate trade-offs, not accidents. The domain requirements in this directory preserve the behavioral outcomes of those decisions without prescribing the same mechanisms.

[audit: 12-git-archaeology.md §Key Architecture Decisions]
