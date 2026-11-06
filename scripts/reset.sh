#!/usr/bin/env bash
# WIZP Reset — Reset the VSCode upstream working directory
# Inspired by MrCode's reset.sh
#
# Usage:
#   ./scripts/reset.sh
#
# Resets vscode-upstream/ to its clean upstream state, discarding all
# local modifications (applied patches, build artifacts, etc.)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"
VSCODE_DIR="$WIZP_DIR/vscode-upstream"

if [ -d "$VSCODE_DIR" ]; then
    cd "$VSCODE_DIR"

    echo "Resetting $VSCODE_DIR to clean upstream state..."
    git add .
    git reset --hard HEAD

    # Clean untracked files that patch/build process may have created
    rm -rf out/ 2>/dev/null || true
    rm -rf out-build/ 2>/dev/null || true
    rm -rf out-vscode/ 2>/dev/null || true
    rm -rf .build/ 2>/dev/null || true
    rm -rf VSCode-*/ 2>/dev/null || true

    echo "Done. vscode-upstream/ is clean."

    cd ..
else
    echo "vscode-upstream/ not found. Run './scripts/get_upstream.sh' first."
fi
