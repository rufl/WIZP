#!/usr/bin/env python3
"""Check that declared npm dependencies resolve to the committed npm lockfiles."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECTS = (ROOT, ROOT / "frontend")
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")


def version_tuple(value: str) -> tuple[int, int, int] | None:
    match = VERSION.match(value)
    return tuple(int(part) for part in match.groups()) if match else None


def satisfies(spec: str, version: str) -> bool:
    expected = version_tuple(spec.lstrip("^~="))
    actual = version_tuple(version)
    if expected is None or actual is None:
        return spec == version
    if spec.startswith("^"):
        return actual >= expected and actual[0] == expected[0]
    if spec.startswith("~"):
        return actual >= expected and actual[:2] == expected[:2]
    return actual == expected


def check_project(project: Path) -> list[str]:
    manifest_path = project / "package.json"
    lock_path = project / "package-lock.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    root = lock.get("packages", {}).get("", {})
    errors: list[str] = []
    declared = {
        **manifest.get("dependencies", {}),
        **manifest.get("devDependencies", {}),
        **manifest.get("optionalDependencies", {}),
    }
    locked_root = {
        **root.get("dependencies", {}),
        **root.get("devDependencies", {}),
        **root.get("optionalDependencies", {}),
    }
    for name, spec in sorted(declared.items()):
        if name not in locked_root:
            errors.append(f"{project.relative_to(ROOT)}: {name} is missing from the lockfile root")
            continue
        lock_spec = locked_root[name]
        if lock_spec != spec:
            errors.append(f"{project.relative_to(ROOT)}: {name} manifest spec {spec!r} != lock spec {lock_spec!r}")
        package = lock.get("packages", {}).get(f"node_modules/{name}")
        if package is None:
            errors.append(f"{project.relative_to(ROOT)}: {name} has no node_modules lock entry")
        elif not satisfies(spec, package.get("version", "")):
            errors.append(f"{project.relative_to(ROOT)}: {name} spec {spec!r} does not admit locked version {package.get('version')!r}")
    return errors


def main() -> int:
    errors = [error for project in PROJECTS for error in check_project(project)]
    upstream = ROOT / "monaco-upstream" / "package.json"
    if upstream.exists():
        upstream_manifest = json.loads(upstream.read_text(encoding="utf-8"))
        upstream_version = upstream_manifest.get("dependencies", {}).get("monaco-editor")
        if upstream_version != "^0.52.2":
            errors.append(f"monaco-upstream: expected monaco-editor '^0.52.2', found {upstream_version!r}")
        for project in PROJECTS:
            manifest = json.loads((project / "package.json").read_text(encoding="utf-8"))
            for section in ("dependencies", "devDependencies", "optionalDependencies"):
                if "monaco-editor" in manifest.get(section, {}):
                    errors.append(f"{project.relative_to(ROOT)}: unused monaco-editor declaration; monaco-upstream owns the runtime")
    if errors:
        print("dependency consistency failed:", file=sys.stderr)
        print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print("dependency consistency ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
