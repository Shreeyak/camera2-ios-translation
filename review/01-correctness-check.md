# Pass 1 — Correctness Check

**Reviewer role:** Agent 4 (REVIEW)
**Primary inputs:** `design/` (architecture), `domain/` (behavioral requirements)
**Constraint:** `audit/` not read; `00-ios-specialist-prereview.md` not echoed

> **Patch status legend** (annotations added after Agent 4 review):
> - **[PATCHED]** — fix applied to `design/` during the post-review patch pass; verified by grep + file read
> - **[DEFERRED]** — left to implementation time; tracked as an open issue
> - **[N/A]** — nothing to patch (item was already PASS)

---

## Category A — Requirements Coverage

Does the design address every requirement from each domain file?

| # | Domain file | Coverage verdict | Notes |
|---|---|---|---|
| A-01 | `domain/01-system-purpose.md` | PASS | All 6 missions present: GPU preview (`MetalRenderer`), natural stream (`NaturalMetalViewWrapper`), C++ consumer fan-out (`ConsumerRegistry`), ISP JPEG still (`StillCaptureController`), GPU-processed still (`StillCaptureController`), HEVC/H.264 recording (`VideoRecorder`). Single-session, back-facing-main-only enforced in `CameraEngine.open()` guard. |
| A-02 | `domain/02-frame-delivery.md` | PASS | 30fps target set. YUV 4:2:0 → Metal compute → BGRA8Unorm pipeline documented. All 4 output streams present: processed preview, tracker (480px height formula preserved verbatim), natural passthrough, encoder. Drop-on-busy via 1-slot mailbox in ConsumerRegistry. GPU-level 3s stall + capture-level 5s stall watchdogs designed. |
| A-03 | `domain/03-camera-control.md` | PARTIAL — **[DEFERRED]** documented deviation, no design action needed. `domain/12-unresolved.md §U-11` rewritten as PARTIALLY RESOLVED (iOS `lensPosition` committed; per-device diopter calibration deferred to implementation if product wants real diopter display). | ISO/exposure coupling (auto-is-contagious) documented in `CameraSettings+Apply.swift`. Focus, white balance (3 modes), zoom ratio all present. Noise reduction / edge enhancement mapping acknowledged as TBD in R-20 ("silently ignored with warning log"). GPU 5-stage color pipeline all 5 stages present in compute kernel. Resolution selection present. **Gap:** domain/03 requires focus reported in diopters; design deviates to lensPosition (0–1), documented as known deviation in D-13 / R-13 — acceptable if product accepts deviation, but is a partial against the literal spec. |
| A-04 | `domain/04-concurrency-invariants.md` | PASS | All 11 invariants mapped. Invariant 1 → Swift actor compiler enforcement. Invariant 7 → StillCaptureController actor guard-before-first-await. Invariant 9 → recovery retry logic vs full close in handleNonFatalError. Invariant 10 → ConsumerRegistry dispatch non-blocking (actor drop-on-busy). Invariant 11 → stall watchdog via `OSAtomicSomething` equivalent (last-frame timestamp). Full mapping table in `design/02-concurrency.md`. |
| A-05 | `domain/05-resource-lifecycle.md` | PASS | 6-step init order and 8-step full teardown both modeled. Session-only teardown path present. GPU resource release safety documented (`CVMetalTextureCacheFlush` on memory warning). `backgroundSuspend()` calls `session.stopRunning()` synchronously. |
| A-06 | `domain/06-error-and-recovery.md` | PASS | All fatal errors covered (PERMISSION_DENIED, MAX_RETRIES_EXCEEDED, RECORDING_START_FAILED, RECORDING_FAILED). Exponential backoff (500ms/1s/2s/4s/8s/8s+) present. Non-fatal → recovery path (5-retry cap). Domain/iOS handling mapping table in `07-ios-specific-risks.md` enumerates every domain edge case. Self-healing for CAMERA_IN_USE via KVO (Phase 6). |
| A-07 | `domain/07-performance-budgets.md` | PASS | 30fps target. 8ms GPU fence budget. 3s/5s stall thresholds. 15fps degradation threshold (3-heartbeat monitor). ~49.5 MB frame buffer acknowledged. Frame budget table in `03-metal-pipeline.md` shows 33.33ms total budget with per-stage allocations. |
| A-08 | `domain/08-capture-and-recording.md` | PARTIAL — **[DEFERRED]** to Phase 5 implementation by product decision. `domain/12-unresolved.md §U-09` rewritten as PARTIALLY RESOLVED (API + key settled; JSON schema defined during Phase 5 by comparing exact fields written by Android source). Recording is now **video-only** (no audio track) per product decision; Phase 5 file tree no longer includes `AudioSyncHandler.swift`. | ISP JPEG + GPU-processed capture both designed. EXIF fields documented in `EXIFWriter.swift` reference. HEVC preferred / H.264 fallback. 50 Mbps default. MP4 container. Recording state machine (IDLE→PREPARING→RECORDING→STOPPING→IDLE) modeled. **Gap:** EXIF user comment JSON schema under `"CamPlugin/v1"` key is explicitly deferred (R-17, NEEDS INVESTIGATION item 5) — schema undefined at design time. Minor gap, acceptable for design phase. |
| A-09 | `domain/09-ui-behaviors.md` | PASS | Split-screen with natural left, processed right. Bottom bar with 5 controls. Expanded bar. Color calibration sidebar. Recording indicator (MM:SS). Capture banner. State-driven UI (8 session states → UI variants). Landscape-only. All SwiftUI components listed in module layout. |
| A-10 | `domain/10-api-contract.md` | PASS | All 7 data types mapped (Size, CameraSettings with Optional fields, ProcessingParameters, SessionCapabilities, SessionState, ErrorCode, FrameResult, RgbSample). All 16 host methods mapped in Phase 5/6 coverage table. All 4 callbacks (onStateChanged, onError, onFrameResult, onEdgeDetectionResult) mapped. `nil` semantics preserved via Swift `Optional`. |
| A-11 | `domain/11-what-not-to-port.md` | PASS | All 21 items confirmed absent in `07-ios-specific-risks.md` "Domain/11 Confirmation of Absence" table. Specifically: no JNI, no Pigeon, no Handler/Looper, no OpenGL ES, no Android codec name strings, no libjpeg-turbo, no fpng, no UV rotation matrix, no GTest. |
| A-12 | `domain/12-unresolved.md` | PASS | All 17 unresolved items addressed. U-12 (front camera) → not in scope. U-13 (natural = display-only, no consumer path) → ConsumerRole enum has no Natural entry. U-15 (480px tracker) → formula preserved. U-17 (single session) → enforced by `CameraEngine.open()` guard. Remaining items documented in NEEDS INVESTIGATION section of `07-ios-specific-risks.md`. |

**Category A verdict: YELLOW → GREEN (post-patch)** — 10 PASS, 2 PARTIAL both DEFERRED by product decision to implementation time. No FAIL.

---

## Category B — Design Completeness

Is the design complete enough to hand to an implementer?

| # | Item | Verdict | Notes |
|---|---|---|---|
| B-01 | All 6 phases have concrete file trees with real filenames (no placeholders) | PASS | `design/05-implementation-phases.md` has per-phase file trees naming every `.swift`, `.hpp`, `.cpp`, `.mm`, `.metal` file. Phase gate criteria are testable. |
| B-02 | Every design decision has alternatives considered and a reversibility assessment | PASS | `design/06-decisions-log.md` has 15 decisions (D-01 through D-15). Each entry lists alternatives considered, chosen rationale, and explicit reversibility assessment. |
| B-03 | All significant iOS-specific risks are documented with mitigations | PASS | `design/07-ios-specific-risks.md` has 27 risk entries (R-01 through R-27), a domain edge-case mapping table covering every entry from domain/06, a domain/11 absence confirmation table, and a NEEDS INVESTIGATION section. |
| B-04 | The design contains no audit lookups (all values sourced from domain/) | PASS | `design/08-audit-lookups.md` documents 0 audit lookups with a full table showing each value was confirmed from domain/ directly. |

**Category B verdict: GREEN** — 4/4 PASS.

---

## Category C — OpenCV Edge Detection

Does the design correctly specify the OpenCV integration?

| # | Item | Verdict | Notes |
|---|---|---|---|
| C-01 | Zero-copy CVPixelBuffer handoff to ObjC++ bridge specified | PASS | `design/04-opencv-integration.md` shows `CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly)` → `CVPixelBufferGetBaseAddress` → `cv::Mat` wrapping the same memory — no copy. `CVBufferRetain` before dispatch, `CVBufferRelease` after `onFrame()` returns. Correct. |
| C-02 | `cv::Canny` is specifically called (not a different edge detector) | PASS | `EdgeDetectionBridge.processFrame` explicitly calls `cv::Canny(gray, edges, _lowThreshold, _highThreshold)`. Thresholds settable from Swift via `-setLowThreshold:highThreshold:`. |
| C-03 | **Correct OpenCV color conversion constant** for Metal output format | **FAIL → [PATCHED]** | `design/04-opencv-integration.md` line 242: was `cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY)`. Metal outputs `BGRA8Unorm` (design decision D-14, `03-metal-pipeline.md` texture spec table). **Patch applied:** changed to `cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY)`; `cv::Mat` variable renamed `rgba` → `bgra`; added a multi-line comment explaining why `COLOR_RGBA2GRAY` is wrong for Metal output. Verified via `grep COLOR_RGBA2GRAY design/` — only remaining match is the negative warning comment. |
| C-04 | `cv::findContours` present to produce Sendable result type | PASS | `cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE)` present. `RETR_EXTERNAL` retrieves only outermost contours — appropriate for edge overlay use case. |
| C-05 | Phase 3 file tree lists all required ObjC++ bridge files | PASS | Phase 3 file tree includes `IFrameConsumer.hpp`, `EdgeDetectionConsumer.hpp`, `EdgeDetectionConsumer.cpp`, `EdgeDetectionBridge.h`, `EdgeDetectionBridge.mm`, `EdgeDetectionResult.swift`. Complete. |
| C-06 | `EdgeDetectionResult` is `Sendable` and crosses the actor boundary safely | PASS | `EdgeDetectionResult` is a Swift struct with all `Sendable` fields (UInt64, [EdgeContour], Double, Int64). `EdgeContour` contains `[EdgePoint]`; `EdgePoint` has Int32 x/y. All `Sendable`. Thread transition chain (consumer thread → @MLProcessor → @MainActor) is long but correct. |
| C-07 | OpenCV xcframework distribution choice documented with alternatives | PASS | D-05 in `design/06-decisions-log.md` documents CocoaPods, SPM, and source build as alternatives. xcframework chosen for official signing and no build-time toolchain dependency. |

**Category C verdict: RED → GREEN (post-patch)** — 6/7 PASS, 1 **PATCHED** (C-03: `cv::COLOR_BGRA2GRAY`). Patch applied to `design/04-opencv-integration.md`; silent correctness bug eliminated before any implementation work began.

---

## Category D — Quality Checks

| # | Item | Verdict | Notes |
|---|---|---|---|
| D-01 | No Android-specific API names remain in the design | PASS | Searched design files: no `DispatchQueue` misuse as Android analog, no `Handler`, `Looper`, `JNI`, `Pigeon`, `SharedPreferences`, `MediaStore`, `OpenGL`, `GLSurfaceView`, `SurfaceTexture`, `EGL`. All iOS-native APIs used throughout. |
| D-02 | Zero audit lookups | PASS | `design/08-audit-lookups.md` confirms 0 lookups. The design derives all values from domain/ files and iOS SDK knowledge. |
| D-03 | Internal cross-references are consistent | PASS | D-03 in decisions log references `03-metal-pipeline.md §GPU-to-Encoder Path` — section exists. R-07 references ObjC++ bridge strategy — present in `04-opencv-integration.md`. D-06 references `04-opencv-integration.md` for contour decision — confirmed. Phase numbers referenced in risk register (R-01: "Phase 1a, 4") match phase structure. |
| D-04 | No orphaned requirements | PASS | Domain/12 unresolved items all addressed or deferred with explicit rationale. No domain requirement found that has no design counterpart. |

**Category D verdict: GREEN** — 4/4 PASS.

---

## Pass 1 Summary

| Category | Items | GREEN | YELLOW | RED |
|---|---|---|---|---|
| A — Requirements Coverage | 12 | 10 | 2 | 0 |
| B — Design Completeness | 4 | 4 | 0 | 0 |
| C — OpenCV Edge Detection | 7 | 6 | 0 | 1 |
| D — Quality Checks | 4 | 4 | 0 | 0 |
| **Total** | **27** | **24** | **2** | **1** |

### Pre-Review Patch Verification

| Pre-review finding | Patched? | Evidence |
|---|---|---|
| C-01: GPU-to-encoder not zero-copy | YES | `03-metal-pipeline.md` §GPU-to-Encoder Path has complete IOSurface-backed pool with `kCVPixelBufferIOSurfacePropertiesKey` and `MTLBlitCommandEncoder` GPU blit. `MTLTexture.getBytes` explicitly forbidden. |
| C-02: ConsumerRegistry struct copy bug | YES | `dispatch()` writes `consumers[role] = entry` in both the busy path (pending overwrite) and the idle path (before queue dispatch). |
| C-03: MetalRenderer texture slot race | YES | `OSAllocatedUnfairLock<MTLTexture?>` specified in both `01-architecture.md` and `02-concurrency.md`. |
| H-01: CMSampleBuffer crosses actor boundary | YES | `IncomingFrame: @unchecked Sendable` wrapper with `CVPixelBuffer` extracted pre-boundary specified in `02-concurrency.md`. |

### Correctness Verdict (as of Agent 4 review)

**YELLOW**

One hard correctness failure (C-03: wrong OpenCV color constant) is present. This is a new finding not from the pre-review; it will cause silently incorrect edge detection. The two Category A partials (diopter convention and EXIF schema) are documented deviations acceptable at design phase. All four pre-review critical findings are confirmed patched.

### Post-Patch Correctness Verdict

**GREEN**

C-03 has been patched (`COLOR_BGRA2GRAY` + variable rename + warning comment in `design/04-opencv-integration.md`). The two Category A partials (A-03 diopter, A-08 EXIF JSON schema) are product-accepted deviations captured in `domain/12-unresolved.md §U-09, §U-11` — neither is a design defect. Zero FAIL items remain in the design; zero items need further design action before implementation.
