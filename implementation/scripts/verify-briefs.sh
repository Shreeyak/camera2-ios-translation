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
