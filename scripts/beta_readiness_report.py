#!/usr/bin/env python3
"""Generate a beta readiness summary from local parity artifacts."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
REPORT = ROOT / "build" / "release" / "beta-readiness.json"
JSON_LOAD_ERRORS: dict[Path, str] = {}


ARTIFACTS = {
    "realExtensions": ROOT / "build" / "parity-real-extensions" / "real-extension-report.json",
    "crossOsPackage": ROOT / "build" / "parity-package" / "cross-os-package-report.json",
    "crossOsArtifacts": ROOT / "build" / "parity-package" / "cross-os-artifact-report.json",
    "stress": ROOT / "build" / "parity-stress" / "stress-report.json",
    "stressTrend": ROOT / "build" / "parity-stress" / "stress-trend-report.json",
    "packageAudit": ROOT / "build" / "parity-package" / "bundled-package-audit.json",
    "selfContainedAudit": ROOT / "build" / "parity-package" / "self-contained-strict-audit.json",
    "apiDrift": ROOT / "build" / "vscode-parity" / "api-drift-report.json",
    "networkPolicy": ROOT / "build" / "release" / "network-policy-report.json",
}

REQUIRED_CROSS_OS_PROOF = {
    "linux": {"terminal-startup", "daemon-pty-policy", "webview-resource-policy", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
    "darwin": {"terminal-startup", "native-shell-contract", "posix-pty-contract", "webview-contract", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
    "windows": {"terminal-startup", "native-shell-contract", "conpty-contract", "webview2-contract", "workspace-folders", "diagnostics-export", "path-normalization", "extension-host-smoke"},
}

DOCS = {
    "backlog": REPO_ROOT / "VSCODE_PARITY_BACKLOG.md",
    "matrix": REPO_ROOT / "docs" / "vscode-parity" / "MATRIX.md",
    "knownExtensions": REPO_ROOT / "docs" / "vscode-parity" / "KNOWN_EXTENSIONS.md",
    "securityPrivacy": REPO_ROOT / "docs" / "SECURITY.md",
    "alphaChecklist": REPO_ROOT / "docs" / "release" / "ALPHA_CHECKLIST.md",
}


def load_json(path: Path) -> dict | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        JSON_LOAD_ERRORS[path] = str(exc)
        return None
    if not isinstance(data, dict):
        JSON_LOAD_ERRORS[path] = "top-level JSON value is not an object"
        return None
    return data


def json_error(path: Path) -> str | None:
    return JSON_LOAD_ERRORS.get(path)


def sha256(path: Path) -> str | None:
    if not path.exists() or not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extension_tiers() -> dict:
    path = DOCS["knownExtensions"]
    tiers: dict[str, int] = {}
    if not path.exists():
        return tiers
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|") or line.startswith("| Extension ") or line.startswith("|---"):
            continue
        parts = [part.strip() for part in line.strip("|").split("|")]
        if len(parts) >= 2:
            tiers[parts[1]] = tiers.get(parts[1], 0) + 1
    return tiers


def backlog_status(ids: list[str]) -> dict:
    text = DOCS["backlog"].read_text(encoding="utf-8") if DOCS["backlog"].exists() else ""
    result = {}
    for item_id in ids:
        match = re.search(rf"\| (?:✅ )?{re.escape(item_id)} \|.*?\| ([^|\n]+) \|$", text, re.MULTILINE)
        result[item_id] = match.group(1).strip() if match else "missing"
    return result


def artifact_summary() -> dict:
    summary = {}
    for name, path in ARTIFACTS.items():
        data = load_json(path)
        summary[name] = {
            "path": str(path.relative_to(ROOT)),
            "present": data is not None,
            "sha256": sha256(path),
            "status": data.get("status") if isinstance(data, dict) else None,
            "error": json_error(path),
        }
    cross_os_reports = find_cross_os_reports()
    if cross_os_reports:
        summary["crossOsPackage"]["reports"] = [
            {
                "path": str(path.relative_to(ROOT)),
                "sha256": sha256(path),
                "os": data.get("os"),
                "expectedRunner": data.get("expectedRunner"),
                "status": data.get("status"),
            }
            for path, data in cross_os_reports
        ]
    return summary


def find_cross_os_reports() -> list[tuple[Path, dict]]:
    candidates = sorted((ROOT / "build" / "parity-package").glob("**/cross-os-package-report.json"))
    reports = []
    seen = set()
    for path in candidates:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        data = load_json(path)
        if isinstance(data, dict):
            reports.append((path, data))
    return reports


def known_blockers(cross_os_reports: list[dict], real_extensions: dict | None, network_policy: dict | None, stress_trend: dict | None) -> list[str]:
    blockers = []
    for path, error in sorted(JSON_LOAD_ERRORS.items()):
        blockers.append(f"artifact {path.relative_to(ROOT)} could not be parsed: {error}")
    backlog = backlog_status(
        [
            "PROD-B01",
            "PROD-B02",
            "PROD-B03",
            "PROD-B04",
            "PROD-B05",
            "PROD-B06",
            "PROD-B07",
            "PROD-B09",
            "HARD-023",
        ]
    )
    cross_os_systems = {
        report.get("os")
        for report in cross_os_reports
        if report.get("status") == "local-package-startup-and-surface-smoke-verified"
        and report.get("extensionHostSmoke", {}).get("ok") is True
        and REQUIRED_CROSS_OS_PROOF.get(report.get("os"), set()).issubset(set(report.get("requiredProof", [])))
    }
    if backlog.get("PROD-B01", "").startswith("open") and not {"linux", "darwin", "windows"}.issubset(cross_os_systems):
        blockers.append("macOS/Windows clean-runner package evidence is still required")
    if backlog.get("PROD-B02", "").startswith("open"):
        blockers.append("Windows ConPTY backend and clean-runner terminal proof remain open")
    if backlog.get("PROD-B03", "").startswith("open"):
        blockers.append("macOS native shell, WebView, and PTY clean-runner proof remain open")
    if backlog.get("PROD-B04", "").startswith("open"):
        blockers.append("fewer than five curated extensions have verified/compatible real runtime behavior")
    if backlog.get("PROD-B05", "").startswith("open"):
        blockers.append("cSpell still lacks a positive IPC language-server diagnostics signal")
    if backlog.get("PROD-B06", "") == "open":
        blockers.append("browser axe/equivalent accessibility gate is not yet materialized")
    if backlog.get("PROD-B07", "") == "open" or not network_policy or network_policy.get("status") != "policy-verified":
        blockers.append("unified beta network policy still needs final settings/UI/security audit proof")
    if backlog.get("PROD-B09", "") == "open":
        blockers.append("VS Code API baseline drift detection is not yet generated")
    api_drift = load_json(ARTIFACTS["apiDrift"])
    if not api_drift or api_drift.get("status") == "blocked":
        blockers.append("VS Code API baseline drift report is missing or blocked")
    if not {"linux", "darwin", "windows"}.issubset(cross_os_systems):
        blockers.append("local report is Linux-only; external macOS/windows artifacts must be uploaded")
    if real_extensions and (real_extensions.get("cspellRuntimeProbe") or {}).get("status") == "runtime-command-effects-not-yet-verified":
        blockers.append("cSpell runtime probe remains blocked")
    if backlog.get("HARD-023", "").startswith("open") or not stress_trend or stress_trend.get("status") != "trend-verified":
        blockers.append("long-running stress trend history is not yet verified")
    return sorted(set(blockers))


def main() -> int:
    real_extensions = load_json(ARTIFACTS["realExtensions"])
    cross_os_reports = [data for _, data in find_cross_os_reports()]
    cross_os = cross_os_reports[0] if cross_os_reports else None
    cross_os_artifacts = load_json(ARTIFACTS["crossOsArtifacts"])
    stress = load_json(ARTIFACTS["stress"])
    stress_trend = load_json(ARTIFACTS["stressTrend"])
    api_drift = load_json(ARTIFACTS["apiDrift"])
    network_policy = load_json(ARTIFACTS["networkPolicy"])
    payload = {
        "schema": "wizp.beta-readiness.v1",
        "status": "blocked",
        "artifacts": artifact_summary(),
        "extensionTiers": extension_tiers(),
        "backlog": backlog_status(
            [
                "PROD-B01",
                "PROD-B02",
                "PROD-B03",
                "PROD-B04",
                "PROD-B05",
                "PROD-B06",
                "PROD-B07",
                "PROD-B08",
                "PROD-B09",
                "PROD-B10",
                "HARD-023",
            ]
        ),
        "crossOs": {
            "artifactStatus": cross_os_artifacts.get("status") if cross_os_artifacts else None,
            "artifactReport": str(ARTIFACTS["crossOsArtifacts"].relative_to(ROOT)),
            "artifactValidSystems": cross_os_artifacts.get("validSystems", []) if cross_os_artifacts else [],
            "artifactMissingSystems": cross_os_artifacts.get("missingSystems", sorted(REQUIRED_CROSS_OS_PROOF)) if cross_os_artifacts else sorted(REQUIRED_CROSS_OS_PROOF),
            "reports": [
                {
                    "os": report.get("os"),
                    "expectedRunner": report.get("expectedRunner"),
                    "requiredProof": report.get("requiredProof", []),
                    "extensionHostSmoke": report.get("extensionHostSmoke"),
                    "status": report.get("status"),
                }
                for report in cross_os_reports
            ],
            "systems": sorted({report.get("os") for report in cross_os_reports if report.get("os")}),
            "workflowMatrix": cross_os.get("workflowMatrix") if cross_os else [],
        },
        "realExtensions": {
            "status": real_extensions.get("status") if real_extensions else None,
            "cspellStatus": (real_extensions.get("cspellRuntimeProbe") or {}).get("status") if real_extensions else None,
            "editorconfigStatus": (real_extensions.get("runtimeCommand") or {}).get("status") if real_extensions else None,
            "pathIntellisenseStatus": (real_extensions.get("runtimeProvider") or {}).get("status") if real_extensions else None,
            "npmIntellisenseStatus": (real_extensions.get("runtimeNpmProvider") or {}).get("status") if real_extensions else None,
            "autoCloseTagStatus": (real_extensions.get("runtimeAutoCloseTag") or {}).get("status") if real_extensions else None,
            "colorHighlightStatus": (real_extensions.get("runtimeColorHighlight") or {}).get("status") if real_extensions else None,
        },
        "stress": {
            "status": stress.get("status") if stress else None,
            "artifact": str(ARTIFACTS["stress"].relative_to(ROOT)),
            "trendStatus": stress_trend.get("status") if stress_trend else None,
            "trendArtifact": str(ARTIFACTS["stressTrend"].relative_to(ROOT)),
            "trendHistoryCount": stress_trend.get("historyCount") if stress_trend else None,
            "trendCiHistoryCount": stress_trend.get("ciHistoryCount") if stress_trend else None,
            "trendMissingCiHistoryCount": stress_trend.get("missingCiHistoryCount") if stress_trend else None,
            "trendRequiredHistory": stress_trend.get("requiredHistoryForTrend") if stress_trend else None,
            "trendRequiredSource": stress_trend.get("requiredSourceForTrend") if stress_trend else None,
            "trendReady": stress_trend.get("trendReady") if stress_trend else None,
            "trendHistoryBySource": stress_trend.get("historyBySource") if stress_trend else None,
            "trendNextActions": stress_trend.get("nextActions") if stress_trend else None,
        },
        "apiDrift": {
            "status": api_drift.get("status") if api_drift else None,
            "artifact": str(ARTIFACTS["apiDrift"].relative_to(ROOT)),
        },
        "networkPolicy": {
            "status": network_policy.get("status") if network_policy else None,
            "artifact": str(ARTIFACTS["networkPolicy"].relative_to(ROOT)),
        },
        "docs": {name: str(path.relative_to(REPO_ROOT)) for name, path in DOCS.items()},
        "knownBlockers": known_blockers(cross_os_reports, real_extensions, network_policy, stress_trend),
    }
    if not payload["knownBlockers"]:
        payload["status"] = "ready"
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"beta readiness report: {REPORT} ({payload['status']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
