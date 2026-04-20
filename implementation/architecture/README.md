# Architecture

Target iOS 26 / Swift 6 / Metal 4 design for the camera-to-ML pipeline, derived from
`domain-revised/` and `ios-platform-guide/`. This directory contains nine concern files,
four register files, and a compiling Swift skeleton.

---

## Primary-owner rule

> Every architectural decision has exactly one primary-owner file. Cross-references in other
> concern files must be labeled `(see X#anchor for the authoritative statement)` and must
> not repeat decision content.

---

## Reading order

New readers start with §Interactions considered below, then read concern files in this order:

1. `01-system-shape.md` — where every type lives; most cited.
2. `02-concurrency.md` — invariant → primitive mapping; scenePhase / error / consumer sequences.
3. `03-camera-session.md` — `AVCaptureSession` config, orientation, interruptions, self-healing.
4. `04-metal-pipeline.md` — per-frame command graph, pools, readback.
5. `05-consumers.md` — `PixelSink` registry, Swift ↔ C++ interop, observability.
6. `06-capture-and-recording.md` — still capture (TIFF) + HEVC recording (MP4).
7. `07-settings.md` — merge, ISO/exposure coupling, persistence, heartbeat.
8. `08-ui.md` — SwiftUI composition, controls, scenePhase wiring.
9. `09-errors-and-recovery.md` — error taxonomy, recovery state machine, watchdogs.

Register files:

- `api-surface.md` — prose summary of the SDK boundary; points into `api-skeletons/`.
- `decisions.md` — `D-##` roster; consequential entries have full ADR-form anchors in their
  owning concern file.
- `constants.md` — load-bearing numeric values. Every cell populated.
- `open-questions.md` — deferred U-## items + architecture-originated open questions.
- `api-skeletons/` — SwiftPM package (`swift build --package-path api-skeletons/` must
  succeed under Swift 6 + strict concurrency).

---

## Cross-file interaction map

Which concerns each top-level operation touches. Primary owner in bold.

| Operation | Concerns involved |
|---|---|
| `open()` | **03-camera-session**, 01-system-shape, 07-settings (persistence load), 04-metal-pipeline (pools), 09-errors-and-recovery |
| `close()` | **03-camera-session** (full teardown), 04-metal-pipeline (GPU release), 05-consumers (registry release), 09-errors-and-recovery (watchdog disarm first), 06-capture-and-recording (stop recording first) |
| `pause()` / `resume()` | **03-camera-session** (session-only teardown), 06-capture-and-recording (pause-during-recording, D-05 resolution), 07-settings (persistence reapply on resume) |
| `backgroundSuspend()` / `backgroundResume()` | **02-concurrency** §Sequence A, 03-camera-session (interruption wiring), 06-capture-and-recording (background drain), 09-errors-and-recovery (cancel pending retry) |
| `updateSettings(_:)` | **07-settings** (merge, coupling), 03-camera-session (commit on sessionQueue) |
| `setProcessingParameters(_:)` | **07-settings** (update path), 04-metal-pipeline (shader uniforms) |
| `sampleCenterPatch()` | **04-metal-pipeline** (sampling compute), 07-settings (calibration clients) |
| `captureImage(outputPath:)` | **06-capture-and-recording** (D-05 direct readback, D-09 EXIF), 04-metal-pipeline (still blit), 05-consumers (atomic guard Inv 7) |
| `startRecording(options:)` / `stopRecording()` | **06-capture-and-recording**, 04-metal-pipeline (encoder compute), 03-camera-session (AE frame-rate range) |
| `setResolution(size:)` | **03-camera-session** (session-only teardown), 04-metal-pipeline (pool resize) |
| `setCropRegion(_:)` | **04-metal-pipeline** (crop uniform) |
| Consumer subscribe / register | **05-consumers**, 04-metal-pipeline (pool buffers), 02-concurrency §Sequence B |
| Error arrival | **09-errors-and-recovery**, 02-concurrency §Sequence C, 03-camera-session (teardown) |
| scenePhase transitions | **08-ui** (observer), 02-concurrency §Sequence A, 03-camera-session (stop/start), 04-metal-pipeline (gate), 06-capture-and-recording (drain) |

---

## Interactions considered

Six cross-subsystem interactions surfaced during design. Each bullet carries one of the
allowed shape tags — `concurrency×lifecycle`, `storage×consumer`, `error×recovery`,
`resource×teardown`, `settings×session`, `ui×state` — per the M8 gate.

- **concurrency×lifecycle**: scenePhase `.inactive` × outstanding `MTLCommandBuffer` →
  `constants.md#FRAME_LATENCY_BUDGET_MS` window. The GPU submission gate (ADR-09 +
  `02-concurrency.md` §Sequence A) is a `ManagedAtomic<Bool>` checked after CPU-side work
  and immediately before `commit()`. `lastCommittedCommandBuffer?.waitUntilScheduled()`
  runs on the engine actor once the gate is set. D-06 commits the strict `.inactive` policy
  — even a notification banner blacks out the preview. Shape: `concurrency×lifecycle`.
- **storage×consumer**: D-02 (`.shared` start-simple default) × D-12 (natural stream
  subscribable) × ADR-20 graduation criterion. With `.shared` from Stage 01, consumer
  attach is a no-op on the Metal side — the sequence is the empty sequence. Graduation to
  dynamic `.private` → `.shared` rotation is the only path where G-25's silent-drop-on-
  `.private` failure mode applies; it is deferred to a MIGRATION stage per
  `open-questions.md` §OQ-01. Shape: `storage×consumer`.
- **error×recovery**: `CAPTURE_FAILURE` × exponential backoff × watchdog disarm order
  (D-13, Inv 12). Step 1 of recovery disarms both watchdogs before any state transition;
  Invariant 12 ensures a late-firing watchdog compares its captured session-token against
  the current one and no-ops. Without this ordering, a retry reopen can arm a fresh
  watchdog that collides with the prior watchdog's scheduled callback, producing a
  double-recovery. See `09-errors-and-recovery.md` §D-13. Shape: `error×recovery`.
- **resource×teardown**: `close()` × in-flight capture × pipeline-pointer guard (D-15,
  Inv 4). The Swift-side engine actor serializes `close()`; the C++-side `std::mutex`
  serializes the raw pointer access; the teardown ordering in `03-camera-session.md`
  §Full teardown releases GPU resources on the delivery queue context they were created
  from (Inv 2). A pure-Swift actor boundary would not suffice because the native pipeline
  pointer is accessible from external C++ callers who go through
  `getNativePipelineHandle()`. Shape: `resource×teardown`.
- **settings×session**: ISO + exposure coupling (Rules 1/2/3 in `07-settings.md` §ISO +
  exposure coupling) × `sessionQueue` config window × KVO state stream. After merge, the
  resolved pair is committed inside a single `lockForConfiguration()` window on
  `sessionQueue` via `setExposureModeCustom(durationNs:iso:)` — iOS's API shape structurally
  enforces coupling. Rule 3 (manual latches from last readback) depends on the
  `DeviceStateSnapshot` stream's most-recent value, updated via KVO per `02-concurrency.md`
  §KVO → AsyncStream adapter. Shape: `settings×session`.
- **ui×state**: `frameResultStream.bufferingNewest(1)` (ADR-22 drop semantics) ×
  `focusDistance == nil` (domain 09 §FrameResult Display). When the UI consumer misses a
  frame due to mailbox overwrite, it retains the prior `liveFrameResult`. If the prior
  result had a numeric `focusDistance` and autofocus began scanning during the skipped
  frame, the binding shows a stale numeric value rather than `nil` — the scanning animation
  never appears for that transition. This failure mode requires both the drop-semantics
  contract (ADR-22) AND the nil-semantics contract (domain 09) simultaneously; either alone
  does not surface the bug. Fix: bind the scanning indicator to the engine's `SessionState`
  or a dedicated `isAdjustingFocus` field rather than to `focusDistance` nilness.
  Shape: `ui×state`.

## Phase coverage table

Maps `domain-revised/NN-*.md` files to primary concern(s) and implementing stage(s). Stage
numbers reference `../stages/stage-index.md`.

| domain file | primary concern(s) | implementing stage(s) |
|---|---|---|
| 01-system-purpose.md | 01-system-shape, 08-ui | 01, 02 |
| 02-frame-delivery.md | 04-metal-pipeline, 05-consumers | 04, 05, 08, 10 |
| 03-camera-control.md | 03-camera-session, 07-settings | 03, 11 |
| 04-concurrency-invariants.md | 02-concurrency | 02, 04, 05, 08, 09 |
| 05-resource-lifecycle.md | 03-camera-session, 09-errors-and-recovery | 02, 03, 06, 07, 09, 12 |
| 06-error-and-recovery.md | 09-errors-and-recovery | 02, 09, 12 |
| 07-performance-budgets.md | 04-metal-pipeline, 09-errors-and-recovery | 04, 09 |
| 08-capture-and-recording.md | 06-capture-and-recording | 07, 10, 12 |
| 09-ui-behaviors.md | 08-ui | 01, 02, 04, 10, 11 |
| 10-api-contract.md | 01-system-shape, api-surface.md | 01, 03, 06, 07, 08, 11 |
| 11-what-not-to-port.md | all (excluded items) | n/a |
| 12-unresolved.md | open-questions.md | 01, 06, 07, 11 |

---

## Mechanical verification

Pre-Agent-4 gate:

```
./implementation/scripts/verify-architecture.sh implementation/
```

Checks M1–M8 defined in the implementation pipeline spec. Failures must be fixed before
Agent 4 runs.

---

## Swift skeleton

```
swift build --package-path implementation/architecture/api-skeletons/
```

Exits 0 under Swift 6 language mode + strict concurrency. Every public type named in
`api-surface.md` has a stub body of `fatalError("Stage N")`; the stage number identifies
where the real implementation lands per `../stages/stage-index.md`.
