#!/usr/bin/env python3
"""Focused tests for the top-20 parity runner utility boundary."""

from __future__ import annotations

import tempfile
from pathlib import Path

from top20_parity_utils import (
    file_count,
    now_iso,
    safe_fixture_dir,
    scenario_filename,
    sha256_directory,
    write_json,
)


def test_artifact_helpers_are_deterministic() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_json(root / "nested" / "artifact.json", {"b": 2, "a": 1})
        (root / "nested" / "fixture.txt").write_text("fixture\n", encoding="utf-8")
        assert file_count(root) == 2
        first = sha256_directory(root)
        second = sha256_directory(root)
        assert first == second
        assert len(first) == 64


def test_path_and_timestamp_helpers() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        fixtures = root / "fixtures"
        assert safe_fixture_dir("fixtures/demo", root, fixtures) == (fixtures / "demo").resolve()
        try:
            safe_fixture_dir("../escape", root, fixtures)
        except AssertionError:
            pass
        else:
            raise AssertionError("unsafe fixture path was accepted")
    assert scenario_filename("publisher.extension") == "publisher.extension.json"
    assert now_iso().endswith("Z")


if __name__ == "__main__":
    test_artifact_helpers_are_deterministic()
    test_path_and_timestamp_helpers()
    print("top20 parity utility tests ok")
