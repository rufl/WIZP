#!/usr/bin/env bash
# WIZP Patch Tool — Interactive patch generator for VSCode workbench modifications.
# Inspired by MrCode's dev/patch.sh
#
# Usage:
#   ./scripts/patch.sh <patch-name>           # Generate patch from staged changes
#   ./scripts/patch.sh file1.patch [file2.patch ...]  # Apply patches, edit, regenerate
#
# Works on the VSCode upstream clone in vscode-upstream/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIZP_DIR="$(dirname "$SCRIPT_DIR")"
VSCODE_DIR="$WIZP_DIR/vscode-upstream"
PATCHES_DIR="$WIZP_DIR/patches"

normalize_file() {
  if [[ "${1}" == *patch ]]; then
    FILE="${1}"
  else
    FILE="${1}.patch"
  fi

  if [[ "${FILE}" == patches/* ]]; then
    FILE="$WIZP_DIR/${FILE}"
  elif [[ -f "$PATCHES_DIR/${FILE}" ]]; then
    FILE="$PATCHES_DIR/${FILE}"
  elif [[ -f "${FILE}" ]]; then
    FILE="$(realpath "${FILE}")"
  else
    FILE="$PATCHES_DIR/${FILE}"
  fi
}

if [ ! -d "$VSCODE_DIR" ]; then
  echo "ERROR: VSCode upstream not found at $VSCODE_DIR"
  echo "Run './scripts/get_upstream.sh' first."
  exit 1
fi

cd "$VSCODE_DIR" || { echo "'$VSCODE_DIR' dir not found"; exit 1; }

if [ $# -eq 0 ]; then
  echo "Usage: $0 <patch-name> [additional-patches-to-apply-first...]"
  echo ""
  echo "Generate a patch from your staged changes:"
  echo "  Make changes in vscode-upstream/ first, then:"
  echo "  $0 extension-management"
  echo ""
  echo "Edit and regenerate an existing patch:"
  echo "  $0 extension-management.patch"
  exit 1
fi

git add .
git reset -q --hard HEAD

# Clean up any leftover VSCODIUM HELPER or WIZP HELPER commits
while [[ -n "$( git log -1 2>/dev/null | grep -E "VSCODIUM HELPER|WIZP HELPER" || true )" ]]; do
  git reset -q --hard HEAD~
done

# Apply additional patches first (dependencies)
while [ $# -gt 1 ]; do
  echo "Applying dependency: $1"
  normalize_file "${1}"

  if [[ -f "${FILE}" ]]; then
    git apply --reject "${FILE}" || true
  fi

  shift
done

# Apply the target patch (which may be a new file name)
normalize_file "${1}"
TARGET_FILE="${FILE}"

echo "Target patch: $TARGET_FILE"

# Commit the current state as a helper commit
git add .
git commit --no-verify -q -m "WIZP HELPER" || true

# If the patch already exists, apply it (with reject for conflicts)
if [[ -f "${TARGET_FILE}" ]]; then
  echo "Applying existing patch: $TARGET_FILE"
  if ! git apply --ignore-whitespace "${TARGET_FILE}"; then
    echo "Conflicts detected — resolve manually"
    git apply --reject "${TARGET_FILE}"

    read -rp "Press Enter when conflicts have been resolved..." -n1 -s
    echo ""
  fi
fi

echo ""
echo "Edit the files as needed, then press Enter to generate the patch."
read -rp "Press Enter to generate the patch..." -n1 -s
echo ""

# Ensure directory exists
mkdir -p "$(dirname "$TARGET_FILE")"

git add .
git diff --staged -U1 > "${TARGET_FILE}"
git reset -q --hard HEAD~

echo "Patch generated: $TARGET_FILE"
