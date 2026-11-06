#!/usr/bin/env python3
"""Validate retained packaged-native Explorer journey evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = ROOT / "build" / "ui-ux" / "native-explorer" / "report.json"

REQUIRED_CHECKS = (
    "workspaceFixtureSelected",
    "treeAccessible",
    "keyboardRovingNavigation",
    "longUnicodePathOpened",
    "keyboardContextMenu",
    "fileCreated",
    "duplicateCreateRecovered",
    "folderCreated",
    "fileRenamed",
    "copyPasteCompleted",
    "deleteConfirmed",
    "permissionFailureRecovered",
    "emptyAndErrorStatesRecovered",
    "outlineNavigated",
)
REQUIRED_EVIDENCE = ("08-permission-error", "09-final")
EXPECTED_NOT_CLAIMED = (
    "Assistive-technology sign-off",
    "macOS or Windows behavior",
)
EXPECTED_CONTEXT_ITEMS = {
    "New File...",
    "New Folder...",
    "Rename... F2",
    "Delete Delete",
    "Copy",
    "Cut",
    "Collapse All",
    "Refresh Explorer",
}


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
    tree = accessibility.get("initialTree")
    if not isinstance(tree, dict):
        errors.append("accessibility.initialTree must be an object")
        tree = {}
    if tree.get("treeFound") is not True:
        errors.append("accessibility.initialTree.treeFound must be true")
    if tree.get("label") != "Workspace files":
        errors.append("accessibility.initialTree.label must be Workspace files")
    if tree.get("tabStops") != 1:
        errors.append("accessibility.initialTree.tabStops must be 1")
    items = tree.get("items")
    if not isinstance(items, list) or not items:
        errors.append("accessibility.initialTree.items must be non-empty")
    else:
        for index, item in enumerate(items):
            if not isinstance(item, dict):
                errors.append(f"accessibility.initialTree.items[{index}] must be an object")
                continue
            if not item.get("path") or not item.get("label"):
                errors.append(f"accessibility.initialTree.items[{index}] must have path and label")
            if item.get("level") != 1:
                errors.append(f"accessibility.initialTree.items[{index}].level must be 1")

    context = accessibility.get("contextMenu")
    if not isinstance(context, dict):
        errors.append("accessibility.contextMenu must be an object")
        context = {}
    if context.get("label") != "Context menu":
        errors.append("accessibility.contextMenu.label must be Context menu")
    if context.get("active") != "New File...":
        errors.append("accessibility.contextMenu.active must be New File...")
    context_items = context.get("items")
    if not isinstance(context_items, list) or not EXPECTED_CONTEXT_ITEMS.issubset(context_items):
        errors.append("accessibility.contextMenu.items mismatch")

    create_dialog = accessibility.get("createDialog")
    if not isinstance(create_dialog, dict):
        errors.append("accessibility.createDialog must be an object")
        create_dialog = {}
    expected_create = {
        "open": True,
        "title": "Create file",
        "labelledBy": "explorer-dialog-title",
        "describedBy": "explorer-dialog-description",
        "activeLabel": "Name",
        "activeTag": "INPUT",
    }
    for key, expected in expected_create.items():
        if create_dialog.get(key) != expected:
            errors.append(f"accessibility.createDialog.{key} must be {expected!r}")

    rename_dialog = accessibility.get("renameDialog")
    if not isinstance(rename_dialog, dict):
        errors.append("accessibility.renameDialog must be an object")
        rename_dialog = {}
    if not str(rename_dialog.get("title", "")).startswith("Rename "):
        errors.append("accessibility.renameDialog.title must start with Rename")
    if rename_dialog.get("activeLabel") != "New name":
        errors.append("accessibility.renameDialog.activeLabel must be New name")

    delete_dialog = accessibility.get("deleteDialog")
    if not isinstance(delete_dialog, dict):
        errors.append("accessibility.deleteDialog must be an object")
        delete_dialog = {}
    if not str(delete_dialog.get("title", "")).startswith("Delete "):
        errors.append("accessibility.deleteDialog.title must start with Delete")
    if delete_dialog.get("activeLabel") != "Delete":
        errors.append("accessibility.deleteDialog.activeLabel must be Delete")

    refresh_menu = accessibility.get("refreshMenu")
    if not isinstance(refresh_menu, dict):
        errors.append("accessibility.refreshMenu must be an object")
    elif "Refresh Explorer" not in refresh_menu.get("items", []):
        errors.append("accessibility.refreshMenu.items must include Refresh Explorer")

    outline = require_mapping(report, "outline", errors)
    if not outline.get("label"):
        errors.append("outline.label must be non-empty")
    line_number = outline.get("lineNumber")
    if isinstance(line_number, bool) or not isinstance(line_number, int) or line_number < 1:
        errors.append("outline.lineNumber must be a positive integer")


def validate_report(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        report = load_report(path)
    except ValueError as exc:
        return [str(exc)]

    if report.get("schema") != 1:
        errors.append("schema must be 1")
    if report.get("kind") != "wizp-linux-packaged-native-explorer":
        errors.append("kind must be wizp-linux-packaged-native-explorer")
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

    profile = require_mapping(report, "profile", errors)
    if profile.get("removedAfterRun") is not True:
        errors.append("profile.removedAfterRun must be true")

    evidence = require_mapping(report, "evidence", errors)
    report_dir = path.parent
    for name in REQUIRED_EVIDENCE:
        item = evidence.get(name)
        if not isinstance(item, dict):
            errors.append(f"evidence.{name} must be an object")
            continue
        require_artifact(report_dir, item, name, "screenshot", errors)
        require_artifact(report_dir, item, name, "ocr", errors)
    permission = evidence.get("08-permission-error")
    if isinstance(permission, dict) and "Could not create the file" not in str(permission.get("message", "")):
        errors.append("evidence.08-permission-error.message must retain the failure")

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
        print("native Explorer report contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"native Explorer report ok: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
