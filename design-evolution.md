# Design Evolution

Keeping track of conversation to explain how and why the structure has evolved.

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
