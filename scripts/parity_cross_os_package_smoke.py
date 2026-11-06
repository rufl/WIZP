#!/usr/bin/env python3
"""Validate cross-OS package smoke runner metadata and local startup basics."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = PROJECT_ROOT / ".github" / "workflows" / "parity-hardening.yml"
REPORT = PROJECT_ROOT / "build" / "parity-package" / "cross-os-package-report.json"

RUNNER_TO_SYSTEM = {
    "ubuntu-latest": "linux",
    "macos-latest": "darwin",
    "windows-latest": "windows",
}
REQUIRED_PROOF = {
    "linux": [
        "terminal-startup",
        "terminal-session",
        "daemon-pty-policy",
        "workspace-folders",
        "diagnostics-export",
        "path-normalization",
        "extension-host-smoke",
    ],
    "darwin": [
        "terminal-startup",
        "terminal-session",
        "native-package",
        "native-shell-runtime",
        "posix-pty-runtime",
        "live-webview",
        "workspace-folders",
        "diagnostics-export",
        "path-normalization",
        "extension-host-smoke",
    ],
    "windows": [
        "terminal-startup",
        "terminal-session",
        "native-package",
        "native-shell-runtime",
        "conpty-runtime",
        "live-webview2",
        "workspace-folders",
        "diagnostics-export",
        "path-normalization",
        "extension-host-smoke",
    ],
}


def _candidate_binary(system: str) -> Path:
    name = "wizp.exe" if system == "windows" else "wizp"
    return PROJECT_ROOT / "zig-out" / "bin" / name


def _terminal_startup(binary: Path) -> dict:
    started = time.perf_counter()
    proc = subprocess.run(
        [str(binary), "--terminal-probe"],
        cwd=str(PROJECT_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    combined = f"{proc.stdout}\n{proc.stderr}"
    if proc.returncode != 0 or "WIZP terminal probe ready" not in combined:
        raise AssertionError(f"terminal startup failed ({proc.returncode}): {combined[-800:]}")
    return {"mode": "terminal", "elapsedMs": elapsed_ms, "ok": True}


def _rpc_call(proc: subprocess.Popen[bytes], method: str, params: dict | None = None) -> dict:
    body: dict = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params
    data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(b"Content-Length: " + str(len(data)).encode("ascii") + b"\r\n\r\n" + data)
    proc.stdin.flush()
    header = b""
    deadline = time.time() + 10
    while b"\r\n\r\n" not in header:
        if time.time() > deadline:
            raise TimeoutError(f"timed out waiting for {method}")
        chunk = proc.stdout.read(1)
        if not chunk:
            stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
            raise AssertionError(f"daemon exited before {method}: {stderr[-800:]}")
        header += chunk
    length = None
    for line in header.decode("ascii", "replace").split("\r\n"):
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length is None:
        raise AssertionError(f"missing Content-Length in {header!r}")
    response = json.loads(proc.stdout.read(length).decode("utf-8"))
    if "error" in response:
        raise AssertionError(f"{method} failed: {response}")
    return response["result"]


def _daemon_rpc(binary: Path, method: str, params: dict | None = None) -> dict:
    with tempfile.TemporaryDirectory(prefix="wizp-package-smoke-") as tmp:
        proc = subprocess.Popen(
            [str(binary), "--daemon"],
            cwd=tmp,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            return _rpc_call(proc, method, params)
        finally:
            proc.kill()
            proc.wait(timeout=5)


def _terminal_session_smoke(binary: Path, system: str) -> dict:
    marker = "WIZP_CONPTY_OK" if system == "windows" else "WIZP_PTY_OK"
    command = f"echo {marker}\r\n" if system == "windows" else f"printf '{marker}\\n'\n"
    with tempfile.TemporaryDirectory(prefix="wizp-terminal-smoke-") as tmp:
        proc = subprocess.Popen(
            [str(binary), "--daemon"],
            cwd=tmp,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        session_id = None
        output = ""
        try:
            spawn_params = {"cwd": tmp}
            if system != "windows":
                spawn_params["shell"] = "/bin/sh"
            spawned = _rpc_call(proc, "terminal/spawn", spawn_params)
            session_id = int(spawned["id"])
            if spawned.get("pid", -1) <= 0:
                raise AssertionError(f"terminal spawn returned invalid pid: {spawned}")
            if _rpc_call(proc, "terminal/resize", {"id": session_id, "rows": 31, "cols": 97}) is not True:
                raise AssertionError("terminal resize failed")
            if _rpc_call(proc, "terminal/write", {"id": session_id, "data": command}) is not True:
                raise AssertionError("terminal write failed")
            deadline = time.time() + 10
            while marker not in output and time.time() < deadline:
                result = _rpc_call(proc, "terminal/read", {"id": session_id})
                encoded = str(result.get("data") or "")
                if encoded:
                    output += base64.b64decode(encoded).decode("utf-8", "replace")
                if result.get("eof") is True:
                    break
            if marker not in output:
                raise AssertionError(f"terminal output marker missing: {output[-800:]!r}")
            if _rpc_call(proc, "terminal/kill", {"id": session_id}) is not True:
                raise AssertionError("terminal kill failed")
            session_id = None
            listed = _rpc_call(proc, "terminal/list")
            if listed.get("terminals") != []:
                raise AssertionError(f"terminal cleanup failed: {listed}")
            return {
                "backend": spawned.get("backend"),
                "pid": spawned.get("pid"),
                "resize": {"rows": 31, "cols": 97},
                "marker": marker,
                "cleanup": True,
                "ok": True,
            }
        finally:
            if session_id is not None and proc.poll() is None:
                try:
                    _rpc_call(proc, "terminal/kill", {"id": session_id})
                except Exception:
                    pass
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)


def _daemon_surface_smoke(binary: Path, system: str) -> dict:
    terminal = _daemon_rpc(binary, "terminal/restorePolicy")
    webview = _daemon_rpc(binary, "webview/lifecycleSmoke")
    workspace = _daemon_rpc(binary, "workspace/getFolders")
    diagnostics = _daemon_rpc(binary, "diagnostics/export")
    native = _daemon_rpc(binary, "platform/native")
    normalized = _daemon_rpc(binary, "platform/normalizePath")
    if terminal.get("stalePtyHandles") is not False:
        raise AssertionError(f"unexpected terminal restore policy: {terminal}")
    csp = str(webview.get("csp") or "")
    if "default-src 'none'" not in csp or webview.get("outsideWorkspaceDenied") is not True:
        raise AssertionError(f"unexpected webview lifecycle metadata: {webview}")
    if diagnostics.get("materialized") is not True or diagnostics.get("redactsSecrets") is not True:
        raise AssertionError(f"unexpected diagnostics export metadata: {diagnostics}")
    if native.get("current") != system:
        raise AssertionError(f"native platform mismatch: expected {system}, got {native}")
    if normalized.get("roundtrip") is not True:
        raise AssertionError(f"unexpected path normalization metadata: {normalized}")
    return {
        "ptyPolicy": "covered",
        "webviewPolicy": "workspace-only",
        "nativePlatform": native.get(system, {}),
        "pathNormalization": {
            "roundtrip": normalized.get("roundtrip"),
            "casePolicy": normalized.get("casePolicy"),
            "sample": normalized.get({"linux": "posix", "darwin": "macos", "windows": "windows"}[system]),
        },
        "diagnosticsArchive": diagnostics.get("path"),
        "diagnosticsBytes": diagnostics.get("bytes"),
        "workspaceFolders": len(workspace.get("folders", [])),
        "ok": True,
    }


def _extension_host_smoke(system: str) -> dict:
    started = time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(PROJECT_ROOT / "scripts" / "parity_extension_host_smoke.py")],
        cwd=str(PROJECT_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
    )
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    combined = f"{proc.stdout}\n{proc.stderr}"
    if proc.returncode != 0 or "parity extension host smoke ok" not in combined:
        raise AssertionError(f"extension-host smoke failed on {system} ({proc.returncode}): {combined[-1600:]}")
    return {
        "runnerSystem": system,
        "script": "scripts/parity_extension_host_smoke.py",
        "elapsedMs": elapsed_ms,
        "ok": True,
    }


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _package_launcher(system: str) -> Path:
    name = "launcher.exe" if system == "windows" else "launcher"
    candidates = [
        path
        for path in (PROJECT_ROOT / "build").glob("dev-*/**/" + name)
        if path.is_file() and "Resources" not in path.parts
    ]
    if not candidates:
        raise AssertionError(f"packaged launcher missing for {system}")
    return max(candidates, key=lambda path: path.stat().st_mtime_ns)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _control_json(port: int, path: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        headers={"Content-Type": "application/json"} if data is not None else {},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        return json.loads(response.read().decode("utf-8"))
def _evaluate_webview(port: int, script: str, timeout: float = 15.0) -> object:
    report_id = f"{os.getpid()}-{time.monotonic_ns()}"
    report_url = f"http://127.0.0.1:{port}/__webview-report"
    wrapped_script = f"""
(async () => {{
  let result = null;
  try {{
    result = await ({script});
  }} catch (err) {{
    result = {{ __error: String(err) }};
  }}
  await fetch({json.dumps(report_url)}, {{
    method: "POST",
    headers: {{ "Content-Type": "application/json" }},
    body: JSON.stringify({{ id: {json.dumps(report_id)}, result }}),
  }});
}})()
"""
    _control_json(port, "/__webview-evaluate", {"script": wrapped_script})
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            payload = _control_json(port, f"/__webview-report?id={report_id}")
            result = payload.get("result")
            if isinstance(result, dict) and "__error" in result:
                raise AssertionError(f"WebView evaluation failed: {result['__error']}")
            return result
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
        time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for WebView evaluation report {report_id}")




def _native_package_smoke(system: str) -> dict:
    launcher = _package_launcher(system)
    resources = launcher.parents[1] / "Resources" / "app"
    backend = resources / ("wizp.exe" if system == "windows" else "wizp")
    frontend = resources / "frontend-dist" / "index.html"
    for required in (backend, frontend):
        if not required.is_file():
            raise AssertionError(f"packaged resource missing: {required}")

    http_port = _free_port()
    control_port = _free_port()
    with tempfile.TemporaryDirectory(prefix="wizp-native-package-") as tmp:
        stdout_path = Path(tmp) / "launcher.stdout.log"
        profile = Path(tmp) / "profile"
        startup_file = Path(tmp) / "wizp-startup.txt"
        startup_file.write_text("WIZP startup file smoke\n", encoding="utf-8")
        profile.mkdir()
        for name in ("cache", "config", "data", "state", "runtime"):
            (profile / name).mkdir()
        for cef_profile in (
            profile / "cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
            profile / ".cache" / "dev.wizp.app" / "dev" / "CEF" / "partitions" / "default",
        ):
            cef_profile.parent.mkdir(parents=True, exist_ok=True)
        if system != "windows":
            os.chmod(profile / "runtime", 0o700)
        stderr_path = Path(tmp) / "launcher.stderr.log"
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(profile),
                "USERPROFILE": str(profile),
                "APPDATA": str(profile / "AppData" / "Roaming"),
                "LOCALAPPDATA": str(profile / "AppData" / "Local"),
                "XDG_CACHE_HOME": str(profile / "cache"),
                "XDG_CONFIG_HOME": str(profile / "config"),
                "XDG_STATE_HOME": str(profile / "state"),
                "XDG_DATA_HOME": str(profile / "data"),
                "XDG_RUNTIME_DIR": str(profile / "runtime"),
                "WIZP_PORT": str(http_port),
                "WIZP_CONTROL_PORT": str(control_port),
                "WIZP_HTTP_WORKERS": "4",
                "WIZP_NATIVE_UI_SMOKE": "1",
            }
        )
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if system == "windows" else 0
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            proc = subprocess.Popen(
                [str(launcher), str(startup_file)],
                cwd=tmp,
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=system != "windows",
                creationflags=creationflags,
            )
            dom = None
            deadline = time.time() + 30
            script = (
                "JSON.stringify({ready:document.readyState,title:document.title,"
                "hasApp:!!document.querySelector('.workbench'),"
                "hasStartupQuery:location.search.includes('wizpOpenPath='),"
                "hasStartupFile:!!document.querySelector('[data-title=\"wizp-startup.txt\"]'),"
                "body:document.body.innerText.slice(0,240)})"
            )
            last_control_error = ""
            try:
                while time.time() < deadline:
                    if proc.poll() is not None:
                        break
                    try:
                        evaluated = _evaluate_webview(control_port, script, timeout=2.0)
                        dom = json.loads(evaluated) if isinstance(evaluated, str) else evaluated
                        if (
                            isinstance(dom, dict)
                            and dom.get("hasStartupQuery") is True
                            and dom.get("hasStartupFile") is True
                            and dom.get("title") == "WIZP"
                        ):
                            break
                    except (OSError, ValueError, urllib.error.URLError) as exc:
                        last_control_error = f"{type(exc).__name__}: {exc}"
                    time.sleep(0.25)
                if (
                    not isinstance(dom, dict)
                    or dom.get("hasStartupQuery") is not True
                    or dom.get("hasStartupFile") is not True
                    or dom.get("title") != "WIZP"
                ):
                    stdout.flush()
                    stderr.flush()
                    failure = stderr_path.read_text(encoding="utf-8", errors="replace")
                    raise AssertionError(
                        f"packaged native WebView did not become ready with startup file: {dom!r}; "
                        f"control={last_control_error}; {failure[-1600:]}"
                    )
                try:
                    urllib.request.urlopen(
                        f"http://127.0.0.1:{control_port}/__window?action=close",
                        timeout=2,
                    ).read()
                except OSError:
                    pass
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if system == "windows":
                        subprocess.run(
                            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            check=False,
                        )
                    else:
                        os.killpg(proc.pid, 15)
                    proc.wait(timeout=10)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)
        return {
            "launcher": str(launcher),
            "packageRoot": str(resources.parents[1]),
            "launcherSha256": _sha256(launcher),
            "backend": str(backend),
            "backendSha256": _sha256(backend),
            "frontend": str(frontend),
            "webview": dom,
            "webviewExecution": True,
            "startupFileOpened": dom.get("hasStartupFile") is True,
            "cleanExit": proc.returncode == 0,
            "ok": dom.get("hasApp") is True and dom.get("hasStartupFile") is True,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--expected-runner",
        choices=sorted(RUNNER_TO_SYSTEM),
        help="GitHub Actions matrix runner label that should match the current OS",
    )
    parser.add_argument(
        "--native-package-smoke",
        action="store_true",
        help="launch the Electrobun package and verify the live WebView DOM",
    )
    args = parser.parse_args()

    system = platform.system().lower()
    if system not in {"linux", "darwin", "windows"}:
        raise AssertionError(f"unsupported runner OS: {system}")
    if args.expected_runner:
        expected_system = RUNNER_TO_SYSTEM[args.expected_runner]
        if expected_system != system:
            raise AssertionError(f"runner mismatch: {args.expected_runner} expects {expected_system}, got {system}")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    for marker in ("ubuntu-latest", "macos-latest", "windows-latest", "parity_cross_os_package_smoke.py"):
        if marker not in workflow:
            raise AssertionError(f"cross-OS workflow marker missing: {marker}")
    binary = _candidate_binary(system)
    if not binary.exists():
        raise AssertionError(f"built WIZP binary missing: {binary}")
    payload = {
        "os": system,
        "expectedRunner": args.expected_runner,
        "requiredProof": REQUIRED_PROOF[system],
        "binary": str(binary),
        "terminalStartup": _terminal_startup(binary),
        "terminalSession": _terminal_session_smoke(binary, system),
        "daemonSurfaces": _daemon_surface_smoke(binary, system),
        "extensionHostSmoke": _extension_host_smoke(system),
        "workflowMatrix": ["ubuntu-latest", "macos-latest", "windows-latest"],
        "status": "local-package-startup-and-surface-smoke-verified",
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    if args.native_package_smoke:
        payload["nativePackage"] = _native_package_smoke(system)
        payload["status"] = "native-package-runtime-smoke-verified"
    REPORT.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"cross-os package runner ok ({system}): {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
