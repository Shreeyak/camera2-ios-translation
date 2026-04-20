# Findings — actionable issues for Agent 3 rerun

Verdict: **Green**, iteration 3. All findings resolved. Agent 5 may run.

---

*(Iteration 2 findings recorded below for history.)*

---

## F-01 (RESOLVED) — Concurrency contract table rows 3, 4, 11

Resolved by commit bb6c684. Agent 3 corrected the invariants-column semantics for rows 3,
4, and 11. Row 4 now matches the J3 PASS example verbatim. J3 passes this iteration.

---

## F-02 (RESOLVED) — Concurrency contract table rows 9, 10: missing ADR/D-## citations

**J-bar:** J2 MARGINAL  
**Blocker for Green:** Yes (J2 must reach PASS)  
**Location:** `architecture/02-concurrency.md` §Concurrency contract table

**Problem:** The table's own invariant states "Every row cites an ADR or introduces a
D-##. No blank cells." Rows 9 and 10 violate this:

- **Row 9** — `C++ lock ordering pipeline > stage > consumer (domain Invariant 5)`: cites
  only the domain invariant. The choice of this specific three-level lock hierarchy for the
  C++ imaging core is an architectural decision — there is no ADR for it, and no D-## has
  been created.

- **Row 10** — `OSAllocatedUnfairLock<UniformBuffer> on the host-written uniform buffer`:
  cites only "Inv 6". The choice of `OSAllocatedUnfairLock` over actor isolation, a serial
  DispatchQueue, `NSLock`, or `pthread_mutex` for this specific uniform-buffer guard is an
  architectural decision — there is no ADR for it and no D-## has been created.

**Fix options:**

For **Row 9**: either (a) add a new `D-##` entry (e.g. D-16) in `decisions.md` for the
C++ lock-hierarchy decision and cite it in the row, or (b) identify an existing ADR in
`ios-platform-guide/` that specifies this ordering and cite it. The row body already names
the invariant precisely; only the citation is missing.

For **Row 10**: same pattern — add a new `D-##` (e.g. D-17) for the `OSAllocatedUnfairLock`
choice with a one-paragraph rationale (real-time-safe, priority-inversion free on the hot
uniform-write path; actor isolation would require a `Task` hop on every slider move, which
is too expensive). Cite ADR-09 if the platform guide references `OSAllocatedUnfairLock`
for hot-path mutex use.

**Scope:** `architecture/02-concurrency.md` rows 9 and 10; optionally `decisions.md` for
new D-## entries. No stage-index edits required.

---

## F-03 (RESOLVED) — ui×state interaction: emergent constraint is a domain restatement

**J-bar:** J4 MARGINAL  
**Blocker for Green:** Yes (J4 must reach PASS)  
**Location:** `architecture/README.md` §Interactions considered, `ui×state` bullet

**Problem:** The entry names `frameResultStream` × `focusDistance == nil` semantics (domain
09 §FrameResult Display). ≥2 inputs are cited. However, the emergent constraint — "UI code
must handle both without showing stale values" — is already implied by domain 09 alone;
domain 09 specifies nil means scanning and that the UI shall show a scanning animation.
No new obligation arises from the simultaneous presence of both inputs.

**Fix:** Replace the emergent constraint with a genuine cross-input consequence. One
specific option (preferred — it passes J4 strictly):

> **ui×state**: `frameResultStream.bufferingNewest(1)` (ADR-22 drop semantics) ×
> `focusDistance == nil` (domain 09 §FrameResult Display). When the UI consumer misses a
> frame due to mailbox overwrite, it retains the prior `liveFrameResult`. If the prior
> result had a numeric `focusDistance` and autofocus began scanning during the skipped
> frame, the binding will show a stale numeric value rather than nil — the scanning
> animation never appears for that transition. This failure mode requires both the
> drop-semantics contract (ADR-22) AND the nil-semantics contract (domain 09)
> simultaneously; either alone does not surface the bug. The fix: bind the scanning
> indicator to the engine's `SessionState` or a dedicated `isAdjustingFocus` field rather
> than to `focusDistance` nilness. Shape: `ui×state`.

**Scope:** `architecture/README.md` §Interactions considered, `ui×state` bullet only.
No other file edits required. Do not touch other interaction bullets.

---

## F-04 (RESOLVED) — Informational: minor cross-reference and accuracy gaps (non-blocking)

These items do not contribute to the Yellow verdict but should be addressed before the
final Green rerun to avoid surfacing again.

**F-04a** — `05-consumers.md` §Quality gate `(G-26 avoidance)` line 278:
"Every PixelSink registration must supply an `onOverwrite` callback" — cites G-26 but not
D-11. Add `per D-11` so the section explicitly cross-references its owning decision.

**F-04b** — `architecture/README.md` §Phase coverage table, row `08-capture-and-recording.md`:
lists implementing stages `06, 07`. Stage 06 in `stage-index.md` touches
`[04-metal-pipeline, 05-consumers]` — it does NOT touch `06-capture-and-recording`. Stage
10 (video recording) and stage 12 (background recording drain) both touch
`06-capture-and-recording` and are absent from this row. Correct to `07, 10, 12`.

---

## Recommended rerun scope

Phase A only. Fix F-02 and F-03 (the two J-bar blockers). Apply F-04a and F-04b as
cleanup. Agent 3 should not touch `stage-index.md` or any concern file not named above.

If iteration 3 still returns Yellow on J2 or J4 (same J-bars), the iteration bound is
reached and the human override / spec-change procedure in the Agent 4 prompt applies.
