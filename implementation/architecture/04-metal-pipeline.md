# 04 — Metal Pipeline

Primary-owner file for **per-frame GPU work**: texture cache, command buffer construction,
pool management, shader order, downsample, preview blit, readback. Cross-subsystem sequencing
(scenePhase, consumer registration) lives in `02-concurrency.md`.

---

## Command graph

One `MTLCommandBuffer` per camera frame, labelled per G-33 (`commandBuffer.label =
"frame.\(frameNumber).pass\(passId)"`). Encoders use `pushDebugGroup()` /
`popDebugGroup()` for navigable GPU captures. The graph is gated per pass — if the feature
driving a pass is off (no recording, no tracker consumer, no still requested), that pass is
skipped via conditional append, never stub shaders.

Authoritative per-frame graph is `ios-platform-guide/01-architecture.md §Per-frame command
graph`. This file states the product-specific choices layered onto that graph, not the shape.

### Passes (product instantiation)

1. **Capture wrap**: `CVMetalTextureCache → yTex (r8Unorm), cbcrTex (rg8Unorm)` for the
   biplanar YUV capture buffer. Zero-copy via ADR-04.
2. **Dequeue pool buffers**: before encoding, three `CVPixelBuffer`s are dequeued from their
   respective pools (`naturalPool`, `processedPool`, `trackerPool`) per ADR-19; tracker is
   gated on `hasSubscriber(.tracker)`. Pool cap `N_active_lanes + 1`
   (`constants.md#POOL_CAP_RULE`).
3. **Pass 1** (compute): crop + YUV→RGB → `naturalTex` (IOSurface-backed,
   `constants.md#WORKING_PIXEL_FORMAT`) and mirror-write into `naturalPoolBuf`. Crop uniforms
   from the engine's current `cropRegion`. BT.709 coefficients (full-range matching capture
   format).
4. **Pass 2** (compute): color transforms → `processedTex` (also mirrored to
   `processedPoolBuf`). Shader order per `07-settings.md` §Processing order:
   black balance → brightness → contrast → saturation → gamma.
5. **Pass 3** (blit): `naturalTex → naturalMTKView.currentDrawable`. Single
   `MTLBlitCommandEncoder` because formats match (G-32 satisfied — no format change).
6. **Pass 4** (compute, gated on tracker subscribers): downsample `processedTex` →
   `trackerTex` at `constants.md#TRACKER_HEIGHT_PX` with aspect-preserving width
   (even-pixel-rounded). Mirror to `trackerPoolBuf`.
7. **Pass 5** (compute, gated on `isRecording`): RGBA16F → NV12 into the encoder pool
   buffer (`06-capture-and-recording.md` §Encoder path, ADR-06).
8. **Pass 6** (blit, gated on `stillRequested`): `processedTex → still readback CVPixelBuffer`
   for `06-capture-and-recording.md` §Still capture. Requires same-format same-precision
   blit; the readback buffer is allocated as RGBA16F for exact equality, then encoded to
   TIFF on the CPU side.

**processed preview is delivered via async consumer** — see ADR-01 §Direct GPU outputs vs
async consumers. The processed MTKView (if present) is driven by the `.processed` async
consumer lane writing into a shared IOSurface, exactly as the canny-preview example in
ADR-01. There is no Pass-3-analog direct blit for processed.

Completion handler: `addCompletedHandler` checks `cb.status == .error` per G-02 / ADR-15;
on `.error` classifies as a Metal failure via `EngineError.metal(.commandBufferFailed(...))`.
On success, constructs `FrameSet` per ADR-18 and publishes into subscribed lane mailboxes
(`05-consumers.md`).

Applies the **completion-handler re-entrancy guard** — see `02-concurrency.md#d-10` for the
authoritative statement. This guard is non-negotiable on every completion handler in this
subsystem.

---

## Working texture format

Every intermediate texture consumer-visible is `constants.md#WORKING_PIXEL_FORMAT`
(RGBA16F) per ADR-05. Channel order is **R, G, B, A** (G-18); BGRA never appears in any
stream a consumer touches. If any consumer applies luma weights, they must use
`constants.md#COLOR_LUMA_WEIGHT_R / _G / _B` in that order — BGRA coefficients applied to
RGBA buffers are silently wrong per G-18.

`processedTex`, `naturalTex`, `trackerTex` all share the working format. The encoder pool
(Pass 5) uses `constants.md#ENCODER_PIXEL_FORMAT` (NV12); the still-capture readback buffer
is RGBA16F for same-format blit; the TIFF encoder converts on the CPU side.

---

## Texture cache

Per ADR-04, one `CVMetalTextureCache` created at `open()` inside `TexturePoolManager`. Flushed
(not recreated) on `UIApplication.didReceiveMemoryWarningNotification` per G-15 via
`CVMetalTextureCacheFlush(cache, 0)`. Per-frame wraps release the `CVMetalTexture` object
by going out of scope at the end of each pass — explicit per G-15.

`CVMetalTextureGetTexture()` is nil-checked per ADR-15 and G-01; nil return increments a
`metalWrapFailureCount` and drops the frame (no pass append, no commit, no pool consumption).

---

## D-02 — Texture storage mode: `.shared` start-simple

Consequential. Crosses `04-metal-pipeline.md` (this file) and `05-consumers.md`.

### Context

ADR-20 documents two equally valid shapes:
- **Start-simple**: allocate all IOSurface-eligible textures as `.shared` from the start.
  Negligible bandwidth cost on unified memory; easiest invariant.
- **Dynamic rotation**: default `.private`, flip to `.shared` on consumer attach, rotate back
  on all-unsubscribe. Saves DRAM bandwidth under multi-texture high-frame-rate load.

The domain requires consumer fan-out for all three streams (natural, processed, tracker) —
D-12 makes natural subscribable too, so at least the tracker is always attached and likely
one of natural/processed is attached in the edge-visualizer case. The "no consumer attached"
window is small enough that dynamic rotation provides limited benefit.

### Options

1. Dynamic rotation from Stage 01. Most conservative on bandwidth; highest complexity; G-25
   failure mode (`.private` → nil `.iosurface` → silent frame drop) requires discipline.
2. Start-simple `.shared` default; graduate only on Instruments evidence. Matches ADR-20
   §Start-simple default.
3. Hybrid: `.private` for streams with no historical subscriber; `.shared` for streams where
   one is always present. Fragile — adds branching without clear benefit.

### Decision

Option 2. All three IOSurface-eligible working textures (`naturalTex`, `processedTex`,
`trackerTex`) allocate as `.shared` from Stage 01. `TexturePoolManager` does not track
subscriber counts for storage-mode purposes. Pool cap is still `N_active_lanes + 1`
(`constants.md#POOL_CAP_RULE`) — when the lane count is zero the pool has one empty slot,
which CF ages out after `constants.md#POOL_MAX_BUFFER_AGE_SECONDS`.

### Consequences

- Consumer attach is a no-op on the Metal side. Sequence B in `02-concurrency.md` simplifies
  accordingly.
- G-25 is not a risk because no texture is allocated `.private`.
- DRAM bandwidth cost must be monitored; graduation criterion is Instruments-driven per
  `open-questions.md` §OQ-01. A dedicated MIGRATION stage
  (`xx-private-default-rotation`) is reserved.

### Reversibility

Moderate. Graduation to dynamic rotation is a MIGRATION stage that adds storage-mode
tracking, pool rotation logic, and the G-25 discipline. Not a one-file edit, but scoped to
the `TexturePoolManager` + `ConsumerRegistry` pair — no SDK signature change.

---

## Pool configuration

Three `CVPixelBufferPool`s — one per stream type — with matching attributes per ADR-19:

- `kCVPixelBufferPoolMinimumBufferCountKey`: `constants.md#POOL_MIN_BUFFER_COUNT` (3).
- `kCVPixelBufferPoolMaximumBufferAgeKey`: `constants.md#POOL_MAX_BUFFER_AGE_SECONDS` (1.0).
- `kCVPixelBufferIOSurfacePropertiesKey`: `[:]`.
- `kCVPixelBufferMetalCompatibilityKey`: `true`.
- `kCVPixelBufferPixelFormatTypeKey`: `constants.md#WORKING_PIXEL_FORMAT` (RGBA16F) for
  natural / processed / tracker. The encoder pool uses
  `constants.md#ENCODER_PIXEL_FORMAT` — configured by `06-capture-and-recording.md`.

Growth: CF handles allocation past the minimum; the architecture does not call
`CVPixelBufferPoolCreatePixelBufferWithAuxAttributes` with an allocation threshold. Pool
exhaustion (domain `pool_exhaustion` counter) is emitted if CF ever returns
`kCVReturnWouldExceedAllocationThreshold` — per ADR-19 §Pool exhaustion.

---

## Readback double-buffer

Per domain 02-frame-delivery §GPU Processing Pipeline, a `READBACK_DOUBLE_BUFFER_DEPTH`
(=2) arrangement: one CPU-readable CVPixelBuffer is being written by the GPU while the
other is being mapped on the CPU side for consumer handoff. In practice the per-pool
mechanism covers this — `CVPixelBufferPool` with `POOL_MIN_BUFFER_COUNT >= 3` guarantees the
double-buffer invariant plus one write slot. The "previous-frame mapping" step in domain
02-frame-delivery §GPU Processing Pipeline step 8 corresponds to the consumer's
`for await` iteration reading the buffer from the prior frame — the lane that was
published by the last frame's completion handler.

Fence synchronization is via `MTLCommandBuffer.addCompletedHandler`; the domain's
"fence not signaled by end of per-frame budget → full GPU flush and log" degradation
maps to a `FRAME_LATENCY_FAILING_MS` breach per `constants.md#FRAME_LATENCY_FAILING_MS`.
A forced flush is `commandBuffer.waitUntilScheduled()` on the most recent buffer — it
does not stall the GPU, only the CPU side — followed by dropping the consumer publish for
that frame.

---

## Shader uniforms

Uniforms for Pass 2 (color transforms) are written from the engine actor (via
`setProcessingParameters(_:)`) and read per-frame by the GPU compute pass. Domain Invariant 6
requires exclusion — see `02-concurrency.md` row `OSAllocatedUnfairLock<UniformBuffer>`.

Implementation: one `OSAllocatedUnfairLock<UniformStorage>` holds the host-written values;
just before encoding Pass 2 the delivery queue acquires the lock, snapshots the struct into
a small `MTLBuffer`, and releases. The snapshot approach means Pass 2's argument binding
reads the struct without further locking.

Per-frame `processingMetadata` for `FrameSet` is constructed from the same snapshot so the
metadata matches the GPU work.

---

## Still-capture readback

Per D-05, `captureImage()` sets the C++-side `captureRequested_` atomic (domain Invariant 8
lock-free fast-path); Pass 6 (a same-format blit from `processedTex` to a CPU-readable
RGBA16F `CVPixelBuffer` allocated from a dedicated `stillReadbackBuffer`) is appended on the
frame where `captureRequested_.exchange(false)` returns true. On completion, the CPU side
maps the CVPixelBuffer, converts to BGRA8 (or direct from RGBA16F), and writes TIFF via
`CGImageDestination` per `06-capture-and-recording.md` §Still capture encoding.

The readback buffer is a single-slot `CVPixelBuffer` (not a pool): at most one capture is in
flight per Invariant 7.

---

## Center-patch sampling

`sampleCenterPatch()` reads `constants.md#CENTER_PATCH_SIZE_PX` pixels from the center of
`processedTex`. Implementation: a compute dispatch with threadgroup-sized buckets that
writes R, G, B histograms into an `MTLBuffer`, then a CPU-side trimmed-mean computation
discards the top and bottom `constants.md#CENTER_PATCH_TRIM_PERCENT` and returns the means.

Runs on the delivery queue after the per-frame command buffer completes (the request is
atomically flagged and the next frame's completion handler drives the readback, mirroring
the still-capture pattern).

---

## Resolution resize

Per `domain-revised/05-resource-lifecycle.md` §GPU Pipeline Resource Initialization and
domain 03-camera-control §Resolution Selection, `setResolution(size:)` triggers:

1. Session-only teardown (`03-camera-session.md` §Session-only teardown).
2. `TexturePoolManager.resize(to: newSize)` — destroys and recreates all three pools +
   internal textures at the new dimensions. Deadline
   `constants.md#RESOLUTION_RESIZE_TIMEOUT_SECONDS`; on timeout, pre-resize dimensions are
   restored.
3. Capture session restarted with the new `activeCaptureResolution`.

Frame drops during this window are expected (domain). No consumer receives partial
frames — the engine state is `.opening` during the transition.

---

## Preview surface rebind

Per `domain-revised/05-resource-lifecycle.md` §Preview Surface Rebind. If the `MTKView`
drawable is unavailable for `constants.md#PREVIEW_SURFACE_FAILURE_THRESHOLD` consecutive
frames, the engine emits a `previewSurfaceLost` signal; `08-ui.md` owns the re-bind by
handing a new `MTKView` (or a refreshed `CAMetalLayer.drawableSize`) to the engine via a
dedicated entry point, without restarting the capture session.

Consecutive failure counter resets on the first successful drawable acquire.

---

## Teardown

`TexturePoolManager.release()` called in the full-teardown ordering (`03-camera-session.md`
§Full teardown, step 4):

1. Drain any in-flight command buffer via `waitUntilScheduled()` (not `waitUntilCompleted` —
   ADR-09, too strong and dangerous on main; here we are on `delivery` via an engine actor
   hop, but still prefer `Scheduled` for bounded latency).
2. Release all three `CVPixelBufferPool`s.
3. Flush `CVMetalTextureCache` (`CVMetalTextureCacheFlush(cache, 0)`), then release the
   cache reference.
4. Release `MTLCommandQueue` (the engine actor drops the reference; `MTLDevice` is retained
   per ADR-09 §What you can safely retain across backgrounding).

`MTLDevice`, `MTLLibrary`, compiled pipeline states are retained across backgrounding (not
released until the engine itself is released) per ADR-09.

---

## Profiling

`os_signpost` intervals at capture callback, encode, GPU execution, and consumer handoff
boundaries per `ios-platform-guide/03-metal.md §Profiling strategy`. Budget classes:

- Acceptable: ≤ `constants.md#FRAME_LATENCY_DEGRADED_MS`.
- Degraded: `FRAME_LATENCY_DEGRADED_MS ..< FRAME_LATENCY_FAILING_MS`.
- Failing: > `constants.md#FRAME_LATENCY_FAILING_MS` — trigger the degraded-path fallback
  (flush, drop publish, log).

The signpost output composes with Metal System Trace in Instruments; no runtime flag is
needed.
