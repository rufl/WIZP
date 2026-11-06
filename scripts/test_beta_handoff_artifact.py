#!/usr/bin/env python3
"""Focused tests for beta handoff artifact hash integrity."""

from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path

from scripts.check_beta_handoff_artifact import validate_recorded_artifact_hashes


class BetaHandoffArtifactTests(unittest.TestCase):
    def test_recorded_artifact_hashes_match_current_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "build" / "parity-package" / "package-report.json"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"current package evidence\n")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            beta = {
                "artifacts": {
                    "package": {
                        "path": "build/parity-package/package-report.json",
                        "sha256": digest,
                        "reports": [
                            {
                                "path": "build/parity-package/package-report.json",
                                "sha256": digest,
                            }
                        ],
                    }
                }
            }

            validate_recorded_artifact_hashes(beta, root)

    def test_recorded_artifact_hash_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            artifact = root / "build" / "parity-package" / "package-report.json"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"old package evidence\n")
            recorded_digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            artifact.write_bytes(b"new package evidence\n")
            beta = {
                "artifacts": {
                    "package": {
                        "path": "build/parity-package/package-report.json",
                        "sha256": recorded_digest,
                    }
                }
            }

            with self.assertRaisesRegex(AssertionError, "sha256 mismatch"):
                validate_recorded_artifact_hashes(beta, root)


if __name__ == "__main__":
    unittest.main()
