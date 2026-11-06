<script lang="ts">
  import { isPanelMaximized, togglePanel, panelHeight, projectPath, showToast } from '../stores';
  import {
    sendRpc,
    getDaemonIdentity,
    retryDaemonConnection,
    pauseTerminalReads,
    waitForTerminalReadsIdle,
    cancelPendingRpcRequests,
  } from '../../bridge';
  import { loadRendererSession, updateRendererSession } from '$lib/session-recovery';
  import Terminal from './Terminal.svelte';
  import { get } from 'svelte/store';
  import { onMount, tick } from 'svelte';

  const tabs = [
    { id: 'terminal', icon: 'terminal', label: 'Terminal' },
    { id: 'problems', icon: 'warning', label: 'Problems' },
    { id: 'output', icon: 'output', label: 'Output' },
    { id: 'debug-console', icon: 'debug-console', label: 'Debug Console' },
    { id: 'chat', icon: 'comment-discussion', label: 'AI Chat' },
  ];

  let activeTab = $state('terminal');
  let terminalCwd = $state('');
  let problems = $state<any[]>([]);
  let problemsLoading = $state(false);
  let problemsSeverity = $state('all');
  let problemsSource = $state('all');
  let problemsGroupByFile = $state(true);
  let problemsSort = $state('severity');
  let problemsSmokeFixtureActive = false;

  // Output channels
  let outputChannels = $state<Record<string, string[]>>({ WIZP: ['WIZP Editor v0.1.0 — Ready'] });
  let activeChannel = $state('WIZP');

  (window as any).__appendOutput = (channel: string, line: string) => {
    if (!outputChannels[channel]) outputChannels[channel] = [];
    outputChannels[channel] = [...outputChannels[channel], line];
    outputChannels = { ...outputChannels };
  };
  (window as any).__clearOutput = (channel: string) => {
    outputChannels[channel] = [];
    outputChannels = { ...outputChannels };
  };

  // ── Terminal split-pane model ─────────────────────────────────────────────
  // A "group" is a visible terminal pane. Each group can hold multiple terminal sessions as tabs.
  // Split creates a new group; New Terminal adds to the active group.
  type TermSession = {
    id: number;
    label: string;
    groupId: number;
    backendId?: number;
    backendIdentity?: string | null;
    status?: string;
    attachmentRevision?: number;
  };
  type SplitDirection = 'vertical' | 'horizontal';
  type TermGroup = { id: number; sessions: TermSession[]; activeId: number };

  function nativeSmokeTerminalCount(): number | null {
    const raw = new URLSearchParams(window.location.search).get('wizpNativeSmokeTerminals');
    if (!raw) return null;
    const count = Number.parseInt(raw, 10);
    return Number.isFinite(count) && count >= 1 && count <= 8 ? count : null;
  }

  function defaultTerminalGroups(): TermGroup[] {
    return [{ id: 0, sessions: [{ id: 0, label: 'bash', groupId: 0 }], activeId: 0 }];
  }

  function nativeSmokeTerminalGroups(count: number): TermGroup[] {
    return Array.from({ length: count }, (_, index) => ({
      id: index,
      sessions: [{ id: index, label: index === 0 ? 'bash' : `bash #${index}`, groupId: index }],
      activeId: index,
    }));
  }

  function loadTerminalLayout(saved?: any): {
    groups: TermGroup[];
    activeGroupId: number;
    splitDirection: SplitDirection;
    nextId: number;
    nextGroupId: number;
  } {
    const smokeTerminalCount = nativeSmokeTerminalCount();
    if (!saved && smokeTerminalCount !== null) {
      const groups = nativeSmokeTerminalGroups(smokeTerminalCount);
      return {
        groups,
        activeGroupId: 0,
        splitDirection: 'vertical',
        nextId: smokeTerminalCount,
        nextGroupId: smokeTerminalCount,
      };
    }
    try {
      if (!saved) throw new Error('missing terminal layout');
      const groups =
        Array.isArray(saved.groups) && saved.groups.length
          ? saved.groups.map((group: any) => ({
              id: Number(group.id),
              activeId: Number(group.activeId),
              sessions:
                Array.isArray(group.sessions) && group.sessions.length
                  ? group.sessions.map((session: any) => ({
                      id: Number(session.id),
                      label: String(session.label || 'bash'),
                      groupId: Number(group.id),
                      backendId:
                        Number.isInteger(Number(session.backendId)) &&
                        Number(session.backendId) >= 0
                          ? Number(session.backendId)
                          : undefined,
                      backendIdentity:
                        typeof session.backendIdentity === 'string'
                          ? session.backendIdentity
                          : null,
                      status: 'starting',
                    }))
                  : [{ id: Number(group.id), label: 'bash', groupId: Number(group.id) }],
            }))
          : defaultTerminalGroups();
      const maxSessionId = Math.max(
        0,
        ...groups.flatMap((group) => group.sessions.map((session) => session.id)),
      );
      const maxGroupId = Math.max(0, ...groups.map((group) => group.id));
      const active = groups.some((group) => group.id === saved.activeGroupId)
        ? Number(saved.activeGroupId)
        : groups[0].id;
      return {
        groups,
        activeGroupId: active,
        splitDirection: saved.splitDirection === 'horizontal' ? 'horizontal' : 'vertical',
        nextId: maxSessionId + 1,
        nextGroupId: maxGroupId + 1,
      };
    } catch {
      return {
        groups: defaultTerminalGroups(),
        activeGroupId: 0,
        splitDirection: 'vertical',
        nextId: 1,
        nextGroupId: 1,
      };
    }
  }

  let nextId = $state(1);
  let nextGroupId = $state(1);
  let splitDirection = $state<SplitDirection>('vertical');
  let termGroups = $state<TermGroup[]>(defaultTerminalGroups());
  let activeGroupId = $state(0);
  let terminalLayoutLoaded = $state(false);
  let terminalOwnershipReady = $state(false);
  let terminalPersistenceWarningShown = false;

  const TERMINAL_RECONCILE_TIMEOUT_MS = 1000;
  const TERMINAL_LAYOUT_LOAD_TIMEOUT_MS = 2000;

  function resolveWithin<T>(promise: Promise<T>, fallback: T, timeoutMs: number): Promise<T> {
    const { promise: result, resolve } = Promise.withResolvers<T>();
    const timer = window.setTimeout(() => resolve(fallback), timeoutMs);
    promise.then(
      (value) => {
        window.clearTimeout(timer);
        resolve(value);
      },
      () => {
        window.clearTimeout(timer);
        resolve(fallback);
      },
    );
    return result;
  }

  $effect(() => projectPath.subscribe((path) => (terminalCwd = path)));

  // Component refs keyed by session id
  const termRefs: Record<number, any> = {};

  function getActiveTerminalRef() {
    const group = getActiveGroup();
    return group ? termRefs[group.activeId] : null;
  }

  function getActiveSession() {
    const group = getActiveGroup();
    return group?.sessions.find((session) => session.id === group.activeId) ?? null;
  }

  function terminalActionsEnabled() {
    const status = getActiveSession()?.status;
    return status === undefined || status === 'starting' || status === 'ready';
  }

  function terminalLayoutSnapshot() {
    const groups = termGroups.map((group) => ({
      id: group.id,
      activeId: group.activeId,
      sessions: group.sessions.map((session) => ({
        id: session.id,
        label: session.label,
        groupId: session.groupId,
        backendId: session.backendId,
        backendIdentity: session.backendIdentity,
        status: session.status,
      })),
    }));
    return { groups, activeGroupId, splitDirection };
  }

  $effect(() => {
    if (!terminalLayoutLoaded || !terminalOwnershipReady) return;
    const terminalLayout = terminalLayoutSnapshot();
    void updateRendererSession({ editorSession: { terminalLayout } }).catch(() => {
      if (!terminalPersistenceWarningShown) {
        terminalPersistenceWarningShown = true;
        showToast('Terminal recovery could not be saved', 'error');
      }
    });
  });

  function getActiveGroup() {
    return termGroups.find((g) => g.id === activeGroupId)!;
  }

  function addTerminal() {
    if (!terminalOwnershipReady) return;
    const sid = nextId++;
    const gid = activeGroupId;
    termGroups = termGroups.map((g) =>
      g.id === gid
        ? {
            ...g,
            sessions: [
              ...g.sessions,
              {
                id: sid,
                label: `bash #${sid}`,
                groupId: gid,
                backendIdentity: getDaemonIdentity(),
              },
            ],
            activeId: sid,
          }
        : g,
    );
  }

  function addAdoptedTerminal(backendId: number, label = 'Extension Terminal') {
    const sid = nextId++;
    const gid = activeGroupId;
    termGroups = termGroups.map((g) =>
      g.id === gid
        ? {
            ...g,
            sessions: [
              ...g.sessions,
              { id: sid, label, groupId: gid, backendId, backendIdentity: getDaemonIdentity() },
            ],
            activeId: sid,
          }
        : g,
    );
    activeGroupId = gid;
    switchTab('terminal');
  }

  async function createVisibleTerminal(name = 'Extension Terminal') {
    const created = await sendRpc('terminal/createVisible', { name });
    if (typeof created?.id === 'number') {
      addAdoptedTerminal(created.id, name);
    }
  }

  function splitTerminal(direction: SplitDirection = 'vertical') {
    if (!terminalOwnershipReady) return;
    const sid = nextId++;
    const gid = nextGroupId++;
    splitDirection = direction;
    termGroups = [
      ...termGroups,
      {
        id: gid,
        sessions: [
          { id: sid, label: `bash #${sid}`, groupId: gid, backendIdentity: getDaemonIdentity() },
        ],
        activeId: sid,
      },
    ];
    activeGroupId = gid;
  }

  function closeSession(groupId: number, sessionId: number) {
    termRefs[sessionId]?.kill();
    delete termRefs[sessionId];

    const group = termGroups.find((g) => g.id === groupId)!;
    if (group.sessions.length <= 1) {
      // Remove the whole group
      termGroups = termGroups.filter((g) => g.id !== groupId);
      if (termGroups.length === 0) {
        // Re-create one default terminal
        const sid = nextId++;
        const gid = nextGroupId++;
        termGroups = [
          {
            id: gid,
            sessions: [
              { id: sid, label: 'bash', groupId: gid, backendIdentity: getDaemonIdentity() },
            ],
            activeId: sid,
          },
        ];
        activeGroupId = gid;
      } else if (activeGroupId === groupId) {
        activeGroupId = termGroups[0].id;
      }
    } else {
      const idx = group.sessions.findIndex((s) => s.id === sessionId);
      const newSessions = group.sessions.filter((s) => s.id !== sessionId);
      const newActiveId =
        group.activeId === sessionId
          ? newSessions[Math.min(idx, newSessions.length - 1)].id
          : group.activeId;
      termGroups = termGroups.map((g) =>
        g.id === groupId ? { ...g, sessions: newSessions, activeId: newActiveId } : g,
      );
    }
  }

  function activateSession(groupId: number, sessionId: number) {
    activeGroupId = groupId;
    termGroups = termGroups.map((g) => (g.id === groupId ? { ...g, activeId: sessionId } : g));
    // Blur all terminals, then focus the active one
    Object.values(termRefs).forEach((ref) => ref?.blur());
    setTimeout(() => {
      termRefs[sessionId]?.focus();
    }, 0);
  }

  function clearActiveTerminal() {
    const g = getActiveGroup();
    termRefs[g?.activeId]?.clear();
  }

  async function rerunActiveTerminal() {
    const terminal = getActiveTerminalRef();
    terminal?.focus();
    const command = (await terminal?.rerunLastCommand?.()) || '';
    if (!command) {
      (window as any).__appendOutput?.('WIZP', '[Terminal] No runnable command is available');
    }
  }

  function relaunchActiveTerminal() {
    const group = getActiveGroup();
    const previous = getActiveSession();
    if (!group || !previous) return;

    termRefs[previous.id]?.kill();
    delete termRefs[previous.id];
    const sessionId = nextId++;
    termGroups = termGroups.map((candidate) =>
      candidate.id === group.id
        ? {
            ...candidate,
            sessions: candidate.sessions.map((session) =>
              session.id === previous.id
                ? {
                    id: sessionId,
                    label: previous.label,
                    groupId: group.id,
                    status: 'starting',
                    backendIdentity: getDaemonIdentity(),
                  }
                : session,
            ),
            activeId: sessionId,
          }
        : candidate,
    );
    setTimeout(() => termRefs[sessionId]?.focus(), 0);
  }

  function updateTerminalStatus(
    sessionId: number,
    status: string,
    identity: string | null,
    attachmentRevision: number,
  ) {
    termGroups = termGroups.map((group) =>
      group.sessions.some((session) => session.id === sessionId)
        ? {
            ...group,
            sessions: group.sessions.map((session) =>
              session.id === sessionId &&
              session.backendIdentity === identity &&
              (session.attachmentRevision ?? 0) === attachmentRevision
                ? { ...session, status }
                : session,
            ),
          }
        : group,
    );
  }

  function updateTerminalBackendId(
    sessionId: number,
    backendId: number | null,
    backendIdentity: string | null,
  ) {
    termGroups = termGroups.map((group) => ({
      ...group,
      sessions: group.sessions.map((session) =>
        session.id === sessionId && session.backendIdentity === backendIdentity
          ? backendId === null
            ? { ...session, backendId: undefined }
            : { ...session, backendId, backendIdentity }
          : session,
      ),
    }));
  }

  let terminalReconcileInFlight: Promise<void> | null = null;
  let terminalReconcileQueued = false;
  let terminalReconcileForceQueued = false;

  async function performTerminalOwnershipReconciliation(forceRemount = false) {
    if (!terminalLayoutLoaded) return;
    try {
      const before = getDaemonIdentity();
      const result = await resolveWithin(
        sendRpc('terminal/list'),
        null,
        TERMINAL_RECONCILE_TIMEOUT_MS,
      );
      if (result === null) {
        terminalOwnershipReady = true;
        return;
      }
      const identity = getDaemonIdentity();
      if (before !== null && before !== identity) {
        terminalReconcileQueued = true;
        return;
      }
      if (!Array.isArray(result?.terminals)) return;
      const activeBackendIds = new Set(
        result.terminals
          .filter(
            (terminal: any) => terminal?.exitKind === undefined || terminal.exitKind === 'running',
          )
          .map((terminal: any) => Number(terminal?.id))
          .filter((id: number) => Number.isInteger(id) && id >= 0),
      );
      const logicalSessionCount = termGroups.reduce(
        (total, group) => total + group.sessions.length,
        0,
      );
      const adoptableBackendId =
        logicalSessionCount === 1 && activeBackendIds.size === 1
          ? [...activeBackendIds][0]
          : undefined;
      termGroups = termGroups.map((group) => ({
        ...group,
        sessions: group.sessions.map((session) => {
          const sameBackend = session.backendIdentity === identity;
          if (
            !forceRemount &&
            sameBackend &&
            session.backendId === undefined &&
            adoptableBackendId !== undefined
          ) {
            return { ...session, backendId: adoptableBackendId, backendIdentity: identity };
          }
          if (
            !forceRemount &&
            sameBackend &&
            (session.backendId === undefined || activeBackendIds.has(session.backendId))
          ) {
            return session;
          }
          // Numeric IDs are only meaningful inside one daemon incarnation.
          // Retain logical IDs and remount only the obsolete PTY attachment.
          return {
            ...session,
            backendId:
              forceRemount &&
              session.backendId !== undefined &&
              activeBackendIds.has(session.backendId)
                ? session.backendId
                : undefined,
            backendIdentity: identity,
            attachmentRevision: (session.attachmentRevision ?? 0) + 1,
            status: 'starting',
          };
        }),
      }));
      terminalOwnershipReady = true;
    } catch {
      // Render recovered logical sessions even when ownership probing is unavailable.
      // Terminal instances will retry backend attachment through their own lifecycle.
      terminalOwnershipReady = true;
    }
  }

  function reconcileTerminalOwnership(forceRemount = false): Promise<void> {
    if (terminalReconcileInFlight) {
      terminalReconcileQueued = true;
      terminalReconcileForceQueued ||= forceRemount;
      return terminalReconcileInFlight;
    }
    const reconciliation = performTerminalOwnershipReconciliation(forceRemount);
    const tracked = reconciliation.finally(() => {
      if (terminalReconcileInFlight !== tracked) return;
      terminalReconcileInFlight = null;
      if (terminalReconcileQueued) {
        const queuedForceRemount = terminalReconcileForceQueued;
        terminalReconcileQueued = false;
        terminalReconcileForceQueued = false;
        void reconcileTerminalOwnership(queuedForceRemount);
      }
    });
    terminalReconcileInFlight = tracked;
    return tracked;
  }

  function applyTerminalLayout(layout: ReturnType<typeof loadTerminalLayout>) {
    termGroups = layout.groups;
    activeGroupId = layout.activeGroupId;
    splitDirection = layout.splitDirection;
    nextId = layout.nextId;
    nextGroupId = layout.nextGroupId;
    terminalLayoutLoaded = true;
  }

  function restoreDefaultTerminalLayout() {
    applyTerminalLayout(loadTerminalLayout());
    terminalOwnershipReady = true;
  }

  onMount(() => {
    let disposed = false;
    const initialize = async (forceTerminalRemount = false) => {
      if (!terminalLayoutLoaded) {
        // Mount a usable terminal immediately; session hydration may depend on
        // the same daemon transport that terminal recovery is probing.
        applyTerminalLayout(loadTerminalLayout());
        const saved = await resolveWithin(
          loadRendererSession(),
          null,
          TERMINAL_LAYOUT_LOAD_TIMEOUT_MS,
        );
        if (disposed) return;
        if (saved) {
          const layout = loadTerminalLayout(saved.editorSession?.terminalLayout);
          applyTerminalLayout(layout);
        }
      }
      await reconcileTerminalOwnership(forceTerminalRemount);
    };
    const onDaemonReconnected = () =>
      void initialize(true).catch(() => restoreDefaultTerminalLayout());
    window.addEventListener('wizpDaemonReconnected', onDaemonReconnected);
    void initialize().catch(() => restoreDefaultTerminalLayout());
    (window as any).__getTerminalLayout = terminalLayoutSnapshot;
    return () => {
      disposed = true;
      window.removeEventListener('wizpDaemonReconnected', onDaemonReconnected);
      delete (window as any).__getTerminalLayout;
    };
  });

  async function copyActiveTerminalSelection() {
    const g = getActiveGroup();
    const text = termRefs[g?.activeId]?.getSelection?.() ?? '';
    if (text) await navigator.clipboard.writeText(text);
  }

  async function pasteIntoActiveTerminal() {
    const text = await navigator.clipboard.readText();
    const g = getActiveGroup();
    await termRefs[g?.activeId]?.pasteText?.(text, 'clipboard-api');
  }

  function killActiveTerminal() {
    const g = getActiveGroup();
    if (g) closeSession(g.id, g.activeId);
  }

  // ── Maximize / restore ────────────────────────────────────────────────────
  let preMaxHeight = 200;

  function toggleMaximize() {
    const isMax = get(isPanelMaximized);
    if (!isMax) {
      preMaxHeight = get(panelHeight);
      isPanelMaximized.set(true);
    } else {
      isPanelMaximized.set(false);
      panelHeight.set(preMaxHeight);
    }
  }

  function onTabBarDblClick(e: MouseEvent) {
    // Only trigger if clicking directly on the tabbar background (not a child button/tab)
    if ((e.target as HTMLElement).closest('.term-tab, button, .tab-pill')) return;
    toggleMaximize();
  }

  // Watch isPanelMaximized and adjust --panel-height CSS var
  $effect(() => {
    const unsubMax = isPanelMaximized.subscribe((max) => {
      if (max) {
        document.documentElement.style.setProperty(
          '--panel-height',
          'calc(100vh - 35px - 28px - 35px)',
        );
      }
      // When false, App.svelte's effect will restore from panelHeight store
    });
    return unsubMax;
  });

  // ── Context Menu ──────────────────────────────────────────────────────────
  let ctxMenu = $state<{ x: number; y: number } | null>(null);

  function openContextMenu(e: MouseEvent) {
    e.preventDefault();
    ctxMenu = { x: e.clientX, y: e.clientY };
  }

  function closeContextMenu() {
    ctxMenu = null;
  }

  $effect(() => {
    const hide = () => closeContextMenu();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closeContextMenu();
      if (e.ctrlKey && e.key === 'l' && activeTab === 'terminal') {
        e.preventDefault();
        clearActiveTerminal();
      }
    };
    document.addEventListener('click', hide);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('click', hide);
      document.removeEventListener('keydown', onKey);
    };
  });

  // ── Problems ──────────────────────────────────────────────────────────────
  async function refreshProblems() {
    problemsLoading = true;
    try {
      const res = await sendRpc('editor/problems/reconcile', {
        groupByFile: problemsGroupByFile,
        sort: problemsSort,
      });
      problems = Array.isArray(res?.problems) ? res.problems : Array.isArray(res) ? res : [];
    } catch {
      try {
        const res = await sendRpc('editor/problems');
        problems = Array.isArray(res) ? res : [];
      } catch {
        problems = [];
      }
    } finally {
      const errors = problems.filter((p: any) => p.severity === 1).length;
      const warnings = problems.filter((p: any) => p.severity === 2).length;
      document.dispatchEvent(new CustomEvent('problems:updated', { detail: { errors, warnings } }));
      problemsLoading = false;
    }
  }

  function switchTab(id: string) {
    activeTab = id;
    if (id === 'problems' && !problemsSmokeFixtureActive) refreshProblems();
  }

  function openProblem(p: any) {
    (window as any).__lastOpenedProblem = p;
    (window as any).__openFile?.(p.file);
  }
  const sevIcon = (s: number) =>
    s === 1 ? 'error' : s === 2 ? 'warning' : s === 3 ? 'info' : 'lightbulb';
  const sevLabel = (s: number) =>
    s === 1 ? 'Error' : s === 2 ? 'Warning' : s === 3 ? 'Info' : 'Hint';

  function filteredProblems() {
    let list = [...problems];
    if (problemsSeverity !== 'all') {
      const severity = Number(problemsSeverity);
      list = list.filter((p: any) => p.severity === severity);
    }
    if (problemsSource !== 'all') {
      list = list.filter((p: any) => String(p.source || '') === problemsSource);
    }
    list.sort((a: any, b: any) => {
      if (problemsSort === 'file') {
        const byFile = String(a.file).localeCompare(String(b.file));
        if (byFile !== 0) return byFile;
      } else {
        const bySeverity = (a.severity || 99) - (b.severity || 99);
        if (bySeverity !== 0) return bySeverity;
      }
      return (a.line || 0) - (b.line || 0) || (a.col || 0) - (b.col || 0);
    });
    return list;
  }

  function groupedProblems() {
    const groups: Record<string, any[]> = {};
    for (const problem of filteredProblems()) {
      const key = problem.file || 'Unknown';
      if (!groups[key]) groups[key] = [];
      groups[key].push(problem);
    }
    return Object.entries(groups);
  }

  (window as any).__setProblemsForSmoke = (items: any[]) => {
    problemsSmokeFixtureActive = true;
    problems = Array.isArray(items) ? items : [];
    const errors = problems.filter((p: any) => p.severity === 1).length;
    const warnings = problems.filter((p: any) => p.severity === 2).length;
    document.dispatchEvent(new CustomEvent('problems:updated', { detail: { errors, warnings } }));
  };

  $effect(() => {
    const iv = setInterval(() => {
      if (activeTab === 'problems' && !problemsSmokeFixtureActive) refreshProblems();
    }, 30000);
    return () => clearInterval(iv);
  });
  async function mirrorTaskCommand(command: string, label: string, attempt = 0) {
    let gr = getActiveGroup();
    if (!gr && terminalOwnershipReady) {
      addTerminal();
      gr = getActiveGroup();
    }
    const ref = gr ? termRefs[gr.activeId] : null;
    if (ref?.getLifecycleStatus?.() === 'disconnected') {
      if (ref.recoverAfterReconnect?.() !== true) {
        if (attempt >= 200) return;
        void retryDaemonConnection().then((connected) => {
          if (connected) {
            const currentGroup = getActiveGroup();
            const currentRef = currentGroup ? termRefs[currentGroup.activeId] : null;
            currentRef?.recoverAfterReconnect?.();
          }
          void mirrorTaskCommand(command, label, attempt + 1);
        });
        return;
      }
    }
    if (!ref || !ref.isInputEnabled?.()) {
      if (attempt >= 200) return;
      void retryDaemonConnection().then((connected) => {
        if (connected) {
          const currentGroup = getActiveGroup();
          const currentRef = currentGroup ? termRefs[currentGroup.activeId] : null;
          currentRef?.recoverAfterReconnect?.();
        }
        void mirrorTaskCommand(command, label, attempt + 1);
      });
      return;
    }
    if (gr && ref && (ref.isInputEnabled?.() ?? true)) {
      const sent = await ref.sendText(command);
      if (sent) {
        (window as any).__lastTaskTerminalMirror = {
          command,
          mirrored: true,
          label,
          sessionId: gr.activeId,
        };
        return;
      }
    }
    if (attempt < 200) {
      window.setTimeout(() => void mirrorTaskCommand(command, label, attempt + 1), 50);
    }
  }

  function handleTaskExecute(e: Event) {
    const task = (e as CustomEvent).detail;
    const command = task?.execution?.command || task?.command;
    if (task && command) {
      const label = task.label || 'Task';
      (window as any).__lastTaskTerminalMirror = {
        command,
        mirrored: false,
        label,
      };
      switchTab('terminal');
      const g = getActiveGroup();
      if (!g) {
        addTerminal();
      }
      cancelPendingRpcRequests(['tasks/run']);
      const resumeTerminalReads = pauseTerminalReads();
      const taskRun = (async () => {
        try {
          await waitForTerminalReadsIdle();
          await new Promise<void>((resolve) => window.setTimeout(resolve, 150));
          const run = sendRpc('tasks/run', { command, background: task.background === true });
          void tick().then(async () => {
            try {
              await mirrorTaskCommand(command, label);
            } finally {
              resumeTerminalReads();
            }
          });
          return await run;
        } catch (error) {
          resumeTerminalReads();
          throw error;
        }
      })();
      taskRun
        .then((result: any) => {
          (window as any).__lastTaskUiResult = result;
          (window as any).__appendOutput?.(
            'Tasks',
            `[${task.label || 'Task'}] ${result.state || 'completed'}`,
          );
          if (result.stdout) (window as any).__appendOutput?.('Tasks', result.stdout.trim());
          if (result.stderr) (window as any).__appendOutput?.('Tasks', result.stderr.trim());
          if (Array.isArray(result.problems) && result.problems.length > 0) {
            problems = [
              ...problems,
              ...result.problems.map((problem: any) => ({
                ...problem,
                source: task.label || 'task',
                severity: 2,
                col: 0,
              })),
            ];
            (window as any).__lastTaskProblems = problems.filter(
              (problem: any) => String(problem.source || '') === String(task.label || 'task'),
            );
            document.dispatchEvent(
              new CustomEvent('problems:updated', {
                detail: {
                  errors: problems.filter((p: any) => p.severity === 1).length,
                  warnings: problems.filter((p: any) => p.severity === 2).length,
                },
              }),
            );
          }
        })
        .catch((err: any) => {
          (window as any).__appendOutput?.(
            'Tasks',
            `[${task.label || 'Task'}] ${err?.message || 'failed'}`,
          );
        });
    }
  }

  let chatParticipants = $state<any[]>([]);
  $effect(() => {
    window.addEventListener('wizpTaskExecute', handleTaskExecute);
    (window as any).__getActiveTerminalSmoke = () => {
      const ref = getActiveTerminalRef();
      const group = getActiveGroup();
      return {
        selection: ref?.getSelection?.() ?? '',
        serialized: ref?.serializeBuffer?.() ?? '',
        findAlpha: ref?.findNext?.('alpha') ?? false,
        commandDecorations: ref?.getCommandDecorations?.() ?? [],
        lastCommand: ref?.getLastCommand?.() ?? '',
        lastRerunResult: ref?.getLastRerunResult?.() ?? 'not-run',
        lastPaste: ref?.getLastPaste?.() ?? null,
        clipboardError: ref?.getClipboardError?.() ?? '',
        spawnError: ref?.getSpawnError?.() ?? null,
        droppedBytes: ref?.getDroppedBytes?.() ?? 0,
        lastLinkActivation: ref?.getLastLinkActivation?.() ?? null,
        linkTarget: ref?.getLinkTarget?.() ?? null,
        sessionId: ref?.getSessionId?.() ?? null,
        status: ref?.getLifecycleStatus?.() ?? 'missing',
        inputEnabled: ref?.isInputEnabled?.() ?? false,
        renderedBytes: Number(
          document
            .querySelector(`[data-terminal-session-id="${ref?.getSessionId?.() ?? ''}"]`)
            ?.getAttribute('data-terminal-rendered-bytes') || 0,
        ),
        dataReadCount: Number(
          document
            .querySelector(`[data-terminal-session-id="${ref?.getSessionId?.() ?? ''}"]`)
            ?.getAttribute('data-terminal-data-read-count') || 0,
        ),
        activeGroupId: group?.id ?? null,
        activeSessionId: group?.activeId ?? null,
      };
    };
    const handleChat = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      chatParticipants = [...chatParticipants, detail];
      switchTab('chat');
    };
    window.addEventListener('wizpChatRegistered', handleChat);
    return () => {
      window.removeEventListener('wizpTaskExecute', handleTaskExecute);
      window.removeEventListener('wizpChatRegistered', handleChat);
      delete (window as any).__getActiveTerminalSmoke;
    };
  });

  // Debug console output
  let debugConsoleLines = $state<string[]>([]);
  let debugConsoleInput = $state('');
  let debugConsoleEvaluating = $state(false);
  let debugConsoleMessage = $state<{ kind: 'info' | 'error'; text: string } | null>(null);

  function appendDebugLine(line: string) {
    debugConsoleLines = [...debugConsoleLines.slice(-500), line];
  }

  // Store-derived reactive values
  let _isPanelMaximized = $state(false);
  $effect(() => {
    const u = isPanelMaximized.subscribe((v) => (_isPanelMaximized = v));
    return u;
  });

  $effect(() => {
    const handleOutput = (e: Event) => {
      const d = (e as CustomEvent).detail;
      appendDebugLine(`[output] ${d?.output || JSON.stringify(d)}`);
      if (activeTab !== 'debug-console') switchTab('debug-console');
    };
    const handleStopped = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (detail?.source) return;
      appendDebugLine(`[stopped] ${detail?.reason || 'breakpoint'} at line ${detail?.line || '?'}`);
    };
    const handleTerminated = (event: Event) => {
      if ((event as CustomEvent).detail?.source) return;
      appendDebugLine('[session ended]');
    };
    const handleSplitTerminal = () => splitTerminal('vertical');
    const handleKillTerminal = () => killActiveTerminal();
    const handleCreateVisibleTerminal = (e: Event) => {
      const detail = (e as CustomEvent).detail || {};
      createVisibleTerminal(detail.name || 'Extension Terminal').catch(() => {});
    };
    window.addEventListener('wizpDebugOutput', handleOutput);
    window.addEventListener('wizpDebugStopped', handleStopped);
    window.addEventListener('wizpDebugTerminated', handleTerminated);
    document.addEventListener('terminal:split', handleSplitTerminal);
    document.addEventListener('terminal:kill', handleKillTerminal);
    document.addEventListener('terminal:create-visible', handleCreateVisibleTerminal);
    return () => {
      window.removeEventListener('wizpDebugOutput', handleOutput);
      window.removeEventListener('wizpDebugStopped', handleStopped);
      window.removeEventListener('wizpDebugTerminated', handleTerminated);
      document.removeEventListener('terminal:split', handleSplitTerminal);
      document.removeEventListener('terminal:kill', handleKillTerminal);
      document.removeEventListener('terminal:create-visible', handleCreateVisibleTerminal);
    };
  });

  async function sendDebugConsoleInput() {
    const expression = debugConsoleInput.trim();
    if (!expression || debugConsoleEvaluating) return;
    debugConsoleEvaluating = true;
    debugConsoleMessage = { kind: 'info', text: `Evaluating ${expression}…` };
    appendDebugLine(`> ${expression}`);
    try {
      const result = await sendRpc('debug/evaluate', { expression });
      appendDebugLine(`  ${result?.result ?? ''}`);
      debugConsoleInput = '';
      debugConsoleMessage = { kind: 'info', text: 'Evaluation complete.' };
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : 'Evaluation failed.';
      appendDebugLine(`[error] ${message}`);
      debugConsoleMessage = { kind: 'error', text: message };
    } finally {
      debugConsoleEvaluating = false;
    }
  }
</script>

<!-- ── Panel shell ── -->
<div class="flex flex-col min-h-0 min-w-0 h-full w-full bg-panel overflow-hidden">
  <!-- Panel tab bar -->
  <div class="flex items-center shrink-0 h-[35px] px-2 bg-sidebar border-b border-border">
    <div class="flex flex-1 gap-4 h-full items-center pl-2">
      {#each tabs as tab (tab.id)}
        <div
          class="flex items-center h-full px-4 cursor-pointer text-[12px] whitespace-nowrap select-none border-b-2 {activeTab ===
          tab.id
            ? 'text-fg border-accent'
            : 'text-dim border-transparent hover:text-fg'}"
          role="button"
          tabindex="0"
          onclick={() => switchTab(tab.id)}
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              switchTab(tab.id);
            }
          }}
        >
          <span class="codicon codicon-{tab.icon} mr-2"></span>{tab.label}
        </div>
      {/each}
    </div>
    <div class="flex items-center gap-[2px] shrink-0">
      <button class="icon-btn" title="Maximize Panel" onclick={toggleMaximize}>
        <span class="codicon {_isPanelMaximized ? 'codicon-chevron-down' : 'codicon-chevron-up'}"
        ></span>
      </button>
      <button class="icon-btn" title="Close Panel" onclick={() => togglePanel(false)}>
        <span class="codicon codicon-close"></span>
      </button>
    </div>
  </div>

  <!-- Panel body -->
  <div class="flex-1 min-h-0 overflow-hidden flex flex-col">
    <!-- ── Terminal tab view ── -->
    <div class="flex-1 flex flex-col min-h-0 min-w-0 {activeTab === 'terminal' ? '' : 'hidden'}">
      <!-- Session tab bar (per group tabs with visual grouping) -->
      <div
        class="flex items-center bg-black/20 border-b border-border shrink-0 h-[32px] px-2 select-none"
        ondblclick={onTabBarDblClick}
        role="toolbar"
        tabindex="0"
      >
        <!-- Session tabs grouped -->
        <div class="flex items-center flex-1 min-w-0 overflow-x-auto">
          {#each termGroups as group, gi (group.id)}
            <!-- Group separator (shows split boundary) -->
            {#if gi > 0}
              <div class="group-sep" title="Split boundary"></div>
            {/if}
            <!-- Sessions in this group -->
            {#each group.sessions as sess, si (sess.id)}
              <div
                class="term-tab {activeGroupId === group.id && group.activeId === sess.id
                  ? 'term-tab-active'
                  : 'term-tab-inactive'}"
                role="button"
                tabindex="0"
                onclick={() => activateSession(group.id, sess.id)}
                onkeydown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    activateSession(group.id, sess.id);
                  }
                }}
              >
                <!-- Show split icon on first session of each non-first group -->
                {#if si === 0 && gi > 0}
                  <span
                    class="codicon {splitDirection === 'horizontal'
                      ? 'codicon-split-vertical'
                      : 'codicon-split-horizontal'} text-[10px] mr-1 text-dim"
                  ></span>
                {:else}
                  <span class="codicon codicon-terminal text-[10px] mr-1.5"></span>
                {/if}
                <span
                  class="term-status-dot {sess.status === 'ready'
                    ? 'term-status-ready'
                    : sess.status === 'error'
                      ? 'term-status-error'
                      : sess.status === 'exited' || sess.status === 'killed'
                        ? 'term-status-ended'
                        : 'term-status-starting'}"
                  title={`Terminal ${sess.status || 'starting'}`}
                ></span>
                <span class="term-tab-label">{sess.label}</span>
                <button
                  class="term-close-btn"
                  title="Close"
                  onclick={(e) => {
                    e.stopPropagation();
                    closeSession(group.id, sess.id);
                  }}
                >
                  <span class="codicon codicon-close" style="font-size:9px"></span>
                </button>
              </div>
            {/each}
          {/each}

          <!-- New terminal button -->
          <button class="icon-btn ml-1" onclick={addTerminal} title="New Terminal">
            <span class="codicon codicon-add" style="font-size:14px"></span>
          </button>
        </div>

        <!-- Right-side action icons -->
        <div class="flex items-center gap-[2px] shrink-0 ml-2">
          <button
            class="icon-btn"
            title="Split Terminal Right"
            onclick={() => splitTerminal('vertical')}
          >
            <span class="codicon codicon-split-horizontal"></span>
          </button>
          <button
            class="icon-btn"
            title="Split Terminal Down"
            onclick={() => splitTerminal('horizontal')}
          >
            <span class="codicon codicon-split-vertical"></span>
          </button>
          <div class="w-px h-4 bg-white/10 mx-0.5"></div>
          <button
            class="icon-btn"
            title="Clear Terminal (Ctrl+L)"
            disabled={!terminalActionsEnabled()}
            onclick={clearActiveTerminal}
          >
            <span class="codicon codicon-clear-all"></span>
          </button>
          <button
            class="icon-btn"
            title="Rerun Last Command"
            disabled={!terminalActionsEnabled()}
            onclick={rerunActiveTerminal}
          >
            <span class="codicon codicon-run-all"></span>
          </button>
          {#if !terminalActionsEnabled()}
            <button
              class="icon-btn"
              title={getActiveSession()?.status === 'error'
                ? 'Retry Terminal Spawn'
                : 'Relaunch Terminal'}
              onclick={relaunchActiveTerminal}
            >
              <span class="codicon codicon-refresh"></span>
            </button>
          {/if}
          <button
            class="icon-btn hover:text-red-400"
            title="Kill Terminal"
            onclick={killActiveTerminal}
          >
            <span class="codicon codicon-trash"></span>
          </button>
          <div class="w-px h-4 bg-white/10 mx-0.5"></div>
          <button
            class="icon-btn"
            title={_isPanelMaximized ? 'Restore Panel' : 'Maximize Panel'}
            onclick={toggleMaximize}
          >
            <span
              class="codicon {_isPanelMaximized ? 'codicon-chevron-down' : 'codicon-chevron-up'}"
            ></span>
          </button>
        </div>
      </div>

      <!-- Terminal panes -->
      <div
        class="flex flex-1 min-h-0 bg-[#1e1e1e] {splitDirection === 'horizontal'
          ? 'flex-col'
          : 'flex-row'}"
      >
        {#each termGroups as group, gi (group.id)}
          <!-- Resizer between groups -->
          {#if gi > 0}
            <div
              class="group-resizer {splitDirection === 'horizontal'
                ? 'group-resizer-row'
                : 'group-resizer-col'}"
              role="separator"
            ></div>
          {/if}

          <!-- Group column: sessions are stacked, only the active one shown -->
          <div
            class="flex-1 min-h-0 min-w-0 relative {activeGroupId === group.id
              ? 'group-col-active'
              : 'group-col'}"
          >
            <!-- Focus ring on active group -->
            {#if termGroups.length > 1}
              <div
                class="group-focus-ring {activeGroupId === group.id
                  ? 'ring-active'
                  : 'ring-inactive'}"
              ></div>
            {/if}
            {#each group.sessions as sess (`${sess.id}:${sess.backendIdentity ?? 'browser'}:${sess.attachmentRevision ?? 0}`)}
              <div
                class="absolute inset-0"
                class:invisible={group.activeId !== sess.id}
                class:pointer-events-none={group.activeId !== sess.id}
              >
                {#if terminalOwnershipReady}
                  <Terminal
                    bind:this={termRefs[sess.id]}
                    existingSessionId={sess.backendId ?? null}
                    existingBackendIdentity={sess.backendIdentity ?? null}
                    cwd={terminalCwd || undefined}
                    onContextMenu={openContextMenu}
                    onFocus={() => activateSession(group.id, sess.id)}
                    onStatusChange={(status) =>
                      updateTerminalStatus(
                        sess.id,
                        status,
                        sess.backendIdentity ?? null,
                        sess.attachmentRevision ?? 0,
                      )}
                    onSessionIdChange={(backendId, identity) =>
                      updateTerminalBackendId(sess.id, backendId, identity)}
                  />
                {/if}
              </div>
            {/each}
          </div>
        {/each}
      </div>
    </div>

    <!-- ── Problems ── -->
    <div
      class="flex-1 flex flex-col overflow-y-auto text-dim {activeTab === 'problems'
        ? ''
        : 'hidden'}"
    >
      <div class="flex items-center gap-2 px-2 py-1 bg-black/20 border-b border-border shrink-0">
        <select
          class="bg-transparent border border-border text-[11px] text-sidebar-fg px-2 py-1 rounded-[2px]"
          bind:value={problemsSeverity}
          title="Filter by severity"
        >
          <option value="all">All</option>
          <option value="1">Errors</option>
          <option value="2">Warnings</option>
          <option value="3">Info</option>
          <option value="4">Hints</option>
        </select>
        <select
          class="bg-transparent border border-border text-[11px] text-sidebar-fg px-2 py-1 rounded-[2px]"
          bind:value={problemsSource}
          title="Filter by source"
        >
          <option value="all">All Sources</option>
          <option value="native">Native</option>
          <option value="task">Task</option>
          <option value="extension">Extension</option>
        </select>
        <select
          class="bg-transparent border border-border text-[11px] text-sidebar-fg px-2 py-1 rounded-[2px]"
          bind:value={problemsSort}
          title="Sort problems"
        >
          <option value="severity">Severity</option>
          <option value="file">File</option>
        </select>
        <label class="flex items-center gap-1 text-[11px] text-dim ml-1">
          <input type="checkbox" bind:checked={problemsGroupByFile} />
          File
        </label>
        <button
          class="icon-btn ml-auto"
          title="Refresh Problems"
          onclick={() => {
            problemsSmokeFixtureActive = false;
            void refreshProblems();
          }}
        >
          <span class="codicon codicon-refresh"></span>
        </button>
      </div>
      {#if problemsLoading}
        <div class="flex-1 flex justify-center items-center">Loading problems...</div>
      {:else if filteredProblems().length === 0}
        <div class="p-3">No problems detected in the workspace.</div>
      {:else if problemsGroupByFile}
        {#each groupedProblems() as [file, items] (file)}
          <div
            class="px-3 py-1 text-[11px] font-semibold text-sidebar-fg bg-white/5 border-b border-white/5"
          >
            {file.split('/').pop() || file}
            <span class="text-dim font-normal ml-2">{items.length}</span>
          </div>
          {#each items as p (p.id || p.message + ':' + p.line)}
            <div
              class="problem-row flex items-center px-3 py-1 cursor-pointer text-[12px] text-sidebar-fg gap-2 border-b border-white/5 hover:bg-white/5 transition-colors"
              role="button"
              tabindex="0"
              data-source={p.source || ''}
              data-file={p.file || ''}
              onclick={() => openProblem(p)}
              onkeydown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  openProblem(p);
                }
              }}
            >
              <span
                class="codicon codicon-{sevIcon(p.severity)} shrink-0 {p.severity === 1
                  ? 'text-error'
                  : p.severity === 2
                    ? 'text-warn'
                    : 'text-info'}"
                title={sevLabel(p.severity)}
              ></span>
              <span class="text-dim text-[11px] shrink-0">Ln {p.line + 1}, Col {p.col + 1}</span>
              <span class="text-dim text-[11px] shrink-0">{p.source || 'unknown'}</span>
              <span class="overflow-hidden text-ellipsis">{p.message}</span>
            </div>
          {/each}
        {/each}
      {:else}
        {#each filteredProblems() as p (p.id || p.message + ':' + p.line)}
          <div
            class="problem-row flex items-center px-3 py-1 cursor-pointer text-[12px] text-sidebar-fg gap-2 border-b border-white/5 hover:bg-white/5 transition-colors"
            role="button"
            tabindex="0"
            data-source={p.source || ''}
            data-file={p.file || ''}
            onclick={() => openProblem(p)}
            onkeydown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                openProblem(p);
              }
            }}
          >
            <span
              class="codicon codicon-{sevIcon(p.severity)} shrink-0 {p.severity === 1
                ? 'text-error'
                : p.severity === 2
                  ? 'text-warn'
                  : 'text-info'}"
            ></span>
            <span class="font-semibold shrink-0 max-w-[200px] overflow-hidden text-ellipsis"
              >{p.file.split('/').pop() || p.file}</span
            >
            <span class="text-dim text-[11px] shrink-0">Ln {p.line + 1}, Col {p.col + 1}</span>
            <span class="text-dim text-[11px] shrink-0">{p.source || 'unknown'}</span>
            <span class="overflow-hidden text-ellipsis">{p.message}</span>
          </div>
        {/each}
      {/if}
    </div>

    <!-- ── Output ── -->
    <div class="flex-1 flex flex-col {activeTab === 'output' ? '' : 'hidden'}">
      <div class="flex gap-[2px] px-2 py-1 bg-black/20 border-b border-border shrink-0">
        {#each Object.keys(outputChannels) as ch (ch)}
          <button
            class="bg-transparent border-none cursor-pointer px-2 py-[2px] text-[11px] rounded-[2px] flex items-center gap-1 hover:bg-white/10 transition-colors {activeChannel ===
            ch
              ? 'text-fg bg-white/5'
              : 'text-dim'}"
            onclick={() => (activeChannel = ch)}
          >
            {ch}
            <span class="text-[10px] bg-white/10 px-1 rounded-full"
              >{outputChannels[ch].length}</span
            >
          </button>
        {/each}
        <button
          class="bg-transparent border-none cursor-pointer px-2 py-[2px] text-[11px] rounded-[2px] text-dim ml-auto hover:bg-white/10 transition-colors"
          onclick={() => (window as any).__clearOutput(activeChannel)}
          title="Clear"
        >
          <span class="codicon codicon-clear-all"></span>
        </button>
      </div>
      <pre
        class="flex-1 m-0 px-3 py-2 font-mono text-[12px] whitespace-pre-wrap overflow-y-auto text-sidebar-fg">{outputChannels[
          activeChannel
        ]?.join('\n') || 'No output'}</pre>
    </div>

    <!-- ── Debug Console ── -->
    <div class="flex-1 flex flex-col {activeTab === 'debug-console' ? '' : 'hidden'} bg-[#1e1e1e]">
      <div class="flex items-center gap-2 px-2 py-1 bg-black/20 border-b border-border shrink-0">
        <span class="codicon codicon-debug-console text-[14px] text-dim"></span>
        <span class="text-[11px] text-dim font-semibold">DEBUG CONSOLE</span>
        <button
          class="ml-auto icon-btn"
          title="Clear Debug Console"
          aria-label="Clear Debug Console"
          onclick={() => {
            debugConsoleLines = [];
            debugConsoleMessage = null;
          }}
        >
          <span class="codicon codicon-clear-all text-[13px]" aria-hidden="true"></span>
        </button>
      </div>
      <div
        class="flex-1 overflow-y-auto px-3 py-2 font-mono text-[12px]"
        id="debug-console-output"
        role="log"
        aria-live="polite"
        aria-label="Debug Console output"
      >
        {#if debugConsoleLines.length === 0}
          <div class="text-dim italic">
            Debug session not started. Press F5 or use Run → Start Debugging.
          </div>
        {:else}
          {#each debugConsoleLines as line, lineIdx (lineIdx)}
            <div
              class="py-[1px] {line.startsWith('[stopped]')
                ? 'text-yellow-400'
                : line.startsWith('[output]')
                  ? 'text-sidebar-fg'
                  : line.startsWith('>')
                    ? 'text-accent'
                    : line.startsWith('[error]')
                      ? 'text-red-400'
                      : 'text-dim'}"
            >
              {line}
            </div>
          {/each}
        {/if}
      </div>
      {#if debugConsoleMessage}
        <div
          class="px-3 py-1 text-[11px] border-t border-border {debugConsoleMessage.kind === 'error'
            ? 'text-red-400'
            : 'text-dim'}"
          role={debugConsoleMessage.kind === 'error' ? 'alert' : 'status'}
        >
          {debugConsoleMessage.text}
        </div>
      {/if}
      <div class="flex items-center border-t border-border px-2 py-1 gap-2 shrink-0">
        <span class="codicon codicon-chevron-right text-dim text-[13px]" aria-hidden="true"></span>
        <input
          type="text"
          class="flex-1 bg-transparent border-none outline-none text-fg text-[12px] font-mono placeholder:text-dim"
          placeholder="Evaluate expression..."
          aria-label="Debug expression"
          maxlength="4096"
          bind:value={debugConsoleInput}
          disabled={debugConsoleEvaluating}
          onkeydown={(e) => e.key === 'Enter' && void sendDebugConsoleInput()}
        />
        <button
          class="icon-btn"
          onclick={() => void sendDebugConsoleInput()}
          title="Evaluate expression"
          aria-label="Evaluate expression"
          disabled={!debugConsoleInput.trim() || debugConsoleEvaluating}
        >
          <span
            class="codicon codicon-{debugConsoleEvaluating
              ? 'loading codicon-modifier-spin'
              : 'send'} text-[13px]"
            aria-hidden="true"
          ></span>
        </button>
      </div>
    </div>

    <!-- ── AI Chat ── -->
    <div class="flex-1 flex flex-col {activeTab === 'chat' ? '' : 'hidden'} bg-[#1e1e1e]">
      <div class="flex items-center gap-2 px-2 py-1 bg-black/20 border-b border-border shrink-0">
        <span class="codicon codicon-comment-discussion text-[14px] text-dim"></span>
        <span class="text-[11px] text-dim font-semibold">AI CHAT</span>
        {#if chatParticipants.length > 0}
          <span class="text-[10px] text-dim ml-2"
            >{chatParticipants.map((c) => '@' + c.name).join(', ')}</span
          >
        {/if}
      </div>
      {#if chatParticipants.length === 0}
        <div class="flex-1 flex flex-col items-center justify-center gap-3 text-dim p-6">
          <span class="codicon codicon-robot text-[32px] text-accent/40"></span>
          <span class="text-[12px] text-center"
            >No AI chat participants registered.<br />Install an extension that provides chat
            support.</span
          >
        </div>
      {:else}
        <div class="flex-1 overflow-y-auto p-4 flex flex-col gap-2">
          <div class="flex gap-2 text-[12px] items-start">
            <span class="codicon codicon-robot text-accent mt-0.5"></span>
            <div class="bg-white/5 rounded-md px-3 py-2 text-sidebar-fg">
              Hi! I'm the WIZP AI assistant. How can I help?
            </div>
          </div>
        </div>
        <div class="relative px-3 pb-3 shrink-0">
          <input
            type="text"
            class="w-full bg-[#3c3c3c] border border-transparent rounded-md py-[7px] pl-[10px] pr-[36px] text-[13px] text-fg outline-none focus:border-accent transition-colors"
            placeholder="Ask a question..."
          />
          <button
            class="absolute right-5 top-1/2 -translate-y-1/2 text-dim hover:text-fg transition-colors"
            title="Send message"
            aria-label="Send message"><span class="codicon codicon-send text-[14px]"></span></button
          >
        </div>
      {/if}
    </div>
  </div>
</div>

<!-- ── Terminal Context Menu ── -->
{#if ctxMenu}
  <div
    class="ctx-menu"
    style="left: {ctxMenu.x}px; top: {ctxMenu.y}px;"
    role="menu"
    tabindex="0"
    onclick={(e) => e.stopPropagation()}
    onkeydown={(e) => e.key === 'Escape' && closeContextMenu()}
  >
    <button
      class="ctx-item"
      onclick={() => {
        copyActiveTerminalSelection().finally(closeContextMenu);
      }}
    >
      <span class="codicon codicon-copy ctx-icon"></span>Copy<span class="ctx-hint">Ctrl+C</span>
    </button>
    <button
      class="ctx-item"
      onclick={() => {
        pasteIntoActiveTerminal().finally(closeContextMenu);
      }}
    >
      <span class="codicon codicon-clippy ctx-icon"></span>Paste<span class="ctx-hint">Ctrl+V</span>
    </button>
    <div class="ctx-sep"></div>
    <button
      class="ctx-item"
      onclick={() => {
        clearActiveTerminal();
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-clear-all ctx-icon"></span>Clear Terminal<span class="ctx-hint"
        >Ctrl+L</span
      >
    </button>
    <button
      class="ctx-item"
      onclick={() => {
        rerunActiveTerminal();
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-run-all ctx-icon"></span>Rerun Last Command
    </button>
    <div class="ctx-sep"></div>
    <button
      class="ctx-item"
      onclick={() => {
        addTerminal();
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-add ctx-icon"></span>New Terminal
    </button>
    <button
      class="ctx-item"
      onclick={() => {
        splitTerminal('vertical');
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-split-horizontal ctx-icon"></span>Split Terminal Right
    </button>
    <button
      class="ctx-item"
      onclick={() => {
        splitTerminal('horizontal');
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-split-vertical ctx-icon"></span>Split Terminal Down
    </button>
    <div class="ctx-sep"></div>
    <button
      class="ctx-item ctx-danger"
      onclick={() => {
        killActiveTerminal();
        closeContextMenu();
      }}
    >
      <span class="codicon codicon-trash ctx-icon"></span>Kill Terminal
    </button>
  </div>
{/if}

<style>
  .icon-btn {
    background: transparent;
    border: none;
    color: var(--dim, #888);
    cursor: pointer;
    padding: 4px 5px;
    display: flex;
    align-items: center;
    border-radius: 4px;
    font-size: 14px;
    transition:
      color 0.15s,
      background 0.15s;
  }
  .icon-btn:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--fg, #ccc);
  }

  /* Terminal session tabs */
  .term-tab {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 2px 8px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 11px;
    white-space: nowrap;
    flex-shrink: 0;
    transition:
      background 0.12s,
      color 0.12s;
    border: 1px solid transparent;
  }
  .term-tab-active {
    background: rgba(255, 255, 255, 0.12);
    color: var(--fg, #ccc);
    border-color: rgba(255, 255, 255, 0.08);
  }
  .term-tab-inactive {
    color: var(--dim, #888);
  }
  .term-tab-inactive:hover {
    background: rgba(255, 255, 255, 0.07);
    color: var(--fg, #ccc);
  }
  .term-tab-label {
    max-width: 80px;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .term-status-dot {
    width: 6px;
    height: 6px;
    margin-right: 5px;
    border-radius: 50%;
    flex-shrink: 0;
    background: #858585;
  }
  .term-status-ready {
    background: #4ec9b0;
  }
  .term-status-error {
    background: #f48771;
  }
  .term-status-ended {
    background: #cca700;
  }
  .term-status-starting {
    background: #569cd6;
    animation: term-status-pulse 1.2s ease-in-out infinite;
  }
  @keyframes term-status-pulse {
    50% {
      opacity: 0.35;
    }
  }
  .term-close-btn {
    background: transparent;
    border: none;
    padding: 1px 2px;
    border-radius: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--dim, #888);
    cursor: pointer;
    opacity: 0;
    transition:
      opacity 0.1s,
      color 0.1s,
      background 0.1s;
    margin-left: 3px;
  }
  .term-tab:hover .term-close-btn,
  .term-tab-active .term-close-btn {
    opacity: 1;
  }
  .term-close-btn:hover {
    color: #f97583;
    background: rgba(255, 255, 255, 0.15);
  }

  /* Group separator — visual split indicator in tab bar */
  .group-sep {
    width: 1px;
    height: 18px;
    background: rgba(255, 255, 255, 0.18);
    margin: 0 5px;
    flex-shrink: 0;
    border-radius: 1px;
  }

  /* Group resizer between terminal panes */
  .group-resizer {
    background: rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
    transition: background 0.15s;
  }
  .group-resizer-col {
    width: 4px;
    cursor: col-resize;
  }
  .group-resizer-row {
    height: 4px;
    cursor: row-resize;
  }
  .group-resizer:hover {
    background: rgba(255, 255, 255, 0.2);
  }

  /* Group column focus ring */
  .group-col {
    position: relative;
  }
  .group-col-active {
    position: relative;
  }
  .group-focus-ring {
    position: absolute;
    inset: 0;
    pointer-events: none;
    z-index: 1;
    border: 1px solid transparent;
    transition: border-color 0.15s;
  }
  .ring-active {
    border-color: rgba(0, 122, 204, 0.5);
  }
  .ring-inactive {
    border-color: transparent;
  }

  /* Context menu */
  .ctx-menu {
    position: fixed;
    z-index: 9999;
    min-width: 210px;
    background: #252526;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    box-shadow:
      0 8px 32px rgba(0, 0, 0, 0.6),
      0 2px 8px rgba(0, 0, 0, 0.4);
    padding: 4px;
    display: flex;
    flex-direction: column;
    gap: 1px;
  }
  .ctx-item {
    background: transparent;
    border: none;
    color: #ccc;
    cursor: pointer;
    padding: 6px 10px;
    text-align: left;
    font-size: 13px;
    border-radius: 4px;
    display: flex;
    align-items: center;
    gap: 8px;
    transition:
      background 0.1s,
      color 0.1s;
    width: 100%;
  }
  .ctx-item:hover {
    background: rgba(255, 255, 255, 0.08);
    color: #fff;
  }
  .ctx-danger {
    color: #f97583;
  }
  .ctx-danger:hover {
    background: rgba(249, 117, 131, 0.12);
    color: #f97583;
  }
  .ctx-icon {
    font-size: 14px;
    width: 16px;
    flex-shrink: 0;
    opacity: 0.7;
  }
  .ctx-hint {
    margin-left: auto;
    font-size: 11px;
    color: #666;
    font-family: monospace;
  }
  .ctx-sep {
    height: 1px;
    background: rgba(255, 255, 255, 0.06);
    margin: 3px 0;
  }
</style>
