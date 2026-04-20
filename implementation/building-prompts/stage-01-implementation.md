You are an iOS engineer starting Stage 01 of a multi-stage native-iOS camera library translated from a Flutter + Android source by an upstream clean-room prompt pipeline. You are running in the `eva-swift-stitch/` repo. You have no conversation memory from prior sessions; everything you need lives on disk.

The authoritative specification for this stage is `implementation/briefs/stage-01.md`. It contains twelve numbered sections: Frontmatter / Starting state / Goal / Files to create / modify / delete / Architecture refs / Domain refs / Contracts & invariants / Tests to write / Tests preserved / Acceptance criteria / Verification steps / State.md updates. The brief is the source of truth. If the architecture, platform guide, or any other document appears to contradict the brief, the brief wins — record the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed.

Context you must read before writing any code:
- `implementation/briefs/stage-01.md` — this stage's full spec. Read in one pass, end to end.
- `implementation/briefs/README.md` — implementer read-path, stage-kickoff template, glossary.
- `implementation/briefs/state-template.md` — the shape `CameraKit/state.md` is seeded from.
- For every architecture anchor cited in §5 (`01-system-shape.md#swift-module-layout`, `#ownership-of-top-level-types`, `#dispatch-queues-non-actor-isolation-boundaries`, `#package-swift-operative-shape`; `03-camera-session.md#session-object-lifetime`, `#device-selection`, `#format-selection`, `#orientation`, `#capture-output-configuration`; `08-ui.md#view-topology`, `#uiviewrepresentable-mtkview-wrappers`; `api-surface.md`) — open and read the cited section in `implementation/architecture/`.
- For every domain file cited in §6 (`01-system-purpose.md`, `09-ui-behaviors.md`, `10-api-contract.md`, `12-unresolved.md`) — open and read at `implementation/domain-revised/<file>`. The `domain-revised/` tree is the platform-neutral behavioral spec upstream of the iOS architecture; it contains no Android API names and is safe to read alongside the brief. In this repo `implementation/domain-revised/` is a symlink to the canonical copy.
- For files you will mirror stubs of, read the corresponding file in `implementation/architecture/api-skeletons/Sources/CameraKit/`.

Repo shape you are implementing into (already on disk — do not recreate):
- `eva-swift-stitch.xcodeproj` with an app target in `eva-swift-stitch/`. Keep the xcodeproj as the app host. Do not replace it with a SwiftPM executable target.
- Existing sources in `eva-swift-stitch/`: `eva_swift_stitchApp.swift` (rewire its WindowGroup body to present `CameraView` from the package), `ContentView.swift` (delete — the `CameraView` from the package replaces it), `CameraCapabilitiesReporter.swift` (delete unless a specific piece is demonstrably reusable; if you keep anything, record the reason in `state.md` under "Decisions taken that weren't in briefs").
- Existing `eva-swift-stitch/Info.plist` already carries `NSCameraUsageDescription`. Preserve it. Do not migrate the key into the package.
- Existing XCTest bundles `eva-swift-stitchTests/` and `eva-swift-stitchUITests/` — leave them alone this stage; the new tests live in the package.

Target artifact — a library-only local Swift package at `CameraKit/` (sibling of the xcodeproj):
```
CameraKit/
├── Package.swift
├── Sources/CameraKit/
│   └── <the files listed in brief §4>
└── Tests/CameraKitTests/
    └── Stage01Tests.swift
```
Wire the package into the xcodeproj as a local package dependency (in Xcode: File → Add Package Dependencies → Add Local…, pointing at `CameraKit/`) and link `CameraKit` to the `eva-swift-stitch` app target. Inside the app target, replace the `WindowGroup` body of `eva_swift_stitchApp.swift` with `CameraView()` from `CameraKit`.

`Package.swift` requirements:
- Transplanted from `implementation/architecture/api-skeletons/Package.swift`, adapted to: `swift-tools-version: 6.0`, `platforms: [.iOS(.v26)]`, Swift 6 language mode + strict concurrency enabled on the library target.
- Exactly one library target (`CameraKit`) and exactly one test target (`CameraKitTests`) using `swift-testing` per ADR-33.
- No `CameraKitCxx`, no OpenCV dependency, no executable target, no XCTest integration bundle — those arrive in later stages. Do not scaffold them.

Stage-kickoff workflow (execute in order):
1. Read the brief, cited architecture refs, cited domain refs, and the api-skeleton files you will mirror.
2. Skip the scaffold pre-flight grep — this is Stage 01 and no scaffolds exist on disk yet.
3. Create `CameraKit/Package.swift`, `CameraKit/Sources/CameraKit/`, `CameraKit/Tests/CameraKitTests/`.
4. Implement every file listed in brief §4 in dependency order: value types (`Capabilities`, `SessionState`, `Errors`, `FrameSet` stub, `Constants`) → `CaptureDeviceProviding` → `CameraSession` → `CaptureDelegate` → `TexturePoolManager` → `MetalPipeline` → `CameraEngine` → `PixelSink` stub → `CameraView` + `ViewModel`.
5. For every scaffold in brief §4, attach an exact-string code comment at the site of the shortcut: `// scaffolding:01:naive-scenephase-stop`, `// scaffolding:01:simple-metal-passthrough`, `// scaffolding:01:skip-completion-guard`. Stage 02's pre-flight grep depends on finding these literally — do not paraphrase the slug.
6. Write `Tests/CameraKitTests/Stage01Tests.swift`. Every TESTABLE entry in brief §8 gets a `@Test` function. Use the `CaptureDeviceProviding` fake per ADR-32 — production `AVCaptureDevice` must not appear in test code.
7. Wire the local package dependency in the xcodeproj and rewire `eva_swift_stitchApp.swift` to present `CameraView()`. Delete `ContentView.swift`. Delete `CameraCapabilitiesReporter.swift` unless you record a reason to keep it.
8. Run verification from brief §11:
   - `swift build --package-path CameraKit/`  — passes with no new warnings under Swift 6 + strict concurrency.
   - `swift test --package-path CameraKit/ --filter Stage01Tests`  — every TESTABLE entry green.
   - `grep -rn '01:naive-scenephase-stop\|01:simple-metal-passthrough\|01:skip-completion-guard' CameraKit/Sources/`  — each slug has ≥1 hit.
   - `xcodebuild -project eva-swift-stitch.xcodeproj -scheme eva-swift-stitch -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build`  — the app builds; adjust destination to a simulator installed on the machine if the named one is unavailable.
9. Create `CameraKit/state.md` by copying `implementation/briefs/state-template.md`, then populate it per brief §12: fill "What's built (permanent)", "Public API exposed so far", "Scaffolding still live". Record any HITL test (notably `01:preview-renders-first-frame`) as pending under "Manual test evidence" if no physical device was exercised this session.
10. Stop. Surface a change-set summary and wait for explicit user approval before any git operation.

Scaffolds are intentional — do NOT preemptively fix them:
- `01:naive-scenephase-stop` — on `.background`, the ViewModel emits a plain `sessionQueue.async { self.session.stopRunning() }` with no GPU-submission gate, no `waitUntilScheduled()`, no `UIApplication.beginBackgroundTask`. Retires in Stage 02.
- `01:simple-metal-passthrough` — only Pass 1 (crop + YUV→RGBA into a single IOSurface-backed `naturalTex`) is wired. No Pass 2 (color), Pass 3 (blit), Pass 4 (tracker), Pass 5 (encoder), or Pass 6 (still readback). No `CVPixelBufferPool` trio. Retires in Stage 08.
- `01:skip-completion-guard` — `addCompletedHandler` does not check `sessionState` before touching readback state. Retires in Stage 09 with the full D-10 guard.

Load-bearing invariants you must NOT violate:
- `AVCaptureSession` mutations and `AVCaptureDevice.lockForConfiguration()` run on `sessionQueue` (ADR-07). The engine actor reaches the queue via an ADR-30 async-with-timeout helper, never by calling AVFoundation APIs directly from the actor.
- The `AVCaptureVideoDataOutput` sample-buffer delegate is `nonisolated` on the `delivery` queue (ADR-02, ADR-07). Metal encode, `commit()`, and every completion handler stay on `delivery`. The frame clock never hops a Swift actor boundary.
- Device is `.builtInWideAngleCamera` back-facing only (D-08). No telephoto, no ultra-wide, no front camera. Resolution is the largest 4:3 format at 30fps per G-17; if no 4:3 format exists, fall back to `constants.md#CAPTURE_FALLBACK_WIDTH_PX × CAPTURE_FALLBACK_HEIGHT_PX`.
- Capture format is 8-bit biplanar YUV, lossless preferred (`constants.md#CAPTURE_PIXEL_FORMAT`). Working format is `rgba16Float` (`constants.md#WORKING_PIXEL_FORMAT`). Never call `MTLTexture.getBytes` — CPU access is through IOSurface-backed `CVPixelBuffer` only (ADR-06).
- Orientation is landscape-right via `AVCaptureConnection.videoRotationAngle = 90` (ADR-17). The app is landscape-right-only at the Info.plist level.
- `stateStream()` uses `.bufferingOldest(constants.md#STATE_STREAM_BUFFER_SIZE)` (ADR-22).
- `CaptureDeviceProviding` is the sole seam through which tests obtain a device (ADR-32). Production code never constructs `AVCaptureDevice` directly.
- `open()` while already open throws `EngineError.alreadyOpen`. Callers must `close()` first.
- In code comments, cite ADRs / D-## decisions / G-## gotchas by ID when the "why" is non-obvious. Do not paraphrase the platform guide.

Rules you must NOT violate:
- Do not edit `implementation/briefs/`, `implementation/architecture/`, or `implementation/ios-platform-guide/`. These are upstream artifacts produced by earlier agents. If you find a gap, flag it in `state.md` under "Open questions for next stage" and implement the closest faithful interpretation. Do not hand-patch upstream.
- Do not run `git commit`, `git push`, `git reset --hard`, `git checkout .`, or any destructive git operation without explicit user approval. Produce the change set and stop.
- Do not add files, features, or abstractions beyond brief §4. No speculative `Core/`, `Plugins/`, `Infra/` modularization (see ADR-01 §three-layer sandwich). No helpers "for future use".
- Do not introduce Pass 2 / the `OSAllocatedUnfairLock` uniform lock / the D-10 completion guard / the pool trio / `FrameSet` publication / the C++ pool in this stage. Each has a documented later stage.
- Do not skip the HITL entries in brief §8. If no physical device is available in this session, record `01:preview-renders-first-frame` as pending under `state.md` "Manual test evidence" — do not claim it passed.
- Do not leak Android API names (`Camera2`, `HandlerThread`, `ImageReader`, `SurfaceTexture`, `EGLContext`, etc.) into code, comments, test names, or docstrings. This is native iOS; the clean-room separation lives upstream, but echoing Android names is a tell.
- Do not skip the scaffold-slug comment convention. Stage 02's pre-flight grep depends on it. The three slugs must each appear as `// scaffolding:01:<slug>` in source.

Stop condition and final output:
- Every checkbox in brief §10 either passes in verification or is recorded as deferred (with a reason) in `CameraKit/state.md`.
- `CameraKit/state.md` exists and reflects brief §12 verbatim for "Scaffolding still live", "What's built (permanent)", and "Public API exposed so far".
- No git operation has been run.
- Your final message summarizes: files created / modified / deleted, `swift build` output (warning count), `swift test` output (pass/fail count per test name), grep-inventory output, `xcodebuild` build status, any deferred HITL items, and the `state.md` initial content. End by asking the user to approve the commit.
