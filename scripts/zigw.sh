#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
expected_version="${WIZP_ZIG_VERSION:-0.17.0}"

run_checked() {
  local compiler="$1"
  shift
  local actual
  actual="$(${compiler} version)"
  if [[ "${actual}" != "${expected_version}" ]]; then
    echo "WIZP requires Zig ${expected_version}; found ${actual} at ${compiler}. Set WIZP_ZIG_VERSION only when updating the supported toolchain." >&2
    exit 2
  fi
  exec "${compiler}" "$@"
}

if [[ -n "${ZIG_BIN:-}" && -x "${ZIG_BIN}" ]]; then
  run_checked "${ZIG_BIN}" "$@"
fi


if command -v zig >/dev/null 2>&1; then
  run_checked "$(command -v zig)" "$@"
fi

echo "WIZP could not find a Zig compiler. Set ZIG_BIN or install/populate wizp/.toolchains." >&2
exit 127
