# WIZP frontend roadmap

## Now

- Preserve the complete Chromium lifecycle/accessibility lane, including modal shortcut isolation and keyboard/pointer focus restoration, the passing responsive packet at 1920x1080, 1440x900, 1280x720, 1024x640, and 200% app zoom, and the Monaco-loaded `one-light` surface/control/boundary/focus contrast measurement.
- Keep the workbench compact under constrained width: editor tabs remain legible, breadcrumbs scroll instead of clipping, the right sidebar yields at 1024px, titlebar menus collapse into More at large UI scale, and the status bar drops secondary detail before primary state.
- Keep the frontend bundle within the current budget: 19,086,499 total bytes, 325,514 initial HTML bytes, 152 files, and five oversized deferred assets.

## Next

1. Make Quick Open retain focus in the isolated editor lane, prove edit/save/dirty-close/reopen/session restore, then extend the same boundary through Explorer, Search, SCM, Debug, Extensions, Settings, terminal, and visual journeys.
2. Add native high-DPI, large-text, pseudo-localization, extension-theme, and accessibility-tree review.
3. Preserve the current visual/token checks while fixing only defects demonstrated by native evidence.

## Later

- Split large components only when a measured defect or review boundary justifies it.
- Add dependencies only when existing Svelte, browser, CSS, and Playwright capabilities cannot prove the required behavior.

## Proof rules

- Browser/static checks do not close native window, CEF, PTY, process, crash, high-DPI, extension-theme, or assistive-technology claims.
- Generated `frontend/dist/` remains a tracked release input and must match source after a build.
