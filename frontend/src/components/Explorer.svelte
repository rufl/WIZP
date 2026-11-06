<script lang="ts">
  import { onMount, tick } from 'svelte';
  import {
    cancelPendingRpcRequests,
    pauseTerminalReads,
    sendRpc,
    sendRpcBounded,
  } from '../../bridge';
  import { updateRendererSession } from '$lib/session-recovery';
  import { projectPath, showToast } from '../stores';
  import TreeItem from './TreeItem.svelte';
  import InlineFeedback from './InlineFeedback.svelte';

  type ExplorerAction = 'newFile' | 'newFolder' | 'rename' | 'delete';
  type ExplorerDialog = { action: ExplorerAction; item?: any; parent: string };

  let treeData = $state<any[]>([]);
  let treeRevision = $state(0);
  let gitStatus = $state<Record<string, string>>({});
  let currentPath = $state('');
  let outlineSymbols = $state<any[]>([]);
  let outlineExpanded = $state(true);
  let clipboardItem = $state<any>(null);
  let workspaceFolders = $state<any[]>([]);
  let selectedPath = $state('');
  let selectedKind = $state('');
  let explorerError = $state('');
  let explorerLoading = $state(false);
  let explorerDialog = $state<ExplorerDialog | null>(null);
  let explorerDialogValue = $state('');
  let explorerDialogError = $state('');
  let explorerDialogValidationError = $state(false);
  let explorerDialogBusy = $state(false);
  let explorerDialogElement = $state<HTMLDialogElement>();
  let explorerDialogInput = $state<HTMLInputElement>();
  let explorerDialogPrimary = $state<HTMLButtonElement>();
  let explorerDialogReturnFocus: HTMLElement | null = null;
  let explorerDialogReturnFocusPath = '';
  let explorerLoadTicket = 0;
  let explorerRequestTicket = 0;
  let explorerReconnectPending = false;
  let explorerReconnectGeneration = 0;

  function scheduleExplorerLoad(rootPath?: string) {
    const ticket = ++explorerLoadTicket;
    window.setTimeout(() => {
      if (ticket !== explorerLoadTicket) return;
      if (explorerLoading) {
        setTimeout(() => {
          if (ticket === explorerLoadTicket) scheduleExplorerLoad(rootPath);
        }, 100);
        return;
      }
      void loadExplorer(rootPath);
    }, 80);
  }
  function scheduleExplorerReconnectRetries(generation: number, rootPath = currentPath) {
    for (const delay of [250, 750, 1500]) {
      window.setTimeout(() => {
        if (generation !== explorerReconnectGeneration) return;
        if (rootPath) scheduleExplorerLoad(rootPath);
      }, delay);
    }
  }

  $effect(() => {
    const unsubscribe = projectPath.subscribe((path) => {
      if (path && (path !== currentPath || workspaceFolders.length === 0)) {
        currentPath = path;
        scheduleExplorerLoad(path);
      }
    });
    const handleDaemonDisconnected = () => {
      explorerError = 'Workspace backend disconnected. Reconnecting…';
    };
    const handleDaemonReconnected = () => {
      const generation = ++explorerReconnectGeneration;
      explorerReconnectPending = true;
      scheduleExplorerLoad(currentPath || undefined);
      scheduleExplorerReconnectRetries(generation);
    };
    const handleOutline = async (event: Event) => {
      const uri = (event as CustomEvent).detail.uri;
      try {
        const result = await sendRpc('textDocument/documentSymbol', { uri });
        outlineSymbols = Array.isArray(result) ? result : [];
      } catch {
        outlineSymbols = [];
      }
    };
    window.addEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
    window.addEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    window.addEventListener('wizpEditorChanged', handleOutline);
    return () => {
      unsubscribe();
      window.removeEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
      window.removeEventListener('wizpDaemonReconnected', handleDaemonReconnected);
      window.removeEventListener('wizpEditorChanged', handleOutline);
    };
  });

  function sortItems(items: any[]): any[] {
    return [...items].sort((a, b) => {
      if (a.kind === 'directory' && b.kind !== 'directory') return -1;
      if (a.kind !== 'directory' && b.kind === 'directory') return 1;
      return (a.name || '').localeCompare(b.name || '');
    });
  }

  async function loadExplorer(rootPath?: string) {
    let persistedPath = '';
    try {
      persistedPath = localStorage.getItem('wizp-last-workspace') || '';
    } catch {
      // Local workspace persistence is best effort.
    }
    const requestedPath = rootPath || currentPath || persistedPath;
    const requestTicket = ++explorerRequestTicket;
    explorerError = '';
    explorerLoading = true;
    try {
      const workspace = requestedPath
        ? null
        : await sendRpcBounded('workspace/getFolders', {}, 5000).catch(() => null);
      if (requestTicket !== explorerRequestTicket) return;
      const backendFolders = Array.isArray(workspace?.folders) ? workspace.folders : [];
      workspaceFolders =
        backendFolders.length > 0 || !requestedPath
          ? backendFolders
          : [{ path: requestedPath, name: requestedPath.split('/').pop() || requestedPath }];
      if (workspaceFolders.length > 0) {
        void updateRendererSession({
          folders: workspaceFolders.map((folder) => ({ path: folder.path })),
        }).catch(() => {});
      }
      if (workspaceFolders.length === 0) {
        currentPath = '';
        treeData = [];
        gitStatus = {};
        selectedPath = '';
        selectedKind = '';
        return;
      }

      if (workspaceFolders.length > 1) {
        const roots = await Promise.all(
          workspaceFolders.map(async (folder: any) => {
            const result = await sendRpcBounded('file/list', { path: folder.path }, 5000);
            return {
              name: folder.name || folder.path.split('/').pop() || folder.path,
              path: folder.path,
              kind: 'directory',
              children: sortItems(
                Array.isArray(result?.files) ? result.files : result?.entries || [],
              ),
            };
          }),
        );
        if (requestTicket !== explorerRequestTicket) return;
        treeData = roots;
      } else {
        const root = workspaceFolders[0];
        currentPath = root.path || requestedPath;
        const result = await sendRpcBounded(
          'file/list',
          { path: root.path || requestedPath },
          5000,
        );
        if (requestTicket !== explorerRequestTicket) return;
        treeData = sortItems(Array.isArray(result?.files) ? result.files : result?.entries || []);
      }

      const selectedRoot = treeData.find((item) => item.path === selectedPath);
      if (!selectedRoot && treeData[0]) {
        selectedPath = treeData[0].path;
        selectedKind = treeData[0].kind;
      }
      await tick();
    } catch {
      if (requestTicket !== explorerRequestTicket) return;
      treeData = [];
      explorerError = 'Could not load this workspace. Check that the folder is still available.';
      const retryPath = requestedPath || currentPath || persistedPath;
      if (retryPath) {
        const generation = ++explorerReconnectGeneration;
        scheduleExplorerReconnectRetries(generation, retryPath);
      }
    } finally {
      if (requestTicket === explorerRequestTicket) {
        explorerLoading = false;
        if (explorerReconnectPending) {
          explorerReconnectPending = false;
          scheduleExplorerLoad();
        }
      }
    }
    if (requestTicket === explorerRequestTicket) void loadGitStatus();
  }

  async function loadGitStatus() {
    if (workspaceFolders.length === 0) {
      gitStatus = {};
      return;
    }
    try {
      const result = await sendRpc('git/status', {});
      if (Array.isArray(result?.files)) {
        const statuses: Record<string, string> = {};
        for (const file of result.files) statuses[file.file] = file.status.trim();
        gitStatus = statuses;
      }
    } catch {
      // Git decorations are optional; file navigation remains available.
    }
  }

  async function openFolder() {
    try {
      const result = await sendRpc('file/open-folder-dialog');
      if (result?.path) {
        ++explorerLoadTicket;
        ++explorerRequestTicket;
        await sendRpc('workspace/setFolders', { path: result.path });
        currentPath = result.path;
        projectPath.set(result.path);
        saveRecentProject(result.path);
        await loadExplorer(result.path);
      }
    } catch {
      explorerError = 'Could not open that folder. Try again or choose another folder.';
    }
  }

  $effect(() => {
    (window as any).__openFolder = openFolder;
  });

  function saveRecentProject(path: string) {
    try {
      const saved = JSON.parse(localStorage.getItem('wizp-recent-projects') || '[]');
      const filtered = saved.filter((item: string) => item !== path);
      filtered.unshift(path);
      localStorage.setItem('wizp-recent-projects', JSON.stringify(filtered.slice(0, 10)));
    } catch {
      // Recent-workspace persistence is best effort.
    }
    try {
      localStorage.setItem('wizp-last-workspace', path);
    } catch {
      // Local workspace persistence is best effort.
    }
  }
  function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = window.setTimeout(
        () => reject(new Error('Explorer request timed out')),
        timeoutMs,
      );
      promise.then(
        (value) => {
          window.clearTimeout(timer);
          resolve(value);
        },
        (error) => {
          window.clearTimeout(timer);
          reject(error);
        },
      );
    });
  }

  async function expandDir(item: any) {
    let lastError: unknown = null;
    let lastEntries: any[] = [];
    const resumeTerminalReads = pauseTerminalReads();
    try {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          const result = await withTimeout(sendRpc('file/list', { path: item.path }), 10000);
          const entries = Array.isArray(result?.files) ? result.files : result?.entries;
          if (!Array.isArray(entries)) throw new Error('file/list returned no entries');
          lastEntries = entries;
          if (entries.length > 0 || attempt === 2) {
            item.children = sortItems(entries);
            return item.children;
          }
        } catch (error) {
          lastError = error;
          if (attempt === 2) break;
        }
        await new Promise((resolve) => window.setTimeout(resolve, 100));
      }
    } finally {
      resumeTerminalReads();
    }
    if (lastError) throw lastError instanceof Error ? lastError : new Error('file/list failed');
    item.children = sortItems(lastEntries);
    return item.children;
  }
  function collapseAll() {
    treeRevision++;
    const selectedRoot = treeData.find((item) => item.path === selectedPath) || treeData[0];
    if (selectedRoot) {
      selectedPath = selectedRoot.path;
      selectedKind = selectedRoot.kind;
    }
  }

  function selectItem(path: string, kind: string) {
    selectedPath = path;
    selectedKind = kind;
  }

  function openFile(path: string) {
    selectItem(path, 'file');
    (window as any).__openFile?.(path);
  }

  function openOutlineSymbol(symbol: any) {
    const editor = (window as any).__getActiveEditor?.();
    const line = Number(symbol.line ?? symbol.startLine ?? 0) + 1;
    if (!editor || !Number.isFinite(line)) return;
    editor.revealLineInCenter(line);
    editor.setPosition({ lineNumber: line, column: 1 });
    editor.focus();
  }

  function parentPath(path: string) {
    const index = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return index > 0 ? path.slice(0, index) : currentPath;
  }

  function joinPath(parent: string, name: string) {
    const separator = parent.includes('\\') && !parent.includes('/') ? '\\' : '/';
    return `${parent.replace(/[\\/]+$/, '')}${separator}${name}`;
  }

  function selectedParentPath() {
    if (selectedPath) return selectedKind === 'directory' ? selectedPath : parentPath(selectedPath);
    return currentPath || workspaceFolders[0]?.path || '';
  }

  function openExplorerDialog(action: ExplorerAction, item?: any, parent?: string) {
    const targetParent =
      parent || (item?.kind === 'directory' ? item.path : parentPath(item?.path || ''));
    if (!targetParent && action !== 'delete') {
      showToast('Open a folder before creating files', 'error');
      return;
    }
    explorerDialogReturnFocus =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    explorerDialogReturnFocusPath = explorerDialogReturnFocus?.getAttribute('data-path') || '';
    explorerDialog = { action, item, parent: targetParent };
    explorerDialogValue = action === 'rename' ? item?.name || '' : '';
    explorerDialogError = '';
    explorerDialogValidationError = false;
    void tick().then(() => {
      explorerDialogElement?.showModal();
      if (action === 'delete') explorerDialogPrimary?.focus();
      else {
        explorerDialogInput?.focus();
        explorerDialogInput?.select();
      }
    });
  }

  function closeExplorerDialog() {
    if (explorerDialogBusy) return;
    explorerDialogElement?.close();
    explorerDialog = null;
    explorerDialogError = '';
    explorerDialogValidationError = false;
    const target = explorerDialogReturnFocus;
    const targetPath = explorerDialogReturnFocusPath;
    explorerDialogReturnFocus = null;
    explorerDialogReturnFocusPath = '';
    if (!target && !targetPath) return;
    const restoreFocus = async () => {
      for (let attempt = 0; attempt < 5; attempt += 1) {
        await tick();
        const replacement =
          (targetPath
            ? Array.from(
                document.querySelectorAll<HTMLElement>('[role="treeitem"][data-path]'),
              ).find((item) => item.getAttribute('data-path') === targetPath)
            : null) ||
          (target?.isConnected && (!targetPath || target.getAttribute('data-path') === targetPath)
            ? target
            : null);
        if (replacement) {
          replacement.focus();
          return;
        }
        await new Promise((resolve) => window.setTimeout(resolve, 50));
      }
    };
    requestAnimationFrame(() => void restoreFocus());
  }
  function validateExplorerName(name: string) {
    if (!name) return 'Enter a name.';
    if (name === '.' || name === '..' || /[\\/]/.test(name)) {
      return 'Use a single file or folder name, not a path.';
    }
    return '';
  }

  async function submitExplorerDialog() {
    const dialog = explorerDialog;
    if (!dialog || explorerDialogBusy) return;
    const name = explorerDialogValue.trim();
    if (dialog.action !== 'delete') {
      explorerDialogError = validateExplorerName(name);
      explorerDialogValidationError = Boolean(explorerDialogError);
      if (explorerDialogError) return;
    }
    explorerDialogValidationError = false;

    explorerDialogBusy = true;
    cancelPendingRpcRequests([
      'file/read',
      'file/save',
      'file/list',
      'file/create',
      'file/mkdir',
      'file/rename',
      'file/delete',
      'session/load',
      'session/save',
    ]);
    const resumeTerminalReads = pauseTerminalReads();
    try {
      if (dialog.action === 'newFile') {
        const path = joinPath(dialog.parent, name);
        await sendRpcBounded('file/create', { path }, 5000);
        await loadExplorer();
        openFile(path);
        showToast(`Created ${name}`);
      } else if (dialog.action === 'newFolder') {
        await sendRpcBounded('file/mkdir', { path: joinPath(dialog.parent, name) }, 5000);
        await loadExplorer();
        showToast(`Created folder ${name}`);
      } else if (dialog.action === 'rename') {
        if (name === dialog.item.name) {
          explorerDialogBusy = false;
          closeExplorerDialog();
          return;
        }
        const path = joinPath(parentPath(dialog.item.path), name);
        await sendRpcBounded('file/rename', { from: dialog.item.path, to: path }, 5000);
        selectedPath = path;
        selectedKind = dialog.item.kind;
        await loadExplorer();
        showToast(`Renamed to ${name}`);
      } else {
        await sendRpcBounded('file/delete', { path: dialog.item.path }, 5000);
        selectedPath = '';
        selectedKind = '';
        await loadExplorer();
        showToast(`Deleted ${dialog.item.name}`);
      }
      explorerDialogBusy = false;
      closeExplorerDialog();
    } catch (error) {
      explorerDialogBusy = false;
      const action =
        dialog.action === 'newFile'
          ? 'create the file'
          : dialog.action === 'newFolder'
            ? 'create the folder'
            : dialog.action === 'rename'
              ? 'rename the item'
              : 'delete the item';
      const detail = error instanceof Error && error.message ? ` (${error.message})` : '';
      explorerDialogValidationError = false;
      explorerDialogError = `Could not ${action}. Check the name and permissions, then try again.${detail}`;
      void tick().then(() =>
        dialog.action === 'delete' ? explorerDialogPrimary?.focus() : explorerDialogInput?.focus(),
      );
    } finally {
      resumeTerminalReads();
    }
  }

  function handleContext(event: MouseEvent | KeyboardEvent, item: any) {
    event.preventDefault();
    event.stopPropagation();
    selectItem(item.path, item.kind);
    const isDirectory = item.kind === 'directory';
    const target = event.currentTarget as HTMLElement;
    const rect = target.getBoundingClientRect();
    const x = event instanceof MouseEvent && event.clientX ? event.clientX : rect.left + 24;
    const y = event instanceof MouseEvent && event.clientY ? event.clientY : rect.top + 20;
    const parent = isDirectory ? item.path : parentPath(item.path);

    (window as any).__showCtxMenu?.(
      x,
      y,
      [
        { label: 'New File...', action: () => openExplorerDialog('newFile', undefined, parent) },
        {
          label: 'New Folder...',
          action: () => openExplorerDialog('newFolder', undefined, parent),
        },
        { sep: true },
        {
          label: 'Rename...',
          accel: 'F2',
          action: () => openExplorerDialog('rename', item),
        },
        {
          label: 'Delete',
          accel: 'Delete',
          danger: true,
          action: () => openExplorerDialog('delete', item),
        },
        { sep: true },
        { label: 'Copy', action: () => (clipboardItem = { ...item, op: 'copy' }) },
        { label: 'Cut', action: () => (clipboardItem = { ...item, op: 'cut' }) },
        ...(clipboardItem
          ? [
              {
                label: 'Paste',
                action: async () => {
                  if (!clipboardItem) return;
                  const targetDirectory = isDirectory ? item.path : parentPath(item.path);
                  try {
                    await sendRpc('file/copy', {
                      from: clipboardItem.path,
                      to: joinPath(targetDirectory, clipboardItem.name),
                    });
                    if (clipboardItem.op === 'cut') {
                      await sendRpc('file/delete', { path: clipboardItem.path });
                    }
                    const operation = clipboardItem.op === 'cut' ? 'Moved' : 'Copied';
                    clipboardItem = null;
                    await loadExplorer();
                    showToast(`${operation} item`);
                  } catch {
                    showToast('Could not paste the selected item', 'error');
                  }
                },
              },
            ]
          : []),
        { sep: true },
        { label: 'Collapse All', action: collapseAll },
        { label: 'Refresh Explorer', action: () => void loadExplorer() },
      ],
      'explorer/context',
    );
  }

  const projectName = $derived(
    workspaceFolders.length > 1
      ? `${workspaceFolders.length} Folders`
      : workspaceFolders.length === 0
        ? 'No Folder Open'
        : currentPath.split(/[\\/]/).pop() || currentPath,
  );

  onMount(() => {
    scheduleExplorerLoad();
    const refresh = () => void loadExplorer();
    document.addEventListener('workspace:modified', refresh);
    (window as any).__refreshExplorer = refresh;
    (window as any).__newExplorerFile = () =>
      openExplorerDialog('newFile', undefined, selectedParentPath());
    (window as any).__newExplorerFolder = () =>
      openExplorerDialog('newFolder', undefined, selectedParentPath());
    return () => {
      explorerLoadTicket++;
      explorerRequestTicket++;
      document.removeEventListener('workspace:modified', refresh);
      delete (window as any).__refreshExplorer;
      delete (window as any).__newExplorerFile;
      delete (window as any).__newExplorerFolder;
    };
  });
</script>

<div class="explorer">
  <div class="explorer-toolbar">
    <span class="toolbar-title">{projectName}</span>
    <button
      type="button"
      class="toolbar-btn"
      title="Open Folder"
      aria-label="Open folder"
      onclick={openFolder}
    >
      <span class="codicon codicon-folder-opened" aria-hidden="true"></span>
    </button>
    <button
      class="toolbar-btn"
      title="Collapse All"
      aria-label="Collapse all explorer folders"
      onclick={collapseAll}
    >
      <span class="codicon codicon-collapse-all" aria-hidden="true"></span>
    </button>
    <button
      class="toolbar-btn"
      title="Refresh"
      aria-label="Refresh explorer"
      onclick={() => void loadExplorer()}
    >
      <span class="codicon codicon-refresh" aria-hidden="true"></span>
    </button>
  </div>

  <div
    class="explorer-tree"
    role="tree"
    aria-label="Workspace files"
    aria-busy={explorerLoading || undefined}
  >
    {#if workspaceFolders.length === 0}
      <div class="empty-workspace" data-workspace-state="empty">
        <span class="codicon codicon-folder-opened empty-workspace-icon" aria-hidden="true"></span>
        <div>No folder opened</div>
        <button type="button" class="empty-workspace-button" onclick={openFolder}
          >Open Folder</button
        >
      </div>
    {:else if explorerLoading && treeData.length === 0}
      <div class="explorer-state" role="status">Loading workspace…</div>
    {:else if treeData.length === 0 && !explorerError}
      <div class="explorer-state" data-workspace-state="empty-folder">
        <span>This folder is empty.</span>
        <div class="explorer-state-actions">
          <button
            type="button"
            onclick={() => openExplorerDialog('newFile', undefined, currentPath)}>New File</button
          >
          <button
            type="button"
            onclick={() => openExplorerDialog('newFolder', undefined, currentPath)}
            >New Folder</button
          >
        </div>
      </div>
    {:else}
      {#each treeData as item, itemIndex (item.path)}
        <TreeItem
          {item}
          depth={0}
          position={itemIndex + 1}
          setSize={treeData.length}
          revision={treeRevision}
          {gitStatus}
          {selectedPath}
          onSelect={selectItem}
          onExpand={expandDir}
          onRename={(target) => openExplorerDialog('rename', target)}
          onDelete={(target) => openExplorerDialog('delete', target)}
          {openFile}
          onContext={handleContext}
        />
      {/each}
    {/if}
    {#if explorerError}
      <div class="explorer-error" role="alert">
        <span>{explorerError}</span>
        <button type="button" onclick={() => void loadExplorer()}>Retry</button>
      </div>
    {/if}
  </div>

  <button
    type="button"
    class="explorer-toolbar outline-toolbar"
    aria-expanded={outlineExpanded}
    aria-controls="explorer-outline"
    onclick={() => (outlineExpanded = !outlineExpanded)}
  >
    <span class="codicon codicon-chevron-{outlineExpanded ? 'down' : 'right'}" aria-hidden="true"
    ></span>
    <span class="toolbar-title">Outline</span>
  </button>
  {#if outlineExpanded}
    <div id="explorer-outline" class="explorer-outline">
      {#if outlineSymbols.length === 0}
        <div class="outline-empty">No symbols found for active file.</div>
      {:else}
        {#each outlineSymbols as symbol (symbol.name + ':' + (symbol.line ?? symbol.startLine ?? 0))}
          <button
            type="button"
            class="outline-item"
            title={symbol.name}
            onclick={() => openOutlineSymbol(symbol)}
          >
            <span
              class="codicon codicon-symbol-{symbol.kind === 5
                ? 'class'
                : symbol.kind === 12
                  ? 'function'
                  : 'property'}"
              aria-hidden="true"
            ></span>
            <span class="outline-label">{symbol.name}</span>
          </button>
        {/each}
      {/if}
    </div>
  {/if}
</div>

{#if explorerDialog}
  <dialog
    bind:this={explorerDialogElement}
    class="explorer-dialog"
    aria-labelledby="explorer-dialog-title"
    aria-describedby="explorer-dialog-description"
    oncancel={(event) => {
      event.preventDefault();
      closeExplorerDialog();
    }}
  >
    <h2 id="explorer-dialog-title">
      {explorerDialog.action === 'newFile'
        ? 'Create file'
        : explorerDialog.action === 'newFolder'
          ? 'Create folder'
          : explorerDialog.action === 'rename'
            ? `Rename ${explorerDialog.item.name}`
            : `Delete ${explorerDialog.item.name}?`}
    </h2>
    <p id="explorer-dialog-description">
      {explorerDialog.action === 'delete'
        ? 'This action cannot be undone.'
        : explorerDialog.action === 'rename'
          ? 'Enter a new name for this item.'
          : `The new ${explorerDialog.action === 'newFile' ? 'file' : 'folder'} will be created in ${explorerDialog.parent}.`}
    </p>
    {#if explorerDialog.action !== 'delete'}
      <input
        bind:this={explorerDialogInput}
        bind:value={explorerDialogValue}
        aria-label={explorerDialog.action === 'rename' ? 'New name' : 'Name'}
        aria-invalid={Boolean(explorerDialogError)}
        aria-describedby="explorer-dialog-error"
        disabled={explorerDialogBusy}
        spellcheck="false"
        oninput={(event) => {
          if (
            explorerDialogValidationError &&
            !validateExplorerName(event.currentTarget.value.trim())
          ) {
            explorerDialogError = '';
            explorerDialogValidationError = false;
          }
        }}
        onkeydown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            void submitExplorerDialog();
          }
        }}
      />
      <InlineFeedback
        id="explorer-dialog-error"
        error={explorerDialog.action === 'delete' ? '' : explorerDialogError}
      />
    {/if}
    {#if explorerDialog.action === 'delete' && explorerDialogError}
      <div id="explorer-dialog-error" class="explorer-dialog-error" role="alert">
        {explorerDialogError}
      </div>
    {/if}
    <div class="explorer-dialog-actions">
      <button type="button" onclick={closeExplorerDialog} disabled={explorerDialogBusy}
        >Cancel</button
      >
      <button
        bind:this={explorerDialogPrimary}
        type="button"
        class="primary"
        class:danger={explorerDialog.action === 'delete'}
        onclick={() => void submitExplorerDialog()}
        disabled={explorerDialogBusy}
      >
        {explorerDialogBusy
          ? 'Working…'
          : explorerDialog.action === 'newFile'
            ? 'Create File'
            : explorerDialog.action === 'newFolder'
              ? 'Create Folder'
              : explorerDialog.action === 'rename'
                ? 'Rename'
                : 'Delete'}
      </button>
    </div>
  </dialog>
{/if}

<style>
  .explorer {
    padding: 0;
  }
  .explorer-toolbar {
    display: flex;
    align-items: center;
    padding: 6px 12px 6px 42px !important;
    border-bottom: 1px solid var(--panel-border);
    color: var(--breadcrumb-dim);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }
  .toolbar-title {
    min-width: 0;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .outline-toolbar {
    width: 100%;
    gap: 6px;
    border: 0;
    border-top: 1px solid var(--panel-border);
    background: transparent;
    cursor: pointer;
    text-align: left;
  }
  .toolbar-btn {
    display: inline-flex;
    width: 24px;
    height: 24px;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: none;
    background: none;
    color: var(--breadcrumb-dim);
    cursor: pointer;
    font-size: 14px;
  }
  .toolbar-btn:hover {
    color: var(--fg);
  }
  .toolbar-btn:focus-visible,
  .empty-workspace-button:focus-visible,
  .explorer-state button:focus-visible,
  .explorer-error button:focus-visible,
  .outline-item:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  .empty-workspace {
    display: flex;
    min-height: 150px;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 24px 16px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    text-align: center;
  }
  .empty-workspace-icon {
    font-size: 28px;
  }
  .empty-workspace-button {
    min-height: 28px;
    padding: 5px 12px;
    border: 1px solid var(--accent);
    border-radius: 3px;
    background: var(--accent);
    color: white;
    cursor: pointer;
    font-size: 12px;
  }
  .empty-workspace-button:hover {
    filter: brightness(1.08);
  }
  .explorer-tree {
    flex: 1;
    overflow-y: auto;
    padding-bottom: 20px;
  }
  .explorer-state {
    display: flex;
    min-height: 96px;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 20px 16px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    text-align: center;
  }
  .explorer-state-actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 8px;
  }
  .explorer-state button,
  .explorer-error button {
    min-height: 24px;
    padding: 4px 8px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
  }
  .explorer-error {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin: 10px;
    color: var(--error);
    font-size: 12px;
  }
  .explorer-error button {
    align-self: flex-start;
  }
  .explorer-outline {
    max-height: 300px;
    overflow-y: auto;
    background: rgba(0, 0, 0, 0.1);
  }
  .outline-empty {
    padding: 10px 20px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
  }
  .outline-item {
    display: flex;
    width: 100%;
    align-items: center;
    gap: 8px;
    overflow: hidden;
    padding: 4px 12px 4px 30px;
    border: 0;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
    font-size: 12px;
    text-align: left;
    white-space: nowrap;
  }
  .outline-item:hover {
    background: rgba(255, 255, 255, 0.04);
  }
  .outline-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .explorer-dialog {
    width: min(460px, calc(100% - 48px));
    margin: 72px auto auto;
    padding: 18px;
    border: 1px solid var(--panel-border);
    border-radius: 8px;
    background: var(--panel-bg);
    box-shadow: 0 18px 48px rgba(0, 0, 0, 0.6);
  }
  .explorer-dialog::backdrop {
    background: rgba(0, 0, 0, 0.5);
  }
  .explorer-dialog h2 {
    margin: 0 0 6px;
    color: var(--fg);
    font-size: 16px;
    font-weight: 600;
  }
  .explorer-dialog p {
    max-width: 65ch;
    margin: 0 0 14px;
    overflow-wrap: anywhere;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    line-height: 1.5;
  }
  .explorer-dialog input {
    width: 100%;
    min-height: 32px;
    box-sizing: border-box;
    padding: 6px 8px;
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    outline: none;
    background: var(--sidebar-bg);
    color: var(--fg);
    font-size: 13px;
  }
  .explorer-dialog input:focus-visible {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }
  .explorer-dialog input[aria-invalid='true'] {
    border-color: var(--error);
  }
  .explorer-dialog-error {
    margin-top: 8px;
    color: var(--error);
    font-size: 12px;
  }
  .explorer-dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 18px;
  }
  .explorer-dialog-actions button {
    min-width: 76px;
    min-height: 30px;
    padding: 5px 10px;
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
  }
  .explorer-dialog-actions button:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }
  .explorer-dialog-actions button:disabled {
    cursor: default;
    opacity: 0.55;
  }
  .explorer-dialog-actions .primary {
    border-color: var(--accent);
    background: var(--accent);
    color: white;
  }
  .explorer-dialog-actions .danger {
    border-color: var(--error);
    background: var(--error);
  }
</style>
