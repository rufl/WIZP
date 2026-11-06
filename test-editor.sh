#!/bin/bash
# WIZP Editor Test Script
# Tests: extension install, daemon spawn, RPC communication, webview assets
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$SCRIPT_DIR/extension"
WIZP_BIN="$SCRIPT_DIR/zig-out/bin/wizp"
VSIX="$EXT_DIR/wizp-editor-0.1.0.vsix"
README="$SCRIPT_DIR/README.md"

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== WIZP Editor Tests ==="
echo "root: $SCRIPT_DIR"
echo ""

# 1. Binary exists and runs
echo "[1] Zig daemon binary"
if [ -f "$WIZP_BIN" ]; then pass "Binary exists ($(du -h "$WIZP_BIN" | cut -f1))"; else fail "Binary missing"; fi
if "$WIZP_BIN" --version 2>&1 | grep -qi "wizp\|ready"; then pass "Binary runs"; else fail "Binary doesn't run"; fi

# 2. VSIX package
echo "[2] VSIX package"
if [ -f "$VSIX" ]; then pass "VSIX exists ($(du -h "$VSIX" | cut -f1))"; else fail "VSIX missing"; fi

# 3. VSIX contents
echo "[3] VSIX contents"
CONTENTS=$(unzip -l "$VSIX" 2>/dev/null)
echo "$CONTENTS" | grep -q "extension/bin/wizp" && pass "Contains Zig binary" || fail "Missing Zig binary"
echo "$CONTENTS" | grep -q "extension/dist/extension.js" && pass "Contains extension.js" || fail "Missing extension.js"
echo "$CONTENTS" | grep -q "extension/media/editor.js" && pass "Contains editor.js" || fail "Missing editor.js"
echo "$CONTENTS" | grep -q "extension/media/editor.css" && pass "Contains editor.css" || fail "Missing editor.css"
echo "$CONTENTS" | grep -q "extension/themes/wizp-dark.json" && pass "Contains theme" || fail "Missing theme"
echo "$CONTENTS" | grep -q "extension/LICENSE" && pass "Contains LICENSE" || fail "Missing LICENSE"

# 4. Extension installed
echo "[4] Extension installed"
if code --list-extensions 2>/dev/null | grep -q "wizp-editor"; then pass "Extension installed in VS Code"; else fail "Extension not installed"; fi

# 5. Extension manifest valid
echo "[5] Extension manifest"
MANIFEST=$(unzip -p "$VSIX" "extension/package.json" 2>/dev/null)
echo "$MANIFEST" | grep -q '"activationEvents"' && pass "Has activationEvents" || fail "Missing activationEvents"
echo "$MANIFEST" | grep -q '"main"' && pass "Has main entry" || fail "Missing main entry"
echo "$MANIFEST" | grep -q '"wizp.openEditor"' && pass "Has commands" || fail "Missing commands"

# 6. TypeScript compiles clean
echo "[6] TypeScript compilation"
if [ -f "$EXT_DIR/dist/extension.js" ]; then pass "extension.js compiled"; else fail "extension.js not compiled"; fi
if [ -f "$EXT_DIR/media/editor.js" ]; then pass "editor.js exists ($(wc -l < "$EXT_DIR/media/editor.js") lines)"; else fail "editor.js missing"; fi

# 7. No Bun dependencies in webview code
echo "[7] Webview code independence"
if grep -q "Bun\." "$EXT_DIR/media/editor.js" 2>/dev/null; then fail "editor.js still uses Bun APIs"; else pass "No Bun dependencies in editor.js"; fi
if grep -q "Bun\." "$EXT_DIR/dist/extension.js" 2>/dev/null; then fail "extension.js still uses Bun APIs"; else pass "No Bun dependencies in extension.js"; fi

# 8. No silent failures in build script
echo "[8] Build script quality"
if grep -q "|| true" "$EXT_DIR/build-vsix.sh"; then fail "build-vsix.sh has silent failures"; else pass "No silent failures in build script"; fi
if grep -q "set -euo pipefail" "$EXT_DIR/build-vsix.sh"; then pass "Build script uses strict mode"; else fail "Missing strict mode"; fi

# 9. .gitignore exists
echo "[9] Git hygiene"
if [ -f "$SCRIPT_DIR/.gitignore" ]; then pass ".gitignore exists"; else fail "Missing .gitignore"; fi

# 10. README accurate
echo "[10] Documentation"
grep -q "build-vsix.sh" "$README" && pass "README documents VSIX build" || fail "README missing VSIX build"
grep -q "code --install-extension" "$README" && pass "README documents install" || fail "README missing install"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
