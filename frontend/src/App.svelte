<script lang="ts">
  import Titlebar from './components/Titlebar.svelte';
  import ActivityBar from './components/ActivityBar.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import EditorArea from './components/EditorArea.svelte';
  import StatusBar from './components/StatusBar.svelte';
  import Panel from './components/Panel.svelte';
  import Settings from './components/Settings.svelte';
  import {
    isSidebarVisible,
    isPanelVisible,
    isRightSidebarVisible,
    isPanelMaximized,
    activityBarPosition,
    sidebarWidth,
    rsbWidth,
    panelHeight,
    projectPath,
    zoomLevel,
    zenMode,
  } from './stores';
  import { ensureBootstrapGroup } from '$lib/editor/state.svelte';
  import { loadRendererSession, updateRendererSession } from '$lib/session-recovery';
  import {
    getNativeBackendStatus,
    nativeControlCredentials,
    retryDaemonConnection as retryDaemonTransport,
    sendRpc,
  } from '../bridge';

  let settingsOpen = $state(false);
  let ctxMenu = $state<{ x: number; y: number; items: any[] } | null>(null);
  let ctxMenuRequest = 0;
  let ctxMenuReturnFocus: HTMLElement | null = null;
  let zoomInitialized = false;
  // Auxiliary overlays remain lazy-loaded; the panel itself is statically
  // imported so a missing chunk cannot blank the primary bottom UI.

  let sessionHydrated = $state(false);

  $effect(() => {
    void loadRendererSession()
      .then((snapshot) => {
        if (typeof snapshot.sidebarVisible === 'boolean')
          isSidebarVisible.set(snapshot.sidebarVisible);
        if (typeof snapshot.panelVisible === 'boolean') isPanelVisible.set(snapshot.panelVisible);
        if (snapshot.editorSession?.terminalLayout) isPanelVisible.set(true);
        if (typeof snapshot.panelHeight === 'number') {
          panelHeight.set(Math.max(100, Math.min(snapshot.panelHeight, 800)));
        }
        const folders = Array.isArray(snapshot.folders) ? snapshot.folders : [];
        const firstFolder = folders.find((folder) => typeof folder?.path === 'string')?.path;
        if (firstFolder) projectPath.set(firstFolder);
        sessionHydrated = true;
      })
      .catch(() => {
        sessionHydrated = true;
      });
  });
  const deferredUiReady = $state(true);
  let daemonAnnouncement = $state('');
  let daemonConnectionState = $state<'connected' | 'disconnected' | null>(null);
  let daemonRetrying = $state(false);

  $effect(() => {
    void getNativeBackendStatus()
      .then((status) => {
        if (!status) return;
        daemonConnectionState = status.state === 'ready' ? 'connected' : 'disconnected';
        daemonAnnouncement =
          status.state === 'ready' ? 'Daemon connected.' : 'Daemon unavailable. Retry connection.';
      })
      .catch(() => {
        // Browser mode and older native hosts use the transport event path.
      });
  });
  $effect(() => {
    const handleDaemonDisconnected = () => {
      if (daemonConnectionState === 'disconnected') return;
      daemonConnectionState = 'disconnected';
      daemonAnnouncement = 'Daemon disconnected. Reconnecting…';
    };
    const handleDaemonReconnected = () => {
      if (daemonConnectionState === 'connected') return;
      daemonConnectionState = 'connected';
      daemonAnnouncement = 'Daemon reconnected.';
    };
    window.addEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
    window.addEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    return () => {
      window.removeEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
      window.removeEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    };
  });

  async function retryDaemon() {
    if (daemonRetrying) return;
    daemonRetrying = true;
    daemonAnnouncement = 'Retrying daemon connection…';
    try {
      const connected = await retryDaemonTransport();
      if (!connected) {
        daemonConnectionState = 'disconnected';
        daemonAnnouncement = 'Daemon unavailable. Retry connection.';
      }
    } finally {
      daemonRetrying = false;
    }
  }

  try {
    const savedLayout = JSON.parse(localStorage.getItem('wizp-layout') || '{}');
    if (typeof savedLayout.sidebarVisible === 'boolean')
      isSidebarVisible.set(savedLayout.sidebarVisible);
    if (typeof savedLayout.panelVisible === 'boolean') isPanelVisible.set(savedLayout.panelVisible);
    if (typeof savedLayout.rightSidebarVisible === 'boolean') {
      isRightSidebarVisible.set(savedLayout.rightSidebarVisible);
    }
    if (typeof savedLayout.panelMaximized === 'boolean')
      isPanelMaximized.set(savedLayout.panelMaximized);
    if (['left', 'top-left', 'top-right', 'hidden'].includes(savedLayout.activityBarPosition)) {
      activityBarPosition.set(savedLayout.activityBarPosition);
    }
    if (Number.isFinite(savedLayout.sidebarWidth)) {
      sidebarWidth.set(Math.max(150, Math.min(savedLayout.sidebarWidth, 800)));
    }
    if (Number.isFinite(savedLayout.rsbWidth)) {
      rsbWidth.set(Math.max(220, Math.min(savedLayout.rsbWidth, 800)));
    }
    if (Number.isFinite(savedLayout.panelHeight)) {
      panelHeight.set(Math.max(100, Math.min(savedLayout.panelHeight, 800)));
    }
  } catch {
    // Best-effort menu discovery; the built-in menu remains available.
  }

  try {
    const savedZoom = Number(localStorage.getItem('wizp-zoom-level'));
    if (Number.isFinite(savedZoom) && savedZoom >= 0.5 && savedZoom <= 3) {
      zoomLevel.set(savedZoom);
    }
  } catch {
    // Best-effort keybinding discovery; built-in shortcuts remain available.
  }

  function closeContextMenu() {
    ctxMenuRequest++;
    ctxMenu = null;
    const target = ctxMenuReturnFocus;
    ctxMenuReturnFocus = null;
    if (target?.isConnected) target.focus();
  }

  $effect(() => {
    (window as any).__showCtxMenu = async (
      x: number,
      y: number,
      items: any[],
      menu = 'editor/context',
    ) => {
      const request = ++ctxMenuRequest;
      ctxMenuReturnFocus =
        document.activeElement instanceof HTMLElement ? document.activeElement : null;
      ctxMenu = { x, y, items };
      try {
        const res = await sendRpc('extension/menus', { menu });
        if (request !== ctxMenuRequest || !ctxMenu) return;
        const contributed = (res?.menus || [])
          .filter((item: any) => item.enabled !== false)
          .map((item: any) => ({
            label: item.title || item.command,
            accel: item.group,
            action: () =>
              sendRpc('extension/execute', { command: item.command, args: item.args || [] }).catch(
                () => {},
              ),
          }));
        if (contributed.length) {
          ctxMenu = { x, y, items: [...items, { sep: true }, ...contributed] };
        }
      } catch {
        // Context-menu discovery is optional for the local editor surface.
      }
    };
    return () => {
      ctxMenuRequest++;
      delete (window as any).__showCtxMenu;
    };
  });

  function platformName() {
    const platform = navigator.platform.toLowerCase();
    if (platform.includes('mac')) return 'mac';
    if (platform.includes('win')) return 'win';
    return 'linux';
  }

  function modalOpen() {
    return Array.from(document.querySelectorAll<HTMLElement>('[aria-modal="true"]')).some(
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
  }

  function eventToVSCodeKey(e: KeyboardEvent) {
    const parts: string[] = [];
    if (e.ctrlKey) parts.push('ctrl');
    if (e.shiftKey) parts.push('shift');
    if (e.altKey) parts.push('alt');
    if (e.metaKey) parts.push('cmd');
    const raw = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase().replace(/\s+/g, '');
    if (['control', 'shift', 'alt', 'meta'].includes(raw)) return '';
    parts.push(raw);
    return parts.join('+');
  }

  $effect(() => {
    const onKey = async (e: KeyboardEvent) => {
      if (e.defaultPrevented || modalOpen()) return;
      const target = e.target as HTMLElement | null;
      if (target && ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return;
      const key = eventToVSCodeKey(e);
      if (!key) return;
      try {
        const res = await sendRpc('extension/keybindings', { platform: platformName() });
        const overrides = JSON.parse(localStorage.getItem('wizp-keybinding-overrides') || '{}');
        const binding = (res?.keybindings || []).find((kb: any) => {
          const effective = String(overrides[kb.command] || kb.key).toLowerCase();
          return kb.enabled !== false && effective === key;
        });
        if (!binding) return;
        e.preventDefault();
        await sendRpc('extension/execute', { command: binding.command });
      } catch {
        // Extension keybindings are optional and may be unavailable at startup.
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  });

  $effect(() => {
    ensureBootstrapGroup();
    const handler = () => {
      settingsOpen = true;
    };
    document.addEventListener('settings:open', handler);
    (window as any).__openSettings = handler;
    return () => {
      document.removeEventListener('settings:open', handler);
      delete (window as any).__openSettings;
    };
  });

  $effect(() => {
    if (sessionHydrated) {
      const layout = {
        sidebarVisible: $isSidebarVisible,
        panelVisible: $isPanelVisible,
        rightSidebarVisible: $isRightSidebarVisible,
        panelMaximized: $isPanelMaximized,
        activityBarPosition: $activityBarPosition,
        sidebarWidth: $sidebarWidth,
        rsbWidth: $rsbWidth,
        panelHeight: $panelHeight,
      };
      if (nativeControlCredentials()) {
        void updateRendererSession(layout).catch(() => {});
      } else {
        try {
          localStorage.setItem('wizp-layout', JSON.stringify(layout));
        } catch {
          // Layout restoration is best effort; defaults are already active.
        }
      }
    }
    document.documentElement.style.setProperty(
      '--sidebar-width',
      $isSidebarVisible && !$zenMode ? `${$sidebarWidth}px` : '0px',
    );
    document.documentElement.style.setProperty(
      '--rsb-width',
      $isRightSidebarVisible && !$zenMode ? `${$rsbWidth}px` : '0px',
    );
    if ($zenMode) {
      document.documentElement.style.setProperty('--panel-height', '0px');
    } else if ($isPanelVisible) {
      // 35px titlebar + 28px statusbar + 35px panel tabbar = 98px overhead
      const h = $isPanelMaximized ? 'calc(100vh - 98px)' : `${$panelHeight}px`;
      document.documentElement.style.setProperty('--panel-height', h);
    } else {
      document.documentElement.style.setProperty('--panel-height', '0px');
    }
  });

  $effect(() => {
    document.body.style.zoom = $zoomLevel.toString();
    document.documentElement.dataset.uiScale = $zoomLevel >= 1.5 ? 'large' : 'normal';
    if (zoomInitialized) {
      try {
        localStorage.setItem('wizp-zoom-level', String($zoomLevel));
      } catch {
        // Zoom persistence is best effort and must not block editor startup.
      }
      // Force a resize event so Monaco recalculates after user-driven zoom changes.
      window.dispatchEvent(new Event('resize'));
    }
    zoomInitialized = true;
  });

  $effect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (modalOpen()) return;
      // Zoom
      if (e.ctrlKey || e.metaKey) {
        if (e.key === '=' || e.key === '+') {
          e.preventDefault();
          zoomLevel.update((z) => Math.min(z + 0.1, 3));
        } else if (e.key === '-') {
          e.preventDefault();
          zoomLevel.update((z) => Math.max(z - 0.1, 0.5));
        } else if (e.key === '0') {
          e.preventDefault();
          zoomLevel.set(1);
        }
      }
      // F11 Zen Mode / Fullscreen
      if (e.key === 'F11') {
        e.preventDefault();
        zenMode.update((z) => {
          const next = !z;
          if (next) {
            document.documentElement.requestFullscreen().catch(() => {});
          } else {
            document.exitFullscreen().catch(() => {});
          }
          return next;
        });
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  });

  function startResizeSidebar(e: MouseEvent) {
    e.preventDefault();
    const startX = e.clientX;
    const startWidth = $sidebarWidth;
    function onMove(ev: MouseEvent) {
      sidebarWidth.set(Math.max(150, Math.min(startWidth + (ev.clientX - startX), 800)));
    }
    function onUp() {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      document.body.style.cursor = '';
    }
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    document.body.style.cursor = 'col-resize';
  }

  function startResizePanel(e: MouseEvent) {
    e.preventDefault();
    const startY = e.clientY;
    const startHeight = $panelHeight;
    function onMove(ev: MouseEvent) {
      panelHeight.set(Math.max(100, Math.min(startHeight - (ev.clientY - startY), 800)));
    }
    function onUp() {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      document.body.style.cursor = '';
    }
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    document.body.style.cursor = 'row-resize';
  }

  function startResizeRSB(e: MouseEvent) {
    e.preventDefault();
    const startX = e.clientX;
    const startWidth = $rsbWidth;
    function onMove(ev: MouseEvent) {
      rsbWidth.set(Math.max(220, Math.min(startWidth - (ev.clientX - startX), 800)));
    }
    function onUp() {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
      document.body.style.cursor = '';
    }
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    document.body.style.cursor = 'col-resize';
  }

  function resizeSidebarWithKeyboard(event: KeyboardEvent) {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    const delta = (event.shiftKey ? 40 : 10) * (event.key === 'ArrowRight' ? 1 : -1);
    sidebarWidth.update((width) => Math.max(150, Math.min(width + delta, 800)));
  }

  function resizePanelWithKeyboard(event: KeyboardEvent) {
    if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
    event.preventDefault();
    const delta = (event.shiftKey ? 40 : 10) * (event.key === 'ArrowUp' ? 1 : -1);
    panelHeight.update((height) => Math.max(100, Math.min(height + delta, 800)));
  }

  function resizeRightSidebarWithKeyboard(event: KeyboardEvent) {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    const delta = (event.shiftKey ? 40 : 10) * (event.key === 'ArrowLeft' ? 1 : -1);
    rsbWidth.update((width) => Math.max(220, Math.min(width + delta, 800)));
  }

  let debugToolbarActive = $state(false);
  let debugPaused = $state(false);

  $effect(() => {
    const onStart = (event: Event) => {
      debugToolbarActive = true;
      debugPaused = !!(event as CustomEvent).detail?.paused;
    };
    const onStopped = () => {
      debugToolbarActive = true;
      debugPaused = true;
    };
    const onContinued = () => {
      debugToolbarActive = true;
      debugPaused = false;
    };
    const onTerminated = () => {
      debugToolbarActive = false;
      debugPaused = false;
    };
    window.addEventListener('wizpDebugStarted', onStart);
    window.addEventListener('wizpDebugStopped', onStopped);
    window.addEventListener('wizpDebugContinued', onContinued);
    window.addEventListener('wizpDebugTerminated', onTerminated);
    return () => {
      window.removeEventListener('wizpDebugStarted', onStart);
      window.removeEventListener('wizpDebugStopped', onStopped);
      window.removeEventListener('wizpDebugContinued', onContinued);
      window.removeEventListener('wizpDebugTerminated', onTerminated);
    };
  });
</script>

<div class="workbench flex flex-col h-screen w-full bg-bg text-fg overflow-hidden select-none">
  <div class="sr-only" role="status" aria-live="polite" aria-atomic="true" aria-relevant="text">
    {daemonAnnouncement}
  </div>

  {#if daemonConnectionState === 'disconnected'}
    <div class="daemon-recovery-banner" role="alert" aria-live="assertive" aria-atomic="true">
      <span>{daemonRetrying ? 'Retrying daemon connection…' : daemonAnnouncement}</span>
      <button type="button" onclick={() => void retryDaemon()} disabled={daemonRetrying}>
        {daemonRetrying ? 'Retrying…' : 'Retry'}
      </button>
    </div>
  {/if}
  <Titlebar />

  <div class="workbench-main flex flex-1 overflow-hidden relative p-0 gap-0 bg-bg">
    {#if $activityBarPosition === 'left' && !$zenMode}
      <ActivityBar orientation="vertical" />
    {/if}

    {#if $isSidebarVisible && !$zenMode}
      <div
        class="primary-sidebar flex flex-col flex-shrink-0 bg-sidebar z-10 rounded-t-xl rounded-b-[3px] border border-border/10 overflow-hidden shadow-sm transition-[background-color,border-color,width]"
        class:ml-[2px]={$activityBarPosition === 'left'}
        style="width: var(--sidebar-width);"
      >
        {#if $activityBarPosition === 'top-left'}
          <ActivityBar orientation="horizontal" />
        {/if}
        <Sidebar />
      </div>
      <button
        type="button"
        class="primary-sidebar-resizer w-1 -ml-[2px] mr-[1px] cursor-col-resize hover:bg-accent/50 z-50 transition-colors border-0 bg-transparent p-0"
        aria-label={`Resize sidebar with Left and Right Arrow keys; current width ${$sidebarWidth} pixels`}
        onmousedown={startResizeSidebar}
        onkeydown={resizeSidebarWithKeyboard}
      ></button>
    {/if}

    <div class="workbench-center flex flex-col flex-1 min-w-0 overflow-hidden relative z-0 gap-0">
      <div
        class="flex-1 min-h-0 relative rounded-t-xl rounded-b-[3px] border border-border/10 shadow-sm bg-panel overflow-hidden"
      >
        <EditorArea />
      </div>
      {#if !$zenMode}
        <button
          type="button"
          class="h-1 -mt-[2px] -mb-[2px] cursor-row-resize hover:bg-accent/50 z-50 transition-colors border-0 bg-transparent p-0"
          aria-label={`Resize panel with Up and Down Arrow keys; current height ${$panelHeight} pixels`}
          class:hidden={!$isPanelVisible}
          onmousedown={startResizePanel}
          onkeydown={resizePanelWithKeyboard}
        ></button>
        <div
          class="flex flex-col flex-shrink-0 min-h-0 min-w-0 border border-border/10 border-t-white/10 bg-panel z-10 transition-colors rounded-t-xl rounded-b-[3px] shadow-sm overflow-hidden -mt-[1px] relative"
          class:hidden={!$isPanelVisible}
          style="height: var(--panel-height);"
        >
          {#if $isPanelVisible}
            <Panel />
          {/if}
        </div>
      {/if}
    </div>

    {#if $isRightSidebarVisible && !$zenMode}
      <button
        type="button"
        class="secondary-sidebar-resizer w-1 -mr-[2px] ml-[1px] cursor-col-resize hover:bg-accent/50 z-50 transition-colors border-0 bg-transparent p-0"
        aria-label={`Resize right sidebar with Left and Right Arrow keys; current width ${$rsbWidth} pixels`}
        onmousedown={startResizeRSB}
        onkeydown={resizeRightSidebarWithKeyboard}
      ></button>
      <div
        class="secondary-sidebar flex flex-col flex-shrink-0 bg-sidebar z-10 transition-colors rounded-t-xl rounded-b-[3px] border border-border/10 shadow-sm overflow-hidden"
        style="width: var(--rsb-width);"
      >
        {#if $activityBarPosition === 'top-right'}
          <ActivityBar orientation="horizontal" />
        {/if}
        <div
          class="h-[35px] flex items-center px-4 text-[11px] uppercase tracking-wider text-dim flex-shrink-0 font-semibold border-b border-border/50"
        >
          Outline
        </div>
        <!-- Reuse Explorer's Outline section directly via a dedicated outline component -->
        {#await import('./components/OutlinePanel.svelte') then { default: OutlinePanelComponent }}
          <OutlinePanelComponent />
        {/await}
      </div>
    {/if}
  </div>

  {#if !$zenMode}
    <StatusBar />
  {/if}

  {#if deferredUiReady}
    {#await import('./components/CommandPalette.svelte') then { default: CommandPaletteComponent }}
      <CommandPaletteComponent />
    {/await}
    {#await import('./components/UIPrompts.svelte') then { default: UIPromptsComponent }}
      <UIPromptsComponent />
    {/await}
    {#await import('./components/ToastContainer.svelte') then { default: ToastContainerComponent }}
      <ToastContainerComponent />
    {/await}
  {/if}
  {#if settingsOpen}
    <Settings isOpen={settingsOpen} onClose={() => (settingsOpen = false)} />
  {/if}
  {#if debugToolbarActive}
    {#await import('./components/DebugToolbar.svelte') then { default: DebugToolbarComponent }}
      <DebugToolbarComponent active={debugToolbarActive} paused={debugPaused} />
    {/await}
  {/if}

  {#if ctxMenu}
    {#await import('./components/ContextMenu.svelte') then { default: ContextMenuComponent }}
      <ContextMenuComponent
        x={ctxMenu.x}
        y={ctxMenu.y}
        items={ctxMenu.items}
        onClose={closeContextMenu}
      />
    {/await}
  {/if}
</div>
