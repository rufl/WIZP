# WIZP implementation notes

The parent [`../BACKLOG.md`](../BACKLOG.md) is the canonical active queue.
This file keeps local commands and proof boundaries close to the implementation;
historical rows live in [`BACKLOG_ARCHIVE.md`](BACKLOG_ARCHIVE.md).

## Current boundaries

- Linux packaged evidence closes `UI-NATIVE-001..005` only. The retained 1/4/8
  terminal matrix and 30-minute soak are under `build/ui-ux/native-baseline/`.
- Primary journeys `UI-NATIVE-006..013` now have retained, validator-backed
  packaged Linux slices; every row remains partial for named recovery,
  accessibility, assistive-technology, or non-Linux evidence. The 23-row plan
  and exact retained run IDs are in
  [`docs/ui-ux/TEST_BACKLOG.md`](docs/ui-ux/TEST_BACKLOG.md).
- Source hardening now uses a shared 36-shortcut registry, removes the
  developer extension demo, hardens OpenVSX consent/local VSIX/host recovery and contribution actions, repairs Settings lifecycle feedback, makes folder
  selection atomically set and reload the workspace, keeps search/replace inside
  that workspace, gives Search responsive semantic controls, bounded result
  reporting, invalid-regex errors, retry/cancel recovery, result navigation,
  replace-one, and confirmation-backed replace-all, gives Explorer one-tab-stop
  tree navigation plus keyboard create/rename/delete/context actions and
  recoverable empty/error states,
  preserves dirty file and untitled content across browser-session recovery, routes Save/Save As through the backend, and gives
  editor tabs roving keyboard focus plus a focus-restoring dirty-close dialog.
  Menus, command/extension quick inputs,
  status pickers, trees, notifications, progress, search states, SCM commit/
  branch/history/diff/conflict/recovery states, and resizers now add semantic
  and keyboard contracts; action-looking status text is no
  longer falsely interactive. `npm run test:ui-contract` and browser/static
  checks do not close native rows.
- `npm run test:parity:playwright` now passes the complete Chromium journey,
  including validated Settings load/save/cancel/partial-sync retry/focus behavior,
  modal background-shortcut isolation, and pointer-trigger focus restoration,
  Explorer create/rename/delete/copy/paste/refresh/error recovery,
  long Unicode paths and outline navigation, dirty-content reload recovery,
  save/revert, untitled dirty-close Save, Search query/filter/regex/context/
  navigation/replace/cancel/error behavior, SCM stage/unstage/discard/commit/
  branch/history/diff/conflict/failure behavior, Debug configuration/start/
  pause/continue/step/restart/stop/breakpoint/variables/evaluation/failure-
  recovery behavior, Extensions consent/local-install/enable-disable/uninstall/host-restart/contribution/failure behavior, and accessibility.
  `npm run test:native-settings` passes retained packaged Linux run
  `20260813T161414Z-3100624`, including keyboard edit/discard/save/reopen,
  dialog semantics/focus containment, trigger focus return, one-shot
  font-size sync failure with local-value/dialog preservation, Retry Save
  backend recovery, and clean teardown.
  `npm run test:native-explorer` passes retained packaged Linux run
  `20260812T221451Z-2137710`, covering pointer/keyboard tree navigation,
  create/rename/delete/copy/paste/refresh, permission and directory-error
  recovery, empty folders, long Unicode paths, outline navigation, semantic
  snapshots, and clean teardown. `check:native-explorer-report` and scheduled
  parity-hardening guard and upload the packet.
  `npm run test:native-search` passes retained packaged Linux run
  `20260813T155115Z-2982087`, covering query/filter/mode/context controls,
  invalid-regex and zero-result recovery, one-shot injected RPC failure with
  query-preserving Retry recovery, cancellation, result navigation, bounded
  reporting, replace-one/all, filesystem-permission preservation, semantic
  snapshots, terminal-session cleanup, and clean teardown.
  `check:native-search-report` and scheduled parity-hardening guard and upload
  the packet.
  `npm run test:native-editor:scheduled` passes packaged native
  run `20260812T203615Z-1613262`, proving fixture workspace selection, Quick Open
  open, edit/save, deterministic Save As path selection, native Save As dialog
  smoke, save-permission failure recovery, dirty-close cancel/discard/reopen,
  renderer-reload restore, process-restart restore, Close All Editors returning
  to Welcome, and dirty-close semantic accessibility under isolated Xvfb.
  `check:native-editor-report` and the scheduled parity-hardening upload guard retained editor evidence.
- The Chromium lane retains responsive baselines and `responsive-report.json`
  for 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact menus,
  right-sidebar yielding, zero horizontal overflow, Settings fit, and a
  Monaco-loaded `one-light` switch with passing surface/control/boundary/focus
  contrast. Eight automation-assisted-reviewed Linux packaged-native default-
  state frames are checksum-bound in `testdata/ui-ux/native-visual-baselines.json`.
  Native high-DPI, extension-theme, large-text, pseudo-localization, manual
  visual, and assistive-technology proof remain open.
- Beta remains blocked by real macOS/Windows artifacts, Windows PTY proof,
  macOS shell proof, and 0/3 required GitHub Actions stress samples.
- Top-20 parity is `25/33` ready with eight scenario and eight H11E budget
  blockers. Generated detail is under `build/vscode-parity/`.
- Local stress proof now includes a profiled daemon/terminal shutdown with CPU,
  RSS delta, bounded cleanup, a reaped terminal, and zero remaining descendants;
  real macOS/Windows reader-shutdown and allocation-profile proof remain open.

## Local gates

```bash
npm run check                         # Zig tests + format
npm run test:ui-contract              # Public shortcut and production-copy guard
npm run test:parity:frontend          # Daemon/frontend workflow smoke
npm run check:ui-ux-audit             # UI/UX evidence and docs contract
npm run check:ui-visual               # Default static token measurements
npm run check:native-visual-baselines      # Checksum-bound retained native frames
npm run verify                        # Broad Linux/package gate
npm run test:native-ui-baseline       # Isolated packaged baseline
npm run test:native-settings          # Isolated partial Settings journey
npm run test:native-editor            # Isolated fixture-backed editor journey
```

## Release and platform follow-through

1. Preserve the passing Linux package packet whenever packaging changes.
2. Implement and retain fixture-backed primary native journeys before new UI
   breadth.
3. Obtain Windows ConPTY and macOS shell/WebView/PTY runner evidence, then
   publish their artifact checksums.
4. Collect three GitHub Actions stress samples and regenerate beta readiness.
5. Route the eight open top-20 scenarios and H11E budget rows to their recorded
   owner; do not generalize extension-specific exceptions without proof.

## Maintenance follow-through

- Keep source and generated frontend/package assets aligned after a build.
- Keep `build/` evidence and `frontend/dist/` when they are release inputs; remove rebuildable Zig/Python caches and `/tmp/wizp-*` probe directories after verification.
- Run automated UI/UX tests only through `scripts/run_virtual_ui_test.sh` on Xvfb with Openbox; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1` compositor testing, and virtual-display evidence remains distinct from manual visual and assistive-technology review.
- Continue bounded `Editor`/`ExtensionHost`/protocol extraction with focused
  tests. Do not use cross-build output as native macOS or Windows proof.

<!-- OVERZEER:DOCS_BACKLOG_BEGIN -->
## OVERZEER project summary
- Git evidence in selected window: `72` commit(s).
- Documentation evidence: authored open tasks below; generated text is a proposal and does not mark work complete.
- [ ] [inferred][needs-proof] No authored open checkbox task was found; confirm project priorities manually.
<!-- OVERZEER:DOCS_BACKLOG_END -->
