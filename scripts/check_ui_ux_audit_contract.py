#!/usr/bin/env python3
"""Protect the native UI/UX audit, evidence, and accepted test queue from drift."""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROL_ROOT = ROOT.parent
AUDIT_DIR = ROOT / "docs" / "ui-ux-audit" / "2026-07-13"
REPORT = AUDIT_DIR / "REPORT.md"
BOARD_HANDOFF = AUDIT_DIR / "FIGMA_BOARD_HANDOFF.md"
TEST_BACKLOG = ROOT / "docs" / "ui-ux" / "TEST_BACKLOG.md"
ROOT_BACKLOG = CONTROL_ROOT / "BACKLOG.md"
ROOT_BACKLOG_ARCHIVE = CONTROL_ROOT / "BACKLOG_ARCHIVE.md"

EXPECTED_TEST_IDS = (
    "UI-NATIVE-001",
    "UI-NATIVE-002",
    "UI-NATIVE-003",
    "UI-NATIVE-004",
    "UI-NATIVE-005",
    "UI-NATIVE-006",
    "UI-NATIVE-007",
    "UI-NATIVE-008",
    "UI-NATIVE-009",
    "UI-NATIVE-010",
    "UI-NATIVE-011",
    "UI-NATIVE-012",
    "UI-NATIVE-013",
    "UI-CONTRACT-001",
    "UI-CONTRACT-002",
    "UI-CONTRACT-003",
    "UI-A11Y-001",
    "UI-A11Y-002",
    "UI-A11Y-003",
    "UI-VISUAL-001",
    "UI-VISUAL-002",
    "UI-VISUAL-003",
    "UI-RECOVERY-001",
)

EXPECTED_EPIC_IDS = (
    "UIUX-RUNTIME-001",
    "UIUX-POLLING-001",
    "UIUX-TERMINAL-001",
    "UIUX-WORKSPACE-001",
    "UIUX-SETTINGS-001",
    "UIUX-SHORTCUTS-001",
    "UIUX-AFFORDANCE-001",
    "UIUX-A11Y-001",
    "UIUX-EXTENSIONS-001",
    "UIUX-VISUAL-001",
    "UIUX-RESPONSIVE-001",
    "UIUX-HARNESS-001",
    "UIUX-FIGMA-001",
)

ACCEPTED_SCREENSHOTS = {
    "01-launch.png": {
        "size": (1920, 1080),
        "sha256": "d3680976aa4681ea7eb246c390dc534ecc890680f851d380410df4f680633dcc",
    },
    "02-command-palette.png": {
        "size": (1920, 1057),
        "sha256": "210fde81c643438105576520528d9962c1ac863a404361e272f63569cab8aa68",
    },
}

REJECTED_SCREENSHOTS = (
    "03-command-filter.png",
    "03-native-blackout.png",
    "03-quick-open.png",
)

DOC_POINTERS = (
    CONTROL_ROOT / "README.md",
    CONTROL_ROOT / "ROADMAP.md",
    CONTROL_ROOT / "MEMORY.md",
    ROOT / "README.md",
    ROOT / "BACKLOG.md",
    ROOT / "ROADMAP.md",
    ROOT / "MEMORY.md",
    ROOT / "docs" / "WIZP.md",
)


def read_text(path: Path, errors: list[str]) -> str:
    if not path.is_file():
        errors.append(f"missing required file: {path.relative_to(CONTROL_ROOT)}")
        return ""
    return path.read_text(encoding="utf-8")


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as handle:
        header = handle.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    return struct.unpack(">II", header[16:24])


def validate() -> list[str]:
    errors: list[str] = []
    report = read_text(REPORT, errors)
    board = read_text(BOARD_HANDOFF, errors)
    test_backlog = read_text(TEST_BACKLOG, errors)
    root_backlog = read_text(ROOT_BACKLOG, errors)
    root_backlog_archive = read_text(ROOT_BACKLOG_ARCHIVE, errors)

    for marker in (
        "failed baseline",
        "Three fresh native launches",
        "approximately 1,070 `/api/rpc` requests in five seconds",
        "signal 11 / exit 139",
        "screenshots/01-launch.png",
        "screenshots/02-command-palette.png",
        "## Audit limits",
    ):
        if marker not in report:
            errors.append(f"audit report missing marker: {marker}")

    for test_id in EXPECTED_TEST_IDS:
        count = test_backlog.count(f"| {test_id} |")
        if count != 1:
            errors.append(
                f"test backlog must contain exactly one row for {test_id}; found {count}"
            )

    for epic_id in EXPECTED_EPIC_IDS:
        count = root_backlog.count(f"| {epic_id} |") + root_backlog_archive.count(
            f"- ✅ `{epic_id}`"
        )
        if count != 1:
            errors.append(
                f"active backlog plus archive must contain exactly one row for {epic_id}; found {count}"
            )

    if "23 rows" not in test_backlog:
        errors.append("test backlog must retain the explicit 23-row exit criterion")
    if "Figma placement blocked" not in board:
        errors.append("Figma handoff must preserve the unavailable-capability blocker")
    if "x=2120" not in board or "exactly `200 px`" not in board:
        errors.append("Figma handoff must preserve the required screenshot spacing")

    screenshots = AUDIT_DIR / "screenshots"
    for name, expected in ACCEPTED_SCREENSHOTS.items():
        path = screenshots / name
        if not path.is_file():
            errors.append(f"missing accepted screenshot: {name}")
            continue
        try:
            dimensions = png_dimensions(path)
        except ValueError as exc:
            errors.append(f"invalid accepted screenshot {name}: {exc}")
            continue
        if dimensions != expected["size"]:
            errors.append(
                f"accepted screenshot {name} dimensions drifted: "
                f"expected {expected['size']}, found {dimensions}"
            )
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected["sha256"]:
            errors.append(
                f"accepted screenshot {name} checksum drifted: "
                f"expected {expected['sha256']}, found {digest}"
            )
        if name not in board:
            errors.append(f"Figma handoff does not place accepted screenshot: {name}")

    for name in REJECTED_SCREENSHOTS:
        if (screenshots / name).exists():
            errors.append(f"rejected screenshot remains in accepted evidence folder: {name}")
        if name not in board:
            errors.append(f"Figma handoff must document rejected capture: {name}")

    for path in DOC_POINTERS:
        text = read_text(path, errors)
        if "TEST_BACKLOG.md" not in text:
            errors.append(
                f"documentation truth surface lacks UI/UX backlog pointer: "
                f"{path.relative_to(CONTROL_ROOT)}"
            )

    package_path = ROOT / "package.json"
    if package_path.is_file():
        package = json.loads(package_path.read_text(encoding="utf-8"))
        command = package.get("scripts", {}).get("check:ui-ux-audit")
        if command != "python3 scripts/check_ui_ux_audit_contract.py":
            errors.append("package.json lacks the canonical check:ui-ux-audit command")
    else:
        errors.append("missing package.json")

    verify = read_text(ROOT / "scripts" / "verify.sh", errors)
    if "python3 scripts/check_ui_ux_audit_contract.py" not in verify:
        errors.append("broad verify gate does not run the UI/UX audit contract")

    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("UI/UX audit contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        "UI/UX audit contract ok: "
        f"{len(EXPECTED_EPIC_IDS)} product rows, "
        f"{len(EXPECTED_TEST_IDS)} test rows, "
        f"{len(ACCEPTED_SCREENSHOTS)} accepted screenshots"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
