# D2 Architecture Diagrams

Same 10 diagrams as [`design/09-architecture-diagrams.md`](../09-architecture-diagrams.md) and [`../diagrams/`](../diagrams/), but authored in **[D2](https://d2lang.com/)** instead of Mermaid. Both sets are kept in parallel — pick the tool that fits your workflow.

**Why keep both?**
- **Mermaid** renders natively on GitHub, VS Code, and inline in Claude Code chat. Best for "diffable markdown with rendered previews where you already are."
- **D2** has a more powerful layout engine (ELK is the default for complex flowcharts), a cleaner syntax for nested containers, and produces noticeably better-laid-out SVGs for dense architecture views. Best for "publish-quality SVGs I'll drop into a slide deck, wiki, or README."

Either set is fine as a reference — they encode the same information.

## Contents

| # | File | Type | Subject |
|---|---|---|---|
| 1 | `01-system-context.d2` | flowchart | CamPlugin ↔ iOS services |
| 2 | `02-actor-topology.d2` | flowchart | Swift actors + isolation domains |
| 3 | `03-frame-data-flow.d2` | flowchart | 4-stream pipeline (Capture → Metal → outputs) |
| 4 | `04-metal-pipeline-internals.d2` | flowchart | Compute kernel + post-blit pass |
| 5 | `05-error-propagation.d2` | flowchart | Error sources → classifier → paths |
| 6 | `06-hot-path-capture-to-display.d2` | sequence | 33ms per-frame hot path |
| 7 | `07-consumer-fanout-1slot-mailbox.d2` | sequence | Drop-on-busy ConsumerRegistry |
| 8 | `08-gpu-to-encoder-zero-copy.d2` | sequence | IOSurface zero-copy recording path |
| 9 | `09-actor-reentrancy-guard.d2` | sequence | F-01 patch — close() mid-flight |
| 10 | `10-still-capture-in-flight-guard.d2` | sequence | Actor-only in-flight guard |

Each `.d2` file has a sidecar `.svg` (native, scalable, small) and `.png` (pre-rendered, drops into slides / issues).

## Rendering

Prerequisite:
```sh
brew install d2
```

Re-render everything after editing any `.d2` file:
```sh
./render.sh          # renders all → .svg + .png
./render.sh svg      # .svg only (faster; no Playwright required)
./render.sh 06       # only files matching "06*"
```

The first PNG render downloads a headless Chromium (~100 MB) to `~/Library/Caches/ms-playwright/`. Subsequent PNG renders are fast. SVG rendering needs only the `d2` binary and is near-instant.

## D2 quirks worth knowing (hit while authoring these)

- **`suspend` and `drop` are reserved-ish keywords in D2's class system.** Using them as class names (`classes: { suspend: { ... } }`) causes `reserved field "class" must have a value` errors on apply sites. Use `suspended`, `dropped`, or namespaced variants.
- **Multi-line labels** work with `\n` in both quoted and unquoted forms. Labels containing `@`, `(`, `)`, `<`, `>`, `→`, `≤` are safest when wrapped in double quotes.
- **Sequence diagram groups** (equivalent to Mermaid's `alt` / `par` / `loop`) are just D2 containers inside a `shape: sequence_diagram` block. The container title becomes the group label. Nested groups work.
- **Actor re-entrancy guard** diagram (#9): D2 sequence diagrams render self-messages (`CE -> CE: ...`) cleanly with activation bars, unlike some Mermaid themes.

## Keeping this directory in sync with the Mermaid set

The source of truth for the *content* of each diagram is the prose design file it cross-references (`design/01-architecture.md` through `design/08-audit-lookups.md`). The Mermaid set lives in [`design/09-architecture-diagrams.md`](../09-architecture-diagrams.md) and [`../diagrams/`](../diagrams/). When you change a diagram:

1. Decide which tool matches the edit best (or update both).
2. Edit the canonical form (Mermaid block in `09-architecture-diagrams.md`, or `.d2` file here).
3. Re-render (`design/diagrams/render.sh` or `design/diagrams-d2/render.sh`).
4. Commit both source and rendered artifacts.

If a diagram is re-done in D2 with a meaningfully better layout and you'd like to retire the Mermaid version, just delete the Mermaid block from `09-architecture-diagrams.md` and remove the matching `.mmd` / `.png` from `../diagrams/`. The two sets are intentionally independent — neither depends on the other.
