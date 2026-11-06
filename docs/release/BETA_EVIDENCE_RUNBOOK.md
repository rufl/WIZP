# WIZP beta evidence runbook

This runbook is the handoff for the external evidence still open in `BACKLOG.md`.
It records what a clean GitHub Actions run must produce and how to validate the
downloaded artifacts locally. Missing external artifacts remain blockers; local
Linux evidence must not be copied into the macOS, Windows, or CI history slots.
Artifact presence alone also cannot close `PROD-B02` Windows ConPTY or
`PROD-B03` macOS native-shell work unless their required runtime surfaces pass.

## Produce evidence

Run the scheduled `WIZP Parity Hardening` workflow, or dispatch it manually from
`.github/workflows/parity-hardening.yml`. The workflow must publish:

- `parity-package-report-ubuntu-latest`
- `parity-package-report-macos-latest`
- `parity-package-report-windows-latest`
- `parity-stress-report`
- `beta-readiness-report` containing `beta-readiness.json`,
  `cross-os-artifact-report.json`, and `stress-trend-report.json`

The beta aggregation job validates this runbook before downloading artifacts;
workflow drift therefore fails the handoff contract before a readiness report
can be published. Artifact downloads are best-effort so a failed or missing
upstream job still produces a blocked readiness report with the missing proof
visible in its artifact summary.

The beta aggregation job also runs the cross-OS and stress-history validators
after download. Those checks are failure-visible but non-blocking for the
aggregation step, preserving a blocked report when external evidence is absent.

The stress job must run `scripts/parity_stress_smoke.py` followed by
`npm run report:stress-trend -- --record-history`. Three records with
`source=github-actions` are required before the trend is verified.

## Validate downloaded artifacts

From `wizp/`, place the downloaded package reports under
`build/parity-package/` and the stress artifact under `build/parity-stress/`,
then run (the beta artifact includes the same aggregate cross-OS report used by
the first command):

```bash
python3 scripts/cross_os_artifact_report.py
npm run check:cross-os-artifacts
npm run test:stress-ci-history
npm run test:performance-baselines
npm run check:extension-timing-boundary
npm run test:budget-gate
npm run report:beta-readiness
npm run check:beta-readiness
npm run check:beta-handoff
npm run test:beta-readiness
```

The expected interim states are `partial` for cross-OS until all three systems
are present, `0/3` or higher CI samples for stress history, and explicit
`extension timing remains unverified` until paired extension timing evidence is
actually supplied. `npm run check:beta-readiness` verifies that the generated
report's status, blocker list, cross-OS partition, and stress trend fields agree;
`npm run check:beta-handoff` additionally verifies that all three published JSON
files agree on cross-OS and stress-trend evidence. These checks do not convert
partial evidence into a pass.

## Current local boundary

As of 2026-07-18, the local Linux package, stress smokes, and first packaged-
native group pass. Exact-package 1/4/8-terminal reports
`20260718T035931Z-1340286`, `20260718T040059Z-1342715`, and
`20260718T035454Z-1325390` retain 60-second survival, clean folderless first
run, 5.658/3.805/1.650 reads/second/session, 3.524%/3.506%/4.452% packaged-main
CPU, no CEF profile warning, and bounded SIGTERM cleanup. The one-terminal run
captures the prompt within 1.479 seconds and retains visible marker-output OCR.
Scheduled report `20260718T040230Z-1344056` survives 1804.055 seconds, retains
its final frame and metrics, records 6.283 reads/second/session, 3.103% main
CPU, and 315,109,376 bytes of steady-state peak RSS growth under the 512 MiB
gate, then exits cleanly. The RSS calculation is reconciled from the retained
1,730 process samples using the first steady process tree rather than the small
launcher-only sample. Current reports retain `windowLifecycle`,
`cefProfileWarning`, `cefProfileSetup`, and `nativeRuntimeDiagnostics`; recorded
runtime stderr markers remain limitations rather than being erased.

None of that local Linux evidence changes the beta boundary: macOS and Windows
artifacts are missing; Windows ConPTY and macOS native-shell/WebView/PTY remain
explicit platform blockers; GitHub Actions stress history is `0/3`; and the
eight H11E performance blockers remain extension-owned with timing unverified.
