#!/usr/bin/env python3
"""Focused fixtures for the explicit core/extension boundary exceptions."""

try:
    from check_core_extension_boundary import (
        required_register_entries,
        unexpected_blocked_fetch_cases,
        unexpected_core_default_keys,
        unexpected_get_extension_branch_ids,
        has_legacy_gitlens_defaults,
    )
except ModuleNotFoundError:
    from scripts.check_core_extension_boundary import (
        required_register_entries,
        unexpected_blocked_fetch_cases,
        unexpected_core_default_keys,
        unexpected_get_extension_branch_ids,
        has_legacy_gitlens_defaults,
    )


def test_every_executable_exception_allowlist_requires_register_evidence() -> None:
    entries = required_register_entries()
    assert {"redhat.java", "ms-python.python", "vscode.git", "vscode.docker", "vscode.yaml", "vscode.typescript-language-features", "GitKraken"} <= entries


def test_registered_blocked_fetch_exception_is_accepted() -> None:
    fixture = r"const isGitKrakenConfig = /gitkraken/;"
    assert unexpected_blocked_fetch_cases(fixture) == []


def test_unregistered_blocked_fetch_exception_is_rejected() -> None:
    fixture = r"const isUnreviewedExtensionConfig = /example/;"
    assert unexpected_blocked_fetch_cases(fixture) == ["isUnreviewedExtensionConfig"]


def test_registered_get_extension_branches_are_accepted() -> None:
    fixture = " || ".join(f"id === '{identifier}'" for identifier in (
        "ms-python.python",
        "vscode.typescript-language-features",
        "vscode.git",
        "vscode.docker",
        "vscode.yaml",
    ))
    assert unexpected_get_extension_branch_ids(fixture) == []


def test_unregistered_get_extension_branch_is_rejected() -> None:
    fixture = "id === 'publisher.unreviewed-extension'"
    assert unexpected_get_extension_branch_ids(fixture) == ["publisher.unreviewed-extension"]


def test_registered_core_defaults_are_accepted() -> None:
    fixture = " ".join("if (full === '{}' ) return {{}};".format(key) for key in (
        "files.exclude",
        "editor.tabSize",
        "git.enabled",
    )).replace("' )", "')")
    assert unexpected_core_default_keys(fixture) == []


def test_extension_owned_default_is_rejected() -> None:
    fixture = "if (full === 'gitLens.codeLens.enabled') return {};"
    assert unexpected_core_default_keys(fixture) == ["gitLens.codeLens.enabled"]


def test_removed_gitlens_default_marker_is_absent() -> None:
    assert not has_legacy_gitlens_defaults("if (full === 'editor.tabSize') return {}; ")


def test_reintroduced_gitlens_default_marker_is_detected() -> None:
    assert has_legacy_gitlens_defaults("const gitLensDefaults = {}; ")


if __name__ == "__main__":
    test_registered_blocked_fetch_exception_is_accepted()
    test_unregistered_blocked_fetch_exception_is_rejected()
    test_registered_get_extension_branches_are_accepted()
    test_unregistered_get_extension_branch_is_rejected()
    test_registered_core_defaults_are_accepted()
    test_extension_owned_default_is_rejected()
    test_removed_gitlens_default_marker_is_absent()
    test_reintroduced_gitlens_default_marker_is_detected()
    print("core extension boundary fixtures ok")
