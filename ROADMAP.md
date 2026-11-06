# WIZP roadmap

## Now

- Preserve the Linux packaged-native `UI-NATIVE-001..005` packet: 1/4/8
  terminal CPU/read evidence, strict prompt/marker proof, clean first run, and
  30-minute soak.
- Continue deterministic primary journeys `UI-NATIVE-006..013` from
  [`docs/ui-ux/TEST_BACKLOG.md`](docs/ui-ux/TEST_BACKLOG.md). Retained packaged
  Settings run `20260813T161414Z-3100624`, editor run
  `20260812T203615Z-1613262`, Explorer run `20260812T221451Z-2137710`, and
  Search run `20260813T155115Z-2982087` cover their bounded Linux lifecycle,
  recovery, semantic, screenshot/OCR, profile-cleanup, and clean-teardown
  slices. Retained SCM run `20260813T162841Z-3165689` covers repository load,
  real `.git` write-permission failure and stage recovery, stage/unstage,
  commit, discard cancel/confirm, branch checkout, and commit diff. Retained
  Debug run `20260813T163636Z-3200207` covers missing-adapter initialization
  failure and recovery, launch loading, paused start, controls, stepping,
  runtime inspection, evaluation, restart/stop, and focus restoration.
  Retained Extensions run
  `20260813T132228Z-2549897` covers consent, fixture install, native VSIX
  chooser review, enable/disable persistence, uninstall focus behavior, host
  restart, and contributions. Retained Terminal run
  `20260813T132452Z-2554796` covers command/ANSI/Unicode rendering, find,
  new/split/rerun/kill, and session cleanup. Their report validators pass and
  parity-hardening runs and uploads all eight primary journeys. Each row
  remains partial for its named untested recovery paths, assistive-technology,
  and non-Linux evidence.
- Preserve the browser visual/responsive packet: reviewed screenshots and
  `responsive-report.json` pass 1920x1080, 1440x900, 1280x720, 1024x640,
  200% app zoom, compact menus, right-sidebar yielding, zero horizontal
  overflow, and Settings fit. `npm run check:ui-visual` retains nine measured
  default-token contrast pairs and a measured Monaco-loaded `one-light` switch.
  Also preserve eight checksum-bound, automation-assisted-reviewed Linux
  packaged-native default-state frames. Native high-DPI, extension-theme,
  large-text, pseudo-localization, manual visual, and assistive-technology
  proof remain open.
- Keep the canonical active queue in [`../BACKLOG.md`](../BACKLOG.md); move only
  proof-backed completion into [`BACKLOG_ARCHIVE.md`](BACKLOG_ARCHIVE.md).
- Maintain `npm run check`, `npm run test:ui-contract`, frontend lint/format,
  parity smoke, and `npm run verify` as the local quality boundary.

## Next

1. Preserve and extend the eight retained packaged primary-journey packets
   without weakening their validators, cleanup bounds, or Chromium assertions.
2. Finish native editor manual Save As chooser review, assistive-technology
   sign-off, and the first retained scheduled CI artifact.
3. Finish packaged Settings assistive-technology and non-Linux evidence without
   weakening retained partial-sync recovery run
   `20260813T161414Z-3100624`.
4. Extend the checksum-bound packaged-native default-state baselines to dynamic
   theme, high-DPI, large-text, pseudo-localization, and manual review without
   treating Linux automation as extension-theme or platform proof.
5. Close Windows ConPTY and macOS shell/WebView/PTY runner proof, then produce
   real cross-OS package artifacts.
6. Collect three GitHub Actions stress samples and regenerate the beta report.
7. Close the eight open top-20 scenarios and eight H11E budget blockers with
   their owner-specific evidence.
8. Extend local daemon/terminal shutdown profiling to allocation and platform
   reader-shutdown evidence, then make only the bounded extraction it justifies.

## Later

- Complete visual/responsive, recovery, and manual assistive-technology lanes.
- Revisit optional modes and architecture only where measurable delivery risk
  requires it.

## Proof rules

- Browser/static tests cannot close packaged-native, CEF, PTY, crash,
  assistive-technology, or cross-platform claims. Automated UI tests must use `scripts/run_virtual_ui_test.sh` and never the active desktop.
- Cross-compilation is not macOS/Windows runtime proof.
- Retain release outputs and evidence reports; clean only rebuildable caches
  and temporary probe directories after verification.
