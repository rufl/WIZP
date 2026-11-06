"""Small, side-effect-free utilities shared by the top-20 parity runner.

Keeping artifact IO, hashing, and path validation here gives the large runner
one tested public boundary without changing its report semantics.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PROJECT_ROOT.parent
SCENARIO_DIR = PROJECT_ROOT / "testdata" / "top20-scenarios"
FIXTURE_ROOT = SCENARIO_DIR / "fixtures"


def now_iso() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise AssertionError(f"missing required artifact: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text_if_missing(path: Path, content: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_directory(path: Path) -> str:
    digest = hashlib.sha256()
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        rel_path = child.relative_to(path).as_posix()
        digest.update(rel_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(child).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def file_count(path: Path) -> int:
    return sum(1 for item in path.rglob("*") if item.is_file())


def rel(path: Path, repo_root: Path = REPO_ROOT) -> str:
    return str(path.relative_to(repo_root))


def scenario_filename(extension_id: str) -> str:
    return extension_id.replace("/", "-") + ".json"


def safe_fixture_dir(
    fixture: str,
    scenario_dir: Path = SCENARIO_DIR,
    fixture_root: Path = FIXTURE_ROOT,
) -> Path:
    if fixture.startswith("/") or ".." in Path(fixture).parts:
        raise AssertionError(f"unsafe fixture path: {fixture}")
    path = (scenario_dir / fixture).resolve()
    root = fixture_root.resolve()
    if path != root and root not in path.parents:
        raise AssertionError(f"fixture must live below {root}: {fixture}")
    return path
