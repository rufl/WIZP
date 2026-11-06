// LSP bridge types for frontend <-> Zig daemon (B2)
// These match JSON-RPC over /api/rpc

export interface LSPPosition {
  line: number;
  character: number;
}

export interface LSPRange {
  start: LSPPosition;
  end: LSPPosition;
}

export interface LSPDiagnostic {
  range: LSPRange;
  severity?: 1 | 2 | 3 | 4;
  message: string;
  source?: string;
}

export interface CompletionItem {
  label: string;
  kind?: number;
  detail?: string;
  insertText?: string;
  documentation?: string;
}

export interface HoverResult {
  contents: string | { kind: string; value: string };
  range?: LSPRange;
}

export interface DefinitionLocation {
  uri: string;
  range: LSPRange;
}

// RPC request shapes the frontend will send
export interface LSPStartParams {
  rootUri: string;
  languageId: string;
  fileUri: string;
}

export interface LSPTextDocumentPositionParams {
  textDocument: { uri: string };
  position: LSPPosition;
}

export interface LSPCompletionParams extends LSPTextDocumentPositionParams {
  context?: { triggerKind: number };
}

export interface LSPDidOpenParams {
  textDocument: {
    uri: string;
    languageId: string;
    version: number;
    text: string;
  };
}

export interface LSPDidChangeParams {
  textDocument: { uri: string; version: number };
  contentChanges: { text: string }[];
}
