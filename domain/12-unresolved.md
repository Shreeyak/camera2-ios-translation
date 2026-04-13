# 12 — Unresolved

This file collects:
1. **UNCLEAR** — items the audit is ambiguous or silent on, requiring downstream architect attention
2. **TARGET-PLATFORM-SPECIFIC CONCERNS** — items that cannot be specified here because they depend on the target platform

Items are numbered for cross-reference. Downstream architect should resolve each before finalizing the design.

---

## U-01: [Camera Permission Flow and Denial Recovery] → RESOLVED in design/ — see design/02-concurrency.md §iOS-Specific Concurrency States (Permission State) and design/07-ios-specific-risks.md R-03, R-04

---

## U-02: [GPU API and Frame Delivery Mechanism] → RESOLVED in design/ — see design/03-metal-pipeline.md §Zero-Copy Bridge (CVMetalTextureCache, CVPixelBuffer → MTLTexture without CPU copy) and §Texture Specification (R8Unorm Y plane, RG8Unorm CbCr plane, double-buffered MTLBuffer readback)

---

## U-03: [Encoder Surface / GPU-to-Encoder Zero-Copy] → RESOLVED in design/ — see design/03-metal-pipeline.md §GPU-to-Encoder Path (IOSurface-backed CVPixelBufferPool with kCVPixelBufferMetalCompatibilityKey; MTLBlitCommandEncoder GPU-local blit; VideoToolbox maps same IOSurface — no CPU copy) and design/06-decisions-log.md D-03

---

## U-04: [Preview Texture Integration with UI Framework] → RESOLVED in design/ — see design/01-architecture.md §Layer 2 (MTKView via UIViewRepresentable; two instances: MetalViewWrapper for processed stream, NaturalMetalViewWrapper for natural stream; OSAllocatedUnfairLock protects shared texture slot; no CPU pixel transfer) and design/06-decisions-log.md D-07

---

## U-05: [Thermal Throttling and System Pressure] → RESOLVED in design/ — see design/02-concurrency.md §Thermal State Integration (ProcessInfo.thermalStateDidChangeNotification: nominal/fair = restore, serious = 15fps cap, critical = full suspend) and design/07-ios-specific-risks.md R-01, R-02 (AVCaptureDevice.systemPressureState KVO)

---

## U-06: [Actor Isolation and Concurrency Model] → RESOLVED in design/ — see design/02-concurrency.md §Domain Invariant Mapping (all 11 invariants mapped to named Swift mechanisms: CameraEngine actor for session/state serialization, @MainActor for UI, OSAllocatedUnfairLock for nonisolated renderer texture slot, AsyncStream for back-pressure) and design/06-decisions-log.md D-01

---

## U-07: [Background Suspension Definition] → RESOLVED in design/ — see design/02-concurrency.md §App Lifecycle (scenePhase == .background is the trigger; .inactive explicitly does NOT trigger suspend — validated against Control Center and notification banner overlays) and design/06-decisions-log.md D-08

---

## U-08: Supported Camera Resolutions and Capability Discovery

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN (rationale partially resolved)

The audit describes resolution discovery via a camera stream configuration map. The system selects the largest 4:3 YUV resolution and falls back to 1280×960 if none is found. Resolution negotiation is also exposed via `setResolution()`.

**Resolved (rationale):** 4:3 is the native aspect ratio of the image sensor on the target hardware (on both source and target platforms). The maximum sensor resolution is approximately 4000×3000 px. Selecting the largest 4:3 resolution therefore maps directly to "use the sensor's native full resolution." This is a hardware constraint, not an arbitrary product choice. Downstream design should preserve the largest-4:3 selection rule and treat any non-4:3 fallback as a degraded path.

**Still for downstream architect:** Determine the target platform's mechanism for discovering supported camera resolutions and formats. The behavioral requirements (prefer largest 4:3, fallback to 1280×960, expose list via `open()` capabilities response) are in `01-system-purpose.md` and `03-camera-control.md`.

[audit: 03-capture-pipeline.md §stream-configuration, 04-pigeon-api.md §CamCapabilities]

---

## U-09: EXIF Metadata on Target Platform

**Type:** PARTIALLY RESOLVED

**Settled:** The iOS EXIF writing API is `CGImageDestination` with `CGImageDestinationAddImageFromSource`. Standard sensor tags (ISO, exposure, focus, white balance) are written via `kCGImagePropertyExifDictionary`. Non-standard fields are serialized as a JSON string under `kCGImagePropertyExifUserComment` using the key `"CamPlugin/v1"` — preserving interoperability with any tool consuming the Android format. Implementation lives in `EXIFWriter.swift` (Phase 5).

**Still open:** The specific JSON field names and schema for the `"CamPlugin/v1"` user comment object are not yet specified. This must be defined during Phase 5 implementation by comparing the exact fields written by the Android source and confirming which subset is meaningful on iOS.

[design: design/05-implementation-phases.md §Phase 5, design/07-ios-specific-risks.md R-17]

---

## U-10: [Camera Orientation and Sensor Mounting Angle] → RESOLVED in design/ — see design/03-metal-pipeline.md §Sensor Orientation (AVCaptureConnection.videoRotationAngle applied in AVFoundation layer before CVPixelBuffer reaches Metal; no manual UV rotation matrix needed) and design/06-decisions-log.md D-11 (exact angle value verified empirically during Phase 1a acceptance criteria)

---

## U-11: Manual Focus Infinity Distance Convention

**Type:** PARTIALLY RESOLVED

**Settled:** iOS uses `AVCaptureDevice.lensPosition` (normalized 0.0–1.0, where 0.0 = near, 1.0 = far/infinity) — not diopters. The design commits to this convention via D-13. The API surface field `focusDistanceDiopters` is preserved by name for cross-platform shape compatibility, but on iOS it carries the normalized `lensPosition` value. The deviation is documented as a known API contract deviation (design/07-ios-specific-risks.md R-13).

**Still open:** If the product requires displaying actual diopter values to the user (e.g., "focus at 2.5 diopters"), a per-device calibration table mapping `lensPosition` to physical distance is required. No such calibration data exists yet. This is an implementation-time concern, not a design gap.

[design: design/06-decisions-log.md D-13, design/07-ios-specific-risks.md R-13]

---

## U-12: Front-Facing Camera Mirroring and Orientation

**Type:** RESOLVED

**Resolution:** The front-facing camera is out of scope for this product. The app uses exclusively the device's back-facing main lens. Telephoto, ultra-wide, and front-facing lenses are explicitly unsupported. No front-camera mirroring logic is required in the target design. The EXIF orientation behavior that conditions on front-vs-back was defensive code inherited from a generic camera plugin; downstream design may drop the front-camera branches entirely or leave them as inert no-ops.

[audit: 10-capture-recording.md §EXIF Orientation]

---

## U-13: Natural Stream Consumer

**Type:** RESOLVED (also: terminology — "natural", not "raw")

**Terminology note:** The product's preferred term for "frames that have not passed through the GPU post-processing stage" is **natural**, not raw. "Raw" is reserved for photography RAW (Bayer-domain sensor data). The domain docs have been updated to use "natural" for API field names (`naturalTextureId`, `naturalWidth`, `naturalHeight`, `enableNaturalStream`, `naturalStreamHeight`) and for prose descriptions of the passthrough stream. The source (Android) code still uses `raw*` names — that is a source-code naming artifact and is preserved only in audit/ footnote references.

**Resolution:** The natural stream is **display-only**. It exists for the split-screen preview (left = natural, right = processed) and has no C++ consumer registration path. Downstream design should:
- Expose a natural display surface / texture identifier via `SessionCapabilities`
- Omit the natural stream from the consumer-role enumeration in the C++ pipeline API — consumers can register only for the processed full-resolution stream or the tracker (480px) stream
- Not allocate readback buffers for the natural stream beyond what the display path requires

The audit references to `SinkRole::RAW` reflect Android source-code symbols that were available structurally but not exercised by any registered consumer; downstream design is free to omit the equivalent role.

[audit: 03-capture-pipeline.md §Raw Stream Path, 06-cpp-sinks.md §SinkRole]

---

## U-14: [GL Timer Query Extension Fallback] → RESOLVED in design/ — see design/03-metal-pipeline.md §Profiling Strategy (os_signpost intervals on all pipeline stages + Metal System Trace in Instruments; no runtime extension check needed — os_signpost is always available on iOS; frame budget table with acceptable/degraded/failing thresholds defined)

---

## U-15: Tracker Resolution Height Constant

**Type:** RESOLVED

**Resolution:** 480px tracker height is a **fixed compile-time value**. It is not a runtime tunable and must not be exposed as a parameter on any public API (neither the SDK surface nor the C++ consumer registration API). Downstream design should treat 480 as a hardcoded constant.

The width-derivation formula must be preserved exactly to maintain dimension consistency with downstream ML consumers:
```
width = ((streamWidth * 480 / streamHeight) + 1) & ~1   // even-rounded
```

[audit: 03-capture-pipeline.md §Tracker Downscale]

---

## U-16: AE FPS Range Selection for Preview vs. Recording

**Type:** PARTIALLY RESOLVED

**Settled:** The iOS API is `AVCaptureDevice.activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration`. Preview mode: both set to `CMTimeMake(1, targetFps)` (fixed frame rate). Recording mode: `activeVideoMinFrameDuration = CMTimeMake(1, targetFps)` (upper bound), `activeVideoMaxFrameDuration = CMTimeMake(1, targetFps/2)` (allow AE to slow to half rate in dark scenes). This matches the domain intent. Documented in design/07-ios-specific-risks.md R-14.

**Still open:** The fallback behavior when no fixed-rate range is available for preview mode (i.e., when the device does not support the exact 30fps fixed duration) requires empirical testing on target hardware during Phase 1a. The design does not specify a fallback policy for this case.

[design: design/07-ios-specific-risks.md R-14, design/05-implementation-phases.md §Phase 1b]

---

## U-17: Session Handle Multi-Tenancy

**Type:** RESOLVED

**Resolution:** Dual-camera and multi-session operation are **not supported**. The product uses exactly one physical camera: the device's **back-facing main lens**. Telephoto, ultra-wide, and front-facing lenses are explicitly out of scope.

Downstream design requirements:
- `open()` is a single-session API. While the handle mechanism (opaque integer) should be preserved for API shape, the implementation may assume at most one active session.
- Calling `open()` while a session is already active is undefined in the source system. Downstream design may either (a) reject the call with an error, or (b) close the prior session and open the new one. The preferred behavior is (a) — fail fast — because it surfaces caller bugs.
- The controller's session-map structure visible in the audit is an implementation artifact of the generic plugin pattern it was forked from. It does not imply multi-session support.
- Camera selection by `cameraId` should be reduced in the API contract: null or a designated "back-main" identifier are the only valid values.

[audit: 04-pigeon-api.md §Handle System]
