# Open Questions

Items from `domain-revised/12-unresolved.md` not fully resolved in this architecture, plus
architecture-level questions that are **deferred** rather than decided here. Each entry records
what is decided now, what remains open, and to which phase the residual decision is deferred.

## Classification key

- **decided-in-architecture**: this document settles the question.
- **deferred-to-stage**: design is fixed; concrete value or mechanism is a Phase-1a measurement.
- **deferred-to-implementation**: downstream coding agent chooses during the relevant stage,
  constrained by cited ADRs.

---

## U-08 — Supported camera resolutions and capability discovery

**Status:** deferred-to-stage (Phase 1a measurement)

**Decided now (03-camera-session.md §Format selection):** resolution enumeration uses
`AVCaptureDevice.formats`, filtered for 8-bit biplanar YUV at `constants.md#FRAME_RATE_TARGET_FPS`
(G-17 — 10-bit and half-float are not supported on `AVCaptureVideoDataOutput`). The largest 4:3
format is selected; fallback is `constants.md#CAPTURE_FALLBACK_WIDTH_PX × CAPTURE_FALLBACK_HEIGHT_PX`.

**Deferred:** the A16 test hardware returns one or more 4:3 formats at 30fps; the exact list
(capture dimensions, supported frame-rate ranges, `formatDescription` details) is an empirical
measurement, not a domain contract. Captured in `measurements/` during Stage 01 bring-up.

---

## U-09 — EXIF metadata field schema

**Status:** deferred-to-stage (Phase 5)

**Decided now (06-capture-and-recording.md §Still capture):** TIFF writing uses
`CGImageDestination` with `.tiff` UTI. Standard sensor tags go through
`kCGImagePropertyExifDictionary`. Non-standard fields are serialized as a JSON string under
`kCGImagePropertyExifUserComment` keyed by `"CamPlugin/v1"`.

**Deferred:** the JSON schema (exact field names, types, nullability) for `"CamPlugin/v1"`
is finalized during the capture-and-recording stage by enumerating the sensor-metadata
fields named in `domain-revised/08-capture-and-recording.md` §EXIF and selecting those
meaningful on iOS. Tracked as D-09 in `decisions.md`.

---

## U-11 — Focus distance units on iOS

**Status:** decided-in-architecture (03-camera-session.md §Focus, D-07)

**Decided:** the product's focus-distance unit is `AVCaptureDevice.lensPosition`
(normalized `[0.0, 1.0]`, G-11). The domain's `focusDistance` field is the same value,
committed via `setFocusModeLocked(lensPosition:)`. `FrameResult.focusDistance` is
`device.lensPosition` when focus is locked and `nil` while the AF system is scanning. No
remaining deferral.

---

## U-16 — AE frame-rate range policy for recording vs. preview

**Status:** deferred-to-stage (Phase 1a measurement)

**Decided now (03-camera-session.md §AE frame-rate range):** preview mode commits
`activeVideoMinFrameDuration = activeVideoMaxFrameDuration = 1/constants.md#FRAME_RATE_TARGET_FPS`
(fixed-rate). Recording mode commits
`activeVideoMaxFrameDuration = 1/constants.md#FRAME_RATE_RECORDING_MIN_FPS` (allowing AE to halve
the frame rate in low-light); `activeVideoMinFrameDuration` stays at the target.

**Deferred:** if the target hardware's active format does not support an exact fixed-rate range
matching the target fps, the fallback policy (closest supported range? error?) requires
empirical testing during Stage 01 bring-up. Captured in `measurements/`.

---

## U-18 — Pause-during-recording finalize semantics

**Status:** decided-in-architecture (06-capture-and-recording.md §Recording during pause)

**Decided:** `pause()` on an active recording drives a finalize-then-teardown sequence on the
engine's session queue. The finalize runs with `constants.md#RECORDING_FINISH_TIMEOUT_SECONDS`
deadline; on expiry the writer is cancelled (not finished), producing an empty file rather than
a corrupt MP4 (per ADR-16 §Finalize with a timeout deadline, G-08). The finalized file URL is
delivered via `onRecordingStateChanged("idle")` carrying the final URI. `pause()` returns only
after the state machine has transitioned to `"paused"`; the UI observes the transition through
the state stream.

On fatal finalization failure (encoder error, disk full) the caller sees `onError` with
`RECORDING_FAILED` (fatal) before the state transition. This resolves the three open sub-items
of U-18; no remaining deferral.

---

## OQ-01 (architecture-originated) — Texture storage-mode graduation

**Status:** deferred-to-stage (Instruments-driven)

**Decided now (04-metal-pipeline.md §Texture storage, D-02):** all three working textures —
`naturalTex`, `processedTex`, and `trackerTex` — are **always IOSurface-backed**. Each is
dequeued from (or wraps) a `CVPixelBuffer` whose pool is configured with
`kCVPixelBufferIOSurfacePropertiesKey: [:]` + `kCVPixelBufferMetalCompatibilityKey: true`
(`04-metal-pipeline.md` §Pool configuration). G-25's silent-drop failure mode (nil
`.iosurface` on `.private` textures) therefore does not apply at any stage — no texture in
the consumer-facing path is ever allocated outside an IOSurface.

Storage mode for all three is `.shared` from Stage 01 (the "start-simple default" of
ADR-20). Consumer attach is a no-op on the Metal side.

**Deferred:** graduation to the dynamic `.private`→`.shared` rotation described in ADR-20
only triggers if Instruments (Memory → IOSurface Bandwidth, or sampled DRAM-bandwidth
counter) shows measurable cost on a target device under production load. No pre-
optimization. A dedicated MIGRATION stage (`xx-private-default-rotation`) is reserved for
that work if the measurement arrives. Even if that graduation lands, IOSurface backing
remains the invariant — the graduation only changes `.shared` vs `.private`, never the
IOSurface-backing bit.

---

## OQ-02 (architecture-originated) — C++ PixelSink inheritance shape

**Status:** decided-in-architecture (05-consumers.md §D-03)

**Decided:** the consumer integration shape is the C-ABI `PixelSinkCallbacks` struct
(POD function pointers + opaque `context`) **as the permanent shape**, not a transitional
one. No Swift-subclass spike is scheduled.

**Why no spike.** The two primary consumers — external C++ CV pipelines (e.g. the tracker
module that calls `getNativePipelineHandle()`) and Swift-side subscribers — both sit to the
*side* of Swift-subclassing:
- External C++ callers cannot subclass from Swift at all; they integrate against the C++
  header surface directly.
- Swift-side subscribers go through `ConsumerRegistry.subscribe(stream:) -> AsyncStream<FrameSet>`
  per D-01, which is already Swift-idiomatic (no retain dance in caller code) and hides the
  C-ABI plumbing.

A hypothetical "Swift-native CV consumer that plugs directly into the C++ pool via subclass"
is the only case where Swift subclassing would matter — and that is not a first-class use
case for this product. The ergonomic payoff (no `Unmanaged.passRetained` at the caller;
compiler-enforced override signatures) does not justify carrying the ABI-stability risks of
Swift-subclassing a C++ abstract class (ADR-31). Stability of the C-ABI shape across
compiler versions, external-caller compatibility, and auditability of the retain dance at
exactly one site (inside `ConsumerRegistry`) win the tradeoff.

If a future product requirement introduces a Swift-native CV consumer that must inherit
from `PixelSink` directly (not through the registry), re-open this decision then.

---

## OQ-03 (architecture-originated) — Recording container choice (MP4 vs. MOV)

**Status:** decided-in-architecture (06-capture-and-recording.md §Recording, D-04)

**Decided:** the recording container is MP4 (`AVFileType.mp4`), matching the domain contract
(domain 08-capture-and-recording §Recording Parameters). HEVC-in-MP4 is supported across iOS
16+ devices; no MOV fallback is required. No remaining deferral.

---

## OQ-04 (architecture-originated) — Self-healing mechanism for `CAMERA_IN_USE`

**Status:** decided-in-architecture (09-errors-and-recovery.md §Self-healing)

**Decided:** self-healing from the terminal `CAMERA_IN_USE` state piggy-backs on the
`AVCaptureSession` interruption-ended notification with reason
`videoDeviceInUseByAnotherClient` → `interruptionEnded`. Per ADR-08 and guide 04-avfoundation
§Interruption reasons, the session does **not** auto-resume on this reason — user intent is
required. The architecture therefore splits the domain's "self-healing" requirement into:

- **Automatic state reset** from terminal error to `"closed"` on
  `AVCaptureSessionInterruptionEnded` with reason `videoDeviceInUseByAnotherClient`. This is the
  "self-healing" portion per domain 06 §Self-Healing.
- **Manual `open()`** from the host (driven by a UI "Resume" button) to transition
  `"closed"` → `"opening"` → `"streaming"`. This is what guide 04-avfoundation requires.

The net behavior preserves the domain guarantee (no user action within the camera layer) while
respecting the iOS policy that the host decides whether to resume. No remaining deferral.
