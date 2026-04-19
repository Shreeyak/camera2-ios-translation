# Implementation Pipeline Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Agent 3 / Agent 4 / Agent 5 pipeline defined in `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` so that `domain-revised/` + `ios-platform-guide/` can be turned into per-stage implementation briefs a separate Claude Code CLI session can execute against.

**Architecture:** Two shell scripts (`verify-architecture.sh`, `verify-briefs.sh`) enforce mechanical quality bars; three agent system prompts (`agent-3-architect.md`, `agent-4-review.md`, `agent-5-brief-writer.md`) drive the LLM work. The scripts are TDD'd against fixture directories. The prompts are built section-by-section to match the spec's contracts and smoke-tested end-to-end against the real domain inputs.

**Tech Stack:** bash 5+, `yq` (v4, Go version), Swift 6 toolchain (for api-skeletons validation at M3 of verify-architecture.sh), markdown. No Xcode project. Fixtures are tiny markdown + YAML files.

**Spec reference:** `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` — every quality bar M1-M8 / J1-J5 / M1-M5 referenced below corresponds to a numbered bar in that spec.

---

## File Structure

Files created by this plan (in the artifacts repo, `/Users/shrek/work/cambrian/ios-translation`):

```
implementation/
├── README.md                                      # top-level orientation
├── prompts/
│   ├── agent-3-architect.md                       # Agent 3 system prompt
│   ├── agent-4-review.md                          # Agent 4 system prompt
│   └── agent-5-brief-writer.md                    # Agent 5 system prompt
├── scripts/
│   ├── verify-architecture.sh                     # M1-M8 mechanical checks
│   ├── verify-briefs.sh                           # M1-M5 mechanical checks (Agent 5)
│   ├── lib.sh                                     # shared helpers
│   └── fixtures/
│       ├── architecture-good/                     # passes all M-bars
│       ├── architecture-bad-m1/                   # missing a required file
│       ├── architecture-bad-m2/                   # D-## without inline anchor
│       ├── architecture-bad-m3/                   # api-skeletons fails to build
│       ├── architecture-bad-m4/                   # stage touches: invalid file
│       ├── architecture-bad-m5/                   # scaffolding not retired
│       ├── architecture-bad-m6/                   # retire without depends_on
│       ├── architecture-bad-m7/                   # constants.md blank cell
│       ├── architecture-bad-m8/                   # interaction w/o shape tag
│       ├── briefs-good/
│       ├── briefs-bad-m1/                         # missing section heading
│       ├── briefs-bad-m2/                         # dangling arch anchor
│       ├── briefs-bad-m3/                         # retires ghost scaffold
│       ├── briefs-bad-m4/                         # unknown class
│       └── briefs-bad-m5/                         # FLAGGED w/o matching TESTABLE
├── architecture/                                  # Agent 3 populates (empty at plan time)
│   └── .gitkeep
├── stages/                                        # Agent 3 populates
│   └── .gitkeep
├── review/                                        # Agent 4 populates
│   └── .gitkeep
└── briefs/                                        # Agent 5 populates
    └── .gitkeep
```

Existing files modified:
- `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md` — pipeline table update
- `/Users/shrek/work/cambrian/ios-translation/README.md` — pipeline table update

---

## Task 1: Scaffold `implementation/` directory

**Files:**
- Create: `implementation/README.md`
- Create: `implementation/prompts/.gitkeep`
- Create: `implementation/scripts/.gitkeep`
- Create: `implementation/scripts/fixtures/.gitkeep`
- Create: `implementation/architecture/.gitkeep`
- Create: `implementation/stages/.gitkeep`
- Create: `implementation/review/.gitkeep`
- Create: `implementation/briefs/.gitkeep`

- [ ] **Step 1: Create the directory tree and empty sentinels**

```bash
cd /Users/shrek/work/cambrian/ios-translation
mkdir -p implementation/{prompts,scripts/fixtures,architecture,stages,review,briefs}
touch implementation/{prompts,scripts,scripts/fixtures,architecture,stages,review,briefs}/.gitkeep
```

- [ ] **Step 2: Write `implementation/README.md`**

```markdown
# implementation/

Pipeline artifacts for turning `domain-revised/` + `ios-platform-guide/` into per-stage implementation briefs for Claude Code CLI.

Designed per `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md`.

## Subdirectories

- `prompts/` — system prompts for Agent 3 (Architect + Stage Mapper), Agent 4 (Architecture Review), Agent 5 (Brief Writer).
- `scripts/` — mechanical verification scripts (`verify-architecture.sh`, `verify-briefs.sh`) and fixtures.
- `architecture/` — Agent 3 output. 9 concern files + 4 register files + api-skeletons SwiftPM target.
- `stages/` — Agent 3 output. `stage-index.md` with YAML frontmatter per stage.
- `review/` — Agent 4 output. Green/Yellow/Red verdict + findings.
- `briefs/` — Agent 5 output. `stage-NN.md` corpus + `state-template.md` + `README.md`.

## Pipeline run order

1. Agent 3 produces `architecture/` and `stages/stage-index.md`.
2. `scripts/verify-architecture.sh` runs mechanical checks M1-M8. Must pass before Agent 4.
3. Agent 4 runs judgement-level review J1-J5; emits verdict in `review/`. Must be Green before Agent 5.
4. Agent 5 produces `briefs/`.
5. `scripts/verify-briefs.sh` runs mechanical checks M1-M5.
6. Claude Code (separate repo) consumes `briefs/` + reads `architecture/` and `ios-platform-guide/` as external reference.
```

- [ ] **Step 3: Verify the tree**

Run: `find implementation -type f | sort`
Expected output (exact):
```
implementation/README.md
implementation/architecture/.gitkeep
implementation/briefs/.gitkeep
implementation/prompts/.gitkeep
implementation/review/.gitkeep
implementation/scripts/.gitkeep
implementation/scripts/fixtures/.gitkeep
implementation/stages/.gitkeep
```

- [ ] **Step 4: Commit**

```bash
git add implementation/
git commit -m "feat(implementation): scaffold pipeline directory tree"
```

---

## Task 2: Install dependencies and write `scripts/lib.sh`

**Files:**
- Create: `implementation/scripts/lib.sh`

**Dependencies required on the executor's machine**: `bash` 5+, `yq` (Go version v4+), `swift` 6+. If any are missing, install first:
- `brew install yq` (macOS)
- Swift 6 toolchain: Xcode 16+ or `swift.org/install`

- [ ] **Step 1: Verify dependencies exist**

```bash
bash --version | head -1    # expect 5.x+
yq --version                # expect v4.x+
swift --version | head -1   # expect Swift version 6.x+
```

If any fail, install before proceeding.

- [ ] **Step 2: Write `implementation/scripts/lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for verify-architecture.sh and verify-briefs.sh.
# Source this file; do not execute it directly.

# Reset and track pass/fail.
declare -gi VERIFY_FAIL_COUNT=0
declare -ga VERIFY_FAILURES=()

pass() {
    printf '[PASS] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    VERIFY_FAILURES+=("$1")
    VERIFY_FAIL_COUNT+=1
}

info() {
    printf '[INFO] %s\n' "$1"
}

# Final summary; exit with 0 on pass, 1 on any failure.
finish() {
    if (( VERIFY_FAIL_COUNT == 0 )); then
        printf '\n[OK] All checks passed.\n'
        exit 0
    fi
    printf '\n[FAIL] %d check(s) failed:\n' "$VERIFY_FAIL_COUNT" >&2
    for f in "${VERIFY_FAILURES[@]}"; do
        printf '  - %s\n' "$f" >&2
    done
    exit 1
}

# require_file PATH LABEL
require_file() {
    if [[ ! -f "$1" ]]; then
        fail "$2: missing file $1"
        return 1
    fi
    return 0
}

# require_dir PATH LABEL
require_dir() {
    if [[ ! -d "$1" ]]; then
        fail "$2: missing directory $1"
        return 1
    fi
    return 0
}
```

- [ ] **Step 3: Make it executable-readable but not a script**

```bash
chmod 644 implementation/scripts/lib.sh
```

- [ ] **Step 4: Commit**

```bash
git add implementation/scripts/lib.sh
git commit -m "feat(implementation): add verify-script shared helpers"
```

---

## Task 3: Build the `architecture-good/` fixture

This is the reference fixture that every check in verify-architecture.sh must pass against. Minimal but complete.

**Files:**
- Create: `implementation/scripts/fixtures/architecture-good/` and subtree

- [ ] **Step 1: Create fixture directory tree**

```bash
cd /Users/shrek/work/cambrian/ios-translation
mkdir -p implementation/scripts/fixtures/architecture-good/architecture/api-skeletons/Sources/CameraKit
mkdir -p implementation/scripts/fixtures/architecture-good/stages
```

- [ ] **Step 2: Write a minimal `architecture/README.md` with required subsections**

File: `implementation/scripts/fixtures/architecture-good/architecture/README.md`

```markdown
# Architecture — Fixture

## Primary-owner rule
Every architectural decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content.

## Phase coverage table
| domain file | primary concern(s) | implementing stage(s) |
|---|---|---|
| 01-system-purpose.md | 01-system-shape | 01 |

## Interactions considered
- **concurrency×lifecycle**: scenePhase `.inactive` × outstanding `MTLCommandBuffer` → gate GPU submission (ADR-09). Shape: `concurrency×lifecycle`.
- **storage×consumer**: consumer registration × texture storage mode → transition on attach. Shape: `storage×consumer`.
- **error×recovery**: watchdog × retry → disarm before retry. Shape: `error×recovery`.
```

- [ ] **Step 3: Write the 9 concern files as near-empty stubs**

For each of `01-system-shape.md`, `02-concurrency.md`, `03-camera-session.md`, `04-metal-pipeline.md`, `05-consumers.md`, `06-capture-and-recording.md`, `07-settings.md`, `08-ui.md`, `09-errors-and-recovery.md`:

```bash
for f in 01-system-shape 02-concurrency 03-camera-session 04-metal-pipeline \
         05-consumers 06-capture-and-recording 07-settings 08-ui 09-errors-and-recovery; do
  printf '# %s — Fixture\n\nCites ADR-01.\n' "$f" > \
    "implementation/scripts/fixtures/architecture-good/architecture/${f}.md"
done
```

- [ ] **Step 4: Write `02-concurrency.md` with required subsections (overwrite the stub)**

File: `implementation/scripts/fixtures/architecture-good/architecture/02-concurrency.md`

```markdown
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
```

- [ ] **Step 5: Write register files `api-surface.md`, `decisions.md`, `constants.md`, `open-questions.md`**

File: `implementation/scripts/fixtures/architecture-good/architecture/api-surface.md`
```markdown
# API Surface — Fixture

See `api-skeletons/Sources/CameraKit/CameraEngine.swift` for signatures.
```

File: `implementation/scripts/fixtures/architecture-good/architecture/decisions.md`
```markdown
# Decisions — Fixture

| D-## | Decision | Cites | Source | File |
|---|---|---|---|---|
| D-01 | Adopt fixture convention | ADR-01 | spec | 01-system-shape.md |
```

File: `implementation/scripts/fixtures/architecture-good/architecture/01-system-shape.md` (append D-01 anchor)
```bash
cat >> implementation/scripts/fixtures/architecture-good/architecture/01-system-shape.md <<'EOF'

## D-01 — Adopt fixture convention

Context: fixture must have one referenced D-## to exercise M2. Decision: add one inline.
EOF
```

File: `implementation/scripts/fixtures/architecture-good/architecture/constants.md`
```markdown
# Constants — Fixture

| Name | Value | Cite | Owning concern | Rationale |
|---|---|---|---|---|
| DRAIN_TIMEOUT_SECONDS | 5 | spec | 06-capture-and-recording | Recording drain budget |
```

File: `implementation/scripts/fixtures/architecture-good/architecture/open-questions.md`
```markdown
# Open Questions — Fixture

(No deferred items in this minimal fixture.)
```

- [ ] **Step 6: Write the minimum `api-skeletons/` SwiftPM package**

File: `implementation/scripts/fixtures/architecture-good/architecture/api-skeletons/Package.swift`

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ApiSkeletons",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(
            name: "CameraKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
```

File: `implementation/scripts/fixtures/architecture-good/architecture/api-skeletons/Sources/CameraKit/CameraEngine.swift`

```swift
public actor CameraEngine {
    public init() {}
    public func open() async throws { fatalError("Stage N") }
}
```

- [ ] **Step 7: Write `stages/stage-index.md` with one stage**

File: `implementation/scripts/fixtures/architecture-good/stages/stage-index.md`

```markdown
# Stage Index — Fixture

---
stage: 01
title: Bare preview
type: FEATURE
depends_on: []
touches: [01-system-shape, 08-ui]
scaffolding_introduced: []
scaffolding_retired: []
tests_preserved: []
---

Visible: Camera feed fills screen.
```

- [ ] **Step 8: Verify the fixture builds**

```bash
swift build --package-path implementation/scripts/fixtures/architecture-good/architecture/api-skeletons
```
Expected: `Build complete!`.

- [ ] **Step 9: Commit**

```bash
git add implementation/scripts/fixtures/architecture-good/
git commit -m "test(implementation): add architecture-good fixture"
```

---

## Task 4: Write `verify-architecture.sh` skeleton

**Files:**
- Create: `implementation/scripts/verify-architecture.sh`

- [ ] **Step 1: Write the skeleton**

File: `implementation/scripts/verify-architecture.sh`

```bash
#!/usr/bin/env bash
# verify-architecture.sh — mechanical checks M1-M8 from the implementation pipeline spec.
# Exits 0 if all pass; 1 otherwise. Prints per-check status.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<USAGE
Usage: $0 <root-dir>
  <root-dir> contains architecture/ and stages/ subdirectories.
USAGE
    exit 2
}

[[ $# -eq 1 ]] || usage
ROOT="$1"
ARCH="$ROOT/architecture"
STAGES="$ROOT/stages"

require_dir "$ARCH"   "root" || finish
require_dir "$STAGES" "root" || finish

check_m1_files_exist() {
    local required=(
        "README.md"
        "01-system-shape.md"
        "02-concurrency.md"
        "03-camera-session.md"
        "04-metal-pipeline.md"
        "05-consumers.md"
        "06-capture-and-recording.md"
        "07-settings.md"
        "08-ui.md"
        "09-errors-and-recovery.md"
        "api-surface.md"
        "decisions.md"
        "constants.md"
        "open-questions.md"
    )
    local ok=1
    for f in "${required[@]}"; do
        require_file "$ARCH/$f" "M1" || ok=0
    done
    require_dir "$ARCH/api-skeletons" "M1" || ok=0
    (( ok == 1 )) && pass "M1: all required files exist"
}

check_m1_files_exist

# M2-M8 added in subsequent tasks

finish
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x implementation/scripts/verify-architecture.sh
```

- [ ] **Step 3: Run against the good fixture**

```bash
./implementation/scripts/verify-architecture.sh implementation/scripts/fixtures/architecture-good
```
Expected output includes `[PASS] M1: all required files exist` and `[OK] All checks passed.` exit 0.

- [ ] **Step 4: Commit**

```bash
git add implementation/scripts/verify-architecture.sh
git commit -m "feat(implementation): verify-architecture.sh skeleton with M1"
```

---

## Task 5: Add M2 (D-## inline anchor check) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m2/` (copy of good with M2 violation)

- [ ] **Step 1: Build the bad fixture**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m2
# Remove the D-01 anchor from 01-system-shape.md
sed -i '' '/^## D-01 — Adopt fixture convention$/,$d' \
  implementation/scripts/fixtures/architecture-bad-m2/architecture/01-system-shape.md
# Confirm the D-01 entry still exists in decisions.md (so M2 should fail on mismatch)
grep 'D-01' implementation/scripts/fixtures/architecture-bad-m2/architecture/decisions.md
```

- [ ] **Step 2: Add M2 to verify-architecture.sh**

Insert before `finish` call:

```bash
check_m2_d_anchors() {
    # For every D-## row in decisions.md (col 1), find that D-## as a heading or anchor
    # in some architecture/*.md file. Failure = D-## exists in register but no inline.
    local decisions="$ARCH/decisions.md"
    [[ -f "$decisions" ]] || { fail "M2: decisions.md missing"; return; }

    # Extract D-## IDs from the table column 1 (skip header/sep rows).
    local ids
    ids=$(grep -oE '^\| D-[0-9]+' "$decisions" | awk '{print $2}' | sort -u || true)
    [[ -z "$ids" ]] && { pass "M2: no D-## entries to check"; return; }

    local ok=1
    while IFS= read -r id; do
        # Search for this D-## as either a heading (## D-##) or plain mention
        # in any architecture/*.md file other than decisions.md.
        if ! grep -rlE "^## ${id}( |$)" "$ARCH" --include='*.md' --exclude='decisions.md' >/dev/null; then
            fail "M2: ${id} in decisions.md has no inline '## ${id}' anchor in a concern file"
            ok=0
        fi
    done <<< "$ids"
    (( ok == 1 )) && pass "M2: every D-## in decisions.md has an inline anchor"
}

check_m2_d_anchors
```

- [ ] **Step 3: Run against the bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m2
```
Expected: `[FAIL] M2: D-01 in decisions.md has no inline '## D-01' anchor in a concern file` and exit 1.

- [ ] **Step 4: Run against the good fixture — expect pass**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-good
```
Expected: `[PASS] M2: every D-## in decisions.md has an inline anchor` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M2 (D-## anchors)"
```

---

## Task 6: Add M3 (api-skeletons swift build) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m3/` (copy with broken Swift)

- [ ] **Step 1: Build the bad fixture**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m3
# Inject a Swift syntax error.
cat > implementation/scripts/fixtures/architecture-bad-m3/architecture/api-skeletons/Sources/CameraKit/CameraEngine.swift <<'EOF'
public actor CameraEngine {
    public init( {}  // deliberate syntax error
    public func open() async throws { fatalError("Stage N") }
}
EOF
```

- [ ] **Step 2: Add M3 check**

Insert before `finish`:

```bash
check_m3_skeletons_build() {
    local pkg="$ARCH/api-skeletons"
    [[ -d "$pkg" ]] || { fail "M3: api-skeletons/ missing"; return; }

    if swift build --package-path "$pkg" >/tmp/m3.log 2>&1; then
        pass "M3: api-skeletons swift build succeeded"
    else
        fail "M3: api-skeletons swift build failed (see /tmp/m3.log)"
    fi
}

check_m3_skeletons_build
```

- [ ] **Step 3: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m3
```
Expected: `[FAIL] M3: api-skeletons swift build failed` and exit 1.

- [ ] **Step 4: Run against good fixture — expect pass**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-good
```
Expected: `[PASS] M3: api-skeletons swift build succeeded`.

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M3 (swift build)"
```

---

## Task 7: Add M4 (stage touches: valid concern file) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m4/`

- [ ] **Step 1: Build the bad fixture — `touches:` names a nonexistent file**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m4
# Change touches: to include a bogus file.
sed -i '' 's/touches: \[01-system-shape, 08-ui\]/touches: [99-nonsense, 08-ui]/' \
  implementation/scripts/fixtures/architecture-bad-m4/stages/stage-index.md
```

- [ ] **Step 2: Add M4 using yq**

Insert before `finish`:

```bash
check_m4_touches_valid() {
    local index="$STAGES/stage-index.md"
    [[ -f "$index" ]] || { fail "M4: stage-index.md missing"; return; }

    # Extract YAML blocks (delimited by ---). yq reads multi-doc YAML from stdin.
    # Strip markdown around the YAML: keep only blocks between ---...---.
    local yamls
    yamls=$(awk '/^---$/{f=!f; if(f)print "---"; next} f' "$index")

    # Valid concern file stems (no extension).
    local valid_stems=(
        01-system-shape 02-concurrency 03-camera-session 04-metal-pipeline
        05-consumers 06-capture-and-recording 07-settings 08-ui 09-errors-and-recovery
    )
    # Build a regex alternation.
    local valid_re
    valid_re=$(IFS='|'; printf '%s' "${valid_stems[*]}")

    local ok=1
    # Each touches: value is a YAML list. yq returns them joined by newline per document.
    while IFS= read -r stem; do
        [[ -z "$stem" ]] && continue
        if ! [[ "$stem" =~ ^(${valid_re})$ ]]; then
            fail "M4: stage touches unknown concern file: $stem"
            ok=0
        fi
    done < <(echo "$yamls" | yq eval-all '.touches[]' -)

    (( ok == 1 )) && pass "M4: every stage touches: entry is a valid concern file"
}

check_m4_touches_valid
```

- [ ] **Step 3: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m4
```
Expected: `[FAIL] M4: stage touches unknown concern file: 99-nonsense`.

- [ ] **Step 4: Run against good fixture — expect pass**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-good
```
Expected: `[PASS] M4: every stage touches: entry is a valid concern file`.

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M4 (touches validity)"
```

---

## Task 8: Add M5 (scaffolding pair + no cycles) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m5/`

- [ ] **Step 1: Build bad fixture — scaffolding introduced but never retired**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m5
cat >> implementation/scripts/fixtures/architecture-bad-m5/stages/stage-index.md <<'EOF'

---
stage: 02
title: Orphan-scaffold stage
type: FEATURE
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: [02:orphan-slug]
scaffolding_retired: []
tests_preserved: []
---
Visible: nothing.
EOF
```

- [ ] **Step 2: Add M5**

Insert before `finish`:

```bash
check_m5_scaffolding_pairs() {
    local index="$STAGES/stage-index.md"
    local yamls
    yamls=$(awk '/^---$/{f=!f; if(f)print "---"; next} f' "$index")

    # Collect all introduced and retired slugs across all stages.
    local introduced retired
    introduced=$(echo "$yamls" | yq eval-all '.scaffolding_introduced[]?' - | sort -u)
    retired=$(echo "$yamls" | yq eval-all '.scaffolding_retired[]?' - | sort -u)

    local ok=1
    # Every introduced must appear in retired.
    while IFS= read -r slug; do
        [[ -z "$slug" ]] && continue
        if ! grep -Fxq "$slug" <<< "$retired"; then
            fail "M5: scaffold '$slug' introduced but never retired"
            ok=0
        fi
    done <<< "$introduced"

    # Every retired must reference an introduced slug.
    while IFS= read -r slug; do
        [[ -z "$slug" ]] && continue
        if ! grep -Fxq "$slug" <<< "$introduced"; then
            fail "M5: scaffold '$slug' retired but never introduced"
            ok=0
        fi
    done <<< "$retired"

    # No cycles in depends_on (simple DFS).
    # Build adjacency from YAML.
    local edges
    edges=$(echo "$yamls" | yq eval-all '.stage as $s | .depends_on[]? | [$s, .] | @csv' - 2>/dev/null)
    # Use tsort to detect cycles (it emits an error on cycles).
    if [[ -n "$edges" ]]; then
        if ! echo "$edges" | tr ',' ' ' | tsort >/dev/null 2>&1; then
            fail "M5: depends_on graph has a cycle"
            ok=0
        fi
    fi

    (( ok == 1 )) && pass "M5: scaffolding pairs balanced and no depends_on cycles"
}

check_m5_scaffolding_pairs
```

- [ ] **Step 3: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m5
```
Expected: `[FAIL] M5: scaffold '02:orphan-slug' introduced but never retired`.

- [ ] **Step 4: Run against good fixture — expect pass**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-good
```
Expected: `[PASS] M5: scaffolding pairs balanced and no depends_on cycles`.

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M5 (scaffolding + cycles)"
```

---

## Task 9: Add M6 (retire implies depends_on) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m6/`

- [ ] **Step 1: Build bad fixture — retire without depends_on**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m6
cat >> implementation/scripts/fixtures/architecture-bad-m6/stages/stage-index.md <<'EOF'

---
stage: 02
title: Introduces scaffold
type: FEATURE
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: [02:some-slug]
scaffolding_retired: []
tests_preserved: []
---
Visible: nothing.

---
stage: 03
title: Retires without depending on 02
type: MIGRATION
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: []
scaffolding_retired: [02:some-slug]
tests_preserved: []
---
Visible: nothing.
EOF
```

- [ ] **Step 2: Add M6**

Insert before `finish`:

```bash
check_m6_retire_implies_depends() {
    local index="$STAGES/stage-index.md"
    local yamls
    yamls=$(awk '/^---$/{f=!f; if(f)print "---"; next} f' "$index")

    local ok=1
    # For every stage, each retired slug's source stage (S) must appear in depends_on.
    # Slug format: "S:slug". Extract S and verify.
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        # row format: "stage|depends_on_joined|retired_joined"
        IFS='|' read -r stage depends retired <<< "$row"
        IFS=',' read -ra retired_arr <<< "$retired"
        IFS=',' read -ra depends_arr <<< "$depends"
        for slug in "${retired_arr[@]}"; do
            [[ -z "$slug" ]] && continue
            local src="${slug%%:*}"
            # Strip leading zeros for comparison ('01' vs '1')
            local src_n=$((10#$src))
            local found=0
            for d in "${depends_arr[@]}"; do
                [[ -z "$d" ]] && continue
                if (( 10#$d == src_n )); then found=1; break; fi
            done
            if (( found == 0 )); then
                fail "M6: stage $stage retires '$slug' but depends_on does not include $src"
                ok=0
            fi
        done
    done < <(echo "$yamls" | yq eval-all \
        '[.stage, (.depends_on // [] | join(",")), (.scaffolding_retired // [] | join(","))] | join("|")' -)

    (( ok == 1 )) && pass "M6: every retired scaffold's source stage is in depends_on"
}

check_m6_retire_implies_depends
```

- [ ] **Step 3: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m6
```
Expected: `[FAIL] M6: stage 3 retires '02:some-slug' but depends_on does not include 02`.

- [ ] **Step 4: Run against good fixture — expect pass**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-good
```
Expected: `[PASS] M6: every retired scaffold's source stage is in depends_on`.

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M6 (retire implies depends_on)"
```

---

## Task 10: Add M7 (constants.md no blank cells) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m7/`

- [ ] **Step 1: Build bad fixture — blank cell in constants**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m7
cat > implementation/scripts/fixtures/architecture-bad-m7/architecture/constants.md <<'EOF'
# Constants — Fixture

| Name | Value | Cite | Owning concern | Rationale |
|---|---|---|---|---|
| DRAIN_TIMEOUT_SECONDS | 5 | spec | 06-capture-and-recording | Recording drain budget |
| BLANK_CELL |  | spec | 06-capture-and-recording | Missing value |
EOF
```

- [ ] **Step 2: Add M7**

Insert before `finish`:

```bash
check_m7_constants_no_blanks() {
    local constants="$ARCH/constants.md"
    [[ -f "$constants" ]] || { fail "M7: constants.md missing"; return; }

    local ok=1
    # Each data row starts with '|'. Separator rows match only |---. Skip header + separator.
    # A blank cell looks like '| |' or '|  |' (whitespace only).
    local lineno=0
    while IFS= read -r line; do
        lineno=$((lineno+1))
        # Skip non-table lines.
        [[ "$line" =~ ^\| ]] || continue
        # Skip the header-separator line ('| --- | --- | ...').
        [[ "$line" =~ ^\|[[:space:]]*-+ ]] && continue
        # Check each cell (strip leading/trailing |, split on |).
        local trimmed="${line#|}"; trimmed="${trimmed%|}"
        IFS='|' read -ra cells <<< "$trimmed"
        # Header row: first line after '# Constants...'; skip by recognizing it
        # contains "Name" literally.
        if [[ "$line" == *"Name"* && "$line" == *"Value"* ]]; then continue; fi
        for cell in "${cells[@]}"; do
            # A cell is blank if it has only whitespace.
            if [[ -z "${cell// /}" ]]; then
                fail "M7: constants.md line $lineno has a blank cell"
                ok=0
                break
            fi
        done
    done < "$constants"

    (( ok == 1 )) && pass "M7: constants.md has no blank cells"
}

check_m7_constants_no_blanks
```

- [ ] **Step 3: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-architecture.sh \
  implementation/scripts/fixtures/architecture-bad-m7
```
Expected: `[FAIL] M7: constants.md line 6 has a blank cell`.

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M7 (constants no blanks)"
```

---

## Task 11: Add M8 (interaction shape tags) — TDD

**Files:**
- Modify: `implementation/scripts/verify-architecture.sh`
- Create: `implementation/scripts/fixtures/architecture-bad-m8/`

- [ ] **Step 1: Build bad fixture — interaction entry without shape tag**

```bash
cp -r implementation/scripts/fixtures/architecture-good \
      implementation/scripts/fixtures/architecture-bad-m8
# Replace the Interactions considered section with a tagless entry.
python3 - <<'EOF'
from pathlib import Path
p = Path('implementation/scripts/fixtures/architecture-bad-m8/architecture/README.md')
text = p.read_text()
# Find the "## Interactions considered" section and replace its body.
start = text.index('## Interactions considered')
# End at next ## or EOF.
rest = text[start:]
next_h2 = rest.find('\n## ', 1)
end_offset = start + next_h2 if next_h2 != -1 else len(text)
new_body = '## Interactions considered\n\n- Some interaction without a shape tag.\n'
p.write_text(text[:start] + new_body + (text[end_offset:] if next_h2 != -1 else ''))
EOF
```

- [ ] **Step 2: Add M8**

Insert before `finish`:

```bash
check_m8_interaction_shapes() {
    local readme="$ARCH/README.md"
    local allowed_tags='concurrency×lifecycle|storage×consumer|error×recovery|resource×teardown|settings×session|ui×state'

    # Extract the ## Interactions considered section.
    local section
    section=$(awk '/^## Interactions considered/{f=1; next} /^## /{f=0} f' "$readme")
    [[ -z "$section" ]] && { fail "M8: 'Interactions considered' section missing"; return; }

    local ok=1
    # Each bullet must carry a tag matching allowed_tags.
    while IFS= read -r line; do
        [[ "$line" =~ ^- ]] || continue
        # Allow bullets literally containing a known tag OR the phrase "no interaction"
        # (nulls allowed per spec).
        if [[ "$line" =~ no\ interaction\ found ]]; then continue; fi
        if ! echo "$line" | grep -qE "${allowed_tags}"; then
            fail "M8: interaction bullet lacks shape tag: $line"
            ok=0
        fi
    done <<< "$section"

    (( ok == 1 )) && pass "M8: every interaction bullet carries a shape tag"
}

check_m8_interaction_shapes
```

- [ ] **Step 3: Run against bad fixture — expect failure**

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-architecture.sh M8 (shape tags)"
```

---

## Task 12: Build `briefs-good/` fixture

**Files:**
- Create: `implementation/scripts/fixtures/briefs-good/` and subtree

- [ ] **Step 1: Create a minimal briefs corpus referencing the architecture-good fixture**

```bash
mkdir -p implementation/scripts/fixtures/briefs-good/briefs
# Re-use the same architecture for anchor validation.
cp -r implementation/scripts/fixtures/architecture-good/architecture \
      implementation/scripts/fixtures/briefs-good/
cp -r implementation/scripts/fixtures/architecture-good/stages \
      implementation/scripts/fixtures/briefs-good/
```

- [ ] **Step 2: Write `briefs/README.md`**

File: `implementation/scripts/fixtures/briefs-good/briefs/README.md`

```markdown
# Briefs — Fixture

## Source of truth
For stage N, your current brief (`stage-NN.md`) is the authoritative source for this stage. If the brief references an architecture anchor or domain section, read it. If a prior brief or the architecture appears to contradict the current brief, the current brief wins — note the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed with the current brief.

## Implementer read-path
For stage N, read only: (1) this brief, (2) cited architecture refs, (3) cited domain refs, (4) `api-skeletons/` for files you'll touch, (5) `state.md` from the prior stage.

## Stage-kickoff template
(as in the spec §Agent 5)
```

- [ ] **Step 3: Write `briefs/stage-01.md` with all 12 section headings**

File: `implementation/scripts/fixtures/briefs-good/briefs/stage-01.md`

```markdown
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

## 7. Contracts & invariants
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
```

- [ ] **Step 4: Write `briefs/state-template.md`**

File: `implementation/scripts/fixtures/briefs-good/briefs/state-template.md`

```markdown
# state.md — initial

## Current stage
(none yet; Stage 01 about to begin)

## Scaffolding still live
(none)

## What's built (permanent)
(none)

## Public API exposed so far
(none)

## Manual test evidence
(none)

## Decisions taken that weren't in briefs
(none)

## Open questions for next stage
(none)
```

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/fixtures/briefs-good/
git commit -m "test(implementation): add briefs-good fixture"
```

---

## Task 13: Write `verify-briefs.sh` with M1 (12 sections) — TDD

**Files:**
- Create: `implementation/scripts/verify-briefs.sh`
- Create: `implementation/scripts/fixtures/briefs-bad-m1/`

- [ ] **Step 1: Build bad fixture — missing section heading**

```bash
cp -r implementation/scripts/fixtures/briefs-good \
      implementation/scripts/fixtures/briefs-bad-m1
# Remove section 7 heading from stage-01.md.
sed -i '' '/^## 7\. Contracts & invariants$/d' \
  implementation/scripts/fixtures/briefs-bad-m1/briefs/stage-01.md
```

- [ ] **Step 2: Write verify-briefs.sh with M1**

File: `implementation/scripts/verify-briefs.sh`

```bash
#!/usr/bin/env bash
# verify-briefs.sh — mechanical checks M1-M5 from the implementation pipeline spec.
# Exits 0 if all pass; 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<USAGE
Usage: $0 <root-dir>
  <root-dir> contains briefs/, architecture/, stages/ subdirectories.
USAGE
    exit 2
}

[[ $# -eq 1 ]] || usage
ROOT="$1"
BRIEFS="$ROOT/briefs"
ARCH="$ROOT/architecture"
STAGES="$ROOT/stages"

require_dir "$BRIEFS" "root" || finish

check_m1_section_headings() {
    local required_headings=(
        "## 1. Frontmatter"
        "## 2. Starting state"
        "## 3. Goal"
        "## 4. Files to create / modify / delete"
        "## 5. Architecture refs"
        "## 6. Domain refs"
        "## 7. Contracts & invariants"
        "## 8. Tests to write"
        "## 9. Tests preserved (must still pass)"
        "## 10. Acceptance criteria"
        "## 11. Verification steps"
        "## 12. State.md updates (Claude Code writes these)"
    )

    local ok=1
    for brief in "$BRIEFS"/stage-*.md; do
        [[ -f "$brief" ]] || continue
        # Extract all H2 lines in order.
        local actual
        actual=$(grep -E '^## ' "$brief" || true)
        # Verify every required heading is present AND order is preserved.
        local last_pos=0
        for heading in "${required_headings[@]}"; do
            local pos
            pos=$(grep -nFx "$heading" "$brief" | head -1 | cut -d: -f1 || true)
            if [[ -z "$pos" ]]; then
                fail "M1: $brief missing heading: $heading"
                ok=0
                continue
            fi
            if (( pos < last_pos )); then
                fail "M1: $brief has heading '$heading' out of order"
                ok=0
            fi
            last_pos=$pos
        done
    done

    (( ok == 1 )) && pass "M1: all briefs have 12 section headings in order"
}

check_m1_section_headings

finish
```

- [ ] **Step 3: Make executable**

```bash
chmod +x implementation/scripts/verify-briefs.sh
```

- [ ] **Step 4: Run against bad fixture — expect failure**

```bash
./implementation/scripts/verify-briefs.sh implementation/scripts/fixtures/briefs-bad-m1
```
Expected: `[FAIL] M1: ...stage-01.md missing heading: ## 7. Contracts & invariants`.

- [ ] **Step 5: Run against good fixture — expect pass**

```bash
./implementation/scripts/verify-briefs.sh implementation/scripts/fixtures/briefs-good
```
Expected: `[PASS] M1: all briefs have 12 section headings in order`.

- [ ] **Step 6: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-briefs.sh M1 (section headings)"
```

---

## Task 14: Add M2 (architecture anchor resolution) — TDD

**Files:**
- Modify: `implementation/scripts/verify-briefs.sh`
- Create: `implementation/scripts/fixtures/briefs-bad-m2/`

- [ ] **Step 1: Build bad fixture — brief cites a nonexistent anchor**

```bash
cp -r implementation/scripts/fixtures/briefs-good \
      implementation/scripts/fixtures/briefs-bad-m2
sed -i '' 's|architecture/08-ui.md$|architecture/08-ui.md#nonexistent-anchor|' \
  implementation/scripts/fixtures/briefs-bad-m2/briefs/stage-01.md
```

- [ ] **Step 2: Add M2**

Insert before `finish`:

```bash
check_m2_arch_anchors() {
    local ok=1
    for brief in "$BRIEFS"/stage-*.md; do
        [[ -f "$brief" ]] || continue
        # Find lines referencing architecture/ files.
        while IFS= read -r ref; do
            # Strip bullet '- ' prefix and trailing punctuation.
            ref=$(echo "$ref" | sed -E 's/^-[[:space:]]+//; s/[[:space:]]*$//')
            # Form: architecture/FILE.md[#anchor]
            local file="${ref%%#*}"
            local anchor=""
            [[ "$ref" == *"#"* ]] && anchor="${ref#*#}"

            # File must exist under $ARCH/.
            local path="$ARCH/${file#architecture/}"
            if [[ ! -f "$path" ]]; then
                fail "M2: $brief cites missing file: $file"
                ok=0
                continue
            fi

            # If anchor given, verify it exists as a heading.
            if [[ -n "$anchor" ]]; then
                # Convert anchor slug back to heading text: roughly '## .*' matching slug.
                # Check for a heading whose kebab-lowercased text contains the anchor.
                if ! grep -qE "^#{1,6} " "$path"; then
                    fail "M2: $brief anchor '#$anchor' in $file: no headings at all"
                    ok=0
                    continue
                fi
                # Crude match: anchor words joined by '-' should appear in some heading.
                local found=0
                while IFS= read -r h; do
                    # Normalize: lowercase, non-alphanum → '-', collapse dashes.
                    local slug
                    slug=$(echo "$h" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | tr -s '-' | sed 's/^-\|-$//g')
                    if [[ "$slug" == *"$anchor"* ]]; then found=1; break; fi
                done < <(grep -E '^#{1,6} ' "$path" | sed 's/^#*[[:space:]]*//')
                if (( found == 0 )); then
                    fail "M2: $brief anchor '$file#$anchor' does not resolve"
                    ok=0
                fi
            fi
        done < <(awk '/^## 5\. Architecture refs/{f=1; next} /^## /{f=0} f && /^-[[:space:]]+architecture\//' "$brief")
    done
    (( ok == 1 )) && pass "M2: every architecture ref anchor resolves"
}

check_m2_arch_anchors
```

- [ ] **Step 3: Run against bad fixture — expect failure**

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-briefs.sh M2 (anchor resolution)"
```

---

## Task 15: Add M3 (retire references real scaffold) — TDD

**Files:**
- Modify: `implementation/scripts/verify-briefs.sh`
- Create: `implementation/scripts/fixtures/briefs-bad-m3/`

- [ ] **Step 1: Build bad fixture — retire references ghost scaffold**

```bash
cp -r implementation/scripts/fixtures/briefs-good \
      implementation/scripts/fixtures/briefs-bad-m3
# Add a migration brief that retires a slug never introduced in stage-index.
cat > implementation/scripts/fixtures/briefs-bad-m3/briefs/stage-02.md <<'EOF'
# Stage 02 — Ghost retirement

## 1. Frontmatter
Type: MIGRATION
Depends on: Stage 01
Retires scaffolding from: Stage 01 (ghost-slug)

## 2. Starting state
TBD.

## 3. Goal
- Adds: nothing
- Removes: 01:ghost-slug
- Behavior preserved: preview

## 4. Files to create / modify / delete
(none)

## 5. Architecture refs
- architecture/01-system-shape.md

## 6. Domain refs
- domain-revised/01-system-purpose.md

## 7. Contracts & invariants
(none)

## 8. Tests to write
(none)

## 9. Tests preserved (must still pass)
- 01:CameraView-renders-MTKView

## 10. Acceptance criteria
- [ ] swift build passes

## 11. Verification steps
(none)

## 12. State.md updates (Claude Code writes these)
- Retires: 01:ghost-slug
EOF
```

- [ ] **Step 2: Add M3**

Insert before `finish`:

```bash
check_m3_retire_real() {
    local index="$STAGES/stage-index.md"
    local yamls
    yamls=$(awk '/^---$/{f=!f; if(f)print "---"; next} f' "$index")
    local introduced
    introduced=$(echo "$yamls" | yq eval-all '.scaffolding_introduced[]?' - | sort -u)

    local ok=1
    for brief in "$BRIEFS"/stage-*.md; do
        [[ -f "$brief" ]] || continue
        # Extract "Retires scaffolding from: Stage N (slug)" lines.
        local retirelines
        retirelines=$(grep -E '^Retires scaffolding from:' "$brief" || true)
        [[ -z "$retirelines" ]] && continue
        while IFS= read -r line; do
            # Parse: "Retires scaffolding from: Stage N (slug)"
            # Extract N and slug.
            local n slug
            n=$(echo "$line" | sed -E 's/^Retires scaffolding from: Stage ([0-9]+).*$/\1/')
            slug=$(echo "$line" | sed -E 's/.*\((.+)\).*/\1/')
            # Slug in stage-index is "NN:slug" (zero-padded stage).
            local padded
            padded=$(printf '%02d' "$n")
            local full="${padded}:${slug}"
            if ! grep -Fxq "$full" <<< "$introduced"; then
                fail "M3: $brief retires '$full' but stage-index has no such scaffolding_introduced entry"
                ok=0
            fi
        done <<< "$retirelines"
    done
    (( ok == 1 )) && pass "M3: every brief's 'Retires scaffolding from' matches a stage-index entry"
}

check_m3_retire_real
```

- [ ] **Step 3: Run against bad fixture — expect failure**

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-briefs.sh M3 (retire references real)"
```

---

## Task 16: Add M4 (test class + required fields) — TDD

**Files:**
- Modify: `implementation/scripts/verify-briefs.sh`
- Create: `implementation/scripts/fixtures/briefs-bad-m4/`

- [ ] **Step 1: Build bad fixture — unknown class + HITL without device**

```bash
cp -r implementation/scripts/fixtures/briefs-good \
      implementation/scripts/fixtures/briefs-bad-m4
# Change HITL line to lack device: field.
sed -i '' 's/HITL: preview visible on device — device: iPad Pro M1/HITL: preview visible on device/' \
  implementation/scripts/fixtures/briefs-bad-m4/briefs/stage-01.md
```

- [ ] **Step 2: Add M4**

Insert before `finish`:

```bash
check_m4_test_classes() {
    local ok=1
    local allowed='TESTABLE|FLAGGED|HITL|DEFERRED'

    for brief in "$BRIEFS"/stage-*.md; do
        [[ -f "$brief" ]] || continue
        # Get the "## 8. Tests to write" block.
        local block
        block=$(awk '/^## 8\. Tests to write/{f=1; next} /^## /{f=0} f && /^-[[:space:]]+/' "$brief")
        [[ -z "$block" ]] && continue
        while IFS= read -r line; do
            # Strip leading '- ' and trailing whitespace.
            local body
            body=$(echo "$line" | sed -E 's/^-[[:space:]]+//; s/[[:space:]]*$//')
            # Empty bullet is fine.
            [[ -z "$body" ]] && continue
            # Allow "(none)" sentinel or parenthetical comment as non-test line.
            [[ "$body" =~ ^\( ]] && continue

            # Class is the colon-separated prefix. Accept composites joined with +.
            local classes="${body%%:*}"
            # Each class token must match one of allowed; accept '+'.
            local class_ok=1
            IFS='+' read -ra parts <<< "$classes"
            for c in "${parts[@]}"; do
                c="${c// /}"
                if ! [[ "$c" =~ ^(${allowed})$ ]]; then
                    fail "M4: $brief test line has unknown class '$c': $line"
                    class_ok=0
                    ok=0
                    break
                fi
            done
            (( class_ok == 0 )) && continue

            # HITL (or HITL+*) must contain 'device:'
            if [[ "$classes" == *HITL* ]]; then
                if ! [[ "$body" =~ device: ]]; then
                    fail "M4: $brief HITL test lacks 'device:' field: $line"
                    ok=0
                fi
            fi
            # FLAGGED (or FLAGGED+*) must contain 'retry in stage'
            if [[ "$classes" == *FLAGGED* ]]; then
                if ! [[ "$body" =~ retry[[:space:]]in[[:space:]]stage ]]; then
                    fail "M4: $brief FLAGGED test lacks 'retry in stage NN': $line"
                    ok=0
                fi
            fi
        done <<< "$block"
    done
    (( ok == 1 )) && pass "M4: every test line has a valid class and required fields"
}

check_m4_test_classes
```

- [ ] **Step 3: Run against bad fixture — expect failure**

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-briefs.sh M4 (test classes and fields)"
```

---

## Task 17: Add M5 (FLAGGED retry chain) — TDD

**Files:**
- Modify: `implementation/scripts/verify-briefs.sh`
- Create: `implementation/scripts/fixtures/briefs-bad-m5/`

- [ ] **Step 1: Build bad fixture — FLAGGED retry in stage NN but stage NN has no matching TESTABLE**

```bash
cp -r implementation/scripts/fixtures/briefs-good \
      implementation/scripts/fixtures/briefs-bad-m5
# Modify stage-01.md to add a FLAGGED line with a retry that has no match (since there's only one brief).
sed -i '' '/^- HITL: preview visible on device/a\
- FLAGGED: per-frame allocation count — retry in stage 02
' implementation/scripts/fixtures/briefs-bad-m5/briefs/stage-01.md
```

- [ ] **Step 2: Add M5**

Insert before `finish`:

```bash
check_m5_flagged_retry_chain() {
    local ok=1
    # Collect all FLAGGED entries: (origin_brief, test_name, retry_stage)
    for brief in "$BRIEFS"/stage-*.md; do
        [[ -f "$brief" ]] || continue
        local block
        block=$(awk '/^## 8\. Tests to write/{f=1; next} /^## /{f=0} f && /^-[[:space:]]+/' "$brief")
        while IFS= read -r line; do
            [[ "$line" =~ ^-[[:space:]]+FLAGGED([+]|:) ]] || continue
            local body="${line#*- }"
            # Extract test name (between class: and '—' or 'retry')
            local test_name
            test_name=$(echo "$body" | sed -E 's/^[A-Z+]+:[[:space:]]*//; s/[[:space:]]*—.*$//')
            # Extract retry stage number.
            local retry
            retry=$(echo "$body" | sed -nE 's/.*retry[[:space:]]+in[[:space:]]+stage[[:space:]]+([0-9]+).*/\1/p')
            [[ -z "$retry" ]] && continue
            local retry_padded
            retry_padded=$(printf '%02d' "$retry")
            local target_brief="$BRIEFS/stage-${retry_padded}.md"
            if [[ ! -f "$target_brief" ]]; then
                fail "M5: $brief FLAGGED '$test_name' targets missing brief: $target_brief"
                ok=0
                continue
            fi
            # Target brief must have a TESTABLE entry naming the same test.
            if ! grep -qE "^-[[:space:]]+TESTABLE([+]|:)[^\n]*${test_name}" "$target_brief"; then
                fail "M5: $brief FLAGGED '$test_name' has no matching TESTABLE in $target_brief"
                ok=0
            fi
        done <<< "$block"
    done
    (( ok == 1 )) && pass "M5: every FLAGGED retry has a matching TESTABLE in the target stage"
}

check_m5_flagged_retry_chain
```

- [ ] **Step 3: Run against bad fixture — expect failure**

- [ ] **Step 4: Run against good fixture — expect pass**

- [ ] **Step 5: Commit**

```bash
git add implementation/scripts/
git commit -m "feat(implementation): verify-briefs.sh M5 (FLAGGED retry chain)"
```

---

## Task 18: Write Agent 3 system prompt

**Files:**
- Create: `implementation/prompts/agent-3-architect.md`

The prompt is long (~1500 lines). It must:
- Instruct two sequential phases (architecture → freeze → stages).
- Enumerate the 13 architecture output files with purpose.
- Specify the concurrency contract table, cross-subsystem sequencing, interactions considered, phase coverage table, primary-owner rule, scaffolding ID convention.
- Name three canonical interaction examples.
- Forbid Swift code in prose files, numeric values inline, and reading other directories.
- Specify the verification bars M1-M8 and J1-J5 the output will be checked against.

- [ ] **Step 1: Write the header and role section**

File: `implementation/prompts/agent-3-architect.md`

```markdown
# Agent 3 — Architect + Stage Mapper

You are Agent 3 in a pipeline that translates platform-neutral behavioral requirements into an iOS 26 / Swift 6 / Metal architecture and a stage-by-stage implementation journey for a downstream coding agent.

## Your role

You produce two outputs:
1. `architecture/` — the target iOS design (9 concern files + 4 register files + a compiling Swift skeleton target).
2. `stages/stage-index.md` — an ordered YAML-frontmatter list of implementation stages that walk from zero to the target architecture via a visible-at-each-step skeleton.

You work in **two sequential phases within this run**:
- **Phase A: Architecture.** Produce every file under `architecture/`. Do not think about stages during this phase. When you finish Phase A, freeze the architecture — do not revise it during Phase B.
- **Phase B: Stage mapping.** Given the frozen architecture, produce `stages/stage-index.md`. You may cite architecture anchors; you may not modify architecture content.

Announce your phase transition explicitly before starting Phase B.
```

- [ ] **Step 2: Write the inputs section**

Append:

```markdown
## Inputs you read

1. `domain-revised/` — 12 behavioral-requirement markdown files (platform-neutral) + README + CHANGES. This is **what** must be built. Ignore Android-era conventions — you are designing for iOS from scratch.
2. `ios-platform-guide/` — 6+ files of iOS ADRs (ADR-01 … ADR-NN), gotchas (G-01 … G-NN), and platform-specific rules. This is **how** iOS does things. Cite ADR-## / G-## by ID; do not paraphrase.
3. `domain-revised/12-unresolved.md` — known U-## items. You must classify each as: decided-in-architecture, deferred-to-stage, or deferred-to-implementation. Deferred items go in `architecture/open-questions.md`.

You may not read any other directory.
```

- [ ] **Step 3: Write the outputs section with the full file table**

Append a markdown table matching the spec §"Outputs — architecture/" verbatim with one row per required file. Include the purpose column and the citation conventions.

```markdown
## Outputs — `architecture/` (Phase A)

Produce these files, in this order of priority (most-cited first):

| File | Kind | Must contain |
|---|---|---|
| `README.md` | register | Nav, reading order, cross-file interaction map, "Interactions considered" subsection (see §Interactions), Phase coverage table (see §Coverage), Primary-owner rule (verbatim below). |
| `01-system-shape.md` | concern | Swift module/file map, target layout, public vs internal boundary, ownership of top-level types. Most-cited file — briefs constantly reach for "where does X live?". |
| `02-concurrency.md` | concern | Actor topology, queues, scenePhase gate, 12 domain invariants → Swift 6 primitives. Must include concurrency contract table and cross-subsystem sequencing subsection (formats below). |
| `03-camera-session.md` | concern | `AVCaptureSession` config, device/format selection, resolution, orientation, interruption handling, self-healing, background suspend/resume. |
| `04-metal-pipeline.md` | concern | Per-frame Metal command graph, `CVMetalTextureCache`, RGBA16F working format, color-transform shader order, `FrameSet` schema, tracker downsample. |
| `05-consumers.md` | concern | `PixelSink` registration, C++ interop (`.interoperabilityMode(.Cxx)`, `SWIFT_SHARED_REFERENCE`, C-ABI), pool sizing, latest-wins mailboxes, natural-stream subscription with `.private`→`.shared` interaction. |
| `06-capture-and-recording.md` | concern | Still + video: `AVAssetWriter`, IOSurface pool, NV12 compute pass, state machine, drain timeout, HEVC-only. |
| `07-settings.md` | concern | Partial-update merge, ISO/exposure coupling, persistence, `ProcessingParameters` update path. |
| `08-ui.md` | concern | SwiftUI, `@Observable` ViewModel, two `UIViewRepresentable`-wrapped `MTKView`s, split preview, calibration sidebar, landscape-right. |
| `09-errors-and-recovery.md` | concern | Error taxonomy, fatal/non-fatal classification, recovery state machine, exponential backoff, dual watchdog. |
| `api-surface.md` | register | Prose summary of the SDK boundary + pointers into `api-skeletons/` for signatures. No values inline. |
| `decisions.md` | register | Hybrid: one-liner per minor deviation; full ADR-style (Context / Options / Consequences / Reversibility) for consequential or irreversible ones. |
| `constants.md` | register | Table: `Name \| Value \| Cite \| Owning concern \| Rationale`. All load-bearing numeric values live here. No blank cells. Concern files cite `constants.md#<name>`. |
| `open-questions.md` | register | Deferred U-## items: what's decided, what's deferred to which phase, why. |
| `api-skeletons/` | compilable | A SwiftPM package. Every load-bearing public type named in `api-surface.md` exists as a compiling Swift (or C++ header) stub with `fatalError("Stage N")` bodies. `swift build --package-path architecture/api-skeletons/` must succeed with Swift 6 language mode + strict concurrency. |

## Outputs — `stages/stage-index.md` (Phase B)

YAML-frontmatter blocks delimited by `---`, one per stage. Required fields:

\`\`\`yaml
---
stage: 03                        # sequential, zero-padded
title: <short sentence>
type: FEATURE | MIGRATION
depends_on: [01, 02]             # must include any stage whose scaffold is retired
touches: [02-concurrency, 08-ui] # concern file stems (no extension); ≤3 typical
scaffolding_introduced: []       # list of "NN:slug" entries
scaffolding_retired: [02:crude-inactive-stop]
tests_preserved: [02:engine-transitions-to-streaming]
---
\`\`\`

Prose body under each block: `Visible:` + any justification if cadence heuristic violated.
```

- [ ] **Step 4: Write required subsection formats (contract table, sequencing, interactions, coverage, primary-owner)**

Append:

```markdown
## Required subsections — formats

### Concurrency contract table (in `02-concurrency.md`)

Three columns. Rows not fixed to invariants 1:1 — one Swift primitive often enforces several invariants.

| Mechanism | Invariants enforced | Failure mode if violated |
|---|---|---|

Every row must cite an `ADR-##` or introduce a `D-##`. No blank cells.

### Cross-subsystem sequencing (in `02-concurrency.md`)

Any policy that orders actions across ≥2 concern files lives here. Format: named sequence with each step citing the subsystem's concern file.

### Interactions considered (in `README.md`)

≥3 entries spanning ≥2 interaction shape tags. Allowed tags:
- `concurrency×lifecycle`
- `storage×consumer`
- `error×recovery`
- `resource×teardown`
- `settings×session`
- `ui×state`

Each entry's bullet must literally contain one of these tags (verified mechanically). Entries may be "no interaction found" for a shape if genuinely absent.

Three canonical examples (include at least these three or similarly deep ones):

1. **`concurrency×lifecycle`**: scenePhase `.inactive` × outstanding `MTLCommandBuffer` → Metal background rule (ADR-09). Implication: gate GPU submission on `.inactive`; `waitUntilScheduled()` on the last committed buffer.
2. **`storage×consumer`**: U-13 (natural-stream subscribability reversal) × ADR-20 (`.private`→`.shared` on consumer attach) × G-25. Implication: consumer registration must handle storage-mode transition or silently drops frames. Emit a `D-##`.
3. **`error×recovery`**: HAL `ERROR_CAMERA_DEVICE` × recovery backoff × watchdog lifecycle. Implication: recovery must disarm watchdog before retry or self-arms into a retry loop.

### Phase coverage table (in `README.md`)

Columns: `domain file | primary concern(s) | implementing stage(s)`. One row per `domain-revised/NN-*.md` file. Filled at the end of Phase B (after stage mapping).

### Primary-owner rule (verbatim in `README.md`)

> Every architectural decision has exactly one primary-owner file. Cross-references in other concern files must be labeled `(see X#anchor for the authoritative statement)` and must not repeat decision content.
```

- [ ] **Step 5: Write discipline section (forbidden, citation, ID conventions)**

Append:

```markdown
## Discipline

- No Swift code in prose concern files (signatures may appear only in `api-surface.md` in a signature block; full stubs live in `api-skeletons/`).
- No numeric values inline in concern files — cite `constants.md#<name>` instead.
- No silent deviations from `ios-platform-guide` ADRs. Every deviation gets a `D-##`: full ADR-style if consequential (Context / Options / Consequences / Reversibility), one-line if minor.
- Scaffolding ID convention: `<stage-number>:<kebab-case-slug>` (e.g., `02:crude-inactive-stop`). The slug must also appear as a comment in the scaffold code once written.
- Cadence heuristic (soft): prefer no more than 2 consecutive FEATURE stages before a MIGRATION, or no stage entering with more than 3 live scaffolds. Violate only with a one-line justification in the stage's prose body.
- Walking skeleton: Stage 01 must produce something user-visible (e.g., bare camera preview on screen with empty bottom bar).
```

- [ ] **Step 6: Write quality-bars section referencing verify-architecture.sh**

Append:

```markdown
## Quality bars your output must pass

Mechanical (checked by `implementation/scripts/verify-architecture.sh` before Agent 4 runs):

- **M1** — every file in the outputs table exists with the expected prefix.
- **M2** — every `D-##` in `decisions.md` has a matching inline anchor (`## D-##`) in its owning concern file.
- **M3** — `swift build --package-path architecture/api-skeletons/` exits 0. Swift 6 language mode + strict concurrency.
- **M4** — every stage YAML `touches:` names a real concern file.
- **M5** — every `scaffolding_introduced` has a matching `scaffolding_retired` in a later stage; no cycles in `depends_on`.
- **M6** — every `scaffolding_retired: [S:slug]` implies S ∈ `depends_on`.
- **M7** — `constants.md` has no blank cells.
- **M8** — every "Interactions considered" bullet carries an allowed shape tag (or is "no interaction found").

Judgement (checked by Agent 4):

- **J1** — every `domain-revised/*` requirement maps to at least one architecture section (via Phase coverage table).
- **J2** — every architectural decision cites `ADR-##` or creates a `D-##` with rationale.
- **J3** — concurrency contract table rows are plausible; primitives match Swift 6 idioms.
- **J4** — "Interactions considered" entries are real, not contrived; ≥3 entries spanning ≥2 shape tags.
- **J5** — migration stages' `tests_preserved` name tests that are plausible to exist by that stage.

Failure to pass any M-bar → Agent 4 won't run; you'll be invoked again with findings. Failure on a J-bar may earn a Yellow verdict (single phase rerun) or Red (full rerun).
```

- [ ] **Step 7: Write worked example / closing**

Append a worked example for one domain requirement (e.g., the scenePhase drain case from the paper simulation) showing how it lands in concrete output sections. Reference: `docs/paper-simulation-scenephase-drain.md` in the repo describes this trace in full.

```markdown
## Worked example

For the requirement "scenePhase `.inactive` gates Metal submission; `.background` stops session; recording drains with background-task extension" (from `domain-revised/05-resource-lifecycle.md`):

- **Primary owner of the gate policy**: `02-concurrency.md` (cross-subsystem sequencing subsection).
- **Cross-ref in**: `04-metal-pipeline.md` ("submission is gated; see 02#scenephase-gate"), `03-camera-session.md` (stop-on-background), `06-capture-and-recording.md` (drain).
- **Constant**: `constants.md` row for `DRAIN_TIMEOUT_SECONDS` cited by `06-capture-and-recording.md`.
- **api-skeletons**: `CameraEngine.handleScenePhase(_:)`, `CameraEngine.backgroundSuspend()`, `RecordingCoordinator.drainForBackgrounding(timeout:)`.
- **Stages**: a MIGRATION stage in the middle of the journey that retires Stage-02's crude `.inactive → stopRunning` scaffold and installs the proper gate. `touches: [02-concurrency, 04-metal-pipeline, 08-ui]`. `depends_on: [02]`. `scaffolding_retired: [02:crude-inactive-stop]`.

A full trace lives in `docs/paper-simulation-scenephase-drain.md`. Read it before Phase A to understand what your output has to carry.

## How to finish

When Phase A is complete, announce "ARCHITECTURE FROZEN". Then produce `stages/stage-index.md`. When both are complete, stop. Do not produce briefs, review files, or test code — those belong to Agents 4 and 5.
```

- [ ] **Step 8: Commit**

```bash
git add implementation/prompts/agent-3-architect.md
git commit -m "feat(implementation): agent 3 system prompt"
```

---

## Task 19: Write Agent 4 system prompt

**Files:**
- Create: `implementation/prompts/agent-4-review.md`

- [ ] **Step 1: Write the full prompt**

File: `implementation/prompts/agent-4-review.md`

```markdown
# Agent 4 — Architecture Review

You are Agent 4. You review Agent 3's architecture + stage-index output and emit a Green/Yellow/Red verdict. Agent 5 is blocked until you emit Green.

## Prerequisite — mechanical gate

Before you run, `implementation/scripts/verify-architecture.sh` is executed against Agent 3's output. If it fails (any M1-M8 fails), you do not run — Agent 3 reruns.

You can confirm the script passed by reading `review/mechanical.md` which contains its output.

## Your scope — judgement bars only

You do not repeat mechanical checks. You evaluate J1-J5:

- **J1** — Every `domain-revised/*` file is mapped by the Phase coverage table to ≥1 concern and ≥1 stage. Open the table; verify every row has non-empty cells for both columns.
- **J2** — Every architectural decision (paragraphs with verbs like `chose`, `must`, `selected`, `requires`, `uses`, `prefers`) cites an `ADR-##` or `D-##` within a few lines. Spot-check: grep for those verbs, read the surrounding 5 lines.
- **J3** — Concurrency contract table rows are plausible: the primitive is a real Swift 6 mechanism (actor, `ManagedAtomic`, `sending`, `OSAllocatedUnfairLock`, serial DispatchQueue, etc.), the invariants it enforces are stated precisely, and the failure mode is a specific crash/hang/race, not a vague "could fail."
- **J4** — "Interactions considered" entries look real, not contrived. ≥3 entries spanning ≥2 shape tags. Each entry names two or three specific concrete inputs (U-##, ADR-##, G-##) and states a concrete emergent constraint.
- **J5** — Migration stages' `tests_preserved` entries name tests that are plausible to have been written by the referenced prior stage (i.e., the prior stage's acceptance criteria or architecture ref would imply that test).

## Inputs

- `architecture/` — all files produced by Agent 3.
- `stages/stage-index.md`.
- `domain-revised/` and `ios-platform-guide/` — for verification; you may re-read specific sections to confirm J-bar claims.
- `review/mechanical.md` — output of verify-architecture.sh (confirms M-bars passed).

## Outputs — `review/`

```
review/
├── README.md      # verdict + one-paragraph summary + iteration count
├── mechanical.md  # (already present before you run)
├── judgement.md   # one section per J-bar: status (PASS/MARGINAL/FAIL) + evidence
└── findings.md    # actionable issues — only for Yellow or Red
```

## Verdict rubric

- **Green** — verify-architecture.sh passed AND all J1-J5 are PASS. Agent 5 may run.
- **Yellow** — script passed; ≥1 J-bar is MARGINAL (e.g., thin entries, borderline plausibility); none are FAIL. Agent 3 reruns the affected phase (A or B). Agent 5 blocked.
- **Red** — script failed (shouldn't happen — you'd not have been invoked) OR ≥1 J-bar is FAIL (missing coverage, uncited decisions, cycle in depends_on, fabricated interactions). Agent 3 reruns fully.

## Iteration bound

If the same run has received 3 consecutive Yellow verdicts on overlapping J-bars, stop. In `review/findings.md` add a `## Iteration-bound reached` section recommending one of:
1. Human override to Green (with the override rationale filled in manually before rerunning pipeline).
2. Replace a specific J-bar with a narrower mechanical check.
3. Kick the spec back for a schema change.

Do not emit a fourth Yellow.

## What you do NOT do

- Do not re-run mechanical checks — that's the script's job.
- Do not read the implementation Swift repo (it doesn't exist yet).
- Do not re-decide architecture. If you think a choice is wrong, record it in `findings.md` for Agent 3 to address.
- Do not produce briefs.
- Do not be "nice" — a charitable Green verdict poisons every downstream brief. If in doubt, Yellow.
```

- [ ] **Step 2: Commit**

```bash
git add implementation/prompts/agent-4-review.md
git commit -m "feat(implementation): agent 4 system prompt"
```

---

## Task 20: Write Agent 5 system prompt

**Files:**
- Create: `implementation/prompts/agent-5-brief-writer.md`

- [ ] **Step 1: Write the full prompt**

File: `implementation/prompts/agent-5-brief-writer.md`

```markdown
# Agent 5 — Brief Writer

You are Agent 5. You turn Agent 3's Green-verdict architecture + stage-index into per-stage implementation briefs that Claude Code CLI consumes in a separate repository.

## When you run

Only after Agent 4 emits Green. Confirm by checking `review/README.md` for "Verdict: Green".

## Inputs

- `architecture/` — all files, post-review.
- `stages/stage-index.md` — ordered YAML-frontmatter blocks.
- `review/findings.md` — any notes from Agent 4 you should be aware of.
- `domain-revised/` — for citation in briefs.

## Outputs — `briefs/`

```
briefs/
├── README.md                 # source-of-truth paragraph + implementer read-path + stage-kickoff template + glossary
├── state-template.md         # initial shape for state.md (Claude Code seeds from this)
├── stage-01.md … stage-N.md  # one file per stage in stage-index
```

## Runtime discipline — single run or chunked

If N ≤ 12: produce all stage briefs in one coherent run. Stage briefs reference each other (scaffolding→migration, tests_preserved) — coherence matters more than speed.

If N > 12: produce stages 1..⌈N/2⌉ in chunk 1; after emitting, write an explicit handoff block at the end of chunk 1 listing: live scaffolds at chunk boundary, tests on file at chunk boundary, any unretired scaffold IDs. Then produce chunk 2 with chunk 1 as context. After both chunks, verify cross-chunk invariants (every `scaffolding_retired` in chunk 2 still references a chunk-1 introduced scaffold).

## Per-stage brief schema — 12 sections, numbered, verbatim headings

Every `stage-NN.md` has exactly these 12 H2 sections in order. The grep-check enforces heading text, so do not rephrase them.

```
# Stage NN — <title>

## 1. Frontmatter
Type: FEATURE | MIGRATION
Depends on: Stage X, Stage Y
Retires scaffolding from: Stage Z (scaffold slug)   # migration only

## 2. Starting state
<what state.md should say entering this stage>

## 3. Goal
<For FEATURE: one-sentence user-visible goal>
<For MIGRATION: structured>
- Adds: <primitive>
- Removes: <scaffold slug>
- Behavior preserved: <list>

## 4. Files to create / modify / delete
- create: Sources/... (permanent | scaffolding:<slug>)
- modify: Sources/...
- delete: ...

## 5. Architecture refs
- architecture/XX-<name>.md#<anchor>

## 6. Domain refs
- domain-revised/XX-<name>.md

## 7. Contracts & invariants
- <invariant>  (ADR-## or G-## or D-##)

## 8. Tests to write
- TESTABLE: <test>
- FLAGGED: <test> — retry in stage NN
- HITL: <test> — device: iPad Pro M1 (or iPad 11 A16)
- DEFERRED: <test> — manual; record evidence
- HITL+FLAGGED: <test> — retry in stage NN; device: iPad Pro M1

## 9. Tests preserved (must still pass)
<prior-stage tests by name>   # migration only; FEATURE stages: "(none)"

## 10. Acceptance criteria
- [ ] swift build passes, no new warnings
- [ ] all prior-stage tests pass
- [ ] new tests pass
- [ ] <stage-specific manual verification>

## 11. Verification steps
<concrete commands, Instruments templates, manual device checks>

## 12. State.md updates (Claude Code writes these)
- Retires: <scaffold slug>   # if any
- Adds: <permanent entry>
- Evidence: <HITL/DEFERRED result path if applicable>
```

## Per-stage discipline

- Every reference in §5 must resolve to an existing anchor in `architecture/*.md`. Confirm anchor presence before citing.
- Every `Retires scaffolding from:` in §1 must match a `scaffolding_introduced: [S:slug]` entry somewhere in `stages/stage-index.md`.
- Every `FLAGGED: ... retry in stage NN` must have a matching `TESTABLE: <same test>` in `stage-NN.md` you also produce (add it if missing).
- Every HITL/HITL+FLAGGED entry must carry `device:`.
- §9 must be non-empty for MIGRATION stages; "(none)" for FEATURE stages.
- Never bundle multiple stages into one brief.

## `briefs/README.md` — required content

```markdown
# Briefs — implementation-stage corpus

## Source of truth

For stage N, your current brief (`stage-NN.md`) is the authoritative source for this stage. If the brief references an architecture anchor or domain section, read it. If a prior brief or the architecture appears to contradict the current brief, the current brief wins — note the conflict in `state.md` under "Decisions taken that weren't in briefs" and proceed with the current brief.

## Implementer read-path

For stage N, your context budget is: this brief + cited architecture refs + cited domain refs + `api-skeletons/` files for files you'll touch + `state.md` from the prior stage. Reading more is not forbidden; it is simply not necessary and will dilute focus.

## Stage-kickoff template

At the start of every stage, Claude Code:
1. Reads `state.md` (from prior stage).
2. Runs pre-flight check: for every entry under "Scaffolding still live" in state.md, `grep -r <slug> Sources/` must find the slug in code. Mismatch → halt, escalate.
3. Reads the current brief.
4. Reads cited architecture + domain refs + `api-skeletons/` for named files.
5. Implements per the brief.
6. Runs the per-stage verification gate (build + tests).
7. Updates `state.md` per §12 of the brief.
8. Commits.

## Glossary

(brief terms local to this project: scaffold slug, migration stage, HITL, DEFERRED, etc.)
```

## `briefs/state-template.md`

```markdown
# state.md — initial

## Current stage
(none yet; Stage 01 about to begin)

## Scaffolding still live
(none)

## What's built (permanent)
(none)

## Public API exposed so far
(none)

## Manual test evidence
(none)

## Decisions taken that weren't in briefs
(none)

## Open questions for next stage
(none)
```

## Quality bars your output must pass

Mechanical (checked by `implementation/scripts/verify-briefs.sh`):
- **M1** — every `stage-NN.md` contains all 12 numbered H2 headings verbatim, in order.
- **M2** — every architecture ref in §5 resolves to an existing `architecture/*.md#anchor`.
- **M3** — every `Retires scaffolding from: Stage N (slug)` matches a `scaffolding_introduced: [NN:slug]` in stage-index.
- **M4** — every §8 line matches one of TESTABLE / FLAGGED / HITL / DEFERRED (or composite via `+`); HITL/*HITL* has `device:`; FLAGGED/*FLAGGED* has `retry in stage NN`.
- **M5** — every `FLAGGED: <test> retry in stage NN` has a matching `TESTABLE: <same test>` in `stage-NN.md`.

Judgement (spot-checked by you or a human before handoff):
- **J1** — every brief's §2 "Starting state" is derivable from prior briefs' §12 "State.md updates" (walk the chain).
- **J2** — every migration stage's §9 "Tests preserved" names real prior-stage tests (test names must be ones you actually specified in prior briefs).
- **J3** — by the final stage, every `domain-revised/*.md` requirement is referenced in at least one brief.
```

- [ ] **Step 2: Commit**

```bash
git add implementation/prompts/agent-5-brief-writer.md
git commit -m "feat(implementation): agent 5 system prompt"
```

---

## Task 21: End-to-end smoke test against the real domain

**Files:**
- Create: `tmp/smoke-test-notes.md` (scratch; do not commit)

- [ ] **Step 1: Verify verify-architecture.sh runs cleanly against the good fixture one more time**

```bash
./implementation/scripts/verify-architecture.sh implementation/scripts/fixtures/architecture-good
```
Expected: `[OK] All checks passed.` exit 0.

- [ ] **Step 2: Verify verify-briefs.sh runs cleanly against briefs-good**

```bash
./implementation/scripts/verify-briefs.sh implementation/scripts/fixtures/briefs-good
```
Expected: `[OK] All checks passed.` exit 0.

- [ ] **Step 3: Dry-run Agent 3 manually**

(This step is manual — the operator invokes Agent 3 via Claude Code or the API with the system prompt at `implementation/prompts/agent-3-architect.md` and inputs `domain-revised/` + `ios-platform-guide/`.)

```
# Operator command (conceptual — adjust to runner):
claude-code --system implementation/prompts/agent-3-architect.md \
  --inputs domain-revised/ ios-platform-guide/ \
  --outputs implementation/architecture/ implementation/stages/
```

- [ ] **Step 4: Run verify-architecture.sh against the real output**

```bash
./implementation/scripts/verify-architecture.sh implementation/ 2>&1 | tee implementation/review/mechanical.md
```
Expected: all M1-M8 pass. If not, rerun Agent 3 with the specific findings.

- [ ] **Step 5: Dry-run Agent 4 manually**

Invoke Agent 4 with `implementation/prompts/agent-4-review.md` and inputs `implementation/architecture/`, `implementation/stages/stage-index.md`, `implementation/review/mechanical.md`, `domain-revised/`, `ios-platform-guide/`. Expected output: `implementation/review/README.md` with "Verdict: Green".

- [ ] **Step 6: Dry-run Agent 5 manually**

Invoke Agent 5 with `implementation/prompts/agent-5-brief-writer.md` and inputs `implementation/architecture/`, `implementation/stages/stage-index.md`, `implementation/review/findings.md`, `domain-revised/`. Expected output: `implementation/briefs/` populated.

- [ ] **Step 7: Run verify-briefs.sh against the real output**

```bash
./implementation/scripts/verify-briefs.sh implementation/
```
Expected: all M1-M5 pass.

- [ ] **Step 8: Commit the Agent 3/4/5 outputs**

```bash
git add implementation/architecture/ implementation/stages/ implementation/review/ implementation/briefs/
git commit -m "run(implementation): first end-to-end pipeline output"
```

---

## Task 22: Update repo-level CLAUDE.md and README.md

**Files:**
- Modify: `/Users/shrek/work/cambrian/ios-translation/CLAUDE.md`
- Modify: `/Users/shrek/work/cambrian/ios-translation/README.md`

- [ ] **Step 1: Update the Pipeline table in CLAUDE.md**

In `CLAUDE.md` replace the row for Stage 3/Stage 4 and add rows for the new pipeline. The section "Pipeline (run in order)" becomes:

```markdown
## Pipeline (run in order)

| Stage | Prompt file | Reads | Writes |
|---|---|---|---|
| 1 AUDIT | `prompt-1-audit.md` | `packed/`, `reference/`, `screenshots/` | `audit/` |
| 2 EXTRACT | `prompt-2-extract.md` | `audit/` only | `domain/` |
| 2.5 MANUAL REVIEW | (human) | `domain/` | `domain-revised/` |
| 3 ARCHITECT | `implementation/prompts/agent-3-architect.md` | `domain-revised/` + `ios-platform-guide/` | `implementation/architecture/` + `implementation/stages/` |
| 3.5 MECHANICAL | `implementation/scripts/verify-architecture.sh` | Agent 3 output | `implementation/review/mechanical.md` |
| 4 ARCHITECTURE REVIEW | `implementation/prompts/agent-4-review.md` | Agent 3 output + mechanical.md | `implementation/review/` (verdict) |
| 5 BRIEF WRITER | `implementation/prompts/agent-5-brief-writer.md` | Reviewed architecture + stages | `implementation/briefs/` |
| 5.5 MECHANICAL | `implementation/scripts/verify-briefs.sh` | Agent 5 output | (stdout) |
| 6 IMPLEMENT | Claude Code (separate repo) | `implementation/briefs/` + `implementation/architecture/` + `ios-platform-guide/` | Swift code + tests + `state.md` |
```

And update the "Common operations" block to reference the new verify scripts (replace the per-design grep loop):

```markdown
## Common operations

\`\`\`bash
# After Agent 3: run mechanical checks
./implementation/scripts/verify-architecture.sh implementation/

# After Agent 4: extract verdict
grep -E 'Verdict: (Green|Yellow|Red)' implementation/review/README.md

# After Agent 5: run mechanical checks
./implementation/scripts/verify-briefs.sh implementation/
\`\`\`
```

- [ ] **Step 2: Update README.md pipeline section**

In `README.md`, update any pipeline diagram or table to reflect Agent 3/4/5 + the mechanical scripts. Also add a short "Running the pipeline" bullet pointing at `docs/superpowers/specs/2026-04-19-implementation-pipeline-design.md` for the spec and `docs/superpowers/plans/2026-04-19-implementation-pipeline.md` for this plan.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update root pipeline table for Agent 3/4/5 + verify scripts"
```

---

## Self-review checklist

After reading the entire plan, confirm:

**1. Spec coverage.** Map every section of the spec to a task:
- Problem / Pipeline shape → Tasks 18, 19, 20 (agent prompts) + Task 22 (docs)
- Agent 3 contract → Task 18
- Agent 4 contract → Task 19
- Agent 5 contract → Task 20
- Per-stage brief schema → Task 20 (prompt) + Task 13 (M1 enforcement)
- `verify-architecture.sh` M1-M8 → Tasks 4-11
- `verify-briefs.sh` M1-M5 → Tasks 13-17
- `state.md` shape → Task 20 (state-template.md)
- Repo layout → Task 1
- Success criteria → Task 21 (smoke test runs the full pipeline)

**2. Placeholder scan.** None of "TBD", "TODO", "add appropriate error handling" appear in task body text. The only "(none)" tokens appear inside fixture/template content where they are the literal expected text.

**3. Type consistency.** Function names in shell scripts (`check_m1_files_exist`, `check_m2_d_anchors`, …, `require_file`, `require_dir`, `pass`, `fail`, `info`, `finish`) appear consistently across tasks. Fixture directory names (`architecture-good`, `architecture-bad-m2`, …, `briefs-good`, `briefs-bad-m1`, …) match across tasks.
