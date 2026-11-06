#!/usr/bin/env python3
"""Print the remaining beta evidence gates from generated reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BETA_REPORT = ROOT / "build" / "release" / "beta-readiness.json"
CROSS_OS_REPORT = ROOT / "build" / "parity-package" / "cross-os-artifact-report.json"
STRESS_TREND_REPORT = ROOT / "build" / "parity-stress" / "stress-trend-report.json"


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"_artifactError": str(exc), "_artifactPath": str(path.relative_to(ROOT))}
    if not isinstance(data, dict):
        return {"_artifactError": "top-level JSON value is not an object", "_artifactPath": str(path.relative_to(ROOT))}
    return data


def status_line(label: str, ok: bool, detail: str) -> str:
    marker = "PASS" if ok else "OPEN"
    return f"[{marker}] {label}: {detail}"


def is_cross_os_blocker(blocker: str) -> bool:
    text = blocker.lower()
    return any(
        term in text
        for term in (
            "macos",
            "windows",
            "cross-os",
            "linux-only",
            "external macos",
            "external os",
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ignore-cross-os", action="store_true", help="only fail on non-OS beta evidence gates")
    args = parser.parse_args()

    beta = load_json(BETA_REPORT)
    cross_os = load_json(CROSS_OS_REPORT)
    stress = load_json(STRESS_TREND_REPORT)

    valid_systems = cross_os.get("validSystems") or beta.get("crossOs", {}).get("artifactValidSystems") or []
    missing_systems = cross_os.get("missingSystems") or beta.get("crossOs", {}).get("artifactMissingSystems") or ["linux", "darwin", "windows"]
    stress_status = stress.get("status") or beta.get("stress", {}).get("trendStatus")
    history_count = stress.get("historyCount", 0)
    ci_history_count = stress.get("ciHistoryCount", 0)
    required_history = stress.get("requiredHistoryForTrend", 3)
    required_source = stress.get("requiredSourceForTrend", "github-actions")
    missing_ci_history = stress.get("missingCiHistoryCount")
    if not isinstance(missing_ci_history, int):
        missing_ci_history = max(0, required_history - ci_history_count)
    blockers = beta.get("knownBlockers", [])
    for data in (beta, cross_os, stress):
        if data.get("_artifactError"):
            blockers.append(f"artifact {data.get('_artifactPath')} could not be parsed: {data.get('_artifactError')}")
    if args.ignore_cross_os:
        blockers = [blocker for blocker in blockers if not is_cross_os_blocker(str(blocker))]

    readiness_status = "artifact-error" if beta.get("_artifactError") else beta.get("status", "missing")
    print(f"beta readiness: {readiness_status}")
    if not args.ignore_cross_os:
        print(status_line("cross-OS package evidence", not missing_systems, f"valid={valid_systems or []} missing={missing_systems or []}"))
    print(
        status_line(
            "stress trend history",
            stress_status == "trend-verified",
            f"status={stress_status or 'missing'} ciSamples={ci_history_count}/{required_history} missingCiSamples={missing_ci_history} totalSamples={history_count} requiredSource={required_source}",
        )
    )
    if args.ignore_cross_os:
        non_os_ok = stress_status == "trend-verified"
        detail = "cross-OS artifact evidence ignored; stress trend must still pass"
        print(status_line("non-OS beta gates", non_os_ok, detail))
    if blockers:
        print("known blockers:")
        for blocker in blockers:
            print(f"- {blocker}")
    else:
        print("known blockers: none")

    if args.ignore_cross_os:
        return 0 if stress_status == "trend-verified" else 1
    return 0 if beta.get("status") == "ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
