<script lang="ts">
  import { onDestroy } from 'svelte';

  type Props = {
    value: string;
    label?: string;
    copiedLabel?: string;
    errorLabel?: string;
    timeout?: number;
    disabled?: boolean;
    class?: string;
    onCopy?: (value: string) => void;
    onError?: (reason: unknown) => void;
  };

  // Svelte prop bindings remain mutable so parent updates stay reactive.
  /* eslint-disable prefer-const */
  let {
    value,
    label = 'Copy',
    copiedLabel = 'Copied',
    errorLabel = 'Failed',
    timeout = 2000,
    disabled = false,
    class: className = '',
    onCopy,
    onError,
  }: Props = $props();
  /* eslint-enable prefer-const */

  let state = $state<'idle' | 'copying' | 'copied' | 'error'>('idle');
  let resetTimer: ReturnType<typeof setTimeout> | undefined;
  let alive = true;

  onDestroy(() => {
    alive = false;
    if (resetTimer) clearTimeout(resetTimer);
  });

  function writeFallback(text: string) {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.inset = '0 auto auto 0';
    area.style.opacity = '0';
    document.body.appendChild(area);

    const selection = document.getSelection();
    const previous = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
    try {
      area.select();
      return document.execCommand('copy');
    } finally {
      area.remove();
      if (selection && previous) {
        selection.removeAllRanges();
        selection.addRange(previous);
      }
    }
  }

  async function copyValue() {
    if (disabled || state === 'copying' || !value) return;
    if (resetTimer) clearTimeout(resetTimer);
    state = 'copying';

    let copied = false;
    let failure: unknown;
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(value);
        copied = true;
      } else {
        copied = writeFallback(value);
      }
    } catch (error) {
      failure = error;
      try {
        copied = writeFallback(value);
      } catch (fallbackError) {
        failure = fallbackError;
      }
    }

    if (!alive) return;
    state = copied ? 'copied' : 'error';
    if (copied) onCopy?.(value);
    else onError?.(failure);
    resetTimer = setTimeout(() => {
      if (alive) state = 'idle';
      resetTimer = undefined;
    }, timeout);
  }
</script>

<button
  type="button"
  class="interior-copy-button {className}"
  class:copied={state === 'copied'}
  class:error={state === 'error'}
  disabled={disabled || !value}
  aria-label={label}
  aria-busy={state === 'copying'}
  onclick={() => void copyValue()}
>
  <span class="icon-slot" aria-hidden="true">
    <svg
      class="copy-icon"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path
        d="M9.6 5.1V3.7A1.7 1.7 0 0 0 7.9 2H3.7A1.7 1.7 0 0 0 2 3.7v4.2a1.7 1.7 0 0 0 1.7 1.7h1.4"
      />
      <rect x="5.1" y="5.1" width="6.9" height="6.9" rx="1.7" />
    </svg>
    <svg
      class="check-icon"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="m2.9 7.4 2.7 2.7L11.1 4" />
    </svg>
    <svg
      class="error-icon"
      viewBox="0 0 14 14"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    >
      <path d="M7 3.1v4.2M7 10.5h.01" />
    </svg>
  </span>
  <span class="label-stack" aria-hidden="true">
    <span class:active={state === 'idle'}>{label}</span>
    <span class:active={state === 'copying'}>{label}</span>
    <span class:active={state === 'copied'}>{copiedLabel}</span>
    <span class:active={state === 'error'}>{errorLabel}</span>
  </span>
</button>
<span class="sr-only" role="status" aria-live="polite">
  {state === 'copied' ? copiedLabel : state === 'error' ? errorLabel : ''}
</span>

<style>
  .interior-copy-button {
    display: inline-flex;
    min-height: 28px;
    align-items: center;
    justify-content: center;
    gap: 5px;
    touch-action: manipulation;
  }

  .icon-slot {
    display: grid;
    width: 14px;
    height: 14px;
    flex: 0 0 14px;
  }

  .icon-slot > svg {
    grid-area: 1 / 1;
    width: 14px;
    height: 14px;
    visibility: hidden;
    opacity: 0;
    transform: scale(0.92);
    transition:
      opacity 140ms ease,
      transform 140ms ease;
  }

  .icon-slot > .copy-icon,
  .interior-copy-button.copied .check-icon,
  .interior-copy-button.error .error-icon {
    visibility: visible;
    opacity: 1;
    transform: scale(1);
  }

  .interior-copy-button.copied .copy-icon,
  .interior-copy-button.error .copy-icon {
    opacity: 0;
    transform: scale(0.92);
  }

  .label-stack {
    display: grid;
    min-width: 0;
  }

  .label-stack > span {
    grid-area: 1 / 1;
    opacity: 0;
    white-space: nowrap;
    transition: opacity 140ms ease;
  }

  .label-stack > .active {
    opacity: 1;
  }

  .interior-copy-button.copied .check-icon {
    color: var(--info, currentColor);
  }

  .interior-copy-button.error .error-icon {
    color: var(--error, currentColor);
  }

  @media (prefers-reduced-motion: reduce) {
    .icon-slot > svg,
    .label-stack > span {
      transition: none;
    }
  }
</style>
