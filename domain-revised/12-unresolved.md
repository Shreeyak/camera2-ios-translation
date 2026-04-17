# 12 — Unresolved

This file collects items requiring downstream architect resolution before the design is final. All previously resolved items have been removed; see git history or `CHANGES.md` for disposition.

Items are numbered for cross-reference with the original audit numbering.

---

## U-08: Supported Camera Resolutions and Capability Discovery

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN (rationale partially resolved)

**Resolved (rationale):** 4:3 is the native aspect ratio of the image sensor on the target hardware. Selecting the largest 4:3 resolution maps directly to "use the sensor's native full resolution." Downstream design should preserve the largest-4:3 selection rule and treat any non-4:3 fallback as a degraded path.

**Still open:** Determine the target platform's mechanism for discovering supported capture resolutions and formats. The behavioral requirements (prefer largest 4:3, fallback to ~1280×960, expose list via `open()` capabilities response) are in `01-system-purpose.md` and `03-camera-control.md`.

[audit: 03-capture-pipeline.md §stream-configuration, 04-pigeon-api.md §CamCapabilities]

---

## U-09: EXIF Metadata Field Schema

**Type:** PARTIALLY RESOLVED

**Settled:** The TIFF/EXIF writing approach is `CGImageDestination`. Standard sensor tags (ISO, exposure, focus, white balance) go via `kCGImagePropertyExifDictionary`. Non-standard fields are serialized as a JSON string under `kCGImagePropertyExifUserComment` using the key `"CamPlugin/v1"`.

**Still open:** The specific JSON field names and schema for the `"CamPlugin/v1"` user comment object are not yet specified. Define during Phase 5 by comparing the exact fields written by the Android source and confirming which subset is meaningful on the target platform.

[design: design/05-implementation-phases.md §Phase 5, design/07-ios-specific-risks.md R-17]

---

## U-16: AE FPS Range Policy for Preview vs. Recording

**Type:** PARTIALLY RESOLVED

**Settled:** Preview mode uses a fixed frame duration (`activeVideoMinFrameDuration = activeVideoMaxFrameDuration = 1/targetFps`). Recording mode allows AE to reduce frame rate in low-light (`activeVideoMaxFrameDuration = 1/(targetFps/2)`).

**Still open:** The fallback behavior when the device does not support an exact fixed-rate range in preview mode requires empirical testing on target hardware during Phase 1a. No fallback policy is specified yet.

[design: design/07-ios-specific-risks.md R-14, design/05-implementation-phases.md §Phase 1b]

---

## U-18: Pause-During-Recording Finalize Semantics

**Type:** UNRESOLVED

When `pause()` is invoked during active recording, the recording must stop and the output file must be finalized in the background before the session is fully paused. The following questions are left to the platform implementation:

1. **Synchrony of `pause()`:** Does `pause()` return before or after recording finalization completes? If before, what signals completion?
2. **Finalization callback:** Which callback surfaces the finalized file URL — `onRecordingStateChanged`, a dedicated event, or a return value from `pause()`?
3. **Failure handling:** If finalization fails (encoder error, disk full), how is the error surfaced and is a partial file returned?

Until resolved, implementations must at minimum stop the encoder, finalize the container file (even if truncated), and surface fatal finalization failures via `onError`.

[domain: 08-capture-and-recording.md §Recording During Pause]
