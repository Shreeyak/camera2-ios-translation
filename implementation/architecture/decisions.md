# Decisions

Product-level decisions made in this architecture. Every deviation from `ios-platform-guide`
gets a `D-##` entry; product choices that pick between documented ADR options also earn a
`D-##` to make the selection searchable.

- **Consequential** entries follow the full ADR shape
  (Context / Options / Decision / Consequences / Reversibility) inline in the owning concern
  file, with a one-line summary row in this register.
- **Minor** entries are a single row here plus a one-paragraph inline anchor
  (`## D-##`) in their owning concern file.

Every entry has a matching `## D-##` heading anchor in the file named under "File" so
`verify-architecture.sh` M2 resolves. Cross-concern rules live in the **primary-owner** file
only (see `README.md` §Primary-owner rule); other concerns cross-reference.

## Register

| D-## | Decision | Cites | Kind | File |
|---|---|---|---|---|
| D-01 | Consumer fan-out uses Mechanism A (C++ PixelSink pool); Swift-side subscribe facade yields `AsyncStream<FrameSet>`. | ADR-13, ADR-18, ADR-19, ADR-29 | Consequential | 05-consumers.md |
| D-02 | Texture storage-mode baseline is `.shared` for `naturalTex`, `processedTex`, `trackerTex` (ADR-20 start-simple default); no `.private` → `.shared` rotation until Instruments evidence. | ADR-20, G-25 | Consequential | 04-metal-pipeline.md |
| D-03 | C++ consumer integration is the C-ABI `PixelSinkCallbacks` struct as the permanent shape; no Swift-subclass spike is scheduled. | ADR-31, ADR-13 | Consequential | 05-consumers.md |
| D-04 | Recording container is MP4 (`AVFileType.mp4`) with HEVC 8-bit; no MOV, no H.264 fallback. | ADR-16, domain 08-capture-and-recording | Minor | 06-capture-and-recording.md |
| D-05 | Still capture path is direct Metal-blit readback into a CPU-readable `CVPixelBuffer` (not a `PixelSink` subscription). | ADR-03, domain 08-capture-and-recording | Minor | 06-capture-and-recording.md |
| D-06 | scenePhase `.inactive` policy is **strict**: gate GPU submission on every `.inactive`, without checking `UIApplication.applicationState`. | ADR-08, ADR-09 | Minor | 02-concurrency.md |
| D-07 | `focusDistance` (`[0.0, 1.0]`) is the identity of `AVCaptureDevice.lensPosition`. | ADR-14, G-11 | Minor | 03-camera-session.md |
| D-08 | Single physical camera: `.builtInWideAngleCamera`, back-facing; telephoto/ultra-wide/front are out of scope per domain U-17. | domain 01-system-purpose | Minor | 03-camera-session.md |
| D-09 | EXIF `"CamPlugin/v1"` field schema is deferred to Stage 5; the key and envelope are fixed now. | guide 04-avfoundation, domain U-09 | Minor | 06-capture-and-recording.md |
| D-10 | Completion-handler re-entrancy guard: every GPU completion handler captures `sessionState` at commit and no-ops if it diverges by handler-time. | ADR-10, G-20, guide 02-concurrency §Completion-handler re-entrancy guard | Consequential | 02-concurrency.md |
| D-11 | Drop-on-busy observability surfaces `FrameDeliveryStats` via a dedicated `AsyncStream<FrameDeliveryStats>`, aggregating Swift-side per-lane counters and C++ PixelSink overwrite counters through a C-ABI metrics callback. | ADR-19, G-26 | Minor | 05-consumers.md |
| D-12 | Natural stream is subscribable on par with processed/tracker (reverses domain U-13); all three stream IDs share one `PixelSink` surface. | domain 02-frame-delivery, ADR-13, ADR-18 | Minor | 05-consumers.md |
| D-13 | Recovery step 1 is watchdog-disarm *before* any state transition; a watchdog callback that outraces teardown no-ops via captured session-token identity. | domain 06-error-and-recovery §Non-Fatal Recovery Sequence, Invariant 12 | Minor | 09-errors-and-recovery.md |
| D-14 | Self-healing from `CAMERA_IN_USE` uses `AVCaptureSessionInterruptionEnded` with reason `videoDeviceInUseByAnotherClient` to return the engine to `"closed"`; re-entry to `"streaming"` requires an explicit host `open()`. | ADR-08, guide 04-avfoundation §Interruption reasons, domain 06 §Self-Healing | Minor | 09-errors-and-recovery.md |
| D-15 | Pipeline-pointer guard (domain Invariant 4) is a Swift actor boundary on the engine side plus a C++ `std::mutex` on the native side; the native `getNativePipelineHandle()` returns the raw pointer only while holding the engine actor. | domain Invariant 4, ADR-02, ADR-11 | Minor | 05-consumers.md |

---

## D-01 summary

See `05-consumers.md` §Mechanism — Swift facade over C++ pool (D-01) for the full ADR-form
entry: Context, Options (Mechanism A vs. Mechanism B), Decision, Consequences, and Reversibility
analysis. Tracker/processed/natural lanes all flow through the same C++ `PixelSink` registry;
Swift-side subscribers receive `FrameSet` through a thin `AsyncStream` bridge.

## D-02 summary

See `04-metal-pipeline.md` §Texture storage mode (D-02) for the full ADR-form entry. `.shared`
default is not a deviation from ADR-20; it is the ADR's start-simple option. Kept as
`Consequential` because switching to dynamic rotation requires a dedicated MIGRATION stage.

## D-03 summary

See `05-consumers.md` §C-ABI callback struct (D-03) for the full ADR-form entry. C-ABI is
the permanent integration shape; Swift subclassing of the C++ abstract class is not
scheduled — its ergonomic benefit is marginal and confined to a use case (a Swift-native
CV consumer plugging directly into the C++ pool) that this product does not require.

## D-10 summary

See `02-concurrency.md` §Completion-handler re-entrancy guard (D-10) for the full ADR-form
entry. Without this guard, an in-flight GPU completion handler can touch actor state that was
released by `close()`/`backgroundSuspend()`/`setResolution()` between `commit()` and handler
firing (G-20).
