# 12 — Unresolved

This file collects:
1. **UNCLEAR** — items the audit is ambiguous or silent on, requiring downstream architect attention
2. **TARGET-PLATFORM-SPECIFIC CONCERNS** — items that cannot be specified here because they depend on the target platform

Items are numbered for cross-reference. Downstream architect should resolve each before finalizing the design.

---

## U-01: Camera Permission Flow and Denial Recovery

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit documents a `PERMISSION_DENIED` error code and that the system receives a `SecurityException` on some devices after keyguard dismiss (treated non-fatally). However, permission flows — how and when the system requests camera access, how it detects denial, and how it recovers — are entirely platform-specific.

**For downstream architect:** Define the permission request lifecycle for the target platform. Determine whether the equivalent of the keyguard-dismiss bug exists on the target platform, and if so, what its observable form is. Determine whether permission can be revoked mid-session and how the system should respond.

[audit: 08-error-recovery.md, 04-pigeon-api.md §CamErrorCode]

---

## U-02: GPU API and Frame Delivery Mechanism

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes a GPU pipeline that receives camera frames via a hardware texture binding (the camera delivers directly to a GPU texture), renders to multiple output targets (preview, encoder, natural, tracker), and reads back processed frames via an asynchronous double-buffered readback mechanism. The specific GPU API is OpenGL ES.

**For downstream architect:** The target platform likely has a different GPU API (Metal on Apple platforms, Vulkan on some others). The behavioral requirements — asynchronous readback, multiple render targets, zero-copy camera-to-GPU delivery — are specified in `02-frame-delivery.md`. Determine the GPU API surface available on the target platform and how camera frames are delivered to the GPU. Specifically: can camera frames be delivered directly to a GPU texture without CPU involvement?

[audit: 03-capture-pipeline.md, 05-gpu-opengl.md]

---

## U-03: Encoder Surface / GPU-to-Encoder Zero-Copy

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes a mechanism where the GPU renders directly to the video encoder's input surface via GPU buffer presentation — no CPU YUV copy. This is specific to the Android GPU-to-encoder integration path and is not universally available on all platforms.

**For downstream architect:** Determine whether the target platform supports GPU-to-encoder zero-copy. If not, a CPU blit path will be needed. This has significant performance implications for recording frame rates. This is a key architectural decision for `08-capture-and-recording.md`.

[audit: 10-capture-recording.md §Video Recording, 03-capture-pipeline.md §GpuPipeline Frame Sequence]

---

## U-04: Preview Texture Integration with UI Framework

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes a "Flutter Texture registry" system where the GPU renders to a platform-provided surface that is mapped to a UI texture ID. The UI layer renders this texture ID in a widget without any CPU frame transfer.

**For downstream architect:** The target platform and UI framework will have a different mechanism for displaying GPU-rendered content in a UI component. Determine the equivalent of the Flutter Texture registry on the target platform. This affects how `02-frame-delivery.md` §Preview Surface Delivery is implemented.

[audit: 03-capture-pipeline.md §GpuPipeline, 04-pigeon-api.md §CamCapabilities]

---

## U-05: Thermal Throttling and System Pressure

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit does not describe any thermal throttling or system pressure handling. The FPS degradation notification (`FPS_DEGRADED` below 15fps for 3 consecutive samples) is a proxy for detecting hardware-induced frame rate drops, but the root cause is not addressed.

**For downstream architect:** The target platform may have explicit thermal/system-pressure APIs. Determine whether the system should observe these APIs and respond proactively (e.g., reduce resolution or frame rate before FPS degrades). The `FPS_DEGRADED` notification semantics are specified in `06-error-and-recovery.md`.

[audit: 08-error-recovery.md §FPS Degradation]

---

## U-06: Actor Isolation and Concurrency Model

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes a thread-based concurrency model with explicit locks and a documented lock ordering. The domain requirements (`04-concurrency-invariants.md`) describe the invariants behaviorally, but the implementation mechanism is unspecified.

**For downstream architect:** The target platform may support structured concurrency models (Swift actors, async/await, etc.) that provide stronger isolation guarantees than explicit locking. Determine whether the lock ordering documented in `04-concurrency-invariants.md` can be enforced structurally (via actor isolation) or requires explicit locks on the target platform.

[audit: 02-threading-model.md §Lock Ordering]

---

## U-07: Background Suspension Definition

**Type:** UNCLEAR

The audit states that the system releases the camera when the app transitions to "fully invisible" (as opposed to partially occluded). The distinction matters for determining when to call `backgroundSuspend()` vs. doing nothing.

**For downstream architect:** The target platform's app lifecycle events may not have a clean "fully invisible" signal equivalent to Android's `onStop`. Clarify how "fully invisible" maps to the target platform's lifecycle. The behavioral requirement is in `05-resource-lifecycle.md`.

[audit: 07-state-machine.md §Background Suspend/Resume, 12-git-archaeology.md]

---

## U-08: Supported Camera Resolutions and Capability Discovery

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN (rationale partially resolved)

The audit describes resolution discovery via a camera stream configuration map. The system selects the largest 4:3 YUV resolution and falls back to 1280×960 if none is found. Resolution negotiation is also exposed via `setResolution()`.

**Resolved (rationale):** 4:3 is the native aspect ratio of the image sensor on the target hardware (on both source and target platforms). The maximum sensor resolution is approximately 4000×3000 px. Selecting the largest 4:3 resolution therefore maps directly to "use the sensor's native full resolution." This is a hardware constraint, not an arbitrary product choice. Downstream design should preserve the largest-4:3 selection rule and treat any non-4:3 fallback as a degraded path.

**Still for downstream architect:** Determine the target platform's mechanism for discovering supported camera resolutions and formats. The behavioral requirements (prefer largest 4:3, fallback to 1280×960, expose list via `open()` capabilities response) are in `01-system-purpose.md` and `03-camera-control.md`.

[audit: 03-capture-pipeline.md §stream-configuration, 04-pigeon-api.md §CamCapabilities]

---

## U-09: EXIF Metadata on Target Platform

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes writing EXIF metadata to still images after encoding, including standard tags (ISO, exposure, focus, white balance) and non-standard fields serialized as JSON in `TAG_USER_COMMENT`.

**For downstream architect:** Determine the target platform's EXIF writing APIs. The behavioral requirement — that EXIF is written with sensor metadata — is in `08-capture-and-recording.md`. The specific JSON structure in `TAG_USER_COMMENT` should be preserved for interoperability if the images are consumed by other tools expecting this format.

[audit: 10-capture-recording.md §EXIF Orientation, §Still Capture: captureImage]

---

## U-10: Camera Orientation and Sensor Mounting Angle

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The audit describes a 90° clockwise UV rotation applied to normalize the camera's physical sensor orientation. This is specific to the Android test device's sensor mounting. The exact rotation needed depends on the physical camera hardware and display orientation conventions.

**For downstream architect:** Determine the sensor mounting orientation of the target camera hardware and what coordinate transformation (if any) is needed. The behavioral requirement — that the preview is displayed with correct orientation — is in `09-ui-behaviors.md`. Do not assume 90° CW is correct for the target device.

[audit: 03-capture-pipeline.md §GpuPipeline, 05-gpu-opengl.md]

---

## U-11: Manual Focus Infinity Distance Convention

**Type:** UNCLEAR / TARGET-PLATFORM-SPECIFIC CONCERN

The audit states that focus distance 0.0 diopters means "optical infinity" in the Android camera hardware abstraction layer. This inverse-distance convention (diopters = 1/meters) is specific to that camera API.

**For downstream architect:** Confirm that the API contract (see `10-api-contract.md`) preserving this diopter convention makes sense on the target platform. If the target platform uses a different convention (e.g., normalized 0.0–1.0, or direct meters), the API contract may need adjustment.

[audit: 04-pigeon-api.md §CamSettings, 09-camera-controls.md]

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

## U-14: GL Timer Query Extension Fallback

**Type:** TARGET-PLATFORM-SPECIFIC CONCERN

The GPU renderer checks for a timing query extension at runtime and enables per-frame GPU timing measurements only when the extension is present.

**For downstream architect:** The target platform's GPU API may have different profiling capabilities. The behavioral requirement — that the system can optionally measure per-frame GPU render time for diagnostics — is in `07-performance-budgets.md`. Determine the equivalent profiling mechanism on the target platform, if any.

[audit: 05-gpu-opengl.md §GL Extension Check]

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

**Type:** UNCLEAR

The audit describes two different auto-exposure frame rate range policies: preview prefers a fixed (lower == upper) range for stable frame rate; recording uses `[targetFps/2, targetFps]` to allow AE to slow in dark scenes. The audit does not document what happens if no matching range is available for recording.

**For downstream architect:** The target platform's AE frame rate control may work differently. The behavioral requirement — that recording mode allows AE to reduce frame rate in dark scenes while capping the upper bound at the configured encoder fps — is in `03-camera-control.md`. Clarify whether the `[targetFps/2, targetFps]` range is a fixed policy or should be tunable.

[audit: 03-capture-pipeline.md §Repeating Request, 09-camera-controls.md §AE FPS Range Selection]

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
