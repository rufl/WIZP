// Frontend LSP client bridge (B2) - matches current Zig daemon RPC handlers
// Zig accepts the request fields from the standard JSON-RPC params object.

import type { LSPDiagnostic } from './types';
import { sendRpc } from '../../../bridge';

// B2.3: Debounce timers per URI for didChange
const _didChangeTimers = new Map<string, ReturnType<typeof setTimeout>>();

async function call<T>(method: string, body: Record<string, unknown>): Promise<T> {
  return sendRpc(method, body) as Promise<T>;
}

export const lsp = {
  async completion(uri: string, line: number, col: number) {
    const res = await call<{ items: string }>('lsp/completion', { uri, line, col });
    try {
      return { items: JSON.parse(res.items || '[]') };
    } catch {
      return { items: (res.items || '').split(',').filter(Boolean) };
    }
  },

  async hover(uri: string, line: number, col: number) {
    return call<{ text?: string }>('lsp/hover', { uri, line, col });
  },

  async fileOpen(path: string) {
    return call<{ content: string; language: string }>('file/open', { path });
  },

  async didChange(uri: string, content: string) {
    // B2.3: Debounce rapid didChange calls (LSP servers expect ~300ms settling)
    const existing = _didChangeTimers.get(uri);
    if (existing) clearTimeout(existing);
    _didChangeTimers.set(
      uri,
      setTimeout(() => {
        _didChangeTimers.delete(uri);
        call('textDocument/didChange', { uri, content }).catch((e) =>
          console.warn('[LSP] didChange failed', e),
        );
      }, 300),
    );
  },

  async getDiagnostics(uri: string): Promise<LSPDiagnostic[]> {
    try {
      const res = await call<any>('lsp/diagnostics', { uri });
      // Zig returns {diagnostics: jsonstring | array} under result; unwrap robustly
      let diags: any[] = [];
      if (Array.isArray(res)) diags = res;
      else if (res?.diagnostics) {
        diags =
          typeof res.diagnostics === 'string'
            ? JSON.parse(res.diagnostics) || []
            : res.diagnostics || [];
      }
      return diags as LSPDiagnostic[];
    } catch {
      return [];
    }
  },

  async didOpen(uri: string, languageId: string, text: string) {
    try {
      await call('textDocument/didOpen', { uri, languageId, text, version: 1 });
    } catch (e) {
      console.warn('[LSP] didOpen failed', e);
    }
  },

  async definition(uri: string, line: number, col: number) {
    try {
      return await call<any[]>('lsp/definition', { uri, line, col });
    } catch {
      return [];
    }
  },

  async references(uri: string, line: number, col: number) {
    try {
      return await call<any[]>('lsp/references', { uri, line, col });
    } catch {
      return [];
    }
  },

  async rename(uri: string, line: number, col: number, newName: string) {
    try {
      return await call<any>('lsp/rename', { uri, line, col, newName });
    } catch {
      return null;
    }
  },

  async codeActions(uri: string, line: number, col: number) {
    try {
      return await call<any[]>('lsp/codeActions', { uri, line, col });
    } catch {
      return [];
    }
  },

  async signatureHelp(uri: string, line: number, col: number) {
    try {
      return await call<any>('textDocument/signatureHelp', { uri, line, col });
    } catch {
      return null;
    }
  },
};
