# 07 — Performance Budgets

This file specifies timing constraints, memory limits, and throughput targets that the system
must meet to be considered correctly functioning.

---

## Frame Rate

| Target | Value | Notes |
|---|---|---|
| Preview frame rate | 30 fps | Upper bound; achieved in normal conditions |
| FPS degradation threshold | 15.0 fps | Sustained fps below this for 3 heartbeats triggers `FPS_DEGRADED` notification |
| Heartbeat interval | Every 30 frames | FPS monitoring sample interval |
| Recording upper bound | Configured encoder fps (default 30) | AE may reduce actual sensor rate in low-light |

[audit: 08-error-recovery.md §FPS Degradation, 07-state-machine.md §Key Constants, 10-capture-recording.md §Default Parameters]

---

## GPU Pipeline Timing

| Budget | Value | Notes |
|---|---|---|
| GPU fence wait | Per-frame budget | Maximum wait for GPU readback completion; falls back to full GPU flush on expiry |
| Frame delivery lag | 1 frame | Asynchronous double-buffered readback: consumers receive frame N during processing of frame N+1 |

The GPU fence wait budget is chosen to prevent stalling the render loop while allowing reasonable GPU completion time. Exceeding this budget forces a blocking GPU flush, which may cause a visible frame drop. Repeated fence timeouts indicate GPU performance degradation. Specific timeout values are platform measurements; see `measurements/` for empirically validated values.

[audit: 05-gpu-opengl.md §PBO Readback Protocol, 03-capture-pipeline.md §PBO Double-Buffer]

---

## Stall Detection Timeouts

| Watchdog | Threshold | Check Interval |
|---|---|---|
| GPU-level stall (frame arrival) | 3000ms | 1000ms |
| Capture-result-level stall | 5000ms | 3000ms |

Both watchdogs run concurrently and independently. The GPU-level watchdog reports a `FRAME_STALL` non-fatally without triggering recovery. The capture-result-level watchdog triggers full recovery on timeout.

[audit: 03-capture-pipeline.md §Stall Watchdog, 08-error-recovery.md §Stall Watchdog]

---

## Recovery Backoff Schedule

| Retry attempt | Delay |
|---|---|
| 1st | 500ms |
| 2nd | 1000ms |
| 3rd | 2000ms |
| 4th | 4000ms |
| 5th | 8000ms |
| 6th (fatal) | — |

Maximum retry attempts before fatal error: **5**. The total maximum recovery time before a fatal error is declared is approximately 15.5 seconds (sum of all delays), not counting the time for each reopen attempt.

Retry count resets to 0 on every successful camera device open.

[audit: 08-error-recovery.md §Exponential Backoff, 07-state-machine.md §Key Constants]

---

## HAL Error Threshold

The system tolerates transient hardware-level frame capture failures without entering recovery. Recovery is triggered only after **5 consecutive** hardware-level failures.

Consecutive failure count resets to 0 on every successful frame completion.

[audit: 08-error-recovery.md §HAL Error Threshold, 07-state-machine.md §Key Constants]

---

## AE Convergence Budget

The AE convergence timeout is a platform measurement, not a domain contract. If auto-exposure remains in a searching state beyond the platform-defined timeout, a non-fatal `AE_CONVERGENCE_TIMEOUT` notification is emitted. This is informational only — no recovery action is taken. Specific timeout values belong in `measurements/`.

[audit: 08-error-recovery.md §AE Convergence Timeout, 07-state-machine.md §Key Constants]

---

## Memory: Frame Buffer

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

## Consumer Processing Budget

Consumers use **drop-on-busy** semantics with a 1-slot mailbox. A consumer that cannot process a frame before the next frame arrives will drop the older frame.

There is no explicit budget imposed on consumer processing time. However, a consumer that consistently fails to complete within one frame duration (33ms at 30fps) will drop every other frame at a minimum.

[audit: 06-cpp-sinks.md §Delivery Path, 02-threading-model.md §C++ ProcessingStage Threads]

---

## Resolution Change Timeout

`setResolution()` includes a GPU pipeline resize step. This step has a maximum timeout of **5 seconds**. If the resize does not complete within 5 seconds, the operation fails non-fatally.

[audit: 09-camera-controls.md §setResolution Flow, 07-state-machine.md §Key Constants]

---

## Video Recording: Drain Timeout

When stopping a recording, the encoder output drain has a maximum timeout of **5 seconds**. If the drain does not complete in 5 seconds, the recording is finalized in its current (possibly truncated) state, a `RECORDING_TRUNCATED` non-fatal error is emitted, and the output URI is returned.

[audit: 10-capture-recording.md §EOS Drain Timeout, 07-state-machine.md §Key Constants]

---

## Preview Surface Failure Threshold

If the preview display surface swap fails on **3 consecutive frames**, the system triggers a preview surface rebind. This threshold prevents noise (a single swap failure) from triggering unnecessary rebinds while still detecting persistent surface invalidation quickly.

[audit: 05-gpu-opengl.md §Preview Surface Rebind]

---

## Per-Frame Metadata Transfer Overhead

Metadata is transferred per frame using two flat arrays (not per-field calls) to minimize inter-layer communication overhead. The arrays are pre-allocated and reused across frames.

Array sizes:
- Long array (5 elements): sensor timestamp, exposure time, frame duration, ISO, focus distance
- Integer array (4 elements): AE state, AF state, AWB state, flash state

This is an implementation-level detail noted here for its performance implication: per-frame metadata has O(1) transfer overhead proportional to the fixed array sizes, not to the number of fields.

[audit: 03-capture-pipeline.md §JNI Metadata Transfer]

---

## Center-Patch Sampling

`sampleCenterPatch()` reads a **96×96 pixel** patch from the center of the most recently rendered GPU-processed frame. The computation applies a histogram trimmed mean (discarding the top and bottom 10% of intensity values) to produce R, G, B mean values.

This operation runs on the GPU rendering execution context and must not block the render loop. The result is delivered asynchronously via callback.

[audit: 05-gpu-opengl.md §sampleCenterPatch, 04-pigeon-api.md §CameraHostApi]
