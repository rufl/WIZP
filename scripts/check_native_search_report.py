#!/usr/bin/env python3
"""Validate retained packaged-native workspace Search journey evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "build" / "ui-ux" / "native-search" / "report.json"

REQUIRED_CHECKS = (
    "workspaceFixtureSelected",
    "searchAccessible",
    "searchActivityBarOpen",
    "queryResultsShown",
    "filtersAndContextApplied",
    "caseAndWholeWordApplied",
    "invalidRegexRecovered",
    "zeroResultShown",
    "rpcFailureExposedRetry",
    "rpcFailurePreservedQuery",
    "rpcRetryRecovered",
    "cancellationClearedStaleResults",
    "resultNavigated",
    "resultLimitReported",
    "replaceOneCompleted",
    "permissionFailurePreservedFile",
    "permissionFailurePreservedState",
    "permissionRecoveryCompleted",
    "replaceAllConfirmed",
    "replaceAllFocusRestored",
    "terminalSessionsClosed",
)
REQUIRED_EVIDENCE = ("07-rpc-error", "08-permission-error", "09-final")
EXPECTED_NOT_CLAIMED = (
    "Assistive-technology sign-off",
    "macOS or Windows behavior",
)


def load_report(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read report: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"report is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("report root must be an object")
    return payload


def require_mapping(report: dict[str, Any], key: str, errors: list[str]) -> dict[str, Any]:
    value = report.get(key)
    if isinstance(value, dict):
        return value
    errors.append(f"{key} must be an object")
    return {}


def require_artifact(
    report_dir: Path,
    item: dict[str, Any],
    name: str,
    field: str,
    errors: list[str],
) -> None:
    value = item.get(field)
    if not isinstance(value, str) or not value:
        errors.append(f"evidence.{name}.{field} must be non-empty")
        return
    if not (report_dir / value).is_file():
        errors.append(f"evidence.{name}.{field} missing artifact: {value}")


def validate_accessibility(report: dict[str, Any], errors: list[str]) -> None:
    accessibility = require_mapping(report, "accessibility", errors)
    initial = accessibility.get("initial")
    if not isinstance(initial, dict):
        errors.append("accessibility.initial must be an object")
        initial = {}
    expected_initial = {
        "found": True,
        "formRole": "search",
        "queryFocused": True,
        "activeLabel": "Search files",
        "resultCount": 0,
    }
    for key, expected in expected_initial.items():
        if initial.get(key) != expected:
            errors.append(f"accessibility.initial.{key} must be {expected!r}")
    toggles = initial.get("toggles")
    expected_toggles = {
        "case": "false",
        "whole": "false",
        "regex": "false",
        "replace": "false",
        "details": "false",
    }
    if toggles != expected_toggles:
        errors.append("accessibility.initial.toggles must expose five inactive controls")

    dialog = accessibility.get("replaceAllDialog")
    if not isinstance(dialog, dict):
        errors.append("accessibility.replaceAllDialog must be an object")
        dialog = {}
    expected_dialog = {
        "open": True,
        "labelledBy": "replace-all-title",
        "title": "Replace across 2 files?",
        "buttons": ["Cancel", "Replace All"],
        "activeTag": "BUTTON",
    }
    for key, expected in expected_dialog.items():
        if dialog.get(key) != expected:
            errors.append(f"accessibility.replaceAllDialog.{key} must be {expected!r}")
    if "cannot be undone" not in str(dialog.get("description", "")):
        errors.append("accessibility.replaceAllDialog.description must retain the destructive warning")

    navigation = require_mapping(report, "navigation", errors)
    editor = navigation.get("editor")
    if not isinstance(editor, dict) or editor.get("marker") is not True or editor.get("line") != 2:
        errors.append("navigation.editor must prove the marker opened at line 2")
    result = navigation.get("result")
    if not isinstance(result, dict) or result.get("label") != "Open search-navigation.txt, line 2":
        errors.append("navigation.result.label must identify the opened result")

    states = require_mapping(report, "states", errors)
    basic = states.get("basic")
    if (
        not isinstance(basic, dict)
        or not isinstance(basic.get("query"), str)
        or not basic.get("query")
        or basic.get("resultListLabel") != "Search results"
        or basic.get("resultCount") != 5
        or not isinstance(basic.get("resultLabels"), list)
        or len(basic["resultLabels"]) != 5
    ):
        errors.append("states.basic must retain the query and five labelled results")
    filtered = states.get("filtered")
    if not isinstance(filtered, dict) or "4 matching lines in 1 file" not in str(filtered.get("summary", "")):
        errors.append("states.filtered must retain the include/exclude summary")
    bounded = states.get("bounded")
    if not isinstance(bounded, dict) or "Result limit: 100" not in str(bounded.get("summary", "")):
        errors.append("states.bounded must retain the 100-result limit")
    invalid = states.get("invalidRegex")
    if not isinstance(invalid, dict) or invalid.get("messageRole") != "alert" or "Retry" not in str(invalid.get("message", "")):
        errors.append("states.invalidRegex must retain an alert with Retry")
    rpc_failure = states.get("rpcFailure")
    if (
        not isinstance(rpc_failure, dict)
        or rpc_failure.get("messageRole") != "alert"
        or rpc_failure.get("messageAction") != "Retry"
        or rpc_failure.get("resultCount") != 0
        or rpc_failure.get("resultLabels") != []
        or "Injected one-shot search/text failure" not in str(rpc_failure.get("message", ""))
    ):
        errors.append("states.rpcFailure must retain the query and expose the injected failure with Retry")
    rpc_retry = states.get("rpcRetry")
    if (
        not isinstance(rpc_retry, dict)
        or rpc_retry.get("resultListLabel") != "Search results"
        or rpc_retry.get("resultCount") != 5
        or "5 matching lines in 2 files" not in str(rpc_retry.get("summary", ""))
    ):
        errors.append("states.rpcRetry must recover five labelled results")
    if isinstance(basic, dict) and isinstance(rpc_failure, dict) and isinstance(rpc_retry, dict):
        if rpc_failure.get("query") != basic.get("query"):
            errors.append("states.rpcFailure.query must preserve the submitted baseline query")
        if rpc_retry.get("query") != basic.get("query"):
            errors.append("states.rpcRetry.query must recover the submitted baseline query")
        if rpc_retry.get("resultLabels") != basic.get("resultLabels"):
            errors.append("states.rpcRetry.resultLabels must restore the baseline result set")

    permission_ready = states.get("permissionReady")
    if (
        not isinstance(permission_ready, dict)
        or permission_ready.get("query") != "permission-one"
        or permission_ready.get("replacement") != "permission-replaced"
        or permission_ready.get("resultListLabel") != "Search results"
        or permission_ready.get("resultCount") != 1
        or not isinstance(permission_ready.get("resultLabels"), list)
        or len(permission_ready["resultLabels"]) != 1
    ):
        errors.append("states.permissionReady must retain the writable query, replacement, and result")
    permission = states.get("permissionFailure")
    if (
        not isinstance(permission, dict)
        or permission.get("messageRole") != "alert"
        or "Replace stopped after 0 changes" not in str(permission.get("message", ""))
        or "AccessDenied" not in str(permission.get("message", ""))
    ):
        errors.append("states.permissionFailure must retain the native AccessDenied alert")
    permission_recovered = states.get("permissionRecovery")
    if (
        not isinstance(permission_recovered, dict)
        or permission_recovered.get("messageRole") != "status"
        or "Replaced 1 occurrence across 1 file" not in str(permission_recovered.get("message", ""))
        or permission_recovered.get("resultCount") != 1
    ):
        errors.append("states.permissionRecovery must retain the successful replacement state")
    if (
        isinstance(permission_ready, dict)
        and isinstance(permission, dict)
        and isinstance(permission_recovered, dict)
    ):
        for field in ("query", "replacement"):
            if permission.get(field) != permission_ready.get(field):
                errors.append(f"states.permissionFailure.{field} must preserve the pre-failure value")
            if permission_recovered.get(field) != permission_ready.get(field):
                errors.append(f"states.permissionRecovery.{field} must preserve the retry value")
        for field in ("resultCount", "resultLabels"):
            if permission.get(field) != permission_ready.get(field):
                errors.append(f"states.permissionFailure.{field} must preserve the pre-failure results")
    replaced = states.get("replaceAll")
    if not isinstance(replaced, dict) or "Replaced 3 occurrences across 2 files" not in str(replaced.get("message", "")):
        errors.append("states.replaceAll must retain the replacement completion")

    rpc_recovery = require_mapping(report, "rpcRecovery", errors)
    injection = rpc_recovery.get("injection")
    if injection != {"armed": True, "method": "search/text", "matched": 0}:
        errors.append("rpcRecovery.injection must arm one search/text failure")
    after_failure = rpc_recovery.get("afterFailure")
    if after_failure != {"armed": False, "method": "search/text", "matched": 1}:
        errors.append("rpcRecovery.afterFailure must prove exactly one injected failure")
    retry_action = rpc_recovery.get("retryAction")
    if (
        not isinstance(retry_action, dict)
        or retry_action.get("label") != "Retry"
        or not isinstance(retry_action.get("x"), int)
        or not isinstance(retry_action.get("y"), int)
    ):
        errors.append("rpcRecovery.retryAction must identify the clickable Retry button")

    permission_recovery = require_mapping(report, "permissionRecovery", errors)
    if permission_recovery.get("path") != "search-read-only.txt":
        errors.append("permissionRecovery.path must identify the read-only fixture")
    permission_action = permission_recovery.get("action")
    if (
        not isinstance(permission_action, dict)
        or permission_action.get("label") != "Replace match in search-read-only.txt on line 1"
        or not isinstance(permission_action.get("x"), int)
        or not isinstance(permission_action.get("y"), int)
    ):
        errors.append("permissionRecovery.action must retain the accessible replace-one action")
    permission_retry_action = permission_recovery.get("retryAction")
    if (
        not isinstance(permission_retry_action, dict)
        or not isinstance(permission_action, dict)
        or permission_retry_action.get("label") != permission_action.get("label")
        or not isinstance(permission_retry_action.get("x"), int)
        or not isinstance(permission_retry_action.get("y"), int)
    ):
        errors.append("permissionRecovery.retryAction must prove the replace action survived failure")
    expected_read_only = {
        "mode": "0o444",
        "writable": False,
        "content": "permission-one permission-one\n",
    }
    if permission_recovery.get("beforeFailure") != expected_read_only:
        errors.append("permissionRecovery.beforeFailure must prove the fixture was read-only")
    if permission_recovery.get("afterFailure") != expected_read_only:
        errors.append("permissionRecovery.afterFailure must prove the failure preserved the file")
    if permission_recovery.get("afterRestore") != {
        "mode": "0o644",
        "writable": True,
        "content": "permission-one permission-one\n",
    }:
        errors.append("permissionRecovery.afterRestore must prove write permission was restored")
    if permission_recovery.get("afterRetry") != {
        "mode": "0o644",
        "writable": True,
        "content": "permission-replaced permission-one\n",
    }:
        errors.append("permissionRecovery.afterRetry must prove the real retry changed one occurrence")

    terminal_teardown = require_mapping(report, "terminalTeardown", errors)
    initial_count = terminal_teardown.get("initialCount")
    initial_ids = terminal_teardown.get("initialIds")
    killed_ids = terminal_teardown.get("killedIds")
    if type(initial_count) is not int or initial_count < 1:
        errors.append("terminalTeardown.initialCount must be a positive integer")
    if (
        not isinstance(initial_ids, list)
        or not initial_ids
        or any(type(item) is not int or item < 1 for item in initial_ids)
        or len(set(initial_ids)) != len(initial_ids)
    ):
        errors.append("terminalTeardown.initialIds must contain unique positive integer IDs")
    if not isinstance(killed_ids, list) or killed_ids != initial_ids:
        errors.append("terminalTeardown.killedIds must exactly match initialIds")
    if type(initial_count) is int and isinstance(initial_ids, list) and initial_count != len(initial_ids):
        errors.append("terminalTeardown.initialCount must match initialIds")
    if terminal_teardown.get("remaining") != []:
        errors.append("terminalTeardown.remaining must be empty")


def validate_report(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        report = load_report(path)
    except ValueError as exc:
        return [str(exc)]

    if report.get("schema") != 1:
        errors.append("schema must be 1")
    if report.get("kind") != "wizp-linux-packaged-native-search":
        errors.append("kind must be wizp-linux-packaged-native-search")
    if report.get("status") != "passed":
        errors.append("status must be passed")
    if report.get("errors") != []:
        errors.append("errors must be empty")
    if not isinstance(report.get("runId"), str) or not report["runId"]:
        errors.append("runId must be non-empty")

    checks = require_mapping(report, "checks", errors)
    if checks.keys() != set(REQUIRED_CHECKS):
        errors.append(f"checks fields must be exactly {sorted(REQUIRED_CHECKS)}")
    for name in REQUIRED_CHECKS:
        if checks.get(name) is not True:
            errors.append(f"checks.{name} must be true")

    cleanup = require_mapping(report, "cleanup", errors)
    if cleanup.get("requested") is not True:
        errors.append("cleanup.requested must be true")
    if cleanup.get("forced") is not False:
        errors.append("cleanup.forced must be false")
    if cleanup.get("remainingPids") != []:
        errors.append("cleanup.remainingPids must be empty")

    profile = require_mapping(report, "profile", errors)
    if profile.get("removedAfterRun") is not True:
        errors.append("profile.removedAfterRun must be true")

    evidence = require_mapping(report, "evidence", errors)
    if evidence.keys() != set(REQUIRED_EVIDENCE):
        errors.append(f"evidence fields must be exactly {sorted(REQUIRED_EVIDENCE)}")
    report_dir = path.parent
    for name in REQUIRED_EVIDENCE:
        item = evidence.get(name)
        if not isinstance(item, dict):
            errors.append(f"evidence.{name} must be an object")
            continue
        require_artifact(report_dir, item, name, "screenshot", errors)
        require_artifact(report_dir, item, name, "ocr", errors)
    rpc_error = evidence.get("07-rpc-error")
    if isinstance(rpc_error, dict) and "Injected one-shot search/text failure" not in str(
        rpc_error.get("message", "")
    ):
        errors.append("evidence.07-rpc-error.message must retain the injected RPC failure")
    permission = evidence.get("08-permission-error")
    if isinstance(permission, dict) and "AccessDenied" not in str(permission.get("message", "")):
        errors.append("evidence.08-permission-error.message must retain AccessDenied")

    validate_accessibility(report, errors)

    not_claimed = report.get("notClaimed")
    if not isinstance(not_claimed, list):
        errors.append("notClaimed must be a list")
    else:
        for marker in EXPECTED_NOT_CLAIMED:
            if marker not in not_claimed:
                errors.append(f"notClaimed missing {marker!r}")

    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", default=str(DEFAULT_REPORT))
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    path = Path(args.report).resolve()
    errors = validate_report(path)
    if errors:
        print("native Search report contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"native Search report ok: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
