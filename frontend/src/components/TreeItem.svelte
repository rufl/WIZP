<script lang="ts">
  import { getIcon } from '../utils';

  const {
    item,
    depth,
    position,
    setSize,
    revision,
    gitStatus,
    selectedPath,
    onSelect,
    onExpand,
    onRename,
    onDelete,
    openFile,
    onContext,
  } = $props<{
    item: any;
    depth: number;
    position: number;
    setSize: number;
    revision: number;
    gitStatus?: Record<string, string>;
    onSelect: (path: string, kind: string) => void;
    onExpand: (item: any) => Promise<any[]>;
    onRename: (item: any) => void;
    onDelete: (item: any) => void;
    openFile: (path: string) => void;
    onContext: (event: MouseEvent | KeyboardEvent, item: any) => void;
  }>();

  let children = $state<any[]>([]);
  let isExpanded = $state(false);
  let loaded = $state(false);
  let loading = $state(false);
  let loadError = $state('');

  $effect(() => {
    void revision;
    isExpanded = false;
  });

  $effect(() => {
    if (Array.isArray(item.children)) {
      children = item.children;
      loaded = true;
    } else if (item.kind === 'directory' && isExpanded && !loading && !loadError) {
      void loadChildren();
    }
  });

  async function loadChildren() {
    if (loading) return false;
    loading = true;
    loadError = '';
    try {
      children = await onExpand(item);
      loaded = true;
      return true;
    } catch {
      children = [];
      loaded = false;
      loadError = `Could not open ${item.name}.`;
      return false;
    } finally {
      loading = false;
    }
  }

  async function activate() {
    onSelect(item.path, item.kind);
    if (item.kind !== 'directory') {
      openFile(item.path);
      return;
    }
    if (isExpanded) {
      isExpanded = false;
      if (selectedPath.startsWith(`${item.path}/`) || selectedPath.startsWith(`${item.path}\\`)) {
        onSelect(item.path, item.kind);
      }
      return;
    }
    if (!loaded) await loadChildren();
    isExpanded = true;
  }

  function visibleTreeItems(target: HTMLElement) {
    return Array.from(
      target.closest('[role="tree"]')?.querySelectorAll<HTMLElement>('[role="treeitem"]') || [],
    );
  }

  function focusTreeItem(target?: HTMLElement) {
    if (!target) return;
    target.focus();
    const path = target.dataset.path;
    const kind = target.dataset.kind;
    if (path && kind) onSelect(path, kind);
  }

  function focusParent(current: HTMLElement) {
    const items = visibleTreeItems(current);
    const index = items.indexOf(current);
    for (let cursor = index - 1; cursor >= 0; cursor--) {
      if (Number(items[cursor].getAttribute('aria-level')) === depth) {
        focusTreeItem(items[cursor]);
        return;
      }
    }
  }

  function handleKeydown(event: KeyboardEvent) {
    const current = event.currentTarget as HTMLElement;
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      void activate();
    } else if (event.key === 'ArrowRight' && item.kind === 'directory') {
      event.preventDefault();
      if (!isExpanded) {
        void activate();
      } else {
        const items = visibleTreeItems(current);
        const next = items[items.indexOf(current) + 1];
        if (Number(next?.getAttribute('aria-level')) === depth + 2) focusTreeItem(next);
      }
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault();
      if (item.kind === 'directory' && isExpanded) {
        isExpanded = false;
        if (selectedPath.startsWith(`${item.path}/`) || selectedPath.startsWith(`${item.path}\\`)) {
          onSelect(item.path, item.kind);
        }
      } else focusParent(current);
    } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      const items = visibleTreeItems(current);
      const index = items.indexOf(current);
      if (index < 0 || items.length === 0) return;
      const targetIndex =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? items.length - 1
            : Math.max(0, Math.min(items.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)));
      focusTreeItem(items[targetIndex]);
    } else if (event.key === 'F2') {
      event.preventDefault();
      onRename(item);
    } else if (event.key === 'Delete') {
      event.preventDefault();
      onDelete(item);
    } else if (event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) {
      event.preventDefault();
      onContext(event, item);
    }
  }

  const status = $derived(gitStatus?.[item.path] || '');
  const accessibleLabel = $derived(
    `${item.kind === 'directory' ? 'Folder' : 'File'} ${item.name}${status ? `, Git status ${status}` : ''}`,
  );
</script>

<div
  class="tree-row"
  class:directory={item.kind === 'directory'}
  class:selected={selectedPath === item.path}
  style="padding-left: {20 + depth * 16}px;"
  data-path={item.path}
  data-kind={item.kind}
  title={item.path}
  onclick={() => void activate()}
  onfocus={() => onSelect(item.path, item.kind)}
  onkeydown={handleKeydown}
  oncontextmenu={(event) => onContext(event, item)}
  role="treeitem"
  tabindex={selectedPath === item.path ? 0 : -1}
  aria-label={accessibleLabel}
  aria-level={depth + 1}
  aria-posinset={position}
  aria-setsize={setSize}
  aria-selected={selectedPath === item.path}
  aria-expanded={item.kind === 'directory' ? isExpanded : undefined}
>
  {#if item.kind === 'directory'}
    <span class="codicon codicon-chevron-{isExpanded ? 'down' : 'right'}" aria-hidden="true"></span>
    <span class="codicon codicon-folder" aria-hidden="true"></span>
  {:else}
    <span class="codicon {getIcon(item.name)} file-icon" aria-hidden="true"></span>
  {/if}
  <span class="tree-label">{item.name}</span>
  {#if status && item.kind !== 'directory'}
    <span class="git-status git-{status[0] || '?'}" aria-hidden="true">{status}</span>
  {/if}
</div>

{#if item.kind === 'directory' && isExpanded}
  {#if loading}
    <div class="tree-message" style="padding-left: {20 + (depth + 1) * 16}px;" role="status">
      Loading…
    </div>
  {:else if loadError}
    <div
      class="tree-message tree-error"
      style="padding-left: {20 + (depth + 1) * 16}px;"
      role="alert"
    >
      <span>{loadError}</span>
      <button type="button" onclick={() => void loadChildren()}>Retry</button>
    </div>
  {:else if loaded && children.length === 0}
    <div class="tree-message" style="padding-left: {20 + (depth + 1) * 16}px;">
      Folder is empty.
    </div>
  {:else}
    {#each children as child, childIndex (child.path)}
      <!-- svelte-ignore svelte_self_deprecated -->
      <svelte:self
        item={child}
        depth={depth + 1}
        position={childIndex + 1}
        setSize={children.length}
        {revision}
        {gitStatus}
        {selectedPath}
        {onSelect}
        {onExpand}
        {onRename}
        {onDelete}
        {openFile}
        {onContext}
      />
    {/each}
  {/if}
{/if}

<style>
  .tree-row {
    display: flex;
    min-height: 24px;
    align-items: center;
    padding-block: 2px;
    color: var(--sidebar-fg);
    cursor: pointer;
    font-size: 13px;
    white-space: nowrap;
  }
  .tree-row:hover,
  .tree-row.selected {
    background: var(--editor-selection);
  }
  .tree-row:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  .tree-row > .codicon {
    flex-shrink: 0;
    margin-right: 4px;
    font-size: 14px;
  }
  .tree-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .file-icon {
    width: 16px;
    margin-right: 6px !important;
    font-size: 12px !important;
    text-align: center;
  }
  .git-status {
    margin-left: auto;
    padding-inline: 4px;
    border-radius: 2px;
    font-size: 10px;
  }
  .git-M {
    color: #e2b714;
  }
  .git-A {
    color: #4ec9b0;
  }
  .git-D {
    color: #f48771;
  }
  .git-\? {
    color: #cca700;
  }
  .tree-message {
    display: flex;
    min-height: 24px;
    align-items: center;
    gap: 8px;
    padding-right: 8px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
  }
  .tree-error {
    color: var(--error);
  }
  .tree-message button {
    min-height: 24px;
    padding-inline: 6px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
  }
  .tree-message button:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 1px;
  }
</style>
