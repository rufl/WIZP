// WIZP Bridge: JSON-RPC 2.0 communication with Zig daemon.
// Dual-mode: Bun (spawns wizp --daemon) or Browser (fetch to embedded HTTP server).

const IS_BUN = typeof (globalThis as any).Bun !== 'undefined';
const LOG_PREFIX = '[WIZP Bridge]';
const DEBUG_BRIDGE = localStorage.getItem('wizp:debugBridge') === '1';

function log(msg: string, ...args: any[]) {
  if (DEBUG_BRIDGE) console.log(LOG_PREFIX, msg, ...args); // craft-ignore: opt-in bridge diagnostics.
}
function warn(msg: string, ...args: any[]) {
  if (DEBUG_BRIDGE) console.warn(LOG_PREFIX, msg, ...args);
}
// Expose log for UI overlay
(globalThis as any).__wizp_log = log;

export function nativeControlCredentials(): { port: string; token: string } | null {
  if (typeof window === 'undefined') return null;
  const params = new URLSearchParams(window.location.search);
  const port = params.get('wizpControlPort') ?? '';
  const token = params.get('wizpControlToken') ?? '';
  return port && token ? { port, token } : null;
}

function rpcApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  return `http://127.0.0.1:${window.location.port}${path}`;
}
function fileApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  // File requests are served locally before daemon work is queued.
  return `http://127.0.0.1:${window.location.port}${path}`;
}
function taskApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  // Keep task execution off the renderer's 127.0.0.1 background-RPC pool.
  return `http://localhost:${window.location.port}${path}`;
}
function lspApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  return `http://127.0.0.1:${window.location.port}${path}`;
}
function searchApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  return `http://127.0.0.1:${window.location.port}${path}`;
}

function terminalApiUrl(path: string): string {
  if (typeof window === 'undefined' || window.location.hostname !== '127.0.0.1') return path;
  // Separate long-poll terminal traffic from files, LSP, and background RPCs.
  return `http://localhost:${window.location.port}${path}`;
}

export type NativeBackendStatus = {
  state: 'ready' | 'disconnected' | 'restarting' | 'unavailable';
  instanceId: string;
  generation: number;
  backendPid: number | null;
  restartAttempts: number;
};

export type NativeSessionSnapshot = {
  files?: Array<{ path: string }>;
  folders?: Array<{ path: string }>;
  editorSession?: Record<string, unknown>;
  [key: string]: unknown;
};

async function nativeControlRequest<T>(
  path: string,
  method: 'GET' | 'POST' = 'GET',
  body?: unknown,
): Promise<T | null> {
  const credentials = nativeControlCredentials();
  if (!credentials) return null;
  const response = await fetch(`http://127.0.0.1:${credentials.port}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-WIZP-Control-Token': credentials.token,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) {
    let detail = `Native control ${path} failed (${response.status})`;
    try {
      const payload: unknown = await response.json();
      if (
        payload &&
        typeof payload === 'object' &&
        'error' in payload &&
        typeof payload.error === 'string'
      )
        detail = payload.error;
    } catch {}
    throw new Error(detail);
  }
  return (await response.json()) as T;
}
export type AgentControlRoute =
  | 'start'
  | 'status'
  | 'events'
  | 'prompt'
  | 'cancel'
  | 'stop'
  | 'propose'
  | 'apply'
  | 'discard';

export async function agentControl(
  route: AgentControlRoute,
  method: 'GET' | 'POST' = 'GET',
  body?: unknown,
): Promise<unknown> {
  const result = await nativeControlRequest<unknown>(`/__agent/${route}`, method, body);
  if (result === null) throw new Error('The native WIZP agent bridge is unavailable.');
  return result;
}

let daemonIdentity: string | null = null;

export function getDaemonIdentity(): string | null {
  return daemonIdentity;
}

export async function getNativeBackendStatus(): Promise<NativeBackendStatus | null> {
  const status = await nativeControlRequest<NativeBackendStatus>('/__native-backend');
  if (status?.instanceId && Number.isInteger(status.generation)) {
    daemonIdentity = `${status.instanceId}:${status.generation}`;
  }
  return status;
}

export async function retryNativeBackend(): Promise<NativeBackendStatus | null> {
  const status = await nativeControlRequest<NativeBackendStatus>('/__native-backend-retry', 'POST');
  if (status?.instanceId && Number.isInteger(status.generation)) {
    daemonIdentity = `${status.instanceId}:${status.generation}`;
  }
  return status;
}

export async function injectNativeRecovery(
  action: 'disconnect' | 'reload-renderer',
): Promise<NativeBackendStatus | null> {
  const status = await nativeControlRequest<NativeBackendStatus>('/__native-recovery', 'POST', {
    action,
  });
  if (status?.instanceId && Number.isInteger(status.generation)) {
    daemonIdentity = `${status.instanceId}:${status.generation}`;
  }
  return status;
}

export async function openExternal(uri: string): Promise<boolean> {
  const url = new URL(uri);
  if (!['http:', 'https:', 'mailto:'].includes(url.protocol)) {
    throw new Error('Unsupported external URL scheme');
  }
  const credentials = nativeControlCredentials();
  if (!credentials) {
    window.open(url.href, '_blank', 'noopener,noreferrer');
    return true;
  }
  const response = await fetch(`http://127.0.0.1:${credentials.port}/__native-open-external`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-WIZP-Control-Token': credentials.token,
    },
    body: JSON.stringify({ url: url.href }),
  });
  if (!response.ok) throw new Error(`External opener failed (${response.status})`);
  return (await response.json()).opened === true;
}

interface RpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: any;
  error?: { code: number; message: string };
}

type PendingRpcRequest = {
  resolve: (v: any) => void;
  reject: (e: Error) => void;
  controller: AbortController;
  method: string;
};

let nextId = 1;
let daemonProcess: any = null;
const pendingRequests: Map<number, PendingRpcRequest> = new Map();
let readBuffer = '';
let rpcConnected = false;
let totalRpcCalls = 0;
let failedRpcCalls = 0;
let reconnectPromise: Promise<boolean> | null = null;
let daemonDisconnected = false;
let rpcConnectionGeneration = 0;
let terminalReadPauseDepth = 0;

const RPC_TIMEOUT_MS = 30000;
const RECONNECT_PROBE_TIMEOUT_MS = 1000;
const RECONNECT_MAX_ATTEMPTS = 5;
const RECONNECT_RETRY_DELAY_MS = 100;

type TransportError = Error & { __wizpTransportFailure?: boolean };
type ElectrobunSender = (request: string) => Promise<unknown>;

function getElectrobunSender(): ElectrobunSender | undefined {
  if (typeof window === 'undefined') return undefined;
  const windowRecord = window as unknown as Record<string, unknown>;
  const bridge = windowRecord.__wizp_electrobun;
  if (!bridge || typeof bridge !== 'object' || !('sendRpc' in bridge)) return undefined;
  const sender = bridge.sendRpc;
  return typeof sender === 'function' ? sender.bind(bridge) : undefined;
}

function emitDaemonEvent(type: 'wizpDaemonDisconnected' | 'wizpDaemonReconnected'): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(type));
  }
}

function markDaemonDisconnected(): void {
  if (!daemonDisconnected) {
    daemonDisconnected = true;
    rpcConnectionGeneration += 1;
    emitDaemonEvent('wizpDaemonDisconnected');
  }
}

function markDaemonConnected(): void {
  rpcConnected = true;
  if (daemonDisconnected) {
    daemonDisconnected = false;
    rpcConnectionGeneration += 1;
    emitDaemonEvent('wizpDaemonReconnected');
  }
}

function transportError(error: unknown): TransportError {
  const failure: TransportError = error instanceof Error ? error : new Error(String(error));
  failure.__wizpTransportFailure = true;
  return failure;
}

function isTransportError(error: unknown): error is TransportError {
  if (!(error instanceof Error) || !('__wizpTransportFailure' in error)) return false;
  return error.__wizpTransportFailure === true;
}

function consumeInjectedDaemonDisconnect(): boolean {
  if (typeof window === 'undefined') return false;
  const windowRecord = window as unknown as Record<string, unknown>;
  if (windowRecord.__wizpInjectDaemonDisconnect !== true) return false;
  windowRecord.__wizpInjectDaemonDisconnect = false;
  return true;
}

function waitForReconnectRetry(): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, RECONNECT_RETRY_DELAY_MS);
  return promise;
}

export function getRpcStats() {
  return { connected: rpcConnected, total: totalRpcCalls, failed: failedRpcCalls };
}

export async function startDaemon(): Promise<void> {
  if (IS_BUN) {
    if (daemonProcess) return;
    log('Starting Bun daemon...');
    const ZIG_BIN = '../zig-out/bin/wizp';
    const proc = (globalThis as any).Bun.spawn([ZIG_BIN, '--daemon'], {
      stdin: 'pipe',
      stdout: 'pipe',
      stderr: 'inherit',
    });
    daemonProcess = proc;
    const reader = proc.stdout.getReader();
    daemonReadLoopBun(reader);
    log('Bun daemon started (pid', proc.pid, ')');
  } else {
    log('Browser mode — daemon is embedded in Zig process, testing connection...');
    for (let i = 0; i < 10; i++) {
      try {
        await sendRpc('workspace/getFolders', {});
        rpcConnected = true;
        log('✅ Daemon connection OK');
        return;
      } catch (e: any) {
        if (i < 9) await new Promise((r) => setTimeout(r, 500));
        else {
          warn('⚠ Daemon not reachable after retries:', e.message);
          rpcConnected = false;
        }
      }
    }
  }
}

// Cleanup pending requests on page unload
if (typeof window !== 'undefined') {
  window.addEventListener('beforeunload', () => {
    const err = new Error('page unload');
    for (const [, pending] of pendingRequests) {
      pending.reject(err);
    }
    pendingRequests.clear();
  });
}

function failPendingTransportRequests(message: string): void {
  if (pendingRequests.size > 0) {
    const failure = transportError(new Error(message));
    for (const [id, pending] of pendingRequests) {
      pendingRequests.delete(id);
      failedRpcCalls++;
      pending.reject(failure);
    }
  }
  markDaemonDisconnected();
}
async function daemonReadLoopBun(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  const decoder = new TextDecoder();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        readBuffer += decoder.decode();
        parseResponses();
        failPendingTransportRequests('daemon disconnected: response stream closed');
        return;
      }
      readBuffer += decoder.decode(value, { stream: true });
      parseResponses();
    }
  } catch (error) {
    failPendingTransportRequests(
      `daemon disconnected: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

function parseResponses(): void {
  while (true) {
    const headerEnd = readBuffer.indexOf('\r\n\r\n');
    if (headerEnd === -1) break;
    const header = readBuffer.substring(0, headerEnd);
    const contentLengthMatch = header.match(/Content-Length: (\d+)/);
    if (!contentLengthMatch) break;
    const contentLength = parseInt(contentLengthMatch[1]);
    const bodyStart = headerEnd + 4;
    if (readBuffer.length < bodyStart + contentLength) break;
    const body = readBuffer.substring(bodyStart, bodyStart + contentLength);
    try {
      const response: RpcResponse = JSON.parse(body);
      // Only truncate buffer after successful parse
      readBuffer = readBuffer.substring(bodyStart + contentLength);
      const pending = pendingRequests.get(response.id);
      if (pending) {
        pendingRequests.delete(response.id);
        if (response.error) {
          pending.reject(new Error(response.error.message, { cause: response.error }));
        } else {
          pending.resolve(response.result);
        }
      }
    } catch (e) {
      console.error('WIZP bridge: failed to parse response:', e);
      // Advance past this message to avoid infinite loop on permanent parse failure
      readBuffer = readBuffer.substring(bodyStart + contentLength);
    }
  }
}

async function performRpc(
  method: string,
  params: unknown,
  countStats: boolean,
  timeoutMs = RPC_TIMEOUT_MS,
  rootFields?: Record<string, unknown>,
): Promise<unknown> {
  const id = nextId++;
  const requestGeneration = rpcConnectionGeneration;
  const body = rootFields
    ? { jsonrpc: '2.0', id, method, ...rootFields }
    : { jsonrpc: '2.0', id, method, params };
  if (countStats) totalRpcCalls++;

  if (consumeInjectedDaemonDisconnect()) {
    if (countStats) failedRpcCalls++;
    markDaemonDisconnected();
    throw transportError(new Error('daemon disconnected: injected failure'));
  }

  const electrobun = getElectrobunSender();
  if (electrobun) {
    try {
      return await electrobun(JSON.stringify(body));
    } catch (error) {
      if (countStats) failedRpcCalls++;
      throw transportError(error);
    }
  }

  const { promise, resolve, reject } = Promise.withResolvers<unknown>();
  const controller = new AbortController();
  pendingRequests.set(id, { resolve, reject, controller, method });

  const timeout = setTimeout(() => {
    controller.abort();
    pendingRequests.delete(id);
    if (countStats) failedRpcCalls++;
    reject(transportError(new Error(`RPC ${method} timed out after ${timeoutMs}ms`)));
  }, timeoutMs);

  fetch(
    (method.startsWith('terminal/')
      ? terminalApiUrl
      : method === 'search/text' || method === 'search/replace'
        ? searchApiUrl
        : method.startsWith('textDocument/') || method.startsWith('lsp/')
          ? lspApiUrl
          : method.startsWith('file/')
            ? fileApiUrl
            : method === 'tasks/run'
              ? taskApiUrl
              : rpcApiUrl)('/api/rpc'),
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
    },
  )
    .then(async (res) => {
      clearTimeout(timeout);
      pendingRequests.delete(id);
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        if (countStats) failedRpcCalls++;
        const failure = new Error(`RPC ${method} failed with ${res.status}: ${text.slice(0, 200)}`);
        reject(res.status >= 500 ? transportError(failure) : failure);
        return;
      }

      const json: unknown = await res.json();
      if (json && typeof json === 'object' && 'error' in json && json.error) {
        const rpcError = json.error;
        const message =
          rpcError &&
          typeof rpcError === 'object' &&
          'message' in rpcError &&
          typeof rpcError.message === 'string'
            ? rpcError.message
            : `RPC ${method} error`;
        if (countStats) failedRpcCalls++;
        reject(new Error(message, { cause: rpcError }));
        return;
      }
      resolve(json && typeof json === 'object' && 'result' in json ? json.result : undefined);
    })
    .catch((error: unknown) => {
      clearTimeout(timeout);
      pendingRequests.delete(id);
      if (error instanceof Error && error.name === 'AbortError') {
        return;
      }
      if (requestGeneration !== rpcConnectionGeneration) {
        reject(transportError(error));
        return;
      }
      if (countStats) {
        failedRpcCalls++;
        const message = error instanceof Error ? error.message : String(error);
        if (typeof document === 'undefined' || document.visibilityState !== 'hidden') {
          if (DEBUG_BRIDGE) console.error(`[WIZP Bridge] RPC ${method} ERROR:`, message);
        }
      }
      reject(transportError(error));
    });

  return promise;
}

async function reconnectDaemon(): Promise<boolean> {
  if (reconnectPromise) return reconnectPromise;

  const attempt = (async () => {
    for (let index = 0; index < RECONNECT_MAX_ATTEMPTS; index++) {
      if (index > 0) await waitForReconnectRetry();
      try {
        await performRpc('workspace/getFolders', {}, false, RECONNECT_PROBE_TIMEOUT_MS);
        markDaemonConnected();
        return true;
      } catch (error) {
        log(`Reconnect probe ${index + 1}/${RECONNECT_MAX_ATTEMPTS} failed`, error);
      }
    }
  })();

  reconnectPromise = attempt.finally(() => {
    reconnectPromise = null;
  });
  return reconnectPromise;
}
export function cancelPendingRpcRequests(exemptMethods: string[] = []): void {
  for (const [id, request] of pendingRequests) {
    if (
      request.method === 'terminal/read' ||
      request.method === 'search/text' ||
      request.method === 'search/replace' ||
      exemptMethods.includes(request.method)
    )
      continue;
    pendingRequests.delete(id);
    request.controller.abort();
    request.reject(new Error(`RPC ${request.method} cancelled for priority request`));
  }
}

export function pauseTerminalReads(): () => void {
  terminalReadPauseDepth += 1;
  let resumed = false;
  return () => {
    if (resumed) return;
    resumed = true;
    terminalReadPauseDepth = Math.max(0, terminalReadPauseDepth - 1);
  };
}

export async function waitForTerminalReadsIdle(): Promise<void> {
  while (terminalReadInFlight.size > 0) {
    await Promise.allSettled([...terminalReadInFlight.values()]);
  }
}

async function retryDaemonConnectionWithFailurePolicy(markFailure: boolean): Promise<boolean> {
  try {
    const nativeStatus = await retryNativeBackend();
    if (nativeStatus) {
      const connected = nativeStatus.state === 'ready';
      if (connected) markDaemonConnected();
      else if (markFailure) markDaemonDisconnected();
      return connected;
    }
  } catch (error) {
    log('Native backend retry failed', error);
  }
  const connected = await reconnectDaemon();
  if (connected) markDaemonConnected();
  else if (markFailure) markDaemonDisconnected();
  return connected;
}

export async function retryDaemonConnection(): Promise<boolean> {
  return retryDaemonConnectionWithFailurePolicy(true);
}

export async function sendRpc(method: string, params?: any): Promise<any> {
  try {
    const result = await performRpc(method, params, true);
    markDaemonConnected();
    return result;
  } catch (error) {
    if (!isTransportError(error)) throw error;

    markDaemonDisconnected();
    await reconnectDaemon();
    throw error;
  }
}

/** Send an optional RPC without reconnecting the whole daemon on timeout. */
export async function sendRpcBounded(method: string, params: any, timeoutMs: number): Promise<any> {
  return performRpc(method, params, true, timeoutMs);
}

export async function saveFile(path: string, content: string): Promise<boolean> {
  cancelPendingRpcRequests([
    'file/read',
    'file/list',
    'file/save',
    'workspace/getFolders',
    'workspace/setFolders',
  ]);
  if (nativeControlCredentials()) {
    const result = await nativeControlRequest<{ saved?: unknown }>('/__native-file-save', 'POST', {
      path,
      content,
    });
    if (result?.saved === true) return true;
    throw new Error('Native file save failed');
  }
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(fileApiUrl('/api/file-save'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'file/save', path, content }),
        signal: controller.signal,
      });
      const payload = await response.json();
      if (!response.ok || payload?.error || payload?.result !== true) {
        throw new Error(payload?.error?.message || `File save failed (${response.status})`);
      }
      return true;
    } catch (error) {
      lastError = error;
      const result = await sendRpcBounded('file/save', { path, content }, 5000).catch(() => null);
      if (result === true) return true;
      if (!(error instanceof Error && error.name === 'AbortError')) throw error;
      if (attempt < 2) await new Promise((resolve) => window.setTimeout(resolve, 50));
    } finally {
      window.clearTimeout(timeout);
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

export async function readFile(path: string, pauseTerminals = true): Promise<{ content: string }> {
  cancelPendingRpcRequests([
    'file/read',
    'file/list',
    'file/save',
    'workspace/getFolders',
    'workspace/setFolders',
  ]);
  const resumeTerminalReads = pauseTerminals ? pauseTerminalReads() : () => {};
  try {
    if (nativeControlCredentials()) {
      const result = await nativeControlRequest<{ content?: unknown }>(
        '/__native-file-read',
        'POST',
        { path },
      );
      return { content: String(result?.content ?? '') };
    }

    let lastError: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch(fileApiUrl('/api/file-read'), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'file/read', path }),
          signal: controller.signal,
        });
        const payload = await response.json();
        if (!response.ok || payload?.error) {
          throw new Error(payload?.error?.message || `File read failed (${response.status})`);
        }
        return { content: String(payload?.result?.content ?? '') };
      } catch (error) {
        lastError = error;
        if (attempt === 2 || !(error instanceof Error && error.name === 'AbortError')) throw error;
        await new Promise((resolve) => window.setTimeout(resolve, 50));
      } finally {
        window.clearTimeout(timeout);
      }
    }
    if (lastError instanceof Error && lastError.name === 'AbortError') {
      const result = await sendRpcBounded('file/read', { path }, 5000);
      if (result && typeof result === 'object' && 'content' in result) {
        return { content: String(result.content ?? '') };
      }
    }
    throw lastError instanceof Error ? lastError : new Error(String(lastError));
  } finally {
    resumeTerminalReads();
  }
}

/**
 * Send a JSON-RPC request whose application fields live at the envelope root.
 * Extension-host routes predate nested `params` and consume these fields there.
 */
export async function sendRpcFields(
  method: string,
  fields: Record<string, unknown> = {},
): Promise<unknown> {
  try {
    const result = await performRpc(method, fields, true, RPC_TIMEOUT_MS, fields);
    markDaemonConnected();
    return result;
  } catch (error) {
    if (!isTransportError(error)) throw error;

    markDaemonDisconnected();
    await reconnectDaemon();
    throw error;
  }
}

export async function terminalSpawn(options?: {
  shell?: string;
  cwd?: string;
  env?: Record<string, string>;
  injectFailure?: boolean;
}): Promise<{
  id: number;
  pid: number;
  shell?: string;
  cwd?: string;
  env?: Record<string, string>;
  backend?: string;
  renderer?: string;
  ghosttyAvailable?: boolean;
  ghosttyEnabled?: boolean;
  nativeRendererBridge?: boolean;
}> {
  cancelPendingRpcRequests(['terminal/spawn']);
  return sendRpc('terminal/spawn', options || {});
}

type TerminalReadResult = {
  data: string;
  eof?: boolean;
  exitKind?: 'running' | 'exited' | 'signaled' | 'unknown';
  exitCode?: number;
  exitSignal?: number;
  droppedBytes?: number;
};

const terminalReadInFlight = new Map<number | undefined, Promise<TerminalReadResult>>();

export async function terminalRead(id?: number): Promise<TerminalReadResult> {
  const existing = terminalReadInFlight.get(id);
  if (existing) return existing;

  while (terminalReadPauseDepth > 0) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 25));
  }
  const resumedExisting = terminalReadInFlight.get(id);
  if (resumedExisting) return resumedExisting;

  const pending = (async (): Promise<TerminalReadResult> => {
    try {
      const result = await sendRpcBounded('terminal/read', id ? { id } : {}, 5000);
      markDaemonConnected();
      return result || { data: '' };
    } catch (error) {
      if (!isTransportError(error)) throw error;
      void retryDaemonConnectionWithFailurePolicy(false);
      return { data: '' };
    }
  })();
  terminalReadInFlight.set(id, pending);
  try {
    return await pending;
  } finally {
    if (terminalReadInFlight.get(id) === pending) terminalReadInFlight.delete(id);
  }
}

const terminalInputQueues = new Map<number | undefined, Promise<unknown>>();

function assertTerminalIdentity(expectedIdentity: string | null): void {
  if (nativeControlCredentials() && expectedIdentity !== getDaemonIdentity()) {
    throw new Error('Terminal operation belongs to a stale daemon generation');
  }
}

function queueTerminalInput<T>(
  id: number | undefined,
  expectedIdentity: string | null,
  operation: () => Promise<T>,
): Promise<T> {
  const run = () => {
    assertTerminalIdentity(expectedIdentity);
    return operation();
  };
  const previous = terminalInputQueues.get(id);
  const pending = previous ? previous.then(run, run) : run();
  terminalInputQueues.set(id, pending);
  const release = () => {
    if (terminalInputQueues.get(id) === pending) terminalInputQueues.delete(id);
  };
  void pending.then(release, release);
  return pending;
}

export async function terminalWrite(data: string, id?: number): Promise<boolean> {
  const identity = getDaemonIdentity();
  return queueTerminalInput(id, identity, () =>
    sendRpcBounded('terminal/write', id ? { id, data } : { data }, 5000),
  );
}

export async function terminalRerun(
  command: string,
  id: number,
): Promise<{ written: boolean; bytes: number }> {
  const identity = getDaemonIdentity();
  return queueTerminalInput(id, identity, () => sendRpc('terminal/rerun', { id, command }));
}

export async function terminalResize(rows: number, cols: number, id?: number): Promise<boolean> {
  return sendRpc('terminal/resize', id ? { id, rows, cols } : { rows, cols });
}

export async function terminalKill(id: number): Promise<boolean> {
  return sendRpc('terminal/kill', { id });
}

export async function terminalActivate(id: number): Promise<boolean> {
  return sendRpc('terminal/activate', { id });
}

export async function terminalList(): Promise<number[]> {
  return sendRpc('terminal/list');
}

export async function ghosttyInfo(): Promise<{
  available: boolean;
  enabled: boolean;
  version: string;
  backend: string;
  ptyBackend?: string;
  renderer?: string;
  nativeRendererBridge?: boolean;
  rendererBridgePolicy?: string;
  runtimeLoaded?: boolean;
  lazyLoaded?: boolean;
  fallbackReason?: string;
  optInEnv?: string;
}> {
  return sendRpcBounded('ghostty/info', {}, 1000);
}

export async function ghosttyRendererBridge(): Promise<{
  policy: string;
  optInEnv: string;
  available: boolean;
  enabled: boolean;
  loaded: boolean;
  surfaceCreated: boolean;
  renderer: string;
  nativeRendererBridge: boolean;
  defaultRenderer: string;
  defaultPtyBackend: string;
  fallbackReason: string;
}> {
  return sendRpcBounded('ghostty/rendererBridge', {}, 1000);
}

export async function extensionUninstall(extensionId: string): Promise<boolean> {
  return sendRpc('extension/uninstall', { id: extensionId });
}

export async function stopDaemon(): Promise<void> {
  if (IS_BUN && daemonProcess) {
    daemonProcess.kill();
    daemonProcess = null;
  }
}

// ── Hub RPCs ──

export async function hubSearch(query: string): Promise<{ extensions: any[]; total: number }> {
  return sendRpc('hub/search', { query });
}

export async function hubInstall(
  namespace: string,
  name: string,
  version?: string,
): Promise<{ installed: { themes: number } }> {
  return sendRpc('hub/install', { namespace, name, version: version || 'latest' });
}

export async function hubList(): Promise<{ installed: any[] }> {
  return sendRpc('hub/list');
}

export async function hubUninstall(extensionId: string): Promise<boolean> {
  return sendRpc('hub/uninstall', { extensionId });
}

export async function hubToggle(extensionId: string, enabled: boolean): Promise<boolean> {
  return sendRpc('hub/toggle', { extensionId, enabled });
}

// ── Theme RPCs ──

export async function themeList(): Promise<{ themes: string[] }> {
  return sendRpc('theme/list');
}

export async function themeApply(name: string): Promise<any> {
  return sendRpc('theme/apply', { name });
}

// ── Native Dialogs (via Zig backend) ──

export async function showOpenFileDialog(options?: { multiple?: boolean }): Promise<string[]> {
  const res = await sendRpc('file/open-file-dialog', { multiple: options?.multiple ?? false });
  return res?.paths ?? [];
}

export async function showOpenFolderDialog(): Promise<string | null> {
  const res = await sendRpc('file/open-folder-dialog', {});
  return res?.path ?? null;
}

// ── Icon Theme RPCs ──

export async function iconThemeList(): Promise<{ iconThemes: string[] }> {
  return sendRpc('icon-theme/list');
}

export async function iconThemeApply(name: string): Promise<{ name: string; content: string }> {
  return sendRpc('icon-theme/apply', { name });
}

// ── Webview RPCs ──

export async function webviewList(): Promise<{
  panels: Array<{ id: string; title: string; html: string }>;
}> {
  return sendRpc('webview/list');
}

export async function webviewCreate(
  id: string,
  title: string,
  html: string = '',
): Promise<{ id: string; title: string; html: string }> {
  return sendRpc('webview/create', { id, title, html });
}

export async function webviewSetHtml(id: string, html: string): Promise<boolean> {
  return sendRpc('webview/setHtml', { id, html });
}

export async function webviewReveal(id: string): Promise<boolean> {
  return sendRpc('webview/reveal', { id });
}

// ── Extensions RPCs ──

export async function extensionsGetExtension(id: string): Promise<any> {
  return sendRpc('extensions/getExtension', { id });
}

// ── Git Blame ──

export async function gitBlame(
  file: string,
): Promise<Array<{ line: number; hash: string; author: string; date: string; summary: string }>> {
  return sendRpc('git/blame', { file });
}

// ── Indent Detection ──

export async function indentDetect(): Promise<{
  useSpaces: boolean;
  size: number;
  confidence: number;
}> {
  return sendRpc('indent/detect');
}

// ── Word Highlight ──

export async function wordHighlight(
  word: string,
): Promise<Array<{ line: number; col: number; len: number }>> {
  return sendRpc('word/highlight', { word });
}

// ── Folding ──

export async function foldRanges(
  uri: string,
): Promise<Array<{ start: number; end: number; level: number; folded: boolean }>> {
  return sendRpc('editor/foldRanges', { uri });
}

// ── Session ──

export async function sessionSave(path: string): Promise<boolean> {
  return sendRpc('session/save', { path });
}

export async function sessionLoad(
  path?: string,
): Promise<{ files: string[]; sidebarVisible: boolean }> {
  return sendRpc('session/load', { path: path || '/tmp/wizp-session' });
}

export async function loadNativeSession(): Promise<NativeSessionSnapshot | null> {
  await getNativeBackendStatus();
  return nativeControlRequest<NativeSessionSnapshot>('/__native-session');
}

export async function saveNativeSession(snapshot: NativeSessionSnapshot): Promise<boolean> {
  const result = await nativeControlRequest<{ saved: boolean }>(
    '/__native-session',
    'POST',
    snapshot,
  );
  return result?.saved === true;
}

// ── Config ──

export async function configGet(): Promise<{
  theme: string;
  tabWidth: number;
  useSpaces: boolean;
  formatOnSave: boolean;
  showWelcome: boolean;
}> {
  return sendRpc('config/get');
}

export async function configSet(key: string, value: string): Promise<boolean> {
  return sendRpc('config/set', { key, value });
}

// ── LSP Premium ──

export async function lspDefinition(uri: string, line: number, col: number): Promise<any> {
  return sendRpc('textDocument/definition', { uri, line, col });
}

export async function lspSignatureHelp(uri: string, line: number, col: number): Promise<any> {
  return sendRpc('textDocument/signatureHelp', { uri, line, col });
}

export async function lspCodeAction(uri: string, line: number, col: number): Promise<any> {
  return sendRpc('textDocument/codeAction', { uri, line, col });
}
