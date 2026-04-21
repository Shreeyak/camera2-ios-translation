# Expectations — what each stage should look like when done

One-page-per-stage summary of what to expect after each stage lands, how to verify it on a physical device or simulator, and what would indicate a regression. Intended for a reviewer who is not going to open the full brief. The authoritative spec for any stage is still its brief (`stage-NN.md`); this document is the human-facing abstract.

## How to use this doc

- Run through a stage's **What you'll see** paragraph first. Something missing there means the implementation is incomplete.
- Follow the **How to verify** steps in order on an iPad Pro M1 (or the simulator where the test is simulator-safe). Each numbered step either confirms a visible behavior or exercises an edge case.
- The **Regression signals** list names specific failure modes. Any of them means the stage is not done — either the implementation is wrong or a prior-stage guarantee got broken.

## MIGRATION vs FEATURE stages

FEATURE stages (01, 03, 04, 06, 07, 10, 11) add new user-visible capability. Their "What you'll see" is the primary acceptance check.

MIGRATION stages (02, 05, 08, 09, 12) change **no user-visible behavior**. Their whole value is structural: retire a scaffold, install a production primitive, preserve all prior behavior. For a migration, the user-facing acceptance check is "everything from the prior stage still works exactly the same, plus one specific failure mode is now prevented". You verify a migration by re-running the prior stage's happy-path manually and confirming the migration's specific fix.

## Scaffold accounting

Each stage retires zero or more scaffolds and may introduce scaffolds of its own. A scaffold is a deliberate shortcut — a known-imperfect implementation kept in code until a later migration stage removes it. Scaffolds are not bugs; they are tracked commitments. The scaffold inventory after each stage is listed in every per-stage "What you'll see" paragraph.

---

## Stage 01 — Walking skeleton: bare natural preview (FEATURE)

**What you'll see.** Launch the app. Within two seconds, a live camera preview from the back camera fills the screen. The bottom of the screen has an empty bar placeholder — no buttons, no sliders. The preview has no color effects applied; it is the raw output of the sensor after YUV→RGB conversion. Scaffolds live: `01:naive-scenephase-stop`, `01:simple-metal-passthrough`, `01:skip-completion-guard`.

**How to verify.**
1. Launch from Xcode onto an iPad Pro M1 or the iPad simulator.
2. Grant the camera permission prompt on first launch.
3. Confirm live preview fills the screen within two seconds.
4. Rotate the device through portrait and upside-down-landscape — the preview stays landscape-right.
5. Point at a white wall, then a colorful object — the preview updates in real time with no processing artifacts.
6. From the terminal: `swift test --package-path CameraKit/ --filter Stage01Tests` passes green.
7. From the terminal: `grep -rn '01:naive-scenephase-stop\|01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/` returns at least one hit per slug.

**Regression signals.** Black screen on launch. Preview stops updating. Orientation rotates with the device (should stay landscape-right). Any color effect visible on the preview — no processing is wired yet. App crashes on permission denial. `AVCaptureDevice` being constructed outside the `CaptureDeviceProviding` seam (the tests will catch this).

---

## Stage 02 — scenePhase / GPU submission gate (MIGRATION)

**What you'll see.** No UI change. Behavior change: pulling down the Notification Center freezes the preview on its current frame instead of blacking out or crashing; dismissing the banner resumes frames. Pressing the home button cleanly stops the session; returning to foreground restores the preview within one frame. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard`.

**How to verify.**
1. Launch the app; confirm live preview as in Stage 01.
2. Pull down the Notification Center from the top-right — the preview should freeze on the current frame. It should NOT turn black, stutter, or kill the session.
3. Swipe the banner away — preview resumes immediately.
4. Press the home button — app backgrounds, camera indicator in the status bar turns off.
5. Reopen the app — preview returns within one frame. No re-authorization prompt.
6. Repeat step 4 three times in a row — no drift, no stutter on return.
7. All Stage 01 tests still pass under `swift test --package-path CameraKit/ --filter "Stage0[12]Tests"`.

**Regression signals.** App crashes when backgrounding. Xcode console shows `MTLCommandBufferErrorNotPermitted` or `IOAF 6`. Preview turns black (instead of freezing) during a Notification Center banner. Frames stutter or lag when returning from background. Camera re-authorization prompt fires on foreground return (session got fully torn down instead of just stopped). Any Stage 01 test that previously passed now fails.

---

## Stage 03 — Camera controls + settings merge + persistence (FEATURE)

**What you'll see.** Expanded bottom bar with ISO, Shutter, Focus, and Zoom controls. Moving any slider updates the preview live. Toggling ISO from auto to manual automatically switches Shutter to manual (and vice versa). Quitting the app and relaunching restores the last-set values. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard` (no new scaffolds).

**How to verify.**
1. Launch the app.
2. Tap to reveal the expanded bar; move the ISO slider — preview brightness changes smoothly.
3. Move the Shutter slider — preview brightness/motion-blur changes smoothly.
4. Toggle ISO to manual — confirm Shutter's manual indicator lights up automatically.
5. Toggle Shutter to manual — confirm ISO's manual indicator lights up automatically.
6. Set specific values on ISO, Shutter, Focus, and Zoom.
7. Force-quit the app (swipe up, swipe away).
8. Relaunch — values are the ones you set in step 6.
9. Move the Focus slider through its range — preview focal plane visibly shifts.
10. Move Zoom from 1x to 2x — preview scales.

**Regression signals.** Sliders have no visible effect. ISO↔Shutter auto-switch does not fire. Values reset to default on relaunch (persistence broken). Preview stutters below 30 fps while a slider is in motion (merge path is slow). Moving two sliders simultaneously causes the device to throw a `lockForConfiguration` error in the Xcode console (commits are racing instead of serializing on `sessionQueue`).

---

## Stage 04 — Color pipeline + processed preview + center-patch sampling (FEATURE)

**What you'll see.** Split preview on launch — left half is the natural (raw) frame, right half is the processed frame. A color-calibration sidebar appears with sliders for brightness, contrast, saturation, gamma, and per-channel black balance. Moving any slider updates the right half in real time; the left half never changes. A Reset button returns the right half to match the left half pixel-for-pixel. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `04:unlocked-uniforms` (new).

**How to verify.**
1. Launch; confirm split preview with two panels.
2. Move brightness — right half gets brighter/darker; left half unchanged.
3. Move contrast, saturation, gamma, and each black-balance channel — each visibly alters the right half.
4. Press Reset — right half returns to match the left half.
5. Deliberately stress a slider (move it rapidly back and forth for 10 s at near-60 Hz motion). An occasional single-frame visual glitch on the right half may appear. This is the known scaffold `04:unlocked-uniforms` and is fixed in Stage 05; record any glitches you see.
6. All prior-stage tests still pass.

**Regression signals.** Only one preview panel (split failed to wire). Sliders have no visible effect on the right half. The left half changes when sliders are moved (natural path got accidentally coupled to processing uniforms). Reset does not return to identity. Frame rate drops below 30 fps while sliders are moving (color compute path is too expensive).

---

## Stage 05 — Uniform lock + per-frame snapshot (MIGRATION)

**What you'll see.** No UI change. Behavior change: the rapid-slider-stress test from Stage 04 no longer produces any single-frame visual glitch. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard`.

**How to verify.**
1. Re-run Stage 04 step 5 — move any slider rapidly for 10 s. You should see zero torn frames. If you see any, the migration is incomplete.
2. Confirm every Stage 04 golden-frame and persistence test still passes: `swift test --package-path CameraKit/ --filter "Stage0[45]Tests"`.

**Regression signals.** Torn frames still visible during stress (the `OSAllocatedUnfairLock` is not actually guarding the uniform write path). Slider response feels sticky or laggy (the lock is being held too long — it should cover only the snapshot copy, not the encode). Any Stage 04 test red.

---

## Stage 06 — Tracker stream + FrameSet publication + pool trio (FEATURE)

**What you'll see.** In a development build, a debug overlay can be toggled on. It displays frame numbers and per-frame capture timestamps. A hidden developer toggle subscribes to the tracker stream; when enabled, a small tracker thumbnail appears in a corner of the screen. Natural and processed preview continue as in Stage 04. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `06:simple-consumer-swift-only` (new).

**How to verify.**
1. Enable the debug overlay (developer gesture documented in the brief).
2. Observe frame numbers increment monotonically and capture timestamps non-decreasing.
3. Enable the tracker subscriber — thumbnail appears within a frame.
4. Disable the tracker subscriber — thumbnail disappears; main preview untouched.
5. Use Instruments Allocations for 30 s — pool high-water mark per lane matches `N_active_lanes + 1`; memory stable after a minute of activity.

**Regression signals.** Frame numbers skip or go backwards (ordering broken). Thumbnail persists after disabling subscriber (subscriber not unregistered). Natural or processed preview stalls when subscriber is toggled (subscriber path is holding a lock on the main frame clock). Memory grows without bound (pool drops are not recycling buffers). Attempting the C-ABI registration path throws an unexpected error beyond the documented "not wired yet" case.

---

## Stage 07 — Still image capture (TIFF) + EXIF envelope (FEATURE)

**What you'll see.** A capture button joins the bottom bar. Pressing it writes a `.tif` file and shows a banner "Image saved: <path>" for three seconds. The saved file opens cleanly in Photos and in macOS Preview (via AirDrop) and matches the on-screen processed preview pixel-for-pixel. First capture triggers the iOS "Allow access to Photos (Add Only)" dialog. Scaffolds live: `01:simple-metal-passthrough`, `01:skip-completion-guard`, `06:simple-consumer-swift-only`, `07:swift-side-capture-atomic` (new).

**How to verify.**
1. Press the capture button once. Confirm the banner appears for ~3 s then auto-dismisses.
2. Open Photos — find the captured image. The image matches what was on screen when you pressed capture.
3. AirDrop the file to Mac; open in Preview; use Tools → Show Inspector to see EXIF metadata. Confirm standard fields (ISO, exposure time) are populated and a `"CamPlugin/v1"` JSON string appears in the UserComment field.
4. Spam the capture button as fast as possible while the first capture is in flight — only the first press takes. Subsequent presses during in-flight capture are rejected (no concurrent captures).
5. Revoke Photos authorization in iOS Settings → Privacy → Photos → (app); relaunch; press capture — file lands in the app's Documents directory instead. Banner still shows the path.

**Regression signals.** Banner shows for wrong duration or doesn't dismiss. `.tif` file is corrupt or zero-sized. File fails to open in Photos or Preview. EXIF missing the `"CamPlugin/v1"` JSON envelope. Capture button allows concurrent captures (two banners in a row indicates the Invariant 7 guard is not wired). Authorization denial crashes the app or silently fails instead of falling back to Documents.

---

## Stage 08 — C++ PixelSink pool (MIGRATION)

**What you'll see.** No user-visible UI change. A demo external consumer — an OpenCV Canny edge stub — can be registered on the tracker stream in a development build; the debug overlay shows its edge-detected output. Registering and unregistering at runtime does not disturb the natural or processed preview. Scaffolds live: `01:skip-completion-guard` (the last remaining). Three scaffolds retired this stage.

**How to verify.**
1. In a development build, trigger the developer action that registers the Canny stub consumer on the tracker stream.
2. Observe the debug overlay now shows Canny edge output, updating at the tracker stream cadence.
3. Unregister — overlay returns to the prior frame-number/capture-time view; preview never stalls.
4. Keep the stub registered and spam the capture button — still captures succeed, no concurrent capture is accepted (the Invariant 7 guard is now enforced on the C++ side, with identical observable behavior).
5. Run all Stage 06 and Stage 07 tests — all pass unchanged.
6. Spot check: `grep -rn '06:simple-consumer-swift-only\|01:simple-metal-passthrough\|07:swift-side-capture-atomic' CameraKit/Sources/` returns zero hits.

**Regression signals.** Registering the Canny stub causes natural or processed preview to stall or drop frames. The stub receives no frames. Unregistering leaks memory (Instruments shows retained context after unregister). Still-capture now allows concurrent captures (the C++ atomic migration regressed Stage 07's guard). Scaffold slugs still present in source (migration incomplete).

---

## Stage 09 — Completion guard + watchdogs + recovery state machine (MIGRATION)

**What you'll see.** No UI change on the happy path. On failure: a transient recovery banner appears when a camera failure is simulated; the banner clears automatically when recovery succeeds. After five consecutive failures, a blocking fatal-error dialog appears and the preview is locked until the user acknowledges. Opening FaceTime while the app is foregrounded triggers an interruption; when FaceTime closes, the app auto-returns to the `closed` state; the user must press a Resume action to reopen. Scaffolds live: (none). Corpus is fully scaffold-free through this stage.

**How to verify.**
1. Happy path: launch, use the app for 30 s — everything works as before.
2. Force-quit the app while the preview is running — no crash on teardown (the D-10 completion guard prevents readback-buffer UAF).
3. Debug harness: trigger a simulated single `CAPTURE_FAILURE` — recovery banner appears and clears within 1 s.
4. Debug harness: trigger six consecutive `CAPTURE_FAILURE` events — observe retries at 500 ms, 1 s, 2 s, 4 s, 8 s intervals; the sixth failure emits a fatal dialog; the preview is blocked until the user acknowledges.
5. On-device: open the app, then open FaceTime. Observe interruption. Close FaceTime. Observe the app's state indicator returns to `closed`. Press Resume. Preview returns.
6. Run all Stage 04 and Stage 01 tests — all pass unchanged.

**Regression signals.** Force-quit mid-frame crashes the app (the D-10 guard is missing). Recovery banner appears but never clears after a successful retry. Backoff intervals wrong (too fast, too slow, or non-exponential). FaceTime interruption leaves the app in a stuck state instead of `closed`. Fatal dialog dismissible without an explicit action. AE-timeout or FPS-degradation notifications fire falsely during normal operation.

---

## Stage 10 — Video recording (HEVC MP4) + AE frame-rate range (FEATURE)

**What you'll see.** A record button and running timer join the bottom bar. Pressing it starts a recording; timer counts up; a red indicator confirms recording. Pressing stop finalizes the recording and the `.mp4` lands in Photos (HEVC codec). Preview stays smooth during recording. In low light, the preview frame rate visibly drops toward 15 fps (the recording-mode AE range). Scaffolds live: `10:synchronous-drain-pause` (new).

**How to verify.**
1. Press the record button. Timer starts. Red indicator visible.
2. Record 10 seconds; press stop. Timer stops; indicator clears.
3. Open Photos — the `.mp4` is present with the correct duration; playback works.
4. AirDrop the file to Mac; inspect with `mediainfo` or Preview's Inspector — codec is HEVC, container is MP4.
5. Record in a well-lit room — frame rate stays at 30 fps.
6. Partially cover the sensor to simulate low light while recording — the visible frame rate drops toward 15 fps; uncover, it returns to 30.
7. While recording, press a pause control — the recording finalizes, final file appears in Photos, state transitions to `paused`.

**Regression signals.** Record button unresponsive. Timer drifts from wall-clock. Final `.mp4` is corrupt or unplayable. Preview stalls while recording. Frame rate does not drop in low light (AE frame-rate range not applied). Pressing pause mid-recording produces a corrupt file instead of a finalized one. File is MOV or H.264 instead of MP4/HEVC. Recording longer than `RECORDING_FINISH_TIMEOUT_SECONDS` on stop produces a corrupt MP4 (should produce an empty file instead).

---

## Stage 11 — UI polish (FEATURE)

**What you'll see.** The full bottom bar is present: Settings, Calibrate, Capture, Record, Resolution. The expanded bar is polished. The color-calibration sidebar now has functional WB Calibrate and BB Calibrate buttons that use center-patch sampling to compute white-balance gains and black-balance offsets and apply them. A recording indicator and capture banner are styled to match iOS 26. Non-fatal errors show a transient toast; fatal errors show a blocking dialog. Every control is enabled or disabled according to the current session and recording state. Orientation is locked to landscape-right at the Info.plist level. Liquid Glass styling is applied. Scaffolds live: `10:synchronous-drain-pause`.

**How to verify.**
1. Walk through the bottom bar — every button is present and visually matches the product reference.
2. Point the camera at a gray/white surface. Press WB Calibrate. The preview shifts to neutralize the scene (the image looks more neutral after the calibration).
3. Point at a dark area. Press BB Calibrate. Black balance offsets are applied; shadows appear slightly differently weighted.
4. Rotate the device through every orientation — the UI stays landscape-right.
5. Debug harness: emit a simulated non-fatal error. Observe a toast appears and auto-dismisses after ~3 s.
6. Debug harness: emit a fatal error. Observe a blocking dialog that cannot be dismissed without pressing a Reset or Report button.
7. Start recording. Confirm the Resolution button is disabled, Capture button is disabled. Stop recording — they are re-enabled.
8. Enable VoiceOver (Settings → Accessibility → VoiceOver). Navigate the UI. Every interactive control has a descriptive label.

**Regression signals.** UI rotates with the device (orientation lock broken). Toast persists beyond its auto-dismiss. Controls that should be disabled during recording remain interactive. Calibrate buttons have no visible effect. Sidebar jitters under rapid slider motion (debouncer not coalescing correctly). Scanning-animation shows a stale numeric `focusDistance` value instead of the scanning indicator during an AF transition (the ui×state binding regression).

---

## Stage 12 — Background recording drain + observability (MIGRATION)

**What you'll see.** No UI change on the happy path. Behavior: pressing the home button mid-recording produces a finalized `.mp4` in Photos (as long as the recording fits within the iOS background-task budget), never a corrupt file. A debug overlay (developer long-press) shows live per-lane overwrite counters from both the Swift and C++ sides. Scaffolds live: (none). Corpus is fully scaffold-free.

**How to verify.**
1. Start a 10 s recording. Press the home button at 5 s. Wait for Photos to sync.
2. Open Photos — the `.mp4` is present and plays back correctly up to the point where the home button was pressed.
3. Repeat with a long recording that exceeds the background-task budget (typically 30+ s in background). The file should be empty or iOS should mark it invalid — **never** corrupt (i.e., Photos should refuse to play it, not crash the player).
4. Long-press the debug overlay. Force a slow subscriber via the developer toggle. Observe overwrite counters incrementing live for both Swift and C++ lanes.
5. Attempt to register an external consumer without providing an `onOverwrite` callback. The registration is rejected with a clear error. This is the observability quality gate.
6. Run the full test sweep: `swift test --package-path CameraKit/`. All pass.

**Regression signals.** Home-mid-recording produces a corrupt MP4 (background-task wrapping missing). Budget-exceeded produces a corrupt file instead of empty (expiration handler called `finishWriting` instead of `cancelWriting`). Debug overlay counters stuck at zero even when drops are happening. Overwrite counters show only one side (Swift-only or C++-only, not merged). Consumer registration without `onOverwrite` silently accepted. Instruments shows leaked `UIBackgroundTaskIdentifier` values after recording completes (missing `endBackgroundTask` call on some exit path).

---

## Cross-stage regression sweep

At any stage, if any of the following is true, something upstream regressed and needs investigation before proceeding:

- A prior stage's automated test suite turns red.
- A prior stage's HITL behavior (e.g. Stage 02's notification-banner freeze, Stage 04's split preview, Stage 07's still-capture banner) no longer works on device.
- A scaffold slug that was supposed to be retired is still grep-findable in source.
- A scaffold slug that was supposed to be introduced is missing.
- `CameraKit/state.md` diverges from the expected exit state of the stage.
- Preview frame rate drops below 30 fps during normal operation (no recording, no stress).
- Memory grows unbounded during a 5-minute soak test with all features exercised.
- Any `MTLCommandBufferErrorNotPermitted` or `IOAF 6` error appears in the Xcode console at any point.
- Any `AVFoundation` exception fires outside the documented recovery paths.

When any of these happens, do not patch the symptom on the current stage. Investigate which prior stage regressed and fix upstream.
