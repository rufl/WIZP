#!/usr/bin/env python3
"""Generate a pinned VS Code API drift report for WIZP beta readiness."""

from __future__ import annotations

import json
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_ROOT = Path(__file__).resolve().parents[1]
BASELINE = REPO_ROOT / "docs" / "vscode-parity" / "vscode-api-baseline.json"
EXTENSION_HOST = PROJECT_ROOT / "src" / "hub" / "ExtensionHost.zig"
SMOKE_FIXTURE = PROJECT_ROOT / "testdata" / "extensions" / "basic-api-smoke" / "extension.js"
REPORT = PROJECT_ROOT / "build" / "vscode-parity" / "api-drift-report.json"


SUPPORT_PROBES: dict[str, list[str]] = {
    "authentication.getSession": [r"getSession: async function"],
    "authentication.registerAuthenticationProvider": [r"registerAuthenticationProvider: function"],
    "commands.executeCommand": [r"executeCommand: function"],
    "commands.registerCommand": [r"registerCommand: function"],
    "commands.registerTextEditorCommand": [r"registerTextEditorCommand: function"],
    "comments.createCommentController": [r"createCommentController: function"],
    "debug.registerDebugAdapterDescriptorFactory": [r"registerDebugAdapterDescriptorFactory: function"],
    "debug.startDebugging": [r"startDebugging: function"],
    "env.clipboard.readText": [r"clipboard: \{", r"readText: function"],
    "env.clipboard.writeText": [r"clipboard: \{", r"writeText: function"],
    "env.openExternal": [r"openExternal: function"],
    "extensions.getExtension": [r"getExtension: function"],
    "languages.createDiagnosticCollection": [r"createDiagnosticCollection: function"],
    "languages.match": [r"match: function"],
    "languages.registerCallHierarchyProvider": [r"registerCallHierarchyProvider: function"],
    "languages.registerCodeActionsProvider": [r"registerCodeActionsProvider: function"],
    "languages.registerCodeLensProvider": [r"registerCodeLensProvider: function"],
    "languages.registerCompletionItemProvider": [r"registerCompletionItemProvider: function"],
    "languages.registerDeclarationProvider": [r"registerDeclarationProvider: function"],
    "languages.registerDefinitionProvider": [r"registerDefinitionProvider: function"],
    "languages.registerDocumentFormattingEditProvider": [r"registerDocumentFormattingEditProvider: function"],
    "languages.registerDocumentHighlightProvider": [r"registerDocumentHighlightProvider: function"],
    "languages.registerDocumentLinkProvider": [r"registerDocumentLinkProvider: function"],
    "languages.registerDocumentRangeFormattingEditProvider": [r"registerDocumentRangeFormattingEditProvider: function"],
    "languages.registerDocumentSemanticTokensProvider": [r"registerDocumentSemanticTokensProvider: function"],
    "languages.registerFoldingRangeProvider": [r"registerFoldingRangeProvider: function"],
    "languages.registerHoverProvider": [r"registerHoverProvider: function"],
    "languages.registerImplementationProvider": [r"registerImplementationProvider: function"],
    "languages.registerInlayHintsProvider": [r"registerInlayHintsProvider: function"],
    "languages.registerOnTypeFormattingEditProvider": [r"registerOnTypeFormattingEditProvider: function"],
    "languages.registerReferenceProvider": [r"registerReferenceProvider: function"],
    "languages.registerRenameProvider": [r"registerRenameProvider: function"],
    "languages.registerSelectionRangeProvider": [r"registerSelectionRangeProvider: function"],
    "languages.registerSignatureHelpProvider": [r"registerSignatureHelpProvider: function"],
    "languages.registerTypeDefinitionProvider": [r"registerTypeDefinitionProvider: function"],
    "notebooks.createNotebookController": [r"createNotebookController: function"],
    "scm.createSourceControl": [r"createSourceControl: function"],
    "tasks.fetchTasks": [r"fetchTasks: function"],
    "tasks.registerTaskProvider": [r"registerTaskProvider: function"],
    "tests.createTestController": [r"createTestController: function"],
    "window.activeTextEditor": [r"get activeTextEditor\(\)"],
    "window.createOutputChannel": [r"createOutputChannel: function"],
    "window.createStatusBarItem": [r"createStatusBarItem: function"],
    "window.createTerminal": [r"createTerminal: function"],
    "window.createTextEditorDecorationType": [r"createTextEditorDecorationType: function"],
    "window.createTreeView": [r"createTreeView: function"],
    "window.createWebviewPanel": [r"createWebviewPanel: function"],
    "window.showErrorMessage": [r"showErrorMessage: function"],
    "window.showInformationMessage": [r"showInformationMessage: function"],
    "window.showInputBox": [r"showInputBox: function"],
    "window.showQuickPick": [r"showQuickPick: function"],
    "window.showTextDocument": [r"showTextDocument: async function"],
    "window.showWarningMessage": [r"showWarningMessage: function"],
    "window.withProgress": [r"withProgress: async function"],
    "workspace.applyEdit": [r"applyEdit: async function"],
    "workspace.createFileSystemWatcher": [r"createFileSystemWatcher: function"],
    "workspace.findFiles": [r"findFiles: async function"],
    "workspace.fs.copy": [r"copy: async function"],
    "workspace.fs.createDirectory": [r"createDirectory: async function"],
    "workspace.fs.delete": [r"delete: async function"],
    "workspace.fs.readDirectory": [r"readDirectory: async function"],
    "workspace.fs.readFile": [r"readFile: async function"],
    "workspace.fs.rename": [r"rename: async function"],
    "workspace.fs.stat": [r"stat: async function"],
    "workspace.fs.writeFile": [r"writeFile: async function"],
    "workspace.getConfiguration": [r"getConfiguration: function"],
    "workspace.onDidChangeTextDocument": [r"onDidChangeTextDocument: function"],
    "workspace.onDidGrantWorkspaceTrust": [r"onDidGrantWorkspaceTrust: function"],
    "workspace.onWillSaveTextDocument": [r"onWillSaveTextDocument: function"],
    "workspace.openTextDocument": [r"openTextDocument: async function"],
    "workspace.registerFileSystemProvider": [r"registerFileSystemProvider: function"],
}


CONTRIBUTION_PROBES: dict[str, list[str]] = {
    "breakpoints": [r"parseBreakpointContributions", r"\"breakpoints\""],
    "commands": [r"parseCommandContributions", r"\"commands\""],
    "configuration": [r"parseConfigurationContributions", r"\"configuration\""],
    "debuggers": [r"parseDebuggerContributions", r"\"debuggers\""],
    "grammars": [r"parseGrammarContributions", r"\"grammars\""],
    "iconThemes": [r"parseIconThemeContributions", r"\"iconThemes\""],
    "jsonValidation": [r"parseJsonValidationContributions", r"\"jsonValidation\""],
    "keybindings": [r"parseKeybindingContributions", r"\"keybindings\""],
    "languages": [r"parseLanguageContributions", r"\"languages\""],
    "menus": [r"parseMenuContributions", r"\"menus\""],
    "problemMatchers": [r"parseProblemMatcherContributions", r"\"problemMatchers\""],
    "resourceLabelFormatters": [r"parseResourceLabelFormatterContributions", r"\"resourceLabelFormatters\""],
    "snippets": [r"parseSnippetContributions", r"\"snippets\""],
    "taskDefinitions": [r"parseTaskDefinitionContributions", r"\"taskDefinitions\""],
    "themes": [r"parseThemeContributions", r"\"themes\""],
    "views": [r"parseViewContributions", r"\"views\""],
    "viewsContainers": [r"parseViewContainerContributions", r"\"viewsContainers\""],
    "viewsWelcome": [r"parseViewsWelcomeContributions", r"\"viewsWelcome\""],
    "walkthroughs": [r"parseWalkthroughContributions", r"\"walkthroughs\""],
}


def has_all(text: str, patterns: list[str]) -> bool:
    return all(re.search(pattern, text) for pattern in patterns)


def main() -> int:
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    host_text = EXTENSION_HOST.read_text(encoding="utf-8")
    fixture_text = SMOKE_FIXTURE.read_text(encoding="utf-8") if SMOKE_FIXTURE.exists() else ""
    combined = host_text + "\n" + fixture_text
    known_gaps = {item["symbol"]: item for item in baseline.get("knownGaps", [])}

    supported_symbols = sorted(
        symbol
        for symbol in baseline.get("stableSymbols", [])
        if has_all(combined, SUPPORT_PROBES.get(symbol, [re.escape(symbol.split(".")[-1])]))
    )
    missing_symbols = sorted(symbol for symbol in baseline.get("stableSymbols", []) if symbol not in supported_symbols)
    untracked_missing = sorted(symbol for symbol in missing_symbols if symbol not in known_gaps)
    tracked_gaps = [known_gaps[symbol] for symbol in sorted(known_gaps)]

    supported_contributions = sorted(
        point
        for point in baseline.get("contributionPoints", [])
        if has_all(combined, CONTRIBUTION_PROBES.get(point, [re.escape(point)]))
    )
    missing_contributions = sorted(
        point for point in baseline.get("contributionPoints", []) if point not in supported_contributions
    )

    status = "baseline-pinned-drift-recorded" if not untracked_missing and not missing_contributions else "blocked"
    payload = {
        "schema": "wizp.vscode-api-drift-report.v1",
        "status": status,
        "baseline": baseline.get("baseline", {}),
        "counts": {
            "stableSymbols": len(baseline.get("stableSymbols", [])),
            "supportedSymbols": len(supported_symbols),
            "trackedGaps": len(tracked_gaps),
            "untrackedMissingSymbols": len(untracked_missing),
            "contributionPoints": len(baseline.get("contributionPoints", [])),
            "supportedContributionPoints": len(supported_contributions),
            "missingContributionPoints": len(missing_contributions),
        },
        "supportedSymbols": supported_symbols,
        "trackedGaps": tracked_gaps,
        "untrackedMissingSymbols": untracked_missing,
        "supportedContributionPoints": supported_contributions,
        "missingContributionPoints": missing_contributions,
        "evidence": {
            "host": str(EXTENSION_HOST.relative_to(REPO_ROOT)),
            "fixture": str(SMOKE_FIXTURE.relative_to(REPO_ROOT)),
            "baseline": str(BASELINE.relative_to(REPO_ROOT)),
        },
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"VS Code API drift report: {REPORT} ({status})")
    return 0 if status != "blocked" else 1


if __name__ == "__main__":
    raise SystemExit(main())
