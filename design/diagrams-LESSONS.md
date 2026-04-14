# Diagramming Lessons — iOS Translation Project

Captured after authoring 10 architecture diagrams in both Mermaid and D2 for the
`design/09-architecture-diagrams.md` reference. Covers tool choice, scoping, authoring
patterns, and every syntax gotcha that cost time.

---

## Tool choice

**Default to Mermaid.** Renders natively on GitHub, in VS Code preview, and in Claude Code's
chat UI. The source text IS the LLM-readable form — no OCR round-trip. Diffable in git.
Zero tooling. Agent 3 already used it in `01-architecture.md` and `02-concurrency.md`, so
staying on Mermaid kept the workspace consistent.

**Reach for D2 when:**
- The flowchart is dense (>15 nodes) and Mermaid's auto-layout crams it. D2's ELK engine
  handles dense hierarchies much better.
- You need publication-quality SVG output — D2's SVGs are 36–52 KB, render cleanly at any
  scale, and look clean in slide decks / wikis.
- You're willing to accept a build-step dependency (`d2` binary, plus Playwright/Chromium
  for PNG).

**Avoid:**
- PlantUML — no GitHub rendering, requires preprocessor.
- Graphviz DOT — same.
- Excalidraw — JSON blob, not LLM-readable as source.
- Hand-authored SVG — high maintenance cost.
- ASCII art — only for inline ≤10-line diagrams.

**Observed:** Mermaid rendering failed three times during this session (semicolons,
`@`-sigil, undirected-link syntax). D2 rendering failed twice (reserved-ish class names).
Both tools have sharp edges; expect 1–2 iterations per diagram the first time.

---

## Scoping a diagram set

For a system-level architecture reference, aim for **5–10 diagrams**, not 20.

**Categorize by the question they answer:**

| Diagram type | Answers | Form |
|---|---|---|
| System context | "What does the app touch outside its boundary?" | Flowchart, 10–15 nodes |
| Actor / module topology | "What are the isolation / ownership domains?" | Flowchart with subgraphs |
| Data flow | "Where does each piece of data go?" | Flowchart, directed |
| Hot-path sequence | "What happens per-event in real time?" | Sequence diagram |
| State machine | "What states exist and how do transitions fire?" | State diagram |
| Error propagation | "How does failure become a user-visible outcome?" | Flowchart with branches |
| Lifecycle / ownership | "Who allocates and who releases X?" | Table or timeline |
| Subsystem zoom | "How does X work internally?" | Flowchart zoom |

**Rules I learned the hard way:**

1. **Every diagram must have a single, explicit question.** Diagrams without a question
   end up as catch-alls that try to show everything and succeed at nothing.
2. **Cap at ~15 nodes per flowchart and ~8 actors per sequence diagram.** Above that, layout
   becomes unreadable regardless of tool. Split by scenario instead.
3. **Don't duplicate info between diagrams.** The frame-data-flow diagram and the buffer-
   ownership table overlapped in scope — I combined them into one section with two
   artifacts (one flowchart + one table) rather than two separate diagrams.
4. **Flowcharts for spatial / structural questions. Sequence diagrams for temporal
   questions.** Don't try to express "what happens over time" in a flowchart.
5. **Avoid the "kitchen sink" diagram.** If you catch yourself wanting to add "one more
   thing," you've probably mixed two questions and should split.

---

## Authoring patterns

### Color coding

Use a small palette (4–6 colors) and **reuse the same color for the same concept across
every diagram**. Readers build a mental association: yellow = `@MainActor`, blue = actors,
red = nonisolated, green = C++ consumers, etc. When I deviated from this in one diagram,
it immediately felt disorienting.

Author colors as **classes**, not inline styles. In Mermaid: `classDef`. In D2: `classes: { }`.
This enforces consistency and makes palette changes trivial.

### Labeled edges

Every edge should carry either:
- The **type** being passed (`CVPixelBuffer`, `FramePacket`, `IncomingFrame`), or
- The **action** happening (`await dispatch`, `present`, `commit`, `capture`).

Unlabeled arrows force the reader to guess. A few extra characters per arrow is always
worth it.

### Cross-references to prose

Every diagram should have a short "Cross-ref" line pointing at the prose design file(s)
that specify the details: *"see `03-metal-pipeline.md §Zero-Copy Path"*. The diagram
answers "what"; the prose answers "why." When they disagree, prose wins and the diagram
gets patched.

### Post-diagram prose

After each diagram, add **3–5 bullets** of "Key takeaways" or "Key points." The diagram
is visual; the bullets name the invariants the reader should walk away with. This is
essential for LLM readers who parse markdown linearly.

### Tables alongside diagrams

When a diagram would carry more labels than nodes, split the detail into a **table** and
keep the diagram focused on structure. The frame-data-flow + buffer-ownership split is
the canonical example: one diagram for "where does data go" (12 nodes, 15 edges), one
table for "who owns each buffer" (12 rows × 6 columns).

---

## File layout and rendering

**Recommended layout for any project:**

```
design/
  NN-topic.md              # Prose design files (1 through N)
  N+1-architecture-diagrams.md   # Main diagram doc; mermaid fenced blocks inline
  diagrams/                # Mermaid sidecars
    01-name.mmd            #   extracted sources
    01-name.png            #   pre-rendered
    extract.py             #   re-extract from source markdown
    render.sh              #   extract + mmdc pass
  diagrams-d2/             # (optional) D2 parallel set
    01-name.d2
    01-name.svg
    01-name.png
    render.sh
    README.md
```

**Always commit both source and rendered output.** Source for diffs and LLM consumption,
rendered for at-a-glance preview in file browsers and GitHub.

**Always ship a `render.sh` script.** Reviewers (and future you) should never have to
guess how to regenerate. The script is cheap and it's the only way to make the
"rendering is reproducible" claim real.

**First-time rendering dependencies:**
- Mermaid: `npm install -g @mermaid-js/mermaid-cli` (pulls Puppeteer + Chromium ~150 MB).
- D2: `brew install d2` for the binary. PNG rendering pulls Playwright Chromium (~100 MB)
  on first use. SVG rendering is instant and has no extra deps.

**Output formats:**
- Mermaid → PNG (mmdc doesn't produce great SVG without config tuning).
- D2 → SVG for the "canonical rendered form" (small, scalable); PNG as a secondary artifact
  for slides and issue attachments.

---

## Mermaid syntax gotchas hit during this session

1. **Semicolons (`;`) are statement terminators in Mermaid.** They **cannot appear inside**
   sequence diagram messages, notes, or edge labels. The parser silently slices your message
   at the `;` and reports a confusing error a few lines later.
   - **Fix:** use `—`, `/`, ` and `, or `·` (middle dot) instead.
   - Broke diagrams 6 and 8 of the Mermaid set.

2. **The `@` character** in flowchart node labels is lexed as the new Mermaid 11 typed-shape
   sigil (`A@{shape: rect}` / `A@-->B`). Labels containing `@MainActor`, `@Observable`,
   `@unchecked`, `@MLProcessor` must be **wrapped in double quotes**:
   ```
   VM["CameraViewModel<br/>@Observable"]
   ```
   - Broke diagram 2 of the Mermaid set.
   - Same rule for edge labels: `-->|"IncomingFrame<br/>@unchecked Sendable"|`.

3. **`---|label|`** (undirected link *with* a label) is **not valid syntax**. Use a
   directed `-->|label|` or an unlabeled `---`.
   - Broke diagram 2 of the Mermaid set.

4. **`<br/>`** works in flowchart node labels and sequence diagram messages, but the parser
   is strict about matching the surrounding quoting. If a label has `<br/>` *and* any other
   special character, double-quote it to be safe.

---

## D2 syntax gotchas hit during this session

1. **`suspend` and `drop`** are reserved-ish when used as class names inside a top-level
   `classes: { ... }` block. Declaring `classes: { suspend: {...} }` compiles, but
   applying it via `{ class: suspend }` produces `reserved field "class" must have a
   value` errors at *the apply site*, not the declaration. The error messages are
   misleading — they point at the apply line, not the class name.
   - **Fix:** rename to `suspended`, `dropped`, `suspend_style`, etc.
   - Broke diagram 5 of the D2 set.

2. **Labels with `@`, `(`, `)`, `<`, `>`, `→`, `≤`** are safest when wrapped in double
   quotes. Unquoted labels work for simple ASCII strings without these characters. When
   in doubt, quote.

3. **`\n` in labels** produces newlines in **both** quoted and unquoted forms. Use freely.

4. **Sequence diagram groups** (the equivalent of Mermaid's `par` / `alt` / `loop` /
   `opt`) use plain D2 container syntax inside a `shape: sequence_diagram` block. The
   container title becomes the group label. Nesting works.
   ```d2
   shape: sequence_diagram
   a: Alice
   b: Bob
   a -> b: before group
   parallel work: {
     a -> b: work A
     b -> a: result A
   }
   a -> b: after
   ```

5. **Layout engine choice:** add to any dense flowchart:
   ```d2
   vars: {
     d2-config: {
       layout-engine: elk
       pad: 40
     }
   }
   ```
   ELK produces dramatically better hierarchical layouts than the default dagre. Sequence
   diagrams don't need this — their layout is trivially linear.

6. **PNG rendering downloads Playwright Chromium** on first use to
   `~/Library/Caches/ms-playwright/`. First PNG takes 30–60 seconds; subsequent ones are
   fast. SVG rendering needs only the `d2` binary.

7. **D2 renders sequence diagram self-messages (`CE -> CE: ...`) cleanly** with activation
   bars, unlike some Mermaid themes that show them as awkward loopbacks.

---

## Iteration and maintenance

1. **Expect 2–4 renders before a diagram is shippable.** First render reveals layout
   problems that are invisible in the source. Budget time for iteration.

2. **When rendering fails, the error messages often point at a syntactically valid earlier
   line.** Mermaid's parser in particular reports errors at the point where parsing gave
   up, not where the invalid token is. Bisect by deleting half the diagram and re-rendering.

3. **Test-render the first diagram end-to-end before writing the rest.** It's much faster
   to discover a tooling issue (Playwright not installed, Rosetta noise, reserved keyword)
   on diagram 1 than on diagram 10.

4. **Re-run `render.sh` before committing.** A diagram with an out-of-date PNG is worse
   than no PNG at all.

5. **When updating prose design docs, check which diagrams became stale.** Diagrams should
   be patched at the same time as the prose that invalidated them. Otherwise they rot.

---

## Specific wins from this project

- **Combining data-flow + ownership** into one section (flowchart + table) was more useful
  than two separate diagrams would have been. Pattern: one visual artifact for "what it
  looks like," one tabular artifact for "who owns which part."
- **The actor re-entrancy guard sequence diagram** (F-01) turned out to be the clearest
  way to explain the subtle race the guard protects against. Prose alone had been
  unconvincing to reviewers; the diagram made the race visible.
- **Color-coding by concept (not severity)** across all 5 flowcharts let a reader who
  understood one diagram understand the next five faster. Display=green, record=red,
  consume=yellow/amber, MainActor=yellow, nonisolated=red became intuitive after the first
  diagram.
- **A shared `render.sh` script per diagram directory** meant regeneration was always one
  command. The first time I had to manually re-render after a patch, I knew to script it.

---

## What I would do differently next time

1. **Write the render script first.** Set up rendering before authoring the first diagram
   so iteration has zero friction from the start.
2. **Start with the smallest diagram** (system context, ~10 nodes) rather than the most
   complex (frame data-flow, ~30 nodes). Small diagrams reveal tooling issues faster.
3. **Decide tool choice once, up-front.** I did both Mermaid and D2 for this project.
   Useful as an experiment but the parallel sets now need to be kept in sync. For a real
   project, pick one and stick with it.
4. **Validate against the prose design doc before finalizing.** I caught one diagram-vs-
   prose disagreement late (the encoder-path zero-copy claim), which would have been
   cheaper to fix at author time.
5. **Sketch the diagram set on paper first.** The set of 10 that landed is good, but I
   added two and removed two mid-way. A 5-minute whiteboard session at the start would
   have saved that churn.
