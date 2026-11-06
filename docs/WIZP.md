# WIZP Documentation

> Status note, 2026-07-18: this is a broad architecture/development document. For release and parity truth, use `../../BACKLOG.md`, `../../BACKLOG_ARCHIVE.md`, `../../VSCODE_PARITY_BACKLOG.md`, `../../docs/vscode-parity/MATRIX.md`, and `../../docs/release/BETA_EVIDENCE_RUNBOOK.md`. The preserved `ui-ux-audit/2026-07-13/REPORT.md` is the failed 3/3 starting baseline. Current exact-package evidence passes `UI-NATIVE-001..005`: 1/4/8 runs pass survival, first-run, CPU/read, and cleanup gates; the one-terminal run passes strict visible prompt/marker proof; and the retained 30-minute soak passes survival, final-frame, telemetry, steady-state RSS-growth, and cleanup gates. Primary journeys and non-Linux proof remain open. Current alpha scope is Linux-only. Beta is blocked until Windows ConPTY and macOS native-shell/WebView/PTY paths pass, clean macOS/Windows package artifacts exist, and 3 GitHub Actions stress trend samples exist. Some module names below are historical or optional paths.

## Overview

WIZP is a high-performance code editor written in Zig. The current product path pairs a Zig backend with a Svelte/Monaco frontend in an Electrobun native shell; DVUI and platform abstraction work remain optional or historical paths. The project targets Linux for alpha, while Windows ConPTY and the macOS shell/WebView/PTY path still require implementation-level closure plus clean runner evidence before beta claims. The compatibility composite is currently 25/33 ready, while the narrower top-20 slice is 14/20; H11E retains 8 blockers split across 4 extension-owned, 3 policy-owned, and 1 host-owned row.

## Current QOL polish

The frontend keeps lightweight local preferences in browser storage so the native shell can restore a familiar working surface without requiring backend state:

| Preference | Storage key | Behavior |
|---|---|---|
| Zoom | `wizp-zoom-level` | Restores a bounded 0.5x–3x editor zoom. |
| Layout | `wizp-layout` | Restores sidebar/panel visibility, right sidebar visibility, activity-bar position, panel maximization, and bounded pane dimensions. |

Dirty editor tabs are guarded on every close path with an in-app Save / Discard / Cancel dialog. Successful saves and reverts produce visible toasts. The status bar provides focused language, indentation, encoding, and EOL pickers; language and indentation apply immediately to the active Monaco editor, and picker choices persist in `wizp-settings`. The remaining accepted polish rows are tracked in `BACKLOG.md`.

Editor session continuity is stored under `wizp:editorSession:v1`: only clean local file tabs, active group/tab, and split orientation are restored. Missing files, dirty unsaved buffers, and webviews are deliberately excluded so startup remains bounded and loss-safe.

Terminal panes track `starting`, `ready`, `exited`, `killed`, and `error` states, expose rerun-last-command from the toolbar/context menu, and sanitize stray NUL/C0 output bytes before handing data to xterm.js. Printable bytes, line controls, and ANSI escape sequences remain intact. The production entry imports xterm's required stylesheet. Successful empty `terminal/read` responses wait 100 ms and errors wait 250 ms before retry, preventing the prior immediate request loop; sustained terminal evidence also proves reader-thread join, descriptor closure, and child reaping through `scripts/check_terminal_resource_report.py`.

Current packaged-native visual evidence is deliberately narrower than full sign-off. Exact-package 1/4/8 reports prove a 60-second surviving Linux window, clean folderless first run, 5.658/3.805/1.650 reads/s/session, 3.524%/3.506%/4.452% packaged-main CPU, and bounded SIGTERM cleanup. The one-terminal report proves a deterministic prompt within two seconds plus strict marker output through the real PTY. Scheduled run `20260718T040230Z-1344056` passes the 30-minute survival/final-frame/telemetry/RSS-growth gate and clean cleanup. The accepted follow-up contracts are in [`ui-ux/TEST_BACKLOG.md`](ui-ux/TEST_BACKLOG.md), while `npm run check:ui-ux-audit` preserves the historical audit without rewriting it.

Native startup and packaging also remove inherited `LD_PRELOAD`, resolve Bun only from regular executable files, accept insignificant whitespace in JSON-RPC fields, and pre-seed Electrobun's CEF cache-format sentinel. Strict package audits enforce the launcher/cache contract. The current frontend bundle report passes with 18,979,195 total bytes, 291,264 initial HTML bytes, 151 files, and five oversized deferred assets.

Security and dependency policy is documented in [`SECURITY.md`](../SECURITY.md). The canonical dependency gate is `npm run audit:dependencies`, which audits both committed npm lockfiles at high severity; `npm run check:dependencies` validates lockfile consistency, and `npm run report:network-policy` records the default-deny/lazy network policy evidence.

### ZIPI local agent

The Activity Bar’s ZIPI Agent starts `zipi acp --no-tools` only after the user selects **Start ZIPI**. WIZP resolves the executable from `ZIPI_BIN` or `PATH`; a trusted workspace is required. Each prompt sends the user’s text, up to 40 KiB of active editor content, at most 50 LSP diagnostics, and at most 100 Git status entries. No prompt or model request occurs on startup.

ZIPI cannot directly edit workspace files in this integration. WIZP stages one-file unified diffs against an existing regular file, rejects path escapes, symlinks, unsupported operations, and stale file contents, then shows the proposal for explicit Apply or Discard. Apply uses an atomic same-directory replacement. ACP session IDs and workspace binding persist in the WIZP session; changing workspace blocks further prompts until ZIPI restarts. See [`SECURITY.md`](../SECURITY.md) for the trust and data boundary.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Systems](#core-systems)
3. [DVUI Native GUI](#dvui-native-gui)
4. [Extension System](#extension-system)
5. [Frontend Options](#frontend-options)
6. [Build System](#build-system)
7. [Development Guide](#development-guide)

---

## Architecture Overview

### Module Organization

| Directory | Purpose |
|-----------|---------|
| `buffer/` | Piece table buffer, cursor management, selection, view, Unicode support |
| `config/` | Editor configuration and settings |
| `features/` | Editor features (edit, search, UI tools, advanced) |
| `ghostty/` | Ghostty terminal emulator integration |
| `http/` | HTTP client for LLM/LSP communication |
| `hub/` | Extension hub (VSIX hosting, file watching, window API, JS runtime) |
| `keybind/` | Key binding system |
| `kilo/` | Agent system, KiloCode AI integration, tool registry |
| `lang/` | Language detection and support |
| `llm/` | LLM integration (OpenRouter, DeepSeek, Ollama) |
| `lsp/` | Language Server Protocol client |
| `mcp/` | Model Context Protocol server |
| `platform/` | Platform abstraction (Linux, macOS, Windows) |
| `plugin/` | Plugin system with Sublime Text compatibility |
| `polish/` | UX polish and onboarding flows |
| `quickjs/` | Historical QuickJS runtime path; current extension runtime is Bun-backed where documented |
| `stubs/` | Stub modules for optional dependencies (DVUI, SDL, svg2tvg) |
| `syntax/` | Syntax highlighting (Sublime grammars, TreeSitter) |
| `theme/` | Theme system (23 built-in themes) |
| `threading/` | Threading primitives (channels, worker threads) |
| `ui/` | UI components (editor, terminal, X11, AI panel) |
| `update/` | Binary diff update system |
| `vsix/` | Historical VSIX QuickJS integration path; current extension-host behavior is tracked under `hub/` and parity docs |
| `webview/` | Native webview + DVUI hybrid window (SDL3 + GTK WebKit2) with full menu bar |

### Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `get_upstream.sh` | Clone VSCode 1.98.0 + install Monaco 0.52.2 |
| `build.sh` | Full build wrapper: upstream → zig build → VSIX |
| `patch.sh` | Interactive VSCode workbench patch editor |
| `update_patches.sh` | Re-apply all patches against VSCode upstream |
| `reset.sh` | Reset vscode-upstream/ to clean state |
| `update_upstream_tracking.sh` | Update upstream/vscode.json with current VSCode commit/tag |

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                        Frontend                              │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │ Terminal │  │ Monaco (Bun) │  │ DVUI Native GUI (SDL3)│  │
│  └────┬─────┘  └──────┬───────┘  └───────────┬───────────┘  │
│       │               │                       │              │
│       └───────────────┼───────────────────────┘              │
│                       │                                      │
│              ┌────────▼────────┐                             │
│              │  Hub / Daemon   │                             │
│              └────────┬────────┘                             │
└───────────────────────┼─────────────────────────────────────┘
                        │
┌───────────────────────┼─────────────────────────────────────┐
│                       ▼                                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   Core Systems                       │    │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────────────┐  │    │
│  │  │  Buffer   │  │   LSP    │  │   Syntax/Theme   │  │    │
│  │  └───────────┘  └──────────┘  └──────────────────┘  │    │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────────────┐  │    │
│  │  │   LLM     │  │   MCP    │  │  Plugin System   │  │    │
│  │  └───────────┘  └──────────┘  └──────────────────┘  │    │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────────────┐  │    │
│  │  │Keybinds   │  │  Config  │  │  Git Integration │  │    │
│  │  └───────────┘  └──────────┘  └──────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Systems

### Buffer (`buffer/`)

The buffer system uses a **piece table** data structure for efficient text editing:

- **Piece Table**: Immutable original buffer + append-only add buffer, with a sequence of pieces referencing both
- **Cursor**: Unicode-aware cursor movement with grapheme cluster support
- **Selection**: Multi-cursor selection support
- **View**: Viewport management for efficient rendering

### LSP Client (`lsp/`)

Implements the Language Server Protocol for IDE features:

- Content-Length framed JSON-RPC protocol
- Diagnostics support
- Completion, hover, go-to-definition
- Mock server for testing

### Syntax Highlighting (`syntax/`)

Multi-backend syntax highlighting:

- **Sublime Text grammars**: Import `.sublime-syntax` files
- **TreeSitter** (optional): Incremental parsing for real-time highlighting
- Embedded syntax for nested languages (e.g., JS in HTML)

### Theme System (`theme/`)

- 23 built-in themes (Sublime/VSCode compatible)
- 24-bit color support via ANSI escapes
- Runtime theme switching

### Key Binding System (`keybind/`)

- Modal editing support (normal, insert, visual, command, search modes)
- Emacs-style key chords (Ctrl+X, Ctrl+S, etc.)
- Configurable key maps

---

## DVUI Native GUI

WIZP integrates [DVUI](https://github.com/dvui/dvui) v0.4.0 as an optional native GUI backend using SDL3 for windowing and rendering.

### Architecture

```
┌─────────────────────────────────────────────┐
│                 main.zig                     │
│  DVUI mode: DVUICore + render loop          │
│  Terminal mode: Editor.run()                │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│              dvui_core.zig                   │
│  SDLBackend.initWindow() → SDL3 window      │
│  dvui.Window.init() → DVUI window context   │
│  beginFrame() / endFrame() / addAllEvents() │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│        DVUI v0.4.0 + SDL3 Backend           │
│  dvui.box() / button() / textLayout()       │
│  dvui.scrollArea() / textEntry()            │
│  SDL3 rendering via sdl.zig backend         │
└─────────────────────────────────────────────┘
```

### DVUI Module Wiring

The build system conditionally wires DVUI modules when `-DWIZP_DVUI_AVAILABLE=true`:

| Module | Source | Purpose |
|--------|--------|---------|
| `dvui` | `dvui/src/dvui.zig` | Core DVUI library |
| `backend` | `dvui/src/backends/sdl.zig` | SDL3 rendering backend |
| `render_backend` | `dvui/src/backends/render/default.zig` | Default render backend |
| `svg2tvg` | `src/stubs/svg2tvg.zig` | Stub for SVG-to-TVG conversion |

When DVUI is disabled, lightweight stub modules are used instead, avoiding SDL3 dependency.

### DVUI Rendering

The Editor's DVUI rendering (`renderDVUI()`) uses an immediate-mode widget hierarchy:

```
hbox (horizontal)
├── Activity Bar (vertical box, fixed width)
│   ├── Explorer button
│   ├── Search button
│   ├── Hub button
│   ├── Git button
│   ├── Debug button
│   └── Extensions button
├── Sidebar (vertical box, variable width)
│   ├── File Explorer / Search / etc.
└── vbox (vertical, expand both)
    ├── Tab Bar (horizontal box)
    ├── Buffer Area (scroll area, line-by-line rendering)
    └── Status Bar (horizontal box, mode indicator)
```

### DVUI Event Loop

```
while (editor.running) {
    editor.render() →
        dvui_core.beginFrame()   // beginWait + begin
        dvui_core.addAllEvents() // SDL3 → DVUI event translation
        renderDVUI()             // Widget hierarchy
        dvui_core.endFrame()     // end + renderPresent + waitEventTimeout
}
```

### DVUI Build Requirements

- SDL3 development libraries (`libsdl3-dev` or equivalent)
- Zig 0.14.x–0.16.x

### Conditional Compilation

DVUI availability is controlled via the `WIZP_DVUI_AVAILABLE` compile-time flag:

```zig
const dvui_available = @import("dvui_available");
const DVUICore = if (dvui_available.WIZP_DVUI_AVAILABLE)
    @import("../dvui_core.zig").DVUICore
else
    struct { dummy: u8 = 0 };
```

Editor methods use `if (dvui_available.WIZP_DVUI_AVAILABLE)` to gate DVUI-specific code.

---

## Extension System

### Plugin Host (`plugin/`)

Sublime Text-compatible plugin architecture:

- Plugin discovery and lifecycle management
- Sublime Text API compatibility layer
- Event-driven plugin communication

### JSEngine (`hub/JSEngine.zig`)

JavaScript evaluation is currently documented and tested through the Bun-backed extension-host path used by the parity smokes. Older QuickJS references are historical or optional and are not the current release compatibility claim.

- Auto-detects Bun binary via `bun_options` module
- Bun-backed evaluation supports the extension-host smoke paths documented in `../../docs/vscode-parity/MATRIX.md`
- Broad Node runtime parity is not claimed; supported shims are compatibility-driven and documented in the parity docs

### VSIX Extension Hub (`hub/`)

Load and run VSIX extensions through the current extension-host path:

- **File Watcher**: Inotify-based file change notifications
- **Window API**: JavaScript-exposed window management
- **VSIX Host**: Extension loading and activation
- **JavaScript Runtime**: Bun-backed extension execution where covered by parity evidence

### MCP Server (`mcp/`)

Model Context Protocol server for AI tool integration:

- Stdio-based JSON-RPC server
- `tools/list` and `tools/call` endpoints
- Backed by `kilo/ToolRegistry`

---

## Frontend Options

### Terminal UI (`ui/`) - Primary

ANSI-based terminal interface:

- 24-bit color support
- Mouse tracking
- Efficient diff-based rendering

### DVUI Native GUI - Opt-in

SDL3-based native GUI via DVUI:

- Activity bar, sidebar, tab bar, editor, status bar
- Immediate-mode widget rendering
- Enabled via `-DWIZP_DVUI_AVAILABLE=true`

### Monaco Frontend (Experimental)

Bun-based web frontend:

- JSON-RPC communication with Zig daemon
- Monaco editor component
- LSP integration
- File tree navigation
- Command palette

### X11 Native GUI (`ui/x11.zig`) - Experimental

- Native X11 window rendering
- Requires libx11-dev

### Native WebView + DVUI Hybrid (`webview/`) - Unavailable legacy path

SDL3 DVUI window with embedded GTK WebKit2 WebView:
- **HybridWindow** (`webview/HybridWindow.zig`) — SDL3 + GTK WebKit2 via X11 reparenting
- **DVUI Menu Bar** — 8 menus (File, Edit, Selection, View, Go, Run, Terminal, Help) with 43 dropdown items
- **MenuAction** enum (41 actions) with per-frame dispatch queue
- **WebView** (`webview/WebView.zig`) — Standalone GTK WebKit2 window
- Architecture: SDL3 root window → X11 XID → GTK window → WebKit2 WebView
- Menu bar reserved space: 30px at top of SDL window
- The legacy WebKit2 implementation remains in the tree for reference, but `build.zig` exposes no `WIZP_WEBVIEW` option and this path is not a supported build mode.

### X11 Native GUI (`ui/x11.zig`) - Experimental

---

## Build System

### Requirements

- Zig 0.14.x–0.16.x (tested with current toolchain, see API notes below)
- SDL3 (for DVUI support)
- Bun (for Monaco frontend)
- libx11-dev (for X11 support)
- webkit2gtk (for webview)

### Build Commands

```bash
# Debug build (terminal mode)
zig build

# Release builds
zig build -Doptimize=ReleaseSafe   # Safe release (recommended)
zig build -Doptimize=ReleaseSmall  # Smallest binary
zig build -Doptimize=ReleaseFast   # Fastest runtime

# Supported and experimental feature flags
zig build -DWIZP_DVUI_AVAILABLE=true     # DVUI native GUI (SDL3, OpenGL)
zig build -DWIZP_X11=true                # X11 native GUI (libx11-dev)
zig build -DWIZP_QUICKJS=true            # Embedded JS runtime
zig build -DTREE_SITTER_AVAILABLE=true   # Incremental AST parsing

# All GUI features at once:
zig build -Doptimize=ReleaseSafe \
  -DWIZP_DVUI_AVAILABLE=true \
  -DWIZP_X11=true \
  -DWIZP_QUICKJS=true \
  -DTREE_SITTER_AVAILABLE=true

# Run tests
zig build test -Doptimize=ReleaseSafe
```

### Project Configuration (`build.zig.zon`)

```zig
.{
    .name = .wizp,
    .version = "0.1.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### DVUI Build Configuration

When `WIZP_DVUI_AVAILABLE=true`, the build system:

1. Creates the `dvui` module from `dvui/src/dvui.zig` with build/default options
2. Creates the `backend` module from `dvui/src/backends/sdl.zig` with SDL3 options
3. Creates the `render_backend` module from `dvui/src/backends/render/default.zig`
4. Creates an `svg2tvg` stub module from `src/stubs/svg2tvg.zig`
5. Adds C include paths for SDL3 headers (`/usr/include`)
6. Compiles `stb_image_impl.c` and `stb_image_write_impl.c` for image loading
7. Links SDL3 system library (`-lSDL3`)
8. Wires dvui ↔ backend bidirectionally

When disabled, stub modules from `src/stubs/` are used instead.

---

## Development Guide

### Adding a New Feature Module

1. Create `src/my_feature/MyFeature.zig`
2. Export a `init()`, `deinit()`, and any public functions
3. Add `@import("my_feature/MyFeature.zig")` in `src/root.zig` or appropriate parent module
4. Register in `src/main.zig` if needed

### Adding a Key Binding

```zig
// In your module
pub const MY_KEYBIND = Keybind{
    .key = "ctrl+shift+m",
    .mode = .normal,
    .action = &myActionFunction,
};
```

### Adding a Theme

Themes are defined as structs implementing the Theme interface:

```zig
pub const my_theme = Theme{
    .name = "My Theme",
    .background = 0x1e1e1e,
    .foreground = 0xd4d4d4,
    // ... other colors
};
```

### Working with DVUI

To add DVUI rendering to a widget:

```zig
fn renderMyWidgetDVUI(self: *Self) !void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .r = 30, .g = 30, .b = 30, .a = 255 },
    });
    defer box.deinit();

    var label = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
    label.addText("Hello, WIZP!", .{});
    label.deinit();
}
```

Key DVUI v0.4.0 API patterns:
- Use `dvui.box()` for layout containers with `.dir = .horizontal` or `.dir = .vertical`
- Use `.min_size_content` for fixed sizes (not `.fixed`)
- Use `.color_fill` for background colors (not `.color`)
- Use `.color_text` for text colors in text layout options
- Use `.expand = .both` or `.expand = .horizontal` for flexible sizing
- Always call `defer widget.deinit()` after creating widgets

### Testing

- Unit tests: `zig test src/my_module.zig`
- Integration tests: `zig build test -Doptimize=ReleaseSafe` (runs all tests, ✅ PASSING 2026-05-19)

### Zig API Notes

The project uses a custom `std.array_list.Managed(T)` type (3-field struct):
```zig
// Zero-value init (module-level globals)
var list: Managed(T) = .{ .allocator = undefined, .items = &[_]T{}, .capacity = 0 };

// Init with allocator
var list = Managed(T).init(allocator);
```

Key patterns:
- `appendSlice(slice)` — 1 argument
- `.deinit()` — 0 args for Managed; `StringHashMapUnmanaged.deinit(allocator)` needs allocator
- No `.empty` property on Managed
- Struct literals must specify ALL fields (no partial init)

### Code Conventions

- No comments unless explicitly necessary
- Error handling: use `catch {}` for UI resilience, proper error propagation for core systems
- Naming: PascalCase for types, snake_case for functions/variables
- Module organization: one module per directory, single responsibility
