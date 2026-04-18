# 08 — Capture and Recording

This file specifies behavioral requirements for still image capture and video recording.

---

## Still Image Capture: One Path, Two Equivalent Implementations

The system provides a single still-capture path that produces the GPU-processed frame as an 8-bit TIFF image. Only one capture may be in flight at a time; a concurrent capture request must be rejected.

**Behavioral contract:** The captured image reflects the exact processed output at the time of capture — the same color adjustments (black balance, brightness, contrast, saturation, gamma) that are visible in the processed preview. The user gets what they see.

**Output format:** 8-bit TIFF (lossless relative to the 8-bit output stage; supported on all target platforms). There is no JPEG or PNG output from this path.

**Implementation choice (platform decides):**
- **Sink implementation:** The capture subscribes to the `processed` stream and saves the next delivered frame as a TIFF.
- **Direct readback implementation:** The capture reads directly from the GPU output buffer (e.g., via GPU blit + CPU map) and encodes the result as TIFF.
Both implementations are behaviorally equivalent; the downstream architect chooses based on platform capabilities and latency requirements.

**File disposition:** Written to a caller-provided path or a platform-managed location; absolute file path returned to the caller.

**EXIF:** Sensor metadata (ISO, exposure time, focal length, aperture, focus distance, flash state, white balance, exposure program, pixel dimensions, orientation, capture timestamp) is written to the image metadata after encoding. Non-standard fields may be serialized as structured data in a user comment tag under an application-specific key.

**Concurrency guard:** If a capture is already in flight, the call is rejected immediately. The caller must wait for the in-flight capture to complete before issuing another.

[audit: 10-capture-recording.md §Still Capture: captureImage]

---

## EXIF Orientation

Still images must include correct EXIF orientation metadata. The orientation is computed from the sensor's physical mounting angle relative to the display orientation at capture time.

[audit: 10-capture-recording.md §EXIF Orientation]

---

## Video Recording

### Architecture Requirements

The video encoder must receive GPU-processed frames directly from the GPU render pipeline without CPU-side frame conversion. The GPU render loop presents frames to both the preview display surface and the encoder input surface on each frame.

Recording must not introduce frame drops in the preview; the preview and encoder receive frames from the same GPU render pass.

[audit: 10-capture-recording.md §Video Recording: VideoRecorder, 03-capture-pipeline.md §GpuRenderer Frame Sequence]

---

### Codec Requirements

**Codec:** HEVC 8-bit (H.265). HEVC is assumed available on target platforms; no H.264 fallback. This selection is not user-configurable.

**Note:** The system produces 8-bit encoded output. HEVC Main10 or 12-bit profiles are not required. This matches the 8-bit YUV encoder input produced by the `rgba16f_to_yuv8` compute pass.

[audit: 10-capture-recording.md §Codec Selection]

---

### Audio

The system does not capture audio. Recordings contain a single video track. The system must not request microphone permission.

---

### Recording Parameters

| Parameter | Default | Configurable? |
|---|---|---|
| Bitrate | `TARGET_BITRATE_MBPS` | Yes (API parameter) |
| Frame rate | 30 fps | Yes (API parameter) |
| Output location | System media library, app video folder | Yes (API parameter) |
| Container format | MP4 | No |

[audit: 10-capture-recording.md §Default Parameters, 04-pigeon-api.md §CameraHostApi §startRecording]

---

### Recording State Machine

```
IDLE → PREPARING → RECORDING → STOPPING → IDLE
                              ↘ ERROR
```

- **PREPARING**: The encoder and container muxer are initialized; the encoder input surface is created.
- **RECORDING**: The encoder input surface is connected to the GPU render pipeline; frames begin flowing; the muxer is started after receiving the first encoder output format.
- **STOPPING**: End-of-stream is signaled; the system drains remaining encoded output; the muxer is finalized; the output is made visible in the media library.

[audit: 10-capture-recording.md §VideoRecorder State Machine]

---

### Start Recording Flow

1. Verify the session is in `"streaming"` state and no recording is in flight.
2. Initialize the encoder at the configured resolution, bitrate, and frame rate.
3. Route GPU render output to the encoder input surface.
4. Rebuild the capture request in recording-optimized mode (allows AE frame rate reduction in low-light).
5. Return the output URI and display name to the caller.

The output entry in the media library is marked as pending (not yet visible) until `stopRecording` completes.

[audit: 10-capture-recording.md §startRecording() Flow]

---

### Stop Recording Flow

1. Rebuild the capture request in preview mode (reverts to standard frame rate behavior).
2. Detach the encoder from the GPU render pipeline.
3. Signal end-of-stream to the encoder.
4. Drain all remaining encoded output, up to a **5-second timeout**.
5. Finalize the container.
6. Mark the output as complete in the media library.
7. Return the output URI to the caller.

If the drain times out (5 seconds), the recording is finalized in its current state (truncated), a non-fatal `RECORDING_TRUNCATED` error is emitted, and the URI is still returned.

[audit: 10-capture-recording.md §stopRecording() Flow, §EOS Drain Timeout]

---

### Encoder Output Draining

Encoded output must be drained continuously and asynchronously — the drain loop must not stall the GPU render loop. Encoded packets are written to the container muxer as they become available.

**Container write protocol:** The container muxer track is not started until the encoder signals its output format (which may arrive one or more buffer outputs after recording starts). Once the format is received, the muxer track is created and started, and subsequently encoded buffers are written.

[audit: 02-threading-model.md §Drain Thread, 10-capture-recording.md §Drain Thread]

---

### Recording During Pause

When `pause()` is called during active recording, the recording must stop and the output file must be finalized in the background before the session is fully paused. The exact semantics — whether `pause()` returns synchronously or asynchronously, which callback surfaces the finalized file URL, and behavior on finalization failure — are left to the platform implementation. See `12-unresolved.md` §U-18.

---

### Recording-Sink Back-Pressure

The recording consumer operates with a bounded buffer budget. When a new frame arrives and no buffer capacity is available, the frame is dropped at the recording sink; the camera producer and other consumers are not affected. Every dropped frame is logged. Drops are not surfaced in the UI.

---

### Output URI Protocol

`startRecording()` returns a string in the format `<uri>|<displayName>`, where:
- `<uri>` is the output URI.
- `<displayName>` is the human-readable file name.
- The delimiter is the first `|` character in the string (not a naive split on `|`), to handle display names that contain `|`.

`stopRecording()` returns the output URI string directly.

[audit: 10-capture-recording.md §Content URI vs File Path]
