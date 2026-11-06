#!/usr/bin/env python3
"""Focused tests for top-20 artifact paths and baseline lookups."""

from pathlib import Path

from top20_artifact_paths import artifact_path, fixture_hash_for_scenario, scenario_manifest_entry, unsupported_dependencies_for


def test_artifact_paths_sanitize_components() -> None:
    root = Path("/tmp/top20-results")
    assert artifact_path(root, "publisher/extension", "scenario name") == root / "publisher-extension" / "scenario-name.json"
    assert artifact_path(root, "publisher/extension", "shot", ".png") == root / "publisher-extension" / "shot.png"


def test_baseline_lookups_are_bounded() -> None:
    baseline = {
        "extensions": [{"id": "publisher.extension", "fixtureWorkspaceHashes": [{"scenarioId": "one", "sha256": "abc"}]}],
        "unsupportedDependencies": [{"extensionId": "publisher.extension", "name": "tool"}],
    }
    assert fixture_hash_for_scenario(baseline, "publisher.extension", "one")["sha256"] == "abc"
    assert fixture_hash_for_scenario(baseline, "publisher.extension", "missing") == {}
    assert unsupported_dependencies_for(baseline, "publisher.extension")[0]["name"] == "tool"
    manifests = {"publisher.extension": {"scenarios": [{"id": "one", "kind": "language"}]}}
    assert scenario_manifest_entry(manifests, "PUBLISHER.EXTENSION", "one")["kind"] == "language"
    assert scenario_manifest_entry(manifests, "publisher.extension", "missing", {"kind": "fallback"})["kind"] == "fallback"


if __name__ == "__main__":
    test_artifact_paths_sanitize_components()
    test_baseline_lookups_are_bounded()
    print("top20 artifact path tests ok")
