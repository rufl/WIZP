#!/usr/bin/env python3
"""Validate sustained-terminal-output resource evidence."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "parity-stress" / "frontend-terminal-resource-report.json"


def validate(report: dict[str, object]) -> list[str]:
    required = (
        "commandBytes",
        "observedBytes",
        "droppedBytes",
        "rssGrowthBytes",
        "rssGrowthLimitBytes",
        "cleanupVerified",
        "cleanupProbe",
    )
    errors = [f"missing {field}" for field in required if field not in report]
    if report.get("status") != "linux-terminal-resource-smoke-passed":
        errors.append("resource smoke status is not passed")
    if report.get("platform") != "linux":
        errors.append("report is not Linux evidence")
    if report.get("commandBytes", 0) <= 0:
        errors.append("commandBytes must be positive")
    if report.get("observedBytes", 0) < 0 or report.get("droppedBytes", 0) < 0:
        errors.append("observedBytes and droppedBytes must be non-negative")
    accounted_bytes = report.get("observedBytes", 0) + report.get("droppedBytes", 0)
    if accounted_bytes < report.get("commandBytes", 0):
        errors.append("observedBytes plus droppedBytes does not account for commandBytes")
    if report.get("rssAfterBytes", 0) < report.get("rssBeforeBytes", 0):
        errors.append("rssAfterBytes cannot be below rssBeforeBytes")
    if report.get("rssGrowthBytes") != report.get("rssAfterBytes", 0) - report.get("rssBeforeBytes", 0):
        errors.append("rssGrowthBytes does not equal rssAfterBytes minus rssBeforeBytes")
    if report.get("rssGrowthBytes", 0) > report.get("rssGrowthLimitBytes", 0):
        errors.append("RSS growth exceeds the recorded limit")
    if report.get("cleanupVerified") is not True:
        errors.append("cleanup was not verified")
    cleanup_probe = report.get("cleanupProbe")
    if not isinstance(cleanup_probe, dict):
        errors.append("cleanupProbe must be an object")
    else:
        terminal_id = cleanup_probe.get("terminalId")
        active_ids = cleanup_probe.get("activeIdsAfterKill")
        if not isinstance(terminal_id, int):
            errors.append("cleanupProbe.terminalId must be an integer")
        if not isinstance(active_ids, list) or any(not isinstance(item, int) for item in active_ids):
            errors.append("cleanupProbe.activeIdsAfterKill must be a list of integer terminal ids")
        elif isinstance(terminal_id, int) and terminal_id in active_ids:
            errors.append("cleanup probe still lists the killed terminal session")
        process_probe = cleanup_probe.get("process")
        if not isinstance(process_probe, dict):
            errors.append("cleanupProbe.process must be an object")
        else:
            if not isinstance(process_probe.get("pid"), int):
                errors.append("cleanupProbe.process.pid must be an integer")
            if process_probe.get("reaped") is not True:
                errors.append("terminal child process was not reaped")
            before = process_probe.get("identityBeforeKill")
            after = process_probe.get("identityAfterKill")
            if not isinstance(before, dict) or not isinstance(before.get("startTimeTicks"), int):
                errors.append("terminal child process lacks a pre-kill identity")
            elif after is not None:
                if not isinstance(after, dict) or not isinstance(after.get("startTimeTicks"), int):
                    errors.append("terminal child process has a malformed post-kill identity")
                elif after.get("startTimeTicks") == before.get("startTimeTicks"):
                    errors.append("terminal child process identity still exists after kill")

    return errors


def main() -> int:
    report_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPORT
    report = json.loads(report_path.read_text(encoding="utf-8"))
    errors = validate(report)

    if errors:
        print("terminal resource report check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        "terminal resource report ok: "
        f"observed={report['observedBytes']} dropped={report['droppedBytes']} "
        f"rssGrowth={report['rssGrowthBytes']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
