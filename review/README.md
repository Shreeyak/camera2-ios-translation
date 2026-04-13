# Review — Agent 4 Output

**Review date:** 2026-04-13
**Reviewer:** Agent 4 (REVIEW)
**Inputs:** `design/` (9 files), `domain/` (12 files)
**Constraint:** `audit/` not read; `00-ios-specialist-prereview.md` not echoed

---

## Original Verdict: YELLOW — Conditional Approval

The iOS translation design is structurally sound. The core architecture (Swift actor isolation, Metal zero-copy pipeline, ObjC++ bridge, ConsumerRegistry) is correctly specified and all four pre-review critical findings (C-01, C-02, C-03, H-01) are confirmed patched. The design is implementable.

Two findings prevent a Green verdict: a silent OpenCV color channel bug that makes edge detection always produce wrong output, and an unprotected background recording drain that risks file corruption when the user backgrounds during recording. Neither is architecturally complex to fix; both must be addressed before Phase 3 and Phase 5 implementation respectively.

## Post-Patch Verdict: GREEN — Implementation-Ready

All Critical and High findings from both this review and the iOS specialist pre-review have been patched in `design/`. See individual finding annotations in `01-correctness-check.md` and `02-adversarial-red-team.md` for per-item `[PATCHED]` / `[DEFERRED]` status.

**Patched:** F-01, F-03, F-05, F-07, F-10, F-11 (and C-01, C-02, C-03, H-01, H-02, H-03, H-04 from the pre-review).
**Deferred (implementation-time only):** F-02, F-04, F-06, F-08 — all documented with concrete mitigation recipes.

The design is ready for Phase 1a implementation start.

---

## Top 3 Findings

### 1. cv::COLOR_RGBA2GRAY Must Be cv::COLOR_BGRA2GRAY (Critical — F-10)

`design/04-opencv-integration.md` line 242 uses `cv::COLOR_RGBA2GRAY`. Metal outputs `BGRA8Unorm`. The byte order mismatch swaps Red and Blue channel weights in the luminance formula, producing silently incorrect grayscale input to Canny. Edge contours will be wrong on every frame. Fix: change to `cv::COLOR_BGRA2GRAY` and rename the `cv::Mat rgba` variable to `bgra`. One-line change.

### 2. Background Recording Drain Needs UIApplication.beginBackgroundTask (Critical — F-03)

`backgroundSuspend()` stops recording and calls `AVAssetWriter.finishWriting` with a 5-second drain timeout. iOS suspends the process approximately 5 seconds after `scenePhase == .background`. The drain and the suspension window race. If iOS wins, the MP4 moov atom is never written — the file is permanently corrupted. Fix: call `UIApplication.shared.beginBackgroundTask` before stopping recording; end the task in the completion handler or expiration handler.

### 3. Actor Re-entrancy in processFrame Not Guarded (High — F-01, pre-review H-02 unpatched)

`onFrameReadbackComplete` (the Metal completedHandler callback that resumes the actor) has no `guard sessionState == .streaming` check. If `close()` or `backgroundSuspend()` arrives during the Metal command buffer await window, the completedHandler can attempt to access a torn-down pipeline. Fix: add a state guard at the entry of `onFrameReadbackComplete`.

---

## Recommended Next Step (original — superseded by patches)

~~**Before Phase 3 begins:**~~
1. ~~Fix F-10 (`COLOR_BGRA2GRAY`) in `04-opencv-integration.md`~~ **[PATCHED]**
2. ~~Fix F-01 (add state guard to `onFrameReadbackComplete`) in `02-concurrency.md` + `CameraEngine` design~~ **[PATCHED in 03-metal-pipeline.md]**
3. ~~Add F-07 to Phase 1a acceptance criteria: `Info.plist` must include `NSMicrophoneUsageDescription` and `NSPhotoLibraryAddUsageDescription`~~ **[PATCHED with product correction: video-only, no microphone key]**

~~**Before Phase 5 begins:**~~
4. ~~Fix F-03 (beginBackgroundTask for recording drain) in `05-implementation-phases.md` Phase 5 acceptance criteria and `07-ios-specific-risks.md` (new risk R-28)~~ **[PATCHED in 02-concurrency.md]**
5. ~~Decide F-05/F-11: assign `EdgeDetectionConsumer` to `ConsumerRole.Tracker` (recommended) or document the resolution limitation explicitly~~ **[PATCHED: configure() asserts Tracker-only]**

**Current next step:** proceed to Phase 1a implementation in a fresh app workspace (see `implementation` section below).

---

## Relationship to Pre-Review

| Pre-review finding | This review |
|---|---|
| C-01 (zero-copy violation) | Confirmed patched — IOSurface + MTLBlitCommandEncoder path complete |
| C-02 (dispatch struct copy bug) | Confirmed patched — write-back present in both dispatch branches |
| C-03 (MetalRenderer texture race) | Confirmed patched — OSAllocatedUnfairLock<MTLTexture?> specified |
| H-01 (CMSampleBuffer actor boundary) | Confirmed patched — IncomingFrame @unchecked Sendable wrapper specified |
| H-02 (actor re-entrancy unacknowledged) | **Still unpatched** — raised as F-01 (High) |
| H-03 (MTKView drive mode unspecified) | Confirmed patched — isPaused=true, enableSetNeedsDisplay=true specified |
| H-04 (Info.plist usage strings missing) | **Still unpatched** — raised as F-07 (High) |
| M-06 (testing strategy absent) | Not raised again — acceptable for design phase; Phase acceptance criteria provide partial coverage |

---

## Files Produced

| File | Contents |
|---|---|
| `review/01-correctness-check.md` | Pass 1 — 27-item correctness check across 4 categories; verdict: YELLOW (1 RED in Category C) |
| `review/02-adversarial-red-team.md` | Pass 2 — 11 findings across 6 attack categories; 2 Critical, 3 High, 4 Medium, 1 Low |
| `review/README.md` | This file — overall verdict, top findings, next steps |
