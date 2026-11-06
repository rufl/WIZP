#!/usr/bin/env python3
"""Focused regression tests for package-linkage classification."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.package_self_contained_audit import (
    is_static_file_output,
    is_static_ldd_output,
    launcher_wrapper_info,
    read_build_config,
)


class StaticLinkageTests(unittest.TestCase):
    def test_build_config_reports_packaged_cef_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "build.json"
            path.write_text(
                json.dumps(
                    {
                        "defaultRenderer": "cef",
                        "availableRenderers": ["native", "cef"],
                    }
                ),
                encoding="utf-8",
            )
            info = read_build_config(path)
            self.assertTrue(info["valid"])
            self.assertEqual(info["defaultRenderer"], "cef")
            self.assertIn("cef", info["availableRenderers"])

    def test_glibc_static_wording(self) -> None:
        self.assertTrue(is_static_ldd_output("\tnot a dynamic executable"))

    def test_musl_static_wording(self) -> None:
        self.assertTrue(is_static_ldd_output("statically linked"))

    def test_dynamic_output(self) -> None:
        self.assertFalse(is_static_ldd_output("libc.so.6 => /lib/libc.so.6"))

    def test_file_reports_static_binary(self) -> None:
        self.assertTrue(is_static_file_output("ELF 64-bit LSB executable, statically linked"))

    def test_linux_wrapper_bootstraps_clean_cef_profile(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            bin_dir = Path(temp)
            (bin_dir / "launcher.bin").write_bytes(b"launcher")
            (bin_dir / "libwizp_cef_xcb_backoff.so").write_bytes(b"backoff")
            (bin_dir / "launcher").write_text(
                "#!/bin/sh\n"
                "CACHE_ROOT=${XDG_CACHE_HOME:-$HOME/.cache}\n"
                "CEF_CACHE_FORMAT=2\n"
                "mkdir -p \"$CACHE_ROOT/app/dev/CEF/partitions/default\"\n"
                "printf '%s\\n' \"$CEF_CACHE_FORMAT\" > \"$CACHE_ROOT/app/dev/CEF/.electrobun_cef_cache_version\"\n"
                "export LD_LIBRARY_PATH=\"$APP_BIN:$APP_BIN/cef\"\n"
                "export WIZP_CEF_XCB_BACKOFF_US=${WIZP_CEF_XCB_BACKOFF_US:-1000}\n"
                "export LD_PRELOAD=\"$APP_BIN/libwizp_cef_xcb_backoff.so:$APP_BIN/libcef.so\"\n"
                "exec \"$APP_BIN/bun\" \"$APP_BIN/../Resources/main.js\"\n",
                encoding="utf-8",
            )
            info = launcher_wrapper_info(bin_dir)
            self.assertTrue(info["setsPackageLibraryPath"])
            self.assertTrue(info["createsCefProfilePath"])
            self.assertTrue(info["createsCefCacheVersionMarker"])
            self.assertTrue(info["loadsCefXcbBackoff"])
            self.assertTrue(info["setsCefXcbBackoffBudget"])
            self.assertTrue(info["startsBundledBunDirectly"])


if __name__ == "__main__":
    unittest.main()
