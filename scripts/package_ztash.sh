#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${OVERZEER_VERSION:-0.1.0}"
TARGET="${OVERZEER_PACKAGE_TARGET:-linux-x86_64}"
DIST_INPUT="${1:-$ROOT/dist/ztash}"
ZIG="${ZIG:-zig}"

if [[ "$TARGET" != linux-x86_64 && "$TARGET" != windows-x86_64 ]]; then
  echo 'package: target must be linux-x86_64 or windows-x86_64' >&2
  exit 2
fi
if [[ "$TARGET" == windows-x86_64 ]]; then
  ZIG_TARGET=x86_64-windows-gnu
  BINARY=wizp.exe
  ARCHIVE_SUFFIX=zip
else
  ZIG_TARGET=x86_64-linux-gnu
  BINARY=wizp
  ARCHIVE_SUFFIX=tar.gz
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo 'package: version must be SemVer' >&2
  exit 2
}

mkdir -p "$DIST_INPUT"
DIST="$(cd "$DIST_INPUT" && pwd)"
case "$DIST" in
  /|"$ROOT") echo 'package: refusing unsafe output directory' >&2; exit 2 ;;
esac
if [[ -n "$(printf '%s' "$DIST" | tr -d '[:space:]')" && ! -f "$DIST/.ztash-release-output" ]]; then
  shopt -s nullglob dotglob
  existing=("$DIST"/*)
  shopt -u nullglob dotglob
  ((${#existing[@]} == 0)) || {
    echo 'package: refusing non-empty output not owned by this packager' >&2
    exit 2
  }
fi

touch "$DIST/.ztash-release-output"
rm -rf -- "$DIST/work" "$DIST/packages"
mkdir -p "$DIST/work" "$DIST/packages"

PACKAGE="$DIST/work/wizp-${VERSION}-${TARGET}"
PREFIX="$DIST/work/prefix"
BUILD_ARGS=(-Doptimize=ReleaseSafe -Dtarget="$ZIG_TARGET")
if [[ -n "${WIZP_BUN:-}" ]]; then
  BUILD_ARGS+=(-DWIZP_BUN="$WIZP_BUN")
fi
if [[ "$TARGET" == windows-x86_64 ]]; then
  BUILD_ARGS+=(-DWIZP_BUNDLED_FRONTEND=true -DWIZP_RUNTIME_BUN=bun)
fi
"$ZIG" build "${BUILD_ARGS[@]}" -p "$PREFIX"
[[ -f "$PREFIX/bin/$BINARY" ]] || { echo "package: WIZP build produced no $BINARY" >&2; exit 1; }
mkdir -p "$PACKAGE/bin"
cp "$PREFIX/bin/$BINARY" "$PACKAGE/bin/$BINARY"
if [[ "$TARGET" == windows-x86_64 ]]; then
  [[ -f "$ROOT/frontend/dist/index.html" ]] || {
    echo 'package: bundled Windows frontend build produced no frontend/dist/index.html' >&2
    exit 1
  }
  cp -R "$ROOT/frontend/dist" "$PACKAGE/frontend-dist"
fi
cp "$ROOT/README.md" "$PACKAGE/README.md"
if [[ "$TARGET" == windows-x86_64 ]]; then
  cp "$ROOT/README.md" "$PACKAGE/README.txt"
fi
cat > "$PACKAGE/LICENSE" <<'LICENSE'
WIZP is licensed under the MIT License.

The project README is the authoritative attribution and license notice:
README.md, section "License".
LICENSE
if [[ "$TARGET" == windows-x86_64 ]]; then
  cp "$PACKAGE/bin/$BINARY" "$PACKAGE/wizp.exe"
else
  cat > "$PACKAGE/wizp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "${1:-}" == --package-smoke ]]; then
  [[ -x ./bin/wizp ]] || { echo 'package smoke: missing executable' >&2; exit 1; }
  ./bin/wizp --package-smoke
  exit 0
fi
exec ./bin/wizp "$@"
LAUNCHER
fi
chmod 755 "$PACKAGE/bin/$BINARY"
if [[ "$TARGET" == windows-x86_64 ]]; then
  chmod 755 "$PACKAGE/wizp.exe"
else
  chmod 755 "$PACKAGE/wizp"
fi

ARCHIVE="$DIST/packages/wizp-${VERSION}-${TARGET}.${ARCHIVE_SUFFIX}"
if [[ "$TARGET" == windows-x86_64 ]]; then
  (cd "$DIST/work" && zip -q -r "$ARCHIVE" "$(basename "$PACKAGE")")
else
  tar -C "$DIST/work" -czf "$ARCHIVE" "$(basename "$PACKAGE")"
fi
(
  cd "$DIST/packages"
  sha256sum "$(basename "$ARCHIVE")" > SHA256SUMS
  sha256sum -c SHA256SUMS
)
printf 'package: wrote %s and SHA256SUMS under %s/packages\n' "$TARGET" "$DIST"

