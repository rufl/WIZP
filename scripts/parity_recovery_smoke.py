#!/usr/bin/env python3
"""Three-cycle daemon recovery smoke for preserved sessions and PTY cleanup."""

from __future__ import annotations

import json
import os
import resource
import subprocess
import tempfile
import time
from pathlib import Path

from parity_daemon_smoke import DEFAULT_BIN, RpcClient

ROOT = Path(__file__).resolve().parents[1]
CYCLES = 3
MAX_RSS_GROWTH_KB = 64 * 1024
MAX_CPU_MS = 15_000
REPORT_PATH = ROOT / "build" / "parity-recovery" / "recovery-report.json"


def descendants(root_pid: int) -> set[int]:
    found: set[int] = set()
    pending = [root_pid]
    while pending:
        pid = pending.pop()
        children_path = Path(f"/proc/{pid}/task/{pid}/children")
        try:
            children = [int(value) for value in children_path.read_text(encoding="utf-8").split()]
        except (FileNotFoundError, PermissionError, ValueError):
            continue
        for child in children:
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


def stop_gracefully(client: RpcClient) -> None:
    assert client.proc.stdin is not None
    client.proc.stdin.close()
    try:
        client.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        client.proc.kill()
        client.proc.wait(timeout=5)
        raise AssertionError("WIZP daemon did not stop after stdin EOF")


def wait_for_exit(pids: set[int]) -> set[int]:
    deadline = time.time() + 2
    remaining = {pid for pid in pids if Path(f"/proc/{pid}").exists()}
    while remaining and time.time() < deadline:
        time.sleep(0.05)
        remaining = {pid for pid in remaining if Path(f"/proc/{pid}").exists()}
    return remaining


def run_cycle(root: Path, home: Path, cycle: int) -> dict[str, object]:
    session_path = root / f"recovery-session-{cycle}.json"
    source_path = root / f"recovery-{cycle}.txt"
    source_path.write_text(f"recovery source {cycle}\n", encoding="utf-8")
    editor_session = {
        "layout": "vertical",
        "activeGroup": 0,
        "groups": [
            {
                "editors": [
                    {
                        "uri": f"file://{source_path}",
                        "languageId": "text",
                        "dirty": True,
                        "content": f"unsaved recovery {cycle}\n",
                    },
                    {
                        "uri": f"untitled-recovery-{cycle}",
                        "languageId": "text",
                        "dirty": True,
                        "content": f"untitled recovery {cycle}\n",
                    },
                ],
                "activeUri": f"untitled-recovery-{cycle}",
            }
        ],
    }
    client = RpcClient(root, env={"HOME": str(home), "USERPROFILE": str(home)})
    daemon_pid = client.proc.pid
    started = time.perf_counter()
    try:
        terminal = client.call("terminal/spawn", {"shell": "/bin/sh", "cwd": str(root)})
        terminal_id = int(terminal["id"])
        terminal_pid = int(terminal["pid"])
        saved = client.call(
            "session/save",
            {
                "path": str(session_path),
                "files": [{"path": str(source_path)}],
                "editorSession": json.dumps(editor_session),
                "sidebarVisible": True,
                "panelVisible": True,
                "panelHeight": 10,
            },
        )
        assert saved["editorSession"] == editor_session, saved
        terminals = client.call("terminal/list")["terminals"]
        assert len(terminals) == 1, terminals
        assert terminals[0]["id"] == terminal_id, terminals
        before_shutdown = descendants(daemon_pid)
    finally:
        stop_gracefully(client)
    remaining = wait_for_exit(before_shutdown)
    assert not remaining, f"cycle {cycle} left descendants: {sorted(remaining)}"

    restored_client = RpcClient(root, env={"HOME": str(home), "USERPROFILE": str(home)})
    try:
        loaded = restored_client.call("session/load", {"path": str(session_path)})
        assert loaded["editorSession"] == editor_session, loaded
        assert restored_client.call("terminal/list")["terminals"] == []
    finally:
        stop_gracefully(restored_client)
    return {
        "cycle": cycle,
        "terminalPid": terminal_pid,
        "descendantsBeforeShutdown": sorted(before_shutdown),
        "remainingPids": sorted(remaining),
        "sessionRestored": True,
        "staleTerminals": 0,
        "elapsedMs": int((time.perf_counter() - started) * 1000),
    }


def main() -> int:
    if not DEFAULT_BIN.exists():
        raise SystemExit(f"missing daemon binary: {DEFAULT_BIN}; run npm run build first")
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    with tempfile.TemporaryDirectory(prefix="wizp-recovery-") as tmp:
        root = Path(tmp)
        home = root / "home"
        home.mkdir()
        cycles = []
        for cycle in range(1, CYCLES + 1):
            cycles.append(run_cycle(root, home, cycle))
    usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_ms = int((usage_after.ru_utime - usage_before.ru_utime + usage_after.ru_stime - usage_before.ru_stime) * 1000)
    max_rss_growth_kb = max(0, int(usage_after.ru_maxrss - usage_before.ru_maxrss))
    assert cpu_ms <= MAX_CPU_MS, cpu_ms
    assert max_rss_growth_kb <= MAX_RSS_GROWTH_KB, max_rss_growth_kb
    report = {
        "status": "passed",
        "cycles": cycles,
        "cycleCount": len(cycles),
        "cpuMs": cpu_ms,
        "cpuBudgetMs": MAX_CPU_MS,
        "maxRssGrowthKb": max_rss_growth_kb,
        "rssGrowthBudgetKb": MAX_RSS_GROWTH_KB,
        "descendants": 0,
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"parity recovery smoke ok: cycles={len(cycles)} cpuMs={cpu_ms} "
        f"maxRssGrowthKb={max_rss_growth_kb} descendants=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
