# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not** an iOS codebase. It is a prompt-engineering workspace containing a
multi-agent "clean room" pipeline that translates a Flutter + Android camera library
(`/Users/shrek/work/cambrian/camera2_flutter_demo`) into a native iOS 26 / Swift 6 / Metal 4
design. The artifacts here are markdown prompts and markdown outputs — there is no Swift,
no Xcode project, and no build/lint/test loop.

The "code" is the agent prompts plus two verify scripts (`implementation/scripts/`); correctness
is enforced by grep-based and swift-build-based verification between stages, not by a compiler
watching the whole tree.

## Pipeline (run in order)

| Stage | Prompt file | Reads | Writes |
|---|---|---|---|
| 1 AUDIT | `prompt-1-audit.md` | `packed/`, `reference/`, `screenshots/` | `audit/` |
| 2 EXTRACT | `prompt-2-extract.md` | `audit/` only | `domain/` |
| 2.5 MANUAL REVIEW | (human) | `domain/` | `domain-revised/` |
| 3 ARCHITECT | `implementation/prompts/agent-3-architect.md` | `domain-revised/` + `ios-platform-guide/` | `implementation/architecture/` + `implementation/stages/` |
| 3.5 MECHANICAL | `implementation/scripts/verify-architecture.sh` | Agent 3 output | `implementation/review/mechanical.md` |
| 4 ARCHITECTURE REVIEW | `implementation/prompts/agent-4-review.md` | Agent 3 output + mechanical.md | `implementation/review/` (verdict) |
| 5 BRIEF WRITER | `implementation/prompts/agent-5-brief-writer.md` | Reviewed architecture + stages | `implementation/briefs/` |
| 5.5 MECHANICAL | `implementation/scripts/verify-briefs.sh` | Agent 5 output | (stdout) |
| 6 IMPLEMENT | Claude Code (separate repo) | `implementation/briefs/` + `implementation/architecture/` + `ios-platform-guide/` | Swift code + tests + `state.md` |

The Agent 3/4/5 pipeline and its two verify scripts are designed per
`docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` and built by
`docs/superpowers/plans/2026-04-19-implementation-pipeline.md`. `implementation/README.md`
orients at the subdirectory level.

`ios-platform-guide/` is a human-authored input to Agent 3 (not produced by any agent). It
contains platform-level ADRs (ADR-01 … ADR-29) and gotchas (G-01 … G-30). Update it by hand
when iOS conventions change; design outputs cite ADRs by ID and deviate only via a `D-##`
decision that names the ADR.

## The load-bearing architectural rule: clean room separation

Agent 3 (ARCHITECT) reads the platform-neutral `domain-revised/` as its primary input so
Android structure cannot leak into the iOS architecture. `domain-revised/` is a manually
reviewed and corrected version of `domain/` (Agent 2's output). The invariant:

- **`domain-revised/` contains zero Android API names.** Verify before running Agent 3.
- **Agent 3 reads only `domain-revised/` + `ios-platform-guide/`.** It does not read `audit/`;
  gaps in `domain-revised/` must be patched upstream, not routed around by reaching into
  Android-structured facts.

`audit/` is organized by Android component; `domain-revised/` is organized by behavioral concern.
The deliberately different shapes are what stop `domain-revised/` from being read as "translated
Android docs".

## Common operations

```bash
# Bootstrap: pack the Android source via repomix and copy reference docs.
# Requires npm (installs repomix globally if missing) and the source repo at
# /Users/shrek/work/cambrian/camera2_flutter_demo.
./setup.sh

# Verification greps — run after the matching agent, expect 0 hits unless noted.
# After Agent 1 (AUDIT): no iOS terminology leaked in.
grep -rn -E 'iOS|Swift|Metal|AVCapture|CVPixelBuffer|UIKit|SwiftUI' audit/

# After Agent 2 (EXTRACT): no Android API names or translation reasoning.
grep -rn -E 'Camera2|CameraCaptureSession|CaptureRequest|HandlerThread|SurfaceTexture|AHardwareBuffer|ImageReader|MediaRecorder|EGLContext' domain/
grep -rn -E 'because Camera2|Android equivalent|iOS equivalent|Kotlin|the Android version' domain/

# Before Agent 3 (DESIGN): verify domain-revised/ is clean (same checks, different dir).
grep -rn -E 'Camera2|CameraCaptureSession|CaptureRequest|HandlerThread|SurfaceTexture|AHardwareBuffer|ImageReader|MediaRecorder|EGLContext' domain-revised/
grep -rn -E 'because Camera2|Android equivalent|iOS equivalent|Kotlin|the Android version' domain-revised/

# After Agent 3 (ARCHITECT): run mechanical checks M1-M8. Must pass before Agent 4 runs.
./implementation/scripts/verify-architecture.sh implementation/

# After Agent 4 (ARCHITECTURE REVIEW): extract verdict.
grep -E 'Verdict: (Green|Yellow|Red)' implementation/review/README.md

# After Agent 5 (BRIEF WRITER): run mechanical checks M1-M5 on briefs/.
./implementation/scripts/verify-briefs.sh implementation/
```

There is no build, no linter, and no test runner. The grep commands above *are* the test suite.

## Context-sensitive language rule for `domain/` and `domain-revised/`

Several Android class names are also ordinary English words (`Handler`, `Surface`, `Image`,
`Message`). Both `domain/` and `domain-revised/` may use them in their English sense ("the
image buffer") but must not use them as Android type references ("the `ImageReader`"). When
reviewing either directory, judge by whether the word names an Android API surface, not by
raw grep hits on the word alone.

## iOS platform baseline (from `ios-platform-guide/`, not the Android source)

The iOS platform conventions Agent 3 builds on live in `ios-platform-guide/`, not in the
Agent 3 prompt and not derivable from `audit/`. Headline choices:

- iOS 26+, Swift 6 strict concurrency, Metal 3 baseline (Metal 4 features `#available`-gated),
  SwiftUI + `MTKView` via `UIViewRepresentable`.
- Two-file architecture baseline: `CameraView.swift` (SwiftUI + inline `UIViewRepresentable`
  + ViewModel) and `CameraEngine.swift` (one actor owning `AVCaptureSession`, Metal,
  consumers). See `ios-platform-guide/01-architecture.md` ADR-01/02.
- Direct GPU outputs (preview, encoder via IOSurface pool, still readback) vs async consumers
  (C++ CV pipelines with drop-on-busy dispatch). Preview is inviolable — sync consumer
  dispatch is forbidden. ADR-03, ADR-13.
- Zero-copy Metal via `CVMetalTextureCache` (ADR-04), working format `rgba16Float` for color
  pipelines (ADR-05), GPU→encoder via IOSurface-backed `CVPixelBufferPool` + `MTLBlitCommandEncoder`
  (ADR-06, ADR-16).
- Swift ↔ C++ direct interop with `.interoperabilityMode(.Cxx)`; OpenCV headers stay private
  to `.cpp` files; no Objective-C++ anywhere (ADR-11, ADR-12).
- scenePhase `.background` stops the session; `.inactive` gates GPU submission (Metal
  background rule; ADR-08, ADR-09).
- `CVPixelBuffer` and `cv::Mat` are not `Sendable`; buffer handling stays on one queue and
  only plain `Sendable` result structs cross actor boundaries (ADR-10).
- OpenCV is a **new capability** (Android doesn't use it) validated via an edge-detection
  consumer proof-of-concept.

Update `ios-platform-guide/` by hand when platform conventions change. Do not try to
"extract" these from the Android source — they're iOS-native.

## Reviewer discipline

Agent 4 (ARCHITECTURE REVIEW) never reads `audit/`. If the reviewer finds a gap, the
remedy is always "fix `domain-revised/`" or "rerun Agent 3 with findings attached", never
a localized patch to `implementation/architecture/`. Re-run the upstream agent instead of
hand-editing the output.

## Commit discipline

Agents produce files but **never run git operations**. All commits require explicit user
approval. Recent history shows one commit per agent prompt (semantic, ordered
docs → features → chore) so that each stage can be reverted independently.

## Background reading (only when needed)

- `README.md` — operator-facing overview, always current.
- `docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md` — formal spec
  for Agents 1-2 (language rules, classification discipline, escape hatch rules).
- `docs/superpowers/plans/2026-04-12-clean-room-prompt-redesign.md` — implementation plan
  used to build the first 4 prompts.
- `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` — formal spec for
  the Agent 3/4/5 pipeline (architecture + stages + briefs; M-bar/J-bar discipline).
- `docs/superpowers/plans/2026-04-19-implementation-pipeline.md` — implementation plan
  used to build the Agent 3/4/5 prompts and the two verify scripts.
- `reference/` — Android source docs copied by `setup.sh`; `reference/CLAUDE.md` is the
  *source* project's CLAUDE, not this project's.
