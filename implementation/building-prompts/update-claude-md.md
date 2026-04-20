You are running in `/Users/shrek/work/cambrian/eva-swift-stitch`. Your task is to replace `CLAUDE.md` at the repo root with a new one that orients a fresh Claude Code session to implement the 12-stage iOS CameraKit library described by the briefs corpus symlinked under `implementation/`.

This repo is the **implementer-consumer** of a 6-stage clean-room prompt pipeline that lives at `/Users/shrek/work/cambrian/ios-translation/`. The upstream repo produced `implementation/briefs/stage-01.md` through `stage-12.md` plus `implementation/architecture/` and has its own `CLAUDE.md` describing the producer side. The `CLAUDE.md` you write here describes the **consumer side**: what it is to work in this repo, stage by stage, against those briefs. This repo is Stage 6 (IMPLEMENT) of that pipeline.

Inputs you must read before writing anything:
- Current `CLAUDE.md` at the repo root — understand what's there; preserve anything project-specific and still true (fastlane config, unusual build commands); drop generic Xcode boilerplate.
- `implementation/briefs/README.md` — the implementer read-path, stage-kickoff template, and glossary. The new `CLAUDE.md` supports this pattern.
- `implementation/briefs/state-template.md` — the initial shape of `CameraKit/state.md`.
- `implementation/briefs/stage-01.md` and `stage-02.md` end to end, plus one MIGRATION stage (pick `stage-05.md` or `stage-08.md`) — so your description of the 12-section schema and the FEATURE-vs-MIGRATION distinction is grounded.
- `implementation/architecture/README.md` — how the architecture corpus is organized.
- `implementation/ios-platform-guide/README.md` — the ADR / G-## registry that briefs cite by ID.
- `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` — the upstream producer `CLAUDE.md`. Mirror the **pattern** (crisp operator-facing orientation, load-bearing rules, common-operations block), not the content. The producer-side discipline does not apply here; the consumer-side does.
- The actual repo directory tree — walk the top two levels so path references in the new `CLAUDE.md` are accurate.
- `CameraKit/state.md` if it exists — reflects which stages have landed so the new `CLAUDE.md` can name the current implementation checkpoint accurately.

The new `CLAUDE.md` must contain these sections, in this order, all concise:

1. **What this repo is.** Swift iOS 26 implementation target for the CameraKit library defined in `implementation/briefs/`. Consumes `briefs/` + `architecture/` + `domain-revised/` + `ios-platform-guide/` (all symlinked in). Produces: Swift source under `CameraKit/Sources/CameraKit/`, swift-testing unit tests under `CameraKit/Tests/CameraKitTests/`, and per-stage `CameraKit/state.md` updates. Upstream at `/Users/shrek/work/cambrian/ios-translation/` is the prompt-engineering pipeline; this repo is its Stage 6.

2. **Repo layout.** Inline tree showing:
   - `eva-swift-stitch.xcodeproj` — app host; do not replace with a SwiftPM executable.
   - `eva-swift-stitch/` — app target files (`eva_swift_stitchApp.swift`, `Info.plist` carrying `NSCameraUsageDescription`, later `NSPhotoLibraryAddUsageDescription`, asset catalog). The app's entry point imports `CameraKit` and presents `CameraView()`.
   - `eva-swift-stitchTests/`, `eva-swift-stitchUITests/` — existing XCTest bundles; library tests land under `CameraKit/` instead.
   - `CameraKit/` — local Swift package (library-only) created at Stage 01. Contains `Package.swift`, `Sources/CameraKit/`, `Tests/CameraKitTests/`, `state.md`.
   - `implementation/` — symlinks to upstream: `briefs -> …/ios-translation/implementation/briefs`, `architecture -> …`, `domain-revised -> …`, `ios-platform-guide -> …`. Mark these as read-only from this repo's perspective.
   - `fastlane/`, `docs/`, `Gemfile*` — existing project infrastructure; preserve whatever the current `CLAUDE.md` says about these if accurate.
   Mark which pieces exist today vs are created during implementation.

3. **Pipeline role and stage discipline.** One sentence describing the 6-stage upstream pipeline and this repo's place (Stage 6 IMPLEMENT). Then the per-stage workflow the implementer must follow:
   - Read `implementation/briefs/stage-NN.md`.
   - Pre-flight: for every entry under `CameraKit/state.md` "Scaffolding still live", `grep -r <slug> CameraKit/Sources/` must find ≥1 hit; mismatch halts the session.
   - Read cited architecture refs (§5), domain refs (§6), and `implementation/architecture/api-skeletons/Sources/CameraKit/` stubs for files you'll touch.
   - Implement per §4 in dependency order.
   - Run §11 verification (build, test, grep inventory, `xcodebuild`).
   - Update `CameraKit/state.md` per §12.
   - Stop and request user approval before any git operation.
   Include one paragraph explaining the 12-section brief schema at a high level and one sentence each for FEATURE (adds user-visible capability + possibly scaffolds) vs MIGRATION (retires ≥1 scaffold, preserves all prior behavior, no new user-visible capability).

4. **Scaffold-slug convention.** Exact-string code comments of the form `// scaffolding:NN:kebab-slug` wherever the shortcut lives. The comment is the grep target for the next stage's pre-flight check. Do not paraphrase the slug. Do not retire a scaffold in any stage except the one whose `scaffolding_retired:` entry in `stages/stage-index.md` names it.

5. **Target shape decisions locked by Stage 01.** The package is a subdirectory (`CameraKit/`), not at the repo root. The xcodeproj remains the app host (Info.plist ownership, signing, simulator scheme). `CameraKit` is linked as a local SPM dependency. iOS 26 deployment target, Swift 6 language mode + strict concurrency. `CameraKitCxx` + OpenCV xcframework arrive at Stage 08; do not scaffold them earlier.

6. **Common operations.** A code block with the frequently used commands:
   ```
   # Library build + tests
   swift build --package-path CameraKit/
   swift test --package-path CameraKit/ --filter StageNNTests

   # Full sweep (all stages landed so far)
   swift test --package-path CameraKit/

   # Scaffold inventory — each live slug must grep ≥1 hit; each retired slug must grep 0.
   grep -rn 'NN:slug' CameraKit/Sources/

   # App build (xcodeproj as host)
   xcodebuild -project eva-swift-stitch.xcodeproj \
     -scheme eva-swift-stitch \
     -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
     build
   ```
   Mention the `measurements/stage-NN/` evidence directory convention for HITL / DEFERRED test evidence.

7. **Commit discipline.** Mirror the upstream rule verbatim in spirit: Claude Code produces files but does not run git operations without explicit user approval. Never amend, force-push, or skip hooks.

8. **Load-bearing invariants (implementer-side).** State positively, one "why" per rule:
   - The brief is the source of truth for its stage. If `architecture/` or `ios-platform-guide/` appears to contradict the brief, the brief wins and the conflict gets recorded in `CameraKit/state.md` under "Decisions taken that weren't in briefs".
   - Never edit `implementation/briefs/`, `implementation/architecture/`, `implementation/domain-revised/`, or `implementation/ios-platform-guide/`. Those are upstream artifacts; gaps go in `state.md` "Open questions for next stage" and get patched in the upstream repo.
   - Never install a future-stage primitive early (e.g., D-10 completion guard before Stage 09, C++ pool before Stage 08, `OSAllocatedUnfairLock` uniform guard before Stage 05). Each stage is deliberate about what it does *not* do.
   - Never retire a scaffold out of order. The retirement chain is locked by `stage-index.md`.
   - Never leak Android API names (`Camera2`, `HandlerThread`, `ImageReader`, `SurfaceTexture`, `EGLContext`, etc.). The clean-room separation lives upstream but echoing Android names in iOS code is a tell.
   - Cite ADRs / D-## / G-## by ID in code comments when the "why" is non-obvious. Do not paraphrase the platform guide.
   - `AVCaptureSession` mutations and `AVCaptureDevice.lockForConfiguration()` run on `sessionQueue` (ADR-07). The `AVCaptureVideoDataOutput` delegate is `nonisolated` on the `delivery` queue (ADR-02). Actors coordinate with queues; they do not replace them.

9. **Background reading (only when needed).**
   - `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` — producer-side pipeline and discipline.
   - `implementation/briefs/README.md` — implementer read-path, stage-kickoff template, glossary.
   - `implementation/architecture/README.md` — concern-file map.
   - `implementation/ios-platform-guide/README.md` — ADR / G-## registry.
   - Individual stage briefs at `implementation/briefs/stage-NN.md` — the authoritative spec for the stage you are in.

Rules for your writing:
- Terse. No filler, no trailing summaries. No emojis.
- Prose paragraphs for orientation; tables or code blocks only where structure genuinely helps.
- Target length 120–180 lines including blank lines and the inline tree. If you run over, cut.
- Do not inline brief content. Link to the brief and let readers fetch it.
- Preserve from the current `CLAUDE.md` anything project-specific and still true (fastlane instructions, custom scripts). Drop anything that is generic Xcode default.
- Every rule gets a one-sentence "why" or a cited ADR / guide anchor. Mystery rules rot.
- Use the word "you" for the reader (a future Claude Code session). Avoid first person.

Stop condition and final output:
- `CLAUDE.md` at the repo root is replaced with the new content. No other file is modified.
- Your final message lists: which sections of the prior `CLAUDE.md` survived (if any), which are new, the final line count, and any ambiguity you resolved by choice (record the choice). Ask the user to approve before any git operation.
