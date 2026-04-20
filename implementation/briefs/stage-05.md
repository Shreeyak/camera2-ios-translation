# Stage 05 — Uniform lock + per-frame snapshot (MIGRATION)

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 04
Retires scaffolding from: Stage 04 (unlocked-uniforms)

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard, 04:unlocked-uniforms
What's built (permanent): Package.swift; `CameraEngine` (open/close/backgroundSuspend/backgroundResume/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/stateStream/frameResultStream); `CameraSession` with ISO/shutter/focus/WB/zoom/EV commits inside `lockForConfiguration()`; `CaptureDelegate`; `CaptureDeviceProviding` + KVO→AsyncStream adapter; `Capabilities`, `SessionState`, `StreamId`, `EngineError`, `FrameSet` (stub), `Constants`, `Settings` (full ProcessingParameters), `SettingsPersistence`; `CameraView` + split preview + expanded bottom bar + color-calibration sidebar + `ViewModel` + MTKView wrappers; `AsyncWithTimeout`; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; Pass 1 + Pass 2; single shared IOSurface-backed `naturalTex` + `processedTex`; center-patch reduction kernel.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `stateStream()`, `frameResultStream()`.

## 3. Goal
- Adds: `OSAllocatedUnfairLock<UniformStorage>` on the host-written uniform buffer (D-17); Pass 2 snapshots uniforms into the per-frame `MTLBuffer` inside the lock; `ProcessingMetadata` type attached to the snapshot path.
- Removes: 04:unlocked-uniforms.
- Behavior preserved: identity and non-identity color transforms (04:color-pipeline-golden-frame); `ProcessingParameters` persistence roundtrip (04:processing-params-persistence-roundtrip).

## 4. Files to create / modify / delete
- create: Sources/CameraKit/UniformStorage.swift (permanent) — `UniformStorage` value type holding the host-writable shader params; `OSAllocatedUnfairLock<UniformStorage>` owned by `MetalPipeline`.
- modify: Sources/CameraKit/MetalPipeline.swift — replace direct uniform writes with `lock.withLock { snapshot ← current }` at the top of each frame (before Pass 2 encode); write the snapshot into the per-frame `MTLBuffer`; remove `scaffolding:04:unlocked-uniforms` comment/marker.
- modify: Sources/CameraKit/CameraEngine.swift — `setProcessingParameters(_:)` routes writes through `lock.withLock`; the engine actor never touches the uniform `MTLBuffer` directly.
- create: Sources/CameraKit/ProcessingMetadata.swift (permanent) — `ProcessingMetadata` value type carrying the frame's snapshotted uniforms; prepared for attachment to `FrameSet` in Stage 06.
- modify: Sources/CameraKit/FrameSet.swift — add `processingMetadata: ProcessingMetadata` field (population deferred to Stage 06 when `FrameSet` is actually constructed; for Stage 05 the field exists but is default-initialized).
- modify: Sources/CameraKit/CaptureDelegate.swift — on each frame, capture the `ProcessingMetadata` snapshot reference and pass it through to downstream (still a no-op consumer path until Stage 06).
- modify: architecture/02-concurrency.md — Inv 6 invariant row is now enforced in code (guide existed since Stage 04). No change to architecture prose; the code-level enforcement is recorded in state.md.
- create: Tests/CameraKitTests/Stage05Tests.swift — see §8.

## 5. Architecture refs
- architecture/02-concurrency.md#d-17-osallocatedunfairlock-for-host-written-uniform-buffer
- architecture/02-concurrency.md#concurrency-contract-table
- architecture/04-metal-pipeline.md#shader-uniforms
- architecture/04-metal-pipeline.md#command-graph
- architecture/07-settings.md#processingparameters-gpu-shader-parameters

## 6. Domain refs
- domain-revised/02-frame-delivery.md
- domain-revised/04-concurrency-invariants.md
- domain-revised/07-performance-budgets.md

## 7. Contracts & invariants
- Uniforms are host-written inside `OSAllocatedUnfairLock<UniformStorage>` (D-17); read via `lock.withLock { snapshot = storage }` and memcpy'd into a per-frame `MTLBuffer`.
- Inv 6 (no torn writes on the uniform buffer) is now enforced in code (row 10 of `02-concurrency.md` §Concurrency contract table).
- The lock is held for the snapshot copy only, never across Metal encode or commit (ADR-09 hot-path discipline; `FRAME_LATENCY_BUDGET_MS`).
- Actor isolation and serial-DispatchQueue alternatives are excluded because they require a `Task` hop per slider move, which exceeds the budget (D-17).
- `ProcessingMetadata` attached to `FrameSet` (when FrameSet is constructed in Stage 06) is the same snapshot; this guarantees consumer-visible metadata matches what the GPU rendered on that frame.

## 8. Tests to write
- TESTABLE: 05:uniform-lock-no-torn-writes-under-stress — stress harness writes `ProcessingParameters` from a `DispatchQueue.concurrentPerform` loop while a simulated delivery loop snapshots 10_000 times; every snapshot equals a prior fully-committed state (no interleaved bytes); the lock's `withLock` count matches writer count.
- TESTABLE: 05:processing-metadata-snapshot-matches-lock — engine `setProcessingParameters(brightness: 0.3)` immediately before snapshot; the snapshot's `brightness` is 0.3; no writer can observe a partially-written storage.
- TESTABLE: 05:lock-not-held-across-commit — instrumented `MetalPipeline` asserts that `commandBuffer.commit()` is called without the lock held (a debug counter in the lock scope is zero at commit time).
- TESTABLE: 04:color-pipeline-golden-frame — carried forward; same golden-frame assertion now with the lock path enabled.
- TESTABLE: 04:processing-params-persistence-roundtrip — carried forward; save/load unchanged by the lock path.

## 9. Tests preserved (must still pass)
- 04:color-pipeline-golden-frame
- 04:processing-params-persistence-roundtrip

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] `grep -rn '04:unlocked-uniforms' Sources/` returns 0 hits.
- [ ] `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' Sources/` each ≥1 hit.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-5]Tests"`
- Scaffold inventory: `01:simple-metal-passthrough` and `01:skip-completion-guard` live; `04:unlocked-uniforms` retired.
- Device smoke on iPad Pro M1: re-run the 04 stress sequence (rapid slider motion at 60 Hz for 10 seconds) — no single-frame torn artifacts observed.
- Instruments Time Profiler: `OSAllocatedUnfairLock.lock()` hold time per frame < 10µs.

## 12. State.md updates (Claude Code writes these)
- Retires: 04:unlocked-uniforms.
- Adds (permanent): `OSAllocatedUnfairLock<UniformStorage>` around Pass 2 uniform snapshot; `ProcessingMetadata` value type (field stub on `FrameSet`, populated in Stage 06); Inv 6 enforced in code.
- Adds (public API): (none).
- Evidence: (none beyond unit tests this stage).
