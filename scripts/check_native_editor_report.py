#!/usr/bin/env python3
"""Validate retained packaged-native editor journey evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "build" / "ui-ux" / "native-editor" / "report.json"

REQUIRED_CHECKS = (
    "workspaceFixtureSelected",
    "openedFixtureFile",
    "editedAndSaved",
    "saveAsCreatedFile",
    "savePermissionFailurePreservedEditor",
    "dirtyCloseDialogAccessible",
    "dirtyCloseCancelled",
    "dirtyCloseDiscarded",
    "reopenedSavedContent",
    "rendererReloadRestoredSavedContent",
    "processRestartRestoredSavedContent",
    "closeAllEditorsReturnedWelcome",
)

REQUIRED_EVIDENCE = (
    "01-open",
    "02-save-as",
    "03-save-failure",
    "02-dirty-close",
    "06-reopen",
    "07-session-restore",
    "08-process-restart-restore",
    "09-close-all",
)

EXPECTED_ACTION_LABELS = [
    "Split editor group right",
    "Split editor group down",
    "Create new file in editor group",
    "Close editor group",
]

EXPECTED_NOT_CLAIMED = (
    "Manual native Save As chooser review",
    "Assistive-technology sign-off",
    "macOS or Windows behavior",
)

NATIVE_SAVE_CHOOSER_NOT_CLAIMED = "Native Save As chooser smoke"


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


def validate_report(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        report = load_report(path)
    except ValueError as exc:
        return [str(exc)]

    if report.get("schema") != 1:
        errors.append("schema must be 1")
    if report.get("kind") != "wizp-linux-packaged-native-editor":
        errors.append("kind must be wizp-linux-packaged-native-editor")
    if report.get("status") != "passed":
        errors.append("status must be passed")
    if report.get("errors") != []:
        errors.append("errors must be empty")
    if not isinstance(report.get("runId"), str) or not report["runId"]:
        errors.append("runId must be non-empty")

    checks = require_mapping(report, "checks", errors)
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

    evidence = require_mapping(report, "evidence", errors)
    report_dir = path.parent
    for name in REQUIRED_EVIDENCE:
        item = evidence.get(name)
        if not isinstance(item, dict):
            errors.append(f"evidence.{name} must be an object")
            continue
        for field in ("screenshot", "ocr"):
            value = item.get(field)
            if not isinstance(value, str) or not value:
                errors.append(f"evidence.{name}.{field} must be non-empty")
                continue
            artifact = report_dir / value
            if not artifact.is_file():
                errors.append(f"evidence.{name}.{field} missing artifact: {value}")


    if checks.get("nativeSaveAsChooserReviewed") is True:
        item = evidence.get("02-native-save-dialog")
        if not isinstance(item, dict):
            errors.append("evidence.02-native-save-dialog must be an object when native Save As chooser is reviewed")
        else:
            for field in ("screenshot", "ocr"):
                value = item.get(field)
                if not isinstance(value, str) or not value:
                    errors.append(f"evidence.02-native-save-dialog.{field} must be non-empty")
                    continue
                artifact = report_dir / value
                if not artifact.is_file():
                    errors.append(f"evidence.02-native-save-dialog.{field} missing artifact: {value}")
            if not isinstance(item.get("windowName"), str):
                errors.append("evidence.02-native-save-dialog.windowName must be a string")
            if isinstance(item.get("windowId"), bool) or not isinstance(item.get("windowId"), int):
                errors.append("evidence.02-native-save-dialog.windowId must be an integer")
    accessibility = require_mapping(report, "accessibility", errors)
    dirty_close = accessibility.get("dirtyClose")
    if not isinstance(dirty_close, dict):
        errors.append("accessibility.dirtyClose must be an object")
        dirty_close = {}
    expected_accessibility = {
        "activeElement": "Save",
        "activeElementTag": "BUTTON",
        "decorativeIconsHidden": True,
        "dialogDescribedBy": "close-prompt-message",
        "dialogDescription": "Your edits will be lost if you discard this file.",
        "dialogLabelledBy": "close-prompt-title",
        "dialogModal": "true",
        "dialogRole": "dialog",
        "panelRole": "tabpanel",
        "tabRole": "tab",
        "tabSelected": "true",
        "tablistRole": "tablist",
    }
    for key, expected in expected_accessibility.items():
        if dirty_close.get(key) != expected:
            errors.append(f"accessibility.dirtyClose.{key} must be {expected!r}")
    if dirty_close.get("dialogButtons") != ["Save", "Discard", "Cancel"]:
        errors.append("accessibility.dirtyClose.dialogButtons must be Save/Discard/Cancel")
    if dirty_close.get("editorActionLabels") != EXPECTED_ACTION_LABELS:
        errors.append("accessibility.dirtyClose.editorActionLabels mismatch")
    tab_id = dirty_close.get("tabId")
    if not isinstance(tab_id, str) or not tab_id:
        errors.append("accessibility.dirtyClose.tabId must be non-empty")
    if dirty_close.get("panelLabelledBy") != tab_id:
        errors.append("accessibility.dirtyClose.panelLabelledBy must match tabId")
    tab_name = dirty_close.get("tabName")
    if not isinstance(tab_name, str) or not tab_name.endswith("unsaved changes"):
        errors.append("accessibility.dirtyClose.tabName must expose unsaved changes")
    dialog_title = dirty_close.get("dialogTitle")
    if not isinstance(dialog_title, str) or not dialog_title.startswith("Save changes to "):
        errors.append("accessibility.dirtyClose.dialogTitle must name the save prompt")

    not_claimed = report.get("notClaimed")
    if not isinstance(not_claimed, list):
        errors.append("notClaimed must be a list")
    else:
        for marker in EXPECTED_NOT_CLAIMED:
            if marker not in not_claimed:
                errors.append(f"notClaimed missing {marker!r}")
        if checks.get("nativeSaveAsChooserReviewed") is not True and NATIVE_SAVE_CHOOSER_NOT_CLAIMED not in not_claimed:
            errors.append(f"notClaimed missing {NATIVE_SAVE_CHOOSER_NOT_CLAIMED!r}")
    session = require_mapping(report, "sessionFileBeforeRestart", errors)
    if session.get("exists") is not True:
        errors.append("sessionFileBeforeRestart.exists must be true")
    if "editor-lifecycle.txt" not in str(session.get("content", "")):
        errors.append("sessionFileBeforeRestart.content must retain editor lifecycle file")

    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", default=str(DEFAULT_REPORT))
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    report_path = Path(args.report).resolve()
    errors = validate_report(report_path)
    if errors:
        print("native editor report contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"native editor report ok: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
