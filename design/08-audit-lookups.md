# 08 — Audit Lookups Log

This file records every consultation of `audit/` during the design phase.
Entries are logged as they occur — not batched at the end.

Per escape-hatch rules, `audit/` may only be consulted when:
1. `domain/` uses the phrase "NEEDS INVESTIGATION" or "SEE AUDIT §X" for a specific item
2. A specific numerical value needs verification
3. A domain requirement is genuinely ambiguous and the ambiguity blocks a concrete design decision

---

No audit lookups required — `domain/` was sufficient.

All behavioral requirements, numerical thresholds, API contracts, and concurrency invariants
were fully specified in the 12 domain files. The design was produced from first principles
using iOS/Metal/Swift native idioms without consulting the Android audit.

Specific values confirmed from `domain/` without audit consultation:

| Value | Source file | Section |
|---|---|---|
| 30 fps target frame rate | domain/07-performance-budgets.md | §Frame Rate |
| 8ms GPU fence timeout | domain/07-performance-budgets.md | §GPU Pipeline Timing |
| 3000ms GPU stall threshold | domain/07-performance-budgets.md | §Stall Detection Timeouts |
| 5000ms capture-result stall threshold | domain/07-performance-budgets.md | §Stall Detection Timeouts |
| 480px tracker height (fixed) | domain/12-unresolved.md | §U-15 (RESOLVED) |
| 5 retry max before fatal | domain/06-error-and-recovery.md | §Exponential Backoff |
| 5s drain timeout | domain/07-performance-budgets.md | §Video Recording: Drain Timeout |
| 3 consecutive swap failures threshold | domain/07-performance-budgets.md | §Preview Surface Failure Threshold |
| 5s resize timeout | domain/07-performance-budgets.md | §Resolution Change Timeout |
| 96×96 center patch size | domain/07-performance-budgets.md | §Center-Patch Sampling |
| 5s AE convergence timeout | domain/07-performance-budgets.md | §AE Convergence Budget |
| 15fps FPS degradation threshold | domain/07-performance-budgets.md | §Frame Rate |
| 5 consecutive HAL errors before recovery | domain/07-performance-budgets.md | §HAL Error Threshold |
| Single session; back-facing main lens only | domain/12-unresolved.md | §U-17 (RESOLVED) |
| Natural stream: display-only, no C++ consumers | domain/12-unresolved.md | §U-13 (RESOLVED) |
| 4:3 native sensor aspect ratio (~4000×3000) | domain/12-unresolved.md | §U-08 (RESOLVED) |
