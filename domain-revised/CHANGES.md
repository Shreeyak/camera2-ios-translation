# Changes from `domain/` to `domain-revised/`

Manual review stage (2.5) applied to Agent 2 output. All edits preserve behavioral intent while removing Android-specific constraints and correcting platform assumptions.

---

## Capture format and crop pipeline

**Capture format is 8-bit YUV 4:2:0**, not full-resolution RGBA. The GPU center-crops to an operator-selected region before color conversion; all downstream streams derive from that crop, not the sensor's full frame.

## All streams use RGBA16F

Delivered frames (`natural`, `processed`, `tracker`) are RGBA16F (half-float), not RGBA8888. Half-float is required because the 5-stage color-transform chain compounds quantization error at 8-bit.

## Natural stream is subscribable (reverses U-13)

Natural was previously display-only with no consumer registration path. There is no product reason to restrict it; consumers wanting unprocessed frames are a valid use case.

## Still capture: one path, two equivalent implementations

The hardware-ISP JPEG path (`captureNaturalPicture`) is removed. One path remains: GPU-processed output as **8-bit TIFF**, implemented either via a stream subscription or a direct GPU readback — platform chooses.

## HEVC 8-bit only, no H.264 fallback

HEVC is assumed available on target platforms; the H.264 fallback was an Android codec-availability workaround that does not apply.

## Audio is not captured

Recordings contain a single video track. The system must not request microphone permission. This is an explicit product constraint documented as a key invariant.

## `focusDistance` replaces `focusDistanceDiopters`

The field is renamed and normalized to `[0.0, 1.0]`; units are platform-defined. iOS uses `lensPosition` directly; other platforms normalize their physical focus distance into the same range.

## Noise reduction and edge mode removed

These were Android HAL integer passthroughs with no platform-neutral equivalent. The fields are deleted from `CameraSettings` and `10-api-contract.md`.

## `open()` takes `captureResolution` and `cropRegion`

`enableNaturalStream` / `naturalStreamHeight` are removed (natural is always on). `captureResolution` and `cropRegion` replace them with explicit 4160×3120 / 1600×1200 defaults.

## `setCropRegion` added

Runtime crop adjustment without session teardown. Takes effect on next committed frame; brief drops may occur during GPU pipeline reconfiguration.

## Watchdog lifecycle rules added

Watchdogs are dormant until the first observation and disarmed as step 1 of both teardown and recovery. Callbacks that fire after session teardown are no-ops.

## Recovery sequence: disarm watchdogs first

Step 1 of the non-fatal recovery sequence is now watchdog disarm, before any state transition. Prevents a stale watchdog callback from triggering a second recovery path.

## Concrete numbers replaced with formulas or deferred

Removed: 8ms fence budget, 49.5 MB frame buffer, 50 Mbps bitrate, 5s AE convergence, 10ms drain poll. Replaced with formulas (`FRAME_WORKING_MB = crop_w × crop_h × 8`) or deferred to `measurements/`.

## Pause-during-recording semantics moved to unresolved (U-18)

The prior "best-effort, errors logged" prose was underspecified. Finalize semantics (sync vs async, failure handling, callback surface) are left to the platform implementation.

## Recording-sink back-pressure documented

When a recording consumer has no buffer capacity, the frame is dropped at that sink only. Camera producer and other consumers are not affected; drops are logged, not surfaced in the UI.

## Orientation: landscape-right, not landscape

Clarified to landscape-right (USB port on the left). The split-screen always shows both halves; the prior "may be omitted or show a placeholder" language is removed.

## 05-resource-lifecycle: C++ and GL implementation details removed

The "acquire lock → zero pointer → release → destruct" protocol and the GL "rendering context must be current" rule are implementation patterns, not behavioral contracts. Replaced with platform-neutral statements and forward references to `04-concurrency-invariants.md`.

## 05-resource-lifecycle: pause() session-only teardown rationale preserved

Keeping the camera device open across pause/resume avoids reopen latency; this came from git archaeology and is not derivable from the API. The rationale note is explicitly preserved so Agent 3 does not default to full teardown on pause.

## Still capture is not a distinct request mode

`03-camera-control.md` and `11-what-not-to-port.md` incorrectly listed still capture as a third ISP-tuned request mode alongside preview and recording. Still capture reads GPU-processed output from the running repeating request; no separate camera request mode exists.

## Tracker format flagged as open ADR

Tracker stream pixel format (RGBA16F, R16F, or R8) depends on consumer needs. The conservative estimate (RGBA16F, bpp=8) is used in the memory formulas until an ADR resolves it.
