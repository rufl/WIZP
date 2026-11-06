#!/usr/bin/env python3
"""Frontend-facing workflow smoke through daemon RPC contracts.

This is a lightweight Playwright-equivalent guard for the workbench calls that
the Svelte UI issues today. It avoids a browser dependency while still catching
missing/mismatched RPC methods for open folder, open file, save, command
palette, terminal, and search workflows.
"""

from __future__ import annotations

import base64
import json
import tempfile
import time
from pathlib import Path

from parity_daemon_smoke import DEFAULT_BIN, RpcClient

FRONTEND = Path(__file__).resolve().parents[1] / "frontend" / "src"


def process_rss_bytes(pid: int) -> int:
    status = Path(f"/proc/{pid}/status")
    if not status.exists():
        return 0
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    return 0


def process_state(pid: int) -> str | None:
    status = Path(f"/proc/{pid}/status")
    if not status.exists():
        return None
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("State:"):
            fields = line.split()
            return fields[1] if len(fields) > 1 else "unknown"
    return "unknown"


def process_identity(pid: int) -> dict[str, int | str] | None:
    stat_path = Path(f"/proc/{pid}/stat")
    if not stat_path.exists():
        return None
    raw = stat_path.read_text(encoding="utf-8", errors="replace").strip()
    comm_end = raw.rfind(")")
    if comm_end < 0:
        return None
    fields = raw[comm_end + 2 :].split()
    if len(fields) < 20:
        return None
    return {
        "pid": pid,
        "state": fields[0],
        "ppid": int(fields[1]),
        "startTimeTicks": int(fields[19]),
    }


def wait_for_terminal_text(client: RpcClient, expected: str, timeout: float = 8.0, terminal_id: int | None = None) -> str:
    deadline = time.time() + timeout
    seen = ""
    while time.time() < deadline:
        params = {"id": terminal_id} if terminal_id is not None else {}
        result = client.call("terminal/read", params)
        data = result.get("data", "")
        if data:
            seen += base64.b64decode(data).decode("utf-8", "replace")
            if expected in seen:
                return seen
        time.sleep(0.05)
    raise AssertionError(f"terminal output did not contain {expected!r}; saw {seen!r}")


def test_editor_settings_wiring() -> None:
    settings = (FRONTEND / "components" / "Settings.svelte").read_text()
    editor = (FRONTEND / "components" / "EditorArea.svelte").read_text()
    required_settings = [
        "editor.minimap.enabled",
        "editor.fontSize",
        "editor.fontFamily",
        "editor.tabSize",
        "editor.lineNumbers",
        "editor.wordWrap",
        "editor.wordWrapColumn",
        "editor.cursorStyle",
        "editor.bracketPairColorization.enabled",
        "editor.renderWhitespace",
    ]
    for key in required_settings:
        assert key in settings, key
    required_editor_options = [
        "opts.minimap",
        "opts.fontSize",
        "opts.fontFamily",
        "opts.tabSize",
        "opts.lineNumbers",
        "opts.wordWrap",
        "opts.wordWrapColumn",
        "opts.cursorStyle",
        "opts.bracketPairColorization",
        "opts.renderWhitespace",
        "updateOptions(opts)",
        "minimap: { enabled: minimapEnabled",
        "wordWrapColumn:",
    ]
    for marker in required_editor_options:
        assert marker in editor, marker


def test_p9_browser_ux_hardening_wiring() -> None:
    search = (FRONTEND / "components" / "Search.svelte").read_text()
    explorer = (FRONTEND / "components" / "Explorer.svelte").read_text()
    outline = (FRONTEND / "components" / "OutlinePanel.svelte").read_text()
    editor = (FRONTEND / "components" / "EditorArea.svelte").read_text()
    tab = (FRONTEND / "components" / "Tab.svelte").read_text()
    sidebar_views = (FRONTEND / "components" / "SidebarViews.svelte").read_text()
    settings = (FRONTEND / "components" / "Settings.svelte").read_text()
    activity = (FRONTEND / "components" / "ActivityBar.svelte").read_text()
    hub = (FRONTEND / "components" / "Hub.svelte").read_text()

    for marker in [
        'aria-label="Search files"',
        'aria-label="Replace with"',
        'aria-label="Files to include"',
        'aria-label="Files to exclude"',
        'aria-label="Context lines"',
        "sendSearchRpc('search/text'",
        "sendRpcBounded(",
        "'search/replace',",
        'role="search"',
        'aria-label="Search results"',
        'aria-label={`Open ${fileName(match.file)}, line ${match.line}`}',
        '(match.uri || match.file)',
        'aria-pressed={wholeWord}',
        "maxReplacements",
        "resultsTruncated",
        "Search canceled.",
        "cannot be undone in WIZP",
        "rawMessage.includes('Open a folder before searching')",
    ]:
        assert marker in search, marker

    for marker in [
        'aria-label="Open folder"',
        'aria-label="Collapse all explorer folders"',
        'aria-label="Refresh explorer"',
        'aria-controls="explorer-outline"',
        'aria-expanded={outlineExpanded}',
        "sendRpc('file/list'",
        "sendRpc('git/status'",
        "'Copy'",
        "'Cut'",
        "'Paste'",
    ]:
        assert marker in explorer, marker

    for marker in [
        'aria-label="Filter outline symbols"',
        'bind:value={sortMode}',
        'title="Follow Cursor"',
        'role="button"',
        'tabindex="0"',
        'window.addEventListener(\'wizpEditorCursorChanged\'',
        "__setOutlineSymbolsForSmoke",
        "__setOutlineCursorForSmoke",
        "data-symbol-name={sym.name}",
        "data-symbol-depth={sym.depth || 0}",
    ]:
        assert marker in outline, marker

    panel = (FRONTEND / "components" / "Panel.svelte").read_text()
    for marker in [
        "sendRpc('editor/problems/reconcile'",
        "title=\"Filter by source\"",
        "bind:value={problemsSource}",
        "data-source={p.source || ''}",
        "__setProblemsForSmoke",
    ]:
        assert marker in panel, marker

    for marker in [
        'role="tablist"',
        "editorPanelId",
        "navigateEditorTabs",
        "handleClosePromptKeydown",
        'aria-describedby="close-prompt-message"',
        'class="breadcrumb-item"',
        'class="breadcrumb-dropdown-item"',
        'role="menuitem"',
        "onclick={(e) => openBreadcrumbDropdown(e, vg.id, crumb)}",
        "resizePaneWithKeyboard",
        "crumb.type === 'symbol'",
        "crumb.type === 'file'",
        "loadBreadcrumbDirectory(groupId, crumb.path)",
        "sendRpc('file/list'",
        "sendRpcBounded('textDocument/documentSymbol'",
        "openBreadcrumbFile(groupId, childPath)",
        "gotoBreadcrumbSymbol(groupId, sym)",
        "hasRecoveredContent",
        "Recovered ${recoveredDirtyEditors} unsaved editor",
        "await saveActiveEditorAs()",
        "textarea.setAttribute('aria-label', 'Reply to comment')",
        "ariaLabel: `Code editor for ${tab.label || 'file'}`",
        'aria-label="Resize panes with Arrow keys; press Enter to equalize"',
        'onDragStart',
        'onDrop',
    ]:
        assert marker in editor, marker

    for marker in [
        "tabindex={active ? 0 : -1}",
        "aria-controls={panelId || undefined}",
        "onNavigate?.('next')",
        "onNavigate?.('previous')",
        "onClose?.()",
        "aria-label={`${title}${dirty ? ', unsaved changes' : ''}`}",
        "data-dirty={dirty}",
        "aria-label={`Close ${title}`}",
    ]:
        assert marker in tab, marker

    for marker in [
        "viewId === 'extensions'",
        "loadExtensions()",
        "role=\"button\"",
        "tabindex=\"0\"",
    ]:
        assert marker in sidebar_views, marker

    for marker in [
        "viewId === 'debug'",
        "sendDebugStateRpc('debug/launchConfigurations'",
        "sendDebugStateRpc('debug/advancedBreakpoints'",
        "debugLaunchConfigs",
        "debugLaunchCompounds",
        "debugLaunchSchemaValid",
        "selectedDebugLaunch",
        "startDebug",
        "runDebugCommand",
        "stopDebug",
        "debugPaused",
        "debugMessage",
        "loadDebugRuntimeDetails",
        "debugStackFrames",
        "debugVariables",
        "debugWatches",
        'title="Select launch configuration"',
        'title="Edit launch.json"',
        'role="toolbar"',
        'aria-label="Variables"',
        "No launch configuration found",
        "Add a valid launch configuration",
        "debug-launch-meta",
        "debug-advanced-breakpoints",
        "preLaunchTask",
        "postDebugTask",
    ]:
        assert marker in sidebar_views, marker

    for marker in [
        'role="dialog"',
        'aria-modal="true"',
        "handleKeydown",
        "Promise.allSettled(writes.map",
        "Saving settings…",
        "Retry Save",
        "files.autoSave",
        "wizp-extension-settings",
        "SHORTCUTS",
        'aria-label={\'Keybinding for \' + kb.command}',
    ]:
        assert marker in settings, marker
    assert "view: 'hub'" in activity and "shortcutFor('view.extensions')" in activity
    for marker in [
        "sendRpc('hub/search'",
        "allowNetwork",
        "Allow OpenVSX Search",
        "sendRpc('hub/list'",
        "sendRpc('hub/install'",
        "sendRpc('hub/installLocal'",
        "sendRpc('hub/uninstall'",
        "sendRpc('hub/toggle'",
        "sendRpc('hub/markRestarted'",
        "sendRpc('extension/hostStatus'",
        "sendRpc('extension/restartHost'",
        "sendRpc('extension/contributionSnapshot'",
        "extensions:refreshed",
        "Install from VSIX",
        "Restart the extension host",
        "Contributions",
        "Open Extension Settings",
        "Install",
        "Uninstall",
        "Disable",
        "Enable",
    ]:
        assert marker in hub, marker
    for marker in [
        "invokeExtensionLsp('extension/invokeCompletion'",
        "invokeExtensionLsp('extension/invokeHover'",
        "invokeExtensionLsp('extension/invokeDefinition'",
        "invokeExtensionLsp('extension/invokeReference'",
        "invokeExtensionLsp('extension/invokeRename'",
        "invokeExtensionLsp('extension/invokeCodeAction'",
        "sendRpcFields('extension/didChangeTextDocument'",
    ]:
        assert marker in editor, marker
    assert "http://127.0.0.1:9876/api/rpc" not in editor
    command_palette = (FRONTEND / "components" / "CommandPalette.svelte").read_text()
    for marker in [
        "sendRpc('extension/tasks'",
        "sendRpc('extension/uiReply'",
    ]:
        assert marker in command_palette, marker
    assert "http://127.0.0.1:9876/api/" not in command_palette
    assert "B3 demo" not in hub and "example.com" not in hub


def test_monaco_render_apply_wiring() -> None:
    editor = (FRONTEND / "components" / "EditorArea.svelte").read_text()
    sidebar_views = (FRONTEND / "components" / "SidebarViews.svelte").read_text()
    titlebar = (FRONTEND / "components" / "Titlebar.svelte").read_text()

    for marker in [
        "'semanticHighlighting.enabled': true",
        "monaco.languages.registerCompletionItemProvider('*'",
        "monaco.languages.registerHoverProvider('*'",
        "monaco.languages.registerDefinitionProvider('*'",
        "monaco.languages.registerReferenceProvider('*'",
        "monaco.languages.registerRenameProvider('*'",
        "monaco.languages.registerCodeActionProvider('*'",
        "monaco.languages.registerInlayHintsProvider('*'",
        "monaco.languages.registerCodeLensProvider('*'",
        "monaco.languages.registerFoldingRangeProvider('*'",
        "sendRpc('textDocument/inlayHint'",
        "sendRpc('extension/codeLenses'",
        "sendRpc('extension/foldingRanges'",
        "pane.editor.deltaDecorations",
        "pane.bpDeco",
        "pane.blameDeco",
        "blame?.lines || []",
        "inlineClassName: 'git-blame-annotation'",
        "editor.action.triggerSuggest",
        "editor.action.formatDocument",
        "editor.action.revealDefinition",
        "editor.action.peekDefinition",
        "editor.action.goToReferences",
        "__runMonacoVisualSmoke",
        "wizp-monaco-decoration-smoke",
        "wizp-monaco-codelens-smoke",
        "wizp-monaco-inlay-smoke",
        "wizp-semantic-smoke-token",
        "wizp-find-smoke-match",
        "wizp-snippet-smoke",
        "monaco-visual-smoke-diff",
    ]:
        assert marker in editor, marker

    assert "sendRpc('git/diff'" in sidebar_views and "codicon-diff" in sidebar_views
    assert "__triggerEditorAction?.('actions.find')" in titlebar


def test_scm_ui_binding_wiring() -> None:
    sidebar_views = (FRONTEND / "components" / "SidebarViews.svelte").read_text()

    for marker in [
        "sendRpc('scm/resources'",
        "scmResourceGroups",
        "normalizeScmResource",
        "sourceControlLabel",
        "Staged Changes",
        "Merge Changes",
        "group.resources",
        "onclick={() => void stageFile(resource.file)}",
        "onclick={() => void unstageFile(resource.file)}",
        "openDiscardDialog(resource, event)",
        "onclick={() => void showDiff(resource)}",
        "showConflict",
        "resolveConflict",
        "sendRpc('git/conflict'",
        "sendRpc('git/resolveConflict'",
        "sendRpc('git/show'",
        "checkoutScmBranch",
        "scmDiscardDialog",
        "Stage at least one file before committing.",
        "Accept Current",
        "Accept Incoming",
        "Accept Both",
        "Mark Resolved",
        "scm-conflict-preview",
        "loadScmRemotes",
        "runRemoteAction",
        "sendRpc('git/remotes'",
        "sendRpc('git/remoteCredentialPromptPlan'",
        "sendRpc(`git/${action}`",
        "scmRemotePromptPlan",
        "scm-remote-prompt-plan",
        "data-manual-only",
        "data-opt-in",
        "Remotes",
        "Fetch",
        "Pull",
        "Push",
        "Sync",
        "Preview",
        "scm-remote-panel",
        "loadScmTimeline",
        "sendRpc('git/timeline'",
        "scmTimelineOpen",
        "Timeline",
        "codicon-git-commit",
        "_updateScmFromExtension",
        "scmProvider = 'extension'",
    ]:
        assert marker in sidebar_views, marker




def test_task_ui_binding_wiring() -> None:
    panel = (FRONTEND / "components" / "Panel.svelte").read_text()
    command_palette = (FRONTEND / "components" / "CommandPalette.svelte").read_text()

    for marker in [
        "window.addEventListener('wizpTaskExecute'",
        "sendRpc('tasks/run'",
        "background: task.background === true",
        "__appendOutput?.('Tasks'",
        "Array.isArray(result.problems)",
        "source: task.label || 'task'",
        "problems:updated",
        "const sent = await ref.sendText(command)",
        "__lastTaskUiResult",
        "__lastTaskTerminalMirror",
        "__lastTaskProblems",
        "__getActiveTerminalSmoke",
    ]:
        assert marker in panel, marker

    for marker in [
        "wizpTaskExecute",
        "tasks.forEach",
        "detail: t",
    ]:
        assert marker in command_palette, marker


def main() -> int:
    if not DEFAULT_BIN.exists():
        raise SystemExit(f"missing daemon binary: {DEFAULT_BIN}; run npm run build first")

    test_editor_settings_wiring()
    test_p9_browser_ux_hardening_wiring()
    test_monaco_render_apply_wiring()
    test_task_ui_binding_wiring()

    with tempfile.TemporaryDirectory(prefix="wizp-parity-frontend-") as tmp:
        cwd = Path(tmp)
        (cwd / "app.zig").write_text("const App = struct {\n  pub fn init() App { return .{}; }\n};\npub fn main() void {}\n")
        (cwd / "src").mkdir()
        (cwd / "src" / "lib.zig").write_text("pub fn helper() void {}\n")
        client = RpcClient(cwd, env={"WIZP_NATIVE_SAVE_DIALOG_PATH": "app.zig"})
        try:
            folder = client.call("file/open-folder-dialog", {"path": str(cwd)})
            assert folder["path"] == str(cwd)
            listed = client.call("file/list", {"path": "."})
            assert any(item["name"] == "app.zig" for item in listed["files"])
            src_listed = client.call("file/list", {"path": str(cwd / "src")})
            assert any(item["name"] == "lib.zig" for item in src_listed["files"])

            opened = client.call("file/read", {"path": "app.zig"})
            assert "pub fn main" in opened["content"]
            symbols = client.call("textDocument/documentSymbol", {"uri": "file://" + str(cwd / "app.zig")})
            symbol_names = {item["name"] for item in symbols}
            assert {"App", "main"} <= symbol_names, symbols
            app_symbol = next(item for item in symbols if item["name"] == "App")
            assert app_symbol["children"][0]["name"] == "init", app_symbol
            saved = client.call("file/save-dialog", {"defaultPath": "app.zig"})
            assert saved["path"] == "app.zig"
            assert client.call("config/set", {"key": "editor.minimap.enabled", "value": "false", "scope": "user"}) is True
            assert client.call("config/get", {"key": "editor.minimap.enabled", "scope": "user"})["value"] == "false"
            assert client.call("config/set", {"key": "editor.wordWrapColumn", "value": "100", "scope": "user"}) is True
            assert client.call("config/get", {"key": "editor.wordWrapColumn", "scope": "user"})["value"] == "100"
            themes = client.call("theme/list", {})["themes"]
            assert "one-dark" in themes and "paseo" in themes
            applied_theme = client.call("theme/apply", {"name": "paseo"})
            assert applied_theme["background"] == "rgb(0,0,0)", applied_theme
            assert applied_theme["foreground"] == "rgb(228,228,231)", applied_theme
            assert applied_theme["selection"] == "rgb(39,39,42)", applied_theme
            applied_theme = client.call("theme/apply", {"name": "one-dark"})
            assert applied_theme["background"].startswith("rgb("), applied_theme
            assert applied_theme["foreground"].startswith("rgb("), applied_theme
            assert applied_theme["selection"].startswith("rgb("), applied_theme

            commands = client.call("extension/commands", {})["commands"]
            assert any(command["command"] == "workbench.action.files.openFolder" for command in commands)
            assert client.call("extension/execute", {"command": "workbench.action.files.openFolder"})["ok"] is True

            first_terminal = client.call("terminal/spawn", {})
            second_terminal = client.call("terminal/spawn", {})
            assert first_terminal["pid"] != 0
            assert second_terminal["pid"] != 0
            assert first_terminal["id"] != second_terminal["id"]
            assert first_terminal["backend"] in {"zigpty", "ghostty (experimental)"}, first_terminal
            assert first_terminal["renderer"] == "xterm.js", first_terminal
            assert isinstance(first_terminal["ghosttyAvailable"], bool), first_terminal
            assert isinstance(first_terminal["ghosttyEnabled"], bool), first_terminal
            assert first_terminal["nativeRendererBridge"] == (first_terminal["ghosttyAvailable"] and first_terminal["ghosttyEnabled"]), first_terminal
            assert isinstance(first_terminal["ghosttyRuntimeLoaded"], bool), first_terminal
            client.call("terminal/write", {"id": first_terminal["id"], "data": "printf WIZP_FRONTEND_ONE\\n"})
            client.call("terminal/write", {"id": second_terminal["id"], "data": "printf WIZP_FRONTEND_TWO\\n"})
            first_output = wait_for_terminal_text(client, "WIZP_FRONTEND_ONE", terminal_id=first_terminal["id"])
            second_output = wait_for_terminal_text(client, "WIZP_FRONTEND_TWO", terminal_id=second_terminal["id"])
            assert "WIZP_FRONTEND_TWO" not in first_output
            assert "WIZP_FRONTEND_ONE" not in second_output

            stress_terminal = client.call("terminal/spawn", {"shell": "/bin/sh", "cwd": str(cwd)})
            rss_before = process_rss_bytes(client.proc.pid)
            client.call("terminal/write", {"id": stress_terminal["id"], "data": "head -c 20000000 /dev/zero | tr '\\0' X\n"})
            time.sleep(0.75)
            stress_bytes = 0
            dropped_bytes = 0
            stress_sample = {}
            stress_deadline = time.time() + 4.0
            while time.time() < stress_deadline:
                stress_sample = client.call("terminal/read", {"id": stress_terminal["id"]})
                encoded = stress_sample.get("data", "")
                if encoded:
                    stress_bytes += len(base64.b64decode(encoded))
                dropped_bytes += int(stress_sample.get("droppedBytes", 0))
                if stress_sample.get("eof"):
                    break
                if stress_bytes + dropped_bytes >= 20_000_000:
                    break
                time.sleep(0.05)
            rss_after = process_rss_bytes(client.proc.pid)
            assert isinstance(stress_sample.get("droppedBytes", 0), int), stress_sample
            assert dropped_bytes >= 0, dropped_bytes
            assert stress_bytes + dropped_bytes >= 1_000_000, (stress_bytes, dropped_bytes, stress_sample)
            assert dropped_bytes <= 20_000_000, dropped_bytes
            assert rss_after - rss_before <= 64 * 1024 * 1024, (rss_before, rss_after, stress_sample)
            child_identity_before_kill = process_identity(int(stress_terminal["pid"]))
            assert client.call("terminal/kill", {"id": stress_terminal["id"]}) is True
            active_terminal_rows = client.call("terminal/list").get("terminals", [])
            active_after_cleanup = [int(item["id"]) for item in active_terminal_rows]
            cleanup_verified = stress_terminal["id"] not in active_after_cleanup
            child_identity_after_kill = process_identity(int(stress_terminal["pid"]))
            child_state_after_kill = process_state(int(stress_terminal["pid"]))
            process_reaped = child_identity_before_kill is not None and (
                child_identity_after_kill is None
                or child_identity_after_kill["startTimeTicks"]
                != child_identity_before_kill["startTimeTicks"]
            )
            assert cleanup_verified, (stress_terminal["id"], active_after_cleanup)
            assert process_reaped, (stress_terminal["pid"], child_state_after_kill)
            resource_report = Path(__file__).resolve().parents[1] / "build" / "parity-stress" / "frontend-terminal-resource-report.json"
            resource_report.parent.mkdir(parents=True, exist_ok=True)
            resource_report.write_text(
                json.dumps(
                    {
                        "status": "linux-terminal-resource-smoke-passed",
                        "commandBytes": 20_000_000,
                        "observedBytes": stress_bytes,
                        "droppedBytes": dropped_bytes,
                        "rssBeforeBytes": rss_before,
                        "rssAfterBytes": rss_after,
                        "rssGrowthBytes": rss_after - rss_before,
                        "rssGrowthLimitBytes": 64 * 1024 * 1024,
                        "cleanupVerified": cleanup_verified,
                        "cleanupProbe": {
                            "terminalId": stress_terminal["id"],
                            "activeIdsAfterKill": active_after_cleanup,
                            "process": {
                                "pid": stress_terminal["pid"],
                                "stateAfterKill": child_state_after_kill,
                                "identityBeforeKill": child_identity_before_kill,
                                "identityAfterKill": child_identity_after_kill,
                                "reaped": process_reaped,
                            },
                        },
                        "platform": "linux",
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            assert client.call("terminal/kill", {"id": first_terminal["id"]}) is True
            assert client.call("terminal/kill", {"id": second_terminal["id"]}) is True

            matches = client.call("search/text", {"query": "main", "regex": False, "caseSensitive": True})["matches"]
            assert any(match["file"].endswith("app.zig") for match in matches)

            preview = client.call("search/preview", {"file": "app.zig", "query": "main", "replace": "entry"})
            assert preview["preview"] is True and preview["replacements"] >= 1, preview
            problems = client.call("editor/problems/query", {"groupByFile": True, "sort": "severity"})
            assert problems["navigation"]["next"] is True, problems
            assert client.call("notifications/list")["centerVisible"] is True
            assert client.call("accessibility/audit")["critical"] == 0
            sorted_editors = client.call("editor/openSorted", {"order": "asc", "rule": "name-local"})
            assert sorted_editors["openPositioning"] == "sort", sorted_editors
            crumb = client.call("breadcrumbs/navigate", {"path": str(cwd / "app.zig"), "symbol": "App"})
            assert crumb["jumped"] is True, crumb
            folder_crumb = client.call("breadcrumbs/interaction", {"type": "folder", "path": str(cwd / "src")})
            assert folder_crumb["action"] == "listDirectory" and folder_crumb["rpc"] == "file/list", folder_crumb
            assert folder_crumb["click"] is True and folder_crumb["keyboard"] is True, folder_crumb
            file_crumb = client.call("breadcrumbs/interaction", {"type": "file", "path": str(cwd / "app.zig")})
            assert file_crumb["action"] == "openFileSymbols" and file_crumb["rpc"] == "textDocument/documentSymbol", file_crumb
            symbol_crumb = client.call("breadcrumbs/interaction", {"type": "symbol", "path": str(cwd / "app.zig"), "symbol": "App"})
            assert symbol_crumb["action"] == "jumpToSymbol" and symbol_crumb["rpc"] == "editor/reveal", symbol_crumb
            assert symbol_crumb["overlapCritical"] == 0, symbol_crumb
            monaco_apply = client.call("editor/monacoRenderApply")
            assert monaco_apply["renderer"] == "monaco" and monaco_apply["preserveWizpUi"] is True, monaco_apply
            assert monaco_apply["features"]["diff"]["rpc"] == "file/diff", monaco_apply
            assert monaco_apply["features"]["find"]["render"] == "actions.find", monaco_apply
            assert monaco_apply["features"]["snippet"]["rpc"] == "textDocument/insertSnippet", monaco_apply
            assert monaco_apply["features"]["decorations"]["render"] == "deltaDecorations", monaco_apply
            assert monaco_apply["features"]["codeLens"]["rpc"] == "extension/codeLenses", monaco_apply
            assert monaco_apply["features"]["inlayHints"]["render"] == "registerInlayHintsProvider", monaco_apply
            assert monaco_apply["features"]["semanticTokens"]["render"] == "semanticHighlighting.enabled", monaco_apply
            assert monaco_apply["features"]["folding"]["rpc"] == "extension/foldingRanges", monaco_apply
            assert monaco_apply["largeFileDegrades"] is True and monaco_apply["overlapCritical"] == 0, monaco_apply
            management = client.call("extensions/management")
            assert management["source"] == "OpenVSX", management
            assert management["networkPolicy"] == "lazy-opt-in", management
            assert {"hub/search", "hub/list", "hub/install", "hub/installLocal", "hub/uninstall", "hub/toggle", "hub/markRestarted", "extension/hostStatus", "extension/restartHost"} <= set(management["uiRpcs"]), management
            assert management["supportsInstall"] and management["supportsUninstall"], management
            assert management["supportsLocalVSIX"] and management["supportsHostRestart"], management
            terminal_binding = client.call("terminal/uiBinding")
            assert terminal_binding["extensionCreated"] is True, terminal_binding
            assert terminal_binding["frontendEvent"] == "terminal:create-visible", terminal_binding
            assert terminal_binding["adoptsExistingSession"] is True, terminal_binding
            assert terminal_binding["xtermPane"] and terminal_binding["contextMenuCopy"], terminal_binding
            terminal_renderer = client.call("terminal/rendererEvidence")
            assert terminal_renderer["component"] == "Terminal.svelte", terminal_renderer
            assert terminal_renderer["linkAddon"] == "@xterm/addon-web-links", terminal_renderer
            assert terminal_renderer["searchAddon"] == "@xterm/addon-search", terminal_renderer
            assert terminal_renderer["serializeAddon"] == "@xterm/addon-serialize", terminal_renderer
            assert terminal_renderer["preservesTabs"] and terminal_renderer["findHighlight"], terminal_renderer
            assert terminal_renderer["commandDecorations"] is True, terminal_renderer
            task_binding = client.call("tasks/uiBinding")
            assert task_binding["event"] == "wizpTaskExecute", task_binding
            assert task_binding["discoverRpc"] == "tasks/discover", task_binding
            assert task_binding["runRpc"] == "tasks/run", task_binding
            assert task_binding["terminalMirror"] is True and task_binding["problemsPanel"] is True, task_binding
            assert task_binding["tasksJsonSchema"] == "2.0.0" and task_binding["backgroundMatchers"] is True, task_binding
            assert task_binding["backgroundLifecycle"] is True, task_binding
        finally:
            client.close()

    print("parity frontend smoke ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
