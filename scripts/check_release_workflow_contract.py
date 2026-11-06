#!/usr/bin/env python3
"""Validate the CI wiring required to close WIZP release evidence gates."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "parity-hardening.yml"


def require(text: str, marker: str) -> None:
    if marker not in text:
        raise AssertionError(f"release workflow contract missing: {marker}")


def validate_workflow_contract(text: str) -> dict[str, object]:
    for marker in (
        "workflow_dispatch:",
        "schedule:",
        "os: [ubuntu-latest, macos-latest, windows-latest]",
        "--expected-runner",
        "parity_cross_os_package_smoke.py",
        "name: parity-package-report-${{ matrix.os }}",
        "--record-history",
        "name: parity-stress-report",
        "needs: [real-extension-smoke, cross-os-package-smoke, stress-budgets, network-policy, api-drift]",
        "name: beta-readiness-report",
        "Validate release evidence handoff",
        "scripts/check_release_evidence_runbook.py",
        "npm run test:beta-readiness",
        "continue-on-error: true",
        "scripts/cross_os_artifact_report.py || true",
        "npm run check:cross-os-artifacts",
        "npm run test:stress-ci-history",
        "npm run check:beta-readiness",
        "npm run check:beta-handoff",
        "wizp/build/parity-package/cross-os-artifact-report.json",
        "wizp/build/parity-stress/stress-trend-report.json",
    ):
        require(text, marker)
    return {
        "workflow": str(WORKFLOW.relative_to(ROOT)),
        "crossOsMatrix": ["ubuntu-latest", "macos-latest", "windows-latest"],
        "stressHistoryRecording": True,
        "betaAggregation": True,
        "status": "release-workflow-contract-verified",
    }


def main() -> int:
    if not WORKFLOW.exists():
        raise AssertionError(f"missing release workflow: {WORKFLOW}")
    result = validate_workflow_contract(WORKFLOW.read_text(encoding="utf-8"))
    print(f"release workflow contract ok: {result['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
