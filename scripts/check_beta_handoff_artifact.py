#!/usr/bin/env python3
"""Validate the beta evidence handoff as one consistent bundle."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

try:
    from check_beta_readiness_contract import validate as validate_beta
    from check_cross_os_artifact_contract import validate_aggregate
    from check_stress_ci_history import validate as validate_stress
except ModuleNotFoundError:
    from scripts.check_beta_readiness_contract import validate as validate_beta
    from scripts.check_cross_os_artifact_contract import validate_aggregate
    from scripts.check_stress_ci_history import validate as validate_stress


ROOT = Path(__file__).resolve().parents[1]
BETA_REPORT = ROOT / "build" / "release" / "beta-readiness.json"
CROSS_OS_REPORT = ROOT / "build" / "parity-package" / "cross-os-artifact-report.json"
STRESS_TREND_REPORT = ROOT / "build" / "parity-stress" / "stress-trend-report.json"


def load(path: Path) -> dict:
    if not path.exists():
        raise AssertionError(f"missing beta handoff artifact: {path.relative_to(ROOT)}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise AssertionError(f"handoff artifact is not an object: {path.relative_to(ROOT)}")
    return payload


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_recorded_artifact_hashes(beta: dict, artifact_root: Path) -> None:
    artifacts = beta.get("artifacts")
    if not isinstance(artifacts, dict) or not artifacts:
        raise AssertionError("beta handoff artifacts must be a non-empty object")

    root = artifact_root.resolve()
    checked = 0

    def visit(value: object, location: str) -> None:
        nonlocal checked
        if isinstance(value, list):
            for index, item in enumerate(value):
                visit(item, f"{location}[{index}]")
            return
        if not isinstance(value, dict):
            return

        has_path = "path" in value
        has_hash = value.get("sha256") is not None
        if has_path and value.get("present") is False and not has_hash:
            pass
        elif has_path or has_hash:
            raw_path = value.get("path")
            expected = value.get("sha256")
            if not isinstance(raw_path, str) or not raw_path:
                raise AssertionError(f"{location} has an invalid artifact path")
            if (
                not isinstance(expected, str)
                or len(expected) != 64
                or any(character not in "0123456789abcdefABCDEF" for character in expected)
            ):
                raise AssertionError(f"{location} has an invalid artifact sha256")

            candidate = (root / raw_path).resolve()
            try:
                candidate.relative_to(root)
            except ValueError as exc:
                raise AssertionError(
                    f"{location} artifact path escapes the handoff root: {raw_path}"
                ) from exc
            if not candidate.is_file():
                raise AssertionError(f"{location} artifact is missing: {raw_path}")

            actual = sha256(candidate)
            if actual != expected.lower():
                raise AssertionError(
                    f"{location} artifact sha256 mismatch for {raw_path}: "
                    f"expected {expected.lower()}, found {actual}"
                )
            checked += 1

        for key, item in value.items():
            visit(item, f"{location}.{key}")

    visit(artifacts, "artifacts")
    if checked == 0:
        raise AssertionError("beta handoff does not record any artifact path+sha256 evidence")


def validate_bundle(
    beta: dict,
    cross_os: dict,
    stress_trend: dict,
    artifact_root: Path | None = None,
) -> None:
    validate_beta(beta)
    validate_aggregate(cross_os)
    validate_stress(stress_trend)
    summary = beta.get("crossOs", {})
    if summary.get("artifactStatus") != cross_os.get("status"):
        raise AssertionError("beta summary and cross-OS artifact status disagree")
    if set(summary.get("artifactMissingSystems", [])) != set(cross_os.get("missingSystems", [])):
        raise AssertionError("beta summary and cross-OS artifact missing systems disagree")
    if set(summary.get("artifactValidSystems", [])) != set(cross_os.get("validSystems", [])):
        raise AssertionError("beta summary and cross-OS artifact valid systems disagree")
    stress_summary = beta.get("stress", {})
    field_pairs = {
        "trendStatus": "status",
        "trendHistoryCount": "historyCount",
        "trendCiHistoryCount": "ciHistoryCount",
        "trendMissingCiHistoryCount": "missingCiHistoryCount",
        "trendRequiredHistory": "requiredHistoryForTrend",
        "trendRequiredSource": "requiredSourceForTrend",
        "trendReady": "trendReady",
    }
    for summary_field, artifact_field in field_pairs.items():
        if stress_summary.get(summary_field) != stress_trend.get(artifact_field):
            raise AssertionError(
                f"beta summary and stress artifact disagree on {summary_field}"
            )
    if artifact_root is not None:
        validate_recorded_artifact_hashes(beta, artifact_root)


def main() -> int:
    validate_bundle(
        load(BETA_REPORT),
        load(CROSS_OS_REPORT),
        load(STRESS_TREND_REPORT),
        artifact_root=ROOT,
    )
    print("beta handoff artifact ok: readiness, cross-OS, and stress reports agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
