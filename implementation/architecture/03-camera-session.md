# 03 — Camera Session

Primary-owner file for **camera hardware access**: `AVCaptureSession` configuration, device
and format selection, orientation, interruption handling, self-healing, background suspend
and resume. Settings merge is in `07-settings.md`; error classification is in
`09-errors-and-recovery.md`.

---

## Session object lifetime

One `AVCaptureSession` instance per `open()` call. Reused across `pause()` / `resume()` per
G-07 and ADR-07 §Session object is created once per `open()`. Never recreated on
`viewWillAppear` / scenePhase transition — that is the forbidden pattern in
`ios-platform-guide/06-gotchas.md §The forbidden pattern`.

Driven on `sessionQueue` per `02-concurrency.md` §Isolation topology. All lifecycle calls
(`startRunning()`, `stopRunning()`, `beginConfiguration()` / `commitConfiguration()`) go
through the async-with-timeout adapter per ADR-30 with deadline
`constants.md#SESSION_LIFECYCLE_TIMEOUT_SECONDS`.

---

## Device selection

## D-08 — Single physical camera

Minor. Per `domain-revised/01-system-purpose.md` §Session Model (resolves U-17) the product
uses exactly one physical camera: back-facing main lens. Telephoto, ultra-wide, and
front-facing are explicitly out of scope.

Implementation: `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)`
obtained at `open()` time. Absence (unlikely on target hardware, but possible on simulator or
future SKUs) surfaces as `EngineError.noBackCamera`. This is a fatal classification per
`09-errors-and-recovery.md` — no device means no recovery.

### Permission flow

Permission is checked at `open()` time per G-16:
1. `AVCaptureDevice.authorizationStatus(for: .video)` — if `.denied` or `.restricted`, throw
   `EngineError.cameraDenied` (fatal).
2. If `.notDetermined`, `await AVCaptureDevice.requestAccess(for: .video)`; a `false` result
   throws `EngineError.cameraDenied`.
3. Only on `.authorized` does the session configuration proceed.

Photo library permission (`PHPhotoLibrary`) is deferred to `06-capture-and-recording.md`
§Still capture persistence and is handled there; it is not a camera-session-level concern.
No microphone permission is ever requested per G-24 and domain invariant 7 (no audio).

---

## Format selection

### Enumeration

`device.formats` is enumerated at `open()` time (not hardcoded per G-22 and ADR-05). The
selection logic:

1. Filter to 8-bit biplanar YUV (`.420YpCbCr8BiPlanarFullRange` preferred; fall back to the
   lossless variant — `constants.md#CAPTURE_PIXEL_FORMAT`). Half-float and 10-bit YUV are not
   supported on `AVCaptureVideoDataOutput` per G-17.
2. Among remaining formats, select the largest 4:3 dimension
   (`width × 3 == height × 4`), sorted by total pixel count descending
   (`domain-revised/03-camera-control.md §Resolution Selection`).
3. If no 4:3 format is found, fall back to
   `constants.md#CAPTURE_FALLBACK_WIDTH_PX × CAPTURE_FALLBACK_HEIGHT_PX` — the nearest 4:3
   supported on the device. Domain permits this as a degraded path.
4. Among formats meeting the resolution criterion, select the highest-resolution format
   supporting `constants.md#FRAME_RATE_TARGET_FPS` at its frame-duration range.

The resulting `activeCaptureResolution` is returned via `SessionCapabilities`.

### AE frame-rate range

Per U-16 (partial):

- **Preview mode**: `activeVideoMinFrameDuration = activeVideoMaxFrameDuration =
  1/FRAME_RATE_TARGET_FPS`. Fixed rate — the AE system cannot reduce frame rate to gain
  exposure headroom.
- **Recording mode**: `activeVideoMinFrameDuration = 1/FRAME_RATE_TARGET_FPS`;
  `activeVideoMaxFrameDuration = 1/FRAME_RATE_RECORDING_MIN_FPS`. AE may halve the frame
  rate in low-light; recording frame rate floor is `constants.md#FRAME_RATE_RECORDING_MIN_FPS`.

`setVideoFrameDurationRange(minFps:maxFps:)` on `CaptureDeviceProviding` commits the range
inside a `lockForConfiguration()` window. Repeating-request "mode switching" between preview
and recording is driven by `06-capture-and-recording.md` §Start / Stop flows.

### Supported sizes

`AVCaptureDevice.formats` converted to `[Size]` for the `supportedSizes` field of
`SessionCapabilities`. Per domain, `setResolution()` must name a size in this list;
rejections are `EngineError.noSupportedFormat`.

---

## Orientation

### Angle commit

Per ADR-17, orientation is set on the `AVCaptureConnection`, not on a shader UV transform:

```
if connection.isVideoRotationAngleSupported(CAPTURE_ORIENTATION_ANGLE_DEG) {
    connection.videoRotationAngle = CAPTURE_ORIENTATION_ANGLE_DEG
}
```

`constants.md#CAPTURE_ORIENTATION_ANGLE_DEG` is 90 (landscape-right, USB port on the left
after rotation). Verified empirically in Stage 01 bring-up per ADR-17 §The exact angle is
hardware-dependent. If `isVideoRotationAngleSupported` returns false for 90°, throw
`EngineError.noSupportedFormat`.

Orientation is owned by `AVCaptureConnection` — `CVPixelBuffer`s arrive pre-rotated and
IOSurface-backed textures honour the rotation. The shader pipeline receives already-
correct orientation and never applies a UV transform.

---

## Configuration windows

Every device mutation goes through a `lockForConfiguration() / unlockForConfiguration()`
window driven on `sessionQueue`. The `defer { device.unlockForConfiguration() }` pattern
from `ios-platform-guide/04-avfoundation.md §Device configuration windows` is the
authoritative shape. Merging of `CameraSettings` happens on the engine actor
(`07-settings.md`); the resulting snapshot is then committed via a single lock window.

ISO + exposure is committed via `setExposureModeCustom(duration:iso:completionHandler:)` —
coupled per the hardware API (the two are not independently settable on iOS, matching the
domain's coupling rule). Focus, white balance, zoom are independent commits inside the
same lock window; mode toggles (auto ↔ manual) switch to
`continuousAutoExposure` / `continuousAutoFocus` / `continuousAutoWhiteBalance` and stop
committing manual values. Slider input is coalesced in the UI layer at the Hz rate before
dispatch (`08-ui.md` §Slider coalescing).

---

## ISO and exposure coupling

Domain rule lives in `07-settings.md` §ISO + Exposure coupling (Rules 1/2/3). This file
states only the **application step**: after the merge on the engine actor, the resulting
snapshot is translated to either `setExposureModeCustom(durationNs:iso:)` (manual) or
`setContinuousAutoExposure()` (auto). There is no `ISO manual + exposure auto` state on
iOS — the API shape matches the domain coupling rule structurally.

---

## Focus

## D-07 — `focusDistance` maps 1:1 to `lensPosition`

Minor. `AVCaptureDevice.lensPosition` is the normalized `[0.0, 1.0]` value (G-11). The
domain `focusDistance` field uses the same `[0.0, 1.0]` range; the mapping is the
identity: `setFocusModeLocked(lensPosition: Float(focusDistance))`.

During autofocus (`continuousAutoFocus` mode, scanning), `FrameResult.focusDistance` is
emitted as `nil` per `domain-revised/03-camera-control.md §Focus`. The engine reads
`device.lensPosition` but also checks `device.isAdjustingFocus`; while adjusting, the
published metadata uses `nil`.

---

## White balance

`.auto`, `.locked`, `.manual` correspond to AVFoundation's `continuousAutoWhiteBalance`,
`locked`, and `manual with gains` respectively. Manual gains are clamped to
`[1.0, device.maxWhiteBalanceGain]` per G-10 before committing (rejecting a gain outside the
range would be a silent no-op; clamping preserves intent while honouring API limits).

Calibration (`sampleCenterPatch()` → compute gains → set manual) is driven by
`08-ui.md` §Color calibration sidebar → the UI calls `engine.sampleCenterPatch()` and
`engine.updateSettings(.init(wbMode: .manual, wbGainR: …, …))` in sequence. The engine does
not open its own pathway to calibration.

---

## Zoom

`device.videoZoomFactor` is set directly inside a lock window. Range is
`[1.0, device.maxAvailableVideoZoomFactor]`. Pinch gestures in `08-ui.md` dispatch
coalesced values to `updateSettings(.init(zoomRatio: …))`. The product is
`constants`-free for zoom: the maximum is a device capability read at `open()` time.

---

## EV compensation

`device.setExposureTargetBias(_:completionHandler:)` inside a lock window. Only valid in
auto-exposure mode (domain rule); in manual mode the value is accepted but has no effect.
The UI validates this in `08-ui.md` §Camera parameter controls (bar collapsed).

---

## Interruption handling

Registered observers:

- `AVCaptureSessionWasInterrupted`
- `AVCaptureSessionInterruptionEnded`

Per `ios-platform-guide/04-avfoundation.md §Interruption reasons` (authoritative table),
handling policy by `AVCaptureSessionInterruptionReasonKey`:

| Reason | Response |
|---|---|
| `videoDeviceNotAvailableInBackground` | No-op. Await `interruptionEnded`. |
| `videoDeviceInUseByAnotherClient` | Transition to terminal `.error` with `CAMERA_IN_USE` (fatal). On `interruptionEnded` with this reason, reset state to `.closed` (D-14) and wait for host `open()`. |
| `audioDeviceInUseByAnotherClient` | N/A — no audio input (G-12, G-24). |
| `videoDeviceNotAvailableWithMultipleForegroundApps` | Emit non-fatal `CAMERA_ACCESS_ERROR`; UI shows "camera unavailable"; await `interruptionEnded`. |
| `videoDeviceNotAvailableDueToSystemPressure` | Emit non-fatal `CAMERA_ACCESS_ERROR`; UI shows "camera unavailable"; await `interruptionEnded`; auto-resume on return. |
| `sensitiveContentMitigationActivated` | Treat as manual-resume-required; user intent drives `open()` re-entry. |

**Do not call `stopRunning()` in response to an interruption** per G-06 and ADR-08 §Three state
machines. The session is already interrupted; calling `stopRunning` produces undefined state.

---

## Background suspend and resume

Two signal sources per `ios-platform-guide/04-avfoundation.md §The view-lifecycle vs
interruption split` (authoritative), not conflated in this file:

- **View lifecycle**: driven by `08-ui.md` — view disappear stops the session via
  `sessionQueue` + timeout. `open()` + `close()` map here.
- **System interruptions**: driven by the observers above — no `stopRunning`, observe-only.

`backgroundSuspend()` per domain is the host signalling that the app is entering background.
On iOS this corresponds to `scenePhase == .background` per ADR-08. The engine:

1. Cancels any pending recovery retry (Inv 9 via the stored retry `Task`).
2. Gates GPU submission (sequence A, `02-concurrency.md`).
3. Stops `AVCaptureSession` via `sessionQueue` (ADR-30 timeout).
4. If recording was active, begins the background-task drain — see
   `06-capture-and-recording.md` §Background drain.

The session is **not** torn down — configuration is retained per `05-resource-lifecycle.md`
§Application Lifecycle Integration.

`backgroundResume()` signals `scenePhase == .active`:
- Ungate GPU submission.
- `AVCaptureSession` restarts automatically via `interruptionEnded` if the suspension reason
  was system-initiated; else the host's explicit call drives `startRunning()` via
  `sessionQueue`.
- Persisted settings are reapplied after the session restarts — `07-settings.md` §Persistence.

---

## Self-healing from `CAMERA_IN_USE`

Primary-owner: `09-errors-and-recovery.md` §Self-healing (D-14). This file only specifies
the **session-layer piece**: the `AVCaptureSessionInterruptionEnded` observer checks the
reason; if `videoDeviceInUseByAnotherClient`, it calls `engine.resetFromTerminal()` which
transitions the engine from `.error` to `.closed`. Re-entry to `.streaming` requires the host
to call `open()` (for iOS policy, per `ios-platform-guide/04-avfoundation.md`).

This implements the domain's self-healing intent (no user action inside the camera layer)
within the iOS constraint that auto-resume is not permitted for this reason (see
`open-questions.md` §OQ-04 for the full disposition).

---

## Capture output configuration

One `AVCaptureVideoDataOutput` attached to the session; its `videoSettings` use the
enumerated 8-bit biplanar YUV format. `alwaysDiscardsLateVideoFrames = true` per the
domain's drop-on-busy semantics (ADR-13 / Invariant 10 — AVFoundation's own drop policy
matches the consumer-level drop discipline). The delegate and delivery queue are configured
per `02-concurrency.md` §Isolation topology.

No `AVCaptureAudioDataOutput` — domain invariant 7 + G-12.

No `AVCapturePhotoOutput` — still capture uses the Metal blit path per D-05; `AVCapturePhotoOutput`
would bypass Metal and violate the domain contract that "the user gets what they see"
(domain 08 §Still Image Capture) and can silently downgrade video resolution per G-09.

---

## Teardown

### Full teardown (close / fatal / recovery retry)

Per `domain-revised/05-resource-lifecycle.md` §Full Teardown Order, delegated to the engine actor:

1. Disarm watchdogs (`09-errors-and-recovery.md`, also step 1 of recovery — domain 06).
2. Stop recording if active (`06-capture-and-recording.md` §Stop recording flow).
3. `sessionQueue.async { session.stopRunning(); session.beginConfiguration(); remove inputs/outputs;
   session.commitConfiguration() }`.
4. Release Metal pipeline (`04-metal-pipeline.md` §Teardown).
5. Release consumer-registry handle; the native `C++` pipeline is released with Invariant 4
   mutual-exclusion protocol (`05-consumers.md` §Native pipeline lifetime, D-15).
6. Release `AVCaptureDevice` reference; CF releases the device.
7. Reset counters (retry count, stall timestamp, consecutive-HW-error count).

All steps run on the engine actor in a single actor-serialized method. Errors during teardown
are logged; the sequence does not short-circuit.

### Session-only teardown (pause / `setResolution`)

Per `domain-revised/05-resource-lifecycle.md` §Session-Only Teardown, the **device is NOT
closed**. Runs the same ordering as full teardown but skips step 6. Used by `pause()` and by
`setResolution()` — the latter resizes Metal pool textures to the new dimensions during the
session-only teardown window with `constants.md#RESOLUTION_RESIZE_TIMEOUT_SECONDS` deadline;
on timeout, the pre-resize state is restored (domain 05).
