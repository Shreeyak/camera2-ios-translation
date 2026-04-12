# 04 — Concurrency Invariants

This file specifies the concurrency guarantees that the system must uphold. Requirements describe
WHAT must be guaranteed — not HOW to implement the guarantee. The downstream architect chooses
the appropriate synchronization mechanism for the target platform (actors, structured concurrency,
dispatch queues, explicit locks, etc.).

---

## Invariant 1: Camera State Must Be Exclusively Serialized

All camera state mutations must be serialized — concurrent access to camera state is forbidden.

Camera state includes:
- The session state value (`"opening"`, `"streaming"`, `"recovering"`, `"paused"`, `"error"`, `"closed"`).
- The retry counter.
- The consecutive hardware error counter.
- The background-suspended flag.
- The stall watchdog timestamps.

**Consequence:** State transitions, error handling, settings updates, stall watchdog checks, and recovery scheduling must never execute concurrently with each other. The implementation must guarantee mutual exclusion across all of these operations.

**Additionally:** The serialization context must not block the UI execution context. State mutation work must be dispatched asynchronously relative to API calls from the application layer — the API call posts the work, and the result is delivered back to the application asynchronously.

[audit: 02-threading-model.md §Background Thread, 07-state-machine.md §State Consistency Rules]

---

## Invariant 2: GPU Operations Must Execute on a Dedicated Serialized Context

All GPU rendering operations for a given session must execute on a single, dedicated serialized execution context. Concurrent GPU operations on the same context are forbidden.

GPU operations include:
- Initializing and destroying the GPU rendering context, render targets, and readback buffers.
- Rendering frames (all operations within the per-frame render sequence).
- Mapping and unmapping readback buffers.
- Sampling the center patch.
- Resizing render targets.
- Binding and unbinding the preview display surface.
- Binding and unbinding the encoder input surface.

**Consequence:** The GPU execution context acts as a serial gate. No GPU operation may be initiated from any other context while another GPU operation is in progress.

[audit: 02-threading-model.md §GL Thread, 05-gpu-opengl.md]

---

## Invariant 3: UI Callbacks Must Arrive on the Main Execution Context

All callbacks from the plugin to the application layer must arrive on the application's main (UI) execution context. Delivering callbacks on any other context will cause concurrency violations in the UI framework.

Affected callbacks:
- `onStateChanged`
- `onError`
- `onFrameResult`
- `onRecordingStateChanged`

**Consequence:** Regardless of which execution context originates an event (camera state change, GPU stall, error detection), the callback must be re-dispatched to the main execution context before being delivered to the application layer.

[audit: 02-threading-model.md §Main Thread, §Native → Dart (FlutterApi)]

---

## Invariant 4: Native Pipeline Pointer Must Be Protected Against Use-After-Free

The native C++ pipeline object is accessed by two concurrent paths: the camera controller (teardown) and capture requests (captureImage, captureNaturalPicture). A teardown that zeroes the pointer while a capture is reading it would produce a use-after-free.

**Required guarantee:** Access to the native pipeline pointer must be guarded by a mutual exclusion primitive. The teardown path must:
1. Acquire the guard.
2. Read and zero the pointer.
3. Release the guard.
4. Call the destructor on the saved pointer (outside the guard).

Capture paths must:
1. Acquire the guard.
2. Read the pointer.
3. Release the guard.
4. If null: return immediately (teardown already ran or not yet initialized).
5. If non-null: proceed with the operation.

[audit: 02-threading-model.md §pipelineLock]

---

## Invariant 5: C++ Consumer Lock Ordering Must Be Consistent

The C++ pipeline's internal locking must follow a consistent lock acquisition order to prevent deadlock. The required ordering is:

```
pipeline consumer registry lock
  > processing stage lock
    > individual consumer lock
```

All code paths that acquire multiple locks must acquire them in this order. Acquiring in any other order risks deadlock.

[audit: 02-threading-model.md §Lock Ordering (C++), 06-cpp-sinks.md §Lock Ordering]

---

## Invariant 6: GPU Shader Uniform Values Must Be Protected Against Concurrent Access

GPU shader parameters (brightness, contrast, saturation, black balance, gamma) are written from the application-initiated path and read from the GPU rendering path on every frame. These two paths execute on different execution contexts.

**Required guarantee:** A mutual exclusion primitive must protect the uniform value buffer. The write path acquires and releases the mutex before the GPU reads, and the GPU read path acquires and releases the mutex for each uniform set during rendering.

[audit: 02-threading-model.md §Uniform Updates (setAdjustments), 05-gpu-opengl.md §Uniform Locations]

---

## Invariant 7: Capture In-Flight Guard Must Be Atomic

The "capture in flight" flag for hardware ISP still captures must be an atomic compare-and-swap operation. A race between two concurrent `captureNaturalPicture()` calls must result in exactly one capture proceeding and one being rejected — never two captures running simultaneously.

**Required guarantee:** The transition from "no capture in flight" to "capture in flight" must be a single atomic check-and-set. Non-atomic read-then-write sequences are not acceptable.

[audit: 10-capture-recording.md §Still Capture: captureNaturalPicture]

---

## Invariant 8: Fast-Path Capture Check Must Be Lock-Free

The C++ frame delivery path checks a "capture requested" flag on every frame to determine whether to encode and save the current frame. This check executes in the critical path for every frame and must not acquire any locks.

**Required guarantee:** The "capture requested" flag must be readable without locking. An atomic boolean or equivalent lock-free mechanism must be used.

[audit: 06-cpp-sinks.md §Delivery Path, §captureRequested_]

---

## Invariant 9: Recovery Retry Must Not Run Concurrently with Close

If the application calls `close()` or `backgroundSuspend()` while a recovery retry is scheduled but not yet fired, the retry must be cancelled. If the retry fires after cancellation, it must detect that the session is no longer in the recovering state and exit without action.

**Required guarantee:** Recovery retry scheduling is idempotent — cancelling a retry that has already been cancelled is safe and produces no error.

[audit: 07-state-machine.md §State Consistency Rules, 08-error-recovery.md §Recovery Cancellation]

---

## Invariant 10: Processing Stage Consumer Dispatch Is Non-Blocking

The frame delivery path that sends frames to C++ consumers must not block waiting for consumer completion. The consumer's 1-slot mailbox is overwritten with the new frame (drop-on-busy) and the delivery path returns immediately.

**Required guarantee:** Frame delivery to a consumer never blocks the GPU rendering execution context. A slow consumer drops frames; it does not slow down the GPU pipeline or the preview.

[audit: 06-cpp-sinks.md §Delivery Path, §ProcessingStage Thread Loop]

---

## Invariant 11: Stall Watchdog Timestamp Must Be Visible Across Contexts

The stall watchdog reads a timestamp that is written by the GPU execution context on every frame. These two operations occur on different execution contexts. The timestamp must be visible to the stall watchdog context without requiring the watchdog to acquire a lock (as the watchdog runs on a different, independent context).

**Required guarantee:** The stall timestamp must be published with sufficient memory ordering that reads from the watchdog context always see the most recently written value. An atomic or volatile variable with appropriate memory ordering is required.

[audit: 02-threading-model.md §GL Thread, 03-capture-pipeline.md §Stall Watchdog]

---

## Cross-Context Communication Pattern

The general pattern for all cross-context communication in this system is:

**Application → Camera state context:**
- The API call is received on the main execution context.
- The camera operation is posted asynchronously to the camera state execution context.
- The result is posted back to the main execution context and returned to the application.

**Camera state context → application (events):**
- Events originate on the camera state execution context or GPU execution context.
- Events are always re-dispatched to the main execution context before delivery.
- No event is ever delivered directly from a non-main context.

**GPU context → C++ consumer:**
- Frame delivery originates on the GPU execution context.
- Frames are placed into consumer mailboxes (non-blocking).
- Each consumer has its own independent execution context for processing.

[audit: 02-threading-model.md §Cross-Thread Communication Patterns]
