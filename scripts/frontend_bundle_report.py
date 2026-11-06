#!/usr/bin/env python3
"""Report reproducible frontend bundle sizes without claiming runtime performance."""

from __future__ import annotations

import json
import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "frontend" / "dist"
REPORT = ROOT / "build" / "parity-stress" / "frontend-bundle-report.json"
CHUNK_LIMIT = 500 * 1024
OVERSIZED_ASSET_BUDGET = 5


def asset_row(path: Path) -> dict[str, object]:
    return {"path": str(path.relative_to(DIST)), "bytes": path.stat().st_size}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fresh", action="store_true", help="mark dist as freshly built by the caller")
    parser.add_argument("--max-oversized-assets", type=int, default=OVERSIZED_ASSET_BUDGET)
    args = parser.parse_args()
    if not DIST.is_dir():
        print(f"missing frontend build: {DIST}; run npm run build:frontend first", file=sys.stderr)
        return 2
    files = [path for path in DIST.rglob("*") if path.is_file()]
    assets = sorted((asset_row(path) for path in files), key=lambda item: (-int(item["bytes"]), str(item["path"])))
    index = DIST / "index.html"
    html = index.read_text(encoding="utf-8") if index.exists() else ""
    initial_refs = sorted(set(re.findall(r'(?:src|href)=["\']([^"\']+)["\']', html)))
    initial_assets = [asset for asset in assets if asset["path"] in {ref.lstrip("/") for ref in initial_refs}]
    report = {
        "schema": 1,
        "status": "bundle-size-measured-existing-dist",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "source": "frontend/dist",
        "fileCount": len(files),
        "totalBytes": sum(int(asset["bytes"]) for asset in assets),
        "initialHtmlReferences": initial_refs,
        "initialHtmlAssets": initial_assets,
        "initialHtmlBytes": sum(int(asset["bytes"]) for asset in initial_assets),
        "largestAssets": assets[:10],
        "chunkLimitBytes": CHUNK_LIMIT,
        "oversizedAssets": [asset for asset in assets if str(asset["path"]).endswith((".js", ".css")) and int(asset["bytes"]) > CHUNK_LIMIT],
        "oversizedAssetBudget": args.max_oversized_assets,
        "runtimeLatencyMeasured": False,
        "buildFreshness": "verified-by-caller" if args.fresh else "not-verified; run npm run build:frontend before publishing a release baseline",
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"frontend bundle report: {REPORT} ({report['totalBytes']} bytes)")
    oversized_count = len(report["oversizedAssets"])
    report["budgetStatus"] = "passed" if oversized_count <= args.max_oversized_assets else "failed"
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if oversized_count > args.max_oversized_assets:
        print(f"error: {oversized_count} JS/CSS assets exceed {CHUNK_LIMIT} bytes; budget is {args.max_oversized_assets}", file=sys.stderr)
        return 1
    if report["oversizedAssets"]:
        print(f"notice: {oversized_count} JS/CSS assets exceed {CHUNK_LIMIT} bytes; budget is {args.max_oversized_assets}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
