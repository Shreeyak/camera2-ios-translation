#!/bin/bash
# iOS Translation — Setup Script
# Run this before using Prompt 1 (Cartographer)
#
# Prerequisites:
#   - npm installed (for repomix)
#   - Take screenshots of every app screen/state and place in screenshots/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_REPO="/Users/shrek/work/cambrian/camera2_flutter_demo"

echo "=== iOS Translation Setup ==="
echo "Working directory: $SCRIPT_DIR"
echo "Source repo: $SOURCE_REPO"
echo ""

# Check source repo exists
if [ ! -d "$SOURCE_REPO" ]; then
    echo "ERROR: Source repo not found at $SOURCE_REPO"
    exit 1
fi

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$SCRIPT_DIR"/{packed,screenshots,reference,reference/plans,output,design}
mkdir -p "$SCRIPT_DIR"/output/{03-inventory,04-architecture-maps,05-translation-cards}

# Install repomix if not present
if ! command -v repomix &> /dev/null; then
    echo "Installing repomix..."
    npm install -g repomix
fi

echo ""
echo "=== Packing codebase layers with repomix ==="
cd "$SOURCE_REPO"


# Full Kotlin source for behavioral analysis
echo "Packing Kotlin layer (full)..."
repomix --include "packages/*/android/**/*.kt,android/**/*.kt" \
    --ignore "build/**" --ignore "build-test/**" --ignore ".gradle/**" \
    --output "$SCRIPT_DIR/packed/kotlin-full.xml" 2>/dev/null || \
repomix --include "packages/*/android/**/*.kt" --include "android/**/*.kt" \
    --ignore "build/**" --ignore "build-test/**" --ignore ".gradle/**" \
    --output "$SCRIPT_DIR/packed/kotlin-full.xml"

# Full C++ source
echo "Packing C++ layer (full)..."
repomix --include "**/*.cpp,**/*.h" \
    --ignore "build/**" --ignore "build-test/**" \
    --output "$SCRIPT_DIR/packed/cpp-full.xml" 2>/dev/null || \
repomix --include "**/*.cpp" --include "**/*.h" \
    --ignore "build/**" --ignore "build-test/**" \
    --output "$SCRIPT_DIR/packed/cpp-full.xml"

# Full shader source
echo "Packing shader layer (full)..."
repomix --include "**/*.glsl" \
    --output "$SCRIPT_DIR/packed/shaders-full.xml" 2>/dev/null || \
echo "  (no .glsl files found — check for inline shaders in Kotlin/C++)"

# Pigeon definitions
echo "Packing Pigeon definitions..."
repomix --include "**/pigeon/**/*.dart,**/pigeons/**/*.dart" \
    --output "$SCRIPT_DIR/packed/pigeon-definitions.xml" 2>/dev/null || \
repomix --include "**/pigeon/**/*.dart" --include "**/pigeons/**/*.dart" \
    --output "$SCRIPT_DIR/packed/pigeon-definitions.xml"

# Dart plugin API (compressed)
echo "Packing Dart plugin API (compressed)..."
repomix --compress --include "packages/*/lib/**/*.dart" \
    --ignore ".dart_tool/**" --ignore "build/**" --ignore "build-test/**" \
    --ignore "*.g.dart" --ignore "*.mocks.dart" \
    --output "$SCRIPT_DIR/packed/dart-plugin-compressed.xml"

# Dart app layer (compressed)
echo "Packing Dart app layer (compressed)..."
repomix --compress --include "lib/**/*.dart" \
    --ignore ".dart_tool/**" --ignore "build/**" --ignore "build-test/**" \
     --ignore "*.g.dart" --ignore "*.mocks.dart" \
    --output "$SCRIPT_DIR/packed/dart-app-compressed.xml"

# Build configuration
echo "Packing build configuration..."
repomix --include "**/build.gradle*,**/CMakeLists.txt,pubspec.yaml,**/AndroidManifest.xml" \
    --ignore "build/**" --ignore "build-test/**" \
    --output "$SCRIPT_DIR/packed/build-config.xml" 2>/dev/null || \
repomix --include "**/build.gradle*" --include "**/CMakeLists.txt" --include "pubspec.yaml" --include "**/AndroidManifest.xml" \
    --ignore "build/**" --ignore "build-test/**" \
    --output "$SCRIPT_DIR/packed/build-config.xml"

echo ""
echo "=== Copying reference docs ==="
cp -f "$SOURCE_REPO/docs/architecture.md" "$SCRIPT_DIR/reference/" 2>/dev/null || echo "  docs/architecture.md not found"
cp -f "$SOURCE_REPO/docs/usage-guide.md" "$SCRIPT_DIR/reference/" 2>/dev/null || echo "  docs/usage-guide.md not found"
cp -f "$SOURCE_REPO/CLAUDE.md" "$SCRIPT_DIR/reference/" 2>/dev/null || echo "  CLAUDE.md not found"
cp -rf "$SOURCE_REPO/docs/plans/" "$SCRIPT_DIR/reference/plans/" 2>/dev/null || echo "  docs/plans/ not found"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Directory structure:"
find "$SCRIPT_DIR" -maxdepth 3 -type d | sed "s|$SCRIPT_DIR|.|g" | sort
echo ""
echo "Packed files:"
ls -lh "$SCRIPT_DIR/packed/" 2>/dev/null || echo "  (none)"
echo ""
echo "Next steps:"
echo "  1. Take screenshots of every app screen/state"
echo "  2. Place screenshots in: $SCRIPT_DIR/screenshots/"
echo "     Name them descriptively: preview-streaming.png, camera-controls.png, etc."
echo "  3. Run Prompt 1 (Cartographer) with working directory: $SCRIPT_DIR"
echo ""
