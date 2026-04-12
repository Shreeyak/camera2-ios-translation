# 09 — UI Behaviors

This file describes the control surface requirements — what the user interface must display and how
it must respond to user input and system events.

---

## Preview Display

The main view displays a **split-screen live preview**:
- Left half: natural (unprocessed) camera stream — no color adjustments applied.
- Right half: GPU-processed stream — all color transforms (brightness, contrast, saturation, gamma, black balance) applied in real time.

Both preview streams update at the camera frame rate. The split-screen is always visible when the session is in `"streaming"` state.

The natural stream is only present when the session was opened with the natural stream enabled. If the natural stream is disabled, the left half of the split may be omitted or show a placeholder.

[audit: 01-system-topology.md §UI Overview]

---

## Bottom Controls Bar

The bottom bar is always present during an active session. It contains:

| Control | Type | Behavior |
|---|---|---|
| Settings | Button | Opens/closes the camera parameters panel |
| Calibrate Color | Button | Opens/closes the color calibration sidebar |
| Capture | Button | Triggers a GPU-processed still image capture |
| Record / Stop | Toggle button | Starts recording when idle; shows Stop when recording |
| Resolution display | Text label | Shows current capture resolution (e.g., `4160×3120`) |

The bottom bar has two modes:
- **Collapsed**: shows the five items above.
- **Expanded**: shows individual camera parameter controls (see below) with a collapse arrow at the left.

[audit: 01-system-topology.md §UI Overview]

---

## Camera Parameter Controls (Expanded Bar)

When expanded, the bottom bar shows individual controls for:

| Control | Display | Behavior |
|---|---|---|
| ISO | Current value (e.g., `1600`) or `AUTO` | Toggle between auto and manual; manual allows numeric entry or slider |
| Shutter | Current value (e.g., `1/33`) or `AUTO` | Toggle between auto and manual |
| Focus | `AUTO` or distance value | Toggle between continuous auto-focus and manual |
| Zoom | Current value (e.g., `1.0x`) | Adjustable by slider or pinch gesture |

**Auto/manual toggling:** ISO and shutter always switch together (they are coupled — see `03-camera-control.md`). Switching either to manual automatically switches the other.

[audit: 01-system-topology.md §UI Overview (flutter_02)]

---

## Color Calibration Sidebar

A left sidebar panel labeled "Calibrate Color" contains:

| Control | Default | Behavior |
|---|---|---|
| White Balance → Calibrate | — | Samples the center of the frame and locks white balance gains |
| Black Balance → lock icon + Calibrate | — | Samples the center of the frame and sets per-channel black levels |
| Brightness slider | `0.00` | Range `[-1.0, 1.0]` |
| Contrast slider | `1.00` | Range `[0.0, 2.0]` |
| Saturation slider | `1.00` (displayed), `0.0` (API) | Range `[-1.0, 1.0]` |
| Gamma slider | `1.00` | Gamma exponent |
| Reset all | — | Restores all sliders to defaults |

Slider changes take effect on the next rendered frame. There is no confirmation step.

The sidebar is dismissible (does not block the preview).

[audit: 01-system-topology.md §UI Overview (flutter_03)]

---

## Recording Indicator

When recording is active:
- The Record button changes to a Stop button (filled square icon).
- A red recording indicator shows elapsed time in `MM:SS` format.
- The live preview continues in the background.
- The "Calibrate Color" sidebar remains usable during recording.

The elapsed timer starts when the `"recording"` callback is received. It stops when `"idle"` is received.

[audit: 01-system-topology.md §UI Overview (flutter_05)]

---

## Capture Confirmation

After a successful still image capture, a status banner appears at the bottom of the screen showing the saved file path. Example: `Image saved: /path/to/capture.png`.

The banner is displayed for a brief period and then dismissed automatically.

[audit: 01-system-topology.md §UI Overview (flutter_04)]

---

## State-Driven UI Behavior

The UI must respond to session state transitions:

| State | Expected UI behavior |
|---|---|
| `"opening"` | Show loading indicator or disable controls |
| `"streaming"` | Enable all controls; show live preview |
| `"recovering"` | Show non-blocking notification; keep preview frozen or last frame visible |
| `"paused"` | Freeze preview; disable capture/record |
| `"error"` | Show error dialog; disable all controls |
| `"closed"` | Return to initial state |

[audit: 04-pigeon-api.md §CamStateUpdate, 07-state-machine.md]

---

## Error Display

Non-fatal errors (e.g., `FRAME_STALL`, `FPS_DEGRADED`, `AE_CONVERGENCE_TIMEOUT`) should be surfaced as non-blocking notifications (e.g., a transient banner or toast). The session continues; the user does not need to take action.

Fatal errors (`isFatal: true`) must be surfaced as a blocking error dialog. The session is unrecoverable; the user should be able to retry (which would call `close()` then `open()` again) or dismiss.

[audit: 04-pigeon-api.md §CamError, 08-error-recovery.md]

---

## FrameResult Display

The `onFrameResult` callback delivers actual sensor values at approximately 3 Hz. The UI should update the displayed ISO, shutter speed, focus distance, and white balance values from these readings — not from the settings sent (the hardware may not apply settings exactly as requested).

`focusDistanceDiopters` is null during autofocus scans; the UI should show a visual indicator (e.g., scanning animation) rather than displaying a numeric value when this field is null.

[audit: 04-pigeon-api.md §CamFrameResult, 09-camera-controls.md §CamFrameResult Delivery]

---

## Log Level Control (Debug Builds Only)

In debug builds, the system supports runtime adjustment of diagnostic log verbosity. This control does not need to be part of the production UI — it is a developer tool. The mechanism is platform-specific (see `11-what-not-to-port.md`).

[audit: 01-system-topology.md §File Map (LogLevelReceiver), 11-build-config.md §Android Manifest]

---

## Orientation

The demo application runs in landscape orientation. All preview and UI elements are laid out for landscape. The system does not dynamically reflow for portrait orientation.

[audit: 01-system-topology.md §UI Overview]
