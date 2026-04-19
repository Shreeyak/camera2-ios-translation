# Review — Summary

**Review date:** 2026-04-18
**Reviewer:** Agent 4 (REVIEW) — independent, adversarial
**Inputs:** `domain-revised/` (12 files), `ios-platform-guide/` (ADR-01…ADR-20, G-01…G-26), `design/` (9 files)
**Not read:** `audit/`, Android source, `reference/`, screenshots
**Merged from:** two independent Agent-4 runs (Sonnet + Opus)

---

## OVERALL VERDICT: **Yellow**

(Worst of the two pass verdicts — Pass 1 Yellow, Pass 2 Yellow.)

---

## Summary

The architecture is structurally sound: the two-isolation-domain model
(`@MainActor` + `actor CameraEngine`) correctly enforces the concurrency invariants
in `domain-revised/04` without per-frame actor hops; ADR-18 FrameSet + ADR-19 pool
sizing + ADR-20 `.private`/`.shared` flip discipline all land in the design text as
intended; `design/08-audit-lookups.md` records zero Android-audit escape-hatch reads
— a clean signal that the design is shaped from iOS primitives rather than
translated Android structure; every ADR cited is actually honored in the
implementation narrative, with no Android API names leaking into `design/`.

What prevents a Green verdict is a small set of concrete pseudocode-level and
contract-level defects that will produce silent corruption or block builds if
unfixed. Two are Critical. The first is a publication-timing inconsistency —
`design/02` §2/§3 sequences the FrameSet mailbox swap inline on `deliveryQueue`
*after* `commit()` but *before* the GPU completion handler, which contradicts
`design/01` §4 and the platform guide; a consumer reading the IOSurface on the
same tick reads uninitialized pixels with no error path. The second is an
exception-safety bug in the OpenCV consumer — `design/04` §5 manually locks the
tracker IOSurface and does not unlock in any `catch` branch, so any `cv::Exception`
pins the surface forever and silently black-holes the tracker lane. Six Highs
round out the priority list: the C-ABI write-complete callback won't compile under
Swift 6 strict concurrency (accesses actor-isolated state from `Task.detached`),
the `Unmanaged<CameraEngine>` box leaks (never balanced with `release`), the
`processFrame(StreamId, FrameRef)` interface fragments the ADR-18 atomic unit so
Canny output misaligns with the processed base it composites onto,
`AVCaptureSession.startRunning()` has no timeout and can hang the state machine,
Low Power Mode is not observed anywhere, and a mid-session camera interruption
during active recording leaves `AVAssetWriter` open with no `moov` atom
(`design/07` R-06 only covers backgrounding). A silent ADR-03 deviation
(`processedMTKView` is added to the split-screen preview without a `D-##` entry in
the decisions log) pushes Pass 1 from Green to Yellow. All findings route to
`design/` edits; none requires changes to `domain-revised/` or
`ios-platform-guide/`. The overall quality signal is a good design that needs a
short `design/` re-pass before implementation.

---

## Top 3 Findings

1. **[Critical | Pass 2 Cat 1] FrameSet published before GPU completion.**
   `design/02` §2/§3 places the mailbox swap inline on `deliveryQueue` after `commit()` but before `addCompletedHandler` fires. `design/01` §4 and `ios-platform-guide/01` both require it inside the completion handler. `commit()` only **schedules** GPU work; consumers reading the IOSurface before the GPU has finished writing observe uninitialized or stale pixel data. Every consumer frame is silently corrupt; no assertion fires.
   **Revise:** `design/02` §2 delivery-queue sequence and §3 Sendable/frame-clock corollary — move the FrameSet construction + mailbox swap into the `addCompletedHandler` block.

2. **[Critical | Pass 2 Cat 6] IOSurface permanently locked after any OpenCV exception.**
   `design/04` §5 locks the tracker `IOSurfaceRef` mid-body and calls `IOSurfaceUnlock` mid-body. The three `catch` branches each `return ErrorCode::...` without unlocking. `processFrame` is `noexcept`, so there is no crash — the surface simply stays pinned indefinitely. The GPU cannot write to that slot; the tracker lane produces zero frames with no error, no log, no recovery.
   **Revise:** `design/04` §5 — introduce a C++ `IOSurfaceLockGuard` RAII wrapper and replace the manual lock/unlock pair. Matches ADR-12's exception-discipline requirement.

3. **[High | Pass 1 Cat E / Pass 2 Cat 1] Silent ADR-03 deviation + Swift-6 callback compile error.**
   `design/01` §4 Pass 3b and `design/05` Phase 2 add a `processedMTKView` display blit. `ios-platform-guide/01` ADR-03 explicitly states "processedTex has no display MTKView". The deviation is required (domain §09 split-screen) but is not logged as a `D-##` entry in `design/06-decisions-log.md`. Separately, the C-ABI write-complete callback in `design/04` §6 accesses `engine.mipmapBlitQueue`, `engine.metalEngine`, and `engine.sharedCannyTexture` from inside a `Task.detached` without `await` hops and invokes a non-existent `DispatchQueue.submit` method — Phase 3 cannot build as written under Swift 6 strict concurrency.
   **Revise:** `design/06` decisions log — add `D-10` documenting the ADR-03 deviation (rationale = domain §09, reversibility stated). `design/04` §6 — rewrite the callback as a single `Task { await engine.handleCannyComplete(frameNumber:) }` hop; move Metal + MTKView trigger inside that actor method.

---

## Recommended Next Step

**Re-run Agent 3 once, with the merged review as combined context, before implementation begins.** The two Criticals produce silent data corruption with no diagnostic signal and must be fixed in `design/02` + `design/04` before Phase 2 begins. The six Highs (Swift-6 callback, `Unmanaged` leak, `processFrame` atomicity, interruption-during-recording, `startRunning` timeout, Low Power Mode) each block or undermine a specific phase milestone and should be fixed in the same pass. The thirteen Mediums and ten Lows cluster into thermal/timing behavior, buffer-pool accounting, recording + interruption contracts, and OpenCV consumer correctness; they are polish and can be resolved in phase order. No redesign is required — all fixes are targeted edits to existing sections.

If an immediate-implementation decision is required instead: the two Criticals are the only findings that cannot be caught by any acceptance test in Phase 2/Phase 3, so at minimum **AT-01 (FrameSet ordering) and AT-02 (IOSurface RAII)** must be fixed before Phase 2 begins. Everything else can be caught during phase acceptance, with rework cost proportional to phase depth at discovery.

---

## Detailed Reports

See `01-correctness-check.md` for the full requirements coverage check (Categories
A–E, 32 items, summary table, correctness-pass verdict — Yellow due to one E-03
Fail + eleven Partials) and `02-adversarial-red-team.md` for ranked failure modes
(Categories 1–6, 2 Critical + 6 High + 13 Medium + 10 Low, severity table,
adversarial-pass verdict — Yellow).
