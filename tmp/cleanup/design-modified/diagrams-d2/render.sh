#!/usr/bin/env bash
# Re-render all D2 diagrams in this directory to SVG + PNG.
#
# Prerequisites:
#   brew install d2
#
# Usage:
#   ./render.sh              # renders all .d2 files
#   ./render.sh svg          # SVG only (fast, no Playwright)
#   ./render.sh 03           # only files matching "03*"
#
# Notes:
# - SVG is D2's native output and is small + scalable.
# - PNG rendering uses an embedded headless Chromium (downloaded on first use,
#   cached in ~/Library/Caches/ms-playwright/).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

MODE="${1:-all}"
FILTER="${2:-}"

# Interpret first arg as filter if it isn't a mode keyword
case "$MODE" in
  all|svg|png) ;;
  *) FILTER="$MODE"; MODE="all" ;;
esac

PATTERN="${FILTER}*.d2"
if [ -z "$FILTER" ]; then
  PATTERN="*.d2"
fi

echo "==> Rendering $PATTERN ($MODE)"
for f in $PATTERN; do
  [ -e "$f" ] || continue
  base="${f%.d2}"
  case "$MODE" in
    svg)
      d2 "$f" "${base}.svg" 2>&1 | tail -1
      ;;
    png)
      d2 "$f" "${base}.png" 2>&1 | tail -1
      ;;
    all)
      d2 "$f" "${base}.svg" 2>&1 | tail -1
      d2 "$f" "${base}.png" 2>&1 | tail -1
      ;;
  esac
done

echo ""
echo "==> Done."
ls -1 *.svg *.png 2>/dev/null | sort
