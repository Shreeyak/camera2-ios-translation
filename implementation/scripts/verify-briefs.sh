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
                    slug=$(echo "$h" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | tr -s '-' | sed -E 's/(^-|-$)//g')
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

finish
