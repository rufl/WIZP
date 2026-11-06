#!/usr/bin/env python3
"""Guard the public WIZP shortcut and production-copy contract."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / "frontend" / "src"


def read(path: str) -> str:
    return (FRONTEND / path).read_text(encoding="utf-8")


def main() -> int:
    shortcuts = read("shortcuts.ts")
    keys = re.findall(r"keys: '([^']+)'", shortcuts)
    shortcut_ids = re.findall(r"^\s*'([^']+)':\s*\{", shortcuts, re.MULTILINE)
    assert keys and len(keys) == len(set(keys)), "shortcut registry has duplicate keys"
    assert len(shortcut_ids) == 36 and len(set(shortcut_ids)) == 36, "shortcut registry must expose 36 unique commands"
    titlebar = read("components/Titlebar.svelte")
    welcome = read("components/Welcome.svelte")
    dispatch_cases = re.findall(r"^\s*case '([^']+)':", titlebar, re.MULTILINE)
    assert len(dispatch_cases) == 35 and set(dispatch_cases) | {'preferences.settings'} == set(shortcut_ids), (
        f"shortcut dispatch coverage mismatch: {dispatch_cases!r}"
    )
    assert "preferences.settings" in titlebar and "__openSettings" in titlebar, "settings shortcut dispatch missing"
    dispatch_body = titlebar[titlebar.index("switch (shortcut)"): ]
    for marker in (
        "windowControl('close')",
        "__showQuickOpenAt?.('@')",
        "__switchSidebarView?.('explorer')",
        "__switchSidebarView?.('search')",
        "__switchSidebarView?.('scm')",
        "__switchSidebarView?.('debug')",
        "__switchSidebarView?.('hub')",
        "toggleSidebar()",
        "togglePanel()",
        "__triggerEditorAction?.('actions.find')",
        "__cycleEditorTab?.(1)",
        "__startDebugging?.()",
        "__runWithoutDebugging?.()",
        "__stopDebugging?.()",
        "__toggleBreakpointAtCursor?.()",
    ):
        assert marker in dispatch_body, marker
    settings = read("components/Settings.svelte")
    activity = read("components/ActivityBar.svelte")
    hub = read("components/Hub.svelte")
    app = read("App.svelte")
    bridge = (ROOT / "frontend" / "bridge.ts").read_text(encoding="utf-8")
    launcher = (ROOT / "src" / "bun" / "index.ts").read_text(encoding="utf-8")
    editor_source = (ROOT / "src" / "ui" / "Editor.zig").read_text(encoding="utf-8")
    logger = read("logger.ts")
    command_palette = read("components/CommandPalette.svelte")
    context_menu = read("components/ContextMenu.svelte")
    input_box = read("components/InputBox.svelte")
    quick_pick = read("components/QuickPick.svelte")
    search = read("components/Search.svelte")
    status_bar = read("components/StatusBar.svelte")
    toast = read("components/ToastContainer.svelte")
    tree_item = read("components/TreeItem.svelte")
    explorer = read("components/Explorer.svelte")
    sidebar = read("components/Sidebar.svelte")
    outline = read("components/OutlinePanel.svelte")
    sidebar_views = read("components/SidebarViews.svelte")
    debug_toolbar = read("components/DebugToolbar.svelte")
    panel = read("components/Panel.svelte")
    tab = read("components/Tab.svelte")
    editor_area = read("components/EditorArea.svelte")
    ui_prompts = read("components/UIPrompts.svelte")
    terminal = read("components/Terminal.svelte")

    surface_contracts = {
        "editor": (editor_area, ('role="tablist"', 'role="tabpanel"', 'aria-label={`Editor group')),
        "explorer": (explorer, ('role="tree"', 'aria-label="Workspace files"', 'role="alert"')),
        "search": (search, ('role="search"', 'aria-label="Search results"', 'aria-live="polite"')),
        "scm": (sidebar_views, ('aria-label="Git branch"', 'aria-label="Commit message"', 'role="alert"')),
        "extensions": (hub, ('Installed extensions', 'role="alert"', 'aria-live={message.kind')),
        "settings": (settings, ('role="dialog"', 'aria-modal="true"', 'aria-labelledby="settings-title"')),
        "terminal": (terminal, ('role="status"', 'aria-live="polite"', 'data-terminal-status')),
    }
    for surface, (source, markers) in surface_contracts.items():
        for marker in markers:
            assert marker in source, f"{surface} accessibility marker missing: {marker}"

    for marker in (
        "shortcutFor",
        "shortcutIdForEvent",
        "case 'debug.start'",
        "case 'debug.breakpoint'",
        "preferences.settings",
        "__openSettings",
        "Close All Editors",
    ):
        assert marker in titlebar, marker
    assert "File: Close All Editors" in command_palette
    input_guard_index = titlebar.index("e.target instanceof HTMLInputElement")
    assert titlebar.index("if (shortcut === 'command.palette')") < input_guard_index
    assert titlebar.index("if (shortcut === 'quick.open')") < input_guard_index
    assert titlebar.index("if (shortcut === 'file.close')") < input_guard_index
    assert "document.addEventListener('keydown', handleGlobalKeys, true)" in titlebar
    assert "async function focusQuickInput()" in command_palette
    assert "void renderFileSearch();" in command_palette
    for marker in ("SHORTCUTS", "WELCOME_SHORTCUTS"):
        assert marker in welcome, marker
    for marker in (
        "SHORTCUTS",
        "storedSettings",
        "loadTicket",
        "closeButton?.focus()",
        'id="settings-dialog"',
        "Saving settings…",
        "Retry Save",
        "files.autoSave",
        "wizp-extension-settings",
        "Promise.allSettled(writes.map",
    ):
        assert marker in settings, marker
    assert "shortcutFor('view.debug')" in activity
    for marker in ('aria-haspopup="dialog"', 'aria-controls="settings-dialog"', "event.currentTarget.focus()"):
        assert marker in activity, marker
    assert "wizp-debug-layout" not in app
    assert "Ctrl+Shift+D" not in logger
    assert "B3 demo" not in hub and "example.com" not in hub
    production_copy = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore")
        for root in (FRONTEND, ROOT / "frontend" / "dist")
        for path in root.rglob("*")
        if path.is_file() and path.suffix in {".css", ".html", ".js", ".svelte", ".ts"}
    )
    for forbidden in ("B3 demo", "example target", "internal milestone"):
        assert forbidden not in production_copy, forbidden
    for marker in (
        'role="tablist"',
        'role="tabpanel"',
        'role="search"',
        "showOpenFileDialog",
        "sendRpc('hub/installLocal'",
        "sendRpc('extension/hostStatus'",
        "sendRpc('extension/restartHost'",
        "sendRpc('extension/contributionSnapshot'",
        "sendRpc('hub/markRestarted'",
        "async function refreshAfterHostRestart()",
        "document.dispatchEvent(new CustomEvent('extensions:refreshed'))",
        "OpenVSX access stays off",
        "Restart the extension host",
        "Install from VSIX",
        "openUninstallDialog",
        "Open Extension Settings",
    ):
        assert marker in hub, marker
    assert "window.confirm" not in hub and "window.prompt" not in hub
    for marker in (
        "const NETWORK_REDACTION = '[redacted]'",
        "function sanitizeNetworkError",
        "https?|wss?",
        "Bearer",
        "access_token",
        "sanitizeNetworkError(result.error",
        "sanitizeNetworkError(cause, 'The extension service did not respond.')",
        "sanitizeNetworkError(cause, 'No extensions were changed.')",
        "failedSearchQuery = query",
        "failedInstallExtension = extension",
        "Retry search",
        "Retry install",
    ):
        assert marker in hub, marker
    assert "VSIX install failed: ${errorMessage" in hub
    retry_start = hub.index("async function retryHostRecovery()")
    retry_host = hub[retry_start:]
    for marker in (
        "if (operation || hostLoading) return;",
        "const previousHostError = hostError;",
        "await sendRpc('extension/restartHost', {});",
        "await loadHostState();",
        "previousHostError || errorMessage",
        'onclick={() => void retryHostRecovery()}',
        "disabled={!!operation || hostLoading}",
    ):
        assert marker in retry_host, marker

    for overlay in (command_palette, quick_pick):
        for marker in ('role="dialog"', 'role="combobox"', 'role="listbox"', 'role="option"'):
            assert marker in overlay, marker
    assert 'role="dialog"' in input_box and 'aria-modal="true"' in input_box
    assert "innerHTML" not in command_palette and "innerHTML" not in titlebar
    assert 'role="menu"' in context_menu and 'role="menuitem"' in context_menu
    assert "ArrowDown" in context_menu and "Escape" in context_menu
    assert 'role={toast.type === \'error\' ? \'alert\' : \'status\'}' in toast
    assert 'aria-live="polite"' in ui_prompts
    for marker in (
        'role="status"',
        'aria-live="polite"',
        'aria-atomic="true"',
        'class="visually-hidden"',
        "clearProcessAnnouncement();",
        "announceProcessExit(`Process exited with ${exitLabel}.`);",
        "terminal?.write(`\\r\\n\\x1b[90m[Process exited: ${exitLabel}]\\x1b[0m\\r\\n`);",
        "event.preventDefault();",
        "event.stopPropagation();",
        "void pasteText(text, 'native-clipboard');",
        "findLocalPathLinks",
        "normalizeTerminalPath",
        "activateTerminalPath",
        "terminal.registerLinkProvider",
        "data-terminal-last-path={lastDetectedPath}",
        "__openFile",
        "lastDetectedPath",
    ):
        assert marker in terminal, marker
    assert terminal.count('role="status"') == 1
    for marker in (
        'role="search"',
        'aria-label="Search results"',
        'aria-controls="search-details"',
        'role={searchMessage.kind === \'error\' ? \'alert\' : \'status\'}',
        "Search canceled.",
        "resultsTruncated",
        "replaceDialogOpen",
        "cannot be undone in WIZP",
        "Files already changed were not reverted.",
    ):
        assert marker in search, marker
    assert "resizeSidebarWithKeyboard" in app and "resizePaneWithKeyboard" in editor_area
    for marker in (
        "aria-label={`Resize sidebar with Left and Right Arrow keys; current width ${$sidebarWidth} pixels`}",
        "aria-label={`Resize panel with Up and Down Arrow keys; current height ${$panelHeight} pixels`}",
        "aria-label={`Resize right sidebar with Left and Right Arrow keys; current width ${$rsbWidth} pixels`}",
    ):
        assert marker in app, marker
    assert app.count("aria-label={`Resize") == 3
    assert app.count("onkeydown={resizeSidebarWithKeyboard}") == 1
    assert app.count("onkeydown={resizePanelWithKeyboard}") == 1
    assert app.count("onkeydown={resizeRightSidebarWithKeyboard}") == 1
    for marker in (
        "function mountEditorPane",
        "use:mountEditorPane",
        "wizp.closeEditor",
    ):
        assert marker in editor_area, marker
    for marker in (
        "wizpDaemonReconnected",
        "window.removeEventListener('wizpDaemonReconnected'",
        "reconnectRestoreGeneration",
        "preserveCurrent",
    ):
        assert marker in editor_area, marker
    for marker in (
        'aria-label="Split editor group right"',
        'aria-label="Split editor group down"',
        'aria-label="Create new file in editor group"',
        'aria-label="Close editor group"',
        'role="dialog"',
        'aria-modal="true"',
        'aria-labelledby="close-prompt-title"',
        'aria-describedby="close-prompt-message"',
    ):
        assert marker in editor_area, marker
    for marker in ("ArrowDown", "ArrowRight", "ArrowLeft", "Home", "F2", "Delete", "ContextMenu"):
        assert marker in tree_item, marker
    for marker in (
        'role="treeitem"',
        "aria-level={depth + 1}",
        "tabindex={selectedPath === item.path ? 0 : -1}",
        "Folder is empty.",
        "Could not open ${item.name}.",
    ):
        assert marker in tree_item, marker
    for marker in (
        "__newExplorerFile",
        "__newExplorerFolder",
        "validateExplorerName",
        "<dialog",
        'role="alert"',
        "This folder is empty.",
    ):
        assert marker in explorer, marker
    assert "window.prompt" not in explorer and "window.confirm" not in explorer

    for component in (explorer, search, settings):
        for marker in (
            "wizpDaemonDisconnected",
            "wizpDaemonReconnected",
            "window.removeEventListener('wizpDaemonDisconnected'",
            "window.removeEventListener('wizpDaemonReconnected'",
        ):
            assert marker in component, marker
    for marker in (
        "if (!daemonDisconnected)",
        "emitDaemonEvent('wizpDaemonDisconnected')",
        "if (daemonDisconnected)",
        "emitDaemonEvent('wizpDaemonReconnected')",
    ):
        assert marker in bridge, marker
    assert "export async function retryDaemonConnection(): Promise<boolean>" in bridge
    assert "const connected = await reconnectDaemon();" in bridge
    assert "function failPendingTransportRequests(message: string): void" in bridge
    assert "daemon disconnected: response stream closed" in bridge
    assert "pending.reject(failure);" in bridge
    for marker in (
        "backendId: session.backendId",
        "let terminalReconcileInFlight: Promise<void> | null = null;",
        "let terminalReconcileQueued = false;",
        "async function performTerminalOwnershipReconciliation(",
        "window.addEventListener('wizpDaemonReconnected', onDaemonReconnected)",
        "onSessionIdChange={(backendId, identity) =>",
    ):
        assert marker in panel, marker
    for marker in (
        "onSessionIdChange?: (sessionId: number | null, identity: string | null) => void;",
        "onSessionIdChange?.(sessionId, sessionIdentity);",
        "Keep the backend PTY alive across renderer teardown",
    ):
        assert marker in terminal, marker
    for marker in (
        "const MAX_ZIG_RESTART_ATTEMPTS = 3;",
        "let zigShutdownRequested = false;",
        "function stopZig()",
        "zigShutdownRequested = true;",
        "if (zigProcess !== child || zigShutdownRequested)",
        "function requestZigRestart()",
        'WIZP_PORT: String(WIZP_PORT)',
    ):
        assert marker in launcher, marker
    for marker in (
        "let daemonAnnouncement = $state('');",
        "let daemonConnectionState = $state<'connected' | 'disconnected' | null>(null);",
        "let daemonRetrying = $state(false);",
        "retryDaemonConnection as retryDaemonTransport",
        "async function retryDaemon()",
        "const connected = await retryDaemonTransport();",
        "Daemon disconnected. Reconnecting…",
        "Daemon reconnected.",
        'role="status"',
        'aria-live="polite"',
        'aria-atomic="true"',
        'role="alert"',
        "Retrying daemon connection…",
        "onclick={() => void retryDaemon()}",
    ):
        assert marker in app, marker
    assert app.count("window.addEventListener('wizpDaemonDisconnected'") == 1
    assert app.count("window.addEventListener('wizpDaemonReconnected'") == 1
    assert app.count("window.removeEventListener('wizpDaemonDisconnected'") == 1
    assert app.count("window.removeEventListener('wizpDaemonReconnected'") == 1
    assert app.count('role="status"') == 1
    assert app.count('aria-live="polite"') == 1
    assert "let explorerReconnectPending = false;" in explorer
    assert "if (explorerReconnectPending)" in explorer
    assert "let searchReconnectPending = false;" in search
    assert "if (!searchReconnectPending || searching || replacing || !query.trim()) return;" in search
    assert "let settingsReconnectPending = false;" in settings
    assert "if (!settingsReconnectPending || !isOpen || loading || saving) return;" in settings
    assert "preserveDraft && draftExtensionValues?.has(setting.key)" in settings
    assert "preserveDraft && draftKeybindingValues?.has(kb.command)" in settings
    assert "__newExplorerFile" in sidebar and "__newExplorerFolder" in sidebar
    assert "ctxMenuRequest" in app and "modalOpen()" in app
    assert "document.querySelectorAll<HTMLElement>('[aria-modal=\"true\"]')" in titlebar
    assert "status-static" in status_bar and "status-action" in status_bar
    assert "resource.id || resource.path || resource.file || resource.name" in sidebar_views
    for marker in (
        'aria-label="Git branch"',
        'aria-label="Commit message"',
        "scmDiscardDialog",
        "Delete untracked file?",
        "Discard file changes?",
        "Stage at least one file before committing.",
        "sendRpc('git/show'",
        'aria-label="Diff contents"',
        "res?.cancelled",
        "'Canceled'",
    ):
        assert marker in sidebar_views, marker
    assert "window.confirm" not in sidebar_views
    for marker in (
        'role="toolbar"',
        'aria-label="Launch configuration"',
        "debugMessage",
        "loadDebugRuntimeDetails",
        "debugAdapterLost",
        "Showing the last known inspection.",
        "Retry debugging",
        "Stop debugging",
        "debugStackFrames",
        "debugVariables",
        "debugWatches",
        "No launch configuration found",
        "runDebugCommand('debug/continue'",
        "runDebugCommand('debug/pause'",
        "runDebugCommand('debug/step'",
        "runDebugCommand('dap/restart'",
        "debugStartButton?.focus()",
        "aria-label={`Remove breakpoint from",
    ):
        assert marker in sidebar_views, marker
    for marker in (
        "adapterState",
        "adapterRecoverable",
        "debug_adapter_lost",
        "if (self.debug_adapter_lost) \"lost\"",
    ):
        assert marker in editor_source, marker
    for component in (panel, sidebar_views, outline):
        assert "e.key === ' '" in component, "Space activation missing"
        assert "e.preventDefault()" in component, "keyboard activation must prevent scrolling"
    assert "onkeydown={(event) => handleEditorGroupKeydown(event, vg.id)}" in editor_area
    assert "aria-label={`Editor group ${i + 1} editor surface`}" in editor_area
    for marker in (
        'role="toolbar"',
        "wizpDebugContinued",
        "wizpDebugStopped",
        "wizpDebugTerminated",
        "disabled={!paused || !!pending}",
    ):
        assert marker in debug_toolbar, marker
    for marker in (
        'role="log"',
        'aria-label="Debug Console output"',
        'aria-label="Debug expression"',
        "debugConsoleEvaluating",
        "Evaluation failed.",
    ):
        assert marker in panel, marker
    for marker in (
        "hasRecoveredContent",
        "Recovered ${recoveredDirtyEditors} unsaved editor",
        "await saveActiveEditorAs()",
        "Save As is unavailable. Your edits are still open; try another location.",
        "__closeAllEditors",
        "closeEditorTargetsSequentially",
    ):
        assert marker in editor_area, marker
    assert "unsaved changes" in tab and "data-dirty={dirty}" in tab

    print(
        f"UI contract ok: {len(keys)} public shortcuts, semantic overlays, live regions, editor recovery, Explorer/Search/SCM/Debug lifecycle, and extension host/install/contribution recovery"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
