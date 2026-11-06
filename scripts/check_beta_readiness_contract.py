#!/usr/bin/env python3
"""Validate that beta-readiness JSON is internally consistent and conservative."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "release" / "beta-readiness.json"


def validate(payload: dict) -> None:
    if payload.get("schema") != "wizp.beta-readiness.v1":
        raise AssertionError(f"unexpected beta readiness schema: {payload.get('schema')!r}")
    blockers = payload.get("knownBlockers")
    if not isinstance(blockers, list) or not all(isinstance(item, str) for item in blockers):
        raise AssertionError("knownBlockers must be a list of strings")
    status = payload.get("status")
    if status == "ready" and blockers:
        raise AssertionError("ready report cannot contain known blockers")
    if status == "blocked" and not blockers:
        raise AssertionError("blocked report must explain at least one blocker")
    if status not in {"ready", "blocked"}:
        raise AssertionError(f"unexpected beta readiness status: {status!r}")

    backlog = payload.get("backlog")
    if not isinstance(backlog, dict):
        raise AssertionError("backlog summary is missing")
    platform_blockers = {
        "PROD-B02": "Windows ConPTY",
        "PROD-B03": "macOS native shell",
    }
    for item_id, blocker_marker in platform_blockers.items():
        if str(backlog.get(item_id, "missing")).startswith("open") and not any(
            blocker_marker in item for item in blockers
        ):
            raise AssertionError(f"open {item_id} must remain visible in knownBlockers")

    cross_os = payload.get("crossOs")
    if not isinstance(cross_os, dict):
        raise AssertionError("crossOs summary is missing")
    missing = set(cross_os.get("artifactMissingSystems", []))
    valid = set(cross_os.get("artifactValidSystems", []))
    if missing & valid:
        raise AssertionError(f"cross-OS valid/missing overlap: {sorted(missing & valid)}")
    expected_cross_status = "partial" if missing else "cross-os-artifacts-verified"
    if cross_os.get("artifactStatus") != expected_cross_status:
        raise AssertionError("cross-OS status does not match its system partition")
    if missing and not any("macOS/Windows" in item or "Linux-only" in item for item in blockers):
        raise AssertionError("missing cross-OS systems must remain visible in blockers")

    stress = payload.get("stress")
    if not isinstance(stress, dict):
        raise AssertionError("stress summary is missing")
    ci_count = stress.get("trendCiHistoryCount")
    required = stress.get("trendRequiredHistory")
    if ci_count is not None and (not isinstance(ci_count, int) or ci_count < 0):
        raise AssertionError("stress CI history count must be a non-negative integer")
    if required is not None and (not isinstance(required, int) or required < 0):
        raise AssertionError("stress required history must be a non-negative integer")
    if stress.get("trendReady") is True and ci_count is not None and required is not None and ci_count < required:
        raise AssertionError("stress trend cannot be ready below its required CI history")


def main() -> int:
    if not REPORT.exists():
        raise AssertionError(f"missing beta readiness artifact: {REPORT.relative_to(ROOT)}")
    validate(json.loads(REPORT.read_text(encoding="utf-8")))
    print(f"beta readiness contract ok: {REPORT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
