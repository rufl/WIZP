#!/usr/bin/env python3
"""Validate the repeatable cold-start benchmark artifact."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "parity-stress" / "startup-benchmark.json"
METRICS = ("processReadyMs", "firstHtmlMs", "criticalAssetsMs", "totalMeasuredMs")


def main() -> int:
    report_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPORT
    report = json.loads(report_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    runs = report.get("runs", [])
    summary = report.get("summary", {})

    if report.get("schema") != 1:
        errors.append("unsupported benchmark schema")
    if report.get("benchmarkKind") != "process-cold-repeated":
        errors.append("benchmark is not a repeated cold-start run")
    if len(runs) < 5:
        errors.append(f"only {len(runs)} runs recorded; at least 5 required")
    if report.get("terminalProbe", {}).get("exitCode") != 0:
        errors.append("terminal probe did not exit cleanly")

    for index, run in enumerate(runs, 1):
        for metric in METRICS:
            if not isinstance(run.get(metric), (int, float)) or run[metric] < 0:
                errors.append(f"run {index}: invalid {metric}")
        if run.get("totalMeasuredMs", 0) < run.get("processReadyMs", 0):
            errors.append(f"run {index}: totalMeasuredMs is below processReadyMs")
        if not isinstance(run.get("criticalAssetCount"), int) or run["criticalAssetCount"] <= 0:
            errors.append(f"run {index}: criticalAssetCount must be positive")
        if not isinstance(run.get("criticalAssetBytes"), int) or run["criticalAssetBytes"] <= 0:
            errors.append(f"run {index}: criticalAssetBytes must be positive")
    for metric in METRICS:
        stats = summary.get(metric, {})
        for percentile in ("p50", "p95"):
            if not isinstance(stats.get(percentile), (int, float)):
                errors.append(f"summary {metric}: missing {percentile}")
        if stats.get("p95", 0) < stats.get("p50", 0):
            errors.append(f"summary {metric}: p95 is below p50")

    if errors:
        print("startup benchmark check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        "startup benchmark ok: "
        f"runs={len(runs)} ready_p95={summary['processReadyMs']['p95']}ms "
        f"total_p95={summary['totalMeasuredMs']['p95']}ms"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
