# 05 — Consumers

Primary-owner file for **how external code receives frames**: `PixelSink` registry, C++
interop, pool handoff, mailbox semantics, observability. Pool sizing + texture allocation
are in `04-metal-pipeline.md`; the publication unit shape is `FrameSet` per ADR-18.

---

## D-01 — Consumer fan-out uses Mechanism A (C++ PixelSink pool)

Consequential. Crosses `01-system-shape.md`, `04-metal-pipeline.md`, `05-consumers.md`
(this file), and `07-settings.md` (via `getNativePipelineHandle()`).

### Context

ADR-13 documents two mechanisms for async consumer dispatch:

- **Mechanism A**: C++ thread pool inside the imaging core; per-consumer 1-slot mailbox;
  consumers subscribe to a C++ `PixelSink` and run on pool threads. Best for multi-consumer
  products with a C++ analysis core.
- **Mechanism B**: Swift-side `AsyncStream.bufferingNewest(1)` per consumer; consumer
  `for await`s in a `Task`. Best for single-Swift-side consumer.

The domain requires:
- A C++ consumer API (`getNativePipelineHandle()` exposes the native pointer so external C++
  tracker code can register directly — `domain-revised/10-api-contract.md` §Host Methods).
- Three subscribable streams (`natural`, `processed`, `tracker`) with latest-only delivery,
  drop-on-busy semantics, per-consumer mailbox (Invariants 8, 10).
- OpenCV consumer is the chosen CV framework (ADR-29).

That combination lands on Mechanism A. A Swift-only Mechanism B would require a separate
C-ABI shim for external C++ consumers and duplicate mailbox discipline across two isolation
domains.

### Options

1. **Pure Mechanism A** (C++ pool for all consumers; Swift-side callers get an `AsyncStream`
   bridge that pulls from the same pool).
2. **Pure Mechanism B** (Swift-side `AsyncStream` per consumer; C++ integration via a
   C-ABI shim that Swift forwards to).
3. **Hybrid** (both; callers pick per-registration).

### Decision

Option 1. The C++ imaging core owns all consumer dispatch. Swift-side callers use
`ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>` (`api-surface.md`); the
registry actor forwards each stream yield into the underlying C++ `PixelSink`'s Swift lane
via a C-ABI callback (D-03). External C++ callers use `ConsumerRegistry.registerCallback(…)`
directly. Both lanes share the same pool threads, mailbox discipline, and overwrite counters.

### Consequences

- Drop counters are published from the C++ pool per ADR-19 §Observability; Swift side
  aggregates into `FrameDeliveryStats` (D-11).
- Lock ordering (Invariant 5: `pipeline > stage > consumer`) lives entirely inside the C++
  imaging core. No Swift-side mirror lock.
- `getNativePipelineHandle()` exposes the raw C++ pointer for callers that want to integrate
  at the `PixelSink*` level rather than through the Swift facade.
- The facade's C++ target depends on `.cxxLanguageStandard = .cxx20` and keeps OpenCV
  strictly out of public headers per ADR-11 §Module map. The Swift-visible interop module
  (`CameraKitInterop`) is thin.
- Testing: pure-logic mailbox tests live in a host-build of the C++ imaging core with
  GTest, independent of Apple frameworks; integration tests exercise the Swift bridge
  under XCTest per ADR-33.

### Reversibility

High initial cost but scoped. Moving to Mechanism B would mean replacing the C++ pool with
Swift-side `AsyncStream`s and rewriting the external C++ integration as a C-ABI shim. Not
reversible without a dedicated MIGRATION stage spanning 05-consumers + 01-system-shape.

---

## D-03 — C-ABI callback struct as the default integration shape

Consequential. Primary-owner file for the integration-shape decision.

### Context

ADR-31 warns that Swift-subclassing a C++ abstract class (e.g. `PixelSink` with
`virtual = 0` methods) is unproven across covariant returns, ABI alignment, and override
boundaries. A throwaway spike is recommended before design-depends-on-it.

### Decision

C++ integration uses the C-ABI `PixelSinkCallbacks` struct (POD with `@convention(c)`
function pointers + opaque `context`) per ADR-31 §C-ABI fallback shape as the **permanent**
shape. Register via `ConsumerRegistry.registerCallback(stream:callbacks:)`. No public
surface depends on Swift subclassing a C++ abstract class; no Swift-subclass spike is
scheduled (see `open-questions.md` §OQ-02 for the full rationale).

Why: the two actual consumer shapes are (a) external C++ CV pipelines — which cannot
subclass from Swift regardless — and (b) Swift-side subscribers using the
`ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>` facade from D-01, which
insulates callers from the C-ABI plumbing entirely. The ergonomic payoff of
Swift-subclassing is confined to a hypothetical Swift-native direct subclass — not a
first-class use case here — and does not justify the ABI-stability risks ADR-31 names.

### Consequences

- `Unmanaged.passRetained(self)` + `Unmanaged.fromOpaque(...)` is the retain dance on the
  Swift side per ADR-13 §C-ABI callback pattern.
- Releases are explicit: the registry balances `passRetained` with `release` on
  `unregister(token:)`.
- The buffer pointer in the `onFrame` callback is valid only for the duration of the call;
  consumers must copy before returning, consistent with ADR-13 §What never crosses the
  consumer boundary.

### Reversibility

Low-cost to revisit. If a future product requirement introduces a Swift-native CV consumer
that must inherit from `PixelSink` directly (bypassing the Swift facade), OQ-02 can be
reopened and a spike added. External C++ callers continue on the C-ABI struct regardless.
Removing the C-ABI struct is not planned.

---

## D-11 — FrameDeliveryStats aggregates Swift + C++ counters via a single stream

Minor. `ConsumerRegistry.deliveryStats() -> AsyncStream<FrameDeliveryStats>` publishes at
1 Hz (UI-tier cadence). The struct (`api-skeletons/Sources/CameraKit/FrameSet.swift`)
fields:

- `producedByLane`, `deliveredByLane`, `droppedByLane`, `holdOverBudgetByLane` — per
  `StreamId`, for Swift-side lanes.
- `cppOverwriteByLane` — per `StreamId`, from the C++ pool's per-consumer
  `mailbox_overwrite_count` atomics via a C-ABI metrics callback at the same cadence.
- `poolExhaustion` — global counter from the Metal pipeline (ADR-19).

The aggregation rule: per lane, the "authoritative" overwrite counter is the C++ side when a
C-ABI consumer is registered; the Swift side when only a Swift `AsyncStream` subscriber is
registered. Both are published — UI debug surfaces can show either; integration tests verify
both agree when the Swift facade is the only consumer.

G-26's absence-of-counter failure mode is prevented by making per-lane C++ counters a
**quality gate** — the `PixelSink` registration path rejects a registration that does not
provide an overwrite-counter callback (`EngineError.interop(.pixelSinkRegistrationRejected)`).

---

## D-12 — Natural stream is subscribable

Minor. Per `domain-revised/02-frame-delivery.md` §Parallel Stream Outputs (reverses U-13),
all three streams (`natural`, `processed`, `tracker`) are subscribable via the same
`ConsumerRegistry.subscribe(stream:)` / `.registerCallback(stream:callbacks:)` API. There is
no separate registration path for any stream; the `StreamId` enum discriminates.

Implementation consequence: the C++ `PixelSink` pool carries three lane ids; the Swift
facade's `StreamId` enum maps 1:1. Lanes with no subscribers do not publish (ADR-13 §Active-
stream rules); the GPU still writes the corresponding texture (because `natural` and
`processed` are always-on in the Metal graph), but the completion handler skips the mailbox
publish for lanes with lane count 0.

---

## D-15 — Native pipeline pointer guard

Minor. Primary-owner file for the pipeline-pointer use-after-free prevention (domain
Invariant 4). The guard has two halves:

- **Engine-actor boundary on the Swift side**: `getNativePipelineHandle()` returns the
  current pointer only while inside the engine actor, where teardown cannot race (the
  actor serializes state mutations). Callers that retain the returned `UInt64` and use it
  later must accept the use-after-free risk — the engine cannot provide lifetime guarantees
  past the actor hop.
- **C++ `std::mutex` on the native side**: the `PixelSink` pool's teardown acquires the
  mutex, reads + zeroes the native pointer, releases, then destructs outside the mutex.
  Capture paths acquire the mutex, read the pointer, release; if null, return immediately.

The canonical mutex-ordered teardown from `domain-revised/04-concurrency-invariants.md`
§Invariant 4 is implemented verbatim in C++. No Swift-side mirror lock — the engine actor
boundary is the Swift-side guarantee.

---

## Publication unit: `FrameSet`

Per ADR-18, each consumer mailbox carries one `FrameSet` (Sendable / `@unchecked Sendable`
for the `CVPixelBuffer` fields per G-13). The three IOSurface-backed `CVPixelBuffer`s plus
capture + processing metadata plus tracker signals are a single atomic unit; cross-sink
correlation is impossible to miswire.

`FrameSet` is constructed in the Metal completion handler per `04-metal-pipeline.md`
§Command graph; published into each subscribed lane's mailbox via an atomic swap. The swap
releases the prior set, which in turn releases the underlying `CVPixelBuffer`s when the
consumer no longer holds them. CF reclaims pool buffers whose refcount drops to 1.

`frameNumber` is monotonic from 0 at `open()`; `captureTime` is the `CMSampleBuffer`
presentation timestamp. Consumers correlate frames to external streams (IMU, sensor
metadata) without depending on clock alignment.

---

## Mailbox semantics

Per ADR-19, each lane has a 1-slot atomic mailbox. The pool trio (`natural`, `processed`,
`tracker`) supplies the buffer refs via `constants.md#POOL_CAP_RULE`. On publish, the prior
set (if any) is released; if it was never pulled, `dropped_mailbox_overwrite` increments
for that lane (D-11 surface).

Consumer's `for await` iteration retains the `FrameSet`; all three `CVPixelBuffer` refs
become consumer-held for the iteration, then release on end-of-iteration. Consumers that
hold a ref past the iteration body must copy the data (ADR-13).

**All-frames-bounded is not supported.** Every lane is latest-wins. A future requirement for
all-frames semantics (an IMU-correlated stitcher that cannot skip) would trigger a re-
architecture rather than be layered on.

---

## Consumer lifecycles

### Swift-side subscribe

```
let stream = await consumers.subscribe(stream: .processed)
for await frameSet in stream {
    try Task.checkCancellation()   // ADR-23
    process(frameSet)               // release at end of iteration
}
```

Per ADR-22 the stream is `.bufferingNewest(1)`. Termination (normal return from the `Task`,
cancellation) unsubscribes; the registry drops the lane; CF ages out the unused pool slot
after `constants.md#POOL_MAX_BUFFER_AGE_SECONDS`.

### C-ABI register

```swift
let token = try await consumers.registerCallback(
    stream: .tracker,
    callbacks: PixelSinkCallbacks(onFrame: ..., onOverwrite: ..., onError: ..., context: ...)
)
// Later:
await consumers.unregister(token: token)
```

The `onFrame` callback runs on the C++ pool thread, not on any Swift actor. The pointer it
receives is an `IOSurface` reference valid for the duration of the call; the C++ consumer
typically `IOSurfaceLock`s, constructs a zero-copy `cv::Mat` view with stride from
`IOSurfaceGetBytesPerRow(surface)` per G-34, processes, `IOSurfaceUnlock`s, returns.

### Unsubscribe semantics

- Swift lane: `Task` cancellation / stream termination; registry drops lane synchronously.
- C-ABI lane: `unregister(token:)` signals the pool to drop the consumer at the next
  mailbox publish; the `passRetained` context is released; the pool waits for the consumer
  thread to exit its current callback before tearing down per-consumer state.

---

## Thread pool sizing

C++ pool thread count: `constants.md#CPP_POOL_THREAD_COUNT` (`min(4, hardware_concurrency)`).
Per ADR-13 §Two viable mechanisms. The pool services multiple consumers in parallel but
within a lane, mailbox semantics serialize the consumer thread so frames cannot be reordered.

---

## Observability

Per D-11, surfaced counters:

- `mailbox_overwrite_count` per consumer per lane — `std::atomic<uint64_t>` in C++
  `PixelSink`.
- `frames_produced`, `frames_delivered`, `dropped_mailbox_overwrite`, `hold_over_budget`
  per lane — published on the Swift-side registry.
- `pool_exhaustion`, `pool_current_size[pool]` — global, from `04-metal-pipeline.md`
  §Pool configuration.

Consumed by `08-ui.md` §Debug surface for development builds; invisible to production UI
except as the "non-fatal notification" channel for `FPS_DEGRADED` etc.

---

## Quality gate (G-26 avoidance)

Every `PixelSink` registration must supply an `onOverwrite` callback (the second function
pointer in `PixelSinkCallbacks`). The registry rejects registrations lacking it with
`EngineError.interop(.pixelSinkRegistrationRejected)`. This prevents a consumer from
silently degrading under thermal load (G-26) because absence-of-counter is visible at
registration time, not at runtime.

---

## Teardown

Engine full teardown triggers `ConsumerRegistry.release()`:

1. Cancel every Swift-side lane `Task`; each `for await` loop exits cleanly per ADR-23.
2. For C-ABI consumers: call each registered `onError(code: shutdown)` to notify; release
   the `Unmanaged<...>` retain for each context.
3. Tell the C++ `PixelSink` pool to drain its thread queues and shut down; pool threads
   join.
4. Release the native pipeline pointer per `05-consumers.md#d-15`.

Steps 1–4 run on the engine actor inside the full teardown sequence (`03-camera-session.md`
§Full teardown). Step 3 may block briefly while pool threads finish; the architecture
accepts this because full teardown is already an off-hot-path operation (close / fatal /
recovery retry).
