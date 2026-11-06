#!/usr/bin/env python3
"""Focused tests for packaged-native visual baseline integrity."""

from __future__ import annotations

import copy
import json
import unittest

try:
    from check_native_visual_baselines import MANIFEST, validate
except ModuleNotFoundError:
    from scripts.check_native_visual_baselines import MANIFEST, validate


class NativeVisualBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    def test_retained_manifest_validates(self) -> None:
        validate(copy.deepcopy(self.manifest))

    def test_screenshot_hash_drift_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["baselines"][0]["screenshot"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(AssertionError, "hash mismatch"):
            validate(manifest)

    def test_automation_baseline_cannot_claim_human_review(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["manualHumanReviewComplete"] = True
        with self.assertRaisesRegex(AssertionError, "must not claim human review"):
            validate(manifest)

    def test_duplicate_journey_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["baselines"][1]["journey"] = manifest["baselines"][0]["journey"]
        with self.assertRaisesRegex(AssertionError, "must be unique"):
            validate(manifest)

    def test_viewport_drift_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["baselines"][0]["visual"]["viewport"]["width"] = 1279
        with self.assertRaisesRegex(AssertionError, "visual viewport changed"):
            validate(manifest)

    def test_report_path_drift_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["baselines"][0]["report"]["path"] = "build/ui-ux/native-terminal/report.json"
        with self.assertRaisesRegex(AssertionError, "report is outside"):
            validate(manifest)

    def test_unsupported_theme_claim_fails(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["baselines"][0]["visual"]["theme"] = "one-light"
        with self.assertRaisesRegex(AssertionError, "default-dark"):
            validate(manifest)


if __name__ == "__main__":
    unittest.main()
