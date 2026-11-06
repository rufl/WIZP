#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path


def pipe_stream(source, destination, log_path: Path | None) -> None:
    log_file = None
    try:
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_file = log_path.open("ab")
        while True:
            chunk = source.read(65536)
            if not chunk:
                break
            if log_file is not None:
                log_file.write(chunk)
                log_file.flush()
            destination.write(chunk)
            destination.flush()
    finally:
        if log_file is not None:
            log_file.close()
        try:
            destination.flush()
        except Exception:
            pass


def forward_stdin(stdin, log_path: Path | None) -> None:
    log_file = None
    try:
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_file = log_path.open("ab")
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            if log_file is not None:
                log_file.write(chunk)
                log_file.flush()
            stdin.write(chunk)
            stdin.flush()
    finally:
        if log_file is not None:
            log_file.close()
        try:
            stdin.close()
        except Exception:
            pass


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: fixture_stdio_proxy.py <log-prefix> <target> [args...]", file=sys.stderr)
        return 2

    log_prefix = sys.argv[1]
    target = sys.argv[2]
    target_args = sys.argv[3:]

    prefix_path = Path(log_prefix) if log_prefix else None
    stdin_log = prefix_path.with_suffix(".stdin.log") if prefix_path else None
    stdout_log = prefix_path.with_suffix(".stdout.log") if prefix_path else None
    stderr_log = prefix_path.with_suffix(".stderr.log") if prefix_path else None

    proc = subprocess.Popen(
        [target, *target_args],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
        bufsize=0,
    )

    assert proc.stdin is not None
    assert proc.stdout is not None
    assert proc.stderr is not None

    threads = [
        threading.Thread(target=forward_stdin, args=(proc.stdin, stdin_log), daemon=True),
        threading.Thread(target=pipe_stream, args=(proc.stdout, sys.stdout.buffer, stdout_log), daemon=True),
        threading.Thread(target=pipe_stream, args=(proc.stderr, sys.stderr.buffer, stderr_log), daemon=True),
    ]
    for thread in threads:
        thread.start()

    return_code = proc.wait()
    for thread in threads:
        thread.join(timeout=1.0)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
