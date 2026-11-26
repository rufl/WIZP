#!/usr/bin/env python3
"""Compare WIZP's bundled CEF payload with a candidate shared runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload(root: Path) -> dict[str, dict[str, int | str]]:
    result: dict[str, dict[str, int | str]] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            result[relative] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    return result


def compare(wizp_package: Path, eurooffice_root: Path) -> dict[str, object]:
    wizp_cef = wizp_package / "bin" / "cef"
    if not wizp_cef.is_dir():
        raise ValueError(f"WIZP CEF directory not found: {wizp_cef}")
    if not (wizp_cef / "libcef.so").is_file():
        raise ValueError(f"WIZP libcef.so not found: {wizp_cef / 'libcef.so'}")
    if not eurooffice_root.is_dir():
        raise ValueError(f"EuroOffice runtime directory not found: {eurooffice_root}")
    if not (eurooffice_root / "libcef.so").is_file():
        raise ValueError(f"EuroOffice libcef.so not found: {eurooffice_root / 'libcef.so'}")

    wizp_files = payload(wizp_cef)
    eurooffice_files = payload(eurooffice_root)
    differences = []
    for relative, wizp_entry in wizp_files.items():
        eurooffice_entry = eurooffice_files.get(relative)
        if eurooffice_entry is None:
            differences.append({"path": relative, "status": "missing-from-eurooffice", "wizp": wizp_entry})
        elif wizp_entry["sha256"] != eurooffice_entry["sha256"]:
            differences.append(
                {
                    "path": relative,
                    "status": "content-mismatch",
                    "wizp": wizp_entry,
                    "eurooffice": eurooffice_entry,
                }
            )
    return {
        "payload_identical": not differences,
        "wizp_cef_root": str(wizp_cef),
        "eurooffice_root": str(eurooffice_root),
        "wizp_file_count": len(wizp_files),
        "eurooffice_file_count": len(eurooffice_files),
        "differences": differences,
        "scope": "Byte-equivalence only; does not validate ABI, loader paths, subprocess behavior, or external-runtime support.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wizp_package", type=Path, help="self-contained WIZP package root")
    parser.add_argument("eurooffice_root", type=Path, help="EuroOffice runtime root (for example /opt/eurooffice)")
    args = parser.parse_args()
    try:
        report = compare(args.wizp_package, args.eurooffice_root)
    except (OSError, ValueError) as error:
        print(f"CEF payload probe: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["payload_identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
