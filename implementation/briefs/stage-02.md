# Stage 02 — scenePhase / GPU submission gate (MIGRATION)

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 01
Retires scaffolding from: Stage 01 (naive-scenephase-stop)

## 2. Starting state
Scaffolding still live: 01:naive-scenephase-stop, 01:simple-metal-passthrough, 01:skip-completion-guard
What's built (permanent): Package.swift; `CameraEngine` actor (open/close/stateStream); `CameraSession`; `CaptureDelegate`; `CaptureDeviceProviding` + `DeviceStateSnapshot` types; `Capabilities`, `SessionState`, `StreamId`, `EngineError`, `FrameSet` (stub), `Constants`; `CameraView` + `ViewModel` + MTKView wrapper; `ConsumerRegistry` stub.
Public API exposed so far: `CameraEngine.init(device:consumers:)`, `open(configuration:)`, `close()`, `stateStream()`.

## 3. Goal
- Adds: `ManagedAtomic<Bool>` GPU submission gate (ADR-09) with `waitUntilScheduled()` drain on `.inactive`; `backgroundSuspend()` / `backgroundResume()` via ADR-30 async-with-timeout; `scenePhase` observer rewired to gate-then-drain-then-stop on `.background`.
- Removes: 01:naive-scenephase-stop.
- Behavior preserved: live natural preview renders on launch (01:preview-renders-first-frame); engine open/close transitions emit correct `stateStream` sequence (01:engine-open-close-transitions).

## 4. Files to create / modify / delete
- modify: Sources/CameraKit/CameraEngine.swift — add `backgroundSuspend()` / `backgroundResume()` implementations; add engine-owned `submissionGate: ManagedAtomic<Bool>` and `lastCommittedCommandBuffer: MTLCommandBuffer?`; internal helpers `setGate(_:)` and `drainSubmittedFrame() async`; `close()` path now disarms watchdogs (placeholder no-op until Stage 09) and calls `submissionGate.store(false)`.
- modify: Sources/CameraKit/MetalPipeline.swift — gate check inserted after CPU-side encode, immediately before `commit()` per ADR-09; on closed gate, the frame is dropped (no-op, no commit); retain `scaffolding:01:simple-metal-passthrough` comment (Pass-1-only still in force).
- modify: Sources/CameraKit/CaptureDelegate.swift — `captureOutput(_:didOutput:from:)` reads the gate after encoding and before `commandBuffer.commit()`; retains the completion-handler NO-OP scaffold comment `01:skip-completion-guard`.
- modify: Sources/CameraKit/ViewModel.swift — remove `01:naive-scenephase-stop` comment and body; `onChange(of: scenePhase)` now branches: `.inactive` → `await engine.setGate(false); await engine.drainSubmittedFrame()`; `.active` → `await engine.setGate(true)`; `.background` → `await engine.backgroundSuspend()`; `.active` returning from `.background` → `await engine.backgroundResume()`.
- create: Sources/CameraKit/AsyncWithTimeout.swift (permanent) — ADR-30 `async-with-timeout` helper bridging `@MainActor` callers to `sessionQueue` `startRunning()` / `stopRunning()` with `SESSION_LIFECYCLE_TIMEOUT_SECONDS` deadline via `CheckedContinuation`.
- modify: Sources/CameraKit/CameraSession.swift — `stopRunning()` and `startRunning()` become callable via `AsyncWithTimeout` from the engine actor.
- create: Tests/CameraKitTests/Stage02Tests.swift — see §8.

## 5. Architecture refs
- architecture/02-concurrency.md#isolation-topology-adr-02-adr-07-adr-21
- architecture/02-concurrency.md#concurrency-contract-table
- architecture/02-concurrency.md#cross-subsystem-sequencing
- architecture/02-concurrency.md#d-06-strict-inactive-gating-policy
- architecture/04-metal-pipeline.md#command-graph
- architecture/03-camera-session.md#background-suspend-and-resume
- architecture/08-ui.md#scenephase-wiring
- architecture/decisions.md

## 6. Domain refs
- domain-revised/04-concurrency-invariants.md
- domain-revised/05-resource-lifecycle.md
- domain-revised/06-error-and-recovery.md
- domain-revised/09-ui-behaviors.md

## 7. Contracts & invariants
- Gate is `ManagedAtomic<Bool>` checked after CPU-side work, immediately before `commit()` (ADR-09, Inv "gate-before-commit").
- D-06: `.inactive` policy is strict — no check of `UIApplication.applicationState`; every `.inactive` gates regardless of cause.
- `lastCommittedCommandBuffer?.waitUntilScheduled()` runs on the engine actor once the gate is set false, bounding the drain window within `FRAME_LATENCY_BUDGET_MS`.
- `backgroundSuspend()` / `backgroundResume()` use ADR-30 async-with-timeout against `SESSION_LIFECYCLE_TIMEOUT_SECONDS` for `AVCaptureSession.startRunning()` / `stopRunning()` on `sessionQueue`.
- Violation of the gate produces `MTLCommandBufferErrorNotPermitted` IOAF 6 → process termination on background submit (row 4 of `02-concurrency.md` §Concurrency contract table).
- Watchdog disarm is a placeholder until Stage 09; scaffold `01:skip-completion-guard` still forbids `sessionState` checks inside completion handlers this stage.

## 8. Tests to write
- TESTABLE: 02:gate-closes-on-inactive — with a fake `MTLCommandQueue` asserting `commit()` count, toggling the ViewModel's `scenePhase` to `.inactive` stops `commit()` calls within one frame; toggling back to `.active` resumes commits.
- TESTABLE: 02:wait-until-scheduled-on-inactive — after `.inactive`, the most recently committed command buffer has had `waitUntilScheduled()` awaited before the gate-false `stateStream` observation completes.
- TESTABLE: 02:background-suspend-via-async-timeout — `backgroundSuspend()` completes ≤ `SESSION_LIFECYCLE_TIMEOUT_SECONDS`; a fake `CameraSession` hanging `stopRunning()` surfaces a timeout (observable as the continuation resuming on deadline).
- TESTABLE: 02:background-resume-is-noop-until-interruption-ended — `backgroundResume()` called before `interruptionEnded` is harmless (idempotent; no thrown error; session stays stopped until the actual interruption-ended signal arrives).
- HITL: 02:notification-banner-freezes-preview — pull down Notification Center over running app; preview freezes on last frame; dismiss restores frames; device: iPad Pro M1.
- HITL: 02:background-stops-session-cleanly — home-button to background; `sessionState` reaches `.closed`; return to foreground; preview resumes within one frame; device: iPad Pro M1.
- TESTABLE: 01:engine-open-close-transitions — carried forward; fake device provider; see Stage 01 §8. Re-asserted under the new `scenePhase` wiring.
- TESTABLE: 01:preview-renders-first-frame — re-runnable as a simulated-delegate unit test (inject a synthetic `CMSampleBuffer`; assert `MTKView.draw` is invoked); simulator harness from Stage 01 extended.

## 9. Tests preserved (must still pass)
- 01:engine-open-close-transitions
- 01:preview-renders-first-frame

## 10. Acceptance criteria
- [ ] `swift build` passes, no new warnings.
- [ ] All prior-stage tests (`01:*`) pass unchanged.
- [ ] New TESTABLE tests pass.
- [ ] HITL 02:notification-banner-freezes-preview and 02:background-stops-session-cleanly visually confirmed on iPad Pro M1.
- [ ] `grep -rn '01:naive-scenephase-stop' Sources/` returns 0 hits (scaffold retired); the other two scaffold slugs still present.

## 11. Verification steps
- Build: `swift build`
- Unit tests: `swift test --filter "Stage0[12]Tests"`
- Scaffold inventory: `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' Sources/` — each ≥1 hit; `grep -rn '01:naive-scenephase-stop' Sources/` — 0 hits.
- Device smoke: iPad Pro M1; exercise Notification Center, home-button background, and return-to-foreground sequences.
- Instruments: Metal System Trace 30s capture confirming `MTLCommandBuffer` commit count drops to zero while `.inactive`, resumes on `.active`.

## 12. State.md updates (Claude Code writes these)
- Retires: 01:naive-scenephase-stop.
- Adds (permanent): `ManagedAtomic<Bool>` GPU submission gate; `waitUntilScheduled()` drain path; `backgroundSuspend()` / `backgroundResume()` via `AsyncWithTimeout`; `scenePhase` strict gate-then-drain-then-stop wiring.
- Adds (public API): `CameraEngine.backgroundSuspend()`, `CameraEngine.backgroundResume()`.
- Evidence: HITL 02:notification-banner-freezes-preview and 02:background-stops-session-cleanly — record under `measurements/stage-02/scenephase.md`.
