<script lang="ts">
  import { tick } from 'svelte';

  const { prompt = null } = $props();

  let isOpen = $state(false);
  let items = $state<any[]>([]);
  let query = $state('');
  let selectedIdx = $state(0);
  let inputEl = $state<HTMLInputElement>();
  let returnFocus: HTMLElement | null = null;

  const filteredItems = $derived(
    items.filter(
      (item: any) =>
        item.label?.toLowerCase().includes(query.toLowerCase()) ||
        item.description?.toLowerCase().includes(query.toLowerCase()),
    ),
  );
  const dialogLabel = $derived(
    prompt?.options?.title || prompt?.options?.placeHolder || 'Select an option',
  );
  const activeOptionId = $derived(
    filteredItems[selectedIdx] ? `quick-pick-option-${selectedIdx}` : undefined,
  );

  $effect(() => {
    if (!prompt) return;
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    isOpen = true;
    items = prompt.items || [];
    query = '';
    selectedIdx = 0;
    void tick().then(() => inputEl?.focus());
  });

  $effect(() => {
    void query;
    selectedIdx = 0;
  });

  function close(value: any) {
    isOpen = false;
    if ((window as any).__uiReply) (window as any).__uiReply(prompt.id, value);
    const target = returnFocus;
    returnFocus = null;
    requestAnimationFrame(() => target?.isConnected && target.focus());
  }

  function handleKeydown(event: KeyboardEvent) {
    if (!isOpen) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      close(undefined);
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (filteredItems.length === 0) return;
      selectedIdx =
        (selectedIdx + (event.key === 'ArrowDown' ? 1 : -1) + filteredItems.length) %
        filteredItems.length;
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      if (filteredItems.length > 0) {
        selectedIdx = event.key === 'Home' ? 0 : filteredItems.length - 1;
      }
    } else if (event.key === 'Enter') {
      event.preventDefault();
      if (filteredItems[selectedIdx]) close(filteredItems[selectedIdx]);
    } else if (event.key === 'Tab') {
      event.preventDefault();
      inputEl?.focus();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if isOpen}
  <div class="quick-pick-layer">
    <div
      class="quick-pick-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="quick-pick-title"
    >
      <h2 id="quick-pick-title" class="visually-hidden">{dialogLabel}</h2>
      <div class="quick-pick-input-wrap">
        <input
          bind:this={inputEl}
          bind:value={query}
          role="combobox"
          aria-label={dialogLabel}
          aria-autocomplete="list"
          aria-expanded="true"
          aria-controls="quick-pick-list"
          aria-activedescendant={activeOptionId}
          placeholder={prompt?.options?.placeHolder || 'Type to filter...'}
          spellcheck="false"
        />
      </div>
      <div id="quick-pick-list" class="quick-pick-list" role="listbox" aria-label={dialogLabel}>
        {#each filteredItems as item, i (item.id || item.label || i)}
          <button
            type="button"
            id={`quick-pick-option-${i}`}
            class="quick-pick-option"
            class:selected={i === selectedIdx}
            role="option"
            aria-selected={i === selectedIdx}
            tabindex="-1"
            onmouseenter={() => (selectedIdx = i)}
            onclick={() => close(item)}
          >
            <span>{item.label}</span>
            {#if item.description}<small>{item.description}</small>{/if}
          </button>
        {:else}
          <div class="quick-pick-empty" role="status">No matching results</div>
        {/each}
      </div>
      <div class="visually-hidden" role="status" aria-live="polite" aria-atomic="true">
        {filteredItems.length}
        {filteredItems.length === 1 ? 'result' : 'results'} available
      </div>
    </div>
  </div>
{/if}

<style>
  .quick-pick-layer {
    position: fixed;
    inset: 0;
    z-index: 1000;
    display: flex;
    justify-content: center;
    pointer-events: none;
  }
  .quick-pick-dialog {
    display: flex;
    width: min(600px, calc(100vw - 48px));
    max-height: 50vh;
    margin-top: 16px;
    flex-direction: column;
    overflow: hidden;
    border: 1px solid var(--panel-border);
    border-radius: 10px;
    background: var(--panel-bg);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
    pointer-events: auto;
  }
  .quick-pick-input-wrap {
    padding: 8px;
    border-bottom: 1px solid var(--panel-border);
  }
  input {
    width: 100%;
    padding: 8px 12px;
    border: 1px solid var(--panel-border);
    border-radius: 5px;
    outline: none;
    background: var(--sidebar-bg);
    color: var(--fg);
    font-size: 13px;
    transition: border-color 120ms ease;
  }
  input:focus-visible {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }
  .quick-pick-list {
    overflow-y: auto;
    padding: 4px;
  }
  .quick-pick-option {
    display: flex;
    width: 100%;
    min-height: 32px;
    align-items: baseline;
    gap: 8px;
    padding: 6px 12px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
    font-size: 13px;
    text-align: left;
  }
  .quick-pick-option:hover,
  .quick-pick-option.selected {
    background: var(--accent);
    color: white;
  }
  .quick-pick-option small {
    overflow: hidden;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .quick-pick-option.selected small {
    color: inherit;
    opacity: 0.8;
  }
  .quick-pick-empty {
    padding: 12px;
    color: var(--breadcrumb-dim);
    font-size: 13px;
    text-align: center;
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
