# frontend Changelog

## Unreleased
- Added reserved inline feedback to Explorer create, rename, and filename validation, clearing validation errors once the name is valid while preserving backend operation failures.
- Added an Interior-inspired determinate/indeterminate progress bar to extension background tasks, honoring reported progress increments and reduced motion.
- Added an explicit expansion control when workspace text-search results reach their current limit.
- Added a reduced-motion-aware typing indicator that announces when ZIPI is responding before streamed text arrives.

- Added Interior-style copy feedback to installed extension IDs so identifiers can be copied with immediate success or error feedback.

- Ported Interior’s layout-stable loading-button feedback to Svelte and applied it to Agent, Extension Hub, Settings, and Git commit actions; loading state keeps keyboard focus and respects reduced motion.
- Added theme-aware copy feedback for completed ZIPI responses, including clipboard fallback, stable button width, selection restoration, and reduced-motion support.
- Added reserved inline validation feedback to ZIPI prompts and Extension Hub search, associating errors with their fields and keeping surrounding controls stationary.

- Hardened the isolated editor lane for virtual focus proxies/root capture; local KWin reaches fixture selection but still routes Quick Open text into the terminal.
- Preserved dirty editor state on Save As failure with actionable copy, and added Close All Editors to File and Command Palette with cross-group browser coverage.
- Added coherent editor-tab active/dirty/pinned/close styling, bounded breadcrumb overflow, responsive sidebar/menu/status behavior, a narrower Welcome layout, and a compact native Settings theme selector.
- Fixed theme changes after Monaco loads by converting backend `rgb(...)` colors to Monaco-compatible hex values; Settings saves no longer fail when switching built-in themes.
- Made Settings controls use theme-relative control tokens with a measured 3:1 boundary floor in `one-light`, while preserving passing text and focus contrast.
- Declared the Settings trigger/dialog relationship, established pointer focus before opening, blocked background workbench shortcuts while the modal is active, and retained focus on the invoking control after close.
- Added Chromium evidence for 1920x1080, 1440x900, 1280x720, 1024x640, 200% app zoom, zero horizontal overflow, compact-shell behavior, Settings fit, and a Monaco-loaded `one-light` Settings state.
- Added nine retained default-token contrast measurements through `npm run check:ui-visual` and strengthened production-copy scanning across source and built assets.
- Refreshed the passing bundle report: 19,086,499 total bytes, 325,514 initial HTML bytes, 152 files, and five oversized deferred assets.
- Imported the xterm stylesheet in the production entry so packaged-native terminals render their prompt and command output correctly.
- Reduced the idle terminal read cadence from 100 ms to 400 ms; active output still reads immediately, while the slower empty-read cadence avoids keeping the packaged native main process above its idle CPU budget.
- Slowed idle extension UI prompt polling to 1000 ms; prompt requests remain best-effort and continue to reschedule after failures, reducing another packaged-native idle request source.
- Removed the implicit packaged-directory workspace fallback and added a visible folderless first-run/Open Folder state; terminal cwd follows the selected workspace only when one exists.
- The latest 60-second Linux package run passed survival, prompt/typed output, and folderless first-run checks but measured 5.333% mean packaged Bun main-process CPU against the 5% baseline budget; UI-NATIVE-003 remains open.
- Refreshed the passing frontend bundle report: 18,979,195 total bytes, 291,264 initial HTML bytes, 151 files, and five oversized deferred assets.
- Initialized project-control documentation from an OVERZEER audit on 2026-07-07.

## Notes

- Record user-visible changes, verification-gate changes, migration notes, and release-affecting fixes here.
- Keep historical entries factual and sync current work back to `BACKLOG.md`, `BACKLOG_ARCHIVE.md`, and `ROADMAP.md`.
- Initial stack signals: Node/JS, Svelte.

<!-- OVERZEER:DOCS_CHANGELOG_BEGIN -->
## Unreleased (frontend)
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
