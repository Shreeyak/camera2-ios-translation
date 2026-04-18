# 02 — Adversarial Red Team (Pass 2)

**Mental model:** This design will fail in production. What fails first? Attack every
assumption.

Merged from two independent Agent-4 runs (Sonnet + Opus). Each finding names the
failure mode, rates it, and routes the fix to `design/` (re-run Agent 3), never a
local patch.

---

## Category 1 — Race Conditions and Concurrency

### [Critical] FrameSet published on `deliveryQueue` before GPU completion — consumers read partially-written pixels
**Category:** 1
**Description:** `design/02` §2 delivery-queue sequence and §3 "Sendable Strategy" place FrameSet mailbox publication inline after `commit()` but before the GPU completion handler fires:
> "The mailbox swap and consumer publication happen inline on `deliveryQueue` before the completion handler's Task is scheduled."
This directly contradicts `design/01` §4 and `ios-platform-guide/01`, both of which specify publication inside `addCompletedHandler` once the GPU has actually written the IOSurfaces. An implementer following the hands-on pseudocode in `design/02` publishes `CVPixelBuffer` refs whose backing IOSurfaces the GPU has not yet drained — `commit()` schedules, it does not complete. `IOSurfaceLock` does **not** wait for GPU completion on iOS; the consumer reads uninitialized or N-1 pixel data. No assertion fires. Every consumer frame is silently corrupt. Canny edges appear black or delayed; tracker input is stale.
**Likelihood:** High (every frame)
**Impact:** Critical
**Design section to revise:** `design/02` §2 (delivery-queue sequence) and §3 (Sendable / frame-clock corollary).
**Routing:** `design/` — re-run Agent 3 to move the FrameSet construction + mailbox swap into the `addCompletedHandler` block. The `design/01` §4 command graph and the platform guide already show the correct sequencing.

### [High] Swift 6 strict-concurrency violation in the C-ABI write-complete callback — will not compile
**Category:** 1
**Description:** `design/04` §6 write-complete handler:
```swift
Task.detached {
    await engine.mipmapBlitQueue.submit {
        engine.metalEngine.generateMipmaps(for: engine.sharedCannyTexture)
        engine.cannyViewTrigger.requestRender(frameNumber: frameNumber)
    }
}
```
Under Swift 6 strict concurrency, `engine.mipmapBlitQueue`, `engine.metalEngine`, `engine.sharedCannyTexture`, and `engine.cannyViewTrigger` are actor-isolated on `CameraEngine`; accessing them inside `Task.detached { }` without `await engine.` hops is a data-race compile error. Additionally, `DispatchQueue.submit { }` is not a real API — the design conflates `DispatchQueue` with a custom actor. Phase 3 is the first phase introducing C++ consumers; if the callback doesn't compile, Phase 3 is blocked.
**Likelihood:** High (blocks build)
**Impact:** High
**Design section to revise:** `design/04` §6 write-complete callback; `design/01` §5 results-return path.
**Routing:** `design/` — re-run Agent 3 to rewrite the callback as a single actor hop (e.g. `Task { await engine.handleCannyComplete(frameNumber: frameNumber) }`) and move the Metal / MTKView trigger inside the actor method.

### [High] `Unmanaged<CameraEngine>` context box passed into the C++ consumer is never released
**Category:** 1
**Description:** `design/04` §6 sets the C-ABI callback with `Unmanaged.passRetained(self).toOpaque()` and recovers it on each call via `takeUnretainedValue()`. The retain is never balanced with a `release()` or `takeRetainedValue()`. Failure modes: (a) **leak** — every `open() → close() → open()` cycle under recovery creates a fresh `passRetained` without balancing the previous one, pinning old `CameraEngine` instances in memory; (b) **correctness-by-accident** — the only reason `takeUnretainedValue` doesn't use-after-free on late C++ callbacks is that the leak keeps the engine alive; any future teardown reorder that frees the C++ side first would expose a UAF. `ios-platform-guide/05` explicitly requires "balance `passRetained` with matching `release` or `takeRetainedValue` when C++ drops the callback."
**Likelihood:** Medium (manifests under repeated session cycles)
**Impact:** High (memory leak; latent UAF)
**Design section to revise:** `design/04` §6 teardown contract for the consumer; `design/05` Phase 3 acceptance.
**Routing:** `design/` — re-run Agent 3 to specify: `EdgeDetectionConsumer` teardown must `setResultCallback(nullptr, nullptr)`; Swift must `box.release()` at that point (or switch the recovery side to `takeRetainedValue()`).

### [Medium] `Task { @MainActor in viewModel.frameResult = … }` can pile up under main-thread contention
**Category:** 1
**Description:** `design/02` §2 schedules a `Task { @MainActor in viewModel.frameResult = … }` at 3 Hz from `deliveryQueue`. Unlike the four `AsyncStream.bufferingNewest(1)` paths in §7, direct-Task writes cannot drop. Under main-thread contention these Tasks queue unboundedly. The design has a contradictory intent: §7 lists `frameResultStream: AsyncStream<FrameResult>` with `bufferingNewest(1)` for the same cadence, but §2 shows the direct-Task shortcut.
**Likelihood:** Medium
**Impact:** Medium
**Design section to revise:** `design/02` §2 and §7.
**Routing:** `design/` — reconcile: keep the `AsyncStream<FrameResult>` path, drop the direct-Task shortcut.

### [Medium] `sessionQueue → deliveryQueue.sync { writeUniforms }` is a hidden blocker / deadlock risk
**Category:** 1
**Description:** `design/02` §6 row 6 states the uniform write path as "engine actor → `sessionQueue.async` → `deliveryQueue.sync { writeUniforms }`". `deliveryQueue.sync` blocks until the delivery queue is idle — and at 30 Hz the delivery queue is essentially never idle. Every slider update stalls `sessionQueue` for up to one frame. If any future code path calls `sessionQueue.sync` from `deliveryQueue` (for a device-state read), the two-way dependency deadlocks. A lock-free double-buffered MTLBuffer (ring of N+1 slots, single writer on `deliveryQueue`) or `setBytes` avoids both issues.
**Likelihood:** Medium
**Impact:** Medium
**Design section to revise:** `design/02` §6 row 6; `design/03` uniform-write plan.
**Routing:** `design/` — small edit.

### [Medium] MTLBuffer uniform writes may race GPU execution of the previous frame
**Category:** 1
**Description:** Metal reads MTLBuffer contents at GPU **execution** time, not at `commit()` time. If frame N's command buffer is still executing while frame N+1's `writeUniforms` lands on the same MTLBuffer, the shader reads a half-updated uniform block — producing a torn frame (half old brightness, half new). The design's "single writer on `deliveryQueue`" argument covers CPU serialization but not CPU-vs-GPU ordering. Mitigations the design lacks: ring of N+1 uniform slots, `setBytes` (encode-time copy), or a completion-handler wait before the next write.
**Likelihood:** Medium under sustained slider motion
**Impact:** Medium (visible tear in processed preview)
**Design section to revise:** `design/03` §4 / §5 (uniform buffer discipline).
**Routing:** `design/` — specify double-buffered uniforms or `setBytes`.

### [Low] Re-entrancy guard in `design/02` §3 shows state-only check, not the full `(state, token)` tuple
**Category:** 1
**Description:** `design/02` §8 (G-20) and `design/07` R-18 both describe capturing `sessionState` + `sessionToken` at commit and re-checking both in the completion handler. But the `design/02` §3 pseudocode shows only the state check. An implementer reading §3 alone could miss the token comparison. If an error path runs `close()` → `open()` fast, state returns to `.streaming` with a different session — the token is the only signal that distinguishes them.
**Likelihood:** Low
**Impact:** Medium (use-after-free on prior-session readback buffers)
**Design section to revise:** `design/02` §3 pseudocode — add the token check to match R-18.
**Routing:** `design/` — small edit.

### [Low] Invariant 4 (C++ pipeline pointer) mapped to ARC + actor serialization, not the mutex the domain prescribes
**Category:** 1
**Description:** `domain-revised/04` invariant 4 prescribes a specific mutex-guarded protocol; `design/02` §6 row 4 substitutes ARC + `Unmanaged` + C++ atomic flag. Valid as long as every access path goes through the actor, but `getNativePipelineHandle` in Phase 6 deliberately exposes the pointer to external C++ consumers — those callers are outside the actor's serialization and outside the C++ lock-order documentation.
**Likelihood:** Low (external-consumer path not exercised in phase 1)
**Impact:** Medium (if the external path is later used)
**Design section to revise:** `design/02` §6 row 4; Phase 6 `getNativePipelineHandle` semantics.
**Routing:** `design/` — either add an explicit `std::mutex` for the external-consumer path or document the lifetime window in which the handle is safe.

---

## Category 2 — Resource Exhaustion

### [Medium] Slow consumer IOSurface lock pins pool slots — drops become invisible to `overwriteCount_`
**Category:** 2
**Description:** ADR-19 specifies drop-on-busy 1-slot mailboxes. But a consumer that calls `IOSurfaceLock` and holds it during a long computation (Canny 50 ms under thermal) pins that IOSurface slot in the `CVPixelBufferPool`. If all `N+1` slots are pinned, `CVPixelBufferPoolCreatePixelBuffer` returns `kCVReturnWouldExceedAllocationThreshold` and the frame drops at the **pool** level before it reaches the mailbox — so `overwriteCount_` never increments. `R-21` monitors mailbox drops but this failure mode is silent to the debug overlay.
**Likelihood:** Medium under thermal
**Impact:** Medium (silent frame starvation; monitoring gives false-negative "healthy")
**Design section to revise:** `design/03` §5 (pool sizing + `pool_exhaustion` counter surfaced in `FrameDeliveryStats`).
**Routing:** `design/` — clarify that `pool_exhaustion` counts must be surfaced alongside `overwriteCount_` in the debug overlay, and that pool size must exceed `max_consumer_hold_time / frame_interval` per lane.

### [Medium] Buffer-pool growth unbounded under sustained consumer hold-over-budget
**Category:** 2
**Description:** `design/03` §5 sets pool cap `N + 1` with CF growth "on demand past the minimum" and no upper bound. A consumer holding a FrameSet longer than expected (hold_over_budget counter fires) forces CF to allocate new pool buffers every frame — at 30 fps × ~15 MB per FrameSet that is 450 MB/s of allocation churn until CF stabilizes. Under sustained thermal throttling this can grow pool memory to hundreds of MB before CF ages buffers out — triggering jetsam.
**Likelihood:** Medium under thermal stress
**Impact:** High (jetsam termination)
**Design section to revise:** `design/03` §5 + `design/07`.
**Routing:** `design/` — add an explicit per-pool allocation ceiling; exceeding it drops the frame, increments `pool_exhaustion`, and emits `FPS_DEGRADED`.

### [Medium] Memory pressure during active recording: no graceful degradation path for the encoder pool
**Category:** 2
**Description:** `design/07` R-10 covers memory pressure on the capture / Metal cache side (`CVMetalTextureCacheFlush`), but there is no analogous response for the encoder IOSurface pool. `CVPixelBufferPoolCreatePixelBuffer` for the encoder may return `kCVReturnWouldExceedAllocationThreshold` under pressure; the design increments `pool_exhaustion` and drops the frame, but does not specify whether the recording should stop cleanly (finalize) or continue producing a sparse file.
**Likelihood:** Medium
**Impact:** Medium (sparse / truncated MP4)
**Design section to revise:** `design/03` §5; `design/05` Phase 5; `design/07`.
**Routing:** `design/` — define the policy (recommend: after N consecutive encoder-pool exhaustions, stop recording via `RECORDING_TRUNCATED`).

### [Low] Shared canny texture (~20 MB at default crop) resident whether or not a Canny subscriber attaches
**Category:** 2
**Description:** `design/04` §6 allocates the shared canny texture "once at engine setup". At 1600×1200 RGBA16F with full mip chain, resident ≈ 20 MB; at 4160×3120 ≈ 130 MB. If the Canny POC is toggled off in a product iteration, the allocation remains dead weight. Should be lazy on first `.tracker` subscriber attach (mirroring ADR-20's flip discipline) and released on last detach.
**Likelihood:** Low
**Impact:** Low
**Design section to revise:** `design/04` §6.
**Routing:** `design/` — small edit.

### [Low] GPU command-queue depth not explicitly bounded
**Category:** 2
**Description:** Default Metal queue depth is ~64. Under GPU stall (thermal), the capture delegate continues submitting and the queue backs up; `commit()` eventually blocks `deliveryQueue`. Watchdogs fire but in the interim the queue accumulates significant in-flight work.
**Likelihood:** Low
**Impact:** Medium (frame pacing jitter)
**Design section to revise:** `design/03` §8.
**Routing:** `design/` — add a "commits-outstanding" gate.

---

## Category 3 — Timing Assumptions

### [High] `AVCaptureSession.startRunning()` has no timeout — session hangs on hardware fault
**Category:** 3
**Description:** `startRunning` is synchronous on `sessionQueue` with no documented timeout. `design/02` §5 transitions `OPENING → STREAMING` contingent on first sample buffer; no timer bounds the duration of `OPENING`. On hardware fault (flaky camera sensor, driver hang, cold-start contention), the call blocks indefinitely. The 5 s capture-result stall watchdog only arms **after** the first sample buffer, which never arrives. User sees a blank preview; only force-quit recovers.
**Likelihood:** Medium
**Impact:** High
**Design section to revise:** `design/02` §5 state machine; `design/05` Phase 1a acceptance; `design/07` risk table.
**Routing:** `design/` — add a 5 s `DispatchSourceTimer` armed at `OPENING` entry; fires → non-fatal `CONFIGURATION_FAILED` + recovery transition.

### [Medium] 3 s / 5 s watchdog distinction collapses if `lastFrameTimestampNs` is written post-commit
**Category:** 3
**Description:** `domain-revised/06` distinguishes GPU-level stall (3 s, informational) from capture-result-level stall (5 s, recovery). `design/02` §6 row 11 and `design/03` §8 do not specify **when** `lastFrameTimestampNs` is written. If written at `captureOutput` delegate entry (before Metal work), it's a capture-result marker; if written at `addCompletedHandler` fire, it's a GPU-completion marker. Both watchdogs read the same atomic, so their semantics collapse into one signal unless two distinct timestamps are written.
**Likelihood:** Medium
**Impact:** Medium (watchdog misfire → unnecessary recovery)
**Design section to revise:** `design/03` §8; `design/02` §6 row 11.
**Routing:** `design/` — specify two distinct atomics: capture-side stamped at delegate entry, GPU-side stamped in `addCompletedHandler`.

### [Medium] C++ consumer holding a FrameSet longer than pool depth can stall the encoder lane
**Category:** 3
**Description:** Under thermal, edge-detection may take ~100 ms per frame (3 frame intervals). With `N = 1` active consumer lane, pool cap = 2 — if the consumer hold exceeds that, frame 3 can find both slots held and the GPU write blocks or drops. Design has `hold_over_budget` counter but no proactive action. The encoder pool is separate per `design/03` §5 (good) — verify that a consumer-held processed pool ref doesn't indirectly block encoder input.
**Likelihood:** Medium under thermal
**Impact:** Medium
**Design section to revise:** `design/03` §5; `design/04` §8.
**Routing:** `design/` — confirm pool separation and document how the consumer-held FrameSet interacts with encoder dequeue.

### [Low] `waitUntilScheduled()` on `scenePhase → .inactive` blocks the main thread
**Category:** 3
**Description:** ADR-09 specifies `lastCommittedCommandBuffer?.waitUntilScheduled()` in the backgrounding handler. `scenePhase` callbacks fire on `@MainActor`. If the last command buffer has queued GPU work (large still readback), `waitUntilScheduled` can block 20–50 ms — visible UI hitch at app-switch.
**Likelihood:** Low
**Impact:** Low
**Design section to revise:** `design/02` §8.
**Routing:** `design/` — small edit to move the wait to `sessionQueue`.

---

## Category 4 — iOS-Specific Edge Cases

### [High] Camera interruption while recording: `AVAssetWriter` not finalized → corrupt MP4
**Category:** 4
**Description:** `AVCaptureSessionWasInterrupted` with `videoDeviceInUseByAnotherClient` (FaceTime, another camera app) or `audioDeviceInUseByAnotherClient` (phone call) arrives while `AVAssetWriter` is actively writing. The design's edge-case mapping routes this to fatal `ERROR` → self-heal on `InterruptionEnded`, with no entry for stopping the writer first. The file is left open with no `moov` atom — exactly the corruption `design/07` R-06 exists to prevent, but R-06 only covers backgrounding, not mid-session interruption. `domain-revised/08` requires `RECORDING_TRUNCATED` in this case, not silence.
**Likelihood:** Medium (phone call during recording is a common flow)
**Impact:** High (recording lost / corrupt)
**Design section to revise:** `design/07` (add interruption-during-recording row to edge-case table); `design/02` §5 (`ACTIVE → SUSPENDED` transition checks `isRecording`, drains writer first).
**Routing:** `design/` — re-run Agent 3 to specify: on any video interruption during active recording, run `stopRecording` (ADR-16 5 s deadline), emit `onRecordingStateChanged("idle")` + `RECORDING_TRUNCATED`, then transition.

### [High] Low Power Mode has no design response
**Category:** 4
**Description:** `ProcessInfo.isLowPowerModeEnabled` / `.NSProcessInfoPowerStateDidChange` are not observed anywhere in `design/`. Low Power Mode halves CPU/GPU ceilings without triggering any thermal state change — `design/07` R-01 / R-02 do not fire. iOS auto-suggests Low Power Mode at 20 % battery, so this is a common user flow; the pipeline silently degrades to degraded-or-failing latency band with no banner.
**Likelihood:** High
**Impact:** Medium
**Design section to revise:** `design/07` (new R-##); `design/02` §5 (optional `LOW_POWER` state wrapper); `design/05` Phase 4 acceptance.
**Routing:** `design/` — re-run Agent 3 to add observation + degradation policy.

### [Medium] `sessionQueue.sync { session.stopRunning() }` from `@MainActor` on backgrounding — deadlock risk
**Category:** 4
**Description:** `design/07` R-16 states: "the `scenePhase → .background` handler blocks on `sessionQueue.sync { session.stopRunning() }`." `.sync` called from `@MainActor` deadlocks if `sessionQueue` currently has a block waiting for the main queue. The per-frame path runs on `deliveryQueue` rather than `sessionQueue`, but any Metal completion handler or KVO callback that hops to main from `sessionQueue` closes the cycle. Swift 6 cooperative thread pool + actor priority inversion extends the risk.
**Likelihood:** Low–Medium
**Impact:** High if hit (main-thread deadlock → watchdog-terminated app)
**Design section to revise:** `design/07` R-16.
**Routing:** `design/` — change `.sync` to `.async` with `beginBackgroundTask` bounding the wait, or use `await engine.stopSession()` inside the scenePhase handler.

### [Medium] Permission revocation mid-session only observed on `scenePhase → .active`
**Category:** 4
**Description:** `design/07` R-04 checks authorization only on `scenePhase → .active`. On iOS the user can revoke permission without fully backgrounding the app (Settings deep link, Control Center widget paths). The session then starts emitting runtime errors that map to `CAMERA_ACCESS_ERROR` / recovery — correct behavior technically, but the UI shows "recovering" rather than "permission revoked".
**Likelihood:** Low
**Impact:** Medium (UX confusion)
**Design section to revise:** `design/07` R-04.
**Routing:** `design/` — small edit to add periodic authorization check on each `FrameResult` cadence, transitioning to fatal `PERMISSION_DENIED` on revocation.

### [Low] iPad Split View / Slide Over interruption — no distinct UI policy
**Category:** 4
**Description:** `videoDeviceNotAvailableWithMultipleForegroundApps` cannot be resolved programmatically; a Resume button does nothing. `design/07` R-05 groups it with other interruptions that do show Resume. Product is iPhone-first per domain §09 landscape-right lock, so low likelihood, but the group is ambiguous.
**Likelihood:** Low
**Impact:** Low
**Design section to revise:** `design/07` R-05.
**Routing:** `design/` — small edit.

### [Low] Photo-library denial fallback to Documents: `captureImage(outputPath:)` return path diverges silently
**Category:** 4
**Description:** `design/07` R-15 specifies fallback to Documents folder on PHPhotoLibrary denial. Domain §captureImage permits both locations, but the caller using the returned path to load thumbnails will fail silently if it assumed a Photos asset URL.
**Likelihood:** Low
**Impact:** Low
**Design section to revise:** `design/07` R-15; `design/05` Phase 5 acceptance.
**Routing:** `design/` — small edit.

---

## Category 5 — Escape Hatch Abuse

**No issues found.** `design/08-audit-lookups.md` has **0 entries**. The design explicitly records that `domain-revised/` + `ios-platform-guide/` were sufficient for every decision; numeric thresholds (3 s / 5 s stall, 500–8000 ms backoff, 5-retry cap, 5 s drain, 3-failure surface rebind, 96×96 center patch, 480 px tracker, 1600×1200 default crop, `TARGET_BITRATE_MBPS` as domain parameter) all come inline from `domain-revised/`. No excessive lookups, no topical cluster, no lookup that changed a decision. Cleanest possible signal on this axis — the design is genuinely iOS-shaped.

---

## Category 6 — Correctness of the OpenCV Edge Detection Consumer

### [Critical] IOSurface permanently locked after any OpenCV exception in `processFrame`
**Category:** 6
**Description:** `design/04` §5:
```cpp
IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
// ... cv::cvtColor, cv::Canny ...   (can throw cv::Exception)
IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
```
The unlock is positioned mid-body, not in a RAII destructor. The three `catch` branches each `return ErrorCode::...` without calling `IOSurfaceUnlock`. `processFrame` is `noexcept` so the process does not crash — the surface simply stays pinned forever. The GPU cannot subsequently write to `trackerTex` for this slot; all following frames on that lane silently produce stale / wrong pixels with no error path. `ios-platform-guide/05` ADR-12 mandates exception discipline at the C++ facade; §5 here omits the RAII guard required to honor it.
**Likelihood:** Medium (any `cv::Exception` — bad pixel layout, allocation under pressure, threshold edge case)
**Impact:** Critical
**Design section to revise:** `design/04` §5 — introduce a `IOSurfaceLockGuard` RAII struct (or use `std::unique_ptr` with a custom deleter), lock with it, remove the manual unlock.
**Routing:** `design/` — re-run Agent 3 to add the guard pattern to `Cpp/EdgeDetectionConsumer.cpp` with a one-line explanation in §5.

### [High] `processFrame(StreamId, FrameRef&)` fragments the FrameSet — contradicts ADR-18 atomicity
**Category:** 6
**Description:** `design/04` §1 declares `processFrame(StreamId sid, const FrameRef& frame) noexcept` — one stream, one buffer per call. But §6 composites the Canny mask onto `FrameSet.processed` full-res while using `FrameSet.tracker` for input; the code reads `processedBase, processedStride` with a comment "here we assume the consumer subscribes to both." Two separate `processFrame` calls per frame means the consumer must correlate them manually by `frameNumber` — and do something when one arrives via drop-on-busy while the other does not. ADR-18 is explicit that the set is atomic exactly to avoid this miswiring; fragmenting it at the facade loses the guarantee.
**Likelihood:** High (every run exercises this path)
**Impact:** High (Canny edges visibly misaligned vs processed pixels)
**Design section to revise:** `design/04` §1 interface; §2 registration; §6 composite.
**Routing:** `design/` — change interface to `processFrame(const FrameSet& set) noexcept`; consumer indexes the streams it needs; per-stream subscription becomes metadata only.

### [Medium] Composite step is not zero-copy — `cv::resize` + full-res memcpy every frame
**Category:** 6
**Description:** §5 header promises zero-copy. §6 body: `cv::resize(edges, edgesFull, cv::Size(fullW, fullH), 0, 0, cv::INTER_NEAREST)` allocates `edgesFull`; `compositeHalfFloat(processedBase, processedStride, edgesFull, dst, dstStride, fullW, fullH)` copies every RGBA16F pixel. At 1600×1200 × 8 bpp = 15 MB/frame; at 30 Hz = 450 MB/s of memcpy on top of Canny itself. Thermal and power cost material.
**Likelihood:** High (every Canny frame)
**Impact:** Medium
**Design section to revise:** `design/04` §5 vs §6 narrative; optionally move the composite to a Metal pass that samples `processedTex` + an edge-mask texture.
**Routing:** `design/` — either correct the zero-copy claim or restructure the composite as GPU work.

### [Medium] `cv::cvtColor(CV_16FC4, COLOR_RGBA2GRAY) + .convertTo(CV_8U, 255.0)` assumes input in [0, 1]
**Category:** 6
**Description:** The color pipeline (`design/03` §6, `domain/03` order) applies black-balance / brightness / contrast / gamma before tracker downsample; intermediates can exceed 1.0 before gamma clamps. If the tracker output is not clamped, `convertTo(CV_8U, 255.0)` saturates in highlights and Canny edges behave inconsistently.
**Likelihood:** Medium in bright / high-contrast scenes
**Impact:** Medium (Canny misses edges or fires on quantization noise)
**Design section to revise:** `design/03` §6 + `design/04` §5.
**Routing:** `design/` — clarify output range or add a clamp.

### [Low] Per-frame heap allocations in OpenCV path (`cv::Mat gray`, `cv::Mat edges`)
**Category:** 6
**Description:** `design/04` §5 allocates fresh `cv::Mat` objects each frame. At 480 p × 30 Hz that is ~336 KB of intermediate allocation/free per second plus Canny scratch. Under thermal allocator-lock contention adds 0.5–2 ms per frame. Not fatal; visible as gradual `overwriteCount_` creep.
**Likelihood:** Medium under thermal
**Impact:** Low
**Design section to revise:** `design/04` §5 — pre-allocate as class members, resize only when dimensions change.
**Routing:** `design/` — small edit.

### [Low] OpenCV framework link-failure: architectural fix exists, smoke-test missing
**Category:** 6
**Description:** `design/07` R-08 provides the architectural fix (OpenCV headers private to `.cpp`, module-map exclusion). But no Phase 3 acceptance bullet verifies the `opencv2.xcframework` actually links at runtime — a broken SPM checksum would crash at first `cv::Canny` call with `dyld` error.
**Likelihood:** Low
**Impact:** Medium (launch-time crash)
**Design section to revise:** `design/05` Phase 3 acceptance.
**Routing:** `design/` — add a link-check bullet.

### [Low] Canny MTKView smoothness decoupled from gesture rate at low Canny throughput
**Category:** 6
**Description:** `design/04` §7 uses `isPaused = true` + `setNeedsDisplay()` on write-complete. Under slow Canny (5 Hz under thermal), gestures run at 60 Hz but render refreshes at 5 Hz — pan/zoom feels laggy because uniforms don't get picked up until the next C++ completion. The design does not separate "render on new Canny" from "render on gesture change".
**Likelihood:** Medium under thermal
**Impact:** Low (UX smoothness)
**Design section to revise:** `design/04` §7.
**Routing:** `design/` — add gesture-driven `setNeedsDisplay` independent of Canny rate.

---

## Summary Table

| Severity | Count |
|---|---|
| Critical | 2 |
| High | 6 |
| Medium | 13 |
| Low | 10 |

---

## Adversarial Pass Verdict: **Yellow**

Reasoning per the review rubric:

- **Not Red:** no finding invalidates a core architectural decision (the `actor` + `deliveryQueue` + FrameSet + ADR-20 storage-mode flip + dual-isolation-domain model all stand). The two Criticals are pseudocode-level errors (publication ordering; missing RAII guard) — both fixable with surgical edits to `design/02` §2/§3 and `design/04` §5. The threshold for Red is "3 or more Critical findings, OR a fundamental design flaw"; neither is met.
- **Matches Yellow:** 2 Critical is within the "1–2 Critical findings" Yellow band, and 6 Highs is well past the "3 or more High findings" Yellow trigger. Both criteria independently place this pass at Yellow.
- **Top priorities before any implementation starts:** AT-01 and AT-02 (Criticals) produce silent data corruption with no diagnostic signal — they must be fixed in `design/02` and `design/04` before Phase 2/Phase 3 can begin. The Highs (Unmanaged leak, Swift-6 callback, `processFrame` atomicity, interruption-during-recording, `startRunning` timeout, Low Power Mode) each block a concrete phase milestone; they must be fixed before Phase 3 completes.

**Overall verdict signal: Yellow — re-run Agent 3 with the two Criticals + six Highs
as explicit context before implementation begins.**
