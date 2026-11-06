#!/usr/bin/env bash
# WIZP Full Build — One-command build: upstream → patches → zig build → vsix
# Inspired by MrCode's dev/build.sh
#
# Usage:
#   ./scripts/build.sh              # Full build
#   ./scripts/build.sh --skip-vsix  # Skip VSIX packaging
#   ./scripts/build.sh --release    # ReleaseSafe build
#   VSCODE_REF=v1.99.0 ./scripts/build.sh  # Use specific VSCode version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"

. "$SCRIPT_DIR/get_upstream.sh"

echo ""
echo "=== Building WIZP ==="

BUILD_MODE="ReleaseSafe"
ZIG_FLAGS="build -Doptimize=ReleaseSafe"

if [[ "${1:-}" == "--debug" ]]; then
    ZIG_FLAGS="build"
    shift
fi

cd "$WIZP_DIR"
echo "Running: zig $ZIG_FLAGS"
zig $ZIG_FLAGS

echo "Build complete: zig-out/bin/wizp"

echo ""
echo "=== Bundling Monaco Editor ==="
MONACO_SRC="$WIZP_DIR/monaco-upstream/node_modules/monaco-editor/min/vs"
MONACO_DST="$WIZP_DIR/zig-out/monaco-vs"
if [ -d "$MONACO_SRC" ]; then
    rm -rf "$MONACO_DST" 2>/dev/null || true
    cp -r "$MONACO_SRC" "$MONACO_DST"
    echo "Monaco editor bundled: $MONACO_DST ($(du -sh "$MONACO_DST" | cut -f1))"
else
    echo "WARNING: Monaco editor not found at $MONACO_SRC"
    echo "Run './scripts/get_upstream.sh' first, or the editor will fall back to CDN."
fi

if [[ "${1:-}" != "--skip-vsix" ]]; then
    echo ""
    echo "=== Building VSIX Extension ==="
    if [ -f "$WIZP_DIR/extension/build-vsix.sh" ]; then
        bash "$WIZP_DIR/extension/build-vsix.sh"
        echo "VSIX built: extension/*.vsix"
    else
        echo "VSIX build script not found, skipping."
    fi
fi

echo ""
echo "=== WIZP Build Complete ==="
echo "Binary:  zig-out/bin/wizp"
echo "VSIX:    extension/wizp-editor-*.vsix (if built)"
