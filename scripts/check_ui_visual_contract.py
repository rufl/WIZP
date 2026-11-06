#!/usr/bin/env python3
"""Measure the default WIZP token contrast floor and retain the result."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CSS = ROOT / "frontend" / "src" / "app.css"
REPORT = ROOT / "build" / "ui-ux" / "visual" / "token-contrast.json"


def channel(value: int) -> float:
    normalized = value / 255
    return normalized / 12.92 if normalized <= 0.04045 else ((normalized + 0.055) / 1.055) ** 2.4


def luminance(color: str) -> float:
    value = color.removeprefix("#")
    if len(value) == 3:
        value = "".join(character * 2 for character in value)
    red, green, blue = (channel(int(value[index : index + 2], 16)) for index in (0, 2, 4))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast(foreground: str, background: str) -> float:
    lighter, darker = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def main() -> int:
    source = CSS.read_text(encoding="utf-8")
    root_block = re.search(r":root\s*\{(?P<body>.*?)\n\}", source, re.DOTALL)
    assert root_block, "app.css has no :root token block"
    tokens = dict(re.findall(r"--([\w-]+):\s*(#[0-9a-fA-F]{3,8})\s*;", root_block.group("body")))
    checks = [
        ("body", "fg", "bg", 4.5),
        ("sidebar", "sidebar-fg", "sidebar-bg", 4.5),
        ("titlebar", "titlebar-fg", "titlebar-bg", 4.5),
        ("statusbar", "status-bar-fg", "status-bar-bg", 4.5),
        ("secondary text", "breadcrumb-dim", "panel-bg", 4.5),
        ("error text", "error", "panel-bg", 4.5),
        ("warning text", "warn", "panel-bg", 4.5),
        ("focus on workbench", "focus-ring", "bg", 3.0),
        ("focus on panel", "focus-ring", "panel-bg", 3.0),
    ]
    measurements = []
    for name, foreground_token, background_token, floor in checks:
        foreground = tokens[foreground_token]
        background = tokens[background_token]
        ratio = contrast(foreground, background)
        measurements.append(
            {
                "name": name,
                "foregroundToken": foreground_token,
                "foreground": foreground,
                "backgroundToken": background_token,
                "background": background,
                "ratio": round(ratio, 2),
                "localFloor": floor,
                "passed": ratio >= floor,
            }
        )
    report = {
        "status": "passed" if all(item["passed"] for item in measurements) else "failed",
        "scope": "default static CSS tokens only",
        "caveat": "This local floor does not claim rendered, extension-theme, platform, or assistive-technology conformance.",
        "measurements": measurements,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    assert report["status"] == "passed", json.dumps(report, indent=2)
    print(f"UI visual token contract ok: {len(measurements)} measured pairs; report {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())