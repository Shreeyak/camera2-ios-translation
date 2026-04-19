# 01 — System Shape

Primary-owner file for **where every type lives** and **who owns what**. Most cited — every
other concern links here when answering "what file contains X?"

---

## Swift module layout

Single library target: `CameraKit` (SwiftPM package in `api-skeletons/` during pre-build;
transplanted to the host app during Stage 01). Public surface is the `CameraEngine` actor +
its value types (`api-surface.md`). All internal machinery is `internal`.

### File map

```
Sources/CameraKit/
├── CameraEngine.swift              ── actor CameraEngine (ADR-02); public engine API
├── CameraView.swift                ── SwiftUI root + UIViewRepresentable wrappers (ADR-01)
├── ViewModel.swift                 ── @Observable @MainActor ViewModel (ADR-21)
├── CaptureDelegate.swift           ── nonisolated sample-buffer delegate (ADR-07, ADR-02)
├── CameraSession.swift             ── AVCaptureSession config, driven on sessionQueue
├── CaptureDeviceProviding.swift    ── protocol seam (ADR-32) + DeviceStateStream (ADR-14)
├── MetalPipeline.swift             ── per-frame command graph, FrameSet construction
├── TexturePoolManager.swift        ── CVPixelBufferPool trio (ADR-19) + CVMetalTextureCache (ADR-04)
├── Consumer.swift                  ── ConsumerRegistry + PixelSinkCallbacks bridge (D-01, D-03)
├── Recording.swift                 ── AVAssetWriter coordinator (ADR-16)
├── StillCapture.swift              ── Metal blit → CVPixelBuffer → TIFF via CGImageDestination (D-05)
├── Settings.swift                  ── CameraSettings, ProcessingParameters, merge + coupling
├── SettingsPersistence.swift       ── UserDefaults adapter (07-settings.md §Persistence)
├── FrameSet.swift                  ── Sendable frame tuple (ADR-18)
├── Errors.swift                    ── EngineError / MetalError / InteropError / RecordingError (ADR-25)
├── Watchdog.swift                  ── GPU + capture-result stall pair
├── RecoveryCoordinator.swift       ── exponential backoff + cancellation (09-errors-and-recovery.md)
├── Capabilities.swift              ── SessionCapabilities, Size, Rect, OpenConfiguration
├── SessionState.swift              ── SessionState / RecordingState / StreamId enums
└── Constants.swift                 ── load-bearing constants (mirrors constants.md)
```

External C++ code lives outside `Sources/CameraKit/` in a companion SPM target
(`CameraKitCxx`) whose Swift-visible headers contain only POD + `SWIFT_SHARED_REFERENCE`
types + C-ABI callbacks per ADR-11. The Swift side imports via a thin `CameraKitInterop`
Swift module (per ADR-13 §Keep `.interoperabilityMode(.Cxx)` contained) so the main
`CameraKit` module stays pure Swift. The host app links both.

### Public vs. internal boundary

- **Public** (exposed by the `CameraKit` library): `CameraEngine` + its method surface,
  all value types (`SessionState`, `CameraSettings`, `ProcessingParameters`, `FrameResult`,
  `RgbSample`, `FrameSet`, `CaptureMetadata`, `ProcessingMetadata`,
  `WhiteBalanceGains`, `SessionCapabilities`, `Size`, `Rect`, `OpenConfiguration`,
  `ConsumerRegistry`, `ConsumerToken`, `PixelSinkCallbacks`, `StillCaptureOutput`,
  `StillCaptureError`, `RecordingOptions`, `RecordingStart`, `StreamId`,
  `RecordingState`, `ErrorCode`, `CameraError`, `EngineError`, `MetalError`,
  `InteropError`, `RecordingError`, `DeviceStateSnapshot`, `SystemPressureLevel`,
  `CaptureDeviceProviding`, `CameraMode`, `WhiteBalanceMode`, `TrackerQuality`,
  `CameraPosition`, `FrameDeliveryStats`).
- **Internal**: `CaptureDelegate`, `CameraSession`, `MetalPipeline`, `TexturePoolManager`,
  `Watchdog`, `RecoveryCoordinator`, `SettingsPersistence`, shader sources, argument
  buffer layouts.

UIKit / SwiftUI types in `CameraView.swift` and `ViewModel.swift` are public to the host
app (they are the view layer) but are not part of the Swift-to-host engine contract — they
are implementation of the UI feature. See `08-ui.md`.

---

## Ownership of top-level types

| Type | Isolation | File | Lifetime |
|---|---|---|---|
| `CameraEngine` | custom `actor` (ADR-02) | `CameraEngine.swift` | Created at `CameraView` appear; retained across pause/resume; released on `close()` + view disappear. |
| `CameraView`, `ViewModel` | `@MainActor` (ADR-21 default) | `CameraView.swift`, `ViewModel.swift` | SwiftUI owns. |
| `CaptureDelegate` | `nonisolated`, `@unchecked Sendable` | `CaptureDelegate.swift` | Created once per `open()`; retained by `AVCaptureVideoDataOutput`; released on `close()`. |
| `CameraSession` | driven by dedicated `sessionQueue` (ADR-07) | `CameraSession.swift` | One `AVCaptureSession` per `open()`; reused across pause/resume per G-07. |
| `MetalPipeline` | engine-actor-isolated state + `nonisolated` per-frame methods called from delivery queue | `MetalPipeline.swift` | Created at `open()`, held for life of the engine. |
| `TexturePoolManager` | engine-actor-isolated | `TexturePoolManager.swift` | Three `CVPixelBufferPool`s (natural, processed, tracker) + one `CVMetalTextureCache` (ADR-04). |
| `ConsumerRegistry` | `actor` (see `05-consumers.md`) | `Consumer.swift` | Shared: the engine holds one; the host obtains a reference via `CameraEngine.consumers`. |
| `Watchdog` (pair) | `nonisolated` with `ManagedAtomic<UInt64>` timestamps per ADR-09 / G-11-style visibility | `Watchdog.swift` | Armed on session-configured, disarmed step 1 of teardown + recovery. |
| `RecoveryCoordinator` | engine-actor-isolated; stores the pending retry `Task?` per ADR-23 | `RecoveryCoordinator.swift` | Created with the engine; cancelled on `close()` / `backgroundSuspend()`. |

The **Primary-owner rule** (see `README.md`) binds these: a decision about any of these types
is stated exactly once in its owning concern file; other concerns cite
`01-system-shape.md#<anchor>` (or the appropriate concern file for rule content).

---

## Dispatch queues (non-actor isolation boundaries)

Swift actors do not replace serial `DispatchQueue`s for AVFoundation + Metal work (ADR-07).
Two queues plus the Swift actors:

| Queue | Qos | Role | Callers |
|---|---|---|---|
| `sessionQueue` (label `camera.session`) | `.userInitiated` | `AVCaptureSession` lifecycle + `AVCaptureDevice.lockForConfiguration()` | Engine actor dispatches via async-with-timeout per ADR-30. |
| `delivery` (label `camera.delivery`) | `.userInitiated` | `AVCaptureVideoDataOutputSampleBufferDelegate` callback; Metal encode + commit; completion-handler consumer publish | AVFoundation invokes the delegate; Metal completion handlers fire on the delivery context too per ADR-02 §Frame clock. |

Actors **coordinate with** queues; they do not replace them. The frame clock never hops a
Swift actor boundary (ADR-02, ADR-10) — the delegate runs on `delivery`, builds the command
buffer inline, commits inline, and publishes `FrameSet` from the completion handler inline.

See `02-concurrency.md` for the invariant→primitive mapping and the completion-handler
re-entrancy guard (D-10).

---

## Extension criteria

The file map above is the v1 baseline. A new file is justified only when:

1. A domain requirement introduces a new lifecycle (e.g. if a scheduled diagnostic pipeline
   outlives the engine, it becomes its own actor — ADR-02 §Principle: one actor per lifecycle).
2. A concern file reaches a size where reviewers get lost — move a named subsystem out.
3. A public type moves from `internal` to `public`, warranting its own file for grep-ability.

Speculative modularization (`Plugins/`, `Core/`, `Infra/`) is a review failure. See ADR-01
§The three-layer sandwich pattern gets wrong.

---

## Package.swift — operative shape

`api-skeletons/Package.swift` captures the engine-only subset. The host-app package adds:

- A `CameraKitCxx` `.target` with `.publicHeadersPath("include")`, `cxxLanguageStandard: .cxx20`,
  and no OpenCV in public headers per ADR-11 §Module map.
- An app executable target that depends on both `CameraKit` and `CameraKitCxx`, plus the
  OpenCV xcframework (private dependency of `CameraKitCxx` only).
- Swift test targets split into a **unit** bundle using `swift-testing` (ADR-33) and an
  **integration** XCTest bundle for Metal/AVFoundation tests.

The operative `Package.swift` is written in Stage 01; `api-skeletons/Package.swift` is
retained alongside for mechanical verification (M3).
