<script lang="ts">
  import { tick } from 'svelte';
  import {
    activeMenu,
    projectPath,
    gitBranch,
    isSidebarVisible,
    isPanelVisible,
    isRightSidebarVisible,
    activityBarPosition,
    toggleSidebar,
    togglePanel,
    toggleRightSidebar,
    toggleActivityBarPosition,
    setActiveMenu,
  } from '../stores';
  import { shortcutFor, shortcutIdForEvent } from '../shortcuts';

  const projectName = $derived($projectPath ? $projectPath.split('/').pop() : '');

  // Window drag: -webkit-app-region CSS
  let dragState = $state<{ x: number; y: number } | null>(null);
  function handleDragStart(e: MouseEvent) {
    if ((e.target as HTMLElement)?.closest('button, [data-no-drag]')) return;
    dragState = { x: e.screenX - (window.screenX || 0), y: e.screenY - (window.screenY || 0) };
    const onMove = (ev: MouseEvent) => {
      if (!dragState) return;
      try {
        window.moveTo(ev.screenX - dragState.x, ev.screenY - dragState.y);
      } catch {
        // Window dragging is optional in browser/dev mode.
      }
    };
    const onUp = () => {
      dragState = null;
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp, { once: true });
    setTimeout(
      () =>
        document.addEventListener(
          'click',
          () => {
            if ($activeMenu) setActiveMenu(null);
          },
          { once: true },
        ),
      0,
    );
  }

  function triggerPalette() {
    (window as any).__showCommandPalette?.();
  }
  function handleMenu(e: Event) {
    const menu = (e.currentTarget as HTMLElement).dataset.menu;
    if (menu) setActiveMenu($activeMenu === menu ? null : menu);
  }
  function handleSplit() {
    (window as any).__splitEditor?.();
  }
  function windowControl(action: string) {
    const port =
      (window as any).__wizpControlPort ||
      new URLSearchParams(window.location.search).get('wizpControlPort') ||
      '19876';
    return fetch(`http://127.0.0.1:${port}/__window?action=${encodeURIComponent(action)}`).catch(
      () => {},
    );
  }

  // ─── Menu dropdown ──────────────────────────────────────────────────────
  const menuDefs: Record<string, any[]> = {
    file: [
      {
        label: 'New File',
        key: shortcutFor('file.new'),
        action: () => (window as any).__newFile?.(),
      },
      {
        label: 'Open File...',
        key: shortcutFor('file.open'),
        action: () => (window as any).__openFileViaDialog?.(),
      },
      { label: 'Open Folder...', action: () => (window as any).__openFolder?.() },
      { sep: true },
      { label: 'Open Recent...', key: '', action: () => (window as any).__showRecentProjects?.() },
      { sep: true },
      {
        label: 'Save',
        key: shortcutFor('file.save'),
        action: () => (window as any).__saveActiveEditor?.(),
      },
      {
        label: 'Save As...',
        key: shortcutFor('file.saveAs'),
        action: () => (window as any).__saveActiveEditorAs?.(),
      },
      { sep: true },
      { label: 'Revert File', action: () => (window as any).__revertActiveEditor?.() },
      { sep: true },
      {
        label: 'Close Editor',
        key: shortcutFor('file.close'),
        action: () => (window as any).__closeActiveEditor?.(),
      },
      { label: 'Close All Editors', action: () => (window as any).__closeAllEditors?.() },
      { label: 'Close Window', key: 'Ctrl+Shift+W', action: () => windowControl('close') },
      { sep: true },
      { label: 'Exit', key: shortcutFor('file.quit'), action: () => windowControl('close') },
    ],
    edit: [
      {
        label: 'Undo',
        key: shortcutFor('editor.undo'),
        action: () => (window as any).__triggerEditorAction?.('undo'),
      },
      {
        label: 'Redo',
        key: shortcutFor('editor.redo'),
        action: () => (window as any).__triggerEditorAction?.('redo'),
      },
      { sep: true },
      {
        label: 'Cut',
        key: 'Ctrl+X',
        action: () => (window as any).__triggerEditorAction?.('editor.action.clipboardCutAction'),
      },
      {
        label: 'Copy',
        key: 'Ctrl+C',
        action: () => (window as any).__triggerEditorAction?.('editor.action.clipboardCopyAction'),
      },
      {
        label: 'Paste',
        key: 'Ctrl+V',
        action: () => (window as any).__triggerEditorAction?.('editor.action.clipboardPasteAction'),
      },
      { sep: true },
      {
        label: 'Find',
        key: shortcutFor('editor.find'),
        action: () => (window as any).__triggerEditorAction?.('actions.find'),
      },
      {
        label: 'Replace',
        key: shortcutFor('editor.replace'),
        action: () =>
          (window as any).__triggerEditorAction?.('editor.action.startFindReplaceAction'),
      },
      { sep: true },
      {
        label: 'Format Document',
        key: shortcutFor('editor.format'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.formatDocument'),
      },
    ],
    selection: [
      {
        label: 'Select All',
        key: shortcutFor('editor.selectAll'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.selectAll'),
      },
      {
        label: 'Expand Selection',
        action: () => (window as any).__triggerEditorAction?.('editor.action.smartSelect.expand'),
      },
      {
        label: 'Shrink Selection',
        action: () => (window as any).__triggerEditorAction?.('editor.action.smartSelect.shrink'),
      },
    ],
    go: [
      {
        label: 'Go to File...',
        key: shortcutFor('quick.open'),
        action: () => (window as any).__showQuickOpen?.(),
      },
      {
        label: 'Go to Symbol in Editor...',
        key: shortcutFor('go.symbols.editor'),
        action: () => (window as any).__showQuickOpenAt?.('@'),
      },
      {
        label: 'Go to Symbol in Workspace...',
        key: shortcutFor('go.symbols.workspace'),
        action: () => (window as any).__showQuickOpenAt?.('#'),
      },
      { sep: true },
      {
        label: 'Go to Line...',
        key: shortcutFor('go.line'),
        action: () => (window as any).__showQuickOpenAt?.(':'),
      },
      { sep: true },
      {
        label: 'Go to Definition',
        key: shortcutFor('editor.definition'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.revealDefinition'),
      },
      {
        label: 'Peek Definition',
        key: shortcutFor('editor.peekDefinition'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.peekDefinition'),
      },
      {
        label: 'Go to References',
        key: shortcutFor('editor.references'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.goToReferences'),
      },
    ],
    run: [
      {
        label: 'Start Debugging',
        key: shortcutFor('debug.start'),
        action: () => (window as any).__startDebugging?.(),
      },
      {
        label: 'Run Without Debugging',
        key: shortcutFor('debug.run'),
        action: () => (window as any).__runWithoutDebugging?.(),
      },
      {
        label: 'Stop Debugging',
        key: shortcutFor('debug.stop'),
        action: () => (window as any).__stopDebugging?.(),
      },
      { sep: true },
      {
        label: 'Toggle Breakpoint',
        key: shortcutFor('debug.breakpoint'),
        action: () => (window as any).__toggleBreakpointAtCursor?.(),
      },
      {
        label: 'New Breakpoint...',
        action: () => (window as any).__triggerEditorAction?.('editor.debug.action.addBreakpoint'),
      },
    ],
    terminal: [
      { label: 'New Terminal', key: shortcutFor('terminal.new'), action: () => togglePanel() },
      { label: 'Split Terminal', action: () => (window as any).__splitTerminal?.() },
      { label: 'Kill Active Terminal', action: () => (window as any).__killTerminal?.() },
    ],
    help: [
      { label: 'Welcome', action: () => (window as any).__showWelcome?.() },
      { sep: true },
      { label: 'Documentation', action: () => window.open('https://github.com', '_blank') },
      { sep: true },
      { label: 'About WIZP', action: () => (window as any).__showAbout?.() },
    ],
    more: [
      {
        label: 'Go to File...',
        key: shortcutFor('quick.open'),
        action: () => (window as any).__showQuickOpen?.(),
      },
      {
        label: 'Start Debugging',
        key: shortcutFor('debug.start'),
        action: () => (window as any).__startDebugging?.(),
      },
      { label: 'New Terminal', key: shortcutFor('terminal.new'), action: () => togglePanel(true) },
      { sep: true },
      { label: 'Welcome', action: () => (window as any).__showWelcome?.() },
      { label: 'Documentation', action: () => window.open('https://github.com', '_blank') },
      { label: 'About WIZP', action: () => (window as any).__showAbout?.() },
    ],
    view: [
      { label: 'Command Palette...', key: shortcutFor('command.palette'), action: triggerPalette },
      { sep: true },
      {
        label: 'Explorer',
        key: shortcutFor('view.explorer'),
        action: () => {
          (window as any).__switchSidebarView?.('explorer');
        },
      },
      {
        label: 'Search',
        key: shortcutFor('view.search'),
        action: () => {
          (window as any).__switchSidebarView?.('search');
        },
      },
      {
        label: 'Source Control',
        key: shortcutFor('view.scm'),
        action: () => {
          (window as any).__switchSidebarView?.('scm');
        },
      },
      {
        label: 'Run and Debug',
        key: shortcutFor('view.debug'),
        action: () => {
          (window as any).__switchSidebarView?.('debug');
        },
      },
      {
        label: 'Extensions',
        key: shortcutFor('view.extensions'),
        action: () => {
          (window as any).__switchSidebarView?.('hub');
        },
      },
      { sep: true },
      {
        label: 'Toggle Word Wrap',
        key: shortcutFor('editor.wordWrap'),
        action: () => (window as any).__triggerEditorAction?.('editor.action.toggleWordWrap'),
      },
      { sep: true },
      { label: 'Toggle Sidebar', key: shortcutFor('view.sidebar'), action: () => toggleSidebar() },
      { label: 'Toggle Panel', key: shortcutFor('view.panel'), action: () => togglePanel() },
      { label: 'Toggle Right Sidebar', action: () => toggleRightSidebar() },
      { sep: true },
      { label: 'Split Editor Right', key: shortcutFor('editor.split'), action: handleSplit },
    ],
  };

  const menuOrder = [
    'file',
    'edit',
    'selection',
    'view',
    'go',
    'run',
    'terminal',
    'help',
    'more',
  ] as const;
  let ddEl: HTMLElement | null = $state(null);
  let menuLeft = $state(0);
  let menuTop = $state(0);

  function dropdownItems() {
    return Array.from(
      ddEl?.querySelectorAll<HTMLButtonElement>(':scope > [role="menuitem"]') || [],
    );
  }

  function visibleMenuOrder() {
    return menuOrder.filter(
      (id) => document.querySelector<HTMLElement>(`.menu-entry[data-menu="${id}"]`)?.offsetParent,
    );
  }

  function focusTopMenu(menu: (typeof menuOrder)[number]) {
    document.querySelector<HTMLElement>(`.menu-entry[data-menu="${menu}"]`)?.focus();
  }

  function handleTopMenuKeydown(event: KeyboardEvent, menu: (typeof menuOrder)[number]) {
    const visibleMenus = visibleMenuOrder();
    const index = visibleMenus.indexOf(menu);
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      const next =
        (index + (event.key === 'ArrowRight' ? 1 : -1) + visibleMenus.length) % visibleMenus.length;
      focusTopMenu(visibleMenus[next]);
      if ($activeMenu) setActiveMenu(visibleMenus[next]);
    } else if (event.key === 'Enter' || event.key === ' ' || event.key === 'ArrowDown') {
      event.preventDefault();
      setActiveMenu(menu);
    } else if (event.key === 'Escape') {
      setActiveMenu(null);
    }
  }

  function handleDropdownKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      const menu = $activeMenu;
      setActiveMenu(null);
      if (menu)
        document.querySelector<HTMLButtonElement>(`.menu-entry[data-menu="${menu}"]`)?.focus();
      return;
    }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const options = dropdownItems();
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

  function activateMenuItem(item: any) {
    item.action?.();
    setActiveMenu(null);
  }

  $effect(() => {
    const menu = $activeMenu;
    if (!menu) return;
    void tick().then(() => {
      const rect = document
        .querySelector<HTMLElement>(`.menu-entry[data-menu="${menu}"]`)
        ?.getBoundingClientRect();
      if (rect) {
        menuLeft = rect.left;
        menuTop = rect.bottom + 2;
      }
      dropdownItems()[0]?.focus();
    });
  });
  // ─── Global keyboard shortcuts ──────────────────────────────────────────
  function handleGlobalKeys(e: KeyboardEvent) {
    const modal = Array.from(document.querySelectorAll<HTMLElement>('[aria-modal="true"]')).some(
      (node) => {
        if (node instanceof HTMLDialogElement) return node.open;
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        return (
          style.display !== 'none' &&
          style.visibility !== 'hidden' &&
          rect.width > 0 &&
          rect.height > 0
        );
      },
    );
    if (modal) return;
    const shortcut = shortcutIdForEvent(e);
    if (shortcut === 'preferences.settings') {
      e.preventDefault();
      return (window as any).__openSettings?.();
    }
    if (shortcut === 'command.palette') {
      e.preventDefault();
      return triggerPalette();
    }
    if (shortcut === 'quick.open') {
      e.preventDefault();
      return (window as any).__showQuickOpen?.();
    }
    if (shortcut === 'file.close') {
      e.preventDefault();
      return (window as any).__closeActiveEditor?.();
    }
    if (
      e.target instanceof HTMLInputElement ||
      e.target instanceof HTMLTextAreaElement ||
      e.target instanceof HTMLSelectElement ||
      (e.target as HTMLElement | null)?.isContentEditable
    )
      return;
    if (!shortcut) return;
    e.preventDefault();
    switch (shortcut) {
      case 'file.new':
        return (window as any).__newFile?.();
      case 'file.open':
        return (window as any).__openFileViaDialog?.();
      case 'file.save':
        return (window as any).__saveActiveEditor?.();
      case 'file.saveAs':
        return (window as any).__saveActiveEditorAs?.();
      case 'file.close':
        return (window as any).__closeActiveEditor?.();
      case 'file.quit':
        return windowControl('close');
      case 'command.palette':
        return triggerPalette();
      case 'quick.open':
        return (window as any).__showQuickOpen?.();
      case 'go.symbols.editor':
        return (window as any).__showQuickOpenAt?.('@');
      case 'go.symbols.workspace':
        return (window as any).__showQuickOpenAt?.('#');
      case 'go.line':
        return (window as any).__showQuickOpenAt?.(':');
      case 'view.explorer':
        return (window as any).__switchSidebarView?.('explorer');
      case 'view.search':
        return (window as any).__switchSidebarView?.('search');
      case 'view.scm':
        return (window as any).__switchSidebarView?.('scm');
      case 'view.debug':
        return (window as any).__switchSidebarView?.('debug');
      case 'view.extensions':
        return (window as any).__switchSidebarView?.('hub');
      case 'view.sidebar':
        return toggleSidebar();
      case 'view.panel':
        return togglePanel();
      case 'editor.split':
        return handleSplit();
      case 'editor.find':
        return (window as any).__triggerEditorAction?.('actions.find');
      case 'editor.replace':
        return (window as any).__triggerEditorAction?.('editor.action.startFindReplaceAction');
      case 'editor.undo':
        return (window as any).__triggerEditorAction?.('undo');
      case 'editor.redo':
        return (window as any).__triggerEditorAction?.('redo');
      case 'editor.selectAll':
        return (window as any).__triggerEditorAction?.('editor.action.selectAll');
      case 'editor.format':
        return (window as any).__triggerEditorAction?.('editor.action.formatDocument');
      case 'editor.wordWrap':
        return (window as any).__triggerEditorAction?.('editor.action.toggleWordWrap');
      case 'editor.definition':
        return (window as any).__triggerEditorAction?.('editor.action.revealDefinition');
      case 'editor.peekDefinition':
        return (window as any).__triggerEditorAction?.('editor.action.peekDefinition');
      case 'editor.references':
        return (window as any).__triggerEditorAction?.('editor.action.goToReferences');
      case 'editor.cycleTabs':
        return (window as any).__cycleEditorTab?.(1);
      case 'terminal.new':
        return togglePanel(true);
      case 'debug.start':
        return (window as any).__startDebugging?.();
      case 'debug.run':
        return (window as any).__runWithoutDebugging?.();
      case 'debug.stop':
        return (window as any).__stopDebugging?.();
      case 'debug.breakpoint':
        return (window as any).__toggleBreakpointAtCursor?.();
    }
  }
  $effect(() => {
    document.addEventListener('keydown', handleGlobalKeys, true);
    return () => document.removeEventListener('keydown', handleGlobalKeys, true);
  });
</script>

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
  class="titlebar shrink-0 w-full relative h-[30px] bg-titlebar flex items-center select-none z-[200] border-b border-border/20 px-2 overflow-hidden"
  role="banner"
  aria-label="Menu bar"
  onmousedown={handleDragStart}
  style="-webkit-app-region: drag;"
>
  <div class="flex-none flex items-center h-full" style="-webkit-app-region: no-drag;">
    <div class="flex items-center h-full gap-1" role="menubar" aria-label="Application menu">
      <div
        class="menu-entry px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'file'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="file"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'file'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'file')}
      >
        File
      </div>
      <div
        class="menu-entry px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'edit'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="edit"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'edit'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'edit')}
      >
        Edit
      </div>
      <div
        class="menu-entry menu-compact-hidden px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'selection'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="selection"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'selection'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'selection')}
      >
        Selection
      </div>
      <div
        class="menu-entry px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'view'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="view"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'view'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'view')}
      >
        View
      </div>
      <div
        class="menu-entry menu-compact-hidden px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'go'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="go"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'go'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'go')}
      >
        Go
      </div>
      <div
        class="menu-entry menu-compact-hidden px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'run'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="run"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'run'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'run')}
      >
        Run
      </div>
      <div
        class="menu-entry menu-compact-hidden px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'terminal'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="terminal"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'terminal'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'terminal')}
      >
        Terminal
      </div>
      <div
        class="menu-entry menu-compact-hidden px-2 h-full flex items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'help'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="help"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'help'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'help')}
      >
        Help
      </div>
      <div
        class="menu-entry menu-overflow-entry px-2 h-full items-center cursor-pointer text-[13px] text-titlebar-fg hover:bg-white/10 transition-colors rounded-[3px] {$activeMenu ===
        'more'
          ? 'bg-white/10'
          : ''}"
        role="menuitem"
        tabindex="0"
        data-menu="more"
        aria-haspopup="menu"
        aria-expanded={$activeMenu === 'more'}
        onclick={handleMenu}
        onkeydown={(event) => handleTopMenuKeydown(event, 'more')}
      >
        More
      </div>
    </div>
  </div>

  <div
    class="titlebar-project flex-1 text-center text-[12px] text-titlebar-fg/80 whitespace-nowrap overflow-hidden font-medium"
    style="-webkit-app-region: no-drag;"
  >
    <span class="mr-2" title={$projectPath}>{projectName}</span>
    {#if $gitBranch}
      <span
        class="text-[11px] text-dim px-[6px] py-[2px] bg-white/5 rounded-[3px]"
        title="Current branch">{$gitBranch}</span
      >
    {/if}
  </div>

  <div class="flex-none flex items-center gap-1" style="-webkit-app-region: no-drag;">
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors {$activityBarPosition !==
      'hidden'
        ? 'text-accent'
        : ''}"
      role="button"
      tabindex="0"
      title={$activityBarPosition === 'left'
        ? 'Move Activity Bar Right'
        : $activityBarPosition === 'right'
          ? 'Hide Activity Bar'
          : 'Show Activity Bar (Left)'}
      onclick={toggleActivityBarPosition}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          toggleActivityBarPosition();
        }
      }}
    >
      <span
        class="codicon text-[14px] {$activityBarPosition === 'hidden'
          ? 'codicon-layout'
          : $activityBarPosition === 'left'
            ? 'codicon-layout-activitybar-left'
            : $activityBarPosition === 'top-left'
              ? 'codicon-layout-menubar'
              : 'codicon-layout-activitybar-right'}"
      ></span>
    </div>
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors {$isSidebarVisible
        ? 'text-accent'
        : ''}"
      role="button"
      tabindex="0"
      title={$isSidebarVisible ? 'Close Sidebar (Ctrl+B)' : 'Open Sidebar (Ctrl+B)'}
      onclick={() => toggleSidebar()}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          toggleSidebar();
        }
      }}
    >
      <span
        class="codicon text-[14px] {$isSidebarVisible
          ? 'codicon-layout-sidebar-left'
          : 'codicon-layout-sidebar-left-off'}"
      ></span>
    </div>
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors {$isRightSidebarVisible
        ? 'text-accent'
        : ''}"
      role="button"
      tabindex="0"
      title={$isRightSidebarVisible ? 'Close Right Sidebar' : 'Open Right Sidebar'}
      onclick={() => toggleRightSidebar()}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          toggleRightSidebar();
        }
      }}
    >
      <span
        class="codicon text-[14px] {$isRightSidebarVisible
          ? 'codicon-layout-sidebar-right'
          : 'codicon-layout-sidebar-right-off'}"
      ></span>
    </div>
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors {$isPanelVisible
        ? 'text-accent'
        : ''}"
      role="button"
      tabindex="0"
      title={$isPanelVisible ? 'Close Panel (Ctrl+J)' : 'Open Panel (Ctrl+J)'}
      onclick={() => togglePanel()}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          togglePanel();
        }
      }}
    >
      <span
        class="codicon text-[14px] {$isPanelVisible
          ? 'codicon-layout-panel'
          : 'codicon-layout-panel-off'}"
      ></span>
    </div>
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors"
      role="button"
      tabindex="0"
      title="Split Editor"
      onclick={handleSplit}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          handleSplit();
        }
      }}
    >
      <span class="codicon codicon-split-horizontal text-[14px]"></span>
    </div>
    <div
      class="w-[26px] h-[26px] flex items-center justify-center cursor-pointer text-titlebar-fg/70 hover:bg-white/10 hover:text-titlebar-fg rounded-[4px] transition-colors"
      role="button"
      tabindex="0"
      title="Command Palette (Ctrl+Shift+P)"
      onclick={triggerPalette}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          triggerPalette();
        }
      }}
    >
      <span class="codicon codicon-search text-[14px]"></span>
    </div>
  </div>
</div>

{#if $activeMenu}
  <div
    bind:this={ddEl}
    role="menu"
    tabindex="-1"
    aria-label={`${$activeMenu} menu`}
    class="fixed z-[9999] flex flex-col bg-popover border border-border/10 rounded-lg shadow-2xl min-w-[300px] p-2 text-[13px] font-medium"
    style:left={`${menuLeft}px`}
    style:top={`${menuTop}px`}
    onclick={(event) => event.stopPropagation()}
    onkeydown={handleDropdownKeydown}
  >
    {#each menuDefs[$activeMenu] || [] as item, index (item.label || `separator-${index}`)}
      {#if item.sep}
        <div class="h-px bg-border/60 my-1.5 mx-2 flex-shrink-0" role="separator"></div>
      {:else}
        <button
          type="button"
          role="menuitem"
          class="flex min-h-8 items-center justify-between gap-8 px-3 py-1.5 border-0 bg-transparent cursor-pointer text-fg hover:bg-white/10 focus-visible:bg-white/10 focus-visible:outline-none rounded text-left"
          onclick={() => activateMenuItem(item)}
        >
          <span>{item.label}</span>
          {#if item.key}<span class="text-dim text-[11px] font-mono">{item.key}</span>{/if}
        </button>
      {/if}
    {/each}
  </div>
{/if}

<style>
  .menu-overflow-entry {
    display: none;
  }
  @media (max-width: 900px) {
    .menu-compact-hidden {
      display: none;
    }
    .menu-overflow-entry {
      display: flex;
    }
    .titlebar-project {
      text-align: left;
      padding-inline: 8px;
    }
  }
  @media (max-width: 700px) {
    .titlebar-project {
      display: none;
    }
  }
  :global(html[data-ui-scale='large']) .menu-compact-hidden {
    display: none;
  }
  :global(html[data-ui-scale='large']) .menu-overflow-entry {
    display: flex;
  }
  :global(html[data-ui-scale='large']) .titlebar-project {
    display: none;
  }
</style>
