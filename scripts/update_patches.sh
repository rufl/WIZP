#!/usr/bin/env bash
# WIZP Update Patches — Re-apply all patches against current VSCode upstream.
# Inspired by MrCode's dev/update_patches.sh
#
# Usage:
#   ./scripts/update_patches.sh            # Update all patches (linux)
#   ./scripts/update_patches.sh -l         # Linux mode
#   ./scripts/update_patches.sh -o         # macOS mode
#   ./scripts/update_patches.sh -w         # Windows mode
#
# Works on the VSCode upstream clone in vscode-upstream/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"
VSCODE_DIR="$WIZP_DIR/vscode-upstream"
PATCHES_DIR="$WIZP_DIR/patches"

case "${OSTYPE}" in
  darwin*)
    export OS_NAME="osx"
    ;;
  msys* | cygwin*)
    export OS_NAME="windows"
    ;;
  *)
    export OS_NAME="linux"
    ;;
esac

while getopts ":low" opt; do
  case "$opt" in
    l)
      export OS_NAME="linux"
      ;;
    o)
      export OS_NAME="osx"
      ;;
    w)
      export OS_NAME="windows"
      ;;
    *)
      ;;
  esac
done

echo "OS_NAME=\"${OS_NAME}\""
echo "Patches dir: $PATCHES_DIR"
echo "VSCode dir: $VSCODE_DIR"

if [ ! -d "$VSCODE_DIR" ]; then
  echo "ERROR: VSCode upstream not found at $VSCODE_DIR"
  echo "Run './scripts/get_upstream.sh' first."
  exit 1
fi

check_file() {
  for file in "$PATCHES_DIR"/*.patch; do
    if [[ -f "${file}" ]]; then
      echo "  Applying: ${file}"
      git apply --ignore-whitespace "${file}" --reject 2>/dev/null || {
        echo "  WARNING: Failed to apply ${file}"
      }
    fi
  done

  if [[ -d "$PATCHES_DIR/${OS_NAME}/" ]]; then
    for file in "$PATCHES_DIR/${OS_NAME}/"*.patch; do
      if [[ -f "${file}" ]]; then
        echo "  Applying: ${file}"
        git apply --ignore-whitespace "${file}" --reject 2>/dev/null || {
          echo "  WARNING: Failed to apply ${file}"
        }
      fi
    done
  fi

  while [ $# -gt 1 ]; do
    echo "  Applying extra: ${1}"
    git apply --reject "${1}" 2>/dev/null || true
    shift
  done

  if [[ -f "${1}" ]]; then
    TARGET_FILE="${1}"

    echo "  Updating: ${TARGET_FILE}"

    if ! git apply --ignore-whitespace "${TARGET_FILE}"; then
      echo "  CONFLICT: ${TARGET_FILE}"

      git apply --reject "${TARGET_FILE}"

      echo ""
      echo "  Resolve conflicts in $VSCODE_DIR, then press Enter to regenerate patch."
      read -rp "  Press Enter to regenerate..." -n1 -s
      echo ""

      git add .
      git diff --staged -U1 > "${TARGET_FILE}"

      echo "  Patch regenerated: ${TARGET_FILE}"
    else
      echo "  Applied cleanly: ${TARGET_FILE}"
    fi
  fi

  git add .
  git reset -q --hard HEAD
}

cd "$VSCODE_DIR" || { echo "'$VSCODE_DIR' dir not found"; exit 1; }

git add .
git reset -q --hard HEAD

# Clean up any leftover helper commits
while [[ -n "$( git log -1 2>/dev/null | grep -E "VSCODIUM HELPER|WIZP HELPER" || true )" ]]; do
  git reset -q --hard HEAD~
done

if [ ! -d "$PATCHES_DIR" ] || [ -z "$(ls -A "$PATCHES_DIR"/*.patch 2>/dev/null)" ]; then
  echo "No patches found in $PATCHES_DIR/"
  echo "Use './scripts/patch.sh <name>' to create patches."
  exit 0
fi

echo ""
echo "=== Applying all patches ==="

for FILE in "$PATCHES_DIR"/*.patch; do
  if [[ -f "${FILE}" ]]; then
    echo "Processing: $(basename "$FILE")"
    check_file "${FILE}"
  fi
done

echo ""
echo "=== All patches applied ==="
