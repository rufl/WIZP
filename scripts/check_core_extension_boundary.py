#!/usr/bin/env python3
"""Guard the core/extension ownership boundary in the extension host.

This intentionally fails fast if core starts hardcoding extension-contributed
configuration defaults, adds new extension-ID-specific getExtension/dependency
branches, or grows new extension-targeted compatibility/policy exceptions
without an explicit review.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "src" / "hub" / "ExtensionHost.zig"
POLICY = ROOT / "src" / "hub" / "ExtensionPolicy.zig"
REGISTER = ROOT / "docs" / "EXTENSION_COMPATIBILITY_EXCEPTIONS.md"

DEFAULT_FOR_START = r"\      function defaultFor(key) {"
DEFAULT_FOR_END = r"\      function cloneValue(value) {"
GET_EXTENSION_START = r"\    getExtension: function(id) {"
GET_EXTENSION_END = r"\    onDidChange: function(callback) { return { dispose: function() {} }; }"
DEPENDENCY_START = "fn isShimmedExtensionDependency"
DEPENDENCY_END = "fn activationTimeoutMs"
BACKGROUND_ACTIVATION_START = "fn allowBackgroundActivationFor"
BACKGROUND_ACTIVATION_END = "fn activationTimeoutMs"
BLOCKED_FETCH_START = r"\\globalThis._wizpBlockedFetchResponse = function(url) {"
BLOCKED_FETCH_END = r"\\globalThis.fetch = function(input, init) {"

ALLOWED_CORE_DEFAULT_KEYS = {
    "files.exclude",
    "files.eol",
    "files.encoding",
    "files.trimTrailingWhitespace",
    "files.insertFinalNewline",
    "editor.detectIndentation",
    "editor.tabSize",
    "editor.indentSize",
    "editor.insertSpaces",
    "git",
    "git.enabled",
    "git.path",
    "git.env",
    "git.autoRepositoryDetection",
    "git.scanRepositories",
    "git.ignoredRepositories",
    "git.confirmSync",
    "git.useCommitInputAsStashMessage",
    "git.autofetch",
    "git.terminalAuthentication",
}

ALLOWED_GET_EXTENSION_BRANCH_IDS = {
    "ms-python.python",
    "vscode.typescript-language-features",
    "vscode.git",
    "vscode.docker",
    "vscode.yaml",
}

ALLOWED_DEPENDENCY_SHIMS = {
    "ms-python.python",
    "vscode.typescript-language-features",
    "vscode.git",
    "vscode.docker",
    "vscode.yaml",
}

ALLOWED_BACKGROUND_ACTIVATION_IDS = {
    "redhat.java",
}

ALLOWED_PREFLIGHT_FUNCTIONS = {
    "preflightJavaRuntimeUnavailable",
}

ALLOWED_BLOCKED_FETCH_CASES = {
    "isGitKrakenConfig",
}


def required_register_entries() -> set[str]:
    """Return every named exception that must remain documented."""
    return (
        ALLOWED_GET_EXTENSION_BRANCH_IDS
        | ALLOWED_DEPENDENCY_SHIMS
        | ALLOWED_BACKGROUND_ACTIVATION_IDS
        | {"GitKraken"}
    )


def extract_segment(text: str, start_marker: str, end_marker: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise AssertionError(f"missing start marker: {start_marker!r}")
    end = text.find(end_marker, start)
    if end < 0:
        raise AssertionError(f"missing end marker: {end_marker!r}")
    return text[start:end]


def unexpected_blocked_fetch_cases(segment: str) -> list[str]:
    """Return blocked-fetch policy names not present in the explicit register."""
    blocked_fetch_cases = set(re.findall(r"const (is[A-Za-z0-9_]+) = /", segment))
    return sorted(blocked_fetch_cases - ALLOWED_BLOCKED_FETCH_CASES)


def unexpected_get_extension_branch_ids(segment: str) -> list[str]:
    """Return extension-qualified getExtension branches outside the register."""
    branch_ids = set(re.findall(r"id === '([^']+)'", segment))
    return sorted(identifier for identifier in branch_ids if "." in identifier and identifier not in ALLOWED_GET_EXTENSION_BRANCH_IDS)


def unexpected_core_default_keys(segment: str) -> list[str]:
    """Return defaultFor keys outside the core-owned register."""
    default_keys = set(re.findall(r"if \(full === '([^']+)'\) return", segment))
    return sorted(default_keys - ALLOWED_CORE_DEFAULT_KEYS)


def has_legacy_gitlens_defaults(segment: str) -> bool:
    """Detect the removed GitLens-specific default payload marker."""
    return "gitLensDefaults" in segment


def main() -> int:
    text = TARGET.read_text()
    register = REGISTER.read_text()
    errors: list[str] = []

    default_segment = extract_segment(text, DEFAULT_FOR_START, DEFAULT_FOR_END)
    unexpected_default_keys = unexpected_core_default_keys(default_segment)
    if unexpected_default_keys:
        errors.append(
            "core defaultFor() contains extension-owned or unexpected keys:\n- "
            + "\n- ".join(unexpected_default_keys)
        )
    if has_legacy_gitlens_defaults(default_segment):
        errors.append("core defaultFor() still contains GitLens-specific fallback data")

    get_extension_segment = extract_segment(text, GET_EXTENSION_START, GET_EXTENSION_END)
    unexpected_branch_ids = unexpected_get_extension_branch_ids(get_extension_segment)
    if unexpected_branch_ids:
        errors.append(
            "getExtension() added non-allowlisted extension-ID branches:\n- "
            + "\n- ".join(unexpected_branch_ids)
        )

    if DEPENDENCY_START in text:
        dependency_segment = extract_segment(text, DEPENDENCY_START, DEPENDENCY_END)
    else:
        policy_text = POLICY.read_text()
        dependency_segment = extract_segment(policy_text, "pub fn isShimmedExtensionDependency", "pub fn allowBackgroundActivation")
    dependency_ids = set(re.findall(r'dependency_id, "([^"]+)"', dependency_segment))
    unexpected_dependency_ids = sorted(dependency_ids - ALLOWED_DEPENDENCY_SHIMS)
    if unexpected_dependency_ids:
        errors.append(
            "isShimmedExtensionDependency() added non-allowlisted shims:\n- "
            + "\n- ".join(unexpected_dependency_ids)
        )

    preflight_functions = set(re.findall(r"\bfn (preflight[A-Za-z0-9_]+)\(", text))
    unexpected_preflight_functions = sorted(preflight_functions - ALLOWED_PREFLIGHT_FUNCTIONS)
    if unexpected_preflight_functions:
        errors.append(
            "core added non-allowlisted preflight extension hooks:\n- "
            + "\n- ".join(unexpected_preflight_functions)
        )

    if BACKGROUND_ACTIVATION_START in text:
        background_segment = extract_segment(text, BACKGROUND_ACTIVATION_START, BACKGROUND_ACTIVATION_END)
        background_matches = {
            f"{publisher}.{ext_id}"
            for publisher, ext_id in re.findall(
                r'ext\.publisher, "([^"]+)"\)\s+and std\.mem\.eql\(u8, ext\.id, "([^"]+)"',
                background_segment,
                flags=re.S,
            )
        }
    else:
        policy_text = POLICY.read_text()
        background_matches = {"redhat.java"} if 'publisher, "redhat"' in policy_text and 'id, "java"' in policy_text else set()
    unexpected_background_ids = sorted(background_matches - ALLOWED_BACKGROUND_ACTIVATION_IDS)
    if unexpected_background_ids:
        errors.append(
            "allowBackgroundActivationFor() added non-allowlisted hardcoded extension matches:\n- "
            + "\n- ".join(unexpected_background_ids)
        )

    blocked_fetch_segment = extract_segment(text, BLOCKED_FETCH_START, BLOCKED_FETCH_END)
    unexpected_blocked_fetch = unexpected_blocked_fetch_cases(blocked_fetch_segment)
    if unexpected_blocked_fetch:
        errors.append(
            "_wizpBlockedFetchResponse() added non-allowlisted extension-specific policy cases:\n- "
            + "\n- ".join(unexpected_blocked_fetch)
        )

    missing_register_entries = sorted(entry for entry in required_register_entries() if entry not in register)
    if missing_register_entries:
        errors.append(
            "extension compatibility register is missing allowlisted exception evidence:\n- "
            + "\n- ".join(missing_register_entries)
        )

    if errors:
        print("core extension boundary check failed:", file=sys.stderr)
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("core extension boundary ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
