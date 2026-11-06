import { writable } from 'svelte/store';

// ─── Core Application State ───
export const activeSidebarView = writable<string>('explorer');
export const activityBarPosition = writable<'left' | 'top-left' | 'top-right' | 'hidden'>('left');
export function toggleActivityBarPosition() {
  activityBarPosition.update((v) => {
    if (v === 'left') return 'top-left';
    if (v === 'top-left') return 'top-right';
    if (v === 'top-right') return 'hidden';
    return 'left';
  });
}
export const isSidebarVisible = writable<boolean>(true);
export const isRightSidebarVisible = writable<boolean>(false);
export function toggleRightSidebar() {
  isRightSidebarVisible.update((v) => !v);
}
export const isPanelVisible = writable<boolean>(true);
export const isPanelMaximized = writable<boolean>(false);
export const isMaximized = writable<boolean>(false);
export const sidebarWidth = writable<number>(300);
export const rsbWidth = writable<number>(300);
export const panelHeight = writable<number>(200);
export const activeMenu = writable<string | null>(null);

export const zoomLevel = writable<number>(1);
export const zenMode = writable<boolean>(false);
export const vimMode = writable<boolean>(false);

export const projectPath = writable<string>('');
export const statusMessage = writable<string>('Initializing...');
export const gitBranch = writable<string>('main');
export const lineColumn = writable<string>('Ln 1, Col 1');
export const language = writable<string>('Plain Text');
export const indentation = writable<string>('Spaces: 4');
export const encoding = writable<string>('UTF-8');
export const eol = writable<string>('LF');
export const lspStatus = writable<string>('');

export interface ToastMessage {
  id: number;
  message: string;
  type: 'info' | 'error';
}

export const toasts = writable<ToastMessage[]>([]);
let toastId = 0;

export function showToast(message: string, type: 'info' | 'error' = 'info') {
  const id = ++toastId;
  toasts.update((t) => [...t.slice(-2), { id, message, type }]);
  setTimeout(() => {
    toasts.update((t) => t.filter((x) => x.id !== id));
  }, 3000);
}

export function toggleSidebar(force?: boolean) {
  isSidebarVisible.update((v) => (force !== undefined ? force : !v));
}

export function togglePanel(force?: boolean) {
  isPanelVisible.update((v) => (force !== undefined ? force : !v));
}

export function switchSidebarView(view: string) {
  activeSidebarView.set(view);
  if (view.startsWith('contributed:')) {
    isSidebarVisible.set(true);
  }
}

export function setActiveMenu(menu: string | null) {
  activeMenu.set(menu);
}

export function openFile(path: string) {
  (window as any).__openFile?.(path);
}
