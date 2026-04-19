# API Surface

Prose summary of the SDK boundary. Every load-bearing type has a compiling Swift stub in
`api-skeletons/Sources/CameraKit/`; call-site consumers are the application layer and any
external C++ pipeline that goes through `PixelSinkCallbacks` (ADR-31, D-03). Signatures are
**not** inlined here — they live in the skeleton. This file maps the domain contract
(`domain-revised/10-api-contract.md`) to Swift/C-ABI identifiers and points into the
skeleton for the actual shape.

## Surface boundaries

| Boundary | Who calls it | Shape | Files |
|---|---|---|---|
| Host-to-engine API | SwiftUI View / ViewModel on `@MainActor` | Actor methods on `CameraEngine`; typed throws (`EngineError`) per ADR-25. Data types `Sendable`. | `api-skeletons/Sources/CameraKit/CameraEngine.swift`, `.../Settings.swift`, `.../Capabilities.swift`, `.../StillCapture.swift`, `.../Recording.swift` |
| Engine-to-host events | Engine `AsyncStream`s consumed on `@MainActor` | Four `AsyncStream`s: `stateStream`, `errorStream`, `frameResultStream`, `recordingStateStream`. Buffering policy: `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` (ADR-22). | `api-skeletons/Sources/CameraKit/CameraEngine.swift`, `.../SessionState.swift`, `.../Errors.swift`, `.../Settings.swift` |
| Device-state stream | Engine internals and (optionally) debug UI | KVO-sourced `AsyncStream<DeviceStateSnapshot>` per ADR-14; `Tokens` box owns observation lifetime. | `api-skeletons/Sources/CameraKit/CaptureDeviceProviding.swift` |
| Swift consumer subscription | Swift-only consumer ("edge visualizer", tests) | `ConsumerRegistry.subscribe(stream:)` returns `AsyncStream<FrameSet>` with `.bufferingNewest(1)`; D-01 serves this lane via the same C++ pool. | `api-skeletons/Sources/CameraKit/PixelSink.swift`, `.../FrameSet.swift` |
| External C++ consumer | Tracker, CV pipeline | `ConsumerRegistry.registerCallback(stream:callbacks:)` accepts a `PixelSinkCallbacks` C-ABI struct (D-03, ADR-31). C++ consumes via IOSurface-backed frames (ADR-18). | `api-skeletons/Sources/CameraKit/PixelSink.swift` |
| Raw pipeline handle | External C++ caller that bypasses the Swift facade entirely | `CameraEngine.getNativePipelineHandle()` returns an opaque `UInt64`. Guarded by D-15. | `api-skeletons/Sources/CameraKit/CameraEngine.swift` |
| Test seam | Unit tests (Swift Testing, ADR-33) | `CaptureDeviceProviding` protocol (ADR-32). The fake implementation supplies canned formats and capability bits. | `api-skeletons/Sources/CameraKit/CaptureDeviceProviding.swift` |

## Host methods — domain-to-skeleton map

Every host method in `domain-revised/10-api-contract.md §Host Methods` maps to one
`CameraEngine` actor method in `api-skeletons/Sources/CameraKit/CameraEngine.swift`. Names are
normalized to Swift-ish (camelCase); session handle is implicit because the engine is a
single-session actor per domain U-17.

| Domain host method | Skeleton counterpart | Throws |
|---|---|---|
| `open(cameraId, captureResolution, cropRegion)` | `CameraEngine.open(configuration:)` | `EngineError` |
| `close(handle)` | `CameraEngine.close()` | — |
| `pause(handle)` | `CameraEngine.pause()` | — |
| `resume(handle)` | `CameraEngine.resume()` | `EngineError` |
| `backgroundSuspend(handle)` | `CameraEngine.backgroundSuspend()` | — |
| `backgroundResume(handle)` | `CameraEngine.backgroundResume()` | — |
| `updateSettings(handle, settings)` | `CameraEngine.updateSettings(_:)` | `EngineError` |
| `setProcessingParameters(handle, params)` | `CameraEngine.setProcessingParameters(_:)` | — |
| `getPersistedProcessingParameters(handle)` | `CameraEngine.getPersistedProcessingParameters()` | — |
| `sampleCenterPatch(handle)` | `CameraEngine.sampleCenterPatch()` | `EngineError` |
| `captureImage(handle, outputPath)` | `CameraEngine.captureImage(outputPath:)` | `EngineError`, `StillCaptureError` |
| `startRecording(handle, …)` | `CameraEngine.startRecording(options:)` | `EngineError`, `RecordingError` |
| `stopRecording(handle)` | `CameraEngine.stopRecording()` | `EngineError`, `RecordingError` |
| `setResolution(handle, w, h)` | `CameraEngine.setResolution(size:)` | `EngineError` |
| `setCropRegion(handle, rect)` | `CameraEngine.setCropRegion(_:)` | `EngineError` |
| `getNativePipelineHandle(handle)` | `CameraEngine.getNativePipelineHandle()` | — |

## Callbacks — domain-to-skeleton map

Callbacks are `AsyncStream`s, not delegate methods. The view model `for await`s them on
`@MainActor` per ADR-21 / ADR-28.

| Domain callback | Skeleton stream | Buffering policy (ADR-22) |
|---|---|---|
| `onStateChanged` | `CameraEngine.stateStream()` → `AsyncStream<SessionState>` | `.bufferingOldest(64)` |
| `onError` | `CameraEngine.errorStream()` → `AsyncStream<CameraError>` | `.bufferingOldest(64)` |
| `onFrameResult` | `CameraEngine.frameResultStream()` → `AsyncStream<FrameResult>` | `.bufferingNewest(1)` (heartbeat is frame-rate) |
| `onRecordingStateChanged` | `CameraEngine.recordingStateStream()` → `AsyncStream<RecordingState>` | `.bufferingOldest(64)` |

## Consumer registration — two lanes, one registry

The domain specifies a single consumer-registration surface (`domain-revised/10-api-contract.md`
§Consumer Registration API) delivering to `natural` / `processed` / `tracker` streams. iOS has
two caller shapes:

- **Swift-side consumer:** `ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>`. Per
  ADR-22 the stream is `.bufferingNewest(1)`. Terminating the `for await` loop (or cancelling
  the owning `Task`) unsubscribes.
- **C++-side consumer:** `ConsumerRegistry.registerCallback(stream:callbacks:)` accepts a
  `PixelSinkCallbacks` POD struct (`@convention(c)` function pointers + opaque context).
  Unsubscribe via `unregister(token:)` or by dropping the C++-side retain.

Both lanes go through the same C++ `PixelSink` pool per D-01; drop counters surface via the
single `FrameDeliveryStats` `AsyncStream` (D-11).

The three stream IDs are the `StreamId` enum. `natural` is subscribable alongside `processed`
and `tracker` per D-12 (reverses domain U-13).

## Atomic publication unit — `FrameSet`

Per ADR-18, every consumer lane delivers a `FrameSet` — one atomic handoff with all three
IOSurface-backed `CVPixelBuffer`s plus capture + processing metadata + derived tracker
signals. The `@unchecked Sendable` conformance on `FrameSet` is justified by the IOSurface
contract (see `04-metal-pipeline.md#framing` and G-13); the pool machinery guarantees the
backing memory is valid for the consumer's iteration and released when the next set publishes.

## Error taxonomy

- `ErrorCode` — the wire-format domain enum; stable across host/plugin boundary.
- `CameraError` — the `onError` payload (code + message + isFatal) delivered on
  `errorStream`.
- `EngineError` — typed throws for `CameraEngine` public methods per ADR-25; wraps framework
  errors via `.metal(MetalError)`, `.interop(InteropError)`, `.recording(RecordingError)`,
  `.fatal(CameraError)`.

All three are `Sendable`.

## Skeleton discipline

Every type above has a compiling stub body of `fatalError("Stage N")` in the skeleton. The
stage number identifies where the real implementation lands — see `stages/stage-index.md`.
Verify with:

```
swift build --package-path implementation/architecture/api-skeletons/
```

Exits 0 under Swift 6 language mode + strict concurrency.
