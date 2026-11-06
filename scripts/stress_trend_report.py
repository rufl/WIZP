#!/usr/bin/env python3
"""Summarize local stress artifacts and available trend history."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STRESS_DIR = ROOT / "build" / "parity-stress"
REPORT = STRESS_DIR / "stress-trend-report.json"


def load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def metric_at(data: dict | None, *keys: str) -> object:
    value: object = data or {}
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def trend_history() -> list[dict]:
    history_dir = STRESS_DIR / "history"
    samples = []
    for path in sorted(history_dir.glob("*.json")):
        data = load_json(path)
        if isinstance(data, dict):
            samples.append(
                {
                    "path": str(path.relative_to(ROOT)),
                    "status": data.get("status"),
                    "source": data.get("source", "local-legacy"),
                    "recordedAt": data.get("recordedAt"),
                    "metrics": data.get("metrics", {}),
                }
            )
    return samples


def history_by_source(history: list[dict]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in history:
        source = str(item.get("source") or "unknown")
        counts[source] = counts.get(source, 0) + 1
    return dict(sorted(counts.items()))


def collect_metrics() -> tuple[dict, list[str]]:
    stress = load_json(STRESS_DIR / "stress-report.json")
    startup = load_json(STRESS_DIR / "startup-benchmark.json")
    packaged = load_json(STRESS_DIR / "startup-benchmark-packaged.json")
    gui = load_json(STRESS_DIR / "gui-startup-benchmark.json")
    metrics = {
        "terminalStartupSamples": metric_at(stress, "samples", "startupTerminal"),
        "largeRepoSearch": metric_at(stress, "samples", "largeRepoSearch"),
        "largeFileRead": metric_at(stress, "samples", "largeFileRead"),
        "crashRecoveryCount": len(metric_at(stress, "samples", "crashRecovery") or []),
        "scriptMemoryGrowthKb": metric_at(stress, "samples", "scriptMemoryGrowthKb"),
        "devStartupTotalP50Ms": metric_at(startup, "summary", "totalMeasuredMs", "p50"),
        "packagedStartupTotalP50Ms": metric_at(packaged, "summary", "totalMeasuredMs", "p50"),
        "guiFirstInteractiveP50Ms": metric_at(gui, "summary", "processToFirstInteractiveProofMs", "p50"),
    }
    missing = [
        name
        for name, value in metrics.items()
        if value is None or value == [] or value == 0 and name == "crashRecoveryCount"
    ]
    return metrics, missing


def sample_source() -> dict:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return {
            "source": "github-actions",
            "githubRunId": os.environ.get("GITHUB_RUN_ID"),
            "githubRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "githubWorkflow": os.environ.get("GITHUB_WORKFLOW"),
            "githubRefName": os.environ.get("GITHUB_REF_NAME"),
            "githubRunnerOs": os.environ.get("RUNNER_OS"),
        }
    return {"source": "local-manual"}


def record_history_sample(metrics: dict) -> Path:
    history_dir = STRESS_DIR / "history"
    history_dir.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    path = history_dir / f"{timestamp.replace(':', '').replace('-', '')}.json"
    payload = {
        "schema": "wizp.stress-trend-history.v1",
        "recordedAt": timestamp,
        "status": "trend-baseline-recorded",
        **sample_source(),
        "metrics": metrics,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-history", action="store_true", help="append the current metrics as a trend history sample")
    args = parser.parse_args()
    metrics, missing = collect_metrics()
    recorded_history_path = None
    if args.record_history and not missing:
        recorded_history_path = record_history_sample(metrics)
    history = trend_history()
    required_history = 3
    required_source = "github-actions"
    ci_history = [
        item
        for item in history
        if item.get("source") == required_source
        and item.get("status") in {"trend-baseline-recorded", "trend-verified"}
    ]
    missing_ci_history = max(0, required_history - len(ci_history))
    status = "trend-baseline-recorded"
    if missing:
        status = "blocked"
    elif missing_ci_history == 0:
        status = "trend-verified"
    next_actions = []
    if missing:
        next_actions.append("generate all local stress/startup/gui artifacts before recording trend history")
    if missing_ci_history > 0:
        next_actions.append(f"collect {missing_ci_history} more scheduled github-actions stress trend sample(s)")
    payload = {
        "schema": "wizp.stress-trend.v1",
        "status": status,
        "trendReady": status == "trend-verified",
        "metrics": metrics,
        "historySamples": history,
        "historyCount": len(history),
        "ciHistoryCount": len(ci_history),
        "missingCiHistoryCount": missing_ci_history,
        "requiredHistoryForTrend": required_history,
        "requiredSourceForTrend": required_source,
        "historyBySource": history_by_source(history),
        "nextActions": next_actions,
        "recordedHistoryPath": str(recorded_history_path.relative_to(ROOT)) if recorded_history_path else None,
        "artifacts": {
            "stress": "build/parity-stress/stress-report.json",
            "startup": "build/parity-stress/startup-benchmark.json",
            "packagedStartup": "build/parity-stress/startup-benchmark-packaged.json",
            "guiStartup": "build/parity-stress/gui-startup-benchmark.json",
        },
        "missing": missing,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"stress trend report: {REPORT} ({status})")
    return 0 if status != "blocked" else 1


if __name__ == "__main__":
    raise SystemExit(main())
