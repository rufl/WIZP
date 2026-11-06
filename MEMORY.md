# wizp Memory

Purpose: concise LLM handoff for future work on this repo. Keep it current, factual, and free of secrets.

## Project Snapshot

- Path: `desktop/WIZP/wizp`
- Product path: Zig backend + Svelte 5/Monaco frontend + Bun/Electrobun Linux native shell
- Supported compiler: repository toolchain Zig `0.16.0`; frontend uses Node/npm with Vite 8 and xterm.js
- Current scope: Linux alpha evidence; Windows ConPTY and macOS POSIX PTY/default-shell paths cross-compile, while real macOS/Windows native shell/WebView/PTY execution and package artifacts remain open

## Canonical Verification

- Fast backend gate: `npm run check` — runs Zig tests and `zig fmt --check src/`.
- Frontend gate: `npm run build:frontend`, then `cd frontend && npm run lint && npm run format:check`.
- Frontend parity: `npm run test:parity:frontend`.
- UI/UX audit/backlog preservation: `npm run check:ui-ux-audit`.
- Default visual-token floor: `npm run check:ui-visual` records nine measured pairs without claiming dynamic-theme or packaged-native conformance.
- UI shell contract: `npm run test:ui-contract` guards the 36-shortcut registry, semantic overlays/live regions, keyboard resizing/navigation, dirty-editor recovery, Explorer/Search/SCM/Debug/Settings lifecycle, and Extensions consent/local-install/host-recovery/contribution behavior without developer-only demo UI; it is not packaged-native proof.
- Sustained terminal evidence: `python3 scripts/check_terminal_resource_report.py`.
- Full repo/package gate: `npm run verify`; it includes package audits and parity lanes and may require a native/runtime-capable environment.
- All packaged-native journey commands (`test:native-ui-baseline`, editor, Explorer, Search, SCM, Debug, Extensions, Settings, and Terminal) run through isolated Xvfb with Openbox and fail closed if isolation is unavailable; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1` compositor testing and they never target the active desktop. `check:native-visual-baselines` validates retained frames without rerunning the UI.
- The latest recorded Slopometer result is `0.6/10`; its 12 medium findings are `console.log` calls in separately retained `vscode/FIR/olik/`, while WIZP proof, hygiene, truth, and stewardship are zero. Do not edit sibling code or scanner boundaries merely to manufacture `0.0`.

## Truth Boundaries

- Generated reports, staged packages, static contracts, and model-only smokes do not prove native runtime behavior by themselves.
- Cross-build output is not macOS/Windows runtime proof; Linux native launch is the current honest runtime surface.
- Missing macOS/Windows artifacts are not the whole platform boundary: `PROD-B02` Windows ConPTY and `PROD-B03` macOS native shell remain explicit blockers until real runner proof closes them.
- Terminal resource evidence accounts for observed and dropped PTY bytes but does not replace visual terminal QA.
- Bun resolution now accepts only regular files and the current package starts its Bun-backed extension process; this does not broaden extension compatibility beyond the recorded parity evidence.
- The 2026-07-13 packaged UI audit failed on 3/3 launches after a blank ready terminal, approximately 1,070 idle RPC requests in five seconds, approximately 99% Electrobun main-process CPU, and signal 11 / exit 139. The accepted report is `docs/ui-ux-audit/2026-07-13/REPORT.md`; the executable queue is `docs/ui-ux/TEST_BACKLOG.md`.
- Current 2026-07-18 exact-package 1/4/8 reports pass 60-second survival, clean first run, CPU/read budgets, bounded SIGTERM cleanup, and the profile-warning gate. One-terminal run `20260718T035931Z-1340286` also passes strict visible prompt/marker proof.
- Scheduled run `20260718T040230Z-1344056` passes the 30-minute soak with final frame and telemetry retained, 3.103% packaged-main CPU, 6.283 reads/s/session, 315,109,376 bytes of steady-state peak RSS growth under 512 MiB, and clean termination. Current evidence is `build/ui-ux/native-baseline/report.json`, `report-soak.json`, and the three terminal-count aliases.
- Only the two checksum-protected accepted screenshots are UI audit evidence. Browser/static smokes and the audit preservation contract do not close native behavior.
- Figma placement is capability-blocked in this workspace; `FIGMA_BOARD_HANDOFF.md` is a specification, not proof that a board exists.

## Continuation Notes

- Treat OVERZEER-generated backlog blocks as proposals, not accepted work.
- Close active rows only after recording the local proof command or audit evidence.
- Move completed or retired rows to `BACKLOG_ARCHIVE.md`; keep current direction in `ROADMAP.md`.
- Current QOL work includes dirty-close protection, dirty-file and untitled session recovery, backend-routed Save/Save As, validated Settings load/save/retry state, status-bar pickers, terminal rerun/lifecycle state, and stray-control-byte filtering.
- The browser visual/responsive packet passes 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact menus, right-sidebar yielding, zero horizontal overflow, Settings fit, and a Monaco-loaded `one-light` switch with passing surface/control/boundary/focus contrast. Eight automation-assisted-reviewed Linux packaged-native default-state frames are checksum-bound by `testdata/ui-ux/native-visual-baselines.json`; the manifest validator checks each source report, required journey check, dimensions, and hashes. Native high-DPI, extension-theme, large-text, pseudo-localization, manual visual, and assistive-technology proof remain open.
- Native `UI-NATIVE-006..013` now have retained packaged Linux slices: Settings `20260813T161414Z-3100624`, editor `20260812T203615Z-1613262`, Explorer `20260812T221451Z-2137710`, Search `20260813T155115Z-2982087`, SCM `20260813T162841Z-3165689`, Debug `20260813T163636Z-3200207`, Extensions `20260813T132228Z-2549897`, and Terminal `20260813T132452Z-2554796`. Their dedicated validators pass; parity-hardening runs and uploads all eight. Debug now includes missing-adapter initialization failure, stopped-state preservation, assertive Retry semantics, and fixture-adapter recovery; SCM includes real `.git` write-permission failure, unchanged-index proof, alert-labelled Retry recovery, permission restoration, and successful staging; Settings includes one-shot `editor.fontSize` sync failure, local-value/dialog preservation, alert-labelled Retry Save recovery, and backend resync; Search includes one-shot injected `search/text` failure, query preservation, Retry recovery, and explicit terminal-session teardown. Each row remains partial for the exact recovery, accessibility, assistive-technology, and non-Linux gaps in `docs/ui-ux/TEST_BACKLOG.md`.
- Folder selection owns backend workspace state and reloads Explorer; source smokes reject empty/no-folder search and replacement outside the active workspace. Explorer has roving tree focus, complete Arrow/Home/End/F2/Delete/context-menu paths, native create/rename/delete dialogs, copy/paste, stable refresh, empty/error recovery, long Unicode path labels, and non-destructive duplicate creation. Search has responsive semantic controls, stale-result suppression, bounded 100-result reporting, invalid-regex errors, case/word/regex/include/exclude/context coverage, retry/cancel recovery, result navigation, replace-one, and confirmation-backed replace-all. Editor tabs retain roving focus, dirty-close uses a keyboard-modal focus-restoring dialog, dirty file and untitled content survive browser reload, and Save/Save As use backend file RPC. SCM has persistent commit input and validation, selected/all staging, accessible stage/unstage/diff actions, native discard/delete confirmation, branch selection, commit-history diff navigation, conflict resolution, and recoverable Git errors. Debug reads launch configuration from the backend-owned workspace, handles missing/invalid configuration and adapter failure, tracks running/paused state, exposes call stack/variables/watches/breakpoints, supports pause/continue/step/restart/stop, preserves failed evaluation input, and restores focus after stop. Extensions require session-scoped OpenVSX consent, use real store/deflate VSIX extraction for local and marketplace routes, persist installed/disabled state, confirm uninstall with focus restoration, recover host unavailable/restart and install failures, and surface command/view/settings contributions. Chromium passes these lifecycle journeys using bundled Chromium or an installed browser fallback; this remains browser proof, not native or screen-reader proof. The native fixture includes editor, Explorer, Search, Git staged/unstaged/untracked/conflict/history, valid/failing/invalid Debug lifecycle inputs, and valid/invalid deflate-compressed VSIX inputs plus empty-folder, long-path, Unicode, large-file, and malformed-config cases. Automated native UI commands are isolated behind Xvfb with Openbox; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1`, and failed virtual packets do not replace retained passing aliases.
- Beta truth is generated and contract-checked: open platform backlog rows must remain visible in `knownBlockers`, alongside cross-OS and stress evidence gaps.
- Current parity truth is 25/33 compatibility rows ready and 14/20 in the narrower top-20 slice; the 8 H11E blockers split into 4 extension-owned, 3 policy-owned, and 1 host-owned row.
- Local `build/parity-stress/stress-report.json` records profiled daemon/terminal shutdown CPU, RSS delta, cleanup latency, terminal reaping, and no remaining descendants. It does not substitute for real macOS/Windows reader-shutdown or allocation profiling.
