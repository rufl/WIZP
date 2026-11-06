# WIZP UI/UX Architecture — VSCode Parity via DVUI + Monaco

## VSCode UI Component Tree (Deep Analysis)

VSCode's UI is split into two layers: the **Electron Shell** (native OS layer) and the **Workbench** (HTML/CSS/JS rendered in a Chromium webview).

### Layer 1: Electron Shell (Native)
```
┌─────────────────────────────────────────────────────────┐
│ Title Bar (OS-native)                          ─ ⬜ ✕   │
├─────────────────────────────────────────────────────────┤
│ Menu Bar: File Edit Selection View Go Run Terminal Help │
├─────────────────────────────────────────────────────────┤
│                                                         │
│            WORKBENCH (Chromium WebView)                  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```
Electron provides:
- **Native title bar** with window controls (minimize, maximize, close)
- **Native menu bar** — File, Edit, Selection, View, Go, Run, Terminal, Help
- **Native context menus** — right-click anywhere triggers OS-native menus
- **Native file dialogs** — Open Folder, Open File, Save As
- **Native notifications** — OS notification center integration
- **System tray** (optional)

### Layer 2: Workbench (HTML/CSS/JS in WebView)
```
┌──────┬──────────────────────────────────────────────────┐
│      │ TAB BAR: [🟢 main.zig] [📄 build.zig] [+]        │
│      ├──────────────────────────────────────────────────┤
│ Act- │ BREADCRUMBS: src > ui > Editor.zig               │
│ ivity├──────────────────────┬───────────────────────────┤
│ Bar  │                      │                           │
│      │    EDITOR AREA       │     MINIMAP               │
│  📁  │    (Monaco Editor)   │     (code outline)        │
│  🔍  │                      │                           │
│  ⑂  │    Syntax highlighted │     ▎▎▎▎▎▎               │
│  🐛  │    Cursor, selection │     ▎▎▎▎▎▎               │
│  🧩  │    Line numbers      │     ▎▎▎▎▎▎               │
│      │    Scrollbar         │     ▎▎▎▎▎▎               │
│      │                      │                           │
│      ├──────────────────────┴───────────────────────────┤
│      │ STATUS BAR: NORMAL  Ln 42, Col 15  UTF-8  Zig   │
├──────┴──────────────────────────────────────────────────┤
│ PANEL: [PROBLEMS] [OUTPUT] [DEBUG CONSOLE] [TERMINAL]  │
│ $ cargo build                                            │
│ Compiling wizp v0.1.0                                    │
└──────────────────────────────────────────────────────────┘
```

The workbench is a **single-page application** composed of these HTML "parts" (VSCode calls them `Part`):
- **ActivityBarPart** — left icon strip, switches sidebar content
- **SideBarPart** — Explorer, Search, SCM, Debug, Extensions views
- **EditorPart** — tab bar, breadcrumbs, Monaco editor(s), minimap
- **StatusbarPart** — bottom status bar
- **PanelPart** — Problems, Output, Debug Console, Terminal

All parts communicate via VSCode's `IEditorService`, `IViewDescriptorService`, etc.

### Key UX Behaviors
- **Activity bar**: Click icon → sidebar changes. Active icon has left accent border + brighter color.
- **Sidebar**: Resizable (drag right edge). Title bar with view name and action buttons.
- **Tabs**: Drag to reorder. Close button on hover. Dirty indicator (●). Active tab has bottom border matching editor background.
- **Editor**: Monaco handles everything — syntax highlighting, IntelliSense, multi-cursor, folding, minimap, breadcrumbs, find/replace, go-to-definition.
- **Status bar**: Left-aligned (mode, git branch, errors/warnings). Right-aligned (line/col, encoding, language, feedback).
- **Panel**: Resizable (drag top edge). Tab switching. Terminal is xterm.js or pty.
- **Command Palette**: `Ctrl+Shift+P` — modal overlay, fuzzy search.
- **Quick Open**: `Ctrl+P` — file picker, fuzzy search.
- **Settings**: `Ctrl+,` — split view (settings.json left, settings UI right).

---

## WIZP DVUI + Monaco Hybrid Architecture

### Design Principle
> **DVUI handles what Electron handles. Monaco handles what the Workbench handles.**

This gives us VSCode-identical editing UX (Monaco) with native performance for chrome (DVUI).

```
┌─────────────────────────────────────────────────────────┐
│ DVUI Window (SDL3, native)                              │
├─────────────────────────────────────────────────────────┤
│ DVUI Menu Bar: File Edit Selection View Go Run Terminal │
├─────────────────────────────────────────────────────────┤
│                                                         │
│         WEBVIEW containing MONACO WORKBENCH              │
│         (identical to VSCode's workbench HTML)           │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ Zig Backend (JSON-RPC over stdin/stdout or Unix socket) │
│   LSP Host │ AI/LLM │ MCP │ File I/O │ Search │ Git     │
└─────────────────────────────────────────────────────────┘
```

### Component Ownership

| VSCode Component | Electron | WIZP Equivalent | Owner |
|---|---|---|---|
| Title bar + window controls | Native (Chromium) | **DVUI** (SDL3 window) | DVUI |
| Menu bar | Native (Electron Menu) | **DVUI** (`dvui.menu()`) | DVUI |
| Context menus | Native (Electron Menu) | **DVUI** (`dvui.menu()` in floating window) | DVUI |
| File dialogs | Native (Electron dialog) | **DVUI** (native file dialog or dvui dialog) | DVUI |
| Command Palette | Workbench (HTML modal) | **Monaco** (QuickInputService) | Monaco |
| Quick Open | Workbench (HTML modal) | **Monaco** (QuickInputService) | Monaco |
| Settings UI | Workbench (HTML) | **Monaco** (settings editor) | Monaco |
| Activity Bar | Workbench (HTML) | **Monaco** (ActivityBarPart) | Monaco |
| Sidebar (Explorer) | Workbench (HTML) | **Monaco** (SideBarPart + ExplorerView) | Monaco |
| Sidebar (Search) | Workbench (HTML) | **Monaco** (SearchView) | Monaco |
| Sidebar (SCM) | Workbench (HTML) | **Monaco** (SCMView) | Monaco |
| Sidebar (Debug) | Workbench (HTML) | **Monaco** (DebugView) | Monaco |
| Sidebar (Extensions) | Workbench (HTML) | **Monaco** (ExtensionsView) | Monaco |
| Editor tabs + breadcrumbs | Workbench (HTML) | **Monaco** (EditorPart) | Monaco |
| Editor surface | Workbench (Monaco) | **Monaco** (IEditor) | Monaco |
| Minimap | Workbench (Monaco) | **Monaco** (built-in) | Monaco |
| Status bar | Workbench (HTML) | **Monaco** (StatusbarPart) | Monaco |
| Panel (Terminal) | Workbench (xterm.js) | **Monaco** (TerminalView via xterm.js) | Monaco |
| Panel (Problems) | Workbench (HTML) | **Monaco** (MarkersView) | Monaco |
| Panel (Output) | Workbench (HTML) | **Monaco** (OutputView) | Monaco |
| Panel (Debug Console) | Workbench (HTML) | **Monaco** (DebugConsoleView) | Monaco |
| Notifications | Workbench (HTML) | **Monaco** (Notifications) | Monaco |
| Modal dialogs | Workbench (HTML) | **DVUI** (floating windows, modal dialogs) | DVUI |

### Key Insight: What DVUI actually owns

DVUI owns the **truly native pieces** that can't be done in a webview:
1. **Window management** — SDL3 window, resize, minimize, maximize, close
2. **Menu bar** — OS-style menus that drop down over the webview
3. **Context menus** — right-click menus (could also be in Monaco, but native is better)
4. **File dialogs** — Open/Save dialogs (OS-native or custom)
5. **Modal overlays** — dialogs that need to cover the entire window (about, crash reporter)
6. **WebView container** — embedding and managing the WebView lifecycle

Monaco owns **everything else** — the entire workbench UI, because:
- It already exists and is battle-tested
- It provides the exact VSCode look and feel
- It handles all the complex editor interactions (IntelliSense, multi-cursor, etc.)
- The VSCode team maintains it

### Data Flow: DVUI → Monaco → Zig Backend

```
┌──────────┐  JSON-RPC   ┌──────────────────┐  JSON-RPC   ┌──────────────┐
│  DVUI    │◄──────────►│  Monaco Workbench │◄──────────►│  Zig Backend │
│ (menus,  │  stdio/     │  (full VSCode UI) │  stdio/    │  (LSP, AI,   │
│  dialogs)│  Unix sock  │                   │  Unix sock │  File I/O)   │
└──────────┘             └──────────────────┘             └──────────────┘
```

**DVUI ↔ Monaco IPC:**
- DVUI sends: `menu/file_open`, `menu/file_save`, `window/close`, `dialog/response`
- Monaco sends: `window/set_title`, `window/set_represented_filename`

**Monaco ↔ Zig Backend IPC (existing daemon protocol):**
- `file/open` — open file and return content + language
- `file/save` — save file content
- `file/close` — close file
- `editor/state` — get editor state (mode, cursor, dirty)
- `lsp/completion` — get completions
- `lsp/hover` — get hover info
- `lsp/definition` — go to definition
- `lsp/diagnostics` — push diagnostics
- `ai/complete` — AI inline completion
- `ai/chat` — AI chat message
- `search/query` — search files
- `git/status` — git status
- `git/diff` — git diff

---

## Implementation Plan

### Phase 1: WebView Container in DVUI (Week 1) ✅ DONE
- Embed a WebView (WebKit2GTK on Linux, WKWebView on macOS, Edge WebView2 on Windows) inside the DVUI/SDL3 window
- Load the Monaco workbench HTML into the WebView
- Handle window resize events: resize WebView to fill content area
- Implemented in `src/webview/HybridWindow.zig` — SDL3 + GTK WebKit2 via X11 reparenting

### Phase 2: Menu Bar in DVUI (Week 1) ✅ DONE
- Render a native menu bar using `dvui.menu()` with menu items
- Wire menu actions to JSON-RPC messages sent to Monaco:
  - File → New, Open, Save, Save As, Close, Exit
  - Edit → Undo, Redo, Cut, Copy, Paste, Find, Replace
  - Selection → Select All, Expand Selection, Shrink Selection
  - View → Appearance, Editor Layout, Toggle Sidebar, Toggle Panel, Zoom
  - Go → Back, Forward, Go to File, Go to Line, Go to Symbol
  - Run → Start Debugging, Run Without Debugging
  - Terminal → New Terminal
  - Help → About, Welcome
- Implemented in `renderMenuBar()` with `MenuAction` enum queue (41 actions)

### Phase 3: Monaco Workbench (Week 2)
- Set up the Monaco workbench HTML/CSS/JS (VSCode's workbench is open source!)
- Use `monaco-editor` npm package for the editor surface
- Implement the workbench parts in HTML/CSS matching VSCode layout exactly
- Wire JSON-RPC communication to Zig backend

### Phase 4: IPC Bridge (Week 2)
- Implement bidirectional JSON-RPC:
  - Zig backend ↔ Monaco (existing daemon protocol, extend with new methods)
  - DVUI ↔ Monaco (new protocol for window/menu/dialog events)
- Use Unix domain sockets or stdin/stdout pipes for fast IPC

### Phase 5: Polish (Week 3)
- Context menus (DVUI floating windows)
- File dialogs (DVUI or native)
- Command palette integration
- Theme synchronization between DVUI chrome and Monaco

---

## DVUI Code Changes Required

### Current State
- `main.zig`: Three parallel paths (daemon, DVUI, terminal)
- `Editor.zig`: DVUI render functions render full VSCode layout

### Target State
- `main.zig`: One path — DVUI window with embedded WebView
  - DVUI renders: menu bar, context menus, modal dialogs
  - WebView renders: Monaco workbench (all editor UI)
- `Editor.zig`: Becomes backend-only (no UI rendering)
  - Handles JSON-RPC from Monaco
  - Manages buffers, LSP, AI, files
- `dvui_core.zig`: Extended with WebView embedding API

### Files to Remove/Repurpose
- `renderActivityBarDVUI()` → Monaco handles this
- `renderSidebarDVUI()` → Monaco handles this
- `renderFileTreeDVUI()` → Monaco handles this
- `renderSearchDVUI()` → Monaco handles this
- `renderTabBarDVUI()` → Monaco handles this
- `renderBufferDVUI()` → Monaco handles this
- `renderStatusBarDVUI()` → Monaco handles this
- `renderPanelDVUI()` → Monaco handles this
- `processDVUIInput()` → Monaco handles keyboard input

### Files to Keep/Extend
- `dvui_core.zig` — add WebView embedding, menu bar rendering
- `main.zig` — single DVUI path with WebView
- `Editor.zig` — backend logic, JSON-RPC handlers
- `monaco_bindings.zig` — Monaco initialization and language registration
- `webview/WebView.zig` — platform-specific WebView code

---

## Monaco Workbench Structure (Frontend)

```
wizp/frontend/
├── package.json          # Bun dependencies (monaco-editor, etc.)
├── index.html            # WebView HTML shell
├── workbench/
│   ├── main.ts           # Entry point, layout initialization
│   ├── parts/
│   │   ├── activityBar.ts    # Activity bar (icon strip)
│   │   ├── sidebar.ts        # Sidebar container
│   │   ├── editor.ts         # Editor area (tabs + Monaco)
│   │   ├── statusBar.ts      # Status bar
│   │   └── panel.ts          # Panel (terminal, output, etc.)
│   ├── views/
│   │   ├── explorer.ts       # File explorer view
│   │   ├── search.ts         # Search view
│   │   ├── scm.ts            # Source control view
│   │   ├── debug.ts          # Debug view
│   │   └── extensions.ts     # Extensions view
│   ├── ipc/
│   │   └── bridge.ts         # JSON-RPC bridge to Zig backend
│   └── styles/
│       └── workbench.css     # VSCode-identical layout CSS
└── server.ts             # Bun HTTP server for development
```

The workbench CSS would replicate VSCode's exact layout using CSS Grid:
```css
.workbench {
    display: grid;
    grid-template-columns: 48px auto;
    grid-template-rows: 1fr auto;
    height: 100vh;
}
.activity-bar { grid-row: 1 / 3; grid-column: 1; }
.sidebar { grid-row: 1; grid-column: 2; }
.editor-area { grid-row: 1; grid-column: 2; }
.panel { grid-row: 2; grid-column: 2; }
.status-bar { grid-row: 3; grid-column: 1 / 3; }
```
