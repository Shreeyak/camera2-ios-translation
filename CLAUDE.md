# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is **not** an iOS codebase. It is a prompt-engineering workspace containing a 4-agent
"clean room" pipeline that translates a Flutter + Android camera library
(`/Users/shrek/work/cambrian/camera2_flutter_demo`) into a native iOS 26 / Swift 6 / Metal 4
design. The artifacts here are markdown prompts and markdown outputs — there is no Swift,
no Xcode project, and no build/lint/test loop.

The "code" is the four prompt files, and correctness is enforced by grep-based verification
between stages, not by a compiler.

## Pipeline (run in order)

| Stage | Prompt file | Reads | Writes |
|---|---|---|---|
| 1 AUDIT | `prompt-1-audit.md` | `packed/`, `reference/`, `screenshots/` | `audit/` (13 files, Android-structured facts) |
| 2 EXTRACT | `prompt-2-extract.md` | `audit/` only | `domain/` (13 files, platform-neutral requirements) |
| 2.5 MANUAL REVIEW | (human) | `domain/` | `domain-revised/` (manually reviewed & corrected domain files) |
| 3 DESIGN | `prompt-3-design.md` | `domain-revised/` (what) + `ios-platform-guide/` (how) + `audit/` escape hatch | `design/` (9 files, iOS architecture citing ADR-## by ID) |
| 4 REVIEW | `prompt-4-review.md` | `domain-revised/` + `ios-platform-guide/` + `design/` only | `review/` (3 files, Green/Yellow/Red verdict) |

`ios-platform-guide/` is a human-authored input to Agent 3 (not produced by any agent). It
contains platform-level ADRs (ADR-01 … ADR-20) and gotchas (G-01 … G-26). Update it by hand
when iOS conventions change; design outputs cite ADRs by ID and deviate only via a `D-##`
decision that names the ADR.

`orchestrator-prompt.md` is an experimental all-in-one driver. `*.archived` files are the
old 2-prompt pipeline kept for reference — do not edit or re-activate them.

## The load-bearing architectural rule: clean room separation

Agent 3 (DESIGN) reads the platform-neutral `domain-revised/` as its primary input so Android
structure cannot leak into the iOS design. `domain-revised/` is a manually reviewed and
corrected version of `domain/` (Agent 2's output). Two invariants enforce clean room separation:

1. **`domain-revised/` contains zero Android API names.** Verify before running Agent 3.
2. **`audit/` is an escape hatch only.** Every lookup Agent 3 makes into `audit/` is logged
   in `design/08-audit-lookups.md`. More than ~10 entries is a yellow flag that `domain-revised/`
   has a gap — the fix is to patch `domain-revised/`, never to route around it.

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

# After Agent 3 (DESIGN): audit lookups stayed bounded, OpenCV consumer is designed.
cat design/08-audit-lookups.md                     # >10 entries = yellow flag
grep -l 'cv::Canny\|EdgeDetection' design/04-opencv-integration.md

# After Agent 3 (DESIGN): every design file cites at least one ADR from ios-platform-guide/.
# Run separately; each file (01..07) should report ≥ 1.
for f in design/0[1-7]-*.md; do echo "$f: $(grep -cE 'ADR-[0-9]+' "$f")"; done

# After Agent 4 (REVIEW): extract verdict.
head -20 review/README.md                          # look for Green / Yellow / Red
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

Agent 4 never reads `audit/`. If the reviewer finds a gap, the remedy is always "fix
`domain-revised/`" or "fix `design/`", never a localized patch. Re-run the upstream agent
with the findings attached instead of hand-editing the output.

## Commit discipline

Agents produce files but **never run git operations**. All commits require explicit user
approval. Recent history shows one commit per agent prompt (semantic, ordered
docs → features → chore) so that each stage can be reverted independently.

## Background reading (only when needed)

- `README.md` — operator-facing overview, always current.
- `clean-room-convo.md` — design conversation with every branch point and rationale. Read
  first if you need to understand *why* the pipeline is shaped this way.
- `docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md` — formal spec
  (language rules, classification discipline, escape hatch rules).
- `docs/superpowers/plans/2026-04-12-clean-room-prompt-redesign.md` — implementation plan
  used to build the 4 prompts.
- `reference/` — Android source docs copied by `setup.sh`; `reference/CLAUDE.md` is the
  *source* project's CLAUDE, not this project's.
