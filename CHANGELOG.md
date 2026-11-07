# Changelog

## [Unreleased] — 2026-07-18

### Added
- Updated WIZP's public ZLAY and zigpty dependencies for Zig 0.17 module graphs; imported sibling source modules explicitly and separated zigpty's shared platform types from backend modules to avoid cyclic imports.
- Kept build-time Bun selection separate from runtime Bun lookup so Windows cross-packages do not probe the Linux build-host executable path; Windows Bun lookup now uses `.exe` names and `;`-separated `PATH`.
- Reused layout-stable inline validation in Explorer create and rename dialogs; valid edits clear validation errors without hiding backend failures.
- Added determinate extension-task progress from reported increments, with an indeterminate state when progress is unknown.
- Added an explicit “Show up to 500 results” path for truncated workspace text searches; search limits are bounded and reported by the backend.
- Added a Winsock-backed Windows transport for the browser-backed WIZP executable, avoiding Zig 0.16 AFD startup failures; Windows package builds now embed `frontend/dist` and launch the default browser.
- Fixed packaged Linux terminal polling, per-session input/rerun ordering, rerun focus, native URL opening, structured spawn errors, and large-output RPC framing. Renderer writes now apply backpressure; native input refuses unverified focus.
- Made native terminal pressure deterministic across a paused renderer and an in-flight read, with complete rendered/dropped-byte accounting. Teardown now waits for session-detached descendants before removing profiles, and rejected evidence returns a failing exit status.
- Replaced full-buffer PTY overflow shifts with circular writes, preserving the 16 MiB bound, newest-byte ordering, and exact dropped-byte counts.
- Added the Paseo color theme: pure-black editor surfaces with a Zinc neutral palette, runtime theme switching, Monaco integration, and Settings preview.
- Routed all native display tests through `overzeer-isolated-display`, which hides host desktop sockets with private bubblewrap mounts and provides serialized, pressure-gated Xvfb/Openbox execution with bounded process-group teardown.
- Hardened virtual UI tests: Openbox is now the only default window manager, nested `kwin_x11 --replace` is refused unless explicitly enabled for compositor testing, and every test command has a bounded timeout.
- Packaged Settings continuation: run `20260812T214821Z-1981100` retains real `Ctrl+,` opening, keyboard field navigation, screenshot-backed edits, Cancel/Escape discard and reopen, Apply & Save backend sync, saved-value reopen, dialog semantics/focus containment, Activity Bar trigger focus return, short-profile cleanup, and clean process teardown.
- Settings modal hardening: the Activity Bar trigger now exposes the dialog relationship and establishes pointer focus before opening; Chromium verifies focus return and blocks workbench, extension, zoom, and fullscreen shortcuts while the modal owns input.
- Native UI isolation: `run_virtual_ui_test.sh` selects Openbox or KWin inside Xvfb, marks the virtual display, keeps software rendering, and fails closed without an isolated window manager.
- Packaged editor journey: added virtual focus-proxy/root-capture fallbacks and reached fixture workspace selection under KWin; Quick Open text still routes into the terminal, so `UI-NATIVE-006` remains open.
- Editor recovery: Save As failure keeps URI/content/dirty state with an actionable error, and Close All Editors is exposed through File and Command Palette with cross-group cleanup coverage.
- Native Settings harness: tolerate bounded OCR separator loss and theme-dependent OCR degradation, derive pointer targets from actual viewport pixels, and use packaged webview state for lifecycle/value assertions while retaining screenshot/OCR diagnostics.
- Packaged Explorer journey: retained run `20260812T221451Z-2137710` proves pointer/keyboard expand/collapse, roving tree focus, Arrow/Home/End navigation, keyboard context menus, create/rename/delete dialogs, duplicate-create recovery, copy/paste, refresh, filesystem-permission and removed-directory recovery, empty folders, long Unicode paths, outline navigation, semantic snapshots, and clean teardown. Scheduled parity-hardening validates and uploads the packet.
- Packaged Search journey: retained run `20260812T224109Z-2217520` proves fixture-backed query/results, case/whole-word/regex and include/exclude/context controls, invalid-regex and zero-result recovery, pending-search cancellation, editor navigation, bounded 100-result reporting, replace-one, confirmation-backed replace-all with focus return, real filesystem-permission failure preservation, semantic snapshots, screenshot/OCR diagnostics, disposable-profile cleanup, and clean teardown. Scheduled parity-hardening validates and uploads the packet.
- Dynamic built-in-theme gate: Chromium switches a Monaco-loaded workbench to `one-light`, retains a Settings screenshot, and measures 10.86:1 surface text, 9.65:1 control text, 3.12:1 control boundary, and 3.84:1 focus contrast.
- Workbench visual/responsive packet: editor tabs now expose active/dirty/pinned/close states, breadcrumbs handle long paths, 1024px layouts yield the right sidebar, large UI scale collapses secondary menus/status detail, Welcome adapts to narrow space, and Settings uses a compact native theme selector.
- Responsive browser gate: the Chromium lane retains 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact-shell, zero-horizontal-overflow, and Settings-fit screenshots plus `responsive-report.json`.
- Visual token contract: `npm run check:ui-visual` records nine default static token contrast measurements with explicit extension-theme/native/manual proof limits.
- Production-copy contract: `npm run test:ui-contract` now scans source and built frontend assets for forbidden demo/example/milestone copy.
- **First native group closed** — Exact-package 1/4/8-terminal runs pass survival, first-run, CPU/read, and cleanup gates; the one-terminal run passes strict prompt/marker proof; and scheduled run `20260718T040230Z-1344056` passes 1804.055-second survival, final-frame, telemetry, steady-state RSS-growth, and cleanup gates. This closes `UI-NATIVE-001..005` on Linux without broadening the claim to deeper journeys or other platforms.
- **Scoped CEF idle backoff** — The Linux package vendors and audits `libwizp_cef_xcb_backoff.so`, leaving normal XCB replies untouched while applying bounded backoff only after sustained unanswered main-thread polls. Packaged termination now performs WIZP state/backend cleanup before a bounded Electrobun native exit.
- **Retained RSS reconciliation** — Native memory growth now starts at the first steady process-tree sample rather than the launcher-only sample; raw reports can be deterministically reconciled with `scripts/reconcile_native_ui_report.py`.
- **Correct bundled-renderer contract** — CEF-bundled builds now generate CEF as the platform default instead of hard-coding the host-native renderer in the main window. Package-layout and strict artifact audits verify the generated renderer contract and bundled availability.
- **Earlier corrected-renderer checkpoint** — The first 1/4/8 corrected-renderer packet retained survival, first-run, read-rate, and profile evidence but still failed CPU, prompt/marker, teardown, and soak gates; the later passing packet above supersedes it for current status.
- **Fail-closed native input evidence** — Non-soak reports are preserved by terminal-count alias; desktop automation revalidates the exact active WIZP window immediately before typing and submit; and the process-group grace period accounts for Electrobun's five-second native quit wait without hiding forced cleanup.
- **Bounded CPU diagnosis** — Live thread evidence and controlled timer probes isolate Electrobun's fixed 10 ms Linux CEF/GTK pump. Slower 20-100 ms fixed delays regress surface/prompt latency, so no unsafe preload/delay shim was shipped.
- **Packaged-native baseline harness** — Added isolated Linux profile/workspace fixtures, visible X11 input, OCR-backed screenshots, HTTP metrics, descendant CPU/RSS sampling, deterministic teardown, contract tests, and scheduled CI wiring.
- **Scoped native baseline truth** — Added native window lifecycle sampling and refreshed standard 60-second run `20260714T204058Z-1336779`: `windowLifecycle.firstLoss=null`, final X11 probe present at 60.001 seconds, prompt OCR within 1.404 seconds, marker-output OCR passed, final-frame OCR passed, and `UI-NATIVE-001`, `UI-NATIVE-004`, and `UI-NATIVE-005` are green for the standard lane. Current native sign-off still stays blocked by CPU, CEF profile warning, and soak evidence.
- **Earlier conservative resource checkpoint** — Kept `UI-NATIVE-003` failed/partial when request rates were bounded but packaged-main CPU still failed; this intermediate truth is superseded by the passing exact-package matrix above.
- **Native request-log and baseline guard** — Routine embedded-server request logs are opt-in via `WIZP_HTTP_REQUEST_LOGS`, backend-ready retry sleeps after non-204 responses, and the native baseline records role/thread CPU attribution, CEF/profile/runtime diagnostics, terminal poll telemetry, window lifecycle sampling, scheduled-soak claims, and retained final-frame artifacts. Earlier focused poll and failed-soak packets remain historical diagnostic evidence; the passing packet above is current status.
- **Bounded package pruning** — Repeated verifier runs now skip ELF stripping by default so pruning cannot hang on CEF/runtime binaries; strict package audits remain the correctness gate, and `--strip` is still available for explicit size-optimization runs.
- **Terminal runtime hardening** — Imported xterm's required stylesheet, added bounded successful-empty/error polling cadence, and hardened PTY reader shutdown, descriptor closure, and child reaping with focused evidence.
- **Native transport/runtime hardening** — Accepted whitespace around JSON-RPC fields, made Bun resolution reject directories in favor of regular executables, and removed inherited `LD_PRELOAD` before child startup.
- **CEF/package integrity** — Seeded Electrobun's CEF cache-format sentinel in the launcher and extended strict package auditing to require it.
- **Beta handoff integrity** — Extended handoff validation to verify every published artifact path and digest while preserving missing macOS/Windows and CI-history blockers.
- **Parity truth reconciliation** — Recorded 25/33 compatibility rows ready and 14/20 in the narrower top-20 slice; the 8 H11E blockers split into 4 extension-owned, 3 policy-owned, and 1 host-owned row.
- **Native UI/UX audit truth** — Recorded the failed 3/3 packaged-launch baseline, two accepted current-run screenshots, blocked downstream flows, code-level risks, and conservative evidence limits in `docs/ui-ux-audit/2026-07-13/REPORT.md`.
- **Executable UI/UX queue** — Added 23 ordered native, contract, accessibility, visual, and recovery test rows with a deterministic workspace fixture and required failure artifacts in `docs/ui-ux/TEST_BACKLOG.md`.
- **UI/UX audit contract** — Added `npm run check:ui-ux-audit` and broad `npm run verify` wiring to preserve 13 canonical product rows, all 23 test IDs, accepted screenshot checksums/dimensions, rejected-capture cleanup, and docs links.
- **Figma-ready handoff** — Preserved exact Section/card placement, 200 px screenshot spacing, notes, checksums, and acceptance checks without claiming a Figma board exists while the required capability is unavailable.
- **Local stress evidence refresh** — Re-ran the real stress-budget contract and refreshed local startup, large-repo, large-file, memory, and crash-recovery measurements without changing the CI-only evidence boundary.
- **Linux release-leg refresh** — Re-ran the real Linux cross-OS package smoke and refreshed aggregate/beta artifacts; Linux remains verified while darwin/windows remain external blockers.
- **H11E ownership triage** — Recorded all eight artifact-backed performance blockers as extension-owned, including their activation, first-result, and spawned-process budget failures; no host-owned false closure was introduced.
- **Native bundle freshness** — Added a Zig build-graph dependency on the generated frontend manifest so Electrobun packaging refreshes when Vite hashes change; completed a clean cache/temp rebuild and native probe.
- **Release verification target** — Broad `npm run verify` now builds the musl/CEF release-shaped package before strict auditing, preventing the dev-package layout from creating false missing-CEF and dynamic-linking failures.
- **Frontend lint cleanup** — Removed the safe mechanical `prefer-const` warning set, reducing lint warnings from 250 to 188 with zero errors while leaving behavior-sensitive findings for separate slices.
- **Dead frontend symbol cleanup** — Removed proven-unused imports and constants, reducing the warning baseline from 188 to 174 with zero errors; keyed-list, empty-catch, and DOM warnings remain explicitly open.
- **Bridge and leaf lint cleanup** — Removed unused bridge declarations and small-component symbols, reducing the warning baseline from 174 to 159 with zero errors while preserving behavior-sensitive findings for later review.
- **Editor callback lint cleanup** — Documented intentionally unused Monaco callback parameters and removed an unreferenced drag-state cell, reducing warnings from 159 to 147 with zero errors.
- **Frontend lint and cache hygiene** — Removed unused catch bindings and remaining dead leaf symbols, reducing warnings from 147 to 122; cleaned transient build caches and `/tmp/wizp-*` artifacts after verification.
- **Final lint/cache pass** — Removed the last unused frontend symbols, reducing warnings from 122 to 119, and repeated post-build transient cache/temp cleanup.
- **Best-effort catch documentation** — Annotated silent startup/theme compatibility catches, reducing warnings from 119 to 107 without changing failure behavior; completed another cache/temp cleanup.
- **Leaf catch documentation** — Annotated intentional best-effort catches in smaller frontend components, reducing warnings from 107 to 95; completed post-build cache/temp cleanup again.
- **Settings/sidebar catch documentation** — Annotated intentional debug, theme, and remote-settings catches, reducing warnings from 95 to 87; completed another post-build cache/temp cleanup.
- **Small-list reconciliation** — Added stable Svelte keys to activity, context, debug, and welcome lists, reducing warnings from 87 to 79; completed another post-build cache/temp cleanup.
- **Data-list reconciliation** — Added stable keys to explorer, outline, hub, quick-pick, search, status, tree, and prompt lists, reducing warnings from 79 to 69; completed another post-build cache/temp cleanup.
- **Sidebar/panel reconciliation** — Added stable keys to settings, SCM/debug/extension, terminal, problems, output, and console lists, reducing warnings from 69 to 46; completed another post-build cache/temp cleanup.
- **Final keyed-list reconciliation** — Added stable keys to editor tabs, breadcrumbs, skeleton rows, dropdown items, and terminal groups, reducing warnings from 46 to 42; completed another post-build cache/temp cleanup.
- **Editor lifecycle catch documentation** — Annotated optional editor lifecycle, persistence, webview, and teardown catches, reducing warnings from 42 to 26; completed another post-build cache/temp cleanup.
- **Monaco fallback documentation** — Annotated provider fallback and registration catches, reducing warnings from 26 to 17; completed another post-build cache/temp cleanup.
- **Settings persistence documentation** — Annotated independent backend preference-write fallbacks, reducing warnings from 17 to 6; completed another post-build cache/temp cleanup.
- **Lint-clean frontend** — Scoped the six intentional legacy DOM renderer suppressions with rationale, reaching 0 lint warnings and 0 errors; completed another post-build cache/temp cleanup.
- **Release evidence refresh** — Re-ran local stress and Linux package smokes and regenerated release truth artifacts; macOS/Windows evidence, GitHub Actions stress samples, and extension timing remain explicitly open.
- **Release evidence handoff** — Added a runbook and contract check covering external OS artifacts, GitHub Actions stress-history recording, validation commands, and conservative closure boundaries.
- **Extension timing boundary** — Added a contract check that preserves unverified extension timing, eight extension-owned H11E blockers, and blocked promotion until paired evidence exists.
- **CI evidence handoff wiring** — The beta aggregation job now validates the release-evidence runbook before downloading artifacts; the workflow contract protects the step.
- **CI artifact intake resilience** — Beta aggregation now treats upstream evidence downloads as best-effort, preserving an explicit blocked readiness report when proof is missing.
- **Beta readiness contract** — Added `npm run check:beta-readiness` and CI wiring to reject internally inconsistent readiness reports without weakening external evidence gates.
- **Beta readiness contract tests** — Added focused coverage for blocked/ready states, cross-OS partition drift, and invalid stress history fields.
- **Beta handoff artifact** — The published beta-readiness artifact now includes the machine-checkable cross-OS aggregate beside the readiness summary.
- **Beta handoff integrity** — Added `npm run check:beta-handoff` to validate presence and cross-OS partition agreement across both published reports.
- **CI evidence consumption** — Beta aggregation now runs cross-OS and stress-history validators after artifact download while retaining failure-visible blocked reporting.
- **Stress-trend beta handoff** — Added `stress-trend-report.json` to the published beta bundle and extended bundle validation/tests to reject summary count or readiness drift.
- **Platform blocker truth** — Beta readiness now surfaces open Windows ConPTY and macOS native-shell/WebView/PTY rows explicitly; contract tests prevent aggregate missing-artifact wording from hiding them.
- **Release blocker triage** — Refreshed stress-history, performance-baseline, and H11E gates; the current next work is 3 GitHub Actions samples, extension timing evidence, and 8 actionable H11E scenarios.
- **Cross-OS artifact contract gate** — Added `npm run check:cross-os-artifacts` to validate aggregate evidence consistency while preserving honest partial status when external systems are missing.
- **Release workflow contract gate** — Added `npm run check:release-workflow` to protect cross-OS matrix, stress-history, artifact-upload, and beta-readiness workflow wiring.
- **Release evidence truth refresh** — Regenerated cross-OS, stress-trend, and beta-readiness artifacts; current status is Linux-only with missing macOS/Windows artifacts and 0/3 required GitHub Actions stress samples.
- **Research intake** — Reviewed the cited PowerFuzz firmware-fuzzing signal, documented the product-fit boundary, and retired it without adding irrelevant hardware instrumentation.
- **Top-20 artifact loading boundary** — Centralized tolerant JSON artifact loading and scenario payload reads in `scripts/top20_artifact_loading.py`, with malformed/missing/non-object coverage and a dedicated `npm run test:top20-loading` gate.
- **Top-20 artifact path boundary** — Centralized sanitized scenario artifact paths and baseline fixture/dependency/manifest lookups in `scripts/top20_artifact_paths.py`, with focused tests and a dedicated `npm run test:top20-paths` gate.
- **Top-20 scenario status boundary** — Extracted pure artifact/status, surface, follow-up, and validation classification into `scripts/top20_scenario_status.py`, with focused tests and a dedicated `npm run test:top20-status` gate.
- **Top-20 parity utility boundary** — Extracted deterministic artifact/path helpers from the large parity runner into `scripts/top20_parity_utils.py`, with focused tests and a dedicated `npm run test:top20-utils` gate.
- **Terminal panel layout hardening** — Bottom-panel flex children now retain usable dimensions in column splits, and xterm performs a post-layout fit so the terminal content remains visible after lazy mount and resize.
- **Editor QOL polish** — Dirty tabs now ask before discard, saves and reverts report their result through toasts, and zoom level persists across launches.
- **Workspace continuity** — Sidebar/panel visibility, activity-bar position, panel maximization, and bounded pane dimensions persist in the local `wizp-layout` preference.
- **In-app close protection** — Dirty-file closing now offers Save, Discard, and Cancel across direct, batch, and group close paths.
- **Status-bar pickers** — Language, indentation, encoding, and EOL controls now open focused popovers and apply/persist their selections.
- **Editor session restore** — Clean file tabs, active group/tab, and split orientation restore from bounded local state; missing files and unsaved buffers are skipped safely.
- **Terminal polish** — Added rerun-last-command actions, lifecycle indicators, and stray-control-byte filtering while preserving ANSI terminal rendering.
- **Named backend check** — Added `zig build check` and `npm run check` for the Zig test suite plus source-format validation.
- **Project truth docs** — Replaced generic handoff content in `MEMORY.md` and `ROADMAP.md` with current commands, proof boundaries, QOL state, and release caveats.
- **Dependency/security hygiene** — Added `npm run audit:dependencies` for root and frontend lockfiles and documented the security/reporting boundary in `SECURITY.md`.

### Changed
- Refreshed active/archive backlog truth and release documentation.
- Added evidence validators for performance baselines, terminal resources, optional modes, H11E blockers, CI stress history, dependency age, and compatibility boundaries.
- Continued bounded LSP/DAP/ExtensionHost protocol and JSON-framing hardening with ReleaseSafe test coverage.

## [Unreleased] — 2026-06-07

### Added
- **Beta evidence gate** — `npm run status:beta-gates` reports cross-OS package evidence and stress trend readiness from generated artifacts.
- **Non-OS beta gate view** — `npm run status:beta-gates:non-os` isolates remaining non-platform beta work.
- **Stress trend provenance** — `scripts/stress_trend_report.py` records whether samples come from local/manual runs or GitHub Actions and requires 3 `github-actions` samples before trend verification.
- **Beta evidence runbook** — `docs/release/BETA_EVIDENCE_RUNBOOK.md` documents workflow dispatch, artifact download, validation, and signoff rules.

### Changed
- **Beta readiness reporting** — `build/release/beta-readiness.json` now includes cross-OS valid/missing systems plus stress trend total/CI counts and required source.
- **Parity docs** — Backlog and matrix now honestly separate local Linux evidence from missing macOS/Windows artifacts and scheduled CI stress evidence.

### Current beta blockers
- Windows ConPTY backend and clean-runner terminal behavior remain open.
- macOS native shell, WebView, POSIX PTY, and clean-runner lifecycle proof remain open.
- macOS package/platform artifact is missing.
- Windows package/platform artifact is missing.
- Stress trend has local/manual samples but 0/3 required GitHub Actions samples.

## [Unreleased] — 2026-05-27

### Added
- **Electrobun BunRPC proxy layer** — Typed RPC bridge between Svelte renderer and Zig daemon via Electrobun's `defineElectrobunRPC`. Daemon mode (`--daemon`) spawns separate process with direct stdio IPC. `bridge.ts` auto-detects Electrobun transport and falls back to HTTP fetch.
- **Native ApplicationMenu** — File/Edit/View/Help menus with accelerators (CmdOrCtrl+N/S/W/Z/etc) via `ApplicationMenu.setApplicationMenu`.
- **Frameless window** — `titleBarStyle: "hidden"` with drag regions in Svelte Titlebar.
- **Window state persistence** — Save/restore window position + size to `~/.wizp-window-state.json`.
- **Problems panel** — `editor/problems` RPC collects all LSP diagnostics across tabs. Panel.svelte shows scrollable list with click-to-navigate. StatusBar shows live error/warning counts.
- **Output panel** — Multi-channel output logger (`__appendOutput`/`__clearOutput`). Channel selector + scrollable log in Panel Output tab.
- **Multi-tab terminal** — Terminal tabs bar in Panel with add/close/switch. Multiple PTY sessions supported.
- **Search toggles** — Regex toggle (`. *`), case-sensitive (`Aa`), replace-all with input field.
- **Undo/Redo** — Piece-table history via `UndoEntry` snapshots in Buffer.zig. Ctrl+Z / Ctrl+Y in Monaco editor actions.
- **Code folding** — FoldManager indent-based fold computation. `editor/foldRanges` RPC + Monaco FoldingRangeProvider.
- **File watching** — Zig-native inotify poll in Editor main loop (no JSC dependency).
- **Multi-server LSP** — `lsp_servers` StringHashMap per file extension + `resolveLspForUri` routing. 7 RPC handlers updated.
- **LSP auto-start** — `tryStartLsp` on file open with PATH check, correct args per server type, project root walk-up.
- **Git operations** — stage/unstage/commit/diff/discard RPC handlers + full SCM sidebar UI with inline diff viewer.
- **Debug Adapter Protocol client** — `DAP.zig` (220 lines, 14 methods, stdio JSON-RPC). Editor.zig (7 RPC handlers). SidebarViews debug UI (start/stop/step/continue + breakpoints).
- **Native file dialogs** — `__openFileViaDialog`/`__openFolderViaDialog` wired to bridge.ts RPCs.
- **Electrobun build verified** — `bunx electrobun build` produces working package (build/dev-linux-x64/WIZP-dev/, 153MB).

### Changed
- **Architecture** — Replaced direct HTTP RPC with dual-path: Electrobun typed RPC (primary) + HTTP fetch (dev fallback).
- **Bridge** — `bridge.ts` detects `window.electrobun.rpc` for Electrobun mode, `globalThis.Bun` for Bun mode, defaults to Browser HTTP.
- **Electrobun config** — Added frameless window, native menus, window state, binary bundling.
- **Frontend** — Vite 4.6s builds, manualChunks split (bits-ui separated), all Svelte deprecations + a11y warnings fixed.
- **Editor.zig** — Added `lsp_servers`, `dap_client`, `breakpoints`, `fold_manager`, `file_watcher_*` struct fields.

### Removed
- **QuickJS** — Deleted `lib/quickjs/` directory (4MB). Removed all references from build.zig, CI, comments.
- **Legacy compiled output** — Deleted `sveltecomp/` and `.svelte-compiled/` directories. Removed `compile-svelte` and `build:legacy` scripts.
- **Vestigial `tailwind.config.js`** — Not used by Tailwind v4.

### Fixed
- **Zig linker** — `-Dtarget=x86_64-linux-gnu` resolves GCC 16 `.sframe` incompatibility. Binary: 44MB.
- **QuickJS dead code** — 6 build references, CI step, ExtensionHost comment.
- **29 Svelte deprecation warnings** — All `on:click` → `onclick`, `on:keydown` → `onkeydown`, event modifiers.
- **21 a11y warnings** — All interactive divs now have `role`, `tabindex`, `onkeydown`.
- **git/diff RPC** — Fixed incompatible anonymous struct types from different scopes.
- **DAP `process.Child.deinit()`** — Removed (unsupported in Zig 0.15.2).
- **StatusBar** — Converted from Svelte stores to `$state`/`$derived` runes.
- **search.ts** — Converted DOM manipulation module to `Search.svelte` Svelte 5 component.
- **Explorer** — Recursive tree with lazy-load children via `TreeItem.svelte`.
- **Editor.zig struct** — Fixed missing `worker_pool` field after field additions.
- **`runGitCapture` reader** — Replaced deprecated `reader().readAllArrayList` with `readToEndAlloc`.

## [Unreleased] — 2026-05-21

### Added
- **SSE push for terminal output** — Push thread reads all sessions every 2ms, pushes `{id,data}` events via EventSource. Eliminates HTTP polling bottleneck for terminal reads.
- **Multi-terminal tabs** — Tab bar with + (new terminal) and X (kill) buttons. Each tab has its own xterm instance and independent session. Ctrl+Shift+` for new tab, Ctrl+W to close.
- **Terminal context menu** — Right-click menu with Copy, Paste, Copy All, Clear, Kill Terminal.
- **Panel/sidebar resize handles** — 6px drag targets between sidebar/editor and editor/panel, highlight blue (#007acc) on hover/drag.
- **`terminal/activate` RPC** — Sets active terminal session for write/resize (called on tab switch).
- **`startDaemon()` retry logic** — Retries daemon connection up to 10x with 500ms intervals before giving up.
- **`\uXXXX` unescape in JSON-RPC write path** — Fixes Ctrl+C (`\u0003`), `\r`, `\n`, etc.

### Changed
- **All terminal RPCs** (spawn, write, resize, read, kill, activate) handled in-process by `embedded_server.zig` — no daemon proxy for terminal operations.
- `session.read(0)` for non-blocking reads (returns immediately if queue empty).
- HTTP keep-alive for daemon proxy RPCs.
- Grid layout updated to 4 columns: activity bar (48px) + sidebar (variable) + resize handle (6px) + editor (1fr).

### Fixed
- **Buffers** in embedded server increased from 64KB to 1MB to prevent index-out-of-bounds on large daemon responses.
- **Ctrl+C** now correctly sends SIGINT (`\u0003` → byte 0x03 via unescape).
- **Explorer initial load** — `switchSidebarView("explorer")` called after daemon connects.
- **HTML build quirk** — `frontend/dist/index.html` is static; must be manually synced with `frontend/index.html`.

## [Unreleased] — 2026-05-20

### Added
- **MrCode-style scripts** (`scripts/`):
  - `patch.sh` — Interactive patch generator for VSCode workbench (adapted from MrCode dev/patch.sh)
  - `update_patches.sh` — Re-apply all patches against VSCode upstream (adapted from MrCode dev/update_patches.sh)
  - `reset.sh` — Reset vscode-upstream/ to clean state (adapted from MrCode reset.sh)
  - `update_upstream_tracking.sh` — Update upstream/vscode.json tracking (adapted from MrCode update_upstream.sh)
  - `build.sh` — Full build wrapper: upstream → zig build → VSIX (adapted from MrCode dev/build.sh)
- **Upstream sources:** VSCode 1.98.0 cloned to `vscode-upstream/`, Monaco 0.52.2 installed to `monaco-upstream/`, version tracked in `upstream/vscode.json`
- **DVUI menu bar** (`src/webview/HybridWindow.zig`):
  - 8 menus (File, Edit, Selection, View, Go, Run, Terminal, Help) with 43 dropdown items
  - `MenuAction` enum (41 actions) with per-frame dispatch queue
  - File → Exit wired to close window
- **Hub actions** (`src/ui/Editor.zig`):
  - Quick Start → switches to Explorer + welcome message
  - Settings → toggles AI settings panel
  - Extensions → switches to Extensions sidebar
  - Themes → shows built-in theme count
  - Keybindings → shows command palette shortcut
  - Documentation → shows GitHub repo URL
- **Bun fallback JS engine** (`src/hub/JSEngine.zig`):
  - Auto-detects Bun binary (via `bun_options` module)
  - Spawns `bun -e <code>` as fallback when QuickJS unavailable
  - `bunEvalString()` full implementation via child process

### Changed
- `.gitignore` — Added vscode-upstream/, monaco-upstream/, upstream/vscode.json
- `upstream/vscode.json` — Created with VSCode 1.98.0 tracking data

## [Unreleased] — 2026-05-19

### Fixed
- **Zig build compilation (all features)** — Fixed 22+ compilation errors across 14 files. Both `zig build test` and `zig build -DWIZP_DVUI_AVAILABLE=true -DWIZP_X11=true -DWIZP_WEBVIEW=true -DWIZP_QUICKJS=true -DTREE_SITTER_AVAILABLE=true` now compile cleanly:
  - `std.array_list.Managed(T)` struct literal initialization: replaced `.empty` with full 3-field `.{ .allocator, .items, .capacity }` pattern (ToolRegistry, tests)
  - `std.StringHashMapUnmanaged.deinit()` now requires allocator argument (Hub, LSP, AgentSystem)
  - `ArrayList.appendSlice()` now takes 1 argument (slice only), not 2 (tests/Terminal)
  - Missing struct fields in `init()` methods: all struct fields must be explicit in literals (LSPClient, MCPClient, PluginManager, PluginHost, Highlighter, Updater, Installer, Registry)
  - Undeclared `allocator` → `self.allocator` in chat/listing functions (KiloCode, SessionExt)
  - `SyntaxDefinition.Variables` default value requires explicit `.entries = .{}`
  - `SessionState` and `TabStopManager` zero-value initialization requires all container fields
- **X11 native GUI build** — Fixed 2 errors in `src/ui/x11.zig`:
  - `X11.XLookupString` not exposed by translate-c → added `extern fn XLookupString(...)` declaration
  - `std.time.sleep` deprecated → `std.Thread.sleep`

### Added
- **DVUI v0.4.0 native GUI backend** — Optional SDL3-based GUI via DVUI immediate-mode library
  - `dvui_core.zig` — DVUI wrapper with SDLBackend, Window lifecycle, event loop
  - `src/main.zig` — Dual-mode entry point (DVUI render loop or terminal mode)
  - `src/ui/Editor.zig` — Full DVUI widget rendering: activity bar, sidebar, tab bar, buffer, status bar, panel
  - `src/stubs/svg2tvg.zig` — Stub for SVG-to-TVG conversion (DVUI dependency)
  - `lib/stb_image_impl.c` / `lib/stb_image_write_impl.c` — stb_image implementation files
  - `-DWIZP_DVUI_AVAILABLE=true` build flag to enable/disable DVUI
  - `WIZP_DVUI_AVAILABLE` compile-time flag for conditional compilation
  - Stub modules (`src/stubs/dvui.zig`, `src/stubs/sdl-backend.zig`) for DVUI-disabled builds

### Changed
- **Zig 0.15.2 API compatibility** — Updated all modules for breaking changes:
  - `ArrayList.init(allocator)` → `ArrayList.initCapacity(allocator, 0)`
  - `appendSlice(items)` → `appendSlice(allocator, items)`
  - `toOwnedSlice()` → `toOwnedSlice(allocator)`
  - `deinit()` → `deinit(allocator)`
  - `json.stringify` → `json.Stringify.value` with `std.Io.Writer.fixed`
  - `File.Writer.writeAll` → `File.Writer.interface.writeAll`
  - `allocator.allocPrint` → `std.fmt.allocPrint`
- **build.zig** — Restructured DVUI module wiring:
  - Fixed SDL3 backend path (`sdl.zig` instead of non-existent `sdl3.zig`)
  - Added `sdl_options` module with SDL3 version config
  - Added C include paths for SDL3 headers and stb libraries
  - Added SDL3 system library linking
  - Enabled `libc` in DVUI default options
- **Editor.zig** — `Editor.init` now accepts `?*DVUICore` (nullable)
- **tests.zig** — Removed DVUI init calls, pass `null` for DVUI core in tests

### Fixed
- SDL3 system library linking via `exe.linkSystemLibrary("SDL3")` with proper library path
- DVUI module dependency chain: dvui ↔ backend ↔ render_backend ↔ svg2tvg
- Theme.Color to dvui.Color conversion for DVUI widget rendering
- DVUI v0.4.0 API alignment: `.color_fill`, `.min_size_content`, `.color_text`, widget deinit patterns

## [0.1.0] — 2026-05-15

### Added
- Initial project structure and build system
- Terminal UI with ANSI rendering, 24-bit color, mouse tracking
- Piece table buffer with Unicode support
- Theme system (22 built-in themes)
- LSP client with Content-Length JSON-RPC protocol
- Key binding system with modal editing
- Plugin system with Sublime Text compatibility
- QuickJS embedded JavaScript runtime (optional)
- TreeSitter incremental parsing (optional)
- Git integration sidebar
- Monaco frontend with Bun/JSON-RPC daemon
- MCP server for AI tool integration
- VSIX extension host
- X11 native GUI (experimental)
- Native webview support (webkit2gtk)

<!-- OVERZEER:DOCS_CHANGELOG_BEGIN -->
## Unreleased (wizp)
- feat(wizp): activate local terminal paths (2026-09-15; commit `edb273d0b70c`)
- test(wizp): enforce visual report locality (2026-09-15; commit `4689dc67b67c`)
- test(wizp): bind visual baselines to retained evidence (2026-09-15; commit `db8d8c96180a`)
- fix(wizp): improve keyboard accessibility semantics (2026-09-15; commit `e4ce12db3dd1`)
- fix(wizp): preserve SCM and debug recovery state (2026-09-15; commit `1cc8f1189812`)
- test(wizp): cover VSIX and network recovery (2026-09-15; commit `449934879bff`)
- fix(wizp): refresh extensions after host retry (2026-09-14; commit `d5650e61ff77`)
- test(wizp): cover renderer terminal recovery cycles (2026-09-14; commit `181d33b4fdc5`)
- fix(wizp): bound terminal recovery reconciliation (2026-09-14; commit `9560d0256321`)
- fix(wizp): preserve terminal ownership on renderer restart (2026-09-14; commit `eb24f6c6ce8f`)
- fix(wizp): settle daemon disconnect requests (2026-09-14; commit `3c257ebf7be5`)
- fix(wizp): expose daemon reconnect retry (2026-09-14; commit `8f6243d71433`)
- fix(wizp): preserve terminal drop reports at EOF (2026-09-14; commit `1aea1fb3b1dc`)
- fix(wizp): account terminal output drops exactly (2026-09-14; commit `a561dacd44cb`)
- Document PTY lifecycle batch and queue follow-ups (2026-09-13; commit `ab7d7a8bd2ac`)
- docs(wizp): add tool-first model research (2026-09-13; commit `c654e540a5b9`)
- feat: guard suite launch requests (2026-09-11; commit `5435d76bd4ec`)
- feat: add suite health probes (2026-09-11; commit `e887fc556856`)
- feat: add guarded suite launch plan (2026-09-11; commit `368c5ebe2ba5`)
- feat: add suite readiness descriptors (2026-09-11; commit `ec2a05edb1e0`)
- feat: report suite project availability (2026-09-11; commit `8255df9c037d`)
- fix(wizp): wire ZLAY into test module (2026-09-11; commit `dad269f86611`)
- feat: expose workstation suite manifest (2026-09-11; commit `f9bacf25d92f`)
- feat: route panel focus through ZLAY (2026-09-11; commit `7c5b218de526`)
- feat: persist ZLAY pointer capture (2026-09-11; commit `ac02e70aa9b1`)
- feat: add ZLAY editor pointer capture (2026-09-11; commit `8e1e1172b3bc`)
- feat: route editor focus through ZLAY (2026-09-11; commit `efdcce0fe161`)
- feat: synchronize ZLAY editor scrolling (2026-09-11; commit `6f954161cb97`)
- feat: surface ZLAY editor viewport state (2026-09-11; commit `1fcbcf559966`)
- feat: add ZLAY retained editor interactions (2026-09-11; commit `1682d6e35378`)
- feat: integrate ZLAY accessibility metadata (2026-09-11; commit `0e914f4fab94`)
- fix: expose modal semantics to assistive tech (2026-09-10; commit `37eaa985c227`)
- fix: limit live region announcements to text (2026-09-10; commit `c5c85e4c739c`)
- feat: expose explorer tree positions (2026-09-10; commit `fea7037eca65`)
- fix: mark extension actions as buttons (2026-09-10; commit `ae63aa8a65b9`)
- fix: clear debug state on DAP failures (2026-09-10; commit `d5bfcc741725`)
- fix: redact credential URLs in git failures (2026-09-10; commit `ceefa4e31d41`)
- fix: honor configured LSP reply port (2026-09-10; commit `e9781fd8aafa`)
- test: cover VSIX permission recovery (2026-09-10; commit `918b9223c8d1`)
- test: isolate extension smoke HTTP port (2026-09-10; commit `ee862c574f6b`)
- test: add three-cycle daemon recovery smoke (2026-09-10; commit `fd088d1b3155`)
- test: wait for terminal input readiness (2026-09-10; commit `75f4bc4bef3d`)
- build: refresh frontend bundle (2026-09-10; commit `b04d3df7d4a2`)
- test: refresh terminal resource report (2026-09-10; commit `c85c472da864`)
- fix: parse VSIX manifests structurally (2026-09-09; commit `c137d662ddeb`)
- fix: parse escaped extension RPC strings (2026-09-09; commit `be72c210a4e4`)
- fix: decode escaped Unicode surrogate pairs (2026-09-09; commit `dd8784cbeaff`)
- fix: restore extension RPC response encoder import (2026-09-09; commit `e0f422c0fb9d`)
- fix: parse JSON-RPC IDs with whitespace (2026-09-09; commit `fd5241adaca3`)
- fix: fully recover extension host after RPC timeout (2026-09-09; commit `c62f911ac29e`)
- fix: harden RPC routing and editor recovery (2026-09-08; commit `966c31a82757`)
- fix: replay routes after daemon reconnect (2026-09-08; commit `9191f0ffaaae`)
- test: cover one-shot daemon reconnect (2026-09-08; commit `bcc3babb55a1`)
- fix: release completed browser RPC requests (2026-09-08; commit `a558f74c7965`)
- test: select visible extension recovery state (2026-09-08; commit `2875d2ef72f2`)
- test: assert Paseo theme RPC palette (2026-09-08; commit `b32e458d872e`)
- test: align extension failure locator (2026-09-08; commit `9eadc97d5fdd`)
- fix: surface SCM and parity recovery errors (2026-09-08; commit `01a0a86ebfef`)
- test: stabilize untitled save smoke fixture (2026-09-08; commit `cf7d72ed1a3c`)
- test: cover Paseo theme in browser smoke (2026-09-08; commit `e58d68a8df03`)
- fix: route native terminal paste through xterm (2026-09-08; commit `e9011b6f5d04`)
- docs: document Paseo theme (2026-09-08; commit `e5d28a17d209`)
- feat: add Paseo black zinc theme (2026-09-08; commit `5755dbcab715`)
- feat: restart WIZP daemon after crashes (2026-09-08; commit `a9afaf5c42eb`)
- feat: retry unavailable extension host (2026-09-08; commit `491fd4fddb41`)
- style: format WIZP credential fixture (2026-09-08; commit `4052bbd2cbd6`)
- feat: announce daemon connection transitions (2026-09-08; commit `ac648d4829cc`)
- feat: expose live resizer dimensions to assistive tech (2026-09-08; commit `8293e58cc13b`)
- feat: harden terminal accessibility and credential cancellation (2026-09-08; commit `e7f1fee47d67`)
- fix: make VSIX installs transactional (2026-09-08; commit `497f97ad89cd`)
- fix: redact extension network errors (2026-09-08; commit `9671f450a941`)
- style: format daemon recovery bridge (2026-09-08; commit `86566932310e`)
<!-- OVERZEER:DOCS_CHANGELOG_END -->
