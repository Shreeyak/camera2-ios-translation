# iOS/Swift Specialist Pre-Review

Independent iOS/Swift/Metal specialist review of `design/`, commissioned by the orchestrator as a
second opinion before the formal Agent 4 (REVIEW) pass. This review is **not** part of the 4-agent
clean-room pipeline deliverables — it is supplementary.

> **Patch status legend** (annotations added after the review):
> - **[PATCHED]** — fix applied to `design/` during the post-review patch pass
> - **[DEFERRED]** — left to implementation time; tracked as an open concern
> - **[N/A]** — nothing to patch (e.g., a strength confirmation)

**Reviewer scope:** iOS platform correctness, Swift/SwiftUI idioms, Metal best practices, Apple
framework API currency, iOS-specific pitfalls.

**Skills consulted:** `swift-engineering:modern-swift`, `swift-engineering:swiftui-patterns`,
`swift-engineering:swift-diagnostics`, `swift-engineering:ios-26-platform`, plus direct analysis
of all 8 design files and domain files 04, 08.

---

## Verdict

**APPROVE WITH CAUTIONS**

The design is structurally sound and shows genuine iOS platform fluency: the Sandwich pattern is
correct, the CVMetalTextureCache zero-copy camera→GPU path is well-specified, actor topology is
coherent, and the domain coverage mapping is thorough. However, there is one hard requirement
violation (GPU-to-encoder path), one logic bug in pseudocode (ConsumerRegistry dispatch), and one
synchronization gap (MetalRenderer texture handoff) that must be resolved before implementation
of those phases begins.

---

## Critical Issues (will break on iOS or violates a hard requirement)

### C-01: GPU-to-encoder path is NOT zero-copy — violates `domain/08` requirement → **[PATCHED]**

**File:** `03-metal-pipeline.md` lines 250–256; `06-decisions-log.md` D-03

The design explicitly states it uses `MTLTexture.getBytes` (a CPU blit from GPU to a
`CVPixelBuffer`) and characterizes this as acceptable with "one `MTLTexture.getBytes` call per
recorded frame." This directly contradicts `domain/08-capture-and-recording.md` lines 76–78:
"The video encoder must receive GPU-processed frames directly from the GPU render pipeline
**without CPU-side frame conversion**."

**What iOS actually requires for true zero-copy:** Create the `CVPixelBufferPool` for
`AVAssetWriterInputPixelBufferAdaptor` with `kCVPixelBufferIOSurfacePropertiesKey` set (this makes
every pool pixel buffer IOSurface-backed). On each recorded frame, dequeue a `CVPixelBuffer` from
the pool, wrap it immediately as a `MTLTexture` via `CVMetalTextureCache`, and render the processed
output **directly into that texture** in the same compute pass (or blit with
`MTLBlitCommandEncoder` GPU-side, which stays on the GPU). Then append the `CVPixelBuffer` to the
adaptor. The `CVPixelBuffer` never touches the CPU — the GPU writes it, VideoToolbox reads it via
the shared IOSurface.

**Impact:** At 4K/30fps, `getBytes` on a full-res texture is ~500 MB/s CPU memory bandwidth. At
4:3 ~4000×3000 BGRA this is catastrophically expensive. Even at lower resolutions, it blocks the
completion handler thread and introduces a mandatory CPU stall every recorded frame.

**Fix:** Redesign `VideoRecorder` to pre-allocate IOSurface-backed `CVPixelBuffer` pool on
recording start, wrap each dequeued buffer as `MTLTexture` per frame, route the Metal compute
output to write into this texture directly via blit encoder (GPU-side, no CPU touch), then append.

---

### C-02: `ConsumerRegistry.dispatch` has a silent struct-copy bug → **[PATCHED — but reviewer misread]**

> **Patch note:** The specific claim — "write-back is missing" — turned out to be a misread; the write-back `consumers[role] = entry` was already present at line 119. However, inspection triggered by this finding uncovered a **different real bug**: `pendingFrame` was set unconditionally before the busy/idle branch, so the immediate-dispatch branch caused `markIdle` to re-dispatch the same frame. That real bug was fixed by splitting the busy/idle paths: pendingFrame is set only on the busy branch, and cleared explicitly before dispatching on the idle branch. `markIdle` now re-dispatches properly when a newer frame arrives mid-processing.


**File:** `04-opencv-integration.md` lines 116–130

```swift
func dispatch(frame: FramePacket, to role: ConsumerRole) {
    guard var entry = consumers[role] else { return }
    entry.pendingFrame = frame          // Mutates LOCAL COPY
    consumers[role] = entry             // <-- This line is MISSING

    if !entry.isProcessing {
        consumers[role]?.isProcessing = true   // Writes back isProcessing only
        entry.queue.async { [weak self] in
            entry.bridge.processFrame(frame)
            ...
        }
    }
}
```

`guard var entry = consumers[role]` copies the `ConsumerEntry` struct. The mutation
`entry.pendingFrame = frame` modifies only the local copy. The write-back `consumers[role] = entry`
is missing. Only `consumers[role]?.isProcessing = true` is written back. The `pendingFrame` update
is **silently lost** on every busy frame. The 1-slot mailbox does not work as designed.

**Fix:** Either add `consumers[role] = entry` immediately after the mutation, or restructure to
use `consumers[role]?.pendingFrame = frame` directly.

---

### C-03: MetalRenderer texture handoff has no specified synchronization primitive → **[PATCHED]**

**File:** `01-architecture.md` line 107; `02-concurrency.md` line 17; `03-metal-pipeline.md`
lines 240–246

The design says `MetalRenderer` holds "a lock-free double-buffer slot" updated by `CameraEngine`
and read in `draw(_:)`. `draw(_:)` is `nonisolated` and called by the system (Metal's display link
timer) on an arbitrary thread — it is completely outside the actor's isolation domain. Actor
isolation does NOT protect this crossing: the actor protects writes that happen *inside* actor
methods, but `draw(_:)` is not an actor method and runs concurrently with actor execution.

A write from `CameraEngine.processFrame` and a read from `MetalRenderer.draw` on different threads
accessing the same texture slot is a data race.

**What iOS requires:** The slot must be protected by `os_unfair_lock`, an atomic swap, or a
lock-free design using `OSAllocatedUnfairLock<MTLTexture?>` (iOS 16+). `MTLTexture` itself is safe
to pass between threads once fully written (Metal guarantees GPU write is visible after the
command buffer completes), but the *slot reference* swap must be atomic.

**Fix:** Explicitly specify the synchronization primitive for the texture slot in the design.
Suggest `OSAllocatedUnfairLock<MTLTexture?>` or `nonisolated(unsafe) var currentTexture: MTLTexture?`
with an `os_unfair_lock` guard, documented in `03-metal-pipeline.md`.

---

## High Priority (works but wrong idiom or risky)

### H-01: `CMSampleBuffer` crosses actor isolation boundary — Swift 6 compiler error → **[PATCHED]**

**File:** `02-concurrency.md` lines 385–398

```swift
func captureOutput(_ output: AVCaptureOutput,
                   didOutput sampleBuffer: CMSampleBuffer,
                   from connection: AVCaptureConnection) {
    guard let engine else { return }
    Task {
        await engine.processFrame(sampleBuffer)  // CMSampleBuffer is non-Sendable
    }
}
```

`CMSampleBuffer` does not conform to `Sendable`. Sending it across an actor boundary inside a
`Task { }` closure is a Swift 6 strict concurrency error. The design explicitly states
"No `@unchecked Sendable`" and claims strict concurrency compliance, but this code will not
compile under Swift 6.

**Fix:** In the delegate callback, extract the `CVPixelBuffer` with `CMSampleBufferGetImageBuffer`,
retain it, and pass that to the actor. Or use `sending CMSampleBuffer` parameter annotation
(SE-0430) on `processFrame` to transfer ownership. Both approaches must be explicitly specified.

---

### H-02: Actor re-entrancy is not acknowledged for `processFrame` → **[PATCHED via F-01]**

> Deferred during the pre-review patch pass; later re-raised by Agent 4 as F-01 (High) and patched then. The completion handler now captures `frameSessionState` at commit time and `onFrameReadbackComplete` guards with `guard sessionState == expectedState, sessionState == .streaming else { return }`. A Metal command buffer error check was also added.


**File:** `02-concurrency.md` D-01 note; `03-metal-pipeline.md` §Zero-Copy Path Detail

The design notes that "Actor re-entrancy at `await` points is well-understood and controlled,"
but never specifies *what* state is captured before `await` points in `processFrame`. Between the
commit of frame N's command buffer and the awaited completion of frame N-1's readback, the actor
is free to accept other messages — including `setProcessingParameters`, `close()`, or another
`processFrame`. `processingParams` and `commandQueue` could change between commit and completion.

**Fix:** Document which actor state is captured (copied) before the first `await` point. Add a
guard in `onFrameReadbackComplete` checking `sessionState == .streaming` before touching readback
buffers.

---

### H-03: `MTKView` drive mode not specified → **[PATCHED]**

**File:** `03-metal-pipeline.md` §Display Path; `01-architecture.md` §Layer 2

The design says `MetalRenderer` "triggers `MTKView.setNeedsDisplay()` when a new texture is ready."
This implies `isPaused = true` and `enableSetNeedsDisplay = true` on the `MTKView`. But the design
never states these configuration requirements. Default `MTKView` runs at 60Hz timer-driven,
rendering stale textures between 30fps camera frames.

**Fix:** Add explicit `MTKView` configuration: `view.isPaused = true`,
`view.enableSetNeedsDisplay = true`, and confirm `MetalRenderer` calls `view.setNeedsDisplay()`
on texture update.

---

### H-04: `NSMicrophoneUsageDescription` and `NSPhotoLibraryAddUsageDescription` not documented → **[PATCHED — with product correction]**

> Product correction: `NSMicrophoneUsageDescription` is **NOT** added — the app records video only, no audio. Only `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription` are added to `Info.plist`. See Phase 5 Info.plist Requirements table in `design/05-implementation-phases.md` and the rationale note explaining why the microphone key must not be added without actual access code.


**File:** `05-implementation-phases.md` Phase 5; `07-ios-specific-risks.md` §Domain/11

The design mentions `NSCameraUsageDescription` but not:
- **`NSMicrophoneUsageDescription`**: Required for `AVCaptureAudioDataOutput`. Missing this causes
  App Store review rejection.
- **`NSPhotoLibraryAddUsageDescription`**: Required for `PHPhotoLibrary.performChanges` write
  access. Without it, `requestAuthorization(for:)` crashes on iOS 14+.

**Fix:** Add an Info.plist requirements section to Phase 5 (or a top-level section in
`01-architecture.md`) listing all three keys with example strings.

---

### H-05: `captureNaturalPicture()` in-flight guard — correct but undocumented reasoning → **[DEFERRED]**

> Code is already sound; this is a documentation-only request. Deferred to implementation time (add a comment explaining that the `guard` + set both happen synchronously before the first `await`, making this atomic by actor construction).


**File:** `02-concurrency.md` lines 155–169

The check-and-set guard for `captureInFlight` is actually sound because the `guard` check and the
`captureInFlight = true` set both happen synchronously before the first `await`, making this
atomic by actor construction. But the design should explicitly note *why* it's sound, because
actor re-entrancy at `await` points makes this a non-obvious invariant.

---

## Medium (worth addressing before implementation) — all **[DEFERRED]** to implementation time

> All seven Medium findings below are style / documentation / tuning improvements. None require design-level changes. They are preserved here as a durable implementation checklist.

### M-01: Deployment target never stated

The design implies iOS 17 minimum (uses `@Observable`, `OSAllocatedUnfairLock`,
`AVCaptureConnection.videoRotationAngle`) but never states it. Should be explicit.

### M-02: `@State private var engine = CameraEngine()` in the App struct is unidiomatic

`@State` on a reference type (Swift actor) in an `@main App` struct is non-standard. Idiomatic
pattern is `@Environment` injection or holding as a `let` at App scope.

### M-03: `os_signpost` API is legacy style

Since iOS 16, Apple recommends `OSSignposter` (Swift-idiomatic with compile-time string checking).
At iOS 17+ minimum there is no reason to use the C-style API.

### M-04: Actor dispatch latency note needed

`CameraEngine.processFrame` holds the actor for the entire Metal encoding duration (1–3ms per
frame). Settings updates are therefore delayed up to one frame period. Should be measured in
Phase 2 Instruments pass.

### M-05: `StallWatchdog` timestamp visibility — up to one-frame measurement latency

The actor-based solution for Invariant 11 introduces up to 33ms of measurement jitter in the
3-second threshold. Acceptable but should be acknowledged.

### M-06: Testing strategy is absent

No protocol seams for `AVCaptureSession`, no Metal pipeline unit tests, no `ConsumerRegistry`
race-condition tests. Camera pipeline testing without physical hardware is a significant
implementation risk. Add a Phase 0 "Test Infrastructure" section.

### M-07: `VideoRecorder` drain uses `Task.sleep` alongside completion handler — race-prone

The 5s drain timeout should wrap `withCheckedThrowingContinuation` in a `TaskGroup` where the
first to complete wins — not a parallel `Task.sleep` race.

---

## Low / Nits

- **L-01** [DEFERRED]: `ColorUniforms` should use `SIMD4<Float>` for Metal alignment safety.
- **L-02** [N/A]: Natural stream naming is consistent in prose — no change needed.
- **L-03** **[PATCHED — escalated to Critical by Agent 4 as F-10]**: `BGRA8Unorm` in Metal vs "RGBA8888" in `IFrameConsumer` interface is a byte-order mismatch. OpenCV bridge now uses `cv::COLOR_BGRA2GRAY`. This was originally classified as a "Low / Nit" by the pre-reviewer, but Agent 4 correctly escalated it to Critical (F-10) because it is a silent per-frame correctness bug, not a style issue. Patched in `design/04-opencv-integration.md` line 244.
- **L-04** [DEFERRED]: `FramePacket.pixelBuffer` is `@property (assign)` — should be `@property (strong)` or have explicit retain semantics in the setter.
- **L-05** [DEFERRED]: `scenePhase` observer creates unstructured `Task` without cancellation. Rapid background↔active transitions could overlap.

---

## Strengths

1. CVMetalTextureCache zero-copy camera→GPU path is correctly specified.
2. `scenePhase == .background` vs `.inactive` distinction is correct and explicitly reasoned.
3. Actor topology is coherent — `ConsumerRegistry` separated from `CameraEngine` is a good call.
4. `AVCaptureVideoPreviewLayer` correctly banned in production (Phase 1a temporary exception is
   properly marked).
5. `MTKView` via `UIViewRepresentable` is the right SwiftUI integration.
6. Thermal state integration correctly wired to `ProcessInfo.thermalState`.
7. `AVAssetWriter` choice over `AVCaptureMovieFileOutput` is correct for GPU-processed frames.
8. `AsyncStream.bufferingNewest(1)` for back-pressure matches the domain invariant.
9. OpenCV integration strategy (two-layer ObjC++ bridge) is pragmatic.
10. UserDefaults + Codable for settings is the right call.

---

## iOS-Specific Risks Not Yet Documented (add to 07-ios-specific-risks.md) — all **[PATCHED]**

> All seven risks below were added to `design/07-ios-specific-risks.md` as R-21 through R-27 during the post-pre-review patch pass. R-26 was later marked NOT APPLICABLE after the product decision to drop audio from recording.


**R-21: `AVCaptureSession` must be stopped before background for camera-in-use indicator.**
Failure to stop the session before entering background is an iOS policy violation (App Store
rejection, not just a runtime issue). Should be a P0 acceptance criterion for Phase 1a.

**R-22: `AVCaptureSession.startRunning()` must not be called on the main thread.**
Blocks until hardware is ready (100–500ms). Must be explicitly called out to prevent
`@MainActor` context mistakes during setup.

**R-23: Metal command buffer errors are silent without explicit error checking.**
`addCompletedHandler` must check `commandBuffer.status` and `commandBuffer.error`. Without this,
GPU errors are only surfaced by the 3-second stall watchdog.

**R-24: `CVMetalTextureGetTexture` can return `nil` under memory pressure.**
The design force-unwraps `CVMetalTextureGetTexture(cvTexture!)!`. Under memory pressure, this
crashes. Guard both the `CVReturn` and the optional unwrap.

**R-25: `AVCapturePhotoOutput` + `AVCaptureVideoDataOutput` resolution conflict.**
At ~4000×3000, attaching both outputs may cause iOS to downgrade the video data output. Phase 5
must verify the video data output continues delivering 4:3 resolution.

**R-26: Audio session category conflict with other apps.**
Phase 5 audio requires `AVAudioSession.sharedInstance().setCategory(.record, mode: .videoRecording)`.
Must document audio-on-background behavior separately from camera release.

**R-27: `PHPhotoLibrary` async authorization flow.**
`PHPhotoLibrary.authorizationStatus(for: .addOnly)` must be checked before `performChanges`. If
`.notDetermined`, call `requestAuthorization(for:)` first. Exact async flow must be documented.
