"""Pure artifact-path and baseline lookup helpers for the top-20 parity lane."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def artifact_path(root: Path, extension_id: str, scenario_id: str, suffix: str = ".json") -> Path:
    safe_extension = extension_id.replace("/", "-").replace(" ", "-")
    safe_scenario = scenario_id.replace("/", "-").replace(" ", "-")
    return root / safe_extension / f"{safe_scenario}{suffix}"


def fixture_hash_for_scenario(baseline: dict[str, Any], extension_id: str, scenario_id: str) -> dict[str, Any]:
    for extension in baseline.get("extensions", []):
        if extension.get("id") != extension_id:
            continue
        for fixture in extension.get("fixtureWorkspaceHashes", []):
            if fixture.get("scenarioId") == scenario_id:
                return fixture
    return {}


def unsupported_dependencies_for(baseline: dict[str, Any], extension_id: str) -> list[dict[str, Any]]:
    return [item for item in baseline.get("unsupportedDependencies", []) if isinstance(item, dict) and item.get("extensionId") == extension_id]


def scenario_manifest_entry(
    manifests: dict[str, dict[str, Any]], extension_id: str, scenario_id: str, fallback: dict[str, Any] | None = None
) -> dict[str, Any]:
    manifest = manifests.get(extension_id.lower(), {})
    for scenario in manifest.get("scenarios", []):
        if isinstance(scenario, dict) and str(scenario.get("id") or "") == scenario_id:
            return scenario
    return dict(fallback or {})
