// Reactive editor state using Svelte 5 runes (.svelte.ts = compiler handles $state)
import type { Editor, EditorGroup, EditorGroups } from './models';
import { sendRpc } from '../../../bridge';

export const editorGroups = $state<EditorGroups>({});
export const visibleGroupOrder = $state<string[]>([]); // ordered groups currently laid out in editor area

// Use a single $state object for scalars to avoid Rolldown "const re-assignment" errors with direct $state exports
export const editorUiState = $state({
  activeGroupId: null as string | null,
  revision: 0,
});

export function notifyEditorState() {
  editorUiState.revision += 1;
}

export function getActiveGroupId(): string | null {
  return editorUiState.activeGroupId;
}

export function setActiveGroupId(id: string | null) {
  if (editorUiState.activeGroupId === id) return;
  editorUiState.activeGroupId = id;
  notifyEditorState();
}

export function addVisibleGroup(id: string) {
  if (!visibleGroupOrder.includes(id)) {
    visibleGroupOrder.push(id);
    notifyEditorState();
  }
}

function baseName(uri: string): string {
  const clean = uri.replace(/^file:\/\//, '');
  return clean.split('/').pop() || clean;
}

function sortableUri(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

function getOpenSortSettings() {
  const fallback = { enabled: false, order: 'asc', rule: 'name-local' };
  try {
    const settings = JSON.parse(localStorage.getItem('wizp-settings') || '{}');
    const openPositioning =
      settings['workbench.editor.openPositioning'] ?? settings.workbenchEditorOpenPositioning;
    if (openPositioning !== 'sort') return fallback;
    const order =
      settings['workbench.editor.openPositioningSortOrder'] ??
      settings.workbenchEditorOpenPositioningSortOrder ??
      'asc';
    const rule =
      settings['workbench.editor.openPositioningSortRule'] ??
      settings.workbenchEditorOpenPositioningSortRule ??
      'name-local';
    return {
      enabled: true,
      order: order === 'desc' ? 'desc' : 'asc',
      rule: ['name-local', 'name-absolute', 'absolute'].includes(rule) ? rule : 'name-local',
    };
  } catch {
    return fallback;
  }
}

function compareEditorsForOpenSort(a: Editor, b: Editor): number {
  const settings = getOpenSortSettings();
  if (!settings.enabled) return 0;

  let left = '';
  let right = '';
  if (settings.rule === 'absolute') {
    left = sortableUri(a.uri);
    right = sortableUri(b.uri);
  } else {
    left = baseName(a.uri);
    right = baseName(b.uri);
  }

  let result = left.localeCompare(right, undefined, { numeric: true, sensitivity: 'base' });
  if (result === 0 && settings.rule === 'name-absolute') {
    result = sortableUri(a.uri).localeCompare(sortableUri(b.uri), undefined, {
      numeric: true,
      sensitivity: 'base',
    });
  }
  if (settings.order === 'desc') result = -result;
  return result;
}

function sortGroupEditorsForOpenPositioning(group: EditorGroup) {
  if (!getOpenSortSettings().enabled) return;
  group.editors = [...group.editors].sort(compareEditorsForOpenSort);
}

// Helper to get current active group
export function getActiveGroup(): EditorGroup | null {
  const id = getActiveGroupId();
  if (!id) return null;
  return editorGroups[id] ?? null;
}

// Very basic helper to create a new group
export function createEditorGroup(): string {
  const id = crypto.randomUUID();
  editorGroups[id] = {
    id,
    editors: [],
    activeEditorId: null,
  };
  notifyEditorState();
  return id;
}

// Make first group if none exists (temporary bootstrap)
export function ensureBootstrapGroup(): void {
  if (visibleGroupOrder.length > 0) {
    if (!getActiveGroupId()) setActiveGroupId(visibleGroupOrder[0]);
    return;
  }
  const firstGroupId = Object.keys(editorGroups)[0] ?? createEditorGroup();
  visibleGroupOrder.push(firstGroupId);
  if (!getActiveGroupId()) setActiveGroupId(firstGroupId);
  notifyEditorState();
}
// === Basic operations (will be expanded) ===

export function openEditorInGroup(groupId: string, editor: Editor) {
  const group = editorGroups[groupId];
  if (!group) return;

  // Reuse an open URI instead of creating a duplicate tab.
  const existing = group.editors.find((e) => e.uri === editor.uri);
  if (!existing) {
    group.editors.push(editor);
    sortGroupEditorsForOpenPositioning(group);
  } else if (existing.dirty !== true && editor.content !== undefined) {
    // Opening an already-dirty URI must not overwrite its unsaved content.
    existing.content = editor.content;
  }
  group.activeEditorId = existing ? existing.id : editor.id;
  notifyEditorState();

  if (editor.type === 'code' && editor.uri) {
    sendRpc('window/setActiveTextEditor', { path: editor.uri }).catch(() => {});
  }
}

export function setActiveEditor(groupId: string, editorId: string) {
  const group = editorGroups[groupId];
  if (!group) return;
  if (group.activeEditorId !== editorId && group.editors.some((e) => e.id === editorId)) {
    group.activeEditorId = editorId;
    notifyEditorState();

    // Notify Extension Host
    const tab = group.editors.find((e) => e.id === editorId);
    if (tab && tab.type === 'code' && tab.uri) {
      sendRpc('window/setActiveTextEditor', { path: tab.uri }).catch(() => {});
    }
  }
}

export function closeEditor(groupId: string, editorId: string) {
  const group = editorGroups[groupId];
  if (!group) return;

  const tab = group.editors.find((e) => e.id === editorId);
  if (tab && (tab.type === 'webview' || tab.uri?.startsWith('webview:'))) {
    try {
      sendRpc('webview/dispose', { id: tab.id });
    } catch {
      // Webview disposal is best effort during tab teardown.
    }
  }

  group.editors = group.editors.filter((e) => e.id !== editorId);

  if (group.activeEditorId === editorId) {
    group.activeEditorId = group.editors.length > 0 ? group.editors[0].id : null;
  }
  notifyEditorState();
}

export function moveEditorToGroup(editorId: string, fromGroupId: string, toGroupId: string) {
  const fromGroup = editorGroups[fromGroupId];
  const toGroup = editorGroups[toGroupId];
  if (!fromGroup || !toGroup) return;

  const editorIndex = fromGroup.editors.findIndex((e) => e.id === editorId);
  if (editorIndex === -1) return;

  const [editor] = fromGroup.editors.splice(editorIndex, 1);
  toGroup.editors.push(editor);

  // Adjust active editor in source group
  if (fromGroup.activeEditorId === editorId) {
    fromGroup.activeEditorId = fromGroup.editors.length > 0 ? fromGroup.editors[0].id : null;
  }

  // Set as active in destination
  toGroup.activeEditorId = editor.id;
  notifyEditorState();
}

// Helper to get currently active editor
export function getActiveEditor(): Editor | null {
  const group = getActiveGroup();
  if (!group || !group.activeEditorId) return null;
  return group.editors.find((e) => e.id === group.activeEditorId) ?? null;
}

// === Multi-group split support (B1) ===

export function splitGroup(
  sourceGroupId: string,
  _direction: 'horizontal' | 'vertical' = 'horizontal',
): string | null {
  const source = editorGroups[sourceGroupId];
  if (!source) return null;

  const newId = createEditorGroup();

  // Insert the new group immediately after the source in the visible layout
  const idx = visibleGroupOrder.indexOf(sourceGroupId);
  if (idx !== -1) {
    visibleGroupOrder.splice(idx + 1, 0, newId);
  } else {
    visibleGroupOrder.push(newId);
  }

  // For horizontal split (side-by-side) we just use order; vertical can be supported later via CSS
  // Seed the new group with a copy of the active editor if present
  if (source.activeEditorId) {
    const activeEd = source.editors.find((e) => e.id === source.activeEditorId);
    if (activeEd) {
      const clone: Editor = {
        id: crypto.randomUUID(),
        uri: activeEd.uri,
        languageId: activeEd.languageId,
        content: activeEd.content,
        dirty: activeEd.dirty,
      };
      openEditorInGroup(newId, clone);
    }
  }

  setActiveGroupId(newId);
  return newId;
}

export function closeGroup(groupId: string) {
  if (!editorGroups[groupId]) return;

  delete editorGroups[groupId];

  const orderIdx = visibleGroupOrder.indexOf(groupId);
  if (orderIdx !== -1) {
    visibleGroupOrder.splice(orderIdx, 1);
  }

  if (getActiveGroupId() === groupId) {
    if (visibleGroupOrder.length > 0) {
      setActiveGroupId(visibleGroupOrder[0]);
    } else {
      // Safeguard: always keep at least one group (B1 completion)
      const newId = createEditorGroup();
      visibleGroupOrder.push(newId);
      setActiveGroupId(newId);
    }
  }
  notifyEditorState();
}

// Reorder editor within its group (B1 micro-task)
export function reorderEditorInGroup(
  groupId: string,
  editorId: string,
  direction: 'left' | 'right',
) {
  const group = editorGroups[groupId];
  if (!group) return;

  const idx = group.editors.findIndex((e) => e.id === editorId);
  if (idx === -1) return;

  const newIdx = direction === 'left' ? idx - 1 : idx + 1;
  if (newIdx < 0 || newIdx >= group.editors.length) return;

  const [editor] = group.editors.splice(idx, 1);
  group.editors.splice(newIdx, 0, editor);
  notifyEditorState();
}

// Full reorder to specific index within group (for drag & drop completion)
export function reorderEditorToIndex(groupId: string, editorId: string, targetIndex: number) {
  const group = editorGroups[groupId];
  if (!group) return;

  const currentIdx = group.editors.findIndex((e) => e.id === editorId);
  if (currentIdx === -1 || currentIdx === targetIndex) return;

  const [editor] = group.editors.splice(currentIdx, 1);
  const insertIdx = targetIndex > currentIdx ? targetIndex - 1 : targetIndex;
  group.editors.splice(Math.max(0, Math.min(insertIdx, group.editors.length)), 0, editor);
  notifyEditorState();
}
