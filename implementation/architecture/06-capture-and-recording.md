# 06 — Capture and Recording

Primary-owner file for **still capture** and **video recording**. Touches
`04-metal-pipeline.md` (encoder compute pass, still blit pass), `05-consumers.md` (concurrency
guard on still capture via native atomic), `02-concurrency.md` (scenePhase drain sequence),
`09-errors-and-recovery.md` (recording-state error codes).

---

## Still image capture

## D-05 — Direct Metal-blit readback

Minor. The domain allows either a subscription-based implementation or a direct GPU-readback
implementation (`domain-revised/08-capture-and-recording.md` §Still Image Capture). Direct
readback is preferred here because:

- The consumer-subscription shape would require a transient single-shot consumer on the
  `.processed` lane, racing with existing subscribers — extra machinery for an equivalent
  outcome.
- Direct readback matches the in-flight atomic guard (Invariant 7) and ADR-03 §Direct GPU
  outputs §Still capture readback cleanly.

Flow:
1. `captureImage(outputPath:)` is invoked on the engine actor.
2. Engine checks session state — must be `.streaming` (domain); else
   `EngineError.invalidState` / `InvalidState`.
3. Engine performs an atomic compare-and-swap on the C++-side `captureRequested_` flag
   (Invariant 7 / Invariant 8, lock-free per domain). If already in-flight, throw
   `StillCaptureError.alreadyInFlight`.
4. On the next camera frame, Pass 6 (`04-metal-pipeline.md` §Command graph) appends a blit
   from `processedTex` → the still readback `CVPixelBuffer` (single-slot, RGBA16F).
5. The command buffer's completion handler (with the D-10 re-entrancy guard) signals the
   engine; engine reads the readback buffer CPU-side.
6. Engine encodes 8-bit TIFF via `CGImageDestination` — see §Still capture encoding.
7. Engine clears `captureRequested_` atomic.
8. Engine returns `StillCaptureOutput` with the resolved file path.

Concurrency guard: only one capture in-flight. The atomic is in the C++ imaging core per
ADR-13 §C-ABI (fast-path) and `02-concurrency.md` row `C-ABI std::atomic<bool>`.

### Output format: 8-bit TIFF

Always 8-bit TIFF per domain 08-capture-and-recording. No JPEG, no PNG in this path. The
architecture does not support a user-selected format parameter;
`ErrorCode.invalidFormat` is reserved for future use per domain 10-api-contract §ErrorCode.

The RGBA16F readback buffer is converted to 8-bit RGB on the CPU side immediately before
writing. A `vImage` or equivalent (Accelerate framework) fp16 → uint8 conversion is the
expected path; implementation detail for Stage 06.

## D-09 — EXIF `"CamPlugin/v1"` envelope

Minor. The standard EXIF dictionary carries well-known fields; non-standard sensor fields
go under `kCGImagePropertyExifUserComment` keyed by `"CamPlugin/v1"`. The JSON schema for
that key is deferred to Stage 05 per `open-questions.md` §U-09 — the key, the envelope, and
the TIFF writing mechanism (`CGImageDestination`) are fixed here.

### Standard EXIF fields — encoding details

`CGImageDestination` with `AVFileType.tiff` UTI (`UTType.tiff`), single-image destination.
EXIF metadata is written as a standard EXIF dictionary under
`kCGImagePropertyExifDictionary`; the domain's non-standard sensor fields are packed into a
JSON string under `kCGImagePropertyExifUserComment` keyed by `"CamPlugin/v1"` (D-09).

The JSON schema for `"CamPlugin/v1"` is **deferred to Stage 05 of the implementation
pipeline**, per `open-questions.md` §U-09. The envelope (key and presence under
`UserComment`) is fixed now.

Standard EXIF fields written:
- ISO (`EXIF:ISOSpeedRatings` — list of 1).
- Exposure time (`EXIF:ExposureTime` — rational, from `exposureTimeNs`).
- Focal length, aperture — from `AVCaptureDevice` active format.
- Focus distance, flash state, white-balance gains — sensor metadata.
- Exposure program — `manual` or `program` per ISO/exposure mode.
- Pixel dimensions — `TIFF:ImageWidth`, `TIFF:ImageLength`.
- Orientation — `TIFF:Orientation` — landscape-right at
  `constants.md#CAPTURE_ORIENTATION_ANGLE_DEG` commits orientation at capture time per ADR-17
  / domain 08 §EXIF Orientation.
- Capture timestamp — `TIFF:DateTime`, `EXIF:DateTimeOriginal`.

Photo-library delivery: if `outputPath` is nil, `PHPhotoLibrary.performChanges` inserts the
TIFF via `NSPhotoLibraryAddUsageDescription` path (G-29). Authorization is requested at
capture time per G-04; denial is **non-fatal** per `ios-platform-guide/04-avfoundation.md`
§Photo library authorization — the engine falls back to an app-documents temp path and
surfaces a non-fatal `ErrorCode.cameraAccessError` (repurposed) or reserved for UI display.
If `outputPath` is non-nil, the file is written directly; no photo-library interaction.

---

## Video recording

## D-04 — Recording container and codec (HEVC in MP4)

Minor. Per `domain-revised/08-capture-and-recording.md` §Codec Requirements, the codec is
HEVC 8-bit and the container is MP4. No H.264 fallback (HEVC is assumed available on all
target iOS devices), no HEVC Main10 / 12-bit (encoder input is 8-bit YUV per ADR-06 §
Encoder compute pass). The `AVAssetWriter` is configured with `AVFileType.mp4`.

`AVVideoCodecKey` = `AVVideoCodecType.hevc`.

### Architecture

GPU-to-encoder zero-copy per ADR-06:

1. `AVAssetWriterInputPixelBufferAdaptor` with `sourcePixelBufferAttributes`:
   - `kCVPixelBufferPixelFormatTypeKey`: `constants.md#ENCODER_PIXEL_FORMAT` (NV12,
     video-range — match VideoToolbox native encoder input).
   - `kCVPixelBufferIOSurfacePropertiesKey`: `[:]`.
   - `kCVPixelBufferMetalCompatibilityKey`: `true`.
2. Per frame while recording: dequeue a `CVPixelBuffer` from the adaptor's
   `pixelBufferPool`; wrap as two `MTLTexture`s (Y + CbCr) via the shared
   `CVMetalTextureCache`.
3. Pass 5 (`04-metal-pipeline.md`) runs a compute kernel that reads `processedTex` (RGBA16F)
   and writes directly into the Y + CbCr plane textures: BT.709 RGB → YCbCr (video-range,
   matching the format), half-float → 8-bit quantization, 2×2 chroma downsample.
4. `adaptor.append(pixelBuffer, withPresentationTime: pts)` — VideoToolbox consumes the
   same IOSurface; no CPU copy.

`MTLTexture.getBytes` is forbidden on this path per ADR-06. `MTLBlitCommandEncoder.copy`
cannot be used because the format conversion is neither same-format nor same-precision
(G-32).

### Parameters

| Parameter | Default | Configurable? |
|---|---|---|
| Bitrate | `constants.md#TARGET_BITRATE_MBPS` | Yes (API: `RecordingOptions.bitrateBps`) |
| Frame rate | `constants.md#FRAME_RATE_TARGET_FPS` | Yes (API: `RecordingOptions.fps`) |
| Output location | System photo library under app-designated video folder | Yes (API: `RecordingOptions.outputDirectory` + `.fileName`) |
| Container | MP4 | No (D-04) |
| Codec | HEVC | No (D-04) |

No audio track — domain invariant, G-12, G-24.

### Recording state machine

```
IDLE → PREPARING → RECORDING → STOPPING → IDLE
                              ↘ ERROR
```

State is published on `CameraEngine.recordingStateStream()` per `api-surface.md`. Transitions:

- **IDLE → PREPARING**: `startRecording(options:)` called; `AVAssetWriter` created;
  `AVAssetWriterInput` configured; pixel-buffer adaptor wired.
- **PREPARING → RECORDING**: writer's first successful `append` of a frame transitions. First
  `encoder.outputFormatDescription` arrival triggers muxer track creation; subsequent frames
  append.
- **RECORDING → STOPPING**: `stopRecording()` called; `AVAssetWriterInput.markAsFinished()`
  signalled; `AVAssetWriter.finishWriting` called with deadline
  `constants.md#RECORDING_FINISH_TIMEOUT_SECONDS`.
- **STOPPING → IDLE**: `finishWriting` completion fires; muxer output URI returned.
- **Any → ERROR**: any `AVAssetWriter.Status == .failed` transition surfaces
  `RecordingError.writerStartFailed` or `.appendFailed`; engine emits fatal
  `RECORDING_START_FAILED` / `RECORDING_FAILED` via `errorStream`.

### Start flow

1. Verify session state == `.streaming`; no recording in flight.
2. Bump AE frame-rate range to recording-mode (`03-camera-session.md` §AE frame-rate range)
   inside `lockForConfiguration()` window on `sessionQueue`.
3. Create `AVAssetWriter` with output URL (resolved from `RecordingOptions`).
4. Create `AVAssetWriterInput` for media type `.video` with `AVVideoCodecType.hevc`,
   `AVVideoWidthKey` / `AVVideoHeightKey` from the crop region, and
   `AVVideoCompressionPropertiesKey = [AVVideoAverageBitRateKey: bitrate]`.
   `expectsMediaDataInRealTime = true`.
5. Wire pixel-buffer adaptor.
6. `assetWriter.startWriting()`; `assetWriter.startSession(atSourceTime: currentPresentationTime)`.
7. Engine sets `isRecording = true`, which gates Pass 5 in the per-frame command graph.
8. Return `RecordingStart(uri: fileURL.absoluteString, displayName: fileName)`.

### Stop flow

1. Rebuild capture request in preview mode (revert AE frame-rate range) on `sessionQueue`.
2. Engine sets `isRecording = false`; Pass 5 stops appending.
3. `AVAssetWriterInput.markAsFinished()`.
4. Concurrent tasks:
   - `Task { await writer.finishWriting() }`.
   - `Task { try? await Task.sleep(for: .seconds(RECORDING_FINISH_TIMEOUT_SECONDS)); writer.cancelWriting() }`.
   The deadline task races the finish task per ADR-16 §Finalize with a timeout deadline.
5. If the finish task wins: return the output URI on `recordingStateStream` as the
   transition to `.idle`.
6. If the deadline wins: `writer.cancelWriting()` produces an empty file; engine emits
   non-fatal `RECORDING_TRUNCATED` per domain 06, returns the (empty) URI.
7. Container finalization: on `.mp4` with an empty `moov` atom the file is unusable — per
   ADR-16 and G-08, an empty file is preferable to a corrupt one; the user sees "recording
   cancelled by system."

### Drain and muxer discipline

Per domain 08 §Encoder Output Draining, encoded output is drained continuously; the drain
must not stall the GPU render loop. On iOS this is automatic — `AVAssetWriter` runs its own
internal encoding queue. The engine's only obligation is to not `append` from the GPU
pipeline faster than real-time for extended periods, which would pressure VideoToolbox; the
`expectsMediaDataInRealTime = true` flag signals the encoder to prioritize real-time
input.

### Background drain

Primary-owner section for the background-recording drain sequence. Cross-cited from
`02-concurrency.md` §Sequence A.

Per `ios-platform-guide/04-avfoundation.md` §Background recording drain (authoritative).
Summarized here:

1. On `scenePhase → .background` with `isRecording == true`, engine calls
   `UIApplication.shared.beginBackgroundTask(withName: "recording-drain")` and stores the
   identifier.
2. Engine invokes the Stop flow (above) with the deadline = `RECORDING_FINISH_TIMEOUT_SECONDS`.
3. `beginBackgroundTask` expiration handler **always** calls `writer.cancelWriting` —
   never `finishWriting` (G-08). An interrupted `finishWriting` produces a corrupt MP4
   (no `moov`); cancelling produces an empty file.
4. On drain completion (either `finishWriting` returned or `cancelWriting` fired), engine
   calls `UIApplication.shared.endBackgroundTask(identifier)`.
5. User-facing language for a background-cancelled recording: "recording cancelled by
   system" — the partial file is not surfaced.

### U-18 resolution — pause-during-recording

Primary-owner file for the U-18 resolution (see `open-questions.md` §U-18 for the
disposition summary).

When `pause()` is called while recording is active:
1. Engine runs the Stop flow with the standard timeout.
2. On drain completion, `recordingStateStream` emits `.idle` carrying the output URI via a
   companion `RecordingStopResult` sidecar published on the same actor tick (the URI is
   carried alongside the state transition through a Swift-side `Task` that completes after
   `finishWriting`). Implementation shape: a `Task` returning `String` awaited by the
   pause caller; the URI is published on the state stream as metadata once available.
3. Engine proceeds with session-only teardown per `03-camera-session.md` §Session-only
   teardown.
4. `pause()` returns only after the state machine has transitioned to `.paused`. Callers
   that need the recording URI observe it via `recordingStateStream` (or via the `pause()`
   async return if they wait for it specifically).

Fatal finalization failure emits `RECORDING_FAILED` (fatal) via `errorStream` before the
state transition; `pause()` then returns with the session having transitioned to `.error`.

---

## Recording-sink back-pressure

Per `domain-revised/08-capture-and-recording.md` §Recording-Sink Back-Pressure: when the
encoder pool has no buffer capacity, the frame is dropped at the recording sink only. The
camera producer and other consumers are not affected. Drops are logged via
`FrameDeliveryStats.poolExhaustion` (D-11) — invisible to production UI.

The encoder pool is pre-sized per ADR-06; in practice, a slow encoder produces back-pressure
via `CVPixelBufferPoolCreatePixelBuffer` returning `kCVReturnWouldExceedAllocationThreshold`.
On that return, Pass 5 is skipped for that frame (the frame still appears on preview and
other consumer lanes); `poolExhaustion` increments; a warning is logged identifying the
recorder lane.

---

## Pause / crop / resolution interactions

- `setResolution()`: tears down the recording (stop flow) before session-only teardown per
  domain 05-resource-lifecycle §Session-only teardown step 2. The output URI from the
  truncated recording is returned via `recordingStateStream` as the transition to `.idle`.
- `setCropRegion()`: recording continues; the new crop takes effect on the next frame with
  no discontinuity in the encoded stream (the crop change is reflected in the compute
  pass; frame-by-frame the crop parameters move, no resolution change so the encoder
  format is unaffected).
- `pause()` during recording: see §U-18 resolution above.
- `close()` during recording: full teardown runs with the stop flow as its recording step,
  matching pause behavior but followed by device close.

---

## Mode switching: preview ↔ recording

The only capture-request property that changes between modes is the AE frame-rate range
(covered in `03-camera-session.md` §AE frame-rate range). Still capture reads GPU-processed
output from the running repeating request — there is no "still capture" request mode
(correct per domain + U-17 + `domain-revised/03-camera-control.md` §Capture Mode for
Repeating Requests / still-capture-not-a-distinct-mode).

---

## Teardown

Recording teardown is step 2 of full teardown (`03-camera-session.md` §Full teardown) and
step 2 of session-only teardown. It always runs the stop flow (finish or cancel depending
on deadline). On fatal finalization error, the file is left in whatever state the writer
produced — the caller sees the error and decides whether to attempt cleanup.
