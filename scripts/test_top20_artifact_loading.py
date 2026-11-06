#!/usr/bin/env python3
"""Focused tests for safe top-20 artifact loading."""

import tempfile
from pathlib import Path

from top20_artifact_loading import load_json_if_exists, read_scenario_artifact_payload


def test_loader_handles_valid_missing_malformed_and_non_object_json() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        valid = root / "valid.json"
        valid.write_text('{"status":"verified"}\n', encoding="utf-8")
        malformed = root / "malformed.json"
        malformed.write_text("{broken", encoding="utf-8")
        scalar = root / "scalar.json"
        scalar.write_text("[]", encoding="utf-8")
        assert load_json_if_exists(valid) == {"status": "verified"}
        assert load_json_if_exists(malformed) == {}
        assert load_json_if_exists(scalar) == {}
        assert load_json_if_exists(root / "missing.json") == {}


def test_scenario_loader_uses_the_shared_artifact_path() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target = root / "publisher-extension" / "scenario-name.json"
        target.parent.mkdir(parents=True)
        target.write_text('{"status":"verified"}\n', encoding="utf-8")
        assert read_scenario_artifact_payload(root, "publisher/extension", "scenario name") == {"status": "verified"}


if __name__ == "__main__":
    test_loader_handles_valid_missing_malformed_and_non_object_json()
    test_scenario_loader_uses_the_shared_artifact_path()
    print("top20 artifact loading tests ok")
