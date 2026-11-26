# WIZP — Ultra-Lightweight Code Editor

> Status, 2026-08-12: Linux-first alpha scope remains the supported release boundary. The exact self-contained package passes `UI-NATIVE-001..005`; Chromium covers the complete Explorer/editor/Search/SCM/Debug/Extensions/Settings lifecycle, accessibility journey, supported 1920/1440/1280/1024 layouts, 200% app zoom, compact-shell behavior, and a measured Monaco-loaded `one-light` theme switch. Packaged editor run `20260812T203615Z-1613262` proves the bounded open/edit/save/Save As/recovery/session-restore/close-all journey. Packaged Settings run `20260812T214821Z-1981100` proves keyboard edit/discard/save/reopen and focus behavior. Packaged Explorer run `20260812T221451Z-2137710` proves navigation and lifecycle/error recovery. Packaged Search run `20260812T224109Z-2217520` proves query/filter/mode/context controls, recovery, navigation, bounded reporting, replacement, filesystem-permission preservation, semantics, and cleanup. Manual assistive-technology, remaining full contracts, and non-Linux proof remain open.

Zig-native code editor with Monaco frontend + Svelte 5 UI + Electrobun shell. No Electron. The backend target is under 45 MB; the self-contained Linux package is much larger because it includes CEF and runtime libraries.

## Isolated UI test policy

`scripts/run_virtual_ui_test.sh` delegates to `overzeer-isolated-display` and
requires Openbox for the default session. The shared runner hides the host X11,
Wayland, and session-bus sockets behind private bubblewrap mounts, starts a
private D-Bus plus Xvfb, serializes graphical tests, checks pressure, applies a
hard timeout, and kills the contained process group. Missing isolation fails
closed. Nested KWin remains disabled unless an explicit compositor test sets
`WIZP_VIRTUAL_WM=kwin_x11 WIZP_ALLOW_NESTED_KWIN=1`; it still runs only inside
the private display namespace.

## Status

- Build: `zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu`
- Frontend: `cd frontend && npm run build`
- Parity evidence: see [`../docs/vscode-parity/MATRIX.md`](../docs/vscode-parity/MATRIX.md)
- Scope: Linux-first. macOS/Windows support is tracked as platform work, not complete.
- Beta gate: blocked until real Windows ConPTY and macOS native-shell/WebView/PTY paths pass, clean macOS/Windows package artifacts exist, and 3 GitHub Actions stress trend samples exist. Current local artifacts have valid Linux evidence, no macOS/Windows package evidence, and 0/3 required GitHub Actions stress samples. Run `npm run status:beta-gates` for the generated state.
- Planning estimate: [`../docs/release/SHIP_READINESS.md`](../docs/release/SHIP_READINESS.md) forecasts 85% / 9-15 focused days to a Linux alpha release candidate and 67% / 42-62 focused days to cross-platform beta; proof gates still decide release status.
- Native UI/UX gate: exact-package baseline reports pass `UI-NATIVE-001..005`; retained editor run `20260812T203615Z-1613262` passes its bounded fixture-backed editor journey, Settings run `20260812T214821Z-1981100` passes keyboard edit/discard/save/reopen and focus behavior, Explorer run `20260812T221451Z-2137710` passes pointer/keyboard navigation and lifecycle/error recovery, and Search run `20260812T224109Z-2217520` passes query/filter/mode/context controls, recovery, navigation, bounded reporting, replace-one/all, filesystem-permission preservation, semantics, and cleanup. `UI-NATIVE-006..013` remain partial or open at their full contracts, with manual assistive-technology and non-Linux proof scoped separately. See [`REPORT.md`](docs/ui-ux-audit/2026-07-13/REPORT.md) and [`TEST_BACKLOG.md`](docs/ui-ux/TEST_BACKLOG.md).
- Audit contract: `npm run check:ui-ux-audit` protects accepted evidence, backlog IDs, documentation links, and verification wiring. `npm run test:ui-contract` and `npm run test:parity:playwright` retain source/browser lifecycle coverage. Automated native UI commands run only through isolated Xvfb with Openbox; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1` compositor testing, unavailable isolation fails closed, and failed packets close no rows.
- Visual/responsive contract: `npm run check:ui-visual` records nine default static token measurements; the Playwright lane retains 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact-shell, zero-horizontal-overflow, Settings-fit, and a passing `one-light` surface/control/boundary/focus contrast measurement. These checks do not close native high-DPI, extension-theme, or manual accessibility rows.

## Quick Start

Build the Zig backend:

```bash
cd wizp
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
```

Output: `zig-out/bin/wizp` (about 44 MB).

Build the Svelte 5 frontend:

```bash
cd wizp/frontend
npm install
npm run build
```

Current budget report: 19,086,499 total bytes; 325,514 initial HTML bytes.

Run with Electrobun (recommended):

```bash
cd wizp
bun run dev:electrobun
```


Open text files or a workspace from the packaged launcher:

```bash
build/dev-linux-x64/WIZP-dev/bin/launcher path/to/file.ts
build/dev-linux-x64/WIZP-dev/bin/launcher path/to/project
```

Multiple paths are accepted. Directories select the workspace; `.code-workspace`
files use the workspace-file loader. The Linux desktop entry forwards `%F` for
the same text-oriented file set. WIZP does not claim binary, image, archive, or
arbitrary MIME handling.

Package for distribution:

```bash
cd wizp
npm run build:self-contained
```

Output: `build/dev-linux-x64/WIZP-dev/`. The packaged binary is under
`Resources/app/wizp`, the launcher is `bin/launcher`, and the current
release-shaped Linux package is 682.3 MiB installed after atomic ELF stripping.
CEF remains bundled; `build/parity-package/linux-package-prune.json` records the
package size and stripping/locale savings.

### CEF runtime and EuroOffice

WIZP's Linux package is intentionally self-contained. Electrobun 1.18.1's
Linux CEF payload is CEF `147.0.10+gd58e84d` / Chromium `147.0.7727.118`,
stored under `bin/cef`; Electrobun also copies selected libraries/resources
beside the launcher and ships its own `process_helper`, native wrapper, Bun,
and app resources. Electrobun's `bundleCEF` switch selects bundled CEF versus
the host-native renderer; `cefVersion` selects an Electrobun CEF build. Neither
configures an arbitrary external CEF root. WIZP therefore has no supported
shared-runtime mode.

We compared the installed Electrobun CEF input with EuroOffice's published
`eurooffice/v9.3.8-dinx5` package (package SHA-256
`15a85ddd69ffb1009a462e9d4ca77975a7d97c6e83351ac2315999d1a92ad97b`).
EuroOffice's release metadata identifies the upstream 9.3.8 Debian payload
SHA-256 as `1816c4cd5d5806b757468c3dc57ec76c23acd1ea0852d441e50d6a549d217da1`;
its metadata does not state the embedded CEF version. Comparing the actual
published package files shows different CEF binaries and resources:

| File | WIZP Electrobun 1.18.1 input SHA-256 | EuroOffice 9.3.8-5 SHA-256 |
| --- | --- | --- |
| `libcef.so` | `5f72fd935d77dad7c21c70ce88528fcfceeb3fdc023b2e1f14585201176cd651` (ELF Build ID `8a4b59047a9905a0f36bc98e0caf4b66698574ec`) | `b86edf848d4c18c70d76eba7bcce766d2f5d735ac56effeb11fcf4ee47771689` (ELF Build ID `464d364bd6d0b7a2fe5f0c6663ee1e238ad858f2`) |
| `icudtl.dat` | `1cf67874b5a87a8363a86fb3f81e3cbbed54d389062dab8fb52308d5cf8c8612` | `97b978a19edd4746e9a44d9a44bb4bc519e127a203c247837ec0922f573449e3` |
| `resources.pak` | `88a6819d93c69108735923df202d5cd3c7295279f1e52e64ebd074ca7b78fbde` | `0c22a7412231d3cfda1663e9a1815a2d1f9f311322946669a3e2240010cc2e7d` |
| `v8_context_snapshot.bin` | `b456736ed60b392948cc31f705b87506363de03c739c6ede05d747021f30b729` | `474eccca3a12af4f6a37409b02dd9e8004f6675b519581d26900f759d9244a6a` |
| `snapshot_blob.bin` | Not present in Electrobun 1.18.1 Linux CEF input | `76a8cd79ae104dc59a3390cc852c8a8b6bb057ee38dcc40903ea427475740d56` |

The WIZP `libcef.so` hash is the Electrobun dependency input; DINX package
pruning strips ELF files, so its final installed hash can differ. EuroOffice's
hash is from its stripped published package. The different build IDs and
resource hashes establish non-identical runtime contents despite strip-state
differences. EuroOffice also trims its packaged CEF locale set.

SquashFS deduplicates identical file contents, but it cannot deduplicate these
different binaries/resources. WIZP keeps its bundled runtime; no symlinks or
external paths are introduced.

For a future candidate, compare the exact package trees without changing
either application:

```bash
python3 scripts/check_cef_payload_equivalence.py \\
  /path/to/WIZP-dev /opt/eurooffice
```

The probe prints per-file hashes and missing/mismatched payload paths. A
byte-identical payload is necessary, not sufficient, for runtime sharing; the
probe does not validate ABI, loader/subprocess behavior, or external-runtime
support. WIZP remains self-contained regardless of probe result.

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Electrobun Shell (Bun Main Process)             │
│  ┌────────────────────────────────────────────┐  │
│  │  Native Menu Bar: File Edit View Help      │  │
│  ├────────────────────────────────────────────┤  │
│  │  Frameless Window (native WebView)         │  │
│  │  ┌──────────────────────────────────────┐  │  │
│  │  │  Svelte 5 + Monaco 0.52.2            │  │  │
│  │  │  • Editor groups/tabs (up to 4-way)  │  │  │
│  │  │  • File explorer (recursive tree)   │  │  │
│  │  │  • Search (grep + regex)            │  │  │
│  │  │  • SCM (stage/commit/diff)          │  │  │
│  │  │  • Terminal (xterm.js + PTY)        │  │  │
│  │  │  • Debug (DAP client)               │  │  │
│  │  │  • Problems / Output panels         │  │  │
│  │  │  • Extensions (OpenVSX)             │  │  │
│  │  │  • Settings (JSON + localStorage)   │  │  │
│  │  └──────────────┬───────────────────────┘  │  │
│  │                 │ Electrobun typed RPC     │  │
│  │  ┌──────────────▼───────────────────────┐  │  │
│  │  │  Zig Daemon (wizp --daemon)          │  │  │
│  │  │  • LSP client (multi-server)         │  │  │
│  │  │  • PTY terminal (zigpty)             │  │  │
│  │  │  • Git operations                   │  │  │
│  │  │  • File I/O + watching (inotify)    │  │  │
│  │  │  • Extension host (Bun JS engine)   │  │  │
│  │  │  • DAP client (debug adapter)       │  │  │
│  │  │  • Undo/redo (piece table history)  │  │  │
│  │  │  • Code folding                     │  │  │
│  │  │  • Theme engine (23 themes)         │  │  │
│  │  └──────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

RPC flow:

```
Svelte WebView ─Electrobun typed RPC─→ Bun Main ─stdio CL framing─→ Zig daemon
              ↕ fallback (dev mode)
Svelte WebView ─────fetch /api/rpc────→ Zig embedded HTTP ─stdio──→ Zig daemon
```
Terminal sessions use `terminal/*` JSON-RPC and `/api/terminal/stream`; the removed `/api/terminal/poll` endpoint is not a compatibility path. Extension bridge failures return explicit HTTP or JSON-RPC errors instead of empty success payloads.


## Features

| Feature | Current claim | Details |
|---------|---------------|---------|
| Editor | Scoped parity evidence | Monaco editor plus verified document/edit/save/find/snippet/settings contracts; deeper render/apply smoke remains tracked. |
| LSP/language intelligence | Scoped parity evidence | Core native routes and extension-provider fixtures pass; deep native server lifecycle/capability parity remains tracked. |
| Git/SCM | Browser-passing, native-open | Persistent commit validation, selected/all staging, stage/unstage/diff actions, discard and untracked-delete confirmation, branch checkout, history-to-diff navigation, conflict preview/resolution, Git failure recovery, remotes policy, blame, and extension SCM provider coverage pass in Chromium. Packaged `UI-NATIVE-009` evidence remains open. |
| Terminal | Scoped parity evidence | xterm.js + zigpty with independent PTY sessions, restore/dispose policy, profiles, links/find, tasks, and extension-created terminal coverage; packaged-native one-terminal prompt/output and the 1/4/8 CPU/read baseline pass, while the deeper `UI-NATIVE-013` journey remains open. The optional DVUI panel reports session state; the web shell renders PTY output. |
| Search | Browser-passing, native-partial | Folder selection sets the active workspace; Chromium covers the full Search lifecycle. Retained packaged Linux run `20260812T224109Z-2217520` proves query/results, case/whole-word/regex and include/exclude/context controls, invalid-regex and zero-result recovery, cancellation, result navigation, the 100-result limit, replace-one, confirmation-backed replace-all with focus return, real filesystem-permission failure preservation, semantics, and cleanup. Injected RPC failure/retry, assistive-technology, and non-Linux proof remain open. |
| Debug | Browser-passing, native-open | Backend-owned workspace launch configuration, missing/invalid configuration recovery, adapter failure recovery, accurate running/paused state, pause/continue/step/restart/stop, call stack, variables, watches, breakpoint removal, evaluation recovery, toolbar synchronization, and stop-focus restoration pass in Chromium. Packaged `UI-NATIVE-010` evidence remains open. |
| Extensions | Browser-passing, native-open | Session-scoped OpenVSX consent, real store/deflate VSIX extraction, persistent local install and enable/disable state, uninstall confirmation, host unavailable/retry/restart, install failure recovery, and command/view/settings contributions pass daemon and Chromium fixtures. Packaged file-chooser, permission, host-crash, accessibility-tree, and assistive-technology proof for `UI-NATIVE-011` remains open; broader API compatibility stays tiered. |
| Problems/Output/Settings | Browser-passing, native-partial | Settings validation, persistence, progress, partial-sync retry, modal shortcut isolation, and keyboard/pointer focus behavior pass in Chromium. Retained packaged Linux run `20260812T214821Z-1981100` proves `Ctrl+,` open, keyboard edits, Cancel/Escape discard and reopen, Apply & Save backend sync, saved-value reopen, dialog semantics/focus containment, Activity Bar trigger focus return, and cleanup; injected partial-sync failure, assistive-technology, and non-Linux paths stay open. |
| Themes/UI shell | WIZP-specific | WIZP preserves its custom UI/UX while implementing compatible behavior. |

## Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Shell | Electrobun + Bun | Native WebView, typed RPC, self-contained Linux packaging with bundled CEF/runtime dependencies |
| Frontend | Svelte 5 (Runes) + Vite | Budgeted bundle: 19,086,499 total bytes, 325,514 initial HTML bytes, 152 files, five oversized deferred assets |
| UI | shadcn-svelte + Bits UI | Beautiful, zero-runtime, VSCode-style |
| Styling | Tailwind CSS v4 | Utility-first, easy theming |
| Editor | Monaco 0.52.2 | `monaco-upstream` is the sole bundled Monaco runtime, 70+ language bundles |
| Terminal | xterm.js + FitAddon | Web-native PTY rendering |
| Backend | Zig 0.17.0 | Multi-threaded, piece-table buffer, LSP/DAP clients |
| PTY | zigpty | Cross-platform pseudo-terminal |
| JS Engine | Bun | Extension host JS runtime |
| Extensions | OpenVSX + VSIX | Marketplace compatibility |

## Build Options

```
# Default Monaco frontend + embedded HTTP server
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu

# Terminal UI mode (stdin/stdout)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu && ./zig-out/bin/wizp --terminal

# Non-interactive startup probe used by package checks
./zig-out/bin/wizp --terminal-probe

# In a generated package root
./wizp --package-smoke

# Bundled frontend package (build and install frontend/dist)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -DWIZP_BUNDLED_FRONTEND=true

# Tree-sitter incremental parsing (optional)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -DTREE_SITTER_AVAILABLE=true

# DVUI native GUI (SDL3, optional)
zig build -Doptimize=ReleaseSafe -DWIZP_DVUI_AVAILABLE=true

# Run tests
zig build test -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
```

## Feature Flags

| Flag | Default | Description |
|------|---------|-------------|
| `TREE_SITTER_AVAILABLE` | false | Incremental AST parsing |
| `WIZP_DVUI_AVAILABLE` | false | DVUI/SDL3 native GUI |
| `WIZP_QUICKJS` | unavailable | Historical QuickJS path; sources are not vendored. Use the Bun-backed extension host. |
| `WIZP_X11` | false/Linux only | Optional X11 native GUI executable (`wizp-native`) |
| `WIZP_BUNDLED_FRONTEND` | false | Build and package the Vite frontend dist tree |
| `WIZP_BUN` | auto | Path to Bun binary |

Build-mode support status:

| Mode | Status | Required proof |
|------|--------|----------------|
| Terminal UI | supported scope | Linux `--terminal` and `--terminal-probe` smoke |
| Monaco frontend + embedded HTTP daemon | supported scope | Vite build, packaged asset freshness, package audit, and daemon smoke |
| Bundled frontend | supported scope | Vite build, packaged asset freshness, package audit |
| Tree-sitter | experimental | Target build and syntax smoke with grammars enabled |
| QuickJS | unavailable | No vendored runtime sources; do not enable `WIZP_QUICKJS` until a reviewed runtime is restored. |
| DVUI/SDL3 | experimental | Target build and native-window smoke with SDL3 available |
| X11 native GUI | experimental/Linux only | `wizp-native` build and X11 startup smoke |
| WebKit2GTK legacy webview flag | unavailable | No current `build.zig` option; do not advertise as supported |

## Frontend Scripts

```bash
cd frontend
npm run dev       # Vite dev server
npm run build     # Vite production build
npm run preview   # Preview production build
```

## Packaging

```
zig-out/bin/wizp
frontend/dist/
                   ──Electrobun self-contained bundling──→ Linux package with Vite assets and bundled CEF/runtime dependencies
```

## Known Limitations

- Alpha scope is Linux-only with scoped VS Code parity and tiered extension compatibility.
- Linux only for alpha. macOS/Windows native shell, WebView, PTY, workspace, extension-host, and diagnostics behavior require clean runner artifacts before beta claims.
- Beta readiness is currently blocked: valid cross-OS systems are `linux`; missing systems are `darwin` and `windows`; stress trends require 3 GitHub Actions samples and currently have 3 local/manual samples but 0/3 required GitHub Actions samples.
- The retained Linux native packet covers `UI-NATIVE-001..005`, fresh first-run and prompt/input evidence, and historical 1/4/8-terminal/read/soak artifacts. The latest 60-second single-terminal run kept the window, prompt, typed marker, and folderless recovery healthy but measured 5.333% packaged-main CPU against the 5% budget, so the current CPU row remains open.
- Zig builds require `-Dtarget=x86_64-linux-gnu` on GCC 16+ systems (.sframe incompatibility)
- Debug adapter requires gdb/lldb/node installed on PATH
- Extensions API is tiered; see [`../docs/vscode-parity/EXTENSION_COMPATIBILITY.md`](../docs/vscode-parity/EXTENSION_COMPATIBILITY.md) and [`../docs/vscode-parity/KNOWN_EXTENSIONS.md`](../docs/vscode-parity/KNOWN_EXTENSIONS.md)
- OpenVSX, Git network remotes, real-extension runtime checks, update checks, AI/agent integrations, and extension-owned network work are lazy/opt-in for alpha.
- Updates are manual-only for alpha unless the release artifact includes signed-update fixture smoke evidence.
- `page_allocator` used throughout (mmap/munmap per alloc/free)

## License

MIT
