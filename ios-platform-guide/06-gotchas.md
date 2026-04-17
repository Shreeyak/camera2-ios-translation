# 06 — Gotchas

Quick-reference table of iOS failure modes and API pitfalls. These are stable
platform facts, not architectural decisions. Every entry is something that will
crash or silently degrade an app if missed.

---

## API pitfalls

| # | Pitfall | Correct handling |
|---|---|---|
| G-01 | `CVMetalTextureCacheCreateTextureFromImage` returns `kCVReturnSuccess` + nil texture under memory pressure | Nil-check `CVMetalTextureGetTexture` return; drop frame on nil (see ADR-15) |
| G-02 | `MTLCommandBuffer` errors are silent without `addCompletedHandler` status check | Always install handler; check `cb.status == .error` |
| G-03 | `AVCaptureSession.startRunning()` blocks 100–500ms | Never call on `@MainActor`; use `sessionQueue` (ADR-07) |
| G-04 | `PHPhotoLibrary.performChanges` crashes without authorization on iOS 14+ | Check + request `.addOnly` before `performChanges` |
| G-05 | Metal command submission in background → process termination (`MTLCommandBufferErrorNotPermitted`, IOAF code 6) | Atomic gate + `waitUntilScheduled()` on `scenePhase == .inactive` (ADR-09) |
| G-06 | Stopping `AVCaptureSession` in response to system interruption races the system | Only stop on view-lifecycle signals; observe `wasInterrupted` without acting |
| G-07 | Recreating `AVCaptureSession()` on every scene appearance incurs full hardware re-init | Create once per `open()`, reuse across pause/resume |
| G-08 | `AVAssetWriter.finishWriting` mid-backgrounding → corrupt MP4 (no `moov` atom) | `beginBackgroundTask` + expiration handler calls `cancelWriting` |
| G-09 | `AVCapturePhotoOutput` attached concurrently with `AVCaptureVideoDataOutput` at max resolution can silently downgrade video output resolution | Verify `CVPixelBufferGetWidth/Height` on sample buffers after adding photo output |
| G-10 | White balance gains passed outside `[1.0, device.maxWhiteBalanceGain]` → `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains` fails | Clamp before setting |
| G-11 | `lensPosition` is 0.0–1.0 normalized, **not** diopters | Don't display as diopters without per-device calibration; label as relative focus |
| G-12 | Camera-only apps shouldn't claim audio — avoids conflict with phone calls, music | If not capturing audio, don't attach `AVCaptureAudioDataOutput`; no `NSMicrophoneUsageDescription` needed |
| G-13 | `CVPixelBuffer` is not `Sendable` as of iOS 26 | Confine to one isolation domain; `sending` where transferred (ADR-10) |
| G-14 | `sessionQueue.async { session.startRunning() }` then immediately reading `session.isRunning` from main — race | Use a state stream or completion callback from `sessionQueue` |
| G-15 | `CVMetalTextureCache` holds onto textures beyond current frame → steady memory growth | Release the `CVMetalTexture` object each frame (not just the Metal texture); or `CVMetalTextureCacheFlush` on memory warning |
| G-16 | `AVCaptureDevice.authorizationStatus` returns `.notDetermined` on first launch | Call `requestAccess(for: .video)` and await result before configuring session |
| G-17 | Capture format 10-bit / half-float not supported on most iOS camera outputs | Enumerate `device.formats` at startup; convert to working format in first Metal pass (ADR-05) |
| G-18 | BGRA channel-order coefficients applied to RGBA buffers → silently wrong grayscale (no crash, no error) | Consumer path is always RGBA; BT.709 weights must be `(0.2126, 0.7152, 0.0722, 0.0)` in that order. See channel-order table in `03-metal.md`. |
| G-19 | Status-bar camera indicator remains active >1s after backgrounding → App Store rejection (policy, not just runtime bug) | `session.stopRunning()` must complete before the view-layer task returns on `.background` |
| G-20 | Between `commandBuffer.commit()` and `addCompletedHandler` firing, the engine may have run `close()` / `backgroundSuspend()` / `setResolution()` → handler touches released buffers | Capture `sessionState` at commit; check equality + `.streaming` in handler before acting. See `02-concurrency.md §Completion-handler re-entrancy guard`. |
| G-21 | `VTFrameProcessor` looked like a fit for custom color transforms, isn't | Does system-defined effects only (deblur, super-res, denoise). Use custom Metal compute for app-owned color pipelines. See `03-metal.md §VTFrameProcessor`. |
| G-22 | Device capability assumed, not verified → silent malfunction on other device models | Check `isVideoHDRSupported`, `isVideoRotationAngleSupported(_:)`, and similar per-capability flags at session config; throw named errors on missing capability. |
| G-23 | Running CV on the full-resolution processed stream instead of the tracker stream → 15–25ms per frame, misses budget | Subscribe CV consumers to tracker stream (~480p, ~0.3M px). Canny budget 2–4ms at that resolution on A16. |
| G-24 | Adding `NSMicrophoneUsageDescription` without using the mic → App Store rejection ("misleading usage description") | Only declare usage keys for permissions actually requested at runtime. |

---

## scenePhase / lifecycle quick reference

| scenePhase | Triggers on | Action |
|---|---|---|
| `.active` | Foreground, receiving events | Resume GPU gate, start streaming |
| `.inactive` | App switcher, notification banner, incoming call, Control Center | **Gate GPU**, do not stop session |
| `.background` | Fully off-screen | Stop session via `sessionQueue` |

- `UIApplicationDelegate.applicationWillResignActive` ≈ `.inactive`
- `UIApplicationDelegate.applicationDidEnterBackground` ≈ `.background`

Full treatment in `02-concurrency.md` ADR-08, ADR-09.

---

## Capture format facts (device-dependent)

- Most recent iPhones + A16 iPad: camera emits 8-bit biplanar YUV only. Half-float
  and 10-bit YUV are **not supported** on `AVCaptureVideoDataOutput`.
- Convert to working format in the first Metal pass, not at capture configuration.
- Full-sensor resolutions (~4160×3120 on A16) are typically 30fps-only; 60fps
  requires a smaller format.
- ProRes / ProRAW paths have different rules and are out of scope here.

Always enumerate `device.formats` at startup and pick the highest-resolution format
meeting your frame-rate and pixel-format requirements. Don't hardcode dimensions.

---

## The forbidden pattern

```swift
// ❌ DO NOT DO THIS
func viewWillAppear() {
    session = AVCaptureSession()   // recreating on every appearance
    configureInputsAndOutputs()
    session.startRunning()
}
```

The "reopen device on every resume" port from Camera2. It:
- Defeats shallow-teardown across pause/resume.
- Incurs full hardware re-initialization latency on every foreground.
- Causes audio/video sync issues if audio is ever added.
- Gives iOS camera apps their "sluggish on foreground" reputation.

Correct: `AVCaptureSession` is created once per `open()` call;
`startRunning()` / `stopRunning()` toggle it across view lifecycle.

---

## Sources

- Apple Developer: "Preparing your Metal app to run in the background"
- Apple Developer: AVCam sample code (`SessionViewController.swift`)
- Apple Developer: AVFoundation Programming Guide — Running and Stopping a Session
- Apple Developer: `AVCaptureSessionInterruptionReason` documentation
- Apple Developer: `MTLCommandBuffer.waitUntilScheduled()` documentation
- Apple Developer: Human Interface Guidelines — Camera
- Swift.org: C++ Interoperability, Safe Interop
- SE-0430: `sending` parameter and result values
