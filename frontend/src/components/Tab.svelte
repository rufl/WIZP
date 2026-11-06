<script lang="ts">
  const {
    title = 'Untitled',
    uri = '',
    id = '',
    groupId = '',
    panelId = '',
    active = false,
    dirty = false,
    pinned = false,
    onClose,
    onClick,
    onMiddleClick,
    onContextMenu,
    onNavigate,
    draggable = false,
    onDragStart,
    onDragOver,
    onDrop,
  }: {
    title?: string;
    uri?: string;
    id?: string;
    groupId?: string;
    panelId?: string;
    active?: boolean;
    dirty?: boolean;
    pinned?: boolean;
    onClose?: () => void;
    onClick?: () => void;
    onMiddleClick?: () => void;
    onContextMenu?: (e: MouseEvent) => void;
    onNavigate?: (direction: 'previous' | 'next' | 'first' | 'last') => void;
    draggable?: boolean;
    onDragStart?: (e: DragEvent) => void;
    onDragOver?: (e: DragEvent) => void;
    onDrop?: (e: DragEvent) => void;
  } = $props();

  function handleClick() {
    onClick?.();
  }
  function handleClose(e: MouseEvent) {
    e.stopPropagation();
    onClose?.();
  }
  function handleMouseDown(e: MouseEvent) {
    if (e.button === 1) {
      e.preventDefault();
      onMiddleClick?.();
    }
  }
  function handleContext(e: MouseEvent) {
    e.preventDefault();
    onContextMenu?.(e);
  }
  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      handleClick();
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      onNavigate?.('previous');
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      onNavigate?.('next');
    } else if (e.key === 'Home') {
      e.preventDefault();
      onNavigate?.('first');
    } else if (e.key === 'End') {
      e.preventDefault();
      onNavigate?.('last');
    } else if (e.key === 'Delete') {
      e.preventDefault();
      onClose?.();
    }
  }
  function handleDragStart(e: DragEvent) {
    onDragStart?.(e);
  }
  function handleDragOver(e: DragEvent) {
    onDragOver?.(e);
  }
  function handleDrop(e: DragEvent) {
    onDrop?.(e);
  }
</script>

<div
  class="wizp-tab group"
  class:tab-active={active}
  class:tab-inactive={!active}
  class:tab-pinned={pinned}
  {id}
  {draggable}
  onclick={handleClick}
  onkeydown={handleKeydown}
  onmousedown={handleMouseDown}
  oncontextmenu={handleContext}
  ondragstart={draggable ? handleDragStart : undefined}
  ondragover={draggable ? handleDragOver : undefined}
  ondrop={draggable ? handleDrop : undefined}
  role="tab"
  tabindex={active ? 0 : -1}
  aria-selected={active}
  aria-controls={panelId || undefined}
  aria-label={`${title}${dirty ? ', unsaved changes' : ''}`}
  data-uri={uri}
  data-title={title}
  data-group-id={groupId}
  data-tab-id={id}
  data-dirty={dirty}
>
  {#if pinned}
    <span class="codicon codicon-pin text-[10px] text-accent flex-shrink-0 mr-1" title="Pinned"
    ></span>
  {/if}
  <span class="tab-title truncate flex-1" {title}>{title}</span>

  {#if dirty && !pinned}
    <span class="tab-dirty" aria-hidden="true"></span>
  {/if}
  {#if dirty && pinned}
    <span class="tab-dirty pinned" aria-hidden="true"></span>
  {/if}

  {#if !pinned}
    <button
      type="button"
      class="tab-close"
      onclick={handleClose}
      title="Close"
      aria-label={`Close ${title}`}
      tabindex="-1"
    >
      <span class="codicon codicon-close text-xs"></span>
    </button>
  {:else}
    <button
      type="button"
      class="tab-close"
      onclick={handleClose}
      title="Close (Pinned)"
      aria-label={`Close ${title}`}
      tabindex="-1"
    >
      <span class="codicon codicon-close text-xs"></span>
    </button>
  {/if}
</div>

<style>
  .wizp-tab {
    position: relative;
    display: flex;
    align-items: center;
    gap: 7px;
    flex: 0 0 auto;
    width: clamp(112px, 15vw, 220px);
    height: 34px;
    padding: 0 9px 0 11px;
    border-right: 1px solid var(--tab-border, var(--panel-border));
    background: var(--tab-bg, var(--editor-bg));
    color: var(--tab-inactive-fg, var(--breadcrumb-dim));
    cursor: default;
    font-size: 12px;
    user-select: none;
  }
  .wizp-tab:hover {
    background: var(--tab-hover-bg, var(--control-hover-bg));
    color: var(--fg);
  }
  .wizp-tab.tab-active {
    background: var(--tab-active-bg, var(--editor-bg));
    color: var(--tab-active-fg, var(--fg));
    box-shadow: inset 0 2px 0 var(--tab-active-border-top, var(--accent));
  }
  .wizp-tab.tab-pinned {
    width: 54px;
    padding-inline: 9px;
  }
  .tab-title {
    min-width: 0;
  }
  .tab-dirty {
    width: 8px;
    height: 8px;
    flex: 0 0 auto;
    border-radius: 50%;
    background: var(--accent);
  }
  .tab-dirty.pinned {
    width: 6px;
    height: 6px;
    background: var(--warn);
  }
  .tab-close {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 20px;
    height: 20px;
    padding: 0;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: inherit;
    opacity: 0;
    cursor: pointer;
  }
  .wizp-tab:hover .tab-close,
  .wizp-tab.tab-active .tab-close,
  .tab-close:focus-visible {
    opacity: 1;
  }
  .tab-close:hover {
    background: color-mix(in srgb, var(--fg) 12%, transparent);
  }
  .wizp-tab:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  @media (max-width: 1100px) {
    .wizp-tab {
      width: clamp(104px, 18vw, 180px);
    }
  }
</style>
