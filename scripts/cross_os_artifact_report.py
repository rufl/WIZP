#!/usr/bin/env python3
"""Validate downloaded cross-OS package smoke reports."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "build" / "parity-package"
REPORT = REPORT_DIR / "cross-os-artifact-report.json"

RUNNER_TO_SYSTEM = {
    "ubuntu-latest": "linux",
    "macos-latest": "darwin",
    "windows-latest": "windows",
}

REQUIRED_PROOF = {
    "linux": {"terminal-startup", "terminal-session", "daemon-pty-policy", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
    "darwin": {"terminal-startup", "terminal-session", "native-package", "native-shell-runtime", "posix-pty-runtime", "live-webview", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
    "windows": {"terminal-startup", "terminal-session", "native-package", "native-shell-runtime", "conpty-runtime", "live-webview2", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
}


def load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def find_reports() -> list[tuple[Path, dict]]:
    reports = []
    seen = set()
    for path in sorted(REPORT_DIR.glob("**/cross-os-package-report.json")):
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        data = load_json(path)
        if isinstance(data, dict):
            reports.append((path, data))
    return reports


def validate_report(path: Path, data: dict) -> dict:
    os_name = data.get("os")
    expected_runner = data.get("expectedRunner")
    required = REQUIRED_PROOF.get(os_name, set())
    actual_required = set(data.get("requiredProof", []))
    failures = []
    if os_name not in REQUIRED_PROOF:
        failures.append(f"unsupported os {os_name!r}")
    if expected_runner:
        expected_system = RUNNER_TO_SYSTEM.get(expected_runner)
        if expected_system != os_name:
            failures.append(f"expectedRunner {expected_runner!r} maps to {expected_system!r}, report os is {os_name!r}")
    expected_status = "local-package-startup-and-surface-smoke-verified" if os_name == "linux" else "native-package-runtime-smoke-verified"
    if data.get("status") != expected_status:
        failures.append(f"unexpected status {data.get('status')!r}")
    if not required.issubset(actual_required):
        failures.append(f"missing requiredProof entries: {sorted(required - actual_required)}")
    if data.get("extensionHostSmoke", {}).get("ok") is not True:
        failures.append("extensionHostSmoke.ok is not true")
    terminal = data.get("terminalStartup", {})
    if terminal.get("ok") is not True:
        failures.append("terminalStartup.ok is not true")
    terminal_session = data.get("terminalSession", {})
    if terminal_session.get("ok") is not True or terminal_session.get("cleanup") is not True:
        failures.append("terminalSession runtime or cleanup proof is missing")
    surfaces = data.get("daemonSurfaces", {})
    if surfaces.get("ok") is not True:
        failures.append("daemonSurfaces.ok is not true")
    if os_name != "linux":
        package = data.get("nativePackage", {})
        if package.get("ok") is not True or package.get("webviewExecution") is not True:
            failures.append("nativePackage live WebView proof is missing")
        if package.get("cleanExit") is not True:
            failures.append("nativePackage clean exit proof is missing")
        if not package.get("launcherSha256") or not package.get("backendSha256"):
            failures.append("nativePackage checksums are missing")
    if not data.get("binary"):
        failures.append("binary path is missing")
    return {
        "path": str(path.relative_to(ROOT)),
        "os": os_name,
        "expectedRunner": expected_runner,
        "valid": not failures,
        "failures": failures,
    }


def main() -> int:
    reports = find_reports()
    validations = [validate_report(path, data) for path, data in reports]
    valid_systems = sorted({item["os"] for item in validations if item["valid"] and item["os"]})
    missing_systems = sorted(set(REQUIRED_PROOF) - set(valid_systems))
    status = "cross-os-artifacts-verified" if not missing_systems and all(item["valid"] for item in validations) else "partial"
    payload = {
        "schema": "wizp.cross-os-artifacts.v1",
        "status": status,
        "validSystems": valid_systems,
        "missingSystems": missing_systems,
        "reports": validations,
        "requiredSystems": sorted(REQUIRED_PROOF),
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"cross-os artifact report: {REPORT} ({status})")
    return 0 if status == "cross-os-artifacts-verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
