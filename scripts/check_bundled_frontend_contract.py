#!/usr/bin/env python3
"""Detect drift between the bundled-frontend build graph and the live Vite output."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    build = (ROOT / "build.zig").read_text(encoding="utf-8")
    server = (ROOT / "src" / "embedded_server.zig").read_text(encoding="utf-8")
    errors: list[str] = []

    if '"run",\n                "build"' not in build:
        errors.append("bundled build graph does not invoke the frontend's Vite build script")
    if '@embedFile("bundle.js")' in server or '@embedFile("index.bundled.html")' in server:
        errors.append("embedded server still depends on deleted legacy bundle/index embed inputs")
    if not (ROOT / "frontend" / "dist" / "index.html").exists():
        errors.append("frontend/dist/index.html is missing")
    if not (ROOT / "frontend" / "dist" / "assets").is_dir():
        errors.append("frontend/dist/assets is missing")

    if errors:
        print("bundled frontend contract failed:", file=sys.stderr)
        print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print("bundled frontend contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
