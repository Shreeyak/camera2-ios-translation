#!/usr/bin/env bash
# Regenerate all diagram PNGs from the master markdown file.
#
# Prerequisites:
#   npm install -g @mermaid-js/mermaid-cli
#
# Usage:
#   ./render.sh
#
# The script runs extract.py to refresh .mmd files from the source markdown,
# then renders each .mmd to a PNG at 2x scale with a white background.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "==> Extracting mermaid blocks from source markdown..."
python3 extract.py

echo ""
echo "==> Rendering each .mmd to .png..."
for f in *.mmd; do
    base="${f%.mmd}"
    echo "  -> $base.png"
    mmdc -i "$f" -o "${base}.png" -b white -s 2 2>&1 \
        | grep -vE 'Rosetta|Degraded performance|Launching Chrome|version of Node|result in huge|warning:' \
        || true
done

echo ""
echo "==> Done. PNGs:"
ls -1 *.png
