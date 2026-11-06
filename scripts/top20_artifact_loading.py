"""Safe JSON artifact loading for the top-20 parity lane."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

try:
    from top20_artifact_paths import artifact_path
except ModuleNotFoundError:
    from scripts.top20_artifact_paths import artifact_path


def load_json_if_exists(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def read_scenario_artifact_payload(root: Path, extension_id: str, scenario_id: str) -> dict[str, Any]:
    return load_json_if_exists(artifact_path(root, extension_id, scenario_id))
