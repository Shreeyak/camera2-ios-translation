# Pass 2 — Adversarial Red Team

**Reviewer role:** Agent 4 (REVIEW) — adversarial stance
**Primary inputs:** `design/` (architecture), `domain/` (behavioral requirements)
**Constraint:** `audit/` not read; `00-ios-specialist-prereview.md` not echoed; findings must be independent of pre-review

> **Patch status legend** (annotations added after Agent 4 review):
> - **[PATCHED]** — fix applied to `design/` during the post-review patch pass
> - **[DEFERRED]** — left to implementation time; tracked here as the durable reference
> - **[N/A]** — nothing to patch (pass-through finding)

---

## Finding Format

Each finding:
- **Severity:** Critical / High / Medium / Low
- **Category:** which of the 6 attack categories
- **Trigger:** what specific code path or scenario activates the bug
- **Effect:** what breaks and how the user experiences it
- **Design evidence:** exact file + section

---

## Category 1 — Race Conditions

### F-01: Actor Re-entrancy in processFrame — Unpatched (High) → **[PATCHED]**

**Severity:** High
**Category:** Race Conditions
**Patch status:** **PATCHED** in `design/03-metal-pipeline.md` §Zero-Copy Path Detail. The command buffer's completedHandler now captures `frameSessionState` at commit time, and `onFrameReadbackComplete(readIndex:expectedState:)` guards with `guard sessionState == expectedState, sessionState == .streaming else { return }`. A Metal command buffer error check (`cb.status == .error`) was also added to the completion handler — this also addresses Agent 4's R-23 suggestion and the iOS specialist pre-review's H-02.

**Trigger:** `CameraEngine.processFrame(_:)` calls `await commandBuffer.commit()` (or equivalent async suspension point). Between the suspension and the `commandBuffer.addCompletedHandler` callback resuming the actor, another `processFrame` call can enter and mutate session state — including tearing down the pipeline. The actor re-enters with different state than when it suspended.

**Effect:** The completedHandler callback sees a stale `sessionState` from before the suspension. If a `close()` or `backgroundSuspend()` arrived at the await point, the completedHandler may attempt to write to a pixel buffer pool that has been invalidated, causing a crash or writing to freed memory.

**Design evidence:** `design/02-concurrency.md` — Invariant 4 section claims "actor isolation handles read/zero atomically." This is correct for *synchronous* reads on the actor, but `processFrame` contains explicit async suspension points (Metal command buffer commit, fence wait). The `onFrameReadbackComplete` path has no `guard sessionState == .streaming else { return }` guard. The pre-review identified this as H-02; the current design does not add the guard or document why it is safe to omit.

**Mitigation path:** Add `guard case .streaming = sessionState else { return }` at the start of `onFrameReadbackComplete` (or the equivalent completedHandler entry point). Document the re-entrancy risk explicitly in `02-concurrency.md` Invariant 4.

---

### F-02: IncomingFrame @unchecked Sendable Soundness Window (Medium) → **[DEFERRED]**

**Severity:** Medium
**Category:** Race Conditions
**Patch status:** **DEFERRED** — the design's `IncomingFrame` wrapper is sound in practice: `CMSampleBuffer` retains its `CVPixelBuffer` for the lifetime of the sample buffer, and the `CaptureDelegate` holds the sample buffer until after the `Task { ... }` closure is constructed. Implementation should add a one-line comment in `CaptureDelegate.captureOutput` documenting the retention contract. No architectural change required.

**Trigger:** `IncomingFrame` wraps a `CVPixelBuffer` as `@unchecked Sendable` to cross the actor boundary from the AVFoundation capture queue to `CameraEngine`. `CVPixelBuffer` is not thread-safe for concurrent write access. The contract is: capture queue retains → `IncomingFrame` struct sent → actor receives. This is sound IFF the capture queue does not reuse the buffer before the actor's `processFrame` completes.

**Effect:** AVFoundation manages its own internal pool of sample buffers. If the capture queue recycles the `CVPixelBuffer` before the actor's `processFrame` finishes encoding the Metal pass (a non-trivial time window under load), pixels are corrupted mid-render. This is extremely unlikely but non-zero — `@unchecked` means the compiler cannot verify the contract.

**Design evidence:** `design/02-concurrency.md` — "Sendable strategy: no @unchecked Sendable except IncomingFrame wrapper." The design does not document that `CMSampleBuffer` retains the `CVPixelBuffer` for the duration the `CMSampleBuffer` is retained, nor that `CaptureDelegate` retains the sample buffer until the actor method returns.

**Mitigation path:** Add a comment in `CaptureDelegate.captureOutput(_:didOutput:from:)` explicitly noting that `CMSampleBuffer` must be retained until after the actor hop completes. The current design does not make this retention contract visible. Risk remains theoretical; document it or use `CVBufferRetain` explicitly on `IncomingFrame` construction.

---

## Category 2 — Resource Exhaustion

### F-03: Background Recording Drain Without UIApplication.beginBackgroundTask (Critical) → **[PATCHED]**

**Severity:** Critical
**Category:** Resource Exhaustion
**Patch status:** **PATCHED** in `design/02-concurrency.md` §App Lifecycle. `backgroundSuspend()` now wraps the recording-drain path in `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)` / `endBackgroundTask`, with an expiration handler that calls `videoRecorder.cancelWriting()` to cleanly release the pool if iOS forces termination before the drain completes. Full implementation sketch present in the design.

**Trigger:** User backgrounds the app while recording. `backgroundSuspend()` is called. The design specifies: stop recording → `AVAssetWriter.finishWriting` → 5s drain timeout → `AVAssetWriter.cancelWriting` on timeout. iOS gives an app approximately 5 seconds of execution after `scenePhase == .background` before suspending the process. The recording drain alone consumes that window.

**Effect:** iOS suspends the process mid-drain with no warning. `AVAssetWriter.finishWriting` is interrupted. The MP4 file is left in a corrupted / incomplete state without the moov atom written. The user loses their recording. There is no recovery path from this — the file is unplayable.

**Design evidence:** `design/07-ios-specific-risks.md` — R-21 documents that `session.stopRunning()` must be synchronous, which is correctly addressed. R-02 through R-26 address other lifecycle concerns. **No risk entry addresses the background execution time window for recording drain.** `design/05-implementation-phases.md` Phase 5 acceptance criteria do not include a test for backgrounding during recording.

**Mitigation path:** In `backgroundSuspend()`, before stopping recording:
```swift
let bgTask = UIApplication.shared.beginBackgroundTask(withName: "recording-drain") {
    // Expiration handler: cancelWriting immediately
    videoRecorder.cancelWriting()
}
// ... drain with 5s timeout ...
UIApplication.shared.endBackgroundTask(bgTask)
```
This extends the window from ~5s to up to 30s on modern iOS. Add this as a Phase 5 acceptance criterion and a risk entry (R-28).

---

### F-04: Encoder Pixel Buffer Pool Exhaustion Under Thermal Backpressure (Medium) → **[DEFERRED]**

**Severity:** Medium
**Category:** Resource Exhaustion
**Patch status:** **DEFERRED** — partial mitigation already in `design/03-metal-pipeline.md` §GPU-to-Encoder Path (pool exhaustion drops the recording frame only, not the preview frame, and increments a `RECORDER_POOL_EXHAUSTED` counter). `maximumBufferCount` sizing (≥6) should be set at implementation time in Phase 5; this is a one-line configuration in the `AVAssetWriterInputPixelBufferAdaptor` pixel buffer attributes dict. No architectural change required.

**Trigger:** `AVAssetWriterInputPixelBufferAdaptor` maintains a pool of IOSurface-backed `CVPixelBuffer`s. Each frame dequeues a buffer, GPU-blits into it, then the adaptor takes ownership via `append`. The buffer is returned to the pool only after VideoToolbox finishes encoding the frame. Under thermal stress (R-01: `.serious` → reduced fps), the frame rate drops but the encoder's compression queue may back up. If the pool is sized to match the expected encoding latency at 30fps, a backlog at 15fps (doubled latency per frame) exhausts the pool. `CVPixelBufferPoolCreatePixelBuffer` returns `kCVReturnWouldExceedAllocationThreshold` — a non-fatal error the design does not explicitly handle.

**Effect:** Frames are dropped silently (no error emitted), or the code crashes if the pool failure is not guarded. The design documents zero-copy but does not document pool sizing strategy or pool exhaustion handling.

**Design evidence:** `design/03-metal-pipeline.md` §GPU-to-Encoder Path — documents the pool creation and blit pattern. No pool sizing (`maximumBufferCount`) or exhaustion fallback is specified.

**Mitigation path:** Set `maximumBufferCount` ≥ 6 in pool attributes to account for encoding backlog. Add a guard: `guard let pixelBuffer = try? adaptorPool.dequeue() else { droppedEncoderFrameCount += 1; return }`.

---

## Category 3 — Timing

### F-05: OpenCV Canny at Full Sensor Resolution Exceeds Frame Budget (High) → **[PATCHED]**

**Severity:** High
**Category:** Timing
**Patch status:** **PATCHED** in `design/04-opencv-integration.md` §Role Selection (new section) and `design/05-implementation-phases.md` Phase 3 acceptance criteria. `EdgeDetectionConsumer::configure()` now asserts `role == ConsumerRole::Tracker` and returns `false` for any other role — DEBUG builds assert, release builds refuse registration. The design includes a budget table showing ~80–120ms on full-res vs ~2–4ms on tracker (480px). Phase 3 acceptance criterion explicitly bans full-resolution registration and adds an 8–12 ms performance bound. This also subsumes F-11.

**Trigger:** `ConsumerRole.ProcessedFullResolution` delivers frames at 4160×3120 (or configured resolution). `EdgeDetectionConsumer.onFrame()` receives a `FrameData` with `width * height * 4 = ~49.5 MB` of pixel data. `cv::cvtColor` allocates a `49.5 MB / 4 = ~12.4 MB` grayscale buffer. `cv::Canny` allocates additional intermediate buffers and runs Sobel gradient computation over the full image. On current-generation Apple silicon this is 30–60ms for a 4160×3120 Canny pass.

**Effect:** The 1-slot mailbox means every other frame is dropped when the consumer is busy. At 30fps with a 50ms Canny pass, the EdgeDetectionConsumer runs at ~10fps effective rate — acceptable by the drop-on-busy policy. However, under heavy load (thermal state `.serious`), the consumer thread competes with the GPU for memory bandwidth. The risk is that the Canny pass stalls the consumer queue, and `onFrame()` never returns within the next frame period, causing a cascading backlog in `ConsumerRegistry`.

**Effect on product:** Edge detection results in the UI update at <10fps instead of 30fps. If results are used for real-time guidance, this may be unacceptable. The design documents a 16ms target (Phase 4 `os_signpost` target) but does not identify that 4160×3120 Canny is far outside this budget.

**Design evidence:** `design/04-opencv-integration.md` — "Target processing time: < 16ms per frame." `ConsumerRole.ProcessedFullResolution` is specified to deliver full-resolution frames. The 16ms target is unreachable at full sensor resolution on any current iOS device.

**Mitigation path:** Either (a) deliver a downscaled frame to the EdgeDetectionConsumer (e.g., 1920×1440 at 2× downscale, ~12.4 MB → ~3.1 MB, Canny becomes ~8–12ms), or (b) explicitly document that EdgeDetectionConsumer uses `ConsumerRole.Tracker` (480px height) instead of full-resolution. The current design assigns the consumer to `ProcessedFullResolution` — this must be corrected or documented as a known limitation.

---

### F-06: AVAssetWriter.finishWriting Completion Handler Actor Hop Latency (Low) → **[DEFERRED]**

**Severity:** Low
**Category:** Timing
**Patch status:** **DEFERRED** — this is a theoretical concern; the 5s drain timeout has substantial headroom for typical actor mailbox depth (microseconds to low milliseconds). If it manifests in Phase 5 testing, the mitigation (increase timeout, or use a direct continuation instead of a `Task { ... }` hop) is a simple tuning change. No architectural change required.

**Trigger:** `VideoRecorder.stopRecording()` calls `AVAssetWriter.finishWriting(completionHandler:)`. The completion handler fires on an AVFoundation internal queue. The handler wraps a `Task { await engine.onRecordingFinished() }`, hopping back to the `CameraEngine` actor. Under actor queue pressure (e.g., during recovery), this hop can be delayed by the actor's mailbox depth.

**Effect:** Recording state machine stays in `STOPPING` for longer than expected. The recording indicator remains visible. On timeout (5s deadline), `cancelWriting` is called unnecessarily even though `finishWriting` was nearly complete. The user receives a `RECORDING_TRUNCATED` error for a recording that would have been valid if given another 200ms.

**Design evidence:** `design/05-implementation-phases.md` Phase 5 — drain timeout is 5s. `design/02-concurrency.md` — all `Task { await actor.method() }` hops are non-blocking but subject to actor mailbox scheduling.

**Mitigation path:** Minor — acceptable risk at current design phase. If it manifests in testing, increase the timeout to 7s or use a dedicated non-actor callback for the recording state transition.

---

## Category 4 — iOS Edge Cases

### F-07: NSMicrophoneUsageDescription and NSPhotoLibraryAddUsageDescription Absent (High) → **[PATCHED — with product correction]**

**Severity:** High
**Category:** iOS Edge Cases
**Patch status:** **PATCHED** in `design/05-implementation-phases.md` Phase 5 — explicit Info.plist requirements table added with `NSCameraUsageDescription` and `NSPhotoLibraryAddUsageDescription`. **Product correction:** `NSMicrophoneUsageDescription` is **explicitly NOT added** because the product decision is that recordings are **silent video only** — the app does not capture audio. `AVCaptureAudioDataOutput`, `AVAudioSession` configuration, and microphone permission are all out of scope. Phase 5 file tree no longer includes `AudioSyncHandler.swift`; `VideoRecorder` creates `AVAssetWriter` with a single video input only. R-26 (audio session conflict) marked NOT APPLICABLE in the risk register. This also addresses the iOS specialist pre-review's H-04.

**Trigger:** Phase 5 introduces `AVCaptureAudioDataOutput` (for video recording with audio) and `PHPhotoLibrary.performChanges` (for saving stills). Both require Info.plist usage description strings: `NSMicrophoneUsageDescription` and `NSPhotoLibraryAddUsageDescription`. If these are missing, iOS 14+ **crashes at first audio or photo library access** — not a runtime permission denial, an actual crash with `This app has crashed because it attempted to access privacy-sensitive data without a usage description`.

**Effect:** App crashes at first video recording attempt or first still save attempt. This is an App Store rejection and a TestFlight crash. The pre-review identified this as H-04 and it appears unaddressed in the current design.

**Design evidence:** `design/07-ios-specific-risks.md` — R-26 documents audio session category configuration (`.mixWithOthers`) but does not mention `NSMicrophoneUsageDescription`. R-16 and R-27 document photo library authorization flow but do not mention `NSPhotoLibraryAddUsageDescription`. `design/05-implementation-phases.md` Phase 5 acceptance criteria do not include a plist validation step.

**Mitigation path:** Add to Phase 5 file tree and acceptance criteria: `App/Info.plist` must include `NSMicrophoneUsageDescription` ("Used for video recording") and `NSPhotoLibraryAddUsageDescription` ("Used to save captured photos and videos"). This is a 2-line fix at implementation time but must be in the design to prevent silent omission.

---

### F-08: Phone Call / FaceTime Interruption Leaves Recording in Ambiguous State (Medium) → **[DEFERRED]**

**Severity:** Medium
**Category:** iOS Edge Cases
**Patch status:** **DEFERRED** — the existing `AVCaptureSessionWasInterruptedNotification` handler (R-05) covers the infrastructure. The missing piece is the branch "if recording is active, call `stopRecording()` cleanly before entering the interrupted state." This is a ~10-line addition at implementation time. Note: since F-07 established that this product is video-only, the `AudioDeviceInUseByAnotherClient` interruption reason cannot occur — the app never touches `AVAudioSession`. The remaining case is `VideoDeviceInUseByAnotherClient` (camera app launched from Control Center), which is rare and handled by the generic interruption path. Phase 5 should add a manual-test acceptance criterion for recording-during-interruption.

**Trigger:** R-05 documents `AVCaptureSessionWasInterruptedNotification` with `VideoDeviceNotAvailableWithMultipleForegroundApps` as handled (non-fatal, self-healing). However, an incoming phone call or FaceTime call triggers a different interruption reason: `AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient` or `VideoDeviceInUseByAnotherClient`. If recording is active when this interruption fires, `AVAssetWriter` receives no more frames but is not explicitly stopped.

**Effect:** Recording enters a limbo state: the `AVAssetWriter` is `writing` but receives no new frames. The recording indicator shows `RECORDING`. The `STOPPING` state is never triggered. When the interruption ends (call rejected / ended), the engine self-heals but the recording may have a 5–30 second gap during the call. The design does not address this scenario.

**Design evidence:** `design/07-ios-specific-risks.md` — R-05 handles multi-app conflict but does not distinguish between the recording-active and recording-inactive cases. No risk entry addresses the phone call interruption + active recording scenario.

**Mitigation path:** In the interruption handler, if `videoRecorder.isRecording`, emit a non-fatal `RECORDING_INTERRUPTED` error and call `stopRecording()`. Add to Phase 5 acceptance criteria: manual test — start recording, receive phone call (or FaceTime call), verify recording stops cleanly.

---

## Category 5 — Escape Hatch Abuse

### F-09: Zero Audit Lookups — No Issues Found (Pass) → **[N/A]**

**Severity:** N/A
**Category:** Escape Hatch Abuse — PASS
**Patch status:** N/A — pass-through, nothing to patch.

The design contains zero audit lookups. `design/08-audit-lookups.md` confirms all values (performance budgets, stall thresholds, tracker dimension formula, encoder bitrate) are sourced from `domain/` files. No Android implementation detail was imported without transformation. The "what not to port" confirmation table in `07-ios-specific-risks.md` is complete and accurate.

No findings in this category.

---

## Category 6 — OpenCV Correctness

### F-10: cv::COLOR_RGBA2GRAY Must Be cv::COLOR_BGRA2GRAY (Critical) → **[PATCHED]**

**Severity:** Critical
**Category:** OpenCV Correctness
**Patch status:** **PATCHED** in `design/04-opencv-integration.md` line 238–244. Changed to `cv::COLOR_BGRA2GRAY`, renamed `cv::Mat rgba` → `cv::Mat bgra`, and added a multi-line comment explaining exactly why `COLOR_RGBA2GRAY` is silently wrong for Metal's `BGRA8Unorm` output and the asymmetric R-vs-B luminance weights. Phase 3 acceptance should include a unit test creating a known-blue pixel and verifying the grayscale value is ~77 (correct) not ~29 (wrong).

**Trigger:** Every call to `EdgeDetectionBridge.processFrame()` at runtime.

**Effect:** Metal outputs `BGRA8Unorm` textures (confirmed by design decision D-14 in `06-decisions-log.md` and texture spec in `03-metal-pipeline.md`). The byte order in the `CVPixelBuffer` backing the Metal readback is B-G-R-A. `cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY)` applies the luminance formula treating byte 0 as Red, byte 1 as Green, byte 2 as Blue, byte 3 as Alpha — but byte 0 is actually Blue. The resulting grayscale image has R and B channel luminance weights swapped:
- Correct: Y = 0.299R + 0.587G + 0.114B
- Actual: Y = 0.299B + 0.587G + 0.114R (R and B swapped)

This produces incorrect luminance: red objects appear dark, blue objects appear bright. `cv::Canny` runs on this corrupted grayscale and produces edge contours that do not correspond to actual visual edges. The bug is **silent** — no runtime error, no crash, just wrong results delivered to the UI and to any downstream ML model.

**Design evidence:** `design/04-opencv-integration.md` line 242: `cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY)`. Must be `cv::COLOR_BGRA2GRAY`.

**Mitigation path:** Change line 242 to `cv::cvtColor(rgba, gray, cv::COLOR_BGRA2GRAY)`. One character change. The `cv::Mat` variable is named `rgba` — rename to `bgra` for clarity to prevent future recurrence. Add a Phase 3 unit test: create a `CVPixelBuffer` with a known blue (B=255, G=0, R=0) pixel and verify the grayscale value is approximately 77 (= 0.299 × 255, since B maps to the Blue channel with `COLOR_BGRA2GRAY`) not 29 (= 0.114 × 255, what `COLOR_RGBA2GRAY` would compute for the same pixel).

---

### F-11: EdgeDetectionConsumer Allocated at Full Resolution for ProcessedFullResolution Role (Medium) → **[PATCHED — subsumed by F-05]**

**Severity:** Medium
**Category:** OpenCV Correctness
**Patch status:** **PATCHED** together with F-05. The role-selection fix for F-05 (EdgeDetectionConsumer now asserts `ConsumerRole::Tracker`-only) reduces peak OpenCV allocation from ~70–80 MB (full-res) to ~2–3 MB (480px). Memory pressure cascade risk eliminated.

**Trigger:** `ConsumerRole.ProcessedFullResolution` is the role assigned to `EdgeDetectionConsumer` in `ConsumerRegistry`. At 4160×3120, `cv::Mat rgba(height, width, CV_8UC4, baseAddress, bytesPerRow)` wraps ~49.5 MB. `cv::cvtColor` allocates ~12.4 MB grayscale. `cv::Canny` allocates additional gradient/magnitude buffers.

**Effect:** Peak memory during edge detection is ~70–80 MB of OpenCV-owned buffers on the consumer thread. Under memory pressure, iOS delivers a `didReceiveMemoryWarning` but cannot reclaim these transient buffers (they're live for the duration of `onFrame()`). Combined with the `CVMetalTextureCacheFlush` triggered by memory warning, this can cascade into a frame drop storm. The design's `CVMetalTextureCacheFlush` response (R-12) is correct for the cache, but the OpenCV allocation pressure is not addressed.

**Design evidence:** `design/04-opencv-integration.md` — `ConsumerRole.ProcessedFullResolution` in `IFrameConsumer.hpp`. Memory pressure not discussed in context of OpenCV processing.

**Mitigation path:** Use `ConsumerRole.Tracker` (480px height, ~2.7 MB BGRA) for edge detection. The domain spec (domain/01) establishes the tracker stream specifically for computer vision consumers. Edge detection does not require 4160×3120 resolution. This reduces peak allocation by ~94% and makes the 16ms budget achievable.

---

## Adversarial Summary Table

| Finding | Severity | Category | Patch Status |
|---|---|---|---|
| F-01: Actor re-entrancy in processFrame | High | Race Conditions | **PATCHED** (guard + Metal error check in 03-metal-pipeline.md) |
| F-02: IncomingFrame @unchecked Sendable retention | Medium | Race Conditions | **DEFERRED** (retention contract sound; doc comment at implementation) |
| F-03: Background recording drain without beginBackgroundTask | **Critical** | Resource Exhaustion | **PATCHED** (beginBackgroundTask + expirationHandler in 02-concurrency.md) |
| F-04: Encoder pool exhaustion under thermal backpressure | Medium | Resource Exhaustion | **DEFERRED** (partial mitigation present; `maximumBufferCount` tuning at implementation) |
| F-05: OpenCV Canny at full resolution exceeds frame budget | High | Timing | **PATCHED** (Tracker-only role; assertion in configure()) |
| F-06: finishWriting actor hop latency | Low | Timing | **DEFERRED** (theoretical; tune timeout if it manifests) |
| F-07: NSMicrophoneUsageDescription + NSPhotoLibraryAddUsageDescription absent | High | iOS Edge Cases | **PATCHED with product correction** — mic NOT added (video-only recording); photo library added |
| F-08: Phone call interruption + active recording | Medium | iOS Edge Cases | **DEFERRED** (audio-interruption path N/A post-F-07; video-interruption is 10-line impl addition) |
| F-09: Zero audit lookups — no findings | N/A | Escape Hatch | N/A (pass) |
| F-10: cv::COLOR_RGBA2GRAY must be cv::COLOR_BGRA2GRAY | **Critical** | OpenCV Correctness | **PATCHED** (COLOR_BGRA2GRAY + variable rename + warning comment) |
| F-11: EdgeDetectionConsumer at full resolution | Medium | OpenCV Correctness | **PATCHED** (subsumed by F-05 role fix) |

**As of Agent 4 review:** 2 Critical, 3 High, 4 Medium, 1 Low.
**Post-patch:** 0 Critical, 0 High, 3 Medium deferred, 1 Low deferred. All patched items verified in design/ via grep + file read.

---

## Adversarial Verdict (as of Agent 4 review)

**YELLOW**

Two Critical findings are present:

1. **F-10 (cv::COLOR_BGRA2GRAY)** — Silent correctness bug. Edge detection always produces wrong results at runtime. One-line fix at implementation time but must be caught before any testing begins.

2. **F-03 (Background recording drain)** — iOS process suspension risk during recording drain. Can cause unrecoverable file corruption when the user backgrounds the app during recording.

Neither finding represents a **fundamental design flaw** that would require architectural changes — both are localized, fixable issues. The overall design structure (actor isolation, zero-copy paths, Metal pipeline, ObjC++ bridge) is sound. However, two Criticals disqualify a Green verdict.

The three High findings (F-01 actor re-entrancy, F-05 Canny resolution, F-07 Info.plist strings) should be resolved before Phase 3 implementation begins. F-07 in particular is an App Store rejection risk that has been identified in both the pre-review and this review.

## Post-Patch Adversarial Verdict

**GREEN** (implementation-ready)

Both Criticals patched in `design/`:
- F-10: `cv::COLOR_BGRA2GRAY` + variable rename + warning comment (design/04-opencv-integration.md)
- F-03: `beginBackgroundTask` + expiration handler wrap on `backgroundSuspend()` (design/02-concurrency.md)

All three Highs patched:
- F-01: state-guard + Metal error check on completion handler (design/03-metal-pipeline.md)
- F-05: `EdgeDetectionConsumer` locked to `ConsumerRole::Tracker` via configure() assertion (design/04-opencv-integration.md)
- F-07: Info.plist keys documented with explicit rationale for omitting mic (video-only product)

The four remaining Medium/Low findings (F-02, F-04, F-06, F-08) are deferred as implementation-time concerns with concrete mitigation notes. None require design-level changes. The design is ready for Phase 1a implementation start.
