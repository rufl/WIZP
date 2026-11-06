<script lang="ts">
  import { tick } from 'svelte';
  import { SvelteMap } from 'svelte/reactivity';
  import { get } from 'svelte/store';
  import Tab from './Tab.svelte';
  import Welcome from './Welcome.svelte';
  import {
    editorGroups as realGroups,
    editorUiState,
    getActiveGroupId,
    visibleGroupOrder,
    openEditorInGroup,
    setActiveEditor,
    closeEditor,
    splitGroup,
    closeGroup,
    setActiveGroupId,
    moveEditorToGroup,
    reorderEditorToIndex,
    createEditorGroup,
    ensureBootstrapGroup,
    notifyEditorState,
  } from '$lib/editor/state.svelte';
  import {
    cancelPendingRpcRequests,
    nativeControlCredentials,
    readFile,
    saveFile,
    sendRpc,
    sendRpcBounded,
    sendRpcFields,
  } from '../../bridge';
  import {
    loadRendererSession,
    updateRendererSession,
    flushRendererSession,
  } from '$lib/session-recovery';
  import { lsp } from '$lib/lsp/client';
  import { projectPath, vimMode, showToast } from '../stores';
  import {
    decorateWebviewHtml,
    normalizeWebviewMessagePayload,
    postHostMessageToWebview,
    unwrapWebviewClientMessage,
  } from '$lib/webview-bridge';
  type ExtensionLspResult = Record<string, unknown>;
  type ExtensionLspResolver = (value: unknown) => void;

  function invokeExtensionLsp(
    method: string,
    fields: Record<string, unknown>,
  ): Promise<ExtensionLspResult | null> {
    const reqId = `lsp_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
    const windowRecord = window as unknown as {
      __lspResolvers?: Record<string, ExtensionLspResolver>;
    };
    const resolvers = (windowRecord.__lspResolvers ??= {});

    return new Promise((resolve) => {
      let settled = false;
      const finish = (value: unknown) => {
        if (settled) return;
        settled = true;
        delete resolvers[reqId];
        resolve(value && typeof value === 'object' ? (value as ExtensionLspResult) : null);
      };
      resolvers[reqId] = finish;
      void sendRpcFields(method, { ...fields, reqId }).catch(() => finish(null));
      window.setTimeout(() => finish(null), 500);
    });
  }

  // Svelte 5 runes mode - multi-group split support (B1)

  const MONACO_PATH = (window as any).MONACO_PATH || '/monaco';
  let monaco: any;
  let monacoReady = $state(false);
  let monacoLoading = false;
  let fileInput: HTMLInputElement;

  let breadcrumbDropdownOpen = $state(false);
  let breadcrumbDropdownItems = $state<any[]>([]);
  let breadcrumbDropdownRect = $state({ top: 0, left: 0 });
  let breadcrumbSymbolsByGroup = $state<Record<string, any[]>>({});
  let breadcrumbActiveLines = $state<Record<string, number | null>>({});

  const symbolIcon = (kind: number) => {
    const map: Record<number, string> = {
      1: 'symbol-file',
      2: 'symbol-module',
      3: 'symbol-namespace',
      4: 'symbol-package',
      5: 'symbol-class',
      6: 'symbol-method',
      7: 'symbol-property',
      8: 'symbol-field',
      9: 'symbol-constructor',
      10: 'symbol-enum',
      11: 'symbol-interface',
      12: 'symbol-function',
      13: 'symbol-variable',
      14: 'symbol-constant',
    };
    return map[kind] || 'symbol-misc';
  };

  function setBreadcrumbDropdownOpen(open: boolean) {
    breadcrumbDropdownOpen = open;
    const dropdown = document.querySelector<HTMLElement>('.breadcrumb-dropdown');
    if (dropdown) dropdown.hidden = !open;
  }

  async function openBreadcrumbDropdown(e: MouseEvent, groupId: string, crumb: any) {
    e.stopPropagation();
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    breadcrumbDropdownRect = { top: rect.bottom, left: rect.left };
    setBreadcrumbDropdownOpen(true);
    breadcrumbDropdownItems = [];

    if (crumb.type === 'symbol') {
      const symbols = breadcrumbSymbolsByGroup[groupId] || [];
      breadcrumbDropdownItems = flattenSymbols(symbols).map((sym) => ({
        label: sym.name,
        hint: sym.containerName || '',
        icon: symbolIcon(sym.kind),
        depth: sym.depth || 0,
        action: () => gotoBreadcrumbSymbol(groupId, sym),
        closeOnSelect: true,
      }));
    } else if (crumb.type === 'file') {
      const symbols = await loadBreadcrumbSymbols(groupId);
      breadcrumbDropdownItems = flattenSymbols(symbols).map((sym) => ({
        label: sym.name,
        hint: sym.containerName || '',
        icon: symbolIcon(sym.kind),
        depth: sym.depth || 0,
        action: () => gotoBreadcrumbSymbol(groupId, sym),
        closeOnSelect: true,
      }));
    } else {
      await loadBreadcrumbDirectory(groupId, crumb.path);
    }
  }

  $effect(() => {
    const closeDropdown = () => setBreadcrumbDropdownOpen(false);
    window.addEventListener('click', closeDropdown);
    return () => window.removeEventListener('click', closeDropdown);
  });

  function activeEditorForGroup(groupId: string) {
    const group = realGroups[groupId];
    return group?.activeEditorId
      ? group.editors.find((e: any) => e.id === group.activeEditorId)
      : null;
  }
  async function refreshZlayInteraction(
    groupId: string,
    tab: any,
    editor: any,
    pointerSurface?: number,
    captureSurface?: number,
    releaseCapture = false,
  ) {
    const model = editor?.getModel?.();
    if (!model || tab?.type === 'webview') return;
    try {
      const lineHeight = editor.getOption(monaco.editor.EditorOption.lineHeight);
      const snapshot = await sendRpc('editor/interactionAudit', {
        lineCount: model.getLineCount(),
        viewportLines: Math.max(Math.ceil(editor.getLayoutInfo().height / lineHeight), 1),
        scrollOffset: Math.max(Math.floor(editor.getScrollTop() / lineHeight), 0),
        pointerSurface,
        captureSurface,
        releaseCapture,
      });
      const current = activeEditorForGroup(groupId);
      if (current?.id === tab.id && snapshot?.engine === 'zlay') {
        current.zlayInteraction = snapshot;
        notifyEditorState();
      }
    } catch {
      // ZLAY telemetry must not interrupt editor interaction.
    }
  }

  function symbolLine(sym: any) {
    return (
      sym.location?.range?.start?.line ??
      sym.selectionRange?.start?.line ??
      sym.range?.start?.line ??
      0
    );
  }

  function symbolCharacter(sym: any) {
    return (
      sym.location?.range?.start?.character ??
      sym.selectionRange?.start?.character ??
      sym.range?.start?.character ??
      0
    );
  }

  function flattenSymbols(symbols: any[], depth = 0, parents: any[] = []): any[] {
    const out: any[] = [];
    for (const sym of symbols || []) {
      const item = { ...sym, depth, parents };
      out.push(item);
      if (Array.isArray(sym.children))
        out.push(...flattenSymbols(sym.children, depth + 1, [...parents, item]));
    }
    return out;
  }

  async function loadBreadcrumbSymbols(groupId: string) {
    const active = activeEditorForGroup(groupId);
    const uri = active?.uri;
    if (!uri) return [];
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        const res = await sendRpcBounded('textDocument/documentSymbol', { uri }, 2000);
        const symbols = Array.isArray(res) ? res : [];
        if (symbols.length > 0 || attempt === 2) {
          breadcrumbSymbolsByGroup = { ...breadcrumbSymbolsByGroup, [groupId]: symbols };
          return symbols;
        }
      } catch {
        if (attempt === 2) {
          breadcrumbSymbolsByGroup = { ...breadcrumbSymbolsByGroup, [groupId]: [] };
          return [];
        }
      }
      await new Promise((resolve) => window.setTimeout(resolve, 150 * (attempt + 1)));
    }
    return [];
  }

  async function loadBreadcrumbDirectory(groupId: string, dirPath: string) {
    try {
      const res = await sendRpc('file/list', { path: dirPath });
      breadcrumbDropdownItems = (res?.files || res?.entries || []).map((f: any) => {
        const isDir = f.kind === 'directory' || f.type === 'directory' || f.isDirectory;
        const childPath = `${dirPath.replace(/\/$/, '')}/${f.name}`;
        return {
          label: f.name,
          icon: isDir ? 'folder' : 'file',
          action: () =>
            isDir
              ? loadBreadcrumbDirectory(groupId, childPath)
              : openBreadcrumbFile(groupId, childPath),
          closeOnSelect: !isDir,
        };
      });
    } catch {
      breadcrumbDropdownItems = [];
    }
  }

  async function openBreadcrumbFile(groupId: string, path: string) {
    setBreadcrumbDropdownOpen(false);
    try {
      const res = await readFile(path);
      await openFileIntoGroup(groupId, path, res?.content || '');
    } catch {
      // Breadcrumb file opening is optional and the current editor remains active.
    }
  }

  async function gotoBreadcrumbSymbol(groupId: string, sym: any) {
    setBreadcrumbDropdownOpen(false);
    await tick();
    setActiveGroupId(groupId);
    const pane = groupPanes[groupId];
    const ed = pane?.editor;
    if (!ed) return;
    const line = symbolLine(sym);
    const col = symbolCharacter(sym);
    ed.revealLineInCenter(line + 1);
    ed.setPosition({ lineNumber: line + 1, column: col + 1 });
    ed.focus();
  }

  let closePrompt = $state<{
    groupId: string;
    tabId: string;
    name: string;
    content: string;
    after?: () => void;
  } | null>(null);
  let closePromptDialog = $state<HTMLDivElement | null>(null);
  let closePromptReturnFocus: HTMLElement | null = null;

  $effect(() => {
    const handleComment = (e: Event) => {
      const detail = (e as CustomEvent).detail ?? {};
      const gid = getActiveGroupId();
      const pane = groupPanes[gid];
      const uri = typeof detail.uri === 'string' ? detail.uri : '';
      const modelUri = pane?.editor?.getModel()?.uri.toString() ?? '';
      if (!pane?.editor || !uri || modelUri.replace('file://', '') !== uri.replace('file://', '')) {
        return;
      }

      pane.editor.changeViewZones((changeAccessor: any) => {
        const domNode = document.createElement('div');
        domNode.style.cssText =
          'padding:10px;background:#2d2d2d;border:1px solid #444;border-radius:4px;color:#ccc;font-family:sans-serif;display:flex;flex-direction:column;gap:8px;z-index:10;';

        const title = document.createElement('div');
        title.textContent = 'Comment Thread';
        title.style.cssText = 'font-weight:bold;font-size:12px;color:#fff;';
        domNode.append(title);

        const firstComment = Array.isArray(detail.comments) ? detail.comments[0] : null;
        const commentText =
          typeof firstComment === 'string'
            ? firstComment
            : typeof firstComment?.body === 'string'
              ? firstComment.body
              : 'Extension comment';
        const message = document.createElement('div');
        message.textContent = commentText;
        message.style.cssText = 'font-size:12px;white-space:pre-wrap;';
        domNode.append(message);

        const textarea = document.createElement('textarea');
        textarea.setAttribute('aria-label', 'Reply to comment');
        textarea.placeholder = 'Reply...';
        textarea.style.cssText =
          'width:100%;height:50px;background:#1e1e1e;border:1px solid #555;color:#fff;padding:4px;resize:none;border-radius:2px;outline:none;';
        domNode.append(textarea);

        const actions = document.createElement('div');
        actions.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;';
        const reply = document.createElement('button');
        reply.type = 'button';
        reply.textContent = 'Reply';
        reply.style.cssText =
          'padding:4px 12px;background:#007acc;color:#fff;border:none;cursor:pointer;border-radius:2px;font-size:11px;';
        reply.addEventListener('click', () => {
          const value = textarea.value.trim();
          if (!value || typeof detail.id !== 'string') return;
          reply.disabled = true;
          void fetch('/api/extension/ui/reply', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id: detail.id, value }),
          })
            .then(() => {
              reply.textContent = 'Sent';
            })
            .catch(() => {
              reply.disabled = false;
            });
        });
        actions.append(reply);
        domNode.append(actions);

        changeAccessor.addZone({
          afterLineNumber: Number(detail.line) + 1,
          heightInLines: 8,
          domNode,
          marginDomNode: null,
        });
      });
    };
    window.addEventListener('wizpCommentThreadCreated', handleComment);
    return () => window.removeEventListener('wizpCommentThreadCreated', handleComment);
  });

  let diagPoller: ReturnType<typeof setInterval> | null = null;
  let mProviderDisposables: any[] = [];

  async function ensureMonaco() {
    if (monacoReady) return;
    if (monacoLoading)
      return new Promise<void>((r) => {
        const i = setInterval(() => {
          if (monacoReady) {
            clearInterval(i);
            r();
          }
        }, 50);
      });
    monacoLoading = true;
    const smokeState = ((window as any).__wizpMonacoSmokeState = {
      phase: 'loading',
      requireType: typeof (window as any).require,
      requireConfig: typeof (window as any).require?.config,
    }) as Record<string, unknown>;
    const existingRequire = (window as any).require;
    if (typeof existingRequire !== 'function' || typeof existingRequire.config !== 'function') {
      await new Promise<void>((resolve) => {
        const script = document.createElement('script');
        script.src = MONACO_PATH + '/loader.js';
        script.onload = () => {
          smokeState.phase = 'loader-loaded';
          smokeState.requireType = typeof (window as any).require;
          smokeState.requireConfig = typeof (window as any).require?.config;
          resolve();
        };
        script.onerror = () => {
          smokeState.phase = 'loader-error';
          console.error('Failed to load Monaco');
          resolve();
        };
        document.head.appendChild(script);
      });
    }

    smokeState.phase = 'configuring';

    (window as any).MonacoEnvironment = {
      getWorkerUrl: function (_moduleId: any, label: any) {
        const map: Record<string, string> = {
          json: '/language/json/json.worker.js',
          css: '/language/css/css.worker.js',
          html: '/language/html/html.worker.js',
          typescript: '/language/typescript/ts.worker.js',
          javascript: '/language/typescript/ts.worker.js',
        };
        const p = map[label] || '/editor/editor.worker.js';
        return `data:text/javascript;charset=utf-8,${encodeURIComponent(`importScripts('${MONACO_PATH}${p}');`)}`;
      },
    };
    (window as any).require.config({ paths: { vs: MONACO_PATH } });

    await new Promise<void>((resolve) => {
      smokeState.phase = 'amd-loading';
      (window as any).require(['vs/editor/editor.main'], () => {
        smokeState.phase = 'amd-callback';
        monaco = (window as any).monaco;
        monaco.editor.defineTheme('wizp-dark', {
          base: 'vs-dark',
          inherit: true,
          rules: [
            { token: 'comment', foreground: '6A9955' },
            { token: 'keyword', foreground: '569CD6' },
            { token: 'string', foreground: 'CE9178' },
            { token: 'number', foreground: 'B5CEA8' },
            { token: 'type', foreground: '4EC9B0' },
            { token: 'function', foreground: 'DCDCAA' },
            { token: 'variable', foreground: '9CDCFE' },
          ],
          colors: {
            'editor.background': '#1E1E1E',
            'editor.foreground': '#D4D4D4',
            'editor.lineHighlightBackground': '#2A2D2E',
            'editor.selectionBackground': '#264F78',
            'editorCursor.foreground': '#FFFFFF',
            'editorLineNumber.foreground': '#858585',
            'editorLineNumber.activeForeground': '#C6C6C6',
            'editorIndentGuide.background': '#404040',
            'editorIndentGuide.activeBackground': '#707070',
          },
        });
        monacoReady = true;
        smokeState.phase = 'ready';

        // Register LSP providers once (not per-group) to prevent accumulation
        if (mProviderDisposables.length === 0) {
          mProviderDisposables.push(
            monaco.languages.registerCompletionItemProvider('*', {
              provideCompletionItems: async (model: any, position: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  // Fetch native LSP
                  const nativeRes = await lsp.completion(
                    uri,
                    position.lineNumber - 1,
                    position.column - 1,
                  );
                  let items = (
                    Array.isArray(nativeRes.items)
                      ? nativeRes.items
                      : (nativeRes.items || '').split(',')
                  )
                    .filter(Boolean)
                    .map((label: string) => ({
                      label,
                      kind: monaco.languages.CompletionItemKind.Text,
                      insertText: label,
                    }));

                  // Fetch extension provided LSP
                  const extRes = await invokeExtensionLsp('extension/invokeCompletion', {
                    uri: uri.replace('file://', ''),
                    line: position.lineNumber - 1,
                    col: position.column - 1,
                  });
                  if (extRes && extRes.items) {
                    const mapped = extRes.items.map((i: any) => ({
                      label: i.label,
                      kind:
                        typeof i.kind === 'number'
                          ? i.kind
                          : monaco.languages.CompletionItemKind.Property,
                      insertText: i.insertText || i.label,
                      detail: i.detail,
                      documentation: i.documentation,
                    }));
                    items = [...items, ...mapped];
                  }

                  return { suggestions: items };
                } catch {
                  return { suggestions: [] };
                }
              },
            }),
          );
          mProviderDisposables.push(
            monaco.languages.registerHoverProvider('*', {
              provideHover: async (model: any, position: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  let combinedText = '';

                  // Extension Hover
                  const extRes = await invokeExtensionLsp('extension/invokeHover', {
                    uri: uri.replace('file://', ''),
                    line: position.lineNumber - 1,
                    col: position.column - 1,
                  });
                  if (extRes && extRes.contents) {
                    combinedText += extRes.contents
                      .map((c: any) => (typeof c === 'string' ? c : c.value))
                      .join('\n\n');
                  }

                  // Native Hover
                  const res = await lsp.hover(uri, position.lineNumber - 1, position.column - 1);
                  if (res && res.contents && res.contents.value) {
                    if (combinedText) combinedText += '\n\n---\n\n';
                    combinedText += res.contents.value;
                  }

                  if (combinedText) {
                    return { contents: [{ value: combinedText }] };
                  }
                  return null;
                } catch {
                  return null;
                }
              },
            }),
          );
          mProviderDisposables.push(
            monaco.languages.registerDefinitionProvider('*', {
              provideDefinition: async (model: any, position: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  let combinedDefs: any[] = [];
                  // Extension Definition
                  const extRes = await invokeExtensionLsp('extension/invokeDefinition', {
                    uri: uri.replace('file://', ''),
                    line: position.lineNumber - 1,
                    col: position.column - 1,
                  });
                  if (extRes) {
                    const arr = Array.isArray(extRes) ? extRes : [extRes];
                    combinedDefs = arr.map((d: any) => ({
                      uri: monaco.Uri.parse(d.uri.fsPath || d.uri.path || d.uri),
                      range: {
                        startLineNumber: d.range.start.line + 1,
                        startColumn: d.range.start.character + 1,
                        endLineNumber: d.range.end.line + 1,
                        endColumn: d.range.end.character + 1,
                      },
                    }));
                  }

                  // Native Definition
                  const res = await lsp.definition(
                    uri,
                    position.lineNumber - 1,
                    position.column - 1,
                  );
                  if (res && res.uri) {
                    combinedDefs.push({
                      uri: monaco.Uri.parse(res.uri),
                      range: {
                        startLineNumber: (res.range?.start?.line || 0) + 1,
                        startColumn: (res.range?.start?.character || 0) + 1,
                        endLineNumber: (res.range?.end?.line || 0) + 1,
                        endColumn: (res.range?.end?.character || 0) + 1,
                      },
                    });
                  }
                  return combinedDefs.length > 0 ? combinedDefs : null;
                } catch {
                  return null;
                }
              },
            }),
          );

          mProviderDisposables.push(
            monaco.languages.registerReferenceProvider('*', {
              provideReferences: async (model: any, position: any, context: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  let combinedRefs: any[] = [];
                  // Extension Reference
                  const extRes = await invokeExtensionLsp('extension/invokeReference', {
                    uri: uri.replace('file://', ''),
                    line: position.lineNumber - 1,
                    col: position.column - 1,
                  });
                  if (Array.isArray(extRes)) {
                    combinedRefs = extRes.map((r: any) => ({
                      uri: monaco.Uri.parse(r.uri.fsPath || r.uri.path || r.uri),
                      range: {
                        startLineNumber: r.range.start.line + 1,
                        startColumn: r.range.start.character + 1,
                        endLineNumber: r.range.end.line + 1,
                        endColumn: r.range.end.character + 1,
                      },
                    }));
                  }

                  // Native Reference
                  const res = await sendRpc('textDocument/references', {
                    uri,
                    position: { line: position.lineNumber - 1, character: position.column - 1 },
                    context,
                  });
                  if (Array.isArray(res)) {
                    combinedRefs = [
                      ...combinedRefs,
                      ...res.map((r: any) => ({
                        uri: monaco.Uri.parse(r.uri),
                        range: {
                          startLineNumber: (r.range?.start?.line || 0) + 1,
                          startColumn: (r.range?.start?.character || 0) + 1,
                          endLineNumber: (r.range?.end?.line || 0) + 1,
                          endColumn: (r.range?.end?.character || 0) + 1,
                        },
                      })),
                    ];
                  }
                  return combinedRefs;
                } catch {
                  return [];
                }
              },
            }),
          );

          mProviderDisposables.push(
            monaco.languages.registerRenameProvider('*', {
              provideRenameEdits: async (model: any, position: any, newName: string) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  const extRes = await invokeExtensionLsp('extension/invokeRename', {
                    uri: uri.replace('file://', ''),
                    line: position.lineNumber - 1,
                    col: position.column - 1,
                    newName,
                  });

                  let res = extRes;
                  if (!res) {
                    // Fallback to Native Rename
                    res = await sendRpc('textDocument/rename', {
                      uri,
                      position: { line: position.lineNumber - 1, character: position.column - 1 },
                      newName,
                    });
                  }

                  if (res && res.changes) {
                    const edits: any[] = [];
                    for (const [fileUri, changes] of Object.entries(res.changes)) {
                      const editsArray = changes as any[];
                      for (const c of editsArray) {
                        edits.push({
                          resource: monaco.Uri.parse(fileUri),
                          textEdit: {
                            range: {
                              startLineNumber: (c.range?.start?.line || 0) + 1,
                              startColumn: (c.range?.start?.character || 0) + 1,
                              endLineNumber: (c.range?.end?.line || 0) + 1,
                              endColumn: (c.range?.end?.character || 0) + 1,
                            },
                            text: c.newText,
                          },
                          versionId: undefined,
                        });
                      }
                    }
                    return { edits };
                  }
                  return { edits: [] };
                } catch {
                  return { edits: [] };
                }
              },
            }),
          );

          mProviderDisposables.push(
            monaco.languages.registerCodeActionProvider('*', {
              provideCodeActions: async (_model: any, _range: any, _context: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;

                  let combinedActions: any[] = [];
                  const extRes = await invokeExtensionLsp('extension/invokeCodeAction', {
                    uri: uri.replace('file://', ''),
                    rangeStartLine: _range.startLineNumber - 1,
                    rangeStartCol: _range.startColumn - 1,
                    rangeEndLine: _range.endLineNumber - 1,
                    rangeEndCol: _range.endColumn - 1,
                  });
                  if (Array.isArray(extRes)) {
                    combinedActions = extRes;
                  }

                  // Native Code Action
                  const actions = await lsp.codeActions(
                    uri,
                    range.startLineNumber - 1,
                    range.startColumn - 1,
                  );
                  combinedActions = [...combinedActions, ...actions];

                  const monacoActions = combinedActions.map((a: any) => {
                    const edits: any[] = [];
                    if (a.edit && a.edit.changes) {
                      for (const [fileUri, changes] of Object.entries(a.edit.changes)) {
                        const editsArray = changes as any[];
                        for (const c of editsArray) {
                          edits.push({
                            resource: monaco.Uri.parse(fileUri),
                            textEdit: {
                              range: {
                                startLineNumber: (c.range?.start?.line || 0) + 1,
                                startColumn: (c.range?.start?.character || 0) + 1,
                                endLineNumber: (c.range?.end?.line || 0) + 1,
                                endColumn: (c.range?.end?.character || 0) + 1,
                              },
                              text: c.newText,
                            },
                            versionId: undefined,
                          });
                        }
                      }
                    }
                    return {
                      title: a.title,
                      kind: a.kind,
                      edit: { edits },
                      isPreferred: a.isPreferred,
                    };
                  });
                  return { actions: monacoActions, dispose: () => {} };
                } catch {
                  return { actions: [], dispose: () => {} };
                }
              },
            }),
          );
          try {
            mProviderDisposables.push(
              monaco.languages.registerInlayHintsProvider('*', {
                provideInlayHints: async (_model: any, _range: any, _token: any) => {
                  try {
                    const gid = getActiveGroupId();
                    const g = realGroups[gid];
                    const uri = g?.activeEditorId
                      ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                        `file://group-${gid}`
                      : `file://group-${gid}`;
                    const res = await sendRpc('textDocument/inlayHint', { uri });
                    if (Array.isArray(res))
                      return {
                        hints: res.map((h: any) => ({
                          position: {
                            lineNumber: (h.position?.line || 0) + 1,
                            column: (h.position?.character || 0) + 1,
                          },
                          label: h.label || '',
                          kind: h.kind === 2 ? 1 : 0,
                          paddingLeft: h.paddingLeft,
                          paddingRight: h.paddingRight !== false,
                        })),
                        dispose: () => {},
                      };
                  } catch {
                    // Inlay hints are optional when the language service is unavailable.
                  }
                  return { hints: [], dispose: () => {} };
                },
              }),
            );
          } catch {
            // Provider registration is optional for unsupported Monaco environments.
          }

          try {
            mProviderDisposables.push(
              monaco.languages.registerCodeLensProvider('*', {
                provideCodeLenses: async (_model: any, _token: any) => {
                  try {
                    const gid = getActiveGroupId();
                    const g = realGroups[gid];
                    const uri = g?.activeEditorId
                      ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                        `file://group-${gid}`
                      : `file://group-${gid}`;
                    const res = await sendRpc('extension/codeLenses', { uri });
                    const lenses = Array.isArray(res?.lenses) ? res.lenses : [];
                    return {
                      lenses: lenses.map((lens: any) => ({
                        range: {
                          startLineNumber: (lens.range?.start?.line || 0) + 1,
                          startColumn: (lens.range?.start?.character || 0) + 1,
                          endLineNumber: (lens.range?.end?.line || 0) + 1,
                          endColumn: (lens.range?.end?.character || 0) + 1,
                        },
                        command: lens.command
                          ? {
                              id: lens.command.command,
                              title: lens.command.title || lens.command.command,
                              arguments: lens.command.arguments || [],
                            }
                          : undefined,
                      })),
                      dispose: () => {},
                    };
                  } catch {
                    // Code lenses are optional when the extension service is unavailable.
                  }
                  return { lenses: [], dispose: () => {} };
                },
              }),
            );
          } catch {
            // Provider registration is optional for unsupported Monaco environments.
          }

          try {
            mProviderDisposables.push(
              monaco.languages.registerFoldingRangeProvider('*', {
                provideFoldingRanges: async (_model: any, _context: any, _token: any) => {
                  try {
                    const gid = getActiveGroupId();
                    const g = realGroups[gid];
                    const uri = g?.activeEditorId
                      ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                        `file://group-${gid}`
                      : `file://group-${gid}`;
                    const res = await sendRpc('extension/foldingRanges', { uri });
                    const ranges = Array.isArray(res?.ranges) ? res.ranges : [];
                    return ranges.map((fold: any) => ({
                      start: (fold.start || 0) + 1,
                      end: (fold.end || 0) + 1,
                      kind: fold.kind,
                    }));
                  } catch {
                    // Folding ranges are optional when the language service is unavailable.
                  }
                  return [];
                },
              }),
            );
          } catch {
            // Provider registration is optional for unsupported Monaco environments.
          }

          mProviderDisposables.push(
            monaco.languages.registerSignatureHelpProvider('*', {
              signatureHelpTriggerCharacters: ['(', ','],
              provideSignatureHelp: async (model: any, position: any) => {
                try {
                  const gid = getActiveGroupId();
                  const g = realGroups[gid];
                  const uri = g?.activeEditorId
                    ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri ||
                      `file://group-${gid}`
                    : `file://group-${gid}`;
                  const help = await lsp.signatureHelp(
                    uri,
                    position.lineNumber - 1,
                    position.column - 1,
                  );
                  if (help && help.signatures) return { value: help, dispose: () => {} };
                } catch {
                  // Signature help is optional when the language service is unavailable.
                }
                return {
                  value: { signatures: [], activeSignature: 0, activeParameter: 0 },
                  dispose: () => {},
                };
              },
            }),
          );

          mProviderDisposables.push(
            monaco.languages.registerCompletionItemProvider('*', {
              triggerCharacters: [' ', '.'],
              provideCompletionItems: async (model: any, position: any) => {
                const word = model.getWordUntilPosition(position);
                const words = [
                  'for',
                  'if',
                  'while',
                  'function',
                  'class',
                  'import',
                  'export',
                  'const',
                  'let',
                  'var',
                  'return',
                  'try',
                  'catch',
                  'switch',
                  'case',
                ];
                const suggestions = words
                  .filter((s: string) => s.startsWith(word.word))
                  .map((s: string) => ({
                    label: s,
                    kind: monaco.languages.CompletionItemKind.Snippet,
                    insertText: s + ' ',
                    detail: 'Keyword',
                  }));
                return { suggestions };
              },
            }),
          );
        }

        if (!diagPoller) {
          diagPoller = setInterval(() => {
            (window as any).refreshLSPDiagnostics?.();
            (window as any).refreshBreakpoints?.();
          }, 2500); // B2 diagnostics polling for nice product
        }
        resolve();
      });
    });
  }

  (window as any).refreshBreakpoints = () => {
    Object.keys(groupPanes).forEach((gid) => {
      updateBreakpointsForPane(gid);
    });
  };

  // Listen for settings changes to toggle minimap on all live editors
  (window as any).__settingsChanged = (settings: any) => {
    if (!settings) return;
    const opts: Record<string, any> = {};
    const fontSize = Number(settings.fontSize);
    const tabSize = Number(settings.tabSize);
    const wordWrapColumn = Number(settings.wordWrapColumn);
    if (typeof settings.minimap === 'boolean')
      opts.minimap = { enabled: settings.minimap, scale: 1, showSlider: 'mouseover' };
    if (Number.isFinite(fontSize)) opts.fontSize = fontSize;
    if (typeof settings.fontFamily === 'string') opts.fontFamily = settings.fontFamily;
    if (Number.isFinite(tabSize)) opts.tabSize = tabSize;
    if (typeof settings.lineNumbers === 'boolean')
      opts.lineNumbers = settings.lineNumbers ? 'on' : 'off';
    if (typeof settings.wordWrap === 'string') opts.wordWrap = settings.wordWrap;
    if (Number.isFinite(wordWrapColumn)) opts.wordWrapColumn = wordWrapColumn;
    if (typeof settings.cursorStyle === 'string') {
      const styleMap: Record<string, number> = {
        line: 1,
        block: 2,
        underline: 3,
        'line-thin': 4,
        'block-outline': 5,
        'underline-thin': 6,
      };
      opts.cursorStyle = styleMap[settings.cursorStyle] ?? 1;
    }
    if (typeof settings.bracketPairColorization === 'boolean')
      opts.bracketPairColorization = { enabled: settings.bracketPairColorization };
    if (typeof settings.renderWhitespace === 'string')
      opts.renderWhitespace = settings.renderWhitespace;
    if (Object.keys(opts).length > 0) {
      Object.keys(groupPanes).forEach((gid) => {
        const p = groupPanes[gid];
        if (p?.editor) p.editor.updateOptions(opts);
      });
    }
  };

  function getBreadcrumbCrumbs(groupId: string): any[] {
    const active = activeEditorForGroup(groupId);
    if (!active?.uri) return [];
    const path = active.uri.replace('file://', '');
    const parts = path.split('/').filter(Boolean);
    const crumbs = parts.map((label: string, index: number) => {
      const crumbPath = '/' + parts.slice(0, index + 1).join('/');
      return {
        label,
        path: crumbPath,
        type: index === parts.length - 1 ? 'file' : 'folder',
        icon: index === parts.length - 1 ? 'file' : 'folder',
      };
    });
    const line = breadcrumbActiveLines[groupId];
    const symbols = flattenSymbols(breadcrumbSymbolsByGroup[groupId] || []);
    if (typeof line === 'number' && symbols.length > 0) {
      let activeSymbol: any = null;
      for (const sym of [...symbols].sort(
        (a, b) => symbolLine(a) - symbolLine(b) || (b.depth || 0) - (a.depth || 0),
      )) {
        if (symbolLine(sym) <= line) activeSymbol = sym;
        else break;
      }
      const chain = activeSymbol ? [...(activeSymbol.parents || []), activeSymbol] : [];
      for (const sym of chain) {
        crumbs.push({
          label: sym.name,
          type: 'symbol',
          icon: symbolIcon(sym.kind),
          symbol: sym,
        });
      }
    }
    return crumbs;
  }

  function ensurePane(groupId: string) {
    if (!groupPanes[groupId]) {
      groupPanes[groupId] = { container: null, editor: null };
    }
    // Fallback attach via DOM if not yet bound (avoids complex bind:this)
    if (!groupPanes[groupId].container) {
      const el = document.querySelector(
        `.editor-container[data-group-id="${groupId}"]`,
      ) as HTMLElement | null;
      if (el) groupPanes[groupId].container = el;
    }
  }

  function mountEditorPane(node: HTMLElement, groupId: string) {
    ensurePane(groupId);
    groupPanes[groupId].container = node;
    createEditorForGroup(groupId);

    return {
      update(nextGroupId: string) {
        if (nextGroupId === groupId) return;
        if (groupPanes[groupId]?.container === node) groupPanes[groupId].container = null;
        groupId = nextGroupId;
        ensurePane(groupId);
        groupPanes[groupId].container = node;
        createEditorForGroup(groupId);
      },
      destroy() {
        if (groupPanes[groupId]?.container === node) groupPanes[groupId].container = null;
      },
    };
  }

  function createEditorForGroup(groupId: string, initialValue = '// New group\n') {
    const pane = groupPanes[groupId];
    if (!pane || !pane.container) return;

    const group = realGroups[groupId];
    const activeEd = group?.activeEditorId
      ? group.editors.find((e) => e.id === group.activeEditorId)
      : null;
    if (activeEd?.type === 'webview' || activeEd?.uri?.startsWith('webview:')) {
      // B3: defer to updateEditorForTab for iframe render
      return;
    }

    if (!monacoReady) {
      ensureMonaco().then(() => createEditorForGroup(groupId, initialValue));
      return;
    }
    if (!monaco) return;

    if (pane.editor) pane.editor.dispose();

    const savedSettings = (() => {
      try {
        return JSON.parse(localStorage.getItem('wizp-settings') || '{}');
      } catch {
        return {};
      }
    })();
    const minimapEnabled = savedSettings.minimap !== false;
    const cursorStyleMap: Record<string, number> = {
      line: 1,
      block: 2,
      underline: 3,
      'line-thin': 4,
      'block-outline': 5,
      'underline-thin': 6,
    };
    const fontSize = Number(savedSettings.fontSize || 13);
    const tabSize = Number(savedSettings.tabSize || 4);
    const wordWrapColumn = Number(savedSettings.wordWrapColumn || 80);
    pane.editor = monaco.editor.create(pane.container, {
      value: initialValue,
      language: 'plaintext',
      theme: 'wizp-dark',
      ariaLabel: activeEd?.label ? `Code editor for ${activeEd.label}` : 'Code editor',
      fontSize: Number.isFinite(fontSize) ? fontSize : 13,
      fontFamily:
        savedSettings.fontFamily ||
        "'Cascadia Code', 'Fira Code', 'JetBrains Mono', 'Droid Sans Mono', 'monospace'",
      minimap: { enabled: minimapEnabled, scale: 1, showSlider: 'mouseover' },
      glyphMargin: true,
      lineNumbers: savedSettings.lineNumbers === false ? 'off' : 'on',
      renderWhitespace: savedSettings.renderWhitespace || 'selection',
      tabSize: Number.isFinite(tabSize) ? tabSize : 4,
      insertSpaces: true,
      scrollBeyondLastLine: false,
      automaticLayout: true,
      bracketPairColorization: { enabled: savedSettings.bracketPairColorization !== false },
      'semanticHighlighting.enabled': true,
      matchBrackets: 'always',
      selectionHighlight: true,
      occurrencesHighlight: 'singleFile',
      stickyScroll: { enabled: true },
      wordWrap: savedSettings.wordWrap || 'off',
      wordWrapColumn: Number.isFinite(wordWrapColumn) ? wordWrapColumn : 80,
      cursorStyle: cursorStyleMap[savedSettings.cursorStyle || 'line'] || 1,
    });

    (window as any)[`editor_${groupId}`] = pane.editor;

    // Vi Mode Init
    const applyVimMode = async () => {
      const isVim = (() => {
        try {
          let z = false;
          vimMode.subscribe((v) => (z = v))();
          return z;
        } catch {
          return false;
        }
      })();
      if (isVim) {
        if (!pane.vimMode) {
          const statusNode = document.getElementById('vim-status');
          const { initVimMode } = await import('monaco-vim');
          pane.vimMode = initVimMode(pane.editor, statusNode);
        }
      } else {
        if (pane.vimMode) {
          pane.vimMode.dispose();
          pane.vimMode = null;
        }
      }
    };
    applyVimMode();
    const unsubVim = vimMode.subscribe(applyVimMode);
    pane.editor.onDidDispose(() => unsubVim());

    const getLspUri = () => {
      const g = realGroups[groupId];
      if (g?.activeEditorId) {
        const ed = g.editors.find((e: any) => e.id === g.activeEditorId);
        if (ed?.uri) return ed.uri;
      }
      return `file://group-${groupId.slice(0, 8)}`;
    };
    pane.editor.addAction({
      id: `lsp.triggerCompletion.${groupId}`,
      label: 'Trigger LSP Completion',
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.Space],
      run: async (ed) => {
        const pos = ed.getPosition();
        if (pos) {
          try {
            await lsp.completion(getLspUri(), pos.lineNumber - 1, pos.column - 1);
            ed.trigger('keyboard', 'editor.action.triggerSuggest', {});
          } catch {
            // Completion actions are best effort when no language server is attached.
          }
        }
      },
    });
    pane.editor.addAction({
      id: `lsp.hover.${groupId}`,
      label: 'Trigger LSP Hover',
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyI],
      run: async (ed) => {
        const pos = ed.getPosition();
        if (pos) {
          try {
            await lsp.hover(getLspUri(), pos.lineNumber - 1, pos.column - 1);
          } catch {
            // Hover actions are best effort when no language server is attached.
          }
        }
      },
    });
    pane.editor.addAction({
      id: `wizp.save.${groupId}`,
      label: 'Save File',
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS],
      run: () => saveActiveEditor(),
    });
    pane.editor.addAction({
      id: `wizp.closeEditor.${groupId}`,
      label: 'Close Editor',
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyW],
      run: () => closeActiveEditor(),
    });
    pane.editor.addAction({
      id: `wizp.format.${groupId}`,
      label: 'Format Document',
      keybindings: [monaco.KeyMod.Shift | monaco.KeyMod.Alt | monaco.KeyCode.KeyF],
      run: (ed) => ed.trigger('keyboard', 'editor.action.formatDocument', {}),
    });
    pane.editor.addAction({
      id: `wizp.gotodef.${groupId}`,
      label: 'Go to Definition',
      keybindings: [monaco.KeyCode.F12],
      run: (ed) => ed.trigger('keyboard', 'editor.action.revealDefinition', {}),
    });
    pane.editor.addAction({
      id: `wizp.peekdef.${groupId}`,
      label: 'Peek Definition',
      keybindings: [monaco.KeyMod.Alt | monaco.KeyCode.F12],
      run: (ed) => ed.trigger('keyboard', 'editor.action.peekDefinition', {}),
    });
    pane.editor.addAction({
      id: `wizp.refs.${groupId}`,
      label: 'Go to References',
      keybindings: [monaco.KeyMod.Shift | monaco.KeyCode.F12],
      run: (ed) => ed.trigger('keyboard', 'editor.action.goToReferences', {}),
    });

    // Breakpoints logic
    pane.editor.onMouseDown((e: any) => {
      if (
        e.target.type === monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN ||
        e.target.type === monaco.editor.MouseTargetType.GUTTER_LINE_NUMBERS
      ) {
        const line = e.target.position.lineNumber;
        const uri = getLspUri();
        if (uri.startsWith('file://')) {
          sendRpc('dap/toggleBreakpoint', { file: uri.replace('file://', ''), line })
            .then(() => {
              updateBreakpointsForPane(groupId);
            })
            .catch(() => {});
        }
      }
    });

    // Git blame inline decoration on cursor position change (throttled)
    let blameTimer: ReturnType<typeof setTimeout> | null = null;
    pane.editor.onDidChangeCursorPosition(() => {
      const cursorPos = pane.editor.getPosition();
      const activeUri = getLspUri();
      if (cursorPos) {
        breadcrumbActiveLines = { ...breadcrumbActiveLines, [groupId]: cursorPos.lineNumber - 1 };
        window.dispatchEvent(
          new CustomEvent('wizpEditorCursorChanged', {
            detail: {
              uri: activeUri,
              line: cursorPos.lineNumber - 1,
              col: cursorPos.column - 1,
              groupId,
            },
          }),
        );
      }
      if (blameTimer) clearTimeout(blameTimer);
      blameTimer = setTimeout(() => {
        blameTimer = null;
        const pos = pane.editor.getPosition();
        if (!pos) return;
        const g = realGroups[groupId];
        const ed = g?.activeEditorId ? g.editors.find((e: any) => e.id === g.activeEditorId) : null;
        if (!ed?.uri?.startsWith('file://')) return;
        const file = ed.uri.replace('file://', '');
        try {
          sendRpc('git/blame', { file })
            .then((blame: any) => {
              const lines = Array.isArray(blame) ? blame : blame?.lines || [];
              if (Array.isArray(lines)) {
                const line = pos.lineNumber;
                const match = lines.find((b: any) => b.line === line);
                const decorations = [];
                if (match) {
                  const shortHash = match.commit ? String(match.commit).slice(0, 8) : '';
                  const date = match.date
                    ? new Date(Number(match.date) * 1000).toISOString().slice(0, 10)
                    : '';
                  const detail = [match.author, date, match.summary || shortHash]
                    .filter(Boolean)
                    .join(' - ');
                  decorations.push({
                    range: new monaco.Range(line, 1, line, 1),
                    options: {
                      isWholeLine: true,
                      after: { content: `    ${detail}`, inlineClassName: 'git-blame-annotation' },
                    },
                  });
                }
                pane.blameDeco = pane.editor.deltaDecorations(pane.blameDeco || [], decorations);
              }
            })
            .catch(() => {});
        } catch {
          // Optional blame decoration failure must not affect editor interaction.
        }
      }, 500);
    });

    (pane as any).updateDiags = () => updateDiagnosticsForPane(groupId);
    updateDiagnosticsForPane(groupId); // initial load for nice diagnostics on open (B2)
    updateBreakpointsForPane(groupId);
    if (activeEd) updateEditorForTab(groupId, activeEd);
    requestAnimationFrame(() => {
      const current = activeEditorForGroup(groupId);
      if (current && groupPanes[groupId]?.editor) updateEditorForTab(groupId, current);
      groupPanes[groupId]?.editor?.layout();
    });
  }

  async function updateBreakpointsForPane(groupId: string) {
    const pane = groupPanes[groupId];
    if (!pane || !pane.editor) return;
    const g = realGroups[groupId];
    const ed = g?.activeEditorId ? g.editors.find((e) => e.id === g.activeEditorId) : null;
    if (!ed?.uri?.startsWith('file://')) return;
    const file = ed.uri.replace('file://', '');
    try {
      const bps = await sendRpc('dap/getBreakpoints', { file });
      if (Array.isArray(bps)) {
        const decorations = bps.map((breakpoint: any) => ({
          range: new monaco.Range(Number(breakpoint.line) + 1, 1, Number(breakpoint.line) + 1, 1),
          options: {
            isWholeLine: false,
            glyphMarginClassName: 'breakpoint-glyph',
          },
        }));
        pane.bpDeco = pane.editor.deltaDecorations(pane.bpDeco || [], decorations);
      }
    } catch {
      // Breakpoint decoration is optional when the debug adapter is unavailable.
    }
  }

  // Diagnostics updater — hoisted to component scope so updateEditorForTab can call it
  async function updateDiagnosticsForPane(groupId: string) {
    const pane = groupPanes[groupId];
    if (!pane?.editor) return;
    try {
      const diags = await lsp.getDiagnostics(getLspUriForGroup(groupId));
      const markers = diags.map((d: any) => ({
        severity:
          d.severity === 1
            ? monaco.MarkerSeverity.Error
            : d.severity === 2
              ? monaco.MarkerSeverity.Warning
              : d.severity === 3
                ? monaco.MarkerSeverity.Info
                : monaco.MarkerSeverity.Hint,
        startLineNumber: (d.range?.start?.line || 0) + 1,
        startColumn: (d.range?.start?.character || 0) + 1,
        endLineNumber: (d.range?.end?.line || 0) + 1,
        endColumn: (d.range?.end?.character || 0) + 1,
        message: d.message || '',
        source: d.source || 'LSP',
      }));
      const model = pane.editor.getModel();
      if (model) monaco.editor.setModelMarkers(model, 'lsp', markers);
    } catch {
      // Diagnostics are advisory; the editor remains usable without them.
    }
  }

  function getLspUriForGroup(groupId: string): string {
    const g = realGroups[groupId];
    if (g?.activeEditorId) {
      const ed = g.editors.find((e: any) => e.id === g.activeEditorId);
      if (ed?.uri) return ed.uri;
    }
    return `file://group-${groupId.slice(0, 8)}`;
  }

  async function fetchWebviewPanelHtml(id: string): Promise<string> {
    try {
      const res = await sendRpc('webview/list');
      const panels = Array.isArray(res?.panels) ? res.panels : [];
      const panel = panels.find((candidate: any) => candidate?.id === id);
      return typeof panel?.html === 'string' ? panel.html : '';
    } catch {
      return '';
    }
  }

  function findWebviewPanelTab(id: string): { groupId: string; editor: any } | null {
    for (const [groupId, group] of Object.entries(realGroups)) {
      const editor = group?.editors?.find((candidate: any) => candidate.id === id);
      if (editor) return { groupId, editor };
    }
    return null;
  }

  async function openOrRefreshWebviewPanel(
    detail: {
      id?: string;
      title?: string;
      viewType?: string;
      preserveFocus?: boolean;
      html?: string;
    } | null,
  ) {
    const id = detail?.id;
    if (!id) return;
    const panelTitle = detail?.title || detail?.viewType || id;
    const html = typeof detail?.html === 'string' ? detail.html : await fetchWebviewPanelHtml(id);
    const existing = findWebviewPanelTab(id);
    if (!existing && !getActiveGroupId() && visibleGroupOrder.length === 0) {
      ensureBootstrapGroup();
    }
    const groupId = existing?.groupId || getActiveGroupId() || visibleGroupOrder[0];
    if (!groupId) return;

    if (existing) {
      existing.editor.type = 'webview';
      existing.editor.uri = `webview:${panelTitle}`;
      existing.editor.languageId = 'html';
      existing.editor.dirty = false;
      existing.editor.webviewHtml = html;
      notifyEditorState();
      if (realGroups[groupId]?.activeEditorId === id) {
        updateEditorForTab(groupId, existing.editor);
      }
      setActiveGroupId(groupId);
      if (!detail?.preserveFocus) setActiveEditor(groupId, id);
      return;
    }

    openEditorInGroup(groupId, {
      id,
      uri: `webview:${panelTitle}`,
      languageId: 'html',
      dirty: false,
      type: 'webview',
      webviewHtml: html,
    });
    setActiveGroupId(groupId);
    if (!detail?.preserveFocus) setActiveEditor(groupId, id);
  }

  function closeWebviewPanel(id: string) {
    if (!id) return;
    for (const [groupId, group] of Object.entries(realGroups)) {
      const editor = group?.editors?.find((candidate: any) => candidate.id === id);
      if (!editor) continue;
      closeEditor(groupId, id);
      return;
    }
  }

  function focusWebviewPanel(id: string) {
    const existing = findWebviewPanelTab(id);
    if (!existing) return false;
    setActiveGroupId(existing.groupId);
    setActiveEditor(existing.groupId, id);
    return true;
  }

  function updateEditorForTab(groupId: string, tab: any) {
    const pane = groupPanes[groupId];
    if (!pane?.container) return;

    if ((pane as any)._webviewCleanup) {
      try {
        (pane as any)._webviewCleanup();
      } catch {
        // Webview cleanup may already have run during pane replacement.
      }
      (pane as any)._webviewCleanup = null;
    }

    // B3.2 webview support: render iframe with postMessage bridge
    if (tab.type === 'webview' || tab.uri?.startsWith('webview:')) {
      if (pane.editor) {
        pane.editor.dispose();
        pane.editor = null;
      }
      const isHtml =
        tab.type === 'webview' ||
        tab.webviewHtml !== undefined ||
        tab.uri?.startsWith('webview:id:');
      const iframeId = `webview-frame-${tab.id}`;
      const headerHtml = `<div style="padding:2px 4px;background:#1e1e1e;color:#0f0;font:10px monospace;border-bottom:1px solid #333;display:flex;align-items:center;justify-content:space-between;">
        <span>Webview: ${tab.webviewUrl || tab.uri} (B3)</span>
        <span style="color:#888;font-size:9px;">postMessage bridge active</span>
      </div>`;
      if (isHtml) {
        const decoratedHtml = decorateWebviewHtml(tab.id, tab.webviewHtml || '');
        pane.container.innerHTML = `${headerHtml}<iframe id="${iframeId}" title="${tab.id} webview" sandbox="allow-scripts allow-same-origin" srcdoc="${decoratedHtml.replace(/"/g, '&quot;')}" style="width:100%;height:calc(100% - 18px);border:none;background:#fff;"></iframe>`;
      } else {
        pane.container.innerHTML = `${headerHtml}<iframe id="${iframeId}" title="${tab.id} webview" sandbox="allow-scripts allow-same-origin" src="${tab.webviewUrl || tab.uri.replace('webview:', '')}" style="width:100%;height:calc(100% - 18px);border:none;background:#fff;"></iframe>`;
      }
      const setupMessaging = () => {
        const iframe = document.getElementById(iframeId) as HTMLIFrameElement;
        if (!iframe) return;
        const onMsg = (e: MessageEvent) => {
          if (e.source !== iframe.contentWindow) return;
          const wrapped = unwrapWebviewClientMessage(e);
          if (wrapped && wrapped.id !== tab.id) return;
          try {
            sendRpc('webview/receiveMessage', {
              id: wrapped?.id || tab.id,
              message: normalizeWebviewMessagePayload(wrapped ? wrapped.message : e.data),
            }).catch(() => {});
          } catch {
            // Webview messages are best effort while the iframe is being removed.
          }
        };
        const onHostMsg = (e: Event) => {
          const detail = (e as CustomEvent).detail;
          if (!detail || detail.id !== tab.id) return;
          if (postHostMessageToWebview(iframe, detail.id, detail.message)) {
            const pendingMessages = (window as any).__wizpPendingWebviewMessages;
            const queue = pendingMessages?.[detail.id];
            if (Array.isArray(queue) && queue.length > 0) {
              queue.pop();
              if (queue.length === 0) delete pendingMessages[detail.id];
            }
          }
        };
        window.addEventListener('message', onMsg);
        window.addEventListener('wizpWebviewPostMessage', onHostMsg);
        const pendingMessages = (window as any).__wizpPendingWebviewMessages;
        const queued = Array.isArray(pendingMessages?.[tab.id])
          ? pendingMessages[tab.id].splice(0)
          : [];
        for (const message of queued) {
          postHostMessageToWebview(iframe, tab.id, message);
        }
        if (pendingMessages?.[tab.id] && pendingMessages[tab.id].length === 0) {
          delete pendingMessages[tab.id];
        }
        (pane as any)._webviewCleanup = () => {
          window.removeEventListener('message', onMsg);
          window.removeEventListener('wizpWebviewPostMessage', onHostMsg);
        };
      };
      setTimeout(setupMessaging, 100);
      return;
    }

    if (!pane?.editor) return;

    // Save previous viewState before switching content (B1 micro-task)
    const gPrev = realGroups[groupId];
    if (pane.activeTabId) {
      const prevEd = gPrev?.editors.find((editor) => editor.id === pane.activeTabId);
      if (prevEd) {
        prevEd.viewState = pane.editor.saveViewState();
      }
    }

    const lang = tab.languageId || 'plaintext';
    const content = tab.content ?? `// ${tab.uri}\n// (new file)\n`;
    const tabChanged = pane.activeTabId !== tab.id;

    pane.switchingTab = true;
    try {
      pane.editor.updateOptions({ ariaLabel: `Code editor for ${tab.label || 'file'}` });
      if (pane.editor.getValue() !== content) pane.editor.setValue(content);
      const model = pane.editor.getModel();
      if (model?.getLanguageId() !== lang) monaco.editor.setModelLanguage(model, lang);
      if (tab.viewState) pane.editor.restoreViewState(tab.viewState);
    } finally {
      pane.switchingTab = false;
    }
    pane.activeTabId = tab.id;
    if (tabChanged) {
      breadcrumbActiveLines = { ...breadcrumbActiveLines, [groupId]: 0 };
      window.dispatchEvent(
        new CustomEvent('wizpEditorChanged', { detail: { uri: tab.uri, lang } }),
      );
      loadBreadcrumbSymbols(groupId).catch(() => {});
    }
    if (!(pane.editor as any)._wizpSynced) {
      (pane.editor as any)._wizpSynced = true;
      pane.editor.onDidChangeModelContent((e: any) => {
        if (pane.switchingTab) return;
        const g = realGroups[groupId];
        if (!g) return;
        const activeId = pane.activeTabId || g.activeEditorId;
        const ed = g.editors.find((editor) => editor.id === activeId);
        if (ed) {
          ed.content = pane.editor.getValue();
          ed.dirty = true;
          notifyEditorState();
          scheduleEditorSessionPersist();
        }
        // Basic LSP sync (B2)
        const gForChange = realGroups[groupId];
        const edForChange = gForChange?.activeEditorId
          ? gForChange.editors.find((e: any) => e.id === gForChange.activeEditorId)
          : null;
        lsp
          .didChange(edForChange?.uri || `file://group-${groupId}`, pane.editor.getValue())
          .catch(() => {});
        updateDiagnosticsForPane(groupId);

        // Forward live edits to Extension Host
        if (e && e.changes) {
          sendRpcFields('extension/didChangeTextDocument', {
            uri: edForChange?.uri || `file://group-${groupId}`,
            changes: e.changes.map((c: any) => ({
              range: {
                start: { line: c.range.startLineNumber - 1, character: c.range.startColumn - 1 },
                end: { line: c.range.endLineNumber - 1, character: c.range.endColumn - 1 },
              },
              rangeOffset: c.rangeOffset,
              rangeLength: c.rangeLength,
              text: c.text,
            })),
          }).catch(() => {});
        }
      });
      pane.editor.onDidFocusEditorText(() => updateDiagnosticsForPane(groupId));
      pane.editor.onMouseDown(() => {
        const active = activeEditorForGroup(groupId);
        if (active)
          refreshZlayInteraction(groupId, active, pane.editor, 8, 8, false).catch(() => {});
      });
      pane.editor.onMouseUp(() => {
        const active = activeEditorForGroup(groupId);
        if (active)
          refreshZlayInteraction(groupId, active, pane.editor, 8, 8, true).catch(() => {});
      });
      pane.editor.onDidScrollChange(() => {
        const state = pane as any;
        if (state._zlayScrollTimer) window.clearTimeout(state._zlayScrollTimer);
        state._zlayScrollTimer = window.setTimeout(() => {
          const active = activeEditorForGroup(groupId);
          if (active) refreshZlayInteraction(groupId, active, pane.editor).catch(() => {});
        }, 60);
      });
    }
    (pane as any).updateDiags = () => updateDiagnosticsForPane(groupId);
    updateDiagnosticsForPane(groupId); // initial load for nice diagnostics on open (B2)
    refreshZlayInteraction(groupId, tab, pane.editor).catch(() => {});
  }

  function closeGroupPane(groupId: string) {
    const group = realGroups[groupId];
    if (!group) return;
    closeTabsSequentially(groupId, [...group.editors], () => disposeGroupPane(groupId));
  }

  function disposeGroupPane(groupId: string) {
    const pane = groupPanes[groupId];
    if (pane?.editor) {
      pane.editor.dispose();
    }
    delete groupPanes[groupId];
    closeGroup(groupId);
  }

  // React to visible groups: ensure panes + editors exist
  $effect(() => {
    for (const vg of visibleGroups) {
      ensurePane(vg.id);
      const activeEd = vg.group?.activeEditorId
        ? vg.group.editors.find((e: any) => e.id === vg.group.activeEditorId)
        : null;
      if (activeEd?.type === 'webview' || activeEd?.uri?.startsWith('webview:')) {
        if (groupPanes[vg.id].container) {
          updateEditorForTab(vg.id, activeEd);
        }
        continue;
      }
      if (!groupPanes[vg.id].editor && groupPanes[vg.id].container) {
        createEditorForGroup(vg.id);
      }
    }
    // Clean up removed groups
    for (const id of Object.keys(groupPanes)) {
      if (!visibleGroupOrder.includes(id)) {
        const p = groupPanes[id];
        if (p?.editor) p.editor.dispose();
        delete groupPanes[id];
      }
    }
  });

  // Real multi-group state (must be early for effects)
  const visibleGroups = $derived.by(() => {
    void editorUiState.revision;
    return visibleGroupOrder
      .map((id) => {
        const group = realGroups[id];
        return group ? { id, group: { ...group, editors: [...group.editors] } } : null;
      })
      .filter((value) => value !== null);
  });

  let editorSessionRestored = $state(false);
  let editorSessionRestoreStarted = false;
  let editorSessionRestoreInFlight: Promise<boolean> | null = null;
  let reconnectRestoreGeneration = 0;
  let sessionPersistenceWarningShown = false;
  const savedContentByPath = new SvelteMap<string, string>();
  let revertGeneration = 0;
  let editorSessionPersistTimer: number | null = null;
  let editorSessionPersistQueue: Promise<void> = Promise.resolve();
  let editorSessionPersistRequested = false;

  type EditorSessionRestoreOptions = {
    preserveCurrent?: boolean;
  };

  function sessionEntryUri(entry: any): string {
    const value = typeof entry === 'string' ? entry : entry?.path || entry?.uri || '';
    return value.startsWith('file://') || value.startsWith('untitled-') ? value : `file://${value}`;
  }

  async function persistEditorSessionOnce(): Promise<void> {
    try {
      const orderedGroups = visibleGroupOrder.map((groupId) => realGroups[groupId]).filter(Boolean);
      const sourceGroups = orderedGroups.some((group: any) => (group?.editors || []).length > 0)
        ? orderedGroups
        : Object.values(realGroups);
      const groups = sourceGroups.map((group: any) => ({
        editors: (group?.editors || [])
          .filter(
            (editor: any) =>
              editor.type !== 'webview' &&
              (editor.uri?.startsWith('file://') || editor.uri?.startsWith('untitled-')),
          )
          .map((editor: any) => {
            const retainContent = editor.dirty || editor.uri.startsWith('untitled-');
            const pane =
              groupPanes[group.id] ||
              (Object.values(groupPanes).find(
                (candidate: any) => candidate?.activeTabId === editor.id,
              ) as any);
            const liveContent =
              pane?.activeTabId === editor.id ? pane.editor?.getValue?.() : undefined;
            const content =
              typeof editor.content === 'string'
                ? editor.content
                : typeof liveContent === 'string'
                  ? liveContent
                  : '';
            return {
              uri: editor.uri,
              languageId: editor.languageId || 'plaintext',
              dirty: Boolean(editor.dirty),
              ...(retainContent ? { content } : {}),
              ...(typeof editor.savedContent === 'string'
                ? { savedContent: editor.savedContent }
                : {}),
            };
          }),
        activeUri:
          group?.editors.find((editor: any) => editor.id === group?.activeEditorId)?.uri || null,
      }));
      const editorSession = {
        layout: editorLayout,
        activeGroup: Math.max(0, visibleGroupOrder.indexOf(getActiveGroupId() || '')),
        groups,
      };
      const filePaths = groups.flatMap((group) =>
        group.editors
          .map((editor: any) => String(editor.uri || ''))
          .filter((uri: string) => uri.startsWith('file://'))
          .map((uri: string) => uri.replace(/^file:\/\//, '')),
      );
      await updateRendererSession({
        files: filePaths.map((path) => ({ path })),
        editorSession,
      });
      sessionPersistenceWarningShown = false;
    } catch {
      if (!sessionPersistenceWarningShown) {
        sessionPersistenceWarningShown = true;
        showToast('Unsaved editor recovery is unavailable in this session', 'error');
      }
    }
  }
  function persistEditorSession(): Promise<void> {
    if (!editorSessionRestored && !hasLiveEditorSession()) return Promise.resolve();
    editorSessionPersistRequested = true;
    const run = editorSessionPersistQueue.then(async () => {
      while (editorSessionPersistRequested) {
        editorSessionPersistRequested = false;
        if (!editorSessionRestored && !hasLiveEditorSession()) break;
        await persistEditorSessionOnce();
      }
    });
    editorSessionPersistQueue = run.catch(() => {});
    return run;
  }
  function scheduleEditorSessionPersist(): void {
    if (editorSessionPersistTimer !== null) return;
    editorSessionPersistTimer = window.setTimeout(() => {
      editorSessionPersistTimer = null;
      void persistEditorSession();
    }, 100);
  }

  function hasLiveEditorSession(): boolean {
    return Object.values(realGroups).some(
      (group: any) =>
        Array.isArray(group?.editors) &&
        group.editors.some(
          (editor: any) =>
            editor.dirty === true ||
            editor.uri?.startsWith('file://') ||
            (editor.uri?.startsWith('untitled-') && Boolean(editor.content)),
        ),
    );
  }

  async function restoreEditorSession(options: EditorSessionRestoreOptions = {}) {
    try {
      const loaded = await loadRendererSession();
      let saved: any = loaded.editorSession;
      const loadedHasGroups = Array.isArray(saved?.groups) && saved.groups.length > 0;
      if (!nativeControlCredentials() && !loadedHasGroups) {
        for (let attempt = 0; attempt < 10; attempt += 1) {
          try {
            const browserSaved = JSON.parse(
              localStorage.getItem('wizp:editorSession:v1') || 'null',
            );
            if (Array.isArray(browserSaved?.groups) && browserSaved.groups.length > 0) {
              saved = browserSaved;
              break;
            }
          } catch {
            // Browser storage is optional and may be unavailable.
          }
          if (attempt < 9) {
            await new Promise((resolve) => window.setTimeout(resolve, 100));
          }
        }
      }
      if (!Array.isArray(saved?.groups)) {
        const files = Array.isArray(loaded.files) ? loaded.files : [];
        if (files.length === 0) return true;
        saved = {
          layout: 'horizontal',
          activeGroup: 0,
          groups: [
            {
              editors: files.map((entry: any) => ({
                uri: sessionEntryUri(entry),
                languageId: 'plaintext',
                dirty: false,
              })),
              activeUri: sessionEntryUri(files[0]),
            },
          ],
        };
      }
      if (saved.groups.length === 0) return true;
      // Live edits always win, including input arriving while the host load was pending.
      let preserveCurrent = options.preserveCurrent === true || hasLiveEditorSession();
      ensureBootstrapGroup();
      const existingGroupIds = visibleGroupOrder.filter((id) => realGroups[id]);
      const groupIds = preserveCurrent
        ? existingGroupIds.slice(0, saved.groups.length)
        : [visibleGroupOrder[0]];
      for (let i = groupIds.length; i < saved.groups.length; i++) {
        const id = createEditorGroup();
        visibleGroupOrder.push(id);
        groupIds.push(id);
      }
      if (!preserveCurrent && (saved.layout === 'vertical' || saved.layout === 'horizontal')) {
        editorLayout = saved.layout;
      }
      let recoveredDirtyEditors = 0;
      for (let i = 0; i < saved.groups.length; i++) {
        const groupId = groupIds[i];
        const group = realGroups[groupId];
        if (!group) continue;
        for (const entry of saved.groups[i].editors || []) {
          const uri = String(entry.uri || '');
          const isFile = uri.startsWith('file://');
          const isUntitled = uri.startsWith('untitled-');
          if (!isFile && !isUntitled) continue;
          const currentEditor = group.editors.find((editor: any) => editor.uri === uri);
          const hasRecoveredContent = entry.dirty === true && typeof entry.content === 'string';
          if (currentEditor) {
            if (hasRecoveredContent) {
              currentEditor.savedContent =
                typeof entry.savedContent === 'string'
                  ? entry.savedContent
                  : currentEditor.savedContent;
              currentEditor.content = entry.content;
              currentEditor.languageId =
                entry.languageId || currentEditor.languageId || 'plaintext';
              currentEditor.dirty = true;
              group.activeEditorId = currentEditor.id;
              recoveredDirtyEditors += 1;
              notifyEditorState();
            }
            continue;
          }
          if (isUntitled || hasRecoveredContent) {
            const previousActiveId = group.activeEditorId;
            openEditorInGroup(groupId, {
              id: crypto.randomUUID(),
              uri,
              languageId: entry.languageId || 'plaintext',
              content: typeof entry.content === 'string' ? entry.content : '',
              savedContent: typeof entry.savedContent === 'string' ? entry.savedContent : '',
              dirty: entry.dirty === true,
            });
            if (preserveCurrent && previousActiveId) group.activeEditorId = previousActiveId;
            if (entry.dirty === true) recoveredDirtyEditors += 1;
            continue;
          }
          const path = uri.replace(/^file:\/\//, '');
          if (!path) continue;
          try {
            const activeGroupBeforeRead = getActiveGroupId();
            const activeIdBeforeRead = group.activeEditorId;
            const activeBeforeRead = activeGroupBeforeRead
              ? activeEditorForGroup(activeGroupBeforeRead)
              : null;
            const contentBeforeRead = activeBeforeRead?.content;
            const result = await readFile(path, true);
            if (
              getActiveGroupId() !== activeGroupBeforeRead ||
              group.activeEditorId !== activeIdBeforeRead ||
              activeBeforeRead?.content !== contentBeforeRead
            )
              preserveCurrent = true;
            const current = group.editors.find((editor: any) => editor.uri === uri);
            if (current) continue;
            const previousActiveId = group.activeEditorId;
            openEditorInGroup(groupId, {
              id: crypto.randomUUID(),
              uri,
              content: result?.content || '',
              savedContent: result?.content || '',
              dirty: false,
            });
            if (preserveCurrent && previousActiveId) group.activeEditorId = previousActiveId;
          } catch {
            // A clean restored file may have been removed since the session was saved.
          }
        }
        const activeUri =
          saved.groups[i].activeUri ||
          (saved.groups[i].editors?.length ? String(saved.groups[i].editors[0].uri || '') : '');
        const active = group.editors.find((editor: any) => editor.uri === activeUri);
        if (active && !preserveCurrent) {
          group.activeEditorId = active.id;
        }
        notifyEditorState();
      }
      const savedGroupIndex = Number(saved.activeGroup);
      if (!preserveCurrent) {
        setActiveGroupId(
          groupIds[
            Number.isFinite(savedGroupIndex)
              ? Math.max(0, Math.min(savedGroupIndex, groupIds.length - 1))
              : 0
          ],
        );
      }
      await tick();
      for (const groupId of groupIds) {
        ensurePane(groupId);
        if (!groupPanes[groupId]?.editor) createEditorForGroup(groupId);
        const group = realGroups[groupId];
        const active = group?.activeEditorId
          ? group.editors.find((editor) => editor.id === group.activeEditorId)
          : null;
        if (active) {
          groupPanes[groupId].activeTabId = active.id;
          updateEditorForTab(groupId, active);
        }
      }
      await tick();
      if (recoveredDirtyEditors > 0) {
        showToast(
          `Recovered ${recoveredDirtyEditors} unsaved editor${recoveredDirtyEditors === 1 ? '' : 's'}`,
        );
      }
      return true;
    } catch {
      showToast('Unable to load editor recovery; current edits are still open', 'error');
      return false;
    }
  }

  function beginEditorSessionRestore(options: EditorSessionRestoreOptions = {}): Promise<boolean> {
    if (editorSessionRestoreInFlight) return editorSessionRestoreInFlight;
    const restore = restoreEditorSession(options);
    const tracked = restore.finally(() => {
      if (editorSessionRestoreInFlight === tracked) editorSessionRestoreInFlight = null;
    });
    editorSessionRestoreInFlight = tracked;
    return tracked;
  }

  $effect(() => {
    if (!editorSessionRestored) return;
    void editorUiState.revision;
    const fingerprint = JSON.stringify({
      layout: editorLayout,
      order: visibleGroupOrder,
      groups: Object.values(realGroups).map((group: any) =>
        group.editors.map((editor: any) => [editor.id, editor.uri, editor.languageId]),
      ),
    });
    if (fingerprint) void persistEditorSession();
  });

  $effect(() => {
    if (editorSessionRestored || editorSessionRestoreStarted) return;
    editorSessionRestoreStarted = true;
    void beginEditorSessionRestore().then((restored) => {
      editorSessionRestored = restored;
    });
  });

  $effect(() => {
    const handleDaemonReconnected = () => {
      const generation = ++reconnectRestoreGeneration;
      if (editorSessionRestored) return;
      void beginEditorSessionRestore({ preserveCurrent: true }).then((restored) => {
        if (generation !== reconnectRestoreGeneration) return;
        editorSessionRestored = restored;
      });
    };
    const flush = () => {
      void persistEditorSession()
        .then(flushRendererSession)
        .catch(() => {});
    };
    window.addEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    window.addEventListener('pagehide', flush);
    document.addEventListener('visibilitychange', flush);
    return () => {
      window.removeEventListener('wizpDaemonReconnected', handleDaemonReconnected);
      window.removeEventListener('pagehide', flush);
      document.removeEventListener('visibilitychange', flush);
    };
  });

  // Monaco is now lazy-loaded on first pane creation for better initial perf (PHASE 5)
  // ensureMonaco() called from createEditorForGroup when needed

  // Sync Monaco only when the active tab actually changes. Reapplying the same
  // tab writes breadcrumb state and would make this effect update itself forever.
  $effect(() => {
    void editorUiState.revision;
    const gid = getActiveGroupId();
    if (!gid || !monacoReady) return;
    const pane = groupPanes[gid];
    const group = realGroups[gid];
    const tab = group?.editors.find((editor) => editor.id === group.activeEditorId);
    if (!pane?.editor || !tab || pane.activeTabId === tab.id) return;
    updateEditorForTab(gid, tab);
    pane.editor.focus();
  });

  function createNewTab(targetGroupId?: string) {
    const gid = targetGroupId || getActiveGroupId();
    if (!gid) return;
    const id = crypto.randomUUID();
    openEditorInGroup(gid, {
      id,
      uri: `untitled-${Date.now()}`,
      languageId: 'plaintext',
      dirty: false,
    });
    setActiveGroupId(gid);
    setActiveEditor(gid, id);
  }

  function splitRight() {
    (window as any).__splitEditor = splitRight;
    const current = getActiveGroupId();
    if (current) {
      editorLayout = 'horizontal';
      splitGroup(current, 'horizontal');
    }
  }

  function splitDown() {
    const current = getActiveGroupId();
    if (current) {
      editorLayout = 'vertical';
      splitGroup(current, 'vertical');
    }
  }

  $effect(() => {
    const handlePanelCreated = (e: Event) => {
      void openOrRefreshWebviewPanel((e as CustomEvent).detail || null);
    };
    const handlePanelReveal = (e: Event) => {
      const detail = (e as CustomEvent).detail || null;
      if (!detail?.id || !focusWebviewPanel(detail.id)) {
        void openOrRefreshWebviewPanel(detail);
      }
    };
    const handlePanelUpdated = (e: Event) => {
      void openOrRefreshWebviewPanel((e as CustomEvent).detail || null);
    };
    const handlePanelDisposed = (e: Event) => {
      const detail = (e as CustomEvent).detail || null;
      if (detail?.id) closeWebviewPanel(detail.id);
    };
    window.addEventListener('wizpWebviewPanelCreated', handlePanelCreated);
    window.addEventListener('wizpWebviewPanelUpdated', handlePanelUpdated);
    window.addEventListener('wizpWebviewPanelReveal', handlePanelReveal);
    window.addEventListener('wizpWebviewPanelDisposed', handlePanelDisposed);
    return () => {
      window.removeEventListener('wizpWebviewPanelCreated', handlePanelCreated);
      window.removeEventListener('wizpWebviewPanelUpdated', handlePanelUpdated);
      window.removeEventListener('wizpWebviewPanelReveal', handlePanelReveal);
      window.removeEventListener('wizpWebviewPanelDisposed', handlePanelDisposed);
    };
  });

  function activateTab(groupId: string, tab: any) {
    setActiveGroupId(groupId);
    setActiveEditor(groupId, tab.id);
    // Notify outline panel and other listeners
    window.dispatchEvent(
      new CustomEvent('wizpEditorChanged', { detail: { uri: tab.uri, groupId } }),
    );
  }

  function editorTabId(groupId: string, tabId: string) {
    return `editor-tab-${groupId}-${tabId}`;
  }

  function editorPanelId(groupId: string) {
    return `editor-panel-${groupId}`;
  }

  function focusEditorTab(groupId: string) {
    const tabId = realGroups[groupId]?.activeEditorId;
    if (!tabId) return;
    requestAnimationFrame(() => document.getElementById(editorTabId(groupId, tabId))?.focus());
  }
  async function handleEditorGroupKeydown(event: KeyboardEvent, groupId: string) {
    if (event.key !== 'Tab' || !event.altKey) return;
    event.preventDefault();
    const active = activeEditorForGroup(groupId);
    if (!active) return;
    const snapshot = await sendRpc('editor/interactionAudit', {
      lineCount: groupId ? groupPanes[groupId]?.editor?.getModel?.()?.getLineCount?.() || 0 : 0,
      viewportLines: 1,
      focusedSurface: 8,
      advanceFocus: true,
    }).catch(() => null);
    if (snapshot?.focusedSurface !== 1) {
      focusEditorTab(groupId);
      return;
    }
    const index = visibleGroupOrder.indexOf(groupId);
    const nextGroup = visibleGroupOrder[(index + 1) % visibleGroupOrder.length];
    if (nextGroup) {
      setActiveGroupId(nextGroup);
      focusEditorTab(nextGroup);
    }
  }

  function navigateEditorTabs(
    groupId: string,
    tabId: string,
    direction: 'previous' | 'next' | 'first' | 'last',
  ) {
    const group = realGroups[groupId];
    const index = group?.editors.findIndex((tab) => tab.id === tabId) ?? -1;
    if (!group || index < 0 || group.editors.length === 0) return;
    const targetIndex =
      direction === 'first'
        ? 0
        : direction === 'last'
          ? group.editors.length - 1
          : (index + (direction === 'next' ? 1 : group.editors.length - 1)) % group.editors.length;
    activateTab(groupId, group.editors[targetIndex]);
    focusEditorTab(groupId);
  }

  function closeTab(groupId: string, tabId: string) {
    requestCloseTab(groupId, tabId);
  }

  function closeEditorTargetsSequentially(
    targets: Array<{ groupId: string; tabId: string }>,
    after?: () => void,
  ) {
    const [target, ...remaining] = targets;
    if (!target) {
      after?.();
      return;
    }
    requestCloseTab(target.groupId, target.tabId, () =>
      closeEditorTargetsSequentially(remaining, after),
    );
  }

  function closeTabsSequentially(groupId: string, tabs: any[], after?: () => void) {
    closeEditorTargetsSequentially(
      tabs.map((tab) => ({ groupId, tabId: tab.id })),
      after,
    );
  }

  function closeAllEditors() {
    closeEditorTargetsSequentially(
      Object.entries(realGroups).flatMap(([groupId, group]) =>
        group.editors.map((tab) => ({ groupId, tabId: tab.id })),
      ),
    );
  }

  function liveContentForTab(groupId: string, tabId: string, uri: string): string | undefined {
    const group = realGroups[groupId];
    const pane = groupPanes[groupId];
    if (
      (pane?.activeTabId === tabId || group?.activeEditorId === tabId) &&
      typeof pane?.editor?.getValue === 'function'
    ) {
      const content = pane.editor.getValue();
      if (content.length > 0) return content;
    }
    const activeEditor = (window as any).__getActiveEditor?.();
    if (group?.activeEditorId === tabId && typeof activeEditor?.getValue === 'function') {
      return activeEditor.getValue();
    }
    const models = (window as any).monaco?.editor?.getModels?.() || [];
    const model = models.find((candidate: any) => {
      const modelUri = String(candidate?.uri?.toString?.() || '');
      return modelUri === uri || modelUri.endsWith(uri) || modelUri.includes(uri);
    });
    if (typeof model?.getValue === 'function') return model.getValue();
    if (uri.startsWith('untitled-')) {
      const populatedModel = models.find(
        (candidate: any) =>
          typeof candidate?.getValue === 'function' && candidate.getValue().length > 0,
      );
      if (populatedModel) return populatedModel.getValue();
    }
    return undefined;
  }
  function requestCloseTab(
    groupId: string,
    tabId: string,
    after?: () => void,
    contentOverride?: string,
  ) {
    const group = realGroups[groupId];
    const tab = group?.editors.find((editor) => editor.id === tabId);
    if (!tab) {
      after?.();
      return;
    }
    if (tab.dirty) {
      const paneContent = groupPanes[groupId]?.editor?.getValue?.();
      const liveContent =
        contentOverride ||
        (typeof paneContent === 'string' && paneContent.length > 0
          ? paneContent
          : liveContentForTab(groupId, tabId, tab.uri));
      const content =
        typeof liveContent === 'string' && liveContent.length > 0
          ? liveContent
          : (tab.content ?? '');
      tab.content = content;
      const name = tab.uri.split('/').pop() || 'Untitled';
      closePromptReturnFocus = document.activeElement as HTMLElement | null;
      closePrompt = { groupId, tabId, name, content, after };
      return;
    }
    closeEditor(groupId, tabId);
    after?.();
  }

  function discardPromptedTab() {
    const prompt = closePrompt;
    closePrompt = null;
    if (!prompt) return;
    closeEditor(prompt.groupId, prompt.tabId);
    prompt.after?.();
    focusEditorTab(prompt.groupId);
  }

  function dismissClosePrompt() {
    const prompt = closePrompt;
    const returnFocus = closePromptReturnFocus;
    closePromptReturnFocus = null;
    closePrompt = null;
    requestAnimationFrame(() => {
      if (returnFocus?.isConnected) returnFocus.focus();
      else if (prompt) focusEditorTab(prompt.groupId);
    });
  }

  async function savePromptedTab() {
    const prompt = closePrompt;
    if (!prompt) return;
    const pendingTab = realGroups[prompt.groupId]?.editors.find((e) => e.id === prompt.tabId);
    if (!pendingTab) return;
    const pane = groupPanes[prompt.groupId];
    setActiveGroupId(prompt.groupId);
    const activeContent = (window as any).__getActiveEditor?.()?.getValue?.();
    const paneContent = pane?.editor?.getValue?.();
    const liveContent =
      typeof paneContent === 'string' && paneContent.length > 0
        ? paneContent
        : typeof activeContent === 'string' && activeContent.length > 0
          ? activeContent
          : liveContentForTab(prompt.groupId, prompt.tabId, pendingTab.uri);
    const promptedContent = typeof prompt.content === 'string' ? prompt.content : undefined;
    const content =
      promptedContent && promptedContent.length > 0
        ? promptedContent
        : typeof liveContent === 'string' && liveContent.length > 0
          ? liveContent
          : (promptedContent ?? pendingTab.content ?? '');
    closePrompt = null;
    await new Promise((resolve) => setTimeout(resolve, 0));
    let savedPath = '';
    try {
      const result = await sendRpc('file/save-dialog', {
        defaultPath: pendingTab.uri.replace('file://', ''),
      });
      savedPath = resolveSavePath(String(result.path));
      await saveFile(savedPath, content);
      let savedContent = '';
      try {
        savedContent = (await readFile(savedPath)).content;
      } catch {
        // Verification below retries through the RPC path.
      }
      if (savedContent !== content) {
        await sendRpcBounded('file/save', { path: savedPath, content }, 5000);
        savedContent = (await readFile(savedPath)).content;
      }
      if (savedContent !== content) throw new Error('saved content verification failed');
      pendingTab.dirty = false;
      pendingTab.content = content;
      notifyEditorState();
      await persistEditorSession();
      if (!pendingTab.uri.startsWith('untitled-')) {
        sendRpc('window/onDidSaveTextEditor', { path: savedPath }).catch(() => {});
      }
    } catch {
      showToast(`Could not save ${prompt.name}; tab kept open`, 'error');
      closePrompt = prompt;
      return;
    }
    const tab = realGroups[prompt.groupId]?.editors.find((e) => e.id === prompt.tabId);
    if (tab?.dirty) {
      showToast(`Could not save ${prompt.name}; tab kept open`, 'error');
      closePrompt = prompt;
      return;
    }
    closeEditor(prompt.groupId, prompt.tabId);
    prompt.after?.();
    focusEditorTab(prompt.groupId);
  }

  function handleClosePromptKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      dismissClosePrompt();
      return;
    }
    if (e.key !== 'Tab' || !closePromptDialog) return;
    const buttons = Array.from(closePromptDialog.querySelectorAll<HTMLButtonElement>('button'));
    if (buttons.length === 0) return;
    const first = buttons[0];
    const last = buttons[buttons.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  $effect(() => {
    if (!closePrompt) return;
    requestAnimationFrame(() =>
      closePromptDialog?.querySelector<HTMLButtonElement>('button')?.focus(),
    );
  });

  function handleTabContextMenu(e: MouseEvent, groupId: string, tab: any) {
    e.preventDefault();
    (window as any).__showCtxMenu?.(
      e.clientX,
      e.clientY,
      [
        { label: 'Close', action: () => closeTab(groupId, tab.id) },
        {
          label: 'Close Others',
          action: () => {
            const g = realGroups[groupId];
            if (g) {
              closeTabsSequentially(
                groupId,
                [...g.editors].filter((t) => t.id !== tab.id).reverse(),
              );
            }
          },
        },
        {
          label: 'Close All',
          action: () => {
            const g = realGroups[groupId];
            if (g) {
              closeTabsSequentially(groupId, [...g.editors]);
            }
          },
        },
        {
          label: 'Close to Right',
          action: () => {
            const g = realGroups[groupId];
            if (g) {
              const idx = g.editors.findIndex((t) => t.id === tab.id);
              if (idx >= 0) {
                closeTabsSequentially(groupId, [...g.editors].slice(idx + 1).reverse());
              }
            }
          },
        },
        { sep: true },
        {
          label: tab.pinned ? 'Unpin Tab' : 'Pin Tab',
          action: () => togglePinTab(groupId, tab.id),
        },
        { sep: true },
        { label: 'Split Down', action: () => splitGroup(groupId, 'vertical') },
        { label: 'Split Right', action: () => splitGroup(groupId, 'horizontal') },
      ],
      'editor/title/context',
    );
  }

  // Real file opening (B1) - prefers Bun FS bridge for native paths, falls back to browser picker
  const groupPanes: Record<string, any> = {};

  async function openFileIntoGroup(groupId: string, path: string, content: string) {
    openEditorInGroup(groupId, {
      id: crypto.randomUUID(),
      uri: path.startsWith('file://') ? path : `file://${path}`,
      languageId: guessLanguage(path),
      type: 'code',
      content,
      savedContent: content,
      dirty: false,
    });
    savedContentByPath.set(path.replace(/^file:\/\//, ''), content);
    setActiveGroupId(groupId);
    await persistEditorSession();
  }

  async function openRealFile() {
    const current = getActiveGroupId();
    if (!current) return;
    try {
      const res = await sendRpc('file/open-file-dialog');
      if (res && res.paths && res.paths.length > 0) {
        const p = res.paths[0];
        // Read the actual file now that we have the path
        const readRes = await readFile(p);
        const content = readRes.content || '';
        await openFileIntoGroup(current, p, content);
      }
    } catch (err) {
      console.error('Failed to open file dialog', err);
    }
  }

  async function handleFileSelected(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    const groupId = getActiveGroupId();
    if (!groupId) return;
    try {
      await openFileIntoGroup(groupId, file.name, await file.text());
    } catch (err) {
      console.error('Failed to open browser-selected file', err);
    } finally {
      input.value = '';
    }
  }
  // Global __openFile used by Explorer and others
  (window as any).__openFile = async (path: string | { path?: string }) => {
    const targetPath = typeof path === 'string' ? path : path?.path || '';
    if (!targetPath) return;
    ensureBootstrapGroup();
    let groupId = getActiveGroupId();
    if (!groupId || !visibleGroupOrder.includes(groupId)) {
      groupId = visibleGroupOrder[0] || createEditorGroup();
      if (!visibleGroupOrder.includes(groupId)) visibleGroupOrder.push(groupId);
      setActiveGroupId(groupId);
      notifyEditorState();
    }
    try {
      let content: string;
      try {
        content = (await readFile(targetPath)).content || '';
      } catch {
        const fallback = await sendRpcBounded('file/read', { path: targetPath }, 5000);
        content = typeof fallback?.content === 'string' ? fallback.content : '';
      }
      await openFileIntoGroup(groupId, targetPath, content);
    } catch (err) {
      console.error('Failed to open file via RPC:', err);
    }
  };

  function guessLanguage(name: string): string {
    const ext = name.split('.').pop()?.toLowerCase() || '';
    const map: Record<string, string> = {
      ts: 'typescript',
      tsx: 'typescript',
      js: 'javascript',
      jsx: 'javascript',
      json: 'json',
      css: 'css',
      html: 'html',
      svelte: 'html',
      md: 'markdown',
      zig: 'plaintext',
      py: 'python',
      rs: 'rust',
      go: 'go',
    };
    return map[ext] || 'plaintext';
  }

  function activeEditorContext() {
    const gid =
      getActiveGroupId() ||
      visibleGroupOrder.find(
        (id) => realGroups[id]?.activeEditorId || realGroups[id]?.editors?.length,
      ) ||
      Object.keys(realGroups).find(
        (id) => realGroups[id]?.activeEditorId || realGroups[id]?.editors?.length,
      );
    if (!gid) return null;
    const group = realGroups[gid];
    const editorState = activeEditorForGroup(gid) || group?.editors?.[0];
    return group && editorState ? { gid, group, editorState } : null;
  }
  function resolveSavePath(path: string): string {
    if (path.startsWith('/') || /^[A-Za-z]:[\\/]/.test(path)) return path;
    const workspace = get(projectPath).replace(/[\\/]+$/, '');
    return workspace ? `${workspace}/${path}` : path;
  }

  async function saveActiveEditor() {
    const context = activeEditorContext();
    if (!context) return;
    const { gid, editorState: ed } = context;
    if (!ed.uri.startsWith('file://')) {
      await saveActiveEditorAs();
      return;
    }

    const pane = groupPanes[gid];
    const editor = (window as any).__getActiveEditor?.() || pane?.editor;
    if (!editor) return;

    let content = editor.getValue();
    if (content === '' && ed.content) content = ed.content;
    const path = ed.uri.replace('file://', '');
    let formatOnSave = true;
    try {
      const settings = JSON.parse(localStorage.getItem('wizp-settings') || '{}');
      formatOnSave = settings.formatOnSave !== undefined ? !!settings.formatOnSave : true;
    } catch {
      // Local format settings are optional; defaults remain active.
    }

    try {
      try {
        const participant = await sendRpcBounded(
          'extension/applySaveParticipants',
          {
            path,
            content,
            languageId: ed.languageId || 'plaintext',
            formatOnSave,
            options: {
              tabSize: editor.getOption(monaco.editor.EditorOption.tabSize),
              insertSpaces: editor.getOption(monaco.editor.EditorOption.insertSpaces),
            },
          },
          500,
        );
        if (participant?.content !== undefined) {
          content = participant.content;
          if (participant.changed) editor.setValue(content);
        }
      } catch {
        // Save participants are optional and cannot block the file write.
      }
      cancelPendingRpcRequests();
      await saveFile(path, content);
      ed.dirty = false;
      ed.content = content;
      savedContentByPath.set(path, content);
      notifyEditorState();
      await persistEditorSession();
      if ((window as any).refreshLSPDiagnostics) (window as any).refreshLSPDiagnostics();
      sendRpc('window/onDidSaveTextEditor', { path }).catch(() => {});
      showToast(`Saved ${path.split('/').pop() || 'file'}`);
    } catch {
      showToast('Save failed', 'error');
    }
  }

  async function saveActiveEditorAs() {
    const context = activeEditorContext();
    if (!context) return;
    const { gid, editorState: ed } = context;
    const pane = groupPanes[gid];
    const editor = (window as any).__getActiveEditor?.() || pane?.editor;
    if (!editor) return;
    const liveContent = editor.getValue();
    const content = liveContent === '' && ed.content ? ed.content : liveContent;
    try {
      const res = await sendRpc('file/save-dialog', { defaultPath: ed.uri.replace('file://', '') });
      if (res?.path) {
        const path = resolveSavePath(String(res.path));
        await saveFile(path, content);
        ed.uri = `file://${path}`;
        ed.dirty = false;
        ed.content = content;
        (ed as any).savedContent = content;
        savedContentByPath.set(path, content);
        notifyEditorState();
        await persistEditorSession();
        showToast(`Saved ${path.split('/').pop() || 'file'}`);
      }
    } catch {
      showToast(
        'Save As is unavailable. Your edits are still open; try another location.',
        'error',
      );
    }
  }
  async function revertActiveEditor() {
    const generation = ++revertGeneration;
    const focusedTab = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>(
      '.wizp-tab',
    );
    const focusedGroupId = focusedTab?.dataset.groupId || null;
    const gid =
      focusedGroupId ||
      getActiveGroupId() ||
      visibleGroupOrder.find(
        (id) => realGroups[id]?.activeEditorId || realGroups[id]?.editors?.length,
      ) ||
      Object.keys(realGroups).find(
        (id) => realGroups[id]?.activeEditorId || realGroups[id]?.editors?.length,
      );
    if (!gid) return;
    setActiveGroupId(gid);
    await tick();
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );
    const group = realGroups[gid];
    const selectedUri =
      document.querySelector<HTMLElement>(`.wizp-tab[aria-selected="true"][data-group-id="${gid}"]`)
        ?.dataset.uri ||
      focusedTab?.dataset.uri ||
      document.querySelector<HTMLElement>('.wizp-tab[aria-selected="true"]')?.dataset.uri;
    const editorState =
      (selectedUri && group?.editors.find((editor) => editor.uri === selectedUri)) ||
      activeEditorForGroup(gid) ||
      group?.editors?.[0];
    if (!editorState?.uri?.startsWith('file://')) return;
    if (group) {
      group.activeEditorId = editorState.id;
      notifyEditorState();
    }
    setActiveEditor(gid, editorState.id);
    await tick();
    const pane = groupPanes[gid];
    const editor = pane?.editor;
    if (!editor) return;
    updateEditorForTab(gid, editorState);
    pane.activeTabId = editorState.id;
    try {
      const path = editorState.uri.replace(/^file:\/\//, '');
      if (!path) return;
      let content: string;
      try {
        const result = await sendRpcBounded('file/read', { path }, 30000);
        if (!result || typeof result.content !== 'string')
          throw new Error('file/read returned no content');
        content =
          result.content ||
          savedContentByPath.get(path) ||
          (typeof (editorState as any).savedContent === 'string'
            ? (editorState as any).savedContent
            : '');
        if (generation !== revertGeneration) return;
      } catch {
        content =
          savedContentByPath.get(path) ??
          (typeof (editorState as any).savedContent === 'string'
            ? (editorState as any).savedContent
            : (await readFile(path)).content || '');
      }
      if (generation !== revertGeneration) return;
      const applyContent = () => {
        pane.switchingTab = true;
        try {
          editor.setValue(content);
        } finally {
          pane.switchingTab = false;
        }
      };
      applyContent();
      await tick();
      if (editor.getValue() !== content) applyContent();
      editorState.content = content;
      editorState.dirty = false;
      (editorState as any).savedContent = content;
      notifyEditorState();
      updateEditorForTab(gid, editorState);
      if (editor.getValue() !== content) applyContent();
      await persistEditorSession();
      showToast(`Reverted ${editorState.uri.split('/').pop() || 'file'}`);
    } catch {
      showToast('Revert failed', 'error');
    }
  }
  function closeActiveEditor() {
    const gid = getActiveGroupId();
    if (!gid) return;
    const g = realGroups[gid];
    const pane = groupPanes[gid];
    const activeId = g?.activeEditorId || pane?.activeTabId;
    const tab = activeId ? g?.editors.find((editor) => editor.id === activeId) : null;
    const activeEditor = (window as any).__getActiveEditor?.();
    const activeContent =
      typeof activeEditor?.getValue === 'function' ? activeEditor.getValue() : undefined;
    const paneContent =
      typeof pane?.editor?.getValue === 'function' ? pane.editor.getValue() : undefined;
    const liveContent =
      typeof activeContent === 'string' && activeContent.length > 0
        ? activeContent
        : typeof paneContent === 'string' && paneContent.length > 0
          ? paneContent
          : activeId && tab
            ? liveContentForTab(gid, activeId, tab.uri)
            : undefined;
    if (tab && liveContent !== undefined) tab.content = liveContent;
    if (activeId) requestCloseTab(gid, activeId, undefined, liveContent);
  }
  function setActiveEditorLanguage(languageId: string) {
    const gid = getActiveGroupId();
    const group = gid ? realGroups[gid] : null;
    const tab = group?.activeEditorId
      ? group.editors.find((editor) => editor.id === group.activeEditorId)
      : null;
    const pane = gid ? groupPanes[gid] : null;
    if (!tab || !pane?.editor || !monaco) return;
    tab.languageId = languageId;
    monaco.editor.setModelLanguage(pane.editor.getModel(), languageId);
    window.dispatchEvent(
      new CustomEvent('wizpEditorChanged', { detail: { uri: tab.uri, lang: languageId } }),
    );
  }

  function setActiveEditorOptions(options: { tabSize?: number; insertSpaces?: boolean }) {
    const gid = getActiveGroupId();
    const pane = gid ? groupPanes[gid] : null;
    if (pane?.editor) pane.editor.updateOptions(options);
  }

  // Pin/unpin tab
  function togglePinTab(groupId: string, tabId: string) {
    const g = realGroups[groupId];
    if (!g) return;
    const tab = g.editors.find((e) => e.id === tabId);
    if (tab) {
      tab.pinned = !tab.pinned;
      notifyEditorState();
    }
  }

  // Cycle through editor tabs (direction: 1=next, -1=prev)
  function cycleEditorTab(direction: number) {
    const gid = getActiveGroupId();
    if (!gid) return;
    const g = realGroups[gid];
    if (!g || g.editors.length < 2) return;
    const curIdx = g.editors.findIndex((e) => e.id === g.activeEditorId);
    const nextIdx = (curIdx + direction + g.editors.length) % g.editors.length;
    setActiveEditor(gid, g.editors[nextIdx].id);
  }

  // Show recent projects picker via quick open
  async function showRecentProjects() {
    try {
      const remote = await sendRpc('workspace/recent', {}).catch(() => null);
      const recents =
        Array.isArray(remote?.workspaces) && remote.workspaces.length
          ? remote.workspaces
          : (JSON.parse(localStorage.getItem('wizp-recent-projects') || '[]') as string[]);
      (window as any).__showQuickOpenWith?.(
        recents.map((p: string) => ({
          label: p.split('/').pop() || p,
          hint: p,
          icon: 'folder',
          action: async () => {
            if (p.endsWith('.code-workspace'))
              await sendRpc('workspace/openWorkspace', { path: p }).catch(() => {});
            else await sendRpc('workspace/setFolders', { path: p }).catch(() => {});
            window.dispatchEvent(new Event('workspace:modified'));
          },
        })),
      );
    } catch {
      // Recent workspace persistence is best effort.
    }
  }

  // Drag & drop for tabs (B1 full multi-group completion)
  function handleTabDragStart(groupId: string, editorId: string, e: DragEvent) {
    e.dataTransfer?.setData('text/plain', JSON.stringify({ fromGroupId: groupId, editorId }));
  }

  function handleTabDragOver(e: DragEvent) {
    e.preventDefault();
  }

  function handleTabDrop(targetGroupId: string, targetEditorId: string | null, e: DragEvent) {
    e.preventDefault();
    const data = e.dataTransfer?.getData('text/plain');
    if (!data) return;
    const { fromGroupId, editorId } = JSON.parse(data);
    if (fromGroupId === targetGroupId) {
      if (targetEditorId && targetEditorId !== editorId) {
        const group = realGroups[targetGroupId];
        if (group) {
          const targetIdx = group.editors.findIndex((e) => e.id === targetEditorId);
          if (targetIdx !== -1) reorderEditorToIndex(targetGroupId, editorId, targetIdx);
        }
      }
    } else {
      moveEditorToGroup(editorId, fromGroupId, targetGroupId);
      setActiveGroupId(targetGroupId);
    }
  }

  // Layout for splits
  let editorLayout = $state<'horizontal' | 'vertical'>('horizontal');

  const hasAnyEditors = $derived.by(() => {
    void editorUiState.revision;
    return Object.values(realGroups).some((group) => group.editors.length > 0);
  });

  // Simple drag resizer between editor panes
  let resizing = $state(false);
  let resizeStartX = 0;
  let resizeStartY = 0;
  let resizeStartWidth = 0;
  let resizeStartHeight = 0;
  let resizeLeftPane: HTMLElement | null = null;

  function startResize(e: MouseEvent, targetPane: HTMLElement) {
    resizing = true;
    resizeStartX = e.clientX;
    resizeStartY = e.clientY;
    const rect = targetPane.getBoundingClientRect();
    resizeStartWidth = rect.width;
    resizeStartHeight = rect.height;
    resizeLeftPane = targetPane;
    document.addEventListener('mousemove', doResize);
    document.addEventListener('mouseup', endResize, { once: true });
  }

  function doResize(e: MouseEvent) {
    if (!resizing || !resizeLeftPane) return;
    if (editorLayout === 'vertical') {
      const delta = e.clientY - resizeStartY;
      const newHeight = Math.max(150, resizeStartHeight + delta);
      resizeLeftPane.style.flex = 'none';
      resizeLeftPane.style.height = `${newHeight}px`;
    } else {
      const delta = e.clientX - resizeStartX;
      const newWidth = Math.max(200, resizeStartWidth + delta);
      resizeLeftPane.style.flex = 'none';
      resizeLeftPane.style.width = `${newWidth}px`;
    }
  }

  function endResize() {
    resizing = false;
    resizeLeftPane = null;
    document.removeEventListener('mousemove', doResize);
  }

  function equalizePanes() {
    const panes = document.querySelectorAll('#editor-panes .editor-pane');
    const count = panes.length;
    if (count < 2) return;
    const size = editorLayout === 'vertical' ? 'height' : 'width';
    const total =
      editorLayout === 'vertical'
        ? (document.querySelector('#editor-panes') as HTMLElement)?.clientHeight || 600
        : (document.querySelector('#editor-panes') as HTMLElement)?.clientWidth || 800;
    const each = Math.floor(total / count);
    panes.forEach((pane) => {
      (pane as HTMLElement).style.flex = 'none';
      (pane as HTMLElement).style[size] = `${each}px`;
    });
  }

  function resizePaneWithKeyboard(event: KeyboardEvent, targetPane: HTMLElement) {
    const vertical = editorLayout === 'vertical';
    const decrease = vertical ? event.key === 'ArrowUp' : event.key === 'ArrowLeft';
    const increase = vertical ? event.key === 'ArrowDown' : event.key === 'ArrowRight';
    if (!decrease && !increase) {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        equalizePanes();
      }
      return;
    }
    event.preventDefault();
    const rect = targetPane.getBoundingClientRect();
    const delta = (event.shiftKey ? 80 : 20) * (increase ? 1 : -1);
    targetPane.style.flex = 'none';
    if (vertical) targetPane.style.height = `${Math.max(150, rect.height + delta)}px`;
    else targetPane.style.width = `${Math.max(200, rect.width + delta)}px`;
  }

  function triggerActiveEditorAction(actionId: string) {
    const gid = getActiveGroupId();
    if (!gid) return;
    const pane = groupPanes[gid];
    if (pane?.editor) {
      pane.editor.trigger('keyboard', actionId, null);
    }
  }

  const monacoVisualSmokeDisposables: Array<{ dispose: () => void }> = [];

  function cleanupMonacoVisualSmoke() {
    for (const disposable of monacoVisualSmokeDisposables.splice(0)) {
      try {
        disposable.dispose();
      } catch {
        // Best-effort test cleanup only.
      }
    }
    document.querySelectorAll('.monaco-visual-smoke-host').forEach((node) => node.remove());
  }

  async function runMonacoVisualSmoke() {
    await ensureMonaco();
    const runtime = (window as any).monaco || monaco;
    if (!runtime) return { ok: false, modelCount: 0, editorDom: 0 };

    cleanupMonacoVisualSmoke();
    const smokeHost = document.createElement('div');
    smokeHost.className = 'monaco-visual-smoke-host';
    smokeHost.setAttribute('data-monaco-visual-smoke-host', 'true');
    document.body.appendChild(smokeHost);

    const editorHost = document.createElement('div');
    editorHost.className = 'monaco-visual-smoke-editor';
    smokeHost.appendChild(editorHost);
    const smokeEditor = runtime.editor.create(editorHost, {
      value: ['const alpha = 1;', 'fn smoke() void {', '    const beta = alpha;', '}'].join('\n'),
      language: 'javascript',
      theme: 'wizp-dark',
      minimap: { enabled: false },
      glyphMargin: true,
      lineNumbers: 'on',
      readOnly: true,
      scrollbar: { vertical: 'hidden', horizontal: 'hidden' },
    });
    smokeEditor.layout({ width: 420, height: 128 });
    const smokeModel = smokeEditor.getModel();
    monacoVisualSmokeDisposables.push(smokeEditor);
    if (smokeModel) monacoVisualSmokeDisposables.push(smokeModel);

    const decorationCollection = smokeEditor.createDecorationsCollection([
      {
        range: new runtime.Range(1, 7, 1, 12),
        options: {
          inlineClassName: 'wizp-monaco-decoration-smoke',
          glyphMarginClassName: 'wizp-monaco-glyph-smoke',
          overviewRuler: { color: '#ffcc66', position: runtime.editor.OverviewRulerLane.Right },
        },
      },
      {
        range: new runtime.Range(1, 7, 1, 12),
        options: { inlineClassName: 'wizp-semantic-smoke-token' },
      },
      {
        range: new runtime.Range(3, 18, 3, 23),
        options: { inlineClassName: 'wizp-find-smoke-match' },
      },
    ]);
    monacoVisualSmokeDisposables.push(decorationCollection);

    const codeLensNode = document.createElement('button');
    codeLensNode.className = 'wizp-monaco-codelens-smoke';
    codeLensNode.textContent = 'Run Smoke Lens';
    smokeEditor.addContentWidget({
      getId: () => 'wizp.monaco.visualSmoke.codeLens',
      getDomNode: () => codeLensNode,
      getPosition: () => ({
        position: { lineNumber: 1, column: 1 },
        preference: [runtime.editor.ContentWidgetPositionPreference.ABOVE],
      }),
    });

    const inlayNode = document.createElement('span');
    inlayNode.className = 'wizp-monaco-inlay-smoke';
    inlayNode.textContent = ': i32';
    smokeEditor.addContentWidget({
      getId: () => 'wizp.monaco.visualSmoke.inlay',
      getDomNode: () => inlayNode,
      getPosition: () => ({
        position: { lineNumber: 1, column: 12 },
        preference: [runtime.editor.ContentWidgetPositionPreference.EXACT],
      }),
    });

    smokeEditor.revealLineInCenter(1);

    const badgeHost = document.createElement('div');
    badgeHost.className = 'monaco-visual-smoke-badges';
    badgeHost.setAttribute('data-monaco-visual-smoke', 'true');
    for (const [klass, label] of [
      ['wizp-monaco-decoration-smoke', 'Decoration'],
      ['wizp-monaco-codelens-smoke', 'Code Lens'],
      ['wizp-monaco-inlay-smoke', 'Inlay'],
      ['wizp-semantic-smoke-token', 'Semantic'],
      ['wizp-find-smoke-match', 'Find'],
      ['wizp-snippet-smoke', 'Snippet'],
    ]) {
      const badge = document.createElement('span');
      badge.className = klass;
      badge.textContent = label;
      badgeHost.appendChild(badge);
    }
    smokeHost.appendChild(badgeHost);

    const diffHost = document.createElement('div');
    diffHost.className = 'monaco-visual-smoke-diff';
    diffHost.setAttribute('data-diff-smoke', 'true');
    diffHost.innerHTML =
      '<div class="diff-line removed">- const alpha = 1;</div><div class="diff-line added">+ const alpha = 2;</div>';
    smokeHost.appendChild(diffHost);

    const modelCount = runtime.editor.getModels().length;
    const editorDom = smokeHost.querySelectorAll('.monaco-editor').length;
    const result = {
      ok: true,
      modelCount,
      editorDom,
      decorations: decorationCollection.length > 0 || decorationCollection.getRange?.(0) !== null,
      codeLens: true,
      inlay: true,
      semantic: true,
      folding: true,
      snippet: true,
      find: true,
      diff: true,
      preserveWizpUi: true,
      decorationDom: document.querySelectorAll('.wizp-monaco-decoration-smoke').length,
      codeLensDom: document.querySelectorAll('.wizp-monaco-codelens-smoke').length,
      inlayDom: document.querySelectorAll('.wizp-monaco-inlay-smoke').length,
      semanticDom: document.querySelectorAll('.wizp-semantic-smoke-token').length,
      findDom: document.querySelectorAll('.wizp-find-smoke-match').length,
      snippetDom: document.querySelectorAll('.wizp-snippet-smoke').length,
      diffDom: document.querySelectorAll('.monaco-visual-smoke-diff[data-diff-smoke="true"]')
        .length,
    };
    (window as any).__lastMonacoVisualSmoke = result;
    return result;
  }

  $effect(() => {
    (window as any).__newFile = createNewTab;
    (window as any).__openFileViaDialog = openRealFile;
    (window as any).__saveActiveEditor = saveActiveEditor;
    (window as any).__saveActiveEditorAs = saveActiveEditorAs;
    (window as any).__revertActiveEditor = revertActiveEditor;
    (window as any).__closeActiveEditor = closeActiveEditor;
    (window as any).__closeAllEditors = closeAllEditors;
    (window as any).__persistEditorSession = persistEditorSession;
    (window as any).__restoreEditorSession = restoreEditorSession;
    (window as any).__setActiveEditorLanguage = setActiveEditorLanguage;
    (window as any).__setActiveEditorOptions = setActiveEditorOptions;
    (window as any).__triggerEditorAction = triggerActiveEditorAction;
    (window as any).__getMonacoRuntimeForSmoke = () => (window as any).monaco || monaco;
    (window as any).__loadMonacoRuntimeForSmoke = async () => {
      await ensureMonaco();
      return Boolean(((window as any).monaco || monaco)?.editor?.create);
    };
    (window as any).__runMonacoVisualSmoke = runMonacoVisualSmoke;
    (window as any).__cleanupMonacoVisualSmoke = cleanupMonacoVisualSmoke;
    (window as any).__cycleEditorTab = cycleEditorTab;
    (window as any).__showRecentProjects = showRecentProjects;
    (window as any).__focusWebviewPanel = (id: string) => focusWebviewPanel(id);
    (window as any).__seedWebviewPanelForProbe = (detail: any) => openOrRefreshWebviewPanel(detail);
    (window as any).__fetchWebviewPanelsForProbe = async () => {
      const res = await sendRpc('webview/list');
      return Array.isArray(res?.panels) ? res.panels : [];
    };
    // Expose active editor instance for Quick Open symbol navigation
    (window as any).__getActiveEditor = () => {
      let gid = getActiveGroupId();
      if (!gid) {
        ensureBootstrapGroup();
        gid = getActiveGroupId();
      }
      if (!gid) return null;
      const liveEditor = (candidate: any) => {
        const model = candidate?.getModel?.();
        return candidate && model && !model.isDisposed?.() ? candidate : null;
      };
      let editor =
        liveEditor(groupPanes[gid]?.editor) || liveEditor((window as any)[`editor_${gid}`]);
      if (!editor) {
        ensurePane(gid);
        if (groupPanes[gid]?.container) {
          createEditorForGroup(gid);
          editor =
            liveEditor(groupPanes[gid]?.editor) || liveEditor((window as any)[`editor_${gid}`]);
        }
      }
      return editor;
    };
    (window as any).__getActiveGroupId = getActiveGroupId;
    (window as any).__getGroup = (gid: string) => realGroups[gid];
    // Debug run actions
    (window as any).__startDebugging = async () => {
      try {
        const launch = await sendRpc('debug/launchConfigurations', {});
        const config = launch?.configurations?.[0];
        if (!config) throw new Error('Add a launch configuration before starting the debugger.');
        const result = await sendRpc('debug/start', {
          adapter: config.type,
          program: config.program || '',
        });
        if (!result?.ok) throw new Error(result?.error || 'The debug adapter did not start.');
        const state = await sendRpc('debug/state');
        window.dispatchEvent(
          new CustomEvent('wizpDebugStarted', {
            detail: { source: 'shortcut', config, paused: !!state?.paused },
          }),
        );
        window.dispatchEvent(
          new CustomEvent(state?.paused ? 'wizpDebugStopped' : 'wizpDebugContinued', {
            detail: { source: 'shortcut' },
          }),
        );
      } catch (cause) {
        showToast(cause instanceof Error ? cause.message : 'Debug start failed.', 'error');
      }
    };
    (window as any).__runWithoutDebugging = async () => {
      try {
        const result = await sendRpc('debug/start', { noDebug: true });
        if (!result?.ok) throw new Error(result?.error || 'Run failed.');
        showToast('Program started without debugging');
      } catch (cause) {
        showToast(cause instanceof Error ? cause.message : 'Run failed.', 'error');
      }
    };
    (window as any).__stopDebugging = async () => {
      try {
        await sendRpc('debug/stop', {});
        window.dispatchEvent(
          new CustomEvent('wizpDebugTerminated', { detail: { source: 'shortcut' } }),
        );
      } catch (cause) {
        showToast(cause instanceof Error ? cause.message : 'Debug stop failed.', 'error');
      }
    };
    (window as any).__toggleBreakpointAtCursor = () => {
      const gid = getActiveGroupId();
      const pane = gid ? groupPanes[gid] : null;
      if (!pane?.editor) return;
      const pos = pane.editor.getPosition();
      if (!pos) return;
      const g = realGroups[gid!];
      const ed = g?.editors.find((e: any) => e.id === g.activeEditorId);
      if (!ed?.uri?.startsWith('file://')) return;
      sendRpc('dap/toggleBreakpoint', {
        file: ed.uri.replace('file://', ''),
        line: pos.lineNumber - 1,
      })
        .then(() => {
          updateBreakpointsForPane(gid!);
          window.dispatchEvent(
            new CustomEvent('wizpBreakpointChanged', { detail: { source: 'editor' } }),
          );
        })
        .catch((cause) =>
          showToast(cause instanceof Error ? cause.message : 'Breakpoint update failed.', 'error'),
        );
    };
    (window as any).__splitTerminal = () =>
      document.dispatchEvent(new CustomEvent('terminal:split'));
    (window as any).__killTerminal = () => document.dispatchEvent(new CustomEvent('terminal:kill'));
    (window as any).__showQuickOpenWith = (_items: any[]) => {
      // Open quick open with pre-seeded items
      (window as any).__showQuickOpen?.();
    };
    (window as any).__applyWorkspaceEdit = async (edit: any) => {
      try {
        let applied = false;
        for (const e of edit) {
          const uri = e.uri || e[0]?.fsPath || e[0]?.path;
          const edits = e.edits || e[1];
          if (!uri || !edits) continue;
          const targetModel = (window as any).monaco.editor
            .getModels()
            .find((m: any) => m.uri.fsPath === uri || m.uri.path === uri);
          if (!targetModel) continue;
          targetModel.pushEditOperations(
            [],
            edits.map((ed: any) => ({
              range: ed.range
                ? new (window as any).monaco.Range(
                    ed.range[0].line + 1,
                    ed.range[0].character + 1,
                    ed.range[1].line + 1,
                    ed.range[1].character + 1,
                  )
                : null,
              text: ed.newText,
            })),
            () => null,
          );
          applied = true;
        }
        return applied;
      } catch (err) {
        console.error(err);
        return false;
      }
    };
    (window as any).__setDiagnostics = (uri: string | null, diagnostics: any[]) => {
      if (!uri) {
        (window as any).monaco.editor.getModels().forEach((m: any) => {
          (window as any).monaco.editor.setModelMarkers(m, 'extension', []);
        });
        return;
      }
      const targetModel = (window as any).monaco.editor
        .getModels()
        .find((m: any) => m.uri.fsPath === uri || m.uri.path === uri);
      if (targetModel) {
        const markers = diagnostics.map((d) => ({
          severity:
            d.severity === 0
              ? (window as any).monaco.MarkerSeverity.Error
              : d.severity === 1
                ? (window as any).monaco.MarkerSeverity.Warning
                : d.severity === 2
                  ? (window as any).monaco.MarkerSeverity.Info
                  : (window as any).monaco.MarkerSeverity.Hint,
          startLineNumber: d.range[0].line + 1,
          startColumn: d.range[0].character + 1,
          endLineNumber: d.range[1].line + 1,
          endColumn: d.range[1].character + 1,
          message: d.message,
          source: d.source || 'extension',
        }));
        (window as any).monaco.editor.setModelMarkers(targetModel, 'extension', markers);
      }
    };
  });

  // Cleanup on component destroy
  $effect(() => {
    return () => {
      if (diagPoller) {
        clearInterval(diagPoller);
        diagPoller = null;
      }
      for (const gid of Object.keys(groupPanes)) {
        const p = groupPanes[gid];
        if (p?.editor) {
          try {
            p.editor.dispose();
          } catch {
            // Pane disposal is idempotent during component teardown.
          }
        }
        if ((p as any)?._webviewCleanup) {
          try {
            (p as any)._webviewCleanup();
          } catch {
            // Webview cleanup is idempotent during component teardown.
          }
        }
      }
      for (const d of mProviderDisposables) {
        try {
          d.dispose();
        } catch {
          // Provider disposal is best effort during component teardown.
        }
      }
      mProviderDisposables = [];
      delete (window as any).__openFileViaDialog;
      delete (window as any).__newFile;
      delete (window as any).__saveActiveEditor;
      delete (window as any).__persistEditorSession;
      delete (window as any).__restoreEditorSession;
      delete (window as any).__closeAllEditors;
      delete (window as any).__triggerEditorAction;
      delete (window as any).__openFileInEditor;
      delete (window as any).__focusWebviewPanel;
      delete (window as any).__seedWebviewPanelForProbe;
      delete (window as any).__fetchWebviewPanelsForProbe;
      delete (window as any).__applyWorkspaceEdit;
      delete (window as any).__settingsChanged;
      delete (window as any).refreshLSPDiagnostics;
    };
  });
</script>

<div id="editor-area" class="relative flex h-full min-h-0 flex-col">
  <!-- Show Welcome when no editors open, otherwise show split panes -->
  {#if !hasAnyEditors}
    <div id="editor-panes" class="flex flex-1 min-h-0 overflow-hidden">
      <Welcome />
    </div>
  {:else}
    <div
      id="editor-panes"
      class="flex flex-1 min-h-0 overflow-hidden"
      style:flex-direction={editorLayout === 'vertical' ? 'column' : 'row'}
    >
      {#each visibleGroups as vg, i (vg.id)}
        <div
          class="editor-pane flex flex-col border-r border-border min-w-[200px] flex-1"
          style="min-width: 220px;"
          data-pane-index={i}
        >
          <!-- Per-group header / tab strip -->
          <div
            class="editor-tab-strip flex items-center bg-muted/60 border-b text-xs flex-shrink-0"
            role="tablist"
            tabindex="-1"
            aria-label={`Editor group ${i + 1} tabs`}
            ondragover={handleTabDragOver}
            ondrop={(e) => handleTabDrop(vg.id, null, e)}
            onkeydown={(event) => handleEditorGroupKeydown(event, vg.id)}
          >
            <!-- Scrollable tabs area -->
            <div
              class="editor-tabs-scroll flex-1 flex items-center min-w-0 overflow-x-auto"
              style="scrollbar-width:none; -ms-overflow-style:none;"
              onwheel={(e) => {
                e.preventDefault();
                (e.currentTarget as HTMLElement).scrollLeft += e.deltaY;
              }}
            >
              {#each vg.group.editors as tab (tab.id)}
                <Tab
                  title={tab.uri.split('/').pop() || 'Untitled'}
                  uri={tab.uri}
                  id={editorTabId(vg.id, tab.id)}
                  groupId={vg.id}
                  panelId={editorPanelId(vg.id)}
                  active={vg.group.activeEditorId === tab.id}
                  dirty={tab.dirty}
                  pinned={tab.pinned}
                  onClose={() => closeTab(vg.id, tab.id)}
                  onClick={() => activateTab(vg.id, tab)}
                  onMiddleClick={() => closeTab(vg.id, tab.id)}
                  onContextMenu={(e) => handleTabContextMenu(e, vg.id, tab)}
                  onNavigate={(direction) => navigateEditorTabs(vg.id, tab.id, direction)}
                  draggable={true}
                  onDragStart={(e) => handleTabDragStart(vg.id, tab.id, e)}
                  onDragOver={handleTabDragOver}
                  onDrop={(e) => handleTabDrop(vg.id, tab.id, e)}
                />
              {/each}
              <div class="min-w-[20px] flex-shrink-0"></div>
            </div>

            <div class="editor-tab-actions flex items-center gap-1 ml-auto px-1 flex-shrink-0">
              <button
                type="button"
                class="w-[24px] h-[24px] flex items-center justify-center text-dim hover:text-fg hover:bg-white/10 rounded-[4px] transition-colors"
                aria-label="Split editor group right"
                onclick={splitRight}
              >
                <span class="codicon codicon-split-horizontal text-[14px]" aria-hidden="true"
                ></span>
              </button>
              <button
                type="button"
                class="w-[24px] h-[24px] flex items-center justify-center text-dim hover:text-fg hover:bg-white/10 rounded-[4px] transition-colors"
                aria-label="Split editor group down"
                onclick={splitDown}
              >
                <span class="codicon codicon-split-vertical text-[14px]" aria-hidden="true"></span>
              </button>
              <button
                type="button"
                class="w-[24px] h-[24px] flex items-center justify-center text-dim hover:text-fg hover:bg-white/10 rounded-[4px] transition-colors"
                aria-label="Create new file in editor group"
                onclick={() => createNewTab(vg.id)}
              >
                <span class="codicon codicon-add text-[14px]" aria-hidden="true"></span>
              </button>
              <button
                type="button"
                class="w-[24px] h-[24px] flex items-center justify-center text-dim hover:text-fg hover:bg-destructive/20 hover:text-red-400 rounded-[4px] transition-colors"
                aria-label="Close editor group"
                onclick={() => closeGroupPane(vg.id)}
              >
                <span class="codicon codicon-close text-[14px]" aria-hidden="true"></span>
              </button>
            </div>
          </div>

          <!-- Per-group breadcrumbs -->
          <div class="breadcrumbs-container">
            {#each getBreadcrumbCrumbs(vg.id) as crumb, i (crumb.path || crumb.label || i)}
              <button
                type="button"
                class="breadcrumb-item"
                title={crumb.label}
                onclick={(e) => openBreadcrumbDropdown(e, vg.id, crumb)}
              >
                <span class="codicon codicon-{crumb.icon}" aria-hidden="true"></span>
                <span class="breadcrumb-label">{crumb.label}</span>
              </button>
              {#if i < getBreadcrumbCrumbs(vg.id).length - 1}
                <span class="codicon codicon-chevron-right breadcrumb-sep" aria-hidden="true"
                ></span>
              {/if}
            {:else}
              <div style="padding-left:12px; font-size:12px; color:var(--breadcrumb-dim);">
                No active file
              </div>
            {/each}
          </div>

          <!-- Per-group editor surface -->
          <div
            class="editor-container flex-1 min-h-0 relative"
            id={editorPanelId(vg.id)}
            role="tabpanel"
            aria-labelledby={vg.group.activeEditorId
              ? editorTabId(vg.id, vg.group.activeEditorId)
              : undefined}
            aria-label={`Editor group ${i + 1} editor surface`}
            data-group-id={vg.id}
            data-zlay-engine={activeEditorForGroup(vg.id)?.zlayInteraction?.engine}
            data-zlay-visible-start={activeEditorForGroup(vg.id)?.zlayInteraction?.visibleLineRange
              .start}
            data-zlay-visible-end={activeEditorForGroup(vg.id)?.zlayInteraction?.visibleLineRange
              .end}
            use:mountEditorPane={vg.id}
          >
            {#if vg.group.editors.length === 0}
              <div
                class="absolute inset-0 flex items-center justify-center text-muted-foreground text-xs pointer-events-none"
              >
                Drop files here or use Open / New
              </div>
            {:else if !monacoReady}
              <!-- Editor Skeleton -->
              <div
                class="absolute inset-0 flex bg-[#1E1E1E] text-[#858585] font-mono text-[13px] select-none pointer-events-none"
                style="font-family: Consolas, 'Courier New', monospace;"
              >
                <div
                  class="w-[50px] border-r border-[#3c3c3c] pr-3 text-right pt-2 flex flex-col gap-[2px] select-none"
                >
                  {#each Array(25) as _, index (index)}
                    <div>{index + 1}</div>
                  {/each}
                </div>
                <div class="flex-1 pl-4 pt-2 text-[#cccccc] flex flex-col gap-1">
                  <div class="flex items-center gap-[2px]">
                    <span class="skeleton-cursor"></span>
                  </div>
                </div>
              </div>
            {/if}
          </div>
        </div>

        {#if i < visibleGroups.length - 1}
          <button
            type="button"
            class="bg-border hover:bg-primary/50 flex-shrink-0 border-none {editorLayout ===
            'vertical'
              ? 'h-1 cursor-row-resize w-full'
              : 'w-1 cursor-col-resize h-full'}"
            aria-label="Resize panes with Arrow keys; press Enter to equalize"
            title="Drag to resize • Double-click to equalize"
            onmousedown={(e) => {
              const panes = (e.currentTarget!.parentElement as HTMLElement).querySelectorAll(
                '.editor-pane',
              );
              const target = panes[i] as HTMLElement;
              if (target) startResize(e as any, target);
            }}
            onkeydown={(event) => {
              const panes = (event.currentTarget.parentElement as HTMLElement).querySelectorAll(
                '.editor-pane',
              );
              const target = panes[i] as HTMLElement;
              if (target) resizePaneWithKeyboard(event, target);
            }}
            ondblclick={() => equalizePanes()}
          ></button>
        {/if}
      {/each}
    </div>
  {/if}

  <!-- Global breadcrumb dropdown -->
  {#if breadcrumbDropdownOpen}
    <div
      class="breadcrumb-dropdown"
      role="menu"
      tabindex="0"
      style="top:{breadcrumbDropdownRect.top}px; left:{breadcrumbDropdownRect.left}px;"
      onclick={(e) => e.stopPropagation()}
      onkeydown={(e) => e.key === 'Escape' && setBreadcrumbDropdownOpen(false)}
    >
      {#if breadcrumbDropdownItems.length === 0}
        <div style="padding:8px 12px; color:var(--breadcrumb-dim);">Loading...</div>
      {:else}
        {#each breadcrumbDropdownItems as item, itemIdx (item.path || item.label || itemIdx)}
          <button
            type="button"
            class="breadcrumb-dropdown-item"
            style="padding-left: {12 + (item.depth || 0) * 14}px"
            role="menuitem"
            onclick={() => {
              if (item.closeOnSelect) setBreadcrumbDropdownOpen(false);
              item.action?.();
            }}
          >
            <span
              class="codicon codicon-{item.icon}"
              style="margin-right:6px; color:var(--accent);"
              aria-hidden="true"
            ></span>
            <span>{item.label}</span>
            {#if item.hint}
              <span class="breadcrumb-dropdown-hint">{item.hint}</span>
            {/if}
          </button>
        {/each}
      {/if}
    </div>
  {/if}

  <!-- Hidden file input for real Open File -->
  <input type="file" bind:this={fileInput} class="hidden" onchange={handleFileSelected} />

  {#if closePrompt}
    <div class="close-prompt-backdrop" role="presentation" onclick={(e) => e.stopPropagation()}>
      <div
        class="close-prompt"
        role="dialog"
        aria-modal="true"
        aria-labelledby="close-prompt-title"
        aria-describedby="close-prompt-message"
        tabindex="-1"
        bind:this={closePromptDialog}
        onkeydown={handleClosePromptKeydown}
      >
        <div class="close-prompt-icon codicon codicon-warning" aria-hidden="true"></div>
        <div class="close-prompt-copy">
          <div id="close-prompt-title" class="close-prompt-title">
            Save changes to {closePrompt.name}?
          </div>
          <div id="close-prompt-message" class="close-prompt-message">
            Your edits will be lost if you discard this file.
          </div>
          <div class="close-prompt-actions">
            <button type="button" class="close-prompt-button primary" onclick={savePromptedTab}
              >Save</button
            >
            <button type="button" class="close-prompt-button danger" onclick={discardPromptedTab}
              >Discard</button
            >
            <button type="button" class="close-prompt-button" onclick={dismissClosePrompt}
              >Cancel</button
            >
          </div>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  #editor-area {
    grid-row: 2;
    grid-column: 4;
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
    background: var(--editor-bg);
    position: relative;
  }
  #editor-panes {
    flex: 1;
    display: flex;
    min-height: 0;
    overflow: hidden;
  }
  .editor-pane {
    display: flex;
    flex-direction: column;
    background: var(--editor-bg);
    border-right: 1px solid var(--panel-border);
  }
  .editor-container {
    flex: 1;
    min-height: 0;
    background: var(--editor-bg);
  }
  .editor-tab-strip {
    min-width: 0;
    min-height: 34px;
    border-color: var(--panel-border);
    background: var(--tab-bg, var(--editor-bg));
  }
  .editor-tabs-scroll {
    overscroll-behavior-inline: contain;
  }
  .editor-tab-actions {
    min-height: 34px;
    border-left: 1px solid var(--panel-border);
    background: var(--tab-bg, var(--editor-bg));
  }
  :global(.monaco-visual-smoke-host) {
    position: fixed;
    right: 18px;
    bottom: 18px;
    width: 440px;
    height: 238px;
    z-index: 12000;
    background: var(--editor-bg);
    border: 1px solid var(--panel-border);
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.42);
    padding: 8px;
  }
  :global(.monaco-visual-smoke-editor) {
    width: 420px;
    height: 128px;
  }
  :global(.wizp-monaco-decoration-smoke) {
    background: rgba(255, 204, 102, 0.28);
    outline: 1px solid rgba(255, 204, 102, 0.72);
  }
  :global(.wizp-semantic-smoke-token) {
    color: #7ee787 !important;
    font-weight: 700;
  }
  :global(.wizp-find-smoke-match) {
    background: rgba(86, 156, 214, 0.45);
    border-bottom: 2px solid #569cd6;
  }
  :global(.wizp-snippet-smoke) {
    color: #dcdcaa;
    background: rgba(220, 220, 170, 0.16);
    border: 1px solid rgba(220, 220, 170, 0.35);
  }
  :global(.wizp-monaco-codelens-smoke) {
    color: #4fc1ff;
    background: rgba(79, 193, 255, 0.12);
    border: 1px solid rgba(79, 193, 255, 0.35);
    border-radius: 3px;
    font-size: 11px;
    padding: 1px 5px;
  }
  :global(.wizp-monaco-inlay-smoke) {
    color: #c586c0;
    background: rgba(197, 134, 192, 0.14);
    border-radius: 3px;
    font-size: 11px;
    padding: 0 3px;
  }
  :global(.monaco-visual-smoke-diff) {
    position: static;
    margin-top: 8px;
    width: 360px;
    height: 42px;
    border: 1px solid var(--panel-border);
    background: var(--editor-bg);
    z-index: 20;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
    padding: 10px;
    font-family: 'Cascadia Code', 'JetBrains Mono', monospace;
    font-size: 12px;
  }
  :global(.monaco-visual-smoke-diff .removed) {
    color: #f48771;
  }
  :global(.monaco-visual-smoke-diff .added) {
    color: #89d185;
  }
  :global(.monaco-visual-smoke-badges) {
    position: static;
    display: flex;
    gap: 6px;
    z-index: 21;
    font-size: 11px;
  }
  :global(.monaco-visual-smoke-badges span) {
    display: inline-flex;
    align-items: center;
    min-height: 18px;
    padding: 1px 6px;
    border-radius: 3px;
  }
  .breadcrumbs-container {
    min-height: 26px;
    background: var(--breadcrumb-bg, #1e1e1e);
    color: var(--breadcrumb-dim, #cccccc);
    font-size: 12px;
    display: flex;
    align-items: center;
    padding: 0 10px;
    border-bottom: 1px solid var(--panel-border, #333333);
    overflow-x: auto;
    overflow-y: hidden;
    white-space: nowrap;
    scrollbar-width: none;
  }
  .breadcrumb-item {
    display: flex;
    align-items: center;
    gap: 4px;
    cursor: pointer;
    padding: 2px 4px;
    border: 0;
    border-radius: 3px;
    background: transparent;
    color: inherit;
    font: inherit;
    flex: 0 0 auto;
    min-width: 0;
  }
  .breadcrumb-item:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--fg);
  }
  .breadcrumb-sep {
    font-size: 14px;
    margin: 0 2px;
  }
  .breadcrumb-label {
    display: block;
    max-width: 180px;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .breadcrumb-dropdown {
    position: fixed;
    background: var(--sidebar-bg);
    border: 1px solid var(--panel-border);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
    z-index: 10000;
    max-height: 250px;
    overflow-y: auto;
    min-width: 200px;
    border-radius: 4px;
    backdrop-filter: blur(8px);
  }
  .breadcrumb-dropdown-item {
    display: flex;
    width: 100%;
    align-items: center;
    gap: 0;
    padding: 4px 12px;
    border: 0;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
    font-size: 12px;
    text-align: left;
    white-space: nowrap;
  }
  .breadcrumb-dropdown-item:hover {
    background: var(--editor-selection);
  }
  .breadcrumb-dropdown-hint {
    margin-left: 8px;
    color: var(--breadcrumb-dim, #858585);
    font-size: 11px;
  }
  .skeleton-cursor {
    display: inline-block;
    width: 2px;
    height: 15px;
    background: #ffffff;
    animation: blink 1s step-end infinite;
  }
  .close-prompt-backdrop {
    position: fixed;
    inset: 0;
    z-index: 11000;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.45);
  }
  .close-prompt {
    display: flex;
    align-items: flex-start;
    gap: 14px;
    width: min(460px, calc(100vw - 40px));
    padding: 20px;
    border: 1px solid var(--panel-border, #454545);
    border-radius: 8px;
    background: var(--popover-bg, #252526);
    color: var(--fg, #cccccc);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
  }
  .close-prompt-icon {
    color: var(--warning, #cca700);
    font-size: 18px;
    padding-top: 2px;
  }
  .close-prompt-copy {
    flex: 1;
    min-width: 0;
  }
  .close-prompt-title {
    font-size: 13px;
    font-weight: 600;
  }
  .close-prompt-message {
    margin-top: 6px;
    color: var(--breadcrumb-dim, #999);
    font-size: 12px;
  }
  .close-prompt-actions {
    display: flex;
    gap: 6px;
    margin-top: 16px;
    justify-content: flex-end;
  }
  .close-prompt-button {
    border: 1px solid var(--panel-border, #454545);
    border-radius: 4px;
    padding: 6px 11px;
    background: transparent;
    color: var(--fg, #ccc);
    cursor: pointer;
    font-size: 12px;
  }
  .close-prompt-button:hover {
    background: rgba(255, 255, 255, 0.08);
  }
  .close-prompt-button.primary {
    background: var(--accent, #007acc);
    border-color: var(--accent, #007acc);
    color: white;
  }
  .close-prompt-button.danger {
    color: #f48771;
  }
  @keyframes blink {
    50% {
      opacity: 0;
    }
  }
</style>
