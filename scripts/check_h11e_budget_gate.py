#!/usr/bin/env python3
"""Validate that H11E blockers remain actionable and artifact-backed."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "vscode-parity" / "top20-behavior-performance-budgets.json"


def artifact_path(value: str) -> Path:
    path = Path(value)
    if path.parts and path.parts[0] == "wizp":
        return ROOT / Path(*path.parts[1:])
    return ROOT / path


def main() -> int:
    report_path = Path(sys.argv[1]) if len(sys.argv) > 1 else REPORT
    report = json.loads(report_path.read_text(encoding="utf-8"))
    queue = report.get("budgetPromotionWorkQueue", {})
    groups = queue.get("groups", [])
    errors: list[str] = []

    if report.get("budgetPromotionGateStatus") not in {"partial-budget-promotion-gate", "closed-budget-promotion-gate"}:
        errors.append("unexpected H11E promotion-gate status")

    blocked = sum(int(group.get("blockedScenarioCount", 0)) for group in groups)
    items = [item for group in groups for owner in group.get("ownerGroups", []) for item in owner.get("items", [])]
    if blocked != len(items):
        errors.append(f"blocked count {blocked} does not equal actionable item count {len(items)}")

    scenario_ids = [item.get("scenarioId") for item in items]
    duplicate_scenarios = sorted({value for value in scenario_ids if value and scenario_ids.count(value) > 1})
    if duplicate_scenarios:
        errors.append(f"duplicate blocked scenario ids: {', '.join(duplicate_scenarios)}")

    owner_counts: dict[str, int] = {}
    bucket_counts: dict[str, int] = {}
    failed_check_counts: dict[str, int] = {}

    for item in items:
        scenario = item.get("scenarioId", "<unknown>")
        owner = item.get("owner")
        bucket = item.get("bucket")
        if owner:
            owner_counts[owner] = owner_counts.get(owner, 0) + 1
        if bucket:
            bucket_counts[bucket] = bucket_counts.get(bucket, 0) + 1
        for field in ("owner", "bucket", "status", "measurementArtifact"):
            if not item.get(field):
                errors.append(f"{scenario}: missing {field}")
        if item.get("status") != "blocked":
            errors.append(f"{scenario}: queue item is not blocked")
        artifact = item.get("measurementArtifact")
        if artifact and not artifact_path(artifact).is_file():
            errors.append(f"{scenario}: missing measurement artifact {artifact}")
        if artifact and artifact_path(artifact).is_file():
            measurement = json.loads(artifact_path(artifact).read_text(encoding="utf-8"))
            budget_checks = measurement.get("budgetChecks")
            if not isinstance(budget_checks, dict):
                errors.append(f"{scenario}: measurement artifact has no budgetChecks object")
            else:
                failed_checks = item.get("failedBudgetChecks")
                if not isinstance(failed_checks, list) or not failed_checks:
                    errors.append(f"{scenario}: queue item has no failedBudgetChecks")
                else:
                    if len(failed_checks) != len(set(failed_checks)):
                        errors.append(f"{scenario}: failedBudgetChecks contains duplicates")
                    for check in failed_checks:
                        failed_check_counts[check] = failed_check_counts.get(check, 0) + 1
                        if check not in budget_checks:
                            errors.append(f"{scenario}: failed budget check {check} is absent from measurement artifact")
                        elif budget_checks[check] is not False:
                            errors.append(f"{scenario}: failed budget check {check} is not false in measurement artifact")

    expected_owner_counts = report.get("budgetPromotionBudgetRuleOwnerCounts")
    if expected_owner_counts != owner_counts:
        errors.append(f"owner counts disagree: queue={owner_counts!r} report={expected_owner_counts!r}")
    expected_bucket_counts = report.get("budgetPromotionBudgetRuleBucketCounts")
    if expected_bucket_counts != bucket_counts:
        errors.append(f"bucket counts disagree: queue={bucket_counts!r} report={expected_bucket_counts!r}")
    expected_failed_check_counts = report.get("budgetPromotionFailedBudgetCheckCounts")
    if expected_failed_check_counts is not None and expected_failed_check_counts != failed_check_counts:
        errors.append(
            f"failed-check counts disagree: queue={failed_check_counts!r} report={expected_failed_check_counts!r}"
        )
    expected_work_queue_counts = report.get("budgetPromotionWorkQueueCounts", {})
    if expected_work_queue_counts.get("wizpBudgetPassRules") != len(items):
        errors.append("work-queue wizpBudgetPassRules count does not equal actionable item count")

    if errors:
        print("H11E budget gate check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"H11E budget gate ok: {len(items)} actionable blocked scenarios")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
