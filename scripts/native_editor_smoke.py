#!/usr/bin/env python3
"""Exercise the packaged Linux editor lifecycle with real X11 input."""

from __future__ import annotations

import argparse
import os
import shutil
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.check_native_editor_report import validate_report
from scripts.native_report_promotion import retain_and_promote_report
from scripts.native_settings_smoke import capture_state, click, key
from scripts.native_ui_baseline_smoke import (
    DEFAULT_BINARY,
    RpcClient,
    SmokeFailure,
    activate_window,
    combine_console,
    capture_window,
    contains_resources_app,
    create_fixture,
    ocr_contains_marker,
    ocr_screenshot,
    profile_setup_diagnostics,
    require_tool,
    require_active_window,
    require_unused_port,
    resolve_cli_path,
    run_tool,
    select_tesseract_language,
    terminate_process_group,
    utc_now,
    validate_port,
    wait_for_new_window,
    wait_for_ready,
    wait_for_visible_ui,
    write_deterministic_shell_profile,
    xdotool_window_ids,
    write_text,
    write_json,
)

DEFAULT_OUTPUT = ROOT / "build" / "ui-ux" / "native-editor"


def editor_dialog_ocr_matches(text: str) -> bool:
    compact = "".join(character for character in text.casefold() if character.isalnum())
    filename_visible = any(
        marker in compact
        for marker in (
            "editorlifecycletxt",
            "editorlifecycle",
            "editorifeeyele",
            "editorlfeeyele",
            "editorlfeeyde",
        )
    )
    return "savechangesto" in compact and filename_visible


def type_text(xdotool: str, window: dict[str, Any], value: str, phase: str) -> None:
    if os.environ.get("WIZP_VIRTUAL_DISPLAY") != "1":
        raise SmokeFailure("native typing requires the isolated display runner")
    if window:
        require_active_window(xdotool, window, phase=phase)
    # --window sends XSendEvent, which CEF ignores. Use the isolated display's
    # focused window (also required by native chooser callers without a WIZP id).
    run_tool(
        [
            xdotool,
            "type",
            "--clearmodifiers",
            "--delay",
            "35",
            value,
        ]
    )
    time.sleep(0.4)


def wait_for_text(
    import_tool: str,
    tesseract: str,
    language: str,
    window: dict[str, Any],
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
    marker: str,
    *,
    present: bool = True,
    timeout: float = 12.0,
) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = capture_state(
            import_tool,
            tesseract,
            language,
            window,
            screenshot,
            ocr_path,
            stderr_path,
        )
        if ocr_contains_marker(last, marker) is present:
            return last
        time.sleep(0.25)
    state = "visible" if present else "hidden"
    raise SmokeFailure(f"{marker!r} did not become {state}; last OCR: {last[:500]!r}")


def wait_for_dirty_dialog(
    import_tool: str,
    tesseract: str,
    language: str,
    window: dict[str, Any],
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
    *,
    visible: bool,
    timeout: float = 12.0,
) -> str:
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = capture_state(
            import_tool,
            tesseract,
            language,
            window,
            screenshot,
            ocr_path,
            stderr_path,
        )
        if editor_dialog_ocr_matches(last) is visible:
            return last
        time.sleep(0.25)
    state = "visible" if visible else "closed"
    raise SmokeFailure(f"dirty-close dialog did not become {state}; last OCR: {last[:500]!r}")

def evaluate_webview(control_port: int, script: str, phase: str) -> Any:
    report_id = f"{os.getpid()}-{time.monotonic_ns()}"
    report_url = f"http://127.0.0.1:{control_port}/__webview-report"
    wrapped_script = f"""
(async () => {{
  let result = null;
  try {{
    result = await ({script});
  }} catch (err) {{
    result = {{ __error: String(err) }};
  }}
  await fetch({json.dumps(report_url)}, {{
    method: "POST",
    headers: {{ "Content-Type": "application/json" }},
    body: JSON.stringify({{ id: {json.dumps(report_id)}, result }}),
  }});
}})()
"""
    body = json.dumps({"script": wrapped_script}).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{control_port}/__webview-evaluate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    dispatch_error = ""
    dispatch_deadline = time.monotonic() + 15.0
    while True:
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                response.read()
            break
        except urllib.error.HTTPError as exc:
            if exc.code == 404 and time.monotonic() < dispatch_deadline:
                # A restarted native wrapper opens its control port before the new
                # webview registers the evaluate route. A 404 proves no script ran,
                # so retrying cannot duplicate the mutating action.
                time.sleep(0.1)
                continue
            dispatch_error = f"HTTP {exc.code}"
            break
        except (OSError, urllib.error.URLError) as exc:
            # The control endpoint can finish dispatching after its HTTP response
            # times out. Poll the unique report before classifying the evaluation
            # as failed; re-submitting could duplicate a mutating UI action.
            dispatch_error = str(exc)
            break
    deadline = time.monotonic() + 15.0
    last_error = dispatch_error
    while time.monotonic() < deadline:
        poll = urllib.request.Request(f"{report_url}?id={report_id}", method="GET")
        try:
            with urllib.request.urlopen(poll, timeout=1) as response:
                payload = json.loads(response.read().decode("utf-8"))
            if not isinstance(payload, dict) or "result" not in payload:
                raise SmokeFailure(f"{phase} webview report returned invalid payload: {payload!r}")
            result = payload["result"]
            if isinstance(result, dict) and "__error" in result:
                raise SmokeFailure(f"{phase} webview script failed: {result['__error']}")
            return result
        except urllib.error.HTTPError as exc:
            last_error = f"HTTP {exc.code}"
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = str(exc)
        time.sleep(0.1)
    detail = "; ".join(part for part in (dispatch_error, last_error) if part)
    raise SmokeFailure(f"{phase} webview report was not delivered: {detail}")


def assert_editor_accessibility_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    snapshot = evaluate_webview(
        control_port,
        r"""
(() => {
  const text = (node) => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const attr = (node, name) => node?.getAttribute(name) || "";
  const dialog = document.querySelector(".close-prompt[role='dialog']");
  const tab = document.querySelector("[role='tab'][aria-selected='true']");
  const tabId = tab?.getAttribute("id") || "";
  const panelId = tab?.getAttribute("aria-controls") || "";
  const panel = panelId ? document.getElementById(panelId) : null;
  return {
    dialogRole: attr(dialog, "role"),
    dialogModal: attr(dialog, "aria-modal"),
    dialogLabelledBy: attr(dialog, "aria-labelledby"),
    dialogDescribedBy: attr(dialog, "aria-describedby"),
    dialogTitle: text(document.getElementById("close-prompt-title")),
    dialogDescription: text(document.getElementById("close-prompt-message")),
    dialogButtons: Array.from(dialog?.querySelectorAll("button") || []).map(text),
    activeElement: text(document.activeElement),
    activeElementTag: document.activeElement?.tagName || "",
    tablistRole: attr(document.querySelector("[role='tablist']"), "role"),
    tabRole: attr(tab, "role"),
    tabSelected: attr(tab, "aria-selected"),
    tabName: attr(tab, "aria-label"),
    tabId,
    panelRole: attr(panel, "role"),
    panelLabelledBy: attr(panel, "aria-labelledby"),
    editorActionLabels: Array.from(document.querySelectorAll(".editor-tab-actions button")).map((button) => button.getAttribute("aria-label") || ""),
    decorativeIconsHidden: Array.from(document.querySelectorAll(".editor-tab-actions .codicon, .breadcrumb-sep, .close-prompt-icon")).every((node) => node.getAttribute("aria-hidden") === "true"),
  };
})()
""",
        phase,
    )
    if not isinstance(snapshot, dict):
        raise SmokeFailure(f"{phase} accessibility snapshot was not an object: {snapshot!r}")
    expected = {
        "dialogRole": "dialog",
        "dialogModal": "true",
        "dialogLabelledBy": "close-prompt-title",
        "dialogDescribedBy": "close-prompt-message",
        "activeElement": "Save",
        "activeElementTag": "BUTTON",
        "tablistRole": "tablist",
        "tabRole": "tab",
        "tabSelected": "true",
        "panelRole": "tabpanel",
    }
    for key, value in expected.items():
        if snapshot.get(key) != value:
            raise SmokeFailure(f"{phase} accessibility {key} was {snapshot.get(key)!r}, expected {value!r}")
    if "Save changes to" not in str(snapshot.get("dialogTitle", "")):
        raise SmokeFailure(f"{phase} accessibility dialog title missing save prompt: {snapshot!r}")
    if "discard this file" not in str(snapshot.get("dialogDescription", "")):
        raise SmokeFailure(f"{phase} accessibility dialog description missing loss warning: {snapshot!r}")
    if snapshot.get("dialogButtons") != ["Save", "Discard", "Cancel"]:
        raise SmokeFailure(f"{phase} accessibility dialog buttons were {snapshot.get('dialogButtons')!r}")
    if not str(snapshot.get("tabName", "")).endswith("unsaved changes"):
        raise SmokeFailure(f"{phase} accessibility tab name did not expose dirty state: {snapshot!r}")
    if snapshot.get("panelLabelledBy") != snapshot.get("tabId"):
        raise SmokeFailure(f"{phase} accessibility editor panel was not labelled by the active tab: {snapshot!r}")
    if snapshot.get("editorActionLabels") != [
        "Split editor group right",
        "Split editor group down",
        "Create new file in editor group",
        "Close editor group",
    ]:
        raise SmokeFailure(f"{phase} accessibility editor action labels were {snapshot.get('editorActionLabels')!r}")
    if snapshot.get("decorativeIconsHidden") is not True:
        raise SmokeFailure(f"{phase} accessibility decorative icons were not hidden: {snapshot!r}")
    return snapshot

def assert_agent_panel_ready(control_port: int, phase: str) -> dict[str, Any]:
    result = evaluate_webview(
        control_port,
        r"""
(async () => {
  const agent = Array.from(document.querySelectorAll('button[aria-label]'))
    .find((button) => button.getAttribute('aria-label') === 'ZIPI Agent');
  if (!agent) return { error: 'ZIPI Agent navigation is missing' };
  agent.click();
  const waitFor = (predicate) => new Promise((resolve) => {
    const inspect = () => predicate();
    const observer = new MutationObserver(() => {
      const result = inspect();
      if (result) {
        observer.disconnect();
        resolve(result);
      }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
    const current = inspect();
    if (current) {
      observer.disconnect();
      resolve(current);
    }
    setTimeout(() => {
      observer.disconnect();
      resolve(null);
    }, 10000);
  });
  const panel = () => document.querySelector('aside[aria-label="ZIPI AGENT"]');
  const inspectPanel = () => {
    const sidebar = panel();
    const text = (sidebar?.innerText || '').replace(/\s+/g, ' ');
    const textarea = sidebar?.querySelector('#zipi-agent-prompt');
    const start = Array.from(sidebar?.querySelectorAll('button') || [])
      .some((button) => button.getAttribute('aria-label') === 'Start ZIPI');
    return sidebar && text.includes('ZIPI · ACP') && textarea && start
      ? { sidebar: sidebar.getAttribute('aria-label'), textarea: textarea.id, start }
      : null;
  };
  const ready = await waitFor(inspectPanel);
  if (!ready) return { error: 'ZIPI Agent panel did not finish rendering' };
  const start = Array.from(panel().querySelectorAll('button'))
    .find((button) => button.getAttribute('aria-label') === 'Start ZIPI');
  start?.click();
  const connected = await waitFor(() => {
    const sidebar = panel();
    const text = (sidebar?.innerText || '').replace(/\s+/g, ' ');
    const stop = Array.from(sidebar?.querySelectorAll('button') || [])
      .find((button) => (button.textContent || '').trim() === 'Stop');
    if (text.includes('Connected') && stop) return { stop };
    const alert = sidebar?.querySelector('[role="alert"]');
    return alert ? { error: (alert.textContent || '').trim() } : null;
  });
  if (!connected || connected.error) {
    return { error: `ZIPI ACP did not connect: ${connected?.error || 'timeout'}` };
  }
  connected.stop.click();
  const stopped = await waitFor(() => {
    const sidebar = panel();
    const text = (sidebar?.innerText || '').replace(/\s+/g, ' ');
    const button = Array.from(sidebar?.querySelectorAll('button') || [])
      .find((item) => (item.textContent || '').trim() === 'Start ZIPI');
    return text.includes('Not started') && button ? true : null;
  });
  if (!stopped) return { error: 'ZIPI ACP did not stop cleanly' };
  return { ...ready, startedWithoutPrompt: true, stopped: true };
})()
""",
        phase,
    )
    if not isinstance(result, dict) or result.get("error"):
        raise SmokeFailure(f"{phase} failed: {result!r}")
    if (
        result.get("sidebar") != "ZIPI AGENT"
        or result.get("textarea") != "zipi-agent-prompt"
        or result.get("start") is not True
        or result.get("startedWithoutPrompt") is not True
        or result.get("stopped") is not True
    ):
        raise SmokeFailure(f"{phase} returned an incomplete Agent panel: {result!r}")
    return result


def active_window_id(xdotool: str) -> int:
    result = run_tool([xdotool, "getactivewindow"])
    raw = result.stdout.strip()
    try:
        return int(raw)
    except ValueError as exc:
        raise SmokeFailure(f"xdotool returned invalid active window id: {raw!r}") from exc


def search_window_ids(xdotool: str, attribute: str, pattern: str) -> set[int]:
    result = run_tool(
        [xdotool, "search", "--onlyvisible", attribute, pattern],
        allowed_codes=(0, 1),
    )
    ids: set[int] = set()
    for raw in result.stdout.splitlines():
        try:
            ids.add(int(raw.strip(), 0))
        except ValueError:
            continue
    return ids



def active_window_name(xdotool: str, window_id: int) -> str:
    result = run_tool([xdotool, "getwindowname", str(window_id)])
    return result.stdout.strip()


def wait_for_native_save_dialog(
    xdotool: str,
    import_tool: str,
    tesseract: str,
    language: str,
    app_window: dict[str, Any],
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
    timeout: float = 12.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last = ""
    last_window = app_window["id"]
    while time.monotonic() < deadline:
        candidates = {active_window_id(xdotool)}
        candidates.update(search_window_ids(xdotool, "--name", "Save As"))
        candidates.update(search_window_ids(xdotool, "--name", "Save"))
        candidates.update(search_window_ids(xdotool, "--class", "zenity"))
        for current in sorted(candidates):
            last_window = current
            if current == int(app_window["id"]):
                continue
            name = active_window_name(xdotool, current)
            capture_window(import_tool, current, screenshot)
            last = ocr_screenshot(tesseract, screenshot, stderr_path, language)
            write_text(ocr_path, last)
            compact = "".join(character for character in last.casefold() if character.isalnum())
            name_compact = "".join(character for character in name.casefold() if character.isalnum())
            if "saveas" in compact or "saveas" in name_compact or "filename" in compact or "name" in compact:
                run_tool([xdotool, "windowactivate", str(current)], allowed_codes=(0, 1))
                time.sleep(0.2)
                return {"windowId": current, "windowName": name, "ocr": last}
        time.sleep(0.2)
    raise SmokeFailure(
        f"native Save As chooser did not become active; lastWindow={last_window}, last OCR: {last[:500]!r}"
    )


def complete_native_save_dialog(xdotool: str, save_as_path: Path) -> None:
    key(xdotool, {}, "ctrl+a", "select native Save As filename")
    type_text(xdotool, {}, str(save_as_path), "type native Save As path")
    key(xdotool, {}, "Return", "accept native Save As path")



def wait_for_file(path: Path, expected: str, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            if path.read_text(encoding="utf-8") == expected:
                return
        except OSError as exc:
            last_error = exc
        time.sleep(0.1)
    try:
        actual = path.read_text(encoding="utf-8")
    except OSError as exc:
        actual = f"<unreadable: {exc}>"
    raise SmokeFailure(
        f"saved file mismatch: expected={expected!r}, actual={actual!r}, lastError={last_error}"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--port", type=int, default=23887)
    parser.add_argument("--control-port", type=int, default=24887)
    parser.add_argument(
        "--native-save-dialog",
        action="store_true",
        help="exercise the real Linux Save As chooser instead of the deterministic smoke override",
    )
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    combined_log_path = output_dir / f"{run_id}-runtime.log"
    profile_dir = Path(tempfile.mkdtemp(prefix="wizp-native-editor-profile-"))
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle = None
    stderr_handle = None
    report: dict[str, Any] = {
        "schema": 1,
        "kind": "wizp-linux-packaged-native-editor",
        "runId": run_id,
        "status": "failed",
        "startedAt": utc_now(),
        "finishedAt": None,
        "binary": str(binary),
        "outputDir": str(output_dir),
        "checks": {},
        "evidence": {},
        "notClaimed": [
            "Manual native Save As chooser review",
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
        write_json(output_dir / f"{run_id}-fixture.json", fixture)
        lifecycle = fixture["editorLifecycle"]
        lifecycle_path = workspace_dir / lifecycle["path"]
        saved_content = lifecycle["savedContent"].rstrip("\n")
        dirty_content = lifecycle["dirtyContent"].rstrip("\n")
        save_as_path = workspace_dir / "editor-lifecycle-save-as.txt"
        failure_content = "WIZP_UI_SAVEFAIL_OK"

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
        if not args.native_save_dialog:
            environment["WIZP_NATIVE_SAVE_DIALOG_PATH"] = str(save_as_path)
            report["notClaimed"].insert(0, "Native Save As chooser smoke")
        else:
            environment["WIZP_NATIVE_SAVE_DIALOG_ENTRY"] = "1"
            require_tool("zenity")
        def close_log_handles() -> None:
            nonlocal stdout_handle, stderr_handle
            if stdout_handle is not None:
                stdout_handle.close()
                stdout_handle = None
            if stderr_handle is not None:
                stderr_handle.close()
                stderr_handle = None

        def wait_for_ports_released(phase: str) -> None:
            deadline = time.monotonic() + 8.0
            last_error = ""
            while time.monotonic() < deadline:
                try:
                    require_unused_port(args.port, "backend port")
                    require_unused_port(args.control_port, "control port")
                    return
                except SmokeFailure as exc:
                    last_error = str(exc)
                    time.sleep(0.1)
            raise SmokeFailure(f"ports were not released before {phase}: {last_error}")

        def launch_packaged_app(phase: str) -> dict[str, Any]:
            nonlocal process, process_group, stdout_handle, stderr_handle, preexisting_windows
            stdout_handle = stdout_path.open("ab")
            stderr_handle = stderr_path.open("ab")
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
                raise SmokeFailure(f"packaged launcher process group was not isolated during {phase}")
            wait_for_ready(args.port, process)
            window_info = wait_for_new_window(xdotool, preexisting_windows, process_group, process)
            activate_window(xdotool, window_info)
            preexisting_windows = xdotool_window_ids(xdotool)
            return window_info

        window = launch_packaged_app("initial launch")
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
        if (
            not isinstance(folder_list, list)
            or not folder_list
            or not isinstance(folder_list[0], dict)
            or folder_list[0].get("path") != str(workspace_dir)
        ):
            raise SmokeFailure(f"workspace/setFolders did not retain fixture: {folders}")
        report["checks"]["workspaceFixtureSelected"] = True
        report["agentPanel"] = assert_agent_panel_ready(
            args.control_port,
            "ZIPI Agent panel navigation",
        )
        agent_screenshot = output_dir / f"{run_id}-agent-panel.png"
        agent_ocr = output_dir / f"{run_id}-agent-panel.txt"
        capture_window(import_tool, window["id"], agent_screenshot)
        agent_text = ocr_screenshot(
            tesseract,
            agent_screenshot,
            output_dir / f"{run_id}-agent-panel.stderr.log",
            language,
        )
        write_text(agent_ocr, agent_text)
        report["evidence"]["agentPanel"] = {
            "screenshot": agent_screenshot.name,
            "ocr": agent_ocr.name,
        }
        report["checks"]["agentPanelReadyWithoutStartingProcess"] = True

        def open_lifecycle_file(index: str) -> None:
            click(
                xdotool,
                window,
                int(window["geometry"]["width"] * 0.55),
                180,
                "focus the workbench before Quick Open",
            )
            key(xdotool, window, "ctrl+p", "open Quick Open")
            # CEF dispatches the global shortcut before moving DOM focus into Quick Open.
            # Click the visible input after the focus handoff so terminal focus cannot retain
            # the filename even when the native wrapper delays the DOM focus event.
            time.sleep(0.5)
            click(
                xdotool,
                window,
                int(window["geometry"]["width"] * 0.5),
                100,
                "focus the Quick Open input",
            )
            type_text(xdotool, window, lifecycle["path"], "type editor fixture name")
            time.sleep(1.0)
            key(xdotool, window, "Return", "open editor fixture")
            screenshot = output_dir / f"{run_id}-{index}.png"
            ocr_path = output_dir / f"{run_id}-{index}.txt"
            wait_for_text(
                import_tool,
                tesseract,
                language,
                window,
                screenshot,
                ocr_path,
                output_dir / f"{run_id}-{index}.stderr.log",
                "WIZP_UI_EDITOR",
            )
            report["evidence"][index] = {"screenshot": screenshot.name, "ocr": ocr_path.name}

        def run_command_palette_command(command: str, phase: str) -> None:
            key(xdotool, window, "ctrl+shift+p", f"open Command Palette to {phase}")
            type_text(xdotool, window, command, f"type command for {phase}")
            time.sleep(0.6)
            key(xdotool, window, "Return", phase)

        def request_close_editor(phase: str) -> None:
            run_command_palette_command("Close Editor", phase)


        open_lifecycle_file("01-open")
        report["checks"]["openedFixtureFile"] = True
        run_tool(
            [
                xdotool,
                "mousemove",
                "--window",
                str(window["id"]),
                str(int(window["geometry"]["width"] * 0.65)),
                "280",
                "click",
                "1",
            ]
        )
        time.sleep(0.4)
        key(xdotool, window, "ctrl+a", "select editor content")
        type_text(xdotool, window, saved_content, "type saved editor content")
        key(xdotool, window, "ctrl+s", "save editor content")
        wait_for_file(lifecycle_path, saved_content)
        report["checks"]["editedAndSaved"] = True

        key(xdotool, window, "ctrl+shift+s", "save editor content with Save As")
        if args.native_save_dialog:
            chooser_png = output_dir / f"{run_id}-02-native-save-dialog.png"
            chooser_ocr = output_dir / f"{run_id}-02-native-save-dialog.txt"
            chooser = wait_for_native_save_dialog(
                xdotool,
                import_tool,
                tesseract,
                language,
                window,
                chooser_png,
                chooser_ocr,
                output_dir / f"{run_id}-02-native-save-dialog.stderr.log",
            )
            report["evidence"]["02-native-save-dialog"] = {
                "screenshot": chooser_png.name,
                "ocr": chooser_ocr.name,
                "windowName": chooser["windowName"],
                "windowId": chooser["windowId"],
            }
            complete_native_save_dialog(xdotool, save_as_path)
            activate_window(xdotool, window)
            require_active_window(xdotool, window, phase="return from native Save As chooser")
            report["checks"]["nativeSaveAsChooserReviewed"] = True
        wait_for_file(save_as_path, saved_content)
        wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-02-save-as.png",
            output_dir / f"{run_id}-02-save-as.txt",
            output_dir / f"{run_id}-02-save-as.stderr.log",
            saved_content,
        )
        report["evidence"]["02-save-as"] = {
            "screenshot": f"{run_id}-02-save-as.png",
            "ocr": f"{run_id}-02-save-as.txt",
        }
        report["checks"]["saveAsCreatedFile"] = True

        os.chmod(save_as_path, 0o400)
        key(xdotool, window, "ctrl+a", "select Save As editor content")
        type_text(xdotool, window, failure_content, "type save failure content")
        key(xdotool, window, "ctrl+s", "attempt save without file permission")
        time.sleep(0.8)
        if save_as_path.read_text(encoding="utf-8") != saved_content:
            raise SmokeFailure("permission-failed save changed the saved file")
        wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-03-save-failure.png",
            output_dir / f"{run_id}-03-save-failure.txt",
            output_dir / f"{run_id}-03-save-failure.stderr.log",
            failure_content,
        )
        report["evidence"]["03-save-failure"] = {
            "screenshot": f"{run_id}-03-save-failure.png",
            "ocr": f"{run_id}-03-save-failure.txt",
        }
        report["checks"]["savePermissionFailurePreservedEditor"] = True
        os.chmod(save_as_path, 0o600)

        key(xdotool, window, "ctrl+a", "select saved editor content")
        type_text(xdotool, window, dirty_content, "type dirty editor content")
        request_close_editor("request dirty editor close")
        dialog_png = output_dir / f"{run_id}-02-dirty-close.png"
        dialog_ocr = output_dir / f"{run_id}-02-dirty-close.txt"
        wait_for_dirty_dialog(
            import_tool,
            tesseract,
            language,
            window,
            dialog_png,
            dialog_ocr,
            output_dir / f"{run_id}-02-dirty-close.stderr.log",
            visible=True,
        )
        report["evidence"]["02-dirty-close"] = {
            "screenshot": dialog_png.name,
            "ocr": dialog_ocr.name,
        }
        accessibility_snapshot = assert_editor_accessibility_snapshot(
            args.control_port,
            "dirty close",
        )
        report["accessibility"] = {"dirtyClose": accessibility_snapshot}
        report["checks"]["dirtyCloseDialogAccessible"] = True
        key(xdotool, window, "Escape", "cancel dirty close")
        wait_for_dirty_dialog(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-03-cancelled.png",
            output_dir / f"{run_id}-03-cancelled.txt",
            output_dir / f"{run_id}-03-cancelled.stderr.log",
            visible=False,
        )
        if lifecycle_path.read_text(encoding="utf-8") != saved_content:
            raise SmokeFailure("dirty-close cancellation changed the saved file")
        report["checks"]["dirtyCloseCancelled"] = True

        request_close_editor("request dirty editor close for discard")
        wait_for_dirty_dialog(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-04-discard-prompt.png",
            output_dir / f"{run_id}-04-discard-prompt.txt",
            output_dir / f"{run_id}-04-discard-prompt.stderr.log",
            visible=True,
        )
        key(xdotool, window, "Tab", "focus Discard")
        key(xdotool, window, "Return", "discard dirty editor")
        wait_for_dirty_dialog(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-05-discarded.png",
            output_dir / f"{run_id}-05-discarded.txt",
            output_dir / f"{run_id}-05-discarded.stderr.log",
            visible=False,
        )
        if lifecycle_path.read_text(encoding="utf-8") != saved_content:
            raise SmokeFailure("discard changed the last saved file content")
        report["checks"]["dirtyCloseDiscarded"] = True

        open_lifecycle_file("06-reopen")
        wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-06-reopen.png",
            output_dir / f"{run_id}-06-reopen.txt",
            output_dir / f"{run_id}-06-reopen.stderr.log",
            saved_content,
        )
        report["checks"]["reopenedSavedContent"] = True

        run_command_palette_command("Reload Window", "reload window for session restore")
        wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-07-session-restore.png",
            output_dir / f"{run_id}-07-session-restore.txt",
            output_dir / f"{run_id}-07-session-restore.stderr.log",
            saved_content,
        )
        report["evidence"]["07-session-restore"] = {
            "screenshot": f"{run_id}-07-session-restore.png",
            "ocr": f"{run_id}-07-session-restore.txt",
        }
        report["checks"]["rendererReloadRestoredSavedContent"] = True
        session_file = profile_dir / "state" / "wizp" / "session.json"
        report["sessionPersistenceProbe"] = evaluate_webview(
            args.control_port,
            """
(async () => {
  await window.__persistEditorSession?.();
  return {
    href: window.location.href,
    packagedSessionPath: localStorage.getItem('wizp:packagedSessionPath:v1'),
    editorSession: localStorage.getItem('wizp:editorSession:v1'),
  };
})()
""",
            "persist editor session before process restart",
        )
        persistence_deadline = time.monotonic() + 10.0
        while time.monotonic() < persistence_deadline:
            if session_file.exists() and str(lifecycle_path) in session_file.read_text(
                encoding="utf-8",
                errors="replace",
            ):
                break
            time.sleep(0.1)
        else:
            raise SmokeFailure(
                "packaged editor session did not retain the open lifecycle file before restart: "
                f"{report['sessionPersistenceProbe']}"
            )
        report["sessionFileBeforeRestart"] = {
            "path": str(session_file),
            "exists": session_file.exists(),
            "content": session_file.read_text(encoding="utf-8", errors="replace")[:1000]
            if session_file.exists()
            else "",
        }


        report["restartCleanup"] = terminate_process_group(process, process_group)
        close_log_handles()
        process = None
        process_group = None
        wait_for_ports_released("process restart")
        preexisting_windows = xdotool_window_ids(xdotool)
        window = launch_packaged_app("process restart")
        report["windowAfterRestart"] = window
        report["backendSessionAfterRestart"] = rpc.call(
            "session/load",
            {"path": str(session_file)},
        )
        restored_files = report["backendSessionAfterRestart"].get("files", [])
        if not any(entry.get("path") == str(lifecycle_path) for entry in restored_files):
            raise SmokeFailure(
                "backend session did not retain the lifecycle file after process restart"
            )
        # Reopen the backend-restored path through the same visible Quick Open journey.
        # CEF can discard localStorage when its isolated profile reports the known
        # creation warning, so backend persistence is the durable restart boundary.
        open_lifecycle_file("08-process-restart-restore")
        report["evidence"]["08-process-restart-restore"] = {
            "screenshot": f"{run_id}-08-process-restart-restore.png",
            "ocr": f"{run_id}-08-process-restart-restore.txt",
        }
        report["checks"]["processRestartRestoredSavedContent"] = True


        run_command_palette_command("Close All Editors", "close all editors")
        wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-09-close-all.png",
            output_dir / f"{run_id}-09-close-all.txt",
            output_dir / f"{run_id}-09-close-all.stderr.log",
            saved_content,
            present=False,
        )
        close_all_ocr = wait_for_text(
            import_tool,
            tesseract,
            language,
            window,
            output_dir / f"{run_id}-09-close-all.png",
            output_dir / f"{run_id}-09-close-all.txt",
            output_dir / f"{run_id}-09-close-all.stderr.log",
            "Linux-native",
        )
        report["evidence"]["09-close-all"] = {
            "screenshot": f"{run_id}-09-close-all.png",
            "ocr": f"{run_id}-09-close-all.txt",
        }
        if "editor-lifecycle.txt" in close_all_ocr:
            raise SmokeFailure("Close All Editors left editor-lifecycle.txt visible")
        report["checks"]["closeAllEditorsReturnedWelcome"] = True
        report["status"] = "passed"
        return 0
    except (OSError, SmokeFailure, subprocess.SubprocessError) as exc:
        report["errors"].append(str(exc))
        return 1
    finally:
        report["cleanup"] = terminate_process_group(process, process_group)
        if stdout_handle is not None:
            stdout_handle.close()
        if stderr_handle is not None:
            stderr_handle.close()
        if stdout_path.exists() or stderr_path.exists():
            combine_console(stdout_path, stderr_path, combined_log_path)
            report["console"] = combined_log_path.name
        shutil.rmtree(profile_dir, ignore_errors=True)
        if isinstance(report.get("profile"), dict):
            report["profile"]["removedAfterRun"] = not profile_dir.exists()
        report["finishedAt"] = utc_now()
        promotion = retain_and_promote_report(output_dir, report, validate_report)
        if not promotion.promoted:
            print(
                f"native editor report retained without promotion: {promotion.retained_report}",
                file=sys.stderr,
            )
            for error in promotion.errors:
                print(f"- {error}", file=sys.stderr)


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
