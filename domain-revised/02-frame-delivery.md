# 02 — Frame Delivery

This file specifies the behavioral requirements for how frames flow from the camera sensor through
GPU processing to preview display and consumer dispatch.

---

## Frame Rate Target

The system must deliver processed frames at up to **30 frames per second** under normal operating conditions.

The frame rate is governed by the camera capture request configuration:
- In preview mode, the system selects a fixed-rate range (where the lower and upper frame rate bound are equal) from the set of ranges the camera hardware supports. If no fixed-rate range is available at 30fps, the system uses the highest available sustained rate.
- In recording mode, the system allows the auto-exposure system to reduce frame rate in low-light conditions (the upper bound is the configured encoder fps; the lower bound is half that value).

[audit: 03-capture-pipeline.md §Repeating Request, 09-camera-controls.md §AE FPS Range Selection]

---

## Capture Format and Crop

The camera sensor delivers frames in an **8-bit YUV 4:2:0 full-range planar** format at an operator-selected **capture resolution** (default: the largest 4:3 resolution the device supports, typically around 4160×3120). The GPU pipeline receives these frames directly via a hardware texture binding — no CPU-side format conversion is performed.

Before any color processing, the GPU **center-crops** the captured frame to an operator-selected **crop region** (default: 1600×1200). The crop region drives the resolution of every downstream stream: processed, natural, and encoder all carry the crop-sized frame. The tracker stream is further downscaled from this crop (see Parallel Stream Outputs below).

Both capture resolution and crop region may be set at session open and adjusted at runtime. Any capture resolution the device supports is valid; if the device does not report a 4:3 resolution, a fallback is selected (e.g., ~1280×960 4:3). The default capture / crop pair represents the intended operating point; alternative pairs are permitted for development and diagnostic use.

[audit: 03-capture-pipeline.md §stream-configuration]

---

## GPU Processing Pipeline

Each frame follows this sequence:

1. **Texture update**: The GPU receives the latest camera frame from the hardware texture binding (8-bit YUV 4:2:0).
2. **Crop and convert**: The GPU center-crops to the operator-selected crop region and converts from YUV to the working color format (RGBA16F, half-float). The result is the **natural** frame.
3. **Processed render**: The GPU renders the natural frame through the color-processing fragment shader (black balance → brightness → contrast → saturation → gamma) into a second RGBA16F target. The result is the **processed** frame.
4. **Preview surface swap**: The processed frame is presented to the processed preview surface, and the natural frame to the natural preview surface. If either swap fails three consecutive times, the system triggers a preview-surface rebind procedure.
5. **Encoder blit** (recording only): The processed frame is converted to the encoder-input format and blitted to the video encoder's input surface.
6. **Asynchronous readback**: A GPU readback command is submitted targeting an alternate asynchronous readback buffer (double-buffered — one buffer is being written while the other is being read).
7. **Fence insertion**: A GPU fence is inserted after the readback command to mark GPU completion.
8. **Previous buffer map**: The readback buffer from the prior frame is mapped to CPU memory (after its fence is confirmed complete).
9. **Frame copy**: The pixel data is copied once into a shared frame buffer.
10. **Consumer dispatch**: The shared frame buffer is distributed to all registered consumers of the `natural`, `processed`, and `tracker` streams.

**Double-buffer semantics**: Frame delivery is always one frame behind the rendered frame. Frame N is delivered to consumers during the processing of frame N+1.

[audit: 03-capture-pipeline.md §GpuRenderer Frame Sequence, 05-gpu-opengl.md §PBO Readback Protocol]

---

## Asynchronous Readback Synchronization

The system must not block the GPU render loop waiting for readback completion. The fence-based synchronization contract is:

- Before reading the completed buffer, the system polls the GPU fence with a zero timeout.
- If the fence is not yet signaled, the system waits up to the **per-frame budget** for it.
- If the fence is still not signaled by the end of the per-frame budget, the system issues a full GPU flush and logs an error. This is a degraded-path fallback.

Specific timeout values are platform measurements, not domain contracts; see `sla.md` / `measurements/` for measured values. Repeated fence timeouts indicate GPU performance degradation.

**Publication ordering constraint**: FrameSet construction and the consumer mailbox swap must occur as the final action *inside* the GPU completion handler callback — after the fence signals GPU completion, not inline on any other execution context after the command buffer is committed. Submitting a command buffer only schedules GPU work; it does not guarantee GPU completion. Any implementation that swaps the mailbox before the completion handler fires delivers a FrameSet backed by uninitialized or stale pixel data. No assertion will fire; all consumer frames will be silently corrupt.

[audit: 05-gpu-opengl.md §PBO Readback Protocol, 03-capture-pipeline.md §PBO Double-Buffer]

---

## Parallel Stream Outputs

The GPU pipeline produces up to four simultaneous output streams per frame:

| Stream | Resolution | Processing | Format | Consumer |
|---|---|---|---|---|
| `natural` | Crop region | Crop + YUV→RGB conversion only; no color transforms | RGBA16F (half-float) | Natural preview display + subscribers |
| `processed` | Crop region | Crop + YUV→RGB + all color transforms | RGBA16F (half-float) | Processed preview display + subscribers |
| `tracker` | 480px fixed height, aspect-preserving width (even-pixel-rounded) | Downscaled from `processed` | RGBA16F (half-float) | Subscribers (e.g., ML inference) |
| Encoder | Crop region | All color transforms applied | Platform-defined encoder input format | Video encoder (when recording) |

"Natural" is the product's term for the cropped-but-color-untransformed stream — frames that have not traversed the color-adjustment stage. Cropping and YUV-to-RGB color-space conversion are not considered "processing" for this purpose. This is distinct from photography "RAW" (Bayer sensor data); natural frames are still demosaiced and converted to a display color space.

Active-stream rules:
- The natural, processed, and tracker streams are always produced when the session is streaming.
- The encoder stream is only active during recording.
- The tracker 480px height is a fixed compile-time value [resolves U-15]. It is not exposed as a runtime-tunable parameter; downstream design should preserve the fixed height.
- All three streams (`natural`, `processed`, `tracker`) are subscribable via the consumer-registration surface [reverses U-13]. Subscription is opt-in; streams with no subscribers incur no dispatch cost.

[audit: 03-capture-pipeline.md §Raw Stream Path, §Tracker Downscale, 06-cpp-sinks.md §SinkRole]

---

## Preview Surface Delivery

The processed and natural frame streams are delivered to the UI layer via display surface abstractions provided by the UI framework (not via CPU pixel buffers). The GPU renders directly to these surfaces — no CPU frame copy is involved in display.

If the preview display surface becomes invalid (e.g., app backgrounding), the system detects consecutive swap failures and triggers a surface rebind: a new display surface is obtained from the UI framework and bound to the GPU pipeline without restarting the capture session.

[audit: 03-capture-pipeline.md §GpuPipeline, 05-gpu-opengl.md §Preview Surface Rebind]

---

## Consumer Dispatch Semantics

**Zero-copy fan-out**: After the single CPU-side frame copy (readback buffer → shared frame buffer), all registered C++ consumers receive a reference to the same buffer. No additional copies are made per consumer.

**Drop-on-busy**: If a consumer is still processing the previous frame when a new frame arrives, the new frame overwrites the pending unprocessed frame. The consumer processes only the most recent frame — older frames are discarded. This ensures consumers never block the delivery pipeline.

**Consumer callback lifetime**: The pixel data pointer passed to a consumer callback is valid only for the duration of that callback. If a consumer needs to retain the data, it must copy it before returning.

[audit: 06-cpp-sinks.md §Delivery Path, §ProcessingStage Thread Loop, 01-system-topology.md §Key Architectural Invariants]

---

## Frame Metadata

Each delivered frame carries the following per-frame sensor metadata:

| Field | Type | Description |
|---|---|---|
| `sensorTimestampNs` | int64 | Sensor-reported timestamp in nanoseconds |
| `exposureTimeNs` | int64 | Actual sensor exposure duration |
| `frameDurationNs` | int64 | Actual frame duration (inverse of frame rate) |
| `iso` | int64 | Actual sensor sensitivity |
| `focusDistance` | float | Actual lens focus distance, normalized `[0.0, 1.0]` (units are platform-defined; see `03-camera-control.md`) |
| `aeState` | int32 | Auto-exposure convergence state |
| `afState` | int32 | Auto-focus convergence state |
| `awbState` | int32 | Auto-white-balance convergence state |
| `flashState` | int32 | Flash state |

Metadata is transferred alongside pixel data for every frame. The values reflect what the sensor actually captured, not what was requested in settings.

[audit: 06-cpp-sinks.md §FrameMetadata, 03-capture-pipeline.md §JNI Metadata Transfer]

---

## Pixel Format

All three delivered streams (`natural`, `processed`, `tracker`) use **RGBA16F** — four half-float channels (red, green, blue, alpha), 8 bytes per pixel. Half-float is used because the color-transform chain (black balance → brightness → contrast → saturation → gamma) compounds quantization error when computed at 8-bit precision.

The 8-bit YUV 4:2:0 full-range capture format is an internal detail of the capture-to-GPU binding; consumers do not see it.

Stride (bytes per row) is included in the frame descriptor and may be larger than `width * 8` due to alignment.

[audit: 06-cpp-sinks.md §PixelFormat, §SinkFrame]

---

## Back-Pressure Behavior

The system uses **drop-on-busy semantics** for consumer delivery. If a consumer is slow, newer frames overwrite pending frames in the consumer's 1-slot mailbox. The GPU render loop and preview display are never blocked by slow consumers.

There is no backpressure mechanism that would cause the camera hardware to slow down in response to slow consumers.

[audit: 06-cpp-sinks.md §Delivery Path, 02-threading-model.md §C++ ProcessingStage Threads]

---

## Frame Stall Detection

See `06-error-and-recovery.md` for detection thresholds and recovery behavior.

**Watchdog lifecycle**:
- Each watchdog is dormant until its first successful observation — first frame arrival for the GPU watchdog, first capture-result completion for the capture watchdog. Stalls cannot be reported before the first frame.
- Both watchdogs are disarmed as step 1 of teardown and as step 1 of recovery, before any capture, GPU, or encoder resource is released.
- A watchdog callback that fires after its session has been torn down is a no-op (see `04-concurrency-invariants.md`: watchdog callbacks observe only the session that was current when they were armed).

[audit: 03-capture-pipeline.md §Stall Watchdog, 08-error-recovery.md §Stall Watchdog]

---

## Frame Result Heartbeat

The system periodically samples actual sensor metadata and emits it to the application layer at approximately **3 Hz** (every 10th completion notification at 30fps). This is used by the UI to display current ISO, exposure, focus, and white balance values.

See `06-error-and-recovery.md` for detection thresholds and recovery behavior.

[audit: 09-camera-controls.md §CamFrameResult Delivery, 08-error-recovery.md §FPS Degradation]

---

## Memory: Frame Buffer Formulas

Frame buffer sizes depend on the operator-selected crop resolution and the working pixel format. Use these formulas:

- `FRAME_WORKING_MB = crop_w × crop_h × bpp(format) / 1_048_576`
  where `bpp(RGBA16F) = 8` (4 channels × 2 bytes/channel).
- `READBACK_MB = FRAME_WORKING_MB × DOUBLE_BUFFER_DEPTH`
  (double-buffering: depth = 2).
- `TRACKER_WORKING_MB = tracker_w × tracker_h × bpp(format) / 1_048_576`
  where tracker height is 480px and width is aspect-preserving from the crop region.

**Tracker format is an open ADR**: the tracker stream may be delivered as RGBA16F (same as processed/natural), R16F (grayscale half-float), or R8 (grayscale 8-bit). The choice depends on consumer needs and affects `bpp`. Until the ADR is resolved, use RGBA16F (bpp=8) as the conservative estimate.

All registered consumers receive a reference to the same frame allocation — no per-consumer copies.

Concrete measured values belong in `measurements/`, not in domain.

[audit: 01-system-topology.md §UI Overview (4160×3120 resolution), 03-capture-pipeline.md §Tracker Downscale, 06-cpp-sinks.md §IImagePipeline]

---

## Center-Patch Sampling

`sampleCenterPatch()` reads a **96×96 pixel** patch from the center of the most recently rendered GPU-processed frame. The computation applies a histogram trimmed mean (discarding the top and bottom 10% of intensity values) to produce R, G, B mean values.

This operation runs on the GPU rendering execution context and must not block the render loop. The result is delivered asynchronously via callback.

[audit: 05-gpu-opengl.md §sampleCenterPatch, 04-pigeon-api.md §CameraHostApi]
