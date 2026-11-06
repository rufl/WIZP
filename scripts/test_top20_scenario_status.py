#!/usr/bin/env python3
"""Focused tests for top-20 scenario status classification."""

from top20_scenario_status import (
    scenario_execution_status,
    scenario_followup_category,
    scenario_surface_capture_status,
    scenario_validation_surface,
    split_blocker_string,
)


def test_status_and_surface_classification() -> None:
    assert scenario_execution_status({}, False) == "blocked-reference-host-executable-unpinned"
    assert scenario_execution_status({"status": "verified"}, True) == "verified"
    assert split_blocker_string("one, two,, three") == ["one", "two", "three"]
    payload = {"normalizedDiff": {"surfaceSummary": {"wizp": {"dom": True}, "reference": {"dom": True}}}}
    assert scenario_surface_capture_status(payload) == "wizp-and-reference-surfaces-captured"


def test_followup_and_validation_classification() -> None:
    blocked = {"blockers": ["missing-ruby-runtime"]}
    assert scenario_followup_category("blocked", {}, blocked) == "runtime-dependency-missing"
    scenario = {"kind": "language", "expectedEvidence": ["diagnostics", "completion"]}
    assert scenario_validation_surface(scenario, {}, "open-scenario-follow-up") == "language-provider-payload-validation"


if __name__ == "__main__":
    test_status_and_surface_classification()
    test_followup_and_validation_classification()
    print("top20 scenario status tests ok")
