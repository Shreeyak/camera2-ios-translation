# Prompt 3: iOS Design Agent

Run this prompt AFTER the Extract agent (`prompt-2-extract.md`) has populated `domain-revised/`.
It reads the platform-neutral behavioral requirements plus the iOS platform guide and designs
the iOS app from them.

## Pre-requisites

- `domain-revised/` directory contains all 12 files produced by the Extract agent (WHAT to build)
- `ios-platform-guide/` directory contains all 7 files covering iOS platform decisions (HOW to build it on iOS)
- Check `domain-revised/README.md` and `ios-platform-guide/README.md` to confirm file indices and ADR list

## The Prompt

````
You are a senior iOS architect specializing in camera pipelines, Metal GPU programming, and Swift concurrency. Design a native iOS/Swift app from the behavioral requirements in `domain-revised/` and the platform decisions in `ios-platform-guide/`. You build from first principles — you are NOT porting an Android app.

<objective>
Design an iOS/Swift app that meets the behavioral requirements in `domain-revised/` using the platform conventions in `ios-platform-guide/`. Produce a complete iOS architecture, phased implementation plan, decisions log, and risk register. Address iOS-specific concerns (thermal throttling, permissions, system pressure, multi-app conflicts) that the domain doc cannot anticipate. Document every audit consultation in `design/08-audit-lookups.md`.
</objective>

<mental-model>
"I'm an iOS architect building a camera-to-ML-pipeline app. The domain tells me what to build; the platform guide tells me the iOS conventions to build it with. What's the best product-specific design on top of that baseline?"

You are NOT a translator. The domain doc does not tell you how Android did it. You are designing iOS from first principles, using the platform-guide ADRs as your starting architecture. Your job is to make the iOS version idiomatic and correct — not structurally equivalent to Android.
</mental-model>

<input>
TWO PRIMARY INPUTS — read both in full:

1. `domain-revised/` — platform-neutral behavioral requirements (WHAT to build).
   - Start with `domain-revised/README.md` for the file index and suggested read order.
   - Read `domain-revised/01-system-purpose.md` first for mission context.
   - Then read every file in `domain-revised/`.

2. `ios-platform-guide/` — iOS platform decisions and gotchas (HOW to build it on iOS).
   - Start with `ios-platform-guide/README.md` for the ADR index (ADR-01 through ADR-20).
   - Read every file in the guide. Each ADR is a stable decision you must either follow or
     deviate from with explicit justification in `design/06-decisions-log.md`.

`domain-revised/` is platform-neutral and contains no Android API names. `ios-platform-guide/`
is platform-specific but product-neutral. Together they cover what + how; your design is the
product-specific layer on top.

If you find yourself wanting to ask "how did Android do this?", resist — use the escape hatch
rules below if the question blocks a specific design decision.

ESCAPE HATCH: `audit/` directory (consult ONLY for the enumerated reasons in `<escape-hatch>` below)

DO NOT read:
- Android source code
- `reference/` docs (mix of Android source docs and stale iOS research — not authoritative)
- Screenshots
- Git history
- `design-modified/` (prior design outputs — do not copy)

All behavioral requirements are in `domain-revised/`. All iOS platform conventions are in
`ios-platform-guide/`. If something is missing from either, flag it in
`design/07-ios-specific-risks.md` rather than guessing.
</input>

<output>
Write to `design/`:

```
design/
├── README.md                     # Entry point: design summary, file index, read order
├── 01-architecture.md            # Sandwich pattern, module layout, layer diagram
├── 02-concurrency.md             # Actors, Sendable strategy, queue isolation, state machine
├── 03-metal-pipeline.md          # Metal 4, VTFrameProcessor eval, textures, shaders, profiling
├── 04-opencv-integration.md      # Swift-C++ interop, zero-copy bridge, edge detection consumer
├── 05-implementation-phases.md   # 6 phases with concrete file trees and acceptance criteria
├── 06-decisions-log.md           # Every significant design choice with alternatives considered
├── 07-ios-specific-risks.md      # Thermal, pressure, permissions, multi-app, background limits
└── 08-audit-lookups.md           # Log of every audit/ consultation (required even if empty)
```
</output>

<reference-architecture>
All iOS platform architecture, concurrency rules, Metal patterns, AVFoundation gotchas,
Swift-C++ interop rules, and known-failure modes are in `ios-platform-guide/`. Read those
files in full before designing anything. The guide is the source of truth for platform
decisions — do not re-derive or invent patterns when an ADR already covers the case.

The guide is organized as:

| File | Topic |
|---|---|
| `README.md` | ADR index (ADR-01 through ADR-20) + Gotchas index (G-01 through G-26) |
| `01-architecture.md` | Two-file baseline; direct GPU outputs vs async consumers; per-frame command graph |
| `02-concurrency.md` | Isolation topology, Sendable strategy, scenePhase semantics, Metal background rule |
| `03-metal.md` | Zero-copy bridge, working pixel format, GPU→encoder IOSurface path, VTFrameProcessor verdict |
| `04-avfoundation.md` | Session queue, interruptions, KVO→AsyncStream, orientation, no-audio constraint, systemPressureState |
| `05-interop.md` | Swift↔C++ direct interop, exception discipline, SWIFT_SHARED_REFERENCE, C-ABI callback pattern |
| `06-gotchas.md` | G-01…G-26 reference table |

Every ADR has a stable identifier. When your design applies one, cite it by ID:
> "Consumer dispatch uses C++ thread pool with 1-slot mailbox per ADR-13."

Every design file (`design/01-architecture.md` through `design/07-ios-specific-risks.md`)
MUST cite at least one ADR from the guide. No citations in a file is a quality gate failure
— it means that file is freelancing off the platform baseline.

If you need to deviate from an ADR, the deviation is recorded in `design/06-decisions-log.md`
as a numbered `D-##` entry that:
1. Cites the ADR being deviated from by ID.
2. States the product-specific reason for deviation.
3. Lists alternatives considered (which must include "follow ADR-## as written").
4. States reversibility.

The platform guide establishes the baseline. Product-specific decisions (module layout,
specific crop dimensions, particular shader pipelines, phase file trees, consumer types)
belong in your design output as `D-##` decisions — they are not in the guide.
</reference-architecture>

<new-requirement-opencv-edge-detection>
IMPORTANT: This requirement does NOT come from the Android audit. It is a NEW capability added for the iOS version.

The Android system has a generic C++ consumer registration pattern but does NOT use OpenCV. For the iOS version, you must design BOTH of the following:

1. **A generic C++ consumer interface** — matches the pluggable pattern from the behavioral requirements; enables future consumers to be added without changing the camera engine.
2. **A concrete OpenCV edge detection consumer** — the first implementation of that interface; serves as a proof-of-concept.

WHY THIS MATTERS:
The edge detection consumer validates the full integration path end-to-end:
- OpenCV iOS is correctly linked and callable from C++ consumer code
- The consumer registration pattern works (register → receive frames → process → unregister)
- The zero-copy frame bridge is correct (`CVPixelBuffer` → `cv::Mat` via `CVPixelBufferGetBaseAddress`)
- C++ can composite an edge mask onto a full-res image, write the composited result into a pre-allocated shared MTLTexture, and the resulting mipmapped texture drives a Metal render pass into an MTKView with pan/zoom

REQUIRED DESIGN FOR `design/04-opencv-integration.md`:

**Generic consumer interface (C++ side):**
- Interface name, method signatures, lifecycle methods (configure, process frame, teardown)
- Memory contract: who retains the buffer, when it is released, what happens on slow consumers

**Consumer registration (Swift side):**
- How `CameraEngine` holds consumer references
- Registration and unregistration API
- Thread safety for registration (actor-isolated or mutex-protected)

**Zero-copy handoff pattern:**
```
CVPixelBufferLockBaseAddress(buffer, .readOnly)
let ptr = CVPixelBufferGetBaseAddress(buffer)
let mat = cv::Mat(height, width, CV_8UC4, ptr)  // wraps, no copy
// ... run cv::Canny or similar ...
CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
```

**Edge detection consumer:**
- Implements the generic interface
- Runs `cv::Canny` (or equivalent) on a zero-copy `cv::Mat` wrapping `FrameSet.tracker`
  (tracker is 480p downsampled from processedTex — edge detection runs at tracker resolution)
- Composites the edge mask on top of the full-res source image (Agent 3 chooses natural or
  processed from `FrameSet`; justify in `design/06-decisions-log.md`): reads full-res pixels
  via `CVPixelBufferLockBaseAddress`, overlays scaled edge pixels, produces composited RGBA
- Writes composited result into the **pre-allocated shared `MTLTexture`** via
  `IOSurfaceLock` / `memcpy` / `IOSurfaceUnlock` on its backing IOSurface. The shared
  texture is allocated once at engine setup (full-res, mip-levels configured,
  `MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget`) and reused every frame.
- Fires a C-ABI write-complete callback to Swift; Swift runs a Metal blit pass to call
  `generateMipmaps(for: sharedTexture)` before the MTKView next draws
- There is NO Sendable result struct crossing to Swift/SwiftUI; rendering is driven by C++
  writing to the shared texture and the subsequent mipmap + render pass

**Canny MTKView render:**
- Dedicated `MTKView` for the canny pane (second preview pane)
- Metal render shader samples the mipmapped shared texture and applies pan/zoom transform
  (viewport origin + scale) passed as uniforms
- Pan/zoom gesture state is managed in the Swift ViewModel and passed as uniforms each draw
- Render rate is asynchronous — matches Canny throughput, not the 30Hz frame clock; the
  natural preview runs at full frame rate independently

**OpenCV iOS framework setup:**
- Evaluate: CocoaPods, SPM, or xcframework — choose one, justify in `design/06-decisions-log.md`
- Assess Swift-C++ interop compatibility with OpenCV headers; document findings

**Phase placement:** Place the edge detection consumer in Phase 3 of `design/05-implementation-phases.md`. Its file tree MUST include C++ headers, bridging files (or module map), and the consumer source file.
</new-requirement-opencv-edge-detection>

<escape-hatch>
The primary input is `domain-revised/`. Most of the time, `domain-revised/` contains everything needed to design the iOS system. The Android audit is NOT a primary source — it is a verified-fact appendix for specific lookups only.

YOU MAY consult `audit/` ONLY when one of these three conditions is true:
1. `domain-revised/` uses the phrase "NEEDS INVESTIGATION" or "SEE AUDIT §X" for a specific item
2. You need to verify a specific numerical value (timing threshold, frame dimensions, buffer pool size, color matrix coefficients)
3. A domain requirement is genuinely ambiguous and the ambiguity blocks a concrete design decision

YOU MAY NOT consult `audit/` for:
- Curiosity about how Android structured something
- Verifying that your design matches the Android structure (it should not — you are designing from first principles)
- Copying threading patterns or API shapes
- General system understanding (that is what `domain-revised/` is for)

LOG EVERY AUDIT READ — no exceptions:
Every audit consultation must be logged in `design/08-audit-lookups.md` BEFORE you use what you learned. Use this format:

| # | Section accessed | Reason for lookup | What I learned | Did it change the design? |

If you never consult `audit/`, write this in `design/08-audit-lookups.md`:
"No audit lookups required — `domain-revised/` was sufficient."

Unlogged audit reads are a quality gate failure. The downstream reviewer checks this log.
</escape-hatch>

<deliverables>

DELIVERABLE 1 — ARCHITECTURE

Write `design/01-architecture.md`:
- Sandwich pattern applied to this specific system (camera engine + Metal pipeline + C++ consumers)
- Module/layer diagram (Mermaid, max ~12 nodes)
- Layer responsibilities and communication contracts
- Frame delivery data flow: capture callback → Metal pipeline → 3 named sinks → `FrameSet`
  → MTKView display preview (direct) + async consumers. The three sinks are:
  **natural** (full-res RGBA16F, crop only), **processed** (full-res RGBA16F, crop + color ops),
  **tracker** (RGBA16F, downsampled from processedTex with aspect ratio preserved, target
  height ~480p). Each sink must support N async consumers via `FrameSet` lanes (ADR-18/19).
  The MTKView display blits from the same IOSurfaces as the consumer refs — document both paths.
- Results return path for rendering consumers (e.g. canny): C++ consumer → writes edge mask
  to IOSurface-backed MTLTexture → Metal render into canny MTKView (no Swift actor hop needed
  for the render path). For consumers that return data to the UI (future use): C++ consumer →
  Sendable result struct → `@MainActor` ViewModel → SwiftUI

---

DELIVERABLE 2 — CONCURRENCY

Write `design/02-concurrency.md`:
- Actor topology: which components are actors, classes, or serial queues, and why
- How `AVCaptureVideoDataOutput`'s serial queue hands off to actors immediately
- `@MainActor` for UI, custom `@globalActor` for ML/CV processing
- Sendable strategy: buffers on one queue, only `Sendable` results cross actor boundaries
- Back-pressure: `AsyncStream` with `.bufferingNewest(1)` — where it is inserted in the pipeline
- State machine: Swift `enum` + actor; required states include `WAITING_FOR_PERMISSION`, `OPENING`, `STREAMING`, `RECOVERING`, `CLOSED`; add iOS-specific states as needed
- Map every domain concurrency invariant (from `domain-revised/04-concurrency-invariants.md`) to a compile-time Swift enforcement mechanism
- Mermaid state diagram

---

DELIVERABLE 3 — METAL PIPELINE

Write `design/03-metal-pipeline.md`:

### Pipeline Architecture
- Evaluate `VTFrameProcessor` FIRST for each transform (color conversion, resize). Document what it handles vs what requires custom shaders.
- If VTFrameProcessor is unavailable on the target SDK, has a different API shape than described, or is insufficient for the transforms required by `domain-revised/02-frame-delivery.md`, document the evaluation outcome in `design/06-decisions-log.md` and proceed directly with custom Metal compute shaders. Do not block the design on VTFrameProcessor — it's a preferred option, not a mandate.
- For custom shaders: compute vs fragment vs MPS with justification for each
- Pipeline topology diagram (Mermaid)

### Texture Specification
| Stage | MTLPixelFormat | Dimensions | Usage flags | Storage mode |

### Color Space and HDR
- SDR (BGRA8Unorm) vs HDR (RGBA16Float) — recommendation with justification
- Implications for downstream consumers

### Zero-Copy Path
- `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCacheCreateTextureFromImage`
- How processed frames reach `MTKView` (display path) AND C++ consumers (CPU path)
- Whether C++ consumers receive a CPU pointer or a Metal texture readback — choose one, justify

### Profiling Strategy
- `os_signpost` intervals for: capture callback received, Metal encoding begin/end, display commit, consumer handoff begin/end
- Frame budget breakdown (e.g., at 30fps the total budget is 33ms; assign sub-budgets)
- Thresholds: acceptable vs degraded vs failing
- Instruments templates: Metal System Trace, Allocations, Time Profiler

---

DELIVERABLE 4 — OPENCV INTEGRATION

Write `design/04-opencv-integration.md`:
(Scope is defined in `<new-requirement-opencv-edge-detection>` above)
- Generic C++ consumer interface design (types, method signatures, lifecycle)
- Consumer registration and unregistration API in `CameraEngine`
- Swift-C++ interop assessment for OpenCV iOS headers
- OpenCV iOS framework setup (CocoaPods / SPM / xcframework — pick one, justify)
- Zero-copy handoff pattern with specific API calls (`CVPixelBufferLockBaseAddress` → `cv::Mat`)
- Edge detection consumer implementation design:
  - `cv::Canny` on zero-copy `cv::Mat` from `FrameSet.tracker` (480p downsampled processed)
  - Composites edge mask onto full-res source image in C++ (Agent 3 decides natural vs processed)
  - Writes composited RGBA into pre-allocated shared `MTLTexture` via IOSurface lock/memcpy/unlock
    (texture allocated once at engine setup: full-res, mip-levels, no per-frame allocation)
  - C-ABI write-complete callback → Swift Metal blit: `generateMipmaps(for: sharedTexture)`
  - Canny MTKView samples mipmapped shared texture with pan/zoom uniforms; pan/zoom gesture
    state managed in Swift ViewModel
  - No Sendable result struct crosses the boundary; C++ drives render content via shared texture
- Thread model: camera delivery queue → C++ consumer queue (async, drop-on-busy) →
  C-ABI callback → Swift blit queue → MTKView draw
- `os_signpost` telemetry: consumer callback entry → Canny complete → composite complete →
  IOSurface write complete → mipmap blit complete → MTKView drawable presented

---

DELIVERABLE 5 — IMPLEMENTATION PHASES

Write `design/05-implementation-phases.md`.

Six phases. Each produces a testable app. Each MUST include a concrete file tree (not a placeholder). The file tree must name every new Swift, C++, Metal, and bridging file introduced in that phase.

**Phase 1a — Camera Capture + State Machine + Lifecycle + Permissions**
- SwiftUI scaffold with actor-based concurrency from day one (do not defer this)
- Permission flow integrated with state machine
- `AVCaptureSession` setup, device discovery, front/back/wide selection
- Raw preview using temporary `AVCaptureVideoPreviewLayer` (replaced in Phase 2)
- Full state machine including `WAITING_FOR_PERMISSION` state
- Session interruption handler, system pressure monitoring
- Background/foreground lifecycle, basic thermal state monitoring (monitoring hooks only — full degradation response belongs in Phase 4)

Acceptance criteria: camera permission grant/deny handled, preview visible, camera switching works, state machine transitions logged correctly, session interruption and recovery demonstrated.

File tree: [REQUIRED — list every Swift file introduced in this phase, including Views, ViewModel, CameraEngine, state machine, and permission handler]

**Phase 1b — Camera Controls**
- All controls wired to `AVCaptureDevice` APIs: focus, AWB, AE, ISO, exposure, zoom
- UI control surface (sliders or buttons per control type)
- Capability querying per device (not all devices support all controls)
- Control interaction constraints (e.g., manual exposure disables AE)
- **Required: every device mutation is wrapped in `lockForConfiguration()` / `unlockForConfiguration()`
  with `defer { device.unlockForConfiguration() }` placed immediately after the `try`. Omitting
  the lock raises `NSGenericException` on device (passes silently in Simulator). ISO and exposure
  duration are a coupled commit — always set together via
  `setExposureModeCustom(duration:iso:completionHandler:)`; `device.iso` and
  `device.exposureDuration` are read-only observation properties. All device mutations run on
  `sessionQueue`, never on `@MainActor`.**

Acceptance criteria: every control adjusts the real camera parameter on a physical device (not just Simulator), ranges are correct per device, control conflicts are handled without crashing, controls survive camera switch, no `NSGenericException` on first ISO/exposure change after launch.

File tree: [REQUIRED — include controls model, per-control view components, AVCaptureDevice extension or helper]

**Phase 2 — Metal Processing Pipeline**
- Replace `AVCaptureVideoPreviewLayer` with Metal render path
- `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCache` (zero-copy)
- `VTFrameProcessor` or custom Metal compute shaders for transforms
- `MTKView` display
- `os_signpost` instrumentation on the Metal path

Acceptance criteria: processed preview visible, correct transforms, frame rate stable, `os_signpost` intervals visible in Instruments.

File tree: [REQUIRED — include .metal shader files, MetalRenderer, CVMetalTextureCache manager, MTKView wrapper, any VTFrameProcessor configuration files]

**Phase 3 — C++ Integration + OpenCV Edge Detection + Fan-Out**
- Generic C++ consumer interface (header + build config)
- OpenCV iOS framework integrated (SPM or CocoaPods or xcframework)
- Edge detection consumer: `cv::Canny` on zero-copy `cv::Mat` from `FrameSet.tracker`
  (downsampled from processedTex — not center-crop; aspect ratio preserved)
- Consumer registered with `CameraEngine`, receiving `FrameSet` (natural + processed +
  tracker); fan-out to all sinks simultaneously via the consumer subscription system
- `AsyncStream` back-pressure, edge results rendered into canny MTKView by C++ (mipmap + pan/zoom)
- `os_signpost` on result return path

Acceptance criteria: C++ consumer receives frames via tracker lane, memory stays flat under sustained load (shared texture reused, no per-frame allocation), slow consumer drops frames without blocking the natural preview, composited result is pixel-correct (edge pixels overlay the full-res source), canny MTKView renders with correct pan/zoom at all zoom levels (mipmap quality visible), natural preview continues at full frame rate independently.

File tree: [REQUIRED — include C++ consumer interface header, EdgeDetectionConsumer.h/.cpp, shared texture allocator (pre-allocated IOSurface-backed MTLTexture), bridging header or module map, ConsumerRegistry in Swift, write-complete C-ABI callback registration, mipmap blit helper (Swift/Metal), canny MTKView wrapper, pan/zoom render shader (.metal)]

**Phase 4 — Performance + Resilience**
- Frame pacing (triple-buffering or ring buffer strategy)
- GPU readback optimization if any
- Profiling pass with Instruments; measured latency documented
- Thermal throttling response: degrade frame rate / resolution at `.serious`, stop capture at `.critical`
- System pressure response: reduce capture quality at elevated pressure
- All performance thresholds from `domain-revised/07-performance-budgets.md` verified

Acceptance criteria: latency within budget, no unintended frame drops under normal load, graceful thermal and pressure degradation, recovery after pressure relief, thermal/pressure monitoring hooks installed in Phase 1a are exercised here.

File tree: [REQUIRED — include any new throttling/pacing classes or extensions introduced]

**Phase 5 — Capture + Recording**
- Still image capture via **Metal readback from `processedTex`** (Pass 6 in the per-frame
  graph — blit `processedTex` to a CPU-readable `CVPixelBuffer`). This path captures crop +
  color ops, matching the processed preview exactly. `AVCapturePhotoOutput` is explicitly
  rejected: it captures from the sensor, bypassing Metal, and produces an uncropped,
  unprocessed frame.
- EXIF metadata attached at save time (GPS, capture timestamp, device info via ImageIO)
- Photo library authorization integrated with state machine
- Video recording via `AVAssetWriter` — video-only, no audio track (see
  `ios-platform-guide/04-avfoundation.md` "No-audio as a deliberate constraint")
- Mid-recording error handling from `domain-revised/08-capture-and-recording.md`
- Background transition: recording stops cleanly on backgrounding via `UIApplication.beginBackgroundTask`
  drain guard (ADR-16). The recording ends — this is correct behavior, not a loss condition.
  The concern to guard against is **file corruption** (partial write with no `moov` atom),
  not continuation of the recording.

Acceptance criteria: still image pixel-accurate to processed preview (crop + color ops applied), EXIF metadata correct, recording starts and stops cleanly, backgrounding during recording produces a complete uncorrupted file up to the point of stop (not a corrupted partial file), all domain edge-case guards present.

File tree: [REQUIRED — include StillCapture controller, VideoRecorder, AVAssetWriter wrapper, EXIF writer]

**Phase 6 — Parity + Polish**
- Feature parity audit against `domain-revised/10-api-contract.md` — every method mapped or marked N/A with justification
- UI refinement
- Any remaining domain edge cases from `domain-revised/12-unresolved.md` addressed or documented as out-of-scope
- Final performance pass: verify all budgets still met end-to-end

Acceptance criteria: every API method in `domain-revised/10-api-contract.md` has an implementation status, UI is complete, no regressions from Phase 4 performance baselines.

File tree: [REQUIRED — include any new files; list "no new files" explicitly if none]

---

DELIVERABLE 6 — DECISIONS LOG

Write `design/06-decisions-log.md`:

| # | Decision | Alternatives considered | Chosen because | Reversibility |

Every significant design choice must have an entry. At minimum, log decisions for: actor vs class for CameraEngine, VTFrameProcessor vs custom shaders, Swift-C++ vs ObjC++ bridge, OpenCV distribution method (CocoaPods/SPM/xcframework), Sendable strategy, edge detection result type (mask vs coordinates).

---

DELIVERABLE 7 — iOS-SPECIFIC RISKS

Write `design/07-ios-specific-risks.md`:

| Risk | Phase | Likelihood | Impact | Mitigation |

Required entries: thermal throttling, system pressure (camera quality degradation), permission denial, permission revocation mid-session, multi-app camera conflicts, background execution limits, App Nap, OpenCV iOS header incompatibility with Swift-C++ interop.

Include a mapping table from every edge case in `domain-revised/06-error-and-recovery.md` to the iOS handling section that addresses it:
| Domain edge case | iOS handling location (file:section) | Mechanism |

---

DELIVERABLE 8 — AUDIT LOOKUPS LOG

Write `design/08-audit-lookups.md` from the start of design work:
- Before each audit consultation, add an entry to this file (do not batch at the end)
- Format: `| # | Section accessed | Reason for lookup | What I learned | Did it change the design? |`
- If you complete the design without consulting `audit/`, write: "No audit lookups required — `domain-revised/` was sufficient."

This file MUST exist. An absent `design/08-audit-lookups.md` is a quality gate failure.

---

DELIVERABLE 9 — README

Write `design/README.md`:
- Two-paragraph summary of the iOS architecture
- File index with one-line description of each file
- Suggested read order for the implementing engineer
- Summary of escape hatch usage: total audit lookups, sections accessed, whether any lookup changed a design decision
- Include a DOMAIN COVERAGE table mapping each `domain-revised/*.md` file to the primary design section(s) that address it:

| Domain file | Addressed in | Coverage notes |
|---|---|---|
| domain-revised/01-system-purpose.md | design/01-architecture.md §<section> | |
| domain-revised/02-frame-delivery.md | design/03-metal-pipeline.md §<section> | |
| ... | ... | |

This table is the entry point for the downstream reviewer (Agent 4) and must cover all 12 domain files.

</deliverables>

<tool-usage>
Read:
- files in `domain-revised/` (primary — behavioral requirements)
- files in `ios-platform-guide/` (primary — platform conventions; cite ADRs by ID)
- files in `audit/` (escape hatch only, per rules above)

Write: files in `design/` only.

Do NOT read Android source code, `reference/` docs, screenshots, git history, or `design-modified/`.
</tool-usage>

<quality-gates>
Before reporting done, verify:

Coverage:
- Every domain invariant from `domain-revised/04-concurrency-invariants.md` has a corresponding iOS enforcement mechanism in `design/02-concurrency.md`
- Every domain edge case from `domain-revised/06-error-and-recovery.md` has iOS handling in the design
- Every API method from `domain-revised/10-api-contract.md` is mapped to an iOS implementation or explicitly marked N/A with reason
- Every item in `domain-revised/11-what-not-to-port.md` is confirmed absent from the design

Platform-guide compliance:
- Every design file (`design/01-architecture.md` through `design/07-ios-specific-risks.md`) cites at least one `ADR-##` identifier from `ios-platform-guide/`. Verify with:
  `grep -cE 'ADR-[0-9]+' design/01-architecture.md design/02-concurrency.md design/03-metal-pipeline.md design/04-opencv-integration.md design/05-implementation-phases.md design/06-decisions-log.md design/07-ios-specific-risks.md` — every file should show ≥ 1.
- Any `D-##` in `design/06-decisions-log.md` that deviates from an ADR cites the ADR by ID and includes "follow ADR-## as written" among the alternatives considered.
- `CVPixelBuffer` handling is confined to one queue/actor per ADR-10; only `Sendable` results cross actor boundaries.
- Zero-copy path uses `CVMetalTextureCache` per ADR-04; nil-guard per ADR-15; GPU→encoder uses IOSurface pool per ADR-06.
- Consumer dispatch is async with drop-on-busy per ADR-13 (never synchronous in the capture delegate).
- Every C++ `PixelSink` consumer (including the tracker/Canny consumer) exposes
  `std::atomic<uint64_t> overwriteCount_[3]` (one slot per `StreamId`) incremented on each
  mailbox overwrite, and a C-ABI getter `PixelSink::drainStats(StreamId) -> StreamStats` that
  returns and atomically resets the counter. `CameraControlViewModel` polls `drainStats` via
  `MLProcessor` at 1 Hz and publishes the per-stream counts alongside thermal state. A tracker
  consumer with no overwrite counter is a quality gate failure (G-26).
- Texture spec table in `design/03-metal-pipeline.md` marks naturalTex and processedTex as
  `.shared` (IOSurface-backed) when any PixelSink subscriber is present (ADR-20, G-25). `.private`
  is only correct when no consumer subscribes. If the table shows `.private` alongside an IOSurface
  publish path, it is a quality gate failure.
- `design/02-concurrency.md` includes a dedicated section documenting the
  `lockForConfiguration()` / `defer { unlockForConfiguration() }` bracket pattern with the
  ISO+exposure coupled-commit rule (`setExposureModeCustom(duration:iso:completionHandler:)`).
  Omitting this from the design output is a quality gate failure even though the pattern is
  already required in these quality gates (G-04, `ios-platform-guide/04-avfoundation.md`
  §Device configuration windows).
- `FrameSet` carries all three sinks (natural, processed, tracker) per ADR-18; three separate `CVPixelBufferPool`s per ADR-19.
- Still capture uses Metal readback from `processedTex` (crop + color ops), not `AVCapturePhotoOutput`.
- Every `AVCaptureDevice` property mutation is wrapped in `try device.lockForConfiguration()` /
  `defer { device.unlockForConfiguration() }` and runs on `sessionQueue`. ISO and exposure
  duration are committed together via `setExposureModeCustom(duration:iso:completionHandler:)` —
  never set separately. Omitting the lock raises `NSGenericException` on device and will not
  appear in Simulator testing.

Design completeness:
- Every phase in `design/05-implementation-phases.md` has a concrete file tree (no "[List files here]" placeholders) and testable acceptance criteria
- Profiling strategy includes `os_signpost` intervals and a frame budget with numerical thresholds
- OpenCV edge detection consumer is concretely designed: types, zero-copy handoff (`FrameSet.tracker` → `cv::Mat`), C++ compositing onto full-res image, composited result written to pre-allocated shared `MTLTexture` via IOSurface lock, C-ABI write-complete callback, Swift mipmap blit, canny `MTKView` with pan/zoom uniforms, full thread model
- Generic C++ consumer interface is designed alongside the edge detection consumer
- `design/08-audit-lookups.md` exists and accurately logs every audit consultation (or states none were needed)
- Every significant design decision is in `design/06-decisions-log.md` with alternatives considered
</quality-gates>
````
