# WIZP frontend memory

Purpose: concise handoff for the Svelte workbench. Keep it factual and free of secrets.

## Snapshot

- Path: `desktop/WIZP/wizp/frontend`
- Stack: Svelte 5, Vite 8, Monaco 0.52.2, xterm.js, Tailwind CSS v4
- Primary surface: dense keyboard-first desktop editor inside Electrobun/CEF, with browser fallback for fast proof
- Generated `dist/` is tracked release input; rebuild it whenever source changes

## Current UX boundary

- Editor tabs now have explicit active/inactive/dirty/pinned/close states instead of unstyled concatenated labels.
- Breadcrumbs scroll and truncate long segments; the workbench yields the right sidebar at 1024px; titlebar menus collapse into More at large UI scale; the status bar hides secondary detail before primary state.
- Welcome uses a responsive actions/recent/shortcut layout with bounded long paths and a factual Linux-native description.
- Settings uses a compact native theme selector, remains fully visible at 1024x640, declares its trigger/dialog relationship, blocks background shortcuts while modal, and restores keyboard or pointer trigger focus in Chromium.
- `../build/playwright-smoke/responsive-report.json` passes 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, zero horizontal overflow, compact-shell behavior, and Settings fit.
- `../build/ui-ux/visual/token-contrast.json` records nine passing default static token measurements. `../build/playwright-smoke/responsive-report.json` additionally records a passing Monaco-loaded `one-light` surface/control/boundary/focus contrast measurement. Neither is packaged-native, extension-theme, or platform conformance proof.

## Verification

```bash
npm run build
npm run lint
npm run format:check
cd .. && npm run test:ui-contract
cd .. && npm run check:ui-visual
cd .. && npm run test:parity:playwright
```

Current bundle evidence: 19,086,499 total bytes, 325,514 initial HTML bytes, 152 files, and five oversized deferred assets.

## Continuation rules

- Native rows `UI-NATIVE-006..013`, high-DPI, large-text, pseudo-localization, extension-theme, and manual assistive-technology proof remain open. The editor harness reaches fixture selection under KWin but still loses Quick Open focus; Chromium covers Save As failure preservation and Close All Editors.
- Keep mouse, keyboard, focus restoration, loading, empty, error, success, and long-content states aligned.
- Prefer native HTML/CSS and existing components over new dependencies or abstractions. Browser UI tests stay headless; packaged UI automation must use the project Xvfb wrapper with Openbox and never the active desktop; nested KWin requires explicit `WIZP_ALLOW_NESTED_KWIN=1` compositor testing.
