#!/usr/bin/env bash
# WIZP Update Upstream Tracking — Update upstream/vscode.json with current
# VSCode version info after a successful build.
# Inspired by MrCode's update_upstream.sh
#
# Usage:
#   ./scripts/update_upstream_tracking.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"
VSCODE_DIR="$WIZP_DIR/vscode-upstream"
UPSTREAM_JSON="$WIZP_DIR/upstream/vscode.json"

if [ ! -d "$VSCODE_DIR" ]; then
    echo "ERROR: VSCode upstream not found at $VSCODE_DIR"
    echo "Run './scripts/get_upstream.sh' first."
    exit 1
fi

cd "$VSCODE_DIR"

VSCODE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
VSCODE_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "detached-${VSCODE_COMMIT:0:7}")

cd "$WIZP_DIR"

MONACO_VERSION="0.52.2"
if [ -f "$UPSTREAM_JSON" ]; then
    EXISTING_MONACO=$(jq -r '.monaco_version // "0.52.2"' "$UPSTREAM_JSON")
    MONACO_VERSION="$EXISTING_MONACO"
fi

mkdir -p "$(dirname "$UPSTREAM_JSON")"

jq -n \
    --arg tag "$VSCODE_TAG" \
    --arg commit "$VSCODE_COMMIT" \
    --arg monaco "$MONACO_VERSION" \
    --arg date "$(date -u +%Y-%m-%d)" \
    '{tag: $tag, commit: $commit, monaco_version: $monaco, date: $date}' \
    > "$UPSTREAM_JSON"

echo "Upstream tracking updated: $UPSTREAM_JSON"
echo "VSCode: $VSCODE_TAG ($VSCODE_COMMIT)"
echo "Monaco: $MONACO_VERSION"
echo "Date:   $(date -u +%Y-%m-%d)"
