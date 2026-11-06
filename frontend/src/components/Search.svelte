<script lang="ts">
  import { tick } from 'svelte';
  import { retryDaemonConnection, sendRpcBounded } from '../../bridge';

  type SearchMatch = {
    uri?: string;
    file: string;
    line: number;
    column?: number;
    text: string;
    before?: string[];
    after?: string[];
  };

  type SearchRequest = {
    query: string;
    regex: boolean;
    caseSensitive: boolean;
    wholeWord: boolean;
    include: string;
    exclude: string;
    contextLines: number;
  };

  type SearchMessage = {
    kind: 'info' | 'error' | 'success';
    text: string;
    action?: 'open-folder' | 'retry';
  };

  let query = $state('');
  let replaceText = $state('');
  let results = $state<SearchMatch[]>([]);
  let searching = $state(false);
  let replacing = $state(false);
  let searchMessage = $state<SearchMessage | null>(null);
  let replaceMessage = $state<SearchMessage | null>(null);
  let regexMode = $state(false);
  let caseSensitive = $state(false);
  let wholeWord = $state(false);
  let preserveCase = $state(false);
  let includeGlob = $state('');
  let excludeGlob = $state('');
  let contextLines = $state(0);
  let showReplace = $state(false);
  let showDetails = $state(false);
  let searchTicket = 0;
  let searchReconnectPending = false;
  let searchTimer: ReturnType<typeof setTimeout> | null = null;
  let searchScheduleToken = 0;
  let searchReconnectTimers: number[] = [];
  let searchRequestTail: Promise<void> = Promise.resolve();
  let completedRequest = $state<SearchRequest | null>(null);
  let resultLimit = $state(100);
  let resultsTruncated = $state(false);
  let searchLimit = $state(100);
  let searchInput = $state<HTMLInputElement>();
  let replaceDialog = $state<HTMLDialogElement>();
  let replaceDialogOpen = $state(false);
  let replaceDialogReturnFocus: HTMLElement | null = null;

  const matchingFileCount = $derived(new Set(results.map((match) => match.file)).size);
  const currentRequestKey = $derived(requestKey(buildRequest()));
  const completedRequestKey = $derived(requestKey(completedRequest));
  const resultsAreCurrent = $derived(
    completedRequest !== null && completedRequestKey === currentRequestKey,
  );
  const canReplace = $derived(resultsAreCurrent && results.length > 0 && !searching && !replacing);

  function buildRequest(): SearchRequest | null {
    const normalizedQuery = query.trim();
    if (!normalizedQuery) return null;
    return {
      query: normalizedQuery,
      regex: regexMode,
      caseSensitive,
      wholeWord,
      include: includeGlob.trim(),
      exclude: excludeGlob.trim(),
      contextLines: Math.max(0, Math.min(5, Number(contextLines) || 0)),
    };
  }

  function requestKey(request: SearchRequest | null) {
    if (!request) return '';
    return JSON.stringify([
      request.query,
      request.regex,
      request.caseSensitive,
      request.wholeWord,
      request.include,
      request.exclude,
      request.contextLines,
    ]);
  }
  function sanitizeSearchError(cause: unknown): string {
    const detail =
      cause instanceof Error
        ? cause.message
        : typeof cause === 'string'
          ? cause
          : String(cause || '');
    return Array.from(detail, (character) => {
      const code = character.charCodeAt(0);
      return code <= 0x1f || code === 0x7f ? ' ' : character;
    })
      .join('')
      .replace(/\b(?:https?|wss?):\/\/[^\s<>"'`]+/gi, '[redacted]')
      .replace(/\bBearer\s+[^\s,;]+/gi, 'Bearer [redacted]')
      .replace(
        /([?&\s])(?:token|access_token|refresh_token|id_token|api_key|apikey|authorization|password|passwd|secret)=([^\s&]+)/gi,
        '$1[redacted]',
      )
      .replace(
        /(\b(?:token|access_token|refresh_token|id_token|api_key|apikey|authorization|password|passwd|secret)\b\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}&]+)/gi,
        '$1[redacted]',
      )
      .trim();
  }

  function clearSearchTimer() {
    if (!searchTimer) return;
    clearTimeout(searchTimer);
    searchTimer = null;
  }

  function clearSearchReconnectTimers() {
    for (const timer of searchReconnectTimers) window.clearTimeout(timer);
    searchReconnectTimers = [];
  }
  async function sendSearchRpc(
    method: string,
    params: Record<string, unknown> | SearchRequest = {},
    isCurrent?: () => boolean,
  ) {
    const run = async () => {
      const ensureCurrent = () => {
        if (isCurrent?.() === false) {
          const cancellation = new Error('Search superseded by a newer request');
          cancellation.name = 'AbortError';
          throw cancellation;
        }
      };
      ensureCurrent();
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          return await sendRpcBounded(method, params, 3000);
        } catch (error) {
          if (error instanceof Error && error.name === 'AbortError') throw error;
          lastError = error;
          ensureCurrent();
          if (attempt === 2) break;
          await retryDaemonConnection();
          await new Promise((resolve) => window.setTimeout(resolve, 150 * (attempt + 1)));
          ensureCurrent();
        }
      }
      throw lastError instanceof Error ? lastError : new Error(String(lastError));
    };
    const request = searchRequestTail.then(run, run);
    searchRequestTail = request.then(
      () => undefined,
      () => undefined,
    );
    return request;
  }

  function invalidateResults() {
    searchTicket++;
    completedRequest = null;
    resultsTruncated = false;
    replaceMessage = null;
  }

  function scheduleSearch() {
    clearSearchTimer();
    clearSearchReconnectTimers();
    searchReconnectPending = false;
    const scheduleToken = ++searchScheduleToken;
    invalidateResults();
    if (!query.trim()) {
      searching = false;
      results = [];
      searchMessage = null;
      return;
    }
    searchTimer = setTimeout(() => {
      searchTimer = null;
      if (scheduleToken !== searchScheduleToken) return;
      void doSearch();
    }, 300);
  }

  function searchNow() {
    searchScheduleToken++;
    clearSearchTimer();
    clearSearchReconnectTimers();
    searchReconnectPending = false;
    void doSearch();
  }
  function showMoreResults() {
    if (searching || !resultsTruncated || resultLimit >= 500) return;
    searchLimit = Math.min(resultLimit * 2, 500);
    searchNow();
  }

  async function doSearch() {
    clearSearchTimer();
    const ticket = ++searchTicket;
    const request = buildRequest();
    if (!request) {
      results = [];
      completedRequest = null;
      resultsTruncated = false;
      searching = false;
      searchMessage = null;
      return;
    }

    searching = true;
    try {
      const response = await sendSearchRpc(
        'search/text',
        { ...request, limit: searchLimit },
        () => ticket === searchTicket,
      );
      if (ticket !== searchTicket) return;
      results = Array.isArray(response?.matches) ? response.matches : [];
      resultLimit = Number(response?.limit) || 100;
      resultsTruncated = response?.truncated === true;
      completedRequest = request;
      clearSearchReconnectTimers();
      searchMessage = null;
      if (results.length === 0) {
        searchMessage = { kind: 'info', text: `No matches found for “${request.query}”.` };
      }
    } catch (cause) {
      if (ticket !== searchTicket) return;
      results = [];
      completedRequest = null;
      resultsTruncated = false;
      const rawMessage = cause instanceof Error ? cause.message : String(cause);
      const message = sanitizeSearchError(cause);
      const noWorkspace = rawMessage.includes('Open a folder before searching');
      searchMessage = {
        kind: noWorkspace ? 'info' : 'error',
        text: noWorkspace
          ? 'Open a folder before searching.'
          : `Search failed: ${message || 'Check the workspace and try again.'}`,
        action: noWorkspace ? 'open-folder' : 'retry',
      };
    } finally {
      if (ticket === searchTicket) {
        searching = false;
        retryAfterReconnect();
      }
    }
  }

  function retryAfterReconnect() {
    if (!searchReconnectPending || searching || replacing || !query.trim()) return;
    searchReconnectPending = false;
    void doSearch();
  }

  function cancelSearch() {
    clearSearchTimer();
    searchTicket++;
    searching = false;
    results = [];
    completedRequest = null;
    resultsTruncated = false;
    searchMessage = { kind: 'info', text: 'Search canceled.' };
    requestAnimationFrame(() => searchInput?.focus());
  }

  function clearSearch() {
    query = '';
    cancelSearch();
    searchMessage = null;
    replaceMessage = null;
  }

  async function replaceMatches(matches: SearchMatch[], maxReplacements?: number) {
    const request = completedRequest;
    if (!request || requestKey(request) !== requestKey(buildRequest()) || matches.length === 0) {
      return;
    }

    clearSearchTimer();
    searchTicket++;
    replacing = true;
    replaceMessage = null;
    let replacementCount = 0;
    try {
      for (const match of matches) {
        const result = await sendRpcBounded(
          'search/replace',
          {
            query: request.query,
            replace: replaceText,
            file: match.file,
            line: maxReplacements ? match.line : undefined,
            maxReplacements,
            regex: request.regex,
            caseSensitive: request.caseSensitive,
            wholeWord: request.wholeWord,
            preserveCase,
          },
          5000,
        );
        replacementCount += Number(result?.replacements || 0);
      }
      replaceMessage = {
        kind: 'success',
        text: `Replaced ${replacementCount} occurrence${replacementCount === 1 ? '' : 's'} across ${matches.length} file${matches.length === 1 ? '' : 's'}.`,
      };
      (window as any).__appendOutput?.(
        'Search',
        `[${new Date().toLocaleTimeString()}] Replaced “${request.query}” with “${replaceText}” ${replacementCount} time${replacementCount === 1 ? '' : 's'}`,
      );
      await doSearch();
    } catch (cause) {
      replaceMessage = {
        kind: 'error',
        text: `Replace stopped after ${replacementCount} change${replacementCount === 1 ? '' : 's'}. ${cause instanceof Error ? cause.message : 'Check file permissions and try again.'} Files already changed were not reverted.`,
      };
    } finally {
      replacing = false;
      retryAfterReconnect();
    }
  }

  function uniqueResultFiles() {
    return [...new Map(results.map((match) => [match.file, match])).values()];
  }

  function openReplaceAllDialog(event: MouseEvent) {
    if (!canReplace) return;
    replaceDialogReturnFocus = event.currentTarget as HTMLElement;
    replaceDialogOpen = true;
    void tick().then(() => replaceDialog?.showModal());
  }

  function closeReplaceAllDialog(restoreFocus = true) {
    replaceDialog?.close();
    replaceDialogOpen = false;
    if (!restoreFocus) return;
    const target = replaceDialogReturnFocus;
    replaceDialogReturnFocus = null;
    requestAnimationFrame(() => target?.isConnected && target.focus());
  }

  async function confirmReplaceAll() {
    const target = replaceDialogReturnFocus;
    replaceDialogReturnFocus = null;
    closeReplaceAllDialog(false);
    await replaceMatches(uniqueResultFiles());
    requestAnimationFrame(() => target?.isConnected && target.focus());
  }

  async function replaceOne(match: SearchMatch) {
    await replaceMatches([match], 1);
  }

  function onSearchKeydown(event: KeyboardEvent) {
    if (event.key !== 'Escape' || !query) return;
    event.preventDefault();
    clearSearch();
  }

  function fileName(path: string) {
    return path.split(/[\\/]/).pop() || path;
  }

  function parentPath(path: string) {
    const parts = path.split(/[\\/]/);
    parts.pop();
    return parts.join('/');
  }

  function resultText(match: SearchMatch) {
    return String(match.text || '').replace(/\r$/, '');
  }

  function focusResult(match: SearchMatch, attempt = 0) {
    try {
      const selectedTab = document.querySelector('.wizp-tab[aria-selected="true"]');
      const selectedUri = decodeURIComponent(
        selectedTab?.getAttribute('data-uri') || '',
      ).replaceAll('\\', '/');
      const expectedPath = match.file.replaceAll('\\', '/');
      const activeEditor = (window as any).__getActiveEditor?.();
      if (selectedUri.endsWith(expectedPath) && activeEditor) {
        const lineNumber = Math.max(1, Number(match.line) || 1);
        const column = Math.max(1, Number(match.column) || 1);
        activeEditor.revealLineInCenter(lineNumber);
        activeEditor.setPosition({ lineNumber, column });
        activeEditor.focus();
        return;
      }
    } catch {
      // File opening remains useful while Monaco is still mounting.
    }
    if (attempt < 20) setTimeout(() => focusResult(match, attempt + 1), 50);
  }

  function openResult(match: SearchMatch) {
    const opened = (window as any).__openFile?.(match.file);
    void Promise.resolve(opened).finally(() => focusResult(match));
  }

  $effect(() => {
    const handleDaemonDisconnected = () => {
      if (query.trim()) {
        searchMessage = {
          kind: 'error',
          text: 'Search backend disconnected. Reconnecting…',
          action: 'retry',
        };
      }
    };
    const handleDaemonReconnected = () => {
      searchReconnectPending = true;
      retryAfterReconnect();
      clearSearchReconnectTimers();
      for (const delay of [250, 750, 1500]) {
        searchReconnectTimers.push(
          window.setTimeout(() => {
            if (!query.trim() || searching || replacing) return;
            searchReconnectPending = true;
            retryAfterReconnect();
          }, delay),
        );
      }
    };
    window.addEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
    window.addEventListener('wizpDaemonReconnected', handleDaemonReconnected);
    return () => {
      window.removeEventListener('wizpDaemonDisconnected', handleDaemonDisconnected);
      window.removeEventListener('wizpDaemonReconnected', handleDaemonReconnected);
      clearSearchReconnectTimers();
      clearSearchTimer();
      searchTicket++;
    };
  });
</script>

<section class="search-view" aria-label="Workspace search">
  <form
    class="search-box"
    role="search"
    onsubmit={(event) => (event.preventDefault(), searchNow())}
  >
    <fieldset disabled={replacing}>
      <div class="search-query-row">
        <input
          bind:this={searchInput}
          type="search"
          placeholder="Search files"
          aria-label="Search files"
          autocomplete="off"
          spellcheck="false"
          bind:value={query}
          oninput={scheduleSearch}
          onkeydown={onSearchKeydown}
        />
        {#if query}
          <button
            type="button"
            class="icon-button"
            onclick={clearSearch}
            title="Clear search"
            aria-label="Clear search"
          >
            <span class="codicon codicon-close" aria-hidden="true"></span>
          </button>
        {/if}
      </div>

      <div class="search-toolbar" aria-label="Search options">
        <div class="search-toggle-group">
          <button
            type="button"
            class="search-toggle"
            class:active={caseSensitive}
            onclick={() => {
              caseSensitive = !caseSensitive;
              searchNow();
            }}
            title="Match case"
            aria-label="Match case"
            aria-pressed={caseSensitive}>Aa</button
          >
          <button
            type="button"
            class="search-toggle"
            class:active={wholeWord}
            onclick={() => {
              wholeWord = !wholeWord;
              searchNow();
            }}
            title="Match whole word"
            aria-label="Match whole word"
            aria-pressed={wholeWord}>ab</button
          >
          <button
            type="button"
            class="search-toggle"
            class:active={regexMode}
            onclick={() => {
              regexMode = !regexMode;
              searchNow();
            }}
            title="Use regular expression"
            aria-label="Use regular expression"
            aria-pressed={regexMode}>.*</button
          >
        </div>
        <div class="search-toolbar-actions">
          <button
            type="button"
            class="icon-button"
            class:active={showDetails}
            onclick={() => (showDetails = !showDetails)}
            title="Toggle search details"
            aria-label="Toggle search details"
            aria-expanded={showDetails}
            aria-controls="search-details"
          >
            <span class="codicon codicon-filter" aria-hidden="true"></span>
          </button>
          <button
            type="button"
            class="icon-button"
            class:active={showReplace}
            onclick={() => (showReplace = !showReplace)}
            title="Toggle replace"
            aria-label="Toggle replace"
            aria-pressed={showReplace}
          >
            <span class="codicon codicon-replace" aria-hidden="true"></span>
          </button>
        </div>
      </div>

      {#if showReplace}
        <div class="search-replace-row">
          <input
            type="text"
            placeholder="Replace with"
            aria-label="Replace with"
            autocomplete="off"
            spellcheck="false"
            bind:value={replaceText}
          />
          <button
            type="button"
            class="search-toggle"
            class:active={preserveCase}
            onclick={() => (preserveCase = !preserveCase)}
            title="Preserve case"
            aria-label="Preserve case"
            aria-pressed={preserveCase}>AB</button
          >
          <button
            type="button"
            class="icon-button replace-all-button"
            onclick={openReplaceAllDialog}
            disabled={!canReplace}
            title="Replace all matches"
            aria-label="Replace all matches"
          >
            <span class="codicon codicon-replace-all" aria-hidden="true"></span>
          </button>
        </div>
      {/if}

      {#if showDetails}
        <div id="search-details" class="search-details">
          <label>
            <span>Files to include</span>
            <input
              type="text"
              placeholder="For example: *.ts"
              aria-label="Files to include"
              autocomplete="off"
              spellcheck="false"
              bind:value={includeGlob}
              oninput={scheduleSearch}
            />
          </label>
          <label>
            <span>Files to exclude</span>
            <input
              type="text"
              placeholder="For example: *.test.ts"
              aria-label="Files to exclude"
              autocomplete="off"
              spellcheck="false"
              bind:value={excludeGlob}
              oninput={scheduleSearch}
            />
          </label>
          <label class="context-lines-label">
            <span>Context lines</span>
            <select aria-label="Context lines" bind:value={contextLines} onchange={searchNow}>
              {#each [0, 1, 2, 3, 4, 5] as count (count)}
                <option value={count}>{count}</option>
              {/each}
            </select>
          </label>
        </div>
      {/if}
    </fieldset>
  </form>

  <div class="search-results" aria-busy={searching || replacing || undefined}>
    {#if replacing}
      <div class="search-state" role="status">
        <span>Replacing matches…</span>
      </div>
    {:else if searching}
      <div class="search-state" role="status">
        <span>Searching workspace…</span>
        <button type="button" class="text-button" onclick={cancelSearch}>Cancel</button>
      </div>
    {:else}
      {#if replaceMessage}
        <div
          class:error-message={replaceMessage.kind === 'error'}
          class:success-message={replaceMessage.kind === 'success'}
          class="search-message"
          role={replaceMessage.kind === 'error' ? 'alert' : 'status'}
        >
          <span>{replaceMessage.text}</span>
        </div>
      {/if}

      {#if searchMessage}
        <div
          class:error-message={searchMessage.kind === 'error'}
          class="search-message"
          role={searchMessage.kind === 'error' ? 'alert' : 'status'}
        >
          <span>{searchMessage.text}</span>
          {#if searchMessage.action === 'open-folder'}
            <button
              type="button"
              class="text-button"
              onclick={() => (window as any).__openFolder?.()}>Open Folder</button
            >
          {:else if searchMessage.action === 'retry'}
            <button type="button" class="text-button" onclick={searchNow}>Retry</button>
          {/if}
        </div>
      {:else if resultsAreCurrent && results.length > 0}
        <div
          class="search-summary"
          role="status"
          aria-live="polite"
          aria-atomic="true"
          aria-relevant="text"
        >
          <span>
            {resultsTruncated ? `First ${results.length}` : results.length}
            {results.length === 1 ? ' matching line' : ' matching lines'} in {matchingFileCount}
            {matchingFileCount === 1 ? ' file' : ' files'}
          </span>
          {#if resultsTruncated}
            <span class="search-limit">Result limit: {resultLimit}</span>
          {/if}
        </div>
        {#if resultsTruncated && resultLimit < 500}
          <button type="button" class="text-button" onclick={showMoreResults}>
            Show up to {Math.min(resultLimit * 2, 500)} results
          </button>
        {/if}
        <ol class="search-result-list" aria-label="Search results">
          {#each results as match ((match.uri || match.file) + ':' + (match.line ?? 0) + ':' + (match.column ?? 0))}
            <li class="search-result">
              <button
                type="button"
                class="search-result-open"
                onclick={() => openResult(match)}
                aria-label={`Open ${fileName(match.file)}, line ${match.line}`}
                title={`${match.file}:${match.line}`}
              >
                <span class="codicon codicon-file" aria-hidden="true"></span>
                <span class="search-result-body">
                  <span class="search-result-top">
                    <span class="search-result-file">{fileName(match.file)}</span>
                    <span class="search-result-path">{parentPath(match.file)}</span>
                    <span class="search-result-line">Ln {match.line}</span>
                  </span>
                  <span class="search-result-text">{resultText(match)}</span>
                  {#if match.before?.length || match.after?.length}
                    <span class="search-result-context">
                      {[...(match.before || []), ...(match.after || [])].join(' · ')}
                    </span>
                  {/if}
                </span>
              </button>
              {#if showReplace}
                <button
                  type="button"
                  class="icon-button replace-one-button"
                  onclick={() => void replaceOne(match)}
                  disabled={!canReplace}
                  aria-label={`Replace match in ${fileName(match.file)} on line ${match.line}`}
                  title="Replace this match"
                >
                  <span class="codicon codicon-replace" aria-hidden="true"></span>
                </button>
              {/if}
            </li>
          {/each}
        </ol>
      {:else if !query}
        <div class="search-empty">
          <span class="codicon codicon-search" aria-hidden="true"></span>
          <span>Search across files in the open workspace.</span>
        </div>
      {/if}
    {/if}
  </div>
</section>

{#if replaceDialogOpen}
  <dialog
    bind:this={replaceDialog}
    class="replace-dialog"
    aria-modal="true"
    aria-labelledby="replace-all-title"
    oncancel={(event) => {
      event.preventDefault();
      closeReplaceAllDialog();
    }}
  >
    <form method="dialog" onsubmit={(event) => (event.preventDefault(), void confirmReplaceAll())}>
      <h2 id="replace-all-title">
        Replace across {matchingFileCount}
        {matchingFileCount === 1 ? 'file' : 'files'}?
      </h2>
      <p>
        Replace every occurrence of <strong>“{completedRequest?.query}”</strong> with
        <strong>{replaceText ? `“${replaceText}”` : 'empty text'}</strong>. This changes files on
        disk and cannot be undone in WIZP.
      </p>
      <div class="replace-dialog-actions">
        <button type="button" class="dialog-button" onclick={() => closeReplaceAllDialog()}
          >Cancel</button
        >
        <button type="submit" class="dialog-button primary">Replace All</button>
      </div>
    </form>
  </dialog>
{/if}

<style>
  .search-view {
    display: flex;
    min-height: 0;
    height: 100%;
    flex-direction: column;
    color: var(--sidebar-fg);
  }

  .search-box {
    flex-shrink: 0;
    padding: 8px 10px 10px;
    border-bottom: 1px solid var(--panel-border);
  }

  fieldset {
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
  }

  .search-query-row,
  .search-replace-row {
    display: flex;
    min-width: 0;
    gap: 4px;
  }

  .search-query-row input,
  .search-replace-row input {
    min-width: 0;
    flex: 1;
  }

  input,
  select {
    width: 100%;
    min-height: 26px;
    box-sizing: border-box;
    padding: 4px 7px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    outline: none;
    background: var(--editor-bg);
    color: var(--sidebar-fg);
    font: inherit;
    font-size: 12px;
  }

  input:focus,
  select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }

  input::placeholder {
    color: var(--breadcrumb-dim);
    opacity: 0.9;
  }

  .search-toolbar {
    display: flex;
    min-width: 0;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    margin-top: 6px;
  }

  .search-toggle-group,
  .search-toolbar-actions {
    display: flex;
    align-items: center;
    gap: 3px;
  }

  .search-toolbar-actions {
    margin-inline-start: auto;
  }

  .search-toggle,
  .icon-button,
  .text-button,
  .dialog-button {
    min-width: 26px;
    min-height: 26px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: var(--breadcrumb-dim);
    cursor: pointer;
    font: inherit;
    font-size: 11px;
  }

  .search-toggle,
  .icon-button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 2px 6px;
  }

  .search-toggle:hover:not(:disabled),
  .icon-button:hover:not(:disabled),
  .text-button:hover,
  .dialog-button:hover {
    background: color-mix(in srgb, var(--fg) 9%, transparent);
    color: var(--fg);
  }

  .search-toggle.active,
  .icon-button.active {
    border-color: var(--accent);
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    color: var(--fg);
  }

  .search-toggle:focus-visible,
  .icon-button:focus-visible,
  .text-button:focus-visible,
  .dialog-button:focus-visible,
  .search-result-open:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }

  button:disabled {
    cursor: not-allowed;
    opacity: 0.45;
  }

  .search-replace-row {
    margin-top: 6px;
  }

  .replace-all-button {
    border-color: color-mix(in srgb, var(--accent) 65%, var(--panel-border));
  }

  .search-details {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 7px;
    margin-top: 8px;
  }

  .search-details label {
    display: grid;
    min-width: 0;
    gap: 3px;
    color: var(--breadcrumb-dim);
    font-size: 10px;
  }

  .context-lines-label {
    max-width: 110px;
  }

  .search-results {
    min-height: 0;
    flex: 1;
    overflow-y: auto;
  }

  .search-state,
  .search-message,
  .search-summary,
  .search-empty {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 10px 12px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
  }

  .search-message {
    border-bottom: 1px solid var(--panel-border);
    overflow-wrap: anywhere;
  }

  .error-message {
    color: var(--error);
  }

  .success-message {
    color: var(--fg);
  }

  .search-summary {
    position: sticky;
    z-index: 1;
    top: 0;
    min-height: 28px;
    box-sizing: border-box;
    padding-block: 5px;
    border-bottom: 1px solid var(--panel-border);
    background: var(--sidebar-bg);
  }

  .search-limit {
    flex-shrink: 0;
    font-size: 10px;
  }

  .text-button {
    flex-shrink: 0;
    padding: 3px 8px;
  }

  .search-empty {
    min-height: 120px;
    flex-direction: column;
    justify-content: center;
    text-align: center;
  }

  .search-empty .codicon {
    color: var(--activity-inactive);
    font-size: 24px;
  }

  .search-result-list {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .search-result {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 4px;
    border-bottom: 1px solid var(--panel-border);
  }

  .search-result-open {
    display: flex;
    min-width: 0;
    flex: 1;
    align-items: center;
    border: 0;
    padding: 7px 8px 7px 10px;
    background: transparent;
    color: var(--sidebar-fg);
    cursor: pointer;
    font: inherit;
    font-size: 12px;
    text-align: start;
  }

  .search-result-open:hover {
    background: color-mix(in srgb, var(--fg) 7%, transparent);
  }

  .search-result-open > .codicon {
    flex-shrink: 0;
    margin-inline-end: 7px;
    color: var(--activity-inactive);
  }

  .search-result-body {
    display: flex;
    min-width: 0;
    flex: 1;
    flex-direction: column;
    overflow: hidden;
  }

  .search-result-top {
    display: flex;
    min-width: 0;
    width: 100%;
    align-items: baseline;
    gap: 6px;
  }

  .search-result-file {
    flex-shrink: 0;
    font-weight: 600;
  }

  .search-result-path,
  .search-result-line,
  .search-result-text,
  .search-result-context {
    overflow: hidden;
    color: var(--breadcrumb-dim);
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .search-result-path {
    min-width: 0;
    flex: 1;
    font-size: 10px;
  }

  .search-result-line {
    flex-shrink: 0;
    font-size: 10px;
  }

  .search-result-text,
  .search-result-context {
    font-family: 'Cascadia Code', 'JetBrains Mono', monospace;
    font-size: 11px;
    white-space: pre;
  }

  .search-result-context {
    opacity: 0.8;
  }

  .replace-one-button {
    flex-shrink: 0;
    margin-inline-end: 6px;
  }

  .replace-dialog {
    width: min(420px, calc(100vw - 32px));
    padding: 0;
    border: 1px solid var(--panel-border);
    border-radius: 5px;
    background: var(--panel-bg);
    color: var(--fg);
    box-shadow: 0 14px 38px rgba(0, 0, 0, 0.46);
  }

  .replace-dialog::backdrop {
    background: rgba(0, 0, 0, 0.55);
  }

  .replace-dialog form {
    padding: 18px;
  }

  .replace-dialog h2 {
    margin: 0 0 8px;
    font-size: 16px;
  }

  .replace-dialog p {
    margin: 0;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    line-height: 1.55;
    overflow-wrap: anywhere;
  }

  .replace-dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 18px;
  }

  .dialog-button {
    min-width: 72px;
    padding: 5px 10px;
  }

  .dialog-button.primary {
    border-color: var(--accent);
    background: var(--accent);
    color: #fff;
  }
</style>
