// Core editor state models (Svelte 5 runes ready)
// These will be used to drive the real Tab system + Editor Groups

export interface ZlayInteractionSnapshot {
  engine: 'zlay';
  registeredSurfaces: number;
  focusedSurface: number;
  visibleLineRange: { start: number; end: number };
  query: { length: number; cursor: number };
  features: string[];
}

export interface Editor {
  id: string;
  uri: string;
  languageId: string;
  dirty: boolean;
  content?: string;
  viewState?: any;
  zlayInteraction?: ZlayInteractionSnapshot;
  type?: 'code' | 'webview'; // for B3 webview support
  webviewUrl?: string;
  webviewHtml?: string;
}

export interface EditorGroup {
  id: string;
  editors: Editor[];
  activeEditorId: string | null;
}

export type EditorGroups = Record<string, EditorGroup>; // groupId -> group
