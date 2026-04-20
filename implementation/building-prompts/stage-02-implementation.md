You are an iOS engineer starting Stage 02 of a multi-stage native-iOS camera library. You are running in the `eva-swift-stitch/` repo. You have no conversation memory from prior sessions; everything you need lives on disk.

Stage 02 is a MIGRATION. It retires the Stage 01 scaffold `01:naive-scenephase-stop` and installs the ADR-09 GPU submission gate (`ManagedAtomic<Bool>`) with `waitUntilScheduled()` drain on `.inactive`, plus `backgroundSuspend()` / `backgroundResume()` via ADR-30 async-with-timeout. No new user-visible features. All Stage 01 behavior must be preserved.

The authoritative specification for this stage is `implementation/briefs/stage-02.md`. Twelve numbered sections, same schema as every brief in the corpus. The brief is the source of truth. If the architecture or platform guide appears to contradict the brief, the brief wins — record the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed.

Context you must read before writing any code:
- `implementation/briefs/stage-02.md` — full spec. Read end to end.
- `implementation/briefs/README.md` — implementer read-path, stage-kickoff template, glossary.
- `implementation/briefs/stage-01.md` §12 — the state you should be entering.
- `CameraKit/state.md` — the Stage 01 exit state on disk. Must match stage-01 §12.
- For every architecture anchor cited in brief §5 (`02-concurrency.md#isolation-topology-adr-02-adr-07-adr-21`, `#concurrency-contract-table`, `#cross-subsystem-sequencing`, `#d-06-strict-inactive-gating-policy`; `04-metal-pipeline.md#command-graph`; `03-camera-session.md#background-suspend-and-resume`; `08-ui.md#scenephase-wiring`; `decisions.md`) — open and read the cited section in `implementation/architecture/`.
- For every domain file cited in §6 (`04-concurrency-invariants.md`, `05-resource-lifecycle.md`, `06-error-and-recovery.md`, `09-ui-behaviors.md`) — open and read at `implementation/domain-revised/<file>`. The `domain-revised/` tree is the platform-neutral behavioral spec upstream of the iOS architecture; it contains no Android API names and is safe to read alongside the brief. In this repo `implementation/domain-revised/` is a symlink to the canonical copy.

Pre-flight (MANDATORY — execute before writing any code):
1. Confirm `CameraKit/state.md` exists. If it does not, HALT: Stage 01 has not landed yet.
2. Read `CameraKit/state.md`. Its "Scaffolding still live" must match brief §2 exactly: `01:naive-scenephase-stop`, `01:simple-metal-passthrough`, `01:skip-completion-guard`. Any mismatch → HALT and report: state drift has occurred, upstream investigation required.
3. For each scaffold in `CameraKit/state.md` "Scaffolding still live", run `grep -rn "<slug>" CameraKit/Sources/` and confirm ≥1 hit. If any slug is listed in state.md but absent from source, or present in source but absent from state.md, HALT.
4. Run `swift test --package-path CameraKit/ --filter Stage01Tests`. If any Stage 01 test is red, HALT: a prior stage's test suite must be green before a MIGRATION begins.

Work to perform (per brief §4 — do not deviate, do not add):
- Modify `CameraKit/Sources/CameraKit/CameraEngine.swift`: add `submissionGate: ManagedAtomic<Bool>`, `lastCommittedCommandBuffer: MTLCommandBuffer?`, internal helpers `setGate(_:)` and `drainSubmittedFrame() async`, and implement `backgroundSuspend()` / `backgroundResume()` via the new `AsyncWithTimeout` helper. `close()` disarms placeholder watchdog hooks (no-op — real watchdogs land in Stage 09) and calls `submissionGate.store(false, ordering: .sequentiallyConsistent)`.
- Modify `CameraKit/Sources/CameraKit/MetalPipeline.swift`: insert the gate check after CPU-side encode and IMMEDIATELY before `commandBuffer.commit()`. If the gate is false, drop the frame — no `commit()`. Keep the `// scaffolding:01:simple-metal-passthrough` comment unchanged — that scaffold is NOT retired in this stage.
- Modify `CameraKit/Sources/CameraKit/CaptureDelegate.swift`: read the gate after encoding and before `commandBuffer.commit()`. Keep the `// scaffolding:01:skip-completion-guard` comment unchanged — also NOT retired here.
- Modify `CameraKit/Sources/CameraKit/ViewModel.swift`: REMOVE the `// scaffolding:01:naive-scenephase-stop` comment and its body. Rewire `.onChange(of: scenePhase)` per the brief: `.inactive` → `await engine.setGate(false); await engine.drainSubmittedFrame()`; `.active` returning from `.inactive` → `await engine.setGate(true)`; `.background` → `await engine.backgroundSuspend()`; `.active` returning from `.background` → `await engine.backgroundResume()`.
- Create `CameraKit/Sources/CameraKit/AsyncWithTimeout.swift`: ADR-30 helper bridging `@MainActor` callers to `sessionQueue` `startRunning()` / `stopRunning()` with a `constants.md#SESSION_LIFECYCLE_TIMEOUT_SECONDS` deadline via `CheckedContinuation` + `DispatchQueue.asyncAfter` deadline fallback.
- Modify `CameraKit/Sources/CameraKit/CameraSession.swift`: expose `startRunning()` and `stopRunning()` as awaitable via `AsyncWithTimeout`.
- Update `CameraKit/Package.swift`: add `swift-atomics` (`https://github.com/apple/swift-atomics`) as a package dependency and link `Atomics` into the `CameraKit` library target. This is the expected home for `ManagedAtomic<Bool>` per ADR-09.
- Create `CameraKit/Tests/CameraKitTests/Stage02Tests.swift`: one `@Test` per TESTABLE entry in brief §8. The §9 "Tests preserved" entries (`01:engine-open-close-transitions`, `01:preview-renders-first-frame`) are re-run via the existing Stage01 test bundle — do not duplicate them in Stage02Tests.

Load-bearing invariants you must NOT violate:
- The gate is `ManagedAtomic<Bool>` with sequentially-consistent ordering on writes, checked after CPU-side work and IMMEDIATELY before `commit()` (ADR-09). Violation produces `MTLCommandBufferErrorNotPermitted` IOAF 6 → process termination on background submit (row 4 of `02-concurrency.md#concurrency-contract-table`).
- The `.inactive` policy is STRICT per D-06: do NOT guard the gate-close with `UIApplication.applicationState`. Every `.inactive` gates regardless of cause (notification banner, Control Center, etc.).
- `lastCommittedCommandBuffer?.waitUntilScheduled()` runs on the engine actor once the gate is set false, bounding the drain window within `constants.md#FRAME_LATENCY_BUDGET_MS`. Do not await the buffer inside the delivery-queue completion handler — that would stall the frame clock.
- `backgroundSuspend()` / `backgroundResume()` use ADR-30 async-with-timeout against `constants.md#SESSION_LIFECYCLE_TIMEOUT_SECONDS`. Timeouts resume the continuation; they do not throw — the caller treats a timeout as an observable state stall.
- Do NOT install the D-10 completion-handler re-entrancy guard here. `// scaffolding:01:skip-completion-guard` MUST still be grep-findable in `MetalPipeline.swift` and `CaptureDelegate.swift` after this stage. D-10 lands in Stage 09.
- Do NOT install Pass 2 / color transforms / `OSAllocatedUnfairLock` / `CVPixelBufferPool` trio / `FrameSet` / `ConsumerRegistry` real bodies / C++ interop. Each is a documented later stage.
- The two tests listed in brief §9 (`01:engine-open-close-transitions`, `01:preview-renders-first-frame`) must still pass unchanged. If either fails after your migration, your migration is wrong — fix the implementation, not the test.

Stage-kickoff workflow (execute in order):
1. Read the brief + cited architecture refs + cited domain refs + prior `state.md` + `stage-01.md` §12.
2. Pre-flight checks (above). HALT on any mismatch and report which check failed.
3. Implement modifications in the order listed in brief §4.
4. Remove the `// scaffolding:01:naive-scenephase-stop` comment everywhere it appears, together with the naive stop body. The other two `01:*` slugs stay untouched.
5. Write `Stage02Tests.swift` covering every TESTABLE entry in §8. Use the same `CaptureDeviceProviding` fake style as Stage 01; add a fake `MTLCommandQueue` / `AVCaptureSession` as needed for gate-count and timeout assertions. Do not duplicate the §9 preserved tests.
6. Run verification per brief §11:
   - `swift build --package-path CameraKit/` — passes with no new warnings.
   - `swift test --package-path CameraKit/ --filter "Stage0[12]Tests"` — full Stage 01 + Stage 02 sweep green.
   - `grep -rn '01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/` — each slug ≥1 hit.
   - `grep -rn '01:naive-scenephase-stop' CameraKit/Sources/` — 0 hits.
   - `xcodebuild -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build` — the app still builds; adjust the destination to a simulator installed on the machine if the named one is unavailable.
7. HITL entries (`02:notification-banner-freezes-preview`, `02:background-stops-session-cleanly`): if a physical device is available, exercise them and record evidence under `measurements/stage-02/scenephase.md`. Otherwise, mark them as deferred under `state.md` "Manual test evidence" — do not claim they passed.
8. Update `CameraKit/state.md` per brief §12:
   - Move `01:naive-scenephase-stop` out of "Scaffolding still live". "Scaffolding still live" should now read `01:simple-metal-passthrough, 01:skip-completion-guard`.
   - Append to "What's built (permanent)": `ManagedAtomic<Bool>` GPU submission gate; `waitUntilScheduled()` drain path; `backgroundSuspend()` / `backgroundResume()` via `AsyncWithTimeout`; `scenePhase` strict gate-then-drain-then-stop wiring.
   - Append to "Public API exposed so far": `CameraEngine.backgroundSuspend()`, `CameraEngine.backgroundResume()`.
9. Stop. Surface a change-set summary and wait for explicit user approval before any git operation.

Rules you must NOT violate:
- Do not edit `implementation/briefs/`, `implementation/architecture/`, or `implementation/ios-platform-guide/`. Gaps go in `state.md` "Open questions for next stage"; do not hand-patch upstream.
- Do not run `git commit` / `git push` / any destructive git operation without explicit approval.
- Do not add features beyond brief §4. No speculative helpers, no "future-proof" abstractions.
- Do not retire any scaffold other than `01:naive-scenephase-stop`. `01:simple-metal-passthrough` retires in Stage 08; `01:skip-completion-guard` retires in Stage 09.
- Do not break any Stage 01 test. If a Stage 01 test is red after your migration, your migration is wrong — do not alter the test to make it green.
- Do not leak Android API names (`Camera2`, `HandlerThread`, `ImageReader`, `SurfaceTexture`, `EGLContext`, etc.) into code, comments, or test names.
- Do not replace the `ManagedAtomic<Bool>` gate with a Swift actor property, a `DispatchQueue`, or `NSLock`. Per ADR-09 this is a hot per-frame read on the delivery queue; actor isolation would require a `Task` hop on every frame and violates `FRAME_LATENCY_BUDGET_MS`.
- Do not install `UIApplication.beginBackgroundTask` integration around the gate drain in this stage. Background-task wrapping of the recording drain is Stage 12; Stage 02 only touches preview-path gating and `AVCaptureSession` lifecycle.

Stop condition and final output:
- Every checkbox in brief §10 either passes in verification or is recorded as deferred (with a reason) in `CameraKit/state.md`.
- `CameraKit/state.md` reflects brief §12: `01:naive-scenephase-stop` retired from "Scaffolding still live"; the two new permanent primitives appended to "What's built (permanent)"; `backgroundSuspend()` / `backgroundResume()` appended to "Public API exposed so far".
- No git operation has been run.
- Your final message summarizes: files modified, `swift build` output (warning count), `swift test` output (pass/fail count per test name, both Stage01 and Stage02), grep-inventory output showing `01:naive-scenephase-stop` at 0 hits and the other two slugs ≥1 hit each, `xcodebuild` build status, any deferred HITL items, and the `state.md` diff. End by asking the user to approve the commit.
