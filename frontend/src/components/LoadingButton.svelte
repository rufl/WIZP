<script lang="ts">
  type Props = {
    label: string;
    pendingLabel?: string;
    pending?: boolean;
    disabled?: boolean;
    type?: 'button' | 'submit';
    class?: string;
    id?: string;
    title?: string;
    element?: HTMLButtonElement;
    onclick?: (event: MouseEvent) => void;
  };
  // Props remain mutable so Svelte can propagate state changes from parent components.
  /* eslint-disable prefer-const */

  let {
    label,
    pendingLabel = label,
    pending = false,
    disabled = false,
    type = 'button',
    class: className = '',
    id,
    title,
    element = $bindable(),
    onclick,
  }: Props = $props();
  /* eslint-enable prefer-const */

  function handleClick(event: MouseEvent) {
    if (pending || disabled) {
      event.preventDefault();
      return;
    }
    onclick?.(event);
  }
</script>

<button
  {type}
  {id}
  {title}
  class="interior-loading-button {className}"
  bind:this={element}
  {disabled}
  aria-label={label}
  aria-busy={pending}
  aria-disabled={pending || disabled}
  onclick={handleClick}
>
  <span class="icon-slot" aria-hidden="true">
    {#if pending}
      <svg class="spinner" viewBox="0 0 12 12" fill="none">
        <circle
          cx="6"
          cy="6"
          r="4.5"
          stroke="currentColor"
          stroke-opacity="0.22"
          stroke-width="1.5"
        />
        <path
          d="M10.5 6A4.5 4.5 0 0 0 6 1.5"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
        />
      </svg>
    {:else}
      <span class="icon-placeholder"></span>
    {/if}
  </span>
  <span class="label-stack" aria-hidden="true">
    <span class:active={!pending}>{label}</span>
    <span class:active={pending}>{pendingLabel}</span>
  </span>
</button>
<span class="sr-only" role="status" aria-live="polite">{pending ? pendingLabel : ''}</span>

<style>
  .interior-loading-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    touch-action: manipulation;
  }

  .icon-slot {
    display: grid;
    width: 12px;
    height: 12px;
    flex: 0 0 12px;
    place-items: center;
  }

  .icon-slot > * {
    grid-area: 1 / 1;
    width: 12px;
    height: 12px;
  }

  .icon-placeholder {
    visibility: hidden;
  }

  .spinner {
    animation: loading-spin 850ms linear infinite;
  }

  .label-stack {
    display: grid;
    min-width: 0;
  }

  .label-stack > span {
    grid-area: 1 / 1;
    visibility: hidden;
    white-space: nowrap;
  }

  .label-stack > .active {
    visibility: visible;
  }

  @keyframes loading-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner {
      animation: none;
    }
  }
</style>
