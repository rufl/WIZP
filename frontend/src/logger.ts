import { eventBus } from './eventbus.ts';

type LogCategory =
  | 'system'
  | 'editor'
  | 'terminal'
  | 'explorer'
  | 'hub'
  | 'event'
  | 'rpc'
  | 'layout'
  | 'keyboard';

const CAT_COLORS: Record<LogCategory, string> = {
  system: '#89d185',
  editor: '#569cd6',
  terminal: '#ce9178',
  explorer: '#4ec9b0',
  hub: '#c586c0',
  event: '#dcdcaa',
  rpc: '#9cdcfe',
  layout: '#d4d4d4',
  keyboard: '#f48771',
};

function truncate(s: string, max: number): string {
  return s.length > max ? s.substring(0, max) + '…' : s;
}

let logEl: HTMLElement | null = null;
let statusEl: HTMLElement | null = null;
const maxLines = 100;
const enabled = localStorage.getItem('wizp:debugLogger') === '1';

export function initLogger() {
  statusEl = document.getElementById('wizp-debug-status');
  logEl = document.getElementById('wizp-debug-log');
  log('system', 'Logger initialized');
  setStatus('Ready');
}

export function setStatus(msg: string, color?: string) {
  if (!statusEl) statusEl = document.getElementById('wizp-debug-status');
  if (statusEl) statusEl.innerHTML = `<span style="color:${color || '#89d185'}">●</span> ${msg}`;
}

export function log(cat: LogCategory, msg: string, data?: any) {
  if (!enabled) return;
  const t = new Date().toLocaleTimeString();
  const prefix = `[${t}][${cat}]`;
  const color = CAT_COLORS[cat] || '#ccc';

  // Console
  if (localStorage.getItem('wizp:debugConsole') === '1') {
    if (data !== undefined)
      console.log(prefix, msg, data); // craft-ignore: opt-in debug console.
    else console.log(prefix, msg); // craft-ignore: opt-in debug console.
  }

  // Debug overlay
  if (!logEl) logEl = document.getElementById('wizp-debug-log');
  if (!logEl) return;
  const line = document.createElement('div');
  line.style.cssText = `font-size:10px;color:${color};white-space:nowrap;overflow:hidden;text-overflow:ellipsis;`;
  line.textContent = `${prefix} ${msg}`;
  if (data !== undefined) line.title = JSON.stringify(data).substring(0, 200);
  logEl.appendChild(line);

  // Trim old lines
  while (logEl.children.length > maxLines) logEl.removeChild(logEl.firstChild!);
  logEl.scrollTop = logEl.scrollHeight;
}

export function error(cat: LogCategory, msg: string, err?: any) {
  console.error(`[${cat}] ${msg}`, err || '');
  if (!logEl) logEl = document.getElementById('wizp-debug-log');
  if (!logEl) return;
  const line = document.createElement('div');
  line.style.cssText =
    'font-size:10px;color:#f48771;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
  line.textContent = `[${new Date().toLocaleTimeString()}][${cat}] ERROR: ${msg}`;
  if (err) line.title = String(err).substring(0, 200);
  logEl.appendChild(line);
  while (logEl.children.length > maxLines) logEl.removeChild(logEl.firstChild!);
  logEl.scrollTop = logEl.scrollHeight;
  setStatus(`Error: ${msg}`, '#f48771');
}

// Wire eventBus events to logger
const origOn = eventBus.on.bind(eventBus);
eventBus.on = (event: string, cb: (...args: any[]) => void) => {
  origOn(event, cb);
};
// Intercept emit for logging
const origEmit = eventBus.emit.bind(eventBus);
eventBus.emit = (event: string, ...args: any[]) => {
  if (enabled && event !== '*' && !event.startsWith('wizp-debug')) {
    log('event', `${event}${args.length ? ': ' + truncate(JSON.stringify(args), 120) : ''}`);
  }
  origEmit(event, ...args);
};

export function wrapSendRpc(method: string, params?: any) {
  log('rpc', `→ ${method}`, params);
}

export function logRpcResponse(method: string, result: any) {
  if (result === undefined || result === null) log('rpc', `← ${method} → null`);
  else if (typeof result === 'object' && 'error' in result)
    error('rpc', `${method} error: ${result.error}`);
  else log('rpc', `← ${method} OK`);
}
