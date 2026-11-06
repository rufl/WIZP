#!/usr/bin/env python3
"""Generate the beta network-policy audit artifact."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

from parity_daemon_smoke import DEFAULT_BIN, RpcClient


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
REPORT = ROOT / "build" / "release" / "network-policy-report.json"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def check_markers(name: str, path: Path, markers: list[str]) -> dict:
    text = read(path)
    missing = [marker for marker in markers if marker not in text]
    return {
        "name": name,
        "path": str(path.relative_to(REPO_ROOT)),
        "status": "pass" if not missing else "fail",
        "missing": missing,
    }


def static_checks() -> list[dict]:
    return [
        check_markers(
            "security-doc-default-deny",
            REPO_ROOT / "docs" / "SECURITY.md",
            [
                "Default startup must not contact the network",
                "OpenVSX search/install: lazy, user-initiated",
                "Git network remotes: manual/opt-in flow",
                "Updates: manual-only for alpha",
                "AI/agent integrations: opt-in",
                "WIZP does not send product analytics on startup",
            ],
        ),
        check_markers(
            "hub-ui-consent",
            ROOT / "frontend" / "src" / "components" / "Hub.svelte",
            [
                "let networkAllowed = $state(false)",
                "allowNetwork",
                "OpenVSX network access is off",
                "Allow OpenVSX Search",
                "sendRpc('hub/search'",
            ],
        ),
        check_markers(
            "scm-remote-consent-ui",
            ROOT / "frontend" / "src" / "components" / "SidebarViews.svelte",
            [
                "git/remoteCredentialPromptPlan",
                "data-manual-only",
                "data-opt-in",
                "dryRun",
                "credentialPolicy",
            ],
        ),
        check_markers(
            "daemon-policy-rpcs",
            ROOT / "src" / "ui" / "Editor.zig",
            [
                "hub/search",
                "allowNetwork",
                "network-consent-required",
                "git/remoteCredentialPromptPlan",
                "optInRequired",
                "debug/adapterInstallPrompt",
                "noAutoNetwork",
                "extension/securityAudit",
                "user-or-extension-owned",
                "platform/signedUpdateSmoke",
            ],
        ),
        check_markers(
            "real-extension-env-opt-in",
            ROOT / "scripts" / "parity_real_extension_smoke.py",
            [
                "WIZP_REAL_EXTENSION_NETWORK=1",
                "WIZP_REAL_EXTENSION_LOAD=1",
                "WIZP_REAL_EXTENSION_RUNTIME=1",
                "requires WIZP_REAL_EXTENSION_NETWORK=1",
            ],
        ),
        check_markers(
            "playwright-consent-proof",
            ROOT / "scripts" / "parity_playwright_smoke.mjs",
            [
                "network-consent-required",
                "OpenVSX network access is off",
                "Allow OpenVSX Search",
                "scm-remote-prompt-plan",
                "credentialPromptRequired",
            ],
        ),
        check_markers(
            "daemon-consent-proof",
            ROOT / "scripts" / "parity_daemon_smoke.py",
            [
                "network-consent-required",
                "networkLazy",
                "credentialPolicy",
                "noAutoNetwork",
                "signedUpdateSmoke",
            ],
        ),
        check_markers(
            "ci-network-isolated-to-explicit-job",
            ROOT / ".github" / "workflows" / "parity-hardening.yml",
            [
                "WIZP_REAL_EXTENSION_NETWORK=1 WIZP_REAL_EXTENSION_LOAD=1",
                "network-policy-report",
                "report:network-policy",
            ],
        ),
    ]


def runtime_probe() -> dict:
    if not DEFAULT_BIN.exists():
        return {
            "status": "blocked",
            "reason": f"missing daemon binary: {DEFAULT_BIN.relative_to(ROOT)}",
        }
    with tempfile.TemporaryDirectory(prefix="wizp-network-policy-") as tmp:
        cwd = Path(tmp)
        subprocess.run(["git", "init", "-b", "main"], cwd=cwd, check=True, stdout=subprocess.DEVNULL)
        client = RpcClient(cwd)
        try:
            hub = client.call("hub/search", {"query": "theme"})
            fixture_hub = client.call("hub/search", {"query": "theme", "fixture": True})
            management = client.call("extensions/management")
            git_prompt = client.call("git/remoteCredentialPromptPlan")
            debug_prompt = client.call("debug/adapterInstallPrompt")
            update = client.call("platform/update")
            signed_update = client.call("platform/signedUpdateSmoke")
            extension_security = client.call("extension/securityAudit")
        finally:
            client.close()

    assertions = {
        "hubSearchRequiresConsent": hub.get("networkRequired") is True and hub.get("status") == "network-consent-required",
        "fixtureSearchIsOffline": fixture_hub.get("status") == "fixture-search-complete",
        "managementPolicyLazyOptIn": management.get("networkPolicy") == "lazy-opt-in",
        "gitRemoteOptIn": git_prompt.get("manualOnly") is True and git_prompt.get("optInRequired") is True,
        "gitRemoteNonInteractiveDefault": git_prompt.get("defaultPolicy") == "non-interactive",
        "debugAdapterNoAutoNetwork": debug_prompt.get("noAutoNetwork") is True,
        "updatesSignedManualContract": update.get("signatureRequired") is True and signed_update.get("validSignatureAccepted") is True,
        "extensionOwnedNetworkAudited": extension_security.get("networkPolicy") == "user-or-extension-owned",
    }
    return {
        "status": "pass" if all(assertions.values()) else "fail",
        "assertions": assertions,
    }


def main() -> int:
    checks = static_checks()
    runtime = runtime_probe()
    status = "policy-verified"
    if any(check["status"] != "pass" for check in checks) or runtime["status"] != "pass":
        status = "blocked"
    payload = {
        "schema": "wizp.network-policy.v1",
        "status": status,
        "defaultStartup": {
            "network": "deny",
            "telemetry": "off",
            "proof": "daemon and UI contracts require explicit consent or fixture mode before networked actions",
        },
        "policyClasses": [
            "OpenVSX search/install",
            "Git remotes",
            "update checks",
            "auth/SecretStorage",
            "AI/agent integrations",
            "debug adapter acquisition",
            "extension-owned requests",
        ],
        "staticChecks": checks,
        "runtimeProbe": runtime,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"network policy report: {REPORT} ({status})")
    return 0 if status == "policy-verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
