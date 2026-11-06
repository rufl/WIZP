<script lang="ts">
  // Svelte 5 runes mode
  import { activeSidebarView } from '../stores';
  import Explorer from './Explorer.svelte';
  import Search from './Search.svelte';
  import Hub from './Hub.svelte';
  const sidebarTitle = $derived(
    (() => {
      const view = $activeSidebarView;
      if (view === 'explorer') return 'EXPLORER';
      if (view === 'search') return 'SEARCH';
      if (view === 'scm') return 'SOURCE CONTROL';
      if (view === 'agent') return 'ZIPI AGENT';
      if (view === 'debug') return 'RUN AND DEBUG';
      if (view === 'hub' || view === 'extensions') return 'EXTENSIONS';
      if (view.startsWith('contributed:')) return view.split(':')[1]?.toUpperCase() || 'VIEW';
      return view.toUpperCase();
    })(),
  );
</script>

<aside class="flex flex-col flex-1 overflow-hidden" aria-label={sidebarTitle}>
  <div class="flex items-center justify-between h-[35px] shrink-0 border-b border-border/30 px-3">
    <span class="text-[11px] font-semibold uppercase tracking-wider text-sidebar-fg"
      >{sidebarTitle}</span
    >
    <div class="flex gap-1">
      {#if $activeSidebarView === 'explorer'}
        <button
          type="button"
          class="sidebar-action flex items-center justify-center w-7 h-7 rounded-[4px] text-dim hover:text-sidebar-fg hover:bg-white/10 transition-colors"
          title="New File..."
          aria-label="New file"
          onclick={() => (window as any).__newExplorerFile?.()}
        >
          <span class="codicon codicon-new-file text-[14px]" aria-hidden="true"></span>
        </button>
        <button
          type="button"
          class="sidebar-action flex items-center justify-center w-7 h-7 rounded-[4px] text-dim hover:text-sidebar-fg hover:bg-white/10 transition-colors"
          title="New Folder..."
          aria-label="New folder"
          onclick={() => (window as any).__newExplorerFolder?.()}
        >
          <span class="codicon codicon-new-folder text-[14px]" aria-hidden="true"></span>
        </button>
        <button
          type="button"
          class="sidebar-action flex items-center justify-center w-7 h-7 rounded-[4px] text-dim hover:text-sidebar-fg hover:bg-white/10 transition-colors"
          title="Refresh Explorer"
          aria-label="Refresh Explorer"
          onclick={() => (window as any).__refreshExplorer?.()}
        >
          <span class="codicon codicon-refresh text-[14px]" aria-hidden="true"></span>
        </button>
      {/if}
    </div>
  </div>
  <div class="flex-1 overflow-y-auto overflow-x-hidden">
    {#if $activeSidebarView === 'explorer'}
      <Explorer />
    {:else if $activeSidebarView === 'search'}
      <Search />
    {:else if $activeSidebarView === 'scm'}
      {#await import('./SidebarViews.svelte') then { default: SidebarViewsComponent }}
        <SidebarViewsComponent viewId="scm" viewName="Source Control" />
      {/await}
    {:else if $activeSidebarView === 'debug'}
      {#await import('./SidebarViews.svelte') then { default: SidebarViewsComponent }}
        <SidebarViewsComponent viewId="debug" viewName="Run and Debug" />
      {/await}
    {:else if $activeSidebarView === 'hub' || $activeSidebarView === 'extensions'}
      <Hub />
    {:else if $activeSidebarView === 'agent'}
      {#await import('./AgentPanel.svelte') then { default: AgentPanelComponent }}
        <AgentPanelComponent />
      {/await}
    {:else if $activeSidebarView.startsWith('contributed:')}
      {#await import('./SidebarViews.svelte') then { default: SidebarViewsComponent }}
        <SidebarViewsComponent
          viewId={$activeSidebarView}
          viewName={$activeSidebarView.split(':')[1] || 'View'}
        />
      {/await}
    {/if}
  </div>
</aside>

<style>
  .sidebar-action:focus-visible {
    outline-offset: -2px;
  }
</style>
