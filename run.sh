#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mode="dev"
clean=0
skip_build=0
benchmark_runs=9
benchmark_warmups=0
benchmark_output="build/parity-stress/runsh-gui-startup-benchmark.json"

usage() {
  cat <<'USAGE'
WIZP launcher

Usage:
  ./run.sh                         Build frontend/backend and open Electrobun dev window
  ./run.sh --skip-build            Open Electrobun dev window using existing artifacts
  ./run.sh --clean                 Clear caches before building/running
  ./run.sh --package               Build audited bundled package and launch it
  ./run.sh --benchmark             Build package and run native GUI cold-start benchmark
  ./run.sh --port PORT             Set WIZP_PORT for the backend HTTP server
  ./run.sh --control-port PORT     Set WIZP_CONTROL_PORT for native-window control/marks
  ./run.sh --runs N                Benchmark runs for --benchmark (default: 9)
  ./run.sh --warmups N             Benchmark warmups for --benchmark (default: 0)
  ./run.sh --output PATH           Benchmark report path (default: build/parity-stress/runsh-gui-startup-benchmark.json)
  ./run.sh --help                  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      clean=1
      ;;
    --skip-build)
      skip_build=1
      ;;
    --package)
      mode="package"
      ;;
    --benchmark)
      mode="benchmark"
      ;;
    --port)
      if [[ $# -lt 2 ]]; then
        echo "--port requires a value" >&2
        exit 2
      fi
      export WIZP_PORT="$2"
      shift
      ;;
    --control-port)
      if [[ $# -lt 2 ]]; then
        echo "--control-port requires a value" >&2
        exit 2
      fi
      export WIZP_CONTROL_PORT="$2"
      shift
      ;;
    --runs)
      if [[ $# -lt 2 ]]; then
        echo "--runs requires a value" >&2
        exit 2
      fi
      benchmark_runs="$2"
      shift
      ;;
    --warmups)
      if [[ $# -lt 2 ]]; then
        echo "--warmups requires a value" >&2
        exit 2
      fi
      benchmark_warmups="$2"
      shift
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "--output requires a value" >&2
        exit 2
      fi
      benchmark_output="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to run WIZP" >&2
  exit 1
fi

audit_self_contained_package() {
  npm run audit:package && npm run audit:self-contained
}

build_self_contained_package() {
  npm run build:self-contained
}

echo "=== WIZP Launcher (${mode}) ==="
if [[ "$mode" == "benchmark" ]]; then
  http_port="${WIZP_PORT:-21876}"
  control_port="${WIZP_CONTROL_PORT:-22876}"
else
  http_port="${WIZP_PORT:-9876}"
  control_port="${WIZP_CONTROL_PORT:-19876}"
fi
echo "[env] WIZP_PORT=${http_port} WIZP_CONTROL_PORT=${control_port}"

pkill -f "zig-out/bin/wizp" 2>/dev/null || true
pkill -f "Resources/app/wizp" 2>/dev/null || true

if [[ "$clean" -eq 1 ]]; then
  echo "[clean] Clearing build and webview caches..."
  rm -rf frontend/dist frontend/node_modules/.vite .zig-cache
  rm -rf ~/.cache/dev.wizp.app ~/.cache/wizp 2>/dev/null || true
fi

if [[ "$mode" == "package" || "$mode" == "benchmark" ]]; then
  if [[ "$skip_build" -eq 0 ]]; then
    echo "[1/3] Building audited bundled package..."
    build_self_contained_package
  else
    echo "[1/3] Reusing package if valid; auditing existing self-contained package..."
    if audit_self_contained_package; then
      echo "[1/3] Existing self-contained package is valid."
    else
      echo "[1/3] Existing package is stale or incomplete; rebuilding self-contained package..."
      build_self_contained_package
    fi
  fi

  launcher="./build/dev-linux-x64/WIZP-dev/bin/launcher"
  if [[ ! -x "$launcher" ]]; then
    echo "Packaged launcher not found: $launcher" >&2
    exit 1
  fi

  if [[ "$mode" == "benchmark" ]]; then
    echo "[2/3] Bundled package audit passed."
    echo "[3/3] Running packaged native GUI startup benchmark..."
    exec node scripts/benchmark-gui-startup.js \
      --binary "$launcher" \
      --runs "$benchmark_runs" \
      --warmups "$benchmark_warmups" \
      --port-base "$http_port" \
      --control-port-base "$control_port" \
      --output "$benchmark_output"
  else
    echo "[2/3] Bundled package audit passed."
    echo "[3/3] Launching packaged WIZP..."
    exec "$launcher"
  fi
fi

if [[ "$skip_build" -eq 0 ]]; then
  echo "[1/3] Building Svelte frontend..."
  npm run build:frontend

  echo "[2/3] Building Zig backend..."
  npm run build
else
  echo "[1/3] Skipping frontend/backend build."
  if [[ ! -x zig-out/bin/wizp ]]; then
    echo "Missing zig-out/bin/wizp; rerun without --skip-build." >&2
    exit 1
  fi
  if [[ ! -f frontend/dist/index.html ]]; then
    echo "Missing frontend/dist/index.html; rerun without --skip-build." >&2
    exit 1
  fi
fi

echo "[3/3] Opening Electrobun dev window..."
if [[ -x ./node_modules/.bin/electrobun ]]; then
  exec ./node_modules/.bin/electrobun dev
fi

echo "Local Electrobun is not installed. Run npm install, then retry." >&2
exit 1
