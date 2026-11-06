#!/usr/bin/env python3
"""Generate a compatibility planning report for top OpenVSX extensions."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parent
REPORT_JSON = ROOT / "build" / "vscode-parity" / "openvsx-top-extensions.json"
DASHBOARD_JSON = ROOT / "build" / "vscode-parity" / "openvsx-compatibility-dashboard.json"
TOP20_RUNTIME_JSON = ROOT / "build" / "vscode-parity" / "openvsx-top20-runtime-coverage.json"
REPORT_MD = REPO_ROOT / "docs" / "vscode-parity" / "TOP_OPENVSX_EXTENSIONS.md"
DASHBOARD_MD = REPO_ROOT / "docs" / "vscode-parity" / "OPENVSX_COMPATIBILITY_DASHBOARD.md"
TOP20_RUNTIME_MD = REPO_ROOT / "docs" / "vscode-parity" / "TOP20_RUNTIME_COVERAGE.md"
KNOWN_EXTENSIONS_MD = REPO_ROOT / "docs" / "vscode-parity" / "KNOWN_EXTENSIONS.md"
USER_AGENT = "WIZP OpenVSX compatibility planning"

RUNTIME_EVIDENCE_DETAILS = {
    "language/tooling runtime smoke",
    "formatter/linter runtime smoke",
    "top-20 targeted activation smoke",
    "top-20 pack child runtime rollup",
    "official Codex VS Code extension and CLI app-server smoke",
}

RUNTIME_STATUS_TOKENS = (
    "runtime",
    "degraded",
    "platform-mismatch",
    "host-timeout",
    "bounded",
    "recovered",
)

TOP20_RUNTIME_ACCEPTANCE: dict[str, str] = {
    "meta.pyrefly": "✅ Keep the bundled-binary platform-mismatch activation proof green and host-responsive.",
    "ms-python.python": "✅ Keep Python main-extension host-timeout recovery, zero startup network/process evidence, debugpy/Python Environments child runtime proofs, and explicit OpenVSX-unavailable Pylance classification green.",
    "ms-python.debugpy": "Verify debug adapter contribution resolution, launch schema, adapter process path, and a bounded degraded/run smoke.",
    "vscjava.vscode-java-dependency": "Verify Java project/dependency tree commands/views and no-JDK degraded behavior against the existing Red Hat Java runtime contract.",
    "redhat.java": "✅ Keep missing-JDK and valid-JDK host-timeout recovery evidence green; deepen full JDT behavior separately.",
    "Shopify.ruby-lsp": "✅ Keep missing-Ruby degraded activation evidence green; deepen valid Ruby LSP behavior separately.",
    "ms-python.vscode-python-envs": "Verify interpreter/env discovery commands, task contribution metadata, and missing/interpreter-less degraded UX.",
    "devsense.composer-php-vscode": "✅ Keep Composer workspace activation with seeded composer/php paths, headless notification dismissal, bounded diagnostic-RPC recovery, zero process spawn, and audited Application Insights telemetry evidence green.",
    "devsense.profiler-php-vscode": "✅ Keep profiler command activation, custom-editor contribution registration, zero process spawn, and zero-or-one audited Application Insights telemetry entries green.",
    "devsense.phptools-vscode": "✅ Keep PHP Tools main-extension missing-PHP host-timeout recovery, PHP debugger metadata, zero network/process evidence, and PHP pack child accounting green; Composer remains its own runtime row.",
    "vscjava.vscode-maven": "Verify Maven explorer/commands/tasks and missing-maven or no-project degraded UX.",
    "vscjava.vscode-java-debug": "Verify Java debug adapter contribution resolution, launch schema, and bounded no-JDK/no-project debug UX.",
    "golang.Go": "✅ Keep missing Go/gopls degraded activation and command evidence green; deepen valid Go debug behavior separately.",
    "Anthropic.claude-code": "✅ Keep startup host-timeout recovery, contributed command/view surface, zero startup network/process evidence, and auth/terminal/webview execution gated behind explicit user commands.",
    "llvm-vs-code-extensions.vscode-clangd": "✅ Keep missing-clangd degraded activation evidence green; deepen valid clangd behavior separately.",
    "vscjava.vscode-gradle": "Verify Gradle explorer/commands/tasks and missing-gradle or no-project degraded UX.",
    "vscjava.vscode-java-test": "Verify test discovery/run-result contribution behavior and bounded no-JDK/no-project degraded UX.",
    "vscjava.vscode-java-pack": "Roll verified Red Hat Java, Maven, Gradle, Debug, and Test child evidence into a pack-level runtime/degraded record and document any unavailable child gaps.",
    "eamodio.gitlens": "✅ Keep offline startup, built-in Git API shim, SCM/tree surfaces, bounded non-repo git probes, and audited offline GitKraken config evidence green; deepen real repository/webview behavior separately.",
    "ms-azuretools.vscode-containers": "✅ Keep missing-Docker bounded activation, Docker debugger metadata, contributed command, LM tool, and bundled Dockerfile/Compose IPC server evidence green; deepen real Docker runtime behavior separately.",
}

JAVA_PACK_RUNTIME_CHILDREN = [
    "redhat.java",
    "vscjava.vscode-java-dependency",
    "vscjava.vscode-maven",
    "vscjava.vscode-java-debug",
    "vscjava.vscode-gradle",
    "vscjava.vscode-java-test",
]


def fetch_json(url: str, timeout: int = 30) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_text(url: str, timeout: int = 30) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def compact_int(value: object) -> str:
    try:
        number = int(value)
    except Exception:
        return "n/a"
    if number >= 1_000_000:
        return f"{number / 1_000_000:.1f}M"
    if number >= 1_000:
        return f"{number / 1_000:.0f}K"
    return str(number)


def extension_id(item: dict[str, Any]) -> str:
    return f"{item.get('namespace')}.{item.get('name')}"


def latest_metadata(item: dict[str, Any]) -> dict[str, Any]:
    namespace = item.get("namespace")
    name = item.get("name")
    if not namespace or not name:
        return item
    try:
        richer = fetch_json(f"https://open-vsx.org/api/{namespace}/{name}")
        merged = dict(item)
        merged.update(richer)
        return merged
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return item


def manifest_for(item: dict[str, Any]) -> dict[str, Any]:
    manifest_url = ((item.get("files") or {}).get("manifest"))
    if not manifest_url:
        return {}
    try:
        return json.loads(fetch_text(str(manifest_url)))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return {}


def as_list(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def contributes_keys(manifest: dict[str, Any]) -> list[str]:
    contributes = manifest.get("contributes")
    if not isinstance(contributes, dict):
        return []
    return sorted(str(key) for key in contributes)


def text_blob(item: dict[str, Any], manifest: dict[str, Any]) -> str:
    fields = [
        extension_id(item),
        str(item.get("displayName") or ""),
        str(item.get("description") or ""),
        " ".join(str(x) for x in as_list(item.get("categories"))),
        " ".join(str(x) for x in as_list(item.get("tags"))),
        " ".join(contributes_keys(manifest)),
    ]
    return " ".join(fields).lower()


def metadata_blob(item: dict[str, Any]) -> str:
    fields = [
        extension_id(item),
        str(item.get("displayName") or ""),
        str(item.get("description") or ""),
        " ".join(str(x) for x in as_list(item.get("categories"))),
        " ".join(str(x) for x in as_list(item.get("tags"))),
    ]
    return " ".join(fields).lower()


def classify_lane(item: dict[str, Any], manifest: dict[str, Any]) -> str:
    extension = extension_id(item).lower()
    if extension in {"shopify.ruby-lsp", "vue.volar", "dart-code.dart-code"}:
        return "language/tooling"
    keys = set(contributes_keys(manifest))
    categories = {str(x).lower() for x in as_list(item.get("categories"))}
    blob = text_blob(item, manifest)
    metadata = metadata_blob(item)
    if keys & {"themes", "iconThemes", "productIconThemes"} or "themes" in categories:
        return "theme/icon"
    if "extension packs" in categories or manifest.get("extensionPack"):
        return "extension pack"
    if re.search(r"\b(ai|copilot|claude|codex|cline|continue|roo|agent|chat|assistant|gemini|openai|anthropic)\b", metadata):
        return "ai/agent"
    if re.search(r"\b(git|gitlab|github|docker|kubernetes|remote|container|ssh|cloud)\b", blob):
        return "scm/cloud/remote"
    if keys & {"debuggers", "breakpoints"} or re.search(r"\b(debug|dap)\b", blob):
        return "debug/tooling"
    if "programming languages" in categories or keys & {"languages", "grammars", "snippets"}:
        return "language/tooling"
    if re.search(r"\b(vim|keymap|emmet|markdown|sorter|editorconfig)\b", metadata):
        return "editor workflow"
    if "formatters" in categories or "linters" in categories:
        return "formatter/linter"
    return "general extension"


def needs_for(item: dict[str, Any], manifest: dict[str, Any]) -> list[str]:
    keys = set(contributes_keys(manifest))
    blob = text_blob(item, manifest)
    needs: set[str] = set()
    if keys & {"themes", "iconThemes", "productIconThemes", "colors"}:
        needs.add("theme/icon contribution rendering")
    if keys & {"languages", "grammars", "snippets"}:
        needs.add("language/grammar/snippet contributions")
    if keys & {"commands", "menus", "keybindings", "configuration"}:
        needs.add("commands/menus/keybindings/config")
    if keys & {"views", "viewsContainers", "viewsWelcome"}:
        needs.add("tree/views contribution runtime")
    if keys & {"debuggers", "breakpoints"}:
        needs.add("debug adapter integration")
    if keys & {"taskDefinitions", "problemMatchers"}:
        needs.add("tasks/problem matchers")
    if keys & {"jsonValidation", "resourceLabelFormatters"}:
        needs.add("JSON/resource label contributions")
    if re.search(r"\b(languageclient|vscode-languageclient|lsp|server|typescript-language-server|jdt|pyright|rust-analyzer|clangd)\b", blob):
        needs.add("language-client/LSP process support")
    if re.search(r"\b(prettier|eslint|ruff|formatter|lint|linter)\b", blob):
        needs.add("format/lint provider runtime")
    if re.search(r"\b(webview|preview|graph|notebook|test explorer)\b", blob):
        needs.add("webview/custom UI surface")
    if re.search(r"\b(git|gitlab|github|pull request|scm)\b", blob):
        needs.add("SCM/auth/network integration")
    if re.search(r"\b(docker|kubernetes|remote|container|ssh|terminal|shell|cli)\b", blob):
        needs.add("terminal/process/network integration")
    if re.search(r"\b(ai|copilot|claude|codex|cline|continue|roo|chat|agent)\b", blob):
        needs.add("AI/chat/auth/network policy")
    if manifest.get("main") or manifest.get("browser"):
        needs.add("extension host JS runtime")
    if not needs:
        needs.add("manifest/loadability smoke")
    return sorted(needs)


def risk_for(lane: str, needs: list[str]) -> str:
    joined = " ".join(needs)
    if lane == "theme/icon" and needs == ["theme/icon contribution rendering"]:
        return "low"
    if any(token in joined for token in ["AI/chat", "SCM/auth", "terminal/process", "debug adapter", "language-client", "webview"]):
        return "high"
    if "extension host JS runtime" in needs or "format/lint" in joined:
        return "medium"
    return "low"


def top_extensions(size: int) -> list[dict[str, Any]]:
    url = f"https://open-vsx.org/api/-/search?size={size}&sortBy=downloadCount&sortOrder=desc"
    payload = fetch_json(url)
    extensions = payload.get("extensions")
    if not isinstance(extensions, list):
        raise AssertionError("OpenVSX search response did not include extensions[]")
    return [item for item in extensions if isinstance(item, dict)]


def cached_top_extensions_report(size: int) -> dict[str, Any] | None:
    if not REPORT_JSON.exists():
        return None
    try:
        payload = json.loads(REPORT_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    extensions = payload.get("extensions")
    if not isinstance(extensions, list):
        return None
    entries = [item for item in extensions[:size] if isinstance(item, dict)]
    if len(entries) < size:
        return None
    lane_counts: dict[str, int] = {}
    risk_counts: dict[str, int] = {}
    need_counts: dict[str, int] = {}
    for entry in entries:
        lane = str(entry.get("lane") or "unknown")
        risk = str(entry.get("risk") or "unknown")
        lane_counts[lane] = lane_counts.get(lane, 0) + 1
        risk_counts[risk] = risk_counts.get(risk, 0) + 1
        for need in as_list(entry.get("needs")):
            if isinstance(need, str):
                need_counts[need] = need_counts.get(need, 0) + 1
    generated_at = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return {
        "schema": "wizp.openvsx-top-extensions.v1",
        "generatedAt": generated_at,
        "source": "https://open-vsx.org/api/-/search?sortBy=downloadCount&sortOrder=desc (cached fallback)",
        "size": size,
        "laneCounts": dict(sorted(lane_counts.items())),
        "riskCounts": dict(sorted(risk_counts.items())),
        "needCounts": dict(sorted(need_counts.items(), key=lambda item: (-item[1], item[0]))),
        "extensions": entries,
    }


def build_report(size: int) -> dict[str, Any]:
    if os.environ.get("WIZP_OPENVSX_CACHED_ONLY") == "1":
        cached = cached_top_extensions_report(size)
        if cached is not None:
            return cached
    generated_at = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    entries = []
    lane_counts: dict[str, int] = {}
    risk_counts: dict[str, int] = {}
    need_counts: dict[str, int] = {}
    try:
        search_items = top_extensions(size)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, AssertionError):
        cached = cached_top_extensions_report(size)
        if cached is not None:
            return cached
        raise
    for index, search_item in enumerate(search_items, start=1):
        item = latest_metadata(search_item)
        manifest = manifest_for(item)
        lane = classify_lane(item, manifest)
        needs = needs_for(item, manifest)
        risk = risk_for(lane, needs)
        for need in needs:
            need_counts[need] = need_counts.get(need, 0) + 1
        lane_counts[lane] = lane_counts.get(lane, 0) + 1
        risk_counts[risk] = risk_counts.get(risk, 0) + 1
        entries.append(
            {
                "rank": index,
                "id": extension_id(item),
                "displayName": item.get("displayName") or extension_id(item),
                "version": item.get("version"),
                "downloadCount": item.get("downloadCount"),
                "categories": as_list(item.get("categories")),
                "contributes": contributes_keys(manifest),
                "lane": lane,
                "risk": risk,
                "needs": needs,
                "url": f"https://open-vsx.org/extension/{item.get('namespace')}/{item.get('name')}",
            }
        )
    return {
        "schema": "wizp.openvsx-top-extensions.v1",
        "generatedAt": generated_at,
        "source": "https://open-vsx.org/api/-/search?sortBy=downloadCount&sortOrder=desc",
        "size": size,
        "laneCounts": dict(sorted(lane_counts.items())),
        "riskCounts": dict(sorted(risk_counts.items())),
        "needCounts": dict(sorted(need_counts.items(), key=lambda item: (-item[1], item[0]))),
        "extensions": entries,
    }


def parse_known_extension_tiers() -> dict[str, dict[str, str]]:
    if not KNOWN_EXTENSIONS_MD.exists():
        return {}
    result: dict[str, dict[str, str]] = {}
    for line in KNOWN_EXTENSIONS_MD.read_text(encoding="utf-8").splitlines():
        if not line.startswith("| ") or line.startswith("| Extension ") or line.startswith("|---"):
            continue
        parts = [part.strip() for part in line.strip().strip("|").split("|")]
        if len(parts) < 4:
            continue
        extension, tier, reason, owner = parts[:4]
        if not extension or extension == "Extension":
            continue
        result[extension.lower()] = {
            "tier": tier,
            "reason": reason,
            "owner": owner,
        }
    return result


def lane_owner(lane: str, needs: list[str]) -> str:
    joined = " ".join(needs)
    if lane == "theme/icon":
        return "CDR-003"
    if lane == "extension pack":
        return "CDR-009"
    if "AI/chat" in joined:
        return "CDR-008"
    if lane == "language/tooling" or "language-client" in joined or "language/grammar" in joined:
        return "CDR-004"
    if lane == "ai/agent":
        return "CDR-008"
    if lane == "scm/cloud/remote" or "SCM/auth" in joined or "terminal/process" in joined:
        return "CDR-007"
    if lane == "debug/tooling" or "debug adapter" in joined:
        return "CDR-006"
    if lane == "formatter/linter" or "format/lint" in joined:
        return "CDR-005"
    return "CDR-010"


def lane_gap(lane: str, needs: list[str]) -> str:
    owner = lane_owner(lane, needs)
    if owner == "CDR-003":
        return "Theme/icon contribution discovery verified for current top candidates; add visual screenshot/rendering evidence before broad UI claims."
    if owner == "CDR-004":
        return "Needs runtime language tooling smoke: activation, LSP/process launch or degraded mode, diagnostics/completion/formatting, workspace config, and no default network."
    if owner == "CDR-005":
        return "Needs formatter/linter smoke: document/range format, format-on-save/save participants, diagnostics lifecycle, config precedence, and missing-tool messaging."
    if owner == "CDR-006":
        return "Needs debug/test/notebook smoke: adapter contribution resolution, launch schema, test discovery/run results, notebook/webview behavior."
    if owner == "CDR-007":
        return "Needs SCM/cloud/remote smoke: tree/webview/auth/terminal behavior, offline degraded UX, and explicit network consent."
    if owner == "CDR-008":
        return "Needs AI/agent smoke: commands/views/webviews/terminals under no-startup-network policy, authenticated model-turn/session behavior, and product-specific auth/consent UX."
    if owner == "CDR-009":
        return "OpenVSX pack/dependency expansion is verified; remaining risk belongs to child runtime lanes and source-unavailable children recorded in the pack smoke."
    return "Needs dashboard triage and an owning lane."


def latest_real_extension_report() -> dict[str, Any]:
    path = ROOT / "build" / "parity-real-extensions" / "real-extension-report.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def smoke_evidence_by_extension(real_report: dict[str, Any]) -> dict[str, dict[str, str]]:
    evidence: dict[str, dict[str, str]] = {}

    def mark(extension_id: object, status: object, artifact: str, detail: str, priority: int = 0) -> None:
        if not isinstance(extension_id, str) or not extension_id:
            return
        key = extension_id.lower()
        existing = evidence.get(key)
        value = {
            "status": str(status or "recorded"),
            "artifact": artifact,
            "detail": detail,
            "priority": str(priority),
        }
        existing_priority = int(existing.get("priority", "0")) if existing else -1
        if existing is None or priority >= existing_priority or existing.get("status", "").endswith("partial"):
            evidence[key] = value

    for package in as_list(real_report.get("packages")):
        if isinstance(package, dict):
            mark(package.get("id"), package.get("status"), "build/parity-real-extensions/real-extension-report.json", "curated package manifest verified", priority=10)

    top = real_report.get("topOpenVSXLoadability")
    if isinstance(top, dict):
        load = top.get("loadability")
        load_status = load.get("status") if isinstance(load, dict) else top.get("status")
        for package in as_list(top.get("packages")):
            if isinstance(package, dict):
                mark(package.get("id"), load_status, "build/parity-real-extensions/real-extension-report.json", "top-20 package/loadability/command-surface smoke", priority=20)

    theme_icon = real_report.get("topOpenVSXThemeIcon")
    if isinstance(theme_icon, dict):
        smoke = theme_icon.get("contributionSmoke")
        smoke_status = smoke.get("status") if isinstance(smoke, dict) else theme_icon.get("status")
        for package in as_list(theme_icon.get("packages")):
            if isinstance(package, dict):
                mark(package.get("id"), smoke_status, "build/parity-real-extensions/real-extension-report.json", "theme/icon contribution smoke", priority=30)

    lane_baseline = real_report.get("topOpenVSXLaneBaseline")
    if isinstance(lane_baseline, dict):
        smoke = lane_baseline.get("baselineSmoke")
        smoke_status = smoke.get("status") if isinstance(smoke, dict) else lane_baseline.get("status")
        for package in as_list(lane_baseline.get("packages")):
            if isinstance(package, dict):
                mark(package.get("id"), smoke_status, "build/parity-real-extensions/real-extension-report.json", "remaining-lane command/contribution baseline smoke", priority=40)

    extension_packs = real_report.get("topOpenVSXExtensionPacks")
    if isinstance(extension_packs, dict):
        smoke = extension_packs.get("expandedInstallSmoke")
        smoke_status = smoke.get("status") if isinstance(smoke, dict) else extension_packs.get("status")
        for package in as_list(extension_packs.get("packages")):
            if isinstance(package, dict):
                mark(package.get("id"), smoke_status, "build/parity-real-extensions/real-extension-report.json", "extension-pack/dependency expansion smoke", priority=50)

    language_runtime = real_report.get("topOpenVSXLanguageRuntime")
    if isinstance(language_runtime, dict):
        for key, runtime in language_runtime.items():
            if key == "status" or not isinstance(runtime, dict):
                continue
            mark(
                runtime.get("extensionId"),
                runtime.get("status"),
                "build/parity-real-extensions/real-extension-report.json",
                "language/tooling runtime smoke",
                priority=60,
            )

    formatter_runtime = real_report.get("topOpenVSXFormatterRuntime")
    if isinstance(formatter_runtime, dict):
        for key, runtime in formatter_runtime.items():
            if key == "status" or not isinstance(runtime, dict):
                continue
            mark(
                runtime.get("extensionId"),
                runtime.get("status"),
                "build/parity-real-extensions/real-extension-report.json",
                "formatter/linter runtime smoke",
                priority=60,
            )

    targeted_top20_runtime = real_report.get("topOpenVSXTop20Runtime")
    if isinstance(targeted_top20_runtime, dict):
        for key, runtime in targeted_top20_runtime.items():
            if key == "status" or not isinstance(runtime, dict):
                continue
            mark(
                runtime.get("extensionId"),
                runtime.get("status"),
                "build/parity-real-extensions/real-extension-report.json",
                "top-20 targeted activation smoke",
                priority=70,
            )

    official_codex = real_report.get("officialCodex")
    if isinstance(official_codex, dict):
        smoke = official_codex.get("extensionSmoke")
        smoke_status = smoke.get("status") if isinstance(smoke, dict) else official_codex.get("status")
        mark(
            official_codex.get("extensionId"),
            smoke_status,
            "build/parity-real-extensions/real-extension-report.json",
            "official Codex VS Code extension and CLI app-server smoke",
            priority=80,
        )

    return evidence


def status_has_runtime_evidence(status: str, detail: str) -> bool:
    status_lower = status.lower()
    if status == "not-tested":
        return False
    if any(token in status_lower for token in ("blocked", "failed", "unverified", "unavailable", "partial")):
        return False
    if detail in RUNTIME_EVIDENCE_DETAILS:
        return True
    return any(token in status for token in RUNTIME_STATUS_TOKENS)


def apply_pack_runtime_rollups(rows: list[dict[str, Any]]) -> None:
    rows_by_id = {str(row["id"]).lower(): row for row in rows}
    java_pack = rows_by_id.get("vscjava.vscode-java-pack")
    if not java_pack:
        return
    child_rows = []
    missing_children = []
    for child_id in JAVA_PACK_RUNTIME_CHILDREN:
        child = rows_by_id.get(child_id.lower())
        if not child or not status_has_runtime_evidence(
            str(child.get("smokeStatus") or ""),
            str(child.get("evidenceDetail") or ""),
        ):
            missing_children.append(child_id)
        else:
            child_rows.append(child)
    if missing_children:
        return
    java_pack["smokeStatus"] = "java-pack-child-runtime-rollup-verified"
    java_pack["artifact"] = "build/parity-real-extensions/real-extension-report.json"
    java_pack["evidenceDetail"] = "top-20 pack child runtime rollup"
    java_pack["owningGap"] = "CDR-009"
    child_statuses = ", ".join(f"{row['id']}={row['smokeStatus']}" for row in child_rows)
    java_pack["knownReason"] = (
        "Pack rollup derived from verified Java child runtime/degraded evidence: "
        f"{child_statuses}."
    )
    java_pack["nextGap"] = (
        "Keep Java child runtime/degraded proofs green and refresh the rollup if the pack manifest adds "
        "new OpenVSX-available children."
    )


def build_dashboard(report: dict[str, Any]) -> dict[str, Any]:
    known = parse_known_extension_tiers()
    evidence = smoke_evidence_by_extension(latest_real_extension_report())
    rows = []
    tier_counts: dict[str, int] = {}
    evidence_counts: dict[str, int] = {}
    for item in report["extensions"]:
        key = str(item["id"]).lower()
        known_row = known.get(key, {})
        tier = known_row.get("tier", "Unlisted")
        smoke = evidence.get(key, {})
        smoke_status = smoke.get("status", "not-tested")
        owner = known_row.get("owner") or lane_owner(item["lane"], item["needs"])
        if smoke.get("detail") == "language/tooling runtime smoke":
            owner = "CDR-004"
        if smoke_status != "not-tested" and tier == "Unlisted":
            next_gap = "Promote or adjust ledger row using the latest smoke evidence."
        elif smoke_status != "not-tested":
            next_gap = "Continue hardening the documented remaining limits for this ledger tier."
        elif tier not in {"Unlisted", "Unknown"}:
            next_gap = "Ledger already classifies this row; add runtime smoke only if support is planned."
        else:
            next_gap = lane_gap(item["lane"], item["needs"])
        rows.append(
            {
                "rank": item["rank"],
                "id": item["id"],
                "displayName": item["displayName"],
                "version": item.get("version"),
                "downloadCount": item.get("downloadCount"),
                "lane": item["lane"],
                "risk": item["risk"],
                "tier": tier,
                "knownReason": known_row.get("reason", ""),
                "smokeStatus": smoke_status,
                "artifact": smoke.get("artifact", ""),
                "evidenceDetail": smoke.get("detail", ""),
                "owningGap": owner,
                "nextGap": next_gap,
            }
        )
        tier_counts[tier] = tier_counts.get(tier, 0) + 1
        evidence_counts[smoke_status] = evidence_counts.get(smoke_status, 0) + 1
    apply_pack_runtime_rollups(rows)
    tier_counts = {}
    evidence_counts = {}
    for row in rows:
        tier_counts[str(row["tier"])] = tier_counts.get(str(row["tier"]), 0) + 1
        evidence_counts[str(row["smokeStatus"])] = evidence_counts.get(str(row["smokeStatus"]), 0) + 1
    return {
        "schema": "wizp.openvsx-compatibility-dashboard.v1",
        "generatedAt": report["generatedAt"],
        "sourceReport": str(REPORT_JSON.relative_to(REPO_ROOT)),
        "knownExtensions": str(KNOWN_EXTENSIONS_MD.relative_to(REPO_ROOT)),
        "tierCounts": dict(sorted(tier_counts.items())),
        "evidenceCounts": dict(sorted(evidence_counts.items())),
        "extensions": rows,
    }


def has_runtime_evidence(item: dict[str, Any]) -> bool:
    status = str(item.get("smokeStatus") or "")
    detail = str(item.get("evidenceDetail") or "")
    return status_has_runtime_evidence(status, detail)


def top20_runtime_acceptance(item: dict[str, Any]) -> str:
    key = str(item["id"])
    acceptance = TOP20_RUNTIME_ACCEPTANCE.get(key)
    if acceptance:
        return acceptance
    if item["owningGap"] == "CDR-009":
        return "Resolve pack/dependency children and classify child runtime evidence or explicit unsupported-source records."
    if item["owningGap"] == "CDR-006":
        return "Verify debug/test contribution resolution, launch/test schema, adapter/process behavior, and bounded degraded UX."
    if item["owningGap"] == "CDR-007":
        return "Verify SCM/cloud tree/webview/auth/terminal behavior, offline degraded UX, and explicit network consent."
    if item["owningGap"] == "CDR-008":
        return "Verify no-startup-network activation, authenticated-session behavior, product-specific consent UX, and webview/terminal/API fallback behavior."
    if item["owningGap"] == "CDR-004":
        return "Verify activation plus language/tool process launch or degraded mode, provider registration, diagnostics/config, and no default network."
    return "Add a lane-specific runtime smoke and promote the extension only after artifact-backed evidence exists."


def build_top20_runtime_coverage(dashboard: dict[str, Any]) -> dict[str, Any]:
    rows = []
    lane_counts: dict[str, int] = {}
    runtime_lane_counts: dict[str, int] = {}
    for item in dashboard["extensions"][:20]:
        runtime_verified = has_runtime_evidence(item)
        lane = item["lane"]
        lane_counts[lane] = lane_counts.get(lane, 0) + 1
        if runtime_verified:
            runtime_lane_counts[lane] = runtime_lane_counts.get(lane, 0) + 1
        rows.append(
            {
                "task": f"T20-{int(item['rank']):03d}",
                "done": runtime_verified,
                "rank": item["rank"],
                "id": item["id"],
                "lane": lane,
                "tier": item["tier"],
                "smokeStatus": item["smokeStatus"],
                "artifact": item["artifact"],
                "evidenceDetail": item["evidenceDetail"],
                "owningGap": item["owningGap"],
                "nextGap": item["nextGap"],
                "acceptance": top20_runtime_acceptance(item),
            }
        )
    runtime_count = sum(1 for row in rows if row["done"])
    return {
        "schema": "wizp.openvsx-top20-runtime-coverage.v1",
        "generatedAt": dashboard["generatedAt"],
        "sourceDashboard": str(DASHBOARD_JSON.relative_to(REPO_ROOT)),
        "sourceReport": dashboard["sourceReport"],
        "knownExtensions": dashboard["knownExtensions"],
        "total": len(rows),
        "runtimeEvidence": runtime_count,
        "remainingRuntimeEvidence": len(rows) - runtime_count,
        "laneCounts": dict(sorted(lane_counts.items())),
        "runtimeEvidenceByLane": dict(sorted(runtime_lane_counts.items())),
        "extensions": rows,
    }


def write_top20_runtime_coverage(coverage: dict[str, Any]) -> None:
    TOP20_RUNTIME_JSON.parent.mkdir(parents=True, exist_ok=True)
    TOP20_RUNTIME_JSON.write_text(json.dumps(coverage, indent=2) + "\n", encoding="utf-8")
    runtime_count = coverage["runtimeEvidence"]
    total = coverage["total"]
    remaining = coverage["remainingRuntimeEvidence"]
    lines = [
        "# Top 20 OpenVSX Runtime Coverage",
        "",
        "This file is generated by `npm run report:openvsx-top`. It tracks the stricter runtime/degraded evidence needed before WIZP can claim top-20 OpenVSX compatibility beyond loadability and contributed command discovery.",
        "",
        f"- Generated: `{coverage['generatedAt']}`",
        f"- Source dashboard: `{coverage['sourceDashboard']}`",
        f"- Runtime/degraded evidence: `{runtime_count}/{total}`",
        f"- Remaining runtime evidence tasks: `{remaining}`",
        "",
        "The earlier `CDR-002` and `CDR-011` gates cover top-20 package loadability and command surface. This tracker only marks ✅ when an extension has runtime or honest degraded-mode evidence in the latest joined dashboard.",
        "",
        "## Lane Snapshot",
        "",
        "| Lane | Top-20 count | Runtime evidence |",
        "|---|---:|---:|",
    ]
    for lane, count in coverage["laneCounts"].items():
        lines.append(f"| {lane} | {count} | {coverage['runtimeEvidenceByLane'].get(lane, 0)} |")
    lines.extend(
        [
            "",
            "## Runtime Tasks",
            "",
            "| Task | Rank | Extension | Lane | Status | Smoke | Acceptance |",
            "|---|---:|---|---|---|---|---|",
        ]
    )
    for item in coverage["extensions"]:
        marker = "✅" if item["done"] else "⬜"
        smoke = item["smokeStatus"]
        if item["artifact"]:
            smoke = f"{smoke}<br>`{item['artifact']}`"
        lines.append(
            f"| {marker} {item['task']} | {item['rank']} | {item['id']} | {item['lane']} | {'runtime/degraded evidence' if item['done'] else 'needs runtime evidence'} | {smoke} | {item['acceptance']} |"
        )
    TOP20_RUNTIME_MD.parent.mkdir(parents=True, exist_ok=True)
    TOP20_RUNTIME_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_dashboard(dashboard: dict[str, Any]) -> None:
    DASHBOARD_JSON.parent.mkdir(parents=True, exist_ok=True)
    DASHBOARD_JSON.write_text(json.dumps(dashboard, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# OpenVSX Compatibility Dashboard",
        "",
        "This file is generated by `npm run report:openvsx-top`. It joins the current OpenVSX top-100 intake with the known-extension ledger and the latest real-extension smoke artifact.",
        "",
        f"- Generated: `{dashboard['generatedAt']}`",
        f"- Source report: `{dashboard['sourceReport']}`",
        f"- Known ledger: `{dashboard['knownExtensions']}`",
        "",
        "## Summary",
        "",
        "| Tier | Count |",
        "|---|---:|",
    ]
    for tier, count in dashboard["tierCounts"].items():
        lines.append(f"| {tier} | {count} |")
    lines.extend(["", "| Smoke status | Count |", "|---|---:|"])
    for status, count in dashboard["evidenceCounts"].items():
        lines.append(f"| {status} | {count} |")
    if "top20RuntimeCoverage" in dashboard:
        top20 = dashboard["top20RuntimeCoverage"]
        lines.extend(
            [
                "",
                "## Top 20 Runtime Coverage",
                "",
                f"- Runtime/degraded evidence: `{top20['runtimeEvidence']}/{top20['total']}`",
                f"- Remaining runtime evidence tasks: `{top20['remainingRuntimeEvidence']}`",
                "- Tracker: [`TOP20_RUNTIME_COVERAGE.md`](TOP20_RUNTIME_COVERAGE.md)",
            ]
        )
    lines.extend(
        [
            "",
            "## Top 100 Join",
            "",
            "| Rank | Extension | Lane | Tier | Smoke | Owning gap | Next gap |",
            "|---:|---|---|---|---|---|---|",
        ]
    )
    for item in dashboard["extensions"]:
        smoke = item["smokeStatus"]
        if item["artifact"]:
            smoke = f"{smoke}<br>`{item['artifact']}`"
        lines.append(
            f"| {item['rank']} | {item['id']} | {item['lane']} | {item['tier']} | {smoke} | {item['owningGap']} | {item['nextGap']} |"
        )
    DASHBOARD_MD.parent.mkdir(parents=True, exist_ok=True)
    DASHBOARD_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_markdown(report: dict[str, Any]) -> None:
    lines = [
        "# Top OpenVSX Extension Compatibility Plan",
        "",
        "This file is generated by `npm run report:openvsx-top`. It tracks the current download-sorted OpenVSX top extensions as a planning input for making WIZP a credible VSCodium-style replacement.",
        "",
        f"- Generated: `{report['generatedAt']}`",
        f"- Source: `{report['source']}`",
        f"- Count: `{report['size']}`",
        "",
        "Important: this is not a compatibility claim. Rows describe likely runtime needs from OpenVSX metadata and extension manifests; each extension still needs install, activation, and runtime smoke evidence before promotion in `KNOWN_EXTENSIONS.md`.",
        "",
        "## Summary",
        "",
        "| Lane | Count |",
        "|---|---:|",
    ]
    for lane, count in report["laneCounts"].items():
        lines.append(f"| {lane} | {count} |")
    lines.extend(["", "| Risk | Count |", "|---|---:|"])
    for risk, count in report["riskCounts"].items():
        lines.append(f"| {risk} | {count} |")
    lines.extend(["", "## Most Common Runtime Needs", "", "| Need | Count |", "|---|---:|"])
    for need, count in list(report["needCounts"].items())[:20]:
        lines.append(f"| {need} | {count} |")
    lines.extend(
        [
            "",
            "## Coverage Milestones",
            "",
            "| Milestone | Target | Acceptance | Evidence/status |",
            "|---|---|---|---|",
            "| CDR-001 | Top 100 intake | Refresh this report and keep the generated JSON artifact. | `npm run report:openvsx-top` writes JSON and Markdown. |",
            "| CDR-002 | Top 20 loadability | Download/install top 20 OpenVSX VSIX packages, verify manifests/main files, and assert zero startup activation crashes. | ✅ Current real-extension report records 20/20 top extensions loadable with no relevant startup activation errors. |",
            "| CDR-003 | Theme/icon fast lane | Verify top theme/icon extensions expose theme/icon/product-icon contributions without JS runtime activation where possible. | ✅ Current real-extension report verifies 5/5 selected top theme/icon candidates, 5/5 theme contributions, 2/2 icon theme contributions, zero missing contribution paths, no product-icon gaps, and no relevant startup activation errors. |",
            "| CDR-004 | Language/tooling lane | Cover language-client process launch, workspace/config/env, diagnostics, formatting, and external tool discovery for top language/tooling extensions. | Pyright and YAML language-server runtimes are verified with real `ms-pyright.pyright` and `redhat.vscode-yaml` activation plus bundled `dist/server.js`/`dist/languageserver.js` IPC fork evidence; Tailwind CSS IntelliSense is verified with real `bradlc.vscode-tailwindcss` startup activation, bundled `dist/tailwindServer.js` fork evidence, completion/color/code-action/diagnostic provider registration, selector matching for absolute workspace globs, VS Code `SnippetString` compatibility, and a real 11k+ Tailwind completion payload from the bundled server; Pyrefly is verified as an honest platform-mismatch path by probing the bundled `meta.pyrefly` `bin/pyrefly` ELF (`aarch64` on this `x86_64` host), capturing the activation/output failure, and keeping the host responsive; clangd missing-binary degraded UX is verified with real `llvm-vs-code-extensions.vscode-clangd` activation, no spawned clangd process, and missing-path stderr/user-facing evidence; Rust Analyzer missing-binary degraded UX is verified with real `rust-lang.rust-analyzer` activation against a Cargo workspace, seeded `rust-analyzer.server.path`, no spawned server process, captured output/error UI, and a responsive host; Go missing-tool degraded UX is verified with real `golang.Go`, all contributed commands registered, seeded missing `go`/`gopls` tool paths, no spawned Go/gopls process, and captured install/download UX; Ruby LSP missing-runtime degraded UX is verified with real `Shopify.ruby-lsp`, all contributed commands registered, seeded missing Ruby path, no spawned Ruby process, captured Ruby LSP output/activation-error evidence, and a responsive host after unhandled rejection capture; Vue Volar is bounded with real `Vue.volar` activation, generic `onLanguage` support, Vue config defaults, built-in TypeScript extension metadata, captured TypeScript-extension restart UX, no activation errors, and no spawned server process; Dart-Code missing-SDK degraded UX is verified with real `Dart-Code.dart-code` activation against a `pubspec.yaml` workspace, all contributed commands registered, Dart config resolving seeded missing Dart/Flutter SDK paths, debug tracker registration, `dart.restartAnalysisServer`/`flutter.doctor` command execution, a real missing Flutter SDK user-facing message, zero activation errors, no spawned Dart/Flutter process, and headless `showOpenDialog` cancellation evidence; Dart-Code valid-SDK analysis-server startup is verified with the real OpenVSX package plus local Dart/Flutter SDK discovery, native `/bin/dart language-server --protocol=lsp` process evidence, diagnostic and completion provider registration, repeated provider probes staying bounded to one Dart LSP plus one tooling-daemon process, SDK log evidence for Dart/Flutter versions, and zero Dart activation errors; Red Hat Java missing-JDK degraded UX and valid-JDK host-timeout recovery are verified with real `redhat.java`: all 40 contributed commands register, seeded `java.jdt.ls.java.home` plus `java.transport: stdio` resolve, package JSON parsing and stream listener gaps stay fixed, external startup fetches are blocked, WIZP records `JavaRuntimeUnavailable` for the missing configured JDK path before entering the long JDT startup promise, surfaces an Open Settings error message, keeps follow-up debug/runtime RPCs responsive, and starts no Java/JDT process; the valid-JDK smoke detects a local JDK, exercises the real long JDT activation path with a 6000ms host deadline, records `ActivationHostTimeout`, restarts the JS extension host, keeps follow-up runtime/debug/provider RPCs responsive, and leaves no Java/JDT process behind. Still open for full Java/JDT language behavior, deeper Dart semantic diagnostics/completion/formatting payloads, richer config/env, and no-default-network smokes. |",
            "| CDR-005 | Formatter/linter lane | Prioritize Prettier, ESLint, Ruff-style save/format/diagnostic flows. | Partial: real `esbenp.prettier-vscode` document/range formatting plus format-on-save are verified; real `dbaeumer.vscode-eslint` startup/config precedence remains verified; and `bmewburn.vscode-intelephense-client` verifies bundled PHP diagnostics publication plus cleanup after the file is fixed. `charliermarsh.ruff` still needs hardening: the bundled runtime now records applied formatting text and platform probing, but the stronger process/provider acceptance path and configured external `ruff.path` discovery are still failing in the latest smoke. |",
            "| CDR-006 | Debug/test/notebook lane | Cover debugpy, Java debug/test, Go/Dart debug surfaces, Jupyter, notebooks, and test explorers. | Contribution baseline is verified, including debug visualizer metadata; still open for debug adapter, launch schema, test discovery/run, notebook renderer/controller, and webview runtime smokes. |",
            "| CDR-007 | SCM/cloud lane | Validate GitLab/GitLens/GitHub/Docker/Kubernetes-style webviews, SCM providers, auth, and terminal/process behavior. | Contribution baseline is verified, including custom editor/icon/MCP-provider metadata; still open for SCM provider, webview/tree, auth/session, terminal/process, offline degraded UX, and opt-in network runtime smokes. |",
            "| CDR-008 | AI/agent lane | Cover Claude Code, Codex/OpenAI/ChatGPT, Continue, Cline/Roo/Kilo/Gemini-style extensions under strict opt-in network policy. | Contribution baseline is verified, including chat participant, chat session, and language-model-tool metadata. `openai.chatgpt` has a dedicated runtime smoke: WIZP installs and activates the current OpenVSX package, exposes its official commands/settings/chat session, configures the official `chatgpt.cliExecutable` setting to the installed Codex CLI, verifies a real `codex app-server --analytics-default-enabled` initialize handshake, observes the extension spawn that real app-server, registers/focuses both contributed Codex webview views, executes the side-effect-light UI commands plus `chatgpt.addToThread` and `chatgpt.addFileToThread` against a selected TODO file, and records zero external network attempts. The extension-host smoke also verifies unsupported language-model API fallback behavior, public blocked-call/network-audit redaction for secret-bearing URLs, and host-level allowlist-is-not-consent behavior: allowlisted external calls still block unless `WIZP_EXTENSION_NETWORK_CONSENT` is present and audit entries record allowlist/consent/passthrough state. Still open for authenticated model-turn behavior and deeper product-specific auth/session/consent UX across the rest of the lane. |",
            "| CDR-009 | Extension packs/dependencies | Resolve extension packs and dependency activation ordering for top packs such as Python, Java, PHP, Jupyter, CMake, database, and language-pack style roots. | ✅ Current extension-pack smoke resolves all 7 top-100 pack roots into 25 package IDs, verifies/installs 23 OpenVSX-available packages, records 21 pack/dependency edges, and tracks `ms-python.vscode-pylance` plus `ms-vscode.cpp-devtools` as explicit OpenVSX 404 unsupported children. |",
            "| CDR-010 | Compatibility dashboard | Join top-100 OpenVSX rank, `KNOWN_EXTENSIONS.md` tier, real smoke result, and owning gap. | ✅ `docs/vscode-parity/OPENVSX_COMPATIBILITY_DASHBOARD.md` and `build/vscode-parity/openvsx-compatibility-dashboard.json` record rank, tier, latest smoke artifact/status, owning gap, and next gap. |",
            "| CDR-011 | Top 20 command surface | Expand contributed command discovery for the OpenVSX top 20 after loadability. | ✅ Current real-extension report records 1,597 expected contributed commands and 1,602 discovered commands including built-ins, with no missing top-20 commands. |",
            "| CDR-012 | Top 20 runtime coverage | Maintain artifact-backed runtime or honest degraded-mode evidence for each current top-20 OpenVSX extension. | Tracked by `docs/vscode-parity/TOP20_RUNTIME_COVERAGE.md` and `build/vscode-parity/openvsx-top20-runtime-coverage.json`; only rows with runtime/degraded evidence get ✅. |",
            "",
            "## Top Extensions",
            "",
            "| Rank | Extension | Downloads | Lane | Risk | Main needs |",
            "|---:|---|---:|---|---|---|",
        ]
    )
    for item in report["extensions"]:
        needs = "<br>".join(item["needs"][:4])
        lines.append(
            f"| {item['rank']} | [{item['id']}]({item['url']}) | {compact_int(item['downloadCount'])} | {item['lane']} | {item['risk']} | {needs} |"
        )
    REPORT_MD.parent.mkdir(parents=True, exist_ok=True)
    REPORT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=100, help="number of top OpenVSX extensions to fetch")
    args = parser.parse_args()
    if args.size < 1 or args.size > 200:
        raise SystemExit("--size must be between 1 and 200")
    report = build_report(args.size)
    REPORT_JSON.parent.mkdir(parents=True, exist_ok=True)
    REPORT_JSON.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    write_markdown(report)
    dashboard = build_dashboard(report)
    dashboard["top20RuntimeCoverage"] = build_top20_runtime_coverage(dashboard)
    write_dashboard(dashboard)
    write_top20_runtime_coverage(dashboard["top20RuntimeCoverage"])
    print(f"openvsx top extension report: {REPORT_JSON}")
    print(f"openvsx top extension plan: {REPORT_MD}")
    print(f"openvsx compatibility dashboard: {DASHBOARD_MD}")
    print(f"openvsx top-20 runtime coverage: {TOP20_RUNTIME_MD}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
