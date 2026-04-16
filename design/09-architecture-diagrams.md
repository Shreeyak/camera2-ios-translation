# 09 — Architecture Diagrams

Visual reference for the iOS architecture. Diagrams are authored in **Mermaid** — the source
text in each code block is the canonical form, so both humans (rendered on GitHub / in IDEs /
in Claude Code UI) and LLM agents (reading the raw markdown) see the same structure.

This file is a **reference companion** to `01-architecture.md` through `08-audit-lookups.md`.
Every diagram cross-links to the design file(s) where the component is specified in prose.

**Sidecar files in [`diagrams/`](diagrams/)**:
- `diagrams/NN-name.mmd` — extracted standalone Mermaid source for each diagram (editable, shareable)
- `diagrams/NN-name.png` — pre-rendered PNG at 2× scale with white background (for slide decks,
  issue attachments, and tools that can't render Mermaid)

**To regenerate** after editing any diagram in this file:
```sh
./design/diagrams/render.sh
```
That script calls `design/diagrams/extract.py` (re-extracts all mermaid blocks into `.mmd`
sidecar files) and then runs `mmdc` on each to produce the PNGs. Prerequisites:
```sh
npm install -g @mermaid-js/mermaid-cli
```
If you add or remove a diagram from this file, update `NAMES` in `extract.py` to match the
new block order.

**Mermaid gotchas encountered during initial rendering** (keep in mind when editing):
- **Semicolons** `;` are treated as statement terminators in Mermaid — they cannot appear inside
  sequence-diagram messages, notes, or edge labels. Use `—`, `/`, or `and` instead.
- **The `@` character** in flowchart node labels is lexed as the new typed-shape/edge sigil
  (e.g. `A@{shape: rect}`). Labels containing `@MainActor`, `@Observable`, etc. must be
  wrapped in double quotes: `VM["CameraViewModel<br/>@Observable"]`.
- **`---|label|`** (undirected link with label) is not valid syntax — use a directed link
  `-->|label|` or an unlabeled undirected link `---`.

---

## Contents

**Part 1 — Architecture / flow diagrams**
1. [System context](#1--system-context) — app boundary and iOS service dependencies
2. [Actor topology](#2--actor-topology) — Swift actors and their message channels
3. [Frame data-flow + buffer ownership](#3--frame-data-flow--buffer-ownership) — 4-stream pipeline with per-buffer ownership table
4. [Metal pipeline internals](#4--metal-pipeline-internals) — compute kernel inputs/outputs and post-encode blits
5. [Error propagation](#5--error-propagation) — how errors reach the UI and the recovery paths

**Part 2 — Sequence diagrams**
6. [Hot path: capture → display](#6--hot-path-capture--display) — the 33 ms per-frame budget
7. [Fan-out to C++ consumer](#7--fan-out-to-c-consumer-1-slot-mailbox) — 1-slot mailbox drop-on-busy semantics
8. [GPU-to-encoder zero-copy recording](#8--gpu-to-encoder-zero-copy-recording) — IOSurface never touches the CPU
9. [Actor re-entrancy guard](#9--actor-re-entrancy-guard-f-01) — close() during an in-flight frame
10. [Still capture in-flight guard](#10--still-capture-in-flight-guard) — concurrent capture rejection

---

## How to read the diagrams

- **Solid arrows** (`-->`): synchronous call, actor-to-actor `await`, or command-buffer encoding step
- **Dashed arrows** (`-.->`): asynchronous or conditional flow (AsyncStream delivery, callbacks, optional paths)
- **Colors on `subgraph` boundaries** (where present): isolation domain (actor vs `@MainActor` vs `nonisolated`)
- **In sequence diagrams**: `activate` / `deactivate` on a participant lifeline = that participant is currently processing a message; the bar visualizes holding the actor

Every structural decision shown here has a corresponding prose entry in `06-decisions-log.md`
or a risk entry in `07-ios-specific-risks.md`. When a diagram and prose disagree, the prose wins
and the diagram should be patched.

---

# Part 1 — Architecture / Flow

## 1 — System context

The app's dependency boundary against iOS system frameworks and the single external library (OpenCV).
This is the C4-level-1 view — "what does CamPlugin touch in the outside world?"

Cross-ref: `01-architecture.md §System Overview`, `06-decisions-log.md D-05, D-11`.

```mermaid
flowchart TB
    User([User])

    subgraph App["CamPlugin (this project)"]
        direction TB
        Core["Swift app<br/>CaptureActor / FramePipeline · actors<br/>Metal pipeline · C++ consumers"]
    end

    User -->|taps, gestures,<br/>scene transitions| App
    App -->|preview, edges,<br/>capture banner| User

    App -->|configure session<br/>receive sample buffers<br/>capturePhoto| AVF[AVFoundation]
    App -->|MTLDevice, command queue<br/>compute + blit passes| Metal[Metal]
    App -->|texture cache<br/>IOSurface wrapping| TC[CoreVideo<br/>CVMetalTextureCache]
    App -->|append pixel buffers| VT[VideoToolbox<br/>HEVC / H.264]
    App -->|CGImageDestination<br/>EXIF properties dict| IO[ImageIO / CoreGraphics]
    App -->|addOnly authorization<br/>performChanges| Photos[Photos<br/>PHPhotoLibrary]
    App -->|thermalState notification<br/>systemPressureState KVO| Foundation[Foundation<br/>ProcessInfo]
    App -->|beginBackgroundTask<br/>for recording drain| UIKit[UIKit<br/>UIApplication]
    App -->|scenePhase, lifecycle| SwiftUI[SwiftUI]
    App -->|edge detection on<br/>tracker 480px stream| OpenCV[OpenCV 4<br/>xcframework]

    AVF -.->|opens| Camera[Back-facing main lens<br/>single physical camera]
    Metal <-->|IOSurface<br/>zero-copy| VT

    classDef ext fill:#eef,stroke:#88a,color:#000
    classDef hw fill:#fed,stroke:#a85,color:#000
    class AVF,Metal,TC,VT,IO,Photos,Foundation,UIKit,SwiftUI,OpenCV ext
    class Camera,User hw
```

**Key takeaways:**
- Single physical camera by product decision (`domain/12-unresolved.md §U-17`).
- Metal ↔ VideoToolbox zero-copy is the *only* arrow that is bidirectional — both read and write the same `IOSurface`-backed pixel buffers.
- OpenCV is the only non-Apple dependency.
- No microphone / `AVAudioSession` boundary (`05-implementation-phases.md §Phase 5` — video-only recording).

---

## 2 — Actor topology

Swift isolation domains and the message channels between them. This is where Invariants 1, 2,
4, 5, 6, 7, and 10 from `domain/04-concurrency-invariants.md` are enforced structurally.

Cross-ref: `02-concurrency.md §Isolation Taxonomy`, `02-concurrency.md §Domain Invariant Mapping`,
`06-decisions-log.md D-01, D-10, D-12`.

```mermaid
flowchart TB
    subgraph MainIso["@MainActor — UI thread"]
        VM["CameraViewModel<br/>@Observable"]
        UI[SwiftUI Views]
        VM -->|binds to| UI
    end

    subgraph Nonisolated["nonisolated — system-driven"]
        CD[CaptureDelegate<br/>AVFoundation sample buffer delegate]
        MR[MetalRenderer<br/>MTKViewDelegate]
        NMR[NaturalMetalRenderer<br/>MTKViewDelegate]
    end

    subgraph Engine["CaptureActor (CaptureKit) + FramePipeline (PipelineKit)"]
        CE[CaptureActor: session state<br/>stall watchdogs<br/>recovery state machine]
        FP[FramePipeline: nonisolated<br/>AVCaptureVideoDataOutputSampleBufferDelegate<br/>drives 6-pass Metal command graph]
    end

    subgraph Support["Support actors"]
        SC[StillWriter<br/>actor — EncoderKit]
        VR[RecordingActor<br/>actor — EncoderKit]
    end

    subgraph ML["@MLProcessor — global actor"]
        MLP[edge result coalescing<br/>overlay state]
    end

    subgraph Cpp["C++ consumers (PixelSink pool)"]
        EDC[EdgeDetector<br/>C++ SWIFT_SHARED_REFERENCE<br/>ImagingCore]
        PS[PixelSink<br/>C++ SWIFT_SHARED_REFERENCE<br/>fixed thread pool, MPSC lanes]
    end

    VM -->|await open / close<br/>await setResolution<br/>await setProcessingParameters| CE
    VM -->|await captureNaturalPicture<br/>await captureImage| SC
    VM -->|await startRecording<br/>await stopRecording| VR

    CE -.->|AsyncStream:<br/>onStateChanged<br/>onError<br/>onFrameResult| VM

    FP -->|"Frame (IOSurface-backed)<br/>inline on delivery queue"| PS

    CE -->|OSAllocatedUnfairLock<br/>withLock publish| MR
    CE -->|OSAllocatedUnfairLock<br/>withLock publish| NMR
    MR -->|Task MainActor<br/>setNeedsDisplay| MR
    NMR -->|Task MainActor<br/>setNeedsDisplay| NMR

    PS -.->|1-slot mailbox<br/>MPSC per stream| EDC
    EDC -.->|EdgeDetectionResult<br/>Sendable C-ABI callback| MLP
    MLP -.->|AsyncStream| VM

    FP -->|await append<br/>recording frame| VR
    SC -->|await session access<br/>AVCapturePhotoOutput| CE
    VR -->|await session access| CE

    classDef main fill:#ffe,stroke:#aa6,color:#000
    classDef actor fill:#eef,stroke:#66a,color:#000
    classDef noniso fill:#fee,stroke:#a66,color:#000
    classDef cpp fill:#efe,stroke:#6a6,color:#000
    class VM,UI main
    class CE,SC,VR,MLP actor
    class CD,MR,NMR,FP noniso
    class EDC,PS cpp
```

**Key takeaways:**
- Solid arrows = synchronous `await` across actors. Dashed = async continuous delivery (`AsyncStream`).
- `MetalRenderer`, `CaptureDelegate`, and `FramePipeline` are **nonisolated** by necessity — they're invoked by
  the system (MTKView timer, AVFoundation serial queue) and cannot be actor-isolated without
  deadlocking. `FramePipeline` runs inline on the delivery queue (no `Task{}`).
- The crossings from the `CaptureActor` **to** the nonisolated renderers use
  `OSAllocatedUnfairLock<MTLTexture?>` for the texture slot — actor isolation alone does not
  protect these reads (F-01 / C-03).
- `PixelSink` is a C++ `SWIFT_SHARED_REFERENCE` class, not a Swift actor — consumer dispatch
  is handled entirely in C++ via per-stream MPSC lanes with 1-slot mailboxes.
- `@MLProcessor` is a custom global actor that keeps edge-detection result handling off the
  camera hot path.

---

## 3 — Frame data-flow + buffer ownership

The structural "where does each frame go" with the 4 parallel output streams. Detailed buffer
ownership lives in the table below the diagram.

Cross-ref: `03-metal-pipeline.md` (entire file), `domain/02-frame-delivery.md` §Parallel Stream Outputs.

### 3a — Data flow

```mermaid
flowchart TB
    HW[Back-main camera sensor]

    subgraph CaptureLayer["AVCaptureSession"]
        direction TB
        AVOut[AVCaptureVideoDataOutput]
        AVPhoto[AVCapturePhotoOutput]
    end

    HW --> AVOut
    HW --> AVPhoto

    AVOut -->|CVPixelBuffer<br/>kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange<br/>~4000x3000| CD[CaptureDelegate]
    CD -->|Frame (IOSurface-backed)| CE[FramePipeline — inline on delivery queue]

    subgraph EngineWork["FramePipeline (nonisolated) — per frame work"]
        direction TB
        CE --> Wrap[CVMetalTextureCache wrap]
        Wrap -->|rgba16Float| Compute
        Compute[Metal compute kernel<br/>half-float RGBA<br/>5-stage color pipeline]
    end

    Compute -->|rgba16Float<br/>full res| Proc[processedTexture]
    Compute -->|rgba16Float<br/>full res, passthrough| Nat[naturalTexture]
    Compute -->|rgba16Float<br/>480px height| Trk[trackerTexture]
    Compute -.->|bgra8Unorm<br/>downcast for encoder,<br/>only while recording| EncT[encoderTexture<br/>from IOSurface pool]

    Proc -->|OSAllocatedUnfairLock<br/>publish| PSlot[processedTextureSlot]
    Nat -->|OSAllocatedUnfairLock<br/>publish| NSlot[naturalTextureSlot]

    Proc -->|blit| RB[readbackBuffer 0 / 1<br/>double-buffered]
    Trk -->|blit| TRB[trackerReadbackBuffer]

    PSlot --> MR[MetalRenderer.draw]
    NSlot --> NMR[NaturalMetalRenderer.draw]

    MR -->|present| Disp1[MTKView<br/>processed preview]
    NMR -->|present| Disp2[MTKView<br/>natural preview]

    TRB -->|wrap Frame<br/>CPU-visible pixels| CR[PixelSink<br/>dispatch StreamId::Tracker]
    CR -.->|1-slot mailbox<br/>MPSC lane| EDC[EdgeDetector<br/>cv::Canny]

    EncT -.->|GPU-local blit<br/>stays in IOSurface| Pool[CVPixelBufferPool]
    Pool -.->|adaptor.append| AW[AVAssetWriterInput<br/>PixelBufferAdaptor]
    AW -.->|same IOSurface| VT[VideoToolbox encoder]

    classDef display fill:#efe,stroke:#6a6,color:#000
    classDef record fill:#fee,stroke:#a66,color:#000
    classDef consume fill:#eef,stroke:#66a,color:#000
    class Disp1,Disp2,MR,NMR,PSlot,NSlot display
    class EncT,Pool,AW,VT record
    class EDC,CR,TRB,CD,CE consume
```

### 3b — Buffer ownership and lifetime

| Buffer | Type | Allocator | Retain period | Release trigger | Notes |
|---|---|---|---|---|---|
| `inputPixelBuffer` | `CVPixelBuffer` (kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange, IOSurface-backed) | AVFoundation internal pool | Retained by `CMSampleBuffer`; transferred via IOSurface-backed `Frame` struct | When `FramePipeline` completes inline processing (CFType release) | `@unchecked Sendable` wrapper — safe because `CVPixelBuffer` retain/release is thread-safe CFType semantics. AVFoundation reuses the buffer once all retains drop. |
| `inputTexture` | `MTLTexture` (rgba16Float) | `CVMetalTextureCache` wrap of `inputPixelBuffer` | Per-frame; bound to the command buffer encode | Automatic when the command buffer completes | Zero-copy — same `IOSurface` as the input. Never copied to CPU. |
| `processedTexture` | `MTLTexture` (rgba16Float, full res) | `FramePipeline` at session-start (or resize) | Session | `teardownSession()` — also rebuilt on `setResolution()` | Pre-allocated; reused every frame. Size depends on `AVCaptureDevice.formats` selection. Pass 1 converts from YUV to RGBA16F. |
| `naturalTexture` | `MTLTexture` (rgba16Float, full res) | Same as above, only if `enableNaturalStream == true` | Session | `teardownSession()` | Passthrough — no GPU color transforms applied. |
| `trackerTexture` | `MTLTexture` (rgba16Float, aspect-preserving, 480 px tall, even-width) | Same as above | Session | `teardownSession()` | Fixed 480 px height per `domain/12-unresolved.md §U-15 RESOLVED`. Width formula preserved verbatim. |
| `readbackBuffer[0]`, `readbackBuffer[1]` | `MTLBuffer` with `.storageModeShared` | `FramePipeline` at session-start | Session | `teardownSession()` | Double-buffered — Metal writes to `writeIndex`, CPU reads from `readIndex = 1 - writeIndex` after the previous command buffer's completion handler fires. Serves the `ProcessedFullResolution` consumer role (if any) and `sampleCenterPatch`. |
| `trackerReadbackBuffer` | `MTLBuffer` with `.storageModeShared` | `FramePipeline` at session-start | Session | `teardownSession()` | CPU-accessible; blit target for `trackerTexture` → handed to `EdgeDetector` via `PixelSink` wrapped as IOSurface-backed `Frame`. |
| `encoderPixelBuffer` | `CVPixelBuffer` (IOSurface-backed, 8-bit YUV biplanar) | `adaptor.pixelBufferPool` created by `RecordingActor` on recording start | Per recorded frame | Returned to pool after `AVAssetWriter` completes encoding | Pool configured with `kCVPixelBufferIOSurfacePropertiesKey: [:]` + `kCVPixelBufferMetalCompatibilityKey: true`. `maximumBufferCount ≥ 6` to survive encoder backlog during thermal throttling (F-04 deferred mitigation). HEVC 8-bit via 8-bit YUV biplanar adaptor pool. |
| `encoderTexture` | `MTLTexture` | `CVMetalTextureCache` wrap of `encoderPixelBuffer` | Per recorded frame | Implicit when the wrapped pixel buffer is appended to the adaptor | Recorder owns its **own** `CVMetalTextureCache` distinct from the input cache — mixing lifecycles is a bug. |
| `textureSlot`, `naturalTextureSlot` | `OSAllocatedUnfairLock<MTLTexture?>` | `MetalRenderer` / `NaturalMetalRenderer` init | Renderer lifetime | Renderer `deinit` | Protects publisher (`FramePipeline`, nonisolated delivery queue) vs consumer (`draw(_:)`, nonisolated MTKView thread). Held for microseconds per swap. |
| `frame` (IOSurface-backed `Frame` struct) | Swift struct wrapping an IOSurface-backed `CVPixelBuffer` | `FramePipeline` per frame at dispatch time | Lifetime of `EdgeDetector.onFrame()` C-ABI callback | Implicit when the consumer callback returns; IOSurface lock released | The pixel data is valid **only** while the IOSurface is locked — `EdgeDetector` locks IOSurface, runs cv::Canny, writes to shared `MTLTexture`, then releases. |

**Invariants enforced by this layout:**
- **Single memcpy per frame** (`domain/04-concurrency-invariants.md §Invariant 2`): Only the readback buffer paths perform a GPU→CPU blit; everything on the display and encoder paths stays in GPU/IOSurface memory.
- **No per-consumer copies** (`domain/02-frame-delivery.md §Consumer Dispatch Semantics`): All registered consumers for a given stream share the same `Frame` — the 1-slot MPSC mailbox in `PixelSink` passes a reference, not a copy.
- **GPU→encoder zero-copy** (`domain/08-capture-and-recording.md §Video Encoding`): `MTLTexture.getBytes` is explicitly **forbidden** on the recording path (see `03-metal-pipeline.md §GPU-to-Encoder Path`).

---

## 4 — Metal pipeline internals

Zoom into the compute kernel stage of diagram 3. Shows inputs, uniforms, and all outputs in
a single command buffer encode pass, plus the post-compute blit pass.

Cross-ref: `03-metal-pipeline.md §Compute Kernel`, `03-metal-pipeline.md §Texture Specification`,
`06-decisions-log.md D-18 (capture format: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange; working format: RGBA16F throughout GPU passes)`.

```mermaid
flowchart LR
    subgraph Inputs["Kernel inputs (per frame)"]
        direction TB
        IN[inYUV (Y + CbCr planes)<br/>texture2d, read<br/>from kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange]
        U[ColorUniforms<br/>brightness, contrast, saturation,<br/>gamma, blackBalance<br/>enableNaturalStream flag]
    end

    subgraph Kernel["Metal compute kernel — cam_pipeline.metal (6-pass, half-float working)"]
        direction TB
        K1[1. Pass 1: YUV → RGBA16F conversion<br/>BT.709 matrix, writes rgba16Float]
        K2[2. black balance offset + rescale<br/>half math, full rate]
        K3[3. 5-stage color pipeline<br/>black balance -> brightness -><br/>contrast -> saturation -> gamma]
        K4[4. write processed<br/>write natural passthrough<br/>write tracker downscaled]
        K1 --> K2 --> K3 --> K4
    end

    IN --> Kernel
    U --> Kernel

    Kernel -->|rgba16Float| P[processedTexture]
    Kernel -->|rgba16Float<br/>no color transforms| N[naturalTexture]
    Kernel -->|rgba16Float| T[trackerTexture<br/>480 px tall]

    subgraph BlitPass["Post-compute blit pass (same command buffer)"]
        direction TB
        BE[MTLBlitCommandEncoder]
        BE --> RB1[readbackBuffer<br/>writeIndex]
        BE --> TRB[trackerReadbackBuffer]
        BE -.->|recording only<br/>GPU-local copy| ENCT[encoderTexture<br/>IOSurface-backed]
    end

    P -.-> BE
    T -.-> BE

    subgraph Completion["Command buffer completion"]
        CH[addCompletedHandler<br/>1. check cb.status == .error<br/>2. Task await onFrameReadbackComplete<br/>   with expectedState guard]
    end

    BlitPass --> CH
```

**Key points:**
- Pass 1 converts the YUV capture format to RGBA16F; subsequent passes operate in half-float throughout. The kernel writes **three** outputs in a single dispatch (processed, natural, tracker) — one kernel, three `texture2d<half, access::write>` arguments. The natural stream is simply the pre-color-pipeline RGBA16F written to its own target.
- The blit pass is encoded into the **same** command buffer as the compute pass — they are committed together. This keeps the completion handler semantics coherent.
- The encoder texture blit only executes when `RecordingActor.recordingState == .recording`. When not recording, the encoder texture is not created and the adaptor pool is not allocated.
- The completion handler has two responsibilities (both added during the post-review patch pass): (a) check `cb.status == .error` for silent GPU failures (R-23), (b) re-enter the actor with the captured `expectedState` to guard against re-entrancy during teardown (F-01).

---

## 5 — Error propagation

How errors from each subsystem reach the UI and the recovery state machine. Shows both the
fatal and non-fatal paths and the final emission point.

Cross-ref: `domain/06-error-and-recovery.md`, `02-concurrency.md §Invariant 9 (Recovery Cancellation)`,
`07-ios-specific-risks.md §Domain Edge Case → iOS Handling Mapping`.

```mermaid
flowchart TB
    subgraph Sources["Error sources"]
        E1[AVCaptureSessionRuntimeError<br/>notification]
        E2[Metal command buffer<br/>cb.status == .error]
        E3[GPU stall watchdog<br/>no completion for 3s]
        E4[Capture stall watchdog<br/>no sample buffer for 5s]
        E5[HAL error counter >= 5<br/>consecutive]
        E6[Permission revoked mid-session<br/>AVError.mediaServicesWereReset]
        E7[AVAssetWriter.status == .failed]
        E8[ProcessInfo.thermalState == .critical]
        E9[CVMetalTextureCache wrap<br/>returned nil / memory pressure]
        E10[CVPixelBufferPoolCreatePixelBuffer<br/>kCVReturnWouldBlock]
    end

    subgraph Classifier["CaptureActor error classifier"]
        Decide{classify}
    end

    E1 --> Decide
    E2 --> Decide
    E3 --> Decide
    E4 --> Decide
    E5 --> Decide
    E6 --> FatalPath
    E7 --> Decide
    E8 --> SuspendPath
    E9 --> NonFatalPath
    E10 --> DropOnly

    Decide -->|fatal<br/>terminal| FatalPath[handleFatalError]
    Decide -->|non-fatal<br/>recoverable| NonFatalPath[handleNonFatalError]

    FatalPath --> ST1[sessionState = .error]
    ST1 --> EmitF[AsyncStream yield:<br/>onError fatal=true]
    EmitF --> VM1[CameraViewModel<br/>UI shows fatal error screen]

    NonFatalPath --> Check{retryCount < 5?}
    Check -->|yes| ST2[sessionState = .recovering]
    ST2 --> Emit2[AsyncStream yield:<br/>onError fatal=false<br/>+ state change]
    Emit2 --> Sleep[Task.sleep<br/>500ms · 1s · 2s · 4s · 8s]
    Sleep --> Retry[doReopenCamera]
    Retry -->|success| Stream[sessionState = .streaming]
    Retry -->|failure| NonFatalPath
    Check -->|no max retries| FatalPath

    SuspendPath --> ST3[sessionState = .backgroundSuspended]
    ST3 --> Release[teardown Metal + session<br/>keep process alive]
    Release --> Thermal[wait for thermalState<br/><= .fair]
    Thermal --> Resume[backgroundResume<br/>-> .opening]

    DropOnly --> Counter[increment<br/>droppedRecorderFrameCount]
    Counter --> Continue[continue — no state change]

    classDef fatal fill:#fcc,stroke:#a33,color:#000
    classDef nonfatal fill:#ffc,stroke:#a83,color:#000
    classDef suspend fill:#ccf,stroke:#33a,color:#000
    classDef drop fill:#cfc,stroke:#3a3,color:#000
    class FatalPath,ST1,EmitF,VM1 fatal
    class NonFatalPath,ST2,Emit2,Sleep,Retry,Stream nonfatal
    class SuspendPath,ST3,Release,Thermal,Resume suspend
    class DropOnly,Counter,Continue drop
```

**Key points:**
- Every non-fatal error path ultimately transitions through `.recovering` → `Task.sleep` (backoff) → `doReopenCamera`. Five consecutive failures promote to fatal.
- The **recovery cancellation** invariant (`domain/04-concurrency-invariants.md §Invariant 9`) is enforced by storing the retry task in the actor and cancelling it on `close()` or `backgroundSuspend()` — the retry body checks `Task.isCancelled` before acting.
- `E9` (texture cache wrap nil under memory pressure, per R-24) is explicitly non-fatal — the frame is dropped, a counter increments, and the next frame retries. It does not reach the stall watchdog unless it persists for 3 seconds.
- `E10` (encoder pool exhaustion) and `E9` both use the drop-only path: the recording or preview frame is lost but no state change occurs. This is critical for thermal survival — a cascade of drop-on-busy must not trigger recovery.

---

# Part 2 — Sequence Diagrams

## 6 — Hot path: capture → display

The per-frame sequence against the 33 ms budget. Shows the actor hop from the AVFoundation
serial queue, the Metal command buffer lifecycle, the texture slot publish, and the `MTKView`
on-demand redraw.

Cross-ref: `03-metal-pipeline.md §Frame Budget`, `02-concurrency.md §Invariant 4, 6`,
`07-ios-specific-risks.md R-23, R-24`.

```mermaid
sequenceDiagram
    autonumber
    participant HW as Camera HW
    participant AVF as AVCaptureSession
    participant CDQ as captureQueue<br/>(serial)
    participant CD as CaptureDelegate<br/>(nonisolated)
    participant CE as FramePipeline<br/>(nonisolated — delivery queue)
    participant MTLQ as MTLCommandQueue
    participant GPU as GPU
    participant Lock as textureSlot<br/>(OSAllocatedUnfairLock)
    participant MR as MetalRenderer<br/>(nonisolated)
    participant MTK as MTKView

    HW->>AVF: sensor frame (~33ms cadence)
    AVF->>CDQ: dispatch didOutput sampleBuffer
    CDQ->>CD: captureOutput(_:didOutput:from:)
    CD->>CD: CMSampleBufferGetImageBuffer → CVPixelBuffer
    CD->>CD: wrap as IOSurface-backed Frame
    CD->>CE: inline call — no Task{} hop

    activate CE
    CE->>CE: CVMetalTextureCache wrap → Y + CbCr planes
    CE->>MTLQ: makeCommandBuffer
    CE->>MTLQ: encode compute pass
    CE->>MTLQ: encode blits — processed readback,<br/>tracker readback, encoder (if recording)
    CE->>CE: frameSessionState = sessionState
    CE->>MTLQ: addCompletedHandler { ... }
    CE->>MTLQ: commit
    CE->>Lock: withLock { $0 = processedTexture }
    CE->>MTK: Task @MainActor { setNeedsDisplay() }
    deactivate CE

    MTLQ->>GPU: submit
    Note right of GPU: Compute + blit execute asynchronously<br/>GPU budget ~5–8 ms

    par GPU execution
        GPU->>GPU: run compute + blit
    and MTKView redraw request
        MTK->>MR: draw(_:)
        activate MR
        MR->>Lock: withLock { $0 }
        Lock-->>MR: MTLTexture reference
        MR->>MTLQ: makeCommandBuffer
        MR->>MTLQ: blit texture → currentDrawable
        MR->>MTK: commandBuffer.present(drawable)
        MR->>MTLQ: commit
        deactivate MR
    end

    GPU-->>MTLQ: command buffer complete
    MTLQ->>CE: addCompletedHandler fires<br/>(Metal internal thread)

    activate CE
    CE->>CE: if cb.status == .error → handleNonFatalError and return
    CE->>CE: Task { await onFrameReadbackComplete(readIndex, expectedState) }
    CE->>CE: guard sessionState == expectedState == .streaming
    CE->>CE: readbackBuffer[readIndex].contents() → Frame (IOSurface-backed)
    CE->>CE: PixelSink.dispatch(frame, StreamId::Tracker) — non-blocking
    deactivate CE

    Note over HW,MTK: Total capture-to-display latency: target < 16 ms,<br/>budget < 25 ms, fail > 25 ms
```

**Key points:**
- `FramePipeline` runs inline on the delivery queue — no `Task{}` hop. The capture queue is held for the encode + commit sequence, then released. This eliminates the actor scheduling overhead on the hot path.
- The `par` block shows that **GPU execution and MTKView redraw overlap** — this is correct because the texture slot published the *previous* frame's output. The MTKView read happens on the Metal thread's `draw(_:)` callback; the GPU compute for the *next* frame runs concurrently.
- The completion handler reads the readback buffer and dispatches to the consumer — this is the only CPU touch of processed pixels, and it happens one frame **after** the initial commit (double-buffered).

---

## 7 — Fan-out to C++ consumer (1-slot mailbox)

The drop-on-busy semantics of `PixelSink` MPSC dispatch. Shows three frames arriving while
the consumer is busy with the first, and how `markIdle` re-dispatches the newest pending frame.

Cross-ref: `04-opencv-integration.md §PixelSink`, `domain/02-frame-delivery.md §Consumer
Dispatch Semantics`.

```mermaid
sequenceDiagram
    autonumber
    participant CE as FramePipeline (PipelineKit)
    participant CR as PixelSink C++ (ImagingBridge)<br/>MPSC lane — StreamId::Tracker
    participant CQ as PixelSink thread pool<br/>(std::min(4, hw_concurrency))
    participant BR as EdgeDetectorFacade<br/>(Swift, ImagingBridge)
    participant CPP as EdgeDetector<br/>(C++, ImagingCore)

    Note over CE,CPP: Frame N arrives — consumer is idle

    CE->>CR: dispatch(frameN, StreamId::Tracker)<br/>called from GPU completion handler — non-blocking
    activate CR
    CR->>CR: lane[Tracker].isProcessing == false → idle branch
    CR->>CR: lane[Tracker].isProcessing = true<br/>lane[Tracker].pendingFrame = nil
    CR->>CQ: pool thread: facade.process(frameN)
    CR-->>CE: return (non-blocking)
    deactivate CR

    activate CQ
    CQ->>BR: facade.process(frameN)
    BR->>BR: IOSurface lock (CVPixelBufferLockBaseAddress)
    BR->>CPP: onFrame(FrameData{span<uint8_t> YUV})<br/>direct Swift↔C++ interop, noexcept
    CPP->>CPP: YUV → gray8u (BT.709)
    CPP->>CPP: cv::Canny
    CPP->>CPP: cv::findContours
    CPP->>CPP: write to shared MTLTexture
    CPP-->>BR: fires C-ABI callback with EdgeDetectionResult
    BR->>BR: IOSurface unlock<br/>convert POD → Sendable Swift struct

    Note over CE,CPP: Frame N+1 arrives while consumer is still busy
    CE->>CR: dispatch(frameN+1, StreamId::Tracker)
    activate CR
    CR->>CR: lane[Tracker].isProcessing == true → busy branch
    CR->>CR: lane[Tracker].pendingFrame = frameN+1
    CR-->>CE: return (no dispatch)
    deactivate CR

    Note over CE,CPP: Frame N+2 arrives — N+1 is overwritten (dropped)
    CE->>CR: dispatch(frameN+2, StreamId::Tracker)
    activate CR
    CR->>CR: lane[Tracker].pendingFrame = frameN+2<br/>(frameN+1 silently dropped)
    CR-->>CE: return
    deactivate CR

    BR-->>CQ: facade.process(frameN) complete
    CQ->>CR: markIdle(StreamId::Tracker)
    deactivate CQ

    activate CR
    CR->>CR: pendingFrame == frameN+2
    CR->>CR: pendingFrame = nil<br/>(keep isProcessing = true)
    CR->>CQ: pool thread: facade.process(frameN+2)
    deactivate CR

    activate CQ
    CQ->>BR: facade.process(frameN+2) via direct Swift↔C++ interop
    Note right of BR: frameN+1 was silently dropped<br/>per drop-on-busy policy — this is correct<br/>per domain/02-frame-delivery.md
    deactivate CQ
```

**Key points:**
- `PixelSink.dispatch` is **non-blocking** — it is called from the GPU completion handler and must return immediately. The MPSC lane atomically swaps the pending frame slot without taking a heavyweight lock.
- The **producer (`FramePipeline`) is never blocked** by consumer slowness. The 1-slot mailbox guarantees memory stays flat (`O(1)` per consumer regardless of frame rate).
- The "drop-on-busy" semantics are the key product contract: the consumer is guaranteed to always process the *newest* frame it can, never a stale one. This is the correct behavior for real-time edge detection.

---

## 8 — GPU-to-encoder zero-copy recording

The per-frame sequence that writes a recorded frame to the encoder without ever touching CPU
pixel memory. Verification point for F-03's zero-copy claim.

Cross-ref: `03-metal-pipeline.md §GPU-to-Encoder Path`, `06-decisions-log.md D-03`,
`domain/08-capture-and-recording.md §Video Encoding`.

```mermaid
sequenceDiagram
    autonumber
    participant CE as FramePipeline (PipelineKit)
    participant VR as RecordingActor (EncoderKit)
    participant Pool as CVPixelBufferPool<br/>(IOSurface-backed)
    participant TC as CVMetalTextureCache<br/>(recorder cache)
    participant CB as MTLCommandBuffer<br/>(shared with other blits)
    participant BE as MTLBlitCommandEncoder
    participant GPU as GPU
    participant Adaptor as AVAssetWriterInput<br/>PixelBufferAdaptor
    participant VT as VideoToolbox

    Note over CE,VT: Frame N — recording is active
    CE->>VR: is recording?
    VR-->>CE: true (cached actor-isolated state)

    CE->>Pool: CVPixelBufferPoolCreatePixelBuffer
    alt pool has buffer
        Pool-->>CE: CVPixelBuffer (IOSurface-backed, 8-bit YUV biplanar)
    else pool exhausted (thermal backlog)
        Pool-->>CE: kCVReturnWouldBlock
        CE->>CE: droppedRecorderFrameCount += 1
        Note right of CE: Recording drops this frame —<br/>preview pipeline unaffected
    end

    CE->>TC: CVMetalTextureCacheCreateTextureFromImage(pixelBuffer)
    TC-->>CE: CVMetalTexture wrapping same IOSurface
    CE->>CE: CVMetalTextureGetTexture → encoderTexture (MTLTexture)
    CE->>CE: guard encoderTexture != nil (R-24)

    CE->>CB: makeBlitCommandEncoder
    CB-->>BE: encoder
    CE->>BE: copy(from: processedTexture, to: encoderTexture)
    Note right of BE: GPU-local blit — pixel data stays<br/>in IOSurface memory. CPU never touches bytes.
    CE->>BE: endEncoding()
    CE->>CB: addCompletedHandler
    CE->>CB: commit

    CB->>GPU: submit
    GPU->>GPU: execute all blits (preview, tracker, encoder)
    GPU-->>CB: complete
    CB->>CE: addCompletedHandler fires
    CE->>VR: Task { await appendRecordedFrame(pixelBuffer, pts) }

    activate VR
    VR->>VR: guard recordingState == .recording<br/>(RecordingActor guard — prevents append after stop)
    VR->>Adaptor: append(pixelBuffer, withPresentationTime: pts)
    Note right of Adaptor: append does NOT copy —<br/>VideoToolbox reads the same IOSurface
    Adaptor->>VT: submit IOSurface handle
    VT->>VT: HEVC / H.264 compress<br/>(reads IOSurface directly)
    VT-->>Adaptor: encoded frame written to file
    Adaptor->>Pool: return CVPixelBuffer to pool
    deactivate VR
```

**Key points:**
- **The CPU never touches recorded pixel data.** Three GPU-side operations handle everything: (1) compute kernel writes `processedTexture`, (2) blit encoder copies to `encoderTexture`, (3) VideoToolbox reads the same `IOSurface`. Every buffer transition stays in GPU/shared memory.
- The **recorder texture cache is separate** from the input texture cache. This is intentional: the input cache is invalidated on session teardown; the recorder cache is invalidated on recording stop. Mixing them couples their lifecycles incorrectly. `RecordingActor` owns its own cache.
- `CVPixelBufferPoolCreatePixelBuffer` can return `kCVReturnWouldBlock` under thermal throttling when the encoder backlog fills the pool. The correct response is to **drop the recording frame only** — the preview pipeline keeps going. This is the documented mitigation for F-04.

---

## 9 — Actor re-entrancy guard (F-01)

The subtlest sequence in the system: `close()` arrives while a frame is mid-flight in the Metal
pipeline. Without the state guard, the completion handler would access freed buffers.

Cross-ref: `03-metal-pipeline.md §onFrameReadbackComplete`, `review/02-adversarial-red-team.md F-01`.

```mermaid
sequenceDiagram
    autonumber
    participant VM as CameraViewModel
    participant CE as CaptureActor
    participant FP as FramePipeline<br/>(nonisolated, delivery queue)
    participant GPU as Metal GPU
    participant CH as Completion handler<br/>(Metal internal thread)

    Note over VM,CH: FramePipeline is busy with processFrame(N)

    VM->>CE: await close()
    Note right of CE: close() is enqueued in the CaptureActor mailbox —<br/>will run after any in-flight actor messages

    activate FP
    FP->>FP: processFrame(N) — encode command buffer inline
    FP->>FP: frameSessionState = sessionState<br/>// captured as .streaming
    FP->>FP: addCompletedHandler { cb in<br/>  if cb.status == .error { ... return }<br/>  Task { await onFrameReadbackComplete(<br/>    readIndex: i, expectedState: .streaming)<br/>  }<br/>}
    FP->>FP: commandBuffer.commit()
    FP->>FP: writeIndex = 1 - writeIndex
    FP-->>FP: processFrame(N) returns
    deactivate FP

    Note over CE: CaptureActor mailbox pumps — close() runs

    activate CE
    CE->>CE: close()
    CE->>CE: gpuStallWatchdogTask.cancel()
    CE->>CE: retryTask?.cancel()
    CE->>CE: sessionState = .closed
    CE->>CE: releaseMetalResources()<br/>// readbackBuffers freed
    CE->>CE: session.stopRunning()
    CE-->>VM: return
    deactivate CE

    Note over GPU: GPU is still executing frame N

    GPU->>CH: command buffer complete (async)
    CH->>CE: Task { await onFrameReadbackComplete(readIndex, expectedState: .streaming) }

    activate CE
    CE->>CE: guard sessionState == expectedState<br/>sessionState == .closed<br/>expectedState == .streaming<br/>⇒ guard FAILS
    CE->>CE: return (frame dropped)
    Note right of CE: The readback buffer for this frame was freed<br/>in releaseMetalResources(). Touching<br/>.contents() would crash. The state guard<br/>prevents this by detecting that the actor<br/>re-entered from a different sessionState<br/>than the commit captured.
    deactivate CE
```

**Why this works:**
- `frameSessionState` is captured **synchronously** before the `commit()` — actor re-entrancy cannot race this assignment because it runs on the actor before any `await`.
- The guard `sessionState == expectedState` detects *any* state change between commit and completion, not just `.closed`. It also catches `backgroundSuspend()`, `setResolution()`, and fatal errors.
- The same pattern protects the `Metal command buffer error` path — if the GPU faults, the completion handler also checks `cb.status == .error` and routes to `handleNonFatalError` instead of the normal readback path.

---

## 10 — Still capture in-flight guard

Shows how `StillWriter.captureNaturalPicture()` enforces `domain/04-concurrency-invariants.md §Invariant 7`
(atomic one-capture-at-a-time) using actor isolation alone — no locks.

Cross-ref: `02-concurrency.md §Invariant 7`, `05-implementation-phases.md §Phase 5 Acceptance Criteria`.

```mermaid
sequenceDiagram
    autonumber
    participant VM as CameraViewModel
    participant SC as StillWriter<br/>(actor — EncoderKit)
    participant APO as AVCapturePhotoOutput
    participant EX as EXIFWriter
    participant FS as FileSystem

    Note over VM,SC: First capture call arrives

    VM->>SC: await captureNaturalPicture()
    activate SC
    SC->>SC: guard !captureInFlight else throw INVALID_STATE
    Note right of SC: This check + the set on the next line<br/>both run synchronously before any<br/>await — they are atomic by StillWriter<br/>actor construction.
    SC->>SC: captureInFlight = true
    SC->>SC: defer { captureInFlight = false }
    SC->>APO: capturePhoto(with: settings, delegate: self)
    Note right of SC: Await suspension here —<br/>StillWriter actor is free to service other messages

    Note over VM,SC: Second capture call arrives — actor is free

    VM->>SC: await captureNaturalPicture()  [concurrent]
    SC->>SC: guard !captureInFlight<br/>captureInFlight == true ⇒ throw
    SC-->>VM: throw CameraError(.invalidState)

    Note over VM,APO: First capture's photo delivery resumes

    APO->>SC: didFinishProcessingPhoto (delegate)
    SC->>SC: receive AVCapturePhoto
    SC->>EX: buildEXIFProperties(sensor metadata)
    EX-->>SC: CFDictionary of EXIF tags
    SC->>FS: write 8-bit TIFF via Pass 6 blit to temp URL
    SC->>EX: CGImageDestinationAddImageFromSource<br/>with EXIF dict
    FS-->>SC: path
    SC-->>VM: return path
    Note right of SC: defer block fires on return:<br/>captureInFlight = false
    deactivate SC
```

**Why the guard is correct without locks:**
- `guard !captureInFlight` and `captureInFlight = true` both execute **synchronously** before the first `await` in the method. Actor isolation guarantees no other method can interleave between these two lines.
- Once the actor suspends on `await APO.capturePhoto(...)` (via the delegate callback), *other* actor methods can run — but any concurrent `captureNaturalPicture` call will re-enter the guard and find `captureInFlight == true`, correctly rejecting.
- `defer { captureInFlight = false }` runs after the `return` (or any `throw`), ensuring the flag is always cleared regardless of success or failure path.

**This pattern is load-bearing** because it replaces an explicit `NSLock` or atomic flag with purely structural Swift-language semantics. Any change to the ordering (moving the guard after an `await`) would break the invariant — document this in the source as a comment.

---

## Regenerating / editing diagrams

Mermaid source is the canonical form. To edit:
1. Open this file in any Markdown editor with Mermaid preview (VS Code + "Markdown Preview Mermaid Support", or paste into https://mermaid.live).
2. Edit the source inside the ```` ```mermaid ```` fences.
3. Commit — GitHub renders the updated diagram automatically on the next view.

To export a single diagram as PNG / SVG for a slide deck or external doc:
```sh
npm install -g @mermaid-js/mermaid-cli
mmdc -i diagram.mmd -o diagram.png
```

If a diagram and the prose design files disagree, **the prose wins**. Patch the diagram to
match and add a note in `06-decisions-log.md` if the disagreement reveals a real design change.
