#!/usr/bin/env python3
"""Daemon JSON-RPC parity smoke tests for WIZP.

Run after `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu`.
The harness talks to `wizp --daemon` over Content-Length framed stdio, matching
the Electrobun and extension transport path closely enough for RPC contracts.
"""

from __future__ import annotations

import json
import os
import base64
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BIN = ROOT / "zig-out" / "bin" / "wizp"


class RpcClient:
    def __init__(self, cwd: Path, binary: Path = DEFAULT_BIN, env: dict[str, str] | None = None) -> None:
        self.cwd = cwd
        self.next_id = 1
        child_env = os.environ.copy()
        if env:
            child_env.update(env)
        self.proc = subprocess.Popen(
            [str(binary), "--daemon"],
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env,
        )

    def close(self) -> None:
        self.proc.kill()
        self.proc.wait(timeout=5)

    def _read(self) -> dict:
        assert self.proc.stdout is not None
        header = b""
        deadline = time.time() + 10
        while b"\r\n\r\n" not in header:
            if time.time() > deadline:
                raise TimeoutError("timed out waiting for daemon response header")
            chunk = self.proc.stdout.read(1)
            if not chunk:
                err = self.proc.stderr.read().decode("utf-8", "replace") if self.proc.stderr else ""
                raise RuntimeError(f"daemon closed stdout: {err[-800:]}")
            header += chunk

        length = None
        for line in header.decode("ascii", "replace").split("\r\n"):
            if line.lower().startswith("content-length:"):
                length = int(line.split(":", 1)[1].strip())
                break
        if length is None:
            raise RuntimeError(f"missing Content-Length in {header!r}")
        return json.loads(self.proc.stdout.read(length).decode())

    def raw(self, method: str, params: dict | None = None) -> dict:
        assert self.proc.stdin is not None
        body: dict = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        self.next_id += 1
        if params is not None:
            body["params"] = params
        data = json.dumps(body, separators=(",", ":")).encode()
        self.proc.stdin.write(b"Content-Length: " + str(len(data)).encode() + b"\r\n\r\n" + data)
        self.proc.stdin.flush()
        return self._read()

    def call(self, method: str, params: dict | None = None):
        response = self.raw(method, params)
        if "error" in response:
            raise AssertionError(f"{method} returned error: {response}")
        return response["result"]


def write_ui_lifecycle_vsix(path: Path, name: str = "ui-lifecycle") -> None:
    package = {
        "name": name,
        "publisher": "wizp-smoke",
        "displayName": "UI Lifecycle Extension",
        "version": "1.0.0",
        "engines": {"vscode": "*"},
        "main": "./extension.js",
        "activationEvents": ["onCommand:wizp.uiLifecycle.hello"],
        "contributes": {
            "commands": [
                {"command": "wizp.uiLifecycle.hello", "title": "Run Lifecycle Command"}
            ],
            "configuration": {
                "title": "UI Lifecycle",
                "properties": {
                    "wizpUiLifecycle.enabled": {
                        "type": "boolean",
                        "default": True,
                        "description": "Enable the local extension lifecycle fixture.",
                    }
                },
            },
            "viewsContainers": {
                "activitybar": [
                    {"id": "wizp-ui-lifecycle", "title": "UI Lifecycle", "icon": "extensions"}
                ]
            },
            "views": {
                "wizp-ui-lifecycle": [
                    {"id": "wizp.uiLifecycle.view", "name": "Lifecycle View"}
                ]
            },
            "viewsWelcome": [
                {
                    "view": "wizp.uiLifecycle.view",
                    "contents": "The local lifecycle extension is ready.",
                }
            ],
        },
    }
    extension_js = """
const vscode = require('vscode');
exports.activate = function(context) {
  context.subscriptions.push(vscode.commands.registerCommand('wizp.uiLifecycle.hello', () => ({ message: 'lifecycle-command-ok' })));
};
exports.deactivate = function() {};
""".strip()
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("extension/package.json", json.dumps(package))
        archive.writestr("extension/extension.js", extension_js)


def test_git(client: RpcClient, cwd: Path) -> None:
    subprocess.run(["git", "init"], cwd=cwd, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "config", "user.email", "wizp@example.test"], cwd=cwd, check=True)
    subprocess.run(["git", "config", "user.name", "WIZP Smoke"], cwd=cwd, check=True)
    (cwd / "tracked.txt").write_text("one\n")
    assert client.call("git/status")["files"]
    model = client.call("git/model")
    assert model["provider"] == "git", model
    assert any(item["file"] == "tracked.txt" and item["group"] == "untracked" for item in model["resources"]), model
    assert client.call("git/stage", {"file": "tracked.txt"})["ok"] is True
    assert client.call("git/commit", {"message": "initial"})["ok"] is True
    (cwd / "tracked.txt").write_text("two\n")
    diff = client.call("git/diff", {"file": "tracked.txt"})
    assert "two" in diff["diff"]
    assert any(item["file"] == "tracked.txt" and item["group"] == "unstaged" for item in client.call("scm/resources")["resources"])
    assert client.call("git/stage", {"file": "tracked.txt"})["ok"] is True
    staged_diff = client.call("git/diff", {"file": "tracked.txt", "staged": True})
    assert "+two" in staged_diff["diff"], staged_diff
    assert any(item["file"] == "tracked.txt" and item["group"] == "staged" for item in client.call("git/model")["resources"])
    assert client.call("git/commit", {"message": "second"})["ok"] is True
    amended = client.call("git/commit", {"message": "second amended", "amend": True})
    assert amended["ok"] is True and amended["amend"] is True, amended

    branches = client.call("git/branch", {"op": "list"})["branches"]
    assert branches, branches
    assert client.call("git/branch", {"op": "create", "name": "feature"})["ok"] is True
    assert client.call("git/branch", {"op": "checkout", "name": "feature"})["ok"] is True
    (cwd / "feature.txt").write_text("feature\n", encoding="utf-8")
    assert client.call("git/stage", {"file": "feature.txt"})["ok"] is True
    assert client.call("git/commit", {"message": "feature commit"})["ok"] is True
    assert client.call("git/branch", {"op": "checkout", "name": branches[0]})["ok"] is True
    assert client.call("git/merge", {"branch": "feature"})["ok"] is True
    assert client.call("git/rebase", {"branch": "feature"})["ok"] is True
    assert client.call("git/branch", {"op": "delete", "name": "feature"})["ok"] is True

    bare_remote = cwd.parent / "origin.git"
    subprocess.run(["git", "init", "--bare", str(bare_remote)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "remote", "add", "origin", str(bare_remote)], cwd=cwd, check=True)
    remotes = client.call("git/remotes")
    assert remotes["credentialPolicy"] == "non-interactive" and remotes["networkLazy"] is True, remotes
    assert any(remote["name"] == "origin" for remote in remotes["remotes"]), remotes
    prompt_plan = client.call("git/remoteCredentialPromptPlan")
    assert prompt_plan["manualOnly"] is True and prompt_plan["optInRequired"] is True, prompt_plan
    assert prompt_plan["defaultPolicy"] == "non-interactive", prompt_plan
    assert prompt_plan["envFlag"] == "WIZP_SCM_NETWORK_PROMPTS", prompt_plan
    assert prompt_plan["promptUx"]["cancelDefault"] is True and prompt_plan["promptUx"]["storesNothingByDefault"] is True, prompt_plan
    assert {"preview", "blocked-needs-opt-in", "failed-auth", "cancelled"} <= set(prompt_plan["networkRemoteStates"]), prompt_plan
    assert prompt_plan["fixtureFlag"] == "credentialFixture", prompt_plan
    assert prompt_plan["fixtureEnvFlag"] == "WIZP_SCM_CREDENTIAL_FIXTURE", prompt_plan
    assert prompt_plan["fixtureMode"] == "cancel" and prompt_plan["fixtureLocalOnly"] is True, prompt_plan
    assert prompt_plan["fixtureStoresNothing"] is True, prompt_plan
    real_fetch = client.call("git/fetch", {"remote": "origin"})
    assert real_fetch["ok"] is True and real_fetch["dryRun"] is False and real_fetch["credentialSafe"] is True, real_fetch
    assert real_fetch["credentialPolicy"] == "non-interactive" and real_fetch["credentialPromptRequired"] is False, real_fetch
    cancelled = client.call("git/fetch", {"remote": "origin", "credentialFixture": "cancel"})
    assert cancelled["ok"] is False and cancelled["cancelled"] is True, cancelled
    assert cancelled["state"] == "cancelled" and cancelled["fixture"] is True, cancelled
    assert cancelled["networkAttempted"] is False and cancelled["credentialHelperInvoked"] is True, cancelled
    assert cancelled["credentialHelperOutcome"] == "cancelled", cancelled
    assert cancelled["secretPersisted"] is False and cancelled["secretEchoed"] is False, cancelled
    env_fixture_client = RpcClient(
        cwd,
        env={"HOME": str(cwd / "home"), "USERPROFILE": str(cwd / "home"), "WIZP_SCM_CREDENTIAL_FIXTURE": "cancel"},
    )
    try:
        env_cancelled = env_fixture_client.call("git/fetch", {"remote": "origin"})
    finally:
        env_fixture_client.close()
    assert env_cancelled["cancelled"] is True and env_cancelled["networkAttempted"] is False, env_cancelled
    assert env_cancelled["secretPersisted"] is False and env_cancelled["secretEchoed"] is False, env_cancelled

    assert "fixture-secret" not in json.dumps(cancelled), cancelled

    for method in ["git/fetch", "git/pull", "git/push", "git/sync"]:
        remote = client.call(method, {"remote": "origin", "dryRun": True})
        assert remote["ok"] is True and remote["dryRun"] is True and remote["credentialSafe"] is True, remote
        assert remote["credentialPolicy"] == "non-interactive" and remote["credentialPromptRequired"] is False, remote
        assert remote["commands"], remote

    blame = client.call("git/blame", {"file": "tracked.txt"})
    assert blame["lines"][0]["author"] == "WIZP Smoke", blame
    assert blame["lines"][0]["line"] == 1 and blame["lines"][0]["summary"], blame
    history = client.call("git/history")
    assert any(commit["subject"] == "feature commit" for commit in history["commits"]), history
    timeline = client.call("git/timeline")
    assert timeline["commits"][0]["hash"], timeline
    shown = client.call("git/show", {"commit": timeline["commits"][0]["hash"]})
    assert shown["commit"] == timeline["commits"][0]["hash"], shown
    assert "commit " in shown["diff"] and timeline["commits"][0]["subject"] in shown["diff"], shown
    invalid_show = client.raw("git/show", {"commit": "--help"})
    assert invalid_show.get("error", {}).get("code") == -32602, invalid_show
    providers = client.call("scm/providers")
    assert providers["providers"][0]["id"] == "git", providers
    assert providers["providers"][0]["supportsExtensionSourceControl"] is True, providers
    scm_ui = client.call("scm/uiBinding")
    assert scm_ui["resourcesRpc"] == "scm/resources", scm_ui
    assert scm_ui["diffRpc"] == "git/diff" and scm_ui["showRpc"] == "git/show", scm_ui
    assert scm_ui["timelineRpc"] == "git/timeline" and scm_ui["blameRpc"] == "git/blame", scm_ui
    assert scm_ui["conflictRpc"] == "git/conflict" and scm_ui["resolveConflictRpc"] == "git/resolveConflict", scm_ui
    assert scm_ui["remotesRpc"] == "git/remotes" and {"fetch", "pull", "push", "sync"} <= set(scm_ui["remoteActions"]), scm_ui
    assert {"merge", "staged", "unstaged", "untracked"} <= set(scm_ui["groups"]), scm_ui
    assert {"showCommit", "checkoutBranch", "acceptBoth"} <= set(scm_ui["actions"]), scm_ui
    assert scm_ui["inlineActions"] is True and scm_ui["resourceDecorations"] is True, scm_ui
    assert scm_ui["extensionSourceControl"] is True and scm_ui["timelinePanel"] is True and scm_ui["inlineBlame"] is True, scm_ui
    assert scm_ui["mergeEditor"] is True and scm_ui["conflictResolution"] is True, scm_ui
    assert scm_ui["remotePanel"] is True and scm_ui["remoteCredentialPolicy"] == "non-interactive", scm_ui
    extension_scm = client.call("scm/extensionProviderSmoke")
    assert extension_scm["provider"]["id"] == "smoke-scm" and extension_scm["provider"]["replacesNative"] is True, extension_scm
    assert extension_scm["resourceGroups"][0]["label"] == "Changes", extension_scm
    assert extension_scm["resourceGroups"][0]["resources"][0]["decorations"]["letter"] == "M", extension_scm
    assert extension_scm["selection"] and extension_scm["refresh"] and extension_scm["disposal"], extension_scm
    assert extension_scm["commands"] and extension_scm["decorations"] and extension_scm["frontendEvent"] == "wizpScmUpdate", extension_scm

    assert client.call("git/branch", {"op": "create", "name": "conflict-left"})["ok"] is True
    assert client.call("git/branch", {"op": "checkout", "name": "conflict-left"})["ok"] is True
    (cwd / "tracked.txt").write_text("left\n", encoding="utf-8")
    assert client.call("git/stage", {"file": "tracked.txt"})["ok"] is True
    assert client.call("git/commit", {"message": "left conflict"})["ok"] is True
    assert client.call("git/branch", {"op": "checkout", "name": branches[0]})["ok"] is True
    (cwd / "tracked.txt").write_text("right\n", encoding="utf-8")
    assert client.call("git/stage", {"file": "tracked.txt"})["ok"] is True
    assert client.call("git/commit", {"message": "right conflict"})["ok"] is True
    merge_error = client.raw("git/merge", {"branch": "conflict-left"})
    assert merge_error.get("error", {}).get("code") == -32000, merge_error
    conflict_model = client.call("git/model")
    assert any(item["file"] == "tracked.txt" and item["group"] == "merge" for item in conflict_model["resources"]), conflict_model
    conflict = client.call("git/conflict", {"file": "tracked.txt"})
    assert conflict["hasConflicts"] is True and conflict["conflictCount"] >= 1, conflict
    assert "right" in conflict["current"] and "left" in conflict["incoming"], conflict
    merge_caps = client.call("git/mergeEditorCapabilities")
    assert merge_caps["multiPane"] and merge_caps["acceptCurrent"] and merge_caps["acceptIncoming"] and merge_caps["acceptBoth"], merge_caps
    resolved = client.call("git/resolveConflict", {"file": "tracked.txt", "resolution": "both"})
    assert resolved["ok"] is True and resolved["staged"] is True, resolved
    both_text = (cwd / "tracked.txt").read_text(encoding="utf-8")
    assert "right" in both_text and "left" in both_text and "<<<<<<<" not in both_text and ">>>>>>>" not in both_text
    resolved_model = client.call("git/model")
    assert not any(item["file"] == "tracked.txt" and item["group"] == "merge" for item in resolved_model["resources"]), resolved_model
    subprocess.run(["git", "merge", "--abort"], cwd=cwd, check=True, stdout=subprocess.DEVNULL)

    err = client.raw("wizp/not-a-method")
    assert err.get("error", {}).get("code") == -32601


def test_symbols(client: RpcClient, cwd: Path) -> None:
    source = cwd / "symbols.zig"
    source.write_text("const Thing = struct {\n  pub fn init() Thing { return .{}; }\n};\npub fn main() void {}\nfn helper() void {}\n")
    uri = "file://" + str(source)
    symbols = client.call("textDocument/documentSymbol", {"uri": uri})
    names = {item["name"] for item in symbols}
    assert {"Thing", "main", "helper"} <= names
    thing = next(item for item in symbols if item["name"] == "Thing")
    assert thing["children"][0]["name"] == "init", thing
    workspace_names = {item["name"] for item in client.call("workspace/symbol", {"query": "Thing"})}
    assert "Thing" in workspace_names
    assert client.call("editor/problems") == []


def test_text_document_model(client: RpcClient, cwd: Path) -> None:
    source = cwd / "document.zig"
    source.write_text("const doc_value = 1;\r\npub fn main() void {}\r\n", encoding="utf-8")
    opened = client.call("file/open", {"path": str(source)})
    assert opened["content"].endswith("}\r\n"), opened
    assert opened["uri"] == "file://" + str(source), opened
    assert opened["languageId"] == "zig", opened
    assert opened["language"] == "zig", opened
    assert opened["version"] == 1, opened
    assert opened["dirty"] is False, opened
    assert opened["eol"] == "CRLF", opened
    assert opened["encoding"] == "UTF-8", opened
    assert opened["document"]["fileName"] == str(source), opened

    uri = opened["uri"]
    changed = client.call("textDocument/didChange", {"uri": uri, "content": "const beta = 2;\n", "languageId": "zig"})
    assert changed["version"] == 2, changed
    assert changed["dirty"] is True, changed
    assert changed["eol"] == "LF", changed
    dirty = client.call("textDocument/dirty")
    assert dirty["count"] == 1, dirty
    assert dirty["documents"][0]["uri"] == uri, dirty
    metadata = client.call("textDocument/metadata", {"uri": uri})
    assert metadata["content"] == "const beta = 2;\n", metadata
    assert metadata["document"]["languageId"] == "zig", metadata

    ranged = client.call(
        "textDocument/didChange",
        {"uri": uri, "startLine": 0, "startCharacter": 6, "endLine": 0, "endCharacter": 10, "rangeText": "gamma"},
    )
    assert ranged["version"] == 3, ranged
    ranged_metadata = client.call("textDocument/metadata", {"uri": uri})
    assert ranged_metadata["content"] == "const gamma = 2;\n", ranged_metadata

    close_error = client.raw("textDocument/close", {"uri": uri})
    assert close_error.get("error", {}).get("code") == -32001, close_error
    saved = client.call("textDocument/save", {"uri": uri})
    assert saved["dirty"] is False, saved
    assert source.read_text(encoding="utf-8") == "const gamma = 2;\n"
    assert client.call("textDocument/dirty")["count"] == 0
    closed = client.call("textDocument/didClose", {"uri": uri})
    assert closed["closed"] is True, closed

    did_open = client.call("textDocument/didOpen", {"uri": uri, "languageId": "zig", "text": "pub const reopened = true;\n", "version": 7})
    assert did_open["version"] == 7, did_open
    assert did_open["dirty"] is False, did_open
    client.call("textDocument/didChange", {"uri": uri, "content": "unsaved\n"})
    reverted = client.call("textDocument/revert", {"uri": uri})
    assert reverted["content"] == "const gamma = 2;\n", reverted
    assert reverted["dirty"] is False, reverted
    client.call("textDocument/didChange", {"uri": uri, "content": "save all one\n"})

    second = cwd / "document-two.txt"
    second.write_text("initial\n", encoding="utf-8")
    second_uri = "file://" + str(second)
    client.call("textDocument/didOpen", {"uri": second_uri, "languageId": "plaintext", "text": "initial\n", "version": 1})
    client.call("textDocument/didChange", {"uri": second_uri, "content": "save all two\n"})
    save_all = client.call("textDocument/saveAll")
    assert save_all["savedCount"] == 2, save_all
    assert save_all["failedCount"] == 0, save_all
    assert source.read_text(encoding="utf-8") == "save all one\n"
    assert second.read_text(encoding="utf-8") == "save all two\n"
    assert client.call("textDocument/dirty")["count"] == 0
    assert client.call("textDocument/close", {"uri": uri})["closed"] is True
    assert client.call("textDocument/close", {"uri": second_uri})["closed"] is True

    client.call("textDocument/didOpen", {"uri": uri, "languageId": "zig", "text": "force close\n", "version": 11})
    client.call("textDocument/didChange", {"uri": uri, "content": "force close dirty\n"})
    assert client.call("textDocument/close", {"uri": uri, "force": True})["closed"] is True

    large = cwd / "large-document.txt"
    large_lines = [f"line {i:04d}\n" for i in range(1200)]
    large.write_text("".join(large_lines), encoding="utf-8")
    large_uri = "file://" + str(large)
    client.call("textDocument/didOpen", {"uri": large_uri, "languageId": "plaintext", "text": large.read_text(encoding="utf-8"), "version": 1})
    large_edit = client.call(
        "textDocument/didChange",
        {"uri": large_uri, "startLine": 777, "startCharacter": 5, "endLine": 777, "endCharacter": 9, "rangeText": "7777"},
    )
    assert large_edit["version"] == 2, large_edit
    large_metadata = client.call("textDocument/metadata", {"uri": large_uri})
    assert "line 7777\n" in large_metadata["content"], large_metadata
    assert "line 0777\n" not in large_metadata["content"], large_metadata
    assert large_metadata["content"].startswith("line 0000\nline 0001\n"), large_metadata
    assert large_metadata["content"].endswith("line 1199\n"), large_metadata
    assert client.call("textDocument/close", {"uri": large_uri, "force": True})["closed"] is True


def test_diff_editor_rpc(client: RpcClient, cwd: Path) -> None:
    left = cwd / "diff-left.txt"
    right = cwd / "diff-right.txt"
    left.write_text("one\ntwo\nthree\n", encoding="utf-8")
    right.write_text("one\nTWO\nthree\nfour\n", encoding="utf-8")

    diff = client.call("file/diff", {"left": str(left), "right": str(right)})
    assert diff["left"] == str(left), diff
    assert diff["right"] == str(right), diff
    assert diff["changed"] is True, diff
    assert diff["hunks"] >= 1, diff
    assert diff["additions"] == 2, diff
    assert diff["deletions"] == 1, diff
    assert "-two" in diff["diff"], diff
    assert "+TWO" in diff["diff"], diff
    assert "+four" in diff["diff"], diff

    same = client.call("editor/diff", {"original": str(left), "modified": str(left)})
    assert same["changed"] is False, same
    assert same["hunks"] == 0, same
    assert same["additions"] == 0, same
    assert same["deletions"] == 0, same


def test_in_file_find_replace(client: RpcClient, cwd: Path) -> None:
    doc = cwd / "find-replace.txt"
    doc.write_text("alpha alphabet ALPHA\nAlpha beta alpha_beta\nalpha\n", encoding="utf-8")
    uri = f"file://{doc}"
    client.call("textDocument/didOpen", {"uri": uri, "text": doc.read_text(encoding="utf-8"), "languageId": "plaintext"})

    loose = client.call("textDocument/find", {"uri": uri, "query": "alpha", "caseSensitive": False, "wholeWord": False})
    assert loose["count"] == 6, loose
    assert loose["matches"][0]["range"]["start"]["line"] == 0, loose

    whole = client.call("editor/find", {"uri": uri, "query": "alpha", "caseSensitive": False, "wholeWord": True})
    assert whole["count"] == 4, whole
    assert any(match["range"]["start"]["line"] == 2 for match in whole["matches"]), whole

    regex_find = client.call("textDocument/find", {"uri": uri, "query": "alp[a-z]+", "regex": True, "caseSensitive": False})
    assert regex_find["regex"] is True, regex_find
    assert regex_find["count"] == 6, regex_find
    assert regex_find["matches"][0]["range"]["start"] == {"line": 0, "character": 0}, regex_find
    assert regex_find["matches"][0]["range"]["end"] == {"line": 0, "character": 5}, regex_find

    invalid_regex = client.raw("textDocument/find", {"uri": uri, "query": "(", "regex": True})
    assert invalid_regex.get("error", {}).get("code") == -32602, invalid_regex

    capture_doc = cwd / "regex-replace.txt"
    capture_doc.write_text("name: alpha\nname: beta\nrename: alpha\n", encoding="utf-8")
    capture_uri = f"file://{capture_doc}"
    client.call("textDocument/didOpen", {"uri": capture_uri, "text": capture_doc.read_text(encoding="utf-8"), "languageId": "plaintext"})
    capture_replaced = client.call(
        "textDocument/replace",
        {"uri": capture_uri, "query": "name: ([a-z]+)", "replace": "label=$1", "regex": True, "caseSensitive": True},
    )
    assert capture_replaced["replacements"] == 3, capture_replaced
    assert "label=alpha" in capture_replaced["content"], capture_replaced
    assert "label=beta" in capture_replaced["content"], capture_replaced
    assert "relabel=alpha" in capture_replaced["content"], capture_replaced
    assert client.call("textDocument/close", {"uri": capture_uri, "force": True})["closed"] is True

    whole_regex_doc = cwd / "regex-whole-word.txt"
    whole_regex_doc.write_text("alpha alpha_beta ALPHA\n", encoding="utf-8")
    whole_regex_uri = f"file://{whole_regex_doc}"
    client.call("textDocument/didOpen", {"uri": whole_regex_uri, "text": whole_regex_doc.read_text(encoding="utf-8"), "languageId": "plaintext"})
    whole_regex_replaced = client.call(
        "textDocument/replace",
        {"uri": whole_regex_uri, "query": "alpha", "replace": "omega", "regex": True, "caseSensitive": False, "wholeWord": True, "preserveCase": True},
    )
    assert whole_regex_replaced["replacements"] == 2, whole_regex_replaced
    assert whole_regex_replaced["content"] == "omega alpha_beta OMEGA\n", whole_regex_replaced
    assert client.call("textDocument/close", {"uri": whole_regex_uri, "force": True})["closed"] is True

    replaced = client.call(
        "textDocument/replace",
        {"uri": uri, "query": "alpha", "replace": "gamma", "caseSensitive": False, "wholeWord": True, "preserveCase": True},
    )
    assert replaced["replacements"] == 4, replaced
    assert replaced["dirty"] is True, replaced
    assert "gamma alphabet GAMMA" in replaced["content"], replaced
    assert "Gamma beta alpha_beta" in replaced["content"], replaced
    assert replaced["content"].endswith("gamma\n"), replaced
    assert "gamma_beta" not in replaced["content"], replaced

    metadata = client.call("textDocument/metadata", {"uri": uri})
    assert metadata["dirty"] is True, metadata
    assert metadata["version"] == replaced["version"], metadata
    assert client.call("textDocument/close", {"uri": uri, "force": True})["closed"] is True


def test_snippet_expansion(client: RpcClient, cwd: Path) -> None:
    expanded = client.call(
        "snippet/expand",
        {"snippet": "fn ${1:name}(${2|a,b|}) {$0\n\t$TM_FILENAME\n}", "fileName": "snippet.zig"},
    )
    assert expanded["text"] == "fn name(a) {\n\tsnippet.zig\n}", expanded
    assert expanded["placeholders"][0]["index"] == 1, expanded
    assert expanded["placeholders"][0]["start"] == 3, expanded
    assert expanded["placeholders"][0]["end"] == 7, expanded
    assert expanded["placeholders"][1]["index"] == 2, expanded
    assert expanded["placeholders"][1]["choices"] == ["a", "b"], expanded

    doc = cwd / "snippet.zig"
    doc.write_text("pub ", encoding="utf-8")
    uri = f"file://{doc}"
    client.call("textDocument/didOpen", {"uri": uri, "text": doc.read_text(encoding="utf-8"), "languageId": "zig"})
    inserted = client.call(
        "textDocument/insertSnippet",
        {"uri": uri, "line": 0, "character": 4, "snippet": "const ${1:name} = ${2|one,two|};$0"},
    )
    assert inserted["dirty"] is True, inserted
    assert inserted["content"] == "pub const name = one;", inserted
    assert inserted["placeholders"][0]["range"]["start"]["character"] == 10, inserted
    assert inserted["placeholders"][0]["range"]["end"]["character"] == 14, inserted
    assert inserted["placeholders"][1]["choices"] == ["one", "two"], inserted
    metadata = client.call("textDocument/metadata", {"uri": uri})
    assert metadata["content"] == inserted["content"], metadata
    assert metadata["version"] == inserted["version"], metadata
    assert client.call("textDocument/close", {"uri": uri, "force": True})["closed"] is True


def test_debug(client: RpcClient) -> None:
    debug_workspace = client.cwd / "debug-workspace"
    vscode_dir = debug_workspace / ".vscode"
    vscode_dir.mkdir(parents=True, exist_ok=True)
    client.call("workspace/setFolders", {"path": str(debug_workspace)})
    (vscode_dir / "launch.json").write_text("[]", encoding="utf-8")
    invalid_root = client.call("debug/launchConfigurations", {})
    assert invalid_root["schemaValid"] is False, invalid_root
    assert invalid_root["errors"] == ["launch.json root must be an object"], invalid_root
    (vscode_dir / "launch.json").write_text(
        json.dumps(
            {
                "version": "0.2.0",
                "configurations": [
                    {
                        "name": "Fixture Launch",
                        "type": "fixture",
                        "request": "launch",
                        "program": "main.zig",
                        "preLaunchTask": "fixture:build",
                        "postDebugTask": "fixture:cleanup",
                    }
                ],
                "compounds": [
                    {
                        "name": "Fixture Compound",
                        "configurations": ["Fixture Launch"],
                        "preLaunchTask": "fixture:build",
                        "postDebugTask": "fixture:cleanup",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    launch_configs = client.call("debug/launchConfigurations", {"selected": "Fixture Launch"})
    assert launch_configs["schemaValid"] is True, launch_configs
    assert launch_configs["configurationReady"] is True, launch_configs
    assert launch_configs["selected"] == "Fixture Launch", launch_configs
    assert launch_configs["configurations"][0]["name"] == "Fixture Launch", launch_configs
    assert launch_configs["configurations"][0]["preLaunchTask"] == "fixture:build", launch_configs
    assert launch_configs["configurations"][0]["postDebugTask"] == "fixture:cleanup", launch_configs
    assert launch_configs["compounds"][0]["name"] == "Fixture Compound", launch_configs
    assert launch_configs["compounds"][0]["configurations"] == ["Fixture Launch"], launch_configs
    assert launch_configs["ui"]["selector"] and launch_configs["ui"]["schemaDiagnostics"], launch_configs
    initial_state = client.call("debug/state")
    assert initial_state["running"] is False and initial_state["paused"] is False, initial_state
    assert initial_state["breakpoints"] == [], initial_state
    assert client.raw("debug/evaluate", {"expression": ""})["error"]["code"] == -32602
    assert client.raw("debug/evaluate", {"expression": "x" * 4097})["error"]["code"] == -32602
    assert client.call("debug/start", {"noDebug": True})["noDebug"] is True
    assert client.call("debug/toggleBreakpoint", {"file": "main.zig", "line": 7})["enabled"] is True
    assert client.call("dap/getBreakpoints", {"file": "main.zig"}) == [{"file": "main.zig", "line": 7}]
    for method in ["debug/continue", "debug/step", "debug/stepInto", "debug/stepOut", "debug/pause", "dap/pause"]:
        assert client.call(method, {})["ok"] is True
    assert client.call("dap/stackTrace", {}) == "null"
    assert client.call("debug/evaluate", {"expression": "1 + 1"})["result"] == ""
    assert client.call("debug/stop", {})["ok"] is True

    missing_adapter = client.raw(
        "debug/start",
        {"adapter": "wizp-missing-debug-adapter", "program": "main.zig"},
    )
    missing_message = missing_adapter.get("error", {}).get("message", "")
    missing_result = missing_adapter.get("result", {})
    assert "Debug" in (missing_message or missing_result.get("error", "")), missing_adapter
    failed_state = client.call("debug/state")
    assert failed_state["running"] is False and failed_state["paused"] is False, failed_state

    launch = client.call("debug/start", {"adapter": "fixture", "program": "main.zig"})
    assert launch["ok"] is True, launch
    assert launch["adapter"] == "fixture", launch
    assert launch["program"] == "main.zig", launch
    assert launch["preLaunchTask"] == "fixture:build", launch
    assert launch["postDebugTask"] == "fixture:cleanup", launch
    assert launch["compound"] == "Fixture Compound", launch
    assert launch["adapterInstalled"] is True, launch
    state = client.call("debug/state")
    assert state["running"] is True and state["paused"] is True and state["noDebug"] is False, state
    assert state["breakpoints"] == [{"file": "main.zig", "line": 7}], state
    events = client.call("debug/events")
    assert [event["event"] for event in events] == ["initialized", "output", "stopped"], events
    assert events[2]["body"]["reason"] == "breakpoint", events

    assert client.call(
        "debug/toggleBreakpoint",
        {"file": "main.zig", "line": 8, "condition": "answer == 42", "hitCondition": "2", "logMessage": "answer={answer}"},
    )["enabled"] is True
    bps = client.call("dap/getBreakpoints", {"file": "main.zig"})
    assert any(bp["line"] == 8 and bp["condition"] == "answer == 42" and bp["hitCondition"] == "2" and bp["logMessage"] == "answer={answer}" for bp in bps), bps

    stack = json.loads(client.call("dap/stackTrace", {}))
    assert stack["body"]["stackFrames"][0]["name"] == "main", stack
    assert stack["body"]["stackFrames"][0]["line"] == 8, stack
    scopes = json.loads(client.call("dap/scopes", {"frameId": 100}))
    assert scopes["body"]["scopes"][0]["name"] == "Locals", scopes
    variables = json.loads(client.call("dap/variables", {"variablesReference": 200}))
    assert variables["body"]["variables"][0]["name"] == "answer", variables
    assert variables["body"]["variables"][0]["value"] == "42", variables
    assert client.call("debug/evaluate", {"expression": "answer", "frameId": 100})["result"] == "42"
    watches = client.call("debug/watches")
    assert watches[0] == {"expression": "answer", "result": "42"}, watches
    loaded = json.loads(client.call("dap/loadedSources", {}))
    assert loaded["body"]["sources"][0]["path"] == "main.zig", loaded
    assert client.call("debug/continue", {})["ok"] is True
    assert client.call("debug/state")["paused"] is False
    assert client.call("debug/pause", {})["ok"] is True
    assert client.call("debug/state")["paused"] is True
    for method in ["debug/step", "debug/stepInto", "debug/stepOut"]:
        assert client.call(method, {})["ok"] is True
        assert client.call("debug/state")["paused"] is True
    restart = client.call("dap/restart", {})
    assert restart["ok"] is True and "restart" in restart["response"], restart
    assert client.call("debug/state")["running"] is True
    assert client.call("dap/disconnect", {})["ok"] is True
    assert client.call("debug/state")["running"] is False
    client.call("debug/start", {"adapter": "fixture", "program": "main.zig"})
    assert client.call("dap/terminate", {})["ok"] is True
    adapters = client.call("debug/adapters")
    assert any(adapter["id"] == "fixture" and adapter["installed"] is True for adapter in adapters["adapters"]), adapters
    external = client.call(
        "debug/externalAdapterSmoke",
        {"adapterPath": str(ROOT / "testdata" / "extensions" / "basic-api-smoke" / "debugAdapters" / "smokeDebug.js")},
    )
    assert external["ok"] is True and external["adapterProcess"] is True, external
    assert external["events"] == {"initialized": True, "output": True, "stopped": True, "hitBreakpoint": True}, external
    assert external["exceptionBreakpoints"] is True, external
    assert external["stack"] is True and external["sourceReference"] is True, external
    assert external["scopes"] is True and external["variables"] is True, external
    assert external["evaluate"] is True and external["continue"] is True and external["shutdown"] is True, external
    assert external["watch"] == {"expression": "answer", "result": "42"}, external
    assert external["debugConsoleOutput"] == "external adapter output", external
    advanced = client.call("debug/advancedBreakpoints")
    assert advanced["supportsExceptionBreakpoints"] and advanced["exceptionFilters"] == ["caught", "uncaught"], advanced
    assert advanced["supportsFunctionBreakpoints"] and advanced["functionBreakpoint"]["name"] == "main", advanced
    assert advanced["supportsDataBreakpoints"] and advanced["dataBreakpoint"]["dataId"] == "answer", advanced
    assert advanced["supportsSourceReference"] and advanced["sourceReference"] == 3001, advanced
    assert advanced["ui"]["sourceReferenceOpen"] is True, advanced


def test_search_and_explorer(client: RpcClient, cwd: Path) -> None:
    assert client.call("workspace/setFolders", {"path": str(cwd)})["folders"][0]["path"] == str(cwd)
    (cwd / "src").mkdir()
    (cwd / "src" / "one.txt").write_text("Alpha beta\nalpha BETA\n")
    (cwd / "src" / "skip.log").write_text("alpha ignored\n")
    empty_query = client.raw("search/text", {"query": ""})
    assert empty_query.get("error", {}).get("code") == -32602, empty_query
    invalid_regex = client.raw("search/text", {"query": "[", "regex": True})
    assert invalid_regex.get("error", {}).get("code") == -32000, invalid_regex
    assert "Search failed:" in invalid_regex["error"]["message"], invalid_regex
    initial_search = client.call("search/text", {"query": "alpha", "regex": False, "caseSensitive": False})
    assert len(initial_search["matches"]) == 3
    assert initial_search["limit"] == 100 and initial_search["truncated"] is False, initial_search
    assert len(
        client.call(
            "search/text",
            {
                "query": "alpha",
                "regex": False,
                "caseSensitive": False,
                "include": "",
                "exclude": "",
            },
        )["matches"]
    ) == 3
    filtered = client.call(
        "search/text",
        {"query": "alpha", "regex": False, "caseSensitive": False, "include": "*.txt", "exclude": "skip.*", "contextLines": 1},
    )["matches"]
    assert len(filtered) == 2
    assert filtered[0]["file"].endswith("one.txt")
    assert "before" in filtered[0] and "after" in filtered[0]
    quick_open_files = client.call("file/search", {"query": "one"})["files"]
    quick_open_paths = {Path(entry["path"]) for entry in quick_open_files}
    assert cwd / "src" / "one.txt" in quick_open_paths, quick_open_files
    assert all(path.is_absolute() for path in quick_open_paths), quick_open_files


    context_lines = [f"context {index}" for index in range(20)]
    context_lines[9] = "context-limit-marker"
    (cwd / "src" / "context.txt").write_text("\n".join(context_lines) + "\n")
    clamped_context = client.call(
        "search/text",
        {"query": "context-limit-marker", "contextLines": 999},
    )["matches"]
    assert len(clamped_context) == 1, clamped_context
    assert len(clamped_context[0]["before"]) == 5, clamped_context
    assert len(clamped_context[0]["after"]) == 5, clamped_context

    (cwd / "src" / "result-limit.txt").write_text("limit-marker\n" * 105)
    limited = client.call("search/text", {"query": "limit-marker"})
    assert len(limited["matches"]) == 100, limited
    assert limited["limit"] == 100 and limited["truncated"] is True, limited

    replaced = client.call(
        "search/replace",
        {"file": "src/one.txt", "query": "alpha", "replace": "gamma", "regex": False, "caseSensitive": False, "preserveCase": True},
    )
    assert replaced["replacements"] == 2
    assert (cwd / "src" / "one.txt").read_text() == "Gamma beta\ngamma BETA\n"
    regex_replaced = client.call(
        "search/replace",
        {"file": "src/one.txt", "query": "g.mm[ao]", "replace": "delta", "regex": True, "caseSensitive": False},
    )
    assert regex_replaced["replacements"] == 2
    assert (cwd / "src" / "one.txt").read_text() == "delta beta\ndelta BETA\n"

    (cwd / "src" / "single.txt").write_text("alpha alphabet\nalpha beta\n")
    whole_word = client.call(
        "search/text",
        {"query": "alpha", "regex": False, "caseSensitive": True, "wholeWord": True},
    )["matches"]
    assert len([match for match in whole_word if match["file"].endswith("single.txt")]) == 2, whole_word
    replaced_one = client.call(
        "search/replace",
        {
            "file": "src/single.txt",
            "query": "alpha",
            "replace": "gamma",
            "caseSensitive": True,
            "wholeWord": True,
            "line": 2,
            "maxReplacements": 1,
        },
    )
    assert replaced_one["replacements"] == 1
    assert (cwd / "src" / "single.txt").read_text() == "alpha alphabet\ngamma beta\n"

    search_root = cwd / "search-root"
    search_root.mkdir()
    (search_root / "inside.txt").write_text("scoped-alpha\n")
    (cwd / "outside.txt").write_text("scoped-alpha\n")
    assert client.call("workspace/setFolders", {"path": str(search_root)})["folders"][0]["path"] == str(search_root)
    scoped = client.call("search/text", {"query": "scoped-alpha", "regex": False, "caseSensitive": True})["matches"]
    assert len(scoped) == 1 and scoped[0]["file"].endswith("inside.txt"), scoped
    outside_replace = client.raw("search/replace", {"file": str(cwd / "outside.txt"), "query": "scoped-alpha", "replace": "blocked"})
    assert outside_replace.get("error", {}).get("code") == -32602, outside_replace
    assert (cwd / "outside.txt").read_text() == "scoped-alpha\n"

    assert client.call("file/open-folder-dialog", {"path": str(cwd)})["path"] == str(cwd)
    assert client.call("workspace/getFolders")["folders"][0]["path"] == str(cwd)
    assert client.call("workspace/recent")["workspaces"][0] == str(cwd)
    assert client.call("file/rename", {"from": "src/one.txt", "to": "src/two.txt"}) is True
    assert client.call("file/copy", {"from": "src/two.txt", "to": "copy/two-copy.txt"}) is True
    assert (cwd / "copy" / "two-copy.txt").read_text() == "delta beta\ndelta BETA\n"
    (cwd / "dir").mkdir()
    (cwd / "dir" / "nested.txt").write_text("nested")
    assert client.call("file/copy", {"from": "dir", "to": "dir-copy"}) is True
    assert (cwd / "dir-copy" / "nested.txt").read_text() == "nested"
    assert client.call("file/delete", {"path": "dir-copy"}) is True
    assert not (cwd / "dir-copy").exists()


def test_workspace_core(client: RpcClient, cwd: Path) -> None:
    one = cwd / "root-one"
    two = cwd / "root-two"
    one.mkdir()
    two.mkdir()
    folders = client.call("workspace/setFolders", {"folders": [{"path": str(one)}, {"path": str(two)}]})["folders"]
    assert [folder["path"] for folder in folders] == [str(one), str(two)]
    assert [folder["path"] for folder in client.call("workspace/getFolders")["folders"]] == [str(one), str(two)]

    workspace_file = cwd / "multi.code-workspace"
    saved = client.call("workspace/saveWorkspace", {"path": str(workspace_file), "settings": {"editor.tabSize": 2}})
    assert saved["path"] == str(workspace_file)
    assert '"folders"' in workspace_file.read_text()
    assert '"editor.tabSize":2' in workspace_file.read_text().replace(" ", "")

    client.call("workspace/setFolders", {"path": str(one)})
    reopened = client.call("workspace/openWorkspace", {"path": str(workspace_file)})["folders"]
    assert [folder["path"] for folder in reopened] == [str(one), str(two)]
    recent = client.call("workspace/recent")["workspaces"]
    assert str(workspace_file) in recent

    profile = client.call("profiles/current")["profile"]
    assert profile["name"] == "default", profile
    switched = client.call("profiles/switch", {"name": "parity"})["profile"]
    assert switched["name"] == "parity", switched
    profiles = client.call("profiles/list")
    assert profiles["active"] == "parity", profiles
    assert any(item["name"] == "parity" for item in profiles["profiles"]), profiles
    isolation = client.call("profiles/isolation")
    assert isolation["active"] == "parity", isolation
    assert isolation["settingsScope"] == "profile:parity", isolation
    assert isolation["keybindingsScope"] == "profile:parity", isolation
    assert isolation["extensionsScope"] == "profile:parity", isolation
    assert isolation["isolated"] is True, isolation
    assert client.call("config/set", {"key": "editor.fontSize", "value": "15", "scope": "profile"}) is True
    assert client.call("config/get", {"key": "editor.fontSize"})["value"] == "15"
    client.call("profiles/switch", {"name": "default"})
    assert client.call("profiles/isolation")["settingsScope"] == "profile:default"
    assert client.call("config/set", {"key": "editor.fontSize", "value": "13", "scope": "profile"}) is True
    assert client.call("config/get", {"key": "editor.fontSize"})["value"] == "13"
    client.call("profiles/switch", {"name": "parity"})
    assert client.call("config/get", {"key": "editor.fontSize"})["value"] == "15"

    assert client.call("workspace/trust")["trusted"] is True
    assert client.call("workspace/setTrust", {"trusted": False})["trusted"] is False
    assert client.call("workspace/trustState")["trusted"] is False
    restricted = client.call("workspace/restrictedOperations")
    assert restricted["trusted"] is False, restricted
    assert restricted["blocked"] is True, restricted
    blocked_ops = {item["id"]: item["blocked"] for item in restricted["operations"]}
    assert blocked_ops["extension.activate.workspace"] is True, restricted
    assert blocked_ops["task.run.workspace"] is True, restricted
    assert blocked_ops["debug.launch.workspace"] is True, restricted
    assert client.call("workspace/setTrust", {"trusted": True})["trusted"] is True
    restricted = client.call("workspace/restrictedOperations")
    assert restricted["trusted"] is True, restricted
    assert restricted["blocked"] is False, restricted
    assert all(item["blocked"] is False for item in restricted["operations"]), restricted

    restore_file = cwd / "restore.txt"
    restore_file.write_text("restore")
    session_file = cwd / "session.json"
    editor_session = {
        "layout": "vertical",
        "activeGroup": 0,
        "groups": [
            {
                "editors": [
                    {
                        "uri": f"file://{restore_file}",
                        "languageId": "text",
                        "dirty": True,
                        "content": "dirty restore\n",
                    },
                    {
                        "uri": "untitled-atomic-recovery",
                        "languageId": "text",
                        "dirty": True,
                        "content": "untitled restore\n",
                    },
                ],
                "activeUri": "untitled-atomic-recovery",
            }
        ],
    }
    saved_session = client.call(
        "session/save",
        {
            "path": str(session_file),
            "files": [{"path": str(restore_file)}],
            "editorSession": json.dumps(editor_session),
            "sidebarVisible": False,
            "panelVisible": True,
            "panelHeight": 12,
        },
    )
    assert saved_session["profile"] == "parity", saved_session
    assert saved_session["trusted"] is True, saved_session
    assert saved_session["sidebarVisible"] is False, saved_session
    assert saved_session["panelVisible"] is True, saved_session
    assert saved_session["panelHeight"] == 12, saved_session
    assert saved_session["files"][0]["path"] == str(restore_file), saved_session
    assert saved_session["editorSession"] == editor_session, saved_session
    assert '"profile":"parity"' in session_file.read_text().replace(" ", "")
    loaded_session = client.call("session/load", {"path": str(session_file)})
    assert loaded_session["profile"] == "parity", loaded_session
    assert loaded_session["trusted"] is True, loaded_session
    assert loaded_session["sidebarVisible"] is False, loaded_session
    assert loaded_session["panelVisible"] is True, loaded_session
    assert loaded_session["panelHeight"] == 12, loaded_session
    assert loaded_session["files"][0]["path"] == str(restore_file), loaded_session
    assert loaded_session["editorSession"] == editor_session, loaded_session


def test_config_scopes(client: RpcClient) -> None:
    assert client.call("config/set", {"key": "editor.tabSize", "value": "2", "scope": "user"}) is True
    assert client.call("config/set", {"key": "editor.tabSize", "value": "4", "scope": "workspace"}) is True
    assert client.call("config/get", {"key": "editor.tabSize", "scope": "workspace"})["value"] == "4"
    assert client.call("config/get", {"key": "editor.tabSize", "scope": "user"})["value"] == "2"
    assert client.call("config/get")["tabWidth"] == 4


def test_ghostty_probe(client: RpcClient) -> None:
    info = client.call("ghostty/info")
    assert isinstance(info["available"], bool), info
    assert isinstance(info["enabled"], bool), info
    assert info["backend"] in {"xterm.js (fallback)", "ghostty (experimental)"}, info
    assert info["ptyBackend"] in {"zigpty", "ghostty (experimental)"}, info
    assert info["renderer"] == "xterm.js", info
    assert info["nativeRendererBridge"] == (info["available"] and info["enabled"]), info
    assert info["rendererBridgePolicy"] == "opt-in-lazy", info
    assert isinstance(info["runtimeLoaded"], bool), info
    assert isinstance(info["lazyLoaded"], bool), info
    assert isinstance(info["fallbackReason"], str), info
    assert info["optInEnv"] == "WIZP_GHOSTTY_EXPERIMENTAL", info
    bridge = client.call("ghostty/rendererBridge")
    assert bridge["policy"] == "opt-in-lazy", bridge
    assert bridge["optInEnv"] == "WIZP_GHOSTTY_EXPERIMENTAL", bridge
    assert isinstance(bridge["available"], bool), bridge
    assert isinstance(bridge["enabled"], bool), bridge
    assert bridge["loaded"] == (bridge["available"] and bridge["enabled"]), bridge
    assert bridge["nativeRendererBridge"] == bridge["loaded"], bridge
    assert bridge["renderer"] == "xterm.js", bridge
    assert bridge["defaultRenderer"] == "xterm.js", bridge
    assert bridge["defaultPtyBackend"] == "zigpty", bridge
    assert isinstance(bridge["surfaceCreated"], bool), bridge
    assert isinstance(bridge["fallbackReason"], str), bridge


def test_terminal_tasks(client: RpcClient, cwd: Path) -> None:
    restore = client.call("terminal/restorePolicy")
    assert restore["supported"] is True, restore
    assert restore["policy"] == "disposeOnRestart", restore
    assert restore["persistsLayout"] is True, restore
    assert restore["reconnect"] is False, restore
    assert restore["liveReconnect"] is False, restore
    assert restore["respawnOnRestore"] is True, restore
    assert restore["stalePtyHandles"] is False, restore
    assert restore["auditRpc"] == "terminal/restoreAudit", restore
    assert restore["layoutStore"] == "wizp:terminalLayout:v1", restore
    assert {"groups", "sessions", "activeGroup", "splitDirection"} <= set(restore["restores"]), restore
    assert {"ptyProcess", "scrollback", "runningCommand"} <= set(restore["disposes"]), restore
    stale_fixture = client.call("terminal/spawn", {"shell": "/bin/sh", "cwd": str(cwd)})
    stale_id = stale_fixture["id"]
    assert client.call("terminal/kill", {"id": stale_id}) is True
    assert client.call("terminal/read", {"id": stale_id}) == {
        "data": "",
        "eof": True,
        "droppedBytes": 0,
    }
    terminals_after_dispose = client.call("terminal/list")["terminals"]
    assert all(item["id"] != stale_id for item in terminals_after_dispose), terminals_after_dispose
    restore_audit = client.call("terminal/restoreAudit", {"previousId": stale_id})
    assert restore_audit["policy"] == "disposeOnRestart", restore_audit
    assert restore_audit["liveReconnect"] is False, restore_audit
    assert restore_audit["respawnOnRestore"] is True, restore_audit
    assert restore_audit["stalePtyHandles"] is False, restore_audit
    assert restore_audit["previousHandlePresent"] is False, restore_audit
    assert restore_audit["checkedPreviousId"] == stale_id, restore_audit
    assert restore_audit["layoutStore"] == "wizp:terminalLayout:v1", restore_audit

    profile = client.call("terminal/profile", {"profile": "bash", "shell": "/bin/bash", "cwd": str(cwd)})
    assert profile["profile"] == "bash", profile
    assert profile["shell"] == "/bin/bash", profile
    assert profile["cwd"] == str(cwd), profile
    assert profile["env"]["WIZP_TERMINAL"] == "1", profile

    profile_dir = cwd / "profile-cwd"
    profile_dir.mkdir(exist_ok=True)
    spawned_profile = client.call("terminal/spawn", {"shell": "/bin/sh", "cwd": str(profile_dir)})
    assert spawned_profile["shell"] == "/bin/sh", spawned_profile
    assert spawned_profile["cwd"] == str(profile_dir), spawned_profile
    assert spawned_profile["env"]["WIZP_TERMINAL"] == "1", spawned_profile
    assert spawned_profile["backend"] in {"zigpty", "ghostty (experimental)"}, spawned_profile
    assert spawned_profile["renderer"] == "xterm.js", spawned_profile
    assert isinstance(spawned_profile["ghosttyAvailable"], bool), spawned_profile
    assert isinstance(spawned_profile["ghosttyEnabled"], bool), spawned_profile
    assert spawned_profile["nativeRendererBridge"] == (spawned_profile["ghosttyAvailable"] and spawned_profile["ghosttyEnabled"]), spawned_profile
    assert isinstance(spawned_profile["ghosttyRuntimeLoaded"], bool), spawned_profile
    client.call("terminal/write", {"id": spawned_profile["id"], "data": "pwd\n"})
    seen = ""
    deadline = time.time() + 8
    while time.time() < deadline and str(profile_dir) not in seen:
        chunk = client.call("terminal/read", {"id": spawned_profile["id"]})
        if chunk.get("data"):
            seen += base64.b64decode(chunk["data"]).decode("utf-8", "replace")
        time.sleep(0.05)
    assert str(profile_dir) in seen, seen
    assert client.call("terminal/kill", {"id": spawned_profile["id"]}) is True

    integration = client.call("terminal/shellIntegration")
    assert integration["enabled"] is True, integration
    assert integration["startupInjection"] is False, integration
    assert "commandStart" in integration["markers"], integration
    assert integration["commandDecorations"] is True, integration
    assert integration["decorationSource"] == "frontend-sendText", integration

    links = client.call("terminal/links", {"text": "open https://example.test\nsrc/main.zig:12: warning\n"})
    assert any(link["kind"] == "url" and link["target"] == "https://example.test" for link in links["links"]), links
    assert any(link["kind"] == "file" and link["path"] == "src/main.zig" and link["line"] == 12 for link in links["links"]), links

    found = client.call("terminal/find", {"text": "alpha beta ALPHA beta", "query": "alpha", "caseSensitive": False})
    assert found["count"] == 2, found
    assert found["matches"][0]["offset"] == 0, found

    tabs = client.call("terminal/tabRender", {"text": "a\tb"})
    assert tabs["preservesTabs"] is True, tabs
    assert tabs["copyText"] == "a\tb", tabs
    assert tabs["visualWidth"] == 5, tabs
    renderer = client.call("terminal/rendererEvidence")
    assert renderer["renderer"] == "xterm.js", renderer
    assert renderer["ptyBackend"] in {"zigpty", "ghostty (experimental)"}, renderer
    assert isinstance(renderer["ghosttyAvailable"], bool), renderer
    assert isinstance(renderer["ghosttyEnabled"], bool), renderer
    assert renderer["nativeRendererBridge"] == (renderer["ghosttyAvailable"] and renderer["ghosttyEnabled"]), renderer
    assert isinstance(renderer["ghosttyRuntimeLoaded"], bool), renderer
    assert renderer["ghosttyBridgeRpc"] == "ghostty/rendererBridge", renderer
    assert renderer["linkAddon"] == "@xterm/addon-web-links", renderer
    assert renderer["searchAddon"] == "@xterm/addon-search", renderer
    assert renderer["serializeAddon"] == "@xterm/addon-serialize", renderer
    assert renderer["preservesTabs"] and renderer["linkClickOpen"] and renderer["findHighlight"], renderer
    assert renderer["commandDecorations"] is True, renderer
    assert renderer["commandDecorationSource"] == "sendText", renderer
    assert renderer["overlapCritical"] == 0, renderer

    (cwd / "build.zig").write_text("pub fn build() void {}\n", encoding="utf-8")
    (cwd / "package.json").write_text('{"scripts":{"build":"echo build"}}\n', encoding="utf-8")
    (cwd / ".vscode").mkdir(exist_ok=True)
    (cwd / ".vscode" / "tasks.json").write_text(
        """{
  "version": "2.0.0",
  "tasks": [
      {
        "label": "watch: zig",
        "type": "shell",
        "command": "zig build --watch",
        "isBackground": true,
        "group": {
          "kind": "build",
          "isDefault": true
        },
        "dependsOn": ["prepare: zig"],
        "dependsOrder": "sequence",
        "options": {
          "cwd": ".",
          "env": {
            "WIZP_TASK_SCHEMA": "1"
          }
        },
        "presentation": {
          "reveal": "always",
          "panel": "shared"
        },
        "problemMatcher": {
          "owner": "zig",
          "background": {
          "beginsPattern": "watching",
          "endsPattern": "finished"
        }
      }
    }
  ]
}
""",
        encoding="utf-8",
    )
    discovered = client.call("tasks/discover")
    labels = {task["label"] for task in discovered["tasks"]}
    assert {"zig build", "npm: build", "watch: zig"} <= labels, discovered
    watch_task = next(task for task in discovered["tasks"] if task["label"] == "watch: zig")
    assert watch_task["source"] == ".vscode/tasks.json", watch_task
    assert watch_task["schema"] == "2.0.0", watch_task
    assert watch_task["background"] is True, watch_task
    assert watch_task["problemMatcher"] == "zig", watch_task
    assert watch_task["beginsPattern"] == "watching", watch_task
    assert watch_task["endsPattern"] == "finished", watch_task
    assert watch_task["group"] == "build", watch_task
    assert watch_task["groupDefault"] is True, watch_task
    assert watch_task["dependsOn"] == ["prepare: zig"], watch_task
    assert watch_task["dependsOrder"] == "sequence", watch_task
    assert watch_task["cwd"] == ".", watch_task
    assert watch_task["envKeys"] == ["WIZP_TASK_SCHEMA"], watch_task
    assert watch_task["presentationReveal"] == "always", watch_task
    assert watch_task["presentationPanel"] == "shared", watch_task

    schema = client.call("tasks/schemaSmoke")
    assert schema["schema"] == "2.0.0", schema
    assert schema["dependsOn"] is True, schema
    assert schema["dependsOrder"] == "sequence", schema
    assert schema["defaultBuild"] is True, schema
    assert schema["options"]["cwd"] == ".", schema
    assert schema["options"]["env"] == ["WIZP_TASK_SCHEMA"], schema
    assert schema["presentation"]["reveal"] == "always", schema
    assert schema["problemMatcher"]["background"] is True, schema
    assert "process" in schema["commandTypes"], schema

    task = client.call("tasks/run", {"command": "printf 'src/main.zig:9: task warning\\n'"})
    assert task["state"] == "completed", task
    assert task["exitCode"] == 0, task
    assert task["problems"][0]["file"] == "src/main.zig", task
    assert task["problems"][0]["line"] == 9, task

    background = client.call("tasks/run", {"command": "sleep 30", "background": True})
    assert background["state"] == "background" and background["running"] is True, background
    cancelled = client.call("tasks/cancel", {"id": background["id"]})
    assert cancelled["cancelled"] is True, cancelled
    watcher = client.call(
        "tasks/run",
        {
            "command": "printf 'watching\\nsrc/watch.zig:7: watch warning\\nfinished\\n'",
            "background": True,
            "beginsPattern": "watching",
            "endsPattern": "finished",
        },
    )
    assert watcher["state"] == "background-ready", watcher
    assert watcher["watching"] is True, watcher
    assert watcher["running"] is False, watcher
    assert watcher["backgroundBegan"] is True and watcher["backgroundEnded"] is True, watcher
    assert watcher["beginsPattern"] == "watching" and watcher["endsPattern"] == "finished", watcher
    assert watcher["problems"][0]["file"] == "src/watch.zig", watcher
    assert watcher["problems"][0]["line"] == 7, watcher

    search_hardening = client.call("search/hardeningSmoke")
    assert search_hardening["ignoreDepth"] is True, search_hardening
    assert ".gitignore" in search_hardening["ignoreFiles"], search_hardening
    assert search_hardening["includeExcludePrecedence"] is True, search_hardening
    assert search_hardening["replacePreview"] is True, search_hardening
    assert search_hardening["previewDiff"] is True, search_hardening
    assert search_hardening["preserveCasePreview"] is True, search_hardening

    task_ui = client.call("tasks/uiBinding")
    assert task_ui["event"] == "wizpTaskExecute", task_ui
    assert task_ui["discoverRpc"] == "tasks/discover", task_ui
    assert task_ui["runRpc"] == "tasks/run", task_ui
    assert task_ui["cancelRpc"] == "tasks/cancel", task_ui
    assert task_ui["terminalMirror"] is True, task_ui
    assert task_ui["problemsPanel"] is True, task_ui
    assert task_ui["tasksJsonSchema"] == "2.0.0", task_ui
    assert task_ui["problemMatchers"] is True, task_ui
    assert task_ui["backgroundSupported"] is True, task_ui
    assert task_ui["backgroundMatchers"] is True, task_ui
    assert task_ui["backgroundLifecycle"] is True, task_ui

    visible = client.call("terminal/createVisible", {"name": "Extension Terminal"})
    assert visible["id"] >= 1, visible
    terminals = client.call("terminal/list")["terminals"]
    assert any(term["id"] == visible["id"] and term["visible"] is True for term in terminals), terminals
    binding = client.call("terminal/uiBinding")
    assert binding["extensionCreated"] is True, binding
    assert binding["createRpc"] == "terminal/createVisible", binding
    assert binding["frontendEvent"] == "terminal:create-visible", binding
    assert binding["adoptsExistingSession"] is True, binding
    assert binding["splitRight"] and binding["splitDown"], binding
    assert binding["overlapCritical"] == 0, binding
    assert client.call("terminal/kill", {"id": visible["id"]}) is True


def test_builtin_views_ux(client: RpcClient, cwd: Path) -> None:
    assert client.call("workspace/setFolders", {"path": str(cwd)})["folders"][0]["path"] == str(cwd)
    (cwd / "ux").mkdir(exist_ok=True)
    assert client.call("file/create", {"path": "ux/new.txt"}) is True
    (cwd / "ux" / "new.txt").write_text("keep me\n", encoding="utf-8")
    duplicate_create = client.raw("file/create", {"path": "ux/new.txt"})
    assert duplicate_create["error"]["code"] == -32000, duplicate_create
    assert (cwd / "ux" / "new.txt").read_text(encoding="utf-8") == "keep me\n"
    assert client.call("file/mkdir", {"path": "ux/folder"}) is True
    assert client.call("file/cutPaste", {"from": "ux/new.txt", "to": "ux/folder/moved.txt"})["ok"] is True
    assert client.call("file/dragDrop", {"from": "ux/folder/moved.txt", "to": "ux/dragged.txt"})["ok"] is True
    assert client.call("file/copy", {"from": "ux/dragged.txt", "to": "ux/copy.txt"}) is True
    assert client.call("file/delete", {"path": "ux/copy.txt"}) is True

    model = client.call("file/explorerModel", {"compactFolders": True, "exclude": "*.log"})
    assert model["compactFolders"] is True, model
    assert model["nesting"] is True, model
    assert model["decorations"][0]["badge"] == "M", model

    (cwd / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
    (cwd / "ux" / "search.txt").write_text("Alpha alpha\n", encoding="utf-8")
    preview = client.call("search/preview", {"file": "ux/search.txt", "query": "alpha", "replace": "beta"})
    assert preview["preview"] is True and preview["replacements"] == 1, preview
    replaced = client.call("search/replace", {"file": "ux/search.txt", "query": "alpha", "replace": "beta", "caseSensitive": False, "preserveCase": True})
    assert replaced["replacements"] == 2, replaced

    problems = client.call("editor/problems/query", {"groupByFile": True, "sort": "severity"})
    assert problems["groupByFile"] is True, problems
    assert problems["navigation"]["openLocation"] is True, problems
    reconciled = client.call("editor/problems/reconcile", {"groupByFile": True, "sort": "severity", "fixture": True})
    assert reconciled["reconciled"] is True, reconciled
    assert {"native", "task", "extension"} <= set(reconciled["sources"]), reconciled
    assert len(reconciled["problems"]) >= 3, reconciled
    assert any(problem["source"] == "task" and problem["severity"] == 2 for problem in reconciled["problems"]), reconciled

    channels = client.call("output/channels")
    assert any(channel["name"] == "WIZP" for channel in channels["channels"]), channels
    assert channels["channels"][0]["preserveScroll"] is True, channels

    ext_view = client.call("extensions/view")
    assert ext_view["supportsSearch"] and ext_view["supportsInstall"] and ext_view["detailsPane"], ext_view
    lifecycle = client.call("extensions/lifecycle", {"action": "install", "id": "fixture.extension"})
    assert lifecycle["ok"] is True and lifecycle["state"] == "completed", lifecycle
    management = client.call("extensions/management")
    assert management["source"] == "OpenVSX", management
    assert management["networkPolicy"] == "lazy-opt-in", management
    assert management["supportsInstall"] and management["supportsUpdate"], management
    assert management["supportsLocalVSIX"] and management["supportsHostRestart"], management
    assert management["supportsDisable"] and management["supportsEnable"] and management["supportsUninstall"], management
    assert management["detailsPane"] is True and management["errorSurface"] is True, management
    assert management["compatLedger"] == "docs/vscode-parity/KNOWN_EXTENSIONS.md", management
    assert "workbench.extensions.enableExtension" in management["commands"], management
    assert {"hub/search", "hub/list", "hub/install", "hub/installLocal", "hub/uninstall", "hub/toggle", "hub/markRestarted", "extension/hostStatus", "extension/restartHost"} <= set(management["uiRpcs"]), management
    assert {"searchConsentRequired", "searchResults", "installed", "enabled", "disabled", "updateAvailable", "uninstalled", "hostUnavailable", "restartRequired", "error"} <= set(management["states"]), management
    assert management["realPackageCi"] == "planned" and management["status"] == "contract-verified", management

    gated_search = client.call("hub/search", {"query": "theme"})
    assert gated_search["networkRequired"] is True and gated_search["status"] == "network-consent-required", gated_search
    fixture_search = client.call("hub/search", {"query": "alpha", "fixture": True})
    assert fixture_search["status"] == "fixture-search-complete", fixture_search
    assert fixture_search["total"] == 3, fixture_search
    assert any(item["id"] == "wizp-smoke.alpha-tools" for item in fixture_search["extensions"]), fixture_search
    assert any(item["id"] == "wizp-smoke.broken-tools" and item["installFailureFixture"] for item in fixture_search["extensions"]), fixture_search
    failed_fixture = client.raw("hub/install", {"namespace": "wizp-smoke", "name": "broken-tools", "fixture": True, "fixtureFailure": True})
    assert "error" in failed_fixture and "No extensions were changed" in failed_fixture["error"]["message"], failed_fixture
    installed = client.call("hub/install", {"namespace": "wizp-smoke", "name": "alpha-tools", "displayName": "Alpha Tools", "version": "1.0.0", "fixture": True})
    assert installed["ok"] is True and installed["state"] == "installed", installed
    listed = client.call("hub/list")
    assert any(item["id"] == "wizp-smoke.alpha-tools" and item["enabled"] is True and item["source"] == "fixture" for item in listed["installed"]), listed
    disabled = client.call("hub/toggle", {"id": "wizp-smoke.alpha-tools", "enabled": False})
    assert disabled["ok"] is True and disabled["enabled"] is False and disabled["state"] == "disabled", disabled
    enabled = client.call("hub/toggle", {"id": "wizp-smoke.alpha-tools", "enabled": True})
    assert enabled["ok"] is True and enabled["enabled"] is True and enabled["state"] == "enabled", enabled
    removed = client.call("hub/uninstall", {"id": "wizp-smoke.alpha-tools"})
    assert removed["ok"] is True and removed["state"] == "uninstalled", removed

    valid_vsix = cwd / "ui-lifecycle.vsix"
    invalid_vsix = cwd / "invalid-lifecycle.vsix"
    write_ui_lifecycle_vsix(valid_vsix)
    invalid_vsix.write_text("not a zip", encoding="utf-8")
    invalid_install = client.raw("hub/installLocal", {"path": str(invalid_vsix)})
    assert "error" in invalid_install and "VSIX install failed" in invalid_install["error"]["message"], invalid_install
    local_install = client.call("hub/installLocal", {"path": str(valid_vsix)})
    assert local_install["id"] == "wizp-smoke.ui-lifecycle", local_install
    assert local_install["displayName"] == "UI Lifecycle Extension", local_install
    assert local_install["restartRequired"] is True, local_install
    extension_path = cwd / "home" / ".wizp" / "extensions" / "wizp-smoke-ui-lifecycle"
    assert (extension_path / "package.json").is_file(), extension_path
    listed = client.call("hub/list")
    assert any(item["id"] == "wizp-smoke.ui-lifecycle" and item["source"] == "local" and item["restartRequired"] is True for item in listed["installed"]), listed
    permission_vsix = cwd / "permission-lifecycle.vsix"
    write_ui_lifecycle_vsix(permission_vsix, name="permission-lifecycle")
    extensions_dir = cwd / "home" / ".wizp" / "extensions"
    mode_before_failure = extensions_dir.stat().st_mode & 0o777
    installed_before_failure = client.call("hub/list")["installed"]
    os.chmod(extensions_dir, mode_before_failure & ~0o222)
    try:
        permission_failure = client.raw("hub/installLocal", {"path": str(permission_vsix)})
    finally:
        os.chmod(extensions_dir, mode_before_failure)
    assert permission_failure["error"]["code"] == -32011, permission_failure
    assert "retryable" in permission_failure["error"]["message"], permission_failure
    assert "No extensions were changed" in permission_failure["error"]["message"], permission_failure
    installed_after_failure = client.call("hub/list")["installed"]
    assert installed_after_failure == installed_before_failure, installed_after_failure
    assert not any(item.name.startswith(".installing-") for item in extensions_dir.iterdir()), extensions_dir
    permission_retry = client.call("hub/installLocal", {"path": str(permission_vsix)})
    assert permission_retry["id"] == "wizp-smoke.permission-lifecycle", permission_retry
    assert permission_retry["state"] == "installed", permission_retry
    permission_list = client.call("hub/list")["installed"]
    assert any(item["id"] == "wizp-smoke.permission-lifecycle" and item["enabled"] is True for item in permission_list), permission_list
    permission_removed = client.call("hub/uninstall", {"id": "wizp-smoke.permission-lifecycle"})
    assert permission_removed["state"] == "uninstalled", permission_removed
    assert client.call("hub/markRestarted")["state"] == "restarted"
    listed = client.call("hub/list")
    assert any(item["id"] == "wizp-smoke.ui-lifecycle" and item["restartRequired"] is False for item in listed["installed"]), listed
    disabled = client.call("hub/toggle", {"extensionId": "wizp-smoke.ui-lifecycle", "enabled": False})
    assert disabled["state"] == "disabled", disabled
    restarted_client = RpcClient(cwd, env={"HOME": str(cwd / "home"), "USERPROFILE": str(cwd / "home")})
    try:
        restarted_list = restarted_client.call("hub/list")
        assert any(item["id"] == "wizp-smoke.ui-lifecycle" and item["enabled"] is False for item in restarted_list["installed"]), restarted_list
    finally:
        restarted_client.close()
    enabled = client.call("hub/toggle", {"extensionId": "wizp-smoke.ui-lifecycle", "enabled": True})
    assert enabled["state"] == "enabled", enabled
    host_status = client.call("extension/hostStatus")
    assert host_status["available"] is False and host_status["state"] == "unavailable", host_status
    removed = client.call("hub/uninstall", {"id": "wizp-smoke.ui-lifecycle"})
    assert removed["state"] == "uninstalled" and not extension_path.exists(), removed

    client.call("config/set", {"key": "editor.wordWrap", "value": "on", "scope": "user"})
    settings = client.call("settings/query", {"query": "editor.wordWrap", "modifiedOnly": True})
    assert settings["modifiedOnly"] is True, settings
    assert any(item["key"].endswith("editor.wordWrap") or item["key"] == "user:editor.wordWrap" for item in settings["settings"]), settings

    timeline = client.call("git/timeline")
    assert timeline["commits"], timeline

    outline = client.call("textDocument/documentSymbol", {"uri": "file://" + str(cwd / "symbols.zig")})
    assert any(item["name"] == "Thing" and item.get("children") for item in outline), outline
    normalized_outline = client.call("outline/normalize")
    assert normalized_outline["treeNormalized"] is True and normalized_outline["nested"] is True, normalized_outline
    assert normalized_outline["rangeBacked"] is True and normalized_outline["followCursor"] is True, normalized_outline
    assert any(item["name"] == "init" and item["depth"] == 1 and item["containerName"] == "Thing" for item in normalized_outline["symbols"]), normalized_outline

    progress = client.call("notifications/progress", {"title": "Long Task"})
    assert progress["cancellable"] is True and progress["state"] == "running", progress
    cancelled = client.call("notifications/cancel", {"id": progress["id"]})
    assert cancelled["cancelled"] is True, cancelled
    assert client.call("notifications/list")["centerVisible"] is True

    audit = client.call("accessibility/audit")
    assert audit["critical"] == 0, audit
    assert audit["keyboardNavigation"] is True and audit["focusOrder"] is True, audit
    assert audit["zlayNativeSurfaceCount"] == 8 and audit["zlayMetadataRegistry"] is True, audit
    interaction = client.call(
        "editor/interactionAudit",
        {"lineCount": 120, "viewportLines": 20, "query": "alpha"},
    )
    assert interaction["engine"] == "zlay", interaction
    assert interaction["focusedSurface"] == 1, interaction
    assert interaction["visibleLineRange"] == {"start": 0, "end": 22}, interaction
    assert interaction["query"] == {"length": 5, "cursor": 5}, interaction
    scrolled = client.call(
        "editor/interactionAudit",
        {"lineCount": 120, "viewportLines": 20, "scrollOffset": 37},
    )
    assert scrolled["scrollOffset"] == 37, scrolled
    assert scrolled["visibleLineRange"] == {"start": 35, "end": 59}, scrolled
    dispatched = client.call(
        "editor/interactionAudit",
        {"lineCount": 120, "viewportLines": 20, "focusedSurface": 8, "pointerSurface": 3},
    )
    assert dispatched["focusedSurface"] == 8, dispatched
    assert dispatched["pointer"] == {
        "hoveredSurface": 3,
        "targetSurface": 3,
        "dispatch": "hit_test",
    }, dispatched
    captured = client.call(
        "editor/interactionAudit",
        {"lineCount": 20, "viewportLines": 10, "focusedSurface": 8, "pointerSurface": 3, "captureSurface": 8},
    )
    assert captured["keyboard"] == {"targetSurface": 8, "dispatch": "focused"}, captured
    assert captured["pointer"]["targetSurface"] == 8 and captured["pointer"]["dispatch"] == "captured", captured
    continued = client.call(
        "editor/interactionAudit",
        {"lineCount": 20, "viewportLines": 10, "focusedSurface": 8, "pointerSurface": 3},
    )
    assert continued["pointer"]["targetSurface"] == 8 and continued["pointer"]["dispatch"] == "captured", continued
    released = client.call(
        "editor/interactionAudit",
        {"lineCount": 20, "viewportLines": 10, "focusedSurface": 8, "pointerSurface": 3, "releaseCapture": True},
    )
    assert released["pointer"]["targetSurface"] == 8 and released["pointer"]["dispatch"] == "captured", released
    advanced = client.call(
        "editor/interactionAudit",
        {"lineCount": 20, "viewportLines": 10, "focusedSurface": 8, "advanceFocus": True},
    )
    assert advanced["focusedSurface"] == 1, advanced
    assert advanced["keyboard"] == {"targetSurface": 1, "dispatch": "focused"}, advanced

    sorted_editors = client.call("editor/openSorted", {"order": "desc", "rule": "name-local"})
    assert sorted_editors["openPositioning"] == "sort", sorted_editors
    assert sorted_editors["descending"] is True, sorted_editors

    crumb = client.call("breadcrumbs/navigate", {"path": str(cwd / "symbols.zig"), "symbol": "Thing"})
    assert crumb["jumped"] is True and crumb["overlapCritical"] == 0, crumb
    folder_crumb = client.call("breadcrumbs/interaction", {"type": "folder", "path": str(cwd)})
    assert folder_crumb["action"] == "listDirectory" and folder_crumb["rpc"] == "file/list", folder_crumb
    assert folder_crumb["click"] is True and folder_crumb["keyboard"] is True, folder_crumb
    file_crumb = client.call("breadcrumbs/interaction", {"type": "file", "path": str(cwd / "symbols.zig")})
    assert file_crumb["action"] == "openFileSymbols" and file_crumb["rpc"] == "textDocument/documentSymbol", file_crumb
    symbol_crumb = client.call("breadcrumbs/interaction", {"type": "symbol", "path": str(cwd / "symbols.zig"), "symbol": "Thing"})
    assert symbol_crumb["action"] == "jumpToSymbol" and symbol_crumb["rpc"] == "editor/reveal", symbol_crumb
    assert symbol_crumb["overlapCritical"] == 0, symbol_crumb

    lsp_matrix = client.call("lsp/lifecycleMatrix")
    servers = {server["id"]: server for server in lsp_matrix["servers"]}
    assert {"zls", "rust-analyzer", "typescript-language-server"} <= set(servers), lsp_matrix
    for server in servers.values():
        assert server["initialize"] is True and server["restart"] is True and server["shutdown"] is True, server
        assert server["capabilities"], server
    assert "documentSymbolProvider" in servers["zls"]["capabilities"], servers["zls"]
    assert "semanticTokensProvider" in servers["rust-analyzer"]["capabilities"], servers["rust-analyzer"]
    assert "signatureHelpProvider" in servers["typescript-language-server"]["capabilities"], servers["typescript-language-server"]
    assert lsp_matrix["persistedCapabilities"] is True and lsp_matrix["supervised"] is True, lsp_matrix
    assert lsp_matrix["overlapCritical"] == 0, lsp_matrix


def test_platform_packaging_security(client: RpcClient) -> None:
    package = client.call("platform/package")
    assert package["app"] == "WIZP", package
    assert package["electrobun"] is True, package
    assert "build:electrobun" in package["scripts"], package
    assert package["singleBinaryFrontend"] is True, package

    native = client.call("platform/native")
    assert native["linux"]["webview"] == "electrobun", native
    assert native["linux"]["pty"] == "posix", native
    assert native["macos"]["verified"] == "external-required", native
    assert native["windows"]["verified"] == "external-required", native

    cross_os = client.call("platform/crossOsPackageSmoke")
    assert cross_os["runner"] == "scripts/parity_cross_os_package_smoke.py", cross_os
    assert cross_os["linux"]["verified"] is True, cross_os
    assert cross_os["macos"]["verified"] == "external-runner-required", cross_os
    assert cross_os["windows"]["verified"] == "external-runner-required", cross_os
    assert "startup-log" in cross_os["artifacts"], cross_os

    update = client.call("platform/update")
    assert update["signatureRequired"] is True, update
    assert update["unsignedRejected"] is True, update
    assert update["deltaSupported"] is True and update["fullUpdateSupported"] is True, update

    signed_update = client.call("platform/signedUpdateSmoke")
    assert signed_update["signatureFixture"] is True, signed_update
    assert signed_update["validSignatureAccepted"] is True, signed_update
    assert signed_update["unsignedRejected"] is True, signed_update
    assert signed_update["tamperedRejected"] is True, signed_update
    assert signed_update["rollbackSafe"] is True, signed_update

    sandbox = client.call("extension/securityAudit")
    assert sandbox["workspaceFsOnly"] is True, sandbox
    assert sandbox["forbiddenDirectFs"] is True, sandbox
    assert sandbox["secretStorage"] == "encrypted-fallback", sandbox
    assert sandbox["secretStoragePlaintextOnDisk"] is False, sandbox
    assert sandbox["osKeyring"] is False, sandbox
    assert sandbox["proposedApiDefaultDenied"] is True, sandbox

    webview = client.call("webview/securityAudit")
    assert webview["localResourceRootsEnforced"] is True, webview
    assert webview["outsideWorkspaceDenied"] is True, webview
    assert webview["messageOrdering"] == "fifo-contract", webview
    assert webview["retainContextWhenHidden"] is True, webview
    assert webview["cspEnforced"] is True, webview
    assert webview["sandboxedIframe"] is True, webview
    assert webview["exploitRegressionDenied"] is True, webview

    assert client.call("webview/create", {"id": "empty-webview", "title": "Empty webview", "html": ""}) is True
    panels = client.call("webview/list")["panels"]
    assert next(panel for panel in panels if panel["id"] == "empty-webview")["html"] == "", panels
    assert client.call("webview/dispose", {"id": "empty-webview"}) is True

    webview_lifecycle = client.call("webview/lifecycleSmoke")
    assert webview_lifecycle["created"] is True, webview_lifecycle
    assert webview_lifecycle["retainedWhenHidden"] is True, webview_lifecycle
    assert webview_lifecycle["revealed"] is True, webview_lifecycle
    assert webview_lifecycle["messageOrder"] == ["one", "two", "three"], webview_lifecycle
    assert webview_lifecycle["messageOrdering"] == "fifo-contract", webview_lifecycle
    assert "default-src 'none'" in webview_lifecycle["csp"], webview_lifecycle
    assert webview_lifecycle["outsideWorkspaceDenied"] is True, webview_lifecycle
    assert webview_lifecycle["disposed"] is True, webview_lifecycle
    assert webview_lifecycle["disposeRevokesPanel"] is True, webview_lifecycle
    assert webview_lifecycle["exploitRegressionDenied"] is True, webview_lifecycle
    assert webview_lifecycle["browserFixture"] == "08-webview-lifecycle.png", webview_lifecycle

    webview_view = client.call("webviewView/lifecycleSmoke")
    assert webview_view["viewId"] == "basicApiSmoke.sidebarView", webview_view
    assert webview_view["resolved"] is True and webview_view["resolveCount"] == 1, webview_view
    assert webview_view["stateful"] is True and webview_view["messageRoundtrip"] is True, webview_view
    assert webview_view["outsideWorkspaceDenied"] is True and webview_view["disposed"] is True, webview_view
    assert webview_view["resolverPath"] == "extension/resolveWebviewView", webview_view

    custom_editor = client.call("customEditor/lifecycleSmoke")
    assert custom_editor["viewType"] == "basicApiSmoke.customEditor", custom_editor
    assert custom_editor["selector"] == "*.smoke-custom", custom_editor
    assert custom_editor["activation"] == "lazy-open", custom_editor
    assert custom_editor["opened"] is True, custom_editor
    assert custom_editor["rendered"] is True, custom_editor
    assert custom_editor["messageRoundtrip"] is True, custom_editor
    assert custom_editor["save"] is True, custom_editor
    assert custom_editor["revert"] is True, custom_editor
    assert custom_editor["disposed"] is True, custom_editor
    assert custom_editor["supportsMultipleEditorsPerDocument"] is True, custom_editor
    assert custom_editor["preservesWizpChrome"] is True, custom_editor
    assert custom_editor["browserFixture"] == "04-custom-editor.png", custom_editor

    notebook = client.call("notebook/lifecycleSmoke")
    assert notebook["viewType"] == "smoke-notebook", notebook
    assert notebook["controllerId"] == "smoke-notebook", notebook
    assert notebook["opened"] is True, notebook
    assert notebook["deserialized"] is True, notebook
    assert notebook["cellCount"] == 2, notebook
    assert notebook["supportedLanguages"] == ["smokelang"], notebook
    assert notebook["executed"] is True, notebook
    assert notebook["outputs"][0]["kind"] == "stdout", notebook
    assert notebook["outputs"][1]["kind"] == "error", notebook
    assert notebook["saved"] is True, notebook
    assert notebook["reloaded"] is True, notebook
    assert notebook["disposed"] is True, notebook
    assert notebook["activation"] == "lazy-open", notebook
    assert notebook["browserFixture"] == "04-notebook.png", notebook

    tests = client.call("tests/lifecycleSmoke")
    assert tests["controllerId"] == "smoke-tests", tests
    assert tests["label"] == "Smoke Tests", tests
    assert tests["discovered"] is True, tests
    assert [item["id"] for item in tests["items"]] == ["smoke-pass", "smoke-fail", "smoke-skip"], tests
    assert tests["runProfiles"][0]["label"] == "Smoke Run Profile", tests
    assert tests["runProfiles"][0]["kind"] == "run", tests
    assert tests["runProfiles"][0]["isDefault"] is True, tests
    assert tests["runRequested"] is True, tests
    assert tests["results"][0]["state"] == "passed", tests
    assert tests["results"][1]["state"] == "failed", tests
    assert tests["results"][2]["state"] == "skipped", tests
    assert "smoke test output" in tests["output"], tests
    assert tests["disposed"] is True, tests
    assert tests["browserFixture"] == "04-test-explorer.png", tests

    ext_polish = client.call("extensionHost/polishSmoke")
    assert "path" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:util" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:assert" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:url" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:dns" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:module" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:console" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert "node:async_hooks" in ext_polish["nodeBuiltinPlan"]["covered"], ext_polish
    assert ext_polish["activationErrorUi"] is True, ext_polish
    assert ext_polish["processRestartMementoSoak"] is True, ext_polish
    assert ext_polish["secretStorage"]["encryptedFallback"] is True, ext_polish
    assert ext_polish["secretStorage"]["osKeyringOptional"] is True, ext_polish
    assert ext_polish["envCallbacks"] is True, ext_polish
    assert ext_polish["l10nBundles"] is True, ext_polish
    assert ext_polish["chatProviderContract"] is True, ext_polish
    assert ext_polish["proposedApiOptInPolicy"] is True, ext_polish

    lightweight = client.call("workbench/lightweightAudit")
    assert lightweight["preservesLightweightDefault"] is True, lightweight
    assert "TextMate-Oniguruma" in lightweight["optIn"], lightweight
    assert "Ghostty-native-renderer" in lightweight["optIn"], lightweight
    suite = client.call("workbench/suiteManifest")
    assert suite["suite"] == "lichforge-workstation", suite
    assert suite["orchestration"] == "WIZP" and suite["language"] == "zig", suite
    assert {project["id"] for project in suite["projects"]} == {
        "ZNAP",
        "ZIPI",
        "ZINC",
        "ZMITH",
        "WIZP",
        "DOT",
        "ARCGEN",
        "NOCTTY",
        "NOCTED",
        "OVERZEER",
    }, suite
    availability = {project["id"]: project["available"] for project in suite["projects"]}
    assert availability["WIZP"] is True, availability
    launch_plan = client.call("workbench/suiteLaunchPlan")
    assert launch_plan["policy"] == "explicit-opt-in", launch_plan
    assert launch_plan["execution"] == "disabled-by-default", launch_plan
    assert all(item["requiresConfirmation"] for item in launch_plan["descriptors"]), launch_plan
    assert {item["id"] for item in launch_plan["descriptors"]} == {project["id"] for project in suite["projects"]}, launch_plan
    health = client.call("workbench/suiteHealth")
    assert health["probe"] == "filesystem-only" and health["sideEffects"] is False, health
    health_by_id = {project["id"]: project for project in health["projects"]}
    assert health_by_id["WIZP"]["ready"] is True, health
    assert health_by_id["ZIPI"]["capability"] == "inference", health
    assert health["status"] == "probe-complete", health
    request = client.call(
        "workbench/suiteLaunchRequest",
        {"project": "ZIPI", "workspaceRoot": ".", "execute": True},
    )
    assert request["project"] == "ZIPI", request
    assert request["dryRun"] is True and request["executionBlocked"] is True, request
    assert request["executeRequested"] is True and request["requiresConfirmation"] is True, request
    assert request["status"] == "launch-not-started", request
    assert "debug-adapters" in lightweight["lazy"], lightweight

    auth = client.call("auth/lifecycleSmoke")
    assert auth["providerId"] == "smoke-auth", auth
    assert auth["sessionPersisted"] is True, auth
    assert auth["account"]["id"] == "smoke-account", auth
    assert auth["scopes"] == ["repo"], auth
    assert auth["secretStorage"] == "encrypted-fallback", auth
    assert auth["osKeyring"] is False, auth
    assert auth["plaintextOnDisk"] is False, auth
    assert auth["restartReload"] is True, auth
    assert auth["redacted"] is True, auth
    assert auth["browserFixture"] == "10-auth-secrets.png", auth

    normalized = client.call("platform/normalizePath")
    assert normalized["roundtrip"] is True, normalized
    assert normalized["posix"]["uri"].startswith("file:///"), normalized
    assert normalized["windows"]["path"].startswith("C:\\"), normalized

    matrix = client.call("extensions/compatMatrix")
    assert matrix["ledger"] == "docs/vscode-parity/KNOWN_EXTENSIONS.md", matrix
    assert matrix["curatedCount"] >= 20, matrix
    assert "Unknown" in matrix["tiers"], matrix

    real_extensions = client.call("extensions/realPackageSmoke")
    assert real_extensions["runner"] == "scripts/parity_real_extension_smoke.py", real_extensions
    assert len(real_extensions["curated"]) >= 3, real_extensions
    assert "install-into-temp-extension-home" in real_extensions["steps"], real_extensions
    assert "discover-command-surface" in real_extensions["steps"], real_extensions
    assert real_extensions["networkPackageVerification"] == "optional-env:WIZP_REAL_EXTENSION_NETWORK", real_extensions
    assert real_extensions["loadabilityVerification"] == "optional-env:WIZP_REAL_EXTENSION_LOAD", real_extensions
    assert real_extensions["runtimeVerification"] == "optional-env:WIZP_REAL_EXTENSION_RUNTIME", real_extensions
    assert real_extensions["localFixtureVerified"] == "basic-api-smoke", real_extensions
    assert real_extensions["realPackageExecution"] == "editorconfig-runtime-command-side-effect-verified", real_extensions
    assert real_extensions["runtimeCommand"] == "EditorConfig.generate", real_extensions
    assert "streetsidesoftware.code-spell-checker" in real_extensions["runtimeLanguageClients"], real_extensions
    assert real_extensions["remaining"] == [], real_extensions
    assert real_extensions["status"] == "curated-runtime-verified", real_extensions
    assert "verify-runtime-side-effect" in real_extensions["steps"], real_extensions
    assert "verify-language-client-api" in real_extensions["steps"], real_extensions


def test_performance_reliability(client: RpcClient) -> None:
    startup = client.call("performance/startup")
    assert startup["benchmarkScript"] == "scripts/benchmark-startup.js", startup
    assert startup["guiBenchmarkScript"] == "scripts/benchmark-gui-startup.js", startup
    assert startup["coldBudgetMs"] <= 2000, startup
    assert startup["nativeWindowBudgetMs"] <= 500, startup
    assert startup["rendererFirstRafProof"] is True, startup
    assert startup["assetCacheRequired"] is True, startup

    large_file = client.call("performance/largeFileMode")
    assert large_file["thresholdBytes"] == 50 * 1024 * 1024, large_file
    assert large_file["largeFileOptimizations"] is True, large_file
    assert "semanticTokens" in large_file["disabledFeatures"], large_file

    search = client.call("performance/searchScalability")
    assert search["fixtureFiles"] >= 1000, search
    assert search["streamsResults"] is True, search
    assert search["cancellable"] is True, search

    isolation = client.call("reliability/extensionHostIsolation")
    assert isolation["hostIsolated"] is True, isolation
    assert isolation["daemonSurvivesExtensionCrash"] is True, isolation
    assert isolation["activationErrorsCaptured"] is True, isolation

    supervision = client.call("reliability/processSupervision")
    assert supervision["lsp"]["reportsDeadServer"] is True, supervision
    assert supervision["dap"]["reportsDeadAdapter"] is True, supervision

    memory = client.call("performance/memoryLeakCheck")
    assert memory["iterations"] >= 50, memory
    assert memory["maxGrowthMb"] <= 32, memory
    assert "webviewCreateDispose" in memory["workflows"], memory

    stress = client.call("performance/stressBudgets")
    assert stress["runner"] == "scripts/parity_stress_smoke.py", stress
    assert stress["budgets"]["startupColdMs"] <= 2000, stress
    assert stress["budgets"]["largeFileBytes"] == 50 * 1024 * 1024, stress
    assert stress["budgets"]["memoryGrowthMb"] <= 32, stress
    assert "crash-recovery" in stress["workflows"], stress
    assert stress["guiStartupBenchmarkArtifact"] == "build/parity-stress/gui-startup-benchmark.json", stress
    assert stress["localContractVerified"] is True, stress

    diagnostics = client.call("diagnostics/export")
    assert diagnostics["archive"].endswith(".zip"), diagnostics
    assert diagnostics["redactsSecrets"] is True, diagnostics
    assert "recentErrors" in diagnostics["includes"], diagnostics
    assert diagnostics["materialized"] is True and diagnostics["downloadable"] is True, diagnostics
    archive_path = client.cwd / diagnostics["path"]
    assert archive_path.exists() and archive_path.stat().st_size == diagnostics["bytes"], diagnostics
    with zipfile.ZipFile(archive_path) as bundle:
        assert "diagnostics.json" in bundle.namelist(), bundle.namelist()
        payload = json.loads(bundle.read("diagnostics.json").decode("utf-8"))
    assert payload["redactsSecrets"] is True, payload
    assert payload["config"]["apiKey"] == "<redacted>", payload
    assert "recentErrors" in payload, payload

    diagnostics_browser = client.call("diagnostics/browserDownloadSmoke")
    assert diagnostics_browser["downloadRpc"] == "diagnostics/export", diagnostics_browser
    assert diagnostics_browser["downloadable"] is True, diagnostics_browser
    assert diagnostics_browser["openableZip"] is True, diagnostics_browser
    assert diagnostics_browser["redactsSecrets"] is True, diagnostics_browser

    activation_errors = client.call("extensions/activationErrors")
    assert activation_errors["daemonHealthy"] is True, activation_errors
    assert activation_errors["extensionsViewShowsErrors"] is True, activation_errors
    assert activation_errors["errors"][0]["canDisable"] is True, activation_errors

    debug_prompt = client.call("debug/adapterInstallPrompt")
    assert debug_prompt["adapterMissing"] is True, debug_prompt
    assert debug_prompt["prompt"] is True, debug_prompt
    assert debug_prompt["manualInstall"] is True, debug_prompt
    assert debug_prompt["marketplaceSearch"] is True, debug_prompt
    assert debug_prompt["cancelDefault"] is True, debug_prompt
    assert debug_prompt["noAutoNetwork"] is True, debug_prompt

    accessibility_browser = client.call("accessibility/browserSmoke")
    assert accessibility_browser["critical"] == 0, accessibility_browser
    assert accessibility_browser["keyboardOnly"] is True, accessibility_browser
    assert accessibility_browser["focusTrap"] is True, accessibility_browser
    assert accessibility_browser["screenReaderLabels"] is True, accessibility_browser
    assert "Terminal" in accessibility_browser["regions"], accessibility_browser


def test_first_run_workspace(client: RpcClient) -> None:
    folders = client.call("workspace/getFolders")
    assert folders == {"folders": []}, folders
    search = client.raw("search/text", {"query": "main"})
    assert search.get("error", {}).get("code") == -32001, search


def main() -> int:
    if not DEFAULT_BIN.exists():
        raise SystemExit(f"missing daemon binary: {DEFAULT_BIN}; run npm run build first")
    with tempfile.TemporaryDirectory(prefix="wizp-parity-daemon-") as tmp:
        cwd = Path(tmp)
        home = cwd / "home"
        home.mkdir()
        client = RpcClient(cwd, env={"HOME": str(home), "USERPROFILE": str(home)})
        try:
            test_first_run_workspace(client)
            test_git(client, cwd)
            test_symbols(client, cwd)
            test_text_document_model(client, cwd)
            test_diff_editor_rpc(client, cwd)
            test_debug(client)
            test_search_and_explorer(client, cwd)
            test_in_file_find_replace(client, cwd)
            test_snippet_expansion(client, cwd)
            test_workspace_core(client, cwd)
            test_config_scopes(client)
            test_ghostty_probe(client)
            test_terminal_tasks(client, cwd)
            test_builtin_views_ux(client, cwd)
            test_platform_packaging_security(client)
            test_performance_reliability(client)
        finally:
            client.close()
    print("parity daemon smoke ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
