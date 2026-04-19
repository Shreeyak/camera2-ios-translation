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
