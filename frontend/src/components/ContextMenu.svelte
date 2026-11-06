<script lang="ts">
  import { tick } from 'svelte';

  const { x, y, items, onClose } = $props<{
    x: number;
    y: number;
    items: any[];
    onClose: () => void;
  }>();

  let menuEl = $state<HTMLElement>();
  let activeSubmenu = $state<{ idx: number; x: number; y: number; items: any[] } | null>(null);

  function menuItems() {
    return Array.from(
      menuEl?.querySelectorAll<HTMLButtonElement>(':scope > [role="menuitem"]') || [],
    );
  }

  function handleClick(item: any) {
    if (!item.action || item.disabled) return;
    onClose();
    item.action();
  }

  function showSubmenu(item: any, idx: number, element: HTMLElement) {
    if (!item.submenu || item.disabled) {
      activeSubmenu = null;
      return;
    }
    const rect = element.getBoundingClientRect();
    activeSubmenu = {
      idx,
      x: rect.right + 230 > window.innerWidth ? rect.left - 222 : rect.right - 4,
      y: rect.top - 6,
      items: item.submenu,
    };
  }

  function focusRelative(delta: number) {
    const options = menuItems();
    if (options.length === 0) return;
    const current = Math.max(0, options.indexOf(document.activeElement as HTMLButtonElement));
    options[(current + delta + options.length) % options.length].focus();
  }

  function handleMenuKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      onClose();
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      focusRelative(event.key === 'ArrowDown' ? 1 : -1);
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      const options = menuItems();
      options[event.key === 'Home' ? 0 : options.length - 1]?.focus();
    } else if (event.key === 'ArrowRight' && activeSubmenu) {
      event.preventDefault();
      requestAnimationFrame(() => {
        const menus = Array.from(document.querySelectorAll<HTMLElement>('.ctx-menu'));
        menus.at(-1)?.querySelector<HTMLButtonElement>('[role="menuitem"]')?.focus();
      });
    }
  }

  $effect(() => {
    const outside = (event: PointerEvent) => {
      const target = event.target as Node;
      if (
        !Array.from(document.querySelectorAll('.ctx-menu')).some((menu) => menu.contains(target))
      ) {
        onClose();
      }
    };
    document.addEventListener('pointerdown', outside);
    void tick().then(() => menuItems()[0]?.focus());
    return () => document.removeEventListener('pointerdown', outside);
  });
</script>

<div
  bind:this={menuEl}
  class="ctx-menu"
  role="menu"
  tabindex="-1"
  aria-label="Context menu"
  style="left:{Math.min(x, window.innerWidth - 230)}px;top:{Math.min(
    y,
    window.innerHeight - items.length * 30 - 20,
  )}px;"
  onkeydown={handleMenuKeydown}
>
  {#each items as item, idx (item.id || item.label || idx)}
    {#if item.sep}
      <div class="ctx-sep" role="separator"></div>
    {:else}
      <button
        type="button"
        class="ctx-item"
        class:danger={item.danger}
        class:has-sub={item.submenu}
        role="menuitem"
        disabled={item.disabled}
        aria-haspopup={item.submenu ? 'menu' : undefined}
        aria-expanded={item.submenu ? activeSubmenu?.idx === idx : undefined}
        onclick={() => handleClick(item)}
        onfocus={(event) => showSubmenu(item, idx, event.currentTarget)}
        onmouseenter={(event) => showSubmenu(item, idx, event.currentTarget)}
      >
        <span>{item.label || ''}</span>
        {#if item.submenu}
          <span class="ctx-submenu-arrow codicon codicon-chevron-right" aria-hidden="true"></span>
        {:else if item.accel}
          <span class="ctx-accel">{item.accel}</span>
        {/if}
      </button>
    {/if}
  {/each}

  {#if activeSubmenu}
    <!-- svelte-ignore svelte_self_deprecated -->
    <svelte:self x={activeSubmenu.x} y={activeSubmenu.y} items={activeSubmenu.items} {onClose} />
  {/if}
</div>

<style>
  .ctx-menu {
    position: fixed;
    z-index: 10000;
    min-width: 220px;
    max-width: 350px;
    padding: 6px 0;
    border: 1px solid var(--panel-border);
    border-radius: 8px;
    background: color-mix(in srgb, var(--bg) 92%, transparent);
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.72);
    backdrop-filter: blur(12px);
    font-family: var(--font-sans);
  }
  .ctx-item {
    display: flex;
    width: calc(100% - 12px);
    min-height: 30px;
    align-items: center;
    justify-content: space-between;
    margin: 1px 6px;
    padding: 6px 10px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: var(--sidebar-fg);
    cursor: pointer;
    font-size: 12px;
    font-weight: 500;
    text-align: left;
    white-space: nowrap;
    transition:
      background-color 50ms ease,
      color 50ms ease;
  }
  .ctx-item:hover,
  .ctx-item:focus-visible {
    outline: none;
    background: var(--accent);
    color: var(--fg);
  }
  .ctx-item:disabled {
    color: var(--breadcrumb-dim);
    cursor: default;
    opacity: 0.5;
  }
  .ctx-item:disabled:hover {
    background: transparent;
  }
  .ctx-item.danger {
    color: var(--error);
  }
  .ctx-item.danger:hover,
  .ctx-item.danger:focus-visible {
    background: color-mix(in srgb, var(--error) 16%, transparent);
    color: var(--error);
  }
  .ctx-sep {
    height: 1px;
    margin: 6px 12px;
    background: var(--panel-border);
    opacity: 0.65;
  }
  .ctx-accel {
    margin-left: 24px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    letter-spacing: 0.5px;
  }
  .ctx-item:hover .ctx-accel,
  .ctx-item:focus-visible .ctx-accel {
    color: inherit;
    opacity: 0.8;
  }
  .ctx-submenu-arrow {
    margin-left: 16px;
    font-size: 12px;
    opacity: 0.7;
  }
</style>
