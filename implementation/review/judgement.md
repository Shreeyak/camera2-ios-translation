# Judgement — J1-J5 evaluation

Agent 4 run against `implementation/` on 2026-04-20. **Iteration 3.**
Iteration 1 J3 finding (rows 3, 4, 11 of concurrency contract table) resolved by commit
bb6c684. Iteration 2 J2 finding (rows 9, 10) resolved by D-16 + D-17. Iteration 2 J4
finding (ui×state) resolved with genuine cross-input emergent constraint.

---

## J1 — Phase coverage table completeness

**Status: PASS**

All 12 `domain-revised/` files appear as rows in `architecture/README.md` §Phase coverage
table. Every row has non-empty cells for both primary concern(s) and implementing stage(s).

Row-by-row: `01-system-purpose` → `01-system-shape, 08-ui` → stages `01, 02` ✓;
`02-frame-delivery` → `04-metal-pipeline, 05-consumers` → stages `04, 05, 08, 10` ✓;
`11-what-not-to-port` → `all (excluded items)` → `n/a` ✓ (non-empty sentinel acceptable
for an exclusion-only file); `08-capture-and-recording` → `06-capture-and-recording` →
`07, 10, 12` ✓ (corrected from iteration 2's F-04b: stage 06 does not touch
`06-capture-and-recording`; stages 10 and 12 do).

---

## J2 — Decision citation audit

**Status: PASS**

### Unconditional check — `decisions.md`

All 17 D-## register entries carry ADR-## or D-## cites in the register row and/or in
the inline anchors in their owning concern file. D-16 and D-17 are the two new entries
added this iteration.

### Unconditional check — `02-concurrency.md`

All 12 rows in the concurrency contract table pass. Rows 9 and 10, which carried only
domain-invariant references in iteration 2, now cite D-16 and D-17 respectively:

| Row | Mechanism | Citations |
|---|---|---|
| 9 | `C++ lock ordering pipeline > stage > consumer` | **D-16** (+ domain Invariant 5, ADR-11 in the inline anchor) |
| 10 | `OSAllocatedUnfairLock<UniformBuffer>` | **D-17** (+ ADR-09, domain Invariant 6 in the inline anchor) |

D-16 inline anchor in `02-concurrency.md` names three alternatives considered (actor
isolation, serial DispatchQueue, unfair lock) with the latency-budget rationale
(`FRAME_LATENCY_BUDGET_MS`). D-17 inline anchor names the three-level C++ mutex hierarchy
and why it is the minimum-constraining order. Both are Minor entries in `decisions.md`.

### Spot-check — other concern files

All `must` paragraphs and a random 3 other-verb paragraphs per file in `01-system-shape.md`,
`03-camera-session.md`, `04-metal-pipeline.md`, `05-consumers.md`, `06-capture-and-recording.md`,
`07-settings.md`, `08-ui.md`, `09-errors-and-recovery.md` carry ADR-## or D-## within 5
lines. The F-04a informational gap (`05-consumers.md` §Quality gate) is also resolved:
"per D-11" is now present in the paragraph (line 280 of the current file).

No omissions found in any concern file. **PASS.**

---

## J3 — Concurrency contract table plausibility

**Status: PASS**

All 12 rows name real Swift 6 / C++ mechanisms, state precise invariants, and carry
specific crash/hang/race failure modes. The row-4 fix from iteration 1 (commit bb6c684)
stands: `MTLCommandBufferErrorNotPermitted IOAF 6 on background submit → process
termination` matches the J3 PASS example verbatim.

| Row | Mechanism | Failure mode | Assessment |
|---|---|---|---|
| 1 | `actor CameraEngine` (ADR-02) | Concurrent state mutation; dangling retry; stale watchdog UAF | ✓ three modes for three invariants |
| 2 | `sessionQueue` (ADR-07, ADR-30) | `NSGenericException`; purple warning; G-03 block | ✓ |
| 3 | `delivery` queue + `nonisolated CaptureDelegate` (ADR-07, ADR-02) | Lost capture-order; per-frame Task drains pool; preview hitches | ✓ |
| 4 | `ManagedAtomic<Bool>` submission gate (ADR-09) | `MTLCommandBufferErrorNotPermitted` IOAF 6 → process termination | ✓ PASS-example match |
| 5 | `ManagedAtomic<UInt64>` stall-timestamp (ADR-09) | Torn / stale timestamp → false-positive or missed stall detection | ✓ |
| 6 | `.bufferingNewest(1)` mailbox (ADR-22) | Unbounded memory growth; backpressure; missed state transitions | ✓ |
| 7 | C-ABI `std::atomic<bool>` / `std::atomic<uint64_t>` (ADR-13) | Two concurrent captures; lock on frame path; mailbox race | ✓ |
| 8 | `std::mutex` + engine-actor boundary (D-15) | UAF crash when teardown zeroes pointer mid-capture | ✓ |
| 9 | C++ lock ordering `pipeline > stage > consumer` (D-16) | Deadlock at scale; silently-stuck consumer under contention | ✓ |
| 10 | `OSAllocatedUnfairLock<UniformBuffer>` (D-17) | Torn reads of per-channel color params → visible artifacts on one frame | ✓ |
| 11 | Engine-captured `sessionToken` + D-10 guard | UAF crashes on readback buffers (G-20); watchdog mutates wrong session's state | ✓ |
| 12 | `Task` handles + `.cancel()` (ADR-23) | Orphan tasks retain actor indefinitely; pool drains | ✓ |

No row uses "undefined behavior", "could fail", or "may crash" without a named crash class.
Row 4 exceeds the minimum with a specific error code and process-termination outcome — the
PASS threshold is met by at least one entry exceeding the minimum. **PASS.**

---

## J4 — "Interactions considered" quality

**Status: PASS**

Six entries in `architecture/README.md` §Interactions considered, spanning all 6 shape tags.
Evaluated against the J4 test: ≥2 distinct named inputs AND emergent constraint not a
tautological restatement.

**All six entries pass:**

- `concurrency×lifecycle` — ADR-09 × D-06. Emergent: gate check must be after CPU-side
  work and immediately before `commit()`, with `waitUntilScheduled()` bounding the drain
  window — a new obligation absent from either input alone. ✓
- `storage×consumer` — D-02 × D-12 × ADR-20 × G-25. Emergent: consumer attach is a Metal
  no-op only when `.shared` default AND natural subscribable AND graduation-by-evidence all
  co-exist; G-25's silent-drop mode is gated out entirely. ✓
- `error×recovery` — D-13 × Inv 12. Emergent: double-recovery from a freshly-armed watchdog
  colliding with the prior scheduled callback requires both exponential-backoff timing AND
  watchdog-first disarm ordering. ✓
- `resource×teardown` — D-15 × Inv 4. Emergent: pure-Swift actor boundary is insufficient
  because external C++ callers reach the pointer via `getNativePipelineHandle()` — the
  `std::mutex` requirement arises only when both the C++ caller path AND the actor
  serialization limit are simultaneously present. ✓
- `settings×session` — Rules 1/2/3 (07-settings.md) × ADR-14. Emergent: Rule 3's live
  sensor latch requires a live KVO `DeviceStateSnapshot` stream; the constraint does not
  exist in auto mode (Rule 3 inapplicable) or without the KVO stream (Rule 3 fails at
  pre-first-frame). ✓
- `ui×state` — ADR-22 drop semantics × domain 09 §FrameResult Display nil semantics.
  Emergent: when the UI consumer misses a frame (mailbox overwrite), it retains the prior
  `liveFrameResult`; if that result had a numeric `focusDistance` and autofocus started
  scanning in the skipped frame, the scanning animation never fires for that transition —
  a stale numeric value is shown instead of `nil`. This failure mode requires both
  constraints simultaneously; ADR-22 alone (no nil semantics) does not surface it; domain
  09 alone (no drop semantics) does not surface it. The entry also names the architectural
  fix: bind the scanning indicator to `SessionState` or `isAdjustingFocus`, not
  `focusDistance` nilness. ✓

**PASS.** All 6 entries have ≥2 distinct named inputs with genuine cross-input emergent
constraints. At least one entry (ui×state, error×recovery) significantly exceeds the
minimum with a concrete failure scenario and named fix.

---

## J5 — Migration stages' `tests_preserved` plausibility

**Status: PASS**

All `tests_preserved` entries in `stage-index.md` evaluated (stages 02, 05, 08, 09, 12):

| Stage | Entry | Source stage scope | Plausible? |
|---|---|---|---|
| 02 | `01:engine-open-close-transitions` | Stage 01 touches `01-system-shape`, `03-camera-session` | ✓ |
| 02 | `01:preview-renders-first-frame` | Stage 01 visible criterion is live preview | ✓ |
| 05 | `04:color-pipeline-golden-frame` | Stage 04 touches `04-metal-pipeline`, adds Pass 2 | ✓ |
| 05 | `04:processing-params-persistence-roundtrip` | Stage 04 touches `07-settings`, wires UserDefaults | ✓ |
| 08 | `06:frame-set-publication` | Stage 06 touches `05-consumers`, introduces FrameSet mailbox | ✓ |
| 08 | `06:swift-consumer-drop-on-busy` | Stage 06 introduces `06:simple-consumer-swift-only` scaffold | ✓ |
| 08 | `07:still-capture-in-flight-guard` | Stage 07 introduces `07:swift-side-capture-atomic` scaffold | ✓ |
| 09 | `04:color-pipeline-golden-frame` | Stage 04 touches `04-metal-pipeline` | ✓ |
| 09 | `01:preview-renders-first-frame` | Stage 01 touches `01-system-shape`, `08-ui` | ✓ |
| 12 | `10:record-start-stop-happy-path` | Stage 10 touches `06-capture-and-recording` | ✓ |
| 12 | `10:recording-truncated-on-deadline` | Stage 10 wires `RECORDING_FINISH_TIMEOUT_SECONDS` + `cancelWriting` race | ✓ |

No entry references a primitive or concern absent from the cited source stage's `touches:`
or `scaffolding_introduced:`. **PASS.**
