#!/usr/bin/env python3
"""Reconcile process-backed claims from retained packaged-native raw samples."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from native_ui_baseline_smoke import reconcile_retained_process_evidence, write_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="native baseline report JSON to reconcile")
    parser.add_argument(
        "--sync-report-alias",
        action="store_true",
        help="also replace report.json when it already points at the same retained run",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report_path = args.report.resolve()
    report = json.loads(report_path.read_text(encoding="utf-8"))
    process_file = report.get("evidenceFiles", {}).get("processSamples")
    if not isinstance(process_file, str):
        raise SystemExit("report does not name a retained processSamples artifact")
    process_path = report_path.parent / process_file
    process_samples = json.loads(process_path.read_text(encoding="utf-8"))
    if not isinstance(process_samples, list):
        raise SystemExit("retained processSamples artifact must contain a JSON list")

    reconcile_retained_process_evidence(report, process_samples)
    write_json(report_path, report)
    if args.sync_report_alias:
        alias_path = report_path.parent / "report.json"
        if alias_path.exists():
            alias = json.loads(alias_path.read_text(encoding="utf-8"))
            if alias.get("runId") != report.get("runId"):
                raise SystemExit("report.json belongs to a different run; alias was not replaced")
            write_json(alias_path, report)
    print(
        f"reconciled {report_path}: {report['status']} "
        f"(RSS growth {report['processSummary']['peakAggregateRssGrowthBytes']} bytes)"
    )
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
