<script lang="ts">
  import LoadingButton from './LoadingButton.svelte';
  import {
    normalizeWebviewMessagePayload,
    postHostMessageToWebview,
    unwrapWebviewClientMessage,
  } from '$lib/webview-bridge';
  import { showToast } from '../stores';
  import { onMount, onDestroy, tick } from 'svelte';
  const { viewId, viewName } = $props<{ viewId: string; viewName: string }>();

  let items = $state<any[]>([]);

  // SCM state
  let scmFiles = $state<any[]>([]);
  let scmProvider = $state('git');
  let scmResourceGroups = $state<any[]>([]);
  let scmBranch = $state('');
  let scmCommitMsg = $state('');
  let scmLoading = $state(false);
  let scmCommitLoading = $state(false);
  let scmDiffFile = $state('');
  let scmDiffText = $state('');
  let scmConflictFile = $state('');
  let scmConflict = $state<any>(null);
  let scmSelected = $state<Set<string>>(new Set());
  let scmTimelineOpen = $state(false);
  let scmTimelineLoading = $state(false);
  let scmTimeline = $state<any[]>([]);
  let scmRemotesOpen = $state(false);
  let scmRemotesLoading = $state(false);
  let scmRemotes = $state<any[]>([]);
  let scmRemoteName = $state('origin');
  let scmRemoteLastResult = $state<any>(null);
  let scmRemotePromptPlan = $state<any>(null);
  let scmLoaded = $state(false);
  let scmMessage = $state<{ kind: 'info' | 'error' | 'success'; text: string } | null>(null);
  let scmBranches = $state<string[]>([]);
  let scmBranchLoading = $state(false);
  let scmCollapsedGroups = $state<Set<string>>(new Set());
  let scmDiffLoading = $state(false);
  let scmDiffError = $state('');
  let scmDiffRequest = $state<any>(null);
  let scmDiscardResource = $state<any>(null);
  let scmDiscardDialog = $state<HTMLDialogElement>();
  let scmDiscardDialogReturnFocus: HTMLElement | null = null;
  let scmCommitInput = $state<HTMLInputElement>();
  let scmRequestTicket = 0;

  const scmStagedCount = $derived(
    scmFiles.filter((resource: any) => resource.group === 'staged').length,
  );
  const scmStageableFiles = $derived(
    scmFiles.filter((resource: any) => resource.group !== 'staged' && resource.group !== 'merge'),
  );
  const scmSelectedStageableCount = $derived(
    scmStageableFiles.filter((resource: any) => scmSelected.has(resource.file)).length,
  );

  function handleScmUpdate(e: Event) {
    const detail = (e as CustomEvent).detail;
    if (detail && Array.isArray(detail)) {
      _updateScmFromExtension(detail);
    }
  }

  onMount(() => {
    const refreshDebug = (event: Event) => {
      if ((event as CustomEvent).detail?.source === 'sidebar') return;
      if (viewId !== 'debug') return;
      void loadDebugState(false).then(async () => {
        if (event.type === 'wizpDebugTerminated') {
          await tick();
          debugStartButton?.focus();
        }
      });
    };
    const killDebugFixtureAdapter = async () => {
      const result = await sendRpc('debug/killFixtureAdapter', { fixture: true });
      window.dispatchEvent(
        new CustomEvent('wizpDebugTerminated', { detail: { source: 'fixture' } }),
      );
      return result;
    };
    (window as any).__wizpKillDebugFixtureAdapter = killDebugFixtureAdapter;

    window.addEventListener('wizpScmUpdate', handleScmUpdate);
    window.addEventListener('wizpDebugStarted', refreshDebug);
    window.addEventListener('wizpDebugStopped', refreshDebug);
    window.addEventListener('wizpDebugContinued', refreshDebug);
    window.addEventListener('wizpDebugTerminated', refreshDebug);
    window.addEventListener('wizpBreakpointChanged', refreshDebug);
    return () => {
      window.removeEventListener('wizpScmUpdate', handleScmUpdate);
      window.removeEventListener('wizpDebugStarted', refreshDebug);
      window.removeEventListener('wizpDebugStopped', refreshDebug);
      window.removeEventListener('wizpDebugContinued', refreshDebug);
      window.removeEventListener('wizpDebugTerminated', refreshDebug);
      window.removeEventListener('wizpBreakpointChanged', refreshDebug);
      if ((window as any).__wizpKillDebugFixtureAdapter === killDebugFixtureAdapter) {
        delete (window as any).__wizpKillDebugFixtureAdapter;
      }
    };
  });

  async function loadScm() {
    const ticket = ++scmRequestTicket;
    scmLoading = true;
    scmMessage = null;
    try {
      try {
        const result = await sendRpc('git/model');
        if (ticket !== scmRequestTicket) return;
        if (Array.isArray(result?.resources)) {
          scmProvider = result.provider || 'git';
          scmBranch = result.branch || 'detached';
          scmFiles = result.resources.map((resource: any) => normalizeScmResource(resource));
          updateScmResourceGroups();
          scmLoaded = true;
          void loadScmBranches();
          return;
        }
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause);
        if (/not a git repository|not a repository/i.test(message)) {
          // Fall back to an Extension Host source-control provider outside Git workspaces.
        } else {
          if (ticket !== scmRequestTicket) return;
          scmProvider = 'unavailable';
          scmBranch = '';
          scmBranches = [];
          scmFiles = [];
          updateScmResourceGroups();
          scmLoaded = true;
          scmMessage = {
            kind: 'error',
            text: scmErrorMessage(cause, 'Could not load source control.'),
          };
          return;
        }
      }
      try {
        const result = await sendRpc('scm/resources');
        if (ticket !== scmRequestTicket) return;
        if (!Array.isArray(result?.resources)) throw new Error('Missing source-control resources');
        scmProvider = result.provider || 'extension';
        scmBranch = result.branch || 'extension';
        scmBranches = [];
        scmFiles = result.resources.map((resource: any) => normalizeScmResource(resource));
        updateScmResourceGroups();
        scmLoaded = true;
      } catch (cause) {
        if (ticket !== scmRequestTicket) return;
        scmProvider = 'unavailable';
        scmBranch = '';
        scmBranches = [];
        scmFiles = [];
        updateScmResourceGroups();
        scmLoaded = true;
        scmMessage = {
          kind: 'error',
          text:
            cause instanceof Error
              ? cause.message
              : 'Could not load source control. Check that this workspace is a Git repository.',
        };
      }
    } finally {
      if (ticket === scmRequestTicket) scmLoading = false;
    }
  }

  export function _updateScmFromExtension(states: any[]) {
    // Replace native git status with Extension Host status
    scmProvider = states[0]?.sourceControlLabel || states[0]?.sourceControlId || 'extension';
    scmBranch = 'extension';
    scmBranches = [];
    scmMessage = null;
    scmLoaded = true;
    scmFiles = states.map((s: any) =>
      normalizeScmResource({
        file: (s.resourceUri || '').replace('file://', ''),
        status: s.decorations?.letter || 'M',
        group: s.group || 'unstaged',
        provider: s.sourceControlId || 'extension',
      }),
    );
    updateScmResourceGroups();
  }

  function normalizeScmResource(resource: any) {
    const file = resource.file || resource.path || '';
    const indexStatus = (resource.indexStatus || '').trim();
    const worktreeStatus = (resource.worktreeStatus || resource.status || '').trim();
    const status = (resource.status || [indexStatus, worktreeStatus].join('').trim() || '?').trim();
    const group = resource.group || inferScmGroup(indexStatus, worktreeStatus, status);
    return { ...resource, file, status, indexStatus, worktreeStatus, group };
  }

  function inferScmGroup(indexStatus: string, worktreeStatus: string, status: string) {
    if (status.includes('U') || indexStatus === 'U' || worktreeStatus === 'U') return 'merge';
    if (status === '??') return 'untracked';
    if (indexStatus && indexStatus !== '?') return 'staged';
    return 'unstaged';
  }

  function updateScmResourceGroups() {
    const labels: Record<string, string> = {
      staged: 'Staged Changes',
      unstaged: 'Changes',
      untracked: 'Untracked',
      merge: 'Merge Changes',
    };
    const order = ['merge', 'staged', 'unstaged', 'untracked'];
    scmResourceGroups = order
      .map((id) => ({
        id,
        label: labels[id],
        resources: scmFiles.filter((file: any) => file.group === id),
      }))
      .filter((group) => group.resources.length > 0);
    const visibleFiles = new Set(scmFiles.map((resource: any) => resource.file));
    scmSelected = new Set([...scmSelected].filter((file) => visibleFiles.has(file)));
  }

  function scmErrorMessage(cause: unknown, fallback: string) {
    return cause instanceof Error && cause.message ? cause.message : fallback;
  }

  function toggleScmGroup(group: string) {
    if (scmCollapsedGroups.has(group)) {
      scmCollapsedGroups = new Set([...scmCollapsedGroups].filter((id) => id !== group));
    } else {
      scmCollapsedGroups = new Set([...scmCollapsedGroups, group]);
    }
  }

  function toggleSelect(file: string) {
    if (scmSelected.has(file)) {
      scmSelected = new Set([...scmSelected].filter((f) => f !== file));
    } else {
      scmSelected = new Set([...scmSelected, file]);
    }
  }

  async function stageAll() {
    const selected = scmStageableFiles.filter((resource: any) => scmSelected.has(resource.file));
    const targets = scmSelected.size > 0 ? selected : scmStageableFiles;
    if (targets.length === 0) {
      scmMessage = { kind: 'info', text: 'Select unstaged files or clear the selection.' };
      return;
    }

    scmLoading = true;
    scmMessage = null;
    let staged = 0;
    try {
      for (const resource of targets) {
        await sendRpc('git/stage', { file: resource.file });
        staged++;
      }
      scmSelected = new Set();
      await loadScm();
      scmMessage = {
        kind: 'success',
        text: `Staged ${staged} file${staged === 1 ? '' : 's'}.`,
      };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: `Staging stopped after ${staged} file${staged === 1 ? '' : 's'}. ${scmErrorMessage(cause, 'Check the repository and try again.')}`,
      };
    } finally {
      scmLoading = false;
    }
  }

  async function stageFile(file: string) {
    scmLoading = true;
    scmMessage = null;
    try {
      await sendRpc('git/stage', { file });
      await loadScm();
      scmMessage = { kind: 'success', text: `Staged ${file}.` };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, `Could not stage ${file}.`),
      };
    } finally {
      scmLoading = false;
    }
  }

  async function unstageFile(file: string) {
    scmLoading = true;
    scmMessage = null;
    try {
      await sendRpc('git/unstage', { file });
      await loadScm();
      scmMessage = { kind: 'success', text: `Unstaged ${file}.` };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, `Could not unstage ${file}.`),
      };
    } finally {
      scmLoading = false;
    }
  }

  function openDiscardDialog(resource: any, event: MouseEvent) {
    scmDiscardResource = resource;
    scmDiscardDialogReturnFocus = event.currentTarget as HTMLElement;
    void tick().then(() => scmDiscardDialog?.showModal());
  }

  function closeDiscardDialog(restoreFocus = true) {
    scmDiscardDialog?.close();
    scmDiscardResource = null;
    if (!restoreFocus) return;
    const target = scmDiscardDialogReturnFocus;
    scmDiscardDialogReturnFocus = null;
    requestAnimationFrame(() => target?.isConnected && target.focus());
  }

  async function discardFile() {
    const resource = scmDiscardResource;
    if (!resource) return;
    const target = scmDiscardDialogReturnFocus;
    scmDiscardDialogReturnFocus = null;
    closeDiscardDialog(false);
    scmLoading = true;
    scmMessage = null;
    try {
      if (resource.group === 'untracked') {
        await sendRpc('file/delete', { path: resource.file });
      } else {
        await sendRpc('git/discard', { file: resource.file });
      }
      await loadScm();
      scmMessage = {
        kind: 'success',
        text:
          resource.group === 'untracked'
            ? `Deleted untracked file ${resource.file}.`
            : `Discarded changes to ${resource.file}.`,
      };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, `Could not discard ${resource.file}.`),
      };
    } finally {
      scmLoading = false;
      requestAnimationFrame(() => target?.isConnected && target.focus());
    }
  }

  async function commitChanges() {
    if (scmLoading) return;
    const message = scmCommitMsg.trim();
    if (!message) {
      scmMessage = { kind: 'error', text: 'Enter a commit message.' };
      requestAnimationFrame(() => scmCommitInput?.focus());
      return;
    }
    if (scmStagedCount === 0) {
      scmMessage = { kind: 'error', text: 'Stage at least one file before committing.' };
      return;
    }

    scmLoading = true;
    scmCommitLoading = true;
    try {
      await sendRpc('git/commit', { message });
      scmCommitMsg = '';
      await loadScm();
      scmTimeline = [];
      scmMessage = { kind: 'success', text: `Committed “${message}”.` };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, 'Commit failed. Check the staged changes and try again.'),
      };
    } finally {
      scmLoading = false;
      scmCommitLoading = false;
    }
  }

  async function loadScmBranches() {
    if (scmProvider !== 'git' || scmBranchLoading) return;
    scmBranchLoading = true;
    try {
      const result = await sendRpc('git/branch', { op: 'list' });
      scmBranches = Array.isArray(result?.branches) ? result.branches : [];
    } catch {
      scmBranches = scmBranch ? [scmBranch] : [];
    } finally {
      scmBranchLoading = false;
    }
  }

  async function checkoutScmBranch(event: Event) {
    const branch = (event.currentTarget as HTMLSelectElement).value;
    if (!branch || branch === scmBranch) return;
    scmBranchLoading = true;
    scmMessage = null;
    try {
      await sendRpc('git/branch', { op: 'checkout', name: branch });
      await loadScm();
      scmMessage = { kind: 'success', text: `Switched to branch ${branch}.` };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, `Could not switch to branch ${branch}.`),
      };
    } finally {
      scmBranchLoading = false;
    }
  }

  async function showDiff(resource: any) {
    scmDiffFile = resource.file;
    scmDiffText = '';
    scmDiffError = '';
    scmDiffLoading = true;
    scmDiffRequest = { type: 'file', resource };
    try {
      const result = await sendRpc('git/diff', {
        file: resource.file,
        staged: resource.group === 'staged',
      });
      scmDiffText = result?.diff || 'No diff available for this file.';
    } catch (cause) {
      scmDiffError = scmErrorMessage(cause, `Could not load the diff for ${resource.file}.`);
    } finally {
      scmDiffLoading = false;
    }
  }

  async function showCommit(commit: any) {
    scmDiffFile = commit.subject || commit.hash;
    scmDiffText = '';
    scmDiffError = '';
    scmDiffLoading = true;
    scmDiffRequest = { type: 'commit', commit };
    try {
      const result = await sendRpc('git/show', { commit: commit.hash });
      scmDiffText = result?.diff || 'No commit diff available.';
    } catch (cause) {
      scmDiffError = scmErrorMessage(cause, `Could not load commit ${commit.hash}.`);
    } finally {
      scmDiffLoading = false;
    }
  }

  function retryScmDiff() {
    if (scmDiffRequest?.type === 'commit') void showCommit(scmDiffRequest.commit);
    else if (scmDiffRequest?.resource) void showDiff(scmDiffRequest.resource);
  }

  function closeScmDiff() {
    scmDiffFile = '';
    scmDiffText = '';
    scmDiffError = '';
    scmDiffRequest = null;
  }

  async function showConflict(file: string) {
    scmConflictFile = file;
    scmConflict = null;
    try {
      scmConflict = await sendRpc('git/conflict', { file });
    } catch (cause) {
      scmConflict = {
        file,
        conflictCount: 0,
        current: '',
        incoming: '',
        error: scmErrorMessage(cause, 'Could not load this conflict.'),
      };
    }
  }

  async function resolveConflict(file: string, resolution: string) {
    scmLoading = true;
    scmMessage = null;
    try {
      await sendRpc('git/resolveConflict', { file, resolution });
      await loadScm();
      scmConflictFile = '';
      scmConflict = null;
      scmMessage = { kind: 'success', text: `Resolved conflict in ${file}.` };
    } catch (cause) {
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, `Could not resolve the conflict in ${file}.`),
      };
    } finally {
      scmLoading = false;
    }
  }

  async function loadScmTimeline() {
    scmTimelineLoading = true;
    try {
      const result = await sendRpc('git/timeline');
      scmTimeline = result?.commits || [];
    } catch (cause) {
      scmTimeline = [];
      scmMessage = {
        kind: 'error',
        text: scmErrorMessage(cause, 'Could not load repository history.'),
      };
    } finally {
      scmTimelineLoading = false;
    }
  }

  async function toggleScmTimeline() {
    scmTimelineOpen = !scmTimelineOpen;
    if (scmTimelineOpen && scmTimeline.length === 0) {
      await loadScmTimeline();
    }
  }

  async function loadScmRemotes() {
    scmRemotesLoading = true;
    try {
      const res = await sendRpc('git/remotes');
      scmRemotes = res?.remotes || [];
      scmRemotePromptPlan = await sendRpc('git/remoteCredentialPromptPlan').catch(() => null);
      if (
        scmRemotes.length > 0 &&
        !scmRemotes.some((remote: any) => remote.name === scmRemoteName)
      ) {
        scmRemoteName = scmRemotes[0].name;
      }
    } catch {
      scmRemotes = [];
    }
    scmRemotesLoading = false;
  }

  async function toggleScmRemotes() {
    scmRemotesOpen = !scmRemotesOpen;
    if (scmRemotesOpen && scmRemotes.length === 0) {
      await loadScmRemotes();
    }
  }

  async function runRemoteAction(action: string, dryRun = false) {
    scmRemotesLoading = true;
    scmRemoteLastResult = null;
    try {
      const res = await sendRpc(`git/${action}`, { remote: scmRemoteName, dryRun });
      scmRemoteLastResult = res;
      if (dryRun) {
        showToast(`${action} plan ready`);
      } else if (res?.cancelled) {
        showToast(`${action} canceled`);
      } else if (res?.ok === false) {
        showToast(`${action} failed`, 'error');
      } else {
        showToast(`${action} complete`);
      }
    } catch {
      scmRemoteLastResult = { ok: false, action, remote: scmRemoteName };
      showToast(`${action} failed`, 'error');
    }
    scmRemotesLoading = false;
  }

  // ─── Debug state ───
  type DebugMessage = { kind: 'info' | 'error' | 'success'; text: string };
  type DebugBreakpoint = {
    file: string;
    line: number;
    condition?: string;
    hitCondition?: string;
    logMessage?: string;
  };

  let debugRunning = $state(false);
  let debugAdapterLost = $state(false);
  let debugPaused = $state(false);
  let debugThreadId = $state(0);
  let debugBreakpoints = $state<DebugBreakpoint[]>([]);
  let debugShowBreakpoints = $state(true);
  let debugShowCallStack = $state(true);
  let debugShowVariables = $state(true);
  let debugShowWatches = $state(true);
  let debugLaunchConfigs = $state<any[]>([]);
  let debugLaunchCompounds = $state<any[]>([]);
  let debugLaunchSchemaValid = $state(false);
  let debugLaunchErrors = $state<string[]>([]);
  let debugAdvancedBreakpoints = $state<any>(null);
  let debugStackFrames = $state<any[]>([]);
  let debugVariables = $state<any[]>([]);
  let debugWatches = $state<any[]>([]);
  let debugLoading = $state(false);
  let debugLoaded = $state(false);
  let debugAction = $state('');
  let debugMessage = $state<DebugMessage | null>(null);
  let selectedDebugLaunch = $state('');
  let debugStartButton = $state<HTMLButtonElement>();
  let debugRequestTicket = 0;
  let lastDebugLaunch = $state<{ adapter: string; program: string; name: string } | null>(null);

  async function retryDebugStart() {
    if (!lastDebugLaunch || debugAction) return;
    const selected = debugLaunchConfigs.find((config) => config.name === lastDebugLaunch.name);
    if (selected) selectedDebugLaunch = selected.name;
    await startDebug();
  }
  const debugBreakpointCount = $derived(debugBreakpoints.length);

  function debugErrorMessage(cause: unknown, fallback: string) {
    return cause instanceof Error && cause.message ? cause.message : fallback;
  }
  function sendDebugStateRpc(method: string, params: Record<string, unknown> = {}) {
    return sendRpcBounded(method, params, 5000);
  }

  function selectedDebugConfiguration() {
    return (
      debugLaunchConfigs.find((config) => config.name === selectedDebugLaunch) ||
      debugLaunchConfigs[0] ||
      null
    );
  }

  function parseDebugPayload(payload: any) {
    if (typeof payload !== 'string') return payload;
    try {
      return JSON.parse(payload);
    } catch {
      return null;
    }
  }

  function announceDebugState() {
    const name = !debugRunning
      ? 'wizpDebugTerminated'
      : debugPaused
        ? 'wizpDebugStopped'
        : 'wizpDebugContinued';
    window.dispatchEvent(
      new CustomEvent(name, {
        detail: {
          source: 'sidebar',
          running: debugRunning,
          paused: debugPaused,
          threadId: debugThreadId,
        },
      }),
    );
  }

  async function loadDebugRuntimeDetails(ticket: number) {
    if (!debugRunning || !debugPaused) {
      if (!debugAdapterLost) {
        debugStackFrames = [];
        debugVariables = [];
        debugWatches = [];
      }
      return;
    }
    try {
      const stackPayload = parseDebugPayload(
        await sendDebugStateRpc('dap/stackTrace', { threadId: debugThreadId }),
      );
      debugStackFrames = stackPayload?.body?.stackFrames || [];
      const frame = debugStackFrames[0];
      if (frame) {
        const scopesPayload = parseDebugPayload(
          await sendDebugStateRpc('dap/scopes', { frameId: frame.id }),
        );
        const scope = scopesPayload?.body?.scopes?.[0];
        if (scope) {
          const variablesPayload = parseDebugPayload(
            await sendDebugStateRpc('dap/variables', {
              variablesReference: scope.variablesReference,
            }),
          );
          if (ticket !== debugRequestTicket) return;
          debugVariables = variablesPayload?.body?.variables || [];
        } else {
          debugVariables = [];
        }
      } else {
        debugVariables = [];
      }
      const watches = await sendDebugStateRpc('debug/watches');
      if (ticket !== debugRequestTicket) return;
      debugWatches = Array.isArray(watches) ? watches : [];
    } catch (cause) {
      if (ticket !== debugRequestTicket) return;
      debugRunning = false;
      debugPaused = false;
      debugThreadId = 0;
      debugMessage = {
        kind: 'error',
        text: debugErrorMessage(
          cause,
          'The debug adapter stopped before its paused state could be inspected.',
        ),
      };
    }
  }

  async function loadDebugState(clearMessage = true) {
    const ticket = ++debugRequestTicket;
    debugLoading = true;
    try {
      const [state, launch, advanced] = await Promise.all([
        sendDebugStateRpc('debug/state'),
        sendDebugStateRpc('debug/launchConfigurations', { selected: selectedDebugLaunch }),
        sendDebugStateRpc('debug/advancedBreakpoints').catch(() => null),
      ]);
      if (ticket !== debugRequestTicket) return;
      debugRunning = !!state?.running;
      debugPaused = !!state?.paused;
      debugThreadId = state?.threadId || 0;
      debugAdapterLost = state?.adapterState === 'lost';
      debugBreakpoints = Array.isArray(state?.breakpoints) ? state.breakpoints : [];
      debugLaunchConfigs = Array.isArray(launch?.configurations) ? launch.configurations : [];
      debugLaunchCompounds = Array.isArray(launch?.compounds) ? launch.compounds : [];
      debugLaunchSchemaValid = !!launch?.schemaValid;
      debugLaunchErrors = Array.isArray(launch?.errors) ? launch.errors : [];
      if (!debugLaunchConfigs.some((config) => config.name === selectedDebugLaunch)) {
        selectedDebugLaunch = debugLaunchConfigs[0]?.name || '';
      }
      debugAdvancedBreakpoints = advanced;
      debugLoaded = true;
      if (!debugRunning && clearMessage) {
        if (!debugLaunchSchemaValid) {
          debugMessage = {
            kind: 'error',
            text: debugLaunchErrors[0] || 'launch.json is missing or invalid.',
          };
        } else if (debugLaunchConfigs.length === 0) {
          debugMessage = {
            kind: 'info',
            text: 'No launch configuration found. Add one to .vscode/launch.json to start debugging.',
          };
        }
      }
      await loadDebugRuntimeDetails(ticket);
    } catch (cause) {
      if (ticket !== debugRequestTicket) return;
      debugRunning = false;
      debugPaused = false;
      debugThreadId = 0;
      debugAdapterLost = false;
      debugStackFrames = [];
      debugVariables = [];
      debugWatches = [];
      debugLoaded = true;
      debugMessage = {
        kind: 'error',
        text: debugErrorMessage(
          cause,
          'Could not load debugger state; the session is unavailable.',
        ),
      };
    } finally {
      if (ticket === debugRequestTicket) debugLoading = false;
    }
  }

  async function startDebug() {
    const selected = selectedDebugConfiguration();
    if (!selected) {
      debugMessage = {
        kind: 'error',
        text: 'Add a valid launch configuration before starting the debugger.',
      };
      return;
    }
    debugAction = 'start';
    lastDebugLaunch = {
      adapter: selected.type || '',
      program: selected.program || '',
      name: selected.name,
    };
    debugMessage = { kind: 'info', text: `Starting ${selected.name}…` };
    try {
      const result = await sendRpc('debug/start', {
        adapter: selected.type,
        program: selected.program || '',
      });
      if (!result?.ok) throw new Error(result?.error || 'The debug adapter did not start.');
      await loadDebugState(false);
      if (!debugRunning) throw new Error('The debug adapter stopped during startup.');
      debugMessage = { kind: 'success', text: `${selected.name} started.` };
      showToast('Debug session started');
      window.dispatchEvent(
        new CustomEvent('wizpDebugStarted', {
          detail: { source: 'sidebar', config: selected, paused: debugPaused },
        }),
      );
      announceDebugState();
    } catch (cause) {
      debugRunning = false;
      debugPaused = false;
      debugThreadId = 0;
      debugAdapterLost = false;
      debugStackFrames = [];
      debugVariables = [];
      debugWatches = [];
      debugMessage = {
        kind: 'error',
        text: debugErrorMessage(
          cause,
          'Debug start failed. Check the selected adapter and program.',
        ),
      };
      showToast('Debug start failed', 'error');
      announceDebugState();
    } finally {
      debugAction = '';
    }
  }

  async function runDebugCommand(method: string, label: string) {
    if (debugAction) return;
    debugAction = method;
    try {
      const result = await sendRpc(method, {});
      if (result?.ok === false) throw new Error(result?.error || `${label} failed.`);
      await loadDebugState(false);
      debugMessage = { kind: 'success', text: `${label} complete.` };
      announceDebugState();
    } catch (cause) {
      await loadDebugState(false);
      debugMessage = {
        kind: 'error',
        text: debugErrorMessage(cause, `${label} failed. The session state was not changed.`),
      };
      showToast(`${label} failed`, 'error');
    } finally {
      debugAction = '';
    }
  }

  async function stopDebug() {
    await runDebugCommand('debug/stop', 'Stop');
    if (!debugRunning) {
      showToast('Debug session stopped');
      await tick();
      debugStartButton?.focus();
    }
  }

  async function removeBreakpoint(file: string, line: number) {
    if (debugAction) return;
    debugAction = 'breakpoint';
    try {
      await sendRpc('debug/toggleBreakpoint', { file, line });
      await loadDebugState(false);
      debugMessage = { kind: 'success', text: `Breakpoint removed from line ${line + 1}.` };
    } catch (cause) {
      debugMessage = {
        kind: 'error',
        text: debugErrorMessage(cause, 'Could not remove the breakpoint.'),
      };
    } finally {
      debugAction = '';
    }
  }

  $effect(() => {
    if (viewId === 'debug') loadDebugState();
    else if (viewId === 'scm') loadScm();
    else if (viewId === 'extensions') loadExtensions();
    else if (viewId.startsWith('contributed:')) loadContributedTree();
  });

  async function loadExtensions() {
    try {
      const res = await sendRpc('hub/list', {});
      const installed = res?.installed || [];
      items = installed || [];
    } catch {
      items = [];
    }
  }

  let webviewTimer: any;
  const webviewFrames: Record<string, HTMLIFrameElement | undefined> = {};

  function bindWebviewFrame(node: HTMLIFrameElement, id: string) {
    webviewFrames[id] = node;
    return {
      update(nextId: string) {
        if (nextId === id) return;
        if (webviewFrames[id] === node) delete webviewFrames[id];
        webviewFrames[nextId] = node;
        id = nextId;
      },
      destroy() {
        if (webviewFrames[id] === node) delete webviewFrames[id];
      },
    };
  }

  function backendOrigin() {
    const host = window.location.hostname;
    const port = window.location.port;
    if ((host === '127.0.0.1' || host === 'localhost') && port && port !== '5173') {
      return window.location.origin;
    }
    return 'http://127.0.0.1:9876';
  }

  function webviewHtmlUrl(id: string) {
    return `${backendOrigin()}/api/extension/webview/html?id=${encodeURIComponent(id)}`;
  }

  async function loadContributedTree() {
    try {
      const viewIdShort = viewId.replace('contributed:', '');
      const [treeRes, , welcomeRes] = await Promise.all([
        sendRpc('extension/getTreeData', { viewId }),
        sendRpc('extension/views', {}),
        sendRpc('extension/viewsWelcome', {}),
      ]);
      const treeItems = Array.isArray(treeRes) ? treeRes : treeRes?.tree || [];
      if (treeItems.length > 0) {
        items = treeItems.map((it: any) =>
          typeof it === 'string' || typeof it === 'number'
            ? { label: String(it), collapsibleState: 0 }
            : it.label
              ? it
              : { ...it, label: it.name || String(it) },
        );
      } else {
        const welcomes = welcomeRes?.viewsWelcome || [];
        const welcome = welcomes.find((entry: any) => entry.view === viewIdShort);
        if (welcome?.contents) {
          items = [
            { type: 'welcome', id: viewIdShort, name: viewIdShort, contents: welcome.contents },
          ];
        } else {
          // Fallback to checking if it's a webview
          items = [{ type: 'webview', id: viewIdShort, name: viewIdShort }];
        }
      }
    } catch {
      items = [];
    }
  }

  $effect(() => {
    const handleTree = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (viewId === `contributed:${detail.id}`) {
        loadContributedTree();
      }
    };
    const handleWebview = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (viewId === `contributed:${detail}`) {
        items = [{ type: 'webview', id: detail, name: detail }];
      }
    };
    window.addEventListener('wizpTreeViewCreated', handleTree);
    window.addEventListener('wizpWebviewRegistered', handleWebview);
    return () => {
      window.removeEventListener('wizpTreeViewCreated', handleTree);
      window.removeEventListener('wizpWebviewRegistered', handleWebview);
    };
  });

  onMount(() => {
    const handleWindowMessage = (e: MessageEvent) => {
      const wrapped = unwrapWebviewClientMessage(e);
      if (wrapped) {
        sendRpc('webview/receiveMessage', {
          id: wrapped.id,
          message: normalizeWebviewMessagePayload(wrapped.message),
        }).catch(() => {});
        return;
      }

      for (const [id, frame] of Object.entries(webviewFrames)) {
        if (!frame?.contentWindow || e.source !== frame.contentWindow) continue;
        sendRpc('webview/receiveMessage', {
          id: `webviewView:${id}`,
          message: normalizeWebviewMessagePayload(e.data),
        }).catch(() => {});
        break;
      }
    };

    const handleHostMessage = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (!detail?.id || typeof detail.id !== 'string') return;
      if (!detail.id.startsWith('webviewView:')) return;
      const shortId = detail.id.replace('webviewView:', '');
      postHostMessageToWebview(webviewFrames[shortId], detail.id, detail.message);
    };

    window.addEventListener('message', handleWindowMessage);
    window.addEventListener('wizpWebviewPostMessage', handleHostMessage);
    return () => {
      window.removeEventListener('message', handleWindowMessage);
      window.removeEventListener('wizpWebviewPostMessage', handleHostMessage);
    };
  });

  let expandedItems = $state(new Set<string>());

  function toggleItem(id: string) {
    if (expandedItems.has(id)) {
      expandedItems = new Set([...expandedItems].filter((x) => x !== id));
    } else {
      expandedItems = new Set([...expandedItems, id]);
    }
  }

  onDestroy(() => {
    scmRequestTicket++;
    if (webviewTimer) clearInterval(webviewTimer);
  });
</script>

<div class="sidebar-view">
  {#if viewId === 'scm'}
    <div class="scm-header">
      <span class="codicon codicon-git-branch" aria-hidden="true"></span>
      {#if scmProvider === 'git'}
        <select
          class="scm-branch-select"
          aria-label="Git branch"
          value={scmBranch}
          disabled={scmLoading || scmBranchLoading}
          onchange={checkoutScmBranch}
        >
          {#if !scmBranches.includes(scmBranch)}
            <option value={scmBranch}>{scmBranch || 'detached'}</option>
          {/if}
          {#each scmBranches as branch (branch)}
            <option value={branch}>{branch}</option>
          {/each}
        </select>
      {:else}
        <span>{scmBranch || 'No repository'}</span>
      {/if}
      <span class="scm-provider">{scmProvider}</span>
      <button
        type="button"
        class="scm-refresh"
        title="Refresh Source Control"
        aria-label="Refresh source control"
        disabled={scmLoading}
        onclick={() => void loadScm()}
      >
        <span
          class="codicon codicon-{scmLoading ? 'loading codicon-modifier-spin' : 'refresh'}"
          aria-hidden="true"
        ></span>
      </button>
    </div>
    {#if scmMessage}
      <div
        class:error-message={scmMessage.kind === 'error'}
        class:success-message={scmMessage.kind === 'success'}
        class="scm-message"
        role={scmMessage.kind === 'error' ? 'alert' : 'status'}
      >
        <span>{scmMessage.text}</span>
        {#if scmMessage.kind === 'error'}
          <button type="button" class="scm-link-button" onclick={() => void loadScm()}>Retry</button
          >
        {/if}
      </div>
    {/if}
    {#if !scmLoaded || (scmLoading && scmFiles.length === 0)}
      <div class="scm-state" role="status">Loading source control…</div>
    {:else if scmFiles.length === 0}
      <div class="scm-clean-state">
        <span class="codicon codicon-check" aria-hidden="true"></span>
        <strong
          >{scmProvider === 'unavailable'
            ? 'Source control unavailable'
            : 'Working tree clean'}</strong
        >
        <span
          >{scmProvider === 'unavailable'
            ? 'Open a Git repository or retry.'
            : 'No changes detected.'}</span
        >
      </div>
    {:else}
      <div class="scm-actions">
        <button
          type="button"
          class="scm-btn"
          onclick={() => void stageAll()}
          title={scmSelected.size > 0 ? 'Stage Selected Changes' : 'Stage All Changes'}
          disabled={scmLoading || scmStageableFiles.length === 0}
        >
          <span class="codicon codicon-add" aria-hidden="true"></span>
          {scmSelected.size > 0 ? `Stage Selected (${scmSelectedStageableCount})` : 'Stage All'}
        </button>
      </div>
      <form
        class="scm-commit-row"
        onsubmit={(event) => (event.preventDefault(), void commitChanges())}
      >
        <input
          bind:this={scmCommitInput}
          type="text"
          placeholder="Commit message"
          aria-label="Commit message"
          maxlength="1000"
          autocomplete="off"
          spellcheck="true"
          bind:value={scmCommitMsg}
          disabled={scmLoading}
        />
        <LoadingButton
          type="submit"
          label={`Commit${scmStagedCount > 0 ? ` (${scmStagedCount})` : ''}`}
          pendingLabel="Committing…"
          pending={scmCommitLoading}
          title="Commit staged changes"
          disabled={scmLoading && !scmCommitLoading}
          class="scm-btn"
        />
      </form>
      {#each scmResourceGroups as group (group.id || group.name)}
        <button
          type="button"
          class="scm-group-header"
          aria-expanded={!scmCollapsedGroups.has(group.id)}
          onclick={() => toggleScmGroup(group.id)}
        >
          <span
            class="codicon codicon-chevron-{scmCollapsedGroups.has(group.id) ? 'right' : 'down'}"
            aria-hidden="true"
          ></span>
          <span>{group.label}</span>
          <span class="scm-group-count">{group.resources.length}</span>
        </button>
        {#if !scmCollapsedGroups.has(group.id)}
          {#each group.resources as resource (resource.id || resource.path || resource.file || resource.name)}
            {@const color =
              resource.group === 'merge'
                ? 'var(--error)'
                : resource.status.includes('M')
                  ? 'var(--warn)'
                  : resource.status.includes('D')
                    ? 'var(--error)'
                    : 'var(--info)'}
            {@const selected = scmSelected.has(resource.file)}
            <div class="tree-row scm-file-row" title={resource.file}>
              <input
                type="checkbox"
                aria-label={`Select ${resource.file}`}
                checked={selected}
                onchange={() => toggleSelect(resource.file)}
              />
              <span
                class="codicon codicon-file"
                aria-hidden="true"
                style="margin-right:6px;color:var(--activity-inactive)"
              ></span>
              <span class="scm-file-name" style="color:{color}">{resource.file}</span>
              <span class="scm-status-badge" style="color:{color}">{resource.status.trim()}</span>
              {#if resource.group !== 'staged' && resource.group !== 'merge'}
                <button
                  type="button"
                  class="scm-action-btn"
                  onclick={() => void stageFile(resource.file)}
                  disabled={scmLoading}
                  title="Stage"
                  aria-label={`Stage ${resource.file}`}
                  ><span class="codicon codicon-add" aria-hidden="true"></span></button
                >
              {/if}
              {#if resource.group === 'staged'}
                <button
                  type="button"
                  class="scm-action-btn"
                  onclick={() => void unstageFile(resource.file)}
                  disabled={scmLoading}
                  title="Unstage"
                  aria-label={`Unstage ${resource.file}`}
                  ><span class="codicon codicon-remove" aria-hidden="true"></span></button
                >
              {/if}
              <button
                type="button"
                class="scm-action-btn"
                onclick={() => void showDiff(resource)}
                disabled={scmLoading}
                title="Diff"
                aria-label={`Show diff for ${resource.file}`}
                ><span class="codicon codicon-diff" aria-hidden="true"></span></button
              >
              {#if resource.group === 'merge'}
                <button
                  type="button"
                  class="scm-action-btn"
                  onclick={() => void showConflict(resource.file)}
                  disabled={scmLoading}
                  title="Show Conflict"
                  aria-label={`Show conflict in ${resource.file}`}
                  ><span class="codicon codicon-git-merge" aria-hidden="true"></span></button
                >
              {/if}
              {#if resource.group !== 'staged' && resource.group !== 'merge'}
                <button
                  type="button"
                  class="scm-action-btn scm-discard"
                  onclick={(event) => openDiscardDialog(resource, event)}
                  disabled={scmLoading}
                  title="Discard"
                  aria-label={`Discard ${resource.file}`}
                  ><span class="codicon codicon-discard" aria-hidden="true"></span></button
                >
              {/if}
            </div>
          {/each}
        {/if}
      {/each}
      {#if scmDiffFile}
        <div class="scm-diff-panel" role="region" aria-label={`Diff for ${scmDiffFile}`}>
          <div class="scm-diff-header">
            <span title={scmDiffFile}>{scmDiffFile}</span>
            <button
              type="button"
              class="scm-action-btn"
              title="Close diff"
              aria-label="Close diff"
              onclick={closeScmDiff}
              ><span class="codicon codicon-close" aria-hidden="true"></span></button
            >
          </div>
          {#if scmDiffLoading}
            <div class="scm-state" role="status">Loading diff…</div>
          {:else if scmDiffError}
            <div class="scm-message error-message" role="alert">
              <span>{scmDiffError}</span>
              <button type="button" class="scm-link-button" onclick={retryScmDiff}>Retry</button>
            </div>
          {:else}
            <textarea class="scm-diff-text" aria-label="Diff contents" readonly value={scmDiffText}
            ></textarea>
          {/if}
        </div>
      {/if}
      {#if scmConflictFile}
        <div class="scm-diff-panel" role="region" aria-label={`Conflict in ${scmConflictFile}`}>
          <div class="scm-diff-header">
            <span title={scmConflictFile}>{scmConflictFile}</span>
            <button
              type="button"
              class="scm-action-btn"
              title="Close conflict"
              aria-label="Close conflict"
              onclick={() => {
                scmConflictFile = '';
                scmConflict = null;
              }}><span class="codicon codicon-close" aria-hidden="true"></span></button
            >
          </div>
          <div class="scm-conflict-actions">
            <button
              type="button"
              class="scm-btn"
              onclick={() => void resolveConflict(scmConflictFile, 'current')}
              disabled={scmLoading}>Accept Current</button
            >
            <button
              type="button"
              class="scm-btn"
              onclick={() => void resolveConflict(scmConflictFile, 'incoming')}
              disabled={scmLoading}>Accept Incoming</button
            >
            <button
              type="button"
              class="scm-btn"
              onclick={() => void resolveConflict(scmConflictFile, 'both')}
              disabled={scmLoading}>Accept Both</button
            >
            <button
              type="button"
              class="scm-btn"
              onclick={() => void resolveConflict(scmConflictFile, 'markResolved')}
              disabled={scmLoading}>Mark Resolved</button
            >
          </div>
          {#if scmConflict?.error}
            <div class="scm-message error-message" role="alert">{scmConflict.error}</div>
          {:else if scmConflict}
            <div class="scm-conflict-preview">
              <div class="scm-conflict-column">
                <div class="scm-conflict-title">Current</div>
                <pre>{scmConflict.current || scmConflict.error || ''}</pre>
              </div>
              <div class="scm-conflict-column">
                <div class="scm-conflict-title">Incoming</div>
                <pre>{scmConflict.incoming || ''}</pre>
              </div>
            </div>
          {/if}
        </div>
      {/if}
    {/if}
    {#if scmDiscardResource}
      <dialog
        bind:this={scmDiscardDialog}
        class="scm-discard-dialog"
        aria-modal="true"
        aria-labelledby="scm-discard-title"
        oncancel={(event) => {
          event.preventDefault();
          closeDiscardDialog();
        }}
      >
        <form method="dialog" onsubmit={(event) => (event.preventDefault(), void discardFile())}>
          <h2 id="scm-discard-title">
            {scmDiscardResource.group === 'untracked'
              ? 'Delete untracked file?'
              : 'Discard file changes?'}
          </h2>
          <p>
            {scmDiscardResource.group === 'untracked'
              ? `${scmDiscardResource.file} is not tracked by Git and will be permanently deleted.`
              : `Restore ${scmDiscardResource.file} to its last committed content. Uncommitted changes will be lost.`}
          </p>
          <div class="scm-dialog-actions">
            <button type="button" class="scm-dialog-button" onclick={() => closeDiscardDialog()}
              >Cancel</button
            >
            <button type="submit" class="scm-dialog-button danger">
              {scmDiscardResource.group === 'untracked' ? 'Delete File' : 'Discard Changes'}
            </button>
          </div>
        </form>
      </dialog>
    {/if}
    <div class="scm-history-section">
      <div class="scm-section-header">
        <button
          type="button"
          class="scm-group-header"
          aria-expanded={scmRemotesOpen}
          onclick={() => void toggleScmRemotes()}
        >
          <span
            class="codicon codicon-chevron-{scmRemotesOpen ? 'down' : 'right'}"
            aria-hidden="true"
          ></span>
          <span>Remotes</span>
        </button>
        <button
          type="button"
          class="scm-action-btn"
          title="Refresh remotes"
          aria-label="Refresh remotes"
          onclick={() => void loadScmRemotes()}
          ><span class="codicon codicon-refresh" aria-hidden="true"></span></button
        >
        {#if scmRemotesLoading}
          <span class="codicon codicon-loading codicon-modifier-spin" aria-hidden="true"></span>
        {/if}
      </div>
      {#if scmRemotesOpen}
        <div class="scm-remote-panel">
          <select bind:value={scmRemoteName} aria-label="Git remote">
            {#if scmRemotes.length === 0}
              <option value="origin">origin</option>
            {:else}
              {#each scmRemotes as remote (remote.name || remote.url)}
                <option value={remote.name}>{remote.name}</option>
              {/each}
            {/if}
          </select>
          <div class="scm-remote-actions">
            <button
              class="scm-btn"
              onclick={() => runRemoteAction('fetch')}
              disabled={scmRemotesLoading}>Fetch</button
            >
            <button
              class="scm-btn"
              onclick={() => runRemoteAction('pull')}
              disabled={scmRemotesLoading}>Pull</button
            >
            <button
              class="scm-btn"
              onclick={() => runRemoteAction('push')}
              disabled={scmRemotesLoading}>Push</button
            >
            <button
              class="scm-btn"
              onclick={() => runRemoteAction('sync')}
              disabled={scmRemotesLoading}>Sync</button
            >
            <button
              class="scm-btn scm-secondary-btn"
              onclick={() => runRemoteAction('fetch', true)}
              disabled={scmRemotesLoading}>Preview</button
            >
          </div>
          {#if scmRemoteLastResult}
            <div class="scm-remote-status">
              <span
                >{scmRemoteLastResult.cancelled
                  ? 'Canceled'
                  : scmRemoteLastResult.ok
                    ? 'Ready'
                    : 'Failed'}</span
              >
              <span>{scmRemoteLastResult.credentialPolicy || 'non-interactive'}</span>
            </div>
          {/if}
          {#if scmRemotePromptPlan}
            <div
              class="scm-remote-status scm-remote-prompt-plan"
              data-manual-only={scmRemotePromptPlan.manualOnly}
              data-opt-in={scmRemotePromptPlan.optInRequired}
            >
              <span>{scmRemotePromptPlan.defaultPolicy}</span>
              <span>{scmRemotePromptPlan.envFlag}</span>
            </div>
          {/if}
        </div>
      {/if}
      <div class="scm-section-header">
        <button
          type="button"
          class="scm-group-header"
          aria-expanded={scmTimelineOpen}
          onclick={() => void toggleScmTimeline()}
        >
          <span
            class="codicon codicon-chevron-{scmTimelineOpen ? 'down' : 'right'}"
            aria-hidden="true"
          ></span>
          <span>Timeline</span>
        </button>
        <button
          type="button"
          class="scm-action-btn"
          title="Refresh timeline"
          aria-label="Refresh timeline"
          onclick={() => void loadScmTimeline()}
          ><span class="codicon codicon-refresh" aria-hidden="true"></span></button
        >
        {#if scmTimelineLoading}
          <span class="codicon codicon-loading codicon-modifier-spin" aria-hidden="true"></span>
        {/if}
      </div>
      {#if scmTimelineOpen}
        {#if scmTimeline.length === 0 && !scmTimelineLoading}
          <div class="scm-empty">No timeline entries</div>
        {:else}
          {#each scmTimeline as commit (commit.hash || commit.id || commit.message)}
            <button
              type="button"
              class="tree-row scm-timeline-row"
              title={`Show ${commit.hash}`}
              aria-label={`Show commit ${commit.subject}`}
              onclick={() => void showCommit(commit)}
            >
              <span class="codicon codicon-git-commit" aria-hidden="true"></span>
              <span class="scm-file-name">{commit.subject}</span>
              <span class="scm-timeline-author">{commit.author}</span>
            </button>
          {/each}
        {/if}
      {/if}
    </div>
  {:else if viewId === 'debug'}
    <div class="debug-toolbar" role="toolbar" aria-label="Debug controls">
      <select
        class="debug-launch-select"
        aria-label="Launch configuration"
        title="Select launch configuration"
        bind:value={selectedDebugLaunch}
        disabled={debugLoading || !!debugAction}
      >
        {#if debugLaunchConfigs.length === 0}
          <option value="">No launch configuration</option>
        {:else}
          {#each debugLaunchConfigs as config (config.name)}
            <option value={config.name}>{config.name}</option>
          {/each}
        {/if}
      </select>
      <button
        type="button"
        class="debug-icon-button"
        title="Edit launch.json"
        aria-label="Edit launch.json"
        onclick={() => (window as any).__openFile?.('.vscode/launch.json')}
      >
        <span class="codicon codicon-json" aria-hidden="true"></span>
      </button>
      <button
        type="button"
        class="debug-icon-button"
        title="Refresh debugger state"
        aria-label="Refresh debugger state"
        disabled={debugLoading || !!debugAction}
        onclick={() => void loadDebugState()}
      >
        <span
          class="codicon codicon-{debugLoading ? 'loading codicon-modifier-spin' : 'refresh'}"
          aria-hidden="true"
        ></span>
      </button>
      {#if !debugRunning}
        <button
          type="button"
          class="debug-btn"
          title="Start Debugging (F5)"
          bind:this={debugStartButton}
          disabled={debugLoading || !!debugAction || debugLaunchConfigs.length === 0}
          onclick={() => void startDebug()}
        >
          <span
            class="codicon codicon-{debugAction === 'start'
              ? 'loading codicon-modifier-spin'
              : 'play'}"
            aria-hidden="true"
          ></span>
          {debugAction === 'start' ? 'Starting' : 'Start'}
        </button>
      {/if}
    </div>
    {#if debugAdapterLost}
      <div class="debug-message error debug-adapter-loss" role="alert" data-adapter-state="lost">
        <span>Debug adapter stopped. Showing the last known inspection.</span>
        <button type="button" class="debug-link-button" onclick={() => void retryDebugStart()}
          >Retry debugging</button
        >
        <button type="button" class="debug-link-button" onclick={() => void stopDebug()}
          >Stop debugging</button
        >
      </div>
    {/if}

    {#if debugRunning}
      <div class="debug-session-bar" data-paused={debugPaused}>
        <span class="debug-session-state">
          <span
            class="codicon codicon-{debugPaused ? 'debug-pause' : 'debug-start'}"
            aria-hidden="true"
          ></span>
          {debugPaused ? `Paused on thread ${debugThreadId}` : `Running thread ${debugThreadId}`}
        </span>
        <div class="debug-session-actions" role="toolbar" aria-label="Active debug session">
          {#if debugPaused}
            <button
              type="button"
              class="debug-icon-button debug-continue"
              title="Continue (F5)"
              aria-label="Continue debugging"
              disabled={!!debugAction}
              onclick={() => void runDebugCommand('debug/continue', 'Continue')}
            >
              <span class="codicon codicon-debug-continue" aria-hidden="true"></span>
            </button>
            <button
              type="button"
              class="debug-icon-button"
              title="Step Over (F10)"
              aria-label="Step over"
              disabled={!!debugAction}
              onclick={() => void runDebugCommand('debug/step', 'Step over')}
            >
              <span class="codicon codicon-debug-step-over" aria-hidden="true"></span>
            </button>
            <button
              type="button"
              class="debug-icon-button"
              title="Step Into (F11)"
              aria-label="Step into"
              disabled={!!debugAction}
              onclick={() => void runDebugCommand('debug/stepInto', 'Step into')}
            >
              <span class="codicon codicon-debug-step-into" aria-hidden="true"></span>
            </button>
            <button
              type="button"
              class="debug-icon-button"
              title="Step Out (Shift+F11)"
              aria-label="Step out"
              disabled={!!debugAction}
              onclick={() => void runDebugCommand('debug/stepOut', 'Step out')}
            >
              <span class="codicon codicon-debug-step-out" aria-hidden="true"></span>
            </button>
          {:else}
            <button
              type="button"
              class="debug-icon-button"
              title="Pause (F6)"
              aria-label="Pause debugging"
              disabled={!!debugAction}
              onclick={() => void runDebugCommand('debug/pause', 'Pause')}
            >
              <span class="codicon codicon-debug-pause" aria-hidden="true"></span>
            </button>
          {/if}
          <button
            type="button"
            class="debug-icon-button"
            title="Restart (Ctrl+Shift+F5)"
            aria-label="Restart debugging"
            disabled={!!debugAction}
            onclick={() => void runDebugCommand('dap/restart', 'Restart')}
          >
            <span class="codicon codicon-debug-restart" aria-hidden="true"></span>
          </button>
          <button
            type="button"
            class="debug-icon-button debug-stop"
            title="Stop (Shift+F5)"
            aria-label="Stop debugging"
            disabled={!!debugAction}
            onclick={() => void stopDebug()}
          >
            <span class="codicon codicon-debug-stop" aria-hidden="true"></span>
          </button>
        </div>
      </div>
    {/if}

    {#if debugMessage}
      <div
        class="debug-message {debugMessage.kind}"
        role={debugMessage.kind === 'error' ? 'alert' : 'status'}
        aria-live={debugMessage.kind === 'error' ? 'assertive' : 'polite'}
      >
        <span>{debugMessage.text}</span>
        {#if debugMessage.kind === 'error'}
          {#if lastDebugLaunch}
            <button type="button" class="debug-link-button" onclick={() => void retryDebugStart()}
              >{debugAdapterLost ? 'Retry debugging' : 'Retry start'}</button
            >
          {/if}
          <button type="button" class="debug-link-button" onclick={() => void loadDebugState()}
            >Refresh</button
          >
        {/if}
      </div>
    {/if}
    <div
      class="debug-launch-meta"
      data-schema-valid={debugLaunchSchemaValid}
      data-compounds={debugLaunchCompounds.length}
    >
      <span class="codicon codicon-{debugLaunchSchemaValid ? 'pass' : 'warning'}" aria-hidden="true"
      ></span>
      <span
        >{debugLaunchSchemaValid
          ? 'launch.json schema valid'
          : 'launch.json missing or invalid'}</span
      >
      {#if debugLaunchCompounds.length > 0}
        <span class="debug-launch-pill">{debugLaunchCompounds[0].name}</span>
      {/if}
      {#if selectedDebugConfiguration()?.preLaunchTask}
        <span class="debug-launch-pill">pre: {selectedDebugConfiguration()?.preLaunchTask}</span>
      {/if}
      {#if selectedDebugConfiguration()?.postDebugTask}
        <span class="debug-launch-pill">post: {selectedDebugConfiguration()?.postDebugTask}</span>
      {/if}
    </div>

    {#if debugAdvancedBreakpoints}
      <div
        class="debug-advanced-breakpoints"
        data-source-reference={debugAdvancedBreakpoints.sourceReference || 0}
        aria-label="Advanced breakpoint support"
      >
        {#if debugAdvancedBreakpoints.functionBreakpoint?.name}
          <span class="debug-launch-pill"
            >fn: {debugAdvancedBreakpoints.functionBreakpoint.name}</span
          >
        {/if}
        {#if debugAdvancedBreakpoints.dataBreakpoint?.dataId}
          <span class="debug-launch-pill"
            >data: {debugAdvancedBreakpoints.dataBreakpoint.dataId}</span
          >
        {/if}
        {#if debugAdvancedBreakpoints.sourceReference}
          <span class="debug-launch-pill">srcRef: {debugAdvancedBreakpoints.sourceReference}</span>
        {/if}
      </div>
    {/if}

    <section class="debug-section" aria-labelledby="debug-breakpoints-heading">
      <button
        type="button"
        class="debug-section-title"
        id="debug-breakpoints-heading"
        aria-expanded={debugShowBreakpoints}
        onclick={() => (debugShowBreakpoints = !debugShowBreakpoints)}
      >
        <span
          class="codicon codicon-chevron-{debugShowBreakpoints ? 'down' : 'right'}"
          aria-hidden="true"
        ></span>
        <span>Breakpoints</span>
        <span class="debug-section-count">{debugBreakpointCount}</span>
      </button>
      {#if debugShowBreakpoints}
        {#if debugBreakpoints.length === 0}
          <div class="debug-empty">No breakpoints set. Press F9 in the editor to add one.</div>
        {:else}
          <div class="debug-data-list" aria-label="Breakpoints">
            {#each debugBreakpoints as breakpoint (breakpoint.file + ':' + breakpoint.line)}
              <div class="debug-data-row debug-bp-row">
                <button
                  type="button"
                  class="debug-row-main"
                  title={breakpoint.file}
                  onclick={() => (window as any).__openFile?.(breakpoint.file)}
                >
                  <span
                    class="codicon codicon-circle-filled debug-breakpoint-icon"
                    aria-hidden="true"
                  ></span>
                  <span class="debug-row-name">{breakpoint.file.split('/').pop()}</span>
                  <span class="debug-row-value">Ln {breakpoint.line + 1}</span>
                </button>
                <button
                  type="button"
                  class="debug-icon-button debug-remove-breakpoint"
                  title={`Remove breakpoint at line ${breakpoint.line + 1}`}
                  aria-label={`Remove breakpoint from ${breakpoint.file} line ${breakpoint.line + 1}`}
                  disabled={!!debugAction}
                  onclick={() => void removeBreakpoint(breakpoint.file, breakpoint.line)}
                >
                  <span class="codicon codicon-close" aria-hidden="true"></span>
                </button>
              </div>
            {/each}
          </div>
        {/if}
      {/if}
    </section>

    {#if debugRunning || debugAdapterLost}
      <section class="debug-section" aria-labelledby="debug-call-stack-heading">
        <button
          type="button"
          class="debug-section-title"
          id="debug-call-stack-heading"
          aria-expanded={debugShowCallStack}
          onclick={() => (debugShowCallStack = !debugShowCallStack)}
        >
          <span
            class="codicon codicon-chevron-{debugShowCallStack ? 'down' : 'right'}"
            aria-hidden="true"
          ></span>
          <span>Call Stack</span>
          <span class="debug-section-count">{debugStackFrames.length}</span>
        </button>
        {#if debugShowCallStack}
          {#if !debugPaused && !debugAdapterLost}
            <div class="debug-empty">Call stack is available when execution is paused.</div>
          {:else if debugStackFrames.length === 0}
            <div class="debug-empty">No stack frames reported.</div>
          {:else}
            <div class="debug-data-list" aria-label="Call stack">
              {#each debugStackFrames as frame (frame.id)}
                <button
                  type="button"
                  class="debug-row-main debug-stack-row"
                  title={frame.source?.path || frame.name}
                  onclick={() =>
                    frame.source?.path && (window as any).__openFile?.(frame.source.path)}
                >
                  <span class="codicon codicon-debug-stackframe" aria-hidden="true"></span>
                  <span class="debug-row-name">{frame.name}</span>
                  <span class="debug-row-value">{frame.source?.name || 'unknown'}:{frame.line}</span
                  >
                </button>
              {/each}
            </div>
          {/if}
        {/if}
      </section>

      <section class="debug-section" aria-labelledby="debug-variables-heading">
        <button
          type="button"
          class="debug-section-title"
          id="debug-variables-heading"
          aria-expanded={debugShowVariables}
          onclick={() => (debugShowVariables = !debugShowVariables)}
        >
          <span
            class="codicon codicon-chevron-{debugShowVariables ? 'down' : 'right'}"
            aria-hidden="true"
          ></span>
          <span>Variables</span>
          <span class="debug-section-count">{debugVariables.length}</span>
        </button>
        {#if debugShowVariables}
          {#if !debugPaused && !debugAdapterLost}
            <div class="debug-empty">Variables are available when execution is paused.</div>
          {:else if debugVariables.length === 0}
            <div class="debug-empty">No variables reported for the selected frame.</div>
          {:else}
            <div class="debug-data-list" aria-label="Variables">
              {#each debugVariables as variable (variable.name)}
                <div class="debug-data-row">
                  <span class="debug-row-name">{variable.name}</span>
                  <span class="debug-row-value" title={variable.value}>{variable.value}</span>
                  {#if variable.type}<span class="debug-row-type">{variable.type}</span>{/if}
                </div>
              {/each}
            </div>
          {/if}
        {/if}
      </section>

      <section class="debug-section" aria-labelledby="debug-watch-heading">
        <button
          type="button"
          class="debug-section-title"
          id="debug-watch-heading"
          aria-expanded={debugShowWatches}
          onclick={() => (debugShowWatches = !debugShowWatches)}
        >
          <span
            class="codicon codicon-chevron-{debugShowWatches ? 'down' : 'right'}"
            aria-hidden="true"
          ></span>
          <span>Watch</span>
          <span class="debug-section-count">{debugWatches.length}</span>
        </button>
        {#if debugShowWatches}
          {#if !debugPaused && !debugAdapterLost}
            <div class="debug-empty">Watch expressions update when execution is paused.</div>
          {:else if debugWatches.length === 0}
            <div class="debug-empty">No watch expressions.</div>
          {:else}
            <div class="debug-data-list" aria-label="Watch expressions">
              {#each debugWatches as watch (watch.expression)}
                <div class="debug-data-row">
                  <span class="debug-row-name">{watch.expression}</span>
                  <span class="debug-row-value" title={watch.result}>{watch.result}</span>
                </div>
              {/each}
            </div>
          {/if}
        {/if}
      </section>
    {:else if debugLoaded && !debugLoading}
      <div class="debug-welcome">
        <span class="codicon codicon-debug-alt debug-welcome-icon" aria-hidden="true"></span>
        <strong
          >{debugMessage?.kind === 'error'
            ? 'Debugger needs attention'
            : debugLaunchConfigs.length > 0
              ? 'Ready to debug'
              : 'Configuration required'}</strong
        >
        <p>
          {debugMessage?.kind === 'error'
            ? 'Choose another configuration or retry after fixing the adapter or launch settings.'
            : debugLaunchConfigs.length > 0
              ? 'Choose a launch configuration and start a session. Breakpoints set with F9 will appear here.'
              : 'Add a launch configuration to .vscode/launch.json, then refresh this view.'}
        </p>
        {#if debugLaunchConfigs.length > 0}
          <button type="button" class="debug-btn" onclick={() => void startDebug()}>
            <span class="codicon codicon-play" aria-hidden="true"></span>
            Start {selectedDebugLaunch}
          </button>
        {:else}
          <button
            type="button"
            class="debug-btn debug-secondary-btn"
            onclick={() => (window as any).__openFile?.('.vscode/launch.json')}
          >
            <span class="codicon codicon-json" aria-hidden="true"></span>
            Open launch.json
          </button>
        {/if}
      </div>
    {:else}
      <div class="debug-loading" role="status">
        <span class="codicon codicon-loading codicon-modifier-spin" aria-hidden="true"></span>
        Loading debugger state…
      </div>
    {/if}
  {:else if viewId === 'extensions'}
    {#if items.length === 0}
      <div style="padding:20px;text-align:center;color:var(--breadcrumb-dim);font-size:12px;">
        No extensions installed
      </div>
    {:else}
      {#each items as ext (ext.id || ext.namespace + '/' + ext.name)}
        <div class="ext-row">
          <span class="codicon codicon-extensions"></span>
          <span style="font-weight:600">{ext.displayName || ext.name}</span>
          <span style="font-size:11px;color:var(--breadcrumb-dim)">Installed</span>
        </div>
      {/each}
    {/if}
  {:else if viewId.startsWith('contributed:')}
    <div class="tree-header">{viewName}</div>
    {#each items as item (item.id || item.label || item.name)}
      {#if item.type === 'welcome'}
        <div class="tree-empty whitespace-pre-wrap px-3 py-2 text-[12px] leading-5">
          {item.contents}
        </div>
      {:else if item.type === 'webview'}
        <div class="webview-container">
          <iframe
            use:bindWebviewFrame={item.id}
            title="{item.id} webview"
            src={webviewHtmlUrl(item.id)}
            sandbox="allow-scripts allow-forms allow-same-origin"
            style="width: 100%; height: 100%; border: none; background: #1e1e1e; color: #fff;"
          >
          </iframe>
        </div>
      {:else}
        {@const hasChildren = (item.collapsibleState ?? 0) > 0}
        <div
          class="tree-row"
          role="button"
          tabindex="0"
          onclick={() => hasChildren && toggleItem(item.label)}
          onkeydown={(e) => {
            if ((e.key === 'Enter' || e.key === ' ') && hasChildren) {
              e.preventDefault();
              toggleItem(item.label);
            }
          }}
        >
          {#if hasChildren}
            <span
              class="codicon codicon-chevron-{expandedItems.has(item.label) ? 'down' : 'right'}"
              aria-hidden="true"
            ></span>
          {:else}
            <span class="codicon codicon-file" aria-hidden="true"></span>
          {/if}
          <span>{item.label}</span>
        </div>
        {#if hasChildren && expandedItems.has(item.label)}
          <div style="padding-left:40px;color:var(--breadcrumb-dim);font-size:11px;">
            Loading children...
          </div>
        {/if}
      {/if}
    {/each}
  {:else}
    {#each items as item (item.id || item.label || item.name)}
      <div
        class="tree-row"
        role="button"
        tabindex="0"
        onclick={() => item.action?.()}
        onkeydown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            item.action?.();
          }
        }}
      >
        <span class="codicon codicon-file" aria-hidden="true"></span>
        <span>{item.label}</span>
      </div>
    {/each}
  {/if}
</div>

<style>
  .sidebar-view {
    padding: 4px 0;
  }
  .tree-row {
    display: flex;
    align-items: center;
    padding: 2px 0 2px 20px;
    cursor: pointer;
    white-space: nowrap;
    font-size: 13px;
    color: var(--sidebar-fg);
    height: 22px;
    gap: 6px;
  }
  .tree-row:hover {
    background: rgba(255, 255, 255, 0.04);
  }
  .tree-header {
    padding: 4px 12px 4px 42px !important;
    font-weight: 600;
    font-size: 11px;
    color: var(--activity-inactive);
  }
  .ext-row {
    display: flex;
    align-items: center;
    height: auto;
    padding: 8px 20px;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    cursor: default;
  }
  .scm-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px 8px 42px !important;
    font-size: 12px;
    font-weight: 600;
    color: var(--sidebar-fg);
    border-bottom: 1px solid var(--panel-border);
  }
  .scm-branch-select {
    min-width: 0;
    flex: 1;
    min-height: 26px;
    padding: 3px 6px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    outline: none;
    background: var(--editor-bg);
    color: var(--sidebar-fg);
    font: inherit;
    font-size: 11px;
  }
  .scm-branch-select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }
  .scm-provider {
    margin-left: auto;
    color: var(--breadcrumb-dim);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0;
  }
  .scm-refresh {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: 0;
    border-radius: 3px;
    color: var(--breadcrumb-dim);
    background: transparent;
    cursor: pointer;
  }
  .scm-refresh:hover:not(:disabled),
  .scm-refresh:focus-visible {
    color: var(--sidebar-fg);
    background: rgba(255, 255, 255, 0.08);
  }
  .scm-refresh:disabled {
    cursor: wait;
    opacity: 0.55;
  }
  .scm-state,
  .scm-message,
  .scm-clean-state {
    padding: 10px 12px;
    color: var(--breadcrumb-dim);
    font-size: 12px;
  }
  .scm-message {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    border-bottom: 1px solid var(--panel-border);
    overflow-wrap: anywhere;
  }
  .scm-message.error-message {
    color: var(--error);
  }
  .scm-message.success-message {
    color: var(--fg);
  }
  .scm-link-button {
    min-width: 48px;
    min-height: 26px;
    flex-shrink: 0;
    padding: 3px 8px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    font-size: 11px;
  }
  .scm-clean-state {
    display: flex;
    min-height: 110px;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 5px;
    text-align: center;
  }
  .scm-clean-state .codicon {
    color: var(--info);
    font-size: 22px;
  }
  .scm-clean-state strong {
    color: var(--sidebar-fg);
    font-size: 12px;
  }
  .scm-actions {
    display: flex;
    gap: 4px;
    padding: 6px 12px;
    border-bottom: 1px solid var(--panel-border);
  }
  :global(.scm-btn) {
    display: inline-flex;
    min-height: 26px;
    align-items: center;
    justify-content: center;
    gap: 4px;
    padding: 3px 8px;
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: 2px;
    font-size: 11px;
    cursor: pointer;
  }
  .scm-secondary-btn {
    background: #3c3c3c;
    color: var(--sidebar-fg);
  }
  :global(.scm-btn:hover) {
    filter: brightness(1.1);
  }
  :global(.scm-btn:disabled) {
    opacity: 0.4;
    cursor: default;
  }
  .scm-commit-row {
    display: flex;
    gap: 4px;
    padding: 4px 12px 7px;
    border-bottom: 1px solid var(--panel-border);
  }
  .scm-commit-row input {
    min-width: 0;
    min-height: 26px;
    flex: 1;
    padding: 4px 8px;
    background: var(--editor-bg);
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    color: var(--sidebar-fg);
    font-size: 12px;
    outline: none;
    box-sizing: border-box;
  }
  .scm-commit-row input:focus {
    border-color: var(--accent);
  }
  .scm-file-row {
    min-height: 28px;
    height: auto;
    padding: 2px 8px 2px 12px !important;
    gap: 4px;
  }
  .scm-group-header {
    display: flex;
    min-width: 0;
    width: 100%;
    min-height: 28px;
    flex: 1;
    align-items: center;
    gap: 5px;
    padding: 3px 12px 3px 20px;
    border: 0;
    background: transparent;
    color: var(--activity-inactive);
    cursor: pointer;
    font: inherit;
    font-size: 11px;
    font-weight: 600;
    text-align: start;
    text-transform: uppercase;
  }
  .scm-group-header:hover {
    background: color-mix(in srgb, var(--fg) 6%, transparent);
  }
  .scm-section-header {
    display: flex;
    align-items: center;
    padding-inline-end: 8px;
  }
  .scm-section-header .scm-group-header {
    width: auto;
  }
  .scm-group-count {
    margin-left: auto;
    color: var(--breadcrumb-dim);
    font-size: 10px;
  }
  .scm-history-section {
    border-top: 1px solid var(--panel-border);
    margin-top: 4px;
  }
  .scm-remote-panel {
    padding: 6px 12px 8px 20px;
    border-bottom: 1px solid var(--panel-border);
  }
  .scm-remote-panel select {
    width: 100%;
    padding: 3px 6px;
    background: #3c3c3c;
    color: var(--sidebar-fg);
    border: 1px solid var(--panel-border);
    font-size: 11px;
    outline: none;
  }
  .scm-remote-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 6px;
  }
  .scm-remote-status {
    display: flex;
    justify-content: space-between;
    gap: 8px;
    margin-top: 6px;
    color: var(--breadcrumb-dim);
    font-size: 10px;
  }
  .scm-empty {
    padding: 6px 22px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
  }
  .scm-timeline-row {
    width: 100%;
    padding-left: 20px !important;
    border: 0;
    background: transparent;
    text-align: start;
  }
  .scm-timeline-author {
    color: var(--breadcrumb-dim);
    font-size: 10px;
    flex-shrink: 0;
    max-width: 72px;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .scm-file-row input[type='checkbox'] {
    width: 16px;
    height: 16px;
    margin: 0;
    flex-shrink: 0;
    cursor: pointer;
  }
  .scm-file-name {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .scm-status-badge {
    font-weight: bold;
    font-size: 10px;
    flex-shrink: 0;
  }
  .scm-action-btn {
    display: inline-flex;
    min-width: 24px;
    min-height: 24px;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    padding: 2px;
    border: none;
    border-radius: 3px;
    background: none;
    color: var(--breadcrumb-dim);
    cursor: pointer;
    opacity: 0.72;
  }
  .scm-action-btn:hover {
    color: var(--sidebar-fg);
    opacity: 1;
    background: rgba(255, 255, 255, 0.08);
  }
  .scm-action-btn.scm-discard:hover {
    color: var(--error);
    background: color-mix(in srgb, var(--error) 12%, transparent);
  }
  .scm-action-btn:focus-visible,
  .scm-group-header:focus-visible,
  :global(.scm-btn:focus-visible),
  .scm-link-button:focus-visible,
  .scm-timeline-row:focus-visible,
  .scm-dialog-button:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  .scm-diff-panel {
    border-top: 1px solid var(--panel-border);
    margin-top: 4px;
  }
  .scm-diff-header {
    display: flex;
    min-width: 0;
    justify-content: space-between;
    align-items: center;
    gap: 8px;
    padding: 4px 12px;
    font-size: 11px;
    color: var(--breadcrumb-dim);
    background: rgba(0, 0, 0, 0.2);
  }
  .scm-diff-header > span {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .scm-diff-text {
    display: block;
    width: 100%;
    min-height: 180px;
    max-height: 300px;
    box-sizing: border-box;
    margin: 0;
    padding: 8px 12px;
    resize: vertical;
    border: 0;
    outline: none;
    background: var(--editor-bg);
    color: var(--sidebar-fg);
    font-family: 'Cascadia Code', 'JetBrains Mono', monospace;
    font-size: 11px;
    white-space: pre;
    overflow: auto;
  }
  .scm-diff-text:focus {
    box-shadow: inset 0 0 0 1px var(--accent);
  }
  .scm-conflict-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    padding: 6px 12px;
    border-bottom: 1px solid var(--panel-border);
  }
  .scm-conflict-preview {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    gap: 1px;
    background: var(--panel-border);
    max-height: 260px;
    overflow: auto;
  }
  .scm-conflict-column {
    min-width: 0;
    background: var(--sidebar-bg);
  }
  .scm-conflict-title {
    padding: 4px 8px;
    color: var(--activity-inactive);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
  }
  .scm-conflict-column pre {
    margin: 0;
    padding: 6px 8px;
    font-family: 'Cascadia Code', 'JetBrains Mono', monospace;
    font-size: 11px;
    white-space: pre-wrap;
    color: var(--sidebar-fg);
  }
  .scm-discard-dialog {
    width: min(420px, calc(100vw - 32px));
    margin: auto;
    padding: 0;
    border: 1px solid var(--panel-border);
    border-radius: 5px;
    background: var(--panel-bg);
    color: var(--fg);
    box-shadow: 0 14px 38px rgba(0, 0, 0, 0.46);
  }
  .scm-discard-dialog::backdrop {
    background: rgba(0, 0, 0, 0.55);
  }
  .scm-discard-dialog form {
    padding: 18px;
  }
  .scm-discard-dialog h2 {
    margin: 0 0 8px;
    font-size: 16px;
  }
  .scm-discard-dialog p {
    margin: 0;
    color: var(--breadcrumb-dim);
    font-size: 12px;
    line-height: 1.55;
    overflow-wrap: anywhere;
  }
  .scm-dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 18px;
  }
  .scm-dialog-button {
    min-width: 72px;
    min-height: 28px;
    padding: 5px 10px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: var(--fg);
    cursor: pointer;
    font: inherit;
    font-size: 11px;
  }
  .scm-dialog-button.danger {
    border-color: var(--error);
    background: var(--error);
    color: var(--bg);
  }
  .debug-toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    padding: 8px 10px;
    border-bottom: 1px solid var(--panel-border);
    align-items: center;
  }
  .debug-launch-select {
    min-width: 0;
    flex: 1;
    min-height: 28px;
    padding: 3px 6px;
    background: var(--input-bg);
    color: var(--fg);
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    outline: none;
    font-size: 12px;
  }
  .debug-launch-select:focus-visible {
    border-color: var(--accent);
    box-shadow: 0 0 0 1px var(--accent);
  }
  .debug-launch-select:disabled {
    opacity: 0.55;
  }
  .debug-launch-meta,
  .debug-advanced-breakpoints {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-bottom: 1px solid var(--panel-border);
    color: var(--breadcrumb-dim);
    font-size: 11px;
    flex-wrap: wrap;
    overflow-wrap: anywhere;
  }
  .debug-launch-pill {
    max-width: 100%;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    padding: 1px 5px;
    color: var(--fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .debug-btn {
    display: inline-flex;
    min-height: 28px;
    align-items: center;
    justify-content: center;
    gap: 4px;
    padding: 4px 9px;
    background: var(--accent);
    color: #fff;
    border: none;
    border-radius: 3px;
    font-size: 12px;
    cursor: pointer;
    font-family: inherit;
  }
  .debug-btn:hover:not(:disabled) {
    filter: brightness(1.1);
  }
  .debug-btn:disabled,
  .debug-icon-button:disabled {
    cursor: default;
    opacity: 0.45;
  }
  .debug-secondary-btn {
    background: #3c3c3c;
    color: var(--sidebar-fg);
  }
  .debug-icon-button {
    display: inline-flex;
    width: 28px;
    height: 28px;
    flex: 0 0 28px;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: 0;
    border-radius: 3px;
    background: transparent;
    color: var(--breadcrumb-dim);
    cursor: pointer;
  }
  .debug-icon-button:hover:not(:disabled) {
    background: color-mix(in srgb, var(--fg) 9%, transparent);
    color: var(--sidebar-fg);
  }
  .debug-icon-button.debug-continue {
    color: var(--success, #89d185);
  }
  .debug-icon-button.debug-stop,
  .debug-remove-breakpoint:hover:not(:disabled) {
    color: var(--error);
  }
  .debug-btn:focus-visible,
  .debug-icon-button:focus-visible,
  .debug-link-button:focus-visible,
  .debug-section-title:focus-visible,
  .debug-row-main:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }
  .debug-session-bar {
    display: flex;
    min-width: 0;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    padding: 5px 10px;
    border-bottom: 1px solid var(--panel-border);
    background: color-mix(in srgb, var(--accent) 8%, transparent);
  }
  .debug-session-state {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 6px;
    color: var(--sidebar-fg);
    font-size: 11px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .debug-session-bar[data-paused='true'] .debug-session-state {
    color: var(--warning, #cca700);
  }
  .debug-session-actions {
    display: flex;
    flex-shrink: 0;
    gap: 1px;
  }
  .debug-message {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 8px 10px;
    border-bottom: 1px solid var(--panel-border);
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.45;
    overflow-wrap: anywhere;
  }
  .debug-message.error {
    color: var(--error);
  }
  .debug-message.success {
    color: var(--sidebar-fg);
  }
  .debug-link-button {
    min-height: 26px;
    flex-shrink: 0;
    padding: 3px 8px;
    border: 1px solid var(--panel-border);
    border-radius: 3px;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
  }
  .debug-section {
    padding: 0;
    border-bottom: 1px solid color-mix(in srgb, var(--panel-border) 70%, transparent);
  }
  .debug-section-title {
    display: flex;
    width: 100%;
    min-height: 30px;
    align-items: center;
    gap: 4px;
    padding: 4px 10px 4px 18px;
    border: 0;
    background: transparent;
    font-size: 11px;
    font-weight: 600;
    color: var(--activity-inactive);
    cursor: pointer;
    font-family: inherit;
    text-align: start;
    text-transform: uppercase;
  }
  .debug-section-title:hover {
    color: var(--sidebar-fg);
    background: color-mix(in srgb, var(--fg) 5%, transparent);
  }
  .debug-section-count {
    margin-inline-start: auto;
    color: var(--breadcrumb-dim);
    font-size: 10px;
    font-weight: 400;
  }
  .debug-empty {
    padding: 7px 12px 9px 28px;
    font-size: 11px;
    line-height: 1.45;
    color: var(--breadcrumb-dim);
    overflow-wrap: anywhere;
  }
  .debug-data-list {
    padding: 0 0 5px;
  }
  .debug-data-row,
  .debug-row-main {
    display: flex;
    min-width: 0;
    width: 100%;
    min-height: 26px;
    align-items: center;
    gap: 6px;
    box-sizing: border-box;
    padding: 3px 10px 3px 28px;
    color: var(--sidebar-fg);
    font-size: 11px;
  }
  button.debug-row-main {
    border: 0;
    background: transparent;
    cursor: pointer;
    font-family: inherit;
    text-align: start;
  }
  .debug-data-row:hover,
  button.debug-row-main:hover {
    background: color-mix(in srgb, var(--fg) 5%, transparent);
  }
  .debug-data-row .debug-row-main {
    min-height: 28px;
    flex: 1;
    padding-inline-start: 0;
  }
  .debug-row-name {
    min-width: 0;
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .debug-row-value {
    min-width: 0;
    max-width: 48%;
    flex-shrink: 1;
    color: var(--breadcrumb-dim);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .debug-row-type {
    flex-shrink: 0;
    color: var(--activity-inactive);
    font-size: 10px;
  }
  .debug-breakpoint-icon {
    flex-shrink: 0;
    color: var(--error);
    font-size: 10px;
  }
  .debug-remove-breakpoint {
    margin-inline-end: 6px;
  }
  .debug-stack-row {
    padding-inline-start: 28px;
  }
  .debug-welcome {
    display: flex;
    min-height: 180px;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 24px 18px;
    text-align: center;
  }
  .debug-welcome-icon {
    margin-bottom: 2px;
    color: var(--accent);
    font-size: 28px;
    opacity: 0.8;
  }
  .debug-welcome strong {
    color: var(--sidebar-fg);
    font-size: 13px;
  }
  .debug-welcome p {
    max-width: 34ch;
    margin: 0 0 5px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
    line-height: 1.5;
  }
  .debug-loading {
    display: flex;
    min-height: 150px;
    align-items: center;
    justify-content: center;
    gap: 7px;
    color: var(--breadcrumb-dim);
    font-size: 11px;
  }
  .webview-container {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 200px;
    height: 100%;
    border-top: 1px solid var(--panel-border);
  }
</style>
