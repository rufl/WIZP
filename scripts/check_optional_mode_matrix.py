#!/usr/bin/env python3
"""Check that optional-mode documentation matches local source availability."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    build_zig = (ROOT / "build.zig").read_text(encoding="utf-8")
    quickjs_available = (ROOT / "lib" / "quickjs" / "quickjs.c").is_file()
    treesitter_available = (ROOT / "lib" / "tree-sitter" / "lib.c").is_file()
    frontend_available = (ROOT / "frontend" / "dist" / "index.html").is_file()
    checks = {
        "quickjs": {
            "available": quickjs_available,
            "documentedUnavailable": "QuickJS | unavailable" in readme,
            "status": "available" if quickjs_available else "unavailable",
        },
        "treeSitter": {
            "available": treesitter_available,
            "documentedOptional": "Tree-sitter | experimental" in readme,
            "status": "available" if treesitter_available else "unavailable",
        },
        "bundledFrontend": {
            "available": frontend_available,
            "documentedContract": "bundled frontend" in readme.lower(),
            "status": "available" if frontend_available else "missing",
        },
        "dvui": {"status": "optional-dependency-gated", "documentedOptional": "DVUI/SDL3 | experimental" in readme},
        "x11": {"status": "optional-dependency-gated", "documentedOptional": "X11 native GUI | experimental/Linux only" in readme},
        "legacyWebView": {
            "available": "WEBKIT2GTK" in build_zig or "webkit2gtk" in build_zig.lower(),
            "documentedUnavailable": "WebKit2GTK legacy webview flag | unavailable" in readme,
            "status": "available" if ("WEBKIT2GTK" in build_zig or "webkit2gtk" in build_zig.lower()) else "unavailable",
        },
    }
    errors = []
    if quickjs_available or not checks["quickjs"]["documentedUnavailable"]:
        errors.append("QuickJS availability/documentation mismatch")
    if not treesitter_available or not checks["treeSitter"]["documentedOptional"]:
        errors.append("Tree-sitter availability/documentation mismatch")
    if not frontend_available or not checks["bundledFrontend"]["documentedContract"]:
        errors.append("bundled frontend availability/documentation mismatch")
    for name in ("dvui", "x11"):
        if not checks[name]["documentedOptional"]:
            errors.append(f"{name} optional status is undocumented")
    if checks["legacyWebView"]["available"] or not checks["legacyWebView"]["documentedUnavailable"]:
        errors.append("legacy WebKit2GTK mode availability/documentation mismatch")

    report = {"schema": 1, "status": "failed" if errors else "passed", "checks": checks, "errors": errors}
    output = ROOT / "build" / "parity-package" / "optional-mode-matrix.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if errors:
        print("optional mode matrix failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"optional mode matrix ok: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
