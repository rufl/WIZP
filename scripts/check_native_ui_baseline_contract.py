#!/usr/bin/env python3
"""Protect the packaged-native baseline implementation and gate wiring."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(path: Path, marker: str, errors: list[str]) -> None:
    if not path.is_file():
        errors.append(f"missing required file: {path.relative_to(ROOT)}")
        return
    if marker not in path.read_text(encoding="utf-8"):
        errors.append(f"{path.relative_to(ROOT)} missing marker: {marker}")


def validate() -> list[str]:
    errors: list[str] = []
    requirements = {
        ROOT / "src" / "embedded_server.zig": (
            'path, "/__wizp_metrics"',
            "terminalReadRequests",
            "terminal_read_requests.fetchAdd",
            "WIZP_HTTP_REQUEST_LOGS",
            "fn logRequest",
        ),
        ROOT / "src" / "ui" / "Editor.zig": (
            "A clean profile intentionally starts without a workspace",
            "s.file_tree_dir = null;",
            '"WIZP_DEFAULT_TERMINAL_CWD"',
            '"hub/installLocal"',
            "installHubVSIX",
            '"extension/hostStatus"',
        ),
        ROOT / "src" / "bun" / "index.ts": (
            "WIZP_DEFAULT_TERMINAL_CWD: homedir()",
            "delete backendEnv.LD_PRELOAD;",
            "wizpNativeSmokeTerminals",
            "WIZP_NATIVE_UI_SMOKE",
            "__native-terminal-telemetry",
            "nativeTerminalTelemetry",
            "nativeMenuSkippedForSmoke",
            "await Bun.sleep(10);",
            "function forceLinuxPackagedExit",
            'app.on("before-quit"',
            "libNativeWrapper.${suffix}",
            'forceExit: { args: ["i32"], returns: "void" }',
        ),
        ROOT / "electrobun.config.ts": (
            '"disable-gpu": true',
            '"disable-gpu-compositing": true',
        ),
        ROOT / "src" / "bun" / "linux_cef_xcb_backoff.c": (
            "WIZP_CEF_XCB_BACKOFF_US",
            "xcb_poll_for_reply",
            "xcb_poll_for_reply64",
            "consecutive_misses <= 64",
            "consecutive_misses > 512",
        ),
        ROOT / "frontend" / "src" / "components" / "Panel.svelte": (
            "function nativeSmokeTerminalCount()",
            "wizpNativeSmokeTerminals",
            "nativeSmokeTerminalGroups",
        ),
        ROOT / "frontend" / "src" / "components" / "Explorer.svelte": (
            "data-workspace-state=\"empty\"",
            "No folder opened",
            "workspaceFolders.length === 0",
        ),
        ROOT / "frontend" / "src" / "components" / "Panel.svelte": (
            "cwd={terminalCwd || undefined}",
        ),
        ROOT / "frontend" / "src" / "components" / "Terminal.svelte": (
            "const TERMINAL_IDLE_POLL_MS = 400;",
            "await waitForNextPoll(TERMINAL_IDLE_POLL_MS);",
            "data-terminal-rendered-bytes={renderedBytes}",
            "const TERMINAL_IDLE_POLL_MS = 400;",
            "data-terminal-idle-poll-ms",
            "__native-terminal-telemetry",
            "if (lifecycleStatus === 'starting') setLifecycleStatus('ready');",
        ),
        ROOT / "frontend" / "svelte-entry.ts": (
            "import './xterm.css';",
            "wizpOpenPath",
            "workspace/openWorkspace",
            "workspace/setFolders",
            "restoreStartupState",
        ),
        ROOT / "scripts" / "native_ui_baseline_smoke.py": (
            '"UI-NATIVE-001"',
            '"UI-NATIVE-002"',
            '"UI-NATIVE-003"',
            '"UI-NATIVE-004"',
            '"UI-NATIVE-005"',
            '"partial"',
            "ui003_count_observed",
            "PROMPT_RENDER_BUDGET_SECONDS = 3.0",
            'terminal_evidence.get("promptWithinBudget") is True',
            "workspaceEmptyStateFoundByOcr",
            "cefProfileDirectories",
            'profile_dir / ".cache"',
            '"partitions" / "default"',
            "selectedMainProcess",
            "def classify_process_role",
            "def summarize_cpu_by_role",
            "def summarize_top_threads_by_cpu",
            "cpuByRole",
            "topThreadsByCpu",
            "cpuPercentSincePrevious",
            "electrobun-main",
            "cef-renderer",
            "PROCESS_STEADY_CPU_WARMUP_SECONDS",
            "cpuWarmupExcludedSampleCount",
            "--terminal-count",
            "terminalReadRequestsPerSecondPerTerminal",
            "WIZP_NATIVE_UI_SMOKE_TERMINALS",
            "TERMINAL_TYPE_DELAY_MS",
            "SOAK_DURATION_SECONDS",
            "SOAK_RSS_GROWTH_BUDGET_BYTES",
            "--claim-soak",
            "def summarize_soak_evidence",
            "report-soak.json",
            '"finalFrame"',
            '"finalFrameScreenshot"',
            "TERMINAL_COMMAND = \"printf WIZP_UI_TERMINAL_%s OK\"",
            "def ocr_contains_shell_error",
            "ldpreload",
            "markerOutputFoundByOcr",
            '"preTypeClear": "none"',
            "CEF_PROFILE_WARNING_MARKER",
            "def extract_cef_profile_warning",
            "GLXBadWindow",
            "blink.mojom.WidgetHost",
            "Child process terminated by signal:",
            "def extract_native_runtime_diagnostics",
            "def profile_path_diagnostics",
            "def profile_setup_diagnostics",
            "def probe_window_lifecycle",
            "def summarize_window_lifecycle",
            '"windowfocus"',
            '"activationMethod"',
            '"cefProfileWarning"',
            '"cefProfileSetup"',
            '"cefProfileLeafPrecreated"',
            '"leafPrecreatedByHarness"',
            "cefProfileParentDirectories",
            '"nativeRuntimeDiagnostics"',
            '"windowLifecycle"',
            '"firstLoss"',
            '"survivedWindow"',
            "cefProfileWarningDetected",
            "childTerminationSignal",
            "likelyFailureBoundary",
            "def read_native_terminal_telemetry",
            '"terminalPollTelemetry"',
            "__native-terminal-telemetry",
            "def reconcile_retained_process_evidence",
            '"rssBaselinePolicy": "first steady-state process-tree sample"',
            '"rssBaselineAggregateRssBytes"',
            '"launchAggregateRssBytes"',
            '"extensionLifecycle"',
            '"extensions/ui-lifecycle.vsix"',
            '"wizp.uiLifecycle.hello"',
            "WIZP_VIRTUAL_DISPLAY",
        ),
        ROOT / "scripts" / "reconcile_native_ui_report.py": (
            "reconcile_retained_process_evidence",
            "--sync-report-alias",
            'report.get("runId")',
        ),
        ROOT / "scripts" / "parity_daemon_smoke.py": (
            "def test_first_run_workspace",
            'assert folders == {"folders": []}',
        ),
        ROOT / "scripts" / "check_terminal_resource_report.py": (
            'process_probe.get("reaped") is not True',
            'cleanup_probe.get("activeIdsAfterKill")',
        ),
        ROOT / "scripts" / "run_virtual_ui_test.sh": (
            "overzeer-isolated-display",
            "isolated-display-bin",
            "refusing the active desktop",
            "openbox",
            "kwin_x11",
            "WIZP_VIRTUAL_WM",
            "WIZP_VIRTUAL_SCREEN",
            "WIZP_VIRTUAL_DISPLAY",
            "OVERZEER_ALLOW_NESTED_KWIN",
        ),
        ROOT / "scripts" / "isolated-display-bin" / "bwrap": (
            "org.kde.plasma.Notifications.service",
            "--ro-bind-try",
            "dbus-daemon",
        ),
        ROOT / "scripts" / "native_settings_smoke.py": (
            "WIZP_VIRTUAL_DISPLAY",
            "dialog_ocr_matches",
            "dialog_geometry",
            "__webview-evaluate",
            "__webview-report",
            "settingsDialogAccessible",
            "savedValueReopened",
            "settingsReturnedFocusToTrigger",
        ),
        ROOT / "scripts" / "native_editor_smoke.py": (
            "workspace/setFolders",
            "WIZP_UI_EDITOR",
            "dirtyCloseCancelled",
            "dirtyCloseDiscarded",
            "reopenedSavedContent",
            "rendererReloadRestoredSavedContent",
            "processRestartRestoredSavedContent",
            "saveAsCreatedFile",
            "savePermissionFailurePreservedEditor",
            "dirtyCloseDialogAccessible",
            "__webview-evaluate",
            "__webview-report",
            "closeAllEditorsReturnedWelcome",
        ),
        ROOT / "scripts" / "check_native_editor_report.py": (
            "REQUIRED_CHECKS",
            "dirtyCloseDialogAccessible",
            "EXPECTED_NOT_CLAIMED",
            "sessionFileBeforeRestart",
        ),
        ROOT / "scripts" / "check_native_settings_report.py": (
            "REQUIRED_CHECKS",
            "settingsDialogAccessible",
            "savedValueReopened",
            "EXPECTED_NOT_CLAIMED",
        ),
        ROOT / "scripts" / "native_explorer_smoke.py": (
            "workspace/setFolders",
            "keyboardRovingNavigation",
            "keyboardContextMenu",
            "duplicateCreateRecovered",
            "copyPasteCompleted",
            "permissionFailureRecovered",
            "emptyAndErrorStatesRecovered",
            "outlineNavigated",
            "evaluate_webview",
        ),
        ROOT / "scripts" / "check_native_explorer_report.py": (
            "REQUIRED_CHECKS",
            "treeAccessible",
            "permissionFailureRecovered",
            "EXPECTED_NOT_CLAIMED",
        ),
        ROOT / "scripts" / "native_search_smoke.py": (
            "workspace/setFolders",
            "filtersAndContextApplied",
            "invalidRegexRecovered",
            "cancellationClearedStaleResults",
            "resultNavigated",
            "resultLimitReported",
            "replaceOneCompleted",
            "permissionFailurePreservedFile",
            "replaceAllConfirmed",
            "replaceAllFocusRestored",
            "evaluate_webview",
        ),
        ROOT / "scripts" / "check_native_search_report.py": (
            "REQUIRED_CHECKS",
            "searchAccessible",
            "permissionFailurePreservedFile",
            "replaceAllFocusRestored",
            "EXPECTED_NOT_CLAIMED",
        ),
    }
    for path, markers in requirements.items():
        for marker in markers:
            require(path, marker, errors)

    package_path = ROOT / "package.json"
    if package_path.is_file():
        scripts = json.loads(package_path.read_text(encoding="utf-8")).get("scripts", {})
        expected = {
            "check:native-ui-baseline": "python3 scripts/check_native_ui_baseline_contract.py",
            "test:native-ui-baseline": "./scripts/run_virtual_ui_test.sh python3 scripts/native_ui_baseline_smoke.py",
            "test:native-ui-baseline-utils": "python3 -m unittest scripts/test_native_ui_baseline_smoke.py",
            "test:native-editor": "./scripts/run_virtual_ui_test.sh python3 scripts/native_editor_smoke.py",
            "check:native-editor-report": "python3 scripts/check_native_editor_report.py",
            "test:native-settings": "./scripts/run_virtual_ui_test.sh python3 scripts/native_settings_smoke.py",
            "check:native-settings-report": "python3 scripts/check_native_settings_report.py",
            "test:native-explorer": "./scripts/run_virtual_ui_test.sh python3 scripts/native_explorer_smoke.py",
            "check:native-explorer-report": "python3 scripts/check_native_explorer_report.py",
            "test:native-search": "./scripts/run_virtual_ui_test.sh python3 scripts/native_search_smoke.py",
            "check:native-search-report": "python3 scripts/check_native_search_report.py",
        }
        for name, command in expected.items():
            if scripts.get(name) != command:
                errors.append(f"package.json script {name} must be: {command}")
    else:
        errors.append("missing required file: package.json")

    verify_path = ROOT / "scripts" / "verify.sh"
    require(verify_path, "python3 scripts/check_native_ui_baseline_contract.py", errors)
    require(verify_path, "scripts/test_native_ui_baseline_smoke.py", errors)

    workflow = ROOT / ".github" / "workflows" / "parity-hardening.yml"
    for marker in (
        "native-ui-baseline:",
        "npm run test:native-ui-baseline -- --duration 60",
        "npm run test:native-settings",
        "npm run check:native-settings-report",
        "npm run test:native-explorer",
        "npm run check:native-explorer-report",
        "npm run test:native-search",
        "npm run check:native-search-report",
        "npm run test:native-editor",
        "npm run check:native-editor-report",
        "name: native-ui-baseline-evidence",
        "name: native-settings-evidence",
        "name: native-explorer-evidence",
        "name: native-search-evidence",
        "name: native-editor-evidence",
    ):
        require(workflow, marker, errors)
    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("native UI baseline contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("native UI baseline contract ok: implementation, harness, verify, and CI wiring")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
