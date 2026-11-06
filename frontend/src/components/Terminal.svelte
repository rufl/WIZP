<script lang="ts">
  // Svelte 5 runes mode — xterm.js loaded lazily, terminal poll via blocking RPC
  import {
    ghosttyInfo,
    ghosttyRendererBridge,
    nativeControlCredentials,
    getDaemonIdentity,
    openExternal,
    terminalSpawn,
    terminalWrite,
    terminalRerun,
    terminalResize,
    terminalKill,
    terminalRead,
  } from '../../bridge';
  import { showToast } from '../stores';

  // terminal/read blocks for up to 20 ms in the daemon. Keep a slower idle
  // cadence so mounted terminals do not spin the native main loop when there
  // is no output; active output immediately starts the next read.
  const TERMINAL_IDLE_POLL_MS = 400;
  const TERMINAL_ERROR_RETRY_MS = 250;
  const NATIVE_POLL_TELEMETRY_INTERVAL_MS = 5000;

  function waitForNextPoll(delayMs: number) {
    return new Promise<void>((resolve) => window.setTimeout(resolve, delayMs));
  }

  function nativeSmokeControlPort(): string | null {
    const params = new URLSearchParams(window.location.search);
    if (!params.has('wizpNativeSmokeTerminals')) return null;
    return params.get('wizpControlPort');
  }

  const {
    onContextMenu,
    onFocus,
    onStatusChange,
    onSessionIdChange,
    existingSessionId = null,
    existingBackendIdentity = null,
    shell = undefined,
    cwd = undefined,
  }: {
    onContextMenu?: (e: MouseEvent) => void;
    onFocus?: () => void;
    onStatusChange?: (status: string) => void;
    onSessionIdChange?: (sessionId: number | null, identity: string | null) => void;
    existingSessionId?: number | null;
    existingBackendIdentity?: string | null;
    shell?: string;
    cwd?: string;
  } = $props();

  let container: HTMLElement;
  let terminal = $state<any>(null);
  let fitAddon = $state<any>(null);
  let searchAddon = $state<any>(null);
  let serializeAddon = $state<any>(null);
  let sessionId = $state<number | null>(null);
  let pollActive = $state(true);
  let startPollLoop: (() => void) | null = null;
  let sessionIdentity = $state<string | null>(null);
  let backendConnected = true;
  let statusBeforeDisconnect = 'starting';

  function ownsCurrentSession() {
    return (
      backendConnected &&
      (!nativeControlCredentials() ||
        (sessionIdentity !== null && sessionIdentity === getDaemonIdentity()))
    );
  }
  let commandDecorations = $state<any[]>([]);
  let terminalBackend = $state('probing');
  let terminalRenderer = $state('xterm.js');
  let ghosttyEnabled = $state(false);
  let ghosttyAvailable = $state(false);
  let ghosttyBridgeLoaded = $state(false);
  let ghosttyBridgePolicy = $state('opt-in-lazy');
  let ghosttyFallbackReason = $state('');
  let lastCommand = $state('');
  let lastRerunResult = $state('not-run');
  let inputBuffer = '';
  let lifecycleStatus = $state('starting');
  let renderedBytes = $state(0);
  let successfulEmptyReads = $state(0);
  let terminalPollLoopIterations = $state(0);
  let terminalDataReadCount = $state(0);
  let lastPollTelemetryAt = 0;
  let totalDroppedBytes = $state(0);
  let lastDetectedLink = $state('');
  let lastDetectedPath = $state('');
  let lastLinkActivation = $state<{
    uri: string;
    source: 'pointer' | 'keyboard';
    count: number;
  } | null>(null);
  let lastPaste = $state<{
    source: 'native-clipboard' | 'clipboard-api';
    characters: number;
    utf8Bytes: number;
    lines: number;
  } | null>(null);
  let clipboardError = $state('');
  let spawnError = $state<{ code: number | null; message: string } | null>(null);
  let processAnnouncement = $state('');
  let nativePasteListener: ((event: ClipboardEvent) => void) | null = null;
  const componentId = `terminal-${Math.random().toString(36).slice(2)}`;
  const telemetryImages: HTMLImageElement[] = [];

  function setLifecycleStatus(status: string) {
    lifecycleStatus = status;
    onStatusChange?.(status);
  }

  function clearProcessAnnouncement() {
    processAnnouncement = '';
  }

  function announceProcessExit(message: string) {
    if (!processAnnouncement) processAnnouncement = message;
  }

  function fitAndRefresh() {
    try {
      fitAddon?.fit();
      if (terminal && terminal.rows > 0) terminal.refresh(0, terminal.rows - 1);
    } catch {
      // xterm refresh can race terminal disposal during panel teardown.
    }
  }

  function sendTerminalPollTelemetry(force = false) {
    const controlPort = nativeSmokeControlPort();
    if (!controlPort) return;
    const now = Date.now();
    if (!force && now - lastPollTelemetryAt < NATIVE_POLL_TELEMETRY_INTERVAL_MS) return;
    lastPollTelemetryAt = now;
    const payload = {
      componentId,
      sessionId,
      status: lifecycleStatus,
      loopIterations: terminalPollLoopIterations,
      successfulEmptyReads,
      dataReadCount: terminalDataReadCount,
      renderedBytes,
      idlePollDelayMs: TERMINAL_IDLE_POLL_MS,
      errorRetryDelayMs: TERMINAL_ERROR_RETRY_MS,
    };
    const params = new URLSearchParams(
      Object.entries(payload).map(([key, value]) => [key, String(value ?? '')]),
    );
    params.set('nonce', `${now}-${Math.random()}`);
    const url = `http://127.0.0.1:${controlPort}/__native-terminal-telemetry?${params.toString()}`;
    const image = new Image();
    image.src = url;
    telemetryImages.push(image);
    if (telemetryImages.length > 16) telemetryImages.shift();
    fetch(`http://127.0.0.1:${controlPort}/__native-terminal-telemetry`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).catch(() => {});
  }

  function cleanTerminalBytes(bytes: Uint8Array) {
    let length = 0;
    for (const byte of bytes) {
      // Preserve ANSI and printable bytes while filtering stray C0 bytes in place.
      const allowedControl = byte === 8 || byte === 9 || byte === 10 || byte === 13 || byte === 27;
      if (byte >= 32 || allowedControl) bytes[length++] = byte;
    }
    return bytes.subarray(0, length);
  }

  function normalizeTerminalPath(raw: string) {
    const token = raw.replace(/[),.;]+$/, '');
    const withoutLocation = token.replace(/:\d+(?::\d+)?$/, '');
    if (withoutLocation.startsWith('file:///')) {
      try {
        return decodeURIComponent(new URL(withoutLocation).pathname);
      } catch {
        return '';
      }
    }
    return withoutLocation;
  }

  function findLocalPathLinks(text: string) {
    const links: Array<{ raw: string; path: string; start: number }> = [];
    const pattern = /(?:^|[\s("'`])((?:file:\/\/\/|\.\/|\.\.\/|\/(?!\/))[^\s"'`<>()]+)/g;
    for (const match of text.matchAll(pattern)) {
      const raw = match[1].replace(/[),.;]+$/, '');
      const start = (match.index ?? 0) + match[0].indexOf(match[1]);
      const path = normalizeTerminalPath(raw);
      if (path) links.push({ raw, path, start });
    }
    return links;
  }

  function rememberTerminalLink(bytes: Uint8Array) {
    const text = new TextDecoder().decode(bytes);
    const matches = text.match(/https?:\/\/\S+/g);
    if (matches?.length) {
      const raw = matches[matches.length - 1].split('\u001b', 1)[0];
      lastDetectedLink = raw.replace(/[),.;'"]+$/, '');
    }
    const paths = findLocalPathLinks(text);
    if (paths.length) lastDetectedPath = paths[paths.length - 1].path;
  }

  function activateTerminalLink(event: Event, uri: string, source: 'pointer' | 'keyboard') {
    event.preventDefault();
    const count = (lastLinkActivation?.count ?? 0) + 1;
    lastLinkActivation = { uri, source, count };

    let destination = uri;
    const controlPort = nativeSmokeControlPort();
    if (controlPort) {
      try {
        const local = new URL(uri);
        if (
          local.hostname === '127.0.0.1' &&
          local.port === controlPort &&
          local.pathname === '/__native-terminal-link'
        ) {
          local.searchParams.set('activation', source);
          destination = local.toString();
        }
      } catch {
        // Invalid links are rejected by the xterm link provider before this callback.
      }
    }
    void openExternal(destination).catch((error) => {
      showToast(error instanceof Error ? error.message : 'Unable to open terminal link', 'error');
    });
  }

  function activateTerminalPath(event: Event, path: string, source: 'pointer' | 'keyboard') {
    event.preventDefault();
    const count = (lastLinkActivation?.count ?? 0) + 1;
    lastLinkActivation = { uri: path, source, count };
    const openFile = (window as any).__openFile;
    if (typeof openFile === 'function') {
      void Promise.resolve(openFile(path)).catch(() => {});
    }
  }

  // Exposed methods — Panel calls these via bind:this
  export function clear() {
    terminal?.clear();
    // Also send Ctrl+L to the shell, targeting this specific session
    if (sessionId !== null && isInputEnabled())
      void terminalWrite('\x0c', sessionId).catch(() => {});
  }

  export function focus() {
    terminal?.focus();
  }

  export function resumePolling() {
    if (sessionId === null || lifecycleStatus === 'exited' || lifecycleStatus === 'killed') return;
    pollActive = true;
    startPollLoop?.();
  }

  export async function sendText(text: string): Promise<boolean> {
    if (sessionId !== null && isInputEnabled()) {
      lastCommand = text.trim();
      inputBuffer = '';
      markCommandDecoration(text);
      try {
        const written = await terminalWrite(text + '\n', sessionId);
        resumePolling();
        return written;
      } catch {
        resumePolling();
        return false;
      }
    }
    return false;
  }

  export async function rerunLastCommand() {
    if (!lastCommand || sessionId === null || lifecycleStatus !== 'ready' || !ownsCurrentSession())
      return '';
    markCommandDecoration(lastCommand);
    try {
      const result = await terminalRerun(lastCommand, sessionId);
      if (!result?.written || result.bytes !== new TextEncoder().encode(lastCommand).length) {
        throw new Error('terminal rerun did not confirm the complete command');
      }
      lastRerunResult = 'written';
      return lastCommand;
    } catch {
      lastRerunResult = 'failed';
      return '';
    }
  }

  export function getLifecycleStatus() {
    return lifecycleStatus;
  }
  export function recoverAfterReconnect() {
    if (nativeControlCredentials() && sessionIdentity !== getDaemonIdentity()) return false;
    backendConnected = true;
    if (lifecycleStatus === 'disconnected') {
      setLifecycleStatus(
        statusBeforeDisconnect === 'starting' || statusBeforeDisconnect === 'ready'
          ? statusBeforeDisconnect
          : 'ready',
      );
    }
    if (sessionId !== null && lifecycleStatus !== 'exited' && lifecycleStatus !== 'killed') {
      pollActive = true;
      startPollLoop?.();
    }
    return isInputEnabled();
  }

  export function getLastCommand() {
    return lastCommand;
  }

  export function getLastRerunResult() {
    return lastRerunResult;
  }

  export function getLastPaste() {
    return lastPaste;
  }

  export function getClipboardError() {
    return clipboardError;
  }

  export function getSpawnError() {
    return spawnError;
  }

  export function getDroppedBytes() {
    return totalDroppedBytes;
  }

  export function getLastLinkActivation() {
    return lastLinkActivation;
  }

  export function getLinkTarget() {
    if (!terminal || !lastDetectedLink) return null;
    const buffer = terminal.buffer?.active;
    if (!buffer) return null;
    for (let row = buffer.baseY; row < buffer.baseY + terminal.rows; row += 1) {
      const text = buffer.getLine(row)?.translateToString(true) ?? '';
      const column = text.indexOf(lastDetectedLink);
      if (column >= 0) {
        const rect = container.getBoundingClientRect();
        return {
          uri: lastDetectedLink,
          row: row - buffer.baseY,
          column,
          length: lastDetectedLink.length,
          x:
            rect.left +
            ((column + Math.min(lastDetectedLink.length / 2, 12)) / terminal.cols) * rect.width,
          y: rect.top + ((row - buffer.baseY + 0.5) / terminal.rows) * rect.height,
        };
      }
    }
    return null;
  }

  export function getPathTarget() {
    return lastDetectedPath || null;
  }

  export function getSessionId() {
    return sessionId;
  }

  export function isInputEnabled() {
    return ownsCurrentSession() && (lifecycleStatus === 'starting' || lifecycleStatus === 'ready');
  }

  function handleTerminalData(data: string) {
    if (data.includes('\r')) {
      const command = inputBuffer.trim();
      if (command) lastCommand = command;
      inputBuffer = '';
    } else if (data === '\u007f' || data === '\b') {
      inputBuffer = inputBuffer.slice(0, -1);
    } else if (data === '\u0003' || data === '\u000c') {
      inputBuffer = '';
    } else if (!data.includes('\u001b') && /^[\x20-\x7e]+$/.test(data)) {
      inputBuffer += data;
    }
    if (sessionId !== null && isInputEnabled()) {
      void terminalWrite(data, sessionId).catch(() => {});
    }
  }

  function markCommandDecoration(command: string) {
    const marker = terminal?.registerMarker?.(0);
    let decoration: any = null;
    if (marker && terminal?.registerDecoration) {
      decoration = terminal.registerDecoration({ marker, x: 0, width: 1, layer: 'top' });
      decoration?.onRender?.((element: HTMLElement) => {
        element.classList.add('terminal-command-decoration');
        element.title = command;
      });
    }
    commandDecorations = [
      ...commandDecorations,
      { command, line: marker?.line ?? null, decorated: decoration !== null },
    ];
  }

  export function getCommandDecorations() {
    return commandDecorations;
  }

  export function getSelection() {
    return terminal?.getSelection?.() ?? '';
  }

  export function findNext(query: string) {
    return searchAddon?.findNext?.(query, { decorations: true }) ?? false;
  }

  export function serializeBuffer() {
    return serializeAddon?.serialize?.() ?? '';
  }

  function recordPaste(text: string, source: 'native-clipboard' | 'clipboard-api') {
    const normalized = text.replace(/\r\n/g, '\n');
    lastPaste = {
      source,
      characters: Array.from(normalized).length,
      utf8Bytes: new TextEncoder().encode(normalized).length,
      lines: normalized.split('\n').length,
    };
    clipboardError = '';
    return normalized;
  }

  export async function pasteText(
    text: string,
    source: 'native-clipboard' | 'clipboard-api' = 'clipboard-api',
  ) {
    if (text && sessionId !== null && isInputEnabled()) {
      const normalized = text.replace(/\r\n/g, '\n');
      await terminalWrite(`\u001b[200~${normalized}\u001b[201~`, sessionId);
      recordPaste(normalized, source);
      terminal?.focus();
    }
  }

  async function pasteNativeClipboard() {
    const credentials = nativeControlCredentials();
    if (!credentials) {
      clipboardError = 'Native clipboard bridge is unavailable';
      return;
    }
    try {
      const response = await fetch(`http://127.0.0.1:${credentials.port}/__native-clipboard-read`, {
        method: 'POST',
        headers: { 'X-WIZP-Control-Token': credentials.token },
      });
      if (!response.ok) throw new Error(`Native clipboard read failed (${response.status})`);
      const payload = await response.json();
      await pasteText(String(payload?.text ?? ''), 'native-clipboard');
    } catch (error) {
      clipboardError = error instanceof Error ? error.message : 'Native clipboard read failed';
    }
  }

  export function blur() {
    terminal?.blur();
  }

  export function kill() {
    pollActive = false;
    if (sessionId !== null) {
      if (ownsCurrentSession()) void terminalKill(sessionId).catch(() => {});
      sessionId = null;
      onSessionIdChange?.(null, sessionIdentity);
    }
    setLifecycleStatus('killed');
    announceProcessExit('Process killed.');
    terminal?.write('\r\n\x1b[90m[Process killed]\x1b[0m\r\n');
  }

  $effect(() => {
    let disposed = false;
    let resizeObserver: ResizeObserver | null = null;
    let pollLoopRunning = false;
    const runPollLoop = () => {
      if (pollLoopRunning || !pollActive || sessionId === null) return;
      pollLoopRunning = true;
      void (async () => {
        try {
          while (pollActive && sessionId !== null) {
            if (!ownsCurrentSession()) {
              await waitForNextPoll(TERMINAL_ERROR_RETRY_MS);
              continue;
            }
            try {
              const sid = sessionId;
              const j = await terminalRead(sid);
              if (disposed || !pollActive || sessionId !== sid || !ownsCurrentSession()) continue;
              terminalPollLoopIterations += 1;
              totalDroppedBytes += Math.max(0, Number(j.droppedBytes) || 0);
              if (j.data && j.data.length > 0) {
                terminalDataReadCount += 1;
                const bin = atob(j.data);
                const arr = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                const clean = cleanTerminalBytes(arr);
                if (clean.length > 0) {
                  rememberTerminalLink(clean);
                  await new Promise<void>((resolve) => {
                    terminal.write(clean, () => {
                      renderedBytes += clean.length;
                      if (lifecycleStatus === 'starting') setLifecycleStatus('ready');
                      resolve();
                    });
                  });
                }
              }
              if (j.eof) {
                pollActive = false;
                setLifecycleStatus('exited');
                const exitLabel =
                  j.exitKind === 'signaled'
                    ? `signal ${j.exitSignal ?? '?'}`
                    : `code ${j.exitCode ?? '?'}`;
                announceProcessExit(`Process exited with ${exitLabel}.`);
                terminal?.write(`\r\n\x1b[90m[Process exited: ${exitLabel}]\x1b[0m\r\n`);
                break;
              }
              if (!j.data) {
                successfulEmptyReads += 1;
                await waitForNextPoll(TERMINAL_IDLE_POLL_MS);
              }
              sendTerminalPollTelemetry();
            } catch {
              await waitForNextPoll(TERMINAL_ERROR_RETRY_MS);
              sendTerminalPollTelemetry();
            }
          }
        } finally {
          pollLoopRunning = false;
        }
      })();
    };
    const pollWatchdog = window.setInterval(() => {
      if (
        sessionId !== null &&
        pollActive &&
        lifecycleStatus !== 'exited' &&
        lifecycleStatus !== 'killed' &&
        !pollLoopRunning
      ) {
        runPollLoop();
      }
    }, 500);
    startPollLoop = runPollLoop;
    const onDisconnected = () => {
      if (backendConnected) statusBeforeDisconnect = lifecycleStatus;
      backendConnected = false;
      setLifecycleStatus('disconnected');
    };
    const onReconnected = () => {
      if (nativeControlCredentials() && sessionIdentity !== getDaemonIdentity()) {
        pollActive = false;
        return;
      }
      backendConnected = true;
      setLifecycleStatus(statusBeforeDisconnect);
      if (sessionId !== null && lifecycleStatus !== 'exited' && lifecycleStatus !== 'killed') {
        pollActive = true;
        runPollLoop();
      }
    };
    window.addEventListener('wizpDaemonDisconnected', onDisconnected);
    window.addEventListener('wizpDaemonReconnected', onReconnected);
    clearProcessAnnouncement();
    (async () => {
      const [{ Terminal }, { FitAddon }, { SearchAddon }, { WebLinksAddon }, { SerializeAddon }] =
        await Promise.all([
          import('@xterm/xterm'),
          import('@xterm/addon-fit'),
          import('@xterm/addon-search'),
          import('@xterm/addon-web-links'),
          import('@xterm/addon-serialize'),
        ]);
      if (disposed) return;
      const focusNewSession = existingSessionId === null;

      terminal = new Terminal({
        cursorBlink: true,
        cursorStyle: 'bar',
        fontSize: 14,
        fontFamily: "'Cascadia Code', 'Fira Code', 'JetBrains Mono', 'Source Code Pro', monospace",
        theme: {
          background: '#1e1e1e',
          foreground: '#cccccc',
          cursor: '#ffffff',
          selectionBackground: '#264f78',
        },
        allowProposedApi: true,
      });
      fitAddon = new FitAddon();
      searchAddon = new SearchAddon();
      serializeAddon = new SerializeAddon();
      terminal.loadAddon(fitAddon);
      terminal.loadAddon(searchAddon);
      terminal.loadAddon(serializeAddon);
      terminal.loadAddon(
        new WebLinksAddon((event: MouseEvent, uri: string) => {
          activateTerminalLink(event, uri, 'pointer');
        }),
      );
      terminal.registerLinkProvider({
        provideLinks: (bufferLineNumber: number, callback: (links: any[]) => void) => {
          const text =
            terminal.buffer.active.getLine(bufferLineNumber - 1)?.translateToString(true) ?? '';
          const links = findLocalPathLinks(text).map(({ raw, path, start }) => ({
            range: {
              start: { x: start + 1, y: bufferLineNumber },
              end: { x: start + raw.length, y: bufferLineNumber },
            },
            text: raw,
            activate: (event: Event) => activateTerminalPath(event, path, 'pointer'),
          }));
          callback(links);
        },
      });
      terminal.open(container);
      nativePasteListener = (event: ClipboardEvent) => {
        const text = event.clipboardData?.getData('text/plain') ?? '';
        if (!text || sessionId === null || !isInputEnabled()) return;
        event.preventDefault();
        event.stopPropagation();
        void pasteText(text, 'native-clipboard');
      };
      container.addEventListener('paste', nativePasteListener, true);
      // The panel is lazily mounted below a flex splitter. Fit once after the
      // committed layout as well as immediately, otherwise xterm can observe
      // a zero-height host during the first mount and remain visually empty.
      fitAndRefresh();
      requestAnimationFrame(fitAndRefresh);
      requestAnimationFrame(() => requestAnimationFrame(fitAndRefresh));

      // Auto-resize on panel resize
      resizeObserver = new ResizeObserver(() => {
        fitAndRefresh();
      });
      resizeObserver.observe(container);

      try {
        const info = await ghosttyInfo().catch(() => null);
        if (info) {
          terminalBackend = info.ptyBackend || info.backend || 'zigpty';
          terminalRenderer = info.renderer || 'xterm.js';
          ghosttyEnabled = !!info.enabled;
          ghosttyAvailable = !!info.available;
          ghosttyBridgePolicy = info.rendererBridgePolicy || 'opt-in-lazy';
          ghosttyBridgeLoaded = !!info.nativeRendererBridge;
          ghosttyFallbackReason = info.fallbackReason || '';
          if (info.enabled) {
            const bridge = await ghosttyRendererBridge().catch(() => null);
            if (bridge) {
              ghosttyBridgePolicy = bridge.policy || ghosttyBridgePolicy;
              ghosttyBridgeLoaded = !!bridge.loaded;
              ghosttyFallbackReason = bridge.fallbackReason || ghosttyFallbackReason;
            }
          }
        }

        if (disposed) return;
        sessionIdentity = getDaemonIdentity();
        if (!backendConnected || (nativeControlCredentials() && sessionIdentity === null)) return;
        if (existingSessionId !== null) {
          if (existingBackendIdentity !== sessionIdentity) return;
          sessionId = existingSessionId;
          onSessionIdChange?.(sessionId, sessionIdentity);
          setLifecycleStatus('ready');
        } else {
          const injectFailure =
            nativeSmokeControlPort() !== null &&
            (window as any).__wizpInjectTerminalSpawnFailure === true;
          if (injectFailure) (window as any).__wizpInjectTerminalSpawnFailure = false;
          const r = await terminalSpawn({ shell, cwd, injectFailure });
          if (disposed || !backendConnected || sessionIdentity !== getDaemonIdentity()) {
            if (backendConnected && sessionIdentity === getDaemonIdentity()) {
              void terminalKill(r.id).catch(() => {});
            }
            return;
          }
          sessionId = r.id;
          onSessionIdChange?.(sessionId, sessionIdentity);
          terminalBackend = r.backend || terminalBackend;
          terminalRenderer = r.renderer || terminalRenderer;
          ghosttyEnabled = !!r.ghosttyEnabled;
          ghosttyAvailable = !!r.ghosttyAvailable;
          ghosttyBridgeLoaded = !!r.nativeRendererBridge || ghosttyBridgeLoaded;
        }
        // Always send resize/write to this specific session id
        void terminalResize(terminal.rows, terminal.cols, sessionId).catch(() => {});
        pollActive = true;
        startPollLoop?.();
      } catch (error) {
        if (disposed) return;
        const cause = error instanceof Error ? error.cause : null;
        spawnError = {
          code:
            cause && typeof cause === 'object' && 'code' in cause && typeof cause.code === 'number'
              ? cause.code
              : null,
          message: error instanceof Error ? error.message : 'Terminal spawn failed',
        };
        setLifecycleStatus('error');
        terminal?.write(
          '\r\n\x1b[31mFailed to spawn terminal. Use Retry Terminal Spawn.\x1b[0m\r\n',
        );
      }

      terminal.onData(handleTerminalData);
      terminal.onResize(({ cols, rows }: { cols: number; rows: number }) => {
        if (sessionId !== null && isInputEnabled()) {
          void terminalResize(rows, cols, sessionId).catch(() => {});
        }
      });

      // Ctrl+L → clear
      terminal.attachCustomKeyEventHandler((e: KeyboardEvent) => {
        if (e.type !== 'keydown') return true;
        if (e.ctrlKey && e.shiftKey && e.key.toLowerCase() === 'v') {
          e.preventDefault();
          pasteNativeClipboard();
          return false;
        }
        if (e.ctrlKey && e.key === 'Enter' && (lastDetectedLink || lastDetectedPath)) {
          if (lastDetectedLink) activateTerminalLink(e, lastDetectedLink, 'keyboard');
          else activateTerminalPath(e, lastDetectedPath, 'keyboard');
          return false;
        }
        if (e.ctrlKey && e.key === 'l') {
          e.preventDefault();
          clear();
          return false;
        }
        return true;
      });

      if (focusNewSession && !disposed) terminal.focus();
    })();

    return () => {
      disposed = true;
      pollActive = false;
      clearInterval(pollWatchdog);
      startPollLoop = null;
      resizeObserver?.disconnect();
      window.removeEventListener('wizpDaemonDisconnected', onDisconnected);
      window.removeEventListener('wizpDaemonReconnected', onReconnected);
      sendTerminalPollTelemetry(true);
      // Keep the backend PTY alive across renderer teardown; explicit kill()
      // owns terminal closure and the persisted layout reconnects by backend id.
      if (nativePasteListener) {
        container.removeEventListener('paste', nativePasteListener, true);
        nativePasteListener = null;
      }
      if (terminal) {
        terminal.dispose();
        terminal = null;
      }
    };
  });
</script>

<div class="terminal-shell">
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div
    bind:this={container}
    class="terminal-wrapper"
    role="application"
    aria-label={`Terminal (${terminalBackend}, ${terminalRenderer})`}
    data-terminal-backend={terminalBackend}
    data-terminal-renderer={terminalRenderer}
    data-terminal-session-id={sessionId ?? ''}
    data-terminal-backend-identity={sessionIdentity ?? ''}
    data-terminal-status={lifecycleStatus}
    data-terminal-input-enabled={isInputEnabled() ? 'true' : 'false'}
    data-terminal-rows={terminal?.rows ?? 0}
    data-terminal-cols={terminal?.cols ?? 0}
    data-terminal-rendered-bytes={renderedBytes}
    data-terminal-poll-loop-iterations={terminalPollLoopIterations}
    data-terminal-empty-reads={successfulEmptyReads}
    data-terminal-data-read-count={terminalDataReadCount}
    data-terminal-dropped-bytes={totalDroppedBytes}
    data-terminal-last-link={lastDetectedLink}
    data-terminal-last-path={lastDetectedPath}
    data-terminal-idle-poll-ms={TERMINAL_IDLE_POLL_MS}
    data-ghostty-enabled={ghosttyEnabled ? 'true' : 'false'}
    data-ghostty-available={ghosttyAvailable ? 'true' : 'false'}
    data-ghostty-bridge-loaded={ghosttyBridgeLoaded ? 'true' : 'false'}
    data-ghostty-bridge-policy={ghosttyBridgePolicy}
    data-ghostty-fallback={ghosttyFallbackReason}
    oncontextmenu={(e) => {
      e.preventDefault();
      onContextMenu?.(e);
    }}
    onmousedown={(e) => {
      // Intercept mouse clicks: call onFocus
      onFocus?.();
      // Prevent middle-click paste if causing issues
      if (e.button === 1) e.preventDefault();
    }}
  ></div>
  <div
    class="visually-hidden"
    role="status"
    aria-live="polite"
    aria-atomic="true"
    aria-relevant="text"
  >
    {processAnnouncement}
  </div>
  {#if (lastDetectedLink || lastDetectedPath) && isInputEnabled()}
    <button
      class="terminal-link-action"
      type="button"
      title={lastDetectedLink ? 'Open Detected Terminal Link' : 'Open Detected Terminal Path'}
      aria-label={lastDetectedLink ? 'Open Detected Terminal Link' : 'Open Detected Terminal Path'}
      onclick={(event) =>
        lastDetectedLink
          ? activateTerminalLink(event, lastDetectedLink, 'pointer')
          : activateTerminalPath(event, lastDetectedPath, 'pointer')}
    >
      <span class="codicon codicon-link-external" aria-hidden="true"></span>
    </button>
  {/if}
</div>

<style>
  .terminal-shell {
    position: relative;
    width: 100%;
    height: 100%;
    min-width: 0;
    min-height: 0;
  }
  .terminal-wrapper {
    width: 100%;
    height: 100%;
    min-width: 0;
    min-height: 0;
    background: #1e1e1e;
    overflow: hidden;
    :global(.xterm) {
      padding: 4px;
    }
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
  .terminal-link-action {
    position: absolute;
    inset-block-start: 6px;
    inset-inline-end: 14px;
    z-index: 3;
    display: grid;
    width: 26px;
    height: 26px;
    place-items: center;
    border: 1px solid rgb(255 255 255 / 16%);
    border-radius: 4px;
    color: #cccccc;
    background: #252526;
  }
  .terminal-link-action:hover {
    color: #ffffff;
    background: #2f3031;
  }
  .terminal-link-action:focus-visible {
    outline: 2px solid #007fd4;
    outline-offset: 1px;
  }
  .terminal-wrapper :global(.terminal-command-decoration) {
    width: 3px;
    height: 100%;
    background: #4ec9b0;
    opacity: 0.85;
  }
</style>
