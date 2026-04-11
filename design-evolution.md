# Design Evolution

Keeping track of conversation to explain how and why the structure has evolved.

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
