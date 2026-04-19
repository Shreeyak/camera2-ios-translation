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
