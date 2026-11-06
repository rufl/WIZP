# WIZP Security Policy

## Scope

WIZP is a local-first Linux alpha editor. This policy covers the Zig backend, Svelte/Electrobun shell, bundled frontend assets, extension host, terminal/PTY integration, dependency manifests, generated reports, and scripts that process workspace files.

## Trust and network boundaries

- Workspace files, extension packages, language-server output, terminal output, and generated artifacts are untrusted input.
- Network access is default-deny or lazy/opt-in for OpenVSX, Git remotes, update checks, AI integrations, extension-owned requests, and other remote services.
- Credentials and tokens must not be placed in source, fixtures, reports, screenshots, or backlog entries.

- ZIPI ACP starts only after an explicit user action, uses the trusted active workspace as its working directory, and runs with filesystem tools disabled. Prompts send only user-entered text plus the active editor buffer, bounded LSP diagnostics, and bounded Git status.
- ZIPI-generated changes are accepted only as a single-file unified diff for an existing workspace file. WIZP rejects traversal, symlink targets, unsupported file operations, and stale base content; it writes only after explicit Apply approval using an atomic same-directory replacement.
- ACP control routes require the local WIZP control token. Trust must remain enabled for prompt, proposal, and apply operations; workspace changes block further prompt/proposal requests until ZIPI is restarted for the new workspace.
- A static contract, dry-run report, staged package, or model-only smoke is not proof that a live remote service or native runtime succeeded.

## Dependency updates

Root and frontend dependencies are reviewed through the committed `package-lock.json` files and the canonical command:

```bash
npm run audit:dependencies
```

The command audits both dependency trees at high severity. A registry/network failure is an unresolved audit result, not a clean pass. Review lockfile diffs, prefer pinned or range-minimized updates, rerun the frontend/backend gates, and regenerate package/audit artifacts before release claims.

Zig dependencies are pinned in `build.zig.zon`; update the commit and hash together, then run `npm run check` and the relevant parity/package gates.

## Untrusted files and generated artifacts

- Do not execute workspace files, extension code, task commands, or downloaded binaries as part of inspection.
- Keep package contents bounded and verify fresh frontend assets before trusting an audit.
- Treat `build/`, `dist/`, `zig-out/`, reports, and screenshots as generated evidence. They must not override live source or runtime truth.
- Terminal output may contain arbitrary control bytes; the renderer filters stray C0/NUL bytes while preserving required ANSI controls.

## Reporting

Report suspected vulnerabilities privately to the project maintainer with reproduction steps, affected version/commit, and sanitized logs. Do not include secrets or exploit payloads in public issues, commits, fixtures, or generated artifacts. If private reporting is unavailable, open a minimal public issue that describes impact without weaponized details.

## Verification boundary

Use `npm run check` for Zig tests and formatting, frontend build/lint/format plus parity smoke for renderer changes, `npm run verify` for the broader package gate, and the native Linux launcher for honest runtime evidence. Cross-build output is not macOS/Windows runtime proof.
