#!/usr/bin/env python3
"""Retain native run reports and atomically promote only validated packets."""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


ReportValidator = Callable[[Path], list[str]]


@dataclass(frozen=True)
class PromotionResult:
    retained_report: Path
    alias: Path
    promoted: bool
    errors: tuple[str, ...]


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    """Write JSON through a same-directory temporary and atomic rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def retain_and_promote_report(
    output_dir: Path,
    report: dict[str, Any],
    validator: ReportValidator,
    *,
    alias_name: str = "report.json",
) -> PromotionResult:
    """Retain every report, but replace the accepted alias only after validation.

    The validator is the journey's release validator, so a nominally passing but
    incomplete packet cannot displace the previously accepted report. Failed and
    interrupted runs remain available under their run-specific report names.
    """
    run_id = report.get("runId")
    if not isinstance(run_id, str) or not run_id.strip():
        raise ValueError("native report runId must be a non-empty string")
    if Path(run_id).name != run_id or run_id in {".", ".."}:
        raise ValueError("native report runId must be a safe filename component")

    retained_report = output_dir / f"{run_id}-report.json"
    alias = output_dir / alias_name
    atomic_write_json(retained_report, report)

    errors: list[str] = []
    if report.get("status") != "passed":
        errors.append("status must be passed")
    if report.get("errors") != []:
        errors.append("errors must be empty")
    if not errors:
        errors.extend(validator(retained_report))

    if errors:
        return PromotionResult(retained_report, alias, False, tuple(errors))

    # Re-serialize the validated in-memory packet instead of copying over the
    # alias in place. os.replace keeps readers on either complete version.
    atomic_write_json(alias, report)
    return PromotionResult(retained_report, alias, True, ())
