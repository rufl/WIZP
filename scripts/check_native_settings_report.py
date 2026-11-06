#!/usr/bin/env python3
"""Validate retained packaged-native Settings journey evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "build" / "ui-ux" / "native-settings" / "report.json"

REQUIRED_CHECKS = (
    "keyboardShortcutOpen",
    "keyboardFieldNavigation",
    "cancelDiscardedEdit",
    "escapeClosedWithoutSaving",
    "saveSyncedBackend",
    "savedValueReopened",
    "settingsDialogAccessible",
    "settingsFocusContained",
    "settingsReturnedFocusToTrigger",
    "partialSyncWarningVisible",
    "partialSyncRetainedDialog",
    "partialSyncPreservedLocalValue",
    "partialSyncBackendUnchanged",
    "retrySaveSyncedBackend",
    "retrySaveClosedDialog",
    "retrySaveReopenedValue",
)

REQUIRED_EVIDENCE = (
    "01-keyboard-open",
    "02-cancel-edit",
    "03-cancel-closed",
    "04-cancel-reopen",
    "05-escape-edit",
    "06-escape-closed",
    "07-escape-reopen",
    "08-save-edit",
    "09-save-closed",
    "10-save-reopen",
    "11-save-reopen-closed",
    "12-trigger-open",
    "13-trigger-closed",
    "14-partial-sync-warning",
    "15-retry-closed",
    "16-retry-reopen",
    "17-retry-reopen-closed",
)

EXPECTED_FONT_EVIDENCE = {
    "02-cancel-edit": "18",
    "04-cancel-reopen": "14",
    "05-escape-edit": "19",
    "07-escape-reopen": "14",
    "08-save-edit": "16",
    "10-save-reopen": "16",
    "16-retry-reopen": "17",
}

EXPECTED_NOT_CLAIMED = (
    "Assistive-technology sign-off",
    "macOS or Windows behavior",
)

EXPECTED_DIALOG = {
    "dialogRole": "dialog",
    "dialogModal": "true",
    "dialogLabelledBy": "settings-title",
    "dialogDescribedBy": "settings-description",
    "dialogTitle": "Settings",
    "dialogDescription": "Review editor preferences, then save to apply and sync them.",
    "activeElement": "Close settings",
    "activeElementTag": "BUTTON",
    "activeInsideDialog": True,
    "closeButtonLabel": "Close settings",
    "decorativeIconsHidden": True,
}

EXPECTED_FIELD_LABELS = {
    "settings-theme": "Color Theme",
    "settings-fontsize": "Font Size",
    "settings-tabsize": "Tab Size",
    "settings-wrapcolumn": "Word Wrap Column",
    "settings-whitespace": "Render Whitespace",
    "settings-fontfamily": "Font Family",
    "settings-cursor": "Cursor Style",
    "settings-wordwrap": "Word Wrap",
}

EXPECTED_CHECKBOX_LABELS = {
    "settings-minimap": "Show Minimap",
    "settings-linenumbers": "Show Line Numbers",
    "settings-bracketpair": "Bracket Pair Colorization",
    "settings-formatonsave": "Format on Save",
    "settings-autosave": "Auto Save (after 1s idle)",
}

EXPECTED_FOOTER_BUTTONS = ["Open Settings (JSON)", "Cancel", "Apply & Save"]


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


def validate_exact_mapping(
    value: Any,
    expected: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    if not isinstance(value, dict):
        errors.append(f"{path} must be an object")
        return
    if value.keys() != expected.keys():
        errors.append(f"{path} fields must be exactly {sorted(expected)}")
    for key, expected_value in expected.items():
        actual = value.get(key)
        if type(actual) is not type(expected_value) or actual != expected_value:
            errors.append(f"{path}.{key} must be {expected_value!r}")


def require_artifact(report_dir: Path, item: dict[str, Any], name: str, field: str, errors: list[str]) -> None:
    value = item.get(field)
    if not isinstance(value, str) or not value:
        errors.append(f"evidence.{name}.{field} must be non-empty")
        return
    if not (report_dir / value).is_file():
        errors.append(f"evidence.{name}.{field} missing artifact: {value}")


def validate_accessibility(report: dict[str, Any], errors: list[str]) -> None:
    accessibility = require_mapping(report, "accessibility", errors)
    settings_dialog = accessibility.get("settingsDialog")
    if not isinstance(settings_dialog, dict):
        errors.append("accessibility.settingsDialog must be an object")
        settings_dialog = {}
    for key, expected in EXPECTED_DIALOG.items():
        if settings_dialog.get(key) != expected:
            errors.append(f"accessibility.settingsDialog.{key} must be {expected!r}")
    if settings_dialog.get("fieldLabels") != EXPECTED_FIELD_LABELS:
        errors.append("accessibility.settingsDialog.fieldLabels mismatch")
    if settings_dialog.get("checkboxLabels") != EXPECTED_CHECKBOX_LABELS:
        errors.append("accessibility.settingsDialog.checkboxLabels mismatch")
    if settings_dialog.get("footerButtons") != EXPECTED_FOOTER_BUTTONS:
        errors.append("accessibility.settingsDialog.footerButtons mismatch")
    section_names = settings_dialog.get("sectionNames")
    if not isinstance(section_names, list) or not {"Appearance", "Keyboard Shortcuts"}.issubset(section_names):
        errors.append("accessibility.settingsDialog.sectionNames must include Appearance and Keyboard Shortcuts")

    focus_wrap = accessibility.get("focusWrap")
    if not isinstance(focus_wrap, dict):
        errors.append("accessibility.focusWrap must be an object")
        focus_wrap = {}
    if focus_wrap.get("activeElement") != "Apply & Save":
        errors.append("accessibility.focusWrap.activeElement must be Apply & Save")
    if focus_wrap.get("activeElementTag") != "BUTTON":
        errors.append("accessibility.focusWrap.activeElementTag must be BUTTON")
    if focus_wrap.get("activeInsideDialog") is not True:
        errors.append("accessibility.focusWrap.activeInsideDialog must be true")

    trigger = accessibility.get("settingsTrigger")
    if not isinstance(trigger, dict):
        errors.append("accessibility.settingsTrigger must be an object")
        trigger = {}
    expected_trigger = {"found": True, "label": "Settings", "controls": "settings-dialog", "hasPopup": "dialog"}
    for key, expected in expected_trigger.items():
        if trigger.get(key) != expected:
            errors.append(f"accessibility.settingsTrigger.{key} must be {expected!r}")
    for key in ("x", "y"):
        if isinstance(trigger.get(key), bool) or not isinstance(trigger.get(key), int):
            errors.append(f"accessibility.settingsTrigger.{key} must be an integer")

    return_focus = accessibility.get("returnFocus")
    if not isinstance(return_focus, dict):
        errors.append("accessibility.returnFocus must be an object")
        return_focus = {}
    expected_return = {
        "activeElement": "Settings",
        "activeElementTag": "BUTTON",
        "activeControls": "settings-dialog",
        "activeHasPopup": "dialog",
    }
    for key, expected in expected_return.items():
        if return_focus.get(key) != expected:
            errors.append(f"accessibility.returnFocus.{key} must be {expected!r}")


def validate_partial_sync_recovery(report: dict[str, Any], errors: list[str]) -> None:
    recovery = require_mapping(report, "partialSyncRecovery", errors)
    expected_fields = {
        "backendBeforeFailure",
        "injection",
        "warning",
        "backendAfterFailure",
        "backendAfterRetry",
    }
    if recovery.keys() != expected_fields:
        errors.append(f"partialSyncRecovery fields must be exactly {sorted(expected_fields)}")

    validate_exact_mapping(
        recovery.get("injection"),
        {"armed": True, "key": "editor.fontSize", "matched": 0},
        "partialSyncRecovery.injection",
        errors,
    )
    validate_exact_mapping(
        recovery.get("warning"),
        {
            "dialogVisible": True,
            "message": (
                "Saved locally, but 1 preference could not sync: font size. "
                "Retry when the backend is available."
            ),
            "messageRole": "alert",
            "messageLive": "assertive",
            "saveButton": "Retry Save",
            "saveButtonDisabled": False,
            "activeElement": "Retry Save",
            "activeElementTag": "BUTTON",
            "activeInsideDialog": True,
            "inputFontSize": "17",
            "storedFontSize": 17,
            "injectedKey": "editor.fontSize",
            "injectedCount": 1,
            "injectionArmed": False,
        },
        "partialSyncRecovery.warning",
        errors,
    )
    expected_backend_states = {
        "backendBeforeFailure": "16",
        "backendAfterFailure": "16",
        "backendAfterRetry": "17",
    }
    for field, value in expected_backend_states.items():
        validate_exact_mapping(
            recovery.get(field),
            {"key": "editor.fontSize", "value": value},
            f"partialSyncRecovery.{field}",
            errors,
        )


def validate_report(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        report = load_report(path)
    except ValueError as exc:
        return [str(exc)]

    if report.get("schema") != 2:
        errors.append("schema must be 2")
    if report.get("kind") != "wizp-linux-packaged-native-settings":
        errors.append("kind must be wizp-linux-packaged-native-settings")
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

    expected_cleanup = {
        "requested": True,
        "signal": "SIGTERM",
        "forced": False,
        "exitCode": 0,
        "remainingPids": [],
    }
    validate_exact_mapping(report.get("cleanup"), expected_cleanup, "cleanup", errors)

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
        expected_fields = {"screenshot", "ocr", "ocrMatched"}
        expected_font = EXPECTED_FONT_EVIDENCE.get(name)
        if expected_font is not None:
            expected_fields.update({"fontValue", "fontOcr"})
        if item.keys() != expected_fields:
            errors.append(f"evidence.{name} fields must be exactly {sorted(expected_fields)}")
        if not isinstance(item.get("ocrMatched"), bool):
            errors.append(f"evidence.{name}.ocrMatched must be a boolean")
        if expected_font is not None:
            if item.get("fontValue") != expected_font:
                errors.append(f"evidence.{name}.fontValue must be {expected_font!r}")
            if not isinstance(item.get("fontOcr"), str):
                errors.append(f"evidence.{name}.fontOcr must be a string")

    validate_accessibility(report, errors)
    validate_partial_sync_recovery(report, errors)

    not_claimed = report.get("notClaimed")
    if not_claimed != list(EXPECTED_NOT_CLAIMED):
        errors.append(f"notClaimed must be exactly {list(EXPECTED_NOT_CLAIMED)!r}")

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
        print("native Settings report contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"native Settings report ok: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
