"""Pure scenario artifact/status classification for the top-20 parity lane."""

from __future__ import annotations

from typing import Any


def split_blocker_string(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def scenario_execution_status(payload: dict[str, Any], reference_ready: bool) -> str:
    if not reference_ready:
        return "blocked-reference-host-executable-unpinned"
    return str(payload.get("status") or "planned")


def scenario_lane_normalized_diff(payload: dict[str, Any]) -> dict[str, Any]:
    normalized = payload.get("normalizedDiff")
    return normalized if isinstance(normalized, dict) else {"status": "not-run", "unexpectedDrift": False}


def scenario_surface_summary(payload: dict[str, Any]) -> dict[str, Any]:
    normalized = scenario_lane_normalized_diff(payload)
    summary = normalized.get("surfaceSummary")
    return summary if isinstance(summary, dict) else {}


def scenario_artifact_status(payload: dict[str, Any]) -> str:
    if not payload:
        return "missing-scenario-artifact"
    return str(payload.get("status") or "unknown-scenario-artifact-status")


def scenario_normalized_status(payload: dict[str, Any]) -> str:
    return str(scenario_lane_normalized_diff(payload).get("status") or "unknown-normalized-status")


def scenario_runtime_modes(scenario: dict[str, Any], payload: dict[str, Any]) -> list[str]:
    modes = payload.get("runtimeModes") if isinstance(payload.get("runtimeModes"), list) else scenario.get("runtimeModes")
    return [str(value) for value in modes if isinstance(value, str)] if isinstance(modes, list) else []


def scenario_payload_lane_groups(scenario: dict[str, Any], payload: dict[str, Any]) -> list[str]:
    groups = payload.get("laneGroups") if isinstance(payload.get("laneGroups"), list) else scenario.get("laneGroups")
    return [str(value) for value in groups if isinstance(value, str)] if isinstance(groups, list) else []


def scenario_expected_evidence(scenario: dict[str, Any], payload: dict[str, Any]) -> list[str]:
    expected = payload.get("expectedEvidence") if isinstance(payload.get("expectedEvidence"), list) else scenario.get("expectedEvidence")
    return [str(value) for value in expected if isinstance(value, str)] if isinstance(expected, list) else []


def scenario_surface_capture_status(payload: dict[str, Any]) -> str:
    summary = scenario_surface_summary(payload)
    wizp_summary = summary.get("wizp") if isinstance(summary.get("wizp"), dict) else {}
    reference_summary = summary.get("reference") if isinstance(summary.get("reference"), dict) else {}
    if wizp_summary and reference_summary:
        return "wizp-and-reference-surfaces-captured"
    if wizp_summary:
        return "wizp-surface-captured"
    if reference_summary:
        return "reference-surface-captured"
    return "no-surface-summary"


def scenario_followup_category(scenario_status: str, ownership: dict[str, Any], payload: dict[str, Any]) -> str:
    owner = str(ownership.get("owner") or "")
    bucket = str(ownership.get("bucket") or "")
    artifact_status = scenario_artifact_status(payload)
    normalized = scenario_lane_normalized_diff(payload)
    blockers = payload.get("blockers") if isinstance(payload.get("blockers"), list) else []
    blocker_text = " ".join(str(value) for value in blockers if isinstance(value, str))
    if scenario_status == "blocked" or "blocked" in artifact_status or bucket == "runtime-blocked":
        return "runtime-dependency-missing" if "missing-ruby-runtime" in blocker_text else "runtime-or-host-blocker"
    if owner == "policy-bound-feature" or bucket == "policy":
        return "policy-decision"
    if normalized.get("unexpectedDrift"):
        return "unexpected-drift-review"
    if artifact_status == "paired-generic-scenario-partial" and scenario_normalized_status(payload) == "paired-generic-survey-captured":
        return "scenario-specific-payload-validation"
    if artifact_status.endswith("-partial"):
        return "specialized-scenario-evidence-gap"
    if artifact_status == "missing-scenario-artifact":
        return "missing-scenario-artifact"
    return "open-scenario-follow-up"


def scenario_validation_surface(scenario: dict[str, Any], payload: dict[str, Any], followup_category: str) -> str:
    kind = str(payload.get("kind") or scenario.get("kind") or "")
    expected = set(scenario_expected_evidence(scenario, payload))
    if followup_category == "runtime-dependency-missing":
        return "ruby-runtime-dependency"
    if followup_category == "policy-decision":
        return {
            "ai-offline": "ai-offline-policy-decision",
            "ai-network": "ai-opt-in-network-policy-decision",
            "network-auth": "scm-auth-network-policy-decision",
        }.get(kind, "policy-decision")
    evidence_surfaces = (
        ({"diagnostics", "completion", "hover"}, "language-provider-payload-validation"),
        ({"dapTrace", "breakpointStop", "breakpoints", "stack", "variables", "evaluate"}, "debug-session-payload-validation"),
        ({"generatedConfigs", "schemaDiagnostics", "selectorState", "launchSchema", "adapterPath"}, "debug-config-payload-validation"),
        ({"testTree", "testResults", "passFailSkipped", "rerunState"}, "test-lifecycle-payload-validation"),
        ({"containerList", "imageList"}, "container-runtime-payload-validation"),
        ({"taskOutput", "problemMatcher", "terminalMetadata"}, "task-runtime-payload-validation"),
        ({"treeNodes", "refreshState"}, "tree-view-payload-validation"),
        ({"blameAnnotations", "historyViews", "commitDetails", "revisionFiles", "gitApiCalls"}, "scm-history-payload-validation"),
        ({"dependencyGraph", "activationOrder", "unsupportedChildren"}, "extension-pack-rollup-validation"),
        ({"interpreterList", "selectedInterpreter", "terminalEnv"}, "interpreter-workflow-payload-validation"),
        ({"commandInvocations", "commandOutput"}, "command-workflow-payload-validation"),
        ({"activationTrace", "languageStatus", "settingsDiff", "cacheState"}, "lifecycle-payload-validation"),
        ({"notifications", "actionButtons", "settingsIntent", "telemetryAudit"}, "degraded-runtime-ux-validation"),
    )
    for required, surface in evidence_surfaces:
        if required & expected:
            return surface
    return followup_category or "open-scenario-validation"
