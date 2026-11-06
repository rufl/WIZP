<script lang="ts">
  import { tick } from 'svelte';

  const { prompt = null } = $props();

  let isOpen = $state(false);
  let query = $state('');
  let inputEl = $state<HTMLInputElement>();
  let returnFocus: HTMLElement | null = null;

  const dialogLabel = $derived(
    prompt?.options?.title ||
      prompt?.options?.prompt ||
      prompt?.options?.placeHolder ||
      'Enter text',
  );

  $effect(() => {
    if (!prompt) return;
    returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    isOpen = true;
    query = prompt.options?.value || '';
    void tick().then(() => {
      inputEl?.focus();
      if (!inputEl || query.length === 0) return;
      const selectionEnd = prompt.options?.valueSelection?.[1] ?? query.length;
      const selectionStart = prompt.options?.valueSelection?.[0] ?? 0;
      inputEl.setSelectionRange(selectionStart, selectionEnd);
    });
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
    } else if (event.key === 'Enter') {
      event.preventDefault();
      close(query);
    } else if (event.key === 'Tab') {
      event.preventDefault();
      inputEl?.focus();
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

{#if isOpen}
  <div class="input-box-layer">
    <div
      class="input-box-dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="input-box-title"
      aria-describedby={prompt?.options?.prompt ? 'input-box-description' : undefined}
    >
      <h2 id="input-box-title" class="visually-hidden">{dialogLabel}</h2>
      <input
        bind:this={inputEl}
        bind:value={query}
        aria-label={dialogLabel}
        placeholder={prompt?.options?.placeHolder || prompt?.options?.prompt || 'Enter text...'}
        spellcheck="false"
      />
      {#if prompt?.options?.prompt}
        <p id="input-box-description">{prompt.options.prompt}</p>
      {/if}
    </div>
  </div>
{/if}

<style>
  .input-box-layer {
    position: fixed;
    inset: 0;
    z-index: 1000;
    display: flex;
    justify-content: center;
    pointer-events: none;
  }
  .input-box-dialog {
    width: min(600px, calc(100vw - 48px));
    margin-top: 16px;
    padding: 8px;
    border: 1px solid var(--panel-border);
    border-radius: 10px;
    background: var(--panel-bg);
    box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
    pointer-events: auto;
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
  p {
    margin: 8px 8px 4px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
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
