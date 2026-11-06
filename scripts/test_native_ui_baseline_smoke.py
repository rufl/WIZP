#!/usr/bin/env python3
"""Focused tests for packaged-native metric and process summarization."""

from __future__ import annotations

import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import unittest
import zipfile
from subprocess import CompletedProcess
from pathlib import Path
from unittest.mock import patch

from scripts.native_editor_smoke import editor_dialog_ocr_matches, wait_for_file
from scripts.native_settings_smoke import dialog_geometry, dialog_ocr_matches
from scripts.native_ui_baseline_smoke import (
    PROMPT_MARKER,
    CEF_PROFILE_WARNING_MARKER,
    TERMINAL_TYPE_DELAY_MS,
    SOAK_DURATION_SECONDS,
    SOAK_RSS_GROWTH_BUDGET_BYTES,
    SmokeFailure,
    activate_window,
    capture_window,
    classify_process_role,
    create_fixture,
    extract_cef_profile_warning,
    extract_native_runtime_diagnostics,
    ocr_contains_marker,
    ocr_contains_shell_error,
    parse_active_window_id,
    profile_path_diagnostics,
    profile_setup_diagnostics,
    reconcile_retained_process_evidence,
    require_active_window,
    summarize_cpu_by_role,
    summarize_metrics,
    summarize_processes,
    summarize_soak_evidence,
    summarize_top_threads_by_cpu,
    summarize_window_lifecycle,
    terminal_command_keysyms,
    terminate_process_group,
    write_deterministic_shell_profile,
)


def process_sample(
    phase: str,
    processes: list[dict],
    aggregate_cpu: float | None = None,
    monotonic_seconds: float | None = None,
) -> dict:
    sample = {
        "phase": phase,
        "aggregateRssBytes": 1000,
        "aggregateCpuPercentSincePrevious": aggregate_cpu,
        "processes": processes,
    }
    if monotonic_seconds is not None:
        sample["monotonicSeconds"] = monotonic_seconds
    return sample


class NativeUiBaselineSmokeTests(unittest.TestCase):
    def test_window_activation_falls_back_when_window_manager_lacks_ewmh(self) -> None:
        ok = CompletedProcess(["xdotool"], 0, "", "")
        active = CompletedProcess(["xdotool"], 0, "42\n", "")
        named = CompletedProcess(["xdotool"], 0, "WIZP\n", "")
        window = {"id": 42}
        with patch(
            "scripts.native_ui_baseline_smoke.run_tool",
            side_effect=[ok, SmokeFailure("_NET_ACTIVE_WINDOW unsupported"), ok, active, named],
        ):
            activate_window("xdotool", window)
        self.assertTrue(window["activated"])
        self.assertEqual(window["activationMethod"], "xdotool-windowfocus-fallback")
        self.assertIn("_NET_ACTIVE_WINDOW", window["activationFallbackReason"])

    def test_virtual_capture_falls_back_to_isolated_root_window(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            screenshot = Path(temp) / "capture.png"

            def capture_side_effect(argv, **_kwargs):
                if argv[3] != "root":
                    raise SmokeFailure("window capture unavailable")
                screenshot.write_bytes(b"png")
                return CompletedProcess(argv, 0, "", "")

            with (
                patch.dict("os.environ", {"WIZP_VIRTUAL_DISPLAY": "1"}),
                patch("scripts.native_ui_baseline_smoke.run_tool", side_effect=capture_side_effect),
            ):
                capture_window("import", 42, screenshot)
            self.assertEqual(screenshot.read_bytes(), b"png")

    def test_virtual_input_refuses_unfocused_retained_wizp_window(self) -> None:
        missing_active = SmokeFailure("active window unavailable")
        named = CompletedProcess(["xdotool"], 0, "WIZP\n", "")
        with (
            patch.dict("os.environ", {"WIZP_VIRTUAL_DISPLAY": "1"}),
            patch(
                "scripts.native_ui_baseline_smoke.run_tool",
                side_effect=[missing_active, missing_active, named],
            ),
            self.assertRaises(SmokeFailure),
        ):
            require_active_window("xdotool", {"id": 42}, phase="test")

    def test_teardown_waits_for_detached_descendant_before_profile_removal(self) -> None:
        child_code = (
            "import os, sys, time\n"
            "from pathlib import Path\n"
            "while os.getppid() == int(sys.argv[1]): time.sleep(0.01)\n"
            "time.sleep(0.5)\n"
            "Path(sys.argv[2]).write_text('shutdown finished')\n"
        )
        parent_code = (
            "import os, subprocess, sys, time\n"
            "child = subprocess.Popen([sys.executable, '-c', sys.argv[1], "
            "str(os.getpid()), sys.argv[2]], start_new_session=True, stdout=subprocess.DEVNULL)\n"
            "print(child.pid, flush=True)\n"
            "time.sleep(30)\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "profile-write"
            with subprocess.Popen(
                [sys.executable, "-c", parent_code, child_code, str(marker)],
                start_new_session=True, stdout=subprocess.PIPE, text=True,
            ) as process:
                descendant_fd = None
                try:
                    self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                    descendant_fd = os.pidfd_open(int(process.stdout.readline()))
                    result = terminate_process_group(process, process.pid)
                    self.assertTrue(marker.is_file(), "teardown returned before its detached writer exited")
                    self.assertTrue(select.select([descendant_fd], [], [], 0)[0])
                    self.assertFalse(result["forced"])
                    self.assertEqual(result["remainingPids"], [])
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    if descendant_fd is not None:
                        try:
                            signal.pidfd_send_signal(descendant_fd, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        finally:
                            os.close(descendant_fd)

    def test_active_window_id_parser_accepts_decimal_and_rejects_noise(self) -> None:
        self.assertEqual(parse_active_window_id("20971521\n"), 20971521)
        with self.assertRaisesRegex(SmokeFailure, "invalid active window id"):
            parse_active_window_id("not-a-window")

    def test_ocr_marker_match_tolerates_separator_substitution(self) -> None:
        self.assertTrue(ocr_contains_marker("WIZP. UI. PROMPT*", "WIZP_UI_PROMPT"))
        self.assertTrue(ocr_contains_marker("wizp ui terminal ok", "WIZP_UI_TERMINAL_OK"))
        self.assertTrue(ocr_contains_marker("WIZP. UI TERNINAL-OK", "WIZP_UI_TERMINAL_OK"))
        self.assertTrue(ocr_contains_marker("WIZP-UI EDTTOR ORIGTNAL", "WIZP_UI_EDITOR"))
        self.assertTrue(ocr_contains_marker("WIZP U1 SAVEFATL O s T", "WIZP_UI_SAVEFAIL_OK"))
        self.assertFalse(ocr_contains_marker("WIZP prompt", "WIZP_UI_TERMINAL_OK"))

    def test_settings_dialog_ocr_does_not_depend_on_expanded_theme_names(self) -> None:
        self.assertTrue(dialog_ocr_matches("Settings Appearance Color Theme Font Size Apply & Save"))
        self.assertTrue(
            dialog_ocr_matches(
                "EXPLORER NO FOLDER OPEN Settings Font Sze Tab Size Word Wrap Column"
            )
        )
        self.assertTrue(
            dialog_ocr_matches(
                "Settings APPERRANCE FortSize TabSiee Word Wrap Colamn Render Whitespaoe"
            )
        )
        self.assertTrue(
            dialog_ocr_matches("Settings APPERRANCE Font S TebSize Word Wrap Column")
        )
        self.assertFalse(dialog_ocr_matches("Settings Appearance Color Theme Loading settings Font Size"))
        self.assertFalse(dialog_ocr_matches("Welcome Start Recent Shortcuts"))

    def test_settings_dialog_geometry_uses_actual_viewport_pixels(self) -> None:
        geometry = dialog_geometry({"geometry": {"width": 1280, "height": 820}})
        self.assertEqual(geometry["scale"], 1.0)
        self.assertEqual(geometry["left"], 330)
        self.assertEqual(geometry["width"], 620)
        self.assertEqual(geometry["cancelX"], 776)
        self.assertEqual(geometry["saveX"], 876)
        self.assertEqual(geometry["mainX"], 602)
        self.assertGreater(geometry["footerY"], geometry["top"])

    def test_editor_dirty_close_ocr_requires_file_and_discard_action(self) -> None:
        self.assertTrue(
            editor_dialog_ocr_matches(
                "Save changes to editor-lifecycle.txt? Save Discard Cancel"
            )
        )
        self.assertFalse(editor_dialog_ocr_matches("Save changes? Save Cancel"))

    def test_editor_file_wait_reports_mismatched_content(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "editor.txt"
            path.write_text("saved", encoding="utf-8")
            wait_for_file(path, "saved", timeout=0.01)
            with self.assertRaisesRegex(SmokeFailure, "saved file mismatch"):
                wait_for_file(path, "expected", timeout=0)

    def test_ocr_shell_error_detection_blocks_echoed_marker_false_positive(self) -> None:
        self.assertTrue(ocr_contains_shell_error("bash: ffprintf: command not found"))
        self.assertTrue(
            ocr_contains_shell_error(
                "ERROR: ld.so: object './libcef.so' from LD_PRELOAD cannot be preloaded"
            )
        )
        self.assertFalse(ocr_contains_shell_error("WIZP_UI_TERMINAL_OK"))

    def test_terminal_typing_delay_preserves_native_key_order(self) -> None:
        self.assertGreaterEqual(int(TERMINAL_TYPE_DELAY_MS), 75)

    def test_terminal_command_is_split_into_discrete_keysyms(self) -> None:
        self.assertEqual(
            terminal_command_keysyms("A_%s OK"),
            ["A", "underscore", "percent", "s", "space", "O", "K"],
        )

    def test_login_shell_profile_sources_deterministic_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            profile = Path(temp)
            write_deterministic_shell_profile(profile)
            self.assertIn(PROMPT_MARKER, (profile / ".bashrc").read_text(encoding="utf-8"))
            self.assertIn(".bashrc", (profile / ".bash_profile").read_text(encoding="utf-8"))

    def test_fixture_contains_editor_recovery_and_edge_case_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "fixture"
            manifest = create_fixture(workspace)
            lifecycle = manifest["editorLifecycle"]
            explorer = manifest["explorerLifecycle"]
            search = manifest["searchLifecycle"]
            scm = manifest["scmLifecycle"]
            debug = manifest["debugLifecycle"]
            extension = manifest["extensionLifecycle"]
            self.assertTrue(manifest["externalToPackagedResources"])
            self.assertEqual(
                (workspace / lifecycle["path"]).read_text(encoding="utf-8"),
                lifecycle["originalContent"],
            )
            self.assertIn("nested/deep/long-path-fixture.txt", manifest["files"])
            self.assertIn("nested/deep/unicode-文件.txt", manifest["files"])
            self.assertIn(explorer["renameDeletePath"], manifest["files"])
            self.assertTrue((workspace / explorer["emptyFolder"]).is_dir())
            self.assertEqual(search["query"], "alpha")
            self.assertEqual(search["include"], "search-*.txt")
            self.assertIn(search["navigationPath"], manifest["files"])
            self.assertTrue(all(path in manifest["files"] for path in search["replaceAllPaths"]))
            status = subprocess.check_output(
                ["git", "-C", str(workspace), "status", "--porcelain"],
                text=True,
            )
            self.assertIn(f"UU {scm['conflictPath']}", status)
            self.assertIn(f"M  {scm['stagedPath']}", status)
            self.assertIn(f" M {scm['unstagedPath']}", status)
            self.assertIn(f"?? {scm['untrackedPath']}", status)
            launch = (workspace / debug["launchPath"]).read_text(encoding="utf-8")
            self.assertIn(debug["validConfiguration"], launch)
            self.assertIn(debug["failingConfiguration"], launch)
            self.assertEqual(debug["evaluateExpression"], "answer")
            self.assertEqual(debug["evaluateResult"], "42")
            self.assertGreater((workspace / "large-file.txt").stat().st_size, 64 * 1024)
            self.assertTrue((workspace / debug["invalidLaunchPath"]).is_file())
            self.assertTrue((workspace / extension["validVsixPath"]).is_file())
            self.assertTrue((workspace / extension["invalidVsixPath"]).is_file())
            with zipfile.ZipFile(workspace / extension["validVsixPath"]) as archive:
                package = json.loads(archive.read("extension/package.json"))
            self.assertEqual(package["publisher"] + "." + package["name"], extension["id"])
            self.assertEqual(package["contributes"]["commands"][0]["command"], extension["command"])
            self.assertIn(extension["setting"], package["contributes"]["configuration"]["properties"])

    def test_cef_profile_warning_is_extracted_and_diagnosed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            profile = Path(temp)
            target = profile / ".cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default"
            target.mkdir(parents=True)
            stderr = f"[WARN] {CEF_PROFILE_WARNING_MARKER} {target}\n"
            warning = extract_cef_profile_warning(stderr)
            self.assertTrue(warning["detected"])
            self.assertEqual(warning["path"], str(target))
            diagnostics = profile_path_diagnostics(Path(warning["path"]), stop_at=profile)
            self.assertTrue(diagnostics["target"]["exists"])
            self.assertTrue(diagnostics["target"]["isDirectory"])

    def test_cef_profile_setup_prepares_parent_without_precreating_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            profile = Path(temp)
            target = profile / ".cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default"
            target.parent.mkdir(parents=True)
            diagnostics = profile_setup_diagnostics(
                [target],
                [target.parent],
                stop_at=profile,
                leaf_precreated=False,
            )
            self.assertFalse(diagnostics["leafPrecreatedByHarness"])
            self.assertFalse(diagnostics["leafDiagnostics"][0]["target"]["exists"])
            self.assertTrue(diagnostics["parentDiagnostics"][0]["exists"])
            self.assertTrue(diagnostics["parentDiagnostics"][0]["isDirectory"])

    def test_window_lifecycle_passes_when_all_samples_remain_present(self) -> None:
        summary = summarize_window_lifecycle(
            [
                {"phase": "activated", "elapsedSeconds": 0.1, "present": True, "name": "WIZP"},
                {"phase": "steady", "elapsedSeconds": 1.1, "present": True, "name": "WIZP"},
                {"phase": "final", "elapsedSeconds": 2.1, "present": True, "name": "WIZP"},
            ],
            duration_seconds=2.0,
        )
        self.assertIsNone(summary["firstLoss"])
        self.assertTrue(summary["presentThroughout"])
        self.assertTrue(summary["survivedWindow"])
        self.assertEqual(summary["finalProbe"]["phase"], "final")

    def test_window_lifecycle_reports_first_loss_before_final_probe(self) -> None:
        summary = summarize_window_lifecycle(
            [
                {"phase": "activated", "elapsedSeconds": 0.1, "present": True, "name": "WIZP"},
                {
                    "phase": "steady",
                    "elapsedSeconds": 12.3,
                    "present": False,
                    "error": "BadWindow",
                },
                {
                    "phase": "final",
                    "elapsedSeconds": 12.4,
                    "present": False,
                    "error": "BadWindow",
                },
            ],
            duration_seconds=60.0,
        )
        self.assertEqual(summary["firstLoss"]["phase"], "steady")
        self.assertEqual(summary["firstLoss"]["elapsedSeconds"], 12.3)
        self.assertFalse(summary["presentThroughout"])
        self.assertFalse(summary["survivedWindow"])

    def test_native_runtime_diagnostics_classifies_cef_glx_signal_failure(self) -> None:
        diagnostics = extract_native_runtime_diagnostics(
            "\n".join(
                [
                    "X11 Error: GLXBadWindow (code 170)",
                    "(bun:1052363): Gtk-WARNING **: gtk_disable_setlocale() must be called before gtk_init()",
                    "Message 0 rejected by interface blink.mojom.WidgetHost",
                    "Child process terminated by signal: 5",
                ]
            )
        )
        self.assertTrue(diagnostics["detected"])
        self.assertTrue(diagnostics["glxBadWindowDetected"])
        self.assertTrue(diagnostics["mojoWidgetHostRejectionDetected"])
        self.assertTrue(diagnostics["gtkDisableSetlocaleWarningDetected"])
        self.assertEqual(diagnostics["childTerminationSignal"], 5)
        self.assertEqual(diagnostics["likelyFailureBoundary"], "cef-glx-renderer-signal-5")

    def test_native_runtime_diagnostics_stays_empty_without_runtime_markers(self) -> None:
        diagnostics = extract_native_runtime_diagnostics("WIZP: Running")
        self.assertFalse(diagnostics["detected"])
        self.assertIsNone(diagnostics["childTerminationSignal"])
        self.assertEqual(diagnostics["likelyFailureBoundary"], "none")

    def test_terminal_read_rate_meets_budget(self) -> None:
        samples = [
            {
                "phase": "steady-baseline",
                "ok": True,
                "monotonicSeconds": 10.0,
                "metrics": {"rpcRequests": 20, "terminalReadRequests": 10},
            },
            {
                "phase": "steady",
                "ok": True,
                "monotonicSeconds": 20.0,
                "metrics": {"rpcRequests": 100, "terminalReadRequests": 90},
            },
        ]
        summary = summarize_metrics(samples)
        self.assertEqual(summary["terminalReadRequestsPerSecond"], 8.0)
        self.assertEqual(summary["terminalReadRequestsPerSecondPerTerminal"], 8.0)
        self.assertTrue(summary["terminalReadBudgetPassed"])

    def test_terminal_read_rate_is_normalized_per_terminal(self) -> None:
        samples = [
            {
                "phase": "steady-baseline",
                "ok": True,
                "monotonicSeconds": 10.0,
                "metrics": {"rpcRequests": 20, "terminalReadRequests": 10},
            },
            {
                "phase": "steady",
                "ok": True,
                "monotonicSeconds": 20.0,
                "metrics": {"rpcRequests": 100, "terminalReadRequests": 330},
            },
        ]
        summary = summarize_metrics(samples, terminal_count=4)
        self.assertEqual(summary["terminalReadRequestsPerSecond"], 32.0)
        self.assertEqual(summary["terminalReadRequestsPerSecondPerTerminal"], 8.0)
        self.assertTrue(summary["terminalReadBudgetPassed"])

    def test_terminal_counter_regression_fails_budget(self) -> None:
        samples = [
            {
                "phase": "steady-baseline",
                "ok": True,
                "monotonicSeconds": 10.0,
                "metrics": {"rpcRequests": 20, "terminalReadRequests": 10},
            },
            {
                "phase": "steady",
                "ok": True,
                "monotonicSeconds": 20.0,
                "metrics": {"rpcRequests": 19, "terminalReadRequests": 9},
            },
        ]
        self.assertFalse(summarize_metrics(samples)["terminalReadBudgetPassed"])

    def test_soak_evidence_is_unverified_when_not_requested(self) -> None:
        evidence = summarize_soak_evidence(
            claim_requested=False,
            duration_seconds=SOAK_DURATION_SECONDS,
            survived_duration=True,
            final_ready=True,
            window_survived=True,
            unexpected_exit=None,
            process_summary={"peakAggregateRssGrowthBytes": 1},
            metrics_summary={"validSampleCount": 10},
            final_frame={"captured": True},
        )
        self.assertEqual(evidence["status"], "unverified")

    def test_soak_evidence_requires_duration_and_final_frame(self) -> None:
        too_short = summarize_soak_evidence(
            claim_requested=True,
            duration_seconds=SOAK_DURATION_SECONDS - 1,
            survived_duration=True,
            final_ready=True,
            window_survived=True,
            unexpected_exit=None,
            process_summary={"peakAggregateRssGrowthBytes": 1},
            metrics_summary={"validSampleCount": 10},
            final_frame={"captured": True},
        )
        missing_frame = summarize_soak_evidence(
            claim_requested=True,
            duration_seconds=SOAK_DURATION_SECONDS,
            survived_duration=True,
            final_ready=True,
            window_survived=True,
            unexpected_exit=None,
            process_summary={"peakAggregateRssGrowthBytes": 1},
            metrics_summary={"validSampleCount": 10},
            final_frame={"captured": False},
        )
        self.assertEqual(too_short["status"], "failed")
        self.assertFalse(too_short["durationRequirementPassed"])
        self.assertEqual(missing_frame["status"], "failed")

    def test_soak_evidence_fails_runaway_rss_growth(self) -> None:
        evidence = summarize_soak_evidence(
            claim_requested=True,
            duration_seconds=SOAK_DURATION_SECONDS,
            survived_duration=True,
            final_ready=True,
            window_survived=True,
            unexpected_exit=None,
            process_summary={"peakAggregateRssGrowthBytes": SOAK_RSS_GROWTH_BUDGET_BYTES + 1},
            metrics_summary={"validSampleCount": 10},
            final_frame={"captured": True},
        )
        self.assertEqual(evidence["status"], "failed")
        self.assertFalse(evidence["rssGrowthBudgetPassed"])

    def test_soak_evidence_passes_when_survival_and_growth_are_bounded(self) -> None:
        evidence = summarize_soak_evidence(
            claim_requested=True,
            duration_seconds=SOAK_DURATION_SECONDS,
            survived_duration=True,
            final_ready=True,
            window_survived=True,
            unexpected_exit=None,
            process_summary={"peakAggregateRssGrowthBytes": SOAK_RSS_GROWTH_BUDGET_BYTES},
            metrics_summary={"validSampleCount": 10},
            final_frame={"captured": True},
        )
        self.assertEqual(evidence["status"], "passed")
        self.assertTrue(evidence["rssGrowthBudgetPassed"])

    def test_electrobun_bun_child_is_selected_as_main_process(self) -> None:
        samples = [
            process_sample(
                "steady",
                [
                    {
                        "pid": 41,
                        "name": "launcher.bin",
                        "command": "/opt/WIZP/bin/launcher.bin",
                        "rssBytes": 200,
                        "cpuPercentSincePrevious": 2.5,
                    },
                    {
                        "pid": 42,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                        "rssBytes": 100,
                        "cpuPercentSincePrevious": 1.0,
                    },
                ],
                3.5,
            )
        ]
        summary = summarize_processes(samples, 41)
        self.assertEqual(summary["selectedMainProcess"]["pid"], 42)
        self.assertEqual(summary["selectedMainProcess"]["role"], "electrobun-main")
        role_totals = {item["role"]: item["totalMeanCpuPercent"] for item in summary["cpuByRole"]}
        self.assertEqual(role_totals["electrobun-main"], 1.0)
        self.assertTrue(summary["mainProcessCpuBudgetPassed"])

    def test_process_roles_cover_native_baseline_tree(self) -> None:
        cases = [
            (
                {"name": "bun", "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js"},
                "electrobun-main",
            ),
            (
                {"name": "bun Helper", "command": "/opt/WIZP/bin/bun Helper --type=renderer"},
                "cef-renderer",
            ),
            (
                {
                    "name": "bun Helper",
                    "command": "/opt/WIZP/bin/bun Helper --utility-sub-type=network.mojom.NetworkService",
                },
                "cef-network-service",
            ),
            (
                {"name": "wizp", "command": "/opt/WIZP/Resources/app/wizp --daemon"},
                "zig-daemon",
            ),
            (
                {"name": "bun", "command": "/opt/WIZP/bin/bun -e const __MARKER='__WIZP_EVAL_END__';"},
                "extension-host-eval-bridge",
            ),
            (
                {"name": "bash", "command": "/bin/bash -l -i"},
                "terminal-shell",
            ),
        ]
        for process, role in cases:
            with self.subTest(role=role):
                self.assertEqual(classify_process_role(process), role)

    def test_cpu_by_role_orders_total_mean_cpu(self) -> None:
        roles = summarize_cpu_by_role(
            [
                {"pid": 1, "role": "cef-renderer", "meanCpuPercent": 3.0, "peakRssBytes": 100},
                {"pid": 2, "role": "cef-renderer", "meanCpuPercent": 2.0, "peakRssBytes": 50},
                {"pid": 3, "role": "electrobun-main", "meanCpuPercent": 100.0, "peakRssBytes": 200},
            ]
        )
        self.assertEqual(roles[0]["role"], "electrobun-main")
        self.assertEqual(roles[0]["totalMeanCpuPercent"], 100.0)
        self.assertEqual(roles[1]["role"], "cef-renderer")
        self.assertEqual(roles[1]["totalMeanCpuPercent"], 5.0)
        self.assertEqual(roles[1]["processCount"], 2)
        self.assertEqual(roles[1]["peakRssBytes"], 150)

    def test_top_threads_by_cpu_preserves_process_role(self) -> None:
        threads = summarize_top_threads_by_cpu(
            [
                {
                    "pid": 10,
                    "name": "bun",
                    "role": "electrobun-main",
                    "threads": [
                        {
                            "tid": 10,
                            "name": "bun",
                            "meanCpuPercent": 94.0,
                            "maxCpuPercent": 100.0,
                            "cpuSampleCount": 5,
                        },
                        {
                            "tid": 11,
                            "name": "Chrome_IOThread",
                            "meanCpuPercent": 2.0,
                            "maxCpuPercent": 3.0,
                            "cpuSampleCount": 5,
                        },
                    ],
                },
                {
                    "pid": 12,
                    "name": "bun Helper",
                    "role": "cef-renderer",
                    "threads": [
                        {
                            "tid": 12,
                            "name": "CrRendererMain",
                            "meanCpuPercent": 4.0,
                            "maxCpuPercent": 5.0,
                            "cpuSampleCount": 5,
                        }
                    ],
                },
            ],
            limit=2,
        )
        self.assertEqual(threads[0]["processRole"], "electrobun-main")
        self.assertEqual(threads[0]["tid"], 10)
        self.assertEqual(threads[0]["meanCpuPercent"], 94.0)
        self.assertEqual(threads[1]["processRole"], "cef-renderer")

    def test_process_summary_includes_thread_cpu_samples(self) -> None:
        def main_process(cpu: float, thread_cpu: float) -> dict:
            return {
                "pid": 70,
                "name": "bun",
                "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                "rssBytes": 200,
                "cpuPercentSincePrevious": cpu,
                "threads": [
                    {
                        "tid": 70,
                        "name": "bun",
                        "cpuPercentSincePrevious": thread_cpu,
                    }
                ],
            }

        samples = [
            process_sample("steady", [main_process(100.0, 90.0)], 100.0, 10.0),
            process_sample("steady", [main_process(1.0, 0.5)], 1.0, 21.0),
            process_sample("steady", [main_process(3.0, 2.5)], 3.0, 22.0),
        ]
        summary = summarize_processes(samples, 70)
        self.assertEqual(summary["selectedMainProcess"]["threads"][0]["tid"], 70)
        self.assertEqual(summary["selectedMainProcess"]["threads"][0]["meanCpuPercent"], 1.5)
        self.assertEqual(summary["topThreadsByCpu"][0]["processRole"], "electrobun-main")
        self.assertEqual(summary["topThreadsByCpu"][0]["meanCpuPercent"], 1.5)

    def test_process_summary_reports_aggregate_rss_growth(self) -> None:
        samples = [
            process_sample(
                "steady",
                [
                    {
                        "pid": 80,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                        "rssBytes": 100,
                        "cpuPercentSincePrevious": 1.0,
                    }
                ],
                1.0,
                10.0,
            ),
            process_sample(
                "steady",
                [
                    {
                        "pid": 80,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                        "rssBytes": 200,
                        "cpuPercentSincePrevious": 1.0,
                    }
                ],
                1.0,
                21.0,
            ),
        ]
        samples[0]["aggregateRssBytes"] = 1000
        samples[1]["aggregateRssBytes"] = 1250
        summary = summarize_processes(samples, 80)
        self.assertEqual(summary["firstAggregateRssBytes"], 1000)
        self.assertEqual(summary["finalAggregateRssBytes"], 1250)
        self.assertEqual(summary["peakAggregateRssGrowthBytes"], 250)

    def test_rss_growth_uses_first_steady_process_tree_not_launcher_sample(self) -> None:
        samples = [
            process_sample("launch", [], 0.0, 1.0),
            process_sample("steady-baseline", [], 0.0, 10.0),
            process_sample("steady", [], 0.0, 20.0),
        ]
        samples[0]["aggregateRssBytes"] = 100
        samples[1]["aggregateRssBytes"] = 1000
        samples[2]["aggregateRssBytes"] = 1200
        summary = summarize_processes(samples, 80)
        self.assertEqual(summary["launchAggregateRssBytes"], 100)
        self.assertEqual(summary["firstAggregateRssBytes"], 1000)
        self.assertEqual(summary["rssBaselinePhase"], "steady-baseline")
        self.assertEqual(summary["rssBaselineSampleIndex"], 1)
        self.assertEqual(summary["peakSteadyAggregateRssBytes"], 1200)
        self.assertEqual(summary["peakAggregateRssGrowthBytes"], 200)

    def test_reconcile_retained_process_evidence_refreshes_soak_claim(self) -> None:
        report = {
            "arguments": {"claimSoak": True, "durationSeconds": 1800.0, "terminalCount": 1},
            "claims": {
                "UI-NATIVE-001": {"status": "passed", "evidence": {}},
                "UI-NATIVE-002": {
                    "status": "failed",
                    "evidence": {
                        "survivedDuration": True,
                        "finalReady": True,
                        "windowSurvived": True,
                        "unexpectedExit": None,
                    },
                    "limitations": [
                        "UI-NATIVE-002 does not waive the separate UI-NATIVE-003 CPU budget failure."
                    ],
                },
                "UI-NATIVE-003": {
                    "status": "passed",
                    "evidence": {
                        "terminalCountObserved": True,
                        "terminalReadBudgetPassed": True,
                    },
                },
                "UI-NATIVE-004": {"status": "passed", "evidence": {}},
                "UI-NATIVE-005": {"status": "passed", "evidence": {}},
            },
            "errors": [],
            "finalFrame": {"captured": True},
            "metricsSummary": {"validSampleCount": 2},
            "process": {"launcherPid": 80, "termination": {"forced": False, "remainingPids": []}},
        }
        samples = [
            process_sample("launch", [], 0.0, 1.0),
            process_sample(
                "steady-baseline",
                [
                    {
                        "pid": 80,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                        "rssBytes": 1000,
                        "cpuPercentSincePrevious": 1.0,
                    }
                ],
                1.0,
                10.0,
            ),
            process_sample(
                "steady",
                [
                    {
                        "pid": 80,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                        "rssBytes": 1200,
                        "cpuPercentSincePrevious": 1.0,
                    }
                ],
                1.0,
                21.0,
            ),
        ]
        samples[0]["aggregateRssBytes"] = 100
        samples[1]["aggregateRssBytes"] = 1000
        samples[2]["aggregateRssBytes"] = 1200
        reconciled = reconcile_retained_process_evidence(report, samples)
        self.assertEqual(reconciled["claims"]["UI-NATIVE-002"]["status"], "passed")
        self.assertEqual(reconciled["claims"]["UI-NATIVE-002"]["limitations"], [])
        self.assertEqual(reconciled["status"], "passed")
        self.assertEqual(
            reconciled["processSummary"]["peakAggregateRssGrowthBytes"], 200
        )

    def test_shell_wrapper_selects_non_helper_bun_child(self) -> None:
        samples = [
            process_sample(
                "steady",
                [
                    {
                        "pid": 51,
                        "name": "sh",
                        "command": "/bin/sh /opt/WIZP/bin/launcher",
                        "rssBytes": 20,
                        "cpuPercentSincePrevious": 0.0,
                    },
                    {
                        "pid": 52,
                        "name": "bun",
                        "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/app/bun/index.js",
                        "rssBytes": 200,
                        "cpuPercentSincePrevious": 6.0,
                    },
                ],
                6.0,
            )
        ]
        summary = summarize_processes(samples, 51)
        self.assertEqual(summary["selectedMainProcess"]["pid"], 52)
        self.assertFalse(summary["mainProcessCpuBudgetPassed"])

    def test_cpu_budget_uses_post_warmup_steady_samples(self) -> None:
        def main_process(cpu: float) -> dict:
            return {
                "pid": 62,
                "name": "bun",
                "command": "/opt/WIZP/bin/bun /opt/WIZP/Resources/main.js",
                "rssBytes": 200,
                "cpuPercentSincePrevious": cpu,
            }

        samples = [
            process_sample("steady", [main_process(100.0)], 100.0, 10.0),
            process_sample("steady", [main_process(95.0)], 95.0, 15.0),
            process_sample("steady", [main_process(1.0)], 1.0, 21.0),
            process_sample("steady", [main_process(2.0)], 2.0, 22.0),
        ]
        summary = summarize_processes(samples, 62)
        self.assertEqual(summary["selectedMainProcess"]["pid"], 62)
        self.assertEqual(summary["selectedMainProcess"]["meanCpuPercent"], 1.5)
        self.assertEqual(summary["cpuWarmupExcludedSampleCount"], 2)
        self.assertTrue(summary["cpuWarmupApplied"])
        self.assertTrue(summary["mainProcessCpuBudgetPassed"])


if __name__ == "__main__":
    unittest.main()
