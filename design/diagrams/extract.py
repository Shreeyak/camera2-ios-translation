#!/usr/bin/env python3
"""
Extract mermaid code blocks from ../09-architecture-diagrams.md into individual .mmd files.

Usage:
    python3 design/diagrams/extract.py

The block order in the markdown file MUST match the NAMES list below.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "09-architecture-diagrams.md"))
OUT_DIR = HERE

# Diagram names in order of appearance in the markdown file. Keep this list in sync
# with the Contents section of 09-architecture-diagrams.md.
NAMES = [
    "01-system-context",
    "02-actor-topology",
    "03-frame-data-flow",
    "04-metal-pipeline-internals",
    "05-error-propagation",
    "06-hot-path-capture-to-display",
    "07-consumer-fanout-1slot-mailbox",
    "08-gpu-to-encoder-zero-copy",
    "09-actor-reentrancy-guard",
    "10-still-capture-in-flight-guard",
]


def main() -> int:
    with open(SRC, "r") as f:
        content = f.read()

    blocks = re.findall(r"```mermaid\n(.*?)\n```", content, re.DOTALL)
    print(f"Found {len(blocks)} mermaid blocks in {SRC}")

    if len(blocks) != len(NAMES):
        print(
            f"ERROR: expected {len(NAMES)} blocks, got {len(blocks)}. "
            "Did you add or remove a diagram? Update the NAMES list."
        )
        return 1

    for name, block in zip(NAMES, blocks):
        out_path = os.path.join(OUT_DIR, f"{name}.mmd")
        with open(out_path, "w") as f:
            f.write(block + "\n")
        print(f"  wrote {out_path} ({len(block)} chars)")

    print(f"\n{len(blocks)} files written to {OUT_DIR}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
