# iOS Platform Guide

Platform-level architectural decisions and gotchas for iOS apps with the shape:
real-time camera → Metal → optional C++ consumers → SwiftUI.

These files are **inputs** to design. They do not describe any specific product. A design
agent reads these, then makes product-specific decisions (numbered `D-##` in its own
output) that cite the ADRs they follow.

## Scope

Covers: AVFoundation capture, Metal rendering, zero-copy bridges, Swift-C++ interop,
Swift 6 concurrency, scenePhase/lifecycle, interruption handling.

Does NOT cover: product-specific architecture (module names, file layout beyond the
minimal baseline, specific shader pipelines). Those are design-output concerns.

## Files

| File | Contains |
|---|---|
| `01-architecture.md` | Two-file baseline; direct GPU outputs vs async consumers; per-frame command graph |
| `02-concurrency.md` | Isolation topology, Sendable rules, Metal background submission, scenePhase semantics |
| `03-metal.md` | Zero-copy via `CVMetalTextureCache`, working pixel format, GPU→encoder path, command-buffer error handling |
| `04-avfoundation.md` | `AVCaptureSession` serial queue, KVO → `AsyncStream`, interruption reasons, orientation |
| `05-interop.md` | Swift ↔ C++ direct interop, exception discipline, `SWIFT_SHARED_REFERENCE` |
| `06-gotchas.md` | Quick-reference failure modes and API pitfalls |

## ADR Index

Every architectural decision in this guide has a stable `ADR-##` identifier. Design outputs
cite these by ID (e.g. "per `ADR-06`" in `design/03-metal-pipeline.md`).

| ID | Decision | File |
|---|---|---|
| ADR-01 | Two-file baseline: `CameraView.swift` + `CameraEngine.swift` | 01 |
| ADR-02 | Single heavy isolation domain: one `actor` for all stateful work | 01, 02 |
| ADR-03 | Distinguish direct GPU outputs from async consumers | 01 |
| ADR-04 | One `CVMetalTextureCache`, created once, flushed on memory warning | 03 |
| ADR-05 | Working format `rgba16Float` for multi-stage color pipelines | 03 |
| ADR-06 | GPU→encoder via IOSurface-backed `CVPixelBufferPool` + `MTLBlitCommandEncoder` | 03 |
| ADR-07 | Dedicated serial queue for `AVCaptureSession`, not `@MainActor` or the engine actor | 02, 04 |
| ADR-08 | scenePhase: `.background` stops session; `.inactive` gates GPU submission | 02 |
| ADR-09 | Metal background rule: atomic submission gate + `waitUntilScheduled()` | 02 |
| ADR-10 | Sendable strategy: non-Sendable types never cross actors; `sending` where transferred | 02 |
| ADR-11 | Swift ↔ C++ direct interop with `.interoperabilityMode(.Cxx)`; no Objective-C++ | 05 |
| ADR-12 | C++ exceptions caught at the facade; public methods `noexcept` | 05 |
| ADR-13 | Async consumers only: 1-slot mailbox, drop-on-busy; preview is inviolable | 01, 05 |
| ADR-14 | Device state delivered to UI via KVO → `AsyncStream` adapter | 04 |
| ADR-15 | `CVMetalTextureGetTexture` can return nil on success — always nil-check | 03, 06 |
| ADR-16 | `AVAssetWriter` + `InputPixelBufferAdaptor` for Metal recording (not `MovieFileOutput`) | 03 |
| ADR-17 | Orientation via `AVCaptureConnection.videoRotationAngle` (not shader UV transform) | 04 |

## Gotchas Index (G-##)

Quick-reference index for `06-gotchas.md`. Each entry is a platform fact that will
crash or silently degrade the app if missed.

See `06-gotchas.md` for descriptions. Referenced by ID elsewhere in the guide and in
design outputs.
