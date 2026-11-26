from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts.check_cef_payload_equivalence import compare


class CEFPayloadEquivalenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.wizp = self.root / "WIZP"
        self.cef = self.wizp / "bin" / "cef"
        self.eurooffice = self.root / "eurooffice"
        self.cef.mkdir(parents=True)
        self.eurooffice.mkdir()
        (self.cef / "libcef.so").write_bytes(b"cef-library")
        (self.cef / "resources.pak").write_bytes(b"resources")
        (self.cef / "locales").mkdir()
        (self.cef / "locales" / "en-US.pak").write_bytes(b"locale")
        for relative in ("libcef.so", "resources.pak", "locales/en-US.pak"):
            destination = self.eurooffice / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((self.cef / relative).read_bytes())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_identical_payload_is_reported_as_byte_equivalent(self) -> None:
        report = compare(self.wizp, self.eurooffice)
        self.assertTrue(report["payload_identical"])
        self.assertEqual(report["differences"], [])

    def test_reports_hash_and_missing_file_mismatches(self) -> None:
        (self.eurooffice / "resources.pak").write_bytes(b"different-resource")
        (self.eurooffice / "locales" / "en-US.pak").unlink()
        report = compare(self.wizp, self.eurooffice)
        self.assertFalse(report["payload_identical"])
        self.assertEqual(
            [(item["path"], item["status"]) for item in report["differences"]],
            [
                ("locales/en-US.pak", "missing-from-eurooffice"),
                ("resources.pak", "content-mismatch"),
            ],
        )
        resources = report["differences"][1]
        self.assertNotEqual(resources["wizp"]["sha256"], resources["eurooffice"]["sha256"])

    def test_missing_cef_roots_fail_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "WIZP CEF directory not found"):
            compare(self.root / "missing", self.eurooffice)


if __name__ == "__main__":
    unittest.main()
