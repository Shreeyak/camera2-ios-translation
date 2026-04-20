# Stage 08 — Consumer registry — C++ PixelSink pool (MIGRATION)

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 01, Stage 06, Stage 07
Retires scaffolding from: Stage 06 (simple-consumer-swift-only)
Retires scaffolding from: Stage 01 (simple-metal-passthrough)
Retires scaffolding from: Stage 07 (swift-side-capture-atomic)

## 2. Starting state
Scaffolding still live: 01:simple-metal-passthrough, 01:skip-completion-guard, 06:simple-consumer-swift-only, 07:swift-side-capture-atomic
What's built (permanent): Package.swift; `CameraEngine` (open/close/background*/updateSettings/setResolution/setProcessingParameters/setCropRegion/sampleCenterPatch/getPersistedProcessingParameters/captureImage/stateStream/frameResultStream); Pass 1 + Pass 2 + Pass 4 + Pass 6 (still-capture blit); `OSAllocatedUnfairLock<UniformStorage>`; `ProcessingMetadata` + `FrameSet`; three-pool trio + still-capture pool; `ConsumerRegistry` actor with Swift-only `subscribe(stream:)` + `unregister(token:)`; TIFF capture + EXIF + Photos authorization + documents fallback; tracker thumbnail + debug overlay; settings + persistence; KVO→AsyncStream; gate + `waitUntilScheduled()` drain; `scenePhase` strict wiring; frame-result heartbeat at 3Hz.
Public API exposed so far: `init(device:consumers:)`, `open(configuration:)`, `close()`, `backgroundSuspend()`, `backgroundResume()`, `updateSettings(_:)`, `setResolution(size:)`, `setProcessingParameters(_:)`, `setCropRegion(_:)`, `sampleCenterPatch()`, `getPersistedProcessingParameters()`, `captureImage(outputPath:)`, `stateStream()`, `frameResultStream()`, `ConsumerRegistry.subscribe(stream:)`, `ConsumerRegistry.unregister(token:)`.

## 3. Goal
- Adds: C++ `PixelSink` pool (Mechanism A per D-01); C-ABI `PixelSinkCallbacks` struct (D-03); `ConsumerRegistry.registerCallback(stream:callbacks:)` real path; OpenCV-backed Canny stub on the tracker stream as the initial acceptance consumer (ADR-29); `CameraEngine.getNativePipelineHandle()` returning the opaque raw pointer per D-15; C++-side `std::atomic<bool>` capture-in-flight guard assuming Invariant 7 ownership; complete Pass-3 color-transform chain pairing (Pass-1 + Pass-2 + Pass-3 + Pass-4 in effect — processed path has real color work, so no passthrough scaffold remains).
- Removes: 06:simple-consumer-swift-only, 01:simple-metal-passthrough, 07:swift-side-capture-atomic.
- Behavior preserved: Swift-side subscribers continue to receive `FrameSet` (06:frame-set-publication); drop-on-busy semantics on slow subscribers (06:swift-consumer-drop-on-busy); still-capture in-flight guarding (07:still-capture-in-flight-guard) now satisfied by the C++ atomic.

## 4. Files to create / modify / delete
- create: Sources/CameraKitCxx/include/PixelSink.hpp (permanent) — C++ abstract class per ADR-31; `onFrame(const PixelFrame&)` + `onOverwrite(const OverwriteEvent&)` virtuals; POD-only header surface (no OpenCV in public headers per ADR-11).
- create: Sources/CameraKitCxx/include/PixelSinkCallbacks.h (permanent) — C header with `PixelSinkCallbacks` struct (D-03): `@convention(c)` function pointers for `on_frame`, `on_overwrite`, `on_unregister` + opaque `void* context`.
- create: Sources/CameraKitCxx/PixelSinkPool.cpp (permanent) — `std::mutex`-guarded pool with `pipeline > stage > consumer` lock ordering (D-16); three-level hierarchy; pool thread cap `CPP_POOL_THREAD_COUNT = min(4, hardware_concurrency)`.
- create: Sources/CameraKitCxx/CaptureAtomic.hpp (permanent) — `std::atomic<bool>` capture-in-flight guard; CAS semantics identical to the retired Swift-side atomic (Invariant 7 now lives on the C++ side).
- create: Sources/CameraKitInterop/CameraKitInterop.swift (permanent) — thin Swift module isolating C++ interop per ADR-13 §Keep `.interoperabilityMode(.Cxx)` contained; exports `@convention(c)` function-pointer typealiases and a `Unmanaged.passRetained` → `void* context` shim confined to a single site.
- modify: Sources/CameraKit/Consumer.swift — `ConsumerRegistry.registerCallback(stream:callbacks:)` real implementation: constructs a C++-side `PixelSink` entry, wires retain via `Unmanaged.passRetained(self).toOpaque()` for `context`, returns a `ConsumerToken` that drops the retain on unregister; remove `scaffolding:06:simple-consumer-swift-only` comment; Swift-side `subscribe(stream:)` is now a facade over the same C++ pool (D-01).
- modify: Sources/CameraKit/StillCapture.swift — delete the `ManagedAtomic<Bool>` guard and its `scaffolding:07:swift-side-capture-atomic` marker; delegate the Invariant-7 guard to the C++ `CaptureAtomic` through the `CameraKitCxx` target; `StillCaptureError.alreadyInFlight` is now raised from the C-ABI check.
- modify: Sources/CameraKit/MetalPipeline.swift — delete the `scaffolding:01:simple-metal-passthrough` comment (by this stage every compute pass 1/2/3/4 is in place with real color work); add Pass 3 (if distinct from Pass 2 per `04-metal-pipeline.md` §Command graph — e.g. tone-map or RGBA chain finalization) to close the processed chain.
- modify: Sources/CameraKit/CameraEngine.swift — implement `getNativePipelineHandle() -> UInt64?` returning the raw C++ pool pointer per D-15 while holding the engine actor; remove the stubbed `fatalError`.
- modify: Sources/CameraKit/Errors.swift — add `InteropError` real variants (retainMismatch, invalidCallbacks); keep `.notWired` for forward-compat (or remove if no longer needed — prefer remove).
- modify: Package.swift — add `CameraKitCxx` `.target` with `.publicHeadersPath("include")`, `cxxLanguageStandard: .cxx20`; add `CameraKitInterop` Swift target; OpenCV xcframework as a private dependency of `CameraKitCxx` only (Canny consumer is inside that target).
- create: Sources/CameraKitCxx/CannyStubConsumer.cpp (permanent) — OpenCV-backed Canny edge stub; consumes tracker frames; writes result metadata to a ring buffer for the debug overlay (ADR-29).
- create: Tests/CameraKitTests/Stage08Tests.swift — see §8.

## 5. Architecture refs
- architecture/05-consumers.md#d-01-consumer-fan-out-uses-mechanism-a-c-pixelsink-pool
- architecture/05-consumers.md#d-03-c-abi-callback-struct-as-the-default-integration-shape
- architecture/05-consumers.md#d-12-natural-stream-is-subscribable
- architecture/05-consumers.md#d-15-native-pipeline-pointer-guard
- architecture/05-consumers.md#mailbox-semantics
- architecture/05-consumers.md#consumer-lifecycles
- architecture/05-consumers.md#thread-pool-sizing
- architecture/02-concurrency.md#d-16-c-lock-ordering-pipeline-stage-consumer
- architecture/01-system-shape.md#swift-module-layout
- architecture/06-capture-and-recording.md#still-image-capture
- architecture/api-surface.md

## 6. Domain refs
- domain-revised/02-frame-delivery.md
- domain-revised/04-concurrency-invariants.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/10-api-contract.md

## 7. Contracts & invariants
- Consumer fan-out is Mechanism A (D-01); Swift-side `subscribe(stream:)` is a facade over the same C++ pool.
- C-ABI `PixelSinkCallbacks` is the permanent integration shape (D-03, OQ-02); no Swift-subclass spike is scheduled.
- C++ lock ordering: `pipeline > stage > consumer` (D-16); callers acquire from outermost to innermost.
- Pipeline-pointer guard: Swift actor boundary + C++ `std::mutex`; `getNativePipelineHandle()` returns the raw pointer only while holding the engine actor (D-15, Inv 4).
- Invariant 7 (capture in-flight) now owned by `std::atomic<bool>` on the C++ side; identical CAS semantics to the retired Swift-side atomic; both lock-free.
- OpenCV is confined to `CameraKitCxx`; no OpenCV symbol escapes to public headers or the main Swift module (ADR-11).
- The processed path now renders full Pass 1 + Pass 2 + Pass 3 + Pass 4 color work; no scaffold passthrough remains.
- IOSurface-backed `CVPixelBuffer`s cross the Swift↔C++ boundary (ADR-18); the C-ABI frame struct is POD.
- Pool thread count caps at `CPP_POOL_THREAD_COUNT`.

## 8. Tests to write
- TESTABLE: 08:cpp-pixelsink-registration-roundtrip — register a C-ABI callback via `ConsumerRegistry.registerCallback(stream: .tracker, callbacks:)`; inject synthetic tracker frames; the C-side `on_frame` is invoked for each; `unregister(token:)` drops the retain (verified via a weak-ref proxy).
- TESTABLE: 08:canny-stub-consumer-receives-tracker-frames — with the Canny stub registered, injecting 10 tracker frames results in 10 `on_frame` invocations on the C++ side; the stub's ring-buffer reports 10 processed frames.
- TESTABLE: 08:get-native-pipeline-handle-holds-actor — `getNativePipelineHandle()` can only return while the engine actor is active; a test that calls it concurrently with `close()` sees either the handle or `nil` (no UAF, no crash).
- TESTABLE: 08:c-abi-callbacks-without-on-frame-rejected — attempting to register `PixelSinkCallbacks` with `on_frame == nil` throws `InteropError.invalidCallbacks`. (Note: the `on_overwrite` guardrail is authored in Stage 12 as a separate registration-quality gate per D-11; this test only covers the `on_frame` POD required-ness.)
- TESTABLE: 08:lock-order-pipeline-stage-consumer — instrumented C++ test; acquiring `stage` before `pipeline` triggers an assertion; lock-order-inversion detected by the debug hierarchy (ADR-11).
- TESTABLE: 08:still-capture-uses-cpp-atomic — two concurrent `captureImage` calls; second throws `StillCaptureError.alreadyInFlight` from the C++ atomic path; neither the Swift-side atomic nor the `07:swift-side-capture-atomic` scaffold marker is present in sources.
- TESTABLE: 08:swift-subscribe-is-facade-over-cpp-pool — a Swift `for await frameSet in subscribe(stream: .natural)` and a C-ABI `on_frame` registered on `.natural` both receive the same frames in the same order (within mailbox-drop semantics).
- TESTABLE: 06:frame-set-publication — carried forward; still passes with the new C++ pool underneath the Swift facade.
- TESTABLE: 06:swift-consumer-drop-on-busy — carried forward; drop semantics preserved through the new path.
- TESTABLE: 07:still-capture-in-flight-guard — carried forward; Invariant 7 now enforced by the C++ atomic with identical observable behavior.
- HITL: 08:external-canny-stub-runs-on-device — Canny stub is the initial acceptance consumer on the tracker stream; debug overlay shows Canny output frame-by-frame; subscribe/unsubscribe at runtime without disturbing natural/processed preview; device: iPad Pro M1.

## 9. Tests preserved (must still pass)
- 06:frame-set-publication
- 06:swift-consumer-drop-on-busy
- 07:still-capture-in-flight-guard

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings; `cxxLanguageStandard: .cxx20` builds on iOS.
- [ ] All prior-stage tests pass unchanged (including the three §9 preserved tests).
- [ ] New TESTABLE tests pass.
- [ ] HITL 08:external-canny-stub-runs-on-device confirmed on iPad Pro M1.
- [ ] `grep -rn '06:simple-consumer-swift-only\|01:simple-metal-passthrough\|07:swift-side-capture-atomic' Sources/` returns 0 hits.
- [ ] `grep -rn '01:skip-completion-guard' Sources/` ≥1 hit (the last remaining scaffold).

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[1-8]Tests"`
- Scaffold inventory: only `01:skip-completion-guard` live (≥1 hit).
- Device smoke on iPad Pro M1: register Canny stub on `.tracker`; observe debug overlay shows edge output; unregister; preview continues undisturbed.
- Instruments System Trace: confirm `pipeline > stage > consumer` lock order across 10s of simulated load; no lock-order inversions.
- Module-boundary check: `swift-api-digester` or `nm` on the built `CameraKit` framework confirms no OpenCV symbols leaked.

## 12. State.md updates (Claude Code writes these)
- Retires: 06:simple-consumer-swift-only, 01:simple-metal-passthrough, 07:swift-side-capture-atomic.
- Adds (permanent): C++ `PixelSinkPool` (Mechanism A); C-ABI `PixelSinkCallbacks` struct (POD); `CameraKitCxx` + `CameraKitInterop` SPM targets; OpenCV-backed Canny stub consumer; `std::atomic<bool>` capture-in-flight guard; `getNativePipelineHandle()` real path; full Pass-3 processed-chain finalization; `InteropError` real variants.
- Adds (public API): `ConsumerRegistry.registerCallback(stream:callbacks:) -> ConsumerToken`; `CameraEngine.getNativePipelineHandle() -> UInt64?`.
- Evidence: HITL 08:external-canny-stub-runs-on-device — `measurements/stage-08/canny.md`.
