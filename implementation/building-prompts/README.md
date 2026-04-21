# Building prompts — session-boot prompts for the downstream Swift repo

Prompts a fresh Claude Code session pastes as its first message when running in the implementation repo (currently `/Users/shrek/work/cambrian/eva-swift-stitch`). Each prompt is self-contained: role, context, read-path, workflow, invariants, stop condition. None of these prompts are consumed by agents in this repo; they are products produced here for the consumer repo to use.

## Files

- `stage-01-implementation.md` — boot a session to implement Stage 01 (walking skeleton: bare natural preview). FEATURE stage. No pre-flight scaffold check (first stage). Creates `CameraKit/` local SPM package, wires it to the existing xcodeproj, introduces three `01:*` scaffolds.
- `stage-02-implementation.md` — boot a session to implement Stage 02 (scenePhase / GPU submission gate). MIGRATION stage. Pre-flight grep of the three `01:*` scaffolds against `CameraKit/state.md` is mandatory. Retires `01:naive-scenephase-stop`; installs the ADR-09 gate + ADR-30 async-with-timeout + strict D-06 `.inactive` policy.
- `update-claude-md.md` — boot a session in the consumer repo to replace its `CLAUDE.md` with a consumer-side operator orientation doc. Writes once; subsequent updates use this prompt as a reference for pattern consistency.

## Pattern (RISEN)

All three prompts follow the RISEN frame: Role, Instructions, Steps, End goal, Narrowing. Framework section labels are stripped; prompts read as flat coherent text. Each prompt ends with an explicit stop condition and a "what to report back" list. Agents never run git operations without user approval.

## When to write another

Add a file here when:

- A new stage brief (`stage-03.md` onward) is ready to be implemented and you want the consumer repo's session to boot with the correct pre-flight + narrowing. Use `stage-02-implementation.md` as the template (MIGRATION pattern) or `stage-01-implementation.md` (FEATURE with new scaffolds).
- A consumer-side doc other than `CLAUDE.md` needs a similar orient-and-rewrite session (e.g. a `docs/progress-report.md` refresher).

Do not use these prompts for producer-side work in this repo — they are for the consumer-side agent session.
