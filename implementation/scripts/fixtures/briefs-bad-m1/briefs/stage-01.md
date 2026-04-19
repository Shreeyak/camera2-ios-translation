# Stage 01 — Bare preview

## 1. Frontmatter
Type: FEATURE
Depends on: (none)

## 2. Starting state
Empty repo.

## 3. Goal
Render the camera feed on screen with an empty bottom bar.

## 4. Files to create / modify / delete
- create: Sources/CameraApp/CameraView.swift (permanent)

## 5. Architecture refs
- architecture/01-system-shape.md
- architecture/08-ui.md

## 6. Domain refs
- domain-revised/09-ui-behaviors.md

- Preview fills screen (ADR-01)

## 8. Tests to write
- TESTABLE: CameraView renders MTKView on mount
- HITL: preview visible on device — device: iPad Pro M1

## 9. Tests preserved (must still pass)
(FEATURE stage — empty)

## 10. Acceptance criteria
- [ ] swift build passes
- [ ] TESTABLE test passes
- [ ] HITL check recorded in state.md

## 11. Verification steps
- swift build
- swift test --filter CameraViewTests
- Run on iPad Pro M1; capture screenshot to evidence/

## 12. State.md updates (Claude Code writes these)
- Adds: CameraView with MTKView root
- Evidence: evidence/stage-01-preview.png
