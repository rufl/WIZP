#!/usr/bin/env bash
# WIZP — Get Upstream Sources
# Clones or fetches the monaco-editor npm package and VSCode sources
# at a specific version for building the WIZP frontend.
#
# Inspired by MrCode's get_repo.sh — tracks upstream version in upstream/vscode.json
#
# Usage:
#   ./scripts/get_upstream.sh              # use version from upstream/vscode.json
#   VSCODE_REF=v1.98.0 ./scripts/get_upstream.sh  # use specific tag
#   VSCODIUM_LATEST=yes ./scripts/get_upstream.sh  # use latest VSCode release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"
UPSTREAM_JSON="$WIZP_DIR/upstream/vscode.json"
MONACO_DIR="$WIZP_DIR/monaco-upstream"
VSCODE_DIR="$WIZP_DIR/vscode-upstream"

echo "=== WIZP: Get Upstream Sources ==="

# --- Determine VSCode version ---
if [[ -n "${VSCODE_REF:-}" ]]; then
    VSCODE_TAG="$VSCODE_REF"
    echo "Using explicit version: $VSCODE_TAG"
elif [[ -f "$UPSTREAM_JSON" ]]; then
    VSCODE_TAG=$(jq -r '.tag' "$UPSTREAM_JSON")
    echo "Using saved version: $VSCODE_TAG"
else
    # Default: track VSCode 1.98.x (the version MrCode's patches target)
    VSCODE_TAG="1.98.0"
    echo "No upstream version set, defaulting to $VSCODE_TAG"
fi

# --- Clone/update VSCode repo (for workbench HTML/CSS/JS reference) ---
if [[ -d "$VSCODE_DIR" ]]; then
    echo "Updating VSCode sources..."
    cd "$VSCODE_DIR"
    git fetch --all --tags
else
    echo "Cloning VSCode (shallow, tag only)..."
    git clone --depth 1 --branch "$VSCODE_TAG" \
        https://github.com/microsoft/vscode.git "$VSCODE_DIR"
fi

cd "$VSCODE_DIR"
git checkout "$VSCODE_TAG" 2>/dev/null || {
    echo "Tag $VSCODE_TAG not found, trying to fetch..."
    git fetch --tags
    git checkout "tags/$VSCODE_TAG"
}
VSCODE_COMMIT=$(git rev-parse HEAD)
echo "VSCode: $VSCODE_TAG ($VSCODE_COMMIT)"

# --- Install Monaco editor npm package ---
MONACO_VERSION=$(jq -r '.monaco_version // "0.52.2"' "$UPSTREAM_JSON" 2>/dev/null || echo "0.52.2")
echo "Monaco version: $MONACO_VERSION"

if [[ ! -d "$MONACO_DIR" ]]; then
    mkdir -p "$MONACO_DIR"
    cd "$MONACO_DIR"
    npm init -y > /dev/null 2>&1
    npm install "monaco-editor@$MONACO_VERSION" --save
    echo "Monaco editor installed at $MONACO_DIR/node_modules/monaco-editor"
else
    echo "Monaco directory exists, skipping npm install"
fi

# --- Save version info ---
mkdir -p "$(dirname "$UPSTREAM_JSON")"
jq -n \
    --arg tag "$VSCODE_TAG" \
    --arg commit "$VSCODE_COMMIT" \
    --arg monaco "$MONACO_VERSION" \
    --arg date "$(date -u +%Y-%m-%d)" \
    '{tag: $tag, commit: $commit, monaco_version: $monaco, date: $date}' \
    > "$UPSTREAM_JSON"

echo "Upstream version saved to $UPSTREAM_JSON"
echo ""
echo "=== Upstream Sources Ready ==="
echo "VSCode:  $VSCODE_TAG ($VSCODE_COMMIT)"
echo "Monaco:  $MONACO_VERSION"
echo "Paths:"
echo "  $VSCODE_DIR   (VSCode workbench reference)"
echo "  $MONACO_DIR   (Monaco editor npm package)"
