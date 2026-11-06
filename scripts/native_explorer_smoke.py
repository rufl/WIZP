#!/usr/bin/env python3
"""Exercise the packaged Linux Explorer lifecycle with real X11 input."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.check_native_explorer_report import validate_report
from scripts.native_editor_smoke import evaluate_webview, type_text
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

DEFAULT_OUTPUT = ROOT / "build" / "ui-ux" / "native-explorer"


def wait_for_webview(
    control_port: int,
    script: str,
    phase: str,
    *,
    timeout: float = 10.0,
) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        last = evaluate_webview(control_port, script, phase)
        if last:
            return last
        time.sleep(0.15)
    raise SmokeFailure(f"{phase} did not become ready; last value: {last!r}")


def wait_for_path(path: Path, *, exists: bool, phase: str, timeout: float = 8.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() is exists:
            return
        time.sleep(0.1)
    state = "exist" if exists else "be removed"
    raise SmokeFailure(f"{phase} did not {state}: {path}")


def tree_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    snapshot = evaluate_webview(
        control_port,
        r"""
(() => {
  const tree = document.querySelector('[role="tree"][aria-label="Workspace files"]');
  const items = Array.from(tree?.querySelectorAll('[role="treeitem"]') || []);
  const active = document.activeElement;
  return {
    treeFound: Boolean(tree),
    label: tree?.getAttribute('aria-label') || '',
    busy: tree?.getAttribute('aria-busy') || '',
    activePath: active?.getAttribute?.('data-path') || '',
    activeRole: active?.getAttribute?.('role') || '',
    tabStops: items.filter((item) => item.getAttribute('tabindex') === '0').length,
    items: items.map((item) => ({
      path: item.getAttribute('data-path') || '',
      kind: item.getAttribute('data-kind') || '',
      label: item.getAttribute('aria-label') || '',
      level: Number(item.getAttribute('aria-level') || 0),
      selected: item.getAttribute('aria-selected') || '',
      expanded: item.getAttribute('aria-expanded'),
      tabIndex: item.getAttribute('tabindex') || '',
    })),
  };
})()
""",
        phase,
    )
    if not isinstance(snapshot, dict):
        raise SmokeFailure(f"{phase} returned invalid tree snapshot: {snapshot!r}")
    return snapshot


def item_script(path: Path, body: str) -> str:
    return (
        "((path) => { const node = Array.from(document.querySelectorAll('[role=\"treeitem\"]'))"
        ".find((item) => item.getAttribute('data-path') === path);"
        f" if (!node) return null; {body} }})("
        + json.dumps(str(path))
        + ")"
    )


def wait_for_tree_path(control_port: int, path: Path, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        item_script(
            path,
            "return { path, expanded: node.getAttribute('aria-expanded'), "
            "selected: node.getAttribute('aria-selected'), label: node.getAttribute('aria-label') || '' };",
        ),
        phase,
    )
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid item: {value!r}")
    return value


def click_tree_item(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    path: Path,
    phase: str,
    *,
    expect_focus: bool = True,
) -> None:
    target = wait_for_webview(
        control_port,
        item_script(
            path,
            "const rect = node.getBoundingClientRect(); "
            "return { x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2) };",
        ),
        phase,
    )
    if not isinstance(target, dict) or not isinstance(target.get("x"), int) or not isinstance(target.get("y"), int):
        raise SmokeFailure(f"{phase} returned invalid coordinates: {target!r}")
    click(xdotool, window, target["x"], target["y"], phase)
    if expect_focus:
        active = tree_snapshot(control_port, f"{phase} focus")
        if active.get("activePath") != str(path):
            raise SmokeFailure(f"{phase} did not focus the tree item: {active!r}")


def wait_for_active_path(control_port: int, path: Path, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        "(() => { const active = document.activeElement; return "
        f"active?.getAttribute?.('data-path') === {json.dumps(str(path))} ? "
        "{ path: active.getAttribute('data-path'), label: active.getAttribute('aria-label') || '' } : null; })()",
        phase,
    )
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid focus state: {value!r}")
    return value

def focus_tree_item_with_keyboard(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    anchor: Path,
    target: Path,
    phase: str,
) -> None:
    click_tree_item(control_port, xdotool, window, anchor, f"{phase} anchor")
    key(xdotool, window, "Home", f"{phase} move to first item")
    snapshot = tree_snapshot(control_port, phase)
    items = snapshot.get("items")
    if not isinstance(items, list):
        raise SmokeFailure(f"{phase} returned invalid tree items: {snapshot!r}")
    index = next(
        (offset for offset, item in enumerate(items) if item.get("path") == str(target)),
        -1,
    )
    if index < 0:
        raise SmokeFailure(f"{phase} target is not visible: {target}")
    for _ in range(index):
        key(xdotool, window, "Down", phase)
    wait_for_active_path(control_port, target, phase)


def dialog_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    value = evaluate_webview(
        control_port,
        r"""
(() => {
  const dialog = document.querySelector('dialog.explorer-dialog[open]');
  if (!dialog) return null;
  const active = document.activeElement;
  const input = dialog.querySelector('input');
  const title = dialog.querySelector('#explorer-dialog-title');
  const description = dialog.querySelector('#explorer-dialog-description');
  const alert = dialog.querySelector('[role="alert"]');
  return {
    open: dialog.open,
    title: title?.textContent?.trim() || '',
    description: description?.textContent?.replace(/\s+/g, ' ').trim() || '',
    labelledBy: dialog.getAttribute('aria-labelledby') || '',
    describedBy: dialog.getAttribute('aria-describedby') || '',
    inputValue: input?.value ?? null,
    inputInvalid: input?.getAttribute('aria-invalid') || '',
    alert: alert?.textContent?.replace(/\s+/g, ' ').trim() || '',
    activeLabel: active?.getAttribute?.('aria-label') || active?.textContent?.trim() || '',
    activeTag: active?.tagName || '',
  };
})()
""",
        phase,
    )
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid dialog snapshot: {value!r}")
    return value


def wait_for_dialog(control_port: int, title: str, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        "(() => { const dialog = document.querySelector('dialog.explorer-dialog[open]'); "
        "const heading = dialog?.querySelector('#explorer-dialog-title')?.textContent?.trim() || ''; "
        f"return heading.startsWith({json.dumps(title)}) ? true : false; }})()",
        phase,
    )
    if value is not True:
        raise SmokeFailure(f"{phase} did not open {title!r}")
    return dialog_snapshot(control_port, phase)


def wait_for_dialog_closed(control_port: int, phase: str) -> None:
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        if not dialog_snapshot(control_port, phase):
            return
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} dialog did not close")


def menu_snapshot(control_port: int, phase: str) -> dict[str, Any]:
    value = evaluate_webview(
        control_port,
        r"""
(() => {
  const menu = document.querySelector('.ctx-menu[role="menu"]');
  if (!menu) return null;
  const items = Array.from(menu.querySelectorAll(':scope > [role="menuitem"]'));
  return {
    label: menu.getAttribute('aria-label') || '',
    active: document.activeElement?.textContent?.replace(/\s+/g, ' ').trim() || '',
    items: items.map((item) => item.textContent?.replace(/\s+/g, ' ').trim() || ''),
  };
})()
""",
        phase,
    )
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise SmokeFailure(f"{phase} returned invalid menu snapshot: {value!r}")
    return value


def wait_for_menu(control_port: int, phase: str) -> dict[str, Any]:
    value = wait_for_webview(
        control_port,
        "Boolean(document.querySelector('.ctx-menu[role=\"menu\"]'))",
        phase,
    )
    if value is not True:
        raise SmokeFailure(f"{phase} context menu did not open")
    deadline = time.monotonic() + 4.0
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = menu_snapshot(control_port, phase)
        if last.get("active"):
            return last
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} context menu did not focus an item: {last!r}")


def wait_for_menu_closed(control_port: int, phase: str) -> None:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if not menu_snapshot(control_port, phase):
            return
        time.sleep(0.1)
    raise SmokeFailure(f"{phase} context menu did not close")


def select_context_item(
    control_port: int,
    xdotool: str,
    window: dict[str, Any],
    index: int,
    phase: str,
) -> dict[str, Any]:
    key(xdotool, window, "shift+F10", f"open context menu to {phase}")
    snapshot = wait_for_menu(control_port, phase)
    items = snapshot.get("items")
    if not isinstance(items, list) or index >= len(items):
        raise SmokeFailure(f"{phase} context item {index} is unavailable: {snapshot!r}")
    for _ in range(index):
        key(xdotool, window, "Down", f"navigate context menu to {phase}")
    key(xdotool, window, "Return", phase)
    return snapshot


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--port", type=int, default=23888)
    parser.add_argument("--control-port", type=int, default=24888)
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    console_path = output_dir / f"{run_id}-console.log"
    profile_dir = Path(tempfile.mkdtemp(prefix="wizp-native-explorer-profile-"))
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle = None
    stderr_handle = None
    readonly_dir: Path | None = None
    report: dict[str, Any] = {
        "schema": 1,
        "kind": "wizp-linux-packaged-native-explorer",
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
        explorer = fixture["explorerLifecycle"]
        readonly_dir = workspace_dir / "read-only-folder"
        readonly_dir.mkdir()
        os.chmod(readonly_dir, 0o555)
        removed_dir = workspace_dir / "removed-folder"
        removed_dir.mkdir()
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
        evaluate_webview(
            args.control_port,
            "(() => { window.__refreshExplorer?.(); return true; })()",
            "refresh Explorer",
        )
        wait_for_tree_path(args.control_port, workspace_dir / "nested", "load fixture tree")
        report["checks"]["workspaceFixtureSelected"] = True

        initial = tree_snapshot(args.control_port, "initial Explorer accessibility")
        items = initial.get("items")
        if initial.get("treeFound") is not True or initial.get("label") != "Workspace files":
            raise SmokeFailure(f"Explorer tree semantics are incomplete: {initial!r}")
        if initial.get("tabStops") != 1 or not isinstance(items, list) or not items:
            raise SmokeFailure(f"Explorer roving focus is incomplete: {initial!r}")
        if any(not item.get("label") or item.get("level") != 1 for item in items):
            raise SmokeFailure(f"Explorer root item semantics are incomplete: {initial!r}")
        report["accessibility"] = {"initialTree": initial}
        report["checks"]["treeAccessible"] = True

        first_path = Path(items[0]["path"])
        last_path = Path(items[-1]["path"])
        click_tree_item(args.control_port, xdotool, window, first_path, "focus first Explorer item")
        key(xdotool, window, "End", "move Explorer focus to last item")
        wait_for_active_path(args.control_port, last_path, "Explorer End navigation")
        key(xdotool, window, "Home", "move Explorer focus to first item")
        wait_for_active_path(args.control_port, first_path, "Explorer Home navigation")
        key(xdotool, window, "Down", "move Explorer focus down")
        moved = tree_snapshot(args.control_port, "Explorer ArrowDown navigation")
        if moved.get("activePath") == str(first_path):
            raise SmokeFailure(f"Explorer ArrowDown did not move focus: {moved!r}")
        report["checks"]["keyboardRovingNavigation"] = True

        nested_path = workspace_dir / "nested"
        deep_path = nested_path / "deep"
        unicode_path = deep_path / "unicode-文件.txt"
        click_tree_item(args.control_port, xdotool, window, nested_path, "expand nested folder with pointer")
        wait_for_tree_path(args.control_port, deep_path, "load nested folder")
        key(xdotool, window, "Left", "collapse nested folder with keyboard")
        collapsed = wait_for_tree_path(args.control_port, nested_path, "confirm nested collapse")
        if collapsed.get("expanded") != "false":
            raise SmokeFailure(f"nested folder did not collapse: {collapsed!r}")
        key(xdotool, window, "Right", "expand nested folder with keyboard")
        wait_for_tree_path(args.control_port, deep_path, "reload nested folder")
        click_tree_item(args.control_port, xdotool, window, deep_path, "expand deep folder with pointer")
        wait_for_tree_path(args.control_port, unicode_path, "load long Unicode path")
        click_tree_item(
            args.control_port,
            xdotool,
            window,
            unicode_path,
            "open Unicode path",
            expect_focus=False,
        )
        editor_marker = wait_for_webview(
            args.control_port,
            "(() => { const editor = window.__getActiveEditor?.(); const value = editor?.getValue?.() || ''; "
            "return value.includes('WIZP_UI_UNICODE_PATH_OK') ? value : ''; })()",
            "open long Unicode fixture",
        )
        if "WIZP_UI_UNICODE_PATH_OK" not in editor_marker:
            raise SmokeFailure("Unicode fixture did not open in the editor")
        report["checks"]["longUnicodePathOpened"] = True

        source_path = workspace_dir / explorer["renameDeletePath"]
        empty_path = workspace_dir / explorer["emptyFolder"]
        focus_tree_item_with_keyboard(
            args.control_port,
            xdotool,
            window,
            empty_path,
            source_path,
            "focus Explorer lifecycle file",
        )
        key(xdotool, window, "shift+F10", "open Explorer keyboard context menu")
        context = wait_for_menu(args.control_port, "Explorer keyboard context menu")
        required_context = {"New File...", "New Folder...", "Rename... F2", "Delete Delete", "Copy", "Cut"}
        if not required_context.issubset(set(context.get("items", []))):
            raise SmokeFailure(f"Explorer context menu is incomplete: {context!r}")
        key(xdotool, window, "Escape", "close Explorer keyboard context menu")
        wait_for_menu_closed(args.control_port, "close Explorer context menu")
        wait_for_active_path(args.control_port, source_path, "restore Explorer focus after context menu")
        report["accessibility"]["contextMenu"] = context
        report["checks"]["keyboardContextMenu"] = True

        select_context_item(args.control_port, xdotool, window, 0, "create Explorer file")
        create_dialog = wait_for_dialog(args.control_port, "Create file", "create file dialog")
        if create_dialog.get("labelledBy") != "explorer-dialog-title" or create_dialog.get("activeLabel") != "Name":
            raise SmokeFailure(f"create file dialog semantics are incomplete: {create_dialog!r}")
        type_text(xdotool, window, explorer["createdFile"], "type created Explorer filename")
        key(xdotool, window, "Return", "create Explorer file")
        created_file = workspace_dir / explorer["createdFile"]
        wait_for_path(created_file, exists=True, phase="create Explorer file")
        wait_for_dialog_closed(args.control_port, "create Explorer file")
        wait_for_tree_path(args.control_port, created_file, "show created Explorer file")
        report["checks"]["fileCreated"] = True

        focus_tree_item_with_keyboard(
            args.control_port,
            xdotool,
            window,
            empty_path,
            created_file,
            "focus created Explorer file",
        )
        select_context_item(args.control_port, xdotool, window, 0, "repeat Explorer file creation")
        wait_for_dialog(args.control_port, "Create file", "duplicate create dialog")
        type_text(xdotool, window, explorer["createdFile"], "type duplicate Explorer filename")
        key(xdotool, window, "Return", "submit duplicate Explorer filename")
        duplicate = wait_for_webview(
            args.control_port,
            "(() => { const dialog = document.querySelector('dialog.explorer-dialog[open]'); "
            "const alert = dialog?.querySelector('[role=\"alert\"]'); return alert ? { "
            "text: alert.textContent.replace(/\\s+/g, ' ').trim(), "
            "invalid: dialog.querySelector('input')?.getAttribute('aria-invalid') || '', "
            "active: document.activeElement?.getAttribute?.('aria-label') || '' } : null; })()",
            "duplicate create recovery",
        )
        if duplicate.get("invalid") != "true" or duplicate.get("active") != "Name":
            raise SmokeFailure(f"duplicate create recovery is incomplete: {duplicate!r}")
        key(xdotool, window, "Escape", "close duplicate create dialog")
        wait_for_dialog_closed(args.control_port, "close duplicate create dialog")
        report["accessibility"]["createDialog"] = create_dialog
        report["checks"]["duplicateCreateRecovered"] = True

        focus_tree_item_with_keyboard(
            args.control_port,
            xdotool,
            window,
            empty_path,
            created_file,
            "focus parent for folder creation",
        )
        select_context_item(args.control_port, xdotool, window, 1, "create Explorer folder")
        folder_dialog = wait_for_dialog(args.control_port, "Create folder", "create folder dialog")
        type_text(xdotool, window, explorer["createdFolder"], "type created Explorer folder")
        key(xdotool, window, "Return", "create Explorer folder")
        created_folder = workspace_dir / explorer["createdFolder"]
        wait_for_path(created_folder, exists=True, phase="create Explorer folder")
        wait_for_dialog_closed(args.control_port, "create Explorer folder")
        wait_for_tree_path(args.control_port, created_folder, "show created Explorer folder")
        report["checks"]["folderCreated"] = True

        focus_tree_item_with_keyboard(
            args.control_port,
            xdotool,
            window,
            empty_path,
            source_path,
            "focus file for rename",
        )
        key(xdotool, window, "F2", "open Explorer rename dialog")
        rename_dialog = wait_for_dialog(args.control_port, "Rename", "rename Explorer dialog")
        renamed_path = workspace_dir / "explorer-renamed.txt"
        key(xdotool, window, "ctrl+a", "select Explorer rename value")
        type_text(xdotool, window, renamed_path.name, "type Explorer renamed filename")
        key(xdotool, window, "Return", "rename Explorer file")
        wait_for_path(source_path, exists=False, phase="remove original Explorer filename")
        wait_for_path(renamed_path, exists=True, phase="create renamed Explorer filename")
        wait_for_dialog_closed(args.control_port, "rename Explorer file")
        wait_for_tree_path(args.control_port, renamed_path, "show renamed Explorer file")
        report["accessibility"]["renameDialog"] = rename_dialog
        report["checks"]["fileRenamed"] = True

        focus_tree_item_with_keyboard(
            args.control_port,
            xdotool,
            window,
            empty_path,
            renamed_path,
            "focus renamed file for copy",
        )
        select_context_item(args.control_port, xdotool, window, 4, "copy Explorer file")
        wait_for_menu_closed(args.control_port, "copy Explorer file")
        click_tree_item(args.control_port, xdotool, window, created_folder, "focus folder for paste")
        paste_menu = select_context_item(args.control_port, xdotool, window, 6, "paste Explorer file")
        if "Paste" not in paste_menu.get("items", []):
            raise SmokeFailure(f"Explorer Paste action is unavailable: {paste_menu!r}")
        copied_path = created_folder / renamed_path.name
        wait_for_path(copied_path, exists=True, phase="paste Explorer file")
        wait_for_menu_closed(args.control_port, "paste Explorer file")
        wait_for_tree_path(args.control_port, created_folder, "show paste destination")
        report["checks"]["copyPasteCompleted"] = True

        click_tree_item(args.control_port, xdotool, window, created_folder, "expand pasted Explorer folder")
        wait_for_tree_path(args.control_port, copied_path, "show pasted Explorer file")
        key(xdotool, window, "Right", "focus pasted Explorer file")
        wait_for_active_path(args.control_port, copied_path, "focus pasted file for delete")
        key(xdotool, window, "Delete", "open Explorer delete dialog")
        delete_dialog = wait_for_dialog(args.control_port, "Delete", "delete Explorer dialog")
        if delete_dialog.get("activeLabel") != "Delete":
            raise SmokeFailure(f"delete dialog did not focus the destructive action: {delete_dialog!r}")
        key(xdotool, window, "Return", "delete pasted Explorer file")
        wait_for_path(copied_path, exists=False, phase="delete pasted Explorer file")
        wait_for_dialog_closed(args.control_port, "delete pasted Explorer file")
        report["accessibility"]["deleteDialog"] = delete_dialog
        report["checks"]["deleteConfirmed"] = True

        click_tree_item(args.control_port, xdotool, window, readonly_dir, "focus read-only Explorer folder")
        select_context_item(args.control_port, xdotool, window, 0, "create file in read-only folder")
        wait_for_dialog(args.control_port, "Create file", "read-only create dialog")
        type_text(xdotool, window, "denied.txt", "type read-only Explorer filename")
        key(xdotool, window, "Return", "submit read-only Explorer filename")
        permission = wait_for_webview(
            args.control_port,
            "(() => { const alert = document.querySelector('dialog.explorer-dialog[open] [role=\"alert\"]'); "
            "return alert?.textContent?.includes('Could not create the file') ? alert.textContent.trim() : ''; })()",
            "Explorer permission failure",
        )
        if (readonly_dir / "denied.txt").exists():
            raise SmokeFailure("read-only Explorer creation unexpectedly wrote a file")
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
            "message": permission,
        }
        key(xdotool, window, "Escape", "close Explorer permission dialog")
        wait_for_dialog_closed(args.control_port, "close Explorer permission dialog")
        report["checks"]["permissionFailureRecovered"] = True

        click_tree_item(args.control_port, xdotool, window, empty_path, "expand empty Explorer folder")
        empty_state = wait_for_webview(
            args.control_port,
            "Array.from(document.querySelectorAll('.tree-message')).some((node) => "
            "node.textContent.includes('Folder is empty.'))",
            "Explorer empty folder state",
        )
        if empty_state is not True:
            raise SmokeFailure("Explorer empty-folder state was not shown")

        removed_dir.rmdir()
        click_tree_item(args.control_port, xdotool, window, removed_dir, "expand removed Explorer folder")
        error_state = wait_for_webview(
            args.control_port,
            "Array.from(document.querySelectorAll('[role=\"alert\"]')).map((node) => "
            "node.textContent.replace(/\\s+/g, ' ').trim()).find((text) => "
            "text.includes('Could not open removed-folder.')) || ''",
            "Explorer directory error state",
        )
        if "Could not open removed-folder." not in error_state:
            raise SmokeFailure(f"Explorer directory error was not shown: {error_state!r}")
        key(xdotool, window, "shift+F10", "open Explorer menu for refresh")
        refresh_menu = wait_for_menu(args.control_port, "Explorer refresh menu")
        key(xdotool, window, "End", "focus Refresh Explorer")
        key(xdotool, window, "Return", "refresh Explorer after directory error")
        wait_for_menu_closed(args.control_port, "refresh Explorer")
        evaluate_webview(
            args.control_port,
            "(() => { window.__refreshExplorer?.(); return true; })()",
            "refresh Explorer state",
        )
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            if not evaluate_webview(
                args.control_port,
                item_script(removed_dir, "return true;"),
                "remove stale Explorer item",
            ):
                break
            time.sleep(0.1)
        else:
            raise SmokeFailure("Explorer refresh retained the removed directory")
        report["accessibility"]["refreshMenu"] = refresh_menu
        report["checks"]["emptyAndErrorStatesRecovered"] = True

        src_path = workspace_dir / "src"
        main_path = src_path / "main.zig"
        click_tree_item(args.control_port, xdotool, window, src_path, "expand source folder")
        wait_for_tree_path(args.control_port, main_path, "show source fixture")
        click_tree_item(
            args.control_port,
            xdotool,
            window,
            main_path,
            "open source fixture",
            expect_focus=False,
        )
        wait_for_webview(
            args.control_port,
            "document.querySelectorAll('#explorer-outline .outline-item').length >= 2",
            "load Explorer outline",
            timeout=12.0,
        )
        outline = evaluate_webview(
            args.control_port,
            "(() => { const items = Array.from(document.querySelectorAll("
            "'#explorer-outline .outline-item')); const item = items.find((node) => "
            "node.getAttribute('title') === 'main'); if (!item) return null; "
            "const rect = item.getBoundingClientRect(); return { "
            "label: item.textContent.replace(/\\s+/g, ' ').trim(), "
            "title: item.getAttribute('title') || '', "
            "x: Math.round(rect.left + rect.width / 2), "
            "y: Math.round(rect.top + rect.height / 2) }; })()",
            "locate Explorer outline symbol",
        )
        if (
            not isinstance(outline, dict)
            or outline.get("title") != "main"
            or not isinstance(outline.get("x"), int)
            or not isinstance(outline.get("y"), int)
        ):
            raise SmokeFailure(f"Explorer outline returned invalid main target: {outline!r}")
        click(
            xdotool,
            window,
            outline["x"],
            outline["y"],
            "navigate with Explorer outline",
        )
        position = evaluate_webview(
            args.control_port,
            "window.__getActiveEditor?.()?.getPosition?.()?.lineNumber || 0",
            "Explorer outline position",
        )
        if not isinstance(position, int) or position < 1:
            raise SmokeFailure(f"Explorer outline did not navigate the editor: {position!r}")
        report["outline"] = {**outline, "lineNumber": position}
        report["checks"]["outlineNavigated"] = True

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
        report["evidence"]["09-final"] = {
            "screenshot": final_png.name,
            "ocr": final_ocr.name,
        }
        report["status"] = "passed"
        return 0
    except (OSError, SmokeFailure, subprocess.SubprocessError) as exc:
        report["errors"].append(str(exc))
        return 1
    finally:
        if readonly_dir is not None and readonly_dir.exists():
            os.chmod(readonly_dir, 0o755)
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
                f"native Explorer report retained without promotion: {promotion.retained_report}",
                file=sys.stderr,
            )
            for error in promotion.errors:
                print(f"- {error}", file=sys.stderr)


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
