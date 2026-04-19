# iOS Translation — Clean Room Pipeline

A 4-agent pipeline for translating the Flutter/Android camera library to a native iOS/Swift app using a clean room approach: platform-neutral domain knowledge is the primary input to iOS design, preventing Android structure from leaking into the design.

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

Two options:

### Option A — Manual (one agent at a time)

Open a fresh Claude Code session in this directory, then paste each prompt file in order, reviewing the output between agents:

1. Paste `prompt-1-audit.md` → verify `audit/` populated (13 files)
2. Paste `prompt-2-extract.md` → verify `domain/` populated, grep for Android API leakage
3. Review `domain/` yourself (language discipline, classifications)
4. Paste `prompt-3-design.md` → verify `design/` populated, check `design/08-audit-lookups.md`
5. Paste `prompt-4-review.md` → read `review/README.md` for Green/Yellow/Red verdict
6. Begin implementation using Phase 1a from `design/05-implementation-phases.md`

### Option B — Orchestrator (automated with checkpoints)

Use the orchestrator prompt (drafted in this conversation — not yet saved to a file) to dispatch all 4 agents as sonnet subagents with automated verification between phases. The orchestrator pauses for user approval between agents and halts on language-discipline failures. See `clean-room-convo.md` for the design.

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
├── clean-room-convo.md                    # Design conversation summary (decisions + rationale)
├── setup.sh                               # Pre-step: repomix pack + reference doc copy
│
├── prompt-1-audit.md                      # Agent 1 (run first)
├── prompt-2-extract.md                    # Agent 2 (run second)
├── prompt-3-design.md                     # Agent 3 (run third)
├── prompt-4-review.md                     # Agent 4 (run fourth)
│
├── prompt-1-cartographer.md.archived      # Previous 2-prompt pipeline (kept for reference)
├── prompt-2-architect.md.archived         # Previous 2-prompt pipeline (kept for reference)
│
├── docs/superpowers/
│   ├── specs/2026-04-12-clean-room-prompt-redesign-design.md   # Design rationale
│   └── plans/2026-04-12-clean-room-prompt-redesign.md          # Implementation plan
│
├── packed/                                # Repomix output (generated by setup.sh)
├── screenshots/                           # UI screenshots (user provides)
├── reference/                             # Android docs copied by setup.sh
│
├── audit/                                 # Agent 1 output — Android-structured facts (empty until run)
├── domain/                                # Agent 2 output — platform-neutral requirements (empty until run)
├── design/                                # Agent 3 output — iOS architecture + phased plan (empty until run)
└── review/                                # Agent 4 output — findings report (empty until run)
```

---

## Key Architecture Decisions

- **Clean room separation**: Agent 3 reads platform-neutral `domain/` as primary input. `audit/` is an escape hatch for specific lookups only, and every lookup is logged in `design/08-audit-lookups.md`.
- **Different organizational structures enforce separation**: `audit/` is organized by Android component; `domain/` is organized by behavioral concern. The different shape prevents `domain/` from being read as "translated Android docs."
- **Language discipline**: `domain/` contains zero Android API names. Enforced by Agent 2's mandatory `grep` self-audit phase, with a context-sensitive rule for common English words (`Handler`, `Surface`, `Image`, `Message`) that double as Android class names.
- **iOS expertise is injected, not extracted**: Metal 4, Swift 6 actors, `Sendable`, VTFrameProcessor, OpenCV iOS — these come from Agent 3's reference architecture section, not from anything the Android audit could produce.
- **OpenCV is a new capability**: Android has a generic C++ consumer registration pattern but doesn't use OpenCV. iOS design adds an OpenCV edge detection consumer as proof-of-concept to validate the full integration path.
- **Sendable strategy**: `CVPixelBuffer` and `cv::Mat` are not Sendable. All buffer handling stays on one queue; only plain Sendable result structs cross actor boundaries.
- **Two-pass review**: Correctness (every requirement met?) + Adversarial (what fails in production?). The reviewer never reads `audit/` — if gaps exist, the answer is "fix `domain/`" or "fix `design/`", never patch.
- **Never commits automatically**: All agents produce files but require user approval before any git operation.

---

## iOS Implementation Phases (produced by Agent 3)

```
Phase 1a  Camera capture + state machine + lifecycle + permissions
Phase 1b  Camera controls (focus, AWB, AE, ISO, exposure, zoom)
Phase 2   Metal processing pipeline (replace raw preview with MTKView)
Phase 3   C++ integration + OpenCV edge detection consumer + fan-out topology
Phase 4   Performance tuning + thermal/pressure resilience
Phase 5   Capture + recording (AVAssetWriter, EXIF)
Phase 6   Parity audit + polish
```

Each phase produces a testable milestone with a concrete file tree.

---

## Verification Checks (run between agents)

After each agent, run these checks before proceeding:

| After Agent | Check | Command |
|---|---|---|
| 1 (AUDIT) | No iOS terminology in audit/ | `grep -rn -E 'iOS\|Swift\|Metal\|AVCapture\|CVPixelBuffer\|UIKit\|SwiftUI' audit/` (expect 0 hits outside of forbidden-list context) |
| 2 (EXTRACT) | No Android API names in domain/ | `grep -rn -E 'Camera2\|CameraCaptureSession\|CaptureRequest\|HandlerThread\|SurfaceTexture\|AHardwareBuffer\|ImageReader\|MediaRecorder\|EGLContext' domain/` (expect 0 hits) |
| 2 (EXTRACT) | No forbidden reasoning | `grep -rn -E 'because Camera2\|Android equivalent\|iOS equivalent\|Kotlin\|the Android version' domain/` (expect 0 hits) |
| 3 (DESIGN) | Audit lookups logged | `cat design/08-audit-lookups.md` (>10 entries is a yellow flag) |
| 3 (DESIGN) | OpenCV edge detection designed | `grep -l 'cv::Canny\|EdgeDetection' design/04-opencv-integration.md` |
| 4 (REVIEW) | Verdict extracted | `head -20 review/README.md` (look for Green/Yellow/Red) |

---

## Expected File Counts

| Directory | Files | Contents |
|-----------|-------|----------|
| `audit/` | 13 | `README.md` + `01-system-topology.md` through `12-git-archaeology.md` (includes `04-pigeon-api.md` added during implementation) |
| `domain/` | 13 | `README.md` + `01-system-purpose.md` through `12-unresolved.md` |
| `design/` | 9 | `README.md` + `01-architecture.md` through `08-audit-lookups.md` |
| `review/` | 3 | `README.md` + `01-correctness-check.md` + `02-adversarial-red-team.md` |

---

## If Agent 4 Returns Yellow or Red

- **Green**: ship it — proceed to implementation
- **Yellow**: read the findings, decide whether to accept risks, re-run Agent 3 with findings as additional input, or patch design files manually
- **Red**: re-run upstream agent (Agent 2 if `domain/` has gaps, Agent 3 if design is missing iOS requirements) with findings attached. Do not proceed to implementation as-is.

**Never auto-rerun.** The reviewer produces findings only; the user decides next action.

---

## Background Reading

- **`clean-room-convo.md`** — Summary of the design conversation with every major branch and decision point. Read this first if you want to understand WHY the pipeline is structured this way.
- **`docs/superpowers/specs/2026-04-12-clean-room-prompt-redesign-design.md`** — Formal spec for Agents 1-2 with language rules, classification discipline, and escape hatch rules.
- **`docs/superpowers/plans/2026-04-12-clean-room-prompt-redesign.md`** — Implementation plan used to build the first 4 prompts.
- **`docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`** — Formal spec for the Agent 3/4/5 pipeline (architecture outputs, stage index schema, M-bar / J-bar discipline).
- **`docs/superpowers/plans/2026-04-19-implementation-pipeline.md`** — Implementation plan used to build the Agent 3/4/5 prompts and the two verify scripts.
- **`implementation/README.md`** — Subdirectory orientation for Agent 3/4/5 artifacts.
- **`docs/paper-simulation-scenephase-drain.md`** — Full schema-walkthrough paper simulation that stress-tested the Agent 3 output schema before building the prompt.

---

## Git History

```
chore(ios-translation): archive 2-prompt pipeline and update README
feat(ios-translation): add Agent 4 (REVIEW) prompt for clean room pipeline
feat(ios-translation): add Agent 3 (DESIGN) prompt for clean room pipeline
feat(ios-translation): add Agent 2 (EXTRACT) prompt for clean room pipeline
feat(ios-translation): add Agent 1 (AUDIT) prompt for clean room pipeline
docs(ios-translation): add clean room prompt redesign spec and plan
```

Semantic commits ordered docs → features → chore. Each agent prompt is isolated in its own commit for easy revert.

---

## Status

✅ Pipeline implemented and committed
✅ All 4 prompts written, reviewed, and consistency-checked
✅ Old 2-prompt pipeline archived for reference
⏳ Pipeline not yet run — `audit/`, `domain/`, `design/`, `review/` are empty
⏳ `setup.sh` needs to be run
⏳ `screenshots/` needs user-provided images

**Next action**: Run `./setup.sh`, add screenshots, then start the pipeline.
