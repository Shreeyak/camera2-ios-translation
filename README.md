# iOS Translation — Clean Room Pipeline

A multi-agent pipeline for translating the Flutter/Android camera library to a native iOS/Swift app using a clean room approach: platform-neutral domain knowledge is the primary input to iOS architecture, preventing Android structure from leaking into the design.

**Source**: `/Users/shrek/work/cambrian/camera2_flutter_demo` (Flutter + Android)
**Target**: iOS 26+, Swift 6, Metal 4, SwiftUI + UIKit

---

## Target Stack

- **iOS 26+**, **Swift 6** (strict concurrency), **Metal 4**
- **SwiftUI** for UI + **UIKit** via `UIViewRepresentable` (for `MTKView`)
- **Swift-C++ direct interop** (Swift 5.9+ feature; ObjC++ only as fallback)
- **OpenCV** — new capability on iOS (Android doesn't use it); validated via an edge detection consumer proof-of-concept
- **Compile-time data race prevention** via Swift 6 actor isolation (`@MainActor`, custom `@globalActor`, `Sendable`)
- **Zero-copy pipeline** (`CVMetalTextureCache`, `CVPixelBuffer` → `cv::Mat` via pointer)
- **Frameworks evaluated**: Metal 4, MetalFX, VTFrameProcessor (iOS 26+)

---

## Quick Start

```bash
cd /Users/shrek/work/cambrian/ios-translation

# 1. Pack the Android codebase (repomix) and copy reference docs
./setup.sh

# 2. Add UI screenshots to screenshots/
#    Name them descriptively: preview-streaming.png, camera-controls.png, etc.
#    At least 3 screenshots recommended. Agent 1 uses these for UI documentation.

# 3. Run the pipeline — see "How to Run" below
```

---

## How to Run

Open a fresh Claude Code session in this directory, then paste each prompt file in order, reviewing the output between agents:

1. Paste `prompt-1-audit.md` → verify `audit/` populated
2. Paste `prompt-2-extract.md` → verify `domain/` populated, grep for Android API leakage
3. Review `domain/` yourself (language discipline, classifications); commit the reviewed version as `domain-revised/`
4. Paste `implementation/prompts/agent-3-architect.md` → verify `implementation/architecture/` + `implementation/stages/` populated, run `./implementation/scripts/verify-architecture.sh implementation/`
5. Paste `implementation/prompts/agent-4-review.md` → read `implementation/review/README.md` for Green/Yellow/Red verdict
6. Paste `implementation/prompts/agent-5-brief-writer.md` → verify `implementation/briefs/` populated, run `./implementation/scripts/verify-briefs.sh implementation/`
7. Hand `implementation/briefs/` + `implementation/architecture/` + `ios-platform-guide/` to Claude Code in a separate Swift repo for the per-stage implementation

---

## Pipeline Agents

| # | Agent | Reads | Writes | Job |
|---|-------|-------|--------|-----|
| 1 | **AUDIT** | Android source, git, reference docs, screenshots | `audit/` | Factual documentation of the Android system — no iOS terminology, no translation |
| 2 | **EXTRACT** | `audit/` only | `domain/` | Translate to platform-neutral behavioral requirements using strict language rules and mandatory grep self-audit |
| 2.5 | **MANUAL REVIEW** (human) | `domain/` | `domain-revised/` | Human pass to repair gaps and tighten language before architecture design runs |
| 3 | **ARCHITECT** | `domain-revised/` + `ios-platform-guide/` | `implementation/architecture/` + `implementation/stages/` | Two-phase run: produce iOS architecture (9 concern files + 4 registers + compiling SwiftPM skeleton), then stage-index walking from zero to target |
| 3.5 | **MECHANICAL (scripted)** | Agent 3 output | `implementation/review/mechanical.md` | `verify-architecture.sh` runs M1–M8 checks (file presence, D-## anchors, swift build, `touches:` validity, scaffolding pairs, cycles, constants, interaction shape tags) |
| 4 | **ARCHITECTURE REVIEW** | Agent 3 output + mechanical.md | `implementation/review/` | Judgement-level J1–J5 review → Green/Yellow/Red verdict; Green required to unblock Agent 5 |
| 5 | **BRIEF WRITER** | Reviewed architecture + stages | `implementation/briefs/` | Per-stage implementation briefs (12-section schema, FLAGGED/HITL/DEFERRED testability classes) |
| 5.5 | **MECHANICAL (scripted)** | Agent 5 output | (stdout) | `verify-briefs.sh` runs M1–M5 (section headings, anchor resolution, retire-matches-introduced, test class fields, FLAGGED retry chain) |

Agents 3/4/5 live under `implementation/prompts/`; scripts live under `implementation/scripts/`.
The full design rationale for the new pipeline is in
`docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`, and the plan that
built it is in `docs/superpowers/plans/2026-04-19-implementation-pipeline.md`.

---

## Directory Structure

```
ios-translation/
├── README.md                              # This file
├── CLAUDE.md                              # Operator rules for agents running in this repo
├── setup.sh                               # Pre-step: repomix pack + reference doc copy
│
├── prompt-1-audit.md                      # Agent 1 (run first)
├── prompt-2-extract.md                    # Agent 2 (run second)
│
├── ios-platform-guide/                    # Human-authored ADRs + gotchas (input to Agent 3)
│
├── implementation/                        # Agent 3/4/5 pipeline (prompts + verify scripts + outputs)
│   ├── prompts/                           # agent-3-architect, agent-4-review, agent-5-brief-writer
│   ├── scripts/                           # verify-architecture.sh + verify-briefs.sh + fixtures
│   ├── architecture/                      # Agent 3 output — iOS architecture + compiling SwiftPM skeleton
│   ├── stages/                            # Agent 3 output — stage-index.md
│   ├── review/                            # Agent 4 output — Green/Yellow/Red verdict
│   └── briefs/                            # Agent 5 output — per-stage implementation briefs
│
├── docs/superpowers/
│   ├── specs/2026-04-12-clean-room-prompt-redesign-design.md   # Spec for Agents 1-2
│   ├── plans/2026-04-12-clean-room-prompt-redesign.md          # Plan for Agents 1-2
│   ├── specs/2026-04-19-implementation-pipeline-design.md      # Spec for Agent 3/4/5
│   └── plans/2026-04-19-implementation-pipeline.md             # Plan for Agent 3/4/5
│
├── packed/                                # Repomix output (generated by setup.sh)
├── screenshots/                           # UI screenshots (user provides)
├── reference/                             # Android docs copied by setup.sh
│
├── audit/                                 # Agent 1 output — Android-structured facts
├── domain/                                # Agent 2 output — platform-neutral requirements
├── domain-revised/                        # Human-reviewed domain/ — authoritative input to Agent 3
│
└── tmp/cleanup/                           # Superseded artifacts from earlier pipeline iterations
```

---

## Key Architecture Decisions

- **Clean room separation**: Agent 3 reads platform-neutral `domain-revised/` + `ios-platform-guide/` only. It does not read `audit/`. Gaps in `domain-revised/` are patched upstream, not routed around.
- **Different organizational structures enforce separation**: `audit/` is organized by Android component; `domain-revised/` is organized by behavioral concern. The different shape prevents `domain-revised/` from being read as "translated Android docs."
- **Language discipline**: `domain-revised/` contains zero Android API names. Enforced by Agent 2's mandatory `grep` self-audit phase, with a context-sensitive rule for common English words (`Handler`, `Surface`, `Image`, `Message`) that double as Android class names.
- **iOS expertise is injected, not extracted**: Metal, Swift 6 actors, `Sendable`, VTFrameProcessor, OpenCV iOS — these come from `ios-platform-guide/` as human-authored ADRs, not from anything the Android audit could produce.
- **Mechanical + judgement split**: `verify-architecture.sh` and `verify-briefs.sh` enforce every rule that can be grep'd, yq'd, or compiled. Agent 4 only judges the things machines can't (soundness, plausibility, coverage).
- **Compiling Swift skeleton**: Agent 3 emits a SwiftPM package of type stubs (`fatalError("Stage N")` bodies). `swift build` runs in CI; signatures can't silently drift between the prose architecture and the downstream implementation.
- **Scaffolding pairs**: Each stage can introduce a temporary crutch as long as a later stage explicitly retires it. The verify scripts enforce pairing — no orphan scaffolds.
- **Sendable strategy**: `CVPixelBuffer` and `cv::Mat` are not Sendable. All buffer handling stays on one queue; only plain Sendable result structs cross actor boundaries.
- **Agent 4 never patches; it rereruns upstream**: if the reviewer finds a gap, the remedy is always "fix `domain-revised/`" or "rerun Agent 3 with findings attached", never a localized patch.
- **Never commits automatically**: All agents produce files but require user approval before any git operation.

---

## Verification Checks (run between agents)

After each agent, run these checks before proceeding:

| After Agent | Check | Command |
|---|---|---|
| 1 (AUDIT) | No iOS terminology in audit/ | `grep -rn -E 'iOS\|Swift\|Metal\|AVCapture\|CVPixelBuffer\|UIKit\|SwiftUI' audit/` (expect 0 hits outside of forbidden-list context) |
| 2 (EXTRACT) | No Android API names in domain/ | `grep -rn -E 'Camera2\|CameraCaptureSession\|CaptureRequest\|HandlerThread\|SurfaceTexture\|AHardwareBuffer\|ImageReader\|MediaRecorder\|EGLContext' domain/` (expect 0 hits) |
| 2 (EXTRACT) | No forbidden reasoning | `grep -rn -E 'because Camera2\|Android equivalent\|iOS equivalent\|Kotlin\|the Android version' domain/` (expect 0 hits) |
| 3 (ARCHITECT) | Mechanical checks M1–M8 | `./implementation/scripts/verify-architecture.sh implementation/` (expect `[OK] All checks passed.`) |
| 4 (ARCHITECTURE REVIEW) | Verdict extracted | `grep -E 'Verdict: (Green\|Yellow\|Red)' implementation/review/README.md` |
| 5 (BRIEF WRITER) | Mechanical checks M1–M5 | `./implementation/scripts/verify-briefs.sh implementation/` (expect `[OK] All checks passed.`) |

---

## If Agent 4 Returns Yellow or Red

- **Green**: proceed to Agent 5 (brief writer); after briefs pass, hand off to the downstream Swift repo for implementation.
- **Yellow**: read the findings in `implementation/review/findings.md`; rerun Agent 3 with the findings attached. Agent 5 remains blocked.
- **Red**: rerun Agent 3 fully with the findings attached. Agent 5 remains blocked.
- **3 consecutive Yellows**: Agent 4 halts and recommends human override, narrower mechanical check, or spec-level schema change (see `implementation/prompts/agent-4-review.md`).

**Never auto-rerun.** The reviewer produces findings only; the user decides next action.

---

## Background Reading

- **`docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md`** — Formal spec for Agents 1-2 with language rules, classification discipline, and escape hatch rules.
- **`docs/superpowers/plans/2026-04-12-clean-room-prompt-redesign.md`** — Implementation plan used to build the first 4 prompts.
- **`docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`** — Formal spec for the Agent 3/4/5 pipeline (architecture outputs, stage index schema, M-bar / J-bar discipline).
- **`docs/superpowers/plans/2026-04-19-implementation-pipeline.md`** — Implementation plan used to build the Agent 3/4/5 prompts and the two verify scripts.
- **`implementation/README.md`** — Subdirectory orientation for Agent 3/4/5 artifacts.

---

## Status

✅ Pipeline implemented and committed (Agents 1-5 + two verify scripts)
✅ `ios-platform-guide/` authored and reviewed
✅ `domain-revised/` reviewed and committed
⏳ Agent 3/4/5 not yet run end-to-end — `implementation/architecture/`, `stages/`, `review/`, `briefs/` are empty
⏳ Downstream Swift repo not yet started

**Next action**: Run Agent 3 against `domain-revised/` + `ios-platform-guide/`, then the verify scripts, then Agents 4 and 5.
