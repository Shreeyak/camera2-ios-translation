# 05 — Resource Lifecycle

This file specifies the ordering constraints for creation and teardown of camera and GPU resources,
and the invariants that must hold at each phase transition.

---

## Session Initialization Order

The following resources must be created in this order. Later stages depend on earlier ones.

1. **Serialized execution context** — the camera state serialization context must be running before any camera operations begin.
2. **Camera device** — the physical camera hardware is opened and held by the session.
3. **GPU pipeline** — the GPU rendering context, render targets, and readback buffers are initialized.
4. **Capture session** — the camera session is configured with the GPU input surface (and still-capture reader surface).
5. **Repeating capture request** — the continuous frame delivery loop is started, applying any persisted settings.
6. **Stall watchdog** — started in `onConfigured` (session successfully configured), not before, to prevent false positives from the initialization window.

[audit: 03-capture-pipeline.md §Session Surfaces, 07-state-machine.md §State Transitions, 08-error-recovery.md §Stall Watchdog]

---

## Full Teardown Order (close / release / recovery)

Full teardown releases all resources including the camera device. Used on explicit `close()`, fatal error, recovery retry, and application background-suspend.

1. Cancel stall watchdog and any pending retry timers.
2. Stop active recording (if any) — encoder and muxer are finalized before other resources are released.
3. Close the capture session.
4. Close the still-capture reader.
5. Stop and release the GPU pipeline — GPU resources (render targets, readback buffers, shader programs) are destroyed. The GPU rendering context must be current when calling GL deletion functions.
6. Release the native C++ pipeline — the native pointer is zeroed under the native pipeline lock before the C++ destructor is called, to prevent use-after-free if a capture call races with teardown.
7. Close the camera device.
8. Reset counters (retry count, stall timestamp, consecutive error count).

**Invariant**: The native pipeline pointer must be zeroed (invalidated) before the C++ destructor runs. Any code path that reads the pointer (e.g., a capture in flight) must re-read the pointer under the same lock and handle a null result gracefully.

[audit: 08-error-recovery.md §teardown() vs teardownSession(), 02-threading-model.md §pipelineLock, 05-gpu-opengl.md §Teardown Safety]

---

## Session-Only Teardown (pause / resolution change)

Session-only teardown releases the capture session and GPU pipeline but retains the camera device. Used for `pause()` and `setResolution()`.

1. Cancel stall watchdog.
2. If called from `pause()` and recording is active: stop recording first.
3. Close the capture session.
4. Close the still-capture reader.
5. Stop and release the GPU pipeline.
6. Release the native C++ pipeline (pointer zeroed under lock).
7. **Camera device is NOT closed.**
8. Reset capture-session-level counters (not the retry count).

**Reason for keeping the device open**: Reopening a camera device has observable latency. Keeping the device open across pause/resume allows the session to restart quickly with only session-level reinitialization.

[audit: 08-error-recovery.md §teardown() vs teardownSession(), 12-git-archaeology.md §Key Architecture Decisions]

---

## GPU Resource Release Safety

GPU resources must be released with the GPU rendering context active. If the GPU pipeline destructor runs on a different execution context than the one that owns the rendering context, the system must bind the rendering context (or a compatible offscreen context) before calling GPU resource deletion.

This invariant prevents undefined behavior from GPU API calls with no active context.

[audit: 05-gpu-opengl.md §Teardown Safety]

---

## Native Pipeline Lock

Access to the native C++ pipeline pointer is guarded by a lock. The teardown path and any in-flight capture path must both acquire this lock before reading or writing the pointer.

**Teardown sequence**:
1. Acquire lock.
2. Read and zero the pointer.
3. Release lock.
4. Call the C++ destructor on the saved pointer.

**Capture sequence**:
1. Acquire lock.
2. Read the pointer.
3. Release lock.
4. If pointer is null: return without operation (teardown already ran).
5. Otherwise: proceed with the capture.

[audit: 02-threading-model.md §pipelineLock]

---

## Still-Capture Reader Lifecycle

A still-capture reader (for hardware ISP captures) is allocated at session creation and released during teardown. It is not created per-capture; it is held for the duration of the session.

The in-flight capture flag is an atomic boolean. Its invariant:
- Set to `true` before issuing the capture trigger.
- Always cleared to `false` in the capture finalization path (even on error).
- This prevents two concurrent captures from issuing overlapping requests to the same reader.

[audit: 10-capture-recording.md §Still Capture: captureNaturalPicture, 08-error-recovery.md §teardown() vs teardownSession()]

---

## GPU Pipeline Resource Initialization

GPU pipeline resources (render targets, readback buffers) are initialized with the stream resolution at session open time. When the resolution is changed via `setResolution()`, these resources are resized:

1. Session-only teardown (above).
2. GPU pipeline resizes: render targets and readback buffers are destroyed and recreated at the new resolution. Timeout: **5 seconds**.
3. New capture session is started.

If the resize times out, the system returns to the previous state. The resize failure is non-fatal.

[audit: 09-camera-controls.md §setResolution Flow, 07-state-machine.md §Key Constants]

---

## Preview Surface Rebind

If the preview display surface becomes invalid mid-session (e.g., app partially hidden), the GPU pipeline can rebind to a new surface without session teardown:

1. Detect consecutive swap failures (threshold: **3** consecutive failures).
2. Request a new display surface from the UI framework.
3. Post to the GPU execution context: destroy the old surface binding, create a new one from the provided surface.

The camera session and GPU pipeline continue running; only the surface binding is replaced.

[audit: 05-gpu-opengl.md §Preview Surface Rebind, 03-capture-pipeline.md §GpuPipeline]

---

## Application Lifecycle Integration

The system integrates with the application lifecycle to release camera resources when the app becomes fully invisible:

**App goes fully invisible:**
1. Recording is stopped (if active).
2. Full teardown is performed.
3. State is set internally to closed without emitting a user-visible state change.
4. A "background suspended" flag is set to suppress recovery retries.

**App returns to visible:**
1. Background suspended flag is cleared.
2. If a camera was previously open, the reopen sequence begins.

The "fully invisible" trigger must be chosen carefully on the target platform — using "partially occluded" (e.g., dialog overlay) would cause unnecessary camera release. The intended behavior is: release only when the app is completely off-screen.

[audit: 07-state-machine.md §Background Suspend/Resume, 12-git-archaeology.md §Key Architecture Decisions]

---

## Settings and Parameters Persistence

Camera settings and GPU processing parameters are saved to persistent local storage on every update. On session open, the persisted settings are loaded and applied to the initial capture request. This allows the camera to open with the same configuration as the previous session without any explicit initialization call from the application layer.

[audit: 09-camera-controls.md §Settings Persistence]

---

## Self-Healing from Terminal Error

When the session enters the terminal error state due to a camera-in-use conflict, the system registers a listener for camera availability events. When the camera becomes available again (because another process released it):

1. The internal state is reset from terminal-error to closed (un-blocking recovery).
2. The camera open sequence is initiated automatically.
3. No user action is required.

This self-healing path only applies to the terminal error state. Non-fatal errors use the exponential backoff retry path.

[audit: 07-state-machine.md §self-healing, 08-error-recovery.md §self-healing]
