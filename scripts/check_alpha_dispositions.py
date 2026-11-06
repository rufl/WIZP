#!/usr/bin/env python3
"""Validate explicit Linux-alpha dispositions for generated parity blockers."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
LEDGER = ROOT.parent / "docs" / "vscode-parity" / "ALPHA_DISPOSITIONS.json"
SCENARIOS = ROOT / "build" / "vscode-parity" / "top20-behavior-parity.json"
BUDGETS = ROOT / "build" / "vscode-parity" / "top20-behavior-performance-budgets.json"
ALLOWED_DISPOSITIONS = {"tiered-limitation", "deferred"}
REQUIRED_FIELDS = (
    "backlogId",
    "scenarioId",
    "extensionId",
    "disposition",
    "supportedScope",
    "userVisibleLimitation",
    "evidence",
    "followUp",
)


def resolve_artifact(value: str) -> Path:
    path = Path(value)
    if path.parts and path.parts[0] == "wizp":
        return ROOT / Path(*path.parts[1:])
    return ROOT / path


def queue_items(report: dict[str, Any], queue_key: str) -> list[dict[str, Any]]:
    queue = report.get(queue_key)
    if not isinstance(queue, dict):
        raise ValueError(f"missing {queue_key}")
    items: list[dict[str, Any]] = []
    for group in queue.get("ownerGroups", []) if queue_key == "openScenarioWorkQueue" else queue.get("groups", []):
        owners = group.get("ownerGroups", []) if queue_key != "openScenarioWorkQueue" else [group]
        for owner in owners:
            raw_items = owner.get("items", [])
            if not isinstance(raw_items, list):
                raise ValueError(f"{queue_key} owner items are not a list")
            items.extend(item for item in raw_items if isinstance(item, dict))
    return items


def validate_entries(entries: Any, label: str, expected: dict[str, dict[str, Any]], errors: list[str]) -> None:
    if not isinstance(entries, list):
        errors.append(f"{label} must be a list")
        return
    seen: set[str] = set()
    actual: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append(f"{label} contains a non-object entry")
            continue
        missing = [field for field in REQUIRED_FIELDS if not isinstance(entry.get(field), str) or not entry[field].strip()]
        if missing:
            errors.append(f"{label} entry is missing: {', '.join(missing)}")
            continue
        backlog_id = entry["backlogId"]
        if backlog_id in seen:
            errors.append(f"{label} duplicates {backlog_id}")
        seen.add(backlog_id)
        actual[backlog_id] = entry
        if entry["disposition"] not in ALLOWED_DISPOSITIONS:
            errors.append(f"{backlog_id}: unsupported disposition {entry['disposition']!r}")
        evidence = resolve_artifact(entry["evidence"])
        if not evidence.is_file():
            errors.append(f"{backlog_id}: missing evidence artifact {entry['evidence']}")
        expected_row = expected.get(backlog_id)
        if expected_row is None:
            errors.append(f"{backlog_id}: disposition is not present in the generated {label} queue")
            continue
        if entry["scenarioId"] != expected_row.get("scenarioId"):
            errors.append(
                f"{backlog_id}: scenario id disagrees: ledger={entry['scenarioId']!r} report={expected_row.get('scenarioId')!r}"
            )
        if entry["extensionId"] != expected_row.get("extensionId"):
            errors.append(
                f"{backlog_id}: extension id disagrees: ledger={entry['extensionId']!r} report={expected_row.get('extensionId')!r}"
            )
    missing = sorted(set(expected) - set(actual))
    if missing:
        errors.append(f"{label} lacks generated blocker dispositions: {', '.join(missing)}")
    extra = sorted(set(actual) - set(expected))
    if extra:
        errors.append(f"{label} contains stale dispositions: {', '.join(extra)}")


def main() -> int:
    errors: list[str] = []
    try:
        ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
        scenarios = json.loads(SCENARIOS.read_text(encoding="utf-8"))
        budgets = json.loads(BUDGETS.read_text(encoding="utf-8"))
        scenario_items = queue_items(scenarios, "openScenarioWorkQueue")
        budget_items = queue_items(budgets, "budgetPromotionWorkQueue")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"alpha disposition check failed: {exc}", file=sys.stderr)
        return 1

    if ledger.get("schema") != "wizp.linux-alpha-dispositions.v1":
        errors.append("unexpected alpha disposition ledger schema")
    if ledger.get("scope") != "linux-alpha":
        errors.append("alpha disposition ledger scope is not linux-alpha")
    if ledger.get("status") != "complete-for-current-generated-blockers":
        errors.append("alpha disposition ledger is not marked complete for current generated blockers")

    expected_scenarios = {
        backlog_id: item
        for item in scenario_items
        for backlog_id in item.get("backlogIds", [])
        if isinstance(backlog_id, str)
    }
    expected_budgets = {
        backlog_id: item
        for item in budget_items
        for backlog_id in item.get("backlogIds", [])
        if isinstance(backlog_id, str)
    }
    validate_entries(ledger.get("scenarioDispositions"), "scenario dispositions", expected_scenarios, errors)
    validate_entries(ledger.get("h11eDispositions"), "H11E dispositions", expected_budgets, errors)

    if errors:
        print("alpha disposition check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "alpha dispositions ok: "
        f"{len(expected_scenarios)} scenario blocker(s), {len(expected_budgets)} H11E blocker(s) explicitly tiered/deferred"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
