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

# M3-M8 added in subsequent tasks

finish
