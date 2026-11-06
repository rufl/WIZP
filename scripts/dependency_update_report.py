#!/usr/bin/env python3
"""Write a reviewable dependency/update inventory without changing dependencies."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def npm_inventory(path: Path, check_registry: bool) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    lock_path = path.with_name("package-lock.json")
    lock = json.loads(lock_path.read_text(encoding="utf-8")) if lock_path.exists() else {}
    direct = {**manifest.get("dependencies", {}), **manifest.get("devDependencies", {})}
    lock_root = lock.get("packages", {}).get("", {})
    locked = {**lock_root.get("dependencies", {}), **lock_root.get("devDependencies", {})}
    missing_from_lock = sorted(set(direct) - set(locked))
    result = {
        "manifest": str(path.relative_to(ROOT)),
        "direct": sorted(direct),
        "lockedDirect": sorted(locked),
        "status": "accepted-lockfile-pinned" if lock_path.exists() and not missing_from_lock else "lockfile-mismatch",
        "missingFromLock": missing_from_lock,
    }
    if check_registry:
        proc = subprocess.run(
            ["npm", "outdated", "--json", "--long"],
            cwd=path.parent,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        try:
            result["outdated"] = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError:
            result["outdatedOutput"] = proc.stdout.strip()
        result["registryStatus"] = "checked" if proc.returncode in (0, 1) else "deferred-registry-error"
    else:
        result["registryStatus"] = "deferred-no-network-check"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network", action="store_true", help="query npm registry via npm outdated")
    parser.add_argument("--report", type=Path, default=ROOT / "build" / "parity-package" / "dependency-update-report.json")
    args = parser.parse_args()

    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "policy": "report-only; upgrades require a reviewed lockfile change",
        "npm": [npm_inventory(ROOT / "package.json", args.network), npm_inventory(ROOT / "frontend" / "package.json", args.network)],
        "zig": {
            "manifest": "build.zig.zon",
            "pinned": "zigpty@54392f8fe9c9028f0f6388513a55323d9da21f2c",
            "status": "defer-pinned-revision-review",
        },
        "electrobun": {"version": json.loads((ROOT / "package.json").read_text(encoding="utf-8"))["dependencies"].get("electrobun"), "status": "accepted-lockfile-pinned"},
        "vendored": {
            "paths": ["lib/quickjs", "lib/tree-sitter", "monaco-upstream"],
            "status": "defer-manual-vendor-review",
        },
    }
    lockfile_mismatches = [
        item
        for item in report["npm"]
        if item["status"] == "lockfile-mismatch"
    ]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"dependency update report: {args.report}")
    if lockfile_mismatches:
        print("dependency update report failed: direct dependencies are missing from a package lockfile", file=sys.stderr)
        for item in lockfile_mismatches:
            print(f"- {item['manifest']}: {', '.join(item['missingFromLock'])}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
