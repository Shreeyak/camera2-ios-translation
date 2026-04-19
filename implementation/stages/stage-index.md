# Stage Index

Ordered implementation stages for the architecture in `../architecture/`. Each stage has
YAML frontmatter + a prose body. `Visible:` in the prose body names what a user (or a
verification run) can observe at stage exit.

Scaffolding slugs use `<stage-number>:<kebab-slug>`. Every introduced slug retires in a
later stage (M5). The retiring stage has that source stage in `depends_on` (M6). Cadence:
no more than 2 consecutive FEATURE stages without a MIGRATION break; no stage enters with
more than 3 live scaffolds. Both are soft; violations carry a one-line justification.

---
stage: 01
title: Walking skeleton — bare natural preview on screen
type: FEATURE
depends_on: []
touches: [01-system-shape, 03-camera-session, 08-ui]
scaffolding_introduced: [01:naive-scenephase-stop, 01:simple-metal-passthrough, 01:skip-completion-guard]
scaffolding_retired: []
tests_preserved: []
---

Visible: the user launches the app and sees a live camera preview filling the screen, with
an empty bottom bar. No color processing, no recording, no controls wired — the preview is
the single acceptance criterion.

The scaffolds track deliberate shortcuts in this stage:
- `01:naive-scenephase-stop` — `.background` triggers a plain `sessionQueue.async { stop }`,
  no GPU-submission gate, no `waitUntilScheduled()`, no `beginBackgroundTask` integration.
  Retired in Stage 02.
- `01:simple-metal-passthrough` — single Pass-1 compute shader that does crop + YUV→RGBA
  conversion only; no color-transform pass; no pool trio (single IOSurface-backed
  `naturalTex`). Retired in Stage 08 when the full pipeline is in place.
- `01:skip-completion-guard` — `addCompletedHandler` does not check `sessionState` before
  touching readback state (D-10 deferred). Retired in Stage 09 alongside the recovery
  state machine. `close()` during Stage 01 is expected to race only rarely because nothing
  outside `open` / `close` mutates engine state yet.

The stage also introduces the `CaptureDeviceProviding` seam per ADR-32 and the first
Swift-Testing unit tests per ADR-33.

---
stage: 02
title: scenePhase / GPU submission gate (MIGRATION)
type: MIGRATION
depends_on: [01]
touches: [02-concurrency, 04-metal-pipeline, 08-ui]
scaffolding_introduced: []
scaffolding_retired: [01:naive-scenephase-stop]
tests_preserved: [01:engine-open-close-transitions, 01:preview-renders-first-frame]
---

Visible: pulling down the Notification Center over the running app freezes the preview
(gate closes) without killing the session; dismissing the banner restores frames. Going
fully background stops the session cleanly; foregrounding resumes within one frame.

Wires the ADR-09 submission gate (`ManagedAtomic<Bool>`) into the delivery queue just
before `commit()`; adds `lastCommittedCommandBuffer?.waitUntilScheduled()` on `.inactive`.
D-06 (strict policy) committed. `backgroundSuspend()` + session lifecycle via ADR-30
async-with-timeout is now the path on `.background`.

---
stage: 03
title: Camera controls + settings merge + persistence
type: FEATURE
depends_on: [01]
touches: [03-camera-session, 07-settings]
scaffolding_introduced: []
scaffolding_retired: []
tests_preserved: []
---

Visible: the expanded bottom bar exposes ISO, shutter, focus, and zoom controls. Toggling
ISO or shutter to manual auto-switches the other; restarting the app restores the last
configured values.

Implements settings merge + ISO/exposure coupling (Rules 1/2/3) on the engine actor;
device commits via `lockForConfiguration()` on `sessionQueue`; `UserDefaults` persistence
for `CameraSettings`. KVO-to-`AsyncStream` adapter (ADR-14) feeds `DeviceStateSnapshot`
into the engine for Rule 3's "manual latches from last readback". `frameResultStream` at
`constants.md#FRAME_RESULT_HEARTBEAT_HZ`.

---
stage: 04
title: Color pipeline + processed preview + sample-center-patch
type: FEATURE
depends_on: [01]
touches: [04-metal-pipeline, 07-settings, 08-ui]
scaffolding_introduced: [04:unlocked-uniforms]
scaffolding_retired: []
tests_preserved: []
---

Visible: the color-calibration sidebar appears on-screen; sliders for brightness, contrast,
saturation, gamma, and per-channel black balance update the right-half processed preview
in real-time. Reset returns to identity.

Adds Pass 2 (color-transform compute kernel) with the shader order per
`04-metal-pipeline.md` §Command graph; renders to a single IOSurface-backed `processedTex`
(Stage 04 uses one shared texture — the `CVPixelBufferPool` trio lands in Stage 06); drives
the processed `MTKView` by blitting from that shared texture each frame.
`setProcessingParameters` is wired with `UserDefaults` persistence. Center-patch sampling
via Metal reduction kernel implemented now for the calibration flows.

`04:unlocked-uniforms` — shader uniforms are written directly by the engine without the
`OSAllocatedUnfairLock<UniformStorage>` per `04-metal-pipeline.md` §Shader uniforms. Torn
writes are possible under rapid slider motion; perceptually benign for Stage 04 but the
lock is mandatory for correctness. Retired in Stage 05.

---
stage: 05
title: Uniform lock + per-frame snapshot (MIGRATION)
type: MIGRATION
depends_on: [04]
touches: [04-metal-pipeline, 07-settings]
scaffolding_introduced: []
scaffolding_retired: [04:unlocked-uniforms]
tests_preserved: [04:color-pipeline-golden-frame, 04:processing-params-persistence-roundtrip]
---

Visible: rapid slider input at 60 Hz no longer produces single-frame artifacts on the
processed preview. (The visible change is absence-of-glitch; golden-frame tests under
stress quantify it.)

Installs `OSAllocatedUnfairLock<UniformStorage>`; Pass 2 snapshots into the per-frame
`MTLBuffer` inside the lock; `ProcessingMetadata` attached to `FrameSet` (when FrameSet
exists in Stage 06) is the same snapshot.

Also completes the Inv 6 invariant row in `02-concurrency.md` — the guide existed since
Stage 04 but the implementation did not enforce it.

---
stage: 06
title: Tracker stream + FrameSet publication + pool trio
type: FEATURE
depends_on: [04]
touches: [04-metal-pipeline, 05-consumers]
scaffolding_introduced: [06:simple-consumer-swift-only]
scaffolding_retired: []
tests_preserved: []
---

Visible: a debug overlay (development builds only) shows frame-number + capture-time for
each publication; tracker preview (tiny thumbnail) appears when any consumer subscribes
to `.tracker`. No external C++ consumer yet.

Adds Pass 4 (tracker downsample) and introduces the three `CVPixelBufferPool` instances
per `04-metal-pipeline.md` §Pool configuration — up to this stage the pipeline used single
shared textures; Stage 06 is the first time natural/processed/tracker are each backed by a
pool, which is the precondition for latest-wins consumer mailboxes. `FrameSet` is
constructed in the completion handler and published into per-lane
`AsyncStream<FrameSet>.bufferingNewest(1)` mailboxes.

`06:simple-consumer-swift-only` — consumer fan-out is Swift-only (Mechanism B placeholder
per ADR-13); the C++ `PixelSink` pool is stubbed with an adapter that receives each
`FrameSet` yield on the Swift side and mirrors to a debug overlay. External C++ consumer
integration lands in Stage 08 with the full Mechanism A from D-01.

---
stage: 07
title: Still image capture (TIFF) + EXIF envelope
type: FEATURE
depends_on: [04]
touches: [06-capture-and-recording, 04-metal-pipeline]
scaffolding_introduced: [07:swift-side-capture-atomic]
scaffolding_retired: []
tests_preserved: []
---

Visible: pressing the capture button writes an `.tif` file; the "Image saved: …" banner
appears at the bottom of the screen for three seconds. The TIFF opens in Preview/Photos
and matches the on-screen processed preview pixel-for-pixel.

Implements Pass 6 (blit to CPU-readable RGBA16F `CVPixelBuffer`), CPU-side RGBA16F → RGB8
conversion via Accelerate, `CGImageDestination` TIFF write with standard EXIF dictionary +
`"CamPlugin/v1"` JSON envelope (D-09 envelope fixed; JSON schema deferred to Stage 5 of
the pipeline per `open-questions.md`). `PHPhotoLibrary` `.addOnly` authorization at
capture time; graceful fallback to app documents on denial.

`07:swift-side-capture-atomic` — the Invariant 7 "capture in-flight" guard lives on the
Swift side as a `ManagedAtomic<Bool>` until the C++ `PixelSink` pool lands in Stage 08.
The architecture text in `06-capture-and-recording.md` §D-05 describes the target shape
(C++ atomic in the imaging core); the Swift-side atomic satisfies the invariant with the
same semantics (CAS-driven; both lock-free). Retired in Stage 08 when the C++ pool
assumes ownership.

---
stage: 08
title: Consumer registry — C++ PixelSink pool (MIGRATION)
type: MIGRATION
depends_on: [01, 06, 07]
touches: [05-consumers, 01-system-shape, 02-concurrency]
scaffolding_introduced: []
scaffolding_retired: [06:simple-consumer-swift-only, 01:simple-metal-passthrough, 07:swift-side-capture-atomic]
tests_preserved: [06:frame-set-publication, 06:swift-consumer-drop-on-busy, 07:still-capture-in-flight-guard]
---

Visible: an external C++ consumer (initial acceptance: a stubbed Canny edge detector on the
tracker stream) registers via `PixelSinkCallbacks` and receives IOSurface-backed frames.
Subscribe/unsubscribe at runtime without disturbing the natural/processed preview.

Implements the C++ `PixelSink` pool per D-01; Swift `ConsumerRegistry` actor bridges both
lanes (Swift `AsyncStream<FrameSet>` via internal yield + C-ABI `PixelSinkCallbacks`
registration). `getNativePipelineHandle()` returns the raw C++ pointer per D-15. OpenCV
is the CV framework for the Canny stub per ADR-29. The C-ABI struct (D-03) is the
permanent integration shape per `open-questions.md` §OQ-02; no Swift-subclass spike is
scheduled.

Retires `01:simple-metal-passthrough` because by this stage every pass (1/2/3/4) is in
place and the processed path has real color work; no scaffolded passthrough remains.

---
stage: 09
title: Completion guard + stall watchdogs + recovery state machine (MIGRATION)
type: MIGRATION
depends_on: [01, 04]
touches: [09-errors-and-recovery, 02-concurrency, 04-metal-pipeline]
scaffolding_introduced: []
scaffolding_retired: [01:skip-completion-guard]
tests_preserved: [04:color-pipeline-golden-frame, 01:preview-renders-first-frame]
---

Visible: force-quitting the engine mid-frame (simulated via a test harness toggle)
no longer crashes on readback-buffer access. Severing the camera connection mid-session
(simulated) triggers the recovery banner and restoration within the backoff window;
exhausting the retry budget shows the fatal error dialog.

Installs the D-10 completion-handler re-entrancy guard on every `MTLCommandBuffer`. Adds
`Watchdog` pair with `ManagedAtomic<UInt64>` timestamps, captured session-token (Inv 12),
and `disarmAll()` as step 1 of recovery (D-13). `RecoveryCoordinator` implements the
non-fatal sequence per `02-concurrency.md` §Sequence C; exponential backoff schedule from
`constants.md#RECOVERY_BACKOFF_<n>_MS`; self-healing for `CAMERA_IN_USE` per D-14.

Two consecutive MIGRATION stages (08 → 09) is within the cadence heuristic (the rule is ≤2
consecutive FEATUREs before a MIGRATION, not the inverse); both migrations are load-bearing
and cannot be collapsed into one stage without exceeding the three-concern soft ceiling on
`touches`.

---
stage: 10
title: Video recording (HEVC MP4) + AE frame-rate range
type: FEATURE
depends_on: [04, 09, 02]
touches: [06-capture-and-recording, 04-metal-pipeline, 03-camera-session]
scaffolding_introduced: [10:synchronous-drain-pause]
scaffolding_retired: []
tests_preserved: []
---

Visible: pressing Record begins a timer and writes an `.mp4`. Stop finalizes and the
recording appears in Photos. During recording, the preview remains at the target frame
rate; low-light tests confirm AE drops below 30fps per the recording-mode frame-rate range.

Adds Pass 5 (RGBA16F → NV12 compute conversion) writing into IOSurface-backed encoder
pool buffers per ADR-06. `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` wired
with HEVC codec + MP4 container (D-04). `startRecording` / `stopRecording` flows per
`06-capture-and-recording.md`; `finishWriting` with `constants.md#RECORDING_FINISH_TIMEOUT_SECONDS`
deadline; AE frame-rate range toggles preview ↔ recording on `sessionQueue`.

`10:synchronous-drain-pause` — `pause()` during recording synchronously awaits
`finishWriting` on the engine actor without `UIApplication.beginBackgroundTask`. Acceptable
on foreground `pause()`; background drain is wired in Stage 12 (where the scaffold retires).

---
stage: 11
title: UI polish — full bar, calibration sidebar, state-driven UI, toasts
type: FEATURE
depends_on: [03, 04, 10]
touches: [08-ui, 07-settings]
scaffolding_introduced: []
scaffolding_retired: []
tests_preserved: []
---

Visible: the full UI matches `domain-revised/09-ui-behaviors.md` — split preview, full
bottom bar (Settings / Calibrate / Capture / Record / Resolution), expanded bar with
ISO/Shutter/Focus/Zoom, color-calibration sidebar with WB/BB Calibrate buttons, recording
indicator, capture banner, error toast (non-fatal) + blocking dialog (fatal),
state-driven enable/disable across all controls, landscape-right lock.

Wires `sampleCenterPatch` → computed gains → `updateSettings` for the WB Calibrate button
and → `setProcessingParameters` for the BB Calibrate button. Slider coalescing at 60 Hz via
a debouncer `Task`. `FrameDeliveryStats` long-press overlay for debug builds (stubbed — the
stream is not yet emitting anything meaningful; Stage 12 populates it).

---
stage: 12
title: Background recording drain + observability (MIGRATION)
type: MIGRATION
depends_on: [06, 08, 10]
touches: [06-capture-and-recording, 05-consumers, 02-concurrency]
scaffolding_introduced: []
scaffolding_retired: [10:synchronous-drain-pause]
tests_preserved: [10:record-start-stop-happy-path, 10:recording-truncated-on-deadline]
---

Visible: home-button press during recording produces a correctly-finalized `.mp4` up to
the background-task budget; deadline expiry produces an empty file (not corrupt) per
ADR-16 / G-08. Debug overlay now shows live per-lane overwrite counters from both
Swift-side `ConsumerRegistry` and C++ `PixelSink`.

Wires `UIApplication.beginBackgroundTask` around the recording drain per
`06-capture-and-recording.md` §Background drain. Expiration handler calls
`writer.cancelWriting()` never `finishWriting()`. `FrameDeliveryStats` emission is
plumbed from C++ pool (`mailbox_overwrite_count`) via C-ABI metrics callback and merged
with Swift-side counters per D-11. Quality-gate assertion: `PixelSink` registration without
an `onOverwrite` callback is rejected.
