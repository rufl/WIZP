#!/usr/bin/env python3
"""Prune safe-to-remove Linux package payload and write a size report."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = PROJECT_ROOT / "build" / "parity-package" / "linux-package-prune.json"
DEFAULT_MAX_STRIP_BYTES = 512 * 1024 * 1024


def default_package_dir() -> Path:
    return PROJECT_ROOT / "build" / "dev-linux-x64" / "WIZP-dev"


def tree_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for item in path.rglob("*"):
        if item.is_symlink():
            continue
        if item.is_file():
            total += item.stat().st_size
    return total


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def parse_locales(value: str) -> set[str]:
    locales = {part.strip() for part in value.split(",") if part.strip()}
    return locales or {"en-US"}


def locale_stem(path: Path) -> str:
    stem = path.stem
    for suffix in ("_FEMININE", "_MASCULINE", "_NEUTER"):
        if stem.endswith(suffix):
            return stem[: -len(suffix)]
    return stem


def prune_locales(locale_dir: Path, keep: set[str]) -> dict:
    removed: dict[str, int] = {}
    kept: list[str] = []
    if not locale_dir.exists():
        return {"dir": str(locale_dir), "removed": removed, "kept": kept}
    for path in sorted(locale_dir.glob("*.pak")):
        if locale_stem(path) in keep:
            kept.append(path.name)
            continue
        size = path.stat().st_size
        path.unlink()
        removed[str(path)] = size
    return {"dir": str(locale_dir), "removed": removed, "kept": kept}


def strip_elfs(
    package_dir: Path,
    strip_bin: str,
    timeout_seconds: float,
    max_strip_bytes: int,
) -> dict:
    stripped: dict[str, dict] = {}
    skipped: dict[str, str] = {}
    roots = [package_dir / "bin", package_dir / "Resources" / "app"]
    for root in roots:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_symlink() or not path.is_file() or not is_elf(path):
                continue
            before = path.stat().st_size
            if before > max_strip_bytes:
                skipped[str(path)] = (
                    f"larger than strip limit: {before} > {max_strip_bytes} bytes"
                )
                continue
            temp_path: Path | None = None
            try:
                with tempfile.NamedTemporaryFile(
                    dir=path.parent,
                    prefix=f".{path.name}.",
                    delete=False,
                ) as temp_file:
                    temp_path = Path(temp_file.name)
                proc = subprocess.run(
                    [
                        strip_bin,
                        "--strip-unneeded",
                        "--output-file",
                        str(temp_path),
                        str(path),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    check=False,
                    timeout=timeout_seconds,
                )
                if proc.returncode == 0:
                    after = temp_path.stat().st_size
                    os.replace(temp_path, path)
                    temp_path = None
                    stripped[str(path)] = {
                        "before": before,
                        "after": after,
                        "saved": max(0, before - after),
                    }
                else:
                    skipped[str(path)] = proc.stdout.strip()
            except subprocess.TimeoutExpired:
                skipped[str(path)] = f"strip timed out after {timeout_seconds:.1f}s"
            finally:
                if temp_path is not None:
                    temp_path.unlink(missing_ok=True)
    return {"stripped": stripped, "skipped": skipped}


def top_files(package_dir: Path, limit: int) -> list[dict]:
    rows: list[dict] = []
    for path in package_dir.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        rows.append({"path": str(path), "bytes": path.stat().st_size})
    rows.sort(key=lambda row: int(row["bytes"]), reverse=True)
    return rows[:limit]


def prune(args: argparse.Namespace) -> dict:
    package_dir = args.package_dir
    if not package_dir.exists():
        raise SystemExit(f"package directory missing: {package_dir}")

    keep_locales = parse_locales(args.locales)
    before = tree_size(package_dir)
    locale_reports = [
        prune_locales(package_dir / "bin" / "locales", keep_locales),
        prune_locales(package_dir / "bin" / "cef" / "locales", keep_locales),
    ]
    strip_report = {"stripped": {}, "skipped": {}}
    if not args.skip_strip:
        strip_report = strip_elfs(
            package_dir,
            args.strip_bin,
            args.strip_timeout,
            args.max_strip_bytes,
        )
    after = tree_size(package_dir)
    locale_saved = sum(
        size
        for report in locale_reports
        for size in report["removed"].values()
    )
    strip_saved = sum(item["saved"] for item in strip_report["stripped"].values())

    payload = {
        "packageDir": str(package_dir),
        "keepLocales": sorted(keep_locales),
        "beforeBytes": before,
        "afterBytes": after,
        "savedBytes": max(0, before - after),
        "localeSavedBytes": locale_saved,
        "stripSavedBytes": strip_saved,
        "localeReports": locale_reports,
        "stripReport": strip_report,
        "topFilesAfter": top_files(package_dir, args.top),
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, default=default_package_dir())
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--locales", default=os.environ.get("WIZP_PACKAGE_LOCALES", "en-US"))
    parser.add_argument("--strip-bin", default=os.environ.get("STRIP", "strip"))
    parser.add_argument(
        "--strip-timeout",
        type=float,
        default=float(os.environ.get("WIZP_STRIP_TIMEOUT_SECONDS", "60")),
        help="maximum seconds to spend stripping one ELF before recording it as skipped",
    )
    parser.add_argument(
        "--max-strip-bytes",
        type=int,
        default=int(os.environ.get("WIZP_MAX_STRIP_BYTES", str(DEFAULT_MAX_STRIP_BYTES))),
        help="maximum ELF size to pass to strip; larger files are recorded as skipped",
    )
    parser.add_argument("--strip", dest="skip_strip", action="store_false")
    parser.add_argument("--skip-strip", dest="skip_strip", action="store_true")
    parser.set_defaults(skip_strip=True)
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()
    payload = prune(args)
    saved_mb = payload["savedBytes"] / (1024 * 1024)
    after_mb = payload["afterBytes"] / (1024 * 1024)
    print(f"pruned Linux package: saved {saved_mb:.1f} MiB, final {after_mb:.1f} MiB ({args.report})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
