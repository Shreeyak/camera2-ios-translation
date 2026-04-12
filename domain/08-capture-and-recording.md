# 08 — Capture and Recording

This file specifies behavioral requirements for still image capture and video recording.

---

## Still Image Capture: Two Paths

The system provides two distinct still capture paths with different characteristics. Both paths are
exposed via the API (see `10-api-contract.md`). Only one capture may be in flight at a time across
both paths; a concurrent capture request must be rejected.

[audit: 10-capture-recording.md §Still Capture: captureNaturalPicture, §Still Capture: captureImage]

---

## Path 1: Hardware-ISP Capture (Natural Picture)

**Behavioral contract:** The system triggers a one-shot capture directly from the camera sensor's ISP output. No GPU color processing is applied. The resulting image reflects only the hardware's native processing (tone mapping, noise reduction, etc.) as configured at the time of capture.

**Use case:** Highest hardware fidelity; use when the exact sensor-processed image is required, not the color-corrected GPU output.

**Output format:** JPEG.

**Quality:** Hardware-determined (ISP-native encoding).

**File disposition:** Written to a cache/temp location; absolute file path returned to the caller.

**EXIF:** Sensor metadata (ISO, exposure time, focal length, aperture, focus distance, flash state, white balance, exposure program, pixel dimensions, orientation, capture timestamp) is written to the EXIF tags after encoding.

**Concurrency guard:** If a capture is already in flight, the call is rejected immediately. The caller must wait for the in-flight capture to complete before issuing another.

**Race condition protection:** The image listener must be installed before the capture trigger is issued (not after) to prevent a race where the image arrives before the listener is registered.

[audit: 10-capture-recording.md §Still Capture: captureNaturalPicture]

---

## Path 2: GPU-Processed Capture

**Behavioral contract:** The system captures the current GPU-processed frame — the exact image visible in the processed preview, including all applied color adjustments (black balance, brightness, contrast, saturation, gamma). The user gets what they see.

**Use case:** Color-corrected capture; use when the output must match the preview.

**Output formats:**
- `.jpg` / `.jpeg` → JPEG, quality 90
- `.png` → PNG lossless
- Other extensions → error `INVALID_FORMAT`

**Output destinations:**
- Explicit path: caller provides a directory and filename; the system encodes and writes directly.
- System media library: caller omits the directory; the system inserts into the system-managed photo library under a designated app folder. The write is atomic from the media library's perspective — the entry is not visible until the write is complete.

**File path returned:** For the system media library path, the absolute file path is resolved from the library after the write completes and returned to the caller.

**EXIF:** Same sensor metadata fields as Path 1, plus non-standard fields serialized as structured data in the EXIF user comment tag under an application-specific key.

[audit: 10-capture-recording.md §Still Capture: captureImage]

---

## EXIF Orientation

Still images must include correct EXIF orientation metadata. The orientation is computed from the sensor's physical mounting angle relative to the display orientation at capture time.

For front-facing cameras, the display rotation is negated in the computation (mirrored behavior).

[audit: 10-capture-recording.md §EXIF Orientation]

---

## Video Recording

### Architecture Requirements

The video encoder must receive GPU-processed frames directly from the GPU render pipeline without CPU-side frame conversion. The GPU render loop presents frames to both the preview display surface and the encoder input surface on each frame.

Recording must not introduce frame drops in the preview; the preview and encoder receive frames from the same GPU render pass.

[audit: 10-capture-recording.md §Video Recording: VideoRecorder, 03-capture-pipeline.md §GpuRenderer Frame Sequence]

---

### Codec Requirements

**Preferred codec:** HEVC (H.265)
**Fallback codec:** H.264 (AVC)

The system must check device capability at recording start and use HEVC when available, falling back to H.264. This selection is not user-configurable in the current API.

[audit: 10-capture-recording.md §Codec Selection]

---

### Recording Parameters

| Parameter | Default | Configurable? |
|---|---|---|
| Bitrate | 50 Mbps | Yes (API parameter) |
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

Encoded output must be drained continuously and asynchronously — the drain loop must not block the GPU render loop. The drain loop polls the encoder output queue with a short timeout per iteration (10ms) and writes encoded packets to the container muxer.

**Container write protocol:** The container muxer track is not started until the encoder signals its output format (which may arrive one or more buffer outputs after recording starts). Once the format is received, the muxer track is created and started, and subsequently encoded buffers are written.

[audit: 02-threading-model.md §Drain Thread, 10-capture-recording.md §Drain Thread]

---

### Recording During Pause

If `pause()` is called while recording is active:
1. Recording is stopped immediately (best-effort; errors are logged but not surfaced).
2. The encoder is detached from the GPU pipeline.
3. A `"idle"` recording state change is emitted to the application layer.
4. The capture session is then torn down.

The application layer must handle the recording stopping automatically without a `stopRecording()` call in this scenario.

[audit: 10-capture-recording.md §Recording During pause()]

---

### Output URI Protocol

`startRecording()` returns a string in the format `<uri>|<displayName>`, where:
- `<uri>` is the output URI.
- `<displayName>` is the human-readable file name.
- The delimiter is the first `|` character in the string (not a naive split on `|`), to handle display names that contain `|`.

`stopRecording()` returns the output URI string directly.

[audit: 10-capture-recording.md §Content URI vs File Path]
