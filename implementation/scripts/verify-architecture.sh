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
        [[ "$stem" == "---" ]] && continue  # yq multi-doc separator, not a value
        if ! [[ "$stem" =~ ^(${valid_re})$ ]]; then
            fail "M4: stage touches unknown concern file: $stem"
            ok=0
        fi
    done < <(echo "$yamls" | yq eval-all '.touches[]' -)

    (( ok == 1 )) && pass "M4: every stage touches: entry is a valid concern file"
}

check_m4_touches_valid

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

# M6-M8 added in subsequent tasks

finish
