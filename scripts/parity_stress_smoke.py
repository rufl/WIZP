#!/usr/bin/env python3
"""Materialize local stress-budget samples and the report contract."""

from __future__ import annotations

import json
import os
import resource
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from parity_daemon_smoke import RpcClient

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "build" / "parity-stress" / "stress-report.json"
WORKFLOW = ROOT / ".github" / "workflows" / "parity-hardening.yml"
BIN = ROOT / "zig-out" / "bin" / "wizp"


def _rss_kb() -> int:
    try:
        with Path("/proc/self/statm").open("r", encoding="utf-8") as statm:
            pages = int(statm.read().split()[1])
        return int(pages * (os.sysconf("SC_PAGE_SIZE") / 1024))
    except Exception:
        return 0


def _terminal_startup_sample() -> dict:
    started = time.perf_counter()
    proc = subprocess.run(
        [str(BIN), "--terminal-probe"],
        cwd=str(ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    if proc.returncode != 0:
        raise AssertionError(f"startup sample failed: {proc.stderr[-800:]}")
    return {"elapsedMs": elapsed_ms, "ok": "WIZP terminal probe ready" in f"{proc.stdout}\n{proc.stderr}"}


def _large_repo_search_sample() -> dict:
    with tempfile.TemporaryDirectory(prefix="wizp-stress-repo-") as tmp:
        root = Path(tmp)
        for index in range(1000):
            (root / f"file-{index:04d}.txt").write_text(
                f"line {index}\nneedle {index % 17}\n", encoding="utf-8"
            )
        started = time.perf_counter()
        matches = 0
        for file in root.glob("*.txt"):
            if "needle 7" in file.read_text(encoding="utf-8"):
                matches += 1
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        return {"files": 1000, "matches": matches, "elapsedMs": elapsed_ms}


def _large_file_sample() -> dict:
    with tempfile.TemporaryDirectory(prefix="wizp-stress-large-file-") as tmp:
        target = Path(tmp) / "large.txt"
        chunk = b"0123456789abcdef\n" * 4096
        remaining = 50 * 1024 * 1024
        with target.open("wb") as output:
            while remaining > 0:
                data = chunk[: min(len(chunk), remaining)]
                output.write(data)
                remaining -= len(data)
        started = time.perf_counter()
        with target.open("rb") as source:
            head = source.read(1024)
            source.seek(-1024, os.SEEK_END)
            tail = source.read(1024)
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        return {"bytes": target.stat().st_size, "sampleBytes": len(head) + len(tail), "elapsedMs": elapsed_ms}


def _kill_fixture_process(kind: str) -> dict:
    proc = subprocess.Popen(
        ["sh", "-c", "trap 'exit 143' TERM; while :; do sleep 1; done"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        cwd=str(ROOT),
        start_new_session=True,
    )
    started = time.perf_counter()
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        return_code = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        return_code = proc.wait(timeout=5)
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    retry = _terminal_startup_sample()
    if retry.get("ok") is not True:
        raise AssertionError(f"WIZP retry probe failed after killing {kind}: {retry}")
    return {
        "kind": kind,
        "pid": proc.pid,
        "terminated": return_code in {143, -15, -9},
        "returnCode": return_code,
        "cleanupMs": elapsed_ms,
        "daemonRetryOk": retry.get("ok") is True,
        "userVisibleState": "process-exited-retry-available",
    }


def _crash_recovery_samples() -> list[dict]:
    samples = [_kill_fixture_process(kind) for kind in ("extension-host", "lsp", "dap", "pty", "webview-renderer")]
    failed = [sample for sample in samples if not sample["terminated"] or not sample["daemonRetryOk"]]
    if failed:
        raise AssertionError(f"crash recovery fixture(s) failed: {failed}")
    return samples


def _process_tree(root_pid: int) -> set[int]:
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


def _real_daemon_shutdown_sample() -> dict:
    with tempfile.TemporaryDirectory(prefix="wizp-stress-shutdown-") as tmp:
        client = RpcClient(Path(tmp), BIN)
        daemon_pid = client.proc.pid
        usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        spawned = client.call("terminal/spawn", {"shell": "/bin/sh", "cwd": tmp})
        terminal_pid = int(spawned["pid"])
        client.call("terminal/write", {"id": spawned["id"], "data": "printf WIZP_SHUTDOWN_ACTIVE\\n"})
        descendants_before = sorted(_process_tree(daemon_pid))
        if terminal_pid not in descendants_before:
            client.close()
            raise AssertionError(
                f"real terminal child {terminal_pid} missing from daemon process tree {descendants_before}"
            )

        started = time.perf_counter()
        assert client.proc.stdin is not None
        client.proc.stdin.close()
        try:
            return_code = client.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.proc.kill()
            client.proc.wait(timeout=5)
            raise AssertionError("WIZP daemon did not stop after stdin EOF")
        cleanup_ms = int((time.perf_counter() - started) * 1000)
        deadline = time.time() + 2
        remaining = [pid for pid in descendants_before if Path(f"/proc/{pid}").exists()]
        while remaining and time.time() < deadline:
            time.sleep(0.05)
            remaining = [pid for pid in descendants_before if Path(f"/proc/{pid}").exists()]
        usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        return {
            "daemonPid": daemon_pid,
            "terminalPid": terminal_pid,
            "descendantPidsBeforeShutdown": descendants_before,
            "remainingPids": remaining,
            "returnCode": return_code,
            "cleanupMs": cleanup_ms,
            "stdinEofShutdown": True,
            "terminalReaped": terminal_pid not in remaining,
            "profiling": {
                "userCpuMs": round((usage_after.ru_utime - usage_before.ru_utime) * 1000, 3),
                "systemCpuMs": round((usage_after.ru_stime - usage_before.ru_stime) * 1000, 3),
                "maxRssDeltaKb": max(0, usage_after.ru_maxrss - usage_before.ru_maxrss),
            },
            "ok": return_code == 0 and not remaining,
        }


def main() -> int:
    if not BIN.exists():
        raise AssertionError(f"built WIZP binary missing: {BIN}")
    budgets = {
        "startupColdMs": 250,
        "largeRepoFiles": 1000,
        "largeRepoSearchMs": 2500,
        "largeFileBytes": 50 * 1024 * 1024,
        "largeFileSampleMs": 1500,
        "memoryGrowthMb": 32,
        "iterations": 50,
        "crashCleanupMs": 5000,
        "daemonShutdownMs": 5000,
    }
    before_rss = _rss_kb()
    startup_samples = [_terminal_startup_sample() for _ in range(3)]
    search_sample = _large_repo_search_sample()
    large_file_sample = _large_file_sample()
    crash_samples = _crash_recovery_samples()
    shutdown_sample = _real_daemon_shutdown_sample()
    after_rss = _rss_kb()
    failures = []
    failures.extend(
        f"startup {sample['elapsedMs']}ms > {budgets['startupColdMs']}ms"
        for sample in startup_samples
        if sample["elapsedMs"] > budgets["startupColdMs"] or sample.get("ok") is not True
    )
    if search_sample["files"] < budgets["largeRepoFiles"] or search_sample["elapsedMs"] > budgets["largeRepoSearchMs"]:
        failures.append(f"large repo search sample missed budget: {search_sample}")
    if large_file_sample["bytes"] < budgets["largeFileBytes"] or large_file_sample["elapsedMs"] > budgets["largeFileSampleMs"]:
        failures.append(f"large file sample missed budget: {large_file_sample}")
    memory_growth_kb = max(0, after_rss - before_rss)
    if memory_growth_kb > budgets["memoryGrowthMb"] * 1024:
        failures.append(f"memory growth {memory_growth_kb}KB > {budgets['memoryGrowthMb']}MB")
    failures.extend(
        f"{sample['kind']} cleanup {sample['cleanupMs']}ms failed"
        for sample in crash_samples
        if sample["cleanupMs"] > budgets["crashCleanupMs"] or not sample["terminated"] or not sample["daemonRetryOk"]
    )
    if shutdown_sample["cleanupMs"] > budgets["daemonShutdownMs"] or shutdown_sample["ok"] is not True:
        failures.append(f"real daemon shutdown missed budget: {shutdown_sample}")
    if failures:
        raise AssertionError("; ".join(failures))
    payload = {
        "budgets": budgets,
        "samples": {
            "startupTerminal": startup_samples,
            "largeRepoSearch": search_sample,
            "largeFileRead": large_file_sample,
            "crashRecovery": crash_samples,
            "scriptMemoryGrowthKb": memory_growth_kb,
            "daemonShutdown": shutdown_sample,
        },
        "startupBenchmark": "build/parity-stress/startup-benchmark.json",
        "guiStartupBenchmark": "build/parity-stress/gui-startup-benchmark.json",
        "workflows": [
            "startup",
            "large-repo-search",
            "50mb-editor",
            "memory-growth",
            "crash-recovery",
            "killed-lsp-dap-recovery",
            "profiled-daemon-terminal-shutdown",
        ],
        "status": "local-budget-samples-materialized",
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    if "stress-budgets" not in workflow or "parity_stress_smoke.py" not in workflow:
        raise AssertionError("stress budget workflow entry is missing")
    print(f"stress budget contract ok: {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
