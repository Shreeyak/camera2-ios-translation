# Stage 06 — Tracker stream + FrameSet publication + pool trio

## 1. Frontmatter
Type: FEATURE
Depends on: Stage 04

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard
What's built (permanent): Package.swift; `CameraEngine` with the full non-consumer, non-capture, non-recording, non-recovery surface (open/close/backgroundSuspend/backgroundResume/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/stateStream/frameResultStream); Pass 1 + Pass 2; `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata`; single shared IOSurface-backed `naturalTex` + `processedTex`; split preview + color-calibration sidebar + expanded bottom bar; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `stateStream()`, `frameResultStream()`.

## 3. Goal
A debug overlay (development builds only) shows frame-number + capture-time for each publication; tracker preview (tiny thumbnail) appears when any consumer subscribes to `.tracker`. No external C++ consumer yet.

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/MetalPipeline.swift — add Pass 4 (tracker downsample compute) producing a `TRACKER_HEIGHT_PX`-tall aspect-preserved, even-pixel-rounded tracker texture; promote `naturalTex` / `processedTex` / `trackerTex` from single shared textures to `CVPixelBufferPool`-backed per ADR-19 (one pool each); `FrameSet` is constructed in the completion handler from the three pool-dequeued buffers plus capture metadata + snapshotted `ProcessingMetadata`.
- modify: Sources/CameraKit/TexturePoolManager.swift — three `CVPixelBufferPool` instances per `04-metal-pipeline.md` §Pool configuration: `POOL_MIN_BUFFER_COUNT`, `POOL_MAX_BUFFER_AGE_SECONDS`, `POOL_CAP_RULE = N_active_lanes + 1`; each configured with `kCVPixelBufferIOSurfacePropertiesKey: [:]` + `kCVPixelBufferMetalCompatibilityKey: true`; storage mode `.shared` (D-02, OQ-01).
- modify: Sources/CameraKit/FrameSet.swift — populate fields: three `CVPixelBuffer` (natural/processed/tracker), `CaptureMetadata`, `ProcessingMetadata`, tracker signals placeholder; `@unchecked Sendable` per ADR-18 and G-13 with doc citing IOSurface contract.
- modify: Sources/CameraKit/Consumer.swift — rename the Stage-01 stub type; `ConsumerRegistry` becomes an actor with:
  - `subscribe(stream: StreamId) -> AsyncStream<FrameSet>` (Swift-only lane, `.bufferingNewest(1)` per ADR-22).
  - `registerCallback(stream:callbacks:)` stub that throws `InteropError.notWired` this stage (scaffolding:06:simple-consumer-swift-only — the C-ABI path lands in Stage 08).
  - `unregister(token:)`.
  - internal `yield(_ frameSet: FrameSet, stream: StreamId)` called from the delivery-queue completion-handler path.
- modify: Sources/CameraKit/CaptureDelegate.swift — after Pass 4 completes, construct `FrameSet` and call `consumers.yield(_:stream:)` for each of `.natural`, `.processed`, `.tracker`; publication happens inline on the `delivery` queue (no actor hop; ADR-02 frame clock).
- modify: Sources/CameraKit/CameraView.swift — tiny tracker thumbnail appears when ViewModel observes at least one `.tracker` subscriber; debug overlay (`#if DEBUG`) shows frame-number + capture-time per `FrameSet` yield.
- modify: Sources/CameraKit/ViewModel.swift — optional `for await frameSet in consumers.subscribe(stream: .tracker)` bound behind a debug toggle; debug overlay plumbing.
- modify: Sources/CameraKit/Errors.swift — add `InteropError.notWired` (migrates to real InteropError variants in Stage 08).
- create: Tests/CameraKitTests/Stage06Tests.swift — see §8.

## 5. Architecture refs
- architecture/04-metal-pipeline.md#command-graph
- architecture/04-metal-pipeline.md#pool-configuration
- architecture/04-metal-pipeline.md#d-02-texture-storage-mode-shared-start-simple
- architecture/05-consumers.md#publication-unit-frameset
- architecture/05-consumers.md#mailbox-semantics
- architecture/05-consumers.md#consumer-lifecycles
- architecture/05-consumers.md#d-12-natural-stream-is-subscribable
- architecture/02-concurrency.md#cross-subsystem-sequencing
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/02-frame-delivery.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/10-api-contract.md
- domain-revised/12-unresolved.md

## 7. Contracts & invariants
- Per-lane mailbox semantics: `AsyncStream<FrameSet>.bufferingNewest(1)` (ADR-22); drop-on-busy is the correct behavior and surfaces via `FrameDeliveryStats` once Stage 12 wires it.
- `POOL_MIN_BUFFER_COUNT = 3`, `POOL_MAX_BUFFER_AGE_SECONDS = 1.0`, `POOL_CAP_RULE = N_active_lanes + 1` (ADR-19).
- All three textures are **always IOSurface-backed** (OQ-01); `.shared` storage mode as the ADR-20 start-simple default (D-02). G-25's silent-drop failure mode on `.private` textures never applies.
- `FrameSet` is constructed once per frame in the completion handler; the same `ProcessingMetadata` snapshot that Pass 2 used is attached (Stage 05 invariant).
- Natural stream is subscribable on par with processed/tracker (D-12, reverses domain U-13); all three `StreamId`s share one logical surface.
- `registerCallback(stream:callbacks:)` is scaffolding — Swift-side mirrors receive frames; C-ABI registration lands in Stage 08 (D-01).
- Frame clock does not hop a Swift actor boundary; the delegate runs on `delivery`, builds the command buffer inline, commits inline, and publishes `FrameSet` from the completion handler inline (ADR-02, ADR-10).

## 8. Tests to write
- TESTABLE: 06:frame-set-publication — inject a known-pattern `CMSampleBuffer`; a Swift subscriber to `.natural` / `.processed` / `.tracker` receives one `FrameSet` per input frame with matching `CaptureMetadata.frameNumber`; each `CVPixelBuffer` is IOSurface-backed (assert `CVPixelBufferGetIOSurface` non-nil).
- TESTABLE: 06:swift-consumer-drop-on-busy — subscriber `for await`s with a 10ms sleep per iteration while the delivery loop yields at 30fps; the subscriber sees the latest frame (not a backlog) and at least one drop event is recorded in a test-visible counter on `ConsumerRegistry`.
- TESTABLE: 06:pool-trio-allocation-on-open — `open()` creates three `CVPixelBufferPool` instances with `kCVPixelBufferIOSurfacePropertiesKey` and `kCVPixelBufferMetalCompatibilityKey` set; cap follows `POOL_CAP_RULE`.
- TESTABLE: 06:tracker-downsample-height-matches-constant — tracker texture height equals `TRACKER_HEIGHT_PX`; width is aspect-preserved and even-pixel-rounded.
- TESTABLE: 06:subscribe-then-cancel-releases-subscriber — cancel the owning `Task`; the `ConsumerRegistry`'s internal subscriber set reflects the removal on the next yield.
- TESTABLE: 06:register-callback-throws-not-wired — `ConsumerRegistry.registerCallback(stream:callbacks:)` throws `InteropError.notWired` this stage (scaffold guard).
- TESTABLE: 06:natural-stream-is-subscribable — per D-12; the `.natural` lane yields `FrameSet` just like `.processed` and `.tracker`.
- HITL: 06:tracker-thumbnail-appears-on-subscribe — toggle debug subscriber in development build; tiny tracker thumbnail appears in the UI; cancel subscriber; thumbnail disappears; device: iPad Pro M1.
- HITL: 06:debug-overlay-shows-frame-number-capture-time — enable debug overlay; per-frame numbers increment monotonically; capture-time is non-decreasing; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
(none)

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL tests confirmed on iPad Pro M1; evidence recorded.
- [ ] `grep -rn '06:simple-consumer-swift-only' Sources/` ≥1 hit; `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' Sources/` each ≥1 hit.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-6]Tests"`
- Scaffold inventory: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `06:simple-consumer-swift-only` live.
- Device smoke on iPad Pro M1: enable debug overlay; confirm frame-number increments; enable tracker-debug subscriber; observe thumbnail; cancel.
- Instruments Allocations: pool high-water-mark per lane equals `POOL_CAP_RULE` and ages-out to zero after 1s of no subscribers per `POOL_MAX_BUFFER_AGE_SECONDS`.

## 12. State.md updates (Claude Code writes these)
- Adds (permanent): Pass 4 tracker downsample; three `CVPixelBufferPool` instances (natural/processed/tracker); `FrameSet` complete type; `ConsumerRegistry` actor with Swift-only `subscribe(stream:)` lane and the C-ABI placeholder; `CaptureMetadata` + tracker signals on `FrameSet`; debug overlay + tracker-thumbnail UI path; `InteropError.notWired`.
- Adds (public API): `ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>`; `ConsumerRegistry.unregister(token:)`.
- Adds (scaffolding): 06:simple-consumer-swift-only.
- Evidence: HITL 06:tracker-thumbnail-appears-on-subscribe and 06:debug-overlay-shows-frame-number-capture-time — `measurements/stage-06/consumers.md`.
