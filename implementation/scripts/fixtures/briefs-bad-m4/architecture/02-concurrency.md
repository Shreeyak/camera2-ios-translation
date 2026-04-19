# 02 — Concurrency — Fixture

Cites ADR-02.

## Concurrency contract table

| Mechanism | Invariants enforced | Failure mode if violated |
|---|---|---|
| CameraEngine actor (serial) | I-1 (state mutations) | Concurrent open() races |

Cites ADR-07.

## Cross-subsystem sequencing

**scenePhase → .background**
1. Gate GPU submission (see `02-concurrency.md#concurrency-contract-table`).
2. `sessionQueue.async { session.stopRunning() }` (see `03-camera-session.md`).
3. If recording active: drain via `06-capture-and-recording.md`.
