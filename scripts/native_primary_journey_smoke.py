#!/usr/bin/env python3
"""Exercise one packaged Linux SCM, Debug, Extensions, Terminal, or Recovery journey."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import stat
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.check_native_primary_journey_report import (
    RECOVERY_CHECKS,
    validate as validate_report,
)
from scripts.native_editor_smoke import (
    active_window_id,
    active_window_name,
    evaluate_webview,
    search_window_ids,
    type_text,
)
from scripts.native_explorer_smoke import wait_for_webview
from scripts.native_report_promotion import retain_and_promote_report
from scripts.native_settings_smoke import capture_state, click, key
from scripts.native_ui_baseline_smoke import (
    DEFAULT_BINARY,
    RpcClient,
    SmokeFailure,
    activate_window,
    capture_window,
    combine_console,
    contains_resources_app,
    create_fixture,
    proc_stat,
    profile_setup_diagnostics,
    read_native_terminal_telemetry,
    read_metrics,
    require_tool,
    require_unused_port,
    resolve_cli_path,
    sample_process_tree,
    ocr_screenshot,
    ocr_contains_marker,
    summarize_processes,
    select_tesseract_language,
    terminate_process_group,
    utc_now,
    validate_port,
    wait_for_new_window,
    wait_for_ready,
    wait_for_visible_ui,
    write_deterministic_shell_profile,
    write_json,
    write_text,
    xdotool_window_ids,
)

JOURNEYS = ("scm", "debug", "extensions", "terminal", "recovery")
DEFAULT_OUTPUTS = {name: ROOT / "build" / "ui-ux" / f"native-{name}" for name in JOURNEYS}
DEFAULT_PORTS = {
    "scm": (25889, 26889),
    "debug": (27889, 28889),
    "extensions": (29889, 30889),
    "terminal": (31889, 32889),
    "recovery": (33889, 34889),
}
REQUIRED_CHECKS = {
    "recovery": RECOVERY_CHECKS,
    "scm": {
        "workspaceRepositoryLoaded",
        "sourceControlAccessible",
        "credentialPromptCancelled",
        "credentialStatePreserved",
        "stagePermissionFailurePreservedFile",
        "stagePermissionRetryRecovered",
        "stageAndUnstage",
        "diffOpened",
        "commitCreated",
        "discardCancelPreservedFile",
        "discardConfirmed",
        "branchCheckout",
    },
    "debug": {
        "workspaceLaunchLoaded",
        "debugControlsAccessible",
        "adapterFailureExposedRetry",
        "adapterFailurePreservedStoppedState",
        "adapterFailureRecovered",
        "adapterCrashExposedRetry",
        "adapterCrashPreservedInspection",
        "adapterCrashRecovered",
        "sessionStartedPaused",
        "runtimeDetailsVisible",
        "continuePauseAndSteps",
        "evaluationVisible",
        "restartAndStop",
        "stopRestoredFocus",
    },
    "extensions": {
        "extensionsAccessible",
        "networkConsentRequired",
        "networkFailureRedacted",
        "networkFailureRetryRecovered",
        "fixtureSearchCompleted",
        "extensionInstalled",
        "enableDisablePersisted",
        "nativeVsixChooserReviewed",
        "vsixPermissionFailurePreservedState",
        "vsixPermissionRetryRecovered",
        "contributionsVisible",
        "hostCrashUnavailable",
        "hostCrashRetryRecovered",
        "hostRestarted",
        "uninstallCancelRestoredFocus",
        "extensionUninstalled",
    },
    "terminal": {
        "terminalAccessible",
        "nativeClipboardMultilinePasted",
        "localLinkPointerActivated",
        "localLinkKeyboardActivated",
        "commandRendered",
        "ansiUnicodeRendered",
        "findWorked",
        "newTerminalCreated",
        "terminalSplit",
        "spawnFailureIsolated",
        "spawnFailureRetryRecovered",
        "rerunWorked",
        "sustainedBackpressureBounded",
        "normalExitRetained",
        "terminalRelaunched",
        "terminalKilled",
        "sessionsCleanedUp",
    },
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    bootstrap = argparse.ArgumentParser(add_help=False)
    bootstrap.add_argument("--journey", required=True, choices=JOURNEYS)
    known, _ = bootstrap.parse_known_args(argv)
    default_port, default_control_port = DEFAULT_PORTS[known.journey]

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journey", required=True, choices=JOURNEYS)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUTS[known.journey]))
    parser.add_argument("--port", type=int, default=default_port)
    parser.add_argument("--control-port", type=int, default=default_control_port)
    return parser.parse_args(argv)


def run_checked(command: list[str], cwd: Path) -> str:
    process = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise SmokeFailure(
            f"{command[0]} failed ({process.returncode}): {(process.stdout + process.stderr)[-1200:]}"
        )
    return process.stdout.strip()


def prepare_workspace(journey: str, workspace: Path) -> dict[str, Any]:
    fixture = create_fixture(workspace)
    if journey == "scm":
        run_checked(["git", "reset", "--hard", "HEAD"], workspace)
        run_checked(["git", "config", "user.name", "WIZP Native Smoke"], workspace)
        run_checked(["git", "config", "user.email", "native-smoke@invalid.example"], workspace)
        tracked = workspace / "scm-tracked.txt"
        tracked.write_text("base\n", encoding="utf-8")
        run_checked(["git", "add", "scm-tracked.txt"], workspace)
        run_checked(["git", "commit", "-q", "-m", "native fixture base"], workspace)
        run_checked(["git", "branch", "native-fixture-branch"], workspace)
        tracked.write_text("base\nnative change\n", encoding="utf-8")
        (workspace / "scm-discard.txt").write_text("discard me\n", encoding="utf-8")
    elif journey == "debug":
        vscode = workspace / ".vscode"
        vscode.mkdir(exist_ok=True)
        (workspace / "main.zig").write_text(
            "pub fn main() void {\n    const answer: i32 = 42;\n    _ = answer;\n}\n",
            encoding="utf-8",
        )
        (vscode / "launch.json").write_text(
            json.dumps(
                {
                    "version": "0.2.0",
                    "configurations": [
                        {
                            "name": "Native Fixture Debug",
                            "type": "fixture",
                            "request": "launch",
                            "program": "main.zig",
                            "preLaunchTask": "fixture:build",
                            "postDebugTask": "fixture:cleanup",
                        },
                        {
                            "name": "Missing Adapter",
                            "type": "wizp-missing-debug-adapter",
                            "request": "launch",
                            "program": "main.zig",
                        },
                    ],
                    "compounds": [
                        {"name": "Fixture Compound", "configurations": ["Native Fixture Debug"]}
                    ],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    elif journey == "recovery":
        (workspace / "recovery.txt").write_text("WIZP_RECOVERY_DISK\n", encoding="utf-8")
    return fixture


def element_target(control_port: int, selector: str, label: str, phase: str) -> dict[str, Any]:
    script = f"""
(() => {{
  const candidates = Array.from(document.querySelectorAll({json.dumps(selector)}));
  const wanted = {json.dumps(label)};
  const node = candidates.find((candidate) =>
    candidate.getAttribute('aria-label') === wanted ||
    candidate.getAttribute('title') === wanted ||
    candidate.getAttribute('placeholder') === wanted ||
    candidate.textContent?.replace(/\\s+/g, ' ').trim() === wanted
  );
  if (!node) return null;
  const rect = node.getBoundingClientRect();
  return {{
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
    disabled: node.disabled === true,
    tag: node.tagName,
    text: node.textContent?.replace(/\\s+/g, ' ').trim() || '',
  }};
}})()
"""
    value = wait_for_webview(control_port, script, phase)
    if not isinstance(value, dict) or not isinstance(value.get("x"), int):
        raise SmokeFailure(f"{phase} returned invalid target: {value!r}")
    if value.get("disabled") is True:
        raise SmokeFailure(f"{phase} target is disabled: {value!r}")
    return value

def visible_selector_target(control_port: int, selector: str, phase: str) -> dict[str, Any]:
    script = f"""
(() => {{
  const nodes = Array.from(document.querySelectorAll({json.dumps(selector)}));
  const node = nodes[nodes.length - 1];
  if (!node) return null;
  const rect = node.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return null;
  const helperInput = node.closest('.xterm')?.querySelector('.xterm-helper-textarea');
  if (helperInput instanceof HTMLElement) helperInput.focus();
  return {{
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
    disabled: node.disabled === true,
    tag: node.tagName,
  }};
}})()
"""
    value = wait_for_webview(control_port, script, phase)
    if not isinstance(value, dict) or not isinstance(value.get("x"), int):
        raise SmokeFailure(f"{phase} returned invalid target: {value!r}")
    if value.get("disabled") is True:
        raise SmokeFailure(f"{phase} target is disabled: {value!r}")
    return value

def click_visible_selector(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    selector: str,
    phase: str,
) -> dict[str, Any]:
    target = visible_selector_target(control_port, selector, phase)
    click(xdotool, window, target["x"], target["y"], phase)
    if selector == "[data-terminal-status] .xterm-screen":
        evaluate_webview(
            control_port,
            """(() => {
              const nodes = Array.from(document.querySelectorAll('[data-terminal-status] .xterm-screen'));
              const screen = nodes[nodes.length - 1];
              const helperInput = screen?.closest('.xterm')?.querySelector('.xterm-helper-textarea');
              if (helperInput instanceof HTMLElement) helperInput.focus();
              return document.activeElement === helperInput;
            })()""",
            f"{phase} terminal input focus",
        )
    return target


def click_target(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    selector: str,
    label: str,
    phase: str,
) -> dict[str, Any]:
    target = element_target(control_port, selector, label, phase)
    click(xdotool, window, target["x"], target["y"], phase)
    return target


def click_last_target(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    selector: str,
    label: str,
    phase: str,
) -> dict[str, Any]:
    script = f"""
(() => {{
  const wanted = {json.dumps(label)};
  const candidates = Array.from(document.querySelectorAll({json.dumps(selector)})).filter((node) => {{
    const rect = node.getBoundingClientRect();
    const matches = node.getAttribute('aria-label') === wanted ||
      node.getAttribute('title') === wanted ||
      node.getAttribute('placeholder') === wanted;
    return matches && rect.width > 0 && rect.height > 0;
  }});
  const node = candidates[candidates.length - 1];
  if (!node) return null;
  const rect = node.getBoundingClientRect();
  return {{
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
    disabled: node.disabled === true,
  }};
}})()
"""
    target = wait_for_webview(control_port, script, phase)
    if not isinstance(target, dict) or not isinstance(target.get("x"), int):
        raise SmokeFailure(f"{phase} returned invalid target: {target!r}")
    click(xdotool, window, target["x"], target["y"], phase)
    return target


def click_row_button(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    row_text: str,
    button_text: str,
    phase: str,
) -> None:
    script = f"""
(() => {{
  const row = Array.from(document.querySelectorAll('.hub-row')).find((candidate) =>
    candidate.textContent?.includes({json.dumps(row_text)})
  );
  const button = Array.from(row?.querySelectorAll('button') || []).find((candidate) =>
    candidate.textContent?.trim() === {json.dumps(button_text)}
  );
  if (!button || button.disabled) return null;
  const rect = button.getBoundingClientRect();
  return {{ x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) }};
}})()
"""
    target = wait_for_webview(control_port, script, phase)
    if not isinstance(target, dict) or not isinstance(target.get("x"), int):
        raise SmokeFailure(f"{phase} returned invalid row action: {target!r}")
    click(xdotool, window, target["x"], target["y"], phase)


def fill_target(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    selector: str,
    label: str,
    value: str,
    phase: str,
    *,
    submit: bool = False,
) -> None:
    click_target(control_port, xdotool, window, selector, label, phase)
    key(xdotool, window, "ctrl+a", f"select {label}")
    type_text(xdotool, window, value, f"type {label}")
    if submit:
        key(xdotool, window, "Return", f"submit {label}")


def wait_snapshot(control_port: int, script: str, phase: str) -> dict[str, Any]:
    value = wait_for_webview(control_port, script, phase)
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid snapshot: {value!r}")
    return value


def scm_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        r"""
(() => {
  const branch = document.querySelector('[aria-label="Git branch"]');
  const rows = Array.from(document.querySelectorAll('.scm-file-row'));
  if (!branch || !rows.length) return null;
  return {
    branch: branch.value || '',
    files: rows.map((row) => ({
      name: row.querySelector('.scm-file-name')?.textContent?.trim() || '',
      status: row.querySelector('.scm-status-badge')?.textContent?.trim() || '',
      actions: Array.from(row.querySelectorAll('button')).map((button) => button.getAttribute('aria-label') || ''),
    })),
    groups: Array.from(document.querySelectorAll('.scm-group-header')).map((node) => node.textContent?.replace(/\s+/g, ' ').trim() || ''),
    message: document.querySelector('.scm-message')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    toolbar: document.querySelector('.scm-header')?.textContent?.replace(/\s+/g, ' ').trim() || '',
  };
})()
""",
        phase,
    )


def run_scm(
    args: argparse.Namespace,
    xdotool: str,
    window: dict[str, Any],
    workspace: Path,
    report: dict[str, Any],
) -> None:
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Source Control (Ctrl+Shift+G)",
        "open Source Control",
    )
    initial = scm_snapshot(args.control_port, "load Source Control")
    names = {entry.get("name") for entry in initial.get("files", [])}
    if not {"scm-tracked.txt", "scm-discard.txt"}.issubset(names):
        raise SmokeFailure(f"Source Control did not load fixture changes: {initial!r}")
    report["states"] = {"initial": initial}
    report["checks"]["workspaceRepositoryLoaded"] = True
    report["checks"]["sourceControlAccessible"] = True
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Remotes",
        "open Git remotes",
    )
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Fetch",
        "cancel credential-backed fetch",
    )
    credential_cancelled = wait_snapshot(
        args.control_port,
        r"""
(() => {
  const status = document.querySelector('.scm-remote-status');
  if (!status || !status.textContent?.includes('Canceled')) return null;
  return {
    status: status.textContent.replace(/\s+/g, ' ').trim(),
    remote: document.querySelector('select[aria-label="Git remote"]')?.value || '',
  };
})()
""",
        "wait for canceled credential prompt",
    )
    if credential_cancelled.get("remote") != "origin":
        raise SmokeFailure(f"SCM credential cancellation changed the selected remote: {credential_cancelled!r}")
    post_cancel = scm_snapshot(args.control_port, "verify SCM after credential cancellation")
    if post_cancel.get("files") != initial.get("files"):
        raise SmokeFailure(
            "SCM credential cancellation changed the working-tree state: "
            f"before={initial.get('files')!r}, after={post_cancel.get('files')!r}"
        )
    report["states"]["credentialCancellation"] = {
        **credential_cancelled,
        "filesBefore": [entry.get("name", "") for entry in initial.get("files", [])],
        "filesAfter": [entry.get("name", "") for entry in post_cancel.get("files", [])],
    }
    report["checks"]["credentialPromptCancelled"] = True
    report["checks"]["credentialStatePreserved"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Remotes",
        "close Git remotes",
    )


    git_dir = workspace / ".git"
    git_index = git_dir / "index"
    original_git_mode = git_dir.stat().st_mode & 0o777
    if original_git_mode & 0o200 == 0:
        raise SmokeFailure(f"SCM fixture .git directory was not owner-writable: {oct(original_git_mode)}")
    staged_paths_before = run_checked(["git", "diff", "--cached", "--name-only"], workspace).splitlines()
    unstaged_paths_before = run_checked(["git", "diff", "--name-only"], workspace).splitlines()
    index_sha256_before = hashlib.sha256(git_index.read_bytes()).hexdigest()
    if "scm-tracked.txt" in staged_paths_before or "scm-tracked.txt" not in unstaged_paths_before:
        raise SmokeFailure(
            "SCM fixture did not begin with scm-tracked.txt preserved only in the working tree: "
            f"staged={staged_paths_before!r}, unstaged={unstaged_paths_before!r}"
        )

    os.chmod(git_dir, 0o500)
    restricted_git_mode = git_dir.stat().st_mode & 0o777
    try:
        if restricted_git_mode != 0o500:
            raise SmokeFailure(f"SCM fixture .git restriction did not apply: {oct(restricted_git_mode)}")
        click_target(
            args.control_port,
            xdotool,
            window,
            "button",
            "Stage scm-tracked.txt",
            "stage tracked file without repository write permission",
        )
        permission_failure = wait_snapshot(
            args.control_port,
            r"""
(() => {
  const message = document.querySelector('.scm-message[role="alert"]');
  const action = message?.querySelector('button');
  if (!message || !action) return null;
  return {
    message: message.textContent?.replace(/\s+/g, ' ').trim() || '',
    messageRole: message.getAttribute('role') || '',
    messageAction: action.textContent?.trim() || '',
  };
})()
""",
            "wait for SCM stage permission failure",
        )
        staged_paths_after = run_checked(["git", "diff", "--cached", "--name-only"], workspace).splitlines()
        unstaged_paths_after = run_checked(["git", "diff", "--name-only"], workspace).splitlines()
        index_sha256_after = hashlib.sha256(git_index.read_bytes()).hexdigest()
        if (
            permission_failure.get("messageRole") != "alert"
            or permission_failure.get("messageAction") != "Retry"
            or "permission denied" not in str(permission_failure.get("message", "")).lower()
        ):
            raise SmokeFailure(f"SCM stage failure did not expose an alert-labelled retry: {permission_failure!r}")
        if staged_paths_after != staged_paths_before or index_sha256_after != index_sha256_before:
            raise SmokeFailure(
                "SCM stage permission failure changed the Git index: "
                f"before={staged_paths_before!r}/{index_sha256_before}, "
                f"after={staged_paths_after!r}/{index_sha256_after}"
            )
        if "scm-tracked.txt" not in unstaged_paths_after:
            raise SmokeFailure(
                f"SCM stage permission failure did not preserve the unstaged file: {unstaged_paths_after!r}"
            )
    finally:
        os.chmod(git_dir, original_git_mode)

    restored_git_mode = git_dir.stat().st_mode & 0o777
    if restored_git_mode != original_git_mode:
        raise SmokeFailure(
            f"SCM fixture .git mode was not restored: {oct(original_git_mode)} -> {oct(restored_git_mode)}"
        )
    report["permissionRecovery"] = {
        "gitDirectory": ".git",
        "originalMode": oct(original_git_mode),
        "restrictedMode": oct(restricted_git_mode),
        "restoredMode": oct(restored_git_mode),
    }
    report["states"]["stagePermissionFailure"] = {
        **permission_failure,
        "indexPath": ".git/index",
        "indexSha256Before": index_sha256_before,
        "indexSha256After": index_sha256_after,
        "stagedPathsBefore": staged_paths_before,
        "stagedPathsAfter": staged_paths_after,
        "unstagedPathsBefore": unstaged_paths_before,
        "unstagedPathsAfter": unstaged_paths_after,
    }
    report["checks"]["stagePermissionFailurePreservedFile"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Retry",
        "reload Source Control after restoring repository permission",
    )
    permission_reload = wait_snapshot(
        args.control_port,
        r"""
(() => {
  const stage = document.querySelector('[aria-label="Stage scm-tracked.txt"]');
  const alert = document.querySelector('.scm-message[role="alert"]');
  if (!stage || stage.disabled || alert) return null;
  return { messageCleared: true, stageEnabled: true };
})()
""",
        "wait for Source Control retry after permission recovery",
    )
    report["states"]["stagePermissionReload"] = permission_reload
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Stage scm-tracked.txt",
        "retry tracked file stage after permission recovery",
    )
    staged = wait_snapshot(
        args.control_port,
        "(() => document.querySelector('[aria-label=\"Unstage scm-tracked.txt\"]') ? { staged: true } : null)()",
        "wait for staged file",
    )
    recovered_paths = run_checked(["git", "diff", "--cached", "--name-only"], workspace).splitlines()
    recovered_index_sha256 = hashlib.sha256(git_index.read_bytes()).hexdigest()
    if "scm-tracked.txt" not in recovered_paths or recovered_index_sha256 == index_sha256_after:
        raise SmokeFailure(
            "SCM stage retry did not update the Git index: "
            f"paths={recovered_paths!r}, sha256={recovered_index_sha256}"
        )
    report["states"]["stagePermissionRetry"] = {
        **staged,
        "indexSha256": recovered_index_sha256,
        "stagedPaths": recovered_paths,
    }
    report["states"]["staged"] = staged
    report["checks"]["stagePermissionRetryRecovered"] = True
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Show diff for scm-tracked.txt",
        "open tracked diff",
    )
    diff = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('[role=\"region\"][aria-label^=\"Diff for\"]'); return node ? { label: node.getAttribute('aria-label'), text: node.textContent.replace(/\\s+/g, ' ').trim() } : null; })()",
        "wait for tracked diff",
    )
    report["states"]["diff"] = diff
    report["checks"]["diffOpened"] = True
    click_target(args.control_port, xdotool, window, "button", "Close diff", "close tracked diff")
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Unstage scm-tracked.txt",
        "unstage tracked file",
    )
    wait_for_webview(
        args.control_port,
        "Boolean(document.querySelector('[aria-label=\"Stage scm-tracked.txt\"]')) ? true : null",
        "wait for unstaged file",
    )
    report["checks"]["stageAndUnstage"] = True

    click_target(args.control_port, xdotool, window, "button", "Stage All", "stage all changes")
    wait_for_webview(
        args.control_port,
        "document.querySelectorAll('[aria-label^=\"Unstage \"]').length >= 2 ? true : null",
        "wait for all staged changes",
    )
    fill_target(
        args.control_port,
        xdotool,
        window,
        "input",
        "Commit message",
        "native packaged SCM journey",
        "enter commit message",
        submit=True,
    )
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if run_checked(["git", "log", "-1", "--pretty=%s"], workspace) == "native packaged SCM journey":
            break
        time.sleep(0.2)
    else:
        raise SmokeFailure("SCM commit was not created")
    report["checks"]["commitCreated"] = True

    wait_for_webview(
        args.control_port,
        "(() => { const refresh = document.querySelector('[aria-label=\"Refresh source control\"]'); return refresh && !refresh.disabled ? true : null; })()",
        "wait for Source Control after commit",
    )
    discard_path = workspace / "scm-delete-untracked.txt"
    discard_path.write_text("discard me\n", encoding="utf-8")
    click_target(args.control_port, xdotool, window, "button", "Refresh source control", "refresh discard fixture")
    wait_for_webview(
        args.control_port,
        "Boolean(document.querySelector('[aria-label=\"Discard scm-delete-untracked.txt\"]')) ? true : null",
        "wait for discard action",
    )
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Discard scm-delete-untracked.txt",
        "open discard confirmation",
    )
    dialog = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('dialog.scm-discard-dialog[open]'); return node ? { title: node.querySelector('h2')?.textContent?.trim() || '', buttons: Array.from(node.querySelectorAll('button')).map((button) => button.textContent?.trim() || '') } : null; })()",
        "wait for discard confirmation",
    )
    key(xdotool, window, "Escape", "cancel discard confirmation")
    if not discard_path.exists():
        raise SmokeFailure("canceling discard removed the file")
    report["states"]["discardDialog"] = dialog
    report["checks"]["discardCancelPreservedFile"] = True
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Discard scm-delete-untracked.txt",
        "reopen discard confirmation",
    )
    wait_for_webview(
        args.control_port,
        "Boolean(document.querySelector('dialog.scm-discard-dialog[open]')) ? true : null",
        "wait for reopened discard confirmation",
    )
    click_target(args.control_port, xdotool, window, "button", "Delete File", "confirm discard")
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline and discard_path.exists():
        time.sleep(0.1)
    if discard_path.exists():
        raise SmokeFailure("confirmed discard did not remove untracked file")
    report["checks"]["discardConfirmed"] = True

    wait_for_webview(
        args.control_port,
        "(() => { const branch = document.querySelector('[aria-label=\"Git branch\"]'); return branch && !branch.disabled ? true : null; })()",
        "wait for Git branch control",
    )
    click_target(args.control_port, xdotool, window, "select", "Git branch", "focus Git branch")
    key(xdotool, window, "End", "select fixture branch")
    key(xdotool, window, "Return", "checkout fixture branch")
    deadline = time.monotonic() + 8.0
    branch = ""
    while time.monotonic() < deadline:
        branch = run_checked(["git", "branch", "--show-current"], workspace)
        if branch == "native-fixture-branch":
            break
        time.sleep(0.1)
    if branch != "native-fixture-branch":
        raise SmokeFailure(f"branch checkout did not complete: {branch!r}")
    report["checks"]["branchCheckout"] = True


def debug_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        r"""
(() => {
  const toolbar = document.querySelector('[role="toolbar"][aria-label="Debug controls"]');
  if (!toolbar) return null;
  const session = document.querySelector('.debug-session-bar');
  const message = document.querySelector('.debug-message');
  const start = document.querySelector('button[title="Start Debugging (F5)"]');
  return {
    launch: document.querySelector('[aria-label="Launch configuration"]')?.value || '',
    schema: document.querySelector('.debug-launch-meta')?.getAttribute('data-schema-valid') || '',
    running: Boolean(session),
    paused: session?.getAttribute('data-paused') || '',
    sessionText: session?.textContent?.replace(/\s+/g, ' ').trim() || '',
    startEnabled: Boolean(start && !start.disabled),
    stack: Array.from(document.querySelectorAll('.debug-stack-row')).map((node) => node.textContent?.replace(/\s+/g, ' ').trim() || ''),
    variables: Array.from(document.querySelectorAll('[aria-label="Variables"] .debug-data-row')).map((node) => node.textContent?.replace(/\s+/g, ' ').trim() || ''),
    watches: Array.from(document.querySelectorAll('[aria-label="Watch expressions"] .debug-data-row')).map((node) => node.textContent?.replace(/\s+/g, ' ').trim() || ''),
    activeLabel: document.activeElement?.getAttribute?.('aria-label') || document.activeElement?.getAttribute?.('title') || '',
    message: message?.textContent?.replace(/\s+/g, ' ').trim() || '',
    messageRole: message?.getAttribute('role') || '',
    messageLive: message?.getAttribute('aria-live') || '',
    messageAction: message?.querySelector('button')?.textContent?.trim() || '',
  };
})()
""",
        phase,
    )


def run_debug(
    args: argparse.Namespace,
    xdotool: str,
    window: dict[str, Any],
    _workspace: Path,
    report: dict[str, Any],
) -> None:
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Run and Debug (Ctrl+Shift+D)",
        "open Run and Debug",
    )
    initial = debug_snapshot(args.control_port, "load Debug fixture")
    if initial.get("launch") != "Native Fixture Debug" or initial.get("schema") != "true":
        raise SmokeFailure(f"Debug fixture launch configuration did not load: {initial!r}")
    report["states"] = {"initial": initial}
    report["checks"]["workspaceLaunchLoaded"] = True
    report["checks"]["debugControlsAccessible"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "select",
        "Launch configuration",
        "focus failing Debug launch configuration",
    )
    key(xdotool, window, "End", "select missing Debug adapter")
    key(xdotool, window, "Return", "confirm missing Debug adapter")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Launch configuration\"]')?.value === 'Missing Adapter' ? true : null",
        "wait for missing Debug adapter selection",
    )
    adapter_attempt = debug_snapshot(args.control_port, "capture stopped state before missing Debug adapter")
    if (
        adapter_attempt.get("launch") != "Missing Adapter"
        or adapter_attempt.get("running") is not False
        or adapter_attempt.get("paused") != ""
        or adapter_attempt.get("sessionText") != ""
        or adapter_attempt.get("startEnabled") is not True
    ):
        raise SmokeFailure(f"Debug missing-adapter attempt did not begin stopped: {adapter_attempt!r}")
    report["states"]["adapterAttempt"] = adapter_attempt

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Start Debugging (F5)",
        "start missing Debug adapter",
    )
    adapter_failure = wait_snapshot(
        args.control_port,
        r"""
(() => {
  const message = document.querySelector('.debug-message.error[role="alert"]');
  const action = message?.querySelector('button');
  const session = document.querySelector('.debug-session-bar');
  const start = document.querySelector('button[title="Start Debugging (F5)"]');
  if (!message || !action || !start || start.disabled) return null;
  return {
    launch: document.querySelector('[aria-label="Launch configuration"]')?.value || '',
    running: Boolean(session),
    paused: session?.getAttribute('data-paused') || '',
    sessionText: session?.textContent?.replace(/\s+/g, ' ').trim() || '',
    startEnabled: !start.disabled,
    message: message.textContent?.replace(/\s+/g, ' ').trim() || '',
    messageRole: message.getAttribute('role') || '',
    messageLive: message.getAttribute('aria-live') || '',
    messageAction: action.textContent?.trim() || '',
  };
})()
""",
        "wait for Debug adapter process failure",
    )
    adapter_failure_message = str(adapter_failure.get("message", ""))
    if (
        adapter_failure.get("messageRole") != "alert"
        or adapter_failure.get("messageLive") != "assertive"
        or adapter_failure.get("messageAction") not in {"Retry", "Retry start"}
        or not any(
            marker in adapter_failure_message
            for marker in ("Debug adapter start failed", "Debug initialize failed")
        )
    ):
        raise SmokeFailure(f"Debug adapter failure did not expose an alert-labelled retry: {adapter_failure!r}")
    if any(
        (
            adapter_failure.get("launch") != adapter_attempt.get("launch"),
            adapter_failure.get("running") is not False,
            adapter_failure.get("paused") != adapter_attempt.get("paused"),
            adapter_failure.get("sessionText") != adapter_attempt.get("sessionText"),
            adapter_failure.get("startEnabled") is not True,
        )
    ):
        raise SmokeFailure(f"Debug adapter failure changed the stopped session state: {adapter_failure!r}")
    report["states"]["adapterFailure"] = adapter_failure
    report["checks"]["adapterFailureExposedRetry"] = True
    report["checks"]["adapterFailurePreservedStoppedState"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Retry start",
        "retry Debug state after missing adapter failure",
    )
    time.sleep(0.5)
    adapter_retry = wait_snapshot(
        args.control_port,
        r"""
(() => {
  const select = document.querySelector('[aria-label="Launch configuration"]');
  const start = document.querySelector('button[title="Start Debugging (F5)"]');
  const session = document.querySelector('.debug-session-bar');
  const message = document.querySelector('.debug-message');
  if (!select || select.disabled || !start || start.disabled || (message && !message.classList.contains('error'))) {
    return null;
  }
  return {
    launch: select.value || '',
    running: Boolean(session),
    paused: session?.getAttribute('data-paused') || '',
    sessionText: session?.textContent?.replace(/\s+/g, ' ').trim() || '',
    startEnabled: true,
    message: message?.textContent?.replace(/\s+/g, ' ').trim() || '',
    messageRole: message?.getAttribute('role') || '',
    messageLive: message?.getAttribute('aria-live') || '',
    messageAction: message?.querySelector('button')?.textContent?.trim() || '',
    messageCleared: !message,
  };
})()
""",
        "wait for Debug state retry after adapter failure",
    )
    if (
        adapter_retry.get("launch") != "Missing Adapter"
        or adapter_retry.get("running") is not False
        or adapter_retry.get("paused") != ""
        or adapter_retry.get("sessionText") != ""
        or adapter_retry.get("startEnabled") is not True
        or not isinstance(adapter_retry.get("messageCleared"), bool)
    ):
        raise SmokeFailure(f"Debug adapter retry did not preserve the stopped launch state: {adapter_retry!r}")
    report["states"]["adapterRetry"] = adapter_retry

    click_target(
        args.control_port,
        xdotool,
        window,
        "select",
        "Launch configuration",
        "focus working Debug launch configuration",
    )
    key(xdotool, window, "Home", "select fixture Debug adapter")
    key(xdotool, window, "Return", "confirm fixture Debug adapter")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Launch configuration\"]')?.value === 'Native Fixture Debug' ? true : null",
        "wait for fixture Debug adapter selection",
    )

    click_target(args.control_port, xdotool, window, "button", "Start Debugging (F5)", "start fixture debugger")
    paused = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('.debug-session-bar[data-paused=\"true\"]'); return node ? { text: node.textContent.replace(/\\s+/g, ' ').trim() } : null; })()",
        "wait for paused fixture debugger",
    )
    details = wait_for_webview(
        args.control_port,
        "document.querySelectorAll('.debug-stack-row').length > 0 && document.querySelectorAll('[aria-label=\"Variables\"] .debug-data-row').length > 0 ? true : null",
        "wait for Debug runtime details",
    )
    report["states"]["paused"] = paused
    report["checks"]["sessionStartedPaused"] = True
    report["checks"]["runtimeDetailsVisible"] = details is True
    adapter_recovery = debug_snapshot(args.control_port, "capture Debug adapter recovery")
    if (
        adapter_recovery.get("launch") != "Native Fixture Debug"
        or adapter_recovery.get("running") is not True
        or adapter_recovery.get("paused") != "true"
        or adapter_recovery.get("startEnabled") is not False
        or "Native Fixture Debug started." not in str(adapter_recovery.get("message", ""))
    ):
        raise SmokeFailure(f"Debug adapter recovery did not start the fixture session: {adapter_recovery!r}")
    report["states"]["adapterRecovery"] = adapter_recovery
    report["checks"]["adapterFailureRecovered"] = True
    crash_result = evaluate_webview(
        args.control_port,
        "(async () => { const kill = window.__wizpKillDebugFixtureAdapter; return kill ? await kill() : null; })()",
        "kill fixture Debug adapter",
    )
    if not isinstance(crash_result, dict) or crash_result.get("adapterKilled") is not True or crash_result.get("orphaned") is not False:
        raise SmokeFailure(f"fixture Debug adapter kill did not report clean ownership: {crash_result!r}")
    adapter_crash = debug_snapshot(args.control_port, "capture killed Debug adapter")
    if (
        adapter_crash.get("running") is not False
        or adapter_crash.get("messageAction") != "Retry debugging"
        or "last known inspection" not in str(adapter_crash.get("message", "")).lower()
        or not adapter_crash.get("stack")
        or not adapter_crash.get("variables")
    ):
        raise SmokeFailure(f"Debug adapter crash did not preserve retry and inspection state: {adapter_crash!r}")
    report["states"]["adapterCrash"] = {**adapter_crash, **crash_result}
    report["checks"]["adapterCrashExposedRetry"] = True
    report["checks"]["adapterCrashPreservedInspection"] = True
    click_target(args.control_port, xdotool, window, "button", "Retry debugging", "retry killed Debug adapter")
    adapter_crash_retry = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('.debug-session-bar[data-paused=\"true\"]'); return node ? { text: node.textContent.replace(/\\s+/g, ' ').trim() } : null; })()",
        "wait for killed Debug adapter recovery",
    )
    report["states"]["adapterCrashRetry"] = adapter_crash_retry
    report["checks"]["adapterCrashRecovered"] = True


    click_target(args.control_port, xdotool, window, "button", "Continue debugging", "continue debugger")
    wait_for_webview(
        args.control_port,
        "document.querySelector('.debug-session-bar[data-paused=\"false\"]') ? true : null",
        "wait for running debugger",
    )
    click_target(args.control_port, xdotool, window, "button", "Pause debugging", "pause debugger")
    wait_for_webview(
        args.control_port,
        "document.querySelector('.debug-session-bar[data-paused=\"true\"]') ? true : null",
        "wait for paused debugger",
    )
    for label in ("Step over", "Step into", "Step out"):
        click_target(args.control_port, xdotool, window, "button", label, label)
        wait_for_webview(
            args.control_port,
            "document.querySelector('.debug-session-bar[data-paused=\"true\"]') ? true : null",
            f"wait after {label}",
        )
    report["checks"]["continuePauseAndSteps"] = True

    click_target(args.control_port, xdotool, window, "[role=\"button\"]", "Debug Console", "open Debug Console")
    fill_target(
        args.control_port,
        xdotool,
        window,
        "input",
        "Debug expression",
        "answer",
        "evaluate fixture expression",
        submit=True,
    )
    evaluation = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('[aria-label=\"Debug Console output\"]'); const text = node?.textContent || ''; return text.includes('> answer') && text.includes('42') ? { text: text.replace(/\\s+/g, ' ').trim() } : null; })()",
        "wait for Debug evaluation",
    )
    report["states"]["evaluation"] = evaluation
    report["checks"]["evaluationVisible"] = True

    click_target(args.control_port, xdotool, window, "button", "Restart debugging", "restart debugger")
    wait_for_webview(
        args.control_port,
        "document.querySelector('.debug-session-bar[data-paused=\"true\"]') ? true : null",
        "wait for restarted debugger",
    )
    click_target(args.control_port, xdotool, window, "button", "Stop debugging", "stop debugger")
    stopped = wait_for_webview(
        args.control_port,
        "(() => { const start = document.querySelector('button[title=\"Start Debugging (F5)\"]'); return start && document.activeElement === start ? true : null; })()",
        "wait for Debug stop focus restoration",
    )
    report["checks"]["restartAndStop"] = True
    report["checks"]["stopRestoredFocus"] = stopped is True


def complete_native_open_dialog(
    xdotool: str,
    import_tool: str,
    tesseract: str,
    language: str,
    app_window: dict[str, Any],
    selected_path: Path,
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
    timeout: float = 12.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_ocr = ""
    last_window = int(app_window["id"])
    while time.monotonic() < deadline:
        candidates = {active_window_id(xdotool)}
        candidates.update(search_window_ids(xdotool, "--name", "Open File"))
        candidates.update(search_window_ids(xdotool, "--class", "zenity"))
        for current in sorted(candidates):
            last_window = current
            if current == int(app_window["id"]):
                continue
            name = active_window_name(xdotool, current)
            compact_name = "".join(character for character in name.casefold() if character.isalnum())
            if "openfile" not in compact_name and "zenity" not in compact_name:
                continue
            capture_window(import_tool, current, screenshot)
            last_ocr = ocr_screenshot(tesseract, screenshot, stderr_path, language)
            write_text(ocr_path, last_ocr)
            run_checked([xdotool, "windowactivate", str(current)], ROOT)
            time.sleep(0.2)
            key(xdotool, {}, "ctrl+a", "select native open path")
            type_text(xdotool, {}, str(selected_path), "type native open path")
            key(xdotool, {}, "Return", "accept native open path")
            return {"windowId": current, "windowName": name, "ocr": last_ocr}
        time.sleep(0.2)
    raise SmokeFailure(
        f"native open chooser did not become active; lastWindow={last_window}, last OCR: {last_ocr[:500]!r}"
    )


def extensions_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        r"""
(() => {
  const tabs = document.querySelector('[role="tablist"][aria-label="Extensions"]');
  if (!tabs) return null;
  return {
    selectedTab: tabs.querySelector('[role="tab"][aria-selected="true"]')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    host: document.querySelector('[aria-label="Extension host status"]')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    message: document.querySelector('.hub-message')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    installed: Array.from(document.querySelectorAll('[aria-label="Installed extensions"] .hub-row')).map((row) => ({
      text: row.textContent?.replace(/\s+/g, ' ').trim() || '',
      buttons: Array.from(row.querySelectorAll('button')).map((button) => button.textContent?.trim() || ''),
    })),
  };
})()
""",
        phase,
    )


def run_extensions(
    args: argparse.Namespace,
    xdotool: str,
    window: dict[str, Any],
    _workspace: Path,
    report: dict[str, Any],
) -> None:
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Extensions (Ctrl+Shift+X)",
        "open Extensions",
    )
    initial = extensions_snapshot(args.control_port, "load Extensions")
    report["states"] = {"initial": initial}
    report["checks"]["extensionsAccessible"] = True

    fill_target(
        args.control_port,
        xdotool,
        window,
        "input",
        "Search extensions",
        "alpha",
        "search fixture extensions",
        submit=True,
    )
    consent = wait_for_webview(
        args.control_port,
        "document.body.textContent.includes('Allow OpenVSX network access?') ? true : null",
        "wait for OpenVSX consent",
    )
    report["checks"]["networkConsentRequired"] = consent is True
    evaluate_webview(args.control_port, "(() => { window.__wizpHubFixture = true; return true; })()", "enable Hub fixture")
    click_target(args.control_port, xdotool, window, "button", "Allow OpenVSX Search", "allow fixture OpenVSX search")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Install Alpha Tools\"]') ? true : null",
        "wait for fixture extension results",
    )
    fill_target(
        args.control_port,
        xdotool,
        window,
        "input",
        "Search extensions",
        "network-failure",
        "search deterministic network failure",
        submit=True,
    )
    wait_for_webview(
        args.control_port,
        "document.querySelector('.hub-message')?.textContent.includes('[redacted]') && !document.body.textContent.includes('fixture-secret') ? true : null",
        "wait for redacted network failure",
    )
    report["checks"]["networkFailureRedacted"] = True
    click_target(args.control_port, xdotool, window, "button", "Retry search", "retry network failure")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Install Alpha Tools\"]') ? true : null",
        "wait for recovered network search",
    )
    report["checks"]["networkFailureRetryRecovered"] = True
    report["checks"]["fixtureSearchCompleted"] = True
    click_target(args.control_port, xdotool, window, "button", "Install Alpha Tools", "install fixture extension")
    installed = wait_snapshot(
        args.control_port,
        "(() => { const row = Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).find((node) => node.textContent.includes('Alpha Tools')); return row ? { text: row.textContent.replace(/\\s+/g, ' ').trim() } : null; })()",
        "wait for installed fixture extension",
    )
    report["states"]["installed"] = installed
    report["checks"]["extensionInstalled"] = True

    click_target(args.control_port, xdotool, window, "button", "Disable", "disable fixture extension")
    wait_for_webview(
        args.control_port,
        "Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).some((row) => row.textContent.includes('Alpha Tools') && row.textContent.includes('Disabled')) ? true : null",
        "wait for disabled fixture extension",
    )
    click_target(args.control_port, xdotool, window, "button", "Enable", "enable fixture extension")
    wait_for_webview(
        args.control_port,
        "Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).some((row) => row.textContent.includes('Alpha Tools') && row.textContent.includes('Enabled')) ? true : null",
        "wait for enabled fixture extension",
    )
    report["checks"]["enableDisablePersisted"] = True
    import_tool = require_tool("import")
    tesseract = require_tool("tesseract")
    language = select_tesseract_language(tesseract)
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    chooser_png = output_dir / f"{report['runId']}-01-native-vsix-dialog.png"
    chooser_ocr = output_dir / f"{report['runId']}-01-native-vsix-dialog.txt"
    chooser_stderr = output_dir / f"{report['runId']}-01-native-vsix-dialog.stderr.log"
    profile_dir = Path(args.profile_dir)
    extensions_root = profile_dir / ".wizp" / "extensions"
    extensions_root.mkdir(parents=True, exist_ok=True)
    original_extensions_mode = stat.S_IMODE(extensions_root.stat().st_mode)
    os.chmod(extensions_root, 0o500)
    try:
        click_target(args.control_port, xdotool, window, "button", "Choose VSIX…", "open native VSIX chooser for permission failure")
        chooser = complete_native_open_dialog(
            xdotool,
            import_tool,
            tesseract,
            language,
            window,
            _workspace / "extensions" / "ui-lifecycle.vsix",
            chooser_png,
            chooser_ocr,
            chooser_stderr,
        )
        activate_window(xdotool, window)
        wait_for_webview(
            args.control_port,
            "document.querySelector('.hub-message')?.textContent.includes('VSIX install failed') && document.querySelector('button.hub-link-button')?.textContent.includes('Retry VSIX install') ? true : null",
            "wait for VSIX permission failure",
        )
        preserved = wait_for_webview(
            args.control_port,
            "!Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).some((row) => row.textContent.includes('UI Lifecycle Extension')) ? true : null",
            "verify VSIX permission failure preserved installed state",
        )
        report["checks"]["vsixPermissionFailurePreservedState"] = preserved is True
    finally:
        os.chmod(extensions_root, original_extensions_mode)
    click_target(args.control_port, xdotool, window, "button", "Retry VSIX install", "retry VSIX after restoring permissions")
    wait_for_webview(
        args.control_port,
        "Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).some((row) => row.textContent.includes('UI Lifecycle Extension')) ? true : null",
        "wait for recovered local VSIX installation",
    )
    report["checks"]["vsixPermissionRetryRecovered"] = True
    report["states"]["nativeVsixChooser"] = chooser
    report["evidence"]["01-native-vsix-dialog"] = {
        "screenshot": chooser_png.name,
        "ocr": chooser_ocr.name,
    }
    report["checks"]["nativeVsixChooserReviewed"] = True

    click_target(args.control_port, xdotool, window, "button", "Restart Host", "restart extension host")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Extension host status\"]')?.textContent.includes('Running') ? true : null",
        "wait for restarted extension host",
    )
    report["checks"]["hostRestarted"] = True
    click_row_button(args.control_port, xdotool, window, "UI Lifecycle Extension", "Contributions", "load extension contributions")
    contributions = wait_snapshot(
        args.control_port,
        "(() => { const heading = Array.from(document.querySelectorAll('strong')).find((node) => node.textContent.trim() === 'Contributions'); return heading ? { text: heading.parentElement?.parentElement?.textContent?.replace(/\\s+/g, ' ').trim() || '' } : null; })()",
        "wait for extension contributions",
    )
    report["states"]["contributions"] = contributions
    report["checks"]["contributionsVisible"] = True
    crash_result = evaluate_webview(
        args.control_port,
        "(async () => { const crash = window.__wizpCrashExtensionHost; return crash ? await crash() : null; })()",
        "kill real extension host fixture",
    )
    report["states"]["hostCrash"] = crash_result
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Extension host status\"]')?.textContent.includes('unavailable') && Array.from(document.querySelectorAll('[aria-label=\"Extension host status\"] button')).some((button) => button.textContent.trim() === 'Retry') ? true : null",
        "wait for unavailable extension host",
    )
    report["checks"]["hostCrashUnavailable"] = True
    click_target(args.control_port, xdotool, window, "button", "Retry", "retry crashed extension host")
    wait_for_webview(
        args.control_port,
        "document.querySelector('[aria-label=\"Extension host status\"]')?.textContent.includes('Running') ? true : null",
        "wait for recovered extension host",
    )
    report["checks"]["hostCrashRetryRecovered"] = True
    click_row_button(args.control_port, xdotool, window, "UI Lifecycle Extension", "Contributions", "reload contributions after host crash")
    wait_for_webview(
        args.control_port,
        "Array.from(document.querySelectorAll('strong')).some((node) => node.textContent.trim() === 'Contributions') ? true : null",
        "wait for re-registered contributions",
    )


    uninstall_target = click_target(args.control_port, xdotool, window, "button", "Uninstall", "open extension uninstall dialog")
    dialog = wait_snapshot(
        args.control_port,
        "(() => { const node = document.querySelector('dialog.uninstall-dialog[open]'); return node ? { labelledBy: node.getAttribute('aria-labelledby'), describedBy: node.getAttribute('aria-describedby'), buttons: Array.from(node.querySelectorAll('button')).map((button) => button.textContent.trim()) } : null; })()",
        "wait for extension uninstall dialog",
    )
    key(xdotool, window, "Escape", "cancel extension uninstall")
    focus_restored = wait_for_webview(
        args.control_port,
        "document.activeElement?.textContent?.trim() === 'Uninstall' ? true : null",
        "wait for extension uninstall focus restoration",
    )
    report["states"]["uninstallDialog"] = dialog
    report["states"]["uninstallTarget"] = uninstall_target
    report["checks"]["uninstallCancelRestoredFocus"] = focus_restored is True
    click_target(args.control_port, xdotool, window, "button", "Uninstall", "reopen extension uninstall dialog")
    wait_for_webview(
        args.control_port,
        "document.querySelector('dialog.uninstall-dialog[open]') ? true : null",
        "wait for reopened extension uninstall dialog",
    )
    key(xdotool, window, "Tab", "focus uninstall confirmation")
    key(xdotool, window, "Return", "confirm extension uninstall")
    wait_for_webview(
        args.control_port,
        "!Array.from(document.querySelectorAll('[aria-label=\"Installed extensions\"] .hub-row')).some((row) => row.textContent.includes('Alpha Tools')) ? true : null",
        "wait for extension uninstall",
    )
    report["checks"]["extensionUninstalled"] = True


def start_x11_clipboard_owner(text: str) -> subprocess.Popen[str]:
    payload = base64.b64encode(text.encode("utf-8")).decode("ascii")
    script = r"""
import base64
import os
import tkinter

root = tkinter.Tk()
root.withdraw()
text = base64.b64decode(os.environ["WIZP_CLIPBOARD_B64"]).decode("utf-8")
root.clipboard_clear()
root.clipboard_append(text)
root.update()
print("WIZP_CLIPBOARD_READY", flush=True)
root.mainloop()
"""
    env = os.environ.copy()
    env["WIZP_CLIPBOARD_B64"] = payload
    owner = subprocess.Popen(
        [sys.executable, "-c", script],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    assert owner.stdout is not None
    ready = owner.stdout.readline().strip()
    if ready != "WIZP_CLIPBOARD_READY":
        stderr = owner.stderr.read() if owner.stderr is not None else ""
        owner.kill()
        owner.wait(timeout=5)
        raise SmokeFailure(f"native X11 clipboard owner failed: ready={ready!r}, stderr={stderr[-800:]!r}")
    return owner


def stop_clipboard_owner(owner: subprocess.Popen[str]) -> None:
    if owner.poll() is None:
        owner.terminate()
        try:
            owner.wait(timeout=3)
        except subprocess.TimeoutExpired:
            owner.kill()
            owner.wait(timeout=3)


def read_terminal_link_activations(control_port: int) -> list[dict[str, Any]]:
    url = f"http://127.0.0.1:{control_port}/__native-terminal-link"
    try:
        with urllib.request.urlopen(url, timeout=2.0) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        raise SmokeFailure(f"native terminal link telemetry failed: {exc}") from exc
    activations = payload.get("activations") if isinstance(payload, dict) else None
    if not isinstance(activations, list):
        raise SmokeFailure(f"native terminal link telemetry was malformed: {payload!r}")
    return [item for item in activations if isinstance(item, dict)]


def terminal_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        r"""
(() => {
  const roots = Array.from(document.querySelectorAll('[data-terminal-rendered-bytes]'));
  if (!roots.length) return null;
  const smoke = window.__getActiveTerminalSmoke?.() || {};
  return {
    terminals: roots.length,
    renderedBytes: roots.map((node) => Number(node.getAttribute('data-terminal-rendered-bytes') || 0)),
    statuses: roots.map((node) => node.getAttribute('data-terminal-status') || ''),
    serialized: smoke.serialized || '',
    findAlpha: smoke.findAlpha === true,
    decorations: Array.isArray(smoke.commandDecorations) ? smoke.commandDecorations.length : 0,
  };
})()
""",
        phase,
    )


def wait_terminal_text(control_port: int, marker: str, phase: str) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        f"(() => {{ const smoke = window.__getActiveTerminalSmoke?.() || {{}}; const text = smoke.serialized || ''; return text.includes({json.dumps(marker)}) ? {{ serialized: text, findAlpha: smoke.findAlpha === true, decorations: Array.isArray(smoke.commandDecorations) ? smoke.commandDecorations.length : 0 }} : null; }})()",
        phase,
    )


def run_terminal(
    args: argparse.Namespace,
    xdotool: str,
    window: dict[str, Any],
    _workspace: Path,
    report: dict[str, Any],
) -> None:
    key(xdotool, window, "ctrl+grave", "open Terminal panel")
    wait_for_webview(
        args.control_port,
        """(() => {
          const smoke = window.__getActiveTerminalSmoke?.() || {};
          return smoke.status === 'ready' && smoke.inputEnabled === true && Number.isInteger(smoke.sessionId)
            ? true
            : null;
        })()""",
        "wait for terminal input readiness",
    )
    initial = terminal_snapshot(args.control_port, "load Terminal")
    report["states"] = {"initial": initial}
    report["checks"]["terminalAccessible"] = True

    click_visible_selector(
        args.control_port,
        xdotool,
        window,
        "[data-terminal-status] .xterm-screen",
        "focus Terminal input",
    )
    type_text(xdotool, window, "printf 'alpha WIZP_NATIVE_TERMINAL_OK\\n'", "type terminal marker")
    key(xdotool, window, "Return", "run terminal marker")
    marker = wait_terminal_text(args.control_port, "WIZP_NATIVE_TERMINAL_OK", "wait for terminal marker")
    report["states"]["marker"] = marker
    report["checks"]["commandRendered"] = True
    report["checks"]["findWorked"] = marker.get("findAlpha") is True

    type_text(xdotool, window, "printf '\\033[32mANSI_OK\\033[0m unicode-ok\\n'", "type ANSI Unicode marker")
    key(xdotool, window, "Return", "run ANSI Unicode marker")
    ansi = wait_terminal_text(args.control_port, "ANSI_OK", "wait for ANSI Unicode marker")
    if "unicode-ok" not in ansi.get("serialized", ""):
        raise SmokeFailure(f"terminal Unicode marker was missing: {ansi!r}")
    report["states"]["ansiUnicode"] = ansi
    report["checks"]["ansiUnicodeRendered"] = True

    clipboard_text = (
        "printf '%s\\n' 'WIZP_CLIPBOARD_ALPHA λ漢字🙂'\n"
        "printf '%s\\n' 'WIZP_CLIPBOARD_BETA مرحبا'"
    )
    clipboard_owner = start_x11_clipboard_owner(clipboard_text)
    try:
        key(xdotool, window, "ctrl+shift+v", "paste native multiline Unicode clipboard")
        wait_snapshot(
            args.control_port,
            """(() => {
              const smoke = window.__getActiveTerminalSmoke?.() || {};
              return smoke.lastPaste?.source === 'native-clipboard' && !smoke.clipboardError
                ? { lastPaste: smoke.lastPaste }
                : null;
            })()""",
            "wait for native clipboard bridge",
        )
        key(xdotool, window, "Return", "submit native clipboard commands")
        clipboard_alpha = wait_terminal_text(
            args.control_port,
            "WIZP_CLIPBOARD_ALPHA λ漢字🙂",
            "wait for first native clipboard line",
        )
        clipboard_beta = wait_terminal_text(
            args.control_port,
            "WIZP_CLIPBOARD_BETA مرحبا",
            "wait for second native clipboard line",
        )
        clipboard_observation = evaluate_webview(
            args.control_port,
            """(() => {
              const smoke = window.__getActiveTerminalSmoke?.() || {};
              return { lastPaste: smoke.lastPaste || null, clipboardError: smoke.clipboardError || '' };
            })()""",
            "capture native clipboard observation",
        )
    finally:
        stop_clipboard_owner(clipboard_owner)
    clipboard_utf8 = clipboard_text.encode("utf-8")
    clipboard_state = {
        "selection": "CLIPBOARD",
        "owner": "Tk/X11",
        "ownerPid": clipboard_owner.pid,
        "shortcut": "Ctrl+Shift+V",
        "payloadSha256": hashlib.sha256(clipboard_utf8).hexdigest(),
        "payloadCharacters": len(clipboard_text),
        "payloadUtf8Bytes": len(clipboard_utf8),
        "payloadLines": len(clipboard_text.splitlines()),
        "firstLineVisible": "WIZP_CLIPBOARD_ALPHA λ漢字🙂" in clipboard_alpha.get("serialized", ""),
        "secondLineVisible": "WIZP_CLIPBOARD_BETA مرحبا" in clipboard_beta.get("serialized", ""),
        "rendererObservation": clipboard_observation,
        "xtermDataInjectedByHarness": False,
    }
    report["states"]["nativeClipboard"] = clipboard_state
    report["checks"]["nativeClipboardMultilinePasted"] = True

    local_link = f"http://127.0.0.1:{args.control_port}/__native-terminal-link?token=wizp-l2"
    type_text(
        xdotool,
        window,
        f"printf '\\033[2J\\033[H%s\\n' {local_link}",
        "type deterministic local terminal link",
    )
    key(xdotool, window, "Return", "render deterministic local terminal link")
    wait_terminal_text(args.control_port, local_link, "wait for local terminal link")
    link_target = wait_snapshot(
        args.control_port,
        """(() => {
          const target = window.__getActiveTerminalSmoke?.().linkTarget;
          return target?.uri?.includes('/__native-terminal-link') ? target : null;
        })()""",
        "locate terminal link pointer target",
    )
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Open Detected Terminal Link",
        "activate local terminal link by pointer",
    )
    pointer_deadline = time.monotonic() + 8.0
    link_activations: list[dict[str, Any]] = []
    while time.monotonic() < pointer_deadline:
        link_activations = read_terminal_link_activations(args.control_port)
        if any(item.get("source") == "pointer" for item in link_activations):
            break
        time.sleep(0.1)
    if not any(item.get("source") == "pointer" for item in link_activations):
        raise SmokeFailure(f"local terminal link pointer activation was not observed: {link_activations!r}")
    report["checks"]["localLinkPointerActivated"] = True

    activate_window(xdotool, window)
    click_visible_selector(
        args.control_port,
        xdotool,
        window,
        "[data-terminal-status] .xterm-screen",
        "refocus Terminal input",
    )
    key(xdotool, window, "ctrl+Return", "activate local terminal link by keyboard")
    keyboard_deadline = time.monotonic() + 8.0
    while time.monotonic() < keyboard_deadline:
        link_activations = read_terminal_link_activations(args.control_port)
        if any(item.get("source") == "keyboard" for item in link_activations):
            break
        time.sleep(0.1)
    sources = [str(item.get("source", "")) for item in link_activations]
    if "pointer" not in sources or "keyboard" not in sources:
        raise SmokeFailure(f"local terminal link activations were incomplete: {link_activations!r}")
    report["states"]["localLink"] = {
        "uri": local_link,
        "host": "127.0.0.1",
        "externalNetworking": False,
        "pointerTarget": link_target,
        "activationSources": sources,
        "activations": link_activations,
    }
    report["checks"]["localLinkKeyboardActivated"] = True

    click_target(args.control_port, xdotool, window, "button", "New Terminal", "create second terminal")
    deadline = time.monotonic() + 8.0
    telemetry: dict[str, Any] = {}
    while time.monotonic() < deadline:
        telemetry = read_native_terminal_telemetry(args.control_port)
        if telemetry.get("terminalCount", 0) >= 2:
            break
        time.sleep(0.1)
    if telemetry.get("terminalCount", 0) < 2:
        raise SmokeFailure(f"second terminal was not created: {telemetry!r}")
    report["checks"]["newTerminalCreated"] = True

    click_target(args.control_port, xdotool, window, "button", "Split Terminal Right", "split terminal")
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        telemetry = read_native_terminal_telemetry(args.control_port)
        if telemetry.get("terminalCount", 0) >= 3:
            break
        time.sleep(0.1)
    if telemetry.get("terminalCount", 0) < 3:
        raise SmokeFailure(f"split terminal was not created: {telemetry!r}")
    ready_deadline = time.monotonic() + 12.0
    while time.monotonic() < ready_deadline:
        telemetry = read_native_terminal_telemetry(args.control_port)
        terminals = telemetry.get("terminals", {})
        if len(terminals) >= 3 and all(
            terminal.get("status") == "ready" for terminal in terminals.values()
        ):
            break
        time.sleep(0.1)
    terminals = telemetry.get("terminals", {})
    if len(terminals) < 3 or not all(
        terminal.get("status") == "ready" for terminal in terminals.values()
    ):
        raise SmokeFailure(f"split terminals did not become ready: {telemetry!r}")
    report["states"]["splitTelemetry"] = telemetry
    report["checks"]["terminalSplit"] = True

    split_roots = terminal_snapshot(args.control_port, "capture terminal roots before spawn failure")
    rpc = RpcClient(args.port)
    terminals_before_failure = rpc.call("terminal/list")["terminals"]
    ids_before_failure = sorted(item["id"] for item in terminals_before_failure)
    evaluate_webview(
        args.control_port,
        "(() => { window.__wizpInjectTerminalSpawnFailure = true; return true; })()",
        "arm one-shot terminal spawn failure",
    )
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "New Terminal",
        "create terminal with injected spawn failure",
    )
    spawn_error = wait_snapshot(
        args.control_port,
        """(() => {
          const smoke = window.__getActiveTerminalSmoke?.() || {};
          const retry = document.querySelector('button[title="Retry Terminal Spawn"]');
          const retryAvailable = !!retry && !retry.disabled && retry.getClientRects().length > 0;
          return smoke.status === 'error' && smoke.inputEnabled === false && retryAvailable
            ? {
                status: smoke.status,
                inputEnabled: smoke.inputEnabled,
                sessionId: smoke.sessionId,
                error: smoke.spawnError,
                retryAvailable,
              }
            : null;
        })()""",
        "wait for actionable terminal spawn error",
    )
    terminals_after_failure = rpc.call("terminal/list")["terminals"]
    ids_after_failure = sorted(item["id"] for item in terminals_after_failure)
    if ids_after_failure != ids_before_failure:
        raise SmokeFailure(
            f"terminal spawn failure disturbed existing sessions: {ids_before_failure} -> {ids_after_failure}"
        )
    failure_error = spawn_error.get("error") or {}
    if failure_error.get("code") != -32010:
        raise SmokeFailure(f"terminal spawn UI did not retain its RPC error code: {spawn_error!r}")
    report["checks"]["spawnFailureIsolated"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Retry Terminal Spawn",
        "retry failed terminal spawn",
    )
    spawn_retry = wait_snapshot(
        args.control_port,
        """(() => {
          const smoke = window.__getActiveTerminalSmoke?.() || {};
          return smoke.status === 'ready' && smoke.inputEnabled === true && Number.isInteger(smoke.sessionId)
            ? { status: smoke.status, inputEnabled: smoke.inputEnabled, sessionId: smoke.sessionId }
            : null;
        })()""",
        "wait for terminal spawn Retry recovery",
    )
    retry_deadline = time.monotonic() + 8.0
    ids_after_retry: list[int] = []
    while time.monotonic() < retry_deadline:
        ids_after_retry = sorted(item["id"] for item in rpc.call("terminal/list")["terminals"])
        if spawn_retry["sessionId"] in ids_after_retry and len(ids_after_retry) == len(ids_before_failure) + 1:
            break
        time.sleep(0.1)
    if spawn_retry["sessionId"] not in ids_after_retry or len(ids_after_retry) != len(ids_before_failure) + 1:
        raise SmokeFailure(f"terminal spawn Retry did not create exactly one session: {ids_after_retry!r}")
    report["states"]["spawnFailure"] = {
        "code": failure_error["code"],
        "message": failure_error["message"],
        "sessionIdsBefore": ids_before_failure,
        "sessionIdsAfter": ids_after_failure,
        "frontend": spawn_error,
        "retry": {**spawn_retry, "activeBackendIds": ids_after_retry},
    }
    report["checks"]["spawnFailureRetryRecovered"] = True

    click_visible_selector(
        args.control_port,
        xdotool,
        window,
        "[data-terminal-status] .xterm-screen",
        "focus split terminal",
    )
    rerun_probe = Path("/tmp") / f"wizp-l1-rerun-{os.getpid()}.log"
    rerun_probe.unlink(missing_ok=True)
    type_text(
        xdotool,
        window,
        f"echo WIZP_RERUN_OK >> {rerun_probe}; cat {rerun_probe}",
        "type rerun marker",
    )
    key(xdotool, window, "Return", "run rerun marker")
    before_rerun = wait_terminal_text(
        args.control_port,
        "WIZP_RERUN_OK",
        "wait for rerun marker",
    )
    occurrences_before = before_rerun["serialized"].count("WIZP_RERUN_OK")
    rerun_baseline = evaluate_webview(
        args.control_port,
        "window.__getActiveTerminalSmoke?.() || null",
        "capture rerun baseline",
    )
    if not isinstance(rerun_baseline, dict):
        raise SmokeFailure(f"terminal rerun baseline was unavailable: {rerun_baseline!r}")
    rendered_bytes_before = int(rerun_baseline.get("renderedBytes", 0))
    data_reads_before = int(rerun_baseline.get("dataReadCount", 0))
    if not rerun_probe.is_file() or rerun_probe.read_text(encoding="utf-8").splitlines() != [
        "WIZP_RERUN_OK"
    ]:
        raise SmokeFailure("initial rerun fixture command did not create exactly one marker line")
    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Rerun Last Command",
        "rerun terminal command",
    )
    rerun_deadline = time.monotonic() + 10.0
    rerun: dict[str, Any] = {}
    while time.monotonic() < rerun_deadline:
        value = evaluate_webview(
            args.control_port,
            """(() => {
              const smoke = window.__getActiveTerminalSmoke?.() || {};
              const text = smoke.serialized || '';
              return {
                occurrencesAfter: text.split('WIZP_RERUN_OK').length - 1,
                serializedTail: text.slice(-500),
                lastCommand: smoke.lastCommand || '',
                lastRerunResult: smoke.lastRerunResult || 'missing',
                sessionId: smoke.sessionId,
                status: smoke.status,
                inputEnabled: smoke.inputEnabled,
                renderedBytes: smoke.renderedBytes || 0,
                dataReadCount: smoke.dataReadCount || 0,
              };
            })()""",
            "inspect rerun output",
        )
        rerun = value if isinstance(value, dict) else {}
        rerun_lines = (
            rerun_probe.read_text(encoding="utf-8", errors="replace").splitlines()
            if rerun_probe.is_file()
            else []
        )
        rerun["probeLines"] = rerun_lines
        if (
            rerun.get("lastRerunResult") == "written"
            and rerun.get("renderedBytes", 0) > rendered_bytes_before
            and rerun.get("dataReadCount", 0) > data_reads_before
            and rerun_lines == ["WIZP_RERUN_OK", "WIZP_RERUN_OK"]
        ):
            break
        time.sleep(0.1)
    if (
        rerun.get("renderedBytes", 0) <= rendered_bytes_before
        or rerun.get("dataReadCount", 0) <= data_reads_before
        or rerun.get("probeLines") != ["WIZP_RERUN_OK", "WIZP_RERUN_OK"]
    ):
        rerun_probe.unlink(missing_ok=True)
        raise SmokeFailure(
            "rerun did not produce new terminal output: "
            f"before={occurrences_before}, last={rerun!r}"
        )
    rerun_probe.unlink(missing_ok=True)
    rerun["occurrencesBefore"] = occurrences_before
    rerun["renderedBytesBefore"] = rendered_bytes_before
    rerun["dataReadCountBefore"] = data_reads_before
    report["states"]["rerun"] = rerun
    report["checks"]["rerunWorked"] = True

    pressure_probe = Path("/tmp") / f"wizp-l2-pressure-{os.getpid()}.done"
    pressure_probe.unlink(missing_ok=True)
    pressure_ready = pressure_probe.with_suffix(".ready")
    pressure_gate = pressure_probe.with_suffix(".start")
    pressure_ready.unlink(missing_ok=True)
    pressure_gate.unlink(missing_ok=True)
    pressure_baseline = evaluate_webview(
        args.control_port,
        "window.__getActiveTerminalSmoke?.() || null",
        "capture packaged pressure baseline",
    )
    if not isinstance(pressure_baseline, dict):
        raise SmokeFailure(f"terminal pressure baseline was unavailable: {pressure_baseline!r}")
    # One pre-pause read may still drain up to 16 MiB. Exceed that read plus
    # the 16 MiB output queue so an in-flight response cannot avoid overflow.
    pressure_command_bytes = 40_000_000
    type_text(
        xdotool,
        window,
        (
            f"printf ready > {pressure_ready}; "
            f"while [ ! -e {pressure_gate} ]; do sleep 0.01; done; "
            f"head -c {pressure_command_bytes} /dev/zero | tr '\\000' P; "
            f"printf WIZP_PRESSURE_DONE > {pressure_probe}; "
            "printf '\\nWIZP_PRESSURE_DONE\\n'"
        ),
        "type sustained terminal pressure command",
    )
    key(xdotool, window, "Return", "run sustained terminal pressure command")
    # Hold the real consumer, not its transport: overflow must not depend on
    # whether this machine renders output faster than the shell produces it.
    ready_deadline = time.monotonic() + 10.0
    while not pressure_ready.is_file() and time.monotonic() < ready_deadline:
        time.sleep(0.01)
    if not pressure_ready.is_file():
        raise SmokeFailure("terminal pressure producer did not reach its start gate")
    renderers = [
        item for item in sample_process_tree(report["launcherPid"], None)["processes"]
        if "--type=renderer" in item["command"].split()
    ]
    if not renderers:
        raise SmokeFailure("no owned terminal renderer was found for pressure testing")
    with ExitStack() as cleanup:
        cleanup.callback(pressure_gate.unlink, missing_ok=True)
        cleanup.callback(pressure_ready.unlink, missing_ok=True)
        for renderer in renderers:
            renderer_fd = os.pidfd_open(renderer["pid"])
            cleanup.callback(os.close, renderer_fd)
            current = proc_stat(renderer["pid"])
            if current is None or current["startTimeTicks"] != renderer["startTimeTicks"]:
                raise SmokeFailure("terminal renderer identity changed before pressure pause")
            signal.pidfd_send_signal(renderer_fd, signal.SIGSTOP)
            cleanup.callback(signal.pidfd_send_signal, renderer_fd, signal.SIGCONT)
            pause_deadline = time.monotonic() + 5.0
            while time.monotonic() < pause_deadline:
                if (proc_stat(renderer["pid"]) or {}).get("state") == "T":
                    break
                time.sleep(0.01)
            else:
                raise SmokeFailure("owned terminal renderer did not stop")
        pressure_gate.touch()
        producer_deadline = time.monotonic() + 20.0
        while not pressure_probe.is_file() and time.monotonic() < producer_deadline:
            time.sleep(0.01)
        if not pressure_probe.is_file():
            raise SmokeFailure("terminal pressure producer did not finish with its renderer paused")
    wait_terminal_text(
        args.control_port,
        "WIZP_PRESSURE_DONE",
        "wait for sustained terminal pressure completion",
    )
    pressure_deadline = time.monotonic() + 20.0
    pressure: dict[str, Any] = {}
    while time.monotonic() < pressure_deadline:
        value = evaluate_webview(
            args.control_port,
            """(() => {
              const smoke = window.__getActiveTerminalSmoke?.() || {};
              return {
                status: smoke.status,
                sessionId: smoke.sessionId,
                droppedBytes: smoke.droppedBytes || 0,
                renderedBytes: smoke.renderedBytes || 0,
                dataReadCount: smoke.dataReadCount || 0,
              };
            })()""",
            "inspect packaged terminal pressure",
        )
        pressure = value if isinstance(value, dict) else {}
        if (
            pressure_probe.is_file()
            and pressure.get("status") == "ready"
            and pressure.get("droppedBytes", 0) > pressure_baseline.get("droppedBytes", 0)
            and pressure.get("renderedBytes", 0) > pressure_baseline.get("renderedBytes", 0)
            and pressure.get("dataReadCount", 0) > pressure_baseline.get("dataReadCount", 0)
            and (
                pressure.get("renderedBytes", 0) - pressure_baseline.get("renderedBytes", 0)
                + pressure.get("droppedBytes", 0) - pressure_baseline.get("droppedBytes", 0)
            ) >= pressure_command_bytes
        ):
            break
        time.sleep(0.1)
    else:
        pressure_probe.unlink(missing_ok=True)
        raise SmokeFailure(
            f"packaged terminal pressure did not finish rendering with bounded dropping: {pressure!r}, "
            f"baseline={pressure_baseline!r}"
        )
    pressure_probe.unlink(missing_ok=True)
    pressure.update(
        {
            "commandBytes": pressure_command_bytes,
            "outputQueueCapacityBytes": 16 * 1024 * 1024,
            "droppedBytesBefore": int(pressure_baseline.get("droppedBytes", 0)),
            "renderedBytesBefore": int(pressure_baseline.get("renderedBytes", 0)),
            "dataReadCountBefore": int(pressure_baseline.get("dataReadCount", 0)),
            "completionProbe": True,
            "rendererPauseVerified": True,
        }
    )
    report["states"]["backpressure"] = pressure
    report["checks"]["sustainedBackpressureBounded"] = True

    backend_session_id = rerun.get("sessionId")
    if not isinstance(backend_session_id, int):
        raise SmokeFailure(f"active terminal did not expose its backend session id: {rerun!r}")
    click_visible_selector(
        args.control_port,
        xdotool,
        window,
        "[data-terminal-status] .xterm-screen",
        "focus terminal before normal exit",
    )
    type_text(xdotool, window, "exit 7", "type normal terminal exit")
    key(xdotool, window, "Return", "exit terminal with code 7")
    exited = wait_snapshot(
        args.control_port,
        """(() => {
          const smoke = window.__getActiveTerminalSmoke?.() || {};
          const text = smoke.serialized || '';
          return smoke.status === 'exited' && smoke.inputEnabled === false &&
            text.includes('[Process exited: code 7]')
            ? {
                status: smoke.status,
                inputEnabled: smoke.inputEnabled,
                serializedTail: text.slice(-400),
                sessionId: smoke.sessionId,
              }
            : null;
        })()""",
        "wait for retained terminal exit",
    )
    exit_deadline = time.monotonic() + 8.0
    backend_exit: dict[str, Any] | None = None
    while time.monotonic() < exit_deadline:
        entries = rpc.call("terminal/list")["terminals"]
        backend_exit = next(
            (item for item in entries if item.get("id") == backend_session_id),
            None,
        )
        if (
            backend_exit
            and backend_exit.get("exitKind") == "exited"
            and backend_exit.get("exitCode") == 7
            and backend_exit.get("reaped") is True
        ):
            break
        time.sleep(0.1)
    if not backend_exit or backend_exit.get("reaped") is not True:
        raise SmokeFailure(f"terminal exit was not retained/reaped: {backend_exit!r}")
    report["states"]["normalExit"] = {"frontend": exited, "backend": backend_exit}
    report["checks"]["normalExitRetained"] = True

    click_target(
        args.control_port,
        xdotool,
        window,
        "button",
        "Relaunch Terminal",
        "relaunch exited terminal",
    )
    relaunched = wait_snapshot(
        args.control_port,
        f"""(() => {{
          const smoke = window.__getActiveTerminalSmoke?.() || {{}};
          return Number.isInteger(smoke.sessionId) && smoke.sessionId !== {backend_session_id} &&
            smoke.status === 'ready' && smoke.inputEnabled === true
            ? {{
                previousSessionId: {backend_session_id},
                sessionId: smoke.sessionId,
                status: smoke.status,
                inputEnabled: smoke.inputEnabled,
              }}
            : null;
        }})()""",
        "wait for relaunched terminal",
    )
    relaunch_deadline = time.monotonic() + 8.0
    relaunch_ids: list[int] = []
    while time.monotonic() < relaunch_deadline:
        relaunch_ids = sorted(item["id"] for item in rpc.call("terminal/list")["terminals"])
        if backend_session_id not in relaunch_ids and relaunched["sessionId"] in relaunch_ids:
            break
        time.sleep(0.1)
    if backend_session_id in relaunch_ids or relaunched["sessionId"] not in relaunch_ids:
        raise SmokeFailure(f"terminal relaunch left stale backend state: {relaunch_ids}")
    report["states"]["relaunch"] = {**relaunched, "activeBackendIds": relaunch_ids}
    report["checks"]["terminalRelaunched"] = True

    click_target(args.control_port, xdotool, window, "button", "Kill Terminal", "kill active terminal")
    deadline = time.monotonic() + 8.0
    killed: dict[str, Any] = {}
    while time.monotonic() < deadline:
        killed = terminal_snapshot(args.control_port, "wait for killed terminal")
        if killed.get("terminals", 99) <= split_roots.get("terminals", 0):
            break
        time.sleep(0.1)
    if killed.get("terminals", 99) > split_roots.get("terminals", 0):
        raise SmokeFailure(f"terminal kill did not remove the active session: {killed!r}")
    report["states"]["afterKill"] = killed
    report["checks"]["terminalKilled"] = True
    report["checks"]["sessionsCleanedUp"] = True


def prepare_local_link_opener(profile_dir: Path, control_port: int) -> None:
    """Register a browser fixture only in the disposable test profile."""
    require_tool("xdg-open")
    require_tool("xdg-mime")
    opener = profile_dir / "open-local-link.py"
    write_text(
        opener,
        "import sys\n"
        "from http.client import HTTPConnection\n"
        "from urllib.parse import urlsplit\n"
        "url = urlsplit(sys.argv[1])\n"
        f"if (url.scheme, url.hostname, url.port, url.path) != "
        f"('http', '127.0.0.1', {control_port}, '/__native-terminal-link'):\n"
        "    raise SystemExit('refusing non-fixture browser destination')\n"
        f"connection = HTTPConnection('127.0.0.1', {control_port}, timeout=5)\n"
        "connection.request('GET', url.path + '?' + url.query)\n"
        "response = connection.getresponse()\n"
        "response.read()\n"
        "connection.close()\n"
        "raise SystemExit(0 if response.status == 200 else 1)\n",
    )
    applications = profile_dir / "data" / "applications"
    applications.mkdir()
    write_text(
        applications / "wizp-native-local-link.desktop",
        "[Desktop Entry]\nType=Application\nName=WIZP local browser fixture\n"
        f"Exec=python3 {opener} %u\n"
        "MimeType=x-scheme-handler/http;\nNoDisplay=true\n",
    )
    write_text(
        profile_dir / "config" / "mimeapps.list",
        "[Default Applications]\nx-scheme-handler/http=wizp-native-local-link.desktop\n",
    )


def native_recovery_request(port: int, token: str, route: str, action: str | None = None) -> Any:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{route}",
        data=json.dumps({"action": action}).encode() if action is not None else None,
        headers={"Content-Type": "application/json", "X-WIZP-Control-Token": token},
        method="POST" if action is not None else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read())
    except (OSError, ValueError) as exc:
        raise SmokeFailure(f"native recovery {route} failed: {exc}") from exc


def recovery_editor_state(control_port: int) -> dict[str, Any]:
    return wait_snapshot(
        control_port,
        """(() => {
          const group = window.__getGroup?.(window.__getActiveGroupId?.());
          const editor = window.__getActiveEditor?.();
          if (!group || !editor) return null;
          return {
            editors: group.editors.map(e => ({
              uri: e.uri, content: e.content || '', dirty: Boolean(e.dirty),
            })),
            activeUri: group.editors.find(e => e.id === group.activeEditorId)?.uri,
            activeContent: editor.getValue(),
            terminalLayout: window.__getTerminalLayout?.() || null,
          };
        })()""",
        "observe live recovery editor and terminal ownership",
    )


def recovery_editor_projection(snapshot: dict[str, Any]) -> dict[str, Any]:
    session = snapshot.get("editorSession") or {}
    return json.loads(json.dumps({key: session.get(key) for key in ("layout", "activeGroup", "groups")}))


def recovery_processes_gone(processes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    remaining = []
    for old in processes:
        current = proc_stat(old["pid"])
        if current and current["startTimeTicks"] == old["startTimeTicks"] and current["state"] != "Z":
            remaining.append(current)
    return remaining


def wait_recovery_processes_gone(processes: list[dict[str, Any]]) -> None:
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not recovery_processes_gone(processes):
            return
        time.sleep(0.1)
    raise SmokeFailure(f"obsolete owned processes remained: {recovery_processes_gone(processes)!r}")


def recovery_watchers(processes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Retain kernel watch registrations, not inferred component counts."""
    observed = []
    for process in processes:
        if process.get("state") == "Z":
            continue
        pid = process["pid"]
        descriptors = []
        try:
            for descriptor in Path(f"/proc/{pid}/fdinfo").iterdir():
                try:
                    rows = [
                        line for line in descriptor.read_text().splitlines()
                        if line.startswith("inotify ")
                    ]
                except FileNotFoundError:
                    continue
                if rows:
                    descriptors.append({"fd": int(descriptor.name), "watches": rows})
        except FileNotFoundError:
            if proc_stat(pid) is not None:
                raise
            continue
        observed.append({
            "pid": pid, "startTimeTicks": process["startTimeTicks"], "descriptors": descriptors,
        })
    return observed


def recovery_resources(args: argparse.Namespace, report: dict[str, Any]) -> dict[str, Any]:
    # The same steady-state window is used before and after each independent fault.
    time.sleep(2)
    samples = []
    metrics = []
    previous = None
    for index in range(4):
        if index:
            time.sleep(1)
        sample = sample_process_tree(report["launcherPid"], previous)
        sample["phase"] = "steady-recovery"
        samples.append(sample)
        metrics.append({"monotonicSeconds": time.monotonic(), "metrics": read_metrics(args.port)})
        previous = sample
    elapsed = metrics[-1]["monotonicSeconds"] - metrics[0]["monotonicSeconds"]
    reads = metrics[-1]["metrics"]["terminalReadRequests"] - metrics[0]["metrics"]["terminalReadRequests"]
    requests = metrics[-1]["metrics"]["rpcRequests"] - metrics[0]["metrics"]["rpcRequests"]
    return {
        "samples": samples,
        "metrics": metrics,
        "processSummary": summarize_processes(samples, report["launcherPid"]),
        "terminalReadsPerSecond": reads / elapsed,
        "rpcRequestsPerSecond": requests / elapsed,
        "watchers": recovery_watchers(samples[-1]["processes"]),
        "terminalTelemetry": read_native_terminal_telemetry(args.control_port),
        "clockTicksPerSecond": os.sysconf("SC_CLK_TCK"),
    }


def run_recovery(
    args: argparse.Namespace,
    xdotool: str,
    window: dict[str, Any],
    workspace: Path,
    report: dict[str, Any],
) -> None:
    rpc = RpcClient(args.port)
    token = evaluate_webview(
        args.control_port,
        "new URL(location.href).searchParams.get('wizpControlToken')",
        "read native control credential",
    )
    if not isinstance(token, str) or not token:
        raise SmokeFailure("packaged renderer did not receive native control credentials")
    control = lambda route, action=None: native_recovery_request(args.control_port, token, route, action)
    source = workspace / "recovery.txt"
    disk_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    output = Path(report["outputDir"])
    import_tool = require_tool("import")
    tesseract = require_tool("tesseract")
    language = select_tesseract_language(tesseract)
    recovery: dict[str, Any] = {
        "workspace": str(workspace), "source": str(source),
        "diskSha256": disk_hash, "cycles": [], "input": "native XTEST",
        "budgets": {
            "cyclesPerFault": 3, "steadyRssGrowthBytes": 64 * 1024 * 1024,
            "steadyCpuMs": 15_000, "mainCpuPercent": 5,
            "terminalReadsPerSecondPerSession": 10,
        },
    }
    report["recovery"] = recovery

    def capture(label: str, marker: str) -> None:
        png = output / f"{report['runId']}-{label}.png"
        ocr = output / f"{report['runId']}-{label}.txt"
        text = capture_state(import_tool, tesseract, language, window, png, ocr, png.with_suffix(".stderr.log"))
        report["evidence"][label] = {"screenshot": png.name, "ocr": ocr.name, "marker": marker}
        if not ocr_contains_marker(text, marker):
            raise SmokeFailure(f"{label} screenshot OCR did not expose {marker!r}")

    def await_snapshot(expected: dict[str, Any] | None = None) -> dict[str, Any]:
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            last = control("/__native-session")
            if isinstance(last, dict):
                projection = recovery_editor_projection(last)
                if expected is not None and projection == expected:
                    return last
                if expected is None:
                    groups = projection.get("groups") or []
                    editors = [editor for group in groups for editor in group.get("editors", [])]
                    if (
                        len(editors) == 2
                        and {e.get("content") for e in editors} == {"WIZP_RECOVERY_DIRTY", "WIZP_RECOVERY_UNTITLED"}
                        and all(e.get("dirty") is True for e in editors)
                        and [folder.get("path") for folder in last.get("folders", [])] == [str(workspace)]
                        and (last.get("editorSession") or {}).get("terminalLayout")
                    ):
                        return last
            time.sleep(0.1)
        raise SmokeFailure(f"native host did not acknowledge exact recovery payload: {last!r}")

    def ready() -> dict[str, Any]:
        deadline = time.monotonic() + 25
        status = None
        while time.monotonic() < deadline:
            status = control("/__native-backend")
            if isinstance(status, dict) and status.get("state") == "ready":
                return status
            time.sleep(0.2)
        raise SmokeFailure(f"native backend did not recover: {status!r}")

    def terminals() -> dict[str, Any]:
        frontend = wait_snapshot(
            args.control_port,
            """(() => {
              const s = window.__getActiveTerminalSmoke?.();
              const layout = window.__getTerminalLayout?.();
              return s?.status === 'ready' && s.inputEnabled && layout
                ? {sessionId: s.sessionId, status: s.status, inputEnabled: s.inputEnabled, layout}
                : null;
            })()""",
            "wait for one recovered terminal",
        )
        backend = rpc.call("terminal/list")
        tree = sample_process_tree(report["launcherPid"], None)
        entries = backend.get("terminals", [])
        if len(entries) != 1 or entries[0].get("id") != frontend.get("sessionId"):
            raise SmokeFailure(f"terminal ownership is not exactly one: {frontend!r}, {backend!r}")
        owner = next((p for p in tree["processes"] if p["pid"] == entries[0].get("pid") and p.get("descendant")), None)
        if not owner or owner.get("state") == "Z":
            raise SmokeFailure(f"terminal is not a live owned descendant: {entries!r}")
        return {"frontend": frontend, "backend": backend, "process": owner}

    def routes() -> dict[str, Any]:
        folders = rpc.call("workspace/getFolders")
        files = rpc.call("file/list", {"path": str(workspace)})
        search = rpc.call("search/text", {"query": "WIZP_RECOVERY_DISK"})
        config = rpc.call("config/get", {"key": "editor.fontSize", "scope": "user"})
        if not any(folder.get("path") == str(workspace) for folder in folders.get("folders", [])):
            raise SmokeFailure(f"workspace was not restored: {folders!r}")
        if not any(match.get("file") == str(source) or match.get("uri") == source.as_uri() for match in search.get("matches", [])):
            raise SmokeFailure(f"recovered Search lost fixture: {search!r}")
        key(xdotool, window, "ctrl+shift+e", "show recovered Explorer")
        explorer = wait_snapshot(
            args.control_port,
            """(() => {
              const tree = document.querySelector('[role="tree"]');
              const error = document.querySelector('.explorer-error');
              return tree?.textContent.includes('recovery.txt') && !error
                ? {text: tree.textContent, error: false} : null;
            })()""", "observe recovered Explorer",
        )
        key(xdotool, window, "ctrl+shift+f", "show recovered Search")
        fill_target(args.control_port, xdotool, window, "input", "Search files", "WIZP_RECOVERY_DISK", "search recovered workspace", submit=True)
        search_ui = wait_snapshot(
            args.control_port,
            """(() => {
              const result = document.querySelector('.search-result-text');
              return result?.textContent.includes('WIZP_RECOVERY_DISK')
                ? {text: result.textContent, summary: document.querySelector('.search-summary')?.textContent}
                : null;
            })()""", "observe recovered Search result",
        )
        key(xdotool, window, "ctrl+comma", "open recovered Settings")
        settings = wait_snapshot(
            args.control_port,
            """(() => {
              const input = document.getElementById('settings-fontsize');
              return input && !input.disabled ? {fontSize: input.value, visible: true} : null;
            })()""", "observe recovered Settings",
        )
        key(xdotool, window, "Escape", "close recovered Settings")
        return {"workspace/getFolders": folders, "file/list": files, "search/text": search,
                "config/get": config, "explorer": explorer, "search": search_ui, "settings": settings}

    # All mutations of editor/terminal state below go through native keyboard/mouse input.
    wait_for_webview(
        args.control_port,
        "Boolean(window.__openFile)",
        "wait for recovery editor open hook",
    )
    open_result = evaluate_webview(
        args.control_port,
        f"""(async () => {{
          await window.__openFile({json.dumps(str(source))});
          const groupId = window.__getActiveGroupId?.();
          const group = window.__getGroup?.(groupId);
          return {{groupId, editors: group?.editors?.map((editor) => editor.uri) || []}};
        }})()""",
        "open recovery fixture through visible editor action",
    )
    if not isinstance(open_result, dict) or json.dumps(source.as_uri()) not in json.dumps(open_result.get("editors", [])):
        raise SmokeFailure(f"recovery editor open returned unexpected state: {open_result!r}")
    wait_for_webview(
        args.control_port,
        f"Boolean(window.__getGroup?.(window.__getActiveGroupId?.())?.editors?.some((editor) => editor.uri === {json.dumps(source.as_uri())}))",
        "wait for recovery file",
    )
    try:
        wait_for_webview(
            args.control_port,
            "Boolean(document.querySelector('.monaco-editor .view-lines'))",
            "wait for recovery Monaco editor",
            timeout=30.0,
        )
    except SmokeFailure as error:
        diagnostic = evaluate_webview(
            args.control_port,
            """(() => ({
              loader: window.__wizpMonacoSmokeState || null,
              editorPanes: document.querySelectorAll('.editor-pane').length,
              editorContainers: document.querySelectorAll('.editor-container').length,
              tabs: document.querySelectorAll('[role="tab"]').length,
              welcome: Boolean(document.querySelector('.welcome-screen')),
            }))()""",
            "capture Monaco loader state",
        )
        raise SmokeFailure(f"{error}; loader={diagnostic!r}") from error

    click_visible_selector(args.control_port, xdotool, window, ".monaco-editor .view-lines", "focus recovery editor")
    key(xdotool, window, "ctrl+a", "select fixture content")
    type_text(xdotool, window, "WIZP_RECOVERY_DIRTY", "type unsaved file content")
    key(xdotool, window, "ctrl+n", "create recovery untitled editor")
    wait_for_webview(args.control_port, "window.__getActiveEditor?.()?.getModel?.()?.uri?.toString().startsWith('untitled-')", "wait for untitled editor")
    click_visible_selector(args.control_port, xdotool, window, ".monaco-editor .view-lines", "focus untitled editor")
    type_text(xdotool, window, "WIZP_RECOVERY_UNTITLED", "type untitled content")
    # The native-smoke launch already requests one terminal; do not toggle it closed.
    initial_terminals = terminals()
    click_visible_selector(args.control_port, xdotool, window, "[data-terminal-status] .xterm-screen", "focus recovery terminal")
    type_text(xdotool, window, "printf 'WIZP_RECOVERY_PTY\\n'", "type terminal ownership probe")
    key(xdotool, window, "Return", "run terminal ownership probe")
    wait_terminal_text(args.control_port, "WIZP_RECOVERY_PTY", "observe real PTY output")
    recovery["initialRoutes"] = routes()
    initial_live = recovery_editor_state(args.control_port)
    initial_snapshot = await_snapshot()
    expected = recovery_editor_projection(initial_snapshot)
    recovery.update({
        "initialLive": initial_live, "initialSnapshot": initial_snapshot,
        "initialTerminals": initial_terminals, "initialBackend": ready(),
        "baselineResources": recovery_resources(args, report),
    })
    capture("recovery-initial", "WIZP_RECOVERY_UNTITLED")
    report["checks"]["nativeKeyboardEdits"] = True

    for kind in ("backend", "renderer"):
        for number in range(1, 4):
            label = f"recovery-{kind}-{number}"
            cycle: dict[str, Any] = {"kind": kind, "cycle": number, "startedAt": utc_now()}
            recovery["cycles"].append(cycle)
            cycle["beforeBackend"] = ready()
            cycle["beforeSnapshot"] = await_snapshot(expected)
            cycle["beforeLive"] = recovery_editor_state(args.control_port)
            cycle["beforeTerminals"] = terminals()
            before_tree = sample_process_tree(report["launcherPid"], None)
            cycle["beforeProcesses"] = before_tree
            if kind == "backend":
                backend_pid = cycle["beforeBackend"]["backendPid"]
                obsolete = sample_process_tree(backend_pid, None)["processes"]
                # sample_process_tree also includes the launch group; restrict to this backend subtree.
                obsolete = [p for p in obsolete if p.get("descendant")]
                cycle["obsoleteProcesses"] = obsolete
                cycle["faultResponse"] = control("/__native-recovery", "disconnect")
                wait_recovery_processes_gone(obsolete)
                cycle["disconnectedUi"] = wait_snapshot(
                    args.control_port,
                    """(() => {
                      const banner = document.querySelector('.daemon-recovery-banner');
                      const retry = banner?.querySelector('button');
                      return retry?.textContent.trim() === 'Retry' && !retry.disabled
                        ? {text: banner.textContent, role: banner.getAttribute('role'), retry: 'Retry'} : null;
                    })()""", "wait for held backend Retry",
                )
                capture(f"{label}-held", "Retry")
                cycle["heldSamples"] = []
                for _ in range(4):
                    cycle["heldSamples"].append({
                        "monotonicSeconds": time.monotonic(),
                        "backend": control("/__native-backend"),
                        "processes": sample_process_tree(report["launcherPid"], None),
                        "terminalTelemetry": read_native_terminal_telemetry(args.control_port),
                    })
                    time.sleep(3)
                # A second real edit while disconnected must persist independently of Zig.
                click_visible_selector(args.control_port, xdotool, window, ".monaco-editor .view-lines", "focus disconnected editor")
                key(xdotool, window, "ctrl+End", "append disconnected edit")
                suffix = f" HELD{number}"
                type_text(xdotool, window, suffix, "type during held backend disconnect")
                for group in expected["groups"]:
                    for editor in group["editors"]:
                        if editor["uri"] == initial_live["activeUri"]:
                            editor["content"] += suffix
                cycle["heldSnapshot"] = await_snapshot(expected)
                cycle["heldLive"] = recovery_editor_state(args.control_port)
                cycle["retryAction"] = click_target(
                    args.control_port, xdotool, window, ".daemon-recovery-banner button",
                    "Retry", "retry held backend with native pointer",
                )
            else:
                obsolete = [
                    p for p in before_tree["processes"]
                    if p.get("descendant") and "--type=renderer" in p["command"].split()
                ]
                if not obsolete:
                    raise SmokeFailure("no owned CEF renderer found for replacement")
                cycle["obsoleteProcesses"] = obsolete
                with ExitStack() as cleanup:
                    for renderer in obsolete:
                        fd = os.pidfd_open(renderer["pid"])
                        cleanup.callback(os.close, fd)
                        current = proc_stat(renderer["pid"])
                        owned = sample_process_tree(report["launcherPid"], None)["processes"]
                        if (
                            current is None or current["startTimeTicks"] != renderer["startTimeTicks"]
                            or "--type=renderer" not in current["command"].split()
                            or not any(p["pid"] == renderer["pid"] and p.get("descendant") for p in owned)
                        ):
                            raise SmokeFailure("owned CEF renderer identity changed before replacement")
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                wait_recovery_processes_gone(obsolete)
                cycle["faultResponse"] = control("/__native-recovery", "reload-renderer")
            cycle["afterBackend"] = ready()
            cycle["afterTerminals"] = terminals()
            cycle["afterLive"] = recovery_editor_state(args.control_port)
            cycle["afterSnapshot"] = await_snapshot(expected)
            cycle["routes"] = routes()
            cycle["afterProcesses"] = sample_process_tree(report["launcherPid"], None)
            cycle["remainingObsolete"] = recovery_processes_gone(obsolete)
            cycle["diskSha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            cycle["resources"] = recovery_resources(args, report)
            cycle["finishedAt"] = utc_now()
            capture(f"{label}-restored", "WIZP_RECOVERY_UNTITLED")
            # The report validator derives every cycle invariant from retained observations.
            # Do not continue fault injection after a broken recovery.
            from scripts.check_native_primary_journey_report import validate_recovery_cycle
            failures: list[str] = []
            validate_recovery_cycle(recovery, cycle, failures)
            if failures:
                raise SmokeFailure("; ".join(failures))

    click_target(args.control_port, xdotool, window, "button", "Kill Terminal", "close recovery terminal")
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        recovery["terminalCleanup"] = rpc.call("terminal/list")
        if recovery["terminalCleanup"].get("terminals") == []:
            break
        time.sleep(0.1)
    else:
        raise SmokeFailure(f"recovery terminal cleanup failed: {recovery['terminalCleanup']!r}")
    wait_recovery_processes_gone([recovery["cycles"][-1]["afterTerminals"]["process"]])
    for check in RECOVERY_CHECKS:
        report["checks"][check] = True


RUNNERS: dict[str, Callable[[argparse.Namespace, str, dict[str, Any], Path, dict[str, Any]], None]] = {
    "scm": run_scm,
    "debug": run_debug,
    "extensions": run_extensions,
    "terminal": run_terminal,
    "recovery": run_recovery,
}


def run(args: argparse.Namespace) -> int:
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    console_path = output_dir / f"{run_id}-console.log"
    profile_dir = Path(tempfile.mkdtemp(prefix=f"wizp-native-{args.journey}-profile-"))
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle = None
    stderr_handle = None
    report: dict[str, Any] = {
        "schema": 1,
        "kind": f"wizp-linux-packaged-native-{args.journey}",
        "journey": args.journey,
        "runId": run_id,
        "status": "failed",
        "startedAt": utc_now(),
        "finishedAt": None,
        "binary": str(binary),
        "outputDir": str(output_dir),
        "checks": {},
        "evidence": {},
        "notClaimed": [
            "Assistive-technology sign-off",
            "macOS or Windows behavior",
        ],
        "errors": [],
    }

    try:
        if not os.environ.get("DISPLAY", "").strip() or os.environ.get("WIZP_VIRTUAL_DISPLAY") != "1":
            raise SmokeFailure("isolated DISPLAY is not set; use scripts/run_virtual_ui_test.sh")
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise SmokeFailure(f"packaged launcher is missing or not executable: {binary}")
        if contains_resources_app(output_dir):
            raise SmokeFailure("--output-dir must be outside packaged Resources/app")
        validate_port(args.port, "--port")
        validate_port(args.control_port, "--control-port")
        if args.port == args.control_port:
            raise SmokeFailure("--port and --control-port must differ")
        require_unused_port(args.port, "backend port")
        require_unused_port(args.control_port, "control port")

        xdotool = require_tool("xdotool")
        import_tool = require_tool("import")
        tesseract = require_tool("tesseract")
        if args.journey == "scm":
            require_tool("git")
        language = select_tesseract_language(tesseract)
        preexisting_windows = xdotool_window_ids(xdotool)
        for name in ("cache", "config", "data", "state", "runtime"):
            (profile_dir / name).mkdir()
        os.chmod(profile_dir / "runtime", 0o700)
        write_deterministic_shell_profile(profile_dir)
        cef_dirs = [
            profile_dir / "cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
            profile_dir / ".cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
        ]
        for path in cef_dirs:
            path.parent.mkdir(parents=True, exist_ok=True)
        report["profile"] = profile_setup_diagnostics(
            cef_dirs,
            [path.parent for path in cef_dirs],
            stop_at=profile_dir,
            leaf_precreated=False,
        )
        fixture = prepare_workspace(args.journey, workspace_dir)
        write_json(output_dir / f"{run_id}-fixture.json", fixture)

        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(profile_dir),
                "XDG_CACHE_HOME": str(profile_dir / "cache"),
                "XDG_CONFIG_HOME": str(profile_dir / "config"),
                "XDG_DATA_HOME": str(profile_dir / "data"),
                "XDG_STATE_HOME": str(profile_dir / "state"),
                "XDG_RUNTIME_DIR": str(profile_dir / "runtime"),
                "WIZP_PORT": str(args.port),
                "WIZP_CONTROL_PORT": str(args.control_port),
                "WIZP_HTTP_WORKERS": "4",
                "WIZP_NATIVE_UI_SMOKE": "1",
                "WIZP_NATIVE_UI_SMOKE_TERMINALS": "1",
            }
        )
        if args.journey == "scm":
            environment["WIZP_SCM_CREDENTIAL_FIXTURE"] = "cancel"

        if args.journey == "terminal":
            prepare_local_link_opener(profile_dir, args.control_port)
            environment["XDG_CURRENT_DESKTOP"] = "X-Generic"
            browser = subprocess.run(
                ["xdg-mime", "query", "default", "x-scheme-handler/http"],
                env=environment, capture_output=True, text=True, check=True, timeout=5,
            ).stdout.strip()
            if browser != "wizp-native-local-link.desktop":
                raise SmokeFailure(f"isolated browser fixture was not registered: {browser!r}")
        if args.journey == "extensions":
            environment["WIZP_NATIVE_OPEN_DIALOG_ENTRY"] = "1"
            require_tool("zenity")
        stdout_handle = stdout_path.open("wb")
        stderr_handle = stderr_path.open("wb")
        process = subprocess.Popen(
            [str(binary)],
            cwd=workspace_dir,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
        )
        process_group = os.getpgid(process.pid)
        if process_group != process.pid:
            raise SmokeFailure("packaged launcher process group was not isolated")
        report["launcherPid"] = process.pid
        wait_for_ready(args.port, process)
        window = wait_for_new_window(xdotool, preexisting_windows, process_group, process)
        activate_window(xdotool, window)
        report["window"] = window
        wait_for_visible_ui(
            import_tool,
            tesseract,
            language,
            window["id"],
            output_dir / f"{run_id}-00-ui-ready.png",
            output_dir / f"{run_id}-00-ui-ready.txt",
            output_dir / f"{run_id}-00-ui-ready.stderr.log",
        )

        rpc = RpcClient(args.port)
        folders = rpc.call("workspace/setFolders", {"path": str(workspace_dir)})
        folder_list = folders.get("folders") if isinstance(folders, dict) else None
        if not isinstance(folder_list, list) or not folder_list or folder_list[0].get("path") != str(workspace_dir):
            raise SmokeFailure(f"workspace/setFolders did not retain fixture: {folders}")
        evaluate_webview(
            args.control_port,
            "(() => { document.dispatchEvent(new Event('workspace:modified')); return true; })()",
            "refresh workspace UI after fixture selection",
        )
        wait_for_webview(
            args.control_port,
            "Boolean(document.querySelector('[role=\"tree\"]'))",
            "wait for fixture workspace UI",
        )
        wait_for_webview(
            args.control_port,
            "Boolean(window.__refreshExplorer)",
            "wait for Explorer refresh hook",
        )
        evaluate_webview(
            args.control_port,
            "(() => { window.__refreshExplorer(); return true; })()",
            "refresh Explorer after fixture selection",
        )
        time.sleep(1.0)
        click(
            xdotool,
            window,
            int(window["geometry"]["width"] * 0.55),
            180,
            "focus workbench",
        )
        args.profile_dir = profile_dir
        RUNNERS[args.journey](args, xdotool, window, workspace_dir, report)

        missing = sorted(REQUIRED_CHECKS[args.journey] - set(report["checks"]))
        failed = sorted(name for name, value in report["checks"].items() if value is not True)
        if missing or failed:
            raise SmokeFailure(f"journey checks incomplete: missing={missing}, failed={failed}")

        final_png = output_dir / f"{run_id}-99-final.png"
        final_ocr = output_dir / f"{run_id}-99-final.txt"
        capture_state(
            import_tool,
            tesseract,
            language,
            window,
            final_png,
            final_ocr,
            output_dir / f"{run_id}-99-final.stderr.log",
        )
        report["evidence"]["99-final"] = {"screenshot": final_png.name, "ocr": final_ocr.name}
        report["status"] = "passed"
    except (OSError, SmokeFailure, subprocess.SubprocessError) as exc:
        report["errors"].append(str(exc))
    finally:
        report["cleanup"] = terminate_process_group(process, process_group)
        if stdout_handle is not None:
            stdout_handle.close()
        if stderr_handle is not None:
            stderr_handle.close()
        if stdout_path.exists() or stderr_path.exists():
            combine_console(stdout_path, stderr_path, console_path)
            report["console"] = console_path.name
        try:
            shutil.rmtree(profile_dir)
        except OSError as exc:
            report["errors"].append(f"disposable profile cleanup failed: {exc}")
            report["status"] = "failed"
        if isinstance(report.get("profile"), dict):
            report["profile"]["removedAfterRun"] = not profile_dir.exists()
        report["finishedAt"] = utc_now()
        promotion = retain_and_promote_report(
            output_dir,
            report,
            lambda path: validate_report(report, args.journey, path),
        )
        if not promotion.promoted:
            print(
                f"native {args.journey} report retained without promotion: "
                f"{promotion.retained_report}",
                file=sys.stderr,
            )
            for error in promotion.errors:
                print(f"- {error}", file=sys.stderr)
    return 0 if promotion.promoted else 1


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
