# Clean Room Prompt Redesign for iOS Translation

**Date:** 2026-04-12
**Status:** Draft — pending user review
**Replaces:** Current two-prompt approach (prompt-1-cartographer.md, prompt-2-architect.md)

## Context

We've been iterating on prompts to translate a Flutter/Android camera library into a native iOS app. The Android codebase has two core missions:
1. Frame delivery pipeline: camera sensor → GPU processing → fan-out to C++ consumer sinks for ML/CV
2. Camera characteristic control surface: full manual control of focus, AWB, AE, ISO, exposure, zoom

The iOS port targets iOS 26+, Swift 6, Metal 4, SwiftUI.

## Problem

The current two-prompt approach has a structural flaw for clean room translation:

**Core tension:** The design doc needs enough detail that an implementing agent can build without ambiguity, but it must not be an Android port wearing iOS clothes. The Android codebase's domain knowledge (buffer management, stall recovery, threading invariants, edge case handling) is gold. Its structural decisions (Camera2 session patterns, Handler threading, SurfaceTexture) are Android-specific and should be left behind.

The current Cartographer output is organized around Android components (`camera-lifecycle.md`, `gpu-pipeline.md`, `shaders.md`, `cpp-sinks.md`). Even when the Architect is told "don't cargo-cult Android workarounds," the *shape* of what it reads is Android — so the design comes out Android-shaped. Organizational structure leaks into thinking.

Additionally, the current prompts accumulated many defensive guards, redundant context, and mixed responsibilities that dilute the signal and waste context.

## Solution

Clean room redesign using structured separation: produce two distinct documents with different organizational structures, and enforce hard language rules on the primary document the iOS designer consumes.

**Key insight:** A different organizational structure for the domain doc is what enforces the separation. If both docs are organized the same way, the iOS agent treats the "platform-neutral" version as just translated Android docs.

### Pipeline: 4 Agents

```
Android source/git/docs ──▶ [1 AUDIT] ──▶ audit/
                                             │
                                             ▼
                                         [2 EXTRACT] ──▶ domain/
                                                            │
                                                            ▼
              iOS expertise ─────────────▶ [3 DESIGN] ──▶ design/
              (injected via prompt)          │     │
                                             │     └─── (audit/ consulted only via logged escape hatch)
                                             ▼
                                         [4 REVIEW] ──▶ review/
                                         reads domain/ + design/ only
                                         two passes: correctness + adversarial
                                         one-shot (no iteration loop)
```

### Agent 1 — AUDIT

**Role:** Technical writer documenting the Android codebase factually.

**Input:** `packed/` (repomix output), original Android source at `/Users/shrek/work/cambrian/camera2_flutter_demo`, `reference/` docs, git history.

**Output:** `audit/` directory organized by Android structure.

```
audit/
├── README.md
├── 01-system-topology.md       # What components exist, how they connect
├── 02-threading-model.md       # Handler threads, queues, synchronization points
├── 03-capture-pipeline.md      # Camera2 session, CaptureRequest flow
├── 04-gpu-opengl.md            # EGL, SurfaceTexture, shader programs
├── 05-cpp-sinks.md             # Generic C++ consumer registration, JNI, AHardwareBuffer
├── 06-state-machine.md         # Kotlin state enum, transitions, guards
├── 07-error-recovery.md        # Stall watchdog, RECOVERING state, recovery strategy
├── 08-camera-controls.md       # Camera2 CaptureRequest keys used and how
├── 09-capture-recording.md     # ImageReader, MediaRecorder patterns
├── 10-build-config.md          # Gradle, CMake, native dependencies
└── 11-git-archaeology.md       # Design decisions and rationale from commit history
```

**Mental model:** "I'm writing documentation for someone who will read it later. I describe what exists, how it behaves, and why (from git and comments)."

**Simplified from current Cartographer:** No L1-L5 layering. No translation cards. No iOS terminology. No platform mapping. Just facts about the Android system organized by Android structure.

**Forbidden:** iOS terminology, "translation cards," "what needs to change," platform comparisons, phrases like "iOS equivalent" or "when we port this."

**Tool strategy:**
- Primary: Read packed files in `packed/`
- Follow-up: Read/Grep on original source
- Git: `git log --oneline` first, then `git show <hash>` selectively
- Screenshots in `screenshots/` for UI capture

**Critical clarification:** The Android app's C++ sink is a generic consumer registration pattern. It does NOT use OpenCV. Document the pattern as it exists — pluggable consumers that receive frames via some memory handoff — without assuming any specific consumer implementation.

### Agent 2 — EXTRACT

**Role:** Requirements analyst translating Android facts into platform-neutral behavioral specifications.

**Input:** `audit/` only (never reads source code, git, or reference docs directly).

**Output:** `domain/` directory organized by behavioral concern.

```
domain/
├── README.md                     # Entry point for iOS designer
├── 01-system-purpose.md          # Missions, topology (platform-neutral), success criteria
├── 02-frame-delivery.md          # Rate, formats, latency, back-pressure behavior
├── 03-camera-control.md          # Parameters, valid ranges, interaction constraints
├── 04-concurrency-invariants.md  # What must be serialized, race conditions to prevent
├── 05-resource-lifecycle.md      # Creation/teardown ordering, cleanup invariants
├── 06-error-and-recovery.md      # Stall detection semantics, recovery contracts
├── 07-performance-budgets.md     # Timing constraints, memory limits, throughput targets
├── 08-capture-and-recording.md   # Still image and video behavioral requirements
├── 09-ui-behaviors.md            # Control surface requirements (from screenshots + API)
├── 10-api-contract.md            # Functional interface (translated from Pigeon definitions)
├── 11-what-not-to-port.md        # Android-specific items explicitly excluded from requirements
└── 12-unresolved.md              # Ambiguities flagged for iOS designer
```

**Mental model:** "Given what this Android code does, what must ANY camera-to-ML-pipeline app do to meet these behavioral requirements?"

**Language rules (strict):**
- ALLOWED: "the system must," "when X happens, the pipeline must Y," "frame stall detection must fire within 2 seconds"
- FORBIDDEN identifier names (case-sensitive class/function names from Android): `Camera2`, `CameraDevice`, `CaptureSession`, `CaptureRequest`, `CameraCaptureSession`, `Handler`, `Looper`, `HandlerThread`, `SurfaceTexture`, `AHardwareBuffer`, `ImageReader`, `MediaRecorder`, `backgroundHandler`, `mainHandler`, `EGLContext`, `EGLSurface`, `GLSurfaceView`, and any Android SDK or NDK class/function name
- ALLOWED: lowercase generic terminology — "capture session," "frame buffer," "preview surface," "device," "GPU pipeline stage," "background thread" (the lowercase generic concept is domain terminology; the CamelCase/snake_case identifiers are Android-specific)
- ALLOWED: quantitative facts — "2000ms threshold," "30fps target," "4-buffer pool"
- FORBIDDEN: Android-specific reasoning — "because Camera2 does X"
- ALLOWED: domain reasoning — "because camera hardware occasionally stalls without signaling"

**The distinction:** Generic concepts like "capture session" exist in every camera framework — that's fine. Specific identifiers like `CameraCaptureSession` are Android SDK class names — those are forbidden because they leak platform structure.

**Classification discipline:** Every item in `audit/` is classified as:
- **Domain** → written to `domain/` as a platform-neutral requirement
- **Android-specific** → written to `domain/11-what-not-to-port.md` with reason
- **iOS-specific concern** → flagged in `domain/12-unresolved.md` (iOS designer will handle)
- **Unclear** → written to `domain/12-unresolved.md` with the ambiguity

**Traceability:** Every domain doc entry links back to its source in `audit/` using a footnote or cross-reference format (e.g., "[audit §02-threading-model]").

**Self-audit rule:** Before finalizing `domain/`, Agent 2 must grep its own output for forbidden Android API names. Any hit must be rewritten.

### Agent 3 — DESIGN

**Role:** iOS architect designing from behavioral requirements.

**Input:**
- Primary: `domain/` directory (read in full)
- Embedded in the prompt text: iOS expertise as a `<reference-architecture>` section — patterns, frameworks, idioms, concurrency model. This is part of the prompt itself, not a separate file the agent must read.
- Escape hatch: `audit/` appendix, only for specific enumerated reasons (see Escape hatch rules below)

**Output:** `design/` directory.

```
design/
├── README.md
├── 01-architecture.md            # Sandwich pattern, module layout, layer diagram
├── 02-concurrency.md             # Actors, Sendable strategy, queue isolation
├── 03-metal-pipeline.md          # Metal 4, VTFrameProcessor, textures, shaders, profiling
├── 04-opencv-integration.md      # Swift-C++ interop, zero-copy bridge, edge detection consumer
├── 05-implementation-phases.md   # 6 phases with file trees and acceptance criteria
├── 06-decisions-log.md           # Every significant choice with alternatives
├── 07-ios-specific-risks.md      # Thermal, pressure, permissions, multi-app conflicts
└── 08-audit-lookups.md           # Log of every time Agent 3 consulted audit/
```

**Mental model:** "I'm an iOS architect building a camera-to-ML-pipeline app. Here are the behavioral requirements. What's the best iOS solution?"

**iOS expertise injected in the prompt** (not extracted from audit):
- Sandwich architecture: SwiftUI top, UIViewRepresentable middle, CameraEngine bottom
- Zero-copy patterns: CVMetalTextureCache for CVPixelBuffer → MTLTexture, CVPixelBufferGetBaseAddress for cv::Mat
- Swift 6 concurrency: actors, @globalActor (e.g., @MLProcessor), Sendable, nonisolated methods for MTKViewDelegate
- iOS 26+ frameworks: Metal 4, VTFrameProcessor (evaluate before custom shaders), MetalFX (upscaling), Swift-C++ interop (direct, prefer over ObjC++)
- Back-pressure: AsyncStream with `.bufferingNewest(1)`
- OpenCV iOS integration: framework via SPM/CocoaPods/xcframework
- iOS-specific failure modes: thermal throttling, AVCaptureDevice.SystemPressureState, permission denial, multi-app camera conflicts

**NEW requirement (not from Android audit):** Design a generic C++ consumer interface for iOS (matching the pluggable pattern from the Android system) AND a concrete OpenCV edge detection consumer as the first implementation of that interface. The edge detection consumer is a proof-of-concept that validates:
- OpenCV iOS is correctly linked and callable from the C++ consumer code
- The consumer registration pattern works end-to-end
- The zero-copy frame bridge (CVPixelBuffer → cv::Mat) works correctly
- Sendable result types flow from C++ back to SwiftUI overlay

Implementation details for the edge detection consumer:
- Implements the generic consumer interface (receives frames via zero-copy handoff)
- Wraps the pixel buffer in a `cv::Mat` and runs `cv::Canny` (or similar edge detection)
- Returns a binary edge mask or edge coordinates as a Sendable result type
- Results render as an overlay on the preview in SwiftUI

Both the generic interface and the edge detection consumer must be concretely designed in `design/04-opencv-integration.md` with types, thread transitions, and file tree entries in `design/05-implementation-phases.md` (targeted for Phase 3). The generic interface enables future consumers; the edge detection consumer proves the pattern works.

**Escape hatch rules:** Agent 3 may consult `audit/` ONLY when:
1. `domain/` uses the phrase "NEEDS INVESTIGATION" or "SEE AUDIT §X"
2. Verifying a specific numerical value (timing threshold, frame dimensions, matrix coefficients)
3. A domain requirement is ambiguous and the ambiguity affects a design decision

Every consultation logged in `design/08-audit-lookups.md` with: section accessed, reason, what was learned, whether it changed the design. Unlogged audit reads are a quality gate failure.

### Agent 4 — REVIEW

**Role:** Independent verifier running two passes with different mental models.

**Input:** `domain/` and `design/` only. Explicitly NOT `audit/`.

**Output:** `review/` directory with two sub-reports.

```
review/
├── README.md                       # Summary verdict: Green / Yellow / Red
├── 01-correctness-check.md         # Requirements coverage, traceability, completeness
└── 02-adversarial-red-team.md      # Ranked failure modes, attacked assumptions
```

**Pass 1 — Correctness Check:**

Mental model: "Does this design do everything the domain requires? Is nothing missed?"

Produces a table with pass/fail per item:
- Every domain invariant in `domain/04-concurrency-invariants.md` has a corresponding iOS enforcement mechanism in `design/02-concurrency.md`
- Every edge case in `domain/06-error-and-recovery.md` has handling in the design
- Every API contract method in `domain/10-api-contract.md` has an implementation plan (or explicit N/A justification)
- Every item in `domain/11-what-not-to-port.md` is confirmed absent from the design
- Every phase in `design/05-implementation-phases.md` has testable acceptance criteria and a concrete file tree
- Every decision in `design/06-decisions-log.md` has alternatives considered
- The OpenCV edge detection consumer is concretely designed with types, threads, and phase placement

**Pass 2 — Adversarial Red Team:**

Mental model: "This design will fail in production. What fails first? Attack every assumption."

Focus areas:
- Race conditions: what happens when two actors access the same state concurrently?
- Resource exhaustion: thermal pressure for 30 minutes, system pressure, memory pressure
- Timing assumptions: what if the camera callback is delayed? What if Metal submission blocks?
- iOS-specific edge cases: app backgrounding mid-recording, permission revocation mid-session, another app taking the camera, interruption handlers
- Sendable boundary violations: could any code path pass a non-Sendable type across actor isolation?
- Escape hatch abuse: did `design/08-audit-lookups.md` show Android-specific contamination creeping in?

Output: ranked list of likely failure modes with severity (Critical / High / Medium / Low) and which design section needs revision.

**Verdict in `review/README.md`:**
- **Green** — ship it, minor issues only
- **Yellow** — significant issues, user decides whether to re-run Agent 3 with findings
- **Red** — critical issues, design should not proceed to implementation as-is

The Reviewer never reads `audit/`. If it believes a domain requirement is missing or wrong, the finding is "fix `domain/`," which means re-running Agent 2 (not patching Agent 3).

## Key Design Rules

### Rule 1 — Language discipline in `domain/`
No Android API names anywhere. Agent 2 self-audits via grep before finalizing. Forbidden: `Camera2`, `Handler`, `Looper`, `SurfaceTexture`, `AHardwareBuffer`, `CaptureRequest`, `CaptureSession`, `ImageReader`, `MediaRecorder`, `backgroundHandler`, `mainHandler`, `EGL`, `GLES`, any class or function from the Android SDK or Android NDK. Generic camera terminology is allowed.

### Rule 2 — Different organizational structures enforce separation
`audit/` organized by Android structure. `domain/` organized by behavioral concern. Intentionally different shapes so the iOS agent cannot treat `domain/` as "translated Android docs."

### Rule 3 — iOS expertise is injected, not extracted
Metal 4, Sendable, VTFrameProcessor, thermal throttling, Swift-C++ interop, AVFoundation patterns — all come from Agent 3's prompt, not from anything Agent 1 or 2 could produce. This is the source of all iOS-native thinking.

### Rule 4 — OpenCV is a NEW requirement for iOS
The Android app does not use OpenCV. The iOS design adds a concrete OpenCV edge detection consumer as a proof-of-concept that:
- Validates OpenCV iOS is correctly linked and callable
- Exercises the full consumer registration pattern end-to-end
- Verifies the zero-copy frame bridge (CVPixelBuffer → cv::Mat)
- Forces the design to be compatible with OpenCV's expectations

This is additive, not translated. Agent 3's prompt explicitly introduces this requirement.

### Rule 5 — Escape hatch is logged, never silent
Every Agent 3 read of `audit/` is logged in `design/08-audit-lookups.md`. The log entry includes section, reason, what was learned, whether it changed the design. The Reviewer checks this log to detect contamination patterns.

### Rule 6 — Reviewer lives in the iOS concurrency domain
Agent 4 never reads `audit/`. If a gap exists, the answer is "fix `domain/`" (re-run Agent 2) or "fix `design/`" (re-run Agent 3), never "let the reviewer patch it."

### Rule 7 — Positive instructions over defensive guards
Each agent prompt uses positive instructions ("do X") rather than defensive lists ("don't do Y") wherever possible. The only guards are those that address specific failure modes identified from prior iteration.

## Critical Files

```
ios-translation/
├── README.md                       # Pipeline overview, updated for 4-agent flow
├── setup.sh                        # Pre-step (unchanged)
├── prompt-1-audit.md               # NEW
├── prompt-2-extract.md             # NEW
├── prompt-3-design.md              # NEW
├── prompt-4-review.md              # NEW
├── packed/                         # Repomix output
├── screenshots/                    # UI screenshots
├── reference/                      # Existing Android docs + iOS architecture reference
├── audit/                          # Agent 1 output
├── domain/                         # Agent 2 output (primary input for Agent 3)
├── design/                         # Agent 3 output
└── review/                         # Agent 4 output
```

The existing `prompt-1-cartographer.md` and `prompt-2-architect.md` will be archived (renamed with `.archived` suffix) but not deleted for reference.

## Verification

After implementation, verify end-to-end by running the 4 agents in sequence on the actual Android codebase:

1. **Agent 1** produces `audit/` — spot-check for any iOS terminology creeping in. Should be zero.
2. **Agent 2** produces `domain/` — grep for forbidden Android API names. Must return zero hits. Spot-check that behavioral requirements are platform-neutral.
3. **Agent 3** produces `design/` — verify it contains a concrete OpenCV edge detection consumer design. Verify `design/08-audit-lookups.md` exists and logs any audit reads.
4. **Agent 4** produces `review/` — verify both correctness and adversarial passes are present with actionable findings.

Manual verification of the quality of outputs is subjective but the key signals:
- Does `domain/` feel like "requirements for a camera app" or "translated Android docs"? It should feel platform-neutral.
- Does `design/` think in iOS idioms (actors, Sendable, Metal 4) or Android idioms translated (Handler → DispatchQueue, Camera2 → AVCaptureSession)? It should think in iOS.
- Does the Reviewer find issues the Designer missed? If it rubber-stamps everything, the adversarial pass is not working.

## Open Questions

1. Should Agent 1 also produce a diff showing what's in `reference/architecture.md` and `reference/usage-guide.md` vs what's in the code? These docs may be stale.
2. Should Agent 2 have a "confidence level" per domain requirement (high/medium/low confidence that this is truly domain-level vs Android-specific)?
