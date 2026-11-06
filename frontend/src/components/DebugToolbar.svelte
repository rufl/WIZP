<script lang="ts">
  import { sendRpc } from '../../bridge';
  import { showToast } from '../stores';

  const { active = false, paused = false } = $props();
  let pending = $state('');

  async function runAction(method: string, label: string, eventName: string) {
    if (pending) return;
    pending = method;
    try {
      const result = await sendRpc(method, {});
      if (result?.ok === false) throw new Error(result?.error || `${label} failed.`);
      window.dispatchEvent(
        new CustomEvent(eventName, {
          detail: { source: 'toolbar', running: eventName !== 'wizpDebugTerminated' },
        }),
      );
    } catch (cause) {
      showToast(cause instanceof Error ? cause.message : `${label} failed.`, 'error');
    } finally {
      pending = '';
    }
  }
</script>

{#if active}
  <div
    class="absolute top-[35px] left-1/2 -translate-x-1/2 z-50 bg-[#252526] border border-border/70 rounded-md shadow-xl flex items-center p-1 gap-1"
    style="box-shadow: 0 4px 16px rgba(0,0,0,0.5);"
    role="toolbar"
    aria-label={paused ? 'Debug controls, execution paused' : 'Debug controls, execution running'}
  >
    <span class="sr-only" role="status">{paused ? 'Execution paused' : 'Execution running'}</span>

    <button
      type="button"
      class="debug-toolbar-button text-[#89D185]"
      onclick={() =>
        void runAction(
          paused ? 'dap/continue' : 'dap/pause',
          paused ? 'Continue' : 'Pause',
          paused ? 'wizpDebugContinued' : 'wizpDebugStopped',
        )}
      title={paused ? 'Continue (F5)' : 'Pause (F6)'}
      aria-label={paused ? 'Continue debugging' : 'Pause debugging'}
      disabled={!!pending}
    >
      <span class="codicon codicon-{paused ? 'play' : 'debug-pause'} text-[16px]" aria-hidden="true"
      ></span>
    </button>

    <button
      type="button"
      class="debug-toolbar-button text-[#569CD6]"
      onclick={() => void runAction('dap/stepOver', 'Step over', 'wizpDebugStopped')}
      title="Step Over (F10)"
      aria-label="Step over"
      disabled={!paused || !!pending}
    >
      <span class="codicon codicon-debug-step-over text-[16px]" aria-hidden="true"></span>
    </button>

    <button
      type="button"
      class="debug-toolbar-button text-[#569CD6]"
      onclick={() => void runAction('dap/stepInto', 'Step into', 'wizpDebugStopped')}
      title="Step Into (F11)"
      aria-label="Step into"
      disabled={!paused || !!pending}
    >
      <span class="codicon codicon-debug-step-into text-[16px]" aria-hidden="true"></span>
    </button>

    <button
      type="button"
      class="debug-toolbar-button text-[#569CD6]"
      onclick={() => void runAction('dap/stepOut', 'Step out', 'wizpDebugStopped')}
      title="Step Out (Shift+F11)"
      aria-label="Step out"
      disabled={!paused || !!pending}
    >
      <span class="codicon codicon-debug-step-out text-[16px]" aria-hidden="true"></span>
    </button>

    <button
      type="button"
      class="debug-toolbar-button text-[#4EAA25]"
      onclick={() => void runAction('dap/restart', 'Restart', 'wizpDebugStopped')}
      title="Restart (Ctrl+Shift+F5)"
      aria-label="Restart debugging"
      disabled={!!pending}
    >
      <span class="codicon codicon-debug-restart text-[16px]" aria-hidden="true"></span>
    </button>

    <button
      type="button"
      class="debug-toolbar-button text-[#F48771]"
      onclick={() => void runAction('dap/stop', 'Stop', 'wizpDebugTerminated')}
      title="Stop (Shift+F5)"
      aria-label="Stop debugging"
      disabled={!!pending}
    >
      <span class="codicon codicon-debug-stop text-[16px]" aria-hidden="true"></span>
    </button>
  </div>
{/if}

<style>
  .debug-toolbar-button {
    display: inline-flex;
    width: 28px;
    height: 28px;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 4px;
    background: transparent;
    cursor: pointer;
  }
  .debug-toolbar-button:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.1);
  }
  .debug-toolbar-button:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  .debug-toolbar-button:disabled {
    cursor: default;
    opacity: 0.42;
  }
</style>
