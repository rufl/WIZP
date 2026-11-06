<script lang="ts">
  // Svelte 5 runes mode (L4: converted from store subscriptions)
  import { tick } from 'svelte';
  import {
    gitBranch,
    lineColumn,
    language,
    indentation,
    encoding,
    eol,
    projectPath,
    lspStatus,
    vimMode,
    language as languageStore,
    indentation as indentationStore,
    encoding as encodingStore,
    eol as eolStore,
  } from '../stores';

  function fromStore<T>(store: { subscribe: (fn: (v: T) => void) => () => void }) {
    let val: T = $state.raw<T>(undefined as unknown as T);
    $effect(() => {
      const unsub = store.subscribe((v) => {
        val = v;
      });
      return unsub;
    });
    return {
      get value() {
        return val;
      },
    };
  }

  const _gitBranch = fromStore(gitBranch);
  const _lineColumn = fromStore(lineColumn);
  const _language = fromStore(language);
  const _indentation = fromStore(indentation);
  const _encoding = fromStore(encoding);
  const _eol = fromStore(eol);
  const _projectPath = fromStore(projectPath);
  const _lspStatus = fromStore(lspStatus);
  const _vimMode = fromStore(vimMode);

  let errors = $state(0);
  let warnings = $state(0);

  let dynamicItems = $state<Record<string, any>>({});
  let picker = $state<null | 'language' | 'indentation' | 'encoding' | 'eol'>(null);
  let pickerTrigger: HTMLButtonElement | null = null;
  let pickerEl = $state<HTMLElement>();
  const pickerOptions = {
    language: [
      ['Plain Text', 'plaintext'],
      ['TypeScript', 'typescript'],
      ['JavaScript', 'javascript'],
      ['JSON', 'json'],
      ['HTML', 'html'],
      ['CSS', 'css'],
      ['Markdown', 'markdown'],
      ['Python', 'python'],
      ['Rust', 'rust'],
      ['Go', 'go'],
    ],
    indentation: [
      ['Spaces: 2', 'spaces:2'],
      ['Spaces: 4', 'spaces:4'],
      ['Tabs', 'tabs'],
    ],
    encoding: [
      ['UTF-8', 'UTF-8'],
      ['UTF-16 LE', 'UTF-16 LE'],
      ['Windows-1252', 'Windows-1252'],
    ],
    eol: [
      ['LF', 'LF'],
      ['CRLF', 'CRLF'],
      ['CR', 'CR'],
    ],
  } as const;

  function saveSetting(key: string, value: unknown) {
    try {
      const settings = JSON.parse(localStorage.getItem('wizp-settings') || '{}');
      settings[key] = value;
      localStorage.setItem('wizp-settings', JSON.stringify(settings));
    } catch {
      // Status preference persistence is best effort.
    }
  }

  function selectPicker(value: string) {
    if (!picker) return;
    if (picker === 'language') {
      const label = pickerOptions.language.find((item) => item[1] === value)?.[0] || value;
      languageStore.set(label);
      (window as any).__setActiveEditorLanguage?.(value);
    } else if (picker === 'indentation') {
      const [mode, rawSize] = value.split(':');
      const tabSize = mode === 'tabs' ? 4 : Number(rawSize);
      indentationStore.set(mode === 'tabs' ? 'Tabs' : `Spaces: ${tabSize}`);
      (window as any).__setActiveEditorOptions?.({ tabSize, insertSpaces: mode !== 'tabs' });
      saveSetting('tabSize', tabSize);
      saveSetting('insertSpaces', mode !== 'tabs');
    } else if (picker === 'encoding') {
      encodingStore.set(value);
      saveSetting('encoding', value);
    } else {
      eolStore.set(value);
      saveSetting('eol', value);
    }
    closePicker();
  }

  function openPicker(
    kind: 'language' | 'indentation' | 'encoding' | 'eol',
    trigger: HTMLButtonElement,
  ) {
    picker = kind;
    pickerTrigger = trigger;
    void tick().then(() => pickerEl?.querySelector<HTMLButtonElement>('button')?.focus());
  }

  function closePicker() {
    picker = null;
    const trigger = pickerTrigger;
    pickerTrigger = null;
    requestAnimationFrame(() => trigger?.isConnected && trigger.focus());
  }

  function handlePickerKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      closePicker();
      return;
    }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const options = Array.from(pickerEl?.querySelectorAll<HTMLButtonElement>('button') || []);
    if (options.length === 0) return;
    const current = Math.max(0, options.indexOf(document.activeElement as HTMLButtonElement));
    const index =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? options.length - 1
          : (current + (event.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
    options[index]?.focus();
  }

  $effect(() => {
    (window as any).__setStatusBarItem = (id: string, item: any) => {
      if (item === null) {
        delete dynamicItems[id];
      } else {
        dynamicItems[id] = item;
      }
      dynamicItems = { ...dynamicItems };
    };

    const handler = (e: Event) => {
      const { errors: eCount, warnings: wCount } = (e as CustomEvent).detail || {};
      errors = eCount ?? 0;
      warnings = wCount ?? 0;
    };
    document.addEventListener('problems:updated', handler);
    return () => document.removeEventListener('problems:updated', handler);
  });
</script>

<footer
  class="status-bar grid grid-cols-[minmax(0,1fr)_auto] items-center w-full h-7 bg-sidebar text-fg text-[11px] px-2 select-none z-[100] border-t border-white/[0.08] shrink-0 overflow-hidden"
  aria-label="Editor status"
>
  <div class="flex items-center gap-1.5 shrink min-w-0 pr-3">
    {#if _vimMode.value}
      <span
        id="vim-status-container"
        class="flex items-center px-2 py-0.5 rounded font-bold text-[#4ec9b0] whitespace-nowrap bg-black/30 border border-[#4ec9b0]/30 mr-1 shrink-0"
      >
        <span id="vim-status">-- NORMAL --</span>
      </span>
    {/if}
    <span
      class="status-project flex items-center px-2 py-0.5 whitespace-nowrap shrink truncate"
      title="Project"
    >
      <span class="codicon codicon-folder mr-1.5 text-xs shrink-0"></span>
      <span class="truncate">{_projectPath.value || 'Untitled'}</span>
    </span>
    <span
      class="status-branch flex items-center px-2 py-0.5 whitespace-nowrap shrink-0"
      title="Current branch"
    >
      <span class="codicon codicon-source-control mr-1.5 text-xs"></span>
      {_gitBranch.value}
    </span>
    <span
      class="status-problems flex items-center gap-1 px-2 py-0.5 whitespace-nowrap shrink-0"
      title="Problem counts"
    >
      <span class="codicon codicon-error text-error text-xs"></span>
      <span class="mr-2">{errors}</span>
      <span class="codicon codicon-warning text-warn text-xs"></span>
      <span>{warnings}</span>
    </span>
    {#each Object.values(dynamicItems) as item (item.command || item.label)}
      {#if item.command}
        <button
          type="button"
          class="status-action"
          onclick={() => (window as any).__triggerEditorAction?.(item.command)}
          title={item.tooltip || item.text || item.command}
        >
          {item.text}
        </button>
      {:else}
        <span class="status-static" title={item.tooltip || ''}>{item.text}</span>
      {/if}
    {/each}
  </div>
  <div class="flex items-center justify-end gap-1.5 shrink-0">
    <button
      type="button"
      class="status-action status-position text-dim"
      title="Go to Line/Column (Ctrl+G)"
      onclick={() => (window as any).__showQuickOpenAt?.(':')}
    >
      {_lineColumn.value}
    </button>
    <button
      type="button"
      class="status-action status-detail text-dim"
      title="Select Indentation"
      aria-haspopup="dialog"
      aria-expanded={picker === 'indentation'}
      onclick={(event) => openPicker('indentation', event.currentTarget)}
    >
      {_indentation.value}
    </button>
    <button
      type="button"
      class="status-action status-detail text-dim"
      title="Change Language Mode"
      aria-haspopup="dialog"
      aria-expanded={picker === 'language'}
      onclick={(event) => openPicker('language', event.currentTarget)}
    >
      {_language.value}
    </button>
    {#if _lspStatus.value}
      <span
        class="status-secondary flex items-center px-2 py-0.5 whitespace-nowrap text-dim"
        title="LSP: {_lspStatus.value}"
      >
        <span
          class="codicon codicon-circle-filled text-[#4ec9b0] mr-1.5 text-[9px]"
          aria-hidden="true"
        ></span>{_lspStatus.value}
      </span>
    {/if}
    <button
      type="button"
      class="status-action status-secondary text-dim"
      title="Select Encoding"
      aria-haspopup="dialog"
      aria-expanded={picker === 'encoding'}
      onclick={(event) => openPicker('encoding', event.currentTarget)}
    >
      {_encoding.value}
    </button>
    <button
      type="button"
      class="status-action status-secondary text-dim"
      title="Select End of Line Sequence"
      aria-haspopup="dialog"
      aria-expanded={picker === 'eol'}
      onclick={(event) => openPicker('eol', event.currentTarget)}
    >
      {_eol.value}
    </button>
  </div>
</footer>

{#if picker}
  <div
    bind:this={pickerEl}
    class="status-picker"
    role="dialog"
    tabindex="-1"
    aria-modal="false"
    aria-label={`Select ${picker}`}
    onkeydown={handlePickerKeydown}
  >
    <div class="status-picker-title">Select {picker}</div>
    {#each pickerOptions[picker] as option (option[1])}
      {@const selected =
        option[1] ===
        (picker === 'language'
          ? _language.value
          : picker === 'indentation'
            ? _indentation.value
            : picker === 'encoding'
              ? _encoding.value
              : _eol.value)}
      <button
        type="button"
        class="status-picker-option"
        aria-pressed={selected}
        onclick={() => selectPicker(option[1])}
      >
        <span>{option[0]}</span>
        {#if selected}
          <span class="status-picker-check codicon codicon-check" aria-hidden="true"></span>
        {/if}
      </button>
    {/each}
  </div>
{/if}

<svelte:window onkeydown={(event) => event.key === 'Escape' && picker && closePicker()} />

<style>
  .status-picker {
    position: fixed;
    right: 10px;
    bottom: 34px;
    z-index: 10001;
    min-width: 190px;
    padding: 6px;
    border: 1px solid var(--panel-border, #454545);
    border-radius: 6px;
    background: var(--popover-bg, #252526);
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
  }
  .status-action {
    display: flex;
    align-items: center;
    padding: 2px 8px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    white-space: nowrap;
    transition: background-color 120ms ease;
  }
  .status-action:hover,
  .status-action:focus-visible {
    outline: none;
    background: rgba(255, 255, 255, 0.1);
  }
  .status-action:focus-visible {
    box-shadow: inset 0 0 0 2px var(--accent);
  }
  .status-static {
    display: flex;
    align-items: center;
    padding: 2px 8px;
    white-space: nowrap;
  }
  .status-picker-title {
    padding: 6px 8px;
    color: var(--breadcrumb-dim, #999);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .status-picker-option {
    display: flex;
    justify-content: space-between;
    width: 100%;
    padding: 7px 8px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: var(--fg, #ccc);
    cursor: pointer;
    text-align: left;
    font-size: 12px;
  }
  .status-picker-option:hover {
    background: rgba(255, 255, 255, 0.08);
  }
  .status-picker-check {
    color: var(--accent, #4fc1ff);
  }
  @media (max-width: 1100px) {
    .status-project {
      max-width: 180px;
    }
    .status-secondary {
      display: none;
    }
  }
  @media (max-width: 760px) {
    .status-project,
    .status-branch,
    .status-detail {
      display: none;
    }
  }
  :global(html[data-ui-scale='large']) .status-project,
  :global(html[data-ui-scale='large']) .status-branch,
  :global(html[data-ui-scale='large']) .status-secondary,
  :global(html[data-ui-scale='large']) .status-detail {
    display: none;
  }
</style>
