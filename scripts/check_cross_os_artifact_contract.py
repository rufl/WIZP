#!/usr/bin/env python3
"""Validate the aggregate cross-OS evidence artifact without requiring all OSes."""

from __future__ import annotations

import json
from pathlib import Path

try:
    from cross_os_artifact_report import REQUIRED_PROOF, REPORT, ROOT
except ModuleNotFoundError:
    from scripts.cross_os_artifact_report import REQUIRED_PROOF, REPORT, ROOT


def validate_aggregate(payload: dict) -> None:
    if payload.get("schema") != "wizp.cross-os-artifacts.v1":
        raise AssertionError(f"unexpected cross-OS artifact schema: {payload.get('schema')!r}")
    required = set(REQUIRED_PROOF)
    required_report = set(payload.get("requiredSystems", []))
    valid = set(payload.get("validSystems", []))
    missing = set(payload.get("missingSystems", []))
    if required_report != required:
        raise AssertionError(f"required system set drift: {sorted(required_report)}")
    if valid & missing or valid | missing != required:
        raise AssertionError(f"valid/missing system partition is inconsistent: valid={sorted(valid)} missing={sorted(missing)}")
    report_systems = {item.get("os") for item in payload.get("reports", []) if item.get("valid") is True}
    if report_systems != valid:
        raise AssertionError(f"validSystems disagrees with report validations: {sorted(valid)} vs {sorted(report_systems)}")
    expected_status = "cross-os-artifacts-verified" if not missing else "partial"
    if payload.get("status") != expected_status:
        raise AssertionError(f"aggregate status does not match missing systems: {payload.get('status')!r}")


def main() -> int:
    if not REPORT.exists():
        raise AssertionError(f"missing aggregate artifact: {REPORT.relative_to(ROOT)}")
    validate_aggregate(json.loads(REPORT.read_text(encoding="utf-8")))
    print(f"cross-OS artifact contract ok: {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
