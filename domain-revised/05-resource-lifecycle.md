# 05 — Resource Lifecycle

This file specifies the ordering constraints for creation and teardown of camera and GPU resources,
and the invariants that must hold at each phase transition.

---

## Session Initialization Order

The following resources must be created in this order. Later stages depend on earlier ones.

1. **Serialized execution context** — the camera state serialization context must be running before any camera operations begin.
2. **Camera device** — the physical camera hardware is opened and held by the session.
3. **GPU pipeline** — the GPU rendering context, render targets, and readback buffers are initialized.
4. **Capture session** — the camera session is configured with the GPU input surface.
5. **Repeating capture request** — the continuous frame delivery loop is started, applying any persisted settings.
6. **Stall watchdog** — started once the capture session reports successful configuration, not before, to prevent false positives from the initialization window.

[audit: 03-capture-pipeline.md §Session Surfaces, 07-state-machine.md §State Transitions, 08-error-recovery.md §Stall Watchdog]

---

## Full Teardown Order (close / release / recovery)

Full teardown releases all resources including the camera device. Used on explicit `close()`, fatal error, and recovery retry.

1. Cancel stall watchdog and any pending retry timers.
2. Stop active recording (if any) — encoder and muxer are finalized before other resources are released.
3. Close the capture session.
4. Stop and release the GPU pipeline — render targets, readback buffers, and shader programs are destroyed. GPU resources must be released on the GPU execution context that owns them.
5. Release the pipeline object — ensure mutual exclusion with any in-flight capture path before releasing. The mechanism is platform-defined (reference counting, isolation boundary, explicit lock, etc.).
7. Close the camera device.
8. Reset counters (retry count, stall timestamp, consecutive error count).

[audit: 08-error-recovery.md §teardown() vs teardownSession(), 05-gpu-opengl.md §Teardown Safety]

---

## Session-Only Teardown (pause / resolution change)

Session-only teardown releases the capture session and GPU pipeline but retains the camera device. Used for `pause()` and `setResolution()`.

1. Cancel stall watchdog.
2. If called from `pause()` and recording is active: stop recording first.
3. Close the capture session.
4. Stop and release the GPU pipeline.
5. Release the pipeline object (platform-defined mutual exclusion with in-flight captures).
7. **Camera device is NOT closed.**
8. Reset capture-session-level counters (not the retry count).

**Reason for keeping the device open**: Reopening a camera device has observable latency. Keeping the device open across pause/resume allows the session to restart quickly with only session-level reinitialization.

[audit: 08-error-recovery.md §teardown() vs teardownSession(), 12-git-archaeology.md §Key Architecture Decisions]

---

## GPU Resource Release Safety

GPU resources must be released on the execution context that owns the GPU pipeline. Releasing GPU resources from a different context produces undefined behavior. The implementation must ensure teardown dispatches GPU resource release to the correct context.

See `04-concurrency-invariants.md §Invariant 2` for the serialization requirement on GPU operations.

[audit: 05-gpu-opengl.md §Teardown Safety]

---

## Pipeline Teardown and Capture Mutual Exclusion

See `04-concurrency-invariants.md §Invariant 4` for the mutual-exclusion requirement between teardown and in-flight capture paths. The implementation mechanism is platform-defined.

---

## Still-Capture Concurrency Guard

The in-flight capture flag is an atomic (or equivalent) boolean that prevents two concurrent `captureImage()` calls from overlapping. It is set before the capture begins and cleared in the finalization path, even on error.

[audit: 10-capture-recording.md §Still Capture: captureImage, 08-error-recovery.md §teardown() vs teardownSession()]

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

Two independent signal sources drive lifecycle management. They must not be conflated — conflating them causes race conditions and unnecessary teardown.

**User-initiated lifecycle (view lifecycle):**
When the camera view disappears, halt the capture session. No resource teardown is required — retain the session and GPU resources for rapid restart when the view reappears. Recreating the session object on every appearance is an explicit anti-pattern that defeats this optimization and incurs unnecessary hardware re-initialization latency.

**System-initiated lifecycle (platform interruptions):**
The platform independently signals camera interruptions when the app backgrounds, another process takes the camera, or system pressure forces GPU access restrictions. Observe and classify these signals; do not proactively tear down in response:
- Application goes to background: the camera session is interrupted by the system. No teardown is required — inputs and outputs remain configured. On return to foreground, the session self-restores via the system's interruption-ended notification. The host calls `backgroundResume()` to confirm readiness.
- Camera taken by another process: surface a manual resume control to the user; await user intent or platform restoration signal.
- System resource pressure: surface "camera unavailable" indicator; await restoration signal.

**GPU submission gating:**
The platform may revoke GPU submission rights before the app is fully invisible — at the point the scene begins transitioning away from active state, not at the point it becomes fully invisible. GPU command submission must stop at this earlier edge. Commands already committed to the GPU will complete; commands not yet submitted must be dropped. In-flight capture callbacks arriving after the gate is set must check the gate before submitting GPU work, as close to the submission as possible.

**On restoration:**
When the platform signals camera access is restored, restart the existing session. Do not recreate the session object. Reapply persisted settings after restart.

**Background recording drain:**
If recording is active when backgrounding begins, the recording must be finalized before the process is suspended. Request a platform background execution extension to complete the drain. If the drain window expires before finalization, cancel the write rather than leave the file in a permanently corrupted state. A corrupted output file (moov atom never written) is worse than no file.

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
