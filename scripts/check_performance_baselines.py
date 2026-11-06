#!/usr/bin/env python3
"""Reconcile the current performance baseline artifacts without overstating coverage."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    paths = {
        "bundle": ROOT / "build" / "parity-stress" / "frontend-bundle-report.json",
        "startup": ROOT / "build" / "parity-stress" / "startup-benchmark.json",
        "terminal": ROOT / "build" / "parity-stress" / "frontend-terminal-resource-report.json",
    }
    errors = [f"missing {name} baseline: {path}" for name, path in paths.items() if not path.is_file()]
    reports = {} if errors else {name: load(path) for name, path in paths.items()}
    if reports:
        if reports["bundle"].get("buildFreshness") != "verified-by-caller":
            errors.append("bundle baseline is not fresh")
        if reports["bundle"].get("budgetStatus") != "passed":
            errors.append("bundle oversized-asset budget is not passing")
        if reports["startup"].get("benchmarkKind") != "process-cold-repeated":
            errors.append("startup baseline is not repeated cold-start evidence")
        if reports["terminal"].get("cleanupVerified") is not True:
            errors.append("terminal cleanup evidence is missing")

    payload = {
        "schema": 1,
        "status": "failed" if errors else "partial-baseline-coverage",
        "coverage": {
            "bundleSize": not errors,
            "startupLatency": not errors,
            "terminalResources": not errors,
            "extensionActivation": False,
            "extensionFirstResult": False,
        },
        "unverified": ["extensionActivation", "extensionFirstResult"],
        "errors": errors,
        "artifacts": {name: str(path.relative_to(ROOT)) for name, path in paths.items()},
    }
    output = ROOT / "build" / "parity-stress" / "performance-baseline-coverage.json"
    output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if errors:
        print("performance baseline coverage failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"performance baseline coverage: {output} (extension timing remains unverified)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
