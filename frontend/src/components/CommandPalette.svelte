<script lang="ts">
  import { tick } from 'svelte';
  import { sendRpc } from '../../bridge';
  import { zenMode, vimMode, switchSidebarView, isSidebarVisible } from '../stores';

  let isOpen = $state(false);
  let mode = $state<'command' | 'file' | 'line' | 'symbol' | 'workspace-symbol'>('command');
  let query = $state('');
  let items = $state<any[]>([]);
  let selectedIdx = $state(0);
  let inputEl = $state<HTMLInputElement>();
  let returnFocus: HTMLElement | null = null;

  let cachedExtensionCommands = $state<any[]>([]);
  let extensionCommandsLoaded = $state(false);
  let renderTicket = 0;

  const activeOptionId = $derived(
    items[selectedIdx] ? `quick-input-option-${selectedIdx}` : undefined,
  );
  const paletteLabel = $derived(
    mode === 'command'
      ? 'Command Palette'
      : mode === 'line'
        ? 'Go to Line'
        : mode === 'symbol'
          ? 'Go to Symbol in Editor'
          : mode === 'workspace-symbol'
            ? 'Go to Symbol in Workspace'
            : 'Quick Open',
  );

  const builtInCommands = [
    { label: 'Preferences: Open Settings (UI)', action: () => (window as any).__openSettings?.() },
    {
      label: 'View: Toggle Primary Side Bar',
      hint: 'Ctrl+B',
      action: () => (window as any).__toggleSidebar?.(),
    },
    {
      label: 'View: Toggle Panel',
      hint: 'Ctrl+J',
      action: () => (window as any).__togglePanel?.(),
    },
    {
      label: 'View: Toggle Zen Mode',
      hint: 'F11',
      action: () => {
        zenMode.update((z) => {
          const next = !z;
          if (next) document.documentElement.requestFullscreen().catch(() => {});
          else document.exitFullscreen().catch(() => {});
          return next;
        });
      },
    },
    { label: 'Preferences: Toggle Vim Mode', action: () => vimMode.update((v) => !v) },
    { label: 'File: New File', hint: 'Ctrl+N', action: () => (window as any).__newFile?.() },
    { label: 'File: Save', hint: 'Ctrl+S', action: () => (window as any).__saveActiveEditor?.() },
    {
      label: 'File: Save As...',
      hint: 'Ctrl+Shift+S',
      action: () => (window as any).__saveActiveEditorAs?.(),
    },
    { label: 'File: Revert File', action: () => (window as any).__revertActiveEditor?.() },
    {
      label: 'File: Close Editor',
      hint: 'Ctrl+W',
      action: () => (window as any).__closeActiveEditor?.(),
    },
    { label: 'File: Close All Editors', action: () => (window as any).__closeAllEditors?.() },
    { label: 'Go to Line...', hint: 'Ctrl+G', action: () => openQuickOpenAt(':') },
    {
      label: 'Go to Symbol in Editor...',
      hint: 'Ctrl+Shift+O',
      action: () => openQuickOpenAt('@'),
    },
    { label: 'Go to Symbol in Workspace...', hint: 'Ctrl+T', action: () => openQuickOpenAt('#') },
    {
      label: 'Developer: Reload Window',
      action: async () => {
        try {
          await (window as any).__persistEditorSession?.();
        } finally {
          location.reload();
        }
      },
    },
  ];

  async function loadExtensionCommands() {
    if (extensionCommandsLoaded) return;
    try {
      const res = await sendRpc('extension/commands', {});
      const cmds = (res?.commands || []) as any[];
      cachedExtensionCommands = cmds.map((c: any) => ({
        label: c.title || c.command,
        hint: c.enabled === false ? 'Disabled' : 'Extension',
        disabled: c.enabled === false,
        action: () => {
          if (c.enabled === false) return;
          sendRpc('extension/execute', { command: c.command }).catch(() => {});
        },
      }));
      // Extension task providers use the same reconnect-aware RPC transport.
      const tasks = await sendRpc('extension/tasks', {});
      if (Array.isArray(tasks)) {
        tasks.forEach((t: any) => {
          cachedExtensionCommands.push({
            label: `Task: ${t.name}`,
            hint: 'Task Provider',
            action: () => {
              sendRpc('extension/uiReply', { id: 0, value: t }).catch(() => {});
              window.dispatchEvent(new CustomEvent('wizpTaskExecute', { detail: t }));
            },
          });
        });
      }
    } catch {
      // Extension commands are optional; built-in commands remain available.
    }
    extensionCommandsLoaded = true;
  }

  async function focusQuickInput() {
    await tick();
    inputEl?.focus({ preventScroll: true });
    inputEl?.setSelectionRange(query.length, query.length);
    requestAnimationFrame(() => {
      if (document.activeElement !== inputEl) {
        inputEl?.focus({ preventScroll: true });
        inputEl?.setSelectionRange(query.length, query.length);
      }
    });
  }

  async function openCommandPalette() {
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    mode = 'command';
    query = '>';
    isOpen = true;
    selectedIdx = 0;
    renderCommands();
    await focusQuickInput();
    await loadExtensionCommands();
    renderCommands();
  }

  async function openQuickOpen() {
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    mode = 'file';
    query = '';
    isOpen = true;
    selectedIdx = 0;
    void renderFileSearch();
    await focusQuickInput();
  }

  async function openQuickOpenAt(prefix: string) {
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (prefix === ':') {
      mode = 'line';
      query = ':';
    } else if (prefix === '@') {
      mode = 'symbol';
      query = '@';
    } else if (prefix === '#') {
      mode = 'workspace-symbol';
      query = '#';
    } else {
      mode = 'file';
      query = prefix;
    }
    isOpen = true;
    selectedIdx = 0;
    void renderSpecialMode();
    await focusQuickInput();
  }

  function close() {
    isOpen = false;
    const target = returnFocus;
    returnFocus = null;
    requestAnimationFrame(() => {
      if (target?.isConnected) target.focus();
      else (window as any).__editorFocus?.();
    });
  }

  // Simple fuzzy match score: consecutive matches + word boundary bonus
  function fuzzyScore(label: string, q: string): number {
    const l = label.toLowerCase(),
      u = q.toLowerCase();
    let score = 0,
      si = 0,
      prev = -2;
    for (let i = 0; i < u.length; i++) {
      const ci = l.indexOf(u[i], si);
      if (ci === -1) return -1; // no match
      score += ci === prev + 1 ? 5 : 1; // consecutive bonus
      if (ci === 0 || l[ci - 1] === ' ' || l[ci - 1] === '-' || l[ci - 1] === '_') score += 3; // word start bonus
      prev = ci;
      si = ci + 1;
    }
    return score;
  }

  async function renderSpecialMode() {
    const ticket = ++renderTicket;
    if (mode === 'line') {
      const lineStr = query.substring(1).trim();
      const lineNum = parseInt(lineStr);
      if (!isNaN(lineNum) && lineNum > 0) {
        items = [
          {
            label: `Go to line ${lineNum}`,
            hint: 'Press Enter',
            action: () => {
              (window as any).__triggerEditorAction?.('editor.action.gotoLine');
              close();
            },
          },
        ];
        // Actually jump directly
        const ed = (window as any).__getActiveEditor?.();
        if (ed) {
          items = [
            {
              label: `Go to line ${lineNum}`,
              hint: 'in current file',
              action: () => {
                ed.revealLineInCenter(lineNum);
                ed.setPosition({ lineNumber: lineNum, column: 1 });
                close();
              },
            },
          ];
        }
      } else {
        items = [{ label: 'Type a line number to jump to', hint: 'e.g. :42' }];
      }
    } else if (mode === 'symbol') {
      const q = query.substring(1).toLowerCase().trim();
      try {
        const gid = (window as any).__getActiveGroupId?.();
        const g = (window as any).__getGroup?.(gid);
        const uri = g?.activeEditorId
          ? g.editors.find((e: any) => e.id === g.activeEditorId)?.uri
          : null;
        if (!uri) {
          items = [{ label: 'No active file' }];
          return;
        }
        const res = await sendRpc('textDocument/documentSymbol', { uri });
        if (ticket !== renderTicket) return;
        const syms = Array.isArray(res) ? res : [];
        const filtered = q ? syms.filter((s: any) => fuzzyScore(s.name, q) >= 0) : syms;
        items = filtered.map((s: any) => ({
          label: s.name,
          hint: s.containerName || '',
          icon:
            s.kind === 5
              ? 'symbol-class'
              : s.kind === 6
                ? 'symbol-method'
                : s.kind === 12
                  ? 'symbol-function'
                  : 'symbol-misc',
          action: () => {
            const ed = (window as any).__getActiveEditor?.();
            if (ed && s.location?.range) {
              ed.revealLineInCenter(s.location.range.start.line + 1);
              ed.setPosition({
                lineNumber: s.location.range.start.line + 1,
                column: s.location.range.start.character + 1,
              });
            }
            close();
          },
        }));
      } catch {
        if (ticket !== renderTicket) return;
        items = [];
      }
    } else if (mode === 'workspace-symbol') {
      const q = query.substring(1).toLowerCase().trim();
      try {
        const res = await sendRpc('workspace/symbol', { query: q });
        if (ticket !== renderTicket) return;
        const syms = Array.isArray(res) ? res : [];
        items = syms.slice(0, 30).map((s: any) => ({
          label: s.name,
          hint: s.location?.uri?.replace('file://', '') || '',
          icon: 'symbol-misc',
          action: () => {
            (window as any).__openFile?.(s.location?.uri?.replace('file://', ''));
            close();
          },
        }));
        if (items.length === 0) items = [{ label: 'No symbols found for: ' + q }];
      } catch {
        if (ticket !== renderTicket) return;
        items = [];
      }
    }
    selectedIdx = 0;
  }

  function renderCommands() {
    renderTicket++;
    if (mode === 'command') {
      const q = query.substring(1).toLowerCase().trim();
      const all = [...builtInCommands, ...cachedExtensionCommands];
      if (q) {
        const scored = all
          .map((c) => ({ item: c, score: fuzzyScore(c.label, q) }))
          .filter((s) => s.score >= 0);
        scored.sort((a, b) => b.score - a.score);
        items = scored.slice(0, 20).map((s) => s.item);
      } else {
        items = all;
      }
      selectedIdx = 0;
    }
  }

  async function renderFileSearch() {
    const ticket = ++renderTicket;
    const requestedQuery = query.trim().toLowerCase();
    try {
      const res = await sendRpc('file/search', { query: requestedQuery });
      if (ticket !== renderTicket) return;
      const files: any[] = res?.files || [];
      const q = requestedQuery;
      if (q) {
        const scored = files
          .map((f) => ({ item: f, score: fuzzyScore(f.name, q) }))
          .filter((s) => s.score >= 0);
        scored.sort((a, b) => b.score - a.score);
        items = scored.slice(0, 20).map((s) => ({
          label: s.item.name,
          hint: s.item.path,
          icon: s.item.kind === 'directory' ? 'folder' : 'file',
          action: () => {
            close();
            (window as any).__openFile?.(s.item.path);
          },
        }));
      } else {
        items = files.slice(0, 20).map((f: any) => ({
          label: f.name,
          hint: f.path,
          icon: f.kind === 'directory' ? 'folder' : 'file',
          action: () => {
            close();
            (window as any).__openFile?.(f.path);
          },
        }));
      }
    } catch {
      if (ticket !== renderTicket) return;
      items = [];
    }
    selectedIdx = 0;
  }

  function handleInput() {
    const q = query;
    if (q.startsWith('>')) {
      mode = 'command';
      renderCommands();
    } else if (q.startsWith(':')) {
      mode = 'line';
      void renderSpecialMode();
    } else if (q.startsWith('@')) {
      mode = 'symbol';
      void renderSpecialMode();
    } else if (q.startsWith('#')) {
      mode = 'workspace-symbol';
      void renderSpecialMode();
    } else {
      mode = 'file';
      void renderFileSearch();
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!isOpen) return;
    if (e.key === 'Escape') {
      close();
      return;
    }
    if (e.key === 'Enter') {
      if (!items[selectedIdx]?.disabled && items[selectedIdx]?.action) {
        items[selectedIdx].action();
        close();
      }
      return;
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (items.length === 0) return;
      selectedIdx = (selectedIdx + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      return;
    }
    if (e.key === 'Home' || e.key === 'End') {
      e.preventDefault();
      if (items.length > 0) selectedIdx = e.key === 'Home' ? 0 : items.length - 1;
      return;
    }
    if (e.key === 'Tab') {
      e.preventDefault();
      inputEl?.focus();
    }
  }

  // Expose to window for bridge callbacks (runes style)
  $effect(() => {
    const refreshExtensionCommands = () => {
      extensionCommandsLoaded = false;
      cachedExtensionCommands = [];
    };
    (window as any).__showCommandPalette = openCommandPalette;
    (window as any).__showQuickOpen = openQuickOpen;
    (window as any).__showQuickOpenAt = openQuickOpenAt;
    (window as any).__hideQuickInput = close;
    (window as any).__switchSidebarView = (view: string) => {
      if (!$isSidebarVisible) isSidebarVisible.update(() => true);
      switchSidebarView(view);
    };
    document.addEventListener('keydown', handleKeydown);
    document.addEventListener('extensions:refreshed', refreshExtensionCommands);

    return () => {
      document.removeEventListener('keydown', handleKeydown);
      document.removeEventListener('extensions:refreshed', refreshExtensionCommands);
    };
  });
</script>

{#if isOpen}
  <div
    id="quick-input"
    class="open"
    role="dialog"
    aria-modal="true"
    aria-labelledby="quick-input-title"
  >
    <h2 id="quick-input-title" class="visually-hidden">{paletteLabel}</h2>
    <input
      type="text"
      bind:this={inputEl}
      bind:value={query}
      oninput={handleInput}
      role="combobox"
      aria-autocomplete="list"
      aria-expanded="true"
      aria-controls="quick-input-list"
      aria-activedescendant={activeOptionId}
      aria-label={paletteLabel}
      placeholder={mode === 'command'
        ? '> Type a command...'
        : mode === 'line'
          ? ':42 — Go to line'
          : mode === 'symbol'
            ? '@ — Go to symbol in file'
            : mode === 'workspace-symbol'
              ? '# — Go to symbol in workspace'
              : 'Search files by name...'}
    />
    <div id="quick-input-list" role="listbox" aria-label={`${paletteLabel} results`}>
      {#each items as item, i (item.id || item.label || i)}
        <button
          type="button"
          id={`quick-input-option-${i}`}
          class="qi-item"
          class:selected={i === selectedIdx}
          class:disabled={item.disabled}
          role="option"
          aria-selected={i === selectedIdx}
          disabled={item.disabled}
          tabindex="-1"
          onmouseenter={() => (selectedIdx = i)}
          onclick={() => {
            if (item.action) item.action();
            close();
          }}
        >
          <span class="qi-label">
            {#if item.icon}<span class="codicon codicon-{item.icon}" aria-hidden="true"></span>{/if}
            {item.label}
          </span>
          {#if item.hint}<span class="qi-hint">{item.hint}</span>{/if}
        </button>
      {:else}
        <div class="qi-empty" role="status">No results</div>
      {/each}
    </div>
    <div class="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
      {items.length}
      {items.length === 1 ? 'result' : 'results'} available
    </div>
  </div>
{/if}

<style>
  #quick-input {
    position: fixed;
    top: 80px;
    left: 50%;
    transform: translateX(-50%);
    width: 600px;
    max-width: calc(100vw - 48px);
    background: #252526;
    border: 1px solid #3c3c3c;
    border-radius: 4px;
    z-index: 1000;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    display: none;
    flex-direction: column;
  }
  #quick-input.open {
    display: flex;
  }
  #quick-input input {
    width: 100%;
    padding: 8px 12px;
    background: #3c3c3c;
    border: none;
    color: var(--fg);
    font-size: 13px;
    outline: none;
    border-radius: 4px 4px 0 0;
    box-sizing: border-box;
  }
  #quick-input-list {
    max-height: 300px;
    overflow-y: auto;
  }
  .qi-item {
    width: 100%;
    border: 0;
    background: transparent;
    color: inherit;
    padding: 6px 12px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 13px;
    text-align: left;
  }
  .qi-item:hover,
  .qi-item.selected {
    background: var(--editor-selection);
  }
  .qi-item.disabled {
    opacity: 0.45;
    cursor: default;
  }
  .qi-item.disabled:hover {
    background: transparent;
  }
  .qi-label {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 6px;
    color: var(--fg);
  }
  .qi-hint {
    margin-left: 16px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
  }
  .qi-empty {
    padding: 10px 20px;
    color: var(--breadcrumb-dim);
  }
  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }
</style>
