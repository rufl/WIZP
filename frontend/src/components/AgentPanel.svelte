<script lang="ts">
  import { onMount } from 'svelte';
  import { agentControl, sendRpc } from '../../bridge';
  import { getActiveEditor } from '../lib/editor/state.svelte';
  import { lsp } from '../lib/lsp/client';
  import { isRecord } from '../lib/validation';
  import CopyButton from './CopyButton.svelte';
  import LoadingButton from './LoadingButton.svelte';
  import InlineFeedback from './InlineFeedback.svelte';
  import TypingIndicator from './TypingIndicator.svelte';

  type ChatMessage = { id: number; role: 'user' | 'assistant'; content: string };
  type AgentStatus = {
    available?: boolean;
    sessionId?: string | null;
    workspace?: string;
    promptActive?: boolean;
    error?: string | null;
  };
  type PatchProposal = { id: string; path: string; diff: string };

  let status = $state<AgentStatus>({});
  let messages = $state<ChatMessage[]>([]);
  let promptText = $state('');
  let busy = $state(false);
  let starting = $state(false);
  let errorText = $state('');
  let promptError = $state('');
  let promptInput: HTMLTextAreaElement | undefined = $state();
  let nextMessageId = 1;
  let pollTimer: ReturnType<typeof setInterval> | null = null;
  let scrollElement: HTMLDivElement | null = null;
  let proposal = $state<PatchProposal | null>(null);

  function updateStatus(value: unknown) {
    if (!isRecord(value)) return;
    status = {
      available: value.available === true,
      sessionId: typeof value.sessionId === 'string' ? value.sessionId : null,
      workspace: typeof value.workspace === 'string' ? value.workspace : undefined,
      promptActive: value.promptActive === true,
      error: typeof value.error === 'string' ? value.error : null,
    };
  }

  function handleEvent(value: unknown) {
    if (!isRecord(value) || !isRecord(value.event)) return;
    const event = value.event;
    if (event.type === 'agent_start') {
      busy = true;
      return;
    }
    if (event.type === 'agent_settled') {
      busy = false;
      void stagePatch();
      return;
    }
    if (event.type !== 'message_update' || !isRecord(event.assistantMessageEvent)) return;
    const assistantEvent = event.assistantMessageEvent;
    const delta = assistantEvent.delta;
    if (
      assistantEvent.type !== 'text_delta' ||
      typeof delta !== 'string' ||
      messages.at(-1)?.role !== 'assistant'
    )
      return;
    const last = messages.at(-1);
    if (!last) return;
    messages[messages.length - 1] = { ...last, content: last.content + delta };
    requestAnimationFrame(() => {
      if (scrollElement) scrollElement.scrollTop = scrollElement.scrollHeight;
    });
  }

  async function pollEvents() {
    try {
      const response = await agentControl('events');
      if (!isRecord(response)) return;
      updateStatus(response);
      if (Array.isArray(response.events)) response.events.forEach(handleEvent);
    } catch (cause) {
      errorText = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function startAgent() {
    if (starting) return;
    starting = true;
    errorText = '';
    try {
      updateStatus(await agentControl('start', 'POST', {}));
      if (!pollTimer) pollTimer = setInterval(() => void pollEvents(), 300);
    } catch (cause) {
      errorText = cause instanceof Error ? cause.message : String(cause);
    } finally {
      starting = false;
    }
  }

  async function activeEditorContext() {
    const editor = getActiveEditor();
    const context = [
      `Workspace root: ${status.workspace ?? '(not reported)'}.`,
      'No filesystem tools are enabled. Use only the active editor content, LSP diagnostics, and Git status below.',
      'For requested edits, return one single-file unified diff inside a diff code fence. Use workspace-relative headers --- a/<path> and +++ b/<path>; do not claim a change was applied.',
    ];
    if (editor && editor.type !== 'webview' && typeof editor.content === 'string') {
      const path = editor.uri.replace(/^file:\/\//, '');
      context.push(
        `<active-editor path=${JSON.stringify(path)} language=${JSON.stringify(editor.languageId)}>\n${editor.content.slice(0, 40_000)}\n</active-editor>`,
      );
      const diagnostics = await lsp.getDiagnostics(editor.uri);
      if (diagnostics.length) {
        const report = diagnostics
          .slice(0, 50)
          .map(
            (item) =>
              `${item.range.start.line + 1}:${item.range.start.character + 1} ${item.severity ?? 'info'} ${item.message}`,
          );
        context.push(`<lsp-diagnostics>\n${report.join('\n')}\n</lsp-diagnostics>`);
      }
    }
    try {
      const git = await sendRpc('git/status', {});
      if (isRecord(git) && Array.isArray(git.files)) {
        const files = git.files.slice(0, 100).flatMap((item) => {
          if (!isRecord(item) || typeof item.file !== 'string' || typeof item.status !== 'string')
            return [];
          return [`${item.status.trim()} ${item.file}`];
        });
        if (files.length) context.push(`<git-status>\n${files.join('\n')}\n</git-status>`);
      }
    } catch {}
    return context.join('\n\n');
  }

  async function sendPrompt() {
    const prompt = promptText.trim();
    if (busy || !status.available) return;
    if (!prompt) {
      promptError = 'Enter a message before sending.';
      promptInput?.focus();
      return;
    }
    promptError = '';
    promptText = '';
    errorText = '';
    messages = [
      ...messages,
      { id: nextMessageId++, role: 'user', content: prompt },
      { id: nextMessageId++, role: 'assistant', content: '' },
    ];
    busy = true;
    try {
      const context = await activeEditorContext();
      updateStatus(await agentControl('prompt', 'POST', { prompt, context }));
    } catch (cause) {
      busy = false;
      errorText = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function cancelPrompt() {
    try {
      await agentControl('cancel', 'POST', {});
    } catch (cause) {
      errorText = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function stagePatch() {
    if (proposal) return;
    const assistant = messages.at(-1);
    if (!assistant || assistant.role !== 'assistant') return;
    const match = /```diff\r?\n([\s\S]*?)\r?\n```/m.exec(assistant.content);
    if (!match) return;
    try {
      const result = await agentControl('propose', 'POST', { diff: match[1] });
      if (
        !isRecord(result) ||
        typeof result.id !== 'string' ||
        typeof result.path !== 'string' ||
        typeof result.diff !== 'string'
      )
        throw new Error('WIZP returned an invalid patch proposal.');
      proposal = { id: result.id, path: result.path, diff: result.diff };
    } catch (cause) {
      errorText = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function applyProposal() {
    if (!proposal) return;
    try {
      const result = await agentControl('apply', 'POST', { id: proposal.id });
      if (!isRecord(result) || result.applied !== true)
        throw new Error('WIZP did not apply the reviewed patch.');
      messages = [
        ...messages,
        {
          id: nextMessageId++,
          role: 'assistant',
          content: `Applied ${proposal.path}. Reload the editor file before saving its buffer.`,
        },
      ];
      proposal = null;
    } catch (cause) {
      errorText = cause instanceof Error ? cause.message : String(cause);
    }
  }

  async function discardProposal() {
    if (!proposal) return;
    try {
      await agentControl('discard', 'POST', { id: proposal.id });
    } finally {
      proposal = null;
    }
  }
  onMount(() => {
    void agentControl('status')
      .then(updateStatus)
      .catch(() => {});
    pollTimer = setInterval(() => void pollEvents(), 300);
    return () => {
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = null;
    };
  });
</script>

<div class="flex h-full min-h-0 flex-col text-[12px] text-fg">
  <div class="flex items-center justify-between gap-2 border-b border-border/50 px-3 py-2">
    <div class="min-w-0">
      <div class="font-semibold">ZIPI · ACP</div>
      <div class="truncate text-[10px] text-dim">
        {status.available ? (status.promptActive ? 'Responding' : 'Connected') : 'Not started'}
        {#if status.workspace}
          · {status.workspace}{/if}
      </div>
    </div>
    {#if !status.available}
      <LoadingButton
        label="Start ZIPI"
        pendingLabel="Starting…"
        pending={starting}
        class="rounded border border-border px-2 py-1 hover:bg-white/5"
        onclick={startAgent}
      />
    {:else if busy}
      <button
        type="button"
        class="rounded border border-border px-2 py-1 hover:bg-white/5"
        onclick={cancelPrompt}>Cancel</button
      >
    {:else}
      <button
        type="button"
        class="rounded border border-border px-2 py-1 hover:bg-white/5"
        onclick={() => void agentControl('stop', 'POST', {}).then(updateStatus)}
      >
        Stop
      </button>
    {/if}
  </div>

  <div
    bind:this={scrollElement}
    class="flex-1 space-y-3 overflow-y-auto p-3"
    aria-live="polite"
    aria-relevant="additions text"
  >
    {#if messages.length === 0}
      <p class="text-dim">
        Start ZIPI to open a local ACP session. ZIPI runs without filesystem tools; the current
        editor content is included only when you send a prompt.
      </p>
    {/if}
    {#each messages as message (message.id)}
      <article class="rounded border border-border/50 p-2">
        <div
          class="mb-1 flex items-center justify-between gap-2 text-[10px] font-semibold uppercase text-dim"
        >
          <span>{message.role}</span>
          {#if message.role === 'assistant' && message.content}
            <CopyButton
              value={message.content}
              label="Copy assistant response"
              copiedLabel="Copied"
              errorLabel="Copy failed"
              disabled={busy && messages.at(-1)?.id === message.id}
              class="rounded border border-border/60 px-1.5 py-0.5 font-normal normal-case text-dim hover:bg-white/5 hover:text-fg"
            />
          {/if}
        </div>
        <pre class="whitespace-pre-wrap break-words font-sans">{message.content}</pre>
        {#if message.role === 'assistant' && !message.content && busy}
          <TypingIndicator />
        {/if}
      </article>
    {/each}
    {#if proposal}
      <section class="rounded border border-accent/60 bg-black/10 p-2" aria-label="Patch approval">
        <div class="mb-2 flex items-center justify-between gap-2">
          <strong class="break-all">Review patch · {proposal.path}</strong>
          <button
            type="button"
            class="rounded border border-border px-2 py-1"
            onclick={() => void discardProposal()}>Discard</button
          >
        </div>
        <pre
          class="max-h-64 overflow-auto whitespace-pre-wrap break-words font-mono text-[11px]">{proposal.diff}</pre>
        <p class="mt-2 text-[10px] text-dim">
          Only this existing workspace file can be changed. WIZP rechecks the workspace and file
          contents before applying.
        </p>
        <button
          type="button"
          class="mt-2 rounded bg-accent px-3 py-1.5 text-white"
          onclick={() => void applyProposal()}
        >
          Apply reviewed patch
        </button>
      </section>
    {/if}
  </div>

  {#if errorText}
    <div role="alert" class="border-t border-border/50 px-3 py-2 text-error">{errorText}</div>
  {/if}
  <form
    class="border-t border-border/50 p-2"
    onsubmit={(event) => {
      event.preventDefault();
      void sendPrompt();
    }}
  >
    <label class="sr-only" for="zipi-agent-prompt">Message ZIPI</label>
    <textarea
      id="zipi-agent-prompt"
      bind:this={promptInput}
      bind:value={promptText}
      class="min-h-[76px] w-full resize-y rounded border border-border bg-input px-2 py-2 text-fg outline-none focus:border-accent"
      placeholder="Ask about the active file…"
      disabled={!status.available || busy}
      aria-invalid={Boolean(promptError)}
      aria-describedby="zipi-agent-prompt-feedback"
      oninput={() => {
        if (promptText.trim()) promptError = '';
      }}
      onkeydown={(event) => {
        if (event.key === 'Enter' && !event.shiftKey) {
          event.preventDefault();
          void sendPrompt();
        }
      }}
    ></textarea>
    <InlineFeedback id="zipi-agent-prompt-feedback" error={promptError} />
    <div class="mt-1 flex justify-end">
      <LoadingButton
        type="submit"
        label="Send"
        pendingLabel="Sending…"
        pending={busy}
        disabled={!status.available}
        class="rounded bg-accent px-3 py-1.5 text-white disabled:opacity-50"
        onclick={() => void sendPrompt()}
      />
    </div>
  </form>
</div>
