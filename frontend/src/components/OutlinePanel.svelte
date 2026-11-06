<script lang="ts">
  import { sendRpc } from '../../bridge';

  let outlineSymbols = $state<any[]>([]);
  let currentUri = $state('');
  let filterText = $state('');
  let sortMode = $state('position');
  let followCursor = $state(true);
  let activeLine = $state<number | null>(null);

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
      15: 'symbol-string',
      16: 'symbol-number',
      17: 'symbol-boolean',
      18: 'symbol-array',
    };
    return map[kind] || 'symbol-misc';
  };

  $effect(() => {
    const handleEditorChange = async (e: Event) => {
      const detail = (e as CustomEvent).detail;
      const uri = detail?.uri;
      if (!uri || uri === currentUri) return;
      currentUri = uri;
      activeLine = null;
      try {
        const res = await sendRpc('textDocument/documentSymbol', { uri });
        outlineSymbols = Array.isArray(res) ? res : [];
      } catch {
        outlineSymbols = [];
      }
    };
    const handleCursor = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (!followCursor || !detail || detail.uri !== currentUri) return;
      activeLine = typeof detail.line === 'number' ? detail.line : null;
    };
    window.addEventListener('wizpEditorChanged', handleEditorChange);
    window.addEventListener('wizpEditorCursorChanged', handleCursor);
    return () => {
      window.removeEventListener('wizpEditorChanged', handleEditorChange);
      window.removeEventListener('wizpEditorCursorChanged', handleCursor);
    };
  });

  function symbolLine(sym: any) {
    return (
      sym.location?.range?.start?.line ??
      sym.selectionRange?.start?.line ??
      sym.range?.start?.line ??
      0
    );
  }

  function flattenSymbols(symbols: any[], depth = 0): any[] {
    const out: any[] = [];
    for (const sym of symbols) {
      out.push({ ...sym, depth });
      if (Array.isArray(sym.children)) out.push(...flattenSymbols(sym.children, depth + 1));
    }
    return out;
  }

  function visibleSymbols() {
    let items = flattenSymbols(outlineSymbols);
    const q = filterText.trim().toLowerCase();
    if (q)
      items = items.filter((sym) =>
        String(sym.name || '')
          .toLowerCase()
          .includes(q),
      );
    if (sortMode === 'name') {
      items = [...items].sort(
        (a, b) =>
          String(a.name || '').localeCompare(String(b.name || '')) || symbolLine(a) - symbolLine(b),
      );
    } else if (sortMode === 'kind') {
      items = [...items].sort(
        (a, b) =>
          (a.kind || 99) - (b.kind || 99) ||
          String(a.name || '').localeCompare(String(b.name || '')),
      );
    }
    return items;
  }

  function isActiveSymbol(sym: any) {
    if (activeLine === null) return false;
    const ordered = flattenSymbols(outlineSymbols).sort(
      (a, b) => symbolLine(a) - symbolLine(b) || (b.depth || 0) - (a.depth || 0),
    );
    let active: any = null;
    for (const item of ordered) {
      if (symbolLine(item) <= activeLine) active = item;
      else break;
    }
    return !!active && active.name === sym.name && symbolLine(active) === symbolLine(sym);
  }

  function gotoSymbol(sym: any) {
    (window as any).__lastOutlineSymbol = sym;
    const ed = (window as any).__getActiveEditor?.();
    if (!ed) return;
    const line = sym.location?.range?.start?.line ?? sym.selectionRange?.start?.line ?? 0;
    const col = sym.location?.range?.start?.character ?? sym.selectionRange?.start?.character ?? 0;
    ed.revealLineInCenter(line + 1);
    ed.setPosition({ lineNumber: line + 1, column: col + 1 });
    ed.focus();
  }

  (window as any).__setOutlineSymbolsForSmoke = (uri: string, symbols: any[]) => {
    currentUri = uri;
    outlineSymbols = Array.isArray(symbols) ? symbols : [];
    activeLine = null;
  };

  (window as any).__setOutlineCursorForSmoke = (line: number) => {
    if (!followCursor) return;
    activeLine = Number.isFinite(line) ? line : null;
  };
</script>

<div class="flex flex-col flex-1 overflow-hidden">
  <div class="outline-toolbar">
    <input
      class="outline-filter"
      bind:value={filterText}
      placeholder="Filter"
      aria-label="Filter outline symbols"
    />
    <select class="outline-sort" bind:value={sortMode} title="Sort symbols">
      <option value="position">Position</option>
      <option value="name">Name</option>
      <option value="kind">Kind</option>
    </select>
    <button
      class="outline-toggle {followCursor ? 'active' : ''}"
      title="Follow Cursor"
      onclick={() => (followCursor = !followCursor)}
    >
      <span class="codicon codicon-location" aria-hidden="true"></span>
    </button>
  </div>
  {#if outlineSymbols.length === 0}
    <div class="p-4 text-[11px] text-dim italic">
      {currentUri ? 'No symbols found.' : 'Open a file to see its outline.'}
    </div>
  {:else if visibleSymbols().length === 0}
    <div class="p-4 text-[11px] text-dim italic">No matching symbols.</div>
  {:else}
    <div class="flex-1 overflow-y-auto">
      {#each visibleSymbols() as sym (sym.name + ':' + (sym.line ?? sym.startLine ?? 0))}
        <div
          class="outline-row {isActiveSymbol(sym) ? 'outline-row-active' : ''}"
          style="padding-left: {16 + (sym.depth || 0) * 14}px"
          role="button"
          tabindex="0"
          onclick={() => gotoSymbol(sym)}
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              gotoSymbol(sym);
            }
          }}
          title={sym.name}
          data-symbol-name={sym.name}
          data-symbol-kind={sym.kind}
          data-symbol-depth={sym.depth || 0}
        >
          <span class="codicon codicon-{symbolIcon(sym.kind)} outline-icon" aria-hidden="true"
          ></span>
          <span class="outline-name">{sym.name}</span>
          {#if sym.containerName}
            <span class="outline-container">{sym.containerName}</span>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .outline-row {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 3px 10px 3px 16px;
    font-size: 12px;
    color: var(--fg, #ccc);
    cursor: pointer;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .outline-row:hover {
    background: rgba(255, 255, 255, 0.05);
  }
  .outline-row-active {
    background: rgba(0, 122, 204, 0.18);
    color: var(--fg, #fff);
  }
  .outline-icon {
    font-size: 14px;
    color: var(--accent, #007acc);
    flex-shrink: 0;
  }
  .outline-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .outline-container {
    font-size: 10px;
    color: var(--breadcrumb-dim, #888);
    flex-shrink: 0;
    margin-left: 4px;
  }
  .outline-toolbar {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto auto;
    gap: 4px;
    padding: 6px 8px;
    border-bottom: 1px solid var(--border, rgba(255, 255, 255, 0.08));
    background: rgba(0, 0, 0, 0.16);
  }
  .outline-filter,
  .outline-sort {
    min-width: 0;
    height: 24px;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.12));
    background: transparent;
    color: var(--fg, #ccc);
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 2px;
  }
  .outline-toggle {
    width: 24px;
    height: 24px;
    border: 1px solid var(--border, rgba(255, 255, 255, 0.12));
    background: transparent;
    color: var(--breadcrumb-dim, #888);
    border-radius: 2px;
    cursor: pointer;
  }
  .outline-toggle.active {
    color: var(--accent, #007acc);
    background: rgba(255, 255, 255, 0.06);
  }
</style>
