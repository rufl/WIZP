#!/usr/bin/env python3
"""Capture a Linux packaged-native WIZP baseline with conservative claims.

This driver launches an Electrobun launcher in an isolated process group and
profile, exercises the visible X11 terminal with real keyboard events, and
retains enough evidence to diagnose a failure.  It covers one requested
terminal-count run at a time for UI-NATIVE-001/003/004/005. It does not claim
the UI-NATIVE-002 30-minute soak.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BINARY = ROOT / "build" / "dev-linux-x64" / "WIZP-dev" / "bin" / "launcher"
DEFAULT_OUTPUT = ROOT / "build" / "ui-ux" / "native-baseline"
TERMINAL_COMMAND = "printf WIZP_UI_TERMINAL_%s OK"
TERMINAL_MARKER = "WIZP_UI_TERMINAL_OK"
TERMINAL_TYPE_DELAY_MS = "85"
PROMPT_MARKER = "WIZP_UI_PROMPT"
PROMPT_RENDER_BUDGET_SECONDS = 3.0
TERMINAL_READ_BUDGET_PER_SECOND = 10.0
MAIN_PROCESS_CPU_BUDGET_PERCENT = 5.0
SAMPLE_INTERVAL_SECONDS = 1.0
PROCESS_STEADY_CPU_WARMUP_SECONDS = 10.0
ELECTROBUN_NATIVE_SHUTDOWN_WAIT_SECONDS = 5.0
DETACHED_DESCENDANT_GRACE_SECONDS = 1.0
PROCESS_GROUP_TERM_TIMEOUT_SECONDS = ELECTROBUN_NATIVE_SHUTDOWN_WAIT_SECONDS + 15.0
SOAK_DURATION_SECONDS = 30.0 * 60.0
SOAK_RSS_GROWTH_BUDGET_BYTES = 512 * 1024 * 1024
CEF_PROFILE_WARNING_MARKER = "Cannot create profile at path"
GLX_BAD_WINDOW_MARKER = "GLXBadWindow"
MOJO_WIDGET_HOST_REJECTION_MARKER = "Message 0 rejected by interface blink.mojom.WidgetHost"
GTK_DISABLE_SETLOCALE_WARNING_MARKER = "gtk_disable_setlocale() must be called before gtk_init()"
CHILD_SIGNAL_MARKER = "Child process terminated by signal:"
MIN_TERMINAL_COUNT = 1
MAX_TERMINAL_COUNT = 8


class SmokeFailure(RuntimeError):
    """A failure with a concise user-facing explanation."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")


def write_deterministic_shell_profile(profile_dir: Path) -> None:
    """Install the marker for both interactive and login-interactive Bash."""
    write_text(
        profile_dir / ".bashrc",
        f"printf '{PROMPT_MARKER}\\n'\nexport PS1='{PROMPT_MARKER}> '\n",
    )
    write_text(
        profile_dir / ".bash_profile",
        'if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n',
    )


def canonical_ocr_marker(value: str) -> str:
    normalized = "".join(character for character in value.casefold() if character.isalnum())
    replacements = (
        ("wezp", "wizp"),
        ("w1zp", "wizp"),
        ("wuizp", "wizp"),
        ("eoitor", "editor"),
        ("edltor", "editor"),
        ("ed1tor", "editor"),
        ("edttor", "editor"),
        ("termtnal", "terminal"),
        ("termlnal", "terminal"),
        ("terninal", "terminal"),
        ("savfd", "saved"),
        ("fatl", "fail"),
        ("wizui", "wizpui"),
        ("wizpu1", "wizpui"),
        ("savefailost", "savefailok"),
        ("linwcnative", "linuxnative"),
        ("lnwenatve", "linuxnative"),
        ("linucnative", "linuxnative"),
        ("sawed", "saved"),
    )
    for old, new in replacements:
        normalized = normalized.replace(old, new)
    return normalized


def ocr_contains_marker(text: str, marker: str) -> bool:
    """Tolerate OCR replacing underscores with spaces, punctuation, or common glyph confusions."""
    normalized_text = canonical_ocr_marker(text)
    normalized_marker = canonical_ocr_marker(marker)
    return bool(normalized_marker) and normalized_marker in normalized_text


def ocr_contains_shell_error(text: str) -> bool:
    normalized = " ".join(text.casefold().split())
    compact = "".join(character for character in text.casefold() if character.isalnum())
    return (
        "command not found" in normalized
        or "cannot be preloaded" in normalized
        or "error: ld.so" in normalized
        or "commandnotfound" in compact
        or "cannotbepreloaded" in compact
        or "errorldso" in compact
        or "ldpreload" in compact
    )


def resolve_cli_path(raw: str, *, base: Path) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def contains_resources_app(path: Path) -> bool:
    parts = [part.casefold() for part in path.resolve().parts]
    return any(parts[index : index + 2] == ["resources", "app"] for index in range(len(parts) - 1))


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        raise SmokeFailure(f"required GUI/evidence tool is missing from PATH: {name}")
    return path


def select_tesseract_language(tesseract: str) -> str:
    result = run_tool([tesseract, "--list-langs"], timeout=10.0)
    languages = {
        line.strip()
        for line in result.stdout.splitlines()
        if line.strip() and not line.startswith("List of available")
    }
    for preferred in ("eng", "afr"):
        if preferred in languages:
            return preferred
    fallback = next((language for language in sorted(languages) if language != "osd"), None)
    if fallback is None:
        raise SmokeFailure("Tesseract has no text recognition language installed")
    return fallback


def validate_port(port: int, name: str) -> None:
    if not 1024 <= port <= 65535:
        raise SmokeFailure(f"{name} must be between 1024 and 65535; got {port}")


def require_unused_port(port: int, name: str) -> None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.2)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                raise SmokeFailure(f"{name} {port} is already in use")
    except SmokeFailure:
        raise
    except OSError as exc:
        raise SmokeFailure(f"could not probe {name} {port}: {exc}") from exc


def run_tool(
    argv: list[str],
    *,
    timeout: float = 15.0,
    allowed_codes: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise SmokeFailure(f"tool timed out after {timeout:.1f}s: {' '.join(argv)}") from exc
    except OSError as exc:
        raise SmokeFailure(f"could not execute {argv[0]}: {exc}") from exc
    if result.returncode not in allowed_codes:
        detail = (result.stderr or result.stdout).strip()
        if len(detail) > 800:
            detail = detail[-800:]
        raise SmokeFailure(
            f"tool failed with exit {result.returncode}: {' '.join(argv)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def http_get(port: int, path: str, *, timeout: float = 1.0) -> tuple[int, bytes]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        method="GET",
        headers={"Cache-Control": "no-cache", "Connection": "close"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def wait_for_ready(port: int, process: subprocess.Popen[bytes], timeout: float = 20.0) -> dict[str, Any]:
    started = time.monotonic()
    attempts = 0
    last_detail = "connection not attempted"
    while time.monotonic() - started < timeout:
        attempts += 1
        exit_code = process.poll()
        if exit_code is not None:
            raise SmokeFailure(f"launcher exited before /__wizp_ready (exit {exit_code})")
        try:
            status, body = http_get(port, "/__wizp_ready", timeout=0.5)
            last_detail = f"HTTP {status}: {body[:200].decode('utf-8', 'replace')}"
            if status == 204:
                return {
                    "attempts": attempts,
                    "elapsedSeconds": round(time.monotonic() - started, 3),
                    "status": status,
                }
        except (OSError, urllib.error.URLError) as exc:
            last_detail = str(exc)
        time.sleep(0.05)
    raise SmokeFailure(f"timed out waiting for /__wizp_ready on port {port}: {last_detail}")


class RpcClient:
    def __init__(self, port: int) -> None:
        self.port = port
        self.next_id = 1

    def call(self, method: str, params: dict[str, Any] | None = None, *, timeout: float = 4.0) -> Any:
        request_id = self.next_id
        self.next_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/api/rpc",
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Content-Length": str(len(payload)),
                "Connection": "close",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            raise SmokeFailure(f"RPC {method} returned HTTP {exc.code}: {detail[:800]}") from exc
        except (OSError, urllib.error.URLError) as exc:
            raise SmokeFailure(f"RPC {method} failed: {exc}") from exc
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SmokeFailure(f"RPC {method} returned invalid JSON: {raw[:800]!r}") from exc
        if not isinstance(decoded, dict):
            raise SmokeFailure(f"RPC {method} returned a non-object JSON-RPC envelope")
        if decoded.get("error") is not None:
            raise SmokeFailure(f"RPC {method} failed: {decoded['error']}")
        if decoded.get("id") != request_id:
            raise SmokeFailure(
                f"RPC {method} response id mismatch: expected {request_id}, got {decoded.get('id')!r}"
            )
        return decoded.get("result")


def read_metrics(port: int) -> dict[str, Any]:
    try:
        status, body = http_get(port, "/__wizp_metrics", timeout=1.0)
    except (OSError, urllib.error.URLError) as exc:
        raise SmokeFailure(f"GET /__wizp_metrics failed: {exc}") from exc
    if status != 200:
        raise SmokeFailure(
            f"GET /__wizp_metrics returned HTTP {status}; the packaged binary must expose the planned metrics endpoint"
        )
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(f"GET /__wizp_metrics returned invalid JSON: {body[:800]!r}") from exc
    if not isinstance(payload, dict):
        raise SmokeFailure("GET /__wizp_metrics returned a non-object JSON payload")
    for field in ("rpcRequests", "terminalReadRequests"):
        value = payload.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise SmokeFailure(f"GET /__wizp_metrics field {field} must be a non-negative integer")
    return payload


def read_native_terminal_telemetry(port: int) -> dict[str, Any]:
    try:
        status, body = http_get(port, "/__native-terminal-telemetry", timeout=1.0)
    except (OSError, urllib.error.URLError) as exc:
        raise SmokeFailure(f"GET /__native-terminal-telemetry failed: {exc}") from exc
    if status != 200:
        raise SmokeFailure(f"GET /__native-terminal-telemetry returned HTTP {status}")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(
            f"GET /__native-terminal-telemetry returned invalid JSON: {body[:800]!r}"
        ) from exc
    if not isinstance(payload, dict):
        raise SmokeFailure("GET /__native-terminal-telemetry returned a non-object JSON payload")
    return payload


def xdotool_window_ids(xdotool: str) -> set[int]:
    result = run_tool(
        [xdotool, "search", "--onlyvisible", "--name", "WIZP"],
        allowed_codes=(0, 1),
    )
    ids: set[int] = set()
    for raw in result.stdout.splitlines():
        try:
            ids.add(int(raw.strip(), 0))
        except ValueError:
            continue
    return ids


def proc_stat(pid: int) -> dict[str, Any] | None:
    return proc_stat_path(Path(f"/proc/{pid}/stat"), pid=pid)


def proc_stat_path(path: Path, *, pid: int, tid: int | None = None) -> dict[str, Any] | None:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    close = raw.rfind(")")
    open_paren = raw.find("(")
    if open_paren < 0 or close < 0 or close <= open_paren:
        return None
    try:
        fields = raw[close + 2 :].split()
        try:
            command = (
                Path(f"/proc/{pid}/cmdline")
                .read_bytes()
                .replace(b"\0", b" ")
                .decode("utf-8", "replace")
                .strip()
            )
        except OSError:
            command = ""
        item = {
            "pid": pid,
            "name": raw[open_paren + 1 : close],
            "command": command,
            "state": fields[0],
            "ppid": int(fields[1]),
            "pgrp": int(fields[2]),
            "cpuTicks": int(fields[11]) + int(fields[12]),
            "startTimeTicks": int(fields[19]),
            "rssBytes": max(0, int(fields[21])) * os.sysconf("SC_PAGE_SIZE"),
        }
        if tid is not None:
            item["tid"] = tid
        return item
    except (IndexError, TypeError, ValueError):
        return None


def read_proc_threads(pid: int) -> list[dict[str, Any]]:
    task_dir = Path(f"/proc/{pid}/task")
    threads: list[dict[str, Any]] = []
    try:
        entries = list(task_dir.iterdir())
    except OSError:
        return threads
    for entry in entries:
        if not entry.name.isdigit():
            continue
        tid = int(entry.name)
        item = proc_stat_path(entry / "stat", pid=pid, tid=tid)
        if item is not None:
            threads.append(
                {
                    "tid": tid,
                    "name": item.get("name", ""),
                    "state": item.get("state", ""),
                    "cpuTicks": item.get("cpuTicks", 0),
                }
            )
    threads.sort(key=lambda item: int(item.get("tid") or 0))
    return threads


def read_proc_table() -> dict[int, dict[str, Any]]:
    table: dict[int, dict[str, Any]] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        item = proc_stat(int(entry.name))
        if item is not None:
            table[item["pid"]] = item
    return table


def process_group_members(process_group: int) -> list[int]:
    return sorted(
        pid
        for pid, item in read_proc_table().items()
        if item.get("pgrp") == process_group and item.get("state") != "Z"
    )


def process_belongs_to_run(pid: int, root_pid: int, process_group: int) -> tuple[bool, bool]:
    table = read_proc_table()
    item = table.get(pid)
    if item is None:
        return False, False
    group_match = item.get("pgrp") == process_group
    cursor = pid
    visited: set[int] = set()
    while cursor in table and cursor not in visited:
        if cursor == root_pid:
            return group_match, True
        visited.add(cursor)
        cursor = table[cursor]["ppid"]
    return group_match, False


def sample_process_tree(root_pid: int, previous: dict[str, Any] | None) -> dict[str, Any]:
    now_mono = time.monotonic()
    table = read_proc_table()
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, item in table.items():
            if pid not in descendants and item["ppid"] in descendants:
                descendants.add(pid)
                changed = True
    root_item = table.get(root_pid)
    process_group = root_item["pgrp"] if root_item is not None else root_pid
    selected_ids = sorted(
        pid for pid, item in table.items() if pid in descendants or item["pgrp"] == process_group
    )
    processes = [dict(table[pid], descendant=pid in descendants) for pid in selected_ids]
    for item in processes:
        item["role"] = classify_process_role(item)
        item["threads"] = read_proc_threads(int(item["pid"]))
    sample: dict[str, Any] = {
        "timestamp": utc_now(),
        "monotonicSeconds": now_mono,
        "rootPid": root_pid,
        "processGroup": process_group,
        "processes": processes,
        "aggregateRssBytes": sum(item["rssBytes"] for item in processes),
        "rootRssBytes": root_item["rssBytes"] if root_item is not None else None,
    }
    if previous is not None:
        elapsed = now_mono - float(previous["monotonicSeconds"])
        prior_ticks = {item["pid"]: item["cpuTicks"] for item in previous["processes"]}
        prior_thread_ticks = {
            (item["pid"], thread["tid"]): thread["cpuTicks"]
            for item in previous["processes"]
            for thread in item.get("threads", [])
            if "tid" in thread and "cpuTicks" in thread
        }
        clock_ticks = os.sysconf("SC_CLK_TCK")
        aggregate_delta = 0
        for item in processes:
            before = prior_ticks.get(item["pid"])
            cpu_percent = None
            if before is not None and elapsed > 0 and item["cpuTicks"] >= before:
                delta = item["cpuTicks"] - before
                aggregate_delta += delta
                cpu_percent = delta / clock_ticks / elapsed * 100.0
            item["cpuPercentSincePrevious"] = (
                round(cpu_percent, 3) if cpu_percent is not None else None
            )
            for thread in item.get("threads", []):
                before_thread = prior_thread_ticks.get((item["pid"], thread["tid"]))
                thread_cpu_percent = None
                if (
                    before_thread is not None
                    and elapsed > 0
                    and thread["cpuTicks"] >= before_thread
                ):
                    thread_delta = thread["cpuTicks"] - before_thread
                    thread_cpu_percent = thread_delta / clock_ticks / elapsed * 100.0
                thread["cpuPercentSincePrevious"] = (
                    round(thread_cpu_percent, 3)
                    if thread_cpu_percent is not None
                    else None
                )
        sample["aggregateCpuPercentSincePrevious"] = (
            round(aggregate_delta / clock_ticks / elapsed * 100.0, 3) if elapsed > 0 else None
        )
    else:
        for item in processes:
            item["cpuPercentSincePrevious"] = None
            for thread in item.get("threads", []):
                thread["cpuPercentSincePrevious"] = None
        sample["aggregateCpuPercentSincePrevious"] = None
    return sample


def classify_process_role(process: dict[str, Any]) -> str:
    name = str(process.get("name", "")).casefold()
    command = str(process.get("command", "")).casefold()
    if "resources/main.js" in command and name == "bun":
        return "electrobun-main"
    if "launcher" in name or "launcher" in command:
        return "launcher-wrapper"
    if name == "wizp" and " --daemon" in command:
        return "zig-daemon"
    if name == "wizp":
        return "zig-http-server"
    if name == "bun" and "__wizp_eval_end__" in command:
        return "extension-host-eval-bridge"
    if "bun helper" in name or " helper " in command:
        if "--type=gpu-process" in command:
            return "cef-gpu"
        if "--utility-sub-type=network.mojom.networkservice" in command:
            return "cef-network-service"
        if "--utility-sub-type=storage.mojom.storageservice" in command:
            return "cef-storage-service"
        if "--type=renderer" in command:
            return "cef-renderer"
        if "--type=zygote" in command:
            return "cef-zygote"
        if "--type=utility" in command:
            return "cef-utility"
        return "cef-helper"
    if name in {"bash", "sh", "dash", "zsh", "fish"}:
        return "terminal-shell"
    return "other"


def get_window_info(xdotool: str, window_id: int) -> dict[str, Any]:
    name = run_tool([xdotool, "getwindowname", str(window_id)]).stdout.strip()
    pid_result = run_tool(
        [xdotool, "getwindowpid", str(window_id)],
        allowed_codes=(0, 1),
    )
    try:
        pid = int(pid_result.stdout.strip())
    except ValueError:
        pid = None
    geometry_result = run_tool([xdotool, "getwindowgeometry", "--shell", str(window_id)])
    geometry: dict[str, int] = {}
    for line in geometry_result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"X", "Y", "WIDTH", "HEIGHT", "SCREEN"}:
            try:
                geometry[key.casefold()] = int(value)
            except ValueError:
                continue
    if geometry.get("width", 0) <= 0 or geometry.get("height", 0) <= 0:
        raise SmokeFailure(f"WIZP window {window_id} has invalid geometry: {geometry_result.stdout!r}")
    return {"id": window_id, "name": name, "pid": pid, "geometry": geometry}


def wait_for_new_window(
    xdotool: str,
    before: set[int],
    process_group: int,
    process: subprocess.Popen[bytes],
    timeout: float = 20.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    rejected: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise SmokeFailure(f"launcher exited before its X11 window appeared (exit {process.returncode})")
        for window_id in sorted(xdotool_window_ids(xdotool) - before):
            try:
                info = get_window_info(xdotool, window_id)
            except SmokeFailure:
                continue
            if "wizp" not in info["name"].casefold():
                continue
            window_pid = info.get("pid")
            group_match, descendant_match = (
                process_belongs_to_run(window_pid, process.pid, process_group)
                if isinstance(window_pid, int)
                else (False, False)
            )
            if isinstance(window_pid, int) and not group_match and not descendant_match:
                rejected.append(info)
                continue
            info["processGroupMatched"] = group_match
            info["descendantMatched"] = descendant_match
            return info
        time.sleep(0.1)
    detail = f"; rejected candidates: {rejected[-3:]}" if rejected else ""
    raise SmokeFailure(f"timed out waiting for a new visible WIZP X11 window{detail}")


def probe_window_lifecycle(
    xdotool: str,
    window_id: int,
    *,
    phase: str,
    ready_monotonic: float,
) -> dict[str, Any]:
    sample: dict[str, Any] = {
        "timestamp": utc_now(),
        "elapsedSeconds": round(max(0.0, time.monotonic() - ready_monotonic), 3),
        "phase": phase,
        "windowId": window_id,
    }
    try:
        name = run_tool([xdotool, "getwindowname", str(window_id)]).stdout.strip()
    except SmokeFailure as exc:
        sample.update(
            {
                "exists": False,
                "wizpNamed": False,
                "present": False,
                "error": str(exc),
            }
        )
        return sample
    wizp_named = "wizp" in name.casefold()
    sample.update(
        {
            "exists": True,
            "wizpNamed": wizp_named,
            "present": wizp_named,
            "name": name,
        }
    )
    return sample


def summarize_window_lifecycle(
    samples: list[dict[str, Any]],
    *,
    duration_seconds: float,
) -> dict[str, Any]:
    first_loss = next(
        (sample for sample in samples if sample.get("present") is not True),
        None,
    )
    final_probe = samples[-1] if samples else None
    return {
        "sampleCount": len(samples),
        "durationSeconds": duration_seconds,
        "probeIntervalSeconds": SAMPLE_INTERVAL_SECONDS,
        "firstLoss": first_loss,
        "finalProbe": final_probe,
        "presentThroughout": first_loss is None,
        "survivedWindow": bool(samples) and first_loss is None and final_probe.get("present") is True,
        "samples": samples,
    }


def activate_window(xdotool: str, window: dict[str, Any]) -> None:
    window_id = str(window["id"])
    run_tool([xdotool, "windowraise", window_id])
    try:
        run_tool([xdotool, "windowactivate", "--sync", window_id])
        activation_method = "xdotool-windowactivate"
    except SmokeFailure as activation_error:
        run_tool([xdotool, "windowfocus", "--sync", window_id])
        activation_method = "xdotool-windowfocus-fallback"
        window["activationFallbackReason"] = str(activation_error)
    require_active_window(xdotool, window, phase="activation")
    window["activated"] = True
    window["activationMethod"] = activation_method


def parse_active_window_id(raw: str) -> int:
    try:
        return int(raw.strip(), 0)
    except ValueError as exc:
        raise SmokeFailure(f"xdotool returned an invalid active window id: {raw.strip()!r}") from exc


def require_active_window(xdotool: str, window: dict[str, Any], *, phase: str) -> None:
    observed: dict[str, Any] = {}
    for command in ("getactivewindow", "getwindowfocus"):
        try:
            window_id = parse_active_window_id(run_tool([xdotool, command]).stdout)
            observed[command] = window_id
        except SmokeFailure as exc:
            observed[command] = str(exc)
            continue
        if window_id == window["id"]:
            active_name = run_tool([xdotool, "getwindowname", str(window_id)]).stdout.strip()
            if "wizp" not in active_name.casefold():
                raise SmokeFailure(
                    f"focused window during {phase} is not WIZP: id={window_id}, name={active_name!r}"
                )
            return
    raise SmokeFailure(
        f"WIZP window lost focus during {phase}: expected {window['id']}, observed {observed}"
    )


def terminal_command_keysyms(command: str) -> list[str]:
    named = {" ": "space", "_": "underscore", "%": "percent"}
    keysyms: list[str] = []
    for character in command:
        keysym = named.get(character, character)
        if len(character) != 1 or not keysym:
            raise SmokeFailure(f"unsupported terminal marker character: {character!r}")
        keysyms.append(keysym)
    return keysyms


def focus_terminal_and_type(xdotool: str, window: dict[str, Any]) -> dict[str, Any]:
    geometry = window["geometry"]
    click_x = max(20, min(geometry["width"] - 20, geometry["width"] // 2))
    click_y = max(20, min(geometry["height"] - 30, int(geometry["height"] * 0.88)))
    window_id = str(window["id"])
    run_tool(
        [
            xdotool,
            "mousemove",
            "--window",
            window_id,
            str(click_x),
            str(click_y),
            "click",
            "1",
        ]
    )
    time.sleep(0.35)
    # Desktop focus can be stolen between initial activation and the terminal
    # click. Never send XTEST keystrokes unless the active window is still the
    # exact WIZP window selected from this process group.
    require_active_window(xdotool, window, phase="terminal typing")
    # CEF ignores synthetic XSendEvent key delivery used by xdotool's
    # --window mode. The window is already active and the click focuses xterm,
    # so use XTEST delivery through the current desktop focus instead.
    # CEF has occasionally reordered or dropped characters from a queued
    # xdotool `type` batch. Send one press/release pair at a time and recheck
    # focus before every character so input can never escape WIZP.
    for index, keysym in enumerate(terminal_command_keysyms(TERMINAL_COMMAND)):
        require_active_window(xdotool, window, phase=f"terminal key {index + 1}")
        run_tool([xdotool, "key", "--clearmodifiers", keysym])
        time.sleep(int(TERMINAL_TYPE_DELAY_MS) / 1000.0)
    require_active_window(xdotool, window, phase="terminal submit")
    run_tool([xdotool, "key", "--clearmodifiers", "Return"])
    return {
        "command": TERMINAL_COMMAND,
        "marker": TERMINAL_MARKER,
        "inputMethod": "xdotool-focus-guarded-discrete-x11-key-events",
        "typeDelayMs": int(TERMINAL_TYPE_DELAY_MS),
        "preTypeClear": "none",
        "click": {"x": click_x, "y": click_y},
        "typed": True,
    }


def capture_and_ocr(
    import_tool: str,
    tesseract: str,
    window_id: int,
    screenshot: Path,
    tesseract_stderr: Path,
    language: str,
) -> str:
    capture_window(import_tool, window_id, screenshot)
    return ocr_screenshot(tesseract, screenshot, tesseract_stderr, language)


def capture_window(import_tool: str, window_id: int, screenshot: Path) -> None:
    try:
        run_tool(
            [import_tool, "-silent", "-window", str(window_id), str(screenshot)],
            timeout=20.0,
        )
    except SmokeFailure:
        if os.environ.get("WIZP_VIRTUAL_DISPLAY") != "1":
            raise
        run_tool(
            [import_tool, "-silent", "-window", "root", str(screenshot)],
            timeout=20.0,
        )
    if not screenshot.is_file() or screenshot.stat().st_size <= 0:
        raise SmokeFailure(f"ImageMagick did not produce a non-empty screenshot: {screenshot}")


def ocr_screenshot(
    tesseract: str,
    screenshot: Path,
    tesseract_stderr: Path,
    language: str,
) -> str:
    result = run_tool(
        [tesseract, str(screenshot), "stdout", "-l", language, "--psm", "6"],
        timeout=30.0,
    )
    write_text(tesseract_stderr, result.stderr)
    return result.stdout


def wait_for_visible_ui(
    import_tool: str,
    tesseract: str,
    language: str,
    window_id: int,
    screenshot: Path,
    ocr_path: Path,
    tesseract_stderr: Path,
    timeout: float = 20.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    attempts = 0
    last_ocr = ""
    markers = ("explorer", "no folder open", "no folder opened", "open folder", "welcome")
    while time.monotonic() < deadline:
        attempts += 1
        last_ocr = capture_and_ocr(
            import_tool,
            tesseract,
            window_id,
            screenshot,
            tesseract_stderr,
            language,
        )
        write_text(ocr_path, last_ocr)
        normalized = " ".join(last_ocr.casefold().split())
        matched = [marker for marker in markers if marker in normalized]
        if matched:
            return {
                "attempts": attempts,
                "matchedMarkers": matched,
                "ocrTextFile": ocr_path.name,
                "screenshotFile": screenshot.name,
                "visible": True,
                "workspaceEmptyStateFoundByOcr": (
                    "no folder open" in normalized or "open folder" in normalized
                ),
            }
        time.sleep(0.25)
    raise SmokeFailure(
        f"native WIZP window never exposed a recognizable application surface within {timeout:.1f}s; "
        f"last OCR was {last_ocr[:300]!r}"
    )


def wait_for_terminals(
    rpc: RpcClient, *, expected_count: int = 1, timeout: float = 12.0
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        last = rpc.call("terminal/list")
        if (
            isinstance(last, dict)
            and isinstance(last.get("terminals"), list)
            and len(last["terminals"]) >= expected_count
        ):
            return last
        time.sleep(0.1)
    raise SmokeFailure(
        f"expected {expected_count} backend terminal(s) within {timeout:.1f}s; "
        f"last response: {last!r}"
    )


def workspace_has_packaged_path(workspace: Any) -> bool:
    if not isinstance(workspace, dict) or not isinstance(workspace.get("folders"), list):
        return True
    for folder in workspace["folders"]:
        raw = folder.get("path") if isinstance(folder, dict) else None
        if not isinstance(raw, str):
            return True
        parts = [part for part in raw.replace("\\", "/").casefold().split("/") if part]
        if any(
            parts[index : index + 2] == ["resources", "app"]
            for index in range(len(parts) - 1)
        ):
            return True
    return False


def summarize_metrics(samples: list[dict[str, Any]], terminal_count: int = 1) -> dict[str, Any]:
    normalized_terminal_count = max(1, terminal_count)
    valid = [
        sample
        for sample in samples
        if sample.get("ok") and str(sample.get("phase", "")).startswith("steady")
    ]
    summary: dict[str, Any] = {
        "sampleCount": len(samples),
        "validSampleCount": len(valid),
        "terminalCount": normalized_terminal_count,
        "terminalReadBudgetPerSecond": TERMINAL_READ_BUDGET_PER_SECOND,
        "terminalReadBudgetTotalPerSecond": round(
            TERMINAL_READ_BUDGET_PER_SECOND * normalized_terminal_count, 3
        ),
    }
    if len(valid) < 2:
        summary["error"] = "at least two valid metrics samples are required"
        return summary
    first = valid[0]
    last = valid[-1]
    elapsed = float(last["monotonicSeconds"]) - float(first["monotonicSeconds"])
    rpc_delta = last["metrics"]["rpcRequests"] - first["metrics"]["rpcRequests"]
    terminal_delta = (
        last["metrics"]["terminalReadRequests"] - first["metrics"]["terminalReadRequests"]
    )
    summary.update(
        {
            "elapsedSeconds": round(elapsed, 3),
            "rpcRequestsDelta": rpc_delta,
            "terminalReadRequestsDelta": terminal_delta,
            "rpcRequestsPerSecond": round(rpc_delta / elapsed, 3) if elapsed > 0 else None,
            "terminalReadRequestsPerSecond": (
                round(terminal_delta / elapsed, 3) if elapsed > 0 else None
            ),
            "terminalReadRequestsPerSecondPerTerminal": (
                round((terminal_delta / elapsed) / normalized_terminal_count, 3)
                if elapsed > 0
                else None
            ),
            "countersMonotonic": rpc_delta >= 0 and terminal_delta >= 0,
        }
    )
    rate = summary["terminalReadRequestsPerSecondPerTerminal"]
    summary["terminalReadBudgetPassed"] = (
        summary["countersMonotonic"] and isinstance(rate, (int, float)) and rate <= TERMINAL_READ_BUDGET_PER_SECOND
    )
    return summary


def summarize_processes(samples: list[dict[str, Any]], root_pid: int) -> dict[str, Any]:
    per_pid: dict[int, dict[str, Any]] = {}
    aggregate_cpu: list[float] = []
    peak_aggregate_rss = 0
    peak_steady_aggregate_rss = 0
    launch_aggregate_rss: int | None = None
    first_aggregate_rss: int | None = None
    rss_baseline_phase: str | None = None
    rss_baseline_sample_index: int | None = None
    final_aggregate_rss: int | None = None
    observed_pids: set[int] = set()
    first_steady_monotonic: float | None = None
    eligible_steady_samples: set[int] = set()
    steady_sample_count = 0
    warmup_excluded_sample_count = 0

    for index, sample in enumerate(samples):
        if not str(sample.get("phase", "")).startswith("steady"):
            continue
        steady_sample_count += 1
        monotonic = sample.get("monotonicSeconds")
        if not isinstance(monotonic, (int, float)) or not math.isfinite(monotonic):
            eligible_steady_samples.add(index)
            continue
        if first_steady_monotonic is None:
            first_steady_monotonic = float(monotonic)
        if float(monotonic) - first_steady_monotonic >= PROCESS_STEADY_CPU_WARMUP_SECONDS:
            eligible_steady_samples.add(index)
        else:
            warmup_excluded_sample_count += 1

    cpu_warmup_applied = bool(eligible_steady_samples)
    if not eligible_steady_samples:
        for index, sample in enumerate(samples):
            if str(sample.get("phase", "")).startswith("steady"):
                eligible_steady_samples.add(index)
        warmup_excluded_sample_count = 0

    for sample_index, sample in enumerate(samples):
        steady = sample_index in eligible_steady_samples
        aggregate_rss = int(sample.get("aggregateRssBytes") or 0)
        if launch_aggregate_rss is None:
            launch_aggregate_rss = aggregate_rss
        if first_aggregate_rss is None and str(sample.get("phase", "")).startswith("steady"):
            first_aggregate_rss = aggregate_rss
            rss_baseline_phase = str(sample.get("phase", ""))
            rss_baseline_sample_index = sample_index
        final_aggregate_rss = aggregate_rss
        peak_aggregate_rss = max(peak_aggregate_rss, aggregate_rss)
        if rss_baseline_sample_index is not None and sample_index >= rss_baseline_sample_index:
            peak_steady_aggregate_rss = max(peak_steady_aggregate_rss, aggregate_rss)
        aggregate = sample.get("aggregateCpuPercentSincePrevious")
        if steady and isinstance(aggregate, (int, float)) and math.isfinite(aggregate):
            aggregate_cpu.append(float(aggregate))
        for item in sample.get("processes", []):
            observed_pids.add(item["pid"])
            if not steady:
                continue
            process = per_pid.setdefault(
                item["pid"],
                {
                    "pid": item["pid"],
                    "name": item.get("name", ""),
                    "command": item.get("command", ""),
                    "role": item.get("role") or classify_process_role(item),
                    "cpuPercentSamples": [],
                    "threadSamples": {},
                    "peakRssBytes": 0,
                },
            )
            process["peakRssBytes"] = max(
                process["peakRssBytes"], int(item.get("rssBytes") or 0)
            )
            cpu = item.get("cpuPercentSincePrevious")
            if isinstance(cpu, (int, float)) and math.isfinite(cpu):
                process["cpuPercentSamples"].append(float(cpu))
            thread_samples = process["threadSamples"]
            for thread in item.get("threads", []):
                tid = thread.get("tid")
                if not isinstance(tid, int):
                    continue
                thread_summary = thread_samples.setdefault(
                    tid,
                    {
                        "tid": tid,
                        "name": thread.get("name", ""),
                        "cpuPercentSamples": [],
                    },
                )
                thread_cpu = thread.get("cpuPercentSincePrevious")
                if isinstance(thread_cpu, (int, float)) and math.isfinite(thread_cpu):
                    thread_summary["cpuPercentSamples"].append(float(thread_cpu))

    if first_aggregate_rss is None:
        first_aggregate_rss = launch_aggregate_rss
        rss_baseline_phase = str(samples[0].get("phase", "")) if samples else None
        rss_baseline_sample_index = 0 if samples else None
        peak_steady_aggregate_rss = peak_aggregate_rss

    process_summaries: list[dict[str, Any]] = []
    for process in per_pid.values():
        cpu_samples = process.pop("cpuPercentSamples")
        thread_samples = process.pop("threadSamples")
        process["role"] = process.get("role") or classify_process_role(process)
        process["cpuSampleCount"] = len(cpu_samples)
        process["meanCpuPercent"] = (
            round(sum(cpu_samples) / len(cpu_samples), 3) if cpu_samples else None
        )
        process["maxCpuPercent"] = round(max(cpu_samples), 3) if cpu_samples else None
        threads: list[dict[str, Any]] = []
        for thread in thread_samples.values():
            thread_cpu_samples = thread.pop("cpuPercentSamples")
            thread["cpuSampleCount"] = len(thread_cpu_samples)
            thread["meanCpuPercent"] = (
                round(sum(thread_cpu_samples) / len(thread_cpu_samples), 3)
                if thread_cpu_samples
                else None
            )
            thread["maxCpuPercent"] = (
                round(max(thread_cpu_samples), 3) if thread_cpu_samples else None
            )
            threads.append(thread)
        threads.sort(
            key=lambda item: (
                -float(item.get("meanCpuPercent") or 0.0),
                int(item.get("tid") or 0),
            )
        )
        process["threads"] = threads
        process_summaries.append(process)
    process_summaries.sort(key=lambda item: item["pid"])
    cpu_by_role = summarize_cpu_by_role(process_summaries)
    top_threads_by_cpu = summarize_top_threads_by_cpu(process_summaries)

    root_summary = next(
        (item for item in process_summaries if item["pid"] == root_pid), None
    )
    root_looks_like_shell = bool(
        root_summary
        and str(root_summary.get("name", "")).casefold() in {"sh", "dash", "bash"}
    )
    main_candidates = [
        item
        for item in process_summaries
        if (
            item["pid"] == root_pid
            and not root_looks_like_shell
            or "launcher.bin" in str(item.get("command", "")).casefold()
            or (
                str(item.get("name", "")).casefold() == "bun"
                and "helper" not in str(item.get("command", "")).casefold()
            )
        )
        and item.get("meanCpuPercent") is not None
    ]
    selected_main = next(
        (
            item
            for item in main_candidates
            if str(item.get("name", "")).casefold() == "bun"
            and "resources/main.js" in str(item.get("command", "")).casefold()
        ),
        None,
    )
    if selected_main is None:
        selected_main = next(
            (
                item
                for item in main_candidates
                if str(item.get("name", "")).casefold() == "bun"
                and "helper" not in str(item.get("command", "")).casefold()
            ),
            None,
        )
    if selected_main is None:
        selected_main = next(
            (item for item in main_candidates if item["pid"] == root_pid),
            max(
                main_candidates,
                key=lambda item: float(item.get("meanCpuPercent") or 0.0),
                default=None,
            ),
        )
    mean_main_cpu = selected_main.get("meanCpuPercent") if selected_main else None
    return {
        "sampleCount": len(samples),
        "observedPids": sorted(observed_pids),
        "processes": process_summaries,
        "selectedMainProcess": selected_main,
        "cpuByRole": cpu_by_role,
        "topThreadsByCpu": top_threads_by_cpu,
        "launchAggregateRssBytes": launch_aggregate_rss,
        "firstAggregateRssBytes": first_aggregate_rss,
        "rssBaselineAggregateRssBytes": first_aggregate_rss,
        "rssBaselinePhase": rss_baseline_phase,
        "rssBaselineSampleIndex": rss_baseline_sample_index,
        "finalAggregateRssBytes": final_aggregate_rss,
        "peakAggregateRssBytes": peak_aggregate_rss,
        "peakSteadyAggregateRssBytes": peak_steady_aggregate_rss,
        "peakAggregateRssGrowthBytes": (
            max(0, peak_steady_aggregate_rss - first_aggregate_rss)
            if first_aggregate_rss is not None
            else None
        ),
        "meanAggregateCpuPercent": (
            round(sum(aggregate_cpu) / len(aggregate_cpu), 3) if aggregate_cpu else None
        ),
        "maxAggregateCpuPercent": round(max(aggregate_cpu), 3) if aggregate_cpu else None,
        "mainProcessCpuBudgetPercent": MAIN_PROCESS_CPU_BUDGET_PERCENT,
        "cpuWarmupSeconds": PROCESS_STEADY_CPU_WARMUP_SECONDS,
        "cpuWarmupApplied": cpu_warmup_applied,
        "cpuSteadySampleCount": steady_sample_count,
        "cpuWarmupExcludedSampleCount": warmup_excluded_sample_count,
        "mainProcessCpuBudgetPassed": (
            isinstance(mean_main_cpu, (int, float))
            and mean_main_cpu <= MAIN_PROCESS_CPU_BUDGET_PERCENT
        ),
    }


def summarize_soak_evidence(
    *,
    claim_requested: bool,
    duration_seconds: float,
    survived_duration: bool,
    final_ready: bool,
    window_survived: bool,
    unexpected_exit: int | None,
    process_summary: dict[str, Any],
    metrics_summary: dict[str, Any],
    final_frame: dict[str, Any],
) -> dict[str, Any]:
    enough_duration = duration_seconds >= SOAK_DURATION_SECONDS
    rss_growth = process_summary.get("peakAggregateRssGrowthBytes")
    rss_growth_passed = (
        isinstance(rss_growth, int) and rss_growth <= SOAK_RSS_GROWTH_BUDGET_BYTES
    )
    final_frame_retained = final_frame.get("captured") is True
    passed = (
        claim_requested
        and enough_duration
        and survived_duration
        and final_ready
        and window_survived
        and unexpected_exit is None
        and rss_growth_passed
        and final_frame_retained
    )
    if not claim_requested:
        status = "unverified"
    elif passed:
        status = "passed"
    else:
        status = "failed"
    return {
        "status": status,
        "claimRequested": claim_requested,
        "durationSeconds": duration_seconds,
        "requiredDurationSeconds": SOAK_DURATION_SECONDS,
        "durationRequirementPassed": enough_duration,
        "survivedDuration": survived_duration,
        "finalReady": final_ready,
        "windowSurvived": window_survived,
        "unexpectedExit": unexpected_exit,
        "rssGrowthBudgetBytes": SOAK_RSS_GROWTH_BUDGET_BYTES,
        "rssGrowthBudgetPassed": rss_growth_passed,
        "processes": process_summary,
        "metrics": metrics_summary,
        "finalFrame": final_frame,
    }


def reconcile_retained_process_evidence(
    report: dict[str, Any], process_samples: list[dict[str, Any]]
) -> dict[str, Any]:
    """Recompute process-backed claims from a retained native evidence packet."""
    process = report.get("process")
    claims = report.get("claims")
    arguments = report.get("arguments")
    if not isinstance(process, dict) or not isinstance(claims, dict) or not isinstance(arguments, dict):
        raise ValueError("report is missing process, claims, or arguments")
    root_pid = process.get("launcherPid")
    if not isinstance(root_pid, int):
        raise ValueError("report process.launcherPid must be an integer")

    process_summary = summarize_processes(process_samples, root_pid)
    report["processSummary"] = process_summary

    ui003 = claims.get("UI-NATIVE-003")
    if not isinstance(ui003, dict) or not isinstance(ui003.get("evidence"), dict):
        raise ValueError("report is missing UI-NATIVE-003 evidence")
    ui003_evidence = ui003["evidence"]
    ui003_evidence["processes"] = process_summary
    ui003_evidence["mainProcessCpuBudgetPassed"] = (
        process_summary.get("mainProcessCpuBudgetPassed") is True
    )
    ui003_passed = (
        ui003_evidence.get("terminalCountObserved") is True
        and ui003_evidence.get("terminalReadBudgetPassed") is True
        and ui003_evidence.get("mainProcessCpuBudgetPassed") is True
    )
    ui003["status"] = (
        "passed"
        if ui003_passed
        else (
            "partial"
            if ui003_evidence.get("terminalCountObserved") is True
            and ui003_evidence.get("terminalReadBudgetPassed") is True
            else "failed"
        )
    )

    ui002 = claims.get("UI-NATIVE-002")
    if not isinstance(ui002, dict) or not isinstance(ui002.get("evidence"), dict):
        raise ValueError("report is missing UI-NATIVE-002 evidence")
    previous_ui002_evidence = ui002["evidence"]
    ui002_evidence = summarize_soak_evidence(
        claim_requested=arguments.get("claimSoak") is True,
        duration_seconds=float(arguments.get("durationSeconds") or 0.0),
        survived_duration=previous_ui002_evidence.get("survivedDuration") is True,
        final_ready=previous_ui002_evidence.get("finalReady") is True,
        window_survived=previous_ui002_evidence.get("windowSurvived") is True,
        unexpected_exit=previous_ui002_evidence.get("unexpectedExit"),
        process_summary=process_summary,
        metrics_summary=report.get("metricsSummary", {}),
        final_frame=report.get("finalFrame", {}),
    )
    if "nativeRuntimeDiagnostics" in previous_ui002_evidence:
        ui002_evidence["nativeRuntimeDiagnostics"] = previous_ui002_evidence[
            "nativeRuntimeDiagnostics"
        ]
    ui002["status"] = ui002_evidence["status"]
    ui002["evidence"] = ui002_evidence
    if ui003_passed and isinstance(ui002.get("limitations"), list):
        ui002["limitations"] = [
            limitation
            for limitation in ui002["limitations"]
            if "UI-NATIVE-003 CPU budget failure" not in str(limitation)
        ]

    required_claims = ["UI-NATIVE-001", "UI-NATIVE-003", "UI-NATIVE-005"]
    if arguments.get("claimSoak") is True:
        required_claims.append("UI-NATIVE-002")
    if int(arguments.get("terminalCount") or 0) == 1:
        required_claims.append("UI-NATIVE-004")
    termination = process.get("termination", {})
    cleanup_passed = not (
        isinstance(termination, dict)
        and (termination.get("forced") is True or bool(termination.get("remainingPids")))
    )
    report["status"] = (
        "passed"
        if cleanup_passed
        and all(
            isinstance(claims.get(claim_id), dict)
            and claims[claim_id].get("status") == "passed"
            for claim_id in required_claims
        )
        else "failed"
    )
    report["reconciliation"] = {
        "source": "retained raw process samples",
        "rssBaselinePolicy": "first steady-state process-tree sample",
        "requiredClaims": required_claims,
    }
    return report


def summarize_top_threads_by_cpu(processes: list[dict[str, Any]], limit: int = 12) -> list[dict[str, Any]]:
    threads: list[dict[str, Any]] = []
    for process in processes:
        for thread in process.get("threads", []):
            mean_cpu = thread.get("meanCpuPercent")
            if not isinstance(mean_cpu, (int, float)) or not math.isfinite(mean_cpu):
                continue
            threads.append(
                {
                    "pid": process.get("pid"),
                    "tid": thread.get("tid"),
                    "name": thread.get("name", ""),
                    "processName": process.get("name", ""),
                    "processRole": process.get("role") or classify_process_role(process),
                    "meanCpuPercent": round(float(mean_cpu), 3),
                    "maxCpuPercent": thread.get("maxCpuPercent"),
                    "cpuSampleCount": thread.get("cpuSampleCount"),
                }
            )
    threads.sort(
        key=lambda item: (
            -float(item.get("meanCpuPercent") or 0.0),
            int(item.get("pid") or 0),
            int(item.get("tid") or 0),
        )
    )
    return threads[:limit]


def summarize_cpu_by_role(processes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_role: dict[str, dict[str, Any]] = {}
    for process in processes:
        role = str(process.get("role") or classify_process_role(process))
        summary = by_role.setdefault(
            role,
            {
                "role": role,
                "processCount": 0,
                "pids": [],
                "totalMeanCpuPercent": 0.0,
                "maxProcessMeanCpuPercent": None,
                "peakRssBytes": 0,
            },
        )
        summary["processCount"] += 1
        summary["pids"].append(process.get("pid"))
        mean_cpu = process.get("meanCpuPercent")
        if isinstance(mean_cpu, (int, float)) and math.isfinite(mean_cpu):
            summary["totalMeanCpuPercent"] += float(mean_cpu)
            max_process = summary["maxProcessMeanCpuPercent"]
            summary["maxProcessMeanCpuPercent"] = (
                round(float(mean_cpu), 3)
                if max_process is None
                else round(max(float(max_process), float(mean_cpu)), 3)
            )
        summary["peakRssBytes"] += int(process.get("peakRssBytes") or 0)
    results = []
    for summary in by_role.values():
        summary["pids"] = sorted(pid for pid in summary["pids"] if isinstance(pid, int))
        summary["totalMeanCpuPercent"] = round(summary["totalMeanCpuPercent"], 3)
        results.append(summary)
    results.sort(
        key=lambda item: (
            -float(item.get("totalMeanCpuPercent") or 0.0),
            str(item.get("role", "")),
        )
    )
    return results


def make_claim(status: str, scope: str, evidence: dict[str, Any], limitations: list[str]) -> dict[str, Any]:
    return {
        "status": status,
        "scope": scope,
        "evidence": evidence,
        "limitations": limitations,
    }


def extract_cef_profile_warning(stderr_text: str) -> dict[str, Any]:
    for line in stderr_text.splitlines():
        if CEF_PROFILE_WARNING_MARKER not in line:
            continue
        path_text = line.split(CEF_PROFILE_WARNING_MARKER, 1)[1].strip().strip("'\"`")
        return {
            "detected": True,
            "marker": CEF_PROFILE_WARNING_MARKER,
            "path": path_text or None,
            "line": line[-1000:],
        }
    return {
        "detected": False,
        "marker": CEF_PROFILE_WARNING_MARKER,
        "path": None,
        "line": None,
    }


def extract_native_runtime_diagnostics(stderr_text: str) -> dict[str, Any]:
    normalized = stderr_text.casefold()
    child_signal: int | None = None
    child_signal_line: str | None = None
    for line in stderr_text.splitlines():
        if CHILD_SIGNAL_MARKER not in line:
            continue
        signal_text = line.split(CHILD_SIGNAL_MARKER, 1)[1].strip().split(" ", 1)[0]
        try:
            child_signal = int(signal_text)
            child_signal_line = line[-1000:]
        except ValueError:
            child_signal_line = line[-1000:]
        break

    glx_bad_window = GLX_BAD_WINDOW_MARKER.casefold() in normalized
    mojo_widget_host_rejection = MOJO_WIDGET_HOST_REJECTION_MARKER.casefold() in normalized
    gtk_disable_setlocale_warning = GTK_DISABLE_SETLOCALE_WARNING_MARKER.casefold() in normalized
    detected = any(
        (
            glx_bad_window,
            mojo_widget_host_rejection,
            gtk_disable_setlocale_warning,
            child_signal is not None,
        )
    )
    likely_boundary = "none"
    if glx_bad_window and child_signal == 5:
        likely_boundary = "cef-glx-renderer-signal-5"
    elif glx_bad_window:
        likely_boundary = "cef-glx-window-error"
    elif child_signal is not None:
        likely_boundary = f"native-child-signal-{child_signal}"
    elif mojo_widget_host_rejection:
        likely_boundary = "cef-mojo-widget-rejection"
    elif gtk_disable_setlocale_warning:
        likely_boundary = "gtk-lifecycle-warning"

    return {
        "detected": detected,
        "glxBadWindowDetected": glx_bad_window,
        "mojoWidgetHostRejectionDetected": mojo_widget_host_rejection,
        "gtkDisableSetlocaleWarningDetected": gtk_disable_setlocale_warning,
        "childTerminationSignal": child_signal,
        "childTerminationLine": child_signal_line,
        "likelyFailureBoundary": likely_boundary,
    }


def path_access_diagnostic(path: Path) -> dict[str, Any]:
    try:
        exists = path.exists()
        is_dir = path.is_dir() if exists else False
        stat_result = path.stat() if exists else None
    except OSError as exc:
        return {
            "path": str(path),
            "exists": False,
            "error": str(exc),
        }
    return {
        "path": str(path),
        "exists": exists,
        "isDirectory": is_dir,
        "readable": os.access(path, os.R_OK),
        "writable": os.access(path, os.W_OK),
        "executable": os.access(path, os.X_OK),
        "mode": (oct(stat_result.st_mode & 0o777) if stat_result else None),
        "uid": (stat_result.st_uid if stat_result else None),
        "gid": (stat_result.st_gid if stat_result else None),
    }


def profile_path_diagnostics(path: Path, *, stop_at: Path | None = None) -> dict[str, Any]:
    resolved = path.resolve(strict=False)
    ancestors: list[dict[str, Any]] = []
    current = resolved.parent
    stop_resolved = stop_at.resolve(strict=False) if stop_at is not None else None
    for _ in range(8):
        ancestors.append(path_access_diagnostic(current))
        if stop_resolved is not None and current == stop_resolved:
            break
        if current == current.parent:
            break
        current = current.parent
    return {
        "target": path_access_diagnostic(resolved),
        "ancestors": ancestors,
    }


def profile_setup_diagnostics(
    leaf_dirs: list[Path],
    parent_dirs: list[Path],
    *,
    stop_at: Path,
    leaf_precreated: bool,
) -> dict[str, Any]:
    return {
        "leafPrecreatedByHarness": leaf_precreated,
        "leafDirectories": [str(path) for path in leaf_dirs],
        "parentDirectories": [str(path) for path in parent_dirs],
        "leafDiagnostics": [
            profile_path_diagnostics(path, stop_at=stop_at) for path in leaf_dirs
        ],
        "parentDiagnostics": [path_access_diagnostic(path) for path in parent_dirs],
    }


def tail(path: Path, limit: int = 6000) -> str:
    try:
        data = path.read_bytes()
    except OSError:
        return ""
    return data[-limit:].decode("utf-8", "replace")


def combine_console(stdout_path: Path, stderr_path: Path, output_path: Path) -> None:
    stdout = stdout_path.read_text(encoding="utf-8", errors="replace") if stdout_path.exists() else ""
    stderr = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
    write_text(output_path, f"===== launcher stdout =====\n{stdout}\n===== launcher stderr =====\n{stderr}")


def terminate_process_group(process: subprocess.Popen[bytes] | None, process_group: int | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "requested": False,
        "signal": None,
        "forced": False,
        "exitCode": process.poll() if process is not None else None,
        "remainingPids": [],
        "trackedPids": [],
    }
    if process is None or process_group is None:
        return result

    # PTY shells can create their own sessions and finish writing profile data
    # after the launcher exits. Retain their identities before they are orphaned.
    with ExitStack() as cleanup:
        owned_fds: dict[int, int] = {}
        for item in sample_process_tree(process.pid, None)["processes"]:
            pid = item["pid"]
            try:
                fd = os.pidfd_open(pid)
            except ProcessLookupError:
                continue
            cleanup.callback(os.close, fd)
            current = proc_stat(pid)
            if current is not None and current["startTimeTicks"] == item["startTimeTicks"]:
                owned_fds[pid] = fd
        result["trackedPids"] = sorted(owned_fds)

        def remaining_members() -> list[int]:
            exited = set(select.select(list(owned_fds.values()), [], [], 0)[0])
            return sorted(
                set(process_group_members(process_group))
                | {pid for pid, fd in owned_fds.items() if fd not in exited}
            )

        members = remaining_members()
        if process.poll() is None or members:
            result["requested"] = True
            result["signal"] = "SIGTERM"

            # Let the launcher save state and stop the backend before signalling
            # its group. Detached descendants get the same bounded exit grace.
            if process.poll() is None:
                try:
                    os.kill(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=ELECTROBUN_NATIVE_SHUTDOWN_WAIT_SECONDS)
                except subprocess.TimeoutExpired:
                    pass

            members = remaining_members()
            if process.poll() is not None and members:
                # Detached PTY/extension children can finish a short profile
                # write after the launcher exits. Let that natural teardown
                # complete before escalating to pidfd SIGTERM.
                detached_deadline = time.monotonic() + DETACHED_DESCENDANT_GRACE_SECONDS
                while members and time.monotonic() < detached_deadline:
                    time.sleep(0.05)
                    members = remaining_members()
            if process.poll() is None or members:
                try:
                    os.killpg(process_group, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                for fd in owned_fds.values():
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGTERM)
                    except ProcessLookupError:
                        pass

            deadline = time.monotonic() + (
                PROCESS_GROUP_TERM_TIMEOUT_SECONDS - ELECTROBUN_NATIVE_SHUTDOWN_WAIT_SECONDS
            )
            while time.monotonic() < deadline:
                members = remaining_members()
                if process.poll() is not None and not members:
                    break
                if process.poll() is None:
                    try:
                        process.wait(timeout=min(0.25, max(0.0, deadline - time.monotonic())))
                    except subprocess.TimeoutExpired:
                        pass
                else:
                    time.sleep(0.05)

        remaining = remaining_members()
        if process.poll() is None or remaining:
            result["forced"] = True
            result["signal"] = "SIGKILL"
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for fd in owned_fds.values():
                try:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                pass
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and remaining_members():
                time.sleep(0.05)
            remaining = remaining_members()

        result["remainingPids"] = remaining
        result["exitCode"] = process.poll()
        return result


def create_fixture(workspace: Path) -> dict[str, Any]:
    workspace.mkdir(parents=True, exist_ok=False)
    for relative in ("src", "nested/deep", "empty-folder", ".vscode", "extensions"):
        (workspace / relative).mkdir(parents=True)
    editor_original = "WIZP_UI_EDITOR_ORIGINAL\n"
    files = {
        "README.md": "# WIZP native UI fixture\n\nWIZP_UI_WORKSPACE_OK\n",
        "editor-lifecycle.txt": editor_original,
        "src/main.zig": 'const std = @import("std");\npub fn main() void { std.debug.print("fixture\\n", .{}); }\n',
        "nested/deep/long-path-fixture.txt": "WIZP_UI_LONG_PATH_OK\n",
        "nested/deep/unicode-文件.txt": "WIZP_UI_UNICODE_PATH_OK\n",
        "explorer-rename-delete.txt": "WIZP_UI_EXPLORER_LIFECYCLE_OK\n",
        "this-is-a-deliberately-long-editor-fixture-filename-for-tab-overflow.txt": "WIZP_UI_LONG_FILENAME_OK\n",
        "unicode.txt": "WIZP fixture: Olá, 世界, λ\n",
        "mixed-lines.txt": "unix\nwindows\r\nfinal\n",
        "search-alpha.txt": "Alpha one\nalpha two\nalphabet soup\nALPHA\n",
        "search-excluded.txt": "alpha excluded\n",
        "search-navigation.txt": "context before\nWIZP_UI_SEARCH_MARKER\ncontext after\n",
        "search-replace-one.txt": "replace-one replace-one\nreplace-one second\n",
        "search-replace-all-a.txt": "replace-all one\nreplace-all two\n",
        "search-replace-all-b.txt": "replace-all three\n",
        "scm-staged.txt": "WIZP_UI_SCM_STAGED_ORIGINAL\n",
        "scm-unstaged.txt": "WIZP_UI_SCM_UNSTAGED_ORIGINAL\n",
        "scm-discard.txt": "WIZP_UI_SCM_DISCARD_ORIGINAL\n",
        "scm-conflict.txt": "WIZP_UI_SCM_CONFLICT_BASE\n",
        "large-file.txt": "WIZP_UI_LARGE_FILE_LINE\n" * 4096,
        ".vscode/tasks.json": '{"version":"2.0.0","tasks":[]}\n',
        ".vscode/launch.json": json.dumps(
            {
                "version": "0.2.0",
                "configurations": [
                    {
                        "name": "Fixture Launch",
                        "type": "fixture",
                        "request": "launch",
                        "program": "src/main.zig",
                    },
                    {
                        "name": "Missing Adapter",
                        "type": "wizp-missing-debug-adapter",
                        "request": "launch",
                        "program": "src/main.zig",
                    },
                ],
            },
            indent=2,
        )
        + "\n",
        ".vscode/launch.invalid.json": "{ invalid launch fixture\n",
    }
    for relative, content in files.items():
        (workspace / relative).write_bytes(content.encode("utf-8"))

    extension_package = {
        "name": "ui-lifecycle",
        "publisher": "wizp-smoke",
        "displayName": "UI Lifecycle Extension",
        "version": "1.0.0",
        "engines": {"vscode": "*"},
        "main": "./extension.js",
        "activationEvents": ["onCommand:wizp.uiLifecycle.hello"],
        "contributes": {
            "commands": [
                {"command": "wizp.uiLifecycle.hello", "title": "Run Lifecycle Command"}
            ],
            "configuration": {
                "title": "UI Lifecycle",
                "properties": {
                    "wizpUiLifecycle.enabled": {
                        "type": "boolean",
                        "default": True,
                        "description": "Enable the local extension lifecycle fixture.",
                    }
                },
            },
            "viewsContainers": {
                "activitybar": [
                    {"id": "wizp-ui-lifecycle", "title": "UI Lifecycle", "icon": "extensions"}
                ]
            },
            "views": {
                "wizp-ui-lifecycle": [
                    {"id": "wizp.uiLifecycle.view", "name": "Lifecycle View"}
                ]
            },
            "viewsWelcome": [
                {
                    "view": "wizp.uiLifecycle.view",
                    "contents": "The local lifecycle extension is ready.",
                }
            ],
        },
    }
    extension_js = """
const vscode = require('vscode');
exports.activate = function(context) {
  context.subscriptions.push(vscode.commands.registerCommand('wizp.uiLifecycle.hello', () => ({ message: 'lifecycle-command-ok' })));
};
exports.deactivate = function() {};
""".strip()
    valid_vsix = workspace / "extensions" / "ui-lifecycle.vsix"
    invalid_vsix = workspace / "extensions" / "invalid-lifecycle.vsix"
    with zipfile.ZipFile(valid_vsix, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("extension/package.json", json.dumps(extension_package))
        archive.writestr("extension/extension.js", extension_js)
    invalid_vsix.write_text("not a zip", encoding="utf-8")

    git = ["git", "-C", str(workspace)]
    subprocess.run([*git, "init"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([*git, "config", "user.email", "wizp@example.test"], check=True)
    subprocess.run([*git, "config", "user.name", "WIZP Native Fixture"], check=True)
    subprocess.run([*git, "add", "."], check=True)
    subprocess.run([*git, "commit", "-m", "fixture initial"], check=True, stdout=subprocess.DEVNULL)
    default_branch = subprocess.check_output([*git, "branch", "--show-current"], text=True).strip()
    subprocess.run([*git, "checkout", "-b", "fixture-conflict"], check=True, stdout=subprocess.DEVNULL)
    (workspace / "scm-conflict.txt").write_text("WIZP_UI_SCM_CONFLICT_INCOMING\n", encoding="utf-8")
    subprocess.run([*git, "add", "scm-conflict.txt"], check=True)
    subprocess.run([*git, "commit", "-m", "fixture incoming conflict"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([*git, "checkout", default_branch], check=True, stdout=subprocess.DEVNULL)
    (workspace / "scm-conflict.txt").write_text("WIZP_UI_SCM_CONFLICT_CURRENT\n", encoding="utf-8")
    subprocess.run([*git, "add", "scm-conflict.txt"], check=True)
    subprocess.run([*git, "commit", "-m", "fixture current conflict"], check=True, stdout=subprocess.DEVNULL)
    merge = subprocess.run(
        [*git, "merge", "fixture-conflict"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if merge.returncode == 0:
        raise RuntimeError("native SCM fixture did not create the expected conflict")
    (workspace / "scm-staged.txt").write_text("WIZP_UI_SCM_STAGED_CHANGED\n", encoding="utf-8")
    subprocess.run([*git, "add", "scm-staged.txt"], check=True)
    (workspace / "scm-unstaged.txt").write_text("WIZP_UI_SCM_UNSTAGED_CHANGED\n", encoding="utf-8")
    (workspace / "scm-discard.txt").write_text("WIZP_UI_SCM_DISCARD_CHANGED\n", encoding="utf-8")
    (workspace / "scm-untracked.txt").write_text("WIZP_UI_SCM_UNTRACKED\n", encoding="utf-8")

    return {
        "path": str(workspace),
        "externalToPackagedResources": not contains_resources_app(workspace),
        "files": sorted([*files, "extensions/ui-lifecycle.vsix", "extensions/invalid-lifecycle.vsix"]),
        "marker": "WIZP_UI_WORKSPACE_OK",
        "editorLifecycle": {
            "path": "editor-lifecycle.txt",
            "originalContent": editor_original,
            "dirtyContent": "WIZP_UI_EDITOR_DIRTY\n",
            "savedContent": "WIZP_UI_EDITOR_SAVED\n",
            "untitledContent": "WIZP_UI_UNTITLED_SAVED\n",
        },
        "explorerLifecycle": {
            "emptyFolder": "empty-folder",
            "renameDeletePath": "explorer-rename-delete.txt",
            "createdFolder": "created-folder",
            "createdFile": "created-file.txt",
        },
        "searchLifecycle": {
            "query": "alpha",
            "include": "search-*.txt",
            "exclude": "search-excluded.txt",
            "navigationPath": "search-navigation.txt",
            "navigationMarker": "WIZP_UI_SEARCH_MARKER",
            "replaceOnePath": "search-replace-one.txt",
            "replaceAllPaths": ["search-replace-all-a.txt", "search-replace-all-b.txt"],
        },
        "scmLifecycle": {
            "defaultBranch": default_branch,
            "alternateBranch": "fixture-conflict",
            "stagedPath": "scm-staged.txt",
            "unstagedPath": "scm-unstaged.txt",
            "discardPath": "scm-discard.txt",
            "untrackedPath": "scm-untracked.txt",
            "conflictPath": "scm-conflict.txt",
            "historySubjects": ["fixture initial", "fixture incoming conflict", "fixture current conflict"],
        },
        "debugLifecycle": {
            "launchPath": ".vscode/launch.json",
            "invalidLaunchPath": ".vscode/launch.invalid.json",
            "validConfiguration": "Fixture Launch",
            "failingConfiguration": "Missing Adapter",
            "breakpointPath": "src/main.zig",
            "breakpointLine": 2,
            "evaluateExpression": "answer",
            "evaluateResult": "42",
        },
        "extensionLifecycle": {
            "validVsixPath": "extensions/ui-lifecycle.vsix",
            "invalidVsixPath": "extensions/invalid-lifecycle.vsix",
            "id": "wizp-smoke.ui-lifecycle",
            "displayName": "UI Lifecycle Extension",
            "command": "wizp.uiLifecycle.hello",
            "commandTitle": "Run Lifecycle Command",
            "viewContainer": "wizp-ui-lifecycle",
            "viewTitle": "UI Lifecycle",
            "setting": "wizpUiLifecycle.enabled",
        },
        "settingsLifecycle": {
            "openShortcut": "ctrl+comma",
            "changedSetting": "files.autoSave",
            "changedValue": "afterDelay",
            "cancelPreservesSavedValue": True,
            "escapeCloses": True,
            "partialSyncFailure": "browser-fixture-required",
        },
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the Linux packaged-native WIZP baseline and retain granular evidence."
    )
    parser.add_argument("--duration", type=float, default=60.0, help="ready-state survival duration in seconds (default: 60)")
    parser.add_argument("--binary", default=str(DEFAULT_BINARY), help="Electrobun launcher path")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT), help="evidence output directory")
    parser.add_argument("--port", type=int, default=23876, help="WIZP backend HTTP port")
    parser.add_argument("--control-port", type=int, default=24876, help="Electrobun window-control port")
    parser.add_argument(
        "--terminal-count",
        type=int,
        default=1,
        help="visible terminal panes to mount in native-smoke mode; valid range 1-8 (default: 1)",
    )
    parser.add_argument(
        "--claim-soak",
        action="store_true",
        help="claim UI-NATIVE-002; requires --duration of at least 1800 seconds",
    )
    args = parser.parse_args(argv)
    if not math.isfinite(args.duration) or args.duration < 1.0:
        parser.error("--duration must be a finite value of at least 1 second")
    if args.claim_soak and args.duration < SOAK_DURATION_SECONDS:
        parser.error("--claim-soak requires --duration of at least 1800 seconds")
    if args.terminal_count < MIN_TERMINAL_COUNT or args.terminal_count > MAX_TERMINAL_COUNT:
        parser.error(
            f"--terminal-count must be between {MIN_TERMINAL_COUNT} and {MAX_TERMINAL_COUNT}"
        )
    return args


def run(args: argparse.Namespace) -> int:
    started_at = utc_now()
    started_monotonic = time.monotonic()
    binary = resolve_cli_path(args.binary, base=Path.cwd())
    output_dir = resolve_cli_path(args.output_dir, base=Path.cwd())
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"

    report_path = output_dir / "report.json"
    stdout_path = output_dir / f"{run_id}-launcher.stdout.log"
    stderr_path = output_dir / f"{run_id}-launcher.stderr.log"
    console_path = output_dir / f"{run_id}-console.log"
    metrics_path = output_dir / f"{run_id}-metrics.json"
    process_path = output_dir / f"{run_id}-process-samples.json"
    workspace_path = output_dir / f"{run_id}-workspace.json"
    terminal_list_path = output_dir / f"{run_id}-terminal-list.json"
    window_path = output_dir / f"{run_id}-window.json"
    screenshot_path = output_dir / f"{run_id}-native-window.png"
    ocr_path = output_dir / f"{run_id}-terminal-ocr.txt"
    tesseract_stderr_path = output_dir / f"{run_id}-tesseract.stderr.log"
    prompt_screenshot_path = output_dir / f"{run_id}-prompt.png"
    prompt_ocr_path = output_dir / f"{run_id}-prompt-ocr.txt"
    prompt_tesseract_stderr_path = output_dir / f"{run_id}-prompt-tesseract.stderr.log"
    ui_screenshot_path = output_dir / f"{run_id}-ui-ready.png"
    ui_ocr_path = output_dir / f"{run_id}-ui-ready-ocr.txt"
    ui_tesseract_stderr_path = output_dir / f"{run_id}-ui-ready-tesseract.stderr.log"
    final_frame_screenshot_path = output_dir / f"{run_id}-final-frame.png"
    final_frame_ocr_path = output_dir / f"{run_id}-final-frame-ocr.txt"
    final_frame_tesseract_stderr_path = output_dir / f"{run_id}-final-frame-tesseract.stderr.log"
    fixture_manifest_path = output_dir / f"{run_id}-fixture-manifest.json"
    command_path = output_dir / f"{run_id}-terminal-command.txt"
    profile_dir = output_dir / f"{run_id}-isolated-profile"
    workspace_dir = output_dir / f"{run_id}-workspace-fixture"

    report: dict[str, Any] = {
        "schema": 1,
        "kind": "wizp-linux-packaged-native-baseline",
        "runId": run_id,
        "status": "failed",
        "startedAt": started_at,
        "finishedAt": None,
        "arguments": {
            "durationSeconds": args.duration,
            "binary": str(binary),
            "outputDir": str(output_dir),
            "port": args.port,
            "controlPort": args.control_port,
            "terminalCount": args.terminal_count,
            "claimSoak": args.claim_soak,
        },
        "scope": {
            "platform": "linux-x11",
            "packagedNative": True,
            "terminalCountsPlanned": [args.terminal_count],
            "notClaimed": [
                "Other UI-NATIVE-003 terminal-count matrix entries not run by this invocation",
                "macOS or Windows behavior",
                "manual assistive-technology sign-off",
            ],
        },
        "evidenceFiles": {
            "console": console_path.name,
            "fixture": fixture_manifest_path.name,
            "metrics": metrics_path.name,
            "ocr": ocr_path.name,
            "promptOcr": prompt_ocr_path.name,
            "promptScreenshot": prompt_screenshot_path.name,
            "processSamples": process_path.name,
            "screenshot": screenshot_path.name,
            "terminalList": terminal_list_path.name,
            "uiOcr": ui_ocr_path.name,
            "uiScreenshot": ui_screenshot_path.name,
            "finalFrameOcr": final_frame_ocr_path.name,
            "finalFrameScreenshot": final_frame_screenshot_path.name,
            "window": window_path.name,
            "workspace": workspace_path.name,
        },
        "errors": [],
        "claims": {},
    }
    if not args.claim_soak:
        report["scope"]["notClaimed"].insert(0, "UI-NATIVE-002 30-minute scheduled idle soak")
    errors: list[str] = report["errors"]
    metrics_samples: list[dict[str, Any]] = []
    process_samples: list[dict[str, Any]] = []
    window_lifecycle_samples: list[dict[str, Any]] = []
    window_lifecycle_summary: dict[str, Any] = summarize_window_lifecycle(
        [],
        duration_seconds=args.duration,
    )
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    stdout_handle: Any = None
    stderr_handle: Any = None
    unexpected_exit: int | None = None
    readiness: dict[str, Any] | None = None
    window: dict[str, Any] | None = None
    initial_workspace: Any = None
    terminal_list: Any = None
    terminal_evidence: dict[str, Any] = {"typed": False, "markerFoundByOcr": False}
    terminal_poll_telemetry: dict[str, Any] = {"available": False}
    ui_evidence: dict[str, Any] = {"visible": False}
    final_frame_evidence: dict[str, Any] = {"captured": False}
    final_ready = False
    window_survived = False
    survived_duration = False
    previous_process_sample: dict[str, Any] | None = None
    cef_profile_dirs: list[Path] = []
    cef_profile_parent_dirs: list[Path] = []
    cef_profile_leaf_precreated = False

    try:
        if sys.platform != "linux":
            raise SmokeFailure(f"this packaged-native driver requires Linux; found {sys.platform}")
        display = os.environ.get("DISPLAY", "").strip()
        if not display or os.environ.get("WIZP_VIRTUAL_DISPLAY") != "1":
            raise SmokeFailure("isolated DISPLAY is not set; use scripts/run_virtual_ui_test.sh")
        if not binary.is_file():
            raise SmokeFailure(f"Electrobun launcher does not exist: {binary}")
        if not os.access(binary, os.X_OK):
            raise SmokeFailure(f"Electrobun launcher is not executable: {binary}")
        if contains_resources_app(output_dir):
            raise SmokeFailure("--output-dir must be outside packaged Resources/app")
        validate_port(args.port, "--port")
        validate_port(args.control_port, "--control-port")
        if args.port == args.control_port:
            raise SmokeFailure("--port and --control-port must be different")
        require_unused_port(args.port, "backend port")
        require_unused_port(args.control_port, "control port")

        xdotool = require_tool("xdotool")
        import_tool = require_tool("import")
        tesseract = require_tool("tesseract")
        tesseract_language = select_tesseract_language(tesseract)
        run_tool([xdotool, "getdisplaygeometry"], timeout=5.0)

        preexisting_windows = xdotool_window_ids(xdotool)
        profile_dir.mkdir(parents=True, exist_ok=False)
        for name in ("cache", "config", "data", "state", "runtime"):
            (profile_dir / name).mkdir()
        cef_profile_dirs = [
            profile_dir / "cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
            profile_dir / ".cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
        ]
        cef_profile_parent_dirs = [path.parent for path in cef_profile_dirs]
        for cef_profile_parent_dir in cef_profile_parent_dirs:
            cef_profile_parent_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(profile_dir / "runtime", 0o700)
        write_deterministic_shell_profile(profile_dir)
        fixture_manifest = create_fixture(workspace_dir)
        write_json(fixture_manifest_path, fixture_manifest)
        write_text(command_path, TERMINAL_COMMAND + "\n")

        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(profile_dir),
                "XDG_CACHE_HOME": str(profile_dir / "cache"),
                "XDG_CONFIG_HOME": str(profile_dir / "config"),
                "XDG_DATA_HOME": str(profile_dir / "data"),
                "XDG_STATE_HOME": str(profile_dir / "state"),
                "XDG_RUNTIME_DIR": str(profile_dir / "runtime"),
                "WIZP_PORT": str(args.port),
                "WIZP_CONTROL_PORT": str(args.control_port),
                "WIZP_HTTP_WORKERS": "4",
                "WIZP_NATIVE_UI_SMOKE": "1",
                "WIZP_NATIVE_UI_SMOKE_TERMINALS": str(args.terminal_count),
            }
        )
        report["environment"] = {
            "display": display,
            "home": str(profile_dir),
            "cefProfileDirectories": [str(path) for path in cef_profile_dirs],
            "cefProfileParentDirectories": [str(path) for path in cef_profile_parent_dirs],
            "cefProfileLeafPrecreated": cef_profile_leaf_precreated,
            "launcherWorkingDirectory": str(workspace_dir),
            "xdgIsolated": True,
            "tesseractLanguage": tesseract_language,
        }

        stdout_handle = stdout_path.open("wb")
        stderr_handle = stderr_path.open("wb")
        try:
            process = subprocess.Popen(
                [str(binary)],
                cwd=workspace_dir,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=stdout_handle,
                stderr=stderr_handle,
                start_new_session=True,
            )
        except OSError as exc:
            raise SmokeFailure(f"could not launch Electrobun binary {binary}: {exc}") from exc
        try:
            process_group = os.getpgid(process.pid)
        except ProcessLookupError as exc:
            raise SmokeFailure(
                f"Electrobun launcher exited immediately (exit {process.poll()})"
            ) from exc
        report["process"] = {
            "launcherPid": process.pid,
            "processGroup": process_group,
            "isolatedProcessGroup": process_group == process.pid,
        }
        if process_group != process.pid:
            raise SmokeFailure(
                f"launcher process group was not isolated: pid={process.pid}, pgrp={process_group}"
            )
        previous_process_sample = sample_process_tree(process.pid, None)
        previous_process_sample["phase"] = "launch"
        process_samples.append(previous_process_sample)

        readiness = wait_for_ready(args.port, process)
        readiness["readyAt"] = utc_now()
        ready_monotonic = time.monotonic()
        report["readiness"] = readiness

        rpc = RpcClient(args.port)
        window = wait_for_new_window(xdotool, preexisting_windows, process_group, process)
        activate_window(xdotool, window)
        window_lifecycle_samples.append(
            probe_window_lifecycle(
                xdotool,
                window["id"],
                phase="activated",
                ready_monotonic=ready_monotonic,
            )
        )
        write_json(window_path, window)

        ui_evidence = wait_for_visible_ui(
            import_tool,
            tesseract,
            tesseract_language,
            window["id"],
            ui_screenshot_path,
            ui_ocr_path,
            ui_tesseract_stderr_path,
        )
        report["uiSurface"] = ui_evidence

        try:
            initial_workspace = rpc.call("workspace/getFolders")
        except SmokeFailure as exc:
            errors.append(str(exc))
        write_json(
            workspace_path,
            {
                "launcherWorkingDirectory": str(workspace_dir),
                "initialWorkspaceGetFolders": initial_workspace,
                "initialContainsPackagedResourcesApp": workspace_has_packaged_path(
                    initial_workspace
                ),
            },
        )

        try:
            terminal_list = wait_for_terminals(rpc, expected_count=args.terminal_count)
        except SmokeFailure as exc:
            errors.append(str(exc))
        write_json(terminal_list_path, {"afterReady": terminal_list})

        prompt_observed_started = time.monotonic()
        try:
            prompt_ocr = ""
            prompt_elapsed = 0.0
            prompt_attempts = 0
            prompt_found = False
            while True:
                prompt_attempts += 1
                capture_window(import_tool, window["id"], prompt_screenshot_path)
                prompt_elapsed = time.monotonic() - prompt_observed_started
                prompt_ocr = ocr_screenshot(
                    tesseract,
                    prompt_screenshot_path,
                    prompt_tesseract_stderr_path,
                    tesseract_language,
                )
                prompt_found = ocr_contains_marker(prompt_ocr, PROMPT_MARKER)
                if (
                    prompt_found
                    or time.monotonic() - prompt_observed_started
                    >= PROMPT_RENDER_BUDGET_SECONDS
                ):
                    break
                time.sleep(0.05)
            write_text(prompt_ocr_path, prompt_ocr)
            terminal_evidence.update(
                {
                    "promptMarker": PROMPT_MARKER,
                    "promptFoundByOcr": prompt_found,
                    "promptRenderBudgetSeconds": PROMPT_RENDER_BUDGET_SECONDS,
                    "promptObservedElapsedSeconds": round(prompt_elapsed, 3),
                    "promptCaptureAttempts": prompt_attempts,
                    "promptWithinBudget": (
                        prompt_found and prompt_elapsed <= PROMPT_RENDER_BUDGET_SECONDS
                    ),
                    "promptOcrTextFile": prompt_ocr_path.name,
                    "promptScreenshotFile": prompt_screenshot_path.name,
                }
            )
            if not terminal_evidence["promptWithinBudget"]:
                errors.append(
                    f"deterministic prompt was not visibly captured within "
                    f"{PROMPT_RENDER_BUDGET_SECONDS:.1f}s of observing the terminal"
                )
        except SmokeFailure as exc:
            errors.append(str(exc))
            terminal_evidence["promptFoundByOcr"] = False
            terminal_evidence["promptWithinBudget"] = False
            if not prompt_ocr_path.exists():
                write_text(prompt_ocr_path, "")

        try:
            metrics_samples.append(
                {
                    "timestamp": utc_now(),
                    "monotonicSeconds": time.monotonic(),
                    "phase": "pre-interaction",
                    "ok": True,
                    "metrics": read_metrics(args.port),
                }
            )
        except SmokeFailure as exc:
            errors.append(str(exc))
            metrics_samples.append(
                {
                    "timestamp": utc_now(),
                    "monotonicSeconds": time.monotonic(),
                    "phase": "pre-interaction",
                    "ok": False,
                    "error": str(exc),
                }
            )

        if args.terminal_count == 1:
            try:
                terminal_evidence.update(focus_terminal_and_type(xdotool, window))
                time.sleep(2.0)
                ocr = capture_and_ocr(
                    import_tool,
                    tesseract,
                    window["id"],
                    screenshot_path,
                    tesseract_stderr_path,
                    tesseract_language,
                )
                write_text(ocr_path, ocr)
                terminal_evidence["markerFoundByOcr"] = ocr_contains_marker(ocr, TERMINAL_MARKER)
                terminal_evidence["shellErrorFoundByOcr"] = ocr_contains_shell_error(ocr)
                terminal_evidence["markerOutputFoundByOcr"] = (
                    terminal_evidence["markerFoundByOcr"]
                    and not terminal_evidence["shellErrorFoundByOcr"]
                )
                normalized_ocr = " ".join(ocr.casefold().split())
                terminal_evidence["workspaceEmptyStateFoundByOcr"] = (
                    "no folder open" in normalized_ocr or "open folder" in normalized_ocr
                )
                terminal_evidence["ocrTextFile"] = ocr_path.name
                terminal_evidence["screenshotFile"] = screenshot_path.name
                if not terminal_evidence["markerFoundByOcr"]:
                    errors.append(
                        f"OCR did not find {TERMINAL_MARKER!r} in the native WIZP window screenshot"
                    )
                if terminal_evidence["shellErrorFoundByOcr"]:
                    errors.append(
                        "OCR found shell error text in the native terminal marker screenshot"
                    )
                if not terminal_evidence["workspaceEmptyStateFoundByOcr"]:
                    errors.append(
                        "OCR did not find the clean first-run No Folder Open/Open Folder state "
                        "in the native WIZP window screenshot"
                    )
            except SmokeFailure as exc:
                errors.append(str(exc))
                if not ocr_path.exists():
                    write_text(ocr_path, "")
        else:
            terminal_evidence.update(
                {
                    "typed": False,
                    "markerFoundByOcr": False,
                    "typingSkipped": True,
                    "typingSkippedReason": (
                        "multi-terminal idle matrix run; UI-NATIVE-004 typed-marker proof "
                        "is retained by the one-terminal baseline"
                    ),
                    "workspaceEmptyStateFoundByOcr": ui_evidence.get(
                        "workspaceEmptyStateFoundByOcr"
                    )
                    is True,
                }
            )
            write_text(ocr_path, "")

        previous_process_sample = sample_process_tree(process.pid, None)
        previous_process_sample["phase"] = "steady-baseline"
        process_samples.append(previous_process_sample)
        try:
            metrics_samples.append(
                {
                    "timestamp": utc_now(),
                    "monotonicSeconds": time.monotonic(),
                    "phase": "steady-baseline",
                    "ok": True,
                    "metrics": read_metrics(args.port),
                }
            )
        except SmokeFailure as exc:
            errors.append(str(exc))
            metrics_samples.append(
                {
                    "timestamp": utc_now(),
                    "monotonicSeconds": time.monotonic(),
                    "phase": "steady-baseline",
                    "ok": False,
                    "error": str(exc),
                }
            )

        next_sample = time.monotonic() + SAMPLE_INTERVAL_SECONDS
        survival_deadline = ready_monotonic + args.duration
        while time.monotonic() < survival_deadline:
            if process.poll() is not None:
                unexpected_exit = process.returncode
                errors.append(
                    f"launcher exited before the {args.duration:.1f}s survival deadline "
                    f"(exit {unexpected_exit})"
                )
                break
            now = time.monotonic()
            if now >= next_sample:
                process_sample = sample_process_tree(process.pid, previous_process_sample)
                process_sample["phase"] = "steady"
                process_samples.append(process_sample)
                previous_process_sample = process_sample
                try:
                    metric_payload = read_metrics(args.port)
                    metrics_samples.append(
                        {
                            "timestamp": utc_now(),
                            "monotonicSeconds": time.monotonic(),
                            "phase": "steady",
                            "ok": True,
                            "metrics": metric_payload,
                        }
                    )
                except SmokeFailure as exc:
                    metrics_samples.append(
                        {
                            "timestamp": utc_now(),
                            "monotonicSeconds": time.monotonic(),
                            "phase": "steady",
                            "ok": False,
                            "error": str(exc),
                        }
                    )
                    if str(exc) not in errors:
                        errors.append(str(exc))
                window_probe = probe_window_lifecycle(
                    xdotool,
                    window["id"],
                    phase="steady",
                    ready_monotonic=ready_monotonic,
                )
                window_lifecycle_samples.append(window_probe)
                if window_probe.get("present") is not True:
                    errors.append(
                        "native WIZP window disappeared during survival loop "
                        f"at {window_probe['elapsedSeconds']:.3f}s: "
                        f"{window_probe.get('error') or window_probe.get('name') or 'window not present'}"
                    )
                    break
                next_sample = now + SAMPLE_INTERVAL_SECONDS
            time.sleep(min(0.1, max(0.0, survival_deadline - time.monotonic())))
        else:
            survived_duration = process.poll() is None

        if process.poll() is None:
            try:
                status, _ = http_get(args.port, "/__wizp_ready", timeout=1.0)
                final_ready = status == 204
                if not final_ready:
                    errors.append(f"final /__wizp_ready probe returned HTTP {status}")
            except (OSError, urllib.error.URLError) as exc:
                errors.append(f"final /__wizp_ready probe failed: {exc}")
            final_window_probe = probe_window_lifecycle(
                xdotool,
                window["id"],
                phase="final",
                ready_monotonic=ready_monotonic,
            )
            window_lifecycle_samples.append(final_window_probe)
            window_lifecycle_summary = summarize_window_lifecycle(
                window_lifecycle_samples,
                duration_seconds=args.duration,
            )
            window_survived = window_lifecycle_summary["survivedWindow"]
            if isinstance(final_window_probe.get("name"), str):
                window["finalName"] = final_window_probe["name"]
            if not window_survived:
                loss = window_lifecycle_summary.get("firstLoss") or final_window_probe
                message = (
                    "native WIZP window disappeared"
                    f" at {loss['elapsedSeconds']:.3f}s during {loss['phase']}: "
                    f"{loss.get('error') or loss.get('name') or 'window not present'}"
                )
                if message not in errors:
                    errors.append(message)
            if window_survived:
                try:
                    final_frame_ocr = capture_and_ocr(
                        import_tool,
                        tesseract,
                        window["id"],
                        final_frame_screenshot_path,
                        final_frame_tesseract_stderr_path,
                        tesseract_language,
                    )
                    write_text(final_frame_ocr_path, final_frame_ocr)
                    normalized_final_frame = " ".join(final_frame_ocr.casefold().split())
                    final_frame_evidence = {
                        "captured": True,
                        "screenshotFile": final_frame_screenshot_path.name,
                        "ocrTextFile": final_frame_ocr_path.name,
                        "workspaceEmptyStateFoundByOcr": (
                            "no folder open" in normalized_final_frame
                            or "open folder" in normalized_final_frame
                        ),
                        "markerFoundByOcr": ocr_contains_marker(final_frame_ocr, TERMINAL_MARKER),
                        "shellErrorFoundByOcr": ocr_contains_shell_error(final_frame_ocr),
                    }
                except SmokeFailure as exc:
                    final_frame_evidence = {
                        "captured": False,
                        "error": str(exc),
                        "screenshotFile": final_frame_screenshot_path.name,
                        "ocrTextFile": final_frame_ocr_path.name,
                    }
                    if args.claim_soak:
                        errors.append(
                            f"final-frame capture failed during UI-NATIVE-002 soak: {exc}"
                        )
                    if not final_frame_ocr_path.exists():
                        write_text(final_frame_ocr_path, "")
            else:
                final_frame_evidence = {
                    "captured": False,
                    "screenshotFile": final_frame_screenshot_path.name,
                    "ocrTextFile": final_frame_ocr_path.name,
                    "skippedReason": "window was not available at final probe",
                }
                if not final_frame_ocr_path.exists():
                    write_text(final_frame_ocr_path, "")
        if window is not None:
            window_lifecycle_summary = summarize_window_lifecycle(
                window_lifecycle_samples,
                duration_seconds=args.duration,
            )
            window["survived"] = window_survived
            window["lifecycle"] = window_lifecycle_summary
            write_json(window_path, window)
            report["window"] = window
        report["windowLifecycle"] = window_lifecycle_summary

        try:
            final_workspace = rpc.call("workspace/getFolders") if process.poll() is None else None
        except SmokeFailure as exc:
            final_workspace = None
            errors.append(str(exc))
        workspace_evidence = {
            "launcherWorkingDirectory": str(workspace_dir),
            "initialWorkspaceGetFolders": initial_workspace,
            "finalWorkspaceGetFolders": final_workspace,
            "initialContainsPackagedResourcesApp": workspace_has_packaged_path(
                initial_workspace
            ),
            "finalContainsPackagedResourcesApp": workspace_has_packaged_path(final_workspace),
            "visibleEmptyStateFoundByOcr": terminal_evidence.get(
                "workspaceEmptyStateFoundByOcr"
            )
            is True
            or ui_evidence.get("workspaceEmptyStateFoundByOcr") is True,
        }
        write_json(workspace_path, workspace_evidence)

        try:
            final_terminal_list = rpc.call("terminal/list") if process.poll() is None else None
        except SmokeFailure as exc:
            final_terminal_list = None
            errors.append(str(exc))
        write_json(
            terminal_list_path,
            {"afterReady": terminal_list, "afterSurvival": final_terminal_list},
        )
        try:
            terminal_poll_telemetry = read_native_terminal_telemetry(args.control_port)
            terminal_poll_telemetry["available"] = True
        except SmokeFailure as exc:
            terminal_poll_telemetry = {
                "available": False,
                "error": str(exc),
            }

        metrics_summary = summarize_metrics(metrics_samples, args.terminal_count)
        process_summary = summarize_processes(process_samples, process.pid)
        report["metricsSummary"] = metrics_summary
        report["processSummary"] = process_summary
        report["terminalPollTelemetry"] = terminal_poll_telemetry
        report["terminal"] = terminal_evidence
        report["workspace"] = workspace_evidence
        report["finalFrame"] = final_frame_evidence

        terminal_count = None
        if isinstance(terminal_list, dict) and isinstance(terminal_list.get("terminals"), list):
            terminal_count = len(terminal_list["terminals"])
        final_terminal_count = None
        if isinstance(final_terminal_list, dict) and isinstance(
            final_terminal_list.get("terminals"), list
        ):
            final_terminal_count = len(final_terminal_list["terminals"])
        report["scope"]["terminalCountsObserved"] = (
            sorted(
                {
                    count
                    for count in (terminal_count, final_terminal_count)
                    if isinstance(count, int)
                }
            )
        )
        initial_workspace_folders = (
            initial_workspace.get("folders", [])
            if isinstance(initial_workspace, dict)
            else None
        )
        final_workspace_folders = (
            final_workspace.get("folders", [])
            if isinstance(final_workspace, dict)
            else None
        )
        workspace_passed = (
            initial_workspace_folders == []
            and final_workspace_folders == []
            and not workspace_evidence["initialContainsPackagedResourcesApp"]
            and not workspace_evidence["finalContainsPackagedResourcesApp"]
            and workspace_evidence["visibleEmptyStateFoundByOcr"]
        )
        ui001_passed = survived_duration and final_ready and window_survived and unexpected_exit is None
        ui003_count_observed = (
            terminal_count == args.terminal_count
            and final_terminal_count == args.terminal_count
        )
        ui003_read_budget_passed = metrics_summary.get("terminalReadBudgetPassed") is True
        ui003_cpu_budget_passed = process_summary.get("mainProcessCpuBudgetPassed") is True
        ui003_passed = ui003_count_observed and ui003_read_budget_passed and ui003_cpu_budget_passed
        ui003_status = (
            "passed"
            if ui003_passed
            else (
                "partial"
                if ui003_count_observed and ui003_read_budget_passed
                else "failed"
            )
        )
        ui004_passed = (
            args.terminal_count == 1
            and
            terminal_evidence.get("promptWithinBudget") is True
            and terminal_evidence.get("markerOutputFoundByOcr") is True
        )
        ui004_status = (
            "passed"
            if ui004_passed
            else ("unverified" if args.terminal_count != 1 else "failed")
        )
        ui002_evidence = summarize_soak_evidence(
            claim_requested=args.claim_soak,
            duration_seconds=args.duration,
            survived_duration=survived_duration,
            final_ready=final_ready,
            window_survived=window_survived,
            unexpected_exit=unexpected_exit,
            process_summary=process_summary,
            metrics_summary=metrics_summary,
            final_frame=final_frame_evidence,
        )

        report["claims"] = {
            "UI-NATIVE-001": make_claim(
                "passed" if ui001_passed else "failed",
                f"one Linux packaged-native launch remained ready with its X11 window present for {args.duration:.1f}s",
                {
                    "survivedDuration": survived_duration,
                    "finalReady": final_ready,
                    "windowSurvived": window_survived,
                    "unexpectedExit": unexpected_exit,
                    "durationSeconds": args.duration,
                    "windowLifecycle": window_lifecycle_summary,
                },
                (
                    []
                    if args.claim_soak
                    else ["This is not the UI-NATIVE-002 30-minute scheduled soak."]
                ),
            ),
            "UI-NATIVE-002": make_claim(
                str(ui002_evidence["status"]),
                "scheduled idle soak survival with retained CPU, memory, RPC-rate, child-process, and final-frame artifacts",
                ui002_evidence,
                [
                    "This row is only claimable when --claim-soak is used with at least 1800 seconds.",
                    "UI-NATIVE-002 does not waive the separate UI-NATIVE-003 CPU budget failure.",
                ],
            ),
            "UI-NATIVE-003": make_claim(
                ui003_status,
                f"{args.terminal_count} visible terminal pane(s); idle RPC counters and descendant CPU/RSS were sampled",
                {
                    "expectedTerminalCount": args.terminal_count,
                    "terminalCount": terminal_count,
                    "finalTerminalCount": final_terminal_count,
                    "terminalCountObserved": ui003_count_observed,
                    "terminalReadBudgetPassed": ui003_read_budget_passed,
                    "mainProcessCpuBudgetPassed": ui003_cpu_budget_passed,
                    "metrics": metrics_summary,
                    "processes": process_summary,
                },
                [
                    "The first-target budgets are 10 terminal reads/s/session and 5% mean packaged-main-process CPU.",
                    "This invocation covers only the requested terminal count; use separate retained runs for the 1/4/8 matrix.",
                ],
            ),
            "UI-NATIVE-004": make_claim(
                ui004_status,
                "a deterministic prompt rendered within two seconds, then the typed marker was checked by OCR in a native-window PNG",
                terminal_evidence,
                [
                    "No backend terminal/write injection was used.",
                    "Typed-marker proof is only required from the one-terminal native baseline run.",
                ],
            ),
            "UI-NATIVE-005": make_claim(
                "passed" if workspace_passed else "failed",
                "a clean isolated first run stayed folderless and exposed its visible Open Folder recovery state",
                workspace_evidence,
                [
                    "The launcher working directory was an external disposable fixture, but no workspace was injected.",
                    "This proves the isolated Linux packaged-native first-run path only.",
                ],
            ),
        }
        report["status"] = (
            "passed"
            if ui001_passed
            and (not args.claim_soak or ui002_evidence["status"] == "passed")
            and ui003_passed
            and (ui004_passed or args.terminal_count != 1)
            and workspace_passed
            else "failed"
        )
    except SmokeFailure as exc:
        errors.append(str(exc))
    except KeyboardInterrupt:
        errors.append("interrupted")
    except Exception as exc:  # Preserve evidence for unexpected harness defects.
        errors.append(f"unexpected driver failure: {type(exc).__name__}: {exc}")
    finally:
        termination = terminate_process_group(process, process_group)
        if termination.get("forced"):
            errors.append("launcher process group required SIGKILL during cleanup")
            report["status"] = "failed"
        if termination.get("remainingPids"):
            errors.append(
                f"process-group cleanup left live pids: {termination['remainingPids']}"
            )
            report["status"] = "failed"
        if stdout_handle is not None:
            stdout_handle.close()
        if stderr_handle is not None:
            stderr_handle.close()
        combine_console(stdout_path, stderr_path, console_path)
        stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
        cef_profile_warning = extract_cef_profile_warning(stderr_text)
        native_runtime_diagnostics = extract_native_runtime_diagnostics(stderr_text)
        cef_profile_warning["configuredProfileDirectories"] = [str(path) for path in cef_profile_dirs]
        cef_profile_warning["configuredProfileParentDirectories"] = [
            str(path) for path in cef_profile_parent_dirs
        ]
        cef_profile_warning["leafPrecreatedByHarness"] = cef_profile_leaf_precreated
        if cef_profile_warning.get("path"):
            warning_path = Path(str(cef_profile_warning["path"]))
            if not warning_path.is_absolute():
                warning_path = profile_dir / warning_path
            cef_profile_warning["diagnostics"] = profile_path_diagnostics(
                warning_path,
                stop_at=profile_dir,
            )
        else:
            cef_profile_warning["diagnostics"] = None
        report["cefProfileWarning"] = cef_profile_warning
        report["cefProfileSetup"] = profile_setup_diagnostics(
            cef_profile_dirs,
            cef_profile_parent_dirs,
            stop_at=profile_dir,
            leaf_precreated=cef_profile_leaf_precreated,
        )
        if cef_profile_warning.get("detected") and report.get("claims"):
            ui001_claim = report["claims"].get("UI-NATIVE-001")
            if isinstance(ui001_claim, dict):
                ui001_claim.setdefault("evidence", {})["cefProfileWarningDetected"] = True
                ui001_claim.setdefault("limitations", []).append(
                    "CEF still emitted a profile-creation warning; see cefProfileWarning diagnostics."
                )
        if process is not None:
            report.setdefault("process", {}).update(
                {
                    "unexpectedExit": unexpected_exit,
                    "termination": termination,
                    "stdoutTail": tail(stdout_path),
                    "stderrTail": tail(stderr_path),
                }
            )
        report["nativeRuntimeDiagnostics"] = native_runtime_diagnostics
        if native_runtime_diagnostics.get("detected") and report.get("claims"):
            limitation = (
                "Native runtime stderr included crash/lifecycle markers; see "
                "nativeRuntimeDiagnostics for the GLX, Mojo, GTK, and child-signal classification."
            )
            for claim_id in ("UI-NATIVE-001", "UI-NATIVE-002"):
                claim = report["claims"].get(claim_id)
                if isinstance(claim, dict):
                    claim.setdefault("evidence", {})["nativeRuntimeDiagnostics"] = native_runtime_diagnostics
                    claim.setdefault("limitations", []).append(limitation)
        directory_cleanup: dict[str, Any] = {}
        for label, path in (("profile", profile_dir), ("workspaceFixture", workspace_dir)):
            existed = path.exists()
            try:
                if existed:
                    shutil.rmtree(path)
                directory_cleanup[label] = {
                    "path": str(path),
                    "existed": existed,
                    "removed": not path.exists(),
                }
            except OSError as exc:
                directory_cleanup[label] = {
                    "path": str(path),
                    "removed": False,
                    "error": str(exc),
                }
                errors.append(f"could not remove disposable {label} directory {path}: {exc}")
                report["status"] = "failed"
        report["cleanup"] = directory_cleanup
        report["finishedAt"] = utc_now()
        report["elapsedSeconds"] = round(time.monotonic() - started_monotonic, 3)
        report["errors"] = list(dict.fromkeys(errors))
        if not report["claims"]:
            unavailable = {"errors": report["errors"]}
            report["claims"] = {
                "UI-NATIVE-001": make_claim(
                    "unverified",
                    "single Linux packaged-native launch survival",
                    unavailable,
                    ["The driver did not reach the survival measurement."],
                ),
                "UI-NATIVE-002": make_claim(
                    "unverified",
                    "scheduled idle soak survival with retained final-frame and telemetry artifacts",
                    unavailable,
                    ["The driver did not reach the scheduled soak measurement."],
                ),
                "UI-NATIVE-003": make_claim(
                    "unverified",
                    "requested terminal-count metrics and descendant CPU/RSS",
                    unavailable,
                    ["The driver did not reach terminal-count measurement."],
                ),
                "UI-NATIVE-004": make_claim(
                    "unverified",
                    "visible X11 terminal input plus screenshot OCR",
                    unavailable,
                    ["No backend terminal/write injection is accepted as a substitute."],
                ),
                "UI-NATIVE-005": make_claim(
                    "unverified",
                    "clean first-run folderless workspace recovery",
                    unavailable,
                    ["The driver did not reach workspace/getFolders verification."],
                ),
            }
        write_json(metrics_path, metrics_samples)
        write_json(process_path, process_samples)
        report_aliases = [report_path]
        if args.claim_soak:
            report_aliases.append(output_dir / "report-soak.json")
        else:
            report_aliases.append(output_dir / f"report-terminal-count-{args.terminal_count}.json")
        for alias in report_aliases:
            write_json(alias, report)

    if report["status"] == "passed":
        print(f"native UI baseline passed; evidence: {report_path}")
        return 0
    print(f"native UI baseline failed; evidence: {report_path}", file=sys.stderr)
    for error in report.get("errors", []):
        print(f"- {error}", file=sys.stderr)
    return 1


def main() -> int:
    return run(parse_args(sys.argv[1:]))


if __name__ == "__main__":
    raise SystemExit(main())
