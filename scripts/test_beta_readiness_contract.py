#!/usr/bin/env python3
"""Focused tests for the beta-readiness consistency contract."""

from __future__ import annotations

import unittest

from scripts.check_beta_readiness_contract import validate
from scripts.check_beta_handoff_artifact import validate_bundle


def payload() -> dict:
    return {
        "schema": "wizp.beta-readiness.v1",
        "status": "blocked",
        "knownBlockers": [
            "macOS/Windows clean-runner package evidence is still required",
            "Windows ConPTY backend and clean-runner terminal proof remain open",
            "macOS native shell, WebView, and PTY clean-runner proof remain open",
        ],
        "backlog": {
            "PROD-B02": "open",
            "PROD-B03": "open",
        },
        "crossOs": {
            "artifactStatus": "partial",
            "artifactMissingSystems": ["darwin", "windows"],
            "artifactValidSystems": ["linux"],
        },
        "stress": {
            "trendStatus": "trend-baseline-recorded",
            "trendHistoryCount": 3,
            "trendCiHistoryCount": 0,
            "trendMissingCiHistoryCount": 3,
            "trendRequiredHistory": 3,
            "trendRequiredSource": "github-actions",
            "trendReady": False,
        },
    }


def cross_os_payload() -> dict:
    return {
        "schema": "wizp.cross-os-artifacts.v1",
        "status": "partial",
        "requiredSystems": ["darwin", "linux", "windows"],
        "validSystems": ["linux"],
        "missingSystems": ["darwin", "windows"],
        "reports": [{"os": "linux", "valid": True}],
    }


def stress_payload() -> dict:
    return {
        "schema": "wizp.stress-trend.v1",
        "status": "trend-baseline-recorded",
        "historyCount": 3,
        "ciHistoryCount": 0,
        "missingCiHistoryCount": 3,
        "requiredHistoryForTrend": 3,
        "requiredSourceForTrend": "github-actions",
        "trendReady": False,
    }


class BetaReadinessContractTests(unittest.TestCase):
    def test_current_blocked_report_is_valid(self) -> None:
        validate(payload())

    def test_ready_report_cannot_keep_blockers(self) -> None:
        report = payload()
        report["status"] = "ready"
        with self.assertRaisesRegex(AssertionError, "ready report"):
            validate(report)

    def test_cross_os_partition_must_match_status(self) -> None:
        report = payload()
        report["crossOs"]["artifactStatus"] = "cross-os-artifacts-verified"
        with self.assertRaisesRegex(AssertionError, "cross-OS status"):
            validate(report)

    def test_stress_trend_cannot_be_ready_below_requirement(self) -> None:
        report = payload()
        report["stress"].update({"trendReady": True, "trendCiHistoryCount": 1})
        with self.assertRaisesRegex(AssertionError, "stress trend"):
            validate(report)

    def test_stress_counts_must_be_non_negative_integers(self) -> None:
        report = payload()
        report["stress"]["trendCiHistoryCount"] = -1
        with self.assertRaisesRegex(AssertionError, "non-negative integer"):
            validate(report)

    def test_open_windows_platform_row_requires_blocker(self) -> None:
        report = payload()
        report["knownBlockers"] = [
            item for item in report["knownBlockers"] if "Windows ConPTY" not in item
        ]
        with self.assertRaisesRegex(AssertionError, "PROD-B02"):
            validate(report)

    def test_open_macos_platform_row_requires_blocker(self) -> None:
        report = payload()
        report["knownBlockers"] = [
            item for item in report["knownBlockers"] if "macOS native shell" not in item
        ]
        with self.assertRaisesRegex(AssertionError, "PROD-B03"):
            validate(report)

    def test_handoff_bundle_accepts_matching_stress_summary(self) -> None:
        validate_bundle(payload(), cross_os_payload(), stress_payload())

    def test_handoff_bundle_rejects_stress_count_drift(self) -> None:
        stress = stress_payload()
        stress["missingCiHistoryCount"] = 2
        with self.assertRaisesRegex(AssertionError, "trendMissingCiHistoryCount"):
            validate_bundle(payload(), cross_os_payload(), stress)


if __name__ == "__main__":
    unittest.main()
