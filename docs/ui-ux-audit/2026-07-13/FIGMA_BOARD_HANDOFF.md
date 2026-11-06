# WIZP UI/UX audit board handoff

Status: **Figma placement blocked — no Figma creation/image-placement capability is available in this workspace**  
Prepared: 2026-07-13  
Section title: `WIZP Native UI/UX Audit — 2026-07-13`

This is the exact board specification to use when a Figma-capable workspace becomes available. It does not claim that a Figma file or board currently exists.

## Section geometry

- Section origin: `x=-100`, `y=-100`
- Section size: `w=4240`, `h=1900`
- Background: neutral dark gray suitable for reviewing the WIZP dark shell
- Screenshots remain at native size, left to right on one row
- Horizontal space between screenshot bounds: exactly `200 px`
- Notes begin `120 px` below the bottom edge of each screenshot

## Accepted evidence manifest

| Step | Local file | Size | SHA-256 | Board position |
| ---: | --- | --- | --- | --- |
| 1 | `screenshots/01-launch.png` | 1920 x 1080 RGBA | `d3680976aa4681ea7eb246c390dc534ecc890680f851d380410df4f680633dcc` | `x=0`, `y=0` |
| 2 | `screenshots/02-command-palette.png` | 1920 x 1057 RGB | `210fde81c643438105576520528d9962c1ac863a404361e272f63569cab8aa68` | `x=2120`, `y=0` |

The second frame starts at `1920 + 200 = 2120`, satisfying the required 200 px spacing.

## Card 1 notes

Position: `x=0`, `y=1200`, width `1920`  
Title: `Step 1 — Native launch and first-run state`  
Health: `CRITICAL`

Strengths:

- Coherent dark shell, recognizable editor regions, consistent icon language.
- Welcome actions and shortcut summary give the screen an initial purpose.
- Terminal lifecycle label and ready indicator are useful concepts.

Issues:

- The package opens `Resources/app` and exposes `bun`, `frontend-dist`, and the packaged executable as a user workspace while also saying `Untitled`.
- The active ready `bash` terminal is visibly blank.
- Secondary labels, borders, and small controls have weak visual separation.
- Welcome content is visually left-weighted with a large inactive canvas.
- Native OS decoration and the in-app title bar create double chrome.

Accessibility risks visible in this frame:

- Small action targets and low-emphasis text may be difficult at high DPI or zoom.
- Visible focus, reading order, keyboard operation, and announcements cannot be established from the screenshot alone.

Evidence limit:

- The app later crashed; this frame proves the rendered launch state only, not successful editor or terminal interaction.

## Card 2 notes

Position: `x=2120`, `y=1177`, width `1920`  
Title: `Step 2 — Command palette`  
Health: `DEGRADED`

Strengths:

- Compact command list, sensible grouping, and clear top-center placement.
- Arrow, Enter, and Escape paths are implemented.

Issues:

- Initial input shows only `>` rather than a descriptive prompt.
- Selected-row contrast and focus/modal context are subtle.
- Closing the palette forces editor focus instead of restoring the invoker.
- The blank terminal remains visible in the background.

Accessibility risks visible or code-confirmed for this step:

- The palette lacks complete combobox/listbox/option relationships, active-descendant state, and selected-result semantics.
- Screenshot review cannot validate screen-reader output or complete focus traversal.

Evidence limit:

- The app crashed before downstream commands and all major views could be exercised reliably.

## Board footer

Position: `x=0`, `y=1650`, width `4040`  
Title: `Overall verdict — native UI/UX baseline failed`

Footer copy:

> Three packaged launches reproduced a blank ready terminal, approximately 1,070 idle RPC requests in five seconds, approximately 99% Electrobun main-process CPU, and signal 11 / exit 139. Editor, search, SCM, debug, extensions, settings, responsive, and assistive-technology journeys remain blocked. See REPORT.md and docs/ui-ux/TEST_BACKLOG.md for findings and the 23-test implementation program.

## Rejected captures

These files were deliberately excluded and should not be uploaded:

- `03-command-filter.png` — an external Yakuake/NOCTTY surface obscured WIZP.
- `03-native-blackout.png` — external terminal overlay, not accepted WIZP evidence.
- `03-quick-open.png` — blank/ambiguous renderer-loss capture.

## Figma completion checklist

- Create one Section with the exact title above.
- Place both accepted screenshots visibly at the recorded positions.
- Confirm both screenshots match their SHA-256 values before upload.
- Place the matching notes under each screenshot and the verdict footer below both cards.
- Render or inspect the completed board and verify that neither screenshot is blank, cropped, misplaced, or only present as an unused asset.
- Record the Figma URL in this file and the audit report only after visual inspection succeeds.
