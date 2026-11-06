<script lang="ts">
  import { showToast, switchSidebarView } from '../stores';
  import { openExternal } from '../../bridge';
  import QuickPick from './QuickPick.svelte';
  import InputBox from './InputBox.svelte';
  import ProgressBar from './ProgressBar.svelte';

  let prompts: any[] = [];
  let pollTimer: any;

  let progressTasks = $state<any[]>([]);

  function backendOrigin() {
    const host = window.location.hostname;
    const port = window.location.port;
    if ((host === '127.0.0.1' || host === 'localhost') && port && port !== '5173') {
      return window.location.origin;
    }
    return 'http://127.0.0.1:9876';
  }

  function uiUrl(path: string) {
    return `${backendOrigin()}${path}`;
  }

  async function pollUI() {
    try {
      const res = await fetch(uiUrl('/api/extension/ui/poll'));
      const data = await res.json();
      if (Array.isArray(data) && data.length > 0) {
        for (const item of data) {
          if (item.type === 'output') {
            const channel = item.channel || item.name || 'Extension';
            if (item.action === 'clear') {
              if ((window as any).__clearOutput) (window as any).__clearOutput(channel);
            } else if (item.action === 'replace') {
              if ((window as any).__clearOutput) (window as any).__clearOutput(channel);
              if ((window as any).__appendOutput)
                (window as any).__appendOutput(channel, item.text || '');
            } else if (item.action === 'append' || item.action === 'appendLine' || !item.action) {
              if ((window as any).__appendOutput)
                (window as any).__appendOutput(channel, item.text ?? item.line ?? '');
            }
          } else if (item.type === 'outputClear') {
            if ((window as any).__clearOutput) (window as any).__clearOutput(item.name);
          } else if (item.type === 'statusBar') {
            if ((window as any).__setStatusBarItem) {
              (window as any).__setStatusBarItem(
                item.id,
                item.action === 'show' ? item.item : null,
              );
            }
          } else if (item.type === 'applyEdit') {
            if ((window as any).__applyWorkspaceEdit) {
              const success = await (window as any).__applyWorkspaceEdit(item.edit);
              await fetch(uiUrl('/api/extension/ui/reply'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: item.id, value: success }),
              });
            } else {
              await fetch(uiUrl('/api/extension/ui/reply'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: item.id, value: false }),
              });
            }
          } else if (item.type === 'showTextDocument') {
            if ((window as any).__openFileInEditor) {
              (window as any).__openFileInEditor(item.uri);
              await fetch(uiUrl('/api/extension/ui/reply'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ id: item.id, value: {} }),
              });
            }
            progressTasks = [
              ...progressTasks,
              { id: item.id, title: item.title, message: '', progress: null },
            ];
          } else if (item.type === 'progressReport') {
            progressTasks = progressTasks.map((task) => {
              if (task.id !== item.id) return task;
              const increment =
                typeof item.increment === 'number' && Number.isFinite(item.increment)
                  ? Math.max(0, item.increment)
                  : null;
              return {
                ...task,
                message: item.message || task.message,
                progress:
                  increment === null
                    ? task.progress
                    : Math.min(100, (task.progress ?? 0) + increment),
              };
            });
          } else if (item.type === 'progressEnd') {
            progressTasks = progressTasks.filter((t) => t.id !== item.id);
          } else if (item.type === 'lspResult') {
            if ((window as any).__lspResolvers && (window as any).__lspResolvers[item.id]) {
              (window as any).__lspResolvers[item.id](item.result);
              delete (window as any).__lspResolvers[item.id];
            }
          } else if (item.type === 'setDiagnostics') {
            if ((window as any).__setDiagnostics) {
              (window as any).__setDiagnostics(item.uri, item.diagnostics);
            }
          } else if (item.type === 'clearDiagnostics') {
            if ((window as any).__setDiagnostics) {
              (window as any).__setDiagnostics(null, []);
            }
          } else if (item.type === 'clipboardRead') {
            navigator.clipboard
              .readText()
              .then((text) => {
                fetch(uiUrl('/api/extension/ui/reply'), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: item.id, value: text }),
                });
              })
              .catch(() => {
                fetch(uiUrl('/api/extension/ui/reply'), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: item.id, value: '' }),
                });
              });
          } else if (item.type === 'clipboardWrite') {
            navigator.clipboard
              .writeText(item.text)
              .then(() => {
                fetch(uiUrl('/api/extension/ui/reply'), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: item.id, value: null }),
                });
              })
              .catch(() => {
                fetch(uiUrl('/api/extension/ui/reply'), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: item.id, value: null }),
                });
              });
          } else if (item.type === 'openExternal') {
            void openExternal(item.uri)
              .catch(() => false)
              .then((opened) =>
                fetch(uiUrl('/api/extension/ui/reply'), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ id: item.id, value: opened }),
                }),
              );
          } else if (item.type === 'scmUpdate') {
            window.dispatchEvent(new CustomEvent('wizpScmUpdate', { detail: item.resourceStates }));
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else if (item.type === 'taskExecute') {
            window.dispatchEvent(new CustomEvent('wizpTaskExecute', { detail: item.task }));
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else if (
            item.type === 'testRunStarted' ||
            item.type === 'testRunPassed' ||
            item.type === 'testRunFailed' ||
            item.type === 'testRunEnded'
          ) {
            if (item.type === 'testRunFailed') {
              showToast(`Test Failed: ${item.message}`, 'error');
            } else if (item.type === 'testRunEnded') {
              showToast('Test Run Completed', 'info');
            }
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else if (item.type === 'debugStarted') {
            window.dispatchEvent(new CustomEvent('wizpDebugStarted', { detail: item.config }));
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else if (item.type === 'webviewRegistered') {
            window.dispatchEvent(new CustomEvent('wizpWebviewRegistered', { detail: item.id }));
          } else if (item.type === 'webviewPanelCreated') {
            window.dispatchEvent(new CustomEvent('wizpWebviewPanelCreated', { detail: item }));
          } else if (item.type === 'webviewPanelUpdated') {
            window.dispatchEvent(new CustomEvent('wizpWebviewPanelUpdated', { detail: item }));
          } else if (item.type === 'webviewPanelReveal') {
            window.dispatchEvent(new CustomEvent('wizpWebviewPanelReveal', { detail: item }));
          } else if (item.type === 'webviewPanelDisposed') {
            window.dispatchEvent(new CustomEvent('wizpWebviewPanelDisposed', { detail: item }));
          } else if (item.type === 'webviewViewFocus') {
            switchSidebarView(`contributed:${item.id}`);
          } else if (item.type === 'webviewPostMessage') {
            const pendingMessages = ((window as any).__wizpPendingWebviewMessages ||= {});
            const queue = Array.isArray(pendingMessages[item.id])
              ? pendingMessages[item.id]
              : (pendingMessages[item.id] = []);
            queue.push(item.message);
            if (queue.length > 100) queue.splice(0, queue.length - 100);
            window.dispatchEvent(
              new CustomEvent('wizpWebviewPostMessage', {
                detail: { id: item.id, message: item.message },
              }),
            );
          } else if (item.type === 'treeViewCreated') {
            window.dispatchEvent(new CustomEvent('wizpTreeViewCreated', { detail: item }));
          } else if (item.type === 'treeViewFocus') {
            switchSidebarView(`contributed:${item.id}`);
          } else if (item.type === 'commentThreadCreated') {
            window.dispatchEvent(new CustomEvent('wizpCommentThreadCreated', { detail: item }));
          } else if (item.type === 'authenticationRequest') {
            showToast(`Extension is authenticating via ${item.provider}...`, 'info');
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else if (item.type === 'chatParticipantRegistered') {
            window.dispatchEvent(new CustomEvent('wizpChatRegistered', { detail: item }));
            fetch(uiUrl('/api/extension/ui/reply'), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ id: item.id || 0, value: true }),
            });
          } else {
            prompts = [...prompts, item];
          }
        }
      }
    } catch {
      // Prompt polling is best effort; the next scheduled poll retries.
    }
    pollTimer = setTimeout(pollUI, 1000);
  }

  $effect(() => {
    pollTimer = setTimeout(pollUI, 1000);
    return () => clearTimeout(pollTimer);
  });

  const currentPrompt = $derived(prompts.length > 0 ? prompts[0] : null);

  $effect(() => {
    // wait for close...
    (window as any).__uiReply = async (id: number, value: any) => {
      prompts = prompts.filter((p) => p.id !== id);
      await fetch(uiUrl('/api/extension/ui/reply'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, value }),
      });
    };
  });
</script>

{#if currentPrompt}
  {#if currentPrompt.type === 'quickPick'}
    <QuickPick prompt={currentPrompt} />
  {:else if currentPrompt.type === 'inputBox'}
    <InputBox prompt={currentPrompt} />
  {/if}
{/if}

{#if progressTasks.length > 0}
  <section
    class="fixed bottom-10 right-4 z-[1000] flex flex-col gap-2 pointer-events-none"
    aria-label="Background progress"
  >
    {#each progressTasks as task (task.id || task.title)}
      <div
        class="bg-panel border border-border/10 rounded-md shadow-lg p-3 w-72 pointer-events-auto"
        role="group"
        aria-label={task.title || 'Extension task'}
      >
        <ProgressBar
          value={task.progress}
          label={task.title || 'Extension task'}
          pendingLabel={task.message || 'Working'}
        />
        <span class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {task.title || 'Extension task'}{task.message ? `: ${task.message}` : ' in progress'}
        </span>
      </div>
    {/each}
  </section>
{/if}
