# 04 — AVFoundation

AVFoundation-specific rules: session management, device state streaming, interruption
handling, orientation.

---

## AVCaptureSession lifecycle (reprise of ADR-07)

All `AVCaptureSession` and `AVCaptureDevice.lockForConfiguration()` operations run on
a dedicated serial queue. The session is created once per `open()`, reused across
pause/resume. See `02-concurrency.md` ADR-07.

### Device capability checks at startup

Never assume a capability; verify against the actual device. At session configuration
time, verify any capability the design depends on and throw a named error if missing.
Examples:

```swift
guard device.activeFormat.isVideoHDRSupported else { /* ... or degrade */ }
guard connection.isVideoRotationAngleSupported(90) else { /* ... */ }
```

The set of supported capabilities varies across device generations and between front
and back cameras on the same device. Hardcoding "A16 supports X" is a trap.

### The view-lifecycle vs interruption split

Two orthogonal signal sources. **Do not conflate them.**

| Source | Signal | Response |
|---|---|---|
| View lifecycle | View appears / disappears (SwiftUI `.task` or UIKit `viewWillAppear`/`viewWillDisappear`) | `startRunning()` / `stopRunning()` on `sessionQueue` |
| System interruptions | `AVCaptureSessionWasInterrupted` / `InterruptionEnded` | Observe, classify, surface UI. Do NOT call `stopRunning()`. |

Calling `stopRunning()` in response to a system interruption races the system and
produces undefined `isRunning`/`isInterrupted` state. Apple's AVCam sample avoids this
by binding start/stop to view lifecycle only.

---

## Interruption reasons

Register for both notifications:

```swift
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionWasInterrupted, ...
)
NotificationCenter.default.addObserver(
    forName: .AVCaptureSessionInterruptionEnded, ...
)
```

The `wasInterrupted` `userInfo` carries `AVCaptureSessionInterruptionReasonKey`.
Handling policy by reason:

| Reason | Meaning | Response |
|---|---|---|
| `videoDeviceNotAvailableInBackground` | App backgrounded | No-op. Await `interruptionEnded`. |
| `videoDeviceInUseByAnotherClient` | FaceTime, another camera app | Show **Resume** button. **Do not auto-resume** — user intent required. |
| `audioDeviceInUseByAnotherClient` | Phone call, audio app | Show Resume button (same policy). |
| `videoDeviceNotAvailableWithMultipleForegroundApps` | iPad Slide Over / Split View / PiP | Show "camera unavailable" label. Cannot be resolved programmatically — user must go full-screen. |
| `videoDeviceNotAvailableDueToSystemPressure` | Thermal throttling | Show "camera unavailable" label. Await `interruptionEnded`. |

On `interruptionEnded`:
- Auto-resume (call `session.startRunning()` on `sessionQueue`) for
  `videoDeviceNotAvailableInBackground` and `videoDeviceNotAvailableDueToSystemPressure`.
- Wait for user intent (Resume button) for the "in use by another client" reasons.

---

## ADR-17: Camera orientation via AVCaptureConnection

Set `AVCaptureConnection.videoRotationAngle` at session configuration time. The
`CVPixelBuffer` arrives pre-rotated — no Metal shader UV transform needed.

```swift
if connection.isVideoRotationAngleSupported(90) {
    connection.videoRotationAngle = 90  // landscape right
}
```

This supersedes the "manual UV transform matrix in a vertex shader" pattern that's
correct on Android (OpenGL ES) but wrong on iOS. AVFoundation handles sensor mounting
angle — trust it.

The exact angle is hardware-dependent. Verify empirically during bring-up (display a
test card with known orientation and confirm the preview matches). Don't hardcode
`90` without checking `isVideoRotationAngleSupported(_:)` — the supported set varies
by device.

---

## ADR-14: KVO → AsyncStream for device state

`AVCaptureDevice` publishes live state via KVO:

- `iso`
- `exposureDuration`
- `whiteBalanceGains`
- `lensPosition`
- `isAdjustingExposure`
- `systemPressureState`

Wrap these as an `AsyncStream` rather than using Combine `@Published`:

```swift
final class DeviceStateStream: @unchecked Sendable {
    func states(for device: AVCaptureDevice) -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { cont in
            let tokens = [
                device.observe(\.iso) { _, _ in cont.yield(Self.snapshot(device)) },
                device.observe(\.exposureDuration) { _, _ in cont.yield(Self.snapshot(device)) },
                // ... other keypaths ...
            ]
            cont.onTermination = { _ in tokens.forEach { $0.invalidate() } }
        }
    }

    private static func snapshot(_ device: AVCaptureDevice) -> DeviceStateSnapshot {
        DeviceStateSnapshot(
            iso: device.iso,
            exposureDuration: device.exposureDuration,
            // ...
        )
    }
}
```

Consume on `@MainActor`:

```swift
Task { @MainActor in
    for await snapshot in deviceStream.states(for: device) {
        viewModel.cameraState = snapshot
    }
}
```

- Terminate the stream cleanly on device reconfiguration; restart on resume.
- No Combine dependency.
- `.task { }` modifier on the SwiftUI view auto-cancels on disappear.
- KVO runs on the thread that made the mutation; yielding into the stream decouples
  observer lifetime from consumer lifetime.

---

## Device configuration windows

`AVCaptureDevice.lockForConfiguration()` / `unlockForConfiguration()` must wrap every
property set:

```swift
try device.lockForConfiguration()
defer { device.unlockForConfiguration() }
device.exposureMode = .custom
device.setExposureModeCustom(
    duration: CMTimeMake(value: 1, timescale: 33),
    iso: 400
) { _ in }
```

- Runs on `sessionQueue`, never on `@MainActor`.
- Coalesce slider input in the UI (e.g. 60Hz debouncer) before committing to the
  queue. Holding the lock per-pixel-dragged is wasteful.
- Mode toggles (auto ↔ manual) are UI state only; switching to auto calls the
  device's `continuousAutoExposure` / `continuousAutoFocus` /
  `continuousAutoWhiteBalance` modes and stops committing manual values.

**Bounds are always read from the device, never hardcoded:**

| Control | Read from |
|---|---|
| ISO | `device.activeFormat.minISO ... .maxISO` |
| Exposure duration | `device.activeFormat.minExposureDuration ... .maxExposureDuration` |
| Lens position | `0.0 ... 1.0` (normalized; see G-11) |
| White balance gain (per channel) | `1.0 ... device.maxWhiteBalanceGain` (see G-10) |

---

## Photo library authorization

`PHPhotoLibrary.performChanges` without authorization crashes on iOS 14+. Before
calling:

```swift
let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
switch status {
case .authorized, .limited:
    break
case .notDetermined:
    let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard granted == .authorized || granted == .limited else { return .denied }
case .denied, .restricted:
    return .denied
@unknown default:
    return .denied
}
// now safe to call performChanges
```

Photo library denial is NOT fatal for the camera session — unlike camera permission
denial. Fall back to a temp file path and surface a non-fatal error.

---

## No-audio as a deliberate constraint

For camera-only apps that don't record audio (scientific imaging, silent video,
surveillance preview), **omit audio entirely**. This is not just an optimization —
it's a policy and UX requirement.

- Do not attach `AVCaptureAudioDataOutput` to the session.
- Do not configure `AVAudioSession`. The system default session is untouched, so
  starting a recording does NOT interrupt the user's music or podcast.
- Do not add `NSMicrophoneUsageDescription` to `Info.plist`. Adding the key without
  actually accessing the microphone is grounds for App Store rejection ("misleading
  usage description").
- Recording writer has a single `AVAssetWriterInput` of media type `.video`. No
  audio input.

If audio is later added, `NSMicrophoneUsageDescription` is required, the audio
session category must be chosen carefully (`.playAndRecord` vs `.ambient`), and
conflict handling with phone calls / music apps becomes a new risk.

---

## systemPressureState KVO

`AVCaptureDevice.systemPressureState` reports thermal / power conditions that affect
capture quality. Observe via KVO (can be integrated into the same
`DeviceStateStream` as other device state):

```swift
device.observe(\.systemPressureState) { device, _ in
    switch device.systemPressureState.level {
    case .nominal, .fair:
        // normal operation
    case .serious:
        // reduce capture preset, drop to lower fps, disable HDR, etc.
    case .critical:
        // stop recording if active; consider full session suspend
    case .shutdown:
        // session already being shut down by the system
    @unknown default: break
    }
}
```

Orthogonal to `ProcessInfo.thermalState` — the device's own view of its pressure.
Both should be observed; the intersection drives degradation policy.

---

## Background recording drain

If recording is active when backgrounding begins, `AVAssetWriter.finishWriting` can
take several seconds. If the process is suspended mid-drain, the MP4 is permanently
corrupted (no `moov` atom).

Request background time:

```swift
let task = UIApplication.shared.beginBackgroundTask(withName: "recording-drain") {
    // expiration handler — cancel rather than leave a corrupt file
    assetWriter.cancelWriting()
    UIApplication.shared.endBackgroundTask(task)
}
await recorder.stop()           // finishWriting + deadline (see ADR-16)
UIApplication.shared.endBackgroundTask(task)
```

Cancelling on expiration produces a clean (empty) file rather than a partial corrupt
one. See G-08.
