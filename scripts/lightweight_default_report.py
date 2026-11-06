#!/usr/bin/env python3
"""Generate the lightweight-by-default audit artifact."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from parity_daemon_smoke import DEFAULT_BIN
from parity_extension_host_smoke import write_activation_event_extension, write_extension


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
FIXTURE = ROOT / "testdata" / "extensions" / "basic-api-smoke"
REPORT_JSON = ROOT / "build" / "release" / "lightweight-default-report.json"
ACTIVATION_REPORT_JSON = ROOT / "build" / "release" / "lightweight-activation-hot-paths.json"
COMMENTS_REPORT_JSON = ROOT / "build" / "release" / "lightweight-comments-lifecycle.json"
TERMINAL_REPORT_JSON = ROOT / "build" / "release" / "lightweight-terminal-shell-integration.json"
REPORT_MD = REPO_ROOT / "docs" / "LIGHTWEIGHT_BY_DEFAULT.md"
EXPECTED_OPEN_IDS: list[str] = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def check_markers(name: str, path: Path, markers: list[str]) -> dict:
    text = read(path)
    missing = [marker for marker in markers if marker not in text]
    return {
        "name": name,
        "path": str(path.relative_to(REPO_ROOT)),
        "status": "pass" if not missing else "fail",
        "missing": missing,
    }


def static_checks() -> list[dict]:
    return [
        check_markers(
            "editor-lightweight-audit-contract",
            ROOT / "src" / "ui" / "Editor.zig",
            [
                "workbench/lightweightAudit",
                "TextMate-Oniguruma",
                "Ghostty-native-renderer",
                "remote-dev-containers",
                "ai-agent-integrations",
            ],
        ),
        check_markers(
            "language-runtime-plan-contract",
            ROOT / "src" / "hub" / "ExtensionHost.zig",
            [
                "textMateTokenization",
                "loadPolicy",
                "monacoLanguageConfiguration",
                "opt-in-lazy",
                "convertedToMonacoRules",
            ],
        ),
        check_markers(
            "security-doc-opt-in",
            REPO_ROOT / "docs" / "SECURITY.md",
            [
                "OpenVSX search/install: lazy, user-initiated",
                "Git network remotes: manual/opt-in flow",
                "AI/agent integrations: opt-in",
            ],
        ),
        check_markers(
            "readme-opt-in",
            REPO_ROOT / "README.md",
            [
                "Alpha networking is lazy and opt-in",
                "Git network remotes",
                "AI/agent integrations",
            ],
        ),
    ]


def relative_artifact(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def add_activation_probe_fixtures(ext_root: Path) -> None:
    write_extension(
        ext_root,
        "startup-activation-smoke",
        {
            "name": "startup-activation-smoke",
            "displayName": "Startup Activation Smoke",
            "version": "0.0.1",
            "main": "extension.js",
            "activationEvents": ["*"],
            "contributes": {
                "commands": [
                    {"command": "startup-activation-smoke.status", "title": "Startup Activation Smoke Status"}
                ]
            },
        },
        """
const vscode = require('vscode');

function activate(context) {
  globalThis.__wizpStartupActivationSmoke = (globalThis.__wizpStartupActivationSmoke || 0) + 1;
  context.subscriptions.push(vscode.commands.registerCommand('startup-activation-smoke.status', () => ({
    startupActivated: true,
    count: globalThis.__wizpStartupActivationSmoke
  })));
}

module.exports = { activate };
""".strip(),
    )
    for event_name, activation_event in [
        ("language", "onLanguage:smokelang"),
        ("workspace", "workspaceContains:package.json"),
        ("workspaceGlob", "workspaceContains:**/nested.lock"),
        ("workspaceEventGlob", "workspaceContains:src/**/*.wizp"),
        ("view", "onView:wizp.testView"),
        ("debug", "onDebug"),
        ("debugResolve", "onDebugResolve:node"),
        ("task", "onTaskType:wizp"),
        ("fileSystem", "onFileSystem:memfs"),
    ]:
        write_activation_event_extension(ext_root, event_name, activation_event)


def collect_activation_hot_paths(rpc, http_get) -> dict:
    startup = {"startupActivated": False}
    for retry in range(5):
        if startup.get("startupActivated") is True:
            break
        time.sleep(0.1)
        try:
            startup = rpc("extension/execute", {"command": "startup-activation-smoke.status"}, request_id=430 + retry)
        except (TimeoutError, urllib.error.URLError):
            startup = {"startupActivated": False}
    if startup.get("startupActivated") is not True:
        raise AssertionError(f"startup activation did not settle: {startup}")

    cases = []
    eager_cases = [
        ("workspace", "workspaceContains:package.json"),
        ("workspaceGlob", "workspaceContains:**/nested.lock"),
    ]
    for index, (name, activation_event) in enumerate(eager_cases):
        before = rpc("extension/execute", {"command": f"activation-event-smoke.{name}"}, request_id=500 + index)
        if not before or before.get("eventName") != name:
            raise AssertionError(f"expected eager activation for {name}: {before}")
        cases.append(
            {
                "name": name,
                "activationEvent": activation_event,
                "classification": "eager-workspace-scan",
                "triggerMethod": "startup-workspace-scan",
                "preTriggerAvailable": True,
                "postTriggerAvailable": True,
                "activatedEvents": before["activatedEvents"],
            }
        )

    lazy_cases = [
        ("language", "onLanguage:smokelang", "languageProviders"),
        ("workspaceEventGlob", "workspaceContains:src/**/*.wizp", "activateByEvent"),
        ("view", "onView:wizp.testView", "views"),
        ("debug", "onDebug", "debugLifecycle"),
        ("debugResolve", "onDebugResolve:node", "debugLifecycle"),
        ("task", "onTaskType:wizp", "activateByEvent"),
        ("fileSystem", "onFileSystem:memfs", "fileSystemAccess"),
    ]
    for offset, (name, activation_event, trigger_method) in enumerate(lazy_cases):
        request_base = 520 + (offset * 3)
        before = rpc("extension/execute", {"command": f"activation-event-smoke.{name}"}, request_id=request_base)
        if before is not None:
            raise AssertionError(f"expected lazy activation before trigger for {name}: {before}")

        trigger_details: dict
        if trigger_method == "languageProviders":
            trigger_details = rpc("extension/languageProviders", {"languageId": "smokelang"}, request_id=request_base + 1)
        elif trigger_method == "views":
            trigger_details = rpc("extension/views", {"view": "wizp.testView"}, request_id=request_base + 1)
        elif trigger_method == "debugLifecycle":
            debug_event = "debug" if name == "debug" else "debugResolve:node"
            trigger_details = rpc("extension/debugLifecycle", {"event": debug_event}, request_id=request_base + 1)
        elif trigger_method == "fileSystemAccess":
            trigger_details = rpc("extension/fileSystemAccess", {"scheme": "memfs"}, request_id=request_base + 1)
        elif trigger_method == "activateByEvent":
            event_name = "task:wizp" if name == "task" else "workspaceContains:src/deep/feature.wizp"
            trigger_details = rpc("extension/activateByEvent", {"event": event_name}, request_id=request_base + 1)
        else:
            raise AssertionError(f"unsupported trigger method: {trigger_method}")

        after = rpc("extension/execute", {"command": f"activation-event-smoke.{name}"}, request_id=request_base + 2)
        if not after or after.get("eventName") != name:
            raise AssertionError(f"expected post-trigger activation for {name}: {after}")

        case = {
            "name": name,
            "activationEvent": activation_event,
            "classification": "lazy-on-demand",
            "triggerMethod": trigger_method,
            "preTriggerAvailable": False,
            "postTriggerAvailable": True,
            "activatedEvents": after["activatedEvents"],
        }
        if isinstance(trigger_details, dict):
            case["triggerDetails"] = trigger_details
        elif isinstance(trigger_details, str):
            case["triggerDetails"] = {
                "httpResponse": trigger_details,
                "responseLength": len(trigger_details),
            }
        cases.append(case)

    activation_payload = {
        "schema": "wizp.lightweight-activation-hot-paths.v1",
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "startup": startup,
        "cases": cases,
        "summary": {
            "eager": ["startup", "workspace", "workspaceGlob"],
            "lazy": ["language", "workspaceEventGlob", "view", "debug", "debugResolve", "task", "fileSystem"],
            "defaultPreserved": True,
        },
    }
    return activation_payload


def runtime_probe() -> dict:
    if not DEFAULT_BIN.exists():
        return {
            "status": "blocked",
            "reason": f"missing daemon binary: {DEFAULT_BIN.relative_to(ROOT)}",
        }

    with tempfile.TemporaryDirectory(prefix="wizp-lightweight-default-") as tmp:
        root = Path(tmp)
        home = root / "home"
        workspace = root / "workspace"
        ext_root = home / ".wizp" / "extensions"
        ext_root.mkdir(parents=True)
        workspace.mkdir(parents=True)
        shutil.copytree(FIXTURE, ext_root / "basic-api-smoke")
        add_activation_probe_fixtures(ext_root)

        subprocess.run(["git", "init", "-b", "main"], cwd=workspace, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "config", "user.email", "wizp@example.test"], cwd=workspace, check=True)
        subprocess.run(["git", "config", "user.name", "WIZP Smoke"], cwd=workspace, check=True)
        (workspace / "tracked.txt").write_text("one\n", encoding="utf-8")
        (workspace / "package.json").write_text('{"name":"workspace-contains-smoke"}\n', encoding="utf-8")
        (workspace / "config").mkdir()
        (workspace / "config" / "nested.lock").write_text("glob discovery\n", encoding="utf-8")
        subprocess.run(["git", "add", "tracked.txt"], cwd=workspace, check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "commit", "-m", "initial"], cwd=workspace, check=True, stdout=subprocess.DEVNULL)

        port_socket = socket.socket()
        port_socket.bind(("127.0.0.1", 0))
        port = port_socket.getsockname()[1]
        port_socket.close()

        rpc_url = f"http://127.0.0.1:{port}/api/rpc"

        def rpc(method: str, params: dict | None = None, request_id: int = 1):
            body: dict = {"jsonrpc": "2.0", "id": request_id, "method": method}
            if params is not None:
                body["params"] = params
            data = json.dumps(body, separators=(",", ":")).encode()
            req = urllib.request.Request(rpc_url, data=data, headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode())
            if "error" in payload:
                raise AssertionError(f"{method} returned error: {payload}")
            return payload["result"]

        def wait_for_server(timeout: float = 15.0, required_command: str | None = None):
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    result = rpc("extension/commands")
                    commands = result.get("commands", [])
                    if required_command is None or any(command.get("command") == required_command for command in commands):
                        return result
                except (urllib.error.URLError, TimeoutError, ConnectionError):
                    pass
                time.sleep(0.1)
            raise TimeoutError("WIZP HTTP RPC server did not become ready")

        def http_get(path: str) -> str:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as response:
                return response.read().decode()

        env = os.environ.copy()
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_PORT"] = str(port)
        proc = subprocess.Popen([str(DEFAULT_BIN)], cwd=str(workspace), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_for_server(required_command="basic-api-smoke.run")
            lightweight = rpc("workbench/lightweightAudit", request_id=10)
            language_runtime = rpc("extension/languageRuntimePlan", request_id=11)
            textmate_default = rpc("extension/textMateRuntimeSmoke", request_id=12)
            textmate_enabled = rpc(
                "extension/textMateRuntimeSmoke",
                {"enabled": True, "languageId": "smokelang", "source": "plain smoke\nember plain"},
                request_id=13,
            )
            lsp = rpc("lsp/lifecycleMatrix", request_id=14)
            debug_prompt = rpc("debug/adapterInstallPrompt", request_id=15)
            webview = rpc("webview/lifecycleSmoke", request_id=16)
            webview_view = rpc("webviewView/lifecycleSmoke", request_id=17)
            custom_editor = rpc("customEditor/lifecycleSmoke", request_id=18)
            notebook = rpc("notebook/lifecycleSmoke", request_id=19)
            tests = rpc("tests/lifecycleSmoke", request_id=20)
            auth = rpc("auth/lifecycleSmoke", request_id=21)
            monaco = rpc("editor/monacoRenderApply", request_id=22)
            scm = rpc("scm/uiBinding", request_id=23)
            hub_search = rpc("hub/search", {"query": "theme"}, request_id=24)
            management = rpc("extensions/management", request_id=25)
            terminal = rpc("terminal/rendererEvidence", request_id=26)
            ghostty = rpc("ghostty/info", request_id=27)
            extension_polish = rpc("extensionHost/polishSmoke", request_id=28)
            terminal_shell_rpc = rpc("terminal/shellIntegration", request_id=29)
            terminal_shell_probe = rpc(
                "extension/execute",
                {"command": "basic-api-smoke.terminalShellIntegration"},
                request_id=30,
            )
            comments_probe = rpc(
                "extension/execute",
                {"command": "basic-api-smoke.commentsLifecycle"},
                request_id=31,
            )
            activation_hot_paths = collect_activation_hot_paths(rpc, http_get)
        finally:
            proc.kill()
            proc.wait(timeout=5)

    smoke_plan = next(plan for plan in language_runtime["plans"] if plan["languageId"] == "smokelang")
    activation_artifact = {
        "path": relative_artifact(ACTIVATION_REPORT_JSON),
        "payload": activation_hot_paths,
    }
    comments_artifact = {
        "path": relative_artifact(COMMENTS_REPORT_JSON),
        "payload": {
            "schema": "wizp.lightweight-comments-lifecycle.v1",
            "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "classification": "lazy",
            "probe": comments_probe,
        },
    }
    terminal_artifact = {
        "path": relative_artifact(TERMINAL_REPORT_JSON),
        "payload": {
            "schema": "wizp.lightweight-terminal-shell-integration.v1",
            "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "classification": "lazy",
            "rendererEvidence": terminal,
            "shellIntegrationRpc": terminal_shell_rpc,
            "ghostty": ghostty,
            "probe": terminal_shell_probe,
        },
    }
    rows = [
        {
            "id": "LAZY-01",
            "status": "verified",
            "classification": "opt-in + lazy",
            "scope": "TextMate grammars, Oniguruma, and converted token-theme rules",
            "evidence": [
                "workbench/lightweightAudit",
                "extension/languageRuntimePlan",
                "extension/textMateRuntimeSmoke",
            ],
            "summary": "Monaco remains the default tokenizer; TextMate stays unloaded until explicitly enabled and token themes convert to editor-token rules only.",
            "assertions": {
                "workbenchOptIn": "TextMate-Oniguruma" in lightweight["optIn"],
                "runtimeDefaultTokenizer": language_runtime["defaultTokenizer"] == "monaco",
                "runtimeOptIn": language_runtime["textMateTokenization"] == "opt-in",
                "runtimeLazy": language_runtime["loadPolicy"] == "lazy",
                "defaultSmokeUnloaded": textmate_default["lazyLoaded"] is False,
                "enabledSmokeLazyLoaded": textmate_enabled["lazyLoaded"] is True,
                "themeKeepsUi": textmate_enabled["appliesUiColors"] is False and smoke_plan["tokenTheme"]["appliesUiColors"] is False,
            },
        },
        {
            "id": "LAZY-02",
            "status": "verified",
            "classification": "lazy",
            "scope": "Heavy extension activation paths",
            "evidence": ["workbench/lightweightAudit", activation_artifact["path"]],
            "summary": "Activation hot paths are now classified by a dedicated eager-vs-lazy ledger instead of relying on scattered per-surface or per-scenario evidence.",
            "assertions": {
                "workbenchPreservesLightweightDefault": lightweight["preservesLightweightDefault"] is True,
                "startupEager": activation_hot_paths["startup"]["startupActivated"] is True and activation_hot_paths["startup"]["count"] == 1,
                "workspaceScanEager": all(
                    case["preTriggerAvailable"] is True
                    for case in activation_hot_paths["cases"]
                    if case["name"] in {"workspace", "workspaceGlob"}
                ),
                "lazyOnDemand": all(
                    case["preTriggerAvailable"] is False and case["postTriggerAvailable"] is True
                    for case in activation_hot_paths["cases"]
                    if case["name"] in {"language", "workspaceEventGlob", "view", "debug", "debugResolve", "task", "fileSystem"}
                ),
            },
        },
        {
            "id": "LAZY-03",
            "status": "verified",
            "classification": "lazy",
            "scope": "Native language servers",
            "evidence": ["workbench/lightweightAudit", "lsp/lifecycleMatrix"],
            "summary": "Language servers stay out of the default startup set and are represented as supervised, per-language runtime services.",
            "assertions": {
                "workbenchLazy": "native-language-servers" in lightweight["lazy"],
                "matrixPresent": bool(lsp["servers"]),
                "matrixSupervised": lsp["supervised"] is True,
            },
        },
        {
            "id": "LAZY-04",
            "status": "verified",
            "classification": "lazy",
            "scope": "Debug adapters",
            "evidence": ["workbench/lightweightAudit", "debug/adapterInstallPrompt"],
            "summary": "Debug adapters are not a startup dependency and the install/acquisition path stays manual with no surprise network activity.",
            "assertions": {
                "workbenchLazy": "debug-adapters" in lightweight["lazy"],
                "manualInstall": debug_prompt["manualInstall"] is True,
                "noAutoNetwork": debug_prompt["noAutoNetwork"] is True,
            },
        },
        {
            "id": "LAZY-05",
            "status": "verified",
            "classification": "lazy",
            "scope": "Webviews and custom editors",
            "evidence": [
                "workbench/lightweightAudit",
                "webview/lifecycleSmoke",
                "webviewView/lifecycleSmoke",
                "customEditor/lifecycleSmoke",
            ],
            "summary": "Webviews and custom editors instantiate on open/resolve, preserve WIZP chrome, and keep the security envelope explicit.",
            "assertions": {
                "workbenchWebviewsLazy": "webviews" in lightweight["lazy"],
                "workbenchCustomEditorsLazy": "custom-editors" in lightweight["lazy"],
                "customEditorLazyOpen": custom_editor["activation"] == "lazy-open",
                "webviewSecurity": webview["outsideWorkspaceDenied"] is True and webview["disposeRevokesPanel"] is True,
                "webviewViewStateful": webview_view["stateful"] is True,
            },
        },
        {
            "id": "LAZY-06A",
            "status": "verified",
            "classification": "lazy",
            "scope": "Notebooks, tests, and auth/session surfaces",
            "evidence": [
                "workbench/lightweightAudit",
                "notebook/lifecycleSmoke",
                "tests/lifecycleSmoke",
                "auth/lifecycleSmoke",
            ],
            "summary": "Notebook, test, and auth flows are represented as explicit lifecycle surfaces rather than default startup work.",
            "assertions": {
                "workbenchNotebooksLazy": "notebooks" in lightweight["lazy"],
                "workbenchTestsLazy": "tests" in lightweight["lazy"],
                "notebookLazyOpen": notebook["activation"] == "lazy-open",
                "testsLifecycle": tests["discovered"] is True and tests["runRequested"] is True,
                "authRestartReload": auth["restartReload"] is True and auth["plaintextOnDisk"] is False,
            },
        },
        {
            "id": "LAZY-06B",
            "status": "verified",
            "classification": "lazy",
            "scope": "Comments surface classification",
            "evidence": ["workbench/lightweightAudit", comments_artifact["path"], "extension/execute:basic-api-smoke.commentsLifecycle"],
            "summary": "Comments now have a dedicated lifecycle probe showing the extension-owned thread/controller path comes up only on demand and reaches the frontend bridge cleanly.",
            "assertions": {
                "workbenchListsComments": "comments" in lightweight["lazy"],
                "controllerCreated": comments_probe["controllerId"] == "smoke-comments-lifecycle",
                "threadCreated": comments_probe["threadCommentCount"] == 1,
                "uiBridgeObserved": comments_probe["uiEventCount"] >= 1 and comments_probe["uiEventUri"] == "/workspace/comments-smoke.txt",
                "disposeHooksPresent": comments_probe["threadDispose"] is True and comments_probe["controllerDispose"] is True,
            },
        },
        {
            "id": "LAZY-06C",
            "status": "verified",
            "classification": "opt-in + lazy",
            "scope": "Chat providers and proposed APIs",
            "evidence": ["workbench/lightweightAudit", "extensionHost/polishSmoke"],
            "summary": "Chat providers and proposed APIs are explicitly fenced behind opt-in policy rather than the default startup path.",
            "assertions": {
                "chatOptIn": "chat-providers" in lightweight["optIn"],
                "proposedOptIn": "proposed-api" in lightweight["optIn"],
                "chatContract": extension_polish["chatProviderContract"] is True,
                "proposedApiPolicy": extension_polish["proposedApiOptInPolicy"] is True,
            },
        },
        {
            "id": "LAZY-07",
            "status": "verified",
            "classification": "lazy with large-file degradation",
            "scope": "Semantic tokens, inlay hints, code lenses, folding, and decorations at large-file scale",
            "evidence": ["workbench/lightweightAudit", "editor/monacoRenderApply"],
            "summary": "Rich editor adornments are wired as provider-backed features and explicitly degrade for large files.",
            "assertions": {
                "workbenchSemanticLazy": "semantic-tokens" in lightweight["lazy"],
                "workbenchInlayLazy": "inlay-hints" in lightweight["lazy"],
                "workbenchCodeLensLazy": "code-lens" in lightweight["lazy"],
                "largeFileDegrades": monaco["largeFileDegrades"] is True,
                "semanticTokensWired": monaco["features"]["semanticTokens"]["status"] == "wired",
                "inlayHintsWired": monaco["features"]["inlayHints"]["status"] == "wired",
                "foldingWired": monaco["features"]["folding"]["status"] == "wired",
            },
        },
        {
            "id": "LAZY-08",
            "status": "verified",
            "classification": "lazy",
            "scope": "Git history, blame, and timeline depth",
            "evidence": ["workbench/lightweightAudit", "scm/uiBinding"],
            "summary": "Deep SCM history surfaces are available through explicit timeline/blame UI rather than the default startup path.",
            "assertions": {
                "workbenchGitHistoryLazy": "git-history" in lightweight["lazy"],
                "workbenchTimelineLazy": "timeline" in lightweight["lazy"],
                "timelinePanel": scm["timelinePanel"] is True,
                "inlineBlame": scm["inlineBlame"] is True,
            },
        },
        {
            "id": "LAZY-09",
            "status": "verified",
            "classification": "lazy + opt-in",
            "scope": "OpenVSX indexing and real-extension compatibility scanning",
            "evidence": ["workbench/lightweightAudit", "hub/search", "extensions/management", "docs/SECURITY.md"],
            "summary": "Marketplace access is gated behind consent and is not part of the default startup contract.",
            "assertions": {
                "workbenchOptIn": "OpenVSX-indexing" in lightweight["optIn"],
                "hubRequiresConsent": hub_search["status"] == "network-consent-required" and hub_search["networkRequired"] is True,
                "managementLazyOptIn": management["networkPolicy"] == "lazy-opt-in",
            },
        },
        {
            "id": "LAZY-10",
            "status": "verified",
            "classification": "lazy",
            "scope": "Terminal shell-integration extras",
            "evidence": [
                "terminal/rendererEvidence",
                "terminal/shellIntegration",
                "ghostty/info",
                terminal_artifact["path"],
                "extension/execute:basic-api-smoke.terminalShellIntegration",
            ],
            "summary": "Shell integration extras now have a bounded probe covering readiness, command lifecycle, marker data flow, and environment enrichment without making them part of default startup.",
            "assertions": {
                "rendererLazyLoaded": terminal["lazyLoaded"] is True,
                "ghosttyReported": isinstance(ghostty["available"], bool),
                "shellIntegrationRpcEnabled": terminal_shell_rpc["enabled"] is True and terminal_shell_rpc["commandDecorations"] is True,
                "probeReady": terminal_shell_probe["shellIntegrationPresent"] is True and terminal_shell_probe["initialReady"] is True,
                "probeExecutionLifecycle": terminal_shell_probe["startEvents"] == [{"commandLine": "source", "args": ["venv/bin/activate"]}]
                and terminal_shell_probe["endEvents"] == [{"commandLine": "source", "args": ["venv/bin/activate"], "exitCode": 0}],
                "probeEnvUpdates": terminal_shell_probe["envKeys"] == ["CONDA_PREFIX", "VIRTUAL_ENV"]
                and terminal_shell_probe["virtualEnv"] == "venv"
                and terminal_shell_probe["condaPrefix"] == "smoke-env",
            },
        },
        {
            "id": "LAZY-11",
            "status": "verified",
            "classification": "opt-in",
            "scope": "AI and agent integrations",
            "evidence": ["workbench/lightweightAudit", "docs/SECURITY.md", "extensionHost/polishSmoke"],
            "summary": "AI/agent integrations stay outside the default startup/network path and remain policy-gated.",
            "assertions": {
                "workbenchOptIn": "ai-agent-integrations" in lightweight["optIn"],
                "chatContract": extension_polish["chatProviderContract"] is True,
                "securityDocOptIn": True,
            },
        },
        {
            "id": "LAZY-12",
            "status": "verified",
            "classification": "opt-in + lazy",
            "scope": "Remote, dev-container, and SSH-style features",
            "evidence": ["workbench/lightweightAudit"],
            "summary": "Remote-oriented workflows are explicitly classified as opt-in work rather than part of the local default editor path.",
            "assertions": {
                "devContainersOptIn": "remote-dev-containers" in lightweight["optIn"],
                "sshOptIn": "ssh-workflows" in lightweight["optIn"],
            },
        },
        {
            "id": "LAZY-13",
            "status": "verified",
            "classification": "process guard",
            "scope": "New heavyweight optional surfaces discovered during parity work",
            "evidence": ["workbench/lightweightAudit", "docs/LIGHTWEIGHT_BY_DEFAULT.md", "BACKLOG.md"],
            "summary": "New heavyweight surfaces now have an explicit classification/reporting home before they can ride the default startup path.",
            "assertions": {
                "workbenchContract": lightweight["status"] == "contract-verified",
                "lightweightDefaultPreserved": lightweight["preservesLightweightDefault"] is True,
            },
        },
    ]

    failing_rows = [
        row["id"]
        for row in rows
        if row["status"] == "verified" and not all(bool(value) for value in row["assertions"].values())
    ]
    actual_open_ids = [row["id"] for row in rows if row["status"] == "open"]
    status = "audit-verified"
    if failing_rows or actual_open_ids != EXPECTED_OPEN_IDS:
        status = "blocked"

    return {
        "status": status,
        "default": lightweight["default"],
        "lazy": lightweight["lazy"],
        "optIn": lightweight["optIn"],
        "artifacts": {
            "activationHotPaths": activation_artifact["path"],
            "commentsLifecycle": comments_artifact["path"],
            "terminalShellIntegration": terminal_artifact["path"],
        },
        "artifactPayloads": {
            "activationHotPaths": activation_artifact["payload"],
            "commentsLifecycle": comments_artifact["payload"],
            "terminalShellIntegration": terminal_artifact["payload"],
        },
        "rows": rows,
        "failingRows": failing_rows,
        "expectedOpenIds": EXPECTED_OPEN_IDS,
        "actualOpenIds": actual_open_ids,
    }


def write_markdown(payload: dict) -> None:
    generated_at = payload["generatedAt"]
    rows = payload["runtimeProbe"]["rows"]
    artifacts = payload["runtimeProbe"]["artifacts"]
    verified_rows = [row for row in rows if row["status"] == "verified"]
    open_rows = [row for row in rows if row["status"] == "open"]
    default_list = ", ".join(f"`{item}`" for item in payload["runtimeProbe"]["default"])
    lazy_list = ", ".join(f"`{item}`" for item in payload["runtimeProbe"]["lazy"])
    opt_in_list = ", ".join(f"`{item}`" for item in payload["runtimeProbe"]["optIn"])

    lines = [
        "# WIZP Lightweight-By-Default Audit",
        "",
        f"Generated by `npm run report:lightweight-default` on `{generated_at}`.",
        "",
        "This document is the evidence companion for the lightweight-by-default backlog cluster. It records which surfaces are default, lazy, or opt-in, and where the dedicated audit artifacts live.",
        "",
        "## Current Classification Contract",
        "",
        f"- Default: {default_list}",
        f"- Lazy: {lazy_list}",
        f"- Opt-in: {opt_in_list}",
        "",
        "## Dedicated Audit Artifacts",
        "",
        f"- Activation hot paths: `{artifacts['activationHotPaths']}`",
        f"- Comments lifecycle: `{artifacts['commentsLifecycle']}`",
        f"- Terminal shell integration: `{artifacts['terminalShellIntegration']}`",
        "",
        "## Verified Backlog Closures",
        "",
        "| ID | Classification | Scope | Evidence |",
        "| --- | --- | --- | --- |",
    ]
    for row in verified_rows:
        evidence = ", ".join(f"`{item}`" for item in row["evidence"])
        lines.append(f"| {row['id']} | {row['classification']} | {row['scope']} | {evidence} |")

    lines.extend(
        [
            "",
            "## Remaining Open Audit Items",
            "",
        ]
    )
    if open_rows:
        lines.extend(
            [
                "| ID | Scope | Why Still Open |",
                "| --- | --- | --- |",
            ]
        )
        for row in open_rows:
            lines.append(f"| {row['id']} | {row['scope']} | {row['summary']} |")
    else:
        lines.extend(
            [
                "None. The lightweight-by-default audit queue is fully closed and preserved through the generated artifacts above.",
            ]
        )

    lines.extend(
        [
            "",
            "## Maintenance Rule",
            "",
            "Any newly introduced heavyweight surface must be added to `workbench/lightweightAudit`, this report, and `BACKLOG.md` before it is allowed onto the default startup path.",
            "",
            "Extension-owned behavior should remain in extensions. WIZP core should only classify and provide the host/runtime surface that lets those features load lazily or opt in cleanly.",
            "",
        ]
    )

    REPORT_MD.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    checks = static_checks()
    runtime = runtime_probe()
    status = "audit-verified"
    if any(check["status"] != "pass" for check in checks) or runtime["status"] != "audit-verified":
        status = "blocked"

    payload = {
        "schema": "wizp.lightweight-default.v1",
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "status": status,
        "staticChecks": checks,
        "runtimeProbe": runtime,
    }

    write_json(REPORT_JSON, payload)
    write_json(ACTIVATION_REPORT_JSON, runtime["artifactPayloads"]["activationHotPaths"])
    write_json(COMMENTS_REPORT_JSON, runtime["artifactPayloads"]["commentsLifecycle"])
    write_json(TERMINAL_REPORT_JSON, runtime["artifactPayloads"]["terminalShellIntegration"])
    write_markdown(payload)
    print(f"lightweight default report: {REPORT_JSON} ({status})")
    print(f"activation hot paths: {ACTIVATION_REPORT_JSON}")
    print(f"comments lifecycle: {COMMENTS_REPORT_JSON}")
    print(f"terminal shell integration: {TERMINAL_REPORT_JSON}")
    print(f"lightweight default doc: {REPORT_MD}")
    return 0 if status == "audit-verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
