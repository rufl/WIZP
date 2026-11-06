#!/usr/bin/env python3
"""Validate a retained packaged Linux primary-journey report."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
JOURNEYS = ("scm", "debug", "extensions", "terminal", "recovery")
RECOVERY_CHECKS = {
    "nativeKeyboardEdits",
    "durableSnapshotsAcknowledged",
    "threeHeldBackendRetries",
    "threeOwnedRendererReplacements",
    "dirtyAndUntitledPreserved",
    "activeEditorAndWorkspacePreserved",
    "routesRecovered",
    "terminalOwnershipPreserved",
    "obsoleteProcessesGone",
    "boundedPollingWatchersAndResources",
    "cycleScreenshotsAndOcr",
    "sessionsCleanedUp",
}
REQUIRED_CHECKS = {
    "recovery": RECOVERY_CHECKS,
    "scm": {
        "workspaceRepositoryLoaded",
        "sourceControlAccessible",
        "credentialPromptCancelled",
        "credentialStatePreserved",
        "stagePermissionFailurePreservedFile",
        "stagePermissionRetryRecovered",
        "stageAndUnstage",
        "diffOpened",
        "commitCreated",
        "discardCancelPreservedFile",
        "discardConfirmed",
        "branchCheckout",
    },
    "debug": {
        "workspaceLaunchLoaded",
        "debugControlsAccessible",
        "adapterFailureExposedRetry",
        "adapterFailurePreservedStoppedState",
        "adapterFailureRecovered",
        "adapterCrashExposedRetry",
        "adapterCrashPreservedInspection",
        "adapterCrashRecovered",
        "sessionStartedPaused",
        "runtimeDetailsVisible",
        "continuePauseAndSteps",
        "evaluationVisible",
        "restartAndStop",
        "stopRestoredFocus",
    },
    "extensions": {
        "extensionsAccessible",
        "networkConsentRequired",
        "networkFailureRedacted",
        "networkFailureRetryRecovered",
        "fixtureSearchCompleted",
        "extensionInstalled",
        "enableDisablePersisted",
        "nativeVsixChooserReviewed",
        "vsixPermissionFailurePreservedState",
        "vsixPermissionRetryRecovered",
        "contributionsVisible",
        "hostCrashUnavailable",
        "hostCrashRetryRecovered",
        "hostRestarted",
        "uninstallCancelRestoredFocus",
        "extensionUninstalled",
    },
    "terminal": {
        "terminalAccessible",
        "nativeClipboardMultilinePasted",
        "localLinkPointerActivated",
        "localLinkKeyboardActivated",
        "commandRendered",
        "ansiUnicodeRendered",
        "findWorked",
        "newTerminalCreated",
        "terminalSplit",
        "spawnFailureIsolated",
        "spawnFailureRetryRecovered",
        "rerunWorked",
        "sustainedBackpressureBounded",
        "normalExitRetained",
        "terminalRelaunched",
        "terminalKilled",
        "sessionsCleanedUp",
    },
}
LEGACY_EXTENSION_CHECKS = {
    "extensionsAccessible",
    "networkConsentRequired",
    "fixtureSearchCompleted",
    "extensionInstalled",
    "enableDisablePersisted",
    "nativeVsixChooserReviewed",
    "contributionsVisible",
    "hostRestarted",
    "uninstallCancelRestoredFocus",
    "extensionUninstalled",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--journey", required=True, choices=JOURNEYS)
    parser.add_argument("--report", type=Path)
    return parser.parse_args(argv)


def is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def is_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(entry, str) for entry in value)


def validate_scm_recovery(payload: dict[str, Any], errors: list[str]) -> None:
    permission = payload.get("permissionRecovery")
    if not isinstance(permission, dict):
        errors.append("permissionRecovery must be an object")
    else:
        if permission.get("gitDirectory") != ".git":
            errors.append("permissionRecovery.gitDirectory must be .git")
        original_mode = permission.get("originalMode")
        try:
            parsed_original_mode = int(original_mode, 8) if isinstance(original_mode, str) else -1
        except ValueError:
            parsed_original_mode = -1
        if (
            parsed_original_mode < 0
            or parsed_original_mode > 0o777
            or oct(parsed_original_mode) != original_mode
            or parsed_original_mode & 0o200 == 0
        ):
            errors.append("permissionRecovery.originalMode must be a canonical owner-writable octal mode")
        if permission.get("restrictedMode") != "0o500":
            errors.append("permissionRecovery.restrictedMode must be 0o500")
        if permission.get("restoredMode") != original_mode:
            errors.append("permissionRecovery must restore the original .git mode")

    states = payload.get("states")
    if not isinstance(states, dict):
        errors.append("states must be an object")
        return

    credential = states.get("credentialCancellation")
    if not isinstance(credential, dict):
        errors.append("states.credentialCancellation must be an object")
    else:
        if "Canceled" not in str(credential.get("status", "")):
            errors.append("states.credentialCancellation.status must retain Canceled")
        if credential.get("remote") != "origin":
            errors.append("states.credentialCancellation.remote must remain origin")
        before = credential.get("filesBefore")
        after = credential.get("filesAfter")
        if not is_string_list(before) or not is_string_list(after):
            errors.append("states.credentialCancellation file snapshots must be string arrays")
        elif before != after:
            errors.append("states.credentialCancellation must preserve the SCM file snapshot")

    failure_index_sha256: str | None = None
    failure = states.get("stagePermissionFailure")
    if not isinstance(failure, dict):
        errors.append("states.stagePermissionFailure must be an object")
    else:
        expected = {
            "messageRole": "alert",
            "messageAction": "Retry",
            "indexPath": ".git/index",
        }
        for key, value in expected.items():
            if failure.get(key) != value:
                errors.append(f"states.stagePermissionFailure.{key} must be {value!r}")
        if "permission denied" not in str(failure.get("message", "")).lower():
            errors.append("states.stagePermissionFailure.message must retain the permission error")

        staged_before = failure.get("stagedPathsBefore")
        staged_after = failure.get("stagedPathsAfter")
        unstaged_before = failure.get("unstagedPathsBefore")
        unstaged_after = failure.get("unstagedPathsAfter")
        for field, value in (
            ("stagedPathsBefore", staged_before),
            ("stagedPathsAfter", staged_after),
            ("unstagedPathsBefore", unstaged_before),
            ("unstagedPathsAfter", unstaged_after),
        ):
            if not is_string_list(value):
                errors.append(f"states.stagePermissionFailure.{field} must be a string array")
        if is_string_list(staged_before) and is_string_list(staged_after):
            if staged_after != staged_before:
                errors.append("states.stagePermissionFailure must preserve the complete staged-path set")
            if "scm-tracked.txt" in staged_after:
                errors.append("states.stagePermissionFailure must leave scm-tracked.txt unstaged")
        if is_string_list(unstaged_before) and is_string_list(unstaged_after):
            if unstaged_after != unstaged_before:
                errors.append("states.stagePermissionFailure must preserve the complete unstaged-path set")
            if "scm-tracked.txt" not in unstaged_after:
                errors.append("states.stagePermissionFailure must preserve scm-tracked.txt in the working tree")

        index_before = failure.get("indexSha256Before")
        index_after = failure.get("indexSha256After")
        if not is_sha256(index_before):
            errors.append("states.stagePermissionFailure.indexSha256Before must be a lowercase SHA-256")
        if not is_sha256(index_after):
            errors.append("states.stagePermissionFailure.indexSha256After must be a lowercase SHA-256")
        if is_sha256(index_before) and is_sha256(index_after) and index_after != index_before:
            errors.append("states.stagePermissionFailure must preserve the exact Git index")
        if is_sha256(index_after):
            failure_index_sha256 = index_after

    reload_state = states.get("stagePermissionReload")
    if not isinstance(reload_state, dict):
        errors.append("states.stagePermissionReload must be an object")
    elif reload_state.get("messageCleared") is not True or reload_state.get("stageEnabled") is not True:
        errors.append("states.stagePermissionReload must prove the alert Retry reloaded an enabled stage action")

    retry = states.get("stagePermissionRetry")
    if not isinstance(retry, dict):
        errors.append("states.stagePermissionRetry must be an object")
    else:
        if retry.get("staged") is not True:
            errors.append("states.stagePermissionRetry.staged must be true")
        retry_paths = retry.get("stagedPaths")
        if not is_string_list(retry_paths):
            errors.append("states.stagePermissionRetry.stagedPaths must be a string array")
        elif "scm-tracked.txt" not in retry_paths:
            errors.append("states.stagePermissionRetry.stagedPaths must contain scm-tracked.txt")
        retry_index_sha256 = retry.get("indexSha256")
        if not is_sha256(retry_index_sha256):
            errors.append("states.stagePermissionRetry.indexSha256 must be a lowercase SHA-256")
        elif failure_index_sha256 is not None and retry_index_sha256 == failure_index_sha256:
            errors.append("states.stagePermissionRetry must prove the recovered stage changed the Git index")


def validate_debug_recovery(payload: dict[str, Any], errors: list[str]) -> None:
    states = payload.get("states")
    if not isinstance(states, dict):
        errors.append("states must be an object")
        return

    stopped_expected = {
        "launch": "Missing Adapter",
        "running": False,
        "paused": "",
        "sessionText": "",
        "startEnabled": True,
    }
    attempt = states.get("adapterAttempt")
    if not isinstance(attempt, dict):
        errors.append("states.adapterAttempt must be an object")
    else:
        for key, value in stopped_expected.items():
            if attempt.get(key) != value:
                errors.append(f"states.adapterAttempt.{key} must be {value!r}")
        if attempt.get("schema") != "true":
            errors.append("states.adapterAttempt.schema must retain the valid launch schema")

    failure = states.get("adapterFailure")
    if not isinstance(failure, dict):
        errors.append("states.adapterFailure must be an object")
    else:
        failure_expected = {
            **stopped_expected,
            "messageRole": "alert",
            "messageLive": "assertive",
        }
        for key, value in failure_expected.items():
            if failure.get(key) != value:
                errors.append(f"states.adapterFailure.{key} must be {value!r}")
        if failure.get("messageAction") not in {"Retry", "Retry start"}:
            errors.append("states.adapterFailure.messageAction must expose Retry")
        failure_message = str(failure.get("message", ""))
        if not any(
            marker in failure_message
            for marker in ("Debug adapter start failed", "Debug initialize failed")
        ):
            errors.append("states.adapterFailure.message must retain the adapter process failure")

    retry = states.get("adapterRetry")
    if not isinstance(retry, dict):
        errors.append("states.adapterRetry must be an object")
    else:
        retry_expected = {**stopped_expected}
        for key, value in retry_expected.items():
            if retry.get(key) != value:
                errors.append(f"states.adapterRetry.{key} must be {value!r}")
        if not isinstance(retry.get("messageCleared"), bool):
            errors.append("states.adapterRetry.messageCleared must be boolean")
        elif not retry["messageCleared"] and retry.get("messageAction") not in {"Retry", "Retry start"}:
            errors.append("states.adapterRetry must retain a retry action after the missing adapter failure")

    recovery = states.get("adapterRecovery")
    if not isinstance(recovery, dict):
        errors.append("states.adapterRecovery must be an object")
    else:
        recovery_expected = {
            "launch": "Native Fixture Debug",
            "schema": "true",
            "running": True,
            "paused": "true",
            "startEnabled": False,
            "messageRole": "status",
            "messageLive": "polite",
            "messageAction": "",
        }
        for key, value in recovery_expected.items():
            if recovery.get(key) != value:
                errors.append(f"states.adapterRecovery.{key} must be {value!r}")
        if not str(recovery.get("sessionText", "")).strip():
            errors.append("states.adapterRecovery.sessionText must retain the active paused session")
        if "Native Fixture Debug started." not in str(recovery.get("message", "")):
            errors.append("states.adapterRecovery.message must retain the successful fixture start")

    crash = states.get("adapterCrash")
    if not isinstance(crash, dict):
        errors.append("states.adapterCrash must be an object")
    else:
        if crash.get("adapterKilled") is not True or crash.get("orphaned") is not False:
            errors.append("states.adapterCrash must prove the fixture adapter was reaped without an orphan")
        if crash.get("running") is not False:
            errors.append("states.adapterCrash.running must be false")
        if crash.get("messageAction") != "Retry debugging":
            errors.append("states.adapterCrash must expose Retry debugging")
        if "last known inspection" not in str(crash.get("message", "")).lower():
            errors.append("states.adapterCrash must retain the last known inspection")
        if not isinstance(crash.get("stack"), list) or not crash.get("stack"):
            errors.append("states.adapterCrash.stack must retain inspection frames")
        if not isinstance(crash.get("variables"), list) or not crash.get("variables"):
            errors.append("states.adapterCrash.variables must retain inspection values")

    crash_retry = states.get("adapterCrashRetry")
    if not isinstance(crash_retry, dict) or not str(crash_retry.get("text", "")).strip():
        errors.append("states.adapterCrashRetry must prove a recovered paused session")


def validate_terminal_lifecycle(payload: dict[str, Any], errors: list[str]) -> None:
    states = payload.get("states")
    if not isinstance(states, dict):
        errors.append("states must be an object")
        return

    clipboard = states.get("nativeClipboard")
    if not isinstance(clipboard, dict):
        errors.append("states.nativeClipboard must be an object")
    else:
        if clipboard.get("owner") != "Tk/X11" or not isinstance(clipboard.get("ownerPid"), int):
            errors.append("states.nativeClipboard must identify the native X11 clipboard owner")
        characters = clipboard.get("payloadCharacters")
        utf8_bytes = clipboard.get("payloadUtf8Bytes")
        if (
            not isinstance(characters, int)
            or characters < 20
            or not isinstance(utf8_bytes, int)
            or utf8_bytes <= characters
        ):
            errors.append("states.nativeClipboard must prove multibyte Unicode payload accounting")
        if clipboard.get("payloadLines") != 2:
            errors.append("states.nativeClipboard must prove a deterministic two-line paste")
        if clipboard.get("selection") != "CLIPBOARD" or clipboard.get("shortcut") != "Ctrl+Shift+V":
            errors.append("states.nativeClipboard must identify the native CLIPBOARD shortcut path")
        if clipboard.get("xtermDataInjectedByHarness") is not False:
            errors.append("states.nativeClipboard must reject harness xterm-data injection")
        if clipboard.get("firstLineVisible") is not True or clipboard.get("secondLineVisible") is not True:
            errors.append("states.nativeClipboard must prove both shell-visible Unicode lines")
        sha = str(clipboard.get("payloadSha256", ""))
        if len(sha) != 64 or any(char not in "0123456789abcdef" for char in sha):
            errors.append("states.nativeClipboard.payloadSha256 must be a lowercase SHA-256")

    local_link = states.get("localLink")
    if not isinstance(local_link, dict):
        errors.append("states.localLink must be an object")
    else:
        uri = str(local_link.get("uri", ""))
        if not uri.startswith("http://127.0.0.1:") or "/__native-terminal-link" not in uri:
            errors.append("states.localLink must use the deterministic loopback endpoint")
        if local_link.get("host") != "127.0.0.1" or local_link.get("externalNetworking") is not False:
            errors.append("states.localLink must reject implicit external networking")
        sources = local_link.get("activationSources")
        if not isinstance(sources, list) or "pointer" not in sources or "keyboard" not in sources:
            errors.append("states.localLink must prove pointer and keyboard activation")
        activations = local_link.get("activations")
        if not isinstance(activations, list) or len(activations) < 2:
            errors.append("states.localLink.activations must retain both local requests")
        elif any(
            not isinstance(item, dict)
            or item.get("source") not in {"pointer", "keyboard"}
            or "127.0.0.1" not in str(item.get("uri", ""))
            for item in activations
        ):
            errors.append("states.localLink.activations must remain loopback-only")

    spawn_failure = states.get("spawnFailure")
    if not isinstance(spawn_failure, dict):
        errors.append("states.spawnFailure must be an object")
    else:
        if spawn_failure.get("code") != -32010:
            errors.append("states.spawnFailure.code must be -32010")
        before = spawn_failure.get("sessionIdsBefore")
        after = spawn_failure.get("sessionIdsAfter")
        if not isinstance(before, list) or not before or any(not isinstance(item, int) for item in before):
            errors.append("states.spawnFailure.sessionIdsBefore must be a non-empty integer array")
        if after != before:
            errors.append("states.spawnFailure must preserve every existing terminal session")
        frontend = spawn_failure.get("frontend")
        retry = spawn_failure.get("retry")
        if (
            not isinstance(frontend, dict)
            or frontend.get("status") != "error"
            or frontend.get("inputEnabled") is not False
            or frontend.get("retryAvailable") is not True
            or not isinstance(frontend.get("error"), dict)
            or frontend["error"].get("code") != -32010
        ):
            errors.append("states.spawnFailure.frontend must expose actionable disabled spawn failure")
        if (
            not isinstance(retry, dict)
            or retry.get("status") != "ready"
            or retry.get("inputEnabled") is not True
            or not isinstance(retry.get("sessionId"), int)
        ):
            errors.append("states.spawnFailure.retry must prove successful UI Retry recovery")
        elif isinstance(before, list) and retry.get("sessionId") in before:
            errors.append("states.spawnFailure.retry must create a fresh backend session")

    rerun = states.get("rerun")
    if not isinstance(rerun, dict):
        errors.append("states.rerun must be an object")
    else:
        rendered_before = rerun.get("renderedBytesBefore")
        rendered_after = rerun.get("renderedBytes")
        reads_before = rerun.get("dataReadCountBefore")
        reads_after = rerun.get("dataReadCount")
        if (
            not isinstance(rendered_before, int)
            or not isinstance(rendered_after, int)
            or rendered_after <= rendered_before
        ):
            errors.append("states.rerun must prove newly rendered terminal bytes")
        if (
            not isinstance(reads_before, int)
            or not isinstance(reads_after, int)
            or reads_after <= reads_before
        ):
            errors.append("states.rerun must prove a new PTY data read")
        if rerun.get("probeLines") != ["WIZP_RERUN_OK", "WIZP_RERUN_OK"]:
            errors.append("states.rerun must prove exactly two side-effect marker lines")
        if rerun.get("lastRerunResult") != "written":
            errors.append("states.rerun.lastRerunResult must be written")
        if not isinstance(rerun.get("sessionId"), int):
            errors.append("states.rerun.sessionId must be an integer")

    backpressure = states.get("backpressure")
    if not isinstance(backpressure, dict):
        errors.append("states.backpressure must be an object")
    else:
        command_bytes = backpressure.get("commandBytes")
        if not isinstance(command_bytes, int) or command_bytes <= 2 * 16 * 1024 * 1024:
            errors.append("states.backpressure workload must exceed the queue plus one in-flight read")
        if backpressure.get("outputQueueCapacityBytes") != 16 * 1024 * 1024:
            errors.append("states.backpressure must retain the 16 MiB queue bound")
        if backpressure.get("rendererPauseVerified") is not True:
            errors.append("states.backpressure must prove a real paused renderer, independent of producer speed")
        dropped_before = backpressure.get("droppedBytesBefore")
        dropped_after = backpressure.get("droppedBytes")
        rendered_before = backpressure.get("renderedBytesBefore")
        rendered_after = backpressure.get("renderedBytes")
        reads_before = backpressure.get("dataReadCountBefore")
        reads_after = backpressure.get("dataReadCount")
        if (
            not isinstance(dropped_before, int)
            or not isinstance(dropped_after, int)
            or dropped_after <= dropped_before
        ):
            errors.append("states.backpressure must prove explicit packaged dropped-byte accounting")
        if (
            not isinstance(rendered_before, int)
            or not isinstance(rendered_after, int)
            or rendered_after <= rendered_before
        ):
            errors.append("states.backpressure must prove packaged rendered-byte growth")
        if all(
            isinstance(value, int)
            for value in (command_bytes, rendered_before, rendered_after, dropped_before, dropped_after)
        ) and rendered_after - rendered_before + dropped_after - dropped_before < command_bytes:
            errors.append("states.backpressure must account for all pressure output as rendered or dropped")
        if (
            not isinstance(reads_before, int)
            or not isinstance(reads_after, int)
            or reads_after <= reads_before
        ):
            errors.append("states.backpressure must prove continued PTY reads")
        if backpressure.get("completionProbe") is not True or backpressure.get("status") != "ready":
            errors.append("states.backpressure must complete while the terminal remains ready")

    normal_exit = states.get("normalExit")
    frontend = normal_exit.get("frontend") if isinstance(normal_exit, dict) else None
    backend = normal_exit.get("backend") if isinstance(normal_exit, dict) else None
    if not isinstance(frontend, dict) or not isinstance(backend, dict):
        errors.append("states.normalExit must retain frontend and backend objects")
    else:
        if frontend.get("status") != "exited" or frontend.get("inputEnabled") is not False:
            errors.append("states.normalExit.frontend must disable input after exit")
        if "[Process exited: code 7]" not in str(frontend.get("serializedTail", "")):
            errors.append("states.normalExit.frontend must render exit code 7")
        if backend.get("exitKind") != "exited" or backend.get("exitCode") != 7:
            errors.append("states.normalExit.backend must retain exit code 7")
        if backend.get("reaped") is not True:
            errors.append("states.normalExit.backend must prove the child was reaped")

    relaunch = states.get("relaunch")
    if not isinstance(relaunch, dict):
        errors.append("states.relaunch must be an object")
    else:
        previous = relaunch.get("previousSessionId")
        current = relaunch.get("sessionId")
        active_ids = relaunch.get("activeBackendIds")
        if not isinstance(previous, int) or not isinstance(current, int) or current == previous:
            errors.append("states.relaunch must replace the backend session id")
        if not isinstance(active_ids, list) or any(not isinstance(item, int) for item in active_ids):
            errors.append("states.relaunch.activeBackendIds must be an integer array")
        elif previous in active_ids or current not in active_ids:
            errors.append("states.relaunch must remove the old backend and retain the new backend")
        if relaunch.get("status") != "ready" or relaunch.get("inputEnabled") is not True:
            errors.append("states.relaunch must restore a ready input-enabled terminal")


def recovery_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def recovery_process_key(process: dict[str, Any]) -> tuple[int, int]:
    pid, start = process["pid"], process["startTimeTicks"]
    if type(pid) is not int or pid <= 0 or type(start) is not int or start <= 0:
        raise ValueError("process identity requires positive pid and startTimeTicks")
    return pid, start


def recovery_logical_layout(layout: dict[str, Any]) -> dict[str, Any]:
    return {
        "activeGroupId": layout["activeGroupId"],
        "splitDirection": layout["splitDirection"],
        "groups": [
            {"id": group["id"], "activeId": group["activeId"],
             "sessions": [{"id": s["id"], "groupId": s["groupId"], "label": s["label"]}
                          for s in group["sessions"]]}
            for group in layout["groups"]
        ],
    }


def validate_recovery_resources(
    resources: dict[str, Any], baseline: dict[str, Any], name: str, errors: list[str],
) -> None:
    samples, metrics = resources["samples"], resources["metrics"]
    if len(samples) != 4 or len(metrics) != 4:
        raise ValueError(f"{name} needs four raw process and RPC metric samples")
    clock = resources["clockTicksPerSecond"]
    if type(clock) is not int or clock <= 0:
        raise ValueError(f"{name} clock tick rate is invalid")
    cpu_ticks = 0
    main_ticks = 0
    main_seen = False
    for previous, current in zip(samples, samples[1:]):
        before = {recovery_process_key(p): p for p in previous["processes"]}
        after = {recovery_process_key(p): p for p in current["processes"]}
        if before.keys() != after.keys():
            errors.append(f"{name} process identities changed during the steady resource window")
        for identity, process in after.items():
            delta = process["cpuTicks"] - before.get(identity, process)["cpuTicks"]
            if delta < 0:
                errors.append(f"{name} process CPU counter regressed")
            cpu_ticks += delta
            if process.get("role") == "electrobun-main":
                main_seen = True
                main_ticks += delta
        if current["monotonicSeconds"] <= previous["monotonicSeconds"]:
            errors.append(f"{name} process sample clock regressed")
    elapsed = samples[-1]["monotonicSeconds"] - samples[0]["monotonicSeconds"]
    if elapsed < 3:
        errors.append(f"{name} resource window is shorter than three seconds")
    if cpu_ticks / clock * 1000 > 15_000:
        errors.append(f"{name} exceeds the 15,000ms steady CPU budget")
    if not main_seen or elapsed <= 0 or main_ticks / clock / elapsed * 100 > 5:
        errors.append(f"{name} exceeds or lacks the 5% packaged-main CPU gate")
    baseline_rss = baseline["samples"][0]["aggregateRssBytes"]
    for sample in samples:
        if sample["aggregateRssBytes"] != sum(p["rssBytes"] for p in sample["processes"]):
            errors.append(f"{name} aggregate RSS disagrees with raw process rows")
        if sample["aggregateRssBytes"] - baseline_rss > 64 * 1024 * 1024:
            errors.append(f"{name} exceeds 64MiB steady RSS growth")
    metric_elapsed = metrics[-1]["monotonicSeconds"] - metrics[0]["monotonicSeconds"]
    for previous, current in zip(metrics, metrics[1:]):
        for field in ("rpcRequests", "terminalReadRequests"):
            if current["metrics"][field] < previous["metrics"][field]:
                errors.append(f"{name} {field} regressed within one backend generation")
    reads = metrics[-1]["metrics"]["terminalReadRequests"] - metrics[0]["metrics"]["terminalReadRequests"]
    if metric_elapsed < 3 or reads / metric_elapsed > 10:
        errors.append(f"{name} terminal polling exceeds 10 reads/s/session")
    requests = metrics[-1]["metrics"]["rpcRequests"] - metrics[0]["metrics"]["rpcRequests"]
    if requests < reads:
        errors.append(f"{name} RPC counters cannot account for terminal reads")
    # Exact stationary workload: recurring RPCs and kernel watches may not grow each cycle.
    base_metrics = baseline["metrics"]
    base_elapsed = base_metrics[-1]["monotonicSeconds"] - base_metrics[0]["monotonicSeconds"]
    base_requests = base_metrics[-1]["metrics"]["rpcRequests"] - base_metrics[0]["metrics"]["rpcRequests"]
    if metric_elapsed > 0 and base_elapsed > 0 and requests / metric_elapsed > base_requests / base_elapsed + 1:
        errors.append(f"{name} idle RPC polling grew beyond one request/s sampling tolerance")
    def count_watches(value: dict[str, Any]) -> int:
        rows = value["watchers"]
        expected = {
            recovery_process_key(p) for p in value["samples"][-1]["processes"]
            if p.get("state") != "Z"
        }
        if {recovery_process_key(p) for p in rows} != expected:
            raise ValueError(f"{name} kernel watcher scan does not cover every live owned process")
        return sum(len(fd["watches"]) for process in rows for fd in process["descriptors"])
    if count_watches(resources) > count_watches(baseline):
        errors.append(f"{name} kernel inotify registrations grew after recovery")
    if not isinstance(resources.get("terminalTelemetry"), dict):
        errors.append(f"{name} native terminal polling telemetry is missing")


def validate_recovery_cycle(recovery: dict[str, Any], cycle: dict[str, Any], errors: list[str]) -> None:
    try:
        _validate_recovery_cycle(recovery, cycle, errors)
    except (KeyError, TypeError, ValueError, IndexError, AttributeError, ZeroDivisionError) as exc:
        errors.append(f"incomplete recovery cycle evidence: {exc}")


def _validate_recovery_cycle(recovery: dict[str, Any], cycle: dict[str, Any], errors: list[str]) -> None:
    name = f"{cycle['kind']} cycle {cycle['cycle']}"
    kind, number = cycle["kind"], cycle["cycle"]
    if kind not in ("backend", "renderer") or type(number) is not int or number not in (1, 2, 3):
        raise ValueError("invalid recovery cycle identity")
    before, after = cycle["beforeBackend"], cycle["afterBackend"]
    for status in (before, after):
        if (
            status["state"] != "ready" or not isinstance(status["instanceId"], str) or not status["instanceId"]
            or type(status["generation"]) is not int or status["generation"] < 1
            or type(status["backendPid"]) is not int or status["backendPid"] <= 0
            or status["restartAttempts"] != 0
        ):
            errors.append(f"{name} backend did not reach protocol/context-ready with a reset budget")
    if before["instanceId"] != after["instanceId"]:
        errors.append(f"{name} unexpectedly replaced the native host")
    if after["generation"] != before["generation"] + (1 if kind == "backend" else 0):
        errors.append(f"{name} backend generation transition is incorrect")
    if (before["backendPid"] == after["backendPid"]) != (kind == "renderer"):
        errors.append(f"{name} backend process replacement/preservation is incorrect")
    expected = json.loads(json.dumps(recovery["initialSnapshot"]["editorSession"]))
    expected.pop("terminalLayout", None)
    prior_suffix_count = number - 1 if kind == "backend" else 3
    active_uri = recovery["initialLive"]["activeUri"]
    for group in expected["groups"]:
        for editor in group["editors"]:
            if editor["uri"] == active_uri:
                editor["content"] += "".join(f" HELD{i}" for i in range(1, prior_suffix_count + 1))
    snapshot_names = ("beforeSnapshot", "afterSnapshot")
    for snapshot_name in snapshot_names:
        if snapshot_name == "afterSnapshot" and kind == "backend":
            for group in expected["groups"]:
                for editor in group["editors"]:
                    if editor["uri"] == active_uri:
                        editor["content"] += f" HELD{number}"
        snapshot = cycle[snapshot_name]
        observed = snapshot["editorSession"]
        projection = {key: observed[key] for key in ("layout", "activeGroup", "groups")}
        expected_projection = {key: expected[key] for key in ("layout", "activeGroup", "groups")}
        if projection != expected_projection:
            errors.append(f"{name} {snapshot_name} lost exact dirty/untitled content or active group")
        if [f["path"] for f in snapshot["folders"]] != [recovery["workspace"]]:
            errors.append(f"{name} {snapshot_name} lost canonical workspace")
        if snapshot.get("path") != recovery["initialSnapshot"].get("path") or not snapshot.get("path"):
            errors.append(f"{name} canonical session path changed or is absent")
        live = cycle["beforeLive" if snapshot_name == "beforeSnapshot" else "afterLive"]
        expected_editors = [
            {key: editor[key] for key in ("uri", "content", "dirty")}
            for group in expected["groups"] for editor in group["editors"]
        ]
        if live["editors"] != expected_editors or live["activeUri"] != active_uri:
            errors.append(f"{name} live editors disagree with acknowledged host snapshot")
        active_content = next(e["content"] for e in expected_editors if e["uri"] == active_uri)
        if live["activeContent"] != active_content:
            errors.append(f"{name} visible editor model lost active content")
    if cycle["diskSha256"] != recovery["diskSha256"]:
        errors.append(f"{name} modified the saved file while preserving dirty content")
    initial_layout = recovery_logical_layout(recovery["initialTerminals"]["frontend"]["layout"])
    for field, status in (("beforeTerminals", before), ("afterTerminals", after)):
        terminals = cycle[field]
        frontend, entries = terminals["frontend"], terminals["backend"]["terminals"]
        if len(entries) != 1 or entries[0]["id"] != frontend["sessionId"]:
            errors.append(f"{name} {field} did not retain exactly one terminal owner")
        if frontend["status"] != "ready" or frontend["inputEnabled"] is not True:
            errors.append(f"{name} {field} terminal is not input-ready")
        if recovery_logical_layout(frontend["layout"]) != initial_layout:
            errors.append(f"{name} {field} changed logical terminal groups")
        sessions = [s for g in frontend["layout"]["groups"] for s in g["sessions"]]
        if (
            len(sessions) != 1 or sessions[0]["backendId"] != entries[0]["id"]
            or sessions[0]["backendIdentity"] != f"{status['instanceId']}:{status['generation']}"
        ):
            errors.append(f"{name} {field} terminal backend identity is stale or duplicated")
        process = terminals["process"]
        recovery_process_key(process)
        if process["pid"] != entries[0]["pid"] or process.get("descendant") is not True or process.get("state") == "Z":
            errors.append(f"{name} {field} terminal process is not live and owned")
    same_terminal = recovery_process_key(cycle["beforeTerminals"]["process"]) == recovery_process_key(cycle["afterTerminals"]["process"])
    if same_terminal != (kind == "renderer"):
        errors.append(f"{name} PTY was not replaced for daemon loss or reattached for renderer loss")
    old = cycle["obsoleteProcesses"]
    if not old or cycle["remainingObsolete"] != []:
        errors.append(f"{name} obsolete process cleanup evidence is incomplete")
    before_processes = {recovery_process_key(p): p for p in cycle["beforeProcesses"]["processes"]}
    after_processes = {recovery_process_key(p): p for p in cycle["afterProcesses"]["processes"] if p.get("state") != "Z"}
    for process in old:
        identity = recovery_process_key(process)
        if identity not in before_processes or process.get("descendant") is not True or identity in after_processes:
            errors.append(f"{name} terminated process was not owned or is still live")
        if kind == "renderer" and "--type=renderer" not in process["command"].split():
            errors.append(f"{name} killed a non-renderer process")
    if kind == "renderer":
        new_renderers = [p for p in after_processes.values() if "--type=renderer" in p["command"].split() and p.get("descendant")]
        if not new_renderers or any(recovery_process_key(p) in {recovery_process_key(o) for o in old} for p in new_renderers):
            errors.append(f"{name} lacks a genuinely new owned CEF renderer")
    else:
        held = cycle["heldSamples"]
        if len(held) != 4 or held[-1]["monotonicSeconds"] - held[0]["monotonicSeconds"] < 9:
            errors.append(f"{name} held disconnect needs at least nine seconds of samples")
        for sample in held:
            status = sample["backend"]
            if (
                status["state"] not in ("disconnected", "unavailable") or status["backendPid"] is not None
                or status["instanceId"] != before["instanceId"] or status["generation"] != before["generation"]
                or status["restartAttempts"] != held[0]["backend"]["restartAttempts"]
            ):
                errors.append(f"{name} automatically restarted or repeated attempts while held")
        if cycle["disconnectedUi"]["role"] != "alert" or cycle["disconnectedUi"]["retry"] != "Retry":
            errors.append(f"{name} visible recoverable disconnect alert is missing")
        if cycle["retryAction"]["label"] != "Retry" or not all(type(cycle["retryAction"].get(axis)) is int for axis in ("x", "y")):
            errors.append(f"{name} Retry did not use an observed native pointer target")
        if cycle["heldSnapshot"]["editorSession"]["groups"] != cycle["afterSnapshot"]["editorSession"]["groups"]:
            errors.append(f"{name} editing during disconnect was not durably acknowledged")
    routes = cycle["routes"]
    if [f["path"] for f in routes["workspace/getFolders"]["folders"]] != [recovery["workspace"]]:
        errors.append(f"{name} workspace route did not recover")
    if not any(m.get("file") == recovery["source"] or m.get("uri") == Path(recovery["source"]).as_uri() for m in routes["search/text"]["matches"]):
        errors.append(f"{name} search/text route did not recover")
    if routes["config/get"] != recovery["initialRoutes"]["config/get"]:
        errors.append(f"{name} config/get changed after recovery")
    if not isinstance(routes["file/list"], dict) or "recovery.txt" not in routes["explorer"]["text"] or routes["explorer"]["error"] is not False:
        errors.append(f"{name} Explorer did not visibly recover")
    if "WIZP_RECOVERY_DISK" not in routes["search"]["text"] or routes["settings"] != recovery["initialRoutes"]["settings"]:
        errors.append(f"{name} Search or Settings did not visibly recover")
    validate_recovery_resources(cycle["resources"], recovery["baselineResources"], name, errors)


def validate_recovery(payload: dict[str, Any], errors: list[str], report_path: Path) -> None:
    try:
        recovery = recovery_mapping(payload.get("recovery"), "recovery")
        cycles = recovery["cycles"]
        expected_order = [(kind, cycle) for kind in ("backend", "renderer") for cycle in (1, 2, 3)]
        if [(c["kind"], c["cycle"]) for c in cycles] != expected_order:
            errors.append("recovery requires three backend and three renderer cycles in order")
        if recovery["input"] != "native XTEST" or not is_sha256(recovery["diskSha256"]):
            errors.append("recovery input and disk hash evidence is missing")
        initial = recovery["initialSnapshot"]["editorSession"]
        editors = [e for g in initial["groups"] for e in g["editors"]]
        if (
            len(editors) != 2 or {e["content"] for e in editors} != {"WIZP_RECOVERY_DIRTY", "WIZP_RECOVERY_UNTITLED"}
            or any(e["dirty"] is not True for e in editors)
            or sum(e["uri"] == Path(recovery["source"]).as_uri() for e in editors) != 1
            or sum(e["uri"].startswith("untitled-") for e in editors) != 1
        ):
            errors.append("initial acknowledged snapshot must contain the exact typed dirty file and untitled editor")
        if not recovery["initialLive"]["activeUri"].startswith("untitled-"):
            errors.append("initial active editor must be the typed untitled buffer")
        validate_recovery_resources(recovery["baselineResources"], recovery["baselineResources"], "baseline", errors)
        for cycle in cycles:
            validate_recovery_cycle(recovery, cycle, errors)
        for previous, current in zip(cycles, cycles[1:]):
            if previous["afterBackend"] != current["beforeBackend"]:
                errors.append("backend identity/attempt state was discontinuous between recovery cycles")
            if previous["afterSnapshot"]["editorSession"]["groups"] != current["beforeSnapshot"]["editorSession"]["groups"]:
                errors.append("durable editor state was discontinuous between recovery cycles")
        if recovery["terminalCleanup"] != {"terminals": []}:
            errors.append("terminal cleanup did not leave an empty owned session set")
        evidence = payload["evidence"]
        labels = ["recovery-initial"] + [
            f"recovery-{kind}-{cycle}-{phase}"
            for kind, cycle in expected_order
            for phase in (("held", "restored") if kind == "backend" else ("restored",))
        ]
        from scripts.native_ui_baseline_smoke import ocr_contains_marker
        for label in labels:
            row = evidence[label]
            marker = "Retry" if label.endswith("-held") else "WIZP_RECOVERY_UNTITLED"
            if row["marker"] != marker:
                errors.append(f"{label} OCR acceptance marker is incorrect")
            for field in ("screenshot", "ocr"):
                filename = row[field]
                if not isinstance(filename, str) or Path(filename).name != filename:
                    raise ValueError(f"{label} artifact path must be a local filename")
                path = report_path.parent / filename
                if not path.is_file() or not path.stat().st_size:
                    raise ValueError(f"{label} {field} artifact is missing or empty")
                if field == "ocr" and not ocr_contains_marker(path.read_text(), marker):
                    errors.append(f"{label} retained OCR does not contain {marker}")
                if field == "screenshot" and path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                    errors.append(f"{label} screenshot is not a PNG")
    except (OSError, KeyError, TypeError, ValueError, IndexError, AttributeError, ZeroDivisionError) as exc:
        errors.append(f"incomplete recovery report evidence: {exc}")


def validate(payload: dict[str, Any], journey: str, report_path: Path) -> list[str]:
    errors: list[str] = []
    if payload.get("schema") != 1:
        errors.append("schema must be 1")
    if payload.get("kind") != f"wizp-linux-packaged-native-{journey}":
        errors.append(f"kind must identify the {journey} packaged-native journey")
    if payload.get("journey") != journey:
        errors.append(f"journey must be {journey}")
    if payload.get("status") != "passed":
        errors.append("status must be passed")
    if payload.get("errors") != []:
        errors.append("errors must be empty")

    required_checks = REQUIRED_CHECKS[journey]
    if journey == "extensions":
        not_claimed = payload.get("notClaimed")
        if isinstance(not_claimed, list) and (
            "Real extension-host crash recovery" in not_claimed
            or "Filesystem permission failure" in not_claimed
        ):
            required_checks = LEGACY_EXTENSION_CHECKS

    checks = payload.get("checks")
    if not isinstance(checks, dict):
        errors.append("checks must be an object")
    else:
        if checks.keys() != required_checks:
            errors.append(
                f"checks fields must be exactly {sorted(required_checks)}"
            )
        for name in sorted(required_checks):
            if checks.get(name) is not True:
                errors.append(f"checks.{name} must be true")

    cleanup = payload.get("cleanup")
    if not isinstance(cleanup, dict):
        errors.append("cleanup must be an object")
    else:
        if cleanup.get("requested") is not True:
            errors.append("cleanup.requested must be true")
        if cleanup.get("forced") is not False:
            errors.append("cleanup.forced must be false")
        if cleanup.get("remainingPids") != []:
            errors.append("cleanup.remainingPids must be empty")

    profile = payload.get("profile")
    if not isinstance(profile, dict) or profile.get("removedAfterRun") is not True:
        errors.append("disposable profile cleanup is not retained")

    evidence = payload.get("evidence")
    final = evidence.get("99-final") if isinstance(evidence, dict) else None
    if not isinstance(final, dict):
        errors.append("final screenshot/OCR evidence is missing")
    else:
        for field in ("screenshot", "ocr"):
            name = final.get(field)
            if not isinstance(name, str) or not name:
                errors.append(f"final {field} path is missing")
            elif not (report_path.parent / name).is_file():
                errors.append(f"final {field} artifact does not exist: {name}")

    not_claimed = payload.get("notClaimed")
    if not isinstance(not_claimed, list) or "Assistive-technology sign-off" not in not_claimed:
        errors.append("manual assistive-technology boundary is missing")
    if not isinstance(not_claimed, list) or "macOS or Windows behavior" not in not_claimed:
        errors.append("non-Linux boundary is missing")
    if journey == "scm":
        validate_scm_recovery(payload, errors)
    elif journey == "debug":
        validate_debug_recovery(payload, errors)
    elif journey == "terminal":
        validate_terminal_lifecycle(payload, errors)
    elif journey == "recovery":
        validate_recovery(payload, errors, report_path)
    return errors


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    report_path = args.report or ROOT / "build" / "ui-ux" / f"native-{args.journey}" / "report.json"
    if not report_path.is_file():
        print(f"native {args.journey} report check failed: missing {report_path}", file=sys.stderr)
        return 1
    try:
        payload = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"native {args.journey} report check failed: {exc}", file=sys.stderr)
        return 1
    if not isinstance(payload, dict):
        print(f"native {args.journey} report check failed: root must be an object", file=sys.stderr)
        return 1
    errors = validate(payload, args.journey, report_path)
    if errors:
        print(f"native {args.journey} report check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"native {args.journey} report ok: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
