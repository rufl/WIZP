#!/usr/bin/env python3
"""Validate persisted GitHub Actions stress-history evidence."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "parity-stress" / "stress-trend-report.json"


def validate(report: dict) -> tuple[int, int, str]:
    required = report.get("requiredHistoryForTrend", 3)
    required_source = report.get("requiredSourceForTrend", "github-actions")
    ci_count = report.get("ciHistoryCount", 0)
    history_count = report.get("historyCount", 0)
    errors: list[str] = []

    if report.get("schema") != "wizp.stress-trend.v1":
        errors.append("unsupported stress-trend schema")
    if required_source != "github-actions":
        errors.append(f"required source is {required_source!r}, expected 'github-actions'")
    if not isinstance(ci_count, int) or ci_count < 0:
        errors.append("ciHistoryCount is invalid")
    if not isinstance(history_count, int) or history_count < ci_count:
        errors.append("historyCount is inconsistent with ciHistoryCount")
    if report.get("trendReady") is not (ci_count >= required):
        errors.append("trendReady does not match persisted CI sample count")

    if errors:
        raise AssertionError("\n".join(errors))
    return ci_count, required, required_source


def main() -> int:
    report_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPORT
    report = json.loads(report_path.read_text(encoding="utf-8"))
    try:
        ci_count, required, required_source = validate(report)
    except AssertionError as exc:
        print("stress CI history check failed:", file=sys.stderr)
        for error in str(exc).splitlines():
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"stress CI history: {ci_count}/{required} {required_source} samples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
