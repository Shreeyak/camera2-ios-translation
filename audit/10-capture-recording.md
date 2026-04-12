# 10 — Still Capture and Video Recording

## Still Capture: captureNaturalPicture

Path: Camera2 hardware ISP → JPEG `ImageReader`

**No GPU post-processing**. The ISP encodes JPEG directly. Color transforms, LUT, brightness/contrast/saturation/gamma are NOT applied. Use this path when hardware-fidelity JPEG is required.

Flow:
1. `captureNaturalPicture(callback)` — runs on `backgroundHandler`.
2. Guard: `isCaptureInFlight.compareAndSet(false, true)` — rejects concurrent captures.
3. Register `OnImageAvailableListener` on `jpegReader` (on `backgroundHandler`) BEFORE triggering capture (eliminates listener-install/image-arrival race).
4. Build one-shot `CaptureRequest` with `TEMPLATE_STILL_CAPTURE`, targeting `jpegReader.surface` only.
5. `session.capture(jpegRequest, null, backgroundHandler)`.
6. Listener fires: acquires image from `jpegReader`, writes bytes to `<cacheDir>/capture_<timestamp>.jpg`.
7. Calls `writeExifMetadata(file, lastCaptureSnapshot)`.
8. Clears `isCaptureInFlight = false` in `finally`.
9. Posts `callback(Result.success(filePath))` to `mainHandler`.

## Still Capture: captureImage

Path: GPU pipeline → C++ `ImagePipeline::captureToFile` / `captureToFd` → JPEG or PNG

**Includes GPU post-processing** (all color transforms, LUT, etc.). Matches exactly what the user sees.

Format detection: from `fileName` extension. `.jpg` / `.jpeg` → JPEG (quality 90). `.png` → PNG (lossless). Others → error `INVALID_FORMAT`.

Two output paths:
- **Explicit directory** (`outputDirectory != null`): `nativeCaptureImage(pipelinePtr, absolutePath, jpegQuality)` — C++ encodes and writes directly to path.
- **MediaStore default** (`outputDirectory == null`):
  1. Insert into `MediaStore.Images` with `IS_PENDING=1`, `RELATIVE_PATH = Pictures/CambrianCamera`.
  2. Open writable fd from content URI.
  3. `nativeCaptureImageToFd(pipelinePtr, fd, isJpeg, jpegQuality)` — C++ encodes to fd.
  4. Write EXIF via separate `rw` fd.
  5. Clear `IS_PENDING=0`.
  6. Query `DATA` column for absolute file path.

EXIF metadata written after encoding: ISO, exposure time, focal length, aperture, focus distance, flash, white balance, exposure program, pixel dimensions, orientation, capture timestamp. Non-standard Camera2 fields serialized as JSON in `TAG_USER_COMMENT` under `"camera2"` key.

## EXIF Orientation

Orientation is computed from sensor mounting angle + display rotation:
```
adjustedDeg = if (front-facing): (sensorOrientation - displayDeg + 360) % 360
              else:              (sensorOrientation + displayDeg) % 360
```
Front cameras negate display rotation (mirrored).

## Video Recording: VideoRecorder

### Architecture
- MediaCodec in surface-input mode (encoder surface → receives tone-mapped GPU frames directly from EGL blit).
- No CPU YUV copy. Encoder gets RGBA frames via the EGL surface.
- MediaMuxer for MP4 container.
- Drain HandlerThread (`"RecorderDrain"`) handles `dequeueOutputBuffer` loop asynchronously.
- Output: MediaStore (`Movies/CambrianCamera/` by default), `IS_PENDING` pattern same as captureImage.

### VideoRecorder State Machine
```
IDLE → PREPARING → RECORDING → STOPPING → IDLE
                              ↘ ERROR
```
- `PREPARING`: `prepare(width, height, bitrate, fps)` — initializes `MediaCodec` (`video/hevc` preferred, `video/avc` fallback), creates encoder surface (`MediaCodec.createInputSurface()`).
- `RECORDING`: `start(outputDirectory, fileName)` — creates MediaStore entry, starts codec + drain thread. Returns `RecordingResult(uri, displayName)`.
- `STOPPING`: `stop()` — signals EOS (`signalEndOfInputStream`), waits for drain thread (5s timeout), finalizes MediaMuxer, clears IS_PENDING. Returns content URI string.

### Drain Thread
Polls `dequeueOutputBuffer(bufferInfo, DRAIN_TIMEOUT_US=10_000us)`:
1. On `INFO_OUTPUT_FORMAT_CHANGED`: `muxer.addTrack(format)` + `muxer.start()`.
2. On valid buffer: `muxer.writeSampleData(trackIndex, buffer, bufferInfo)`, `releaseOutputBuffer()`.
3. On `BUFFER_FLAG_END_OF_STREAM`: exits loop.
4. On `INFO_TRY_AGAIN_LATER` after EOS signaled: timeout after 5s → `wasEosDrainTimedOut = true`.

### EOS Drain Timeout
If drain doesn't complete within 5s: `wasEosDrainTimedOut()` returns `true`. `stopRecording()` emits non-fatal `RECORDING_TRUNCATED` error to Dart.

### Codec Selection
Priority: `video/hevc` (HEVC/H.265) → `video/avc` (AVC/H.264). Falls back to AVC if HEVC codec is unavailable.

### Default Parameters
- Bitrate: 50 Mbps
- FPS: 30
- Output: `Movies/CambrianCamera/`

## startRecording() Flow

```kotlin
fun startRecording(outputDirectory, fileName, bitrate, fps, callback) {
    backgroundHandler.post {
        if (state != STREAMING || isRecording) { error }
        videoRecorder = VideoRecorder(context)
        videoRecorder.prepare(previewWidth, previewHeight, bitrate, fps)
        val surface = videoRecorder.inputSurface
        val result = videoRecorder.start(outputDirectory, fileName)
        gpuPipeline.setEncoderSurface(surface)   // route GPU output to encoder
        recordingFps = configuredFps
        isRecording = true
        rebuildRepeatingRequest()                // switch to TEMPLATE_RECORD
        callback(Result.success("${result.uri}|${result.displayName}"))
    }
}
```

`gpuPipeline.setEncoderSurface(surface)` — posts to GL thread: `nativeGpuSetEncoderSurface(surface)` → `GpuRenderer::setEncoderSurface()` creates `eglEncoderSurface_` from the MediaCodec surface. Each frame, `eglSwapBuffers(eglEncoderSurface_)` is called after the preview swap.

## stopRecording() Flow

```kotlin
fun stopRecording(callback) {
    backgroundHandler.post {
        if (!isRecording) { error }
        isRecording = false
        rebuildRepeatingRequest()           // revert to TEMPLATE_PREVIEW
        gpuPipeline.setEncoderSurface(null) // detach encoder
        val uri = recorder.stop()           // blocks on drain thread (up to 5s)
        if (recorder.wasEosDrainTimedOut()) { emit RECORDING_TRUNCATED }
        callback(Result.success(uri))
    }
}
```

## Recording During pause()

When `pause()` is called while `isRecording == true` (guarded in `teardown()` but also handled in the auto-stop code path from the plan at `fix-pause-recording-and-kdoc.md`):
```kotlin
if (isRecording) {
    isRecording = false
    gpuPipeline?.setEncoderSurface(null)
    try { videoRecorder?.stop() } catch (e: Exception) { log }
    mainHandler.post { flutterApi.onRecordingStateChanged(handle, "idle") {} }
}
```

## Content URI vs File Path

`startRecording()` returns `"${result.uri}|${result.displayName}"`. The Dart layer splits on the first `|` character (not naive `split('|')` — uses `indexOf` to handle `|` in filenames).

`stopRecording()` returns the MediaStore content URI string (e.g., `content://media/external/video/media/42`).

`captureImage()` default path returns the absolute file path resolved from `MediaStore.Images.Media.DATA` column (populated for app-created files on API 33).
