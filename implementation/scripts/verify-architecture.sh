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
    # Filter out '---' multi-doc separators yq emits between documents
    # (same workaround used below for the depends_on graph).
    local introduced retired
    introduced=$(echo "$yamls" | yq eval-all '.scaffolding_introduced[]?' - | grep -v '^---$' | sort -u)
    retired=$(echo "$yamls" | yq eval-all '.scaffolding_retired[]?' - | grep -v '^---$' | sort -u)

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
    # Filter out '---' multi-doc separators yq emits between documents.
    if [[ -n "$edges" ]]; then
        if ! echo "$edges" | grep -v '^---$' | tr ',' ' ' | tsort >/dev/null 2>&1; then
            fail "M5: depends_on graph has a cycle"
            ok=0
        fi
    fi

    (( ok == 1 )) && pass "M5: scaffolding pairs balanced and no depends_on cycles"
}

check_m5_scaffolding_pairs

check_m6_retire_implies_depends() {
    local index="$STAGES/stage-index.md"
    local yamls
    yamls=$(awk '/^---$/{f=!f; if(f)print "---"; next} f' "$index")

    # Extract three parallel streams, filtering yq multi-doc '---' separators.
    # paste(1) zips them back into "stage|depends_joined|retired_joined" rows.
    local stages depends_col retired_col
    stages=$(echo "$yamls"    | yq eval-all '.stage'                           - | grep -v '^---$')
    depends_col=$(echo "$yamls" | yq eval-all '.depends_on // [] | join(",")' - | grep -v '^---$')
    retired_col=$(echo "$yamls" | yq eval-all '.scaffolding_retired // [] | join(",")' - | grep -v '^---$')

    local ok=1
    # For every stage, each retired slug's source stage (S) must appear in depends_on.
    # Slug format: "S:slug". Extract S and verify.
    while IFS='|' read -r stage depends retired; do
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
    done < <(paste -d'|' <(echo "$stages") <(echo "$depends_col") <(echo "$retired_col"))

    (( ok == 1 )) && pass "M6: every retired scaffold's source stage is in depends_on"
}

check_m6_retire_implies_depends

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

finish
