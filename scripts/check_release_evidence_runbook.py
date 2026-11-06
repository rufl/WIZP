#!/usr/bin/env python3
"""Protect the release evidence handoff from drifting away from CI wiring."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNBOOK = ROOT / "docs" / "release" / "BETA_EVIDENCE_RUNBOOK.md"


def main() -> int:
    if not RUNBOOK.exists():
        print(f"missing release evidence runbook: {RUNBOOK}", file=sys.stderr)
        return 1
    text = RUNBOOK.read_text(encoding="utf-8")
    required = (
        "parity-package-report-ubuntu-latest",
        "parity-package-report-macos-latest",
        "parity-package-report-windows-latest",
        "parity-stress-report",
        "beta-readiness-report",
        "cross-os-artifact-report.json",
        "stress-trend-report.json",
        "npm run check:beta-handoff",
        "PROD-B02",
        "Windows ConPTY",
        "PROD-B03",
        "macOS native-shell",
        "--record-history",
        "npm run check:cross-os-artifacts",
        "npm run test:stress-ci-history",
        "npm run check:extension-timing-boundary",
        "extension timing remains unverified",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        print("release evidence runbook contract failed:", file=sys.stderr)
        for marker in missing:
            print(f"- missing marker: {marker}", file=sys.stderr)
        return 1
    print("release evidence runbook contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
