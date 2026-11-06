#!/usr/bin/env python3
"""Copy Linux dynamic-library runtime dependencies into the packaged WIZP app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CEF_XCB_BACKOFF_SOURCE = PROJECT_ROOT / "src" / "bun" / "linux_cef_xcb_backoff.c"
CEF_XCB_BACKOFF_LIBRARY = "libwizp_cef_xcb_backoff.so"
BASELINE_LINUX_ABI_LIBS = {
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libdl.so.2",
    "libm.so.6",
    "libpthread.so.0",
    "libresolv.so.2",
    "librt.so.1",
    "libutil.so.1",
    "linux-vdso.so.1",
}


def default_package_dir() -> Path:
    return PROJECT_ROOT / "build" / "dev-linux-x64" / "WIZP-dev"


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def parse_ldd(output: str) -> list[dict]:
    deps: list[dict] = []
    for line in output.splitlines():
        stripped = line.strip()
        if "=>" in stripped:
            name, rest = stripped.split("=>", 1)
            target = rest.strip().split(" ", 1)[0]
            if target.startswith("/"):
                deps.append({"name": name.strip(), "path": target})
        elif stripped.startswith("/"):
            path = stripped.split(" ", 1)[0]
            deps.append({"name": Path(path).name, "path": path})
    return deps


def run_ldd(path: Path, lib_dirs: list[Path]) -> list[dict]:
    env = os.environ.copy()
    # Host preload/audit hooks are not package dependencies. Exclude them from
    # closure discovery so the package does not vendor session-specific libs.
    env.pop("LD_PRELOAD", None)
    env.pop("LD_AUDIT", None)
    env["LD_LIBRARY_PATH"] = ":".join(str(p) for p in lib_dirs if p.exists())
    proc = subprocess.run(
        ["ldd", str(path)],
        cwd=str(PROJECT_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if "not a dynamic executable" in proc.stdout:
        return []
    return parse_ldd(proc.stdout)


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def should_vendor(dep: dict, package_dir: Path) -> bool:
    name = str(dep["name"])
    source = Path(str(dep["path"]))
    if name in BASELINE_LINUX_ABI_LIBS or source.name in BASELINE_LINUX_ABI_LIBS:
        return False
    if inside(source, package_dir):
        return False
    if not source.exists():
        return False
    return True


def elf_roots(package_dir: Path) -> list[Path]:
    roots: list[Path] = []
    for base in (package_dir / "bin", package_dir / "Resources" / "app"):
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_file() and is_elf(path):
                roots.append(path)
    return sorted(set(roots))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_cef_xcb_backoff(bin_dir: Path) -> dict:
    destination = bin_dir / CEF_XCB_BACKOFF_LIBRARY
    cache_root = PROJECT_ROOT / ".zig-cache" / "wizp-cef-xcb-backoff"
    command = [
        str(PROJECT_ROOT / "scripts" / "zigw.sh"),
        "cc",
        "-target",
        "x86_64-linux-gnu",
        "-shared",
        "-fPIC",
        "-O2",
        f"-Wl,-soname,{CEF_XCB_BACKOFF_LIBRARY}",
        "-o",
        str(destination),
        str(CEF_XCB_BACKOFF_SOURCE),
        "-ldl",
        "-pthread",
    ]
    env = os.environ.copy()
    env.pop("LD_PRELOAD", None)
    env.pop("LD_AUDIT", None)
    env["ZIG_LOCAL_CACHE_DIR"] = str(cache_root / "local")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(cache_root / "global")
    subprocess.run(command, cwd=str(PROJECT_ROOT), env=env, check=True)
    destination.chmod(0o755)
    return {
        "source": str(CEF_XCB_BACKOFF_SOURCE),
        "library": str(destination),
        "sha256": sha256(destination),
        "defaultBackoffMicroseconds": 1000,
        "maxIdleBackoffMicroseconds": 2500,
        "consecutiveMissThreshold": 64,
        "idleEscalationThreshold": 512,
    }


def install_launcher_wrapper(bin_dir: Path) -> dict:
    launcher = bin_dir / "launcher"
    launcher_bin = bin_dir / "launcher.bin"
    if not launcher.exists():
        return {"installed": False, "reason": f"missing launcher: {launcher}"}

    if is_elf(launcher):
        if launcher_bin.exists():
            launcher_bin.unlink()
        launcher.rename(launcher_bin)
    elif not launcher_bin.exists():
        return {"installed": False, "reason": f"launcher is not ELF and {launcher_bin} is missing"}

    wrapper = r"""#!/bin/sh
APP_BIN=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
VERSION_JSON="$APP_BIN/../Resources/version.json"
CACHE_ROOT=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
NATIVE_CACHE_ROOT=${HOME:-/tmp}/.cache
CEF_CACHE_FORMAT=2
APP_IDENTIFIER=$(sed -n 's/.*"identifier":"\([^"]*\)".*/\1/p' "$VERSION_JSON")
APP_CHANNEL=$(sed -n 's/.*"channel":"\([^"]*\)".*/\1/p' "$VERSION_JSON")
prepare_cef_profile() {
  CEF_ROOT="$1/$APP_IDENTIFIER/$APP_CHANNEL/CEF"
  mkdir -p "$CEF_ROOT" || exit 1
  printf '%s\n' "$CEF_CACHE_FORMAT" > "$CEF_ROOT/.electrobun_cef_cache_version" || exit 1
}
if [ -n "$APP_IDENTIFIER" ] && [ -n "$APP_CHANNEL" ]; then
  # Electrobun starts CEF before the application worker can create its profile.
  # A clean Linux home therefore needs this native-owned path and its cache
  # format sentinel ready before the native wrapper runs its migration.
  prepare_cef_profile "$NATIVE_CACHE_ROOT"
  if [ "$CACHE_ROOT" != "$NATIVE_CACHE_ROOT" ]; then
    prepare_cef_profile "$CACHE_ROOT"
  fi
fi
STARTUP_ARGS_FILE=""
if [ "$#" -gt 0 ]; then
  STARTUP_ARGS_FILE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/wizp-startup-args-$$"
  (umask 077 && : > "$STARTUP_ARGS_FILE") || exit 1
  for startup_arg in "$@"; do
    printf '%s\0' "$startup_arg" >> "$STARTUP_ARGS_FILE" || exit 1
  done
  export WIZP_STARTUP_OPEN_PATHS_FILE="$STARTUP_ARGS_FILE"
fi
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="$APP_BIN:$APP_BIN/cef:$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="$APP_BIN:$APP_BIN/cef"
fi
EVENT_BACKOFF="$APP_BIN/libwizp_cef_xcb_backoff.so"
if [ ! -r "$EVENT_BACKOFF" ]; then
  printf '%s\n' "WIZP launcher is missing $EVENT_BACKOFF" >&2
  exit 1
fi
export WIZP_CEF_XCB_BACKOFF_US=${WIZP_CEF_XCB_BACKOFF_US:-1000}
export LD_PRELOAD="$EVENT_BACKOFF:$APP_BIN/libcef.so:$APP_BIN/libvk_swiftshader.so"
export ICU_DATA="$APP_BIN"
cd "$APP_BIN" || exit 1
exec "$APP_BIN/bun" "$APP_BIN/../Resources/main.js" "$@"
"""
    launcher.write_text(wrapper, encoding="utf-8")
    launcher.chmod(0o755)
    return {
        "installed": True,
        "launcher": str(launcher),
        "target": str(launcher_bin),
        "libraryPath": "$APP_BIN:$APP_BIN/cef",
        "cefProfileBootstrap": True,
        "cefXcbBackoff": True,
        "startsBundledBunDirectly": True,
    }


def vendor(args: argparse.Namespace) -> dict:
    package_dir = args.package_dir
    bin_dir = package_dir / "bin"
    cef_dir = bin_dir / "cef"
    lib_dirs = [bin_dir, cef_dir]
    copied: dict[str, str] = {}

    if not bin_dir.exists():
        raise SystemExit(f"package bin directory missing: {bin_dir}")

    cef_xcb_backoff = build_cef_xcb_backoff(bin_dir)

    for _ in range(args.max_passes):
        changed = False
        for root in elf_roots(package_dir):
            for dep in run_ldd(root, lib_dirs):
                if not should_vendor(dep, package_dir):
                    continue
                source = Path(str(dep["path"]))
                dest = bin_dir / source.name
                if dest.exists():
                    continue
                shutil.copy2(source, dest, follow_symlinks=True)
                copied[str(dest)] = str(source)
                changed = True
        if not changed:
            break

    remaining: list[str] = []
    for root in elf_roots(package_dir):
        for dep in run_ldd(root, lib_dirs):
            if should_vendor(dep, package_dir):
                remaining.append(f"{dep['name']} => {dep['path']}")

    launcher_wrapper = install_launcher_wrapper(bin_dir)

    payload = {
        "packageDir": str(package_dir),
        "destination": str(bin_dir),
        "copied": copied,
        "copiedCount": len(copied),
        "launcherWrapper": launcher_wrapper,
        "cefXcbBackoff": cef_xcb_backoff,
        "remainingNonBaselineExternalDependencies": sorted(set(remaining)),
        "baselineLinuxAbiAllowlist": sorted(BASELINE_LINUX_ABI_LIBS),
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, default=default_package_dir())
    parser.add_argument("--report", type=Path, default=PROJECT_ROOT / "build" / "parity-package" / "linux-runtime-deps.json")
    parser.add_argument("--max-passes", type=int, default=8)
    args = parser.parse_args()

    payload = vendor(args)
    print(f"vendored {payload['copiedCount']} Linux runtime libraries: {args.report}")
    if payload["remainingNonBaselineExternalDependencies"]:
        print("remaining non-baseline external dependencies:")
        for dep in payload["remainingNonBaselineExternalDependencies"]:
            print(f"- {dep}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
