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

## Input Format

The camera sensor delivers frames in a planar YUV format (4:2:0 chroma subsampling, the largest 4:3 aspect ratio resolution the sensor supports). The GPU pipeline receives these frames directly via a hardware texture binding — no CPU-side format conversion is performed.

Default fallback resolution: **1280×960** (4:3), used when no 4:3 YUV resolution is reported by the camera hardware.

[audit: 03-capture-pipeline.md §stream-configuration]

---

## GPU Processing Pipeline

Each frame follows this sequence:

1. **Texture update**: The GPU receives the latest camera frame from the hardware texture binding.
2. **Processed render**: The GPU renders the frame through the color processing fragment shader into a GPU render target, producing RGBA output at full stream resolution.
3. **Preview surface swap**: The processed frame is presented to the preview display surface. If this swap fails three consecutive times, the system triggers a preview surface rebind procedure.
4. **Encoder blit** (recording only): The processed frame is blitted to the video encoder's input surface.
5. **Asynchronous readback**: A GPU readback command is submitted targeting an alternate asynchronous readback buffer (double-buffered — one buffer is being written while the other is being read).
6. **Fence insertion**: A GPU fence is inserted after the readback command to mark GPU completion.
7. **Previous buffer map**: The readback buffer from the prior frame is mapped to CPU memory (after its fence is confirmed complete).
8. **Frame copy**: The pixel data is copied once into a shared frame buffer.
9. **Consumer dispatch**: The shared frame buffer is distributed to all registered C++ consumers.

**Double-buffer semantics**: Frame delivery is always one frame behind the rendered frame. Frame N is delivered to consumers during the processing of frame N+1.

[audit: 03-capture-pipeline.md §GpuRenderer Frame Sequence, 05-gpu-opengl.md §PBO Readback Protocol]

---

## Asynchronous Readback Synchronization

The system must not block the GPU render loop waiting for readback completion. The following fence-based synchronization protocol must be maintained:

- Before reading the completed buffer, the system polls the GPU fence with a zero timeout.
- If the fence is not yet signaled, the system waits up to **8ms** for it.
- If the fence is still not signaled after 8ms, the system issues a full GPU flush and logs an error. This is a degraded-path fallback.

The 8ms fence timeout is chosen to avoid stalling the render loop while allowing reasonable GPU completion time. Repeated fence timeouts indicate GPU performance degradation.

[audit: 05-gpu-opengl.md §PBO Readback Protocol, 03-capture-pipeline.md §PBO Double-Buffer]

---

## Parallel Stream Outputs

The GPU pipeline produces up to four simultaneous output streams per frame:

| Stream | Resolution | Processing | Consumer |
|---|---|---|---|
| Processed (full-res) | Stream resolution | All color transforms applied | Processed preview display + C++ consumers |
| Tracker | 480px fixed height, aspect-preserving width (even-pixel-rounded) | All color transforms applied | C++ tracker consumers |
| Natural (full-res) | Stream resolution | No color transforms (passthrough) | Natural preview display only (no C++ consumers) |
| Encoder | Stream resolution | All color transforms applied | Video encoder input (when recording) |

"Natural" is the product's term for the passthrough stream — frames that have not traversed the GPU color-adjustment stage. This is distinct from photography "RAW" (Bayer sensor data); natural frames are still demosaiced, they simply have no brightness/contrast/saturation/gamma/black-balance transforms applied.

Not all streams are active simultaneously:
- The natural stream requires explicit enablement at session open time.
- The encoder stream is only active during recording.
- The tracker stream is always available when sinks are registered.
- The tracker 480px height is a fixed compile-time value [resolves U-15]. It is not exposed as a runtime-tunable parameter; downstream design should preserve the fixed height.
- The natural stream is display-only. C++ consumer registration targets only the processed and tracker streams [resolves U-13].

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
| `focusDistanceDiopters` | float | Actual lens focus distance |
| `aeState` | int32 | Auto-exposure convergence state |
| `afState` | int32 | Auto-focus convergence state |
| `awbState` | int32 | Auto-white-balance convergence state |
| `flashState` | int32 | Flash state |

Metadata is transferred alongside pixel data for every frame. The values reflect what the sensor actually captured, not what was requested in settings.

[audit: 06-cpp-sinks.md §FrameMetadata, 03-capture-pipeline.md §JNI Metadata Transfer]

---

## Pixel Format

All delivered frames use **RGBA8888** (4 bytes per pixel, 8 bits per channel, red-green-blue-alpha). Stride (bytes per row) is included in the frame descriptor and may be larger than `width * 4` due to alignment.

[audit: 06-cpp-sinks.md §PixelFormat, §SinkFrame]

---

## Back-Pressure Behavior

The system uses **drop-on-busy semantics** for consumer delivery. If a consumer is slow, newer frames overwrite pending frames in the consumer's 1-slot mailbox. The GPU render loop and preview display are never blocked by slow consumers.

There is no backpressure mechanism that would cause the camera hardware to slow down in response to slow consumers.

[audit: 06-cpp-sinks.md §Delivery Path, 02-threading-model.md §C++ ProcessingStage Threads]

---

## Frame Stall Detection

Two independent stall detection mechanisms run concurrently:

**GPU-level stall** (monitors frame arrival at the GPU pipeline):
- Threshold: **3000ms** of no frame arrival.
- Check interval: **1000ms**.
- On stall: emits a non-fatal `FRAME_STALL` error to the application layer. Does not trigger session recovery.

**Capture-result-level stall** (monitors frame completion acknowledgments from the camera hardware):
- Threshold: **5000ms** of no completion notification.
- Check interval: **3000ms**.
- On stall: triggers non-fatal error handling and recovery (full teardown and reinitialization).
- The stall check is initialized at session start to prevent false positives before the first frame arrives.

Both watchdogs are cancelled immediately during session teardown.

[audit: 03-capture-pipeline.md §Stall Watchdog, 08-error-recovery.md §Stall Watchdog]

---

## Frame Result Heartbeat

The system periodically samples actual sensor metadata and emits it to the application layer at approximately **3 Hz** (every 10th completion notification at 30fps). This is used by the UI to display current ISO, exposure, focus, and white balance values.

FPS monitoring runs on a separate heartbeat (every 30 completion notifications). If the computed fps from `frameDurationNs` falls below **15.0 fps** for **3 consecutive heartbeats**, a non-fatal `FPS_DEGRADED` notification is emitted.

[audit: 09-camera-controls.md §CamFrameResult Delivery, 08-error-recovery.md §FPS Degradation]
