// ─── Legacy Bootstrap ───
// Non-UI initialization that Svelte components don't handle:
// - Keyboard shortcuts
// - Daemon connection
// - Window unload handler
// - Global event listeners

import { startDaemon, stopDaemon } from './bridge';
import { eventBus } from './src/eventbus';
import { showToast } from './src/stores';
import { initLogger, log, setStatus } from './src/logger';
import { editorGroups } from './src/lib/editor/state.svelte';

// ─── Keyboard Shortcuts ───
document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key === 'b') {
    e.preventDefault();
    eventBus.emit('sidebar:toggle');
  } else if (e.ctrlKey && e.key === 'j') {
    e.preventDefault();
    eventBus.emit('panel:toggle');
  } else if (e.ctrlKey && e.shiftKey && e.key === 'P') {
    e.preventDefault();
    document.dispatchEvent(new CustomEvent('palette:open'));
  } else if (e.ctrlKey && e.key === 'p') {
    e.preventDefault();
    document.dispatchEvent(new CustomEvent('quickopen:open'));
  } else if (e.ctrlKey && e.key === 's') {
    e.preventDefault();
    eventBus.emit('file:save');
  } else if (e.ctrlKey && e.key === 'n') {
    e.preventDefault();
    eventBus.emit('file:new');
  } else if (e.ctrlKey && e.key === '\\') {
    e.preventDefault();
    eventBus.emit('editor:split');
  } else if (e.ctrlKey && e.key === 'Tab') {
    e.preventDefault();
    eventBus.emit('editor:next-tab');
  }
});

// ─── Window Unload ───
window.addEventListener('beforeunload', (e) => {
  try {
    const state = {
      width: window.outerWidth, height: window.outerHeight,
      x: window.screenX, y: window.screenY,
      maximized: document.fullscreenElement !== null,
    };
    localStorage.setItem('wizp:windowState', JSON.stringify(state));
  } catch {}

  // Check unsaved changes
  try {
    for (const group of Object.values(editorGroups)) {
      for (const ed of group.editors) {
        if (ed?.dirty && ed?.uri && !ed.uri.startsWith('welcome')) {
          e.preventDefault();
          e.returnValue = 'You have unsaved changes.';
          return;
        }
      }
    }
  } catch {}

  stopDaemon();
  try { fetch('/api/window', { method: 'POST', body: JSON.stringify({ close: true }) }); } catch {}
});

// ─── Initialize ───
initLogger();
log('system', 'WIZP Editor initializing (Svelte mode)');

startDaemon().then(() => {
  log('system', 'Daemon connected');
  setStatus('connected');
}).catch(err => {
  log('system', 'Daemon connection failed: ' + err);
  showToast('Failed to connect to backend daemon: ' + err, 'error');
});
