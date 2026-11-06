const vscode = require('vscode');

async function flushTicks(count = 1) {
  for (let index = 0; index < count; index += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

async function activate(context) {
  const command = vscode.commands.registerCommand('basic-api-smoke.run', async () => {
    const result = {
      commandRegistered: true,
      messageShown: false,
      fileRead: false,
      fileWritten: false,
    };

    try {
      await vscode.window.showInformationMessage('basic-api-smoke');
      result.messageShown = true;
      const messageChoice = await vscode.window.showInformationMessage('basic-api-smoke-choice', 'Run');
      result.messageItem = messageChoice === 'Run';
      const quickPick = await vscode.window.showQuickPick([{ label: 'First' }, { label: 'Second' }], { placeHolder: 'Pick one' });
      result.quickPick = quickPick && quickPick.label === 'First';
      const input = await vscode.window.showInputBox({ value: 'typed', prompt: 'Type something' });
      result.inputBox = input === 'typed';
      const progressResult = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Smoke Progress' }, async (progress) => {
        progress.report({ message: 'halfway', increment: 50 });
        return 'progress-ok';
      });
      result.progress = progressResult === 'progress-ok';
      const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
      status.text = 'Smoke';
      status.tooltip = 'Smoke status';
      status.show();
      status.hide();
      status.dispose();
      result.statusBar = true;
      const output = vscode.window.createOutputChannel('Basic API Smoke');
      output.append('one');
      output.appendLine('two');
      output.replace('three');
      output.clear();
      output.show(true);
      output.hide();
      output.dispose();
      const log = vscode.window.createOutputChannel('Basic API Smoke Log', { log: true });
      log.trace('trace');
      log.debug('debug');
      log.info('info');
      log.warn('warn');
      log.error('error');
      log.dispose();
      result.outputChannel = output.name === 'Basic API Smoke' && log.name === 'Basic API Smoke Log';
    } catch (_) {}

    try {
      result.workspaceTrust = vscode.workspace.isTrusted === true;
      let trustEvent = false;
      const trustDisposable = vscode.workspace.onDidGrantWorkspaceTrust(() => {
        trustEvent = true;
      });
      await new Promise((resolve) => setTimeout(resolve, 0));
      trustDisposable.dispose();
      result.workspaceTrustEvent = trustEvent;
    } catch (_) {}

    try {
      if (vscode.workspace.fs && vscode.Uri) {
        const input = vscode.Uri.file('basic-api-smoke-input.txt');
        const output = vscode.Uri.file('basic-api-smoke-output.txt');
        const bytes = await vscode.workspace.fs.readFile(input);
        result.fileRead = bytes && bytes.length >= 0;
        await vscode.workspace.fs.writeFile(output, bytes);
        result.fileWritten = true;

        const dir = vscode.Uri.file('basic-api-smoke-fs');
        const created = vscode.Uri.file('basic-api-smoke-fs/created.txt');
        const copied = vscode.Uri.file('basic-api-smoke-fs/copied.txt');
        const renamed = vscode.Uri.file('basic-api-smoke-fs/renamed.txt');
        await vscode.workspace.fs.createDirectory(dir);
        await vscode.workspace.fs.writeFile(created, new TextEncoder().encode('fs-data'));
        const stat = await vscode.workspace.fs.stat(created);
        const entries = await vscode.workspace.fs.readDirectory(dir);
        await vscode.workspace.fs.copy(created, copied, { overwrite: true });
        await vscode.workspace.fs.rename(copied, renamed, { overwrite: true });
        await vscode.workspace.fs.delete(created, { recursive: false, useTrash: false });
        result.fsStat = stat && stat.size === 7;
        result.fsReadDirectory = entries.some(([name]) => name === 'created.txt');
        result.fsCopyRename = (await vscode.workspace.fs.readFile(renamed)).length === 7;
        await vscode.workspace.fs.delete(dir, { recursive: true, useTrash: false });
        result.fsDelete = true;
      }
    } catch (error) {
      result.error = String(error && error.message ? error.message : error);
    }

    return result;
  });

  context.subscriptions.push(command);

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.enabledOnly', async () => {
    return { enabledOnly: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.menuCommand', async (source) => {
    return { menuCommand: true, source };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.keybindingCommand', async () => {
    return { keybindingCommand: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.diagnostics', async () => {
    const temp = vscode.languages.createDiagnosticCollection('basic-api-smoke-temp');
    const first = vscode.Uri.file('diag-a.txt');
    const second = vscode.Uri.file('diag-b.txt');
    const makeDiag = (line, severity, message) => ({
      range: new vscode.Range(new vscode.Position(line, 0), new vscode.Position(line, 5)),
      severity,
      message,
      source: 'basic-api-smoke'
    });

    temp.set(first, [makeDiag(0, vscode.DiagnosticSeverity.Error, 'first problem')]);
    temp.set([[second, [makeDiag(1, vscode.DiagnosticSeverity.Warning, 'second problem')]]]);
    temp.delete(first);
    let forEachCount = 0;
    temp.forEach(() => { forEachCount += 1; });
    temp.clear();
    temp.dispose();

    const collection = vscode.languages.createDiagnosticCollection('basic-api-smoke');
    collection.set(second, [makeDiag(2, vscode.DiagnosticSeverity.Warning, 'final problem')]);
    return { diagnostics: true, forEachCount };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.fsProvider', async () => {
    const files = new Map();
    const dirs = new Set(['/']);
    const key = (uri) => uri.path || '/';
    const parent = (path) => path.slice(0, Math.max(1, path.lastIndexOf('/'))) || '/';
    const nameOf = (path) => path.split('/').filter(Boolean).pop() || '';
    const provider = {
      stat(uri) {
        const path = key(uri);
        if (dirs.has(path)) return { type: vscode.FileType.Directory, ctime: 1, mtime: 1, size: 0 };
        const data = files.get(path);
        if (!data) throw new Error('not found');
        return { type: vscode.FileType.File, ctime: 1, mtime: 2, size: data.length };
      },
      readDirectory(uri) {
        const path = key(uri);
        const prefix = path.endsWith('/') ? path : path + '/';
        const entries = [];
        for (const dir of dirs) {
          if (dir !== path && parent(dir) === path) entries.push([nameOf(dir), vscode.FileType.Directory]);
        }
        for (const file of files.keys()) {
          if (parent(file) === path) entries.push([nameOf(file), vscode.FileType.File]);
        }
        return entries;
      },
      createDirectory(uri) {
        const path = key(uri);
        dirs.add(path);
      },
      readFile(uri) {
        const data = files.get(key(uri));
        if (!data) throw new Error('not found');
        return data;
      },
      writeFile(uri, content) {
        const path = key(uri);
        dirs.add(parent(path));
        files.set(path, content instanceof Uint8Array ? content : new Uint8Array(content));
      },
      delete(uri) {
        const path = key(uri);
        files.delete(path);
        dirs.delete(path);
      },
      rename(oldUri, newUri) {
        const oldPath = key(oldUri);
        const newPath = key(newUri);
        const data = files.get(oldPath);
        if (!data) throw new Error('not found');
        files.delete(oldPath);
        files.set(newPath, data);
      },
      copy(source, destination) {
        const data = files.get(key(source));
        if (!data) throw new Error('not found');
        files.set(key(destination), new Uint8Array(data));
      }
    };
    const registration = vscode.workspace.registerFileSystemProvider('memfs', provider, { isCaseSensitive: true });
    const dir = vscode.Uri.parse('memfs:/folder');
    const file = vscode.Uri.parse('memfs:/folder/file.txt');
    const renamed = vscode.Uri.parse('memfs:/folder/renamed.txt');
    const copied = vscode.Uri.parse('memfs:/folder/copied.txt');
    await vscode.workspace.fs.createDirectory(dir);
    await vscode.workspace.fs.writeFile(file, new TextEncoder().encode('mem-data'));
    const stat = await vscode.workspace.fs.stat(file);
    const entries = await vscode.workspace.fs.readDirectory(dir);
    await vscode.workspace.fs.rename(file, renamed, { overwrite: true });
    await vscode.workspace.fs.copy(renamed, copied, { overwrite: true });
    const copiedBytes = await vscode.workspace.fs.readFile(copied);
    await vscode.workspace.fs.delete(renamed, {});
    registration.dispose();
    return {
      fsProvider: true,
      statSize: stat.size,
      listed: entries.some(([name, type]) => name === 'file.txt' && type === vscode.FileType.File),
      copied: new TextDecoder().decode(copiedBytes) === 'mem-data'
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.workspaceEdit', async () => {
    const first = vscode.Uri.file('workspace-edit-one.txt');
    const second = vscode.Uri.file('workspace-edit-two.txt');
    const renamed = vscode.Uri.file('workspace-edit-renamed.txt');
    await vscode.workspace.fs.writeFile(first, new TextEncoder().encode('one fish\n'));
    await vscode.workspace.fs.writeFile(second, new TextEncoder().encode('two fish\n'));

    const edit = new vscode.WorkspaceEdit();
    edit.replace(first, new vscode.Range(new vscode.Position(0, 0), new vscode.Position(0, 3)), 'red');
    edit.insert(second, new vscode.Position(0, 0), 'blue ');
    edit.createFile(renamed, { overwrite: true });
    edit.replace(renamed, new vscode.Range(new vscode.Position(0, 0), new vscode.Position(0, 0)), 'created\n');
    const applied = await vscode.workspace.applyEdit(edit);

    const firstText = new TextDecoder().decode(await vscode.workspace.fs.readFile(first));
    const secondText = new TextDecoder().decode(await vscode.workspace.fs.readFile(second));
    const renamedText = new TextDecoder().decode(await vscode.workspace.fs.readFile(renamed));
    await vscode.workspace.fs.delete(first, {});
    await vscode.workspace.fs.delete(second, {});
    await vscode.workspace.fs.delete(renamed, {});
    return {
      workspaceEdit: applied === true,
      firstText,
      secondText,
      renamedText
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.saveParticipant', async () => {
    const uri = vscode.Uri.file('save-participant.txt');
    let willSaveSeen = false;
    let didSaveSeen = false;
    const will = vscode.workspace.onWillSaveTextDocument((event) => {
      willSaveSeen = event.document.uri.toString() === uri.toString();
      event.waitUntil(Promise.resolve([
        vscode.TextEdit.insert(new vscode.Position(0, 0), 'participant\n')
      ]));
    });
    const did = vscode.workspace.onDidSaveTextDocument((document) => {
      didSaveSeen = document.uri.toString() === uri.toString();
    });

    const document = {
      uri,
      fileName: uri.fsPath,
      languageId: 'plaintext',
      version: 1,
      getText: () => 'body\n'
    };
    const finalText = await vscode.workspace._fireWillSaveTextDocument(document, 1);
    await vscode.workspace.fs.writeFile(uri, new TextEncoder().encode(finalText));
    if (globalThis._wizp_onDidSaveTextDocument) globalThis._wizp_onDidSaveTextDocument(document);
    const diskText = new TextDecoder().decode(await vscode.workspace.fs.readFile(uri));
    await vscode.workspace.fs.delete(uri, {});
    will.dispose();
    did.dispose();
    return {
      saveParticipant: true,
      willSaveSeen,
      didSaveSeen,
      diskText
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.textDocumentEditorEvents', async () => {
    const uri = vscode.Uri.file('text-document-editor-events.txt');
    await vscode.workspace.fs.writeFile(uri, new TextEncoder().encode('alpha\nbeta\n'));
    const events = [];
    const disposables = [
      vscode.workspace.onDidOpenTextDocument((document) => events.push(`open:${document.uri.toString()}`)),
      vscode.workspace.onDidChangeTextDocument((event) => events.push(`change:${event.document.version}:${event.contentChanges[0] && event.contentChanges[0].text}`)),
      vscode.workspace.onDidSaveTextDocument((document) => events.push(`save:${document.uri.toString()}`)),
      vscode.workspace.onDidCloseTextDocument((document) => events.push(`close:${document.uri.toString()}`))
    ];

    const document = await vscode.workspace.openTextDocument(uri);
    const selection = new vscode.Selection(new vscode.Position(1, 0), new vscode.Position(1, 4));
    const editor = await vscode.window.showTextDocument(document, { viewColumn: vscode.ViewColumn.Two, selection });
    await editor.edit((edit) => {
      edit.insert(new vscode.Position(0, 0), 'start\n');
    });
    const revealRange = new vscode.Range(new vscode.Position(1, 0), new vscode.Position(1, 5));
    editor.revealRange(revealRange, vscode.TextEditorRevealType.InCenter);
    const saved = await document.save();
    vscode.workspace._closeTextDocument(document);
    disposables.forEach((disposable) => disposable.dispose());
    await vscode.workspace.fs.delete(uri, {});

    return {
      textDocumentEditorEvents: true,
      events,
      saved,
      activeMatches: vscode.window.activeTextEditor === editor,
      visibleCount: vscode.window.visibleTextEditors.length,
      viewColumn: editor.viewColumn,
      selectionStartLine: editor.selection.start.line,
      selectionEndCharacter: editor.selection.end.character,
      visibleRangeStartLine: editor.visibleRanges[0] && editor.visibleRanges[0].start.line,
      finalText: document.getText(),
      version: document.version,
      dirtyAfterSave: document.isDirty,
      isClosed: document.isClosed
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.terminalApi', async () => {
    const events = [];
    const disposables = [
      vscode.window.onDidOpenTerminal((terminal) => events.push(`open:${terminal.name}`)),
      vscode.window.onDidChangeActiveTerminal((terminal) => events.push(`active:${terminal ? terminal.name : 'none'}`)),
      vscode.window.onDidCloseTerminal((terminal) => events.push(`close:${terminal.name}`))
    ];
    const terminal = vscode.window.createTerminal({ name: 'Smoke Terminal', cwd: '.', env: { WIZP_SMOKE: '1' } });
    const processId = await terminal.processId;
    terminal.sendText('printf terminal-api', false);
    terminal.sendText(' && printf smoke');
    terminal.show(true);
    terminal.hide();
    const activeBeforeDispose = vscode.window.activeTerminal === terminal;
    const listedBeforeDispose = vscode.window.terminals.some((item) => item === terminal);
    terminal.dispose();
    disposables.forEach((disposable) => disposable.dispose());
    return {
      terminalApi: true,
      processId,
      name: terminal.name,
      sentText: terminal._sentText,
      shown: terminal._shown,
      interacted: terminal.state.isInteractedWith,
      activeBeforeDispose,
      listedBeforeDispose,
      listedAfterDispose: vscode.window.terminals.some((item) => item === terminal),
      exitStatusCode: terminal.exitStatus && terminal.exitStatus.code,
      exitStatusReason: terminal.exitStatus && terminal.exitStatus.reason,
      events
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.terminalShellIntegration', async () => {
    const terminalEvents = {
      data: [],
      start: [],
      end: [],
      integration: []
    };
    let terminal = null;
    const disposables = [
      vscode.window.onDidWriteTerminalData((event) => {
        if (event.terminal === terminal) terminalEvents.data.push(event.data);
      }),
      vscode.window.onDidStartTerminalShellExecution((event) => {
        if (event.terminal !== terminal) return;
        terminalEvents.start.push({
          commandLine: event.execution.commandLine,
          args: Array.isArray(event.execution.args) ? event.execution.args.slice() : []
        });
      }),
      vscode.window.onDidEndTerminalShellExecution((event) => {
        if (event.terminal !== terminal) return;
        terminalEvents.end.push({
          commandLine: event.execution.commandLine,
          args: Array.isArray(event.execution.args) ? event.execution.args.slice() : [],
          exitCode: event.exitCode
        });
      }),
      vscode.window.onDidChangeTerminalShellIntegration((event) => {
        if (event.terminal !== terminal) return;
        const envValue = event.shellIntegration && event.shellIntegration.env && event.shellIntegration.env.value
          ? event.shellIntegration.env.value
          : {};
        terminalEvents.integration.push({
          envKeys: Object.keys(envValue).sort(),
          envValue: Object.assign({}, envValue)
        });
      })
    ];
    terminal = vscode.window.createTerminal({ name: 'Shell Integration Terminal', cwd: '.', env: { WIZP_SMOKE: '1' } });
    terminal.show(true);
    await flushTicks(2);
    const initialReady = terminalEvents.integration.length >= 1;
    const execution = terminal.shellIntegration.executeCommand('source', ['venv/bin/activate']);
    await flushTicks(3);
    terminal.sendText('conda activate smoke-env');
    await flushTicks(1);
    const envValue = terminal.shellIntegration && terminal.shellIntegration.env && terminal.shellIntegration.env.value
      ? terminal.shellIntegration.env.value
      : {};
    const sentText = terminal._sentText.slice();
    terminal.dispose();
    disposables.forEach((disposable) => disposable.dispose());
    return {
      terminalShellIntegration: true,
      shellIntegrationPresent: !!terminal.shellIntegration,
      initialReady,
      executionCommandLine: execution.commandLine,
      executionArgs: execution.args,
      sentText,
      dataEvents: terminalEvents.data.slice(),
      startEvents: terminalEvents.start.slice(),
      endEvents: terminalEvents.end.slice(),
      integrationEvents: terminalEvents.integration.slice(),
      envKeys: Object.keys(envValue).sort(),
      virtualEnv: envValue.VIRTUAL_ENV || null,
      condaPrefix: envValue.CONDA_PREFIX || null
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.commentsLifecycle', async () => {
    const initialUiEventCount = Array.isArray(globalThis._wizp_uiQueue) ? globalThis._wizp_uiQueue.length : 0;
    const commentController = vscode.comments.createCommentController('smoke-comments-lifecycle', 'Smoke Comments Lifecycle');
    const threadUri = vscode.Uri.file('/workspace/comments-smoke.txt');
    const threadRange = new vscode.Range(new vscode.Position(3, 2), new vscode.Position(3, 8));
    const threadComments = [{ body: 'hello', mode: 1, author: { name: 'Smoke' } }];
    const commentThread = commentController.createCommentThread(threadUri, threadRange, threadComments);
    await flushTicks(1);
    const uiEvents = (globalThis._wizp_uiQueue || [])
      .slice(initialUiEventCount)
      .filter((event) => event && event.type === 'commentThreadCreated');
    const createdEvent = uiEvents[uiEvents.length - 1] || null;
    const threadDispose = typeof commentThread.dispose === 'function';
    const controllerDispose = typeof commentController.dispose === 'function';
    commentThread.dispose();
    commentController.dispose();
    return {
      commentsLifecycle: true,
      controllerId: commentController.id,
      controllerLabel: commentController.label,
      threadUri: commentThread.uri.toString(),
      threadStartLine: commentThread.range.start.line,
      threadStartCharacter: commentThread.range.start.character,
      threadCommentCount: commentThread.comments.length,
      threadDispose,
      controllerDispose,
      uiEventCount: uiEvents.length,
      uiEventUri: createdEvent && createdEvent.uri,
      uiEventLine: createdEvent && createdEvent.line
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.apiPrimitives', async () => {
    let disposableCount = 0;
    const firstDisposable = new vscode.Disposable(() => { disposableCount += 1; });
    const secondDisposable = new vscode.Disposable(() => { disposableCount += 10; });
    vscode.Disposable.from(firstDisposable, secondDisposable).dispose();

    const emitter = new vscode.EventEmitter();
    const fired = [];
    const eventDisposable = emitter.event((value) => fired.push(value));
    emitter.fire('one');
    eventDisposable.dispose();
    emitter.fire('two');

    const cancellation = new vscode.CancellationTokenSource();
    let cancelled = false;
    const cancelDisposable = cancellation.token.onCancellationRequested(() => { cancelled = true; });
    cancellation.cancel();
    cancelDisposable.dispose();
    cancellation.dispose();

    const parsed = vscode.Uri.parse('wizp://authority/root/file.txt?query=1#frag');
    const joined = vscode.Uri.joinPath(vscode.Uri.file('/tmp/work'), 'src', '..', 'file.txt');
    const joinedHttps = vscode.Uri.joinPath(vscode.Uri.parse('https://example.test'), 'api', 'v1');
    const changed = parsed.with({ scheme: 'smoke', path: '/changed', query: 'q=2', fragment: 'done' });
    const json = changed.toJSON();

    const p1 = new vscode.Position(1, 2);
    const p2 = p1.translate(2, 3);
    const p3 = p2.with({ character: 9 });
    const range = new vscode.Range(p1, p3);
    const inner = new vscode.Range(new vscode.Position(2, 0), new vscode.Position(2, 2));
    const selection = new vscode.Selection(p3, p1);

    const markdown = new vscode.MarkdownString('hello', true)
      .appendMarkdown(' **world**')
      .appendText(' [safe]')
      .appendCodeblock('const x = 1;', 'js');
    const icon = new vscode.ThemeIcon('zap', { id: 'terminal.ansiGreen' });
    const fileIcon = vscode.ThemeIcon.File;
    const relative = new vscode.RelativePattern(vscode.Uri.file('/workspace'), '**/*.zig');
    const smokeConfig = vscode.workspace.getConfiguration('basicApiSmoke');
    const smokeCurrentLine = smokeConfig.get('currentLine');
    const smokeCurrentLineConfig = vscode.workspace.getConfiguration('basicApiSmoke.currentLine');
    const smokeFormatInspect = smokeConfig.inspect('currentLine.format');

    return {
      apiPrimitives: true,
      disposableCount,
      fired,
      cancelled,
      tokenCancelled: cancellation.token.isCancellationRequested,
      parsedScheme: parsed.scheme,
      parsedAuthority: parsed.authority,
      parsedPath: parsed.path,
      parsedQuery: parsed.query,
      parsedFragment: parsed.fragment,
      joined: joined.toString(),
      joinedHttps: joinedHttps.toString(),
      changed: changed.toString(),
      jsonPath: json.path,
      jsonExternal: json.external,
      positionCompare: p1.compareTo(p2),
      positionWithCharacter: p3.character,
      rangeContains: range.contains(inner),
      rangeIntersectionLine: range.intersection(inner).start.line,
      rangeUnionEndCharacter: range.union(new vscode.Range(new vscode.Position(5, 0), new vscode.Position(5, 1))).end.character,
      selectionReversed: selection.isReversed,
      selectionStartLine: selection.start.line,
      markdownValue: markdown.value,
      markdownThemeIcons: markdown.supportThemeIcons,
      iconId: icon.id,
      iconColorId: icon.color.id,
      fileIconId: fileIcon.id,
      relativeBase: relative.base,
      relativePattern: relative.pattern,
      smokeCurrentLineFormat: smokeCurrentLine && smokeCurrentLine.format,
      smokeCurrentLineHasDefault: smokeConfig.has('currentLine'),
      smokeCurrentLineDirectFormat: smokeCurrentLineConfig.get('format'),
      smokeCurrentLineInspectDefault: smokeFormatInspect && smokeFormatInspect.defaultValue
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.extensionContext', async () => {
    const previousGlobal = context.globalState.get('runs', 0);
    await context.globalState.update('runs', previousGlobal + 1);
    await context.workspaceState.update('workspaceValue', { ok: true, run: previousGlobal + 1 });
    context.globalState.setKeysForSync(['runs']);

    const secretEvents = [];
    const secretDisposable = context.secrets.onDidChange((event) => secretEvents.push(event.key));
    await context.secrets.store('token', 'secret-value');
    const secretBeforeDelete = await context.secrets.get('token');
    await context.secrets.delete('token');
    const secretAfterDelete = await context.secrets.get('token');
    secretDisposable.dispose();

    const env = context.environmentVariableCollection;
    env.clear();
    env.replace('WIZP_REPLACE', 'one');
    env.append('WIZP_APPEND', 'two');
    env.prepend('WIZP_PREPEND', 'three');
    const envEntries = [];
    env.forEach((variable, mutator) => envEntries.push(`${variable}:${mutator.type}:${mutator.value}`));
    const scopedSame = env.getScoped({ workspaceFolder: vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0] }) === env;
    env.delete('WIZP_APPEND');

    const builtInGit = vscode.extensions.getExtension('vscode.git');
    const builtInGitApi = builtInGit && builtInGit.exports && builtInGit.exports.getAPI(1);

    return {
      extensionContext: true,
      extensionPathEnds: context.extensionPath.endsWith('basic-api-smoke'),
      extensionUri: context.extensionUri.toString(),
      storageUri: context.storageUri.toString(),
      globalStorageUri: context.globalStorageUri.toString(),
      logUri: context.logUri.toString(),
      absolutePath: context.asAbsolutePath('extension.js'),
      extensionMode: context.extensionMode,
      packageName: context.packageJSON.name,
      packageAiKeyType: typeof context.packageJSON.aiKey,
      extensionId: context.extension.id,
      extensionExportsActive: !!context.extension.exports,
      quickInputInline: vscode.QuickInputButtonLocation.Inline,
      quickInputBack: vscode.QuickInputButtons.Back.tooltip,
      previousGlobal,
      currentGlobal: context.globalState.get('runs'),
      workspaceValue: context.workspaceState.get('workspaceValue'),
      globalKeys: context.globalState.keys(),
      secretBeforeDelete,
      secretAfterDelete: secretAfterDelete || null,
      secretEvents,
      envReplace: env.get('WIZP_REPLACE'),
      envAppendDeleted: env.get('WIZP_APPEND') || null,
      envEntries: envEntries.sort(),
      builtInGitEnv: builtInGitApi && builtInGitApi.git && typeof builtInGitApi.git.env === 'object',
      builtInGitRepositoryEvents: builtInGitApi && typeof builtInGitApi.onDidOpenRepository === 'function' && typeof builtInGitApi.onDidCloseRepository === 'function',
      scopedSame,
      subscriptionsCount: context.subscriptions.length
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.authSecretsPersistence', async () => {
    const before = await context.secrets.get('persistent-token');
    if (!before) {
      await context.secrets.store('persistent-token', 'persistent-secret-value');
    }
    const after = await context.secrets.get('persistent-token');
    const metadata = context.secrets._metadata ? context.secrets._metadata() : {};
    return {
      authSecretsPersistence: true,
      before: before || null,
      after,
      backend: metadata.backend || 'memory',
      osKeyring: metadata.osKeyring === true,
      plaintextOnDisk: metadata.plaintextOnDisk === true,
      file: metadata.file || null
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.decorations', async () => {
    const decoration = vscode.window.createTextEditorDecorationType({
      backgroundColor: '#123456',
      border: '1px solid #abcdef'
    });
    const editor = vscode.window.activeTextEditor;
    const range = new vscode.Range(new vscode.Position(0, 1), new vscode.Position(0, 5));
    editor.setDecorations(decoration, [{ range, hoverMessage: 'decorated' }]);
    const uri = editor.document.uri.toString();
    const typeId = decoration.id || decoration.key;
    const before = ((globalThis._wizpEditorDecorations || {})[uri] || {})[typeId] || [];
    editor.setDecorations(decoration, []);
    const after = ((globalThis._wizpEditorDecorations || {})[uri] || {})[typeId] || [];
    decoration.dispose();
    return {
      decorations: true,
      typeId,
      beforeCount: before.length,
      afterCount: after.length,
      startLine: before[0] && before[0].start.line,
      startCharacter: before[0] && before[0].start.character,
      endCharacter: before[0] && before[0].end.character,
      hoverMessage: before[0] && before[0].hoverMessage,
      disposed: !!((globalThis._wizpDecorationTypes || {})[typeId] || {}).disposed
    };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.codeLensCommand', async (source) => {
    globalThis._basicApiSmokeCodeLensHits = (globalThis._basicApiSmokeCodeLensHits || 0) + 1;
    return { codeLensCommand: true, source, hits: globalThis._basicApiSmokeCodeLensHits };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.codeLensSetup', async () => {
    const registration = vscode.languages.registerCodeLensProvider({ language: 'plaintext' }, {
      provideCodeLenses() {
        return [
          new vscode.CodeLens(
            new vscode.Range(new vscode.Position(1, 0), new vscode.Position(1, 4)),
            { title: 'Run Lens', command: 'basic-api-smoke.codeLensCommand', arguments: ['from-codelens'] }
          )
        ];
      }
    });
    context.subscriptions.push(registration);
    return { codeLensSetup: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.inlayHintsSetup', async () => {
    const registration = vscode.languages.registerInlayHintsProvider({ language: 'plaintext' }, {
      provideInlayHints() {
        const first = new vscode.InlayHint(
          new vscode.Position(0, 4),
          ': string',
          vscode.InlayHintKind.Type
        );
        first.tooltip = 'resolved by provider';
        first.paddingLeft = true;
        const second = {
          position: new vscode.Position(1, 2),
          label: 'name:',
          kind: vscode.InlayHintKind.Parameter,
          paddingRight: true
        };
        return [first, second];
      },
      resolveInlayHint(hint) {
        if (!hint.tooltip) hint.tooltip = 'resolved tooltip';
        return hint;
      }
    });
    context.subscriptions.push(registration);
    return { inlayHintsSetup: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.semanticTokensSetup', async () => {
    const legend = new vscode.SemanticTokensLegend(
      ['class', 'function'],
      ['declaration', 'static']
    );
    const registration = vscode.languages.registerDocumentSemanticTokensProvider({ language: 'plaintext' }, {
      provideDocumentSemanticTokens() {
        const builder = new vscode.SemanticTokensBuilder(legend);
        builder.push(0, 0, 5, 0, 1);
        builder.push(1, 2, 4, 1, 2);
        return builder.build('semantic-smoke');
      }
    }, legend);
    context.subscriptions.push(registration);
    return { semanticTokensSetup: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.foldingRangesSetup', async () => {
    const registration = vscode.languages.registerFoldingRangeProvider({ language: 'plaintext' }, {
      provideFoldingRanges() {
        return [
          new vscode.FoldingRange(0, 3, vscode.FoldingRangeKind.Region),
          { start: 5, end: 7, kind: vscode.FoldingRangeKind.Comment, startCharacter: 1, endCharacter: 9 }
        ];
      }
    });
    context.subscriptions.push(registration);
    return { foldingRangesSetup: true };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.languageProvidersSetup', async () => {
    const target = vscode.Uri.file('language-provider-target.txt');
    const range = new vscode.Range(new vscode.Position(2, 1), new vscode.Position(2, 7));
    const editRange = new vscode.Range(new vscode.Position(0, 0), new vscode.Position(0, 5));

    const registrations = [
      vscode.languages.registerCompletionItemProvider({ language: 'plaintext' }, {
        provideCompletionItems() {
          return {
            items: [
              {
                label: 'smokeCompletion',
                kind: 3,
                insertText: 'smokeCompletion()',
                detail: 'fixture completion',
                documentation: 'completion docs',
                commitCharacters: ['.']
              }
            ]
          };
        },
        resolveCompletionItem(item) {
          item.detail = `${item.detail} resolved`;
          item.documentation = 'resolved completion docs';
          return item;
        }
      }, '.'),
      vscode.languages.registerCompletionItemProvider({ language: 'plaintext' }, {
        provideCompletionItems() {
          return [
            {
              label: 'smokeSecondCompletion',
              kind: 3,
              insertText: 'smokeSecondCompletion()',
              detail: 'second fixture completion'
            }
          ];
        }
      }, ':'),
      vscode.languages.registerCompletionItemProvider({ scheme: 'file', language: 'plaintext' }, {
        provideCompletionItems(document, position, token) {
          return [
            {
              label: token.isCancellationRequested ? 'smokeSpecificCompletionCancelled' : 'smokeSpecificCompletion',
              kind: 3,
              insertText: 'smokeSpecificCompletion()',
              detail: 'specific fixture completion'
            }
          ];
        }
      }, '.'),
      vscode.languages.registerCompletionItemProvider({ language: 'markdown' }, {
        provideCompletionItems() {
          return [
            {
              label: 'smokeMarkdownOnlyCompletion',
              kind: 3,
              insertText: 'smokeMarkdownOnlyCompletion()'
            }
          ];
        }
      }, '.'),
      vscode.languages.registerHoverProvider({ language: 'plaintext' }, {
        provideHover() {
          return {
            contents: ['**Smoke Hover**', { value: '`hover-docs`' }],
            range
          };
        }
      }),
      vscode.languages.registerSignatureHelpProvider({ language: 'plaintext' }, {
        provideSignatureHelp() {
          return {
            activeSignature: 0,
            activeParameter: 1,
            signatures: [
              {
                label: 'smoke(a, b)',
                documentation: 'signature docs',
                parameters: [
                  { label: 'a', documentation: 'first param' },
                  { label: 'b', documentation: 'second param' }
                ]
              }
            ]
          };
        }
      }, '(', ','),
      vscode.languages.registerDefinitionProvider({ language: 'plaintext' }, {
        provideDefinition() {
          return new vscode.Location(target, range);
        }
      }),
      vscode.languages.registerDeclarationProvider({ language: 'plaintext' }, {
        provideDeclaration() {
          return new vscode.Location(vscode.Uri.file('language-provider-declaration.txt'), new vscode.Range(new vscode.Position(5, 1), new vscode.Position(5, 11)));
        }
      }),
      vscode.languages.registerTypeDefinitionProvider({ language: 'plaintext' }, {
        provideTypeDefinition() {
          return new vscode.Location(vscode.Uri.file('language-provider-type-definition.txt'), new vscode.Range(new vscode.Position(6, 2), new vscode.Position(6, 12)));
        }
      }),
      vscode.languages.registerImplementationProvider({ language: 'plaintext' }, {
        provideImplementation() {
          return [
            new vscode.Location(vscode.Uri.file('language-provider-implementation.txt'), new vscode.Range(new vscode.Position(7, 3), new vscode.Position(7, 13)))
          ];
        }
      }),
      vscode.languages.registerReferenceProvider({ language: 'plaintext' }, {
        provideReferences() {
          return [
            new vscode.Location(target, range),
            new vscode.Location(vscode.Uri.file('language-provider-reference.txt'), new vscode.Range(new vscode.Position(4, 0), new vscode.Position(4, 6)))
          ];
        }
      }),
      vscode.languages.registerRenameProvider({ language: 'plaintext' }, {
        prepareRename() {
          return { range, placeholder: 'oldName' };
        },
        provideRenameEdits(document, position, newName) {
          const edit = new vscode.WorkspaceEdit();
          edit.replace(document.uri, editRange, newName);
          return edit;
        }
      }),
      vscode.languages.registerCodeActionsProvider({ language: 'plaintext' }, {
        provideCodeActions(document) {
          const edit = new vscode.WorkspaceEdit();
          edit.replace(document.uri, editRange, 'fixed');
          return [
            {
              title: 'Smoke Fix',
              kind: 'quickfix',
              isPreferred: true,
              edit,
              command: { title: 'Run Smoke Command', command: 'basic-api-smoke.menuCommand', arguments: ['from-code-action'] }
            }
          ];
        },
        resolveCodeAction(action) {
          action.title = `${action.title} Resolved`;
          action.command = { title: 'Resolved Command', command: 'basic-api-smoke.keybindingCommand', arguments: ['from-resolved-code-action'] };
          return action;
        }
      })
    ];

    registrations.forEach((registration) => context.subscriptions.push(registration));
    return { languageProvidersSetup: true, registrations: registrations.length };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.languageProvidersMoreSetup', async () => {
    const fullRange = new vscode.Range(new vscode.Position(0, 0), new vscode.Position(0, 12));
    const linkRange = new vscode.Range(new vscode.Position(1, 0), new vscode.Position(1, 18));
    const registrations = [
      vscode.languages.registerDocumentHighlightProvider({ language: 'plaintext' }, {
        provideDocumentHighlights() {
          return [
            { range: fullRange, kind: 1 },
            { range: new vscode.Range(new vscode.Position(2, 2), new vscode.Position(2, 8)), kind: 2 }
          ];
        }
      }),
      vscode.languages.registerDocumentLinkProvider({ language: 'plaintext' }, {
        provideDocumentLinks() {
          return [
            { range: linkRange, target: vscode.Uri.file('linked-target.txt'), tooltip: 'open target' },
            { range: new vscode.Range(new vscode.Position(3, 0), new vscode.Position(3, 4)) }
          ];
        },
        resolveDocumentLink(link) {
          if (!link.target) link.target = vscode.Uri.file('resolved-link.txt');
          if (!link.tooltip) link.tooltip = 'resolved target';
          return link;
        }
      }),
      vscode.languages.registerDocumentFormattingEditProvider({ language: 'plaintext' }, {
        provideDocumentFormattingEdits() {
          return [
            vscode.TextEdit.replace(fullRange, 'formatted-all')
          ];
        }
      }),
      vscode.languages.registerDocumentRangeFormattingEditProvider({ language: 'plaintext' }, {
        provideDocumentRangeFormattingEdits(document, range) {
          return [
            vscode.TextEdit.replace(range, 'formatted-range')
          ];
        }
      }),
      vscode.languages.registerOnTypeFormattingEditProvider({ language: 'plaintext' }, {
        provideOnTypeFormattingEdits(document, position, ch) {
          return [
            vscode.TextEdit.insert(position, `typed-${ch}`)
          ];
        }
      }, ';')
    ];

    registrations.forEach((registration) => context.subscriptions.push(registration));
    return { languageProvidersMoreSetup: true, registrations: registrations.length };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.hierarchyProvidersSetup', async () => {
    const uri = vscode.Uri.file('hierarchy-source.txt');
    const range = new vscode.Range(new vscode.Position(1, 0), new vscode.Position(1, 8));
    const selectionRange = new vscode.Range(new vscode.Position(1, 2), new vscode.Position(1, 8));
    const callItem = new vscode.CallHierarchyItem(vscode.SymbolKind.Function, 'smokeCall', 'fixture call', uri, range, selectionRange);
    const callerItem = new vscode.CallHierarchyItem(vscode.SymbolKind.Function, 'caller', 'incoming', vscode.Uri.file('caller.txt'), range, selectionRange);
    const calleeItem = new vscode.CallHierarchyItem(vscode.SymbolKind.Function, 'callee', 'outgoing', vscode.Uri.file('callee.txt'), range, selectionRange);
    const typeItem = new vscode.TypeHierarchyItem(vscode.SymbolKind.Class, 'SmokeType', 'fixture type', uri, range, selectionRange);
    const superItem = new vscode.TypeHierarchyItem(vscode.SymbolKind.Class, 'BaseSmoke', 'super', vscode.Uri.file('base-smoke.txt'), range, selectionRange);
    const subItem = new vscode.TypeHierarchyItem(vscode.SymbolKind.Class, 'ChildSmoke', 'sub', vscode.Uri.file('child-smoke.txt'), range, selectionRange);

    const registrations = [
      vscode.languages.registerCallHierarchyProvider({ language: 'plaintext' }, {
        prepareCallHierarchy() {
          return callItem;
        },
        provideCallHierarchyIncomingCalls() {
          return [{ from: callerItem, fromRanges: [selectionRange] }];
        },
        provideCallHierarchyOutgoingCalls() {
          return [{ to: calleeItem, fromRanges: [selectionRange] }];
        }
      }),
      vscode.languages.registerTypeHierarchyProvider({ language: 'plaintext' }, {
        prepareTypeHierarchy() {
          return typeItem;
        },
        provideTypeHierarchySupertypes() {
          return [superItem];
        },
        provideTypeHierarchySubtypes() {
          return [subItem];
        }
      })
    ];

    registrations.forEach((registration) => context.subscriptions.push(registration));
    return { hierarchyProvidersSetup: true, registrations: registrations.length };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.diagnosticsLifecycle', async () => {
    const collection = vscode.languages.createDiagnosticCollection('basic-api-smoke-lifecycle');
    const uri = vscode.Uri.file('diag-lifecycle.txt');
    const other = vscode.Uri.file('diag-lifecycle-other.txt');
    const makeDiag = (line, message) => ({
      range: new vscode.Range(new vscode.Position(line, 0), new vscode.Position(line, 4)),
      severity: vscode.DiagnosticSeverity.Information,
      message,
      source: 'basic-api-smoke-lifecycle',
      code: `D${line}`
    });

    collection.set(uri, [makeDiag(0, 'opened problem')]);
    collection.set(uri, [makeDiag(1, 'changed problem')]);
    collection.set([[other, [makeDiag(2, 'saved problem')]]]);
    let beforeClear = 0;
    collection.forEach(() => { beforeClear += 1; });
    collection.delete(uri);
    let afterDelete = 0;
    collection.forEach(() => { afterDelete += 1; });
    collection.clear();
    let afterClear = 0;
    collection.forEach(() => { afterClear += 1; });
    collection.dispose();
    return { diagnosticsLifecycle: true, beforeClear, afterDelete, afterClear };
  }));

  context.subscriptions.push(vscode.commands.registerCommand('basic-api-smoke.longTailApis', async () => {
    const panel = vscode.window.createWebviewPanel(
      'basicApiSmoke.panel',
      'Smoke Panel',
      vscode.ViewColumn.One,
      { retainContextWhenHidden: true, localResourceRoots: [context.extensionUri] }
    );
    let panelMessage = null;
    let panelDisposed = false;
    panel.webview.html = '<html><body>smoke</body></html>';
    const panelMessageDisposable = panel.webview.onDidReceiveMessage((message) => {
      panelMessage = message && message.kind;
    });
    const panelDisposeDisposable = panel.onDidDispose(() => {
      panelDisposed = true;
    });
    const panelPosted = await panel.webview.postMessage({ kind: 'panel-message' });
    const panelId = Object.keys(globalThis._wizp_webviewPanels || {}).find((id) => (globalThis._wizp_webviewPanels || {})[id] === panel) || panel.id || null;
    const panelMessageInjected = !!(panelId && globalThis._wizp_receiveWebviewMessage && globalThis._wizp_receiveWebviewMessage(panelId, { kind: 'panel-message' }));
    await flushTicks(1);
    panel.reveal(vscode.ViewColumn.Two, true);
    panel.dispose();
    panelMessageDisposable.dispose();
    panelDisposeDisposable.dispose();

    let webviewViewHtml = '';
    const viewRegistration = vscode.window.registerWebviewViewProvider('basic-api-smoke-view', {
      resolveWebviewView(view) {
        view.webview.html = '<html><body>view</body></html>';
        webviewViewHtml = view.webview.html;
      }
    }, { retainContextWhenHidden: true });
    const webviewProviderRegistered = !!(globalThis._wizp_webviewProviders && globalThis._wizp_webviewProviders['basic-api-smoke-view']);
    const webviewViewFocusResult = await vscode.commands.executeCommand('basic-api-smoke-view.focus');
    await flushTicks(1);
    const serializerRegistration = vscode.window.registerWebviewPanelSerializer('basicApiSmoke.panel', {
      async deserializeWebviewPanel(restoredPanel, state) {
        restoredPanel.webview.html = `<html><body>${state && state.restored ? 'restored' : 'panel'}</body></html>`;
      }
    });
    const webviewPanelSerializerRegistered = !!(globalThis._wizp_webviewPanelSerializers && globalThis._wizp_webviewPanelSerializers['basicApiSmoke.panel']);

    let customEditorResolved = false;
    let customEditorSaved = false;
    let customEditorReverted = false;
    let customEditorDisposed = false;
    let customEditorMessage = null;
    const customProvider = {
      resolveCustomTextEditor(document, panel) {
        customEditorResolved = document.uri.toString().endsWith('fixture.smoke-custom');
        panel.webview.html = '<html><body data-custom-editor="true">custom smoke</body></html>';
        panel.webview.onDidReceiveMessage((message) => {
          customEditorMessage = message && message.kind;
        });
        panel.webview.postMessage({ kind: 'custom-message' });
      },
      saveCustomDocument() {
        customEditorSaved = true;
      },
      revertCustomDocument() {
        customEditorReverted = true;
      }
    };
    const customRegistration = vscode.window.registerCustomEditorProvider('basicApiSmoke.customEditor', customProvider, { supportsMultipleEditorsPerDocument: true });
    const customEditorProvider = globalThis._wizp_customEditors && globalThis._wizp_customEditors['basicApiSmoke.customEditor'];
    const customEditorPanel = {
      webview: {
        html: '',
        onDidReceiveMessage(listener) {
          this._listener = listener;
          return { dispose() {} };
        },
        postMessage(message) {
          if (this._listener) this._listener(message);
          return Promise.resolve(true);
        }
      },
      onDidDispose(listener) {
        this._dispose = listener;
        return { dispose() {} };
      },
      dispose() {
        customEditorDisposed = true;
        if (this._dispose) this._dispose();
      }
    };
    const customDocument = {
      uri: vscode.Uri.file('fixture.smoke-custom'),
      getText() { return 'custom smoke document'; }
    };
    if (customEditorProvider) {
      await Promise.resolve(customEditorProvider.resolveCustomTextEditor(customDocument, customEditorPanel, { isCancellationRequested: false }));
      await Promise.resolve(customEditorProvider.saveCustomDocument(customDocument, { isCancellationRequested: false }));
      await Promise.resolve(customEditorProvider.revertCustomDocument(customDocument, { isCancellationRequested: false }));
      customEditorPanel.dispose();
    }
    const customEditorRegistered = !!customEditorProvider;
    const customEditorLifecycle = customEditorRegistered && customEditorResolved && customEditorSaved && customEditorReverted && customEditorDisposed && customEditorMessage === 'custom-message' && customEditorPanel.webview.html.includes('custom smoke');

    const treeView = vscode.window.createTreeView('basicApiSmoke.tree', {
      treeDataProvider: {
        getChildren() { return [{ id: 'child', label: 'Child' }]; },
        getTreeItem(item) { return item; }
      },
      showCollapseAll: true
    });
    let treeCheckboxCount = 0;
    let treeCollapseCount = 0;
    let treeExpandCount = 0;
    const treeCheckboxDisposable = treeView.onDidChangeCheckboxState((event) => {
      treeCheckboxCount += event.items.length;
    });
    const treeCollapseDisposable = treeView.onDidCollapseElement((event) => {
      if (event.element && event.element.id === 'child') treeCollapseCount += 1;
    });
    const treeExpandDisposable = treeView.onDidExpandElement((event) => {
      if (event.element && event.element.id === 'child') treeExpandCount += 1;
    });
    const treeChild = { id: 'child', label: 'Child' };
    treeView._fireCheckboxState([[{ id: 'child', label: 'Child' }, 1]]);
    treeView._fireCollapseElement(treeChild);
    treeView._fireExpandElement(treeChild);
    treeCheckboxDisposable.dispose();
    treeCollapseDisposable.dispose();
    treeExpandDisposable.dispose();
    const treeRegistered = !!(globalThis._wizp_treeViews && globalThis._wizp_treeViews['basicApiSmoke.tree']);

    const taskRegistration = vscode.tasks.registerTaskProvider('smokeTask', {
      provideTasks() {
        return [
          new vscode.Task(
            { type: 'smokeTask', script: 'build' },
            vscode.TaskScope.Workspace,
            'Smoke Task',
            'basic-api-smoke',
            new vscode.ShellExecution('echo', [{ value: 'smoke', quoting: vscode.ShellQuoting.Strong }])
          )
        ];
      }
    });
    const tasks = await vscode.tasks.fetchTasks({ type: 'smokeTask' });
    const taskExecution = await vscode.tasks.executeTask(tasks[0]);

    const debugRegistration = vscode.debug.registerDebugAdapterDescriptorFactory('smoke-debug', {
      createDebugAdapterDescriptor() {
        return { type: 'inline' };
      }
    });
    const debugStarted = await vscode.debug.startDebugging(undefined, { type: 'smoke-debug', request: 'launch', name: 'Smoke Debug' });

    const sourceControl = vscode.scm.createSourceControl('smoke-scm', 'Smoke SCM', vscode.Uri.file('/workspace'));
    const resourceGroup = sourceControl.createResourceGroup('changes', 'Changes');
    resourceGroup.resourceStates = [{ resourceUri: vscode.Uri.file('/workspace/file.txt') }];

    const commentController = vscode.comments.createCommentController('smoke-comments', 'Smoke Comments');
    const commentThread = commentController.createCommentThread(
      vscode.Uri.file('/workspace/file.txt'),
      new vscode.Range(new vscode.Position(0, 0), new vscode.Position(0, 1)),
      [{ body: 'hello', mode: 1, author: { name: 'Smoke' } }]
    );

    let notebookExecuted = false;
    let notebookSaved = false;
    let notebookReloaded = false;
    const notebookOutputs = [];
    const notebookDocument = {
      uri: vscode.Uri.file('fixture.smoke-notebook'),
      notebookType: 'smoke-notebook',
      isDirty: false,
      getCells() {
        return notebookCells;
      }
    };
    const notebookCells = [
      { index: 0, document: { languageId: 'smokelang', getText() { return 'pass'; } }, outputs: [] },
      { index: 1, document: { languageId: 'smokelang', getText() { return 'fail'; } }, outputs: [] }
    ];
    const notebookController = vscode.notebooks.createNotebookController('smoke-notebook', 'smoke-notebook', 'Smoke Notebook', async (cells, notebook) => {
      notebookExecuted = notebook.notebookType === 'smoke-notebook';
      for (const cell of cells) {
        const text = cell.document.getText();
        const output = text === 'fail' ? { kind: 'error', message: 'smoke failure' } : { kind: 'stdout', text: 'smoke output' };
        cell.outputs = [output];
        notebookOutputs.push(output);
      }
    });
    notebookController.supportedLanguages = ['smokelang'];
    await notebookController.executeHandler(notebookCells, notebookDocument, notebookController);
    const serializedNotebook = JSON.stringify({ cells: notebookCells.map((cell) => ({ language: cell.document.languageId, value: cell.document.getText(), outputs: cell.outputs })) });
    notebookSaved = serializedNotebook.includes('smoke output') && serializedNotebook.includes('smoke failure');
    const reloadedNotebook = JSON.parse(serializedNotebook);
    notebookReloaded = reloadedNotebook.cells.length === 2 && reloadedNotebook.cells[0].outputs[0].kind === 'stdout' && reloadedNotebook.cells[1].outputs[0].kind === 'error';
    const notebookLifecycle = notebookExecuted && notebookSaved && notebookReloaded && notebookOutputs.length === 2;
    const notebookTextItem = vscode.NotebookCellOutputItem.text('plain smoke');
    const notebookStdoutItem = vscode.NotebookCellOutputItem.stdout('smoke output');
    const notebookStderrItem = vscode.NotebookCellOutputItem.stderr('smoke stderr');
    const notebookErrorItem = vscode.NotebookCellOutputItem.error(new Error('smoke failure'));
    const notebookOutput = new vscode.NotebookCellOutput([notebookTextItem, notebookStdoutItem, notebookStderrItem, notebookErrorItem]);
    const notebookData = new vscode.NotebookData([
      new vscode.NotebookCellData(vscode.NotebookCellKind.Code, '1 + 1', 'javascript')
    ]);

    const testController = vscode.tests.createTestController('smoke-tests', 'Smoke Tests');
    const passingTest = testController.createTestItem('smoke-pass', 'Smoke Pass', vscode.Uri.file('smoke.test'));
    const failingTest = testController.createTestItem('smoke-fail', 'Smoke Fail', vscode.Uri.file('smoke.test'));
    testController.items.add(passingTest);
    testController.items.add(failingTest);
    const runProfile = testController.createRunProfile('Smoke Run Profile', 1, async (request) => {
      const testRun = testController.createTestRun(request, 'Smoke Run', false);
      for (const item of request.include || []) {
        testRun.enqueued(item);
        testRun.started(item);
        if (item.id === 'smoke-fail') {
          testRun.failed(item, new vscode.TestMessage('expected smoke failure'), 2);
        } else {
          testRun.passed(item, 1);
        }
      }
      testRun.appendOutput('smoke test output');
      testRun.end();
    }, true);
    await testController.runProfiles[0].handler(new vscode.TestRunRequest([passingTest, failingTest], [], runProfile));
    const testState = globalThis._wizp_testControllers && globalThis._wizp_testControllers['smoke-tests'];
    const testResults = testState && testState.results && testState.results[0];
    const testExplorerLifecycle = !!(testState && testState.items._items.length === 2 && testState.runProfiles.length === 1 && testResults && testResults.ended && testResults.results.some((item) => item.id === 'smoke-pass' && item.state === 'passed') && testResults.results.some((item) => item.id === 'smoke-fail' && item.state === 'failed') && testResults.output.join('').includes('smoke test output'));

    const authRegistration = vscode.authentication.registerAuthenticationProvider('smoke-auth', 'Smoke Auth', {
      async getSessions(scopes) {
        return [{
          id: 'smoke-session',
          accessToken: 'real-smoke-token',
          account: { id: 'smoke-account', label: 'Smoke Account' },
          scopes
        }];
      },
      async createSession(scopes) {
        return {
          id: 'created-smoke-session',
          accessToken: 'created-smoke-token',
          account: { id: 'created-smoke-account', label: 'Created Smoke Account' },
          scopes
        };
      },
      async removeSession() {}
    }, { supportsMultipleAccounts: false });
    const authSession = await vscode.authentication.getSession('smoke-auth', ['repo'], { createIfNone: true });
    const authSessionEventDisposable = vscode.authentication.onDidChangeSessions(() => {});
    const authSessionEventRegistered = !!authSessionEventDisposable.dispose;
    authSessionEventDisposable.dispose();

    const chatParticipant = vscode.chat.createChatParticipant('smoke-chat', async () => {});
    const chatParticipantDisposable = !!(chatParticipant && typeof chatParticipant.dispose === 'function');
    const lmNetworkAuditBefore = (globalThis._wizpNetworkAudit || []).length;
    const lmToolRegistration = vscode.lm.registerTool('smoke-tool', {
      async invoke() {
        return { content: [{ value: 'smoke tool' }] };
      }
    });
    const lmToolRegistered = !!(globalThis._wizpLmTools && globalThis._wizpLmTools['smoke-tool']);
    const chatModelsDefault = await vscode.lm.selectChatModels();
    const chatModelsAny = await vscode.lm.selectChatModels({});
    const chatModelsOpenAi = await vscode.lm.selectChatModels({ vendor: 'openai', family: 'gpt-4o' });
    const lmNetworkAuditAfter = (globalThis._wizpNetworkAudit || []).length;
    const unsupportedLanguageModelApi = {
      selectDefault: chatModelsDefault.length,
      selectAny: chatModelsAny.length,
      selectOpenAi: chatModelsOpenAi.length,
      noImplicitNetwork: lmNetworkAuditAfter === lmNetworkAuditBefore,
      hasRequestApi: typeof vscode.lm.sendChatParticipantRequest === 'function',
      hasModelObject: chatModelsDefault.concat(chatModelsAny, chatModelsOpenAi).some((model) => !!model)
    };
    const translated = vscode.l10n.t('Smoke translated');
    const external = await vscode.env.asExternalUri(vscode.Uri.parse('https://example.test/path'));
    const telemetryEventDisposable = vscode.env.onDidChangeTelemetryEnabled(() => {});
    const telemetryEventRegistered = !!telemetryEventDisposable.dispose;
    telemetryEventDisposable.dispose();
    const windowStateDisposable = vscode.window.onDidChangeWindowState(() => {});
    const windowStateEventRegistered = !!windowStateDisposable.dispose;
    windowStateDisposable.dispose();

    viewRegistration.dispose();
    serializerRegistration.dispose();
    customRegistration.dispose();
    treeView.dispose();
    taskRegistration.dispose();
    debugRegistration.dispose();
    sourceControl.dispose();
    commentThread.dispose();
    commentController.dispose();
    notebookController.dispose();
    testController.dispose();
    authRegistration.dispose();
    chatParticipant.dispose();
    lmToolRegistration.dispose();
    const lmToolDisposed = !(globalThis._wizpLmTools && globalThis._wizpLmTools['smoke-tool']);

    return {
      webviewPanel: panelPosted === true && panelMessageInjected === true && panelMessage === 'panel-message' && panelDisposed === true && panel.viewColumn === vscode.ViewColumn.Two,
      webviewPanelMessageReceived: panelMessage,
      webviewPanelMessageInjected: panelMessageInjected,
      webviewPanelHtml: panel.webview.html,
      webviewViewRegistered: webviewProviderRegistered,
      webviewViewResolved: webviewViewHtml === '<html><body>view</body></html>' && webviewViewFocusResult === true,
      webviewViewHtml,
      webviewPanelSerializerRegistered,
      customEditorRegistered,
      customEditorLifecycle,
      customEditorHtml: customEditorPanel.webview.html,
      treeRegistered,
      treeCheckboxCount,
      treeCollapseCount,
      treeExpandCount,
      taskCount: tasks.length,
      taskName: tasks[0] && tasks[0].name,
      taskExecutionName: taskExecution && taskExecution.task && taskExecution.task.name,
      debugStarted,
      sourceControlGroup: resourceGroup.resourceStates.length,
      commentThread: commentThread.comments.length,
      notebookController: notebookController.viewType,
      notebookLifecycle,
      notebookOutputs: notebookOutputs.map((output) => output.kind),
      notebookOutputItems: notebookOutput.items.map((item) => item.mime),
      notebookOutputText: new TextDecoder().decode(notebookTextItem.data),
      notebookDataLanguage: notebookData.cells[0].languageId,
      testController: testController.id,
      testExplorerLifecycle,
      testItems: testState ? testState.items._items.map((item) => item.id) : [],
      testProfiles: testState ? testState.runProfiles.map((profile) => profile.label) : [],
      testResults: testResults ? testResults.results.filter((item) => item.state === 'passed' || item.state === 'failed').map((item) => item.state) : [],
      authSession: authSession && authSession.id,
      authToken: authSession && authSession.accessToken,
      authSessionEventRegistered,
      envMachineId: vscode.env.machineId,
      envSessionId: vscode.env.sessionId,
      envAppName: vscode.env.appName,
      envExternal: external.toString(),
      envTelemetryEnabled: vscode.env.isTelemetryEnabled,
      envTelemetryEventRegistered: telemetryEventRegistered,
      windowFocused: vscode.window.state.focused,
      windowStateEventRegistered,
      l10n: translated,
      chatParticipantDisposable,
      lmToolRegistered,
      lmToolDisposed,
      chatModelsLength: chatModelsAny.length,
      unsupportedLanguageModelApi,
      proposedUnavailable: typeof vscode.proposedApi === 'undefined'
    };
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };
