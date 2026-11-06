#!/usr/bin/env python3
"""Exercise the packaged Linux workspace Search lifecycle with real X11 input."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.check_native_search_report import validate_report
from scripts.native_editor_smoke import evaluate_webview, type_text
from scripts.native_explorer_smoke import wait_for_path, wait_for_webview
from scripts.native_report_promotion import retain_and_promote_report
from scripts.native_settings_smoke import capture_state, click, key
from scripts.native_ui_baseline_smoke import (
    DEFAULT_BINARY,
    RpcClient,
    SmokeFailure,
    activate_window,
    combine_console,
    contains_resources_app,
    create_fixture,
    profile_setup_diagnostics,
    require_tool,
    require_unused_port,
    resolve_cli_path,
    select_tesseract_language,
    terminate_process_group,
    utc_now,
    validate_port,
    wait_for_new_window,
    wait_for_ready,
    wait_for_visible_ui,
    write_deterministic_shell_profile,
    write_json,
    xdotool_window_ids,
)

DEFAULT_OUTPUT = ROOT / "build" / "ui-ux" / "native-search"


def control_script(label: str, body: str) -> str:
    return (
        "((label) => { const node = document.querySelector(`[aria-label=\"${label}\"]`); "
        f"if (!node) return null; {body} }})("
        + json.dumps(label)
        + ")"
    )


def control_target(control_port: int, label: str, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        control_script(
            label,
            "const rect = node.getBoundingClientRect(); return { "
            "x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2), "
            "tag: node.tagName, role: node.getAttribute('role') || '', "
            "pressed: node.getAttribute('aria-pressed'), "
            "expanded: node.getAttribute('aria-expanded'), disabled: node.disabled === true };",
        ),
        phase,
    )
    if not isinstance(value, dict) or not isinstance(value.get("x"), int) or not isinstance(value.get("y"), int):
        raise SmokeFailure(f"{phase} returned invalid control: {value!r}")
    return value


def click_control(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    label: str,
    phase: str,
) -> dict[str, Any]:
    target = control_target(control_port, label, phase)
    click(xdotool, window, target["x"], target["y"], phase)
    return target


def fill_control(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    label: str,
    value: str,
    phase: str,
    *,
    submit: bool = False,
) -> None:
    actual: Any = None
    for attempt in range(2):
        click_control(control_port, xdotool, window, label, phase)
        key(xdotool, window, "ctrl+a", f"select {label} for {phase}")
        if value:
            type_text(xdotool, window, value, f"type {label} for {phase}")
        else:
            key(xdotool, window, "BackSpace", f"clear {label} for {phase}")
        actual = evaluate_webview(
            control_port,
            control_script(label, "return node.value ?? null;"),
            f"verify {label} for {phase}",
        )
        if actual == value:
            break
        if attempt == 0:
            time.sleep(0.2)
    if actual != value:
        raise SmokeFailure(f"{phase} did not set {label} to {value!r}: {actual!r}")
    if submit:
        key(xdotool, window, "Return", phase)


def select_control(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    label: str,
    value: str,
    phase: str,
) -> None:
    click_control(control_port, xdotool, window, label, phase)
    key(xdotool, window, "Home", f"reset {label} for {phase}")
    for _ in range(int(value)):
        key(xdotool, window, "Down", f"select {label} for {phase}")
    key(xdotool, window, "Return", phase)


def search_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    value = evaluate_webview(
        control_port,
        r"""
(() => {
  const view = document.querySelector('section[aria-label="Workspace search"]');
  const form = view?.querySelector('form[role="search"]');
  const results = view?.querySelector('.search-results');
  const summary = view?.querySelector('.search-summary');
  const message = view?.querySelector('.search-message');
  const rows = Array.from(view?.querySelectorAll('.search-result') || []);
  const active = document.activeElement;
  const byLabel = (label) => view?.querySelector(`[aria-label="${label}"]`);
  return {
    found: Boolean(view),
    formRole: form?.getAttribute('role') || '',
    resultsBusy: results?.getAttribute('aria-busy') || '',
    query: byLabel('Search files')?.value || '',
    replacement: byLabel('Replace with')?.value || '',
    queryFocused: active === byLabel('Search files'),
    activeLabel: active?.getAttribute?.('aria-label') || '',
    summary: summary?.textContent?.replace(/\s+/g, ' ').trim() || '',
    message: message?.textContent?.replace(/\s+/g, ' ').trim() || '',
    messageRole: message?.getAttribute('role') || '',
    messageAction: message?.querySelector('button')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    resultListLabel: view?.querySelector('.search-result-list')?.getAttribute('aria-label') || '',
    resultCount: rows.length,
    resultLabels: rows.map((row) => row.querySelector('.search-result-open')?.getAttribute('aria-label') || ''),
    resultFiles: rows.map((row) => row.querySelector('.search-result-file')?.textContent?.trim() || ''),
    resultContexts: rows.map((row) => row.querySelector('.search-result-context')?.textContent?.replace(/\s+/g, ' ').trim() || ''),
    toggles: {
      case: byLabel('Match case')?.getAttribute('aria-pressed') || '',
      whole: byLabel('Match whole word')?.getAttribute('aria-pressed') || '',
      regex: byLabel('Use regular expression')?.getAttribute('aria-pressed') || '',
      replace: byLabel('Toggle replace')?.getAttribute('aria-pressed') || '',
      details: byLabel('Toggle search details')?.getAttribute('aria-expanded') || '',
    },
  };
})()
""",
        phase,
    )
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid Search snapshot: {value!r}")
    return value


def wait_for_search_state(
    control_port: int,
    phase: str,
    predicate: str,
    *,
    timeout: float = 12.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = search_snapshot(control_port, phase)
        matched = evaluate_webview(
            control_port,
            f"((snapshot) => Boolean({predicate}))({json.dumps(last)})",
            phase,
        )
        if matched is True:
            return last
        time.sleep(0.15)
    raise SmokeFailure(f"{phase} did not reach the expected state: {last!r}")


def wait_for_summary(control_port: int, marker: str, phase: str) -> dict[str, Any]:
    return wait_for_search_state(
        control_port,
        phase,
        f"snapshot.summary.includes({json.dumps(marker)}) && snapshot.resultsBusy === ''",
    )


def wait_for_message(control_port: int, marker: str, phase: str) -> dict[str, Any]:
    return wait_for_search_state(
        control_port,
        phase,
        f"snapshot.message.includes({json.dumps(marker)}) && snapshot.resultsBusy === ''",
    )


def inject_one_shot_rpc_failure(
    control_port: int,
    method: str,
    phase: str,
) -> dict[str, Any]:
    value = evaluate_webview(
        control_port,
        r"""
((targetMethod) => {
  const originalFetch = window.fetch.bind(window);
  const state = { armed: true, method: targetMethod, matched: 0 };
  window.__wizpNativeSearchFailure = state;
  window.fetch = (input, init) => {
    const url = typeof input === "string" ? input : input?.url || "";
    if (url.endsWith("/api/rpc") && typeof init?.body === "string") {
      try {
        const request = JSON.parse(init.body);
        if (state.armed && request?.method === targetMethod) {
          state.armed = false;
          state.matched += 1;
          window.fetch = originalFetch;
          return Promise.reject(new Error(`Injected one-shot ${targetMethod} failure`));
        }
      } catch {
        // Non-JSON requests are unrelated to the RPC fault injection.
      }
    }
    return originalFetch(input, init);
  };
  return { armed: state.armed, method: state.method, matched: state.matched };
})
""" + f"({json.dumps(method)})",
        phase,
    )
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid injection state: {value!r}")
    if value != {"armed": True, "method": method, "matched": 0}:
        raise SmokeFailure(f"{phase} did not arm the expected one-shot failure: {value!r}")
    return value


def search_retry_target(control_port: int, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        r"""
(() => {
  const node = Array.from(document.querySelectorAll('.search-message button'))
    .find((button) => (button.textContent || '').replace(/\s+/g, ' ').trim() === 'Retry');
  if (!node) return null;
  const rect = node.getBoundingClientRect();
  return {
    label: (node.textContent || '').replace(/\s+/g, ' ').trim(),
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
  };
})()
""",
        phase,
    )
    if not isinstance(value, dict) or not isinstance(value.get("x"), int) or not isinstance(value.get("y"), int):
        raise SmokeFailure(f"{phase} returned invalid Retry action: {value!r}")
    return value


def replace_dialog_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    value = evaluate_webview(
        control_port,
        r"""
(() => {
  const dialog = document.querySelector('dialog.replace-dialog[open]');
  if (!dialog) return null;
  const active = document.activeElement;
  return {
    open: dialog.open,
    title: dialog.querySelector('#replace-all-title')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    labelledBy: dialog.getAttribute('aria-labelledby') || '',
    description: dialog.querySelector('p')?.textContent?.replace(/\s+/g, ' ').trim() || '',
    buttons: Array.from(dialog.querySelectorAll('button')).map((button) => button.textContent?.trim() || ''),
    active: active?.textContent?.trim() || active?.getAttribute?.('aria-label') || '',
    activeTag: active?.tagName || '',
  };
})()
""",
        phase,
    )
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid replace dialog: {value!r}")
    return value


def wait_for_replace_dialog(control_port: int, phase: str) -> dict[str, Any]:
    deadline = time.monotonic() + 6.0
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = replace_dialog_snapshot(control_port, phase)
        if last.get("open") is True:
            return last
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} replace dialog did not open: {last!r}")


def wait_for_replace_dialog_closed(control_port: int, phase: str) -> None:
    deadline = time.monotonic() + 6.0
    while time.monotonic() < deadline:
        if not replace_dialog_snapshot(control_port, phase):
            return
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} replace dialog did not close")


def wait_for_file_content(path: Path, expected: str, phase: str, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            last = path.read_text(encoding="utf-8")
        except OSError:
            last = ""
        if expected in last:
            return
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} did not write {expected!r} to {path}: {last!r}")


def permission_file_snapshot(path: Path) -> dict[str, Any]:
    return {
        "mode": f"0o{path.stat().st_mode & 0o777:03o}",
        "writable": os.access(path, os.W_OK),
        "content": path.read_text(encoding="utf-8"),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--port", type=int, default=23889)
    parser.add_argument("--control-port", type=int, default=24889)
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    console_path = output_dir / f"{run_id}-console.log"
    profile_dir = Path(tempfile.mkdtemp(prefix="wizp-native-search-profile-"))
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle = None
    stderr_handle = None
    permission_path: Path | None = None
    report: dict[str, Any] = {
        "schema": 1,
        "kind": "wizp-linux-packaged-native-search",
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
        fixture = create_fixture(workspace_dir)
        search = fixture["searchLifecycle"]
        permission_path = workspace_dir / "search-read-only.txt"
        permission_path.write_text("permission-one permission-one\n", encoding="utf-8")
        os.chmod(permission_path, 0o444)
        limit_dir = workspace_dir / "search-limit"
        limit_dir.mkdir()
        for index in range(105):
            (limit_dir / f"limit-{index:03}.txt").write_text(
                f"WIZP_UI_SEARCH_LIMIT {index}\n", encoding="utf-8"
            )
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
        report["checks"]["workspaceFixtureSelected"] = True

        search_target = wait_for_webview(
            args.control_port,
            r"""
(() => {
  const node = Array.from(document.querySelectorAll('nav[aria-label="Activity bar"] button'))
    .find((button) => (button.getAttribute('aria-label') || '').startsWith('Search ('));
  if (!node) return null;
  const rect = node.getBoundingClientRect();
  return {
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
    label: node.getAttribute('aria-label') || '',
  };
})()
""",
            "locate Search Activity Bar control",
        )
        if (
            not isinstance(search_target, dict)
            or not isinstance(search_target.get("x"), int)
            or not isinstance(search_target.get("y"), int)
            or not str(search_target.get("label", "")).startswith("Search (")
        ):
            raise SmokeFailure(f"Search Activity Bar control is invalid: {search_target!r}")
        click(
            xdotool,
            window,
            search_target["x"],
            search_target["y"],
            "open workspace Search from the Activity Bar",
        )
        initial = wait_for_search_state(
            args.control_port,
            "open workspace Search",
            "snapshot.found && snapshot.formRole === 'search'",
        )
        click_control(args.control_port, xdotool, window, "Search files", "focus Search input")
        initial = wait_for_search_state(
            args.control_port,
            "focus Search input",
            "snapshot.queryFocused",
        )
        expected_toggles = {"case": "false", "whole": "false", "regex": "false", "replace": "false", "details": "false"}
        if initial.get("toggles") != expected_toggles:
            raise SmokeFailure(f"Search controls have invalid initial semantics: {initial!r}")
        report["accessibility"] = {"initial": initial}
        report["checks"]["searchAccessible"] = True
        report["checks"]["searchActivityBarOpen"] = True

        fill_control(args.control_port, xdotool, window, "Search files", search["query"], "search fixture", submit=True)
        basic = wait_for_summary(args.control_port, "5 matching lines in 2 files", "basic Search results")
        if basic.get("resultListLabel") != "Search results" or basic.get("resultCount") != 5:
            raise SmokeFailure(f"basic Search result semantics are incomplete: {basic!r}")
        report["states"] = {"basic": basic}
        report["checks"]["queryResultsShown"] = True

        click_control(args.control_port, xdotool, window, "Toggle search details", "show Search details")
        fill_control(args.control_port, xdotool, window, "Files to include", search["include"], "set Search include")
        fill_control(args.control_port, xdotool, window, "Files to exclude", search["exclude"], "set Search exclude")
        select_control(args.control_port, xdotool, window, "Context lines", "1", "set Search context")
        filtered = wait_for_summary(args.control_port, "4 matching lines in 1 file", "filtered Search results")
        if not any("Alpha one" in context or "alpha two" in context for context in filtered.get("resultContexts", [])):
            raise SmokeFailure(f"Search context lines were not rendered: {filtered!r}")
        report["states"]["filtered"] = filtered
        report["checks"]["filtersAndContextApplied"] = True

        click_control(args.control_port, xdotool, window, "Match whole word", "enable Search whole word")
        whole = wait_for_summary(args.control_port, "3 matching lines in 1 file", "whole-word Search")
        if whole.get("toggles", {}).get("whole") != "true":
            raise SmokeFailure(f"Search whole-word toggle did not activate: {whole!r}")
        click_control(args.control_port, xdotool, window, "Match case", "enable Search case matching")
        case = wait_for_summary(args.control_port, "1 matching line in 1 file", "case-sensitive Search")
        if case.get("toggles", {}).get("case") != "true":
            raise SmokeFailure(f"Search case toggle did not activate: {case!r}")
        report["states"]["wholeWord"] = whole
        report["states"]["caseSensitive"] = case
        report["checks"]["caseAndWholeWordApplied"] = True

        click_control(args.control_port, xdotool, window, "Match case", "disable Search case matching")
        click_control(args.control_port, xdotool, window, "Match whole word", "disable Search whole word")
        click_control(args.control_port, xdotool, window, "Use regular expression", "enable Search regex")
        fill_control(args.control_port, xdotool, window, "Search files", "[", "submit invalid Search regex", submit=True)
        invalid = wait_for_message(args.control_port, "Search failed:", "invalid Search regex")
        if invalid.get("messageRole") != "alert" or "Retry" not in invalid.get("message", ""):
            raise SmokeFailure(f"invalid Search regex did not expose recoverable error semantics: {invalid!r}")
        report["states"]["invalidRegex"] = invalid
        report["checks"]["invalidRegexRecovered"] = True

        click_control(args.control_port, xdotool, window, "Use regular expression", "disable Search regex")
        fill_control(args.control_port, xdotool, window, "Files to include", "", "clear Search include")
        fill_control(args.control_port, xdotool, window, "Files to exclude", "", "clear Search exclude")
        select_control(args.control_port, xdotool, window, "Context lines", "0", "clear Search context")
        fill_control(args.control_port, xdotool, window, "Search files", "WIZP_UI_NO_MATCH", "zero-result Search", submit=True)
        zero = wait_for_message(args.control_port, "No matches found", "zero-result Search")
        report["states"]["zero"] = zero
        report["checks"]["zeroResultShown"] = True

        fill_control(
            args.control_port,
            xdotool,
            window,
            "Search files",
            search["query"],
            "prepare Search query for injected RPC failure",
        )
        rpc_ready = wait_for_summary(
            args.control_port,
            "5 matching lines in 2 files",
            "prepare Search RPC failure",
        )
        if rpc_ready.get("resultLabels") != basic.get("resultLabels"):
            raise SmokeFailure(
                f"Search RPC failure setup did not restore the baseline results: {rpc_ready!r}"
            )
        report["states"]["rpcReady"] = rpc_ready
        injection = inject_one_shot_rpc_failure(
            args.control_port,
            "search/text",
            "inject one-shot Search RPC failure",
        )
        submitted = evaluate_webview(
            args.control_port,
            "(() => { const form = document.querySelector('form.search-box'); "
            "if (!(form instanceof HTMLFormElement)) return false; "
            "form.requestSubmit(); return true; })()",
            "submit Search with injected RPC failure",
        )
        if submitted is not True:
            raise SmokeFailure("Injected Search RPC failure form submission was unavailable")
        rpc_failure = wait_for_message(
            args.control_port,
            "Injected one-shot search/text failure",
            "injected Search RPC failure",
        )
        if (
            rpc_failure.get("messageRole") != "alert"
            or rpc_failure.get("messageAction") != "Retry"
            or rpc_failure.get("query") != search["query"]
            or rpc_failure.get("resultCount") != 0
        ):
            raise SmokeFailure(
                f"Search RPC failure did not preserve a recoverable query state: {rpc_failure!r}"
            )
        injection_after_failure = evaluate_webview(
            args.control_port,
            "(() => { const state = window.__wizpNativeSearchFailure; "
            "return state ? { armed: state.armed, method: state.method, matched: state.matched } : null; })()",
            "inspect one-shot Search RPC failure",
        )
        if injection_after_failure != {"armed": False, "method": "search/text", "matched": 1}:
            raise SmokeFailure(
                f"Search RPC failure did not fire exactly once: {injection_after_failure!r}"
            )
        rpc_error_png = output_dir / f"{run_id}-07-rpc-error.png"
        rpc_error_ocr = output_dir / f"{run_id}-07-rpc-error.txt"
        capture_state(
            import_tool,
            tesseract,
            language,
            window,
            rpc_error_png,
            rpc_error_ocr,
            output_dir / f"{run_id}-07-rpc-error.stderr.log",
        )
        report["evidence"]["07-rpc-error"] = {
            "screenshot": rpc_error_png.name,
            "ocr": rpc_error_ocr.name,
            "message": rpc_failure.get("message", ""),
        }
        report["rpcRecovery"] = {
            "injection": injection,
            "afterFailure": injection_after_failure,
        }
        report["states"]["rpcFailure"] = rpc_failure
        report["checks"]["rpcFailureExposedRetry"] = True
        report["checks"]["rpcFailurePreservedQuery"] = True

        retry_target = search_retry_target(args.control_port, "locate Search Retry action")
        click(xdotool, window, retry_target["x"], retry_target["y"], "retry failed Search")
        rpc_retry = wait_for_summary(
            args.control_port,
            "5 matching lines in 2 files",
            "Search RPC retry",
        )
        if (
            rpc_retry.get("query") != search["query"]
            or rpc_retry.get("resultCount") != 5
            or rpc_retry.get("resultListLabel") != "Search results"
            or rpc_retry.get("resultLabels") != basic.get("resultLabels")
        ):
            raise SmokeFailure(
                f"Search RPC retry did not restore the retained query results: {rpc_retry!r}"
            )
        report["rpcRecovery"]["retryAction"] = retry_target
        report["states"]["rpcRetry"] = rpc_retry
        report["checks"]["rpcRetryRecovered"] = True

        fill_control(args.control_port, xdotool, window, "Search files", "debounced-cancel", "schedule Search cancellation")
        key(xdotool, window, "Escape", "cancel pending Search")
        time.sleep(0.7)
        cancelled = search_snapshot(args.control_port, "cancel pending Search")
        if cancelled.get("query") or cancelled.get("resultCount") != 0 or cancelled.get("queryFocused") is not True:
            raise SmokeFailure(f"Search cancellation retained stale state: {cancelled!r}")
        report["states"]["cancelled"] = cancelled
        report["checks"]["cancellationClearedStaleResults"] = True

        fill_control(args.control_port, xdotool, window, "Search files", search["navigationMarker"], "Search navigation fixture", submit=True)
        navigation = wait_for_summary(args.control_port, "1 matching line in 1 file", "Search result navigation")
        first_result = wait_for_webview(
            args.control_port,
            "(() => { const node = document.querySelector('.search-result-open'); if (!node) return null; "
            "const rect = node.getBoundingClientRect(); return { label: node.getAttribute('aria-label') || '', "
            "x: Math.round(rect.left + rect.width / 2), y: Math.round(rect.top + rect.height / 2) }; })()",
            "locate Search navigation result",
        )
        if not isinstance(first_result, dict) or not isinstance(first_result.get("x"), int) or not isinstance(first_result.get("y"), int):
            raise SmokeFailure(f"Search navigation result is invalid: {first_result!r}")
        click(xdotool, window, first_result["x"], first_result["y"], "open Search result")
        click(xdotool, window, first_result["x"], first_result["y"], "confirm Search result open")
        opened = wait_for_webview(
            args.control_port,
            "(() => { const editor = window.__getActiveEditor?.(); const value = editor?.getValue?.() || ''; "
            "const line = editor?.getPosition?.()?.lineNumber || 0; return value.includes('WIZP_UI_SEARCH_MARKER') "
            "&& line === 2 ? { line, marker: true } : null; })()",
            "Search result editor navigation",
        )
        report["navigation"] = {"result": first_result, "editor": opened, "state": navigation}
        report["checks"]["resultNavigated"] = True

        key(xdotool, window, "ctrl+shift+f", "return to workspace Search")
        wait_for_search_state(args.control_port, "return to Search", "snapshot.found")
        fill_control(args.control_port, xdotool, window, "Search files", "WIZP_UI_SEARCH_LIMIT", "bounded Search", submit=True)
        bounded = wait_for_summary(args.control_port, "First 100 matching lines in 100 files", "bounded Search results")
        if "Result limit: 100" not in bounded.get("summary", ""):
            raise SmokeFailure(f"Search result limit was not reported: {bounded!r}")
        report["states"]["bounded"] = bounded
        report["checks"]["resultLimitReported"] = True

        click_control(args.control_port, xdotool, window, "Toggle replace", "show Search replacement")
        fill_control(args.control_port, xdotool, window, "Search files", "replace-one", "Search replace-one fixture", submit=True)
        wait_for_summary(args.control_port, "2 matching lines in 1 file", "replace-one Search results")
        fill_control(args.control_port, xdotool, window, "Replace with", "replaced-one", "set replace-one text")
        replace_one = wait_for_webview(
            args.control_port,
            "(() => { const node = document.querySelector('.replace-one-button'); if (!node || node.disabled) return null; "
            "const rect = node.getBoundingClientRect(); return { x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2), label: node.getAttribute('aria-label') || '' }; })()",
            "locate replace-one action",
        )
        if not isinstance(replace_one, dict) or not isinstance(replace_one.get("x"), int) or not isinstance(replace_one.get("y"), int):
            raise SmokeFailure(f"replace-one action is invalid: {replace_one!r}")
        click(xdotool, window, replace_one["x"], replace_one["y"], "replace one Search match")
        replace_one_path = workspace_dir / search["replaceOnePath"]
        wait_for_file_content(replace_one_path, "replaced-one replace-one", "replace one Search match")
        replaced_one = wait_for_search_state(
            args.control_port,
            "replace-one result",
            "snapshot.message.includes('Replaced 1 occurrence') || snapshot.summary.includes('2 matching lines')",
        )
        report["states"]["replaceOne"] = replaced_one
        report["checks"]["replaceOneCompleted"] = True

        fill_control(args.control_port, xdotool, window, "Search files", "permission-one", "Search read-only fixture", submit=True)
        wait_for_summary(
            args.control_port,
            "1 matching line in 1 file",
            "read-only Search results",
        )
        fill_control(args.control_port, xdotool, window, "Replace with", "permission-replaced", "set read-only replacement")
        permission_ready = search_snapshot(args.control_port, "read-only Search ready to replace")
        if (
            permission_ready.get("query") != "permission-one"
            or permission_ready.get("replacement") != "permission-replaced"
            or permission_ready.get("resultCount") != 1
            or permission_ready.get("resultListLabel") != "Search results"
        ):
            raise SmokeFailure(f"read-only Search state is incomplete before replacement: {permission_ready!r}")
        permission_before_failure = permission_file_snapshot(permission_path)
        if permission_before_failure != {
            "mode": "0o444",
            "writable": False,
            "content": "permission-one permission-one\n",
        }:
            raise SmokeFailure(
                f"Search permission fixture is not genuinely read-only: {permission_before_failure!r}"
            )
        permission_action = wait_for_webview(
            args.control_port,
            "(() => { const node = document.querySelector('.replace-one-button'); if (!node || node.disabled) return null; "
            "const rect = node.getBoundingClientRect(); return { x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2), label: node.getAttribute('aria-label') || '' }; })()",
            "locate read-only replace action",
        )
        if (
            not isinstance(permission_action, dict)
            or not isinstance(permission_action.get("x"), int)
            or not isinstance(permission_action.get("y"), int)
            or permission_action.get("label") != "Replace match in search-read-only.txt on line 1"
        ):
            raise SmokeFailure(f"read-only replace action is invalid: {permission_action!r}")
        click(xdotool, window, permission_action["x"], permission_action["y"], "replace read-only Search match")
        permission = wait_for_message(args.control_port, "Replace stopped after 0 changes", "Search permission failure")
        permission_after_failure = permission_file_snapshot(permission_path)
        if (
            permission.get("messageRole") != "alert"
            or "AccessDenied" not in str(permission.get("message", ""))
            or permission.get("query") != permission_ready.get("query")
            or permission.get("replacement") != permission_ready.get("replacement")
            or permission.get("resultCount") != permission_ready.get("resultCount")
            or permission.get("resultLabels") != permission_ready.get("resultLabels")
            or permission_after_failure != permission_before_failure
        ):
            raise SmokeFailure(
                f"Search permission failure did not preserve the query, results, and file: {permission!r}; "
                f"file={permission_after_failure!r}"
            )
        permission_png = output_dir / f"{run_id}-08-permission-error.png"
        permission_ocr = output_dir / f"{run_id}-08-permission-error.txt"
        capture_state(
            import_tool,
            tesseract,
            language,
            window,
            permission_png,
            permission_ocr,
            output_dir / f"{run_id}-08-permission-error.stderr.log",
        )
        report["evidence"]["08-permission-error"] = {
            "screenshot": permission_png.name,
            "ocr": permission_ocr.name,
            "message": permission.get("message", ""),
        }
        report["states"]["permissionReady"] = permission_ready
        report["states"]["permissionFailure"] = permission
        report["checks"]["permissionFailurePreservedFile"] = True
        report["checks"]["permissionFailurePreservedState"] = True

        os.chmod(permission_path, 0o644)
        permission_after_restore = permission_file_snapshot(permission_path)
        if permission_after_restore != {
            "mode": "0o644",
            "writable": True,
            "content": "permission-one permission-one\n",
        }:
            raise SmokeFailure(
                f"Search permission fixture did not become writable for recovery: {permission_after_restore!r}"
            )
        permission_retry_action = wait_for_webview(
            args.control_port,
            "(() => { const node = document.querySelector('.replace-one-button'); if (!node || node.disabled) return null; "
            "const rect = node.getBoundingClientRect(); return { x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2), label: node.getAttribute('aria-label') || '' }; })()",
            "locate retained read-only replace action",
        )
        if (
            not isinstance(permission_retry_action, dict)
            or not isinstance(permission_retry_action.get("x"), int)
            or not isinstance(permission_retry_action.get("y"), int)
            or permission_retry_action.get("label") != permission_action.get("label")
        ):
            raise SmokeFailure(
                f"Search permission failure did not retain the replace action: {permission_retry_action!r}"
            )
        click(
            xdotool,
            window,
            permission_retry_action["x"],
            permission_retry_action["y"],
            "retry read-only Search replacement after restoring permission",
        )
        permission_recovered = wait_for_message(
            args.control_port,
            "Replaced 1 occurrence across 1 file",
            "Search permission recovery",
        )
        wait_for_file_content(
            permission_path,
            "permission-replaced permission-one\n",
            "Search permission recovery",
        )
        permission_after_retry = permission_file_snapshot(permission_path)
        if (
            permission_recovered.get("messageRole") != "status"
            or permission_recovered.get("query") != permission_ready.get("query")
            or permission_recovered.get("replacement") != permission_ready.get("replacement")
            or permission_recovered.get("resultCount") != 1
            or permission_after_retry
            != {
                "mode": "0o644",
                "writable": True,
                "content": "permission-replaced permission-one\n",
            }
        ):
            raise SmokeFailure(
                f"Search permission retry did not recover through the retained state: "
                f"{permission_recovered!r}; file={permission_after_retry!r}"
            )
        report["states"]["permissionRecovery"] = permission_recovered
        report["permissionRecovery"] = {
            "path": "search-read-only.txt",
            "action": permission_action,
            "retryAction": permission_retry_action,
            "beforeFailure": permission_before_failure,
            "afterFailure": permission_after_failure,
            "afterRestore": permission_after_restore,
            "afterRetry": permission_after_retry,
        }
        report["checks"]["permissionRecoveryCompleted"] = True

        fill_control(args.control_port, xdotool, window, "Search files", "replace-all", "Search replace-all fixtures", submit=True)
        wait_for_summary(args.control_port, "3 matching lines in 2 files", "replace-all Search results")
        fill_control(args.control_port, xdotool, window, "Replace with", "replaced-all", "set replace-all text")
        replace_all_target = click_control(args.control_port, xdotool, window, "Replace all matches", "open replace-all dialog")
        if replace_all_target.get("disabled") is True:
            raise SmokeFailure("replace-all action was disabled with current results")
        replace_dialog = wait_for_replace_dialog(args.control_port, "replace-all confirmation")
        if (
            replace_dialog.get("labelledBy") != "replace-all-title"
            or replace_dialog.get("buttons") != ["Cancel", "Replace All"]
            or "2 files" not in replace_dialog.get("title", "")
        ):
            raise SmokeFailure(f"replace-all dialog semantics are incomplete: {replace_dialog!r}")
        key(xdotool, window, "Escape", "cancel replace-all dialog")
        wait_for_replace_dialog_closed(args.control_port, "cancel replace-all dialog")
        focus_after_cancel = wait_for_webview(
            args.control_port,
            "document.activeElement?.getAttribute?.('aria-label') === 'Replace all matches' ? true : false",
            "replace-all cancel focus return",
        )
        if focus_after_cancel is not True:
            raise SmokeFailure("replace-all cancellation did not restore trigger focus")
        click_control(args.control_port, xdotool, window, "Replace all matches", "reopen replace-all dialog")
        wait_for_replace_dialog(args.control_port, "reopen replace-all confirmation")
        key(xdotool, window, "Tab", "focus Replace All confirmation")
        key(xdotool, window, "Return", "confirm replace-all")
        wait_for_replace_dialog_closed(args.control_port, "confirm replace-all")
        for relative in search["replaceAllPaths"]:
            wait_for_file_content(workspace_dir / relative, "replaced-all", "replace all Search matches")
        replace_all = wait_for_message(args.control_port, "Replaced 3 occurrences across 2 files", "replace-all completion")
        report["accessibility"]["replaceAllDialog"] = replace_dialog
        report["states"]["replaceAll"] = replace_all
        report["checks"]["replaceAllConfirmed"] = True
        report["checks"]["replaceAllFocusRestored"] = True

        final_png = output_dir / f"{run_id}-09-final.png"
        final_ocr = output_dir / f"{run_id}-09-final.txt"
        capture_state(
            import_tool,
            tesseract,
            language,
            window,
            final_png,
            final_ocr,
            output_dir / f"{run_id}-09-final.stderr.log",
        )
        report["evidence"]["09-final"] = {"screenshot": final_png.name, "ocr": final_ocr.name}
        terminal_list = rpc.call("terminal/list")
        terminals = terminal_list.get("terminals") if isinstance(terminal_list, dict) else None
        if not isinstance(terminals, list) or not terminals:
            raise SmokeFailure(
                f"terminal/list did not retain a session for cleanup: {terminal_list!r}"
            )
        terminal_ids: list[int] = []
        for terminal in terminals:
            terminal_id = terminal.get("id") if isinstance(terminal, dict) else None
            if not isinstance(terminal_id, int) or terminal_id < 1 or terminal_id in terminal_ids:
                raise SmokeFailure(f"terminal/list returned an invalid terminal row: {terminal!r}")
            terminal_ids.append(terminal_id)
        killed_terminal_ids: list[int] = []
        for terminal_id in terminal_ids:
            killed = rpc.call("terminal/kill", {"id": terminal_id})
            if killed is not True:
                raise SmokeFailure(f"terminal/kill did not close terminal {terminal_id}: {killed!r}")
            killed_terminal_ids.append(terminal_id)
        deadline = time.monotonic() + 5.0
        terminal_after_cleanup: Any = None
        while time.monotonic() < deadline:
            terminal_after_cleanup = rpc.call("terminal/list")
            remaining_terminals = (
                terminal_after_cleanup.get("terminals")
                if isinstance(terminal_after_cleanup, dict)
                else None
            )
            if remaining_terminals == []:
                break
            time.sleep(0.1)
        if not isinstance(terminal_after_cleanup, dict) or terminal_after_cleanup.get("terminals") != []:
            raise SmokeFailure(
                f"Search terminal cleanup left backend sessions: {terminal_after_cleanup!r}"
            )
        wait_for_webview(
            args.control_port,
            """(() => {
                const terminals = Array.from(document.querySelectorAll('[data-terminal-status]'));
                return terminals.length > 0
                    && terminals.every((node) => ['exited', 'killed'].includes(
                        node.getAttribute('data-terminal-status') || ''
                    ));
            })()""",
            "Search terminal frontend poll shutdown",
            timeout=10.0,
        )
        report["terminalTeardown"] = {
            "initialCount": len(terminals),
            "initialIds": terminal_ids,
            "killedIds": killed_terminal_ids,
            "remaining": terminal_after_cleanup["terminals"],
        }
        report["checks"]["terminalSessionsClosed"] = True
        report["status"] = "passed"
        return 0
    except (OSError, SmokeFailure, subprocess.SubprocessError) as exc:
        report["errors"].append(str(exc))
        return 1
    finally:
        if permission_path is not None and permission_path.exists():
            os.chmod(permission_path, 0o644)
        report["cleanup"] = terminate_process_group(process, process_group)
        if stdout_handle is not None:
            stdout_handle.close()
        if stderr_handle is not None:
            stderr_handle.close()
        if stdout_path.exists() or stderr_path.exists():
            combine_console(stdout_path, stderr_path, console_path)
            report["console"] = console_path.name
        shutil.rmtree(profile_dir, ignore_errors=True)
        if isinstance(report.get("profile"), dict):
            report["profile"]["removedAfterRun"] = not profile_dir.exists()
        report["finishedAt"] = utc_now()
        promotion = retain_and_promote_report(output_dir, report, validate_report)
        if not promotion.promoted:
            print(
                f"native Search report retained without promotion: {promotion.retained_report}",
                file=sys.stderr,
            )
            for error in promotion.errors:
                print(f"- {error}", file=sys.stderr)


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
