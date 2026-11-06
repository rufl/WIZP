#!/usr/bin/env python3
"""Focused regressions for accepted native report promotion."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

try:
    from native_report_promotion import retain_and_promote_report
except ModuleNotFoundError:
    from scripts.native_report_promotion import retain_and_promote_report


class NativeReportPromotionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name)
        self.alias = self.output / "report.json"
        self.accepted = {
            "runId": "accepted-run",
            "status": "passed",
            "errors": [],
            "packetComplete": True,
        }
        self.alias.write_text(json.dumps(self.accepted) + "\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def validate(path: Path) -> list[str]:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return [] if payload.get("packetComplete") is True else ["packet is incomplete"]

    def test_failed_run_is_retained_without_replacing_accepted_alias(self) -> None:
        failed = {
            "runId": "failed-run",
            "status": "failed",
            "errors": ["interrupted"],
            "packetComplete": False,
        }
        result = retain_and_promote_report(self.output, failed, self.validate)

        self.assertFalse(result.promoted)
        self.assertTrue(result.retained_report.is_file())
        self.assertEqual(json.loads(self.alias.read_text(encoding="utf-8")), self.accepted)

    def test_incomplete_nominal_pass_is_retained_without_replacing_alias(self) -> None:
        incomplete = {
            "runId": "incomplete-run",
            "status": "passed",
            "errors": [],
            "packetComplete": False,
        }
        result = retain_and_promote_report(self.output, incomplete, self.validate)

        self.assertFalse(result.promoted)
        self.assertIn("packet is incomplete", result.errors)
        self.assertEqual(json.loads(self.alias.read_text(encoding="utf-8")), self.accepted)

    def test_complete_pass_replaces_alias_without_partial_temp_files(self) -> None:
        passing = {
            "runId": "passing-run",
            "status": "passed",
            "errors": [],
            "packetComplete": True,
        }
        result = retain_and_promote_report(self.output, passing, self.validate)

        self.assertTrue(result.promoted)
        self.assertEqual(json.loads(self.alias.read_text(encoding="utf-8")), passing)
        self.assertEqual(list(self.output.glob("*.tmp")), [])
        self.assertEqual(list(self.output.glob(".*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
