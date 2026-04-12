# 07 — iOS-Specific Risks

---

## Risk Register

| # | Risk | Phase | Likelihood | Impact | Mitigation |
|---|---|---|---|---|---|
| R-01 | Thermal throttling causes preview frame drops or session suspension | 1a, 4 | High | High | `ProcessInfo.ThermalState` monitoring installed in Phase 1a; full response in Phase 4: reduce fps at `.serious`, suspend at `.critical`; restore on thermal relief |
| R-02 | System pressure (`AVCaptureDevice.systemPressureState`) degrades camera quality | 1a, 4 | Medium | Medium | KVO observer on `systemPressureState`; at `.elevated` reduce capture preset; at `.critical` stop recording first, then reduce further |
| R-03 | Camera permission denial at first launch | 1a | High | High | `PermissionManager` handles all `AVAuthorizationStatus` cases; `waitingForPermission` → `permissionDenied` with actionable Settings deep-link |
| R-04 | Camera permission revocation mid-session | 1a | Low | High | `AVCaptureSessionRuntimeErrorNotification` with `AVError.mediaServicesWereReset` detected; treated as fatal `PERMISSION_DENIED` error; self-heal not possible for revoked permission |
| R-05 | Multi-app camera conflict (FaceTime, Phone) causes session interruption | 1a, 4 | Medium | High | `AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps` caught via `AVCaptureSessionWasInterruptedNotification`; triggers non-fatal recovery; self-heal via `AVCaptureSessionInterruptionEndedNotification` |
| R-06 | App lifecycle: camera released on partial occlusion (wrong signal) | 1a | Low | High | `scenePhase == .background` is the trigger (not `.inactive`); tested with Control Center, notification banner overlay — camera must NOT release on those transitions |
| R-07 | OpenCV iOS headers incompatible with Swift-C++ direct interop | 3 | High | Medium | Documented in design; ObjC++ bridge (`.mm`) used for all OpenCV code; generic `IFrameConsumer` interface uses direct Swift-C++ interop. Mitigation already applied. |
| R-08 | OpenCV xcframework binary size increase (~80–120 MB added) | 3 | High | Medium | Use `EXCLUDED_ARCHS` to strip simulator slices in Release builds; consider linking only required OpenCV modules (`core`, `imgproc`) if OpenCV modular build becomes available |
| R-09 | Metal-to-encoder copy overhead impacts recording frame rate | 5 | Medium | Medium | `MTLBlitCommandEncoder` copy runs asynchronously after `commitCommandBuffer`; pre-allocated pixel buffer pool from `AVAssetWriterInputPixelBufferAdaptor`; measure with Instruments; if bandwidth-limited, explore IOSurface sharing |
| R-10 | App Nap suspends watchdog timers during background | all | Medium | Low | Watchdog `Task` objects use `withTaskCancellationHandler`; `backgroundSuspend()` cancels watchdogs before background; stall detection is irrelevant while backgrounded |
| R-11 | Metal command queue stalls under sustained load | 2, 4 | Low | High | Double-buffered readback prevents GPU→CPU synchronization stall; `commandBuffer.addCompletedHandler` is async; Instruments Metal System Trace used to detect queue depth issues |
| R-12 | `CVMetalTextureCache` holding stale textures after memory warning | 2, 4 | Low | Medium | `CVMetalTextureCacheFlush` called on `UIApplication.didReceiveMemoryWarningNotification`; cache is NOT recreated (creation is expensive) |
| R-13 | Focus distance diopter convention mismatch (U-11) | 1b | High | Low | iOS uses normalized `lensPosition` (0–1), not diopters. UI displays relative focus value; no diopter conversion without hardware calibration data. Documented as known deviation from domain API contract. |
| R-14 | AE frame rate range for recording: iOS behavior differs from domain spec (U-16) | 5 | Medium | Low | iOS recording mode: set `AVCaptureDevice.activeVideoMinFrameDuration` to `1/fps` upper bound and allow AE to use `activeVideoMaxFrameDuration` down to `1/(fps/2)`. Behavior matches domain intent (allow slowdown in low light). Exact range policy documented in Phase 5. |
| R-15 | Preview surface rebind race: `MTKView.currentDrawable` nil during rebind | 2, 4 | Low | Low | `MetalRenderer.draw(_:)` guards on nil drawable; consecutive failure counter resets after successful rebind; rebind runs inside `CameraEngine` actor (serialized) |
| R-16 | Photo library authorization denied for still capture | 5 | Medium | Medium | `PHPhotoLibrary.requestAuthorization` flow integrated; on denial, `captureImage()` falls back to temp directory path and emits non-fatal error; `PERMISSION_DENIED` not fatal for photo library (unlike camera) |
| R-17 | EXIF user comment JSON structure undefined | 5 | Low | Low | Defined in `EXIFWriter.swift` as key `"CamPlugin/v1"` in `kCGImagePropertyExifUserComment`; JSON schema to be specified during Phase 5 implementation |
| R-18 | `IFrameConsumer.onFrame()` called on arbitrary consumer queue; ObjC++ exception escaping | 3 | Low | High | All `EdgeDetectionBridge.mm` code wrapped in `@try/@catch` to prevent C++ exceptions from propagating into Swift runtime |
| R-19 | White balance gains out of range for `AVCaptureDevice.setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains` | 1b | Medium | Low | Gains clamped to `[device.minWhiteBalanceGain, device.maxWhiteBalanceGain]` before applying; out-of-range values return `SETTINGS_CONFLICT` error |
| R-20 | Noise reduction and edge enhancement: iOS AVFoundation has different control surface than domain passthrough | 1b | High | Low | iOS exposes `noiseReductionMode` and sharpness controls via `AVCaptureDevice` (not raw integer passthrough). Map domain integer values to the closest iOS equivalent; document mapping. Values not directly mappable are silently ignored with warning log. |
| R-21 | `AVCaptureSession` not stopped before background → iOS policy violation (App Store rejection, not just a runtime issue). The camera-in-use indicator in the status bar must not remain active in background. | 1a | Low | **Critical (policy)** | **P0 acceptance criterion for Phase 1a**: on `scenePhase == .background`, `CameraEngine.backgroundSuspend()` MUST call `session.stopRunning()` synchronously inside the actor before the view-layer task returns. Verified manually (switch to another app → status bar camera indicator must disappear within 1 second). |
| R-22 | `AVCaptureSession.startRunning()` must not run on the main thread — it blocks 100–500ms waiting for hardware readiness. | 1a | Medium | High | `startRunning()` is called inside `CameraEngine` (Swift actor, off-main by construction). Explicitly banned from any `@MainActor` context. Reviewed via `#assert(!Thread.isMainThread)` in DEBUG builds inside `CameraEngine.start()`. |
| R-23 | Metal command buffer errors (OOM, command-buffer timeout, invalid state) are silent without explicit status check in `addCompletedHandler`. | 2 | Low | High | Every `commandBuffer.addCompletedHandler { cb in … }` closure checks `cb.status == .error` and inspects `cb.error`. On error: increment a Metal-error counter, emit a non-fatal error to the state machine, and tear down the current command queue. Without this check, GPU faults are only surfaced by the 3-second stall watchdog — too slow. |
| R-24 | `CVMetalTextureCacheCreateTextureFromImage` can return `kCVReturnSuccess` and still produce a `CVMetalTexture` whose `CVMetalTextureGetTexture` returns `nil` under memory pressure. Force-unwrapping crashes. | 2 | Low | High | All texture-cache wraps use a guarded pattern: check `CVReturn == kCVReturnSuccess` AND `CVMetalTextureGetTexture(tex) != nil`. On failure, drop the frame, increment the metal-wrap-failure counter, and continue. Add a `memoryWarning` notification observer that flushes the texture cache. |
| R-25 | `AVCapturePhotoOutput` + `AVCaptureVideoDataOutput` attached to the same session at ~4000×3000 may cause iOS to silently downgrade the video data output resolution. | 5 | Medium | Medium | Phase 5 acceptance criterion: verify that after attaching `AVCapturePhotoOutput`, `CVPixelBufferGetWidth/Height` on video sample buffers still matches the configured 4:3 resolution. If iOS downgrades, evaluate `isHighResolutionCaptureEnabled` and whether photo output must be disconnected before recording. |
| R-26 | ~~Audio session category conflict~~ — **NOT APPLICABLE.** The product does not capture audio. Recordings are silent video tracks only. `AVCaptureAudioDataOutput`, `AVAudioSession` configuration, and `NSMicrophoneUsageDescription` are all explicitly out of scope. If audio is introduced in a future version, this risk will need to be restored and `NSMicrophoneUsageDescription` added to `Info.plist`. | — | — | — | — |
| R-27 | `PHPhotoLibrary.performChanges` async authorization flow not documented. `performChanges` called without authorization crashes on iOS 14+. | 5 | Medium | High | Phase 5 acceptance criterion: before `performChanges`, check `PHPhotoLibrary.authorizationStatus(for: .addOnly)`. If `.notDetermined`, call `requestAuthorization(for: .addOnly)` via `async` continuation wrapper. If `.denied` or `.restricted`, fall back to temp directory path and surface non-fatal `PHOTO_LIBRARY_DENIED` error. |

---

## Domain Edge Case → iOS Handling Mapping

Every edge case from `domain/06-error-and-recovery.md`:

| Domain edge case | iOS handling location | Mechanism |
|---|---|---|
| Capture session configuration rejected (`CONFIGURATION_FAILED`) | `CameraEngine.configureSession()` | `AVCaptureSession` `AVCaptureSessionRuntimeErrorNotification` with `AVError.sessionConfigurationChanged`; caught → non-fatal recovery |
| Camera device disconnected (`CAMERA_DISCONNECTED`) | `CameraEngine` + `SystemPressureMonitor` | `AVCaptureSessionRuntimeErrorNotification` with `AVError.deviceIsNotAvailableInBackground` or `.videoDeviceNotAvailable` |
| Camera device access error (`CAMERA_ACCESS_ERROR`) | `CameraEngine.open()` error handler | `AVCaptureDevice` throws `AVError`; catch → non-fatal; 5-retry backoff |
| Platform security bug after keyguard dismiss | `CameraEngine` interrupt handler | On iOS: Secure Enclave re-authentication; no exact equivalent to Android keyguard bug. System reports `AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground` — treated as non-fatal `CAMERA_ACCESS_ERROR` |
| 5 consecutive hardware-level frame failures (`CAPTURE_FAILURE`) | `CameraEngine.captureOutput(_:didDrop:from:)` | `AVCaptureVideoDataOutput` `captureOutput(_:didDrop:from:)` counts consecutive drops; at 5 → `handleNonFatalError(.captureFailure)` |
| No frames for 5000ms (`FRAME_STALL` → recovery) | `StallWatchdog` | Capture-result-level watchdog: 5s Task sleep + timestamp check; fires → `handleNonFatalError(.frameStall)` → full teardown + reopen |
| No frames at GPU level for 3000ms (`FRAME_STALL` → notify only) | `StallWatchdog` | GPU-level watchdog: 3s Task sleep + Metal last-frame timestamp check; fires → `errorStream.yield(.frameStall(fatal: false))`; no recovery |
| AE not converged within 5000ms | `AEConvergenceMonitor` | `AVCaptureDevice` KVO on `isAdjustingExposure`; timer started when adjusting starts; 5s expiry → non-fatal `AE_CONVERGENCE_TIMEOUT` notify |
| Frame rate below 15fps for 3 heartbeats | `FPSDegradationMonitor` | 30-frame heartbeat reads `frameDurationNs` from `CMSampleBufferGetDuration`; 3 consecutive < 15fps → non-fatal `FPS_DEGRADED` notify |
| EOS drain timeout during recording stop (`RECORDING_TRUNCATED`) | `VideoRecorder.stopRecording()` | `AVAssetWriter.finishWriting` with 5s `Task.sleep` deadline; if timeout → `AVAssetWriter.cancelWriting` + emit `RECORDING_TRUNCATED` + return partial URI |
| Camera in use by another app (`CAMERA_IN_USE`) | `CameraEngine` + `CameraAvailabilityMonitor` (Phase 6) | `AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps` → fatal error; KVO on `AVCaptureDevice` for availability → self-heal |
| Max retries exceeded (`MAX_RETRIES_EXCEEDED`) | `CameraEngine.handleNonFatalError()` | After 5th failed retry → `handleFatalError(.maxRetriesExceeded)` → full teardown + `.error` state |
| Camera access disabled by policy (`PERMISSION_DENIED`) | `PermissionManager` | `AVCaptureDevice.authorizationStatus == .denied / .restricted` → fatal `PERMISSION_DENIED` |
| Video encoder init failure (`RECORDING_START_FAILED`) | `VideoRecorder.startRecording()` | `AVAssetWriter` init throws → fatal `RECORDING_START_FAILED` |
| Recording pipeline failure mid-session (`RECORDING_FAILED`) | `VideoRecorder` error observer | `AVAssetWriter.status == .failed` observed in drain loop → fatal `RECORDING_FAILED` |
| Invalid file format for GPU capture (`INVALID_FORMAT`) | `GPUCaptureController` | Extension check on `fileName`; only `.jpg`, `.jpeg`, `.png` accepted; other → `INVALID_FORMAT` error |
| Settings conflict (`SETTINGS_CONFLICT`) | `ISOExposureCoupling` | Merge + coupling validation; attempting manual ISO/exposure with no prior sensor readback → `SETTINGS_CONFLICT` |
| Open while session active | `CameraEngine.open()` guard | `guard sessionState == .closed || sessionState == .permissionDenied else { throw CameraError(.invalidState) }` |
| HAL error threshold (5 consecutive) | `CameraEngine.captureOutput(_:didDrop:from:)` | `consecutiveDropCount` incremented; reset on successful frame; at 5 → non-fatal recovery |

---

## Domain/11 "What Not to Port" — Confirmation of Absence

All 21 items from `domain/11-what-not-to-port.md` are confirmed absent from this iOS design:

| Item | Confirmation |
|---|---|
| Android message-dispatch mechanism | Not used — Swift actors and `AsyncStream` |
| JNI | Not used — Swift-C++ interop and ObjC++ |
| Flutter Pigeon codegen | Not used — native Swift API surface |
| SharedPreferences (double-as-long workaround) | Not used — `UserDefaults` + `Codable` with native `Double` support |
| MediaStore integration | Not used — `PHPhotoLibrary` and file URL APIs |
| Android manifest + permission model | Not used — iOS `Info.plist` `NSCameraUsageDescription` + `AVCaptureDevice.requestAccess` |
| Android capture request templates | Not used — iOS `AVCaptureDevice` mode properties |
| Android noise/edge integer passthrough values | Not used — iOS `AVCaptureDevice` noise/sharpness APIs with iOS-specific values |
| Gradle / NDK / CMake build configuration | Not used — Xcode + Swift Package Manager + xcframework |
| ADB broadcast receivers | Not used — no debug ADB equivalent in design |
| ProcessLifecycleOwner (onStop/onStart) | Not used — SwiftUI `scenePhase` |
| Android camera availability notification | Not used — iOS `AVCaptureDevice` KVO availability (Phase 6) |
| OpenGL ES (PBOs, FBOs, EGL, GLSL) | Not used — Metal compute shaders |
| UV rotation matrix (90° CW sensor orientation) | Not used — `AVCaptureConnection.videoRotationAngle` |
| Encoder output drain loop (polling model) | Not used — `AVAssetWriter.finishWriting(completionHandler:)` |
| Flutter binary messenger thread affinity | Not used — no Flutter runtime |
| HEVC/H.264 Android codec name strings | Not used — `AVVideoCodecType.hevc` / `.h264` |
| libjpeg-turbo build from source | Not used — `CGImageDestination` (system JPEG encoder) |
| fpng bundled encoder | Not used — `CGImageDestination` (system PNG encoder) |
| Android white balance four-element Bayer gain vector | Not used — `AVCaptureDevice.WhiteBalanceGains` (R, G, B only; no Bayer duplication) |
| Host GTest unit tests | Not present — iOS uses Swift Testing (`@Test`) |

---

## NEEDS INVESTIGATION Items

The following items require validation during implementation (not design blockers, but implementation-time concerns):

1. **U-11 (Focus diopter convention):** iOS `lensPosition` does not map to diopters without hardware calibration. If the product requires actual diopter display, a per-device calibration table must be developed. Currently designed as raw `lensPosition` display.

2. **U-16 (AE FPS range for recording):** iOS `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` API is the equivalent. Exact policy for handling the case where no 30fps fixed range is available needs empirical testing on target hardware.

3. **Sensor orientation angle (U-10):** `AVCaptureConnection.videoRotationAngle` value for the target device must be verified empirically during Phase 1a. The value `0` (landscape right) is an assumption that needs hardware validation.

4. **Noise reduction and edge enhancement mapping (R-20):** Mapping from domain integer passthrough values to iOS `AVCaptureDevice.activeVideoStabilizationMode` and related controls is not standardized. Implementation-time mapping table required.

5. **EXIF user comment JSON schema (R-17):** The non-standard fields to serialize in `kCGImagePropertyExifUserComment` under the `"CamPlugin/v1"` key need specification during Phase 5.
