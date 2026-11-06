#!/usr/bin/env python3
"""Audit WIZP packaged artifacts for self-contained release expectations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORT = PROJECT_ROOT / "build" / "parity-package" / "self-contained-audit.json"
BASELINE_LINUX_ABI_LIBS = {
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libdl.so.2",
    "libm.so.6",
    "libpthread.so.0",
    "libresolv.so.2",
    "librt.so.1",
    "libutil.so.1",
    "linux-vdso.so.1",
}
SYSTEM_WEBVIEW_MARKERS = (
    "libwebkit2gtk",
    "libjavascriptcoregtk",
    "libgtk-3",
    "libgdk-3",
    "libayatana-appindicator",
    "libappindicator",
)


def default_package_dir() -> Path:
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch = "arm64" if machine in {"arm64", "aarch64"} else "x64"
    if system == "linux":
        return PROJECT_ROOT / "build" / f"dev-linux-{arch}" / "WIZP-dev"
    if system == "darwin":
        return PROJECT_ROOT / "build" / f"dev-macos-{arch}" / "WIZP-dev.app"
    if system == "windows":
        return PROJECT_ROOT / "build" / "dev-win-x64" / "WIZP-dev"
    return PROJECT_ROOT / "build" / f"dev-{system}-{arch}" / "WIZP-dev"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_executable(path: Path) -> bool:
    if platform.system().lower() == "windows":
        return path.exists()
    return path.exists() and os.access(path, os.X_OK)


def run_ldd(path: Path, lib_dirs: list[Path]) -> dict:
    if platform.system().lower() != "linux":
        return {"available": False, "reason": "ldd audit is Linux-only"}
    if not is_elf(path):
        return {"available": True, "script": True, "static": False, "dependencies": [], "missing": []}
    env = os.environ.copy()
    # Do not let the audit inherit host/session injection such as NoMachine's
    # LD_PRELOAD; that is not a package dependency and makes ldd lie about the
    # artifact's runtime closure.
    env.pop("LD_PRELOAD", None)
    env.pop("LD_AUDIT", None)
    ld_path = ":".join(str(p) for p in lib_dirs if p.exists())
    if ld_path:
        env["LD_LIBRARY_PATH"] = ld_path
    proc = subprocess.run(
        ["ldd", str(path)],
        cwd=str(PROJECT_ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    output = proc.stdout.strip()
    dependencies = parse_ldd_dependencies(output)
    file_output = describe_binary(path)
    return {
        "available": True,
        "returncode": proc.returncode,
        "output": output,
        "static": is_static_ldd_output(output) or is_static_file_output(file_output),
        "file": file_output,
        "missing": sorted(parse_missing_libs(output)),
        "dependencies": dependencies,
        "external": sorted(format_dependency(dep) for dep in dependencies if dep.get("path")),
        "systemWebview": sorted(dep["name"] for dep in dependencies if is_system_webview_name(dep["name"])),
    }


def is_static_ldd_output(output: str) -> bool:
    """Recognize glibc and musl wording for a binary with no dynamic loader."""
    normalized = output.lower()
    return "not a dynamic executable" in normalized or "statically linked" in normalized


def describe_binary(path: Path) -> str:
    try:
        proc = subprocess.run(
            ["file", "-b", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    return proc.stdout.strip()


def is_static_file_output(output: str) -> bool:
    return "statically linked" in output.lower()


def parse_missing_libs(output: str) -> set[str]:
    missing: set[str] = set()
    for line in output.splitlines():
        stripped = line.strip()
        if "=> not found" in stripped:
            missing.add(stripped.split("=>", 1)[0].strip())
    return missing


def parse_ldd_dependencies(output: str) -> list[dict]:
    deps: list[dict] = []
    for line in output.splitlines():
        stripped = line.strip()
        if "=>" in stripped:
            name, rest = stripped.split("=>", 1)
            target = rest.strip().split(" ", 1)[0]
            if target.startswith("/"):
                deps.append({"name": name.strip(), "path": target})
            elif target == "not":
                deps.append({"name": name.strip(), "path": None})
        elif stripped.startswith("/"):
            path = stripped.split(" ", 1)[0]
            deps.append({"name": Path(path).name, "path": path})
        elif stripped.startswith("linux-vdso"):
            deps.append({"name": stripped.split(" ", 1)[0], "path": None})
    return deps


def format_dependency(dep: dict) -> str:
    path = dep.get("path")
    if path:
        return f"{dep['name']} => {path}"
    return dep["name"]


def is_system_webview_name(name: str) -> bool:
    lower = name.lower()
    for marker in SYSTEM_WEBVIEW_MARKERS:
        if marker in lower:
            return True
    return False


def is_inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def is_baseline_linux_abi(name: str, path: str | None) -> bool:
    if name in BASELINE_LINUX_ABI_LIBS:
        return True
    if path and Path(path).name in BASELINE_LINUX_ABI_LIBS:
        return True
    return False


def require_file(path: Path, missing: list[str]) -> None:
    if not path.exists():
        missing.append(str(path))


def require_exec(path: Path, missing: list[str]) -> None:
    if not is_executable(path):
        missing.append(f"{path} (missing or not executable)")


def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def launcher_wrapper_info(bin_dir: Path) -> dict:
    launcher = bin_dir / "launcher"
    launcher_bin = bin_dir / "launcher.bin"
    info = {
        "launcher": str(launcher),
        "target": str(launcher_bin),
        "wrapped": False,
        "setsPackageLibraryPath": False,
        "createsCefProfilePath": False,
        "createsCefCacheVersionMarker": False,
        "loadsCefXcbBackoff": False,
        "setsCefXcbBackoffBudget": False,
        "startsBundledBunDirectly": False,
        "targetExists": launcher_bin.exists(),
    }
    if not launcher.exists():
        info["reason"] = "launcher missing"
        return info
    if is_elf(launcher):
        info["reason"] = "launcher is a direct ELF binary"
        return info
    try:
        text = launcher.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        info["reason"] = "launcher is not UTF-8 text"
        return info
    except OSError as err:
        info["reason"] = str(err)
        return info
    info["wrapped"] = text.startswith("#!")
    info["setsPackageLibraryPath"] = (
        "LD_LIBRARY_PATH" in text
        and "$APP_BIN" in text
        and "$APP_BIN/cef" in text
    )
    info["createsCefProfilePath"] = (
        "XDG_CACHE_HOME" in text
        and (
            "CEF/partitions/default" in text
            or (
                "CEF_ROOT=" in text
                and 'mkdir -p "$CEF_ROOT"' in text
            )
        )
        and "mkdir -p" in text
    )
    info["createsCefCacheVersionMarker"] = (
        ".electrobun_cef_cache_version" in text
        and "CEF_CACHE_FORMAT=2" in text
        and "printf" in text
    )
    info["loadsCefXcbBackoff"] = (
        "libwizp_cef_xcb_backoff.so" in text
        and "LD_PRELOAD" in text
        and (bin_dir / "libwizp_cef_xcb_backoff.so").is_file()
    )
    info["setsCefXcbBackoffBudget"] = (
        "WIZP_CEF_XCB_BACKOFF_US" in text and ":-1000" in text
    )
    info["startsBundledBunDirectly"] = (
        'exec "$APP_BIN/bun" "$APP_BIN/../Resources/main.js"' in text
    )
    return info


def read_build_config(path: Path) -> dict:
    info = {
        "path": str(path),
        "exists": path.is_file(),
        "valid": False,
        "defaultRenderer": None,
        "availableRenderers": [],
        "error": None,
    }
    if not info["exists"]:
        return info
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        info["error"] = f"{type(exc).__name__}: {exc}"
        return info
    if not isinstance(value, dict):
        info["error"] = "top-level value is not an object"
        return info
    available = value.get("availableRenderers")
    info["valid"] = True
    info["defaultRenderer"] = value.get("defaultRenderer")
    info["availableRenderers"] = available if isinstance(available, list) else []
    return info


def audit(args: argparse.Namespace) -> tuple[dict, list[str]]:
    package_dir = args.package_dir
    build_config_path = package_dir / "Resources" / "build.json"
    app_dir = package_dir / "Resources" / "app"
    bin_dir = package_dir / "bin"
    frontend_dir = app_dir / "frontend-dist"
    monaco_dir = frontend_dir / "monaco"
    cef_dir = bin_dir / "cef"

    missing: list[str] = []
    require_exec(bin_dir / "launcher", missing)
    launcher_info = launcher_wrapper_info(bin_dir)
    if launcher_info.get("targetExists"):
        require_exec(bin_dir / "launcher.bin", missing)
    require_exec(bin_dir / "bun", missing)
    require_file(bin_dir / "libwizp_cef_xcb_backoff.so", missing)
    require_file(build_config_path, missing)
    require_exec(app_dir / "wizp", missing)
    require_file(app_dir / "bun" / "index.js", missing)
    require_file(frontend_dir / "index.html", missing)
    require_file(monaco_dir / "loader.js", missing)

    frontend_js = sorted((frontend_dir / "assets").glob("*.js")) if (frontend_dir / "assets").exists() else []
    frontend_css = sorted((frontend_dir / "assets").glob("*.css")) if (frontend_dir / "assets").exists() else []
    if not frontend_js:
        missing.append(f"{frontend_dir / 'assets'}/*.js")
    if not frontend_css:
        missing.append(f"{frontend_dir / 'assets'}/*.css")

    cef_markers = [
        bin_dir / "libcef.so",
        cef_dir / "libcef.so",
        bin_dir / "icudtl.dat",
        cef_dir / "icudtl.dat",
    ]
    cef_present = any(path.exists() for path in cef_markers)
    build_config = read_build_config(build_config_path)
    if args.require_cef and not cef_present:
        missing.append("CEF runtime files (expected bin/libcef.so or bin/cef/libcef.so)")
    if args.require_cef and build_config.get("defaultRenderer") != "cef":
        missing.append("packaged build.json does not select CEF as the default renderer")
    if args.require_cef and "cef" not in build_config.get("availableRenderers", []):
        missing.append("packaged build.json does not advertise the bundled CEF renderer")

    source_freshness = compare_fresh_assets(frontend_dir, monaco_dir)
    if args.require_fresh_assets:
        for item in source_freshness:
            if item["status"] == "stale":
                missing.append(f"stale packaged asset: {item['package']}")

    lib_dirs = [bin_dir, cef_dir]
    binaries = {
        "backend": app_dir / "wizp",
        "launcher": bin_dir / "launcher",
        "launcherBinary": bin_dir / "launcher.bin",
        "bun": bin_dir / "bun",
        "nativeWrapper": bin_dir / "libNativeWrapper.so",
        "cefXcbBackoff": bin_dir / "libwizp_cef_xcb_backoff.so",
        "asar": bin_dir / "libasar.so",
    }
    ldd = {name: run_ldd(path, lib_dirs) for name, path in binaries.items() if path.exists()}
    package_root = package_dir.resolve()
    all_dependencies = [
        dep
        for result in ldd.values()
        for dep in result.get("dependencies", [])
        if dep.get("path")
    ]
    bundled_deps = sorted(
        {
            format_dependency(dep)
            for dep in all_dependencies
            if is_inside(Path(str(dep["path"])), package_root)
        }
    )
    external_deps = sorted(
        {
            format_dependency(dep)
            for dep in all_dependencies
            if not is_inside(Path(str(dep["path"])), package_root)
        }
    )
    non_baseline_external_deps = sorted(
        {
            format_dependency(dep)
            for dep in all_dependencies
            if not is_inside(Path(str(dep["path"])), package_root)
            and not is_baseline_linux_abi(str(dep["name"]), str(dep["path"]))
        }
    )
    system_webview_deps = sorted(
        {
            format_dependency(dep)
            for dep in all_dependencies
            if is_system_webview_name(str(dep["name"]))
            and not is_inside(Path(str(dep["path"])), package_root)
        }
    )
    bundled_system_webview_deps = sorted(
        {
            format_dependency(dep)
            for dep in all_dependencies
            if is_system_webview_name(str(dep["name"]))
            and is_inside(Path(str(dep["path"])), package_root)
        }
    )
    missing_libs = sorted({dep for result in ldd.values() for dep in result.get("missing", [])})

    failures = list(missing)
    if args.strict_static_backend and not ldd.get("backend", {}).get("static", False):
        failures.append("backend is dynamically linked; expected static Linux musl binary")
    if args.fail_on_system_webview and system_webview_deps:
        failures.append(f"system webview dependencies outside package: {', '.join(system_webview_deps)}")
    if args.fail_on_external_deps and non_baseline_external_deps:
        failures.append(
            f"non-baseline dynamic dependencies outside package: {', '.join(non_baseline_external_deps)}"
        )
    if args.fail_on_external_deps and platform.system().lower() == "linux":
        if not launcher_info.get("setsPackageLibraryPath"):
            failures.append("packaged launcher does not set bundled LD_LIBRARY_PATH")
        if not launcher_info.get("createsCefProfilePath"):
            failures.append("packaged launcher does not bootstrap the clean-profile CEF path")
        if not launcher_info.get("createsCefCacheVersionMarker"):
            failures.append("packaged launcher does not pin the Electrobun CEF cache format")
        if not launcher_info.get("loadsCefXcbBackoff"):
            failures.append("packaged launcher does not load the bounded CEF/XCB backoff")
        if not launcher_info.get("setsCefXcbBackoffBudget"):
            failures.append("packaged launcher does not set the 1ms CEF/XCB backoff budget")
        if not launcher_info.get("startsBundledBunDirectly"):
            failures.append("packaged launcher does not start the bundled Bun/CEF entrypoint directly")
    if missing_libs:
        failures.append(f"missing dynamic libraries: {', '.join(missing_libs)}")

    bundle_audit_passed = not failures
    strict_no_system_package = bundle_audit_passed and not non_baseline_external_deps
    status = "bundled-package-audit-passed" if bundle_audit_passed else "bundled-package-audit-failed"
    if args.fail_on_system_webview or args.fail_on_external_deps:
        status = (
            "strict-self-contained-package-audit-passed"
            if bundle_audit_passed
            else "strict-self-contained-package-audit-failed"
        )
    payload = {
        "packageDir": str(package_dir),
        "appDir": str(app_dir),
        "bundleAuditPassed": bundle_audit_passed,
        "strictNoSystemPackage": strict_no_system_package,
        "cefRequired": bool(args.require_cef),
        "cefPresent": cef_present,
        "browserRuntime": build_config,
        "freshAssetChecks": source_freshness,
        "frontendAssetCounts": {"js": len(frontend_js), "css": len(frontend_css)},
        "launcherWrapper": launcher_info,
        "ldd": ldd,
        "bundledDynamicDependencies": bundled_deps,
        "externalDynamicDependencies": external_deps,
        "nonBaselineExternalDynamicDependencies": non_baseline_external_deps,
        "systemWebviewDependencies": system_webview_deps,
        "bundledSystemWebviewDependencies": bundled_system_webview_deps,
        "baselineLinuxAbiAllowlist": sorted(BASELINE_LINUX_ABI_LIBS),
        "failures": failures,
        "status": status,
    }
    return payload, failures


def compare_fresh_assets(frontend_dir: Path, monaco_dir: Path) -> list[dict]:
    checks = [
        (PROJECT_ROOT / "frontend" / "dist" / "index.html", frontend_dir / "index.html"),
        (PROJECT_ROOT / "frontend" / "dist" / "monaco" / "loader.js", monaco_dir / "loader.js"),
    ]
    result: list[dict] = []
    for source, packaged in checks:
        item = {"source": str(source), "package": str(packaged)}
        if not source.exists() or not packaged.exists():
            item["status"] = "missing"
        elif sha256(source) == sha256(packaged):
            item["status"] = "fresh"
        else:
            item["status"] = "stale"
        result.append(item)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, default=default_package_dir())
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--require-cef", action="store_true")
    parser.add_argument("--strict-static-backend", action="store_true")
    parser.add_argument("--fail-on-system-webview", action="store_true")
    parser.add_argument("--fail-on-external-deps", action="store_true")
    parser.add_argument("--require-fresh-assets", action="store_true")
    args = parser.parse_args()

    payload, failures = audit(args)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    label = "strict self-contained package audit" if args.fail_on_system_webview else "bundled package audit"

    if failures:
        print(f"{label} failed: {args.report}")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print(f"{label} ok: {args.report}")
    if payload["systemWebviewDependencies"]:
        print("system webview dependencies remain; strict audit will fail until the native wrapper is fixed")
    if payload["nonBaselineExternalDynamicDependencies"]:
        print("non-baseline external dynamic dependencies remain; see report for runtime details")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
