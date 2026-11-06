<script lang="ts">
  import { tick } from 'svelte';
  import { sendRpc, showOpenFileDialog } from '../../bridge';
  import LoadingButton from './LoadingButton.svelte';
  import InlineFeedback from './InlineFeedback.svelte';
  import CopyButton from './CopyButton.svelte';
  import { switchSidebarView } from '../stores';

  type Message = { kind: 'status' | 'success' | 'error'; text: string };
  type ExtensionItem = {
    id: string;
    namespace?: string;
    name: string;
    displayName: string;
    description?: string;
    version?: string;
    downloads?: number;
    enabled?: boolean;
    source?: 'fixture' | 'marketplace' | 'local';
    updateAvailable?: boolean;
    restartRequired?: boolean;
    installFailureFixture?: boolean;
  };
  type HostState = {
    available: boolean;
    running: boolean;
    restartSupported: boolean;
    extensionCount: number;
    activatedCount: number;
    disabledCount: number;
    state: string;
  };

  let searchQuery = $state('');
  let searchResults = $state<ExtensionItem[]>([]);
  let installed = $state<ExtensionItem[]>([]);
  let activeTab = $state<'search' | 'installed'>('search');
  let searchLoading = $state(false);
  let searchError = $state('');
  let installedLoading = $state(true);
  let installedError = $state('');
  let networkAllowed = $state(false);
  let networkRequired = $state(false);
  let message = $state<Message | null>(null);
  let failedSearchQuery = $state('');
  let failedInstallExtension = $state<ExtensionItem | null>(null);
  let failedLocalVsixPath = $state('');
  let operation = $state('');
  let hostLoading = $state(true);
  let hostState = $state<HostState | null>(null);
  let hostError = $state('');
  let selectedExtensionId = $state('');
  let contributions = $state<any>(null);
  let contributionsLoading = $state(false);
  let uninstallTarget = $state<ExtensionItem | null>(null);
  let uninstallDialog = $state<HTMLDialogElement>();
  let uninstallTrigger = $state<HTMLButtonElement | null>(null);
  let didInitialLoad = false;
  let searchTicket = 0;
  let installedTicket = 0;
  let hostTicket = 0;

  const restartRequired = $derived(installed.some((extension) => extension.restartRequired));

  $effect(() => {
    if (didInitialLoad) return;
    didInitialLoad = true;
    void Promise.all([loadInstalled(), loadHostState()]);
  });

  $effect(() => {
    const windowRecord = window as typeof window & {
      __wizpCrashExtensionHost?: () => Promise<unknown>;
    };
    windowRecord.__wizpCrashExtensionHost = async () => {
      const result = await sendRpc('extension/crashHost', { fixture: true });
      await loadHostState();
      return result;
    };
    return () => {
      delete windowRecord.__wizpCrashExtensionHost;
    };
  });

  $effect(() => {
    const refresh = () => {
      void loadInstalled();
      void loadHostState();
    };
    document.addEventListener('extensions:installed', refresh);
    document.addEventListener('extensions:uninstalled', refresh);
    document.addEventListener('extensions:toggled', refresh);
    return () => {
      document.removeEventListener('extensions:installed', refresh);
      document.removeEventListener('extensions:uninstalled', refresh);
      document.removeEventListener('extensions:toggled', refresh);
    };
  });

  function fixtureMode() {
    return Boolean((window as any).__wizpHubFixture);
  }

  const NETWORK_REDACTION = '[redacted]';

  function errorMessage(cause: unknown, fallback: string) {
    if (cause instanceof Error && cause.message.trim()) return cause.message;
    if (typeof cause === 'string' && cause.trim()) return cause;
    return fallback;
  }
  function sanitizeNetworkError(cause: unknown, fallback: string) {
    const detail =
      typeof cause === 'string' && cause.trim() ? cause : errorMessage(cause, fallback);
    return Array.from(detail, (character) => {
      const code = character.charCodeAt(0);
      return code <= 0x1f || code === 0x7f ? ' ' : character;
    })
      .join('')
      .replace(/\b(?:https?|wss?):\/\/[^\s<>"'`]+/gi, NETWORK_REDACTION)
      .replace(/\bBearer\s+[^\s,;]+/gi, `Bearer ${NETWORK_REDACTION}`)
      .replace(
        /([?&\s])(?:token|access_token|refresh_token|id_token|api_key|apikey|authorization|password|passwd|secret)=([^\s&]+)/gi,
        `$1${NETWORK_REDACTION}`,
      )
      .replace(
        /(\b(?:token|access_token|refresh_token|id_token|api_key|apikey|authorization|password|passwd|secret)\b\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}&]+)/gi,
        `$1${NETWORK_REDACTION}`,
      )
      .trim();
  }

  function announce(kind: Message['kind'], text: string) {
    message = { kind, text };
  }

  function selectTab(tab: 'search' | 'installed') {
    activeTab = tab;
    if (tab === 'installed') void loadInstalled();
  }

  function handleTabKey(event: KeyboardEvent) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === 'ArrowLeft' || event.key === 'Home' ? 'search' : 'installed';
    selectTab(next);
    void tick().then(() =>
      document.querySelector<HTMLButtonElement>(`#extensions-tab-${next}`)?.focus(),
    );
  }

  async function doSearch(allowNetwork = networkAllowed) {
    if (searchLoading) return;
    const query = searchQuery.trim();
    if (!query) {
      searchError = 'Enter an extension name or feature to search.';
      document.getElementById('extension-search-input')?.focus();
      return;
    }
    searchError = '';
    const ticket = ++searchTicket;
    searchLoading = true;
    networkRequired = false;
    message = null;
    try {
      const result = await sendRpc('hub/search', {
        query,
        allowNetwork,
        fixture: fixtureMode(),
      });
      if (ticket !== searchTicket) return;
      searchResults = (result?.extensions || []).map((extension: any) => ({
        id: extension.id || `${extension.namespace}.${extension.name}`,
        namespace: extension.namespace,
        name: extension.name,
        displayName: extension.displayName || extension.name,
        description: extension.description || '',
        version: extension.version || '',
        downloads: extension.downloads || extension.downloadCount || 0,
        updateAvailable: Boolean(extension.updateAvailable),
        installFailureFixture: Boolean(extension.installFailureFixture),
      }));
      networkRequired = Boolean(result?.networkRequired);
      if (result?.error) {
        failedSearchQuery = query;
        announce(
          'error',
          `OpenVSX search failed: ${sanitizeNetworkError(result.error, 'The extension service did not respond.')}. Check the connection and retry.`,
        );
      } else {
        failedSearchQuery = '';
        if (!networkRequired) {
          announce(
            'status',
            searchResults.length === 1
              ? '1 extension found.'
              : `${searchResults.length} extensions found.`,
          );
        }
      }
    } catch (cause) {
      if (ticket !== searchTicket) return;
      failedSearchQuery = query;
      announce(
        'error',
        `Search failed: ${sanitizeNetworkError(cause, 'The extension service did not respond.')}`,
      );
    } finally {
      if (ticket === searchTicket) searchLoading = false;
    }
  }

  function allowNetworkSearch() {
    networkAllowed = true;
    networkRequired = false;
    void doSearch(true);
  }

  async function loadInstalled() {
    const ticket = ++installedTicket;
    installedLoading = true;
    installedError = '';
    try {
      const result = await sendRpc('hub/list', {});
      if (ticket !== installedTicket) return;
      installed = (result?.installed || []).map((extension: any) => ({
        ...extension,
        id: extension.id,
        name: extension.name || extension.id,
        displayName: extension.displayName || extension.name || extension.id,
      }));
    } catch (cause) {
      if (ticket !== installedTicket) return;
      installedError = errorMessage(cause, 'Installed extensions could not be loaded.');
    } finally {
      if (ticket === installedTicket) installedLoading = false;
    }
  }

  async function loadHostState() {
    const ticket = ++hostTicket;
    hostLoading = true;
    hostError = '';
    try {
      const result = await sendRpc('extension/hostStatus', {});
      if (ticket !== hostTicket) return;
      hostState = result;
      if (!result?.available || !result?.running) {
        hostError = 'The extension host is unavailable. Extension commands and views are paused.';
      }
    } catch (cause) {
      if (ticket !== hostTicket) return;
      hostState = null;
      hostError = errorMessage(cause, 'The extension host is unavailable.');
    } finally {
      if (ticket === hostTicket) hostLoading = false;
    }
  }

  async function installExtension(extension: ExtensionItem) {
    if (operation) return;
    operation = `install:${extension.id}`;
    message = null;
    try {
      const result = await sendRpc('hub/install', {
        namespace: extension.namespace,
        name: extension.name,
        displayName: extension.displayName,
        version: extension.version,
        allowNetwork: networkAllowed,
        fixture: fixtureMode(),
        fixtureFailure: extension.installFailureFixture,
      });
      failedInstallExtension = null;
      await loadInstalled();
      activeTab = 'installed';
      selectedExtensionId = result?.id || extension.id;
      announce(
        'success',
        result?.restartRequired
          ? `${extension.displayName} installed. Restart the extension host to load its contributions.`
          : `${extension.displayName} installed and enabled.`,
      );
      document.dispatchEvent(new CustomEvent('extensions:installed', { detail: result }));
    } catch (cause) {
      failedInstallExtension = extension;
      announce(
        'error',
        `Install failed for ${extension.displayName}: ${sanitizeNetworkError(cause, 'No extensions were changed.')}`,
      );
    } finally {
      operation = '';
    }
  }

  async function installLocalVSIX(pathOverride = '') {
    if (operation) return;
    operation = 'install-local';
    message = null;
    let selectedPath = pathOverride;
    try {
      selectedPath = pathOverride || (await showOpenFileDialog({ multiple: false }))[0];
      const path = selectedPath;
      if (!path) {
        failedLocalVsixPath = '';
        announce('status', 'VSIX installation canceled.');
        return;
      }
      if (!path.toLowerCase().endsWith('.vsix')) {
        failedLocalVsixPath = '';
        announce('error', 'Choose a .vsix extension package. No files were installed.');
        return;
      }
      const result = await sendRpc('hub/installLocal', { path });
      failedLocalVsixPath = '';
      selectedExtensionId = result.id;
      activeTab = 'installed';
      await loadInstalled();
      announce(
        'success',
        `${result.displayName} ${result.version} installed. Restart the extension host to load its commands, views, and settings.`,
      );
      document.dispatchEvent(new CustomEvent('extensions:installed', { detail: result }));
    } catch (cause) {
      failedLocalVsixPath = selectedPath;
      announce(
        'error',
        `VSIX install failed: ${errorMessage(cause, 'The package was not installed. Check that it is a valid VSIX file.')}`,
      );
    } finally {
      operation = '';
    }
  }

  function retryLocalVSIX() {
    if (failedLocalVsixPath) void installLocalVSIX(failedLocalVsixPath);
  }

  async function refreshAfterHostRestart() {
    await sendRpc('hub/markRestarted', {});
    await Promise.all([loadInstalled(), loadHostState()]);
    if (selectedExtensionId) await loadContributions(selectedExtensionId);
    document.dispatchEvent(new CustomEvent('extensions:refreshed'));
  }

  async function restartExtensionHost() {
    if (operation) return;
    operation = 'restart-host';
    message = null;
    try {
      await sendRpc('extension/restartHost', {});
      await refreshAfterHostRestart();
      announce('success', 'Extension host restarted. Contributions are available.');
    } catch (cause) {
      announce(
        'error',
        `Extension host restart failed: ${errorMessage(cause, 'Retry, or restart WIZP if the host remains unavailable.')}`,
      );
      await loadHostState();
    } finally {
      operation = '';
    }
  }

  async function retryHostRecovery() {
    if (operation || hostLoading) return;
    const previousHostError = hostError;
    operation = 'retry-host';
    message = null;
    let restartFailure: unknown = null;
    try {
      try {
        await sendRpc('extension/restartHost', {});
        await refreshAfterHostRestart();
      } catch (cause) {
        restartFailure = cause;
      }
      if (restartFailure) {
        await loadHostState();
        hostError =
          previousHostError || errorMessage(restartFailure, 'The extension host is unavailable.');
        announce(
          'error',
          `Extension host restart failed: ${errorMessage(restartFailure, 'Retry, or restart WIZP if the host remains unavailable.')}`,
        );
      } else {
        announce('success', 'Extension host restarted. Contributions are available.');
      }
    } finally {
      operation = '';
    }
  }

  async function toggleExtension(extension: ExtensionItem, enabled: boolean) {
    if (operation) return;
    operation = `toggle:${extension.id}`;
    message = null;
    try {
      await sendRpc('extension/execute', {
        command: enabled
          ? 'workbench.extensions.enableExtension'
          : 'workbench.extensions.disableExtension',
        args: [extension.id],
      });
      await sendRpc('hub/toggle', { extensionId: extension.id, enabled });
      await loadInstalled();
      announce('success', `${extension.displayName} ${enabled ? 'enabled' : 'disabled'}.`);
      document.dispatchEvent(
        new CustomEvent('extensions:toggled', { detail: { id: extension.id, enabled } }),
      );
    } catch (cause) {
      announce(
        'error',
        `${enabled ? 'Enable' : 'Disable'} failed for ${extension.displayName}: ${errorMessage(cause, 'The previous state was kept.')}`,
      );
    } finally {
      operation = '';
    }
  }

  function openUninstallDialog(extension: ExtensionItem, trigger: HTMLButtonElement) {
    uninstallTarget = extension;
    uninstallTrigger = trigger;
    void tick().then(() => uninstallDialog?.showModal());
  }

  function closeUninstallDialog() {
    uninstallTarget = null;
    uninstallDialog?.close();
    const trigger = uninstallTrigger;
    uninstallTrigger = null;
    requestAnimationFrame(() => trigger?.focus());
  }

  async function uninstallExtension() {
    const extension = uninstallTarget;
    if (!extension || operation) return;
    operation = `uninstall:${extension.id}`;
    try {
      await sendRpc('hub/uninstall', { extensionId: extension.id });
      if (selectedExtensionId === extension.id) {
        selectedExtensionId = '';
        contributions = null;
      }
      closeUninstallDialog();
      await loadInstalled();
      announce(
        'success',
        `${extension.displayName} uninstalled. Restart WIZP if an already-loaded contribution remains visible.`,
      );
      document.dispatchEvent(
        new CustomEvent('extensions:uninstalled', { detail: { id: extension.id } }),
      );
    } catch (cause) {
      announce(
        'error',
        `Uninstall failed for ${extension.displayName}: ${errorMessage(cause, 'The extension remains installed.')}`,
      );
    } finally {
      operation = '';
    }
  }

  async function loadContributions(extensionId: string) {
    selectedExtensionId = extensionId;
    contributionsLoading = true;
    contributions = null;
    try {
      const result = await sendRpc('extension/contributionSnapshot', {
        extensionId,
        platform: navigator.platform.toLowerCase().includes('mac')
          ? 'mac'
          : navigator.platform.toLowerCase().includes('win')
            ? 'win'
            : 'linux',
      });
      if (selectedExtensionId !== extensionId) return;
      if (result?.status !== 'ok') {
        announce(
          'error',
          'Contributions are not loaded yet. Restart the extension host and retry.',
        );
        return;
      }
      contributions = result;
      announce('status', `Loaded contributions for ${result.displayName}.`);
    } catch (cause) {
      if (selectedExtensionId !== extensionId) return;
      announce(
        'error',
        `Could not load extension contributions: ${errorMessage(cause, 'Restart the extension host and retry.')}`,
      );
    } finally {
      if (selectedExtensionId === extensionId) contributionsLoading = false;
    }
  }

  async function runContributionCommand(command: any) {
    if (operation || command.enabled === false) return;
    operation = `command:${command.command}`;
    try {
      await sendRpc('extension/execute', { command: command.command });
      announce('success', `${command.title || command.command} completed.`);
    } catch (cause) {
      announce(
        'error',
        `Command failed: ${errorMessage(cause, 'The extension did not complete the command.')}`,
      );
    } finally {
      operation = '';
    }
  }

  function openContributedView(container: any) {
    document.dispatchEvent(new CustomEvent('extensions:refreshed'));
    switchSidebarView(`contributed:${container.id}`);
  }

  function openExtensionSettings() {
    document.dispatchEvent(new CustomEvent('settings:open'));
  }
</script>

<div class="hub-container">
  <section class="hub-host" aria-label="Extension host status">
    <div class="hub-host-copy">
      <span
        class="host-indicator"
        class:ready={hostState?.available && hostState?.running}
        aria-hidden="true"
      ></span>
      <div>
        <strong>Extension host</strong>
        {#if hostLoading}
          <span>Checking status…</span>
        {:else if hostError}
          <span>{hostError}</span>
        {:else}
          <span>
            Running · {hostState?.extensionCount || 0} discovered · {hostState?.activatedCount || 0}
            active
          </span>
        {/if}
      </div>
    </div>
    {#if hostError}
      <LoadingButton
        label="Retry"
        pendingLabel="Retrying…"
        pending={operation === 'retry-host'}
        disabled={hostLoading || (!!operation && operation !== 'retry-host')}
        class="hub-button secondary"
        onclick={() => void retryHostRecovery()}
      />
    {:else if hostState?.restartSupported}
      <LoadingButton
        label="Restart Host"
        pendingLabel="Restarting…"
        pending={operation === 'restart-host'}
        disabled={!!operation && operation !== 'restart-host'}
        class="hub-button secondary"
        onclick={() => void restartExtensionHost()}
      />
    {/if}
  </section>

  {#if restartRequired}
    <div class="hub-notice" role="status">
      Restart the extension host to load newly installed contributions.
      <button type="button" disabled={!!operation} onclick={() => void restartExtensionHost()}
        >Restart now</button
      >
    </div>
  {/if}
  {#if message}
    <div
      class="hub-message"
      class:error={message.kind === 'error'}
      class:success={message.kind === 'success'}
      role={message.kind === 'error' ? 'alert' : 'status'}
      aria-live={message.kind === 'error' ? 'assertive' : 'polite'}
      aria-relevant="text"
    >
      {message.text}
      {#if message.kind === 'error' && failedSearchQuery}
        <button type="button" class="hub-link-button" onclick={() => void doSearch(networkAllowed)}
          >Retry search</button
        >
      {/if}
      {#if message.kind === 'error' && failedInstallExtension}
        <button
          type="button"
          class="hub-link-button"
          onclick={() => void installExtension(failedInstallExtension)}
        >
          Retry install
        </button>
      {/if}
      {#if message.kind === 'error' && failedLocalVsixPath}
        <button type="button" class="hub-link-button" onclick={retryLocalVSIX}
          >Retry VSIX install</button
        >
      {/if}
    </div>
  {/if}

  <div class="hub-tabs" role="tablist" aria-label="Extensions">
    <button
      id="extensions-tab-search"
      type="button"
      role="tab"
      aria-selected={activeTab === 'search'}
      aria-controls="extensions-search-panel"
      tabindex={activeTab === 'search' ? 0 : -1}
      class:active={activeTab === 'search'}
      onclick={() => selectTab('search')}
      onkeydown={handleTabKey}>Search</button
    >
    <button
      id="extensions-tab-installed"
      type="button"
      role="tab"
      aria-selected={activeTab === 'installed'}
      aria-controls="extensions-installed-panel"
      tabindex={activeTab === 'installed' ? 0 : -1}
      class:active={activeTab === 'installed'}
      onclick={() => selectTab('installed')}
      onkeydown={handleTabKey}
    >
      Installed <span class="tab-count">{installed.length}</span>
    </button>
  </div>

  {#if activeTab === 'search'}
    <div
      id="extensions-search-panel"
      class="hub-panel"
      role="tabpanel"
      aria-labelledby="extensions-tab-search"
    >
      <form
        class="hub-search"
        role="search"
        onsubmit={(event) => {
          event.preventDefault();
          void doSearch();
        }}
      >
        <label for="extension-search-input" class="visually-hidden">Search extensions</label>
        <input
          id="extension-search-input"
          type="search"
          placeholder="Search extensions"
          autocomplete="off"
          bind:value={searchQuery}
          aria-invalid={Boolean(searchError)}
          aria-describedby="extension-search-help extension-search-error"
          oninput={(event) => {
            if (event.currentTarget.value.trim()) searchError = '';
          }}
        />
        <LoadingButton
          type="submit"
          label="Search"
          pendingLabel="Searching…"
          pending={searchLoading}
          class="hub-button primary"
          onclick={() => void doSearch()}
        />
      </form>
      <InlineFeedback id="extension-search-error" error={searchError} />
      <p id="extension-search-help" class="hub-help">
        OpenVSX access stays off until you approve it for this window.
      </p>

      {#if searchLoading}
        <div class="hub-state" role="status">
          <span class="codicon codicon-loading codicon-modifier-spin" aria-hidden="true"></span>
          Searching OpenVSX…
        </div>
      {:else if networkRequired}
        <div class="hub-state consent-state">
          <strong>Allow OpenVSX network access?</strong>
          <p>
            WIZP will send this search query to open-vsx.org. This approval lasts only for the
            current window.
          </p>
          <button type="button" class="hub-button primary" onclick={allowNetworkSearch}>
            Allow OpenVSX Search
          </button>
        </div>
      {:else if searchResults.length === 0}
        <div class="hub-state">
          {#if searchQuery.trim()}
            No extensions found. Try a broader name or feature.
          {:else}
            Search OpenVSX, or install a local VSIX from the Installed tab.
          {/if}
        </div>
      {:else}
        <div class="hub-list" aria-label="Extension search results">
          {#each searchResults as extension (extension.id)}
            <article class="hub-row">
              <div class="hub-icon" aria-hidden="true">
                {(extension.displayName[0] || 'E').toUpperCase()}
              </div>
              <div class="hub-row-copy">
                <strong title={extension.displayName}>{extension.displayName}</strong>
                <p title={extension.description}>{extension.description}</p>
                <span>
                  {extension.namespace} · {extension.version || 'latest'} · {(
                    extension.downloads || 0
                  ).toLocaleString()}
                  downloads
                </span>
              </div>
              <button
                type="button"
                class="hub-button primary compact"
                disabled={!!operation}
                aria-label={`Install ${extension.displayName}`}
                onclick={() => void installExtension(extension)}
              >
                {operation === `install:${extension.id}` ? 'Installing…' : 'Install'}
              </button>
            </article>
          {/each}
        </div>
      {/if}
    </div>
  {:else}
    <div
      id="extensions-installed-panel"
      class="hub-panel"
      role="tabpanel"
      aria-labelledby="extensions-tab-installed"
    >
      <div class="local-install">
        <div>
          <strong>Install from VSIX</strong>
          <span>Choose a local extension package up to 100 MB.</span>
        </div>
        <button
          type="button"
          class="hub-button primary"
          disabled={!!operation}
          onclick={() => void installLocalVSIX()}
        >
          {operation === 'install-local' ? 'Installing…' : 'Choose VSIX…'}
        </button>
      </div>

      {#if installedLoading}
        <div class="hub-state" role="status">Loading installed extensions…</div>
      {:else if installedError}
        <div class="hub-state error-state" role="alert">
          <strong>Installed extensions could not be loaded.</strong>
          <span>{installedError}</span>
          <button type="button" class="hub-button secondary" onclick={() => void loadInstalled()}
            >Retry</button
          >
        </div>
      {:else if installed.length === 0}
        <div class="hub-state">
          <strong>No extensions installed</strong>
          <span>Install a local VSIX, or search OpenVSX after approving network access.</span>
        </div>
      {:else}
        <div class="hub-list" aria-label="Installed extensions">
          {#each installed as extension (extension.id)}
            <article class="hub-row installed-row" class:disabled={extension.enabled === false}>
              <div class="hub-icon" aria-hidden="true">
                {(extension.displayName[0] || 'E').toUpperCase()}
              </div>
              <div class="hub-row-copy">
                <div class="extension-title">
                  <strong title={extension.displayName}>{extension.displayName}</strong>
                  <span class="hub-badge" class:enabled={extension.enabled !== false}>
                    {extension.enabled !== false ? 'Enabled' : 'Disabled'}
                  </span>
                  {#if extension.source}
                    <span class="hub-badge source"
                      >{extension.source === 'local' ? 'Local VSIX' : extension.source}</span
                    >
                  {/if}
                </div>
                <div class="extension-id">
                  <p title={extension.id}>{extension.id}</p>
                  <CopyButton
                    value={extension.id}
                    label="Copy extension ID"
                    copiedLabel="Copied"
                    errorLabel="Copy failed"
                    class="extension-id-copy"
                  />
                </div>
              </div>
              <div class="hub-actions">
                <button
                  type="button"
                  class="hub-button secondary compact"
                  disabled={!!operation || !!hostError}
                  onclick={() => void loadContributions(extension.id)}
                >
                  {contributionsLoading && selectedExtensionId === extension.id
                    ? 'Loading…'
                    : 'Contributions'}
                </button>
                <button
                  type="button"
                  class="hub-button secondary compact"
                  disabled={!!operation || !!hostError}
                  onclick={() => void toggleExtension(extension, extension.enabled === false)}
                >
                  {extension.enabled !== false ? 'Disable' : 'Enable'}
                </button>
                <button
                  type="button"
                  class="hub-button danger compact"
                  disabled={!!operation}
                  onclick={(event) => openUninstallDialog(extension, event.currentTarget)}
                  >Uninstall</button
                >
              </div>
            </article>

            {#if selectedExtensionId === extension.id && contributions}
              <section class="contributions" aria-label={`${extension.displayName} contributions`}>
                <div class="contribution-heading">
                  <strong>Contributions</strong>
                  <span>
                    {(contributions.commands || []).length} commands · {(contributions.views || [])
                      .length}
                    views · {(contributions.configuration || []).length} settings
                  </span>
                </div>

                {#if contributions.commands?.length}
                  <div class="contribution-group">
                    <span>Commands</span>
                    {#each contributions.commands as command (command.command)}
                      <button
                        type="button"
                        class="contribution-action"
                        disabled={command.enabled === false ||
                          !!operation ||
                          extension.enabled === false}
                        onclick={() => void runContributionCommand(command)}
                      >
                        <span class="codicon codicon-play" aria-hidden="true"></span>
                        {command.title || command.command}
                      </button>
                    {/each}
                  </div>
                {/if}

                {#if contributions.viewsContainers?.length}
                  <div class="contribution-group">
                    <span>Views</span>
                    {#each contributions.viewsContainers as container (container.id)}
                      <button
                        type="button"
                        class="contribution-action"
                        disabled={extension.enabled === false}
                        onclick={() => openContributedView(container)}
                      >
                        <span class="codicon codicon-layout" aria-hidden="true"></span>
                        Open {container.title}
                      </button>
                    {/each}
                  </div>
                {/if}

                {#if contributions.configuration?.length}
                  <div class="contribution-group">
                    <span>Settings</span>
                    <button
                      type="button"
                      class="contribution-action"
                      onclick={openExtensionSettings}
                    >
                      <span class="codicon codicon-settings-gear" aria-hidden="true"></span>
                      Open Extension Settings
                    </button>
                    {#each contributions.configuration.slice(0, 3) as setting (setting.key)}
                      <code title={setting.description || setting.key}>{setting.key}</code>
                    {/each}
                  </div>
                {/if}
              </section>
            {/if}
          {/each}
        </div>
      {/if}
    </div>
  {/if}
</div>

<dialog
  bind:this={uninstallDialog}
  class="uninstall-dialog"
  aria-modal="true"
  aria-labelledby="extension-uninstall-title"
  aria-describedby="extension-uninstall-description"
  onclose={() => {
    if (uninstallTarget) closeUninstallDialog();
  }}
  oncancel={(event) => {
    event.preventDefault();
    closeUninstallDialog();
  }}
>
  <form
    method="dialog"
    onsubmit={(event) => {
      event.preventDefault();
      void uninstallExtension();
    }}
  >
    <h2 id="extension-uninstall-title">Uninstall extension?</h2>
    <p id="extension-uninstall-description">
      {uninstallTarget?.displayName} will be removed. Already-loaded contributions may remain until WIZP
      restarts.
    </p>
    <div class="dialog-actions">
      <button type="button" class="hub-button secondary" onclick={closeUninstallDialog}>
        Cancel
      </button>
      <button type="submit" class="hub-button danger" disabled={!!operation}>
        {operation.startsWith('uninstall:') ? 'Uninstalling…' : 'Uninstall'}
      </button>
    </div>
  </form>
</dialog>

<style>
  .hub-container {
    display: flex;
    min-height: 100%;
    flex-direction: column;
    color: var(--sidebar-fg);
  }

  .hub-host {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 10px 12px;
    border-block-end: 1px solid var(--panel-border);
    background: color-mix(in srgb, var(--sidebar-bg) 90%, var(--fg) 10%);
  }

  .hub-host-copy {
    display: flex;
    min-width: 0;
    align-items: flex-start;
    gap: 8px;
  }

  .hub-host-copy div {
    min-width: 0;
  }

  .hub-host-copy strong,
  .hub-host-copy span {
    display: block;
  }

  .hub-host-copy strong {
    font-size: 12px;
  }

  .hub-host-copy span {
    margin-block-start: 2px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.35;
  }

  .host-indicator {
    width: 8px;
    height: 8px;
    flex: 0 0 auto;
    margin-block-start: 4px;
    border: 1px solid var(--breadcrumb-dim);
    border-radius: 50%;
    background: transparent;
  }

  .host-indicator.ready {
    border-color: #89d185;
    background: #89d185;
  }

  .hub-notice,
  .hub-message {
    padding: 8px 12px;
    border-block-end: 1px solid var(--panel-border);
    font-size: 11px;
    line-height: 1.4;
  }

  .hub-notice {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    background: color-mix(in srgb, #cca700 15%, var(--sidebar-bg));
    color: var(--sidebar-fg);
  }

  .hub-notice button {
    min-height: 24px;
    flex: 0 0 auto;
    border: 0;
    background: transparent;
    color: var(--accent);
    font: inherit;
    font-weight: 600;
    cursor: pointer;
  }

  .hub-message {
    background: color-mix(in srgb, var(--accent) 10%, var(--sidebar-bg));
  }

  .hub-message.success {
    background: color-mix(in srgb, #89d185 12%, var(--sidebar-bg));
  }

  .hub-message.error {
    background: color-mix(in srgb, #f48771 13%, var(--sidebar-bg));
    color: #ffd7d2;
  }

  .hub-tabs {
    display: flex;
    gap: 4px;
    padding: 6px 12px;
    border-block-end: 1px solid var(--panel-border);
  }

  .hub-tabs button {
    min-width: 0;
    min-height: 28px;
    flex: 1;
    border: 1px solid transparent;
    border-radius: 4px;
    background: transparent;
    color: var(--tab-inactive-fg);
    font-size: 11px;
    cursor: pointer;
  }

  .hub-tabs button.active {
    border-color: var(--panel-border);
    background: var(--tab-active-bg);
    color: var(--tab-active-fg);
    font-weight: 600;
  }

  .tab-count {
    display: inline-flex;
    min-width: 18px;
    min-height: 18px;
    align-items: center;
    justify-content: center;
    margin-inline-start: 4px;
    border-radius: 9px;
    background: color-mix(in srgb, var(--fg) 12%, transparent);
    font-size: 10px;
  }

  .hub-panel {
    min-height: 0;
    flex: 1;
  }

  .hub-search {
    display: flex;
    gap: 6px;
    padding: 10px 12px 0;
  }

  .hub-search input {
    min-width: 0;
    flex: 1;
    min-height: 30px;
    box-sizing: border-box;
    border: 1px solid var(--input-border, #555);
    border-radius: 4px;
    outline: none;
    background: var(--input-bg, #3c3c3c);
    color: var(--fg);
    padding-inline: 8px;
    font-size: 12px;
  }

  .hub-search input:focus-visible {
    border-color: var(--focus-border, #007fd4);
    box-shadow: 0 0 0 1px var(--focus-border, #007fd4);
  }

  .hub-help {
    margin: 5px 12px 8px;
    color: var(--breadcrumb-dim);
    font-size: 10px;
    line-height: 1.4;
  }

  :global(.hub-button) {
    min-height: 28px;
    border: 1px solid transparent;
    border-radius: 4px;
    padding: 4px 9px;
    color: var(--fg);
    font-size: 11px;
    line-height: 1.2;
    cursor: pointer;
  }

  :global(.hub-button.primary) {
    background: var(--button-bg, #0e639c);
    color: #fff;
  }

  :global(.hub-button.secondary) {
    border-color: var(--panel-border);
    background: color-mix(in srgb, var(--sidebar-bg) 82%, var(--fg) 18%);
  }

  :global(.hub-button.danger) {
    border-color: color-mix(in srgb, #f48771 45%, var(--panel-border));
    background: color-mix(in srgb, #f48771 18%, var(--sidebar-bg));
    color: #ffd7d2;
  }

  :global(.hub-button.compact) {
    min-height: 26px;
    padding: 3px 8px;
  }

  :global(.hub-button:hover:not(:disabled)),
  .contribution-action:hover:not(:disabled) {
    filter: brightness(1.12);
  }

  :global(.hub-button:focus-visible),
  .hub-tabs button:focus-visible,
  .hub-notice button:focus-visible,
  .contribution-action:focus-visible {
    outline: 2px solid var(--focus-border, #007fd4);
    outline-offset: 1px;
  }

  :global(.hub-button:disabled),
  .hub-notice button:disabled,
  .contribution-action:disabled {
    cursor: default;
    opacity: 0.5;
  }

  .hub-state {
    display: flex;
    min-height: 100px;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 7px;
    padding: 20px 16px;
    color: var(--breadcrumb-dim);
    text-align: center;
    font-size: 12px;
    line-height: 1.45;
  }

  .hub-state strong {
    color: var(--sidebar-fg);
  }

  .consent-state p {
    max-width: 34ch;
    margin: 0;
  }

  .error-state span {
    overflow-wrap: anywhere;
  }

  .hub-list {
    padding: 0 8px 12px;
  }

  .hub-row {
    display: flex;
    align-items: start;
    gap: 8px;
    padding: 9px 4px;
    border-block-end: 1px solid color-mix(in srgb, var(--panel-border) 65%, transparent);
  }

  .hub-icon {
    display: flex;
    width: 24px;
    flex: none;
    height: 24px;
    align-items: center;
    justify-content: center;
    border-radius: 5px;
    background: color-mix(in srgb, var(--accent) 55%, #1e1e1e);
    color: #fff;
    font-size: 11px;
    font-weight: 700;
  }

  .hub-row-copy {
    min-width: 0;
    flex: 1;
  }

  .hub-row-copy strong,
  .hub-row-copy p,
  .hub-row-copy > span {
    display: block;
    min-width: 0;
  }

  .hub-row-copy strong {
    overflow: hidden;
    color: var(--sidebar-fg);
    font-size: 12px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .hub-row-copy p {
    display: -webkit-box;
    overflow: hidden;
    margin: 2px 0 4px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.35;
    overflow-wrap: anywhere;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
  }

  .hub-row-copy > span {
    color: var(--breadcrumb-dim);
    font-size: 10px;
    overflow-wrap: anywhere;
  }

  .installed-row {
    flex-wrap: wrap;
  }

  .installed-row.disabled .hub-icon {
    filter: grayscale(1);
  }

  .installed-row.disabled .hub-row-copy strong {
    color: var(--breadcrumb-dim);
  }
  .extension-id {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 6px;
  }

  .extension-id p {
    flex: 1;
    margin: 2px 0 4px;
  }

  .extension-title {
    display: flex;
    min-width: 0;
    flex-wrap: wrap;
    align-items: center;
    gap: 4px;
  }

  .extension-title strong {
    max-width: 100%;
  }

  .hub-badge {
    display: inline-flex;
    min-height: 18px;
    align-items: center;
    border: 1px solid var(--panel-border);
    border-radius: 9px;
    padding-inline: 6px;
    background: color-mix(in srgb, var(--fg) 8%, transparent);
    color: var(--breadcrumb-dim);
    font-size: 9px;
    font-weight: 500;
  }

  .hub-badge.enabled {
    border-color: color-mix(in srgb, #89d185 45%, var(--panel-border));
    color: #b7e8b3;
  }

  .hub-badge.source {
    text-transform: capitalize;
  }

  .hub-actions {
    display: flex;
    flex-basis: calc(100% - 32px);
    flex-wrap: wrap;
    gap: 5px;
    margin-block-start: 2px;
    margin-inline-start: 32px;
  }

  .local-install {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    padding: 10px 12px;
    border-block-end: 1px solid var(--panel-border);
  }

  .local-install div {
    min-width: 0;
  }

  .local-install strong,
  .local-install span {
    display: block;
  }

  .local-install strong {
    font-size: 12px;
  }

  .local-install span {
    margin-block-start: 2px;
    color: var(--breadcrumb-dim);
    font-size: 10px;
    line-height: 1.35;
  }

  .contributions {
    margin: 0 4px 8px 36px;
    padding: 8px;
    border: 1px solid var(--panel-border);
    border-radius: 5px;
    background: color-mix(in srgb, var(--sidebar-bg) 88%, var(--fg) 12%);
  }

  .contribution-heading {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    justify-content: space-between;
    gap: 4px 8px;
    margin-block-end: 8px;
  }

  .contribution-heading strong {
    font-size: 11px;
  }

  .contribution-heading span,
  .contribution-group > span {
    color: var(--breadcrumb-dim);
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .contribution-group {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-block-start: 8px;
  }

  .contribution-action {
    display: flex;
    min-height: 26px;
    align-items: center;
    gap: 6px;
    border: 1px solid var(--panel-border);
    border-radius: 4px;
    background: var(--sidebar-bg);
    color: var(--sidebar-fg);
    padding: 4px 7px;
    font-size: 10px;
    text-align: start;
    cursor: pointer;
  }

  .contribution-group code {
    overflow: hidden;
    color: var(--breadcrumb-dim);
    font-size: 10px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .uninstall-dialog {
    width: min(420px, calc(100vw - 32px));
    box-sizing: border-box;
    border: 1px solid var(--panel-border);
    border-radius: 6px;
    background: var(--panel-bg, #252526);
    color: var(--fg);
    padding: 0;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.55);
  }

  .uninstall-dialog::backdrop {
    background: rgba(0, 0, 0, 0.55);
  }

  .uninstall-dialog form {
    padding: 18px;
  }

  .uninstall-dialog h2 {
    margin: 0 0 8px;
    font-size: 16px;
  }

  .uninstall-dialog p {
    margin: 0;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    line-height: 1.5;
    overflow-wrap: anywhere;
  }

  .dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-block-start: 18px;
  }

  .visually-hidden {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }

  @media (max-width: 340px) {
    .hub-host,
    .local-install,
    .hub-notice {
      align-items: stretch;
      flex-direction: column;
    }

    .hub-search {
      flex-direction: column;
    }

    .hub-row {
      flex-wrap: wrap;
    }

    :global(.hub-row > .hub-button) {
      margin-inline-start: 32px;
    }

    .contributions {
      margin-inline-start: 4px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .codicon-modifier-spin {
      animation: none;
    }
  }
</style>
