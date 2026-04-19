# Design Evolution

Keeping track of conversation to explain how and why the structure has evolved.

## clean room redesign - get behavior and intent instead of translation


---
  Implementation Complete

  All 10 tasks executed through the subagent-driven development process. Here's the summary:

  Files Created

  ┌─────────────────────┬───────┬───────────────────────────────────────────────────────────────┐
  │        File         │ Lines │                            Purpose                            │
  ├─────────────────────┼───────┼───────────────────────────────────────────────────────────────┤
  │ prompt-1-audit.md   │ 298   │ Agent 1 — Factual Android audit (12-file output)              │
  ├─────────────────────┼───────┼───────────────────────────────────────────────────────────────┤
  │ prompt-2-extract.md │ 252   │ Agent 2 — Platform-neutral domain extraction (12-file output) │
  ├─────────────────────┼───────┼───────────────────────────────────────────────────────────────┤
  │ prompt-3-design.md  │ 464   │ Agent 3 — iOS architecture design (8-file output)             │
  ├─────────────────────┼───────┼───────────────────────────────────────────────────────────────┤
  │ prompt-4-review.md  │ 282   │ Agent 4 — Correctness + adversarial review (3-file output)    │
  ├─────────────────────┼───────┼───────────────────────────────────────────────────────────────┤
  │ README.md           │ 78    │ Workflow overview                                             │
  └─────────────────────┴───────┴───────────────────────────────────────────────────────────────┘

  Files Archived (git mv'd)

  - prompt-1-cartographer.md → prompt-1-cartographer.md.archived
  - prompt-2-architect.md → prompt-2-architect.md.archived

  Directories Created

  - audit/ (Agent 1 output target)
  - domain/ (Agent 2 output target)
  - review/ (Agent 4 output target)
  - (design/ already existed; all 4 are empty awaiting agent runs)

  Review Iterations

  Each prompt went through implementer → spec review → quality review → fixes. Notable findings:

  - Task 2 (EXTRACT) — 4 rounds: missing forbidden identifiers in grep, \bSurface\b gap, grep false-positives on common English words, spec deviation on forbidden list, then dry-run surfaced "background
  thread" architectural leakage. All fixed.
  - Task 3 (AUDIT) — 2 critical issues: missing Pigeon API phase (added as new file 04, making 12 audit files total), OpenCV contradiction between prompt and CLAUDE.md (fixed with nuanced framing).
  - Task 4 (DESIGN) — 4 important issues: Phase 1a/4 thermal boundary, domain/06 orphan ownership, VTFrameProcessor fallback path, Agent 4 traceability artifact. All fixed.
  - Task 5 (REVIEW) — 2 important issues: "Suggested fix" field contradicted no-patching rule (renamed to "Routing"), Red threshold too permissive for core-mission files.
  - Task 8 (consistency) — Minor gap: Agent 4 didn't explicitly check for design/07-ios-specific-risks.md; added to quality gates.

  Spec Deviations (Documented)

  1. audit/ has 12 files instead of 11 — added 04-pigeon-api.md because Agent 2 needs Pigeon method-level detail to write domain/10-api-contract.md. Downstream agents read audit/ generically, so no
  propagation issues.


★ Insight ─────────────────────────────────────
  Commit sequence is deliberate. The semantic order (docs → features → chore) lets someone reading git log reconstruct the redesign: "here's the plan, here's each agent, here's the cleanup." If you ever
  need to revert a specific agent's prompt, its commit is isolated. The chore commit at the end bundles all the legacy-removal noise in one place so the feature commits stay readable.

  Plugin architecture hook reminders appeared on every commit. Those are from the parent Flutter repo's hook (camera2_flutter_demo), which watches all bash commands. The commits are in the separate
  ios-translation repo and only touch markdown prompt files — no plugin architecture or public API changes, so the reminder is safely ignorable here.
  ─────────────────────────────────────────────────

  What You Have Now

  The clean room pipeline is fully in place:

  ios-translation/
  ├── prompt-1-audit.md              ← run first
  ├── prompt-2-extract.md            ← run second
  ├── prompt-3-design.md             ← run third
  ├── prompt-4-review.md             ← run fourth
  ├── docs/superpowers/
  │   ├── specs/2026-04-12-clean-room-prompt-redesign-design.md
  │   └── plans/2026-04-12-clean-room-prompt-redesign.md
  ├── audit/ domain/ design/ review/  ← empty, awaiting agent runs
  └── prompt-1-cartographer.md.archived, prompt-2-architect.md.archived

  Next Actions (not started — your call)

  1. Run setup.sh to re-pack the codebase with the current repomix exclusions
  2. Add screenshots to screenshots/
  3. Run Agent 1 in a fresh Claude Code session with working directory ios-translation/
  4. Review audit/ output before running Agent 2
  5. Continue the pipeline through Agents 2, 3, 4

  
## gemini feedback

Good feedback. Let me assess each point quickly, then apply the changes.

  ┌──────────────────────────────────────┬──────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │               Feedback               │       Verdict        │                                                               Reasoning                                                                │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ C++ hardware pointer/alignment docs  │ Agree                │ Where C++ touches AHardwareBuffer pointers, alignment matters for iOS port                                                             │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Waterfall / no feedback loop         │ Partially agree      │ Add gap analysis phase to Architect start, not a full separate prompt (simpler, same effect)                                           │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ L4.5 Buffer lifecycle / memory       │ Agree                │ Buffer pooling, pre-allocation, OOM handling is a real gap                                                                             │
  │ pressure                             │                      │                                                                                                                                        │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Swift 6 sending keyword              │ Mention, don't       │ sending (SE-0430, formerly transferring) is real in Swift 6, but our design avoids boundary crossing — it's a fallback option, not a   │
  │                                      │ mandate              │ hard requirement                                                                                                                       │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 3-step Pulse                         │ Partially agree      │ Fold into Architect as Phase 0 gap analysis, not a separate prompt                                                                     │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ os_signpost for return path          │ Agree                │ Specific and measurable                                                                                                                │
  ├──────────────────────────────────────┼──────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ setup.sh exclude build/              │ Agree                │ Quick fix                                                                                                                              │
  └──────────────────────────────────────┴──────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘


## 2026-04-12 we use opencv!

USER: ❯ do we need CVPixelBuffer is an ObjC type?

Good catch — I was imprecise. CVPixelBuffer is a CoreFoundation type (CVPixelBufferRef / CFTypeRef), not an Objective-C class. It's C-based, not ObjC-based. But the Sendable concern is the same —
  CoreFoundation types aren't Sendable either.

  The deeper question is: do we need CVPixelBuffer to travel across actor boundaries at all?

  The answer depends on where processing happens:

  Option A: CVPixelBuffer crosses boundaries (current design)
    Camera queue → [CVPixelBuffer] → @MLProcessor actor → [CVPixelBuffer] → Metal
    Problem: CVPixelBuffer not Sendable, needs wrapper

  Option B: Convert early, send texture (minimize CVPixelBuffer scope)
    Camera queue → CVPixelBuffer → MTLTexture (via cache) → [MTLTexture] → actors
    Problem: MTLTexture is also not Sendable (it's a protocol)

  Option C: Keep all buffer work on one queue (no crossing)
    Camera queue: CVPixelBuffer → MTLTexture → Metal processing → done
    Only RESULTS cross to @MainActor (coordinates, labels — plain Swift structs, inherently Sendable)
    Problem: camera queue is doing too much work, could stall frame delivery

  Option D: VTFrameProcessor handles it
    Camera queue → VTFrameProcessor.process() → AsyncSequence<ProcessedFrame>
    VTFrameProcessor manages buffers internally
    Problem: depends on what transforms VTFrameProcessor supports

  Option C is actually the cleanest — keep all buffer handling within the camera/compute scope, only send Sendable results (structs, enums, value types) across actor boundaries. The frame buffer never needs
   to cross an isolation domain if the pipeline stays on one serial queue or actor.

USER: We use opencv!

That's important context — and good news for portability. The Android project already uses OpenCV (it's in the CLAUDE.md and build config). This means:

  1. The C++ code is likely highly portable. OpenCV abstracts platform differences. cv::Mat works the same on Android and iOS. The JNI-specific parts (function entry points) need to change, but the actual
  CV logic should compile as-is.
  2. The bridge is straightforward. CVPixelBuffer → CVPixelBufferGetBaseAddress() → cv::Mat wrapping the raw pointer (zero-copy). OpenCV doesn't care where the pixels came from.
  3. This simplifies the Sendable question. The natural pattern is:
  Camera queue → CVPixelBuffer → lock base address → cv::Mat (zero-copy wrap)
  → OpenCV processing → results (plain structs) → @MainActor
  3. CVPixelBuffer and cv::Mat stay on one queue. Only results cross actor boundaries. No Sendable wrappers needed for buffers.
  4. OpenCV is available on iOS via CocoaPods, Swift Package Manager, or manual framework. Since the Android project already has OpenCV as a dependency, the build config just needs the iOS equivalent.


The four options I listed were:

  ┌────────┬─────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │ Option │                           Pattern                           │                                                  Works for OpenCV?                                                   │
  ├────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ A      │ CVPixelBuffer crosses actor boundaries via Sendable wrapper │ Adds complexity for no gain — OpenCV needs a raw pointer, not a CVPixelBuffer on a different actor                   │
  ├────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ B      │ Convert to MTLTexture early, pass texture                   │ Wrong direction. OpenCV needs CPU pixels, not GPU textures. You'd have to read back from GPU → CPU, which is a copy. │
  ├────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ C      │ Keep all buffer work on one queue, send only results        │ Cleanest fit. CVPixelBuffer → raw pointer → cv::Mat → OpenCV → results. No crossing.                                 │
  ├────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ D      │ VTFrameProcessor handles it                                 │ VTFrameProcessor is for video effects, not OpenCV. Doesn't apply to the CV path.                                     │
  └────────┴─────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  The honest answer: Option C is the only one that makes sense for OpenCV. The other three don't fail because of Sendable — they fail because they don't match how OpenCV works:

  - OpenCV needs CPU-accessible pixels (a pointer to memory it can read)
  - CVPixelBuffer already has those pixels (via CVPixelBufferGetBaseAddress)
  - Moving the buffer to a different actor/queue just to process it there adds unnecessary complexity
  - Moving it to an MTLTexture first means going GPU → CPU readback, which is a copy and defeats zero-copy

  The pipeline is naturally single-queue for the OpenCV path:

  Camera queue delivers CVPixelBuffer
    → lock base address (same queue)
    → wrap as cv::Mat (same queue, zero-copy)
    → OpenCV processes (same queue)
    → unlock base address (same queue)
    → send DetectionResult struct to @MainActor (Sendable, trivial)

  The only nuance: if OpenCV processing is slow (>33ms at 30fps), it blocks the camera queue and you drop frames. The fix is AsyncStream with .bufferingNewest(1) feeding a dedicated processing queue — but
  it's the stream that crosses the boundary, not the buffer. The buffer is created fresh from each dequeued CMSampleBuffer on the processing side.

  The prompt already captures Option C correctly now. The other options were me over-engineering the Sendable concern before knowing OpenCV was the consumer.


## 2026-04-12 search docs better

 ★ Insight ─────────────────────────────────────
  Three corrections and their impact:

  1. VTFrameProcessor is real (iOS 26+). My earlier "hallucinated" call was wrong — it's a new VideoToolbox API. It processes frames with configurable effects, has a Metal command buffer variant, and
  returns AsyncSequence. For our pipeline, this could replace custom Metal compute shaders for standard transforms (color space conversion, resize). The prompt now says "evaluate VTFrameProcessor first,
  custom shaders only for what it can't do."
  2. AsyncStream .bufferingNewest(1) was already correct. The original feedback's .dropOldest describes the behavior but isn't the API name. Our prompt already had the right name.
  3. Sendable is a real constraint we missed. Swift 6 enforces Sendable at compile time. CVPixelBuffer is an ObjC type that isn't inherently Sendable. Every time a frame buffer crosses an actor boundary
  (camera queue → ML actor → renderer), the compiler will reject it unless we design a Sendable strategy. This is a genuine architectural concern that could cause dozens of compiler errors if not designed
  upfront.
  ─────────────────────────────────────────────────

  Summary of Changes

  ┌───────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────┐
  │                        Correction                         │                                       Files Updated                                       │
  ├───────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ VTFrameProcessor is real — evaluate before custom shaders │ Prompt 2 (reference architecture, pipeline deliverable, quality gates), reference file    │
  ├───────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ Sendable strategy for CVPixelBuffer across actors         │ Prompt 2 (reference architecture, concurrency deliverable, quality gates), reference file │
  ├───────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
  │ VTFrameProcessor warning removed                          │ Prompt 2 (reference architecture)                                                         │
  └───────────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────┘

  The AsyncStream buffering policy was already correctly named in our prompts — no change needed there.


## 2026-04-12 gemini feedback on 2026 ios dev and latest frameworks/languagues to use

 ★ Insight ─────────────────────────────────────
  Three findings that materially changed our prompts:

  1. Swift-C++ direct interop eliminates ObjC++. Since Swift 5.9, Swift imports C++ headers via Clang modules. Our original "Swift → ObjC++ → C++" sandwich becomes "Swift → C++ (direct)." This removes an
  entire architectural layer. The prompt now says "prefer direct, fall back to ObjC++ if needed" with a compatibility assessment step.
  2. @globalActor replaces manual queue discipline. Instead of a dedicated DispatchQueue for ML processing, a custom @MLProcessor global actor gives compile-time enforcement — the compiler literally
  prevents you from calling ML code from the wrong thread. This is strictly better than runtime queue checks. The concurrency section now specifies this pattern.
  3. AsyncStream with .bufferingNewest(1) is the concrete back-pressure mechanism. Our prompt said "drop frames" but didn't say how. This is the 4-line Swift API that does it automatically — no manual drop
  logic, memory stays flat, latest frame always available.

  What we rejected from the feedback:
  - "VTFrameProcessor" — doesn't exist (hallucinated). Added an explicit warning in the prompt.
  - "Concurrent Actor" — not a Swift concept. Actors are serial. Used nonisolated instead.
  - SwiftData for metadata — over-engineered for this demo app.
  ─────────────────────────────────────────────────

  Summary of Changes

  ┌──────────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────┐
  │                          Change                          │                                 Where Applied                                  │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ Swift-C++ direct interop as default (ObjC++ as fallback) │ Prompt 2: reference architecture, constraints, C++ integration design, Phase 3 │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ @globalActor pattern for ML isolation                    │ Prompt 2: reference architecture concurrency table, concurrency deliverable    │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ AsyncStream .bufferingNewest(1) for back-pressure        │ Prompt 2: hard requirements, concurrency deliverable, Phase 3                  │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ Metal 4 (verified real)                                  │ Prompt 2: constraints updated from Metal 3 → Metal 4                           │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ MetalFX noted as available                               │ Prompt 2: constraints, available frameworks                                    │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ VTFrameProcessor flagged as non-existent                 │ Prompt 2: explicit warning in available frameworks                             │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ nonisolated for MTKViewDelegate (not "concurrent actor") │ Prompt 2: concurrency table                                                    │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ CVMetalTextureCache lifecycle (create once, reuse)       │ Prompt 2: hard requirement #5                                                  │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ C++ interop compatibility assessment step                │ Prompt 2: C++ integration design, Phase 3                                      │
  ├──────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ Updated reference architecture file                      │ reference/ios-camera-pipeline-patterns.md                                      │
  └──────────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────┘


## 2026-04-12 claude feedback on prompt 2

★ Insight ─────────────────────────────────────
  The three most impactful changes:
  1. <handling-audit-gaps> — The original prompt had no stance on what to do when the audit is wrong or incomplete. Now the agent makes provisional choices with stated assumptions instead of blocking. This
  is critical for autonomous operation.
  2. "What NOT to Port" section — Prevents cargo-culting Android-specific workarounds. The agent must explicitly identify Android-only guards and confirm they're safe to omit. This saves the implementing
  agent from building guards against problems that don't exist on iOS.
  3. iOS-specific failure modes as a required section — Thermal state, system pressure, permission denial, multi-app camera conflicts. The Android audit can't anticipate these. Without this section, the iOS
   app handles Android failure modes perfectly and crashes on iOS-specific ones.
  ─────────────────────────────────────────────────

  Summary of All Changes

  ┌────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │              Feedback              │                                                 Change                                                  │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Reference architecture mixes roles │ Split into PATTERN (guidance), HARD REQUIREMENTS (non-negotiable), BACKGROUND (context)                 │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Assumes audit is complete          │ Added <handling-audit-gaps> section with stance for incomplete/ambiguous/contradictory/wrong audit data │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Deliverable 1 monolithic           │ Split into 3 files: 01-concurrency-and-state.md, 02-metal-pipeline.md, 03-integration-and-controls.md   │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No device discovery                │ Added Camera Device Discovery and Selection section                                                     │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No HDR consideration               │ Added Color Space and HDR Consideration section in Metal pipeline                                       │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No profiling strategy              │ Added <profiling-strategy> section with os_signpost intervals and frame budget                          │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No iOS-specific failures           │ Added iOS-Specific Failure Modes section: thermal, system pressure, multi-app, permissions              │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No permissions design              │ Added Permissions Design section and WAITING_FOR_PERMISSION state                                       │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phase 1 overloaded                 │ Split into Phase 1a (camera + state machine + lifecycle) and Phase 1b (camera controls)                 │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phase 4 grab bag                   │ Moved fan-out topology to Phase 3; Phase 4 = pure performance + resilience                              │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phase 5 bundles too much           │ Split into Phase 5 (capture + recording) and Phase 6 (parity + polish)                                  │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ "Files to create" placeholder      │ Made file tree a required output per phase, added to forbidden-actions                                  │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ iOS 26+ aggressive                 │ Pushed back — added "Why iOS 26+:" justification line                                                   │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Quality gate too rigid             │ Changed to "mapped OR documented as not applicable with justification"                                  │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Design Decisions Log               │ Added as Deliverable 5 with structured format                                                           │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Metal texture vocabulary           │ Added per-texture spec: MTLPixelFormat, dimensions, usage flags, storage mode                           │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Concrete results return path       │ Added specific tracing scenario (object detection at coordinates → SwiftUI overlay)                     │
  ├────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ "What NOT to port"                 │ Added as dedicated section in integration-and-controls                                                  │
  └────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────┘

## 2026-04-12 claude feedback on prompt 1

Prompt will output too much detail. give briefs instead. 
★ Insight ─────────────────────────────────────
  The output volume concern was the most important feedback. The original prompt would generate 50,000+ words — replacing "too much code to read" with "too much docs to read." The fix is the
  <output-priority> section: the architecture brief + API contract + data-plane map should be enough to START working. Everything else is reference material consulted per-component. This changes the
  Cartographer's mindset from "document everything equally" to "make the brief sufficient, detail is backup."
  ─────────────────────────────────────────────────

  Summary of All Changes Applied

  ┌──────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────┐
  │             Feedback             │                                              Change Made                                               │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phase 3 is busywork              │ Changed to lightweight index (file → class → responsibility → threading), not exhaustive method tables │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phases 4/5 overlap               │ Translation cards now reference architecture maps for cross-cutting concerns instead of repeating them │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No settings persistence          │ Added Configuration & Settings section to the API contract phase                                       │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No performance budget            │ Added to data-plane map and as a dedicated section in architecture brief                               │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ No C++ portability assessment    │ Added PORTABILITY MATRIX to cpp-sinks translation card                                                 │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Screenshot gaps not actionable   │ Agent now infers from Pigeon API + state machine, marks with "INFERRED — not screenshotted"            │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Stop conditions too conservative │ Changed to NEEDS INVESTIGATION for most unknowns; only stop for genuinely blocking ambiguities         │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ 500-line check ambiguous         │ Clarified: applies to source files in the original repo, not output files                              │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ "No Dart reading" too absolute   │ Relaxed: screenshots for layout, Dart source for interaction logic and conditional behavior            │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Git calls token-heavy            │ Added strategy: --oneline first, then git show <hash> selectively                                      │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Output volume problem            │ Added <output-priority> section with explicit reading hierarchy                                        │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ "Gotchas" section                │ Added to architecture brief — 5-10 higher-level bullets                                                │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Bidirectional platform mapping   │ Added "iOS has no equivalent" and "iOS has a better primitive" columns                                 │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ C++ assumptions                  │ Folded into cpp-sinks PORTABILITY MATRIX — buffer format assumptions, alignment, threading model       │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Mermaid complexity               │ Added ~12 node cap, split into sub-diagrams if complex                                                 │
  ├──────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────┤
  │ Phase 1 ordering                 │ Kept as-is (pushed back) — but added Dart source reading for interaction logic                         │
  └──────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────┘


## 2026-04-12 gemini arch of swift code for camera all

★ Insight ─────────────────────────────────────
  What this context revealed about our prompt gaps:
  1. The results return path was completely missing. We designed frames flowing DOWN to C++ but never designed how ML/CV results flow UP to the UI. This is a full bidirectional data flow that both prompts
  now capture.
  2. "Drop, don't queue" is a concrete strategy. Our prompts said "handle back-pressure" which is vague. The reference architecture gives the specific answer — drop frames when consumers are busy. This
  prevents memory exhaustion and unbounded latency.
  3. CVBufferRetain/Release is an iOS-specific edge case. The Android audit won't surface this because Android's ImageReader uses a different pattern (acquireLatestImage/close). The Architect prompt now
  explicitly calls it out so the iOS agent doesn't miss it.
  ─────────────────────────────────────────────────

  Summary of Changes

  Prompt 1 (Cartographer) — one edit:
  - Data plane map now asks for the results return path (how ML/CV results flow from C++ back to UI), not just the frame delivery path

  Prompt 2 (Architect) — five edits:
  - Added <reference-architecture> section with the Sandwich pattern, zero-copy pipeline, three-thread model, frame dropping strategy, CVBuffer retention, and results return path
  - Updated constraints: zero-copy throughout, frame dropping not queuing, preview layer noted as temporary
  - Updated module/layer diagram to follow the Sandwich pattern with bidirectional data flow
  - Added Results Return Path as its own design section
  - Updated Phase 3 (C++ sinks) with CameraEngine ownership, CVBufferRetain, frame dropping, and results return

  New reference file: reference/ios-camera-pipeline-patterns.md — preserves this architecture context for future reference.


## 2026-04-19 implementation/ pipeline (Agents 3/4/5) replaces design/

Extended the clean-room pipeline past the DESIGN stage. The old `prompt-3-design.md` produced a single `design/` blob; the new pipeline produces a per-stage implementation corpus that a downstream Claude Code CLI can build against one stage at a time.

- **New**: `implementation/` directory with three agent prompts (`agent-3-architect`, `agent-4-review`, `agent-5-brief-writer`), two shell verify scripts (`verify-architecture.sh` M1–M8, `verify-briefs.sh` M1–M5), and fixture directories for each negative test case.
- **Agent 3 (ARCHITECT)** produces `implementation/architecture/` (9 concern files + 4 register files + a compiling SwiftPM skeleton of type stubs) and `implementation/stages/stage-index.md` (YAML-frontmatter blocks, one per build stage with scaffolding-introduced / scaffolding-retired pairs).
- **Agent 4 (ARCHITECTURE REVIEW)** judges only J1–J5 (coverage, citations, plausibility); mechanical checks are scripted.
- **Agent 5 (BRIEF WRITER)** produces per-stage briefs with a 12-section numbered schema and explicit TESTABLE / FLAGGED / HITL / DEFERRED test classes.
- **Superseded**: `design/`, `design-modified/`, `review/`, `prompt-3-design.md`, `prompt-4-review.md`, `orchestrator-prompt.md`, and two legacy `.archived` prompts moved to `tmp/cleanup/`. History preserved via `git mv`.
- **Spec + plan**: `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` and `docs/superpowers/plans/2026-04-19-implementation-pipeline.md` — 22 tasks, TDD-built via subagent-driven development, one commit per task.

The pipeline has not yet been run end-to-end against the real `domain-revised/` + `ios-platform-guide/`. All 15 fixtures pass their verify scripts.


## 2026-04-20 ios-platform-guide amendments from swift-architect review

Ran a fresh `swift-architect` subagent against the existing `design/` output (generated by the old DESIGN stage) and folded its 14 findings into `ios-platform-guide/` — not into `design/`, which will be regenerated by the new Agent 3 pipeline.

- **4 new ADRs**: ADR-30 (async session lifecycle with timeout, no `sessionQueue.sync` from MainActor), ADR-31 (Swift-subclassing a C++ abstract class is unproven — spike first; C-ABI callback struct as fallback), ADR-32 (`CaptureDeviceProviding` DI seam for testability), ADR-33 (Swift Testing + XCTest strategy with `CaptureDeviceProviding` as seam).
- **4 new gotchas**: G-31 (no raw `Task { @MainActor }` on hot-path delegates), G-32 (`MTLBlitCommandEncoder.copy` does not format-convert), G-33 (label `MTLCommandBuffer`s + `pushDebugGroup` for Xcode capture), G-34 (`IOSurfaceGetBytesPerRow` vs `width * bpp` for `cv::Mat` views).
- **7 updates**: ADR-02 (literal Swift 6 delegate class declaration), ADR-11 (module-map discipline promoted to day-one, not a mitigation), ADR-14 (strict-concurrency requirements for KVO→AsyncStream: `[weak self]`, `onTermination`, deterministic close), ADR-16 (background-during-recording: expiration handler always `cancelWriting`), ADR-20 (demoted to a graduated path; v1 default is always-`.shared` on Apple Silicon), G-08 (cross-ref to ADR-16), G-30 (at-most-once worked example).
