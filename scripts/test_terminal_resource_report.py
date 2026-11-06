#!/usr/bin/env python3
"""Regression tests for terminal cleanup evidence shape and semantics."""

from __future__ import annotations

import copy
import unittest

from scripts.check_terminal_resource_report import validate


def valid_report() -> dict[str, object]:
    return {
        "status": "linux-terminal-resource-smoke-passed",
        "platform": "linux",
        "commandBytes": 20_000_000,
        "observedBytes": 16_000_000,
        "droppedBytes": 4_000_000,
        "rssBeforeBytes": 10_000_000,
        "rssAfterBytes": 20_000_000,
        "rssGrowthBytes": 10_000_000,
        "rssGrowthLimitBytes": 64 * 1024 * 1024,
        "cleanupVerified": True,
        "cleanupProbe": {
            "terminalId": 7,
            "activeIdsAfterKill": [2, 5],
            "process": {
                "pid": 700,
                "stateAfterKill": None,
                "identityBeforeKill": {
                    "pid": 700,
                    "state": "S",
                    "ppid": 70,
                    "startTimeTicks": 12_345,
                },
                "identityAfterKill": None,
                "reaped": True,
            },
        },
    }


class TerminalResourceReportTests(unittest.TestCase):
    def test_accepts_normalized_absence_probe(self) -> None:
        self.assertEqual(validate(valid_report()), [])

    def test_rejects_old_terminal_list_object_shape(self) -> None:
        report = valid_report()
        report["cleanupProbe"] = {
            "terminalId": 7,
            "activeIdsAfterKill": {"terminals": [{"id": 7}]},
        }
        self.assertIn(
            "cleanupProbe.activeIdsAfterKill must be a list of integer terminal ids",
            validate(report),
        )

    def test_rejects_killed_terminal_still_present(self) -> None:
        report = copy.deepcopy(valid_report())
        report["cleanupProbe"]["activeIdsAfterKill"] = [2, 7]
        self.assertIn("cleanup probe still lists the killed terminal session", validate(report))

    def test_rejects_zombie_child_process(self) -> None:
        report = copy.deepcopy(valid_report())
        report["cleanupProbe"]["process"] = {
            "pid": 700,
            "stateAfterKill": "Z",
            "identityBeforeKill": {
                "pid": 700,
                "state": "S",
                "ppid": 70,
                "startTimeTicks": 12_345,
            },
            "identityAfterKill": {
                "pid": 700,
                "state": "Z",
                "ppid": 70,
                "startTimeTicks": 12_345,
            },
            "reaped": False,
        }
        errors = validate(report)
        self.assertIn("terminal child process was not reaped", errors)
        self.assertIn("terminal child process identity still exists after kill", errors)


if __name__ == "__main__":
    unittest.main()
