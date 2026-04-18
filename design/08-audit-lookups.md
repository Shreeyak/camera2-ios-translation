# 08 — Audit Lookups

This file logs every read of `audit/` performed during iOS design. The escape hatch is
only used for specific numeric values, "NEEDS INVESTIGATION" markers, or genuine
ambiguities in `domain-revised/` that block a concrete iOS decision.

## Policy

- `domain-revised/` is the primary input. Every behavior requirement is sourced there.
- `ios-platform-guide/` provides the iOS-native "how" (ADRs, gotchas).
- `audit/` is consulted only when a decision cannot be made from the above two.

## Lookup Log

| # | Section accessed | Reason for lookup | What I learned | Did it change the design? |
|---|------------------|-------------------|----------------|---------------------------|

**No audit lookups required — `domain-revised/` (with numeric values inlined in
02-frame-delivery.md, 05-resource-lifecycle.md, 06-error-and-recovery.md, and
08-capture-and-recording.md) together with `ios-platform-guide/` were sufficient to
design every iOS component.** Specific numeric thresholds (3s GPU stall, 5s capture-result
stall, 5 consecutive hardware errors, 500/1000/2000/4000/8000 ms backoff, 5s drain
timeout, 3-failure surface rebind threshold, 96×96 center patch, 480px tracker height,
~1600×1200 default crop, 4:3 resolution selection rule, `TARGET_BITRATE_MBPS` platform
measurement) are all stated inline in `domain-revised/`.

The single `TARGET_BITRATE_MBPS` value (domain-revised/08 §Recording Parameters flags it
as `measurements/`) is intentionally deferred to Phase 5 tuning per D-09 below; it is
surfaced as a configurable `bitrate` parameter on `startRecording` per the domain API
contract, not hardcoded in the design.

If a future design revision needs a specific Android numeric value not captured in
`domain-revised/`, append a row here before reading `audit/`.
