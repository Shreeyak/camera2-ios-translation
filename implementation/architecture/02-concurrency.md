# 02 — Concurrency

Primary-owner file for **who runs where** and **which primitive enforces which domain
invariant**. The 12 invariants in `domain-revised/04-concurrency-invariants.md` map to
Swift 6 primitives here; cross-subsystem sequencing rules live in this file, not spread
across callers.

---

## Isolation topology (ADR-02, ADR-07, ADR-21)

Two Swift actors and two `DispatchQueue`s per `CameraEngine` session:

| Isolation domain | Kind | Runs | Cited ADR |
|---|---|---|---|
| `@MainActor` | default (ADR-21) | SwiftUI views, `ViewModel`, any `@Observable` state type | ADR-21 |
| `CameraEngine` | custom `actor` | Engine state, settings merge, recovery coordination, consumer registry delegation | ADR-02 |
| `sessionQueue` | serial `DispatchQueue` | `AVCaptureSession.startRunning()` / `stopRunning()`; `AVCaptureDevice.lockForConfiguration()` | ADR-07 |
| `delivery` | serial `DispatchQueue` | `AVCaptureVideoDataOutputSampleBufferDelegate`; Metal encode + commit + present; completion handlers; consumer publish | ADR-07 |

The delegate class pattern (`final class CaptureDelegate: NSObject, @unchecked Sendable,
AVCaptureVideoDataOutputSampleBufferDelegate` + `nonisolated` method) follows ADR-07 §Swift 6
delegate class declaration verbatim. All four attributes are load-bearing; omitting any one
produces a compile error or a latent data race (see `ios-platform-guide/02-concurrency.md`
for the authoritative statement; do not repeat the argument here).

---

## Concurrency contract table

Every domain invariant in `domain-revised/04-concurrency-invariants.md` is enforced by at
least one row below. Primitives may enforce multiple invariants.

| Mechanism | Invariants enforced | Failure mode if violated |
|---|---|---|
| `actor CameraEngine` (ADR-02) | Inv 1 (camera-state serialization), Inv 9 (recovery retries cancelled on close / suspend), Inv 12 (watchdog callbacks observe only originating session — via captured session-token identity) | Concurrent state mutation; dangling retry; stale watchdog touches released resources |
| Dedicated `sessionQueue` (ADR-07) via async-with-timeout (ADR-30) | Inv 1 (state mutation ≠ UI context; all `lockForConfiguration` calls serialized), Inv 6 (per-frame uniform write path serialized with session-queue-driven config) | `NSGenericException` on `lockForConfiguration` from main; purple warning; blocking `startRunning` on `@MainActor` (G-03) |
| Dedicated `delivery` queue + `nonisolated` `CaptureDelegate` (ADR-07, ADR-02) | Inv 2 (GPU operations on single dedicated serial context), Inv 10 (consumer dispatch never blocks frame path), Inv 11 (stall timestamp written on delivery, read elsewhere via atomic — see row below) | Lost capture-order ordering (ADR-02 anti-pattern); per-frame `Task` allocation drains `CVPixelBuffer` pool; preview hitches |
| `ManagedAtomic<Bool>` submission gate (ADR-09) | Inv 8 (fast-path capture-requested flag is lock-free; same primitive family), Inv 11 (stall timestamp visibility via `ManagedAtomic<UInt64>` siblings) | `MTLCommandBufferErrorNotPermitted` IOAF 6 on background submit → process termination |
| `.bufferingNewest(1)` mailbox (ADR-22) + `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` for state streams | Inv 3 (UI callbacks on main — consumer side uses `for await` on `@MainActor`), Inv 10 (drop-on-busy mailbox semantics) | Unbounded memory growth; backpressure pushes back into camera producer; missed state transitions |
| C-ABI `std::atomic<bool>` (capture-requested) and `std::atomic<uint64_t>` (mailbox overwrite count) in C++ `PixelSink` (ADR-13) | Inv 7 (capture in-flight guard via atomic CAS), Inv 8 (lock-free fast-path on every frame), Inv 10 (atomic publish of frame ref into 1-slot mailbox) | Two concurrent captures; frame path acquires a lock; mailbox race drops frames without counter |
| `std::mutex` native-pipeline-pointer guard in C++ + engine-actor boundary on Swift side (D-15) | Inv 4 (native pipeline pointer use-after-free) | UAF crash when teardown zeroes pointer mid-capture |
| C++ lock ordering `pipeline > stage > consumer` (domain Invariant 5) | Inv 5 | Deadlock at scale; silently-stuck consumer under contention |
| `OSAllocatedUnfairLock<UniformBuffer>` on the host-written uniform buffer, flushed to the Metal argument buffer per frame | Inv 6 (uniforms protected against concurrent write by slider + GPU-thread read) | Torn reads of per-channel color params → visible artifacts on one frame |
| Engine-captured `sessionToken` + completion-handler guard (D-10) | Inv 9 (retry no-ops after close — same mechanism), Inv 12 (watchdog / completion-handler no-op when session has advanced) | Use-after-free crashes on readback buffers (G-20); watchdog mutates wrong session's state |
| `Task` handles stored on `CameraEngine` + `.cancel()` in `close()` / `deinit` (ADR-23) | Inv 9 (recovery retry cancellation), implicit cross-Inv cleanup | Orphan tasks retain the actor indefinitely; pool drains |

Every row cites an ADR or introduces a `D-##`. No blank cells.

---

## Cross-subsystem sequencing

Sequences whose ordering crosses ≥2 concern files are written here as named sequences; other
concerns cite `02-concurrency.md#<anchor>` for the authoritative statement.

### Sequence A — scenePhase foreground → `.inactive` → `.background`

Drives: gating of GPU submission, session stop, watchdog discipline, optional recording drain.

1. `08-ui.md` — `.task(id: scenePhase)` observer on `CameraView` receives `.inactive`.
2. `02-concurrency.md` — engine sets `gpuSubmissionEnabled.store(false, ordering: .releasing)`
   on the delivery queue boundary and calls `lastCommittedCommandBuffer?.waitUntilScheduled()`
   per ADR-09. Submission gate check is **after** CPU-side work and immediately before
   `commit()` — async consumers and C++/CV pipelines continue (D-06 strict policy).
3. On `.background`: `08-ui.md` dispatches
   `engine.backgroundSuspend()` → engine calls `CameraSession.stop(timeout:)` on `sessionQueue`
   per ADR-30 (`constants.md#SESSION_LIFECYCLE_TIMEOUT_SECONDS`). Recovery retries are cancelled
   by the engine in the same actor-serialized step.
4. `09-errors-and-recovery.md` — both watchdogs are disarmed as **step 1** of the teardown
   (domain 02-frame-delivery §Watchdog lifecycle, 06-error-and-recovery §Non-Fatal Recovery).
5. `06-capture-and-recording.md` — if recording was active when `.background` fired, the
   engine requests `UIApplication.beginBackgroundTask`; the expiration handler **always**
   calls `cancelWriting`, never `finishWriting` (G-08). See `06-capture-and-recording.md`
   §Background drain for the authoritative statement.

On foreground (`.active`):
- `08-ui.md` sets `gpuSubmissionEnabled = true`.
- If the system emitted `AVCaptureSessionInterruptionEnded` with reason
  `videoDeviceNotAvailableInBackground`, engine calls `startRunning()` on `sessionQueue`
  per ADR-30. If the reason was `videoDeviceInUseByAnotherClient`, the engine exits self-
  healing as described in `09-errors-and-recovery.md` §Self-healing (D-14) — **user intent
  is required**; no auto-resume.

### Sequence B — Consumer subscribe / unsubscribe

Drives: `ConsumerRegistry` interaction with `TexturePoolManager` and the pool cap rule.

1. `05-consumers.md` — `ConsumerRegistry.subscribe(stream:)` or `.registerCallback` is
   invoked; the consumer lane is allocated atomically inside the registry actor.
2. `04-metal-pipeline.md` — `TexturePoolManager` observes the new lane count and continues
   with its start-simple `.shared` default (D-02); no storage-mode flip. The pool cap
   rule `N_active_lanes + 1` (`constants.md#POOL_CAP_RULE`) governs `CVPixelBufferPool`
   growth — CF handles allocation; the architecture does not grow/shrink explicitly.
3. `05-consumers.md` — the next `FrameSet` constructed in the completion handler publishes
   to the newly subscribed lane.

On unsubscribe: the consumer's `Task` cancellation terminates the `for await` loop; the
registry releases the lane; CF ages pool buffers out after
`constants.md#POOL_MAX_BUFFER_AGE_SECONDS`. No explicit teardown step required.

### Sequence C — Error → recovery

Drives: error classification, watchdog discipline, exponential backoff.

1. `09-errors-and-recovery.md` — error detected (camera HAL, `MTLCommandBuffer.status ==
   .error`, watchdog timeout, pool exhaustion).
2. **Step 1 of recovery (domain 06):** both watchdogs disarmed by `Watchdog.disarmAll()`
   called from the engine actor. This precedes any state transition and prevents a watchdog
   callback from firing mid-recovery.
3. Engine classifies via `EngineError`; decides fatal vs. non-fatal per
   `09-errors-and-recovery.md` §Classification.
4. If non-fatal and not already in terminal state: transition to `.recovering`; emit state;
   emit error (`isFatal: false`); verify retry budget (`constants.md#RECOVERY_MAX_RETRIES`);
   cancel any pending retry `Task`; schedule new retry `Task` with delay from
   `constants.md#RECOVERY_BACKOFF_<n>_MS` and a `try Task.checkCancellation()` per iteration
   (ADR-23).
5. If retry fires: full teardown (`03-camera-session.md` §Full teardown) → reopen.
6. If fatal or retry budget exhausted: full teardown → transition `.error` → emit fatal
   error. No further transitions except the self-healing path for `CAMERA_IN_USE` (D-14).

---

## D-06 — Strict `.inactive` gating policy

Minor. Per ADR-08 the two viable policies are strict (gate on every `.inactive`) and loose
(gate only when `UIApplication.shared.applicationState != .active`). Product choice: **strict**.
A scientific-imaging / professional-camera product tolerates a brief preview freeze on notification
banners more readily than it tolerates the App Store policy risk of a missed gate (G-05, G-19).
The cost is one frame of blackout when a banner drops; the benefit is a simpler invariant with
no `UIApplication` accessor on the hot path.

---

## D-10 — Completion-handler re-entrancy guard

Consequential. Crosses `02-concurrency.md` (this file) and `04-metal-pipeline.md` (all
`MTLCommandBuffer` consumers).

### Context

Between `commandBuffer.commit()` and its `addCompletedHandler` firing, the `CameraEngine`
actor may have serviced `close()`, `backgroundSuspend()`, or `setResolution()` — any of which
releases readback buffers, the pool, or the whole pipeline. A completion handler that acts on
stale pointers produces use-after-free crashes (G-20). Swift 6 strict concurrency does not
prevent this: the completion handler is `@Sendable` and runs on `delivery`, hopping back to
the engine via `Task { await self?.onFrameComplete(...) }`.

### Options considered

1. **Drop completion handlers entirely and poll status.** Rejected: completion handlers carry
   the only reliable GPU-error signal (`MTLCommandBuffer.status == .error` — G-02); polling
   adds latency + duplicates state.
2. **Cancel the completion handler on teardown.** Metal completion handlers cannot be
   cancelled once installed; the handler always fires.
3. **Capture expected session state at commit; no-op on mismatch.** Matches the pattern in
   `ios-platform-guide/02-concurrency.md §Completion-handler re-entrancy guard`.

### Decision

Every `MTLCommandBuffer` commit in the per-frame graph captures the current `sessionState`
into a local `expectedState`. The `addCompletedHandler` hops back to the engine via
`Task { await self?.onFrameComplete(readIndex: N, expectedState: .streaming) }`. Inside the
actor, the guard reads `sessionState` and compares to the captured token:

```
guard sessionState == expectedState, sessionState == .streaming else { return }
```

The mismatch no-op is silent — it is expected during teardown.

### Consequences

- Every per-frame completion handler in `MetalPipeline.swift` must apply the guard; tests
  enforce it by simulating rapid `close()` after `commit()`.
- The pattern extends to `RecoveryCoordinator` retry tasks (already covered by
  Inv 9: retry checks state before executing).
- Pairs with G-30 (actor re-entrancy across `await`): read state, compare, mutate, all
  within the same continuation. No `await` between guard and mutation.

### Reversibility

Minor code change to reverse — the guard is a two-line pattern. Kept as `Consequential`
because the pattern crosses every GPU completion site (04-metal-pipeline + 06-capture-and-recording
+ 08-ui for the preview blit) and changing it would require editing each call site.

---

## KVO → `AsyncStream` adapter (ADR-14)

`DeviceStateStream` in `CaptureDeviceProviding.swift` wraps the live `AVCaptureDevice` KVO
properties (`iso`, `exposureDuration`, `whiteBalanceGains`, `lensPosition`,
`isAdjustingExposure`, `systemPressureState`) as a single `AsyncStream<DeviceStateSnapshot>`.
The `Tokens` box + `cont.onTermination = { _ in _ = box }` pattern from
`ios-platform-guide/04-avfoundation.md` is the authoritative shape; see that file for the
rationale. The engine consumes the stream inside a `Task` stored on the actor and cancelled
in `close()` per ADR-23 (see **Task ownership and cleanup** in
`ios-platform-guide/02-concurrency.md`).

Buffering policy: `.bufferingOldest(STATE_STREAM_BUFFER_SIZE)` per ADR-22 (state-change
stream, every transition must be delivered).

---

## Streams owned by the engine

`CameraEngine` exposes four public `AsyncStream`s (`api-surface.md`). Every internal loop
reading from these or from internal streams stores its `Task<Void, Never>?` on the actor
and cancels it in `close()` / `deinit`. `Task.checkCancellation()` is called per iteration
per ADR-23.

| Stream | Purpose | Buffering | Consumer |
|---|---|---|---|
| `stateStream()` → `AsyncStream<SessionState>` | Session state transitions | `.bufferingOldest(64)` | ViewModel on `@MainActor` |
| `errorStream()` → `AsyncStream<CameraError>` | Errors (fatal + non-fatal) | `.bufferingOldest(64)` | ViewModel on `@MainActor` |
| `frameResultStream()` → `AsyncStream<FrameResult>` | Sensor metadata heartbeat at `FRAME_RESULT_HEARTBEAT_HZ` | `.bufferingNewest(1)` (frame-rate) | ViewModel on `@MainActor` |
| `recordingStateStream()` → `AsyncStream<RecordingState>` | Recording state transitions | `.bufferingOldest(64)` | ViewModel on `@MainActor` |

ViewModel subscribes via `.task { for await … }` per ADR-28 — auto-cancels on view
disappear.

---

## What this file deliberately does NOT specify

- The shape of the C++ `PixelSink` pool threads and per-consumer mailbox machinery —
  `05-consumers.md` owns it.
- Per-frame command buffer construction — `04-metal-pipeline.md` owns it.
- Watchdog callback bodies — `09-errors-and-recovery.md` owns it. Watchdog timestamp
  write-from-delivery / read-from-engine is the Inv 11 concern (see row above).
- UI scenePhase wiring — `08-ui.md` owns it; this file only specifies the engine-side
  sequence (Sequence A).
