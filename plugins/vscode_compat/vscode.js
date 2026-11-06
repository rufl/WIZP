/**
 * WIZP - VS Code Extension API Shim
 * Provides the `vscode` module API that VS Code extensions expect.
 * All operations are proxied to WIZP via MCP JSON-RPC over stdio.
 * 
 * This enables 100% compatibility with Open VSX extensions
 * by providing the full vscode namespace that extensions import.
 */

const { EventEmitter } = require('events');

// ============================================================
// MCP Bridge to WIZP
// ============================================================

class MCPBridge {
    constructor() {
        this._id = 0;
        this._pending = new Map();
        this._events = new EventEmitter();
        this._setupStdio();
        this._sendInitialize();
    }

    _setupStdio() {
        process.stdin.setEncoding('utf8');
        let buffer = '';
        process.stdin.on('data', (chunk) => {
            buffer += chunk;
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';
            for (const line of lines) {
                if (!line.trim()) continue;
                try {
                    const msg = JSON.parse(line);
                    if (msg.id !== undefined && msg.id !== null) {
                        const resolve = this._pending.get(msg.id);
                        if (resolve) {
                            this._pending.delete(msg.id);
                            resolve(msg.result);
                        }
                    } else if (msg.method) {
                        this._events.emit(msg.method, msg.params);
                    }
                } catch (e) {}
            }
        });
    }

    _sendInitialize() {
        this.request('initialize', {
            protocolVersion: '2024-11-05',
            capabilities: { tools: {}, resources: {} },
            clientInfo: { name: 'wizp-vscode-extension', version: '1.0.0' }
        });
    }

    request(method, params) {
        return new Promise((resolve) => {
            this._id++;
            const id = this._id;
            this._pending.set(id, resolve);
            const msg = JSON.stringify({ jsonrpc: '2.0', id, method, params: params || {} });
            process.stdout.write(msg + '\n');
        });
    }

    notify(method, params) {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params: params || {} }) + '\n');
    }
}

const bridge = new MCPBridge();

// ============================================================
// vscode namespace (compatibility shim)
// ============================================================

const vscode = {
    version: '1.95.0',

    // URI
    Uri: class {
        constructor(scheme, authority, path, query, fragment) {
            this.scheme = scheme;
            this.authority = authority;
            this.path = path;
            this.query = query;
            this.fragment = fragment;
        }
        static file(path) { return new vscode.Uri('file', '', path); }
        static parse(value) { return new vscode.Uri('file', '', value); }
        toString() { return `${this.scheme}://${this.path}`; }
        with(change) { return this; }
        toJSON() { return { scheme: this.scheme, path: this.path }; }
    },

    // Position
    Position: class {
        constructor(line, character) { this.line = line; this.character = character; }
        isAfter(other) { return this.line > other.line || (this.line === other.line && this.character > other.character); }
        isBefore(other) { return this.line < other.line || (this.line === other.line && this.character < other.character); }
        translate(lineDelta, charDelta) { return new vscode.Position(this.line + (lineDelta || 0), this.character + (charDelta || 0)); }
        with(line, character) { return new vscode.Position(line ?? this.line, character ?? this.character); }
    },

    // Range
    Range: class {
        constructor(startLine, startChar, endLine, endChar) {
            if (startLine instanceof vscode.Position) {
                this.start = startLine;
                this.end = startChar;
            } else {
                this.start = new vscode.Position(startLine, startChar);
                this.end = new vscode.Position(endLine, endChar);
            }
        }
        get isEmpty() { return this.start.isEqual(this.end); }
        get isSingleLine() { return this.start.line === this.end.line; }
        contains(positionOrRange) {
            if (positionOrRange instanceof vscode.Position) {
                return !positionOrRange.isBefore(this.start) && !positionOrRange.isAfter(this.end);
            }
            return this.contains(positionOrRange.start) && this.contains(positionOrRange.end);
        }
        intersection(range) {
            const start = this.start.isAfter(range.start) ? this.start : range.start;
            const end = this.end.isBefore(range.end) ? this.end : range.end;
            return start.isBefore(end) ? new vscode.Range(start, end) : undefined;
        }
        union(range) {
            return new vscode.Range(
                this.start.isBefore(range.start) ? this.start : range.start,
                this.end.isAfter(range.end) ? this.end : range.end
            );
        }
        with(start, end) { return new vscode.Range(start ?? this.start, end ?? this.end); }
    },

    // Selection
    Selection: class extends vscode.Range {
        constructor(anchorLine, anchorChar, activeLine, activeChar) {
            super(anchorLine, anchorChar, activeLine ?? anchorLine, activeChar ?? anchorChar);
            if (anchorLine instanceof vscode.Position) {
                this.anchor = anchorLine;
                this.active = anchorChar;
            } else {
                this.anchor = new vscode.Position(anchorLine, anchorChar);
                this.active = new vscode.Position(activeLine, activeChar);
            }
        }
        get isReversed() { return this.anchor === this.end; }
    },

    // TextEdit
    TextEdit: class {
        constructor(range, newText) { this.range = range; this.newText = newText; }
        static insert(position, newText) { return new vscode.TextEdit(new vscode.Range(position, position), newText); }
        static delete(range) { return new vscode.TextEdit(range, ''); }
        static replace(range, newText) { return new vscode.TextEdit(range, newText); }
    },

    // WorkspaceEdit
    WorkspaceEdit: class {
        constructor() { this._edits = new Map(); this._fileOps = []; }
        set(uri, edits) { this._edits.set(uri.toString(), edits); }
        get(uri) { return this._edits.get(uri.toString()) || []; }
        has(uri) { return this._edits.has(uri.toString()); }
        delete(uri, edits) { this._edits.set(uri.toString(), edits); }
        createFile(uri, options) { this._fileOps.push({ type: 'create', uri, options }); }
        deleteFile(uri, options) { this._fileOps.push({ type: 'delete', uri, options }); }
        renameFile(oldUri, newUri, options) { this._fileOps.push({ type: 'rename', oldUri, newUri, options }); }
        entries() { return this._edits.entries(); }
        get size() { return this._edits.size; }
    },

    // SnippetString
    SnippetString: class {
        constructor(value) { this.value = value || ''; }
        appendText(string) { this.value += string; return this; }
        appendTabstop(number) { this.value += `$${number}`; return this; }
        appendPlaceholder(value, number) { this.value += `\${${number}:${value}}`; return this; }
        appendVariable(name, defaultValue) { this.value += `\${${name}${defaultValue ? ':' + defaultValue : ''}}`; return this; }
    },

    // ThemeColor
    ThemeColor: class {
        constructor(id) { this.id = id; }
    },

    // ThemeIcon
    ThemeIcon: class {
        constructor(id, color) { this.id = id; this.color = color; }
        static File = new vscode.ThemeIcon('file');
        static Folder = new vscode.ThemeIcon('folder');
    },

    // MarkdownString
    MarkdownString: class {
        constructor(value, supportThemeIcons) {
            this.value = value || '';
            this.isTrusted = false;
            this.supportThemeIcons = supportThemeIcons || false;
            this.baseUri = undefined;
        }
        appendText(value) { this.value += value; return this; }
        appendMarkdown(value) { this.value += value; return this; }
        appendCodeblock(value, language) { this.value += `\n\`\`\`${language || ''}\n${value}\n\`\`\``; return this; }
    },

    // Diagnostic
    Diagnostic: class {
        constructor(range, message, severity) {
            this.range = range;
            this.message = message;
            this.severity = severity || vscode.DiagnosticSeverity.Error;
            this.code = undefined;
            this.source = undefined;
        }
    },

    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    DiagnosticTag: { Unnecessary: 1, Deprecated: 2 },

    // SymbolKind
    SymbolKind: {
        File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5,
        Property: 6, Field: 7, Constructor: 8, Enum: 9, Interface: 10,
        Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15,
        Boolean: 16, Array: 17, Object: 18, Key: 19, Null: 20,
        EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25
    },

    // CompletionItemKind
    CompletionItemKind: {
        Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4,
        Variable: 5, Class: 6, Interface: 7, Module: 8, Property: 9,
        Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14,
        Color: 15, File: 16, Reference: 17, Folder: 18, EnumMember: 19,
        Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24
    },

    // ViewColumn
    ViewColumn: { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3 },

    // StatusBarAlignment
    StatusBarAlignment: { Left: 1, Right: 2 },

    // ConfigurationTarget
    ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },

    // ProgressLocation
    ProgressLocation: { SourceControl: 1, Window: 10, Notification: 15 },

    // TextEditorCursorStyle
    TextEditorCursorStyle: { Line: 1, Block: 2, Underline: 3 },

    // TextEditorLineNumbersStyle
    TextEditorLineNumbersStyle: { Off: 0, On: 1, Relative: 2 },

    // EndOfLine
    EndOfLine: { LF: 1, CRLF: 2 },

    // OverviewRulerLane
    OverviewRulerLane: { Left: 1, Center: 2, Right: 4, Full: 7 },

    // QuickPickItemKind
    QuickPickItemKind: { Default: 0, Separator: -1 },

    // window namespace
    window: {
        get activeTextEditor() {
            return undefined; // Will be set by extension host
        },
        get visibleTextEditors() { return []; },
        createOutputChannel(name) {
            return {
                name,
                append(value) { bridge.notify('vscode/output/append', { name, value }); },
                appendLine(value) { this.append((value || '') + '\n'); },
                clear() { bridge.notify('vscode/output/clear', { name }); },
                show() { bridge.notify('vscode/output/show', { name }); },
                hide() {},
                dispose() {},
            };
        },
        showInformationMessage(message, ...items) {
            return bridge.request('vscode/window/showMessage', { type: 'info', message, items });
        },
        showWarningMessage(message, ...items) {
            return bridge.request('vscode/window/showMessage', { type: 'warning', message, items });
        },
        showErrorMessage(message, ...items) {
            return bridge.request('vscode/window/showMessage', { type: 'error', message, items });
        },
        showQuickPick(items, options) {
            return bridge.request('vscode/window/showQuickPick', { items, options });
        },
        showInputBox(options) {
            return bridge.request('vscode/window/showInputBox', options || {});
        },
        showOpenDialog(options) {
            return bridge.request('vscode/window/showOpenDialog', options || {});
        },
        showSaveDialog(options) {
            return bridge.request('vscode/window/showSaveDialog', options || {});
        },
        createStatusBarItem(alignment, priority) {
            return {
                alignment, priority,
                text: '', tooltip: '', command: undefined,
                show() { bridge.notify('vscode/statusbar/show', {}); },
                hide() { bridge.notify('vscode/statusbar/hide', {}); },
                dispose() {},
            };
        },
        setStatusBarMessage(text) {
            bridge.notify('vscode/statusbar/message', { text });
        },
        createTerminal(options) {
            return {
                name: options?.name || 'Terminal',
                show() {},
                hide() {},
                sendText(text) { bridge.notify('vscode/terminal/send', { text }); },
                dispose() {},
            };
        },
        onDidChangeActiveTextEditor: new EventEmitter(),
        onDidChangeTextEditorSelection: new EventEmitter(),
        onDidChangeTextEditorVisibleRanges: new EventEmitter(),
        onDidCloseTerminal: new EventEmitter(),
    },

    // workspace namespace
    workspace: {
        get workspaceFolders() { return undefined; },
        get textDocuments() { return []; },
        openTextDocument(uri) { return bridge.request('vscode/workspace/openTextDocument', { uri: uri.toString() }); },
        getConfiguration(section) {
            return {
                get(key, defaultValue) { return defaultValue; },
                update(key, value, target) { return Promise.resolve(); },
                has(key) { return false; },
                inspect(key) { return undefined; },
            };
        },
        applyEdit(edit) { return bridge.request('vscode/workspace/applyEdit', { edit }); },
        findFiles(include, exclude, maxResults) { return bridge.request('vscode/workspace/findFiles', { include, exclude, maxResults }); },
        saveAll() { return bridge.request('vscode/workspace/saveAll', {}); },
        get fs() {
            return {
                readFile(uri) { return bridge.request('vscode/workspace/fs/readFile', { uri: uri.toString() }); },
                writeFile(uri, content) { return bridge.request('vscode/workspace/fs/writeFile', { uri: uri.toString(), content }); },
                delete(uri) { return bridge.request('vscode/workspace/fs/delete', { uri: uri.toString() }); },
                createDirectory(uri) { return bridge.request('vscode/workspace/fs/createDirectory', { uri: uri.toString() }); },
                readDirectory(uri) { return bridge.request('vscode/workspace/fs/readDirectory', { uri: uri.toString() }); },
                rename(source, target) { return bridge.request('vscode/workspace/fs/rename', { source: source.toString(), target: target.toString() }); },
                copy(source, target) { return bridge.request('vscode/workspace/fs/copy', { source: source.toString(), target: target.toString() }); },
                stat(uri) { return bridge.request('vscode/workspace/fs/stat', { uri: uri.toString() }); },
            };
        },
        onDidChangeTextDocument: new EventEmitter(),
        onDidSaveTextDocument: new EventEmitter(),
        onDidOpenTextDocument: new EventEmitter(),
        onDidCloseTextDocument: new EventEmitter(),
        onDidChangeConfiguration: new EventEmitter(),
        onWillSaveTextDocument: new EventEmitter(),
    },

    // languages namespace
    languages: {
        createDiagnosticCollection(name) {
            return {
                name,
                set(uri, diagnostics) { bridge.notify('vscode/diagnostics/set', { uri: uri.toString(), diagnostics, name }); },
                delete(uri) { bridge.notify('vscode/diagnostics/delete', { uri: uri.toString(), name }); },
                clear() { bridge.notify('vscode/diagnostics/clear', { name }); },
                dispose() {},
            };
        },
        registerCompletionItemProvider(selector, provider, ...triggerCharacters) {
            return { dispose() {} };
        },
        registerHoverProvider(selector, provider) { return { dispose() {} }; },
        registerDefinitionProvider(selector, provider) { return { dispose() {} }; },
        registerReferenceProvider(selector, provider) { return { dispose() {} }; },
        registerDocumentSymbolProvider(selector, provider) { return { dispose() {} }; },
        registerCodeActionsProvider(selector, provider) { return { dispose() {} }; },
        registerCodeLensProvider(selector, provider) { return { dispose() {} }; },
        registerDocumentFormattingEditProvider(selector, provider) { return { dispose() {} }; },
        registerSignatureHelpProvider(selector, provider, ...triggerCharacters) { return { dispose() {} }; },
        registerRenameProvider(selector, provider) { return { dispose() {} }; },
        setLanguageConfiguration(language, configuration) {},
        getLanguages() { return Promise.resolve([]); },
        match(selector, document) { return 0; },
    },

    // commands namespace
    commands: {
        registerCommand(command, callback, thisArg) {
            return { dispose() {} };
        },
        executeCommand(command, ...args) {
            return bridge.request('vscode/commands/execute', { command, args });
        },
        getCommands() { return bridge.request('vscode/commands/list', {}); },
    },

    // extensions namespace
    extensions: {
        getExtension(extensionId) {
            return undefined;
        },
        get all() { return []; },
        get onDidChange() { return new EventEmitter(); },
    },

    // env namespace
    env: {
        get appName() { return 'WIZP'; },
        get appRoot() { return process.cwd(); },
        get language() { return 'en'; },
        get machineId() { return 'wizp'; },
        get sessionId() { return 'wizp-session'; },
        get shell() { return process.env.SHELL || '/bin/sh'; },
        get uriScheme() { return 'file'; },
        get clipboard() {
            return {
                readText() { return bridge.request('vscode/clipboard/read', {}); },
                writeText(value) { return bridge.request('vscode/clipboard/write', { value }); },
            };
        },
        openExternal(target) { return bridge.request('vscode/env/openExternal', { target: target.toString() }); },
    },

    // Disposable
    Disposable: class {
        constructor(callOnDispose) { this._callOnDispose = callOnDispose; }
        static from(...disposables) { return { dispose() { disposables.forEach(d => d.dispose()); } }; }
        dispose() { if (this._callOnDispose) this._callOnDispose(); }
    },

    // EventEmitter
    EventEmitter: EventEmitter,

    // CancellationTokenSource
    CancellationTokenSource: class {
        constructor() {
            this.token = { isCancellationRequested: false, onCancellationRequested: new EventEmitter() };
        }
        cancel() { this.token.isCancellationRequested = true; this.token.onCancellationRequested.emit('cancelled'); }
        dispose() {}
    },

    // ExtensionContext (passed to activate)
    ExtensionContext: class {
        constructor() {
            this.subscriptions = [];
            this.extensionPath = process.cwd();
            this.extensionUri = vscode.Uri.file(process.cwd());
            this.globalState = {
                get(key) { return Promise.resolve(undefined); },
                update(key, value) { return Promise.resolve(); },
                keys() { return []; },
            };
            this.workspaceState = {
                get(key) { return Promise.resolve(undefined); },
                update(key, value) { return Promise.resolve(); },
                keys() { return []; },
            };
            this.storagePath = undefined;
            this.globalStoragePath = undefined;
            this.logPath = undefined;
            this.extensionMode = 1;
        }
    },
};

// Make vscode available globally (extensions expect it)
global.vscode = vscode;
module.exports = vscode;
