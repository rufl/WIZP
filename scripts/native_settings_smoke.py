#!/usr/bin/env python3
"""Exercise the packaged Linux Settings dialog with real X11 input."""

from __future__ import annotations

import argparse
import json
import os
import shutil
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

from scripts.check_native_settings_report import validate_report
from scripts.native_report_promotion import retain_and_promote_report
from scripts.native_ui_baseline_smoke import (
    DEFAULT_BINARY,
    RpcClient,
    SmokeFailure,
    activate_window,
    capture_window,
    combine_console,
    contains_resources_app,
    create_fixture,
    ocr_screenshot,
    profile_setup_diagnostics,
    require_active_window,
    require_tool,
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
    write_json,
    write_text,
    xdotool_window_ids,
)

DEFAULT_OUTPUT = ROOT / "build" / "ui-ux" / "native-settings"


def normalized(text: str) -> str:
    return " ".join(text.casefold().split())


def dialog_ocr_matches(text: str) -> bool:
    compact = "".join(character for character in normalized(text) if character.isalnum())
    field_visible = "font" in compact or "fort" in compact
    section_visible = any(
        marker in compact
        for marker in (
            "appearance",
            "apperrance",
            "colortheme",
            "tabsize",
            "wordwrapcolumn",
            "wordwrapcolamn",
        )
    )
    return (
        "settings" in compact
        and field_visible
        and section_visible
        and "loadingsettings" not in compact
    )


def click(xdotool: str, window: dict[str, Any], x: int, y: int, phase: str) -> None:
    activate_window(xdotool, window)
    require_active_window(xdotool, window, phase=phase)
    run_tool(
        [
            xdotool,
            "mousemove",
            "--window",
            str(window["id"]),
            str(x),
            str(y),
            "click",
            "1",
        ]
    )
    time.sleep(0.75)


def key(xdotool: str, _window: dict[str, Any], value: str, _phase: str) -> None:
    run_tool([xdotool, "key", "--clearmodifiers", value])
    time.sleep(0.2)


def dialog_geometry(window: dict[str, Any]) -> dict[str, int | float]:
    viewport_width = int(window["geometry"]["width"])
    viewport_height = int(window["geometry"]["height"])
    scale = 1.0
    dialog_width_css = min(620, viewport_width)
    dialog_height_css = min(int(viewport_height * 0.8), 760)
    left_css = (viewport_width - dialog_width_css) // 2
    top_css = (viewport_height - dialog_height_css) // 2
    dialog_width = dialog_width_css
    dialog_height = dialog_height_css
    left = left_css
    top = top_css
    return {
        "left": left,
        "top": top,
        "width": dialog_width,
        "height": dialog_height,
        "cancelX": round((left_css + dialog_width_css - 174) * scale),
        "saveX": round((left_css + dialog_width_css - 74) * scale),
        "footerY": round((top_css + dialog_height_css - 32) * scale),
        "mainX": round(viewport_width * 0.47 * scale),
        "mainY": round(min(160, viewport_height // 3) * scale),
        "scale": round(scale, 3),
    }


def capture_state(
    import_tool: str,
    tesseract: str,
    language: str,
    window: dict[str, Any],
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
) -> str:
    capture_window(import_tool, window["id"], screenshot)
    text = ocr_screenshot(tesseract, screenshot, stderr_path, language)
    write_text(ocr_path, text)
    return text


def wait_for_dialog(
    control_port: int,
    import_tool: str,
    tesseract: str,
    language: str,
    window: dict[str, Any],
    screenshot: Path,
    ocr_path: Path,
    stderr_path: Path,
    *,
    visible: bool,
    timeout: float = 15.0,
) -> str:
    wait_for_settings_dom(control_port, visible=visible, timeout=timeout)
    return capture_state(
        import_tool,
        tesseract,
        language,
        window,
        screenshot,
        ocr_path,
        stderr_path,
    )


def capture_font_value(
    convert: str,
    tesseract: str,
    language: str,
    screenshot: Path,
    crop_path: Path,
    ocr_path: Path,
    stderr_path: Path,
    geometry: dict[str, int | float],
) -> str:
    scale = float(geometry["scale"])
    crop_x = geometry["left"] + int(24 * scale)
    crop_y = geometry["top"] + int(196 * scale)
    crop_width = int(100 * scale)
    crop_height = int(36 * scale)
    run_tool(
        [
            convert,
            str(screenshot),
            "-crop",
            f"{crop_width}x{crop_height}+{crop_x}+{crop_y}",
            "+repage",
            "-resize",
            "300%",
            "-colorspace",
            "Gray",
            "-negate",
            str(crop_path),
        ]
    )
    result = run_tool(
        [
            tesseract,
            str(crop_path),
            "stdout",
            "-l",
            language,
            "--psm",
            "13",
            "-c",
            "tessedit_char_whitelist=0123456789",
        ]
    )
    write_text(stderr_path, result.stderr)
    text = result.stdout
    write_text(ocr_path, text)
    return text


def evaluate_webview(control_port: int, script: str, phase: str) -> Any:
    report_id = f"{os.getpid()}-{time.monotonic_ns()}"
    report_url = f"http://127.0.0.1:{control_port}/__webview-report"
    wrapped_script = f"""
(async () => {{
  try {{
    const result = await (async () => {{ return await ({script}); }})();
    await fetch({json.dumps(report_url)}, {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify({{ id: {json.dumps(report_id)}, result }}),
    }});
  }} catch (error) {{
    await fetch({json.dumps(report_url)}, {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify({{ id: {json.dumps(report_id)}, result: {{ __error: String(error?.stack || error) }} }}),
    }});
  }}
}})()
"""
    body = json.dumps({"script": wrapped_script}).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{control_port}/__webview-evaluate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            response.read()
    except (OSError, urllib.error.URLError) as exc:
        raise SmokeFailure(f"{phase} webview evaluation failed: {exc}") from exc
    deadline = time.monotonic() + 5.0
    last_error = ""
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
    raise SmokeFailure(f"{phase} webview report was not delivered: {last_error}")


def inject_one_shot_config_set_failure(
    control_port: int,
    key: str,
    phase: str,
) -> dict[str, Any]:
    result = evaluate_webview(
        control_port,
        r"""
((targetKey) => {
  const originalFetch = window.fetch.bind(window);
  const state = { armed: true, key: targetKey, matched: 0 };
  window.__wizpNativeSettingsFailure = state;
  window.fetch = (input, init) => {
    const url = typeof input === "string" ? input : input?.url || "";
    if (url.endsWith("/api/rpc") && typeof init?.body === "string") {
      try {
        const request = JSON.parse(init.body);
        if (
          state.armed &&
          request?.method === "config/set" &&
          request?.params?.key === targetKey
        ) {
          state.armed = false;
          state.matched += 1;
          window.fetch = originalFetch;
          return Promise.reject(new Error(`Injected one-shot config/set failure for ${targetKey}`));
        }
      } catch {
        // Non-JSON requests are unrelated to the RPC fault injection.
      }
    }
    return originalFetch(input, init);
  };
  return { armed: state.armed, key: state.key, matched: state.matched };
})
""" + f"({json.dumps(key)})",
        phase,
    )
    if not isinstance(result, dict):
        raise SmokeFailure(f"{phase} returned invalid injection state: {result!r}")
    if result != {"armed": True, "key": key, "matched": 0}:
        raise SmokeFailure(f"{phase} did not arm the expected one-shot failure: {result!r}")
    return result


def wait_for_settings_sync_warning(
    control_port: int,
    expected_font_size: str,
    *,
    timeout: float = 10.0,
) -> dict[str, Any]:
    expected_message = (
        "Saved locally, but 1 preference could not sync: font size. "
        "Retry when the backend is available."
    )
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        last = evaluate_webview(
            control_port,
            r"""
(() => {
  const text = (node) => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const status = document.querySelector(".settings-save-status");
  const saveButton = Array.from(document.querySelectorAll(".settings-footer button"))
    .find((node) => ["Retry Save", "Saving…"].includes(text(node)));
  let storedFontSize = null;
  try {
    storedFontSize = JSON.parse(localStorage.getItem("wizp-settings") || "{}").fontSize ?? null;
  } catch {
    storedFontSize = "invalid-json";
  }
  const injection = window.__wizpNativeSettingsFailure || null;
  return {
    dialogVisible: Boolean(document.getElementById("settings-dialog")),
    message: text(status),
    messageRole: status?.getAttribute("role") || "",
    messageLive: status?.getAttribute("aria-live") || "",
    saveButton: text(saveButton),
    saveButtonDisabled: Boolean(saveButton?.disabled),
    activeElement: text(document.activeElement) || document.activeElement?.getAttribute("aria-label") || "",
    activeElementTag: document.activeElement?.tagName || "",
    activeInsideDialog: document.getElementById("settings-dialog")?.contains(document.activeElement) || false,
    inputFontSize: document.getElementById("settings-fontsize")?.value ?? null,
    storedFontSize,
    injectedKey: injection?.key ?? null,
    injectedCount: injection?.matched ?? null,
    injectionArmed: injection?.armed ?? null,
  };
})()
""",
            "Settings partial-sync warning",
        )
        if (
            isinstance(last, dict)
            and last.get("dialogVisible") is True
            and last.get("saveButton") == "Retry Save"
            and last.get("saveButtonDisabled") is False
            and last.get("activeElement") == "Retry Save"
            and last.get("activeElementTag") == "BUTTON"
            and last.get("activeInsideDialog") is True
            and last.get("inputFontSize") == expected_font_size
            and str(last.get("storedFontSize")) == expected_font_size
            and last.get("injectedKey") == "editor.fontSize"
            and last.get("injectedCount") == 1
            and last.get("injectionArmed") is False
            and last.get("messageRole") == "alert"
            and last.get("messageLive") == "assertive"
            and last.get("message") == expected_message
        ):
            return last
        time.sleep(0.2)
    raise SmokeFailure(f"Settings partial-sync warning did not reach the expected state: {last!r}")

def wait_for_settings_dom(
    control_port: int,
    *,
    visible: bool,
    timeout: float = 10.0,
) -> None:
    deadline = time.monotonic() + timeout
    last_present: bool | None = None
    while time.monotonic() < deadline:
        present = evaluate_webview(
            control_port,
            "Boolean(document.getElementById('settings-dialog'))",
            "Settings dialog state",
        )
        if not isinstance(present, bool):
            raise SmokeFailure(f"Settings dialog state returned invalid value: {present!r}")
        last_present = present
        if present is visible:
            return
        time.sleep(0.2)
    expectation = "visible" if visible else "closed"
    raise SmokeFailure(
        f"Settings dialog did not become {expectation} in the webview; "
        f"last present state: {last_present!r}"
    )


def assert_settings_accessibility_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    snapshot = evaluate_webview(
        control_port,
        r"""
(() => {
  const text = (node) => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const attr = (node, name) => node?.getAttribute(name) || "";
  const dialog = document.getElementById("settings-dialog");
  const fieldIds = [
    "settings-theme",
    "settings-fontsize",
    "settings-tabsize",
    "settings-wrapcolumn",
    "settings-whitespace",
    "settings-fontfamily",
    "settings-cursor",
    "settings-wordwrap",
  ];
  return {
    dialogRole: attr(dialog, "role"),
    dialogModal: attr(dialog, "aria-modal"),
    dialogLabelledBy: attr(dialog, "aria-labelledby"),
    dialogDescribedBy: attr(dialog, "aria-describedby"),
    dialogTitle: text(document.getElementById("settings-title")),
    dialogDescription: text(document.getElementById("settings-description")),
    activeElement: text(document.activeElement) || attr(document.activeElement, "aria-label"),
    activeElementTag: document.activeElement?.tagName || "",
    activeInsideDialog: dialog?.contains(document.activeElement) || false,
    fieldLabels: Object.fromEntries(fieldIds.map((id) => [id, text(document.querySelector(`label[for="${id}"]`))])),
    checkboxLabels: Object.fromEntries(["settings-minimap", "settings-linenumbers", "settings-bracketpair", "settings-formatonsave", "settings-autosave"].map((id) => [id, text(document.querySelector(`label[for="${id}"]`))])),
    closeButtonLabel: attr(document.querySelector(".settings-close"), "aria-label"),
    decorativeIconsHidden: Array.from(document.querySelectorAll(".settings-close .codicon")).every((node) => attr(node, "aria-hidden") === "true"),
    footerButtons: Array.from(document.querySelectorAll(".settings-footer button")).map(text),
    sectionNames: Array.from(document.querySelectorAll(".settings-section-title")).map(text),
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
        "dialogLabelledBy": "settings-title",
        "dialogDescribedBy": "settings-description",
        "dialogTitle": "Settings",
        "dialogDescription": "Review editor preferences, then save to apply and sync them.",
        "activeElement": "Close settings",
        "activeElementTag": "BUTTON",
        "activeInsideDialog": True,
        "closeButtonLabel": "Close settings",
        "decorativeIconsHidden": True,
    }
    for key, value in expected.items():
        if snapshot.get(key) != value:
            raise SmokeFailure(f"{phase} accessibility {key} was {snapshot.get(key)!r}, expected {value!r}")
    expected_field_labels = {
        "settings-theme": "Color Theme",
        "settings-fontsize": "Font Size",
        "settings-tabsize": "Tab Size",
        "settings-wrapcolumn": "Word Wrap Column",
        "settings-whitespace": "Render Whitespace",
        "settings-fontfamily": "Font Family",
        "settings-cursor": "Cursor Style",
        "settings-wordwrap": "Word Wrap",
    }
    if snapshot.get("fieldLabels") != expected_field_labels:
        raise SmokeFailure(f"{phase} accessibility field labels mismatch: {snapshot!r}")
    expected_checkbox_labels = {
        "settings-minimap": "Show Minimap",
        "settings-linenumbers": "Show Line Numbers",
        "settings-bracketpair": "Bracket Pair Colorization",
        "settings-formatonsave": "Format on Save",
        "settings-autosave": "Auto Save (after 1s idle)",
    }
    if snapshot.get("checkboxLabels") != expected_checkbox_labels:
        raise SmokeFailure(f"{phase} accessibility checkbox labels mismatch: {snapshot!r}")
    if snapshot.get("footerButtons") != ["Open Settings (JSON)", "Cancel", "Apply & Save"]:
        raise SmokeFailure(f"{phase} accessibility footer buttons mismatch: {snapshot!r}")
    if "Appearance" not in snapshot.get("sectionNames", []) or "Keyboard Shortcuts" not in snapshot.get("sectionNames", []):
        raise SmokeFailure(f"{phase} accessibility section headings missing: {snapshot!r}")
    return snapshot


def assert_settings_focus_wrapped(control_port: int, phase: str) -> dict[str, Any]:
    snapshot = evaluate_webview(
        control_port,
        r"""
(() => {
  const text = (node) => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const attr = (node, name) => node?.getAttribute(name) || "";
  const dialog = document.getElementById("settings-dialog");
  return {
    activeElement: text(document.activeElement) || attr(document.activeElement, "aria-label"),
    activeElementTag: document.activeElement?.tagName || "",
    activeInsideDialog: dialog?.contains(document.activeElement) || false,
  };
})()
""",
        phase,
    )
    if not isinstance(snapshot, dict):
        raise SmokeFailure(f"{phase} focus snapshot was not an object: {snapshot!r}")
    if snapshot.get("activeElement") != "Apply & Save":
        raise SmokeFailure(f"{phase} did not wrap focus to Apply & Save: {snapshot!r}")
    if snapshot.get("activeElementTag") != "BUTTON" or snapshot.get("activeInsideDialog") is not True:
        raise SmokeFailure(f"{phase} focus escaped Settings dialog: {snapshot!r}")
    return snapshot


def assert_settings_trigger_focus(control_port: int, phase: str) -> dict[str, Any]:
    snapshot = evaluate_webview(
        control_port,
        r"""
(() => {
  const text = (node) => (node?.textContent || "").replace(/\s+/g, " ").trim();
  const attr = (node, name) => node?.getAttribute(name) || "";
  return {
    activeElement: text(document.activeElement) || attr(document.activeElement, "aria-label"),
    activeElementTag: document.activeElement?.tagName || "",
    activeControls: attr(document.activeElement, "aria-controls"),
    activeHasPopup: attr(document.activeElement, "aria-haspopup"),
  };
})()
""",
        phase,
    )
    if not isinstance(snapshot, dict):
        raise SmokeFailure(f"{phase} focus snapshot was not an object: {snapshot!r}")
    expected = {
        "activeElement": "Settings",
        "activeElementTag": "BUTTON",
        "activeControls": "settings-dialog",
        "activeHasPopup": "dialog",
    }
    for key, value in expected.items():
        if snapshot.get(key) != value:
            raise SmokeFailure(f"{phase} focus {key} was {snapshot.get(key)!r}, expected {value!r}")
    return snapshot

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--port", type=int, default=23886)
    parser.add_argument("--control-port", type=int, default=24886)
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    console_path = output_dir / f"{run_id}-console.log"
    profile_dir = Path(tempfile.mkdtemp(prefix="wizp-native-settings-profile-"))
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle = None
    stderr_handle = None
    report: dict[str, Any] = {
        "schema": 2,
        "kind": "wizp-linux-packaged-native-settings",
        "runId": run_id,
        "status": "failed",
        "startedAt": utc_now(),
        "finishedAt": None,
        "binary": str(binary),
        "outputDir": str(output_dir),
        "evidence": {},
        "checks": {},
        "notClaimed": [
            "Assistive-technology sign-off",
            "macOS or Windows behavior",
        ],
        "errors": [],
    }
    try:
        display = os.environ.get("DISPLAY", "").strip()
        if not display or os.environ.get("WIZP_VIRTUAL_DISPLAY") != "1":
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
        convert = require_tool("convert")
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
        geometry = dialog_geometry(window)
        report["window"] = window
        report["dialogGeometry"] = geometry
        rpc = RpcClient(args.port)

        ui_png = output_dir / f"{run_id}-00-ui-ready.png"
        ui_ocr = output_dir / f"{run_id}-00-ui-ready.txt"
        ui_err = output_dir / f"{run_id}-00-ui-ready.stderr.log"
        wait_for_visible_ui(
            import_tool,
            tesseract,
            language,
            window["id"],
            ui_png,
            ui_ocr,
            ui_err,
        )

        def settings_state(index: str, visible: bool = True) -> tuple[Path, str]:
            screenshot = output_dir / f"{run_id}-{index}.png"
            ocr_path = output_dir / f"{run_id}-{index}.txt"
            ocr_err = output_dir / f"{run_id}-{index}.stderr.log"
            text = wait_for_dialog(
                args.control_port,
                import_tool,
                tesseract,
                language,
                window,
                screenshot,
                ocr_path,
                ocr_err,
                visible=visible,
            )
            report["evidence"][index] = {
                "screenshot": screenshot.name,
                "ocr": ocr_path.name,
                "ocrMatched": dialog_ocr_matches(text) is visible,
            }
            return screenshot, text

        def open_settings(phase: str) -> None:
            last_error: SmokeFailure | None = None
            for _ in range(3):
                click(
                    xdotool,
                    window,
                    geometry["mainX"],
                    geometry["mainY"],
                    f"focus the workbench before {phase}",
                )
                key(xdotool, window, "ctrl+comma", phase)
                try:
                    wait_for_dialog(
                        args.control_port,
                        import_tool,
                        tesseract,
                        language,
                        window,
                        output_dir / f"{run_id}-open-probe.png",
                        output_dir / f"{run_id}-open-probe.txt",
                        output_dir / f"{run_id}-open-probe.stderr.log",
                        visible=True,
                        timeout=4.0,
                    )
                    return
                except SmokeFailure as exc:
                    last_error = exc
            raise SmokeFailure(f"{phase} failed after 3 attempts: {last_error}")

        def set_font_size(value: str, phase: str) -> None:
            key(xdotool, window, "Tab", f"focus theme selector for {phase}")
            key(xdotool, window, "Tab", f"focus font size for {phase}")
            key(xdotool, window, "ctrl+a", f"select font size for {phase}")
            for digit in value:
                key(xdotool, window, digit, f"type font size {value} for {phase}")

        def capture_visible_font(index: str, expected: str | None = None) -> None:
            screenshot, _ = settings_state(index)
            value = evaluate_webview(
                args.control_port,
                "document.getElementById('settings-fontsize')?.value ?? null",
                f"{index} font value",
            )
            if not isinstance(value, str):
                raise SmokeFailure(f"{index} font value returned invalid value: {value!r}")
            if expected is not None and value != expected:
                raise SmokeFailure(
                    f"Settings font value {expected!r} was not restored in the dialog: {value!r}"
                )
            font_ocr = capture_font_value(
                convert,
                tesseract,
                language,
                screenshot,
                output_dir / f"{run_id}-{index}-crop.png",
                output_dir / f"{run_id}-{index}-crop.txt",
                output_dir / f"{run_id}-{index}-crop.stderr.log",
                geometry,
            )
            report["evidence"][index]["fontValue"] = value
            report["evidence"][index]["fontOcr"] = font_ocr.strip()

        def click_settings_footer(label: str, phase: str) -> dict[str, Any]:
            target = evaluate_webview(
                args.control_port,
                r"""
((label) => {
  const button = Array.from(document.querySelectorAll(".settings-footer button"))
    .find((node) => (node.textContent || "").replace(/\s+/g, " ").trim() === label);
  if (!button) return { found: false, label };
  const rect = button.getBoundingClientRect();
  return {
    found: true,
    label,
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
  };
})
""" + f"({json.dumps(label)})",
                phase,
            )
            if not isinstance(target, dict) or target.get("found") is not True:
                raise SmokeFailure(f"{phase} Settings footer button was not found: {target!r}")
            x = target.get("x")
            y = target.get("y")
            if not isinstance(x, int) or not isinstance(y, int):
                raise SmokeFailure(f"{phase} Settings footer returned invalid coordinates: {target!r}")
            click(xdotool, window, x, y, phase)
            return target

        def click_settings_button(phase: str) -> dict[str, Any]:
            target = evaluate_webview(
                args.control_port,
                r"""
(() => {
  const button = document.querySelector('button[aria-label="Settings"][aria-controls="settings-dialog"]');
  if (!button) return { found: false };
  const rect = button.getBoundingClientRect();
  return {
    found: true,
    x: Math.round(rect.left + rect.width / 2),
    y: Math.round(rect.top + rect.height / 2),
    label: button.getAttribute("aria-label") || "",
    controls: button.getAttribute("aria-controls") || "",
    hasPopup: button.getAttribute("aria-haspopup") || "",
  };
})()
""",
                phase,
            )
            if not isinstance(target, dict) or target.get("found") is not True:
                raise SmokeFailure(f"{phase} Settings trigger was not found: {target!r}")
            x = target.get("x")
            y = target.get("y")
            if not isinstance(x, int) or not isinstance(y, int):
                raise SmokeFailure(f"{phase} Settings trigger returned invalid coordinates: {target!r}")
            click(xdotool, window, x, y, phase)
            wait_for_dialog(
                args.control_port,
                import_tool,
                tesseract,
                language,
                window,
                output_dir / f"{run_id}-trigger-open-probe.png",
                output_dir / f"{run_id}-trigger-open-probe.txt",
                output_dir / f"{run_id}-trigger-open-probe.stderr.log",
                visible=True,
                timeout=4.0,
            )
            return target


        initial_font = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        open_settings("open Settings with the keyboard shortcut")
        settings_state("01-keyboard-open")
        report["accessibility"] = {
            "settingsDialog": assert_settings_accessibility_snapshot(
                args.control_port,
                "Settings dialog",
            )
        }
        key(xdotool, window, "shift+Tab", "wrap Settings focus from close button to Apply and Save")
        report["accessibility"]["focusWrap"] = assert_settings_focus_wrapped(
            args.control_port,
            "Settings focus wrap",
        )
        key(xdotool, window, "Tab", "restore Settings focus to close button after wrap proof")
        report["checks"]["settingsDialogAccessible"] = True
        report["checks"]["settingsFocusContained"] = True
        report["checks"]["keyboardShortcutOpen"] = True

        set_font_size("18", "prepare a cancelled Settings edit")
        report["checks"]["keyboardFieldNavigation"] = True
        capture_visible_font("02-cancel-edit")
        click_settings_footer("Cancel", "cancel Settings edit")
        settings_state("03-cancel-closed", visible=False)
        cancelled_font = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        if cancelled_font.get("value") != initial_font.get("value"):
            raise SmokeFailure(
                f"Cancel changed the backend font size: before={initial_font}, after={cancelled_font}"
            )

        open_settings("reopen Settings with the keyboard shortcut after Cancel")
        capture_visible_font("04-cancel-reopen", "14")
        report["checks"]["cancelDiscardedEdit"] = True

        set_font_size("19", "prepare an escaped Settings edit")
        capture_visible_font("05-escape-edit")
        key(xdotool, window, "Escape", "close Settings with Escape")
        settings_state("06-escape-closed", visible=False)
        escaped_font = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        if escaped_font.get("value") != initial_font.get("value"):
            raise SmokeFailure(
                f"Escape changed the backend font size: before={initial_font}, after={escaped_font}"
            )

        open_settings("reopen Settings after Escape")
        capture_visible_font("07-escape-reopen", "14")
        report["checks"]["escapeClosedWithoutSaving"] = True

        set_font_size("16", "prepare a saved Settings edit")
        capture_visible_font("08-save-edit")
        click_settings_footer("Apply & Save", "save Settings edit")
        settings_state("09-save-closed", visible=False)
        saved_font = rpc.call("config/get", {"key": "editor.fontSize", "scope": "user"})
        if saved_font.get("value") != "16":
            raise SmokeFailure(f"Apply and Save did not sync font size 16: {saved_font}")
        report["checks"]["saveSyncedBackend"] = True

        open_settings("reopen Settings after Save")
        capture_visible_font("10-save-reopen", "16")
        report["checks"]["savedValueReopened"] = True
        key(xdotool, window, "Escape", "close keyboard-opened Settings after saved-value reopen")
        settings_state("11-save-reopen-closed", visible=False)

        report["accessibility"]["settingsTrigger"] = click_settings_button(
            "open Settings through the Activity Bar trigger",
        )
        settings_state("12-trigger-open")
        key(xdotool, window, "Escape", "close trigger-opened Settings")
        settings_state("13-trigger-closed", visible=False)
        report["accessibility"]["returnFocus"] = assert_settings_trigger_focus(
            args.control_port,
            "Settings return focus",
        )
        report["checks"]["settingsReturnedFocusToTrigger"] = True

        open_settings("open Settings for partial-sync recovery")
        set_font_size("17", "prepare a partially synced Settings edit")
        backend_before_failure = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        if backend_before_failure.get("value") != "16":
            raise SmokeFailure(
                "Partial-sync recovery did not start from backend font size 16: "
                f"{backend_before_failure}"
            )
        injection = inject_one_shot_config_set_failure(
            args.control_port,
            "editor.fontSize",
            "inject one-shot Settings font-size sync failure",
        )
        click_settings_footer("Apply & Save", "attempt Settings save with injected sync failure")
        warning = wait_for_settings_sync_warning(args.control_port, "17")
        settings_state("14-partial-sync-warning")
        backend_after_failure = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        if backend_after_failure != backend_before_failure:
            raise SmokeFailure(
                "Injected font-size sync failure did not preserve the backend state: "
                f"before={backend_before_failure}, after={backend_after_failure}"
            )
        report["partialSyncRecovery"] = {
            "backendBeforeFailure": backend_before_failure,
            "injection": injection,
            "warning": warning,
            "backendAfterFailure": backend_after_failure,
        }
        report["checks"]["partialSyncWarningVisible"] = True
        report["checks"]["partialSyncRetainedDialog"] = True
        report["checks"]["partialSyncPreservedLocalValue"] = True
        report["checks"]["partialSyncBackendUnchanged"] = True

        click_settings_footer("Retry Save", "retry Settings save after injected sync failure")
        settings_state("15-retry-closed", visible=False)
        backend_after_retry = rpc.call(
            "config/get", {"key": "editor.fontSize", "scope": "user"}
        )
        if backend_after_retry.get("value") != "17":
            raise SmokeFailure(f"Retry Save did not sync font size 17: {backend_after_retry}")
        report["partialSyncRecovery"]["backendAfterRetry"] = backend_after_retry
        report["checks"]["retrySaveSyncedBackend"] = True
        report["checks"]["retrySaveClosedDialog"] = True

        open_settings("reopen Settings after partial-sync recovery")
        capture_visible_font("16-retry-reopen", "17")
        report["checks"]["retrySaveReopenedValue"] = True
        key(xdotool, window, "Escape", "close Settings after partial-sync recovery")
        settings_state("17-retry-reopen-closed", visible=False)

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
            combine_console(stdout_path, stderr_path, console_path)
            report["console"] = console_path.name
        shutil.rmtree(profile_dir, ignore_errors=True)
        if isinstance(report.get("profile"), dict):
            report["profile"]["removedAfterRun"] = not profile_dir.exists()
        report["finishedAt"] = utc_now()
        promotion = retain_and_promote_report(output_dir, report, validate_report)
        if not promotion.promoted:
            print(
                f"native Settings report retained without promotion: {promotion.retained_report}",
                file=sys.stderr,
            )
            for error in promotion.errors:
                print(f"- {error}", file=sys.stderr)


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
