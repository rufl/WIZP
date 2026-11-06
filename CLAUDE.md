# WIZP Project Memory

This file is historical project memory. For release/parity truth, prefer:

- `../VSCODE_PARITY_BACKLOG.md`
- `../docs/vscode-parity/MATRIX.md`
- `../docs/release/BETA_EVIDENCE_RUNBOOK.md`
- `npm run status:beta-gates`

## Current State (2026-06-07)

**Linux alpha scope:** documented and locally evidenced for scoped VS Code parity.
**Beta gate:** blocked until macOS/Windows package artifacts and 3 GitHub Actions stress trend samples exist.
**Build:** `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu` plus `cd frontend && npm run build`.
**Self-contained package:** use `npm run build:self-contained`; current Linux evidence bundles CEF and non-baseline runtime dependencies, so old small-package size notes below are historical.
**Frontend:** Vite + Svelte 5 Runes + shadcn-svelte + Bits UI + Tailwind v4 + Monaco 0.52.2

## Architecture

```
Svelte WebView ─Electrobun typed RPC─→ Bun Main ─stdio CL framing─→ Zig daemon (--daemon)
              ↕ fallback (dev mode)
Svelte WebView ─────fetch /api/rpc────→ Zig embedded HTTP ─stdio──→ Zig daemon
```

## Build Commands

```bash
# Zig backend (terminal + embedded HTTP + daemon)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu

# Frontend
cd frontend
npm install
npm run build     # Vite production (4.8s)
npm run dev       # Vite dev server

# Electrobun
bun run dev:electrobun     # Dev mode
npm run build:self-contained # Release evidence package path

# Tests
zig build test -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
```

## Feature Flags

| Flag | Default | Description |
|------|---------|-------------|
| `TREE_SITTER_AVAILABLE` | false | Incremental AST parsing |
| `WIZP_DVUI_AVAILABLE` | false | DVUI/SDL3 native GUI |
| `WIZP_WEBVIEW` | false | WebKit2GTK (legacy, Electrobun preferred) |
| `WIZP_BUNDLED_FRONTEND` | false | Embed frontend/dist/ in binary |

## Key Files

| File | Role |
|------|------|
| `src/bun/index.ts` | Electrobun main: spawns daemon, typed RPC proxy, native menus, window state |
| `electrobun.config.ts` | Electrobun build: app metadata, entrypoint, binary copy |
| `frontend/bridge.ts` | JSON-RPC dual-mode: Electrobun typed RPC → Bun → HTTP fallback |
| `src/embedded_server.zig` | HTTP server + daemon proxy + terminal/SSE + extension/webview RPC |
| `src/ui/Editor.zig` | Core editor: tabs, groups, LSP, DAP, git, folding, search, undo, file watch |
| `src/lsp/LSP.zig` | LSP client: stdio JSON-RPC, Content-Length framing |
| `src/debug/DAP.zig` | DAP client: stdio JSON-RPC, 14 methods |
| `src/buffer/Buffer.zig` | Piece table buffer with undo/redo stacks |
| `src/features/EditFeatures.zig` | FoldManager, MultiCursor |
| `src/features/SearchFeatures.zig` | SearchEngine (grep, glob, fuzzy) |
| `src/hub/ExtensionHost.zig` | VSIX extension host with Bun JS engine |
| `src/hub/OpenVSX.zig` | OpenVSX marketplace integration |
| `frontend/svelte-entry.ts` | Svelte 5 mount point, window globals |
| `frontend/src/components/EditorArea.svelte` | Monaco editor with groups/tabs/splits/drag/Folding/LSP/dialogs/undo/webview |
| `frontend/src/components/SidebarViews.svelte` | SCM, Debug, Extensions sidebar panels |
| `frontend/src/components/Panel.svelte` | Terminal, Problems, Output, Debug Console tabs |
| `frontend/src/components/Titlebar.svelte` | Custom titlebar with drag regions, menus, window controls |

## Frontend Component Map

```
App.svelte
├── Titlebar.svelte          (menu bar, window controls, command input)
├── ActivityBar.svelte       (explorer, search, scm, debug, extensions icons)
├── Sidebar.svelte
│   ├── Explorer.svelte + TreeItem.svelte  (recursive file tree)
│   ├── Search.svelte        (grep + regex + case-sensitive + replace)
│   └── SidebarViews.svelte  (SCM, Debug, Extensions panels)
├── EditorArea.svelte        (Monaco groups, tabs, splits, LSP, folding, undo, webview)
├── Panel.svelte
│   ├── Terminal.svelte      (xterm.js + PTY, multi-tab)
│   ├── problems list        (LSP diagnostics with click-to-navigate)
│   └── output channels      (terminal logs, daemon logs)
└── StatusBar.svelte         (branch, errors/warnings, line/col, lang, encoding)
```

## RPC Protocol

- **Format:** JSON-RPC 2.0 over Content-Length framed stdio (daemon) or HTTP POST (embedded)
- **Daemon path:** `wizp --daemon` → stdin/stdout with `Content-Length: N\r\n\r\n{body}` framing
- **Electrobun path:** typed RPC via `defineElectrobunRPC` → `sendRpc` handler proxies to daemon
- **HTTP path:** `POST /api/rpc` → `extractAndUnescape` hand-parses JSON fields
- **SSE path:** `GET /api/terminal/events` → EventSource streaming (base64-encoded chunks)

## Zig Memory Patterns

- `std.array_list.Managed(T)` — 3-field struct: `{ .allocator, .items, .capacity }`. `appendSlice(slice)` 1 arg, `toOwnedSlice()` 0 args, `deinit()` 0 args.
- `std.StringHashMapUnmanaged` — `deinit(allocator)` REQUIRED. `put(allocator, key, value)` for insertion.
- Struct literals: ALL fields required. Use `undefined` for fields initialized after literal.
- `self.allocator` in method bodies, never bare `allocator`.
- `?*Pointer` optional — use `|ptr|` capture (not `|*ptr|` which gives `**T`).

## Zig 0.16.0 Specifics

- Runtime file/network/process operations take an explicit `std.Io`; use `runtime_016.io()`.
- Filesystem operations use `std.Io.Dir`/`std.Io.File`, with the `std.Io` passed to open, read, write, stat, and close calls.
- Spawn children with `std.process.spawn`; capture bounded command output with `std.process.run`.
- Executable entry points accept `std.process.Init.Minimal` and iterate `init.args`.
- Growable formatted output uses `std.Io.Writer.Allocating`; managed array lists remain for container-style append operations.
- `std.mem.trimLeft`/`trimRight` are `trimStart`/`trimEnd`.
- `-Dtarget=x86_64-linux-gnu` remains required on GCC 16+ systems because of `.sframe` incompatibility.

## Known Quirks

Current release blockers:

- macOS package/platform artifact missing.
- Windows package/platform artifact missing.
- Stress trend requires 3 `github-actions` samples; local/manual samples do not close beta.

Historical/local quirks:

- `frontend/dist/index.html` is static — Vite generates it once, not regenerated on changes
- `page_allocator` used throughout (mmap/munmap per alloc/free)
- Manual JSON field extraction in Editor.zig (hand-rolled string scanning, no std.json)
- Two parallel codebases: terminal (DVUI) and web (Svelte/Monaco) — features in one may not exist in other

## RPC Handlers Reference

### Editor.zig (handled via daemon)
`editor/state`, `editor/undo`, `editor/redo`, `editor/foldRanges`, `editor/problems`,
`lsp/completion`, `lsp/hover`, `lsp/diagnostics`, `textDocument/didOpen`, `textDocument/didChange`,
`textDocument/definition`, `textDocument/signatureHelp`,
`git/status`, `git/stage`, `git/unstage`, `git/commit`, `git/diff`, `git/discard`,
`debug/start`, `debug/stop`, `debug/step`, `debug/continue`, `debug/breakpoints`, `debug/toggleBreakpoint`, `debug/state`,
`search/text`, `file/list`, `file/open`, `theme/list`, `theme/apply`, `hub/list`, `hub/search`, `hub/install`

### embedded_server.zig (handled in-process)
`terminal/spawn`, `terminal/write`, `terminal/resize`, `terminal/kill`, `terminal/activate`, `terminal/list`,
`webview/create`, `webview/setHtml`, `webview/reveal`, `webview/list`, `webview/receiveMessage`, `webview/postMessage`,
`extension/viewsContainers`, `extension/views`, `extension/commands`, `extension/getTreeData`, `extension/execute`,
`file/open-file-dialog`, `file/open-folder-dialog`
