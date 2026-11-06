#!/bin/bash
# Build and package WIZP as a VSIX extension
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIZP_DIR="$SCRIPT_DIR/.."
EXT_DIR="$SCRIPT_DIR"

echo "=== WIZP VSIX Builder ==="

# 1. Build Zig daemon binary
echo "[1/4] Building Zig daemon..."
if [ ! -f "$WIZP_DIR/zig-out/bin/wizp" ]; then
  (cd "$WIZP_DIR" && zig build -Doptimize=ReleaseSafe 2>&1)
  if [ ! -f "$WIZP_DIR/zig-out/bin/wizp" ]; then
    echo "ERROR: Zig build failed. Install Zig 0.14-0.16 and run: zig build -Doptimize=ReleaseSafe"
    exit 1
  fi
  echo "  Built: $WIZP_DIR/zig-out/bin/wizp"
else
  echo "  Already built"
fi

# 2. Clean and copy Zig binary
echo "[2/4] Copying binary..."
rm -rf "$EXT_DIR/bin"
mkdir -p "$EXT_DIR/bin"
cp "$WIZP_DIR/zig-out/bin/wizp" "$EXT_DIR/bin/wizp"

# 3. Clean, install deps, compile TypeScript
echo "[3/4] Compiling TypeScript..."
cd "$EXT_DIR"
rm -rf "$EXT_DIR/dist"
[ -d node_modules ] || npm install 2>&1
npx tsc -p ./tsconfig.json 2>&1
if [ ! -f "dist/extension.js" ]; then
  echo "ERROR: TypeScript compilation failed"
  exit 1
fi

# 4. Package VSIX
echo "[4/4] Packaging VSIX..."
rm -f wizp-editor-*.vsix
npx vsce package --no-dependencies 2>&1

VSIX=$(ls "$EXT_DIR"/wizp-editor-*.vsix 2>/dev/null | head -1)
if [ -n "$VSIX" ]; then
  echo ""
  echo "=== SUCCESS ==="
  echo "VSIX: $VSIX ($(du -h "$VSIX" | cut -f1))"
  echo ""
  echo "Install: code --install-extension $VSIX"
else
  echo "ERROR: No .vsix produced"
  exit 1
fi
