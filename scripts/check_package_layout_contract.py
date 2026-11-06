#!/usr/bin/env python3
"""Verify that the frontend build, Zig install, Electrobun copy, and package audit agree."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    build = (ROOT / "build.zig").read_text(encoding="utf-8")
    electrobun = (ROOT / "electrobun.config.ts").read_text(encoding="utf-8")
    electrobun_main = (ROOT / "src" / "bun" / "index.ts").read_text(encoding="utf-8")
    audit = (ROOT / "scripts" / "package_self_contained_audit.py").read_text(encoding="utf-8")
    vendor = (ROOT / "scripts" / "vendor_linux_runtime_deps.py").read_text(encoding="utf-8")
    package = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    prune = (ROOT / "scripts" / "prune_linux_package.py").read_text(encoding="utf-8")
    scripts = package["scripts"]
    errors: list[str] = []

    if "frontend/dist" not in build or "zig-out/frontend-dist" not in build:
        errors.append("Zig install step does not copy frontend/dist to zig-out/frontend-dist")
    if '"zig-out/frontend-dist": "frontend-dist"' not in electrobun:
        errors.append("Electrobun config does not package zig-out/frontend-dist as frontend-dist")
    renderer_contract = 'defaultRenderer: bundleBrowserRuntime ? "cef" : "native"'
    if electrobun.count(renderer_contract) != 3:
        errors.append(
            "Electrobun platform configs must select CEF when the browser runtime is bundled"
        )
    if '"disable-gpu": true' not in electrobun or '"disable-gpu-compositing": true' not in electrobun:
        errors.append("Linux CEF packaging does not pin software compositing for broad DINX hardware")
    if 'renderer: "native"' in electrobun_main:
        errors.append(
            "Electrobun main process hard-codes the host renderer instead of using the packaged default"
        )
    if 'app_dir / "frontend-dist"' not in audit or 'frontend_dir / "assets"' not in audit:
        errors.append("package audit does not inspect the packaged frontend-dist/assets tree")
    if "libwizp_cef_xcb_backoff.so" not in vendor or "WIZP_CEF_XCB_BACKOFF_US" not in vendor:
        errors.append("Linux packaging does not build and launch with the bounded CEF/XCB backoff")
    if "WIZP_STARTUP_OPEN_PATHS_FILE" not in vendor or "printf '%s\\0'" not in vendor:
        errors.append("Linux launcher wrapper does not preserve startup file arguments across the Electrobun worker")
    if "WIZP_STARTUP_OPEN_PATHS_FILE" not in electrobun_main or "readStartupOpenPaths" not in electrobun_main:
        errors.append("Electrobun main process does not consume worker-safe startup file arguments")
    if '"cefXcbBackoff": bin_dir / "libwizp_cef_xcb_backoff.so"' not in audit:
        errors.append("package audit does not inspect the packaged CEF/XCB backoff library")
    if not scripts.get("build:self-contained", "").startswith("npm run build:frontend &&"):
        errors.append("self-contained build does not build the frontend before the backend")
    if "npm run build:electrobun" not in scripts.get("build:self-contained", ""):
        errors.append("self-contained build does not invoke Electrobun packaging")
    if "npm run audit:package" not in scripts.get("build:self-contained", ""):
        errors.append("self-contained build does not run the bundled package audit")
    if "--strip" not in scripts.get("prune:linux-package", ""):
        errors.append("Linux package pruning is not configured to strip release ELF payloads")
    if "DEFAULT_MAX_STRIP_BYTES = 512 * 1024 * 1024" not in prune:
        errors.append("Linux package pruning limit does not include the bundled CEF payload")
    if '"stripSavedBytes"' not in prune or "DEFAULT_REPORT" not in prune:
        errors.append("Linux package pruning does not emit a strip size report")
    verify = (ROOT / "scripts" / "verify.sh").read_text(encoding="utf-8")
    if "npm run build:self-contained" not in verify:
        errors.append("broad verify gate does not build the release-shaped package before auditing")

    if errors:
        print("package layout contract failed:", file=sys.stderr)
        print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print("package layout contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
