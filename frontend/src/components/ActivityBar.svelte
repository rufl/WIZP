<script lang="ts">
  import { sendRpc } from '../../bridge';
  import { activeSidebarView, switchSidebarView, isSidebarVisible } from '../stores';
  import { shortcutFor } from '../shortcuts';

  const { orientation = 'vertical' }: { orientation?: 'vertical' | 'horizontal' } = $props();

  let contributedItems = $state<any[]>([]);
  let contributedLoadTicket = 0;

  const defaultItems = [
    { view: 'explorer', icon: 'files', title: `Explorer (${shortcutFor('view.explorer')})` },
    { view: 'search', icon: 'search', title: `Search (${shortcutFor('view.search')})` },
    { view: 'scm', icon: 'source-control', title: `Source Control (${shortcutFor('view.scm')})` },
    {
      view: 'debug',
      icon: 'debug-alt-small',
      title: `Run and Debug (${shortcutFor('view.debug')})`,
    },
    { view: 'hub', icon: 'extensions', title: `Extensions (${shortcutFor('view.extensions')})` },
    { view: 'agent', icon: 'sparkle', title: 'ZIPI Agent' },
  ];

  async function loadContributed() {
    try {
      const containersRes = await sendRpc('extension/viewsContainers', {});
      contributedItems = containersRes?.containers || containersRes || [];
    } catch {
      contributedItems = [];
    }
  }

  function scheduleLoadContributed() {
    const ticket = ++contributedLoadTicket;
    requestAnimationFrame(() => {
      setTimeout(() => {
        if (ticket === contributedLoadTicket) loadContributed();
      }, 200);
    });
  }

  function handleClick(view: string) {
    if (!$isSidebarVisible && orientation !== 'horizontal') isSidebarVisible.set(true);
    switchSidebarView(view);
  }

  $effect(() => {
    scheduleLoadContributed();
    document.addEventListener('extensions:refreshed', loadContributed);
    return () => {
      contributedLoadTicket++;
      document.removeEventListener('extensions:refreshed', loadContributed);
    };
  });
</script>

<nav
  class="flex shrink-0 bg-sidebar border-border transition-colors duration-200 z-20
    {orientation === 'vertical'
    ? 'flex-col w-[48px] h-full border-r items-center py-2'
    : 'flex-row h-[35px] w-full border-b items-center px-2'}"
  aria-label="Activity bar"
>
  <div class="flex {orientation === 'vertical' ? 'flex-col gap-2' : 'flex-row gap-1'} flex-1">
    {#each defaultItems as item (item.view)}
      <button
        type="button"
        class="activity-button group relative flex items-center justify-center cursor-pointer border-0 bg-transparent p-0 transition-colors duration-150 rounded-[6px]
          {orientation === 'vertical' ? 'w-10 h-10' : 'w-8 h-8'}
          {$activeSidebarView === item.view
          ? 'text-fg'
          : 'text-activity-inactive hover:text-fg hover:bg-white/5'}"
        title={item.title}
        aria-label={item.title}
        aria-pressed={$activeSidebarView === item.view}
        onclick={() => handleClick(item.view)}
      >
        <span class="codicon codicon-{item.icon} text-[22px]" aria-hidden="true"></span>
        {#if $activeSidebarView === item.view}
          <span
            class="absolute bg-accent rounded-full transition-[inset,width,height] duration-300
            {orientation === 'vertical'
              ? 'left-[-4px] top-2 bottom-2 w-[3px]'
              : 'bottom-[-6px] left-2 right-2 h-[3px]'}"
            aria-hidden="true"
          ></span>
        {/if}
      </button>
    {/each}
    {#each contributedItems as container (container.id)}
      {@const label = `${container.title} (${container.extensionName || 'Extension'})`}
      <button
        type="button"
        class="activity-button group relative flex items-center justify-center cursor-pointer border-0 bg-transparent p-0 transition-colors duration-150 rounded-[6px]
          {orientation === 'vertical' ? 'w-10 h-10' : 'w-8 h-8'}
          {$activeSidebarView === 'contributed:' + container.id
          ? 'text-fg'
          : 'text-activity-inactive hover:text-fg hover:bg-white/5'}"
        title={label}
        aria-label={label}
        aria-pressed={$activeSidebarView === 'contributed:' + container.id}
        onclick={() => handleClick(`contributed:${container.id}`)}
      >
        <span
          class="codicon codicon-{container.icon &&
          !container.icon.endsWith('.png') &&
          !container.icon.endsWith('.svg')
            ? container.icon
            : 'extensions'} text-[22px]"
          aria-hidden="true"
        ></span>
        {#if $activeSidebarView === 'contributed:' + container.id}
          <span
            class="absolute bg-accent rounded-full transition-[inset,width,height] duration-300
            {orientation === 'vertical'
              ? 'left-[-4px] top-2 bottom-2 w-[3px]'
              : 'bottom-[-6px] left-2 right-2 h-[3px]'}"
            aria-hidden="true"
          ></span>
        {/if}
      </button>
    {/each}
  </div>

  <div class="flex {orientation === 'vertical' ? 'flex-col gap-2 pb-2' : 'flex-row gap-1 pr-2'}">
    <button
      type="button"
      class="activity-button group relative flex items-center justify-center cursor-pointer border-0 bg-transparent p-0 transition-colors duration-150 rounded-[6px] text-activity-inactive hover:text-fg hover:bg-white/5
        {orientation === 'vertical' ? 'w-10 h-10' : 'w-8 h-8'}"
      title="Settings"
      aria-label="Settings"
      aria-haspopup="dialog"
      aria-controls="settings-dialog"
      onclick={(event) => {
        event.currentTarget.focus();
        document.dispatchEvent(new CustomEvent('settings:open'));
      }}
    >
      <span class="codicon codicon-settings-gear text-[22px]" aria-hidden="true"></span>
    </button>
  </div>
</nav>

<style>
  .activity-button:focus-visible {
    outline-offset: -3px;
  }
</style>
