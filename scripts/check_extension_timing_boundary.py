#!/usr/bin/env python3
"""Validate the extension-timing boundary without treating missing timing as pass."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COVERAGE = ROOT / "build" / "parity-stress" / "performance-baseline-coverage.json"
BUDGETS = ROOT / "build" / "vscode-parity" / "top20-behavior-performance-budgets.json"


def main() -> int:
    errors: list[str] = []
    if not COVERAGE.is_file():
        errors.append(f"missing performance coverage: {COVERAGE.relative_to(ROOT)}")
    if not BUDGETS.is_file():
        errors.append(f"missing H11E budget artifact: {BUDGETS.relative_to(ROOT)}")
    if errors:
        print("extension timing boundary failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    coverage = json.loads(COVERAGE.read_text(encoding="utf-8"))
    budgets = json.loads(BUDGETS.read_text(encoding="utf-8"))
    if coverage.get("status") != "partial-baseline-coverage":
        errors.append("performance coverage must remain partial until extension timing is supplied")
    unverified = set(coverage.get("unverified", []))
    for field in ("extensionActivation", "extensionFirstResult"):
        if field not in unverified or coverage.get("coverage", {}).get(field) is not False:
            errors.append(f"{field} boundary is not explicitly unverified")
    promotion = budgets.get("performanceBudgetPromotionGate", {})
    if promotion.get("blockedScenarioCount") != 8:
        errors.append("H11E blocked scenario count changed from the current 8-scenario boundary")
    if promotion.get("budgetRuleFailedCheckOwnerCounts", {}).get("extension-owned-behavior") is None:
        errors.append("H11E extension-owned timing owner boundary is missing")
    if budgets.get("budgetPromotionReady") is not False:
        errors.append("H11E promotion must remain blocked while extension timing is unresolved")

    if errors:
        print("extension timing boundary failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("extension timing boundary ok: unverified and extension-owned blockers preserved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
