// Svelte 5 entry point — mounts the App component
import { mount } from 'svelte';
import App from './src/App.svelte';
import { eventBus } from './src/eventbus';
import { toggleSidebar, togglePanel } from './src/stores';
import { showOpenFileDialog, showOpenFolderDialog, sessionLoad, sendRpc } from './bridge';
import './src/app.css'; // Tailwind + global styles
import './xterm.css'; // Required canvas/viewport layout for the lazy terminal chunk

const startupParams = new URLSearchParams(window.location.search);
const startupBenchmark = startupParams.get('wizpStartupBenchmark') === '1';
const startupControlPort = startupParams.get('wizpControlPort') || '19876';
const sessionPath =
  startupParams.get('wizpSessionPath') ||
  (() => {
    const key = 'wizp:browserSessionId';
    try {
      const id = localStorage.getItem(key) || crypto.randomUUID();
      localStorage.setItem(key, id);
      return `/tmp/wizp-session-${id}.json`;
    } catch {
      return `/tmp/wizp-session-${crypto.randomUUID()}.json`;
    }
  })();
const startupOpenPaths = startupParams.getAll('wizpOpenPath').filter((path) => path.length > 0);
(window as any).__wizpControlPort = startupControlPort;
const startupImageBeacons: HTMLImageElement[] = [];

function startupMark(name: string) {
  if (!startupBenchmark) return;
  const params = new URLSearchParams({
    name,
    t: String(performance.now()),
    href: window.location.href,
  });
  const url = `http://127.0.0.1:${startupControlPort}/__startup-mark?${params.toString()}`;
  const image = new Image();
  image.decoding = 'async';
  image.src = `${url}&transport=image&nonce=${Date.now()}-${Math.random()}`;
  startupImageBeacons.push(image);
  if (startupImageBeacons.length > 32) startupImageBeacons.shift();
  fetch(`http://127.0.0.1:${startupControlPort}/__startup-mark`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, t: performance.now(), href: window.location.href }),
    keepalive: true,
  }).catch(() => {});
}

startupMark('moduleLoaded');

const runWhenIdle = (fn: () => void) => {
  if ('requestIdleCallback' in window) {
    (window as any).requestIdleCallback(fn, { timeout: 1200 });
  } else {
    window.setTimeout(fn, 150);
  }
};

// ─── Startup file/folder arguments and session restore ───
document.documentElement.style.setProperty('--panel-height', '200px');

type StartupWindow = Window & {
  __openFile?: (path: string) => unknown;
};
const startupWindow = window as StartupWindow;

function hasDirectoryListing(value: unknown): value is { files: unknown[] } {
  return (
    typeof value === 'object' && value !== null && 'files' in value && Array.isArray(value.files)
  );
}

async function openStartupPath(path: string): Promise<void> {
  const directory = await sendRpc('file/list', { path }).catch(() => null);
  if (hasDirectoryListing(directory)) {
    const method = path.endsWith('.code-workspace')
      ? 'workspace/openWorkspace'
      : 'workspace/setFolders';
    await sendRpc(method, { path }).catch(() => {});
    window.dispatchEvent(new Event('workspace:modified'));
    return;
  }
  await Promise.resolve(startupWindow.__openFile?.(path));
}

async function restoreStartupState(): Promise<void> {
  for (const path of startupOpenPaths) {
    try {
      await openStartupPath(path);
    } catch {
      // A single stale command-line path must not block later paths.
    }
  }
  try {
    const session = await sessionLoad(sessionPath).catch(() => null);
    if (session?.files?.length) {
      for (const path of session.files) {
        try {
          await Promise.resolve(startupWindow.__openFile?.(path));
        } catch {
          // A single stale session file must not block restoring other files.
        }
      }
    }
  } catch {
    // Session restore is best effort; startup continues with an empty session.
  }
}

// ─── Session save on close ───
window.addEventListener('beforeunload', () => {
  if (navigator.sendBeacon) {
    navigator.sendBeacon(
      '/api/rpc',
      JSON.stringify({
        jsonrpc: '2.0',
        id: Date.now(),
        method: 'session/save',
        params: { path: sessionPath },
      }),
    );
  }
});

// ─── Bridge window globals for legacy interop ───
(window as any).__openFileViaDialog = async (): Promise<string[]> => {
  try {
    return await showOpenFileDialog({ multiple: true });
  } catch {
    return [];
  }
};
(window as any).__openFolderViaDialog = async (): Promise<string | null> => {
  try {
    return await showOpenFolderDialog();
  } catch {
    return null;
  }
};
(window as any).__openSettings = () => eventBus.emit('settings:open');
(window as any).__toggleSidebar = () => toggleSidebar();
(window as any).__togglePanel = () => togglePanel();
(window as any).__newFile = () => eventBus.emit('file:new');
(window as any).__saveFile = () => eventBus.emit('file:save');
(window as any).__editorFocus = () => eventBus.emit('editor:focus');
(window as any).__newFolder = () => {
  const name = prompt('New folder name:');
  if (name) eventBus.emit('file:mkdir', name);
};

// ─── Mount Svelte app ───
// Remove static HTML layout so Svelte can take over completely
const staticWb = document.getElementById('workbench');
if (staticWb) staticWb.remove();
startupMark('staticWorkbenchRemoved');
const app = mount(App, { target: document.body });
startupMark('svelteMounted');
document.body.removeAttribute('data-svelte-boot');
runWhenIdle(() => {
  void restoreStartupState();
});
startupMark('bodyVisible');
requestAnimationFrame(() => {
  startupMark('firstRaf');
  requestAnimationFrame(() => startupMark('secondRafInteractive'));
});
runWhenIdle(() => {
  import('./legacy-bootstrap').catch(() => {});
});
export default app;
