# 01 — Correctness Check (Pass 1)

**Mental model:** Does this design do everything the domain requires? Is nothing missed?

Merged from two independent Agent-4 runs (Sonnet + Opus). Each item gets
**pass / fail / partial** with a specific design-section reference. Pass-2 attacks
are in `02-adversarial-red-team.md`.

---

## Category A — Requirements Coverage

| # | Domain file | Verdict | Addressed in | Notes |
|---|---|---|---|---|
| A-01 | `domain-revised/01-system-purpose.md` | **Pass** | `design/01` §1, §3; `design/README.md` domain coverage table | Both missions explicit (frame delivery via FrameSet, camera control via engine actor). Single-session + back-facing-main-lens constraint codified in `open()` per D-01. All 7 key invariants mapped. |
| A-02 | `domain-revised/02-frame-delivery.md` | **Partial** | `design/03` §2 / §4 / §5 / §8; `design/01` §4 | 30 fps, YUV capture, 10-step pipeline, RGBA16F, three subscribable streams, 480 px tracker, drop-on-busy, FrameResult 3 Hz heartbeat, dual stall watchdogs — all present. **Three gaps:** (a) FrameSet `CaptureMetadata` (ADR-18) omits the four per-frame convergence-state fields the domain §02 metadata table requires (`aeState`, `afState`, `awbState`, `flashState`) — C++ consumers reading convergence get silent zeros; (b) `sampleCenterPatch` (domain §02, 96 × 96 GPU sampling with trimmed-mean reduction) has no concrete design section — no Metal kernel, no readback path, no frame-clock hook; (c) FrameSet publication timing is inconsistent across files — `design/01` §4 and `ios-platform-guide/01` place publication in `addCompletedHandler`, while `design/02` §2/§3 pseudocode places it inline on `deliveryQueue` after `commit()` but before GPU completion. Pass-2 AT-01 details the correctness impact. |
| A-03 | `domain-revised/03-camera-control.md` | **Pass** | `design/02` §4; `design/05` Phase 1b | All 6 controls + GPU color params designed. ISO/exposure coupled via `setExposureModeCustom(duration:iso:)`. `SETTINGS_CONFLICT` before first readback (Rule 3). WB gains clamped per G-10. GPU color chain in required order. Settings persistence via UserDefaults. |
| A-04 | `domain-revised/04-concurrency-invariants.md` | **Partial** | `design/02` §6 invariant → iOS mechanism table | All 12 invariants mapped. Compile-time enforcement is genuine for invariants 1/2/3/7/8/10. Invariants 4, 6, 11 rely on a mix of mechanisms (ARC + `Unmanaged` + C++ flag for 4; same-queue writer + coherence for 6; acquire/release atomic for 11) — correct in substance. Invariant 6 is specifically underspecified: the design says "MTLBuffer single-writer via deliveryQueue" but does not specify double-buffered uniform slots or `setBytes` — see Pass-2 AT-06. |
| A-05 | `domain-revised/05-resource-lifecycle.md` | **Partial** | `design/02` §5 state machine; `design/05` Phase 1a; `design/07` R-06/R-19/R-20 | Background drain, device-retain-across-pause, self-healing all good. **Two gaps:** (a) the explicit 7-step full teardown order (domain §05) is not enumerated in any design section — state machine and risk table reference it implicitly, but an implementer could release the GPU pipeline before stopping an active recording and not know the ordering is wrong; (b) the preview-surface rebind mechanism (3 consecutive swap-failure trigger, replace MTKView drawable without session teardown — domain §05) has no concrete design — no phase file, no Metal code sketch, no state-machine entry. |
| A-06 | `domain-revised/06-error-and-recovery.md` | **Pass** | `design/07` §"Domain Edge-Case Mapping"; `design/02` §5 | All 19 error codes mapped 1:1. Exponential backoff 500/1000/2000/4000/8000 ms + 5-retry cap. Recovery sequence complete. HAL threshold = 5. Dual watchdogs (3 s informational, 5 s recovery). Self-heal for `CAMERA_IN_USE`. |
| A-07 | `domain-revised/07-performance-budgets.md` | **Pass** | `design/03` §8 | Domain 07 is mostly stub. Design adds 30-fps sub-budget buckets (≤15 ms / 15–25 ms / >25 ms) and Instruments strategy. |
| A-08 | `domain-revised/08-capture-and-recording.md` | **Partial** | `design/05` Phase 5; `design/03` Pass 5 / Pass 6; `design/07` R-06, R-15 | Still capture via Metal readback from `processedTex`, 8-bit TIFF via `CGImageDestination`, EXIF with `CamPlugin/v1` JSON, HEVC 8-bit via `AVAssetWriter` + NV12 IOSurface pool, no audio, 5 s drain deadline, in-flight-capture atomic. **One gap:** the `startRecording` return-value format `<uri>|<displayName>` (domain §10, first-`|` split rule) is not specified in Phase 5 design — the domain API contract constrains callers to parse this exact format. |
| A-09 | `domain-revised/09-ui-behaviors.md` | **Partial** | `design/05` Phase 1a + Phase 6; `design/01` §2 | Split-screen preview, bottom bar, expanded controls, color sidebar, recording indicator, capture banner, state-driven UI, landscape-right lock, 3 Hz FrameResult — all present. **One gap:** the domain §09 debug-build log-level control has no placement in any phase file tree or acceptance criterion. Low severity (developer tool only). |
| A-10 | `domain-revised/10-api-contract.md` | **Partial** | `design/05` Phase 6 + Phase 1a/1b; `design/01` §3; `design/04` §2 | All 16 host methods and 4 callbacks mapped to async engine surface + `AsyncStream` paths. Consumer registration via `engine.attach(consumer:, to: StreamId)`. Sendable POD data types modeled. **Three gaps:** (a) `sampleCenterPatch` Metal implementation missing (same as A-02b); (b) `SessionCapabilities.previewTextureId` / `.naturalTextureId` have no iOS equivalent — Flutter's texture-registry integer ID doesn't map cleanly to `MTKView` or `CVPixelBuffer` under SwiftUI; the design does not specify what these fields return (or whether they are preserved at all); (c) `setCropRegion` validation (crop must fit within capture resolution, reject with `INVALID_STATE`) is not in Phase 6 — Phase 6 only notes "commits new crop uniforms on next frame". |
| A-11 | `domain-revised/11-what-not-to-port.md` | **Pass** | `design/06` D-01…D-09; `design/07` R-08; `design/README` | Every Android mechanism replaced with a native iOS primitive or deliberately excluded. OpenCV confirmed as new iOS capability. Audio absent end-to-end. No Android API name surfaces in `design/`. |
| A-12 | `domain-revised/12-unresolved.md` | **Pass** | `design/07` R-13 / R-14 / R-17; `design/05` Phase 1a / 1b / 5 | U-08, U-09, U-11, U-16, U-18 all assigned to phases or flagged as accepted risk. |

**Category A summary:** 7 pass, 0 fail, 5 partial.

---

## Category B — Design Completeness

| # | Check | Verdict | Evidence |
|---|---|---|---|
| B-01 | Every phase in `design/05` has a concrete file tree | **Partial** | Phases 1a/1b/2/3/4/5 list real file paths; Phase 6 legitimately lists modifications-only. Phase 2 does not include `CenterPatchKernel.metal` or any file realizing the `sampleCenterPatch` host method referenced from Phase 1b ("requires Phase 2 sampleCenterPatch"). |
| B-02 | Every phase has testable acceptance criteria | **Pass** | All six phases list empirically checkable bullets. |
| B-03 | Every decision in `design/06` has ≥ 1 alternative considered | **Pass** | D-01 through D-09 each list 2–3 alternatives plus the "follow ADR-## as written" baseline. |
| B-04 | `design/08-audit-lookups.md` exists and is plausibly complete | **Pass** | 0 entries, explicit justification. Far below the 10-entry yellow flag. |
| B-05 | `design/07-ios-specific-risks.md` has required entries | **Partial** | Thermal / pressure / permission / revocation / multi-app / background / App Nap + domain edge-case mapping all present. Missing: **Low Power Mode** (`ProcessInfo.isLowPowerModeEnabled` not observed anywhere); G-18 BGRA-vs-RGBA gotcha not cited (see E-04). |
| B-06 | All 8 design files exist | **Pass** | `README.md` + `01-architecture.md` through `08-audit-lookups.md` all present. |

**Category B summary:** 4 pass, 0 fail, 2 partial.

---

## Category C — OpenCV Edge Detection Verification

| # | Check | Verdict | Evidence |
|---|---|---|---|
| C-01 | Generic `PixelSink` C++ interface with method signatures + lifecycle | **Pass** | `design/04` §1: `configure` / `processFrame` / `teardown` / `drainStats`, `overwriteCount_[3]`, all `noexcept`, `SWIFT_SHARED_REFERENCE` for ARC import. |
| C-02 | Edge-detection consumer concretely designed | **Pass** | `design/04` §5–§8: specific OpenCV calls (`cv::cvtColor`, `cv::Canny`, `cv::resize`); explicit thread transitions; Canny 2–4 ms budget at 480 p on A16; exception translation. |
| C-03 | Edge-detection consumer in Phase 3 file tree | **Pass** | `EdgeDetectionConsumer.{h,cpp}` + `CannyPreviewView` + `SharedTextureAllocator` + `MipmapBlitHelper` + `CannyPanZoom.metal` + `WriteCompleteCallback.h` all present. |
| C-04 | OpenCV framework integration with justification | **Pass** | `design/06` D-04: pinned SPM `.binaryTarget` / `.xcframework`. Alternatives (CocoaPods, source build, vendored submodule) considered and rejected with rationale. |
| C-05 | Zero-copy handoff with exact API calls | **Partial** | Input path is zero-copy (`IOSurfaceLock` / `CVPixelBufferLockBaseAddress` → `cv::Mat(…, base, stride)` → unlock). **But the composite path in §6 is not zero-copy**: `cv::resize` allocates `edgesFull`, and `compositeHalfFloat` does a full-res RGBA16F memcpy from processed base into the shared surface every frame (~15 MB at default crop). The §5 header promises zero-copy; the §6 body is one memcpy per frame. |
| C-06 | Result return path to SwiftUI designed | **Partial** | Two shapes per `design/01` §5 and D-07: rendering consumers use shared IOSurface-backed `MTLTexture`; data consumers use Sendable structs via `AsyncStream`. Both match ADR-13 intent. **But the write-complete callback code in §6 violates Swift 6 strict concurrency** — accesses actor-isolated `CameraEngine` properties from `Task.detached` without `await`, and uses a `DispatchQueue.submit(…)` method that does not exist. See Pass-2 AT-05. |

**Category C summary:** 4 pass, 0 fail, 2 partial.

---

## Category D — Quality Checks

| # | Check | Verdict | Evidence |
|---|---|---|---|
| D-01 | No Android API names anywhere in `design/` | **Pass** | 0 hits for `Camera2`, `HandlerThread`, `CameraCaptureSession`, `CaptureRequest`, `SurfaceTexture`, `AHardwareBuffer`, `ImageReader`, `MediaRecorder`, `EGLContext`, `EGLSurface`, `Looper`, `backgroundHandler`, `mainHandler`. All `Handler` substring matches are iOS/Swift identifiers. |
| D-02 | `design/08-audit-lookups.md` not over-consulted | **Pass** | 0 entries. |
| D-03 | Cross-references consistent | **Partial** | Spot-checks on R-## / D-## / ADR-## cross-references all land correctly. **But** ADR-03 in `ios-platform-guide/01` states "processedTex has no display MTKView"; `design/01` §4 Pass 3b and `design/05` Phase 2 add a `processedMTKView` display blit. The deviation is **correct** (domain §09 mandates the split-screen), but it is undocumented in `design/06-decisions-log.md` — an implementer reading ADR-03 alone would build only the natural display path. See E-03. |

**Category D summary:** 2 pass, 0 fail, 1 partial.

---

## Category E — Platform-Guide Compliance

| # | Check | Verdict | Evidence |
|---|---|---|---|
| E-01 | ADR citation coverage: every `design/0[1-7]-*.md` cites ≥ 1 ADR | **Pass** | Counts: 35 / 24 / 32 / 22 / 30 / 10 / 17. |
| E-02 | ADR claim verification: cited ADRs match actual design | **Pass** | Spot-checks verify ADR-02, ADR-13, ADR-06 (compute not blit), ADR-04, ADR-09, ADR-16, ADR-18/19/20 are all honored in the design text, not just cited by ID. |
| E-03 | Deviations are documented | **Fail** | `design/01` §2/§4 and `design/05` Phase 2 introduce a `processedMTKView` display path. ADR-03 in `ios-platform-guide/01` explicitly states "processedTex has no display MTKView — it feeds recording, still capture, and the async consumer subscription system only." The design's deviation is necessary (domain §09 requires the split-screen preview), but no `D-##` entry in `design/06-decisions-log.md` records the deviation. Per review rules, silent ADR deviation is a fail — even when the behavior is correct, the rationale and reversibility must be logged. |
| E-04 | Gotcha coverage | **Partial** | Covered: G-01, G-02, G-03, G-04, **G-05**, G-07, **G-08**, G-10, G-11, G-12 / G-24, G-13, G-14, G-15, G-16, G-17 / G-22, **G-19**, **G-20**, **G-21**, G-23, G-25, G-26. **Missing:** G-06 (stop-on-interruption race) and G-18 (BGRA-vs-RGBA channel-order silent-bug). Substance of G-18 is right (pipeline is RGBA16F end-to-end with correct BT.709 weights), but a single-line citation would prevent a future editor from introducing a BGRA shortcut unseen. |
| E-05 | No forbidden patterns | **Pass** | `MTLTexture.getBytes` and `.mm` appear only in prohibition text. `AVCaptureSession()` constructor only appears as R-19's not-this anti-pattern. `viewWillAppear` has no session-construction use. No synchronous C++ call from the capture delegate. |

**Category E summary:** 3 pass, 1 fail, 1 partial.

---

## Summary Table

| Category | Items checked | Passed | Failed | Partial |
|---|---|---|---|---|
| A — Requirements Coverage | 12 | 7 | 0 | 5 |
| B — Design Completeness | 6 | 4 | 0 | 2 |
| C — OpenCV Edge Detection | 6 | 4 | 0 | 2 |
| D — Quality Checks | 3 | 2 | 0 | 1 |
| E — Platform-Guide Compliance | 5 | 3 | 1 | 1 |
| **Total** | **32** | **20** | **1** | **11** |

---

## Correctness Pass Verdict: **Yellow**

Reasoning per the review rubric:

- **Not Red:** no Category C item fails; no Category A fail in the core-mission files (01 / 02 / 04 / 05); no forbidden-pattern violation; only one silent ADR deviation in Category E (the rubric requires 2+ deviations or other Red-class failures).
- **Not Green:** one E-03 fail (silent ADR-03 deviation — `processedMTKView` is undocumented in the decisions log) + eleven partials clustered on real implementation gaps (FrameSet metadata fields, `sampleCenterPatch` not designed, teardown ordering not enumerated, surface-rebind not designed, output-URI format unspecified, `previewTextureId` gap, Low Power Mode missing, G-18 gotcha missing, composite step not zero-copy, Swift-6 callback compile error).
- **Yellow** matches "1–2 silent ADR deviations" + "some partials, no critical failures" per the rubric.

Route the fixes to `design/` (re-run Agent 3 once with Pass 1 + Pass 2 findings as
combined context). None require changes to `domain-revised/` or
`ios-platform-guide/`.
