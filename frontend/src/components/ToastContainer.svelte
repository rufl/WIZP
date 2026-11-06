<script lang="ts">
  import { toasts } from '../stores';
  import { fade } from 'svelte/transition';
</script>

{#if $toasts.length > 0}
  <div class="toast-container" aria-label="Notifications">
    {#each $toasts as toast (toast.id)}
      <div
        class="toast {toast.type}"
        role={toast.type === 'error' ? 'alert' : 'status'}
        aria-live={toast.type === 'error' ? 'assertive' : 'polite'}
        aria-atomic="true"
        aria-relevant="text"
        transition:fade={{ duration: 200 }}
      >
        <span
          class="codicon {toast.type === 'error' ? 'codicon-error' : 'codicon-info'}"
          aria-hidden="true"
        ></span>
        <span>{toast.message}</span>
      </div>
    {/each}
  </div>
{/if}

<style>
  .toast-container {
    position: fixed;
    right: 20px;
    bottom: 40px;
    z-index: 9999;
    display: flex;
    flex-direction: column;
    gap: 8px;
    pointer-events: none;
  }
  .toast {
    display: flex;
    min-width: 200px;
    max-width: min(400px, calc(100vw - 40px));
    align-items: flex-start;
    gap: 8px;
    padding: 9px 12px;
    border: 1px solid color-mix(in srgb, var(--info) 55%, var(--panel-border));
    border-radius: 6px;
    background: var(--panel-bg, #252526);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
    color: var(--fg, #fff);
    font-size: 12px;
    line-height: 1.4;
    overflow-wrap: anywhere;
  }
  .toast .codicon {
    margin-top: 2px;
    flex: 0 0 auto;
    color: var(--info);
  }
  .toast.error {
    border-color: color-mix(in srgb, var(--error) 65%, var(--panel-border));
  }
  .toast.error .codicon {
    color: var(--error);
  }
</style>
