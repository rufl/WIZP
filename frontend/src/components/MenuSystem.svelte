<script lang="ts">
  // Svelte 5 runes mode
  import { activeMenu, setActiveMenu } from '../stores';

  const { menuId, label, items } = $props<{ menuId: string; label: string; items: any[] }>();

  // Svelte 5 runes mode
  let isOpen = $state(false);
  let dropdownEl: HTMLElement;
  let submenuEl: HTMLElement | null = null;
  let selectedIndex = $state(-1);

  function toggle(e: MouseEvent) {
    e.stopPropagation();
    if ($activeMenu === menuId) {
      closeAll();
    } else {
      open();
    }
  }

  function open() {
    setActiveMenu(menuId);
    isOpen = true;
    selectedIndex = -1;
    renderItems();
    positionDropdown();
  }

  function closeAll() {
    setActiveMenu(null);
    isOpen = false;
    if (submenuEl) submenuEl.style.display = 'none';
  }

  function positionDropdown() {
    // Position handled by CSS — dropdown is fixed/absolute
  }

  function renderItems() {
    if (!dropdownEl) return;
    // Controlled legacy menu renderer; definitions are supplied by the host menu model.
    // eslint-disable-next-line svelte/no-dom-manipulating
    dropdownEl.innerHTML = items
      .map((item, i) => {
        if (item.sep) return '<div class="menu-separator"></div>';
        const disabled = item.disabled ? ' disabled' : '';
        const hasSub = item.submenu ? ' has-submenu' : '';
        const arrow = item.shortcut ? `<span class="menu-shortcut">${item.shortcut}</span>` : '';
        const subArrow = item.submenu ? '<span style="margin-left:auto;opacity:0.6;">▶</span>' : '';
        return `<div class="menu-item${disabled}${hasSub}" data-idx="${i}">
        <span>${item.label}</span>${arrow}${subArrow}
      </div>`;
      })
      .join('');

    dropdownEl.querySelectorAll('.menu-item').forEach((el) => {
      const idx = parseInt((el as HTMLElement).dataset.idx || '-1');
      const item = items.filter((it) => !it.sep)[idx];
      if (!item || item.disabled) {
        (el as HTMLElement).style.pointerEvents = 'none';
        return;
      }
      (el as HTMLElement).onclick = (e) => {
        e.stopPropagation();
        if (item.action) {
          item.action();
          closeAll();
        }
      };
      (el as HTMLElement).onmouseenter = () => {
        if (item.submenu) showSubmenu(item, el as HTMLElement);
      };
    });
  }

  function showSubmenu(item: any, parentEl: HTMLElement) {
    if (!submenuEl) {
      submenuEl = document.createElement('div');
      submenuEl.className = 'menu-dropdown submenu';
      document.body.appendChild(submenuEl);
    }
    const rect = parentEl.getBoundingClientRect();
    submenuEl.style.left = `${rect.right + 2}px`;
    submenuEl.style.top = `${rect.top}px`;
    submenuEl.style.display = 'block';
    // Render submenu items...
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!$activeMenu) return;
    if (e.key === 'Escape') {
      closeAll();
      return;
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const flat = items.filter((it) => !it.sep);
      selectedIndex =
        (selectedIndex + (e.key === 'ArrowDown' ? 1 : -1) + flat.length) % flat.length;
      renderItems();
    }
    if (e.key === 'Enter' && selectedIndex >= 0) {
      const flat = items.filter((it) => !it.sep);
      if (flat[selectedIndex]?.action) {
        flat[selectedIndex].action();
        closeAll();
      }
    }
  }

  // Global click to close
  if (typeof window !== 'undefined') {
    window.addEventListener('click', (e) => {
      if (
        !(e.target as HTMLElement).closest('.menu-entry') &&
        !(e.target as HTMLElement).closest('.menu-dropdown')
      ) {
        closeAll();
      }
    });
    window.addEventListener('keydown', handleKeydown);
  }
</script>

<div
  class="menu-entry"
  class:open={$activeMenu === menuId}
  onmousedown={toggle}
  onmouseenter={() => {
    if ($activeMenu && $activeMenu !== menuId) open();
  }}
>
  {label}
</div>

{#if isOpen}
  <div class="menu-dropdown open" bind:this={dropdownEl}>
    <!-- Items rendered imperatively -->
  </div>
{/if}

<style>
  .menu-entry {
    padding: 0 8px;
    height: 100%;
    display: flex;
    align-items: center;
    cursor: pointer;
    color: var(--titlebar-fg, #cccccc);
    font-size: 13px;
  }
  .menu-entry:hover,
  .menu-entry.open {
    background: rgba(255, 255, 255, 0.08);
  }
  .menu-dropdown {
    position: fixed;
    top: 30px;
    background: var(--menu-bg, #252526);
    border: 1px solid var(--panel-border, #3c3c3c);
    border-radius: 4px;
    z-index: 1000;
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    min-width: 220px;
    padding: 4px 0;
    display: none;
  }
  .menu-dropdown.open {
    display: block;
  }
  :global(.menu-item) {
    padding: 4px 24px 4px 12px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 13px;
    color: var(--menu-fg, #cccccc);
    height: 28px;
  }
  :global(.menu-item:hover) {
    background: var(--editor-selection, #094771);
    color: var(--fg, #ffffff);
  }
  :global(.menu-item.disabled) {
    color: #5a5a5a;
    pointer-events: none;
  }
  :global(.menu-separator) {
    height: 1px;
    background: var(--panel-border, #3c3c3c);
    margin: 4px 0;
  }
  :global(.menu-shortcut) {
    color: var(--breadcrumb-dim, #858585);
    font-size: 12px;
    margin-left: 24px;
  }
</style>
