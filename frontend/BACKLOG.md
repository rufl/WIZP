# WIZP frontend backlog

The parent [`../../BACKLOG.md`](../../BACKLOG.md) is the canonical active queue. This file keeps frontend-owned slices and proof commands close to the Svelte implementation.

## Current proof boundary

- Chromium passes the complete Explorer/editor/Search/SCM/Debug/Extensions/Settings lifecycle and dependency-free accessibility scan, including modal background-shortcut isolation, pointer-trigger focus restoration, and a Monaco-loaded `one-light` theme switch with measured surface, control, boundary, and focus contrast.
- The responsive packet under `../build/playwright-smoke/` passes 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, compact menus, right-sidebar yielding, zero document/body horizontal overflow, and Settings fit.
- `npm run check:ui-visual` records nine passing default static token measurements under `../build/ui-ux/visual/token-contrast.json`.
- These are browser/static results. Automated native UI commands require isolated Xvfb with Openbox and never target the active desktop; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1` compositor testing. The new editor lifecycle harness is CI-wired but has no accepted packet; `UI-NATIVE-006..013` and manual/native proof remain open.

## Active queue

- [ ] [P1][UX][TEST] Make Quick Open retain focus in the fixture-backed editor lane, prove its native lifecycle/session restore, then extend through `UI-NATIVE-007..013`; Chromium already covers Save As failure preservation and Close All Editors.
- [ ] [P2][UX][TEST] Retain reviewed packaged-native visual baselines for the supported dimensions and states now covered in Chromium.
- [ ] [P2][A11Y][TEST] Retain native accessibility-tree, keyboard, and screen-reader evidence for the primary journeys.
- [ ] [P2][UX][TEST] Add native high-DPI, large-text, pseudo-localized, and extension-theme measurements without widening the supported platform claim; the built-in `one-light` browser measurement is retained.

## Local gates

```bash
npm run build
npm run lint
npm run format:check
cd .. && npm run test:ui-contract
cd .. && npm run check:ui-visual
cd .. && npm run test:parity:playwright
```

<!-- OVERZEER:DOCS_BACKLOG_BEGIN -->
## OVERZEER project summary
- Git evidence in selected window: `72` commit(s).
- Documentation evidence: authored open tasks below; generated text is a proposal and does not mark work complete.
- [ ] [P1][UX][TEST] Make Quick Open retain focus in the fixture-backed editor lane, prove its native lifecycle/session restore, then extend through `UI-NATIVE-007..013`; Chromium already covers Save As failure preservation and Close All Editors.
- [ ] [P2][UX][TEST] Retain reviewed packaged-native visual baselines for the supported dimensions and states now covered in Chromium.
- [ ] [P2][A11Y][TEST] Retain native accessibility-tree, keyboard, and screen-reader evidence for the primary journeys.
- [ ] [P2][UX][TEST] Add native high-DPI, large-text, pseudo-localized, and extension-theme measurements without widening the supported platform claim; the built-in `one-light` browser measurement is retained.
<!-- OVERZEER:DOCS_BACKLOG_END -->
