#!/usr/bin/env python3
"""Validate retained packaged-native visual baselines and their source reports."""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "testdata" / "ui-ux" / "native-visual-baselines.json"
REQUIRED_JOURNEYS = {
    "editor": "UI-NATIVE-006",
    "explorer": "UI-NATIVE-007",
    "search": "UI-NATIVE-008",
    "scm": "UI-NATIVE-009",
    "debug": "UI-NATIVE-010",
    "extensions": "UI-NATIVE-011",
    "settings": "UI-NATIVE-012",
    "terminal": "UI-NATIVE-013",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as handle:
        header = handle.read(24)
    if len(header) != 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise AssertionError(f"not a PNG with an IHDR header: {path}")
    return struct.unpack(">II", header[16:24])


def resolve_artifact(root: Path, value: Any, location: str) -> Path:
    if not isinstance(value, str) or not value:
        raise AssertionError(f"{location} must be a non-empty relative path")
    path = Path(value)
    if path.is_absolute():
        raise AssertionError(f"{location} must be relative")
    resolved_root = root.resolve()
    resolved = (resolved_root / path).resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise AssertionError(f"{location} escapes the project root") from exc
    if not resolved.is_file():
        raise AssertionError(f"{location} is missing: {value}")
    return resolved


def validate_hash(path: Path, expected: Any, location: str) -> None:
    if not isinstance(expected, str) or len(expected) != 64:
        raise AssertionError(f"{location} must contain a SHA-256 digest")
    actual = file_sha256(path)
    if actual != expected.lower():
        raise AssertionError(
            f"{location} hash mismatch: expected {expected.lower()}, found {actual}"
        )


def report_screenshot_names(report: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    evidence = report.get("evidence")
    if not isinstance(evidence, dict):
        return names
    for item in evidence.values():
        if isinstance(item, dict) and isinstance(item.get("screenshot"), str):
            names.add(Path(item["screenshot"]).name)
    return names


def validate(manifest: dict[str, Any], root: Path = ROOT) -> None:
    if manifest.get("schema") != "wizp.native-visual-baselines.v1":
        raise AssertionError("unsupported native visual baseline schema")
    if manifest.get("status") != "automation-assisted-reviewed":
        raise AssertionError("native visual baselines must record automation-assisted review")
    if manifest.get("platform") != "linux" or manifest.get("renderer") != "cef":
        raise AssertionError("baseline platform/renderer must remain Linux/CEF")
    if manifest.get("manualHumanReviewComplete") is not False:
        raise AssertionError("automation-assisted baselines must not claim human review")
    caveats = manifest.get("caveats")
    if not isinstance(caveats, list) or len(caveats) < 2:
        raise AssertionError("native visual baselines must retain explicit review caveats")

    baselines = manifest.get("baselines")
    if not isinstance(baselines, list):
        raise AssertionError("baselines must be an array")
    journeys = [item.get("journey") for item in baselines if isinstance(item, dict)]
    if len(journeys) != len(set(journeys)):
        raise AssertionError("native visual baseline journeys must be unique")
    if set(journeys) != set(REQUIRED_JOURNEYS):
        raise AssertionError(
            f"native visual baseline journeys changed: {sorted(journeys)!r}"
        )

    for index, item in enumerate(baselines):
        if not isinstance(item, dict):
            raise AssertionError(f"baselines[{index}] must be an object")
        journey = str(item.get("journey") or "")
        location = f"baselines[{index}] ({journey})"
        if item.get("backlogId") != REQUIRED_JOURNEYS[journey]:
            raise AssertionError(f"{location} has the wrong backlog ID")
        if not isinstance(item.get("state"), str) or not item["state"]:
            raise AssertionError(f"{location} must name the reviewed state")
        visual = item.get("visual")
        if not isinstance(visual, dict):
            raise AssertionError(f"{location} must record visual metadata")
        if visual.get("theme") != "default-dark":
            raise AssertionError(f"{location} visual theme must remain default-dark")
        if visual.get("scale") != 1 or visual.get("locale") != "en-US":
            raise AssertionError(f"{location} visual scale/locale is unsupported")
        viewport = visual.get("viewport")
        if not isinstance(viewport, dict):
            raise AssertionError(f"{location} visual viewport is required")
        viewport_width = viewport.get("width")
        viewport_height = viewport.get("height")
        if (
            not isinstance(viewport_width, int)
            or isinstance(viewport_width, bool)
            or viewport_width <= 0
            or not isinstance(viewport_height, int)
            or isinstance(viewport_height, bool)
            or viewport_height <= 0
        ):
            raise AssertionError(f"{location} visual viewport must be positive integer dimensions")

        required_check = item.get("requiredCheck")
        if not isinstance(required_check, str) or not required_check:
            raise AssertionError(f"{location} must name a required report check")

        screenshot = item.get("screenshot")
        report_entry = item.get("report")
        if not isinstance(screenshot, dict) or not isinstance(report_entry, dict):
            raise AssertionError(f"{location} must bind a screenshot and report")
        screenshot_path_value = screenshot.get("path")
        expected_prefix = f"build/ui-ux/native-{journey}/"
        if not isinstance(screenshot_path_value, str) or not screenshot_path_value.startswith(
            expected_prefix
        ):
            raise AssertionError(f"{location} screenshot is outside its journey directory")
        screenshot_path = resolve_artifact(
            root, screenshot_path_value, f"{location}.screenshot.path"
        )
        report_path_value = report_entry.get("path")
        if not isinstance(report_path_value, str) or not report_path_value.startswith(
            expected_prefix
        ):
            raise AssertionError(f"{location} report is outside its journey directory")
        report_path = resolve_artifact(
            root, report_entry.get("path"), f"{location}.report.path"
        )
        validate_hash(
            screenshot_path, screenshot.get("sha256"), f"{location}.screenshot"
        )
        validate_hash(report_path, report_entry.get("sha256"), f"{location}.report")

        width, height = png_dimensions(screenshot_path)
        if (screenshot.get("width"), screenshot.get("height")) != (width, height):
            raise AssertionError(
                f"{location} dimensions changed: expected "
                f"{screenshot.get('width')}x{screenshot.get('height')}, found {width}x{height}"
            )
        if (viewport_width, viewport_height) != (width, height):
            raise AssertionError(
                f"{location} visual viewport changed: expected "
                f"{viewport_width}x{viewport_height}, found {width}x{height}"
            )

        report = json.loads(report_path.read_text(encoding="utf-8"))
        if not isinstance(report, dict):
            raise AssertionError(f"{location} report must be an object")
        kind = str(report.get("kind") or "")
        if kind != f"wizp-linux-packaged-native-{journey}":
            raise AssertionError(f"{location} report kind does not match the journey")
        if report.get("errors") != []:
            raise AssertionError(f"{location} source report contains errors")
        checks = report.get("checks")
        if not isinstance(checks, dict) or checks.get(required_check) is not True:
            raise AssertionError(f"{location} required check {required_check!r} did not pass")
        cleanup = report.get("cleanup")
        if not isinstance(cleanup, dict):
            raise AssertionError(f"{location} source report has no cleanup evidence")
        if cleanup.get("forced") is not False or cleanup.get("remainingPids") != []:
            raise AssertionError(f"{location} source run did not cleanly release processes")
        if cleanup.get("exitCode") not in {0, 143}:
            raise AssertionError(f"{location} source run has an unexpected exit code")
        if screenshot_path.name not in report_screenshot_names(report):
            raise AssertionError(f"{location} screenshot is not declared by its report")


def main() -> int:
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise AssertionError("native visual baseline manifest must be an object")
        validate(manifest)
    except (AssertionError, json.JSONDecodeError, OSError) as exc:
        print(f"native visual baseline check failed: {exc}", file=sys.stderr)
        return 1
    print(
        "native visual baselines ok: "
        f"{len(REQUIRED_JOURNEYS)} checksum-bound Linux packaged-native frames"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
