# WIZP UI/UX test backlog

Status: accepted planning truth as of 2026-08-09
Audit source: [`../ui-ux-audit/2026-07-13/REPORT.md`](../ui-ux-audit/2026-07-13/REPORT.md)  
Canonical priority/status owner: [`../../../BACKLOG.md`](../../../BACKLOG.md)

## Purpose

This document turns the 2026-07-13 native UI/UX audit into executable test contracts. It owns test scope, fixtures, evidence, and sequencing. The root backlog owns product priority and closure status. Neither this plan nor a browser-only smoke is native runtime proof.

## Status vocabulary

- `open`: accepted and ready to implement.
- `partial`: some implementation or evidence exists, but the contract is not fully proven.
- `blocked`: meaningful progress requires an unavailable platform, tool, or external state.
- `done`: implemented and passing at the required layer; the root backlog row can move to the archive.

Current evidence uses a separate vocabulary:

- `passing`: the required native behavior passed at the row's stated scope.
- `failing`: the audited native behavior was exercised and failed.
- `degraded`: the behavior was reachable but incomplete or misleading.
- `unverified`: the native flow could not be completed after the P0 crash.

## Proof rules

1. Boot, CEF, window, PTY, process, file-dialog, packaging, and crash claims require the packaged native application.
2. Browser/component tests are valid for fast state and semantic coverage, but cannot close a native row by themselves.
3. Terminal output must be typed through a real native PTY path and visibly rendered; injected xterm data is not sufficient.
4. Every native failure artifact must include a screenshot, process sample, RPC-rate sample, console tail, and current workspace fixture identity.
5. Assistive-technology and cross-platform claims remain open until tested in their real environment.
6. Visual baselines must specify platform, decoration mode, viewport, scale, theme, zoom, workspace fixture, and application commit/build identity.
7. Automated UI/UX tests must run through `scripts/run_virtual_ui_test.sh` on isolated Xvfb with Openbox, never the developer's active desktop. Nested KWin is refused unless `WIZP_ALLOW_NESTED_KWIN=1` is explicitly set for compositor testing. Virtual-display evidence does not replace manual visual or assistive-technology sign-off.

## Required fixture

Create one disposable workspace outside the packaged application directory containing:

- clean and dirty text files, a long filename, Unicode content, mixed line endings, and a large file;
- nested folders, symlink/path edge cases allowed by the host, and search/replace matches;
- a small Git repository with staged, unstaged, untracked, conflicted, and historical states;
- valid and invalid debug/task configurations;
- one local deflate-compressed VSIX test extension with commands, a view, settings, and controlled invalid-package/install failure modes;
- deterministic shell startup that prints a known prompt marker without relying on user dotfiles.

The fixture must be recreated for each test and must never resolve inside `Resources/app`, `frontend-dist`, or another packaged-resource path.

## Group 1 — native baseline and first-run safety

| ID | Priority | State | Current evidence | Test contract and finish condition |
| --- | --- | --- | --- | --- |
| UI-NATIVE-001 | P0 | done | passing | Launch the packaged app with a clean profile and fixture; the native window becomes interactive and remains responsive for 60 seconds with no crash signal, renderer loss, or unhandled child termination. Exact-package 1/4/8-terminal Linux X11 runs `20260718T035931Z-1340286`, `20260718T040059Z-1342715`, and `20260718T035454Z-1325390` retain 60-second window survival and exit cleanly on SIGTERM. |
| UI-NATIVE-002 | P0 | done | passing | Run a 30-minute scheduled idle soak; retain CPU, memory, RPC-rate, child-process, and last-frame artifacts and fail on signal 11, exit 139, renderer disappearance, or runaway growth. Scheduled run `20260718T040230Z-1344056` survives 1804.055 seconds with the window and final frame present, 6.283 reads/s/session, 3.103% packaged-main CPU, 315,109,376 bytes of steady-state peak RSS growth under the 512 MiB budget, and clean SIGTERM cleanup. RSS was reconciled from all 1,730 retained raw process samples using the first steady process-tree sample instead of the launcher-only sample. |
| UI-NATIVE-003 | P0 | done | passing | After warm-up with 1, 4, and 8 idle terminals, terminal reads stay at or below the accepted request budget and sustained main-process CPU stays below the reference-runner budget; the first target is 10 reads/second/session and 5% main-process CPU. Exact-package runs record 5.658/3.805/1.650 reads/s/session and 3.524%/3.506%/4.452% packaged-main CPU. The package audit requires the scoped XCB unanswered-poll backoff runtime and launcher configuration that close the former fixed-pump saturation without delaying normal replies. |
| UI-NATIVE-004 | P0 | done | passing | A real PTY displays a deterministic prompt within two seconds, accepts typed `printf WIZP_UI_TERMINAL_%s OK`, and visibly renders `WIZP_UI_TERMINAL_OK` with non-zero geometry. One-terminal run `20260718T035931Z-1340286` captures the prompt at 1.479 seconds after two in-budget screenshot attempts, then proves focus-guarded discrete X11 input and visible marker output with no shell error. |
| UI-NATIVE-005 | P0 | done | passing | First run presents a deliberate welcome/open-folder state or restores an explicit recent project; no packaged resource directory is displayed as a user workspace. All three exact-package 1/4/8-terminal runs stay folderless, exclude `Resources/app`, and visibly expose Open Folder. |

Current packaged-native evidence is under `../../build/ui-ux/`. The latest
standard alias is `native-baseline/report.json`, non-soak runs are preserved by
terminal count, and the scheduled result is preserved as `report-soak.json`.
The current exact-package reports are `report-terminal-count-1.json`
(`20260718T035931Z-1340286`), `report-terminal-count-4.json`
(`20260718T040059Z-1342715`), `report-terminal-count-8.json`
(`20260718T035454Z-1325390`), and passing soak `20260718T040230Z-1344056`.
All short runs pass survival, first-run, CPU/read budgets, CEF profile setup, and
bounded teardown. The one-terminal run additionally passes the strict visible
prompt/marker contract. The soak retains final-frame, metric, process/thread,
window-lifecycle, diagnostics, and cleanup artifacts. Runtime stderr diagnostics
remain retained as limitations; this packet does not close deeper journeys or
cross-platform proof.

## Group 2 — primary native journeys

Current source hardening: `npm run test:ui-contract` guards the shared shortcut registry, semantic overlay/live-region contracts, keyboard resize/navigation, dirty-editor recovery, Explorer lifecycle/navigation, Search recovery/replacement, Settings load/save/retry behavior, and extension lifecycle/recovery behavior. Explorer now has one-tab-stop tree semantics, complete Arrow/Home/End/F2/Delete/context-menu paths, native create/rename/delete dialogs, duplicate-create protection, copy/paste, refresh, loading/empty/error recovery, long Unicode path labels, and outline navigation. Search now has responsive semantic controls, stale-result suppression, bounded 100-result reporting, invalid-regex errors, case/word/regex/include/exclude/context coverage, loading/zero-result/error states, retry/cancel recovery, result navigation, replace-one, and confirmation-backed replace-all. Dirty file and untitled content persist through browser-session recovery and Save/Save As use the backend route. SCM now has persistent commit input and validation, selected/all staging, accessible stage/unstage/diff actions, native discard and untracked-delete confirmation, branch selection, commit-history diff navigation, conflict preview/resolution, and recoverable Git errors. Debug now reads launch configuration from the backend-owned workspace, distinguishes missing/invalid configuration and adapter failures, reports accurate running/paused state, exposes call stack/variables/watches/breakpoints, supports pause/continue/step/restart/stop, preserves failed evaluation input, synchronizes the floating toolbar, and restores focus after stop. Extensions now expose session-scoped OpenVSX consent, real deflate-capable local VSIX installation, persistent installed/disabled state, enable/disable/uninstall actions, host unavailable/retry/restart states, contribution details and command/view/settings actions, installation failure recovery, and focus-restoring uninstall confirmation without a production demo action. Chromium passes the complete Playwright lane across these Explorer/editor/Search/SCM/Debug/Extensions/Settings/accessibility journeys. The packaged Linux Settings smoke `build/ui-ux/native-settings/report.json` also passes real `Ctrl+,` opening, keyboard field navigation, screenshot-backed font-size editing, Cancel and Escape discard/reopen paths, Apply & Save backend synchronization, short disposable CEF-profile cleanup, and bounded process-group cleanup; it intentionally does not claim packaged-native partial failure, saved-value reopen, focus containment/restoration, assistive technology, or non-Linux behavior. The disposable native fixture includes editor, Explorer, Search, Git staged/unstaged/untracked/conflict/history, valid/failing/invalid Debug inputs, valid/invalid local VSIX inputs, empty folders, long paths, Unicode, large files, and malformed configuration. `test:native-editor` is scheduled in CI and now tolerates virtual focus proxies and root-window capture. Local KWin reaches fixture workspace selection, but Quick Open text still routes into the terminal. Chromium additionally preserves URI/content/dirty state on Save As failure and proves cross-group Close All Editors. Every Group 2 row remains open until its packaged contract passes.

| ID | Priority | State | Current evidence | Test contract and finish condition |
| --- | --- | --- | --- | --- |
| UI-NATIVE-006 | P1 | partial | native-partial/browser-passing | Open, create, edit, save, Save As, revert, dirty-close, cancel, discard, close-all, and session restore preserve content with clear recovery. Chromium verifies Save As failure retains URI/content/dirty state and Close All Editors works across groups. Packaged native run `20260812T203615Z-1613262` proves fixture workspace selection, Quick Open file opening, edit/save, deterministic Save As path selection, native Save As dialog smoke with retained dialog screenshot/OCR, save-permission failure preserving editor content and saved file bytes, dirty-close cancel, dirty-close discard, reopen-saved-content, renderer-reload restore, process-restart restore, Close All Editors returning to Welcome with clean SIGTERM, and dirty-close semantic accessibility under isolated Xvfb. `check:native-editor-report` validates retained editor reports, and scheduled parity-hardening now runs the native Save As dialog variant before uploading dedicated `native-editor-evidence`. Manual native Save As chooser review, assistive-technology sign-off, first retained scheduled CI artifact, and non-Linux proof remain required. |
| UI-NATIVE-007 | P1 | partial | native-partial/browser-passing | Explorer expand/collapse, roving selection, Arrow/Home/End navigation, keyboard context menus, create/rename/delete, duplicate-create error recovery, copy/paste, refresh, outline navigation, long Unicode paths, and empty/error states pass in Chromium. Retained packaged Linux run `20260812T221451Z-2137710` proves fixture workspace selection, pointer/keyboard expand/collapse, one-tab-stop tree semantics, Arrow/Home/End navigation, keyboard context menus, semantic create/rename/delete dialogs, duplicate-create recovery, copy/paste, refresh, real filesystem-permission failure recovery, empty-folder and removed-directory error recovery, long Unicode path opening, outline navigation, screenshot/OCR diagnostics, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-explorer-report` validates the packet and scheduled parity-hardening uploads it. Assistive-technology sign-off and non-Linux evidence remain required. |
| UI-NATIVE-008 | P1 | partial | native-partial/browser-passing | Chromium covers query, case/word/regex toggles, include/exclude, context, loading, zero-result, invalid-regex and injected RPC errors, retry, result navigation, replace-one, confirmation-backed replace-all, cancellation, stale-result suppression, and bounded result reporting. Retained packaged Linux run `20260813T155115Z-2982087` proves fixture workspace selection, query/results, case/whole-word/regex controls, include/exclude/context filters, invalid-regex and zero-result recovery, a one-shot injected `search/text` RPC failure that preserves the query and exposes an alert-labelled Retry action, successful retry to five results, pending-search cancellation, result-to-editor navigation, bounded 100-result reporting, replace-one, confirmation-backed replace-all with focus return, real filesystem-permission failure preservation, semantic Search snapshots, screenshot/OCR diagnostics, terminal-session teardown, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-search-report` validates the retained packet and parity-hardening runs and uploads it. Assistive-technology sign-off and non-Linux evidence remain required. |
| UI-NATIVE-009 | P1 | partial | native-partial/browser-passing | Chromium covers stage, unstage, selected/all staging, tracked discard cancellation/confirmation/focus restoration, untracked deletion confirmation, empty-message and no-staged commit validation, commit, branch checkout, timeline-to-commit-diff navigation, conflict preview/accept-both resolution, injected stage/load failures, retry, remotes, and extension-provider rendering. Retained packaged Linux run `20261018T235446Z-24` proves fixture repository loading, Source Control access, local fake credential prompt cancellation with exact file-snapshot preservation, a real `.git` write-permission failure that leaves the index/worktree unchanged and exposes an alert-labelled Retry action, successful stage recovery, stage/unstage, commit, branch checkout, diff opening, untracked discard cancellation/confirmation, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-scm-report` validates the retained packet. Credential prompt accessibility-tree, assistive-technology, and non-Linux evidence remain required. |
| UI-NATIVE-010 | P1 | partial | native-partial/browser-passing | Chromium covers backend-owned workspace launch selection, missing configuration, invalid-root parsing, injected state-load failure and retry, adapter initialization failure and recovery, start, accurate running/paused state, pause, continue, step over/into/out, restart, stop with focus restoration, floating-toolbar dismissal, breakpoint rendering/removal, call stack, variables, watches, successful evaluation, failed-evaluation input preservation, and absence of developer-only layout diagnostics. Retained packaged Linux run `20261019T000322Z-24` proves fixture launch loading, accessible Debug controls, a real missing-adapter initialization failure with stopped-state preservation and Retry, valid recovery to the paused fixture adapter, actual adapter kill/reap with preserved call-stack/variable/watch inspection data and an alert-labelled `Retry debugging` action, pause/continue/step operations, successful evaluation, restart/stop, stop-focus restoration, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-debug-report` validates the retained packet. Accessibility-tree, assistive-technology, and non-Linux evidence remain required. |
| UI-NATIVE-011 | P1 | partial | native-partial/browser-passing | Chromium covers session-scoped OpenVSX consent, fixture marketplace install and controlled failure, real deflate-compressed local VSIX install and invalid-package recovery, installed-state persistence, enable/disable, uninstall cancellation/confirmation/focus restoration, host unavailable/retry/restart, contributed command execution, contributed view opening, contributed settings visibility, and absence of the production demo action. Retained packaged Linux run `20261018T232907Z-24` proves keyboard Extensions access, session-scoped OpenVSX consent, fixture search/install, redacted network failure with preserved query and Retry recovery, native VSIX chooser review with screenshot/OCR, real extensions-directory permission denial with state preservation and Retry recovery, enable/disable persistence, real host crash/unavailable/Retry/restart with contribution re-registration, uninstall cancellation/confirmation with focus restoration, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-extensions-report` validates the retained packet and parity-hardening runs and uploads it. Accessibility-tree, assistive-technology, and non-Linux evidence remain required. |
| UI-NATIVE-012 | P1 | partial | native-partial/browser-passing | Chromium covers the full Settings lifecycle and focus behavior. Retained packaged Linux run `20260813T161414Z-3100624` proves keyboard open/edit, Cancel/Escape discard and reopen, backend save sync, saved-value reopen, dialog semantics and focus containment, Activity Bar trigger focus return, a one-shot injected `config/set` failure for `editor.fontSize`, local value `17` and dialog preservation while the backend remains at `16`, an assertive alert with enabled Retry Save, successful backend resync to `17`, saved-value reopen, screenshot/OCR diagnostics, disposable-profile cleanup, and clean SIGTERM under isolated Xvfb. `check:native-settings-report` validates the retained packet and scheduled parity-hardening uploads it. Assistive-technology sign-off and non-Linux evidence remain required. |
| UI-NATIVE-013 | P1 | partial | native-passing/browser-passing | Linux alpha L2 is complete: retained packaged run `20260922T085801Z-24` passes all 17 checks, including native multiline Unicode clipboard paste, loopback URL activation by pointer and keyboard, actual spawn-error Retry, retained normal exit and relaunch, ANSI/Unicode, find, new/split sessions, ordered rerun, kill, and cleanup. A paused real renderer exercises 40 MB of output against a 16 MiB circular queue with complete rendered/dropped-byte accounting. `check:native-terminal-report` and the fresh backend resource gate pass. Identity-safe descendant teardown exits 0 without force, leaves no live owned PIDs, and removes the disposable profile. Screenshot/OCR evidence is retained. Manual assistive-technology and non-Linux evidence remain required; the upstream CEF persistent-profile limitation is documented in Linux batch L2. |

## Group 3 — contracts, keyboard, and accessibility

| ID | Priority | State | Current evidence | Test contract and finish condition |
| --- | --- | --- | --- | --- |
| UI-CONTRACT-001 | P1 | partial | browser-passing/native-partial | One executable 36-shortcut table drives menus, Welcome, Settings, and dispatch tests; `Ctrl+,` opens Settings from native workbench focus. Complete packaged context/conflict coverage remains required. |
| UI-CONTRACT-002 | P1 | done | passing | `npm run test:ui-contract` scans source and built frontend assets and rejects `B3 demo`, example-target, and internal-milestone copy; the production extension demo action remains absent. |
| UI-CONTRACT-003 | P1 | partial | degraded | Activity/sidebar controls use native buttons, status text no longer advertises dead actions, and sidebar/panel/editor resizing has keyboard alternatives. Retain packaged pointer/keyboard proof and finish the remaining action-looking surfaces. |
| UI-A11Y-001 | P1 | partial | native-semantic-partial | Editor tabs, menus, command/extension quick inputs, pickers, trees, dialogs, status controls, and resizers now expose stronger semantic ownership. Packaged native editor run `20260812T203615Z-1613262` snapshots the dirty-close modal name/description, initial Save focus, dirty tab accessible name, tablist/tabpanel linkage, editor action labels, and decorative icon hiding. Native accessibility-tree and screen-reader proof remain required. |
| UI-A11Y-002 | P1 | partial | browser-passing/native-partial | Editor tabs, menus, quick inputs, trees, pickers, dirty-close, and resizers cover their expected Enter/Space/Arrow/Home/End/Escape/Tab paths. Settings now exposes its trigger/dialog relationship, blocks workbench shortcuts behind the modal, and restores keyboard or pointer trigger focus in Chromium. Packaged native editor run `20260812T203615Z-1613262` proves dirty-close initial Save focus, Escape cancel, Tab to Discard, and Enter discard. A complete isolated packaged-native keyboard journey remains required. |
| UI-A11Y-003 | P1 | partial | unverified | Search result counts/errors, toast severity, and extension progress now use bounded status/alert announcements without duplicating visible search messages. Terminal, connection, extension-host, and manual screen-reader coverage remain open. |

## Group 4 — visual, responsive, and recovery coverage

| ID | Priority | State | Current evidence | Test contract and finish condition |
| --- | --- | --- | --- | --- |
| UI-VISUAL-001 | P2 | partial | native-partial/browser-passing | Chromium retains representative Welcome, editor, Search, SCM, Debug, Extensions, Settings, terminal, dialog, menu, notification, and responsive screenshots under `build/playwright-smoke/`. Eight automation-assisted-reviewed Linux packaged-native default-state frames are checksum-bound in `testdata/ui-ux/native-visual-baselines.json`; `check:native-visual-baselines` verifies their source reports, required checks, dimensions, and hashes. Dynamic-theme states, manual human review, and non-Linux packaged-native baselines remain required. |
| UI-VISUAL-002 | P2 | partial | static/browser-passing | `npm run check:ui-visual` records nine passing default-token contrast measurements in `build/ui-ux/visual/token-contrast.json`; Chromium additionally switches a Monaco-loaded workbench to `one-light` and records 10.86:1 surface text, 9.65:1 control text, 3.12:1 control boundary, and 3.84:1 focus contrast in `responsive-report.json`. Extension themes, native rendering, and manual review remain open. |
| UI-VISUAL-003 | P2 | partial | browser-passing | `build/playwright-smoke/responsive-report.json` passes 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact-shell, right-sidebar yielding, zero horizontal overflow, and Settings-fit checks. Native high-DPI, large-text, and pseudo-localization evidence remain open. |
| UI-RECOVERY-001 | P2 | open | unverified | Fault-inject daemon, renderer, PTY, extension-host, and network failures; state is explained, unsaved work remains protected, recovery is offered, and repeated recovery does not leak processes or sessions. |

## Implementation order

1. Preserve the passing UI-NATIVE-001 through UI-NATIVE-005 package packet and add deterministic fixture-backed primary journeys UI-NATIVE-006 through UI-NATIVE-013.
2. Generate UI-CONTRACT-001 from one shortcut registry, then add affordance and production-copy contracts.
3. Add semantic component tests and native keyboard journeys before manual assistive-technology sign-off.
4. Capture visual/responsive baselines only while the green runtime packet remains repeatable.
5. Add fault injection and scheduled platform/assistive-technology lanes last; preserve missing external evidence as blocked.

## Pull-request and scheduled lanes

| Lane | Frequency | Maximum intended duration | Required scope |
| --- | --- | ---: | --- |
| UI static contract | every pull request | 1 minute | Audit evidence, backlog IDs, docs links, production-copy and shortcut tables. |
| Native baseline | every pull request on Linux | 3 minutes | UI-NATIVE-001, UI-NATIVE-003, UI-NATIVE-004, UI-NATIVE-005. |
| Native primary journeys | every pull request or merge queue, plus scheduled parity-hardening | 10 minutes | UI-NATIVE-006 through UI-NATIVE-013 on isolated Xvfb with Openbox; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1`; editor lane is wired first, scheduled parity-hardening runs the native Save As dialog variant, and its retained report is validated by `check:native-editor-report`. |
| Native soak/recovery | scheduled | 45 minutes | UI-NATIVE-002 and UI-RECOVERY-001 with artifacts. |
| Visual/responsive | merge queue and release candidate | 15 minutes | UI-VISUAL-001 through UI-VISUAL-003. |
| Platform/manual AT | release candidate | manual/external | macOS, Windows, Linux screen-reader and keyboard review with named evidence. |

## Program exit criteria

The UI/UX test program is not complete until all 23 rows are implemented at their required layer, the three P0 runtime findings pass in the packaged app, primary native journeys are repeatable against the fixture, and external platform/manual evidence is attached without substituting Linux or browser-only results.
