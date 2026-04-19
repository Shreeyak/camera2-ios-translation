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

finish
