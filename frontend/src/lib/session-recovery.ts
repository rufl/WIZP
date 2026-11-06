import {
  loadNativeSession,
  nativeControlCredentials,
  saveNativeSession,
  sendRpcBounded,
  type NativeSessionSnapshot,
} from '../../bridge';

const EDITOR_SESSION_KEY = 'wizp:editorSession:v1';
const TERMINAL_LAYOUT_KEY = 'wizp:terminalLayout:v1';
let snapshot: NativeSessionSnapshot = {};
let loading: Promise<NativeSessionSnapshot> | null = null;
let revision = 0;
let savedRevision = 0;
let writing: Promise<void> | null = null;

const SESSION_LOAD_TIMEOUT_MS = 3000;

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

export function loadRendererSession(): Promise<NativeSessionSnapshot> {
  if (loading) return loading.then(() => snapshot);
  loading = (async () => {
    let browserFallback: NativeSessionSnapshot = {};
    try {
      const editorSession = JSON.parse(localStorage.getItem(EDITOR_SESSION_KEY) || 'null');
      const terminalLayout = JSON.parse(localStorage.getItem(TERMINAL_LAYOUT_KEY) || 'null');
      browserFallback = {
        editorSession: {
          ...(editorSession ?? {}),
          ...(terminalLayout ? { terminalLayout } : {}),
        },
      };
    } catch {
      // Browser storage is optional; it never gates the native host service.
    }
    if (nativeControlCredentials()) {
      const nativeSnapshot =
        (await resolveWithin(
          loadNativeSession(),
          {
            sidebarVisible: true,
            panelVisible: true,
            panelHeight: 200,
          },
          SESSION_LOAD_TIMEOUT_MS,
        )) ?? {};
      snapshot = {
        ...browserFallback,
        ...nativeSnapshot,
        editorSession: {
          ...browserFallback.editorSession,
          ...nativeSnapshot.editorSession,
        },
      };
      if (snapshot.editorSession?.terminalLayout && snapshot.panelVisible === false) {
        snapshot.panelVisible = true;
      }
    } else {
      const path = new URLSearchParams(window.location.search).get('wizpSessionPath');
      if (path) {
        snapshot =
          (await resolveWithin(
            sendRpcBounded('session/load', { path }, SESSION_LOAD_TIMEOUT_MS),
            { sidebarVisible: true, panelVisible: true, panelHeight: 200 },
            SESSION_LOAD_TIMEOUT_MS,
          )) ?? {};
      }
      snapshot = {
        ...snapshot,
        ...browserFallback,
        editorSession: { ...snapshot.editorSession, ...browserFallback.editorSession },
      };
    }
    return snapshot;
  })().catch((error) => {
    loading = null;
    throw error;
  });
  return loading;
}

export async function updateRendererSession(patch: NativeSessionSnapshot): Promise<void> {
  try {
    if (patch.editorSession) {
      let storedEditorSession: Record<string, unknown> = {};
      try {
        const stored = JSON.parse(localStorage.getItem(EDITOR_SESSION_KEY) || 'null');
        if (stored && typeof stored === 'object' && !Array.isArray(stored)) {
          storedEditorSession = stored as Record<string, unknown>;
        }
      } catch {
        // Ignore malformed optional browser state and replace it below.
      }
      localStorage.setItem(
        EDITOR_SESSION_KEY,
        JSON.stringify({ ...storedEditorSession, ...patch.editorSession }),
      );
    }
    if (patch.editorSession?.terminalLayout) {
      localStorage.setItem(TERMINAL_LAYOUT_KEY, JSON.stringify(patch.editorSession.terminalLayout));
    }
  } catch {
    // Browser storage is optional; the session service remains authoritative.
  }
  await loadRendererSession();
  snapshot = {
    ...snapshot,
    ...patch,
    editorSession: { ...snapshot.editorSession, ...patch.editorSession },
  };
  revision += 1;
  await flushRendererSession();
}

export async function flushRendererSession(): Promise<void> {
  await loadRendererSession();
  if (writing) {
    await writing;
    if (savedRevision !== revision) await flushRendererSession();
    return;
  }
  if (savedRevision === revision) return;
  const drain = async () => {
    while (savedRevision !== revision) {
      const targetRevision = revision;
      const next = snapshot;
      if (nativeControlCredentials()) {
        const saved = await resolveWithin(
          saveNativeSession(next).then((value) => value === true),
          false,
          SESSION_LOAD_TIMEOUT_MS,
        );
        if (!saved) throw new Error('Native session service unavailable');
      } else {
        const path = new URLSearchParams(window.location.search).get('wizpSessionPath');
        if (path) {
          await resolveWithin(
            sendRpcBounded(
              'session/save',
              {
                ...next,
                path,
                editorSession: JSON.stringify(next.editorSession ?? {}),
              },
              SESSION_LOAD_TIMEOUT_MS,
            ),
            null,
            SESSION_LOAD_TIMEOUT_MS,
          );
        }
        localStorage.setItem(EDITOR_SESSION_KEY, JSON.stringify(next.editorSession ?? {}));
        if (next.editorSession?.terminalLayout) {
          localStorage.setItem(
            TERMINAL_LAYOUT_KEY,
            JSON.stringify(next.editorSession.terminalLayout),
          );
        }
      }
      savedRevision = targetRevision;
    }
  };
  writing = drain().finally(() => {
    writing = null;
  });
  return writing;
}
