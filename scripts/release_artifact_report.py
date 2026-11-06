#!/usr/bin/env python3
"""Inventory release-path generated outputs and obsolete frontend copies."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def entry(relative: str, kind: str, status: str) -> dict:
    path = ROOT / relative
    return {"path": relative, "kind": kind, "exists": path.exists(), "status": status}


def main() -> int:
    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "policy": "generated outputs are reproducible artifacts; removal candidates require review",
        "removalCandidates": [
            entry("src/bundle.js", "legacy-frontend-bundle", "remove-candidate-unreferenced"),
            entry("src/index.bundled.html", "legacy-bundled-index", "remove-candidate-unreferenced"),
            entry("frontend/dist/bundle.js", "legacy-frontend-bundle", "remove-candidate-unreferenced"),
        ],
        "declaredGeneratedOutputs": [
            entry("frontend/dist", "vite-output", "declared-build-output"),
            entry("zig-out/frontend-dist", "zig-install-output", "declared-build-output"),
            entry("build/dev-linux-x64", "electrobun-package", "declared-release-output"),
            entry("build/parity-package", "audit-reports", "declared-report-output"),
        ],
    }
    destination = ROOT / "build" / "parity-package" / "release-artifact-report.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    candidates = [item for item in report["removalCandidates"] if item["exists"]]
    print(f"release artifact report: {destination} ({len(candidates)} removal candidate(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
