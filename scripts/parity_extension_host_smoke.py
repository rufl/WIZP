#!/usr/bin/env python3
"""Extension-host parity smoke for command activation/dispatch."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "bin" / "wizp"
FIXTURE = ROOT / "testdata" / "extensions" / "basic-api-smoke"
RPC_URL = "http://127.0.0.1:9876/api/rpc"
BASE_URL = "http://127.0.0.1:9876"


def free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])




def write_extension(root: Path, name: str, package: dict, extension_js: str) -> None:
    ext_dir = root / name
    ext_dir.mkdir(parents=True)
    (ext_dir / "package.json").write_text(json.dumps(package, indent=2))
    (ext_dir / "extension.js").write_text(extension_js)


def write_raw_extension(root: Path, name: str, package_json: str, extension_js: str = "") -> None:
    ext_dir = root / name
    ext_dir.mkdir(parents=True)
    (ext_dir / "package.json").write_text(package_json)
    if extension_js:
        (ext_dir / "extension.js").write_text(extension_js)


def write_activation_event_extension(root: Path, event_name: str, activation_event: str) -> None:
    command = f"activation-event-smoke.{event_name}"
    write_extension(
        root,
        f"activation-event-smoke-{event_name}",
        {
            "name": f"activation-event-smoke-{event_name}",
            "displayName": f"Activation Event Smoke {event_name}",
            "version": "0.0.1",
            "main": "extension.js",
            "activationEvents": [activation_event],
            "contributes": {"commands": [{"command": command, "title": f"Activation Event Smoke {event_name}"}]},
        },
        f"""
const vscode = require('vscode');

function activate(context) {{
  globalThis.__wizpActivationEventSmoke = globalThis.__wizpActivationEventSmoke || [];
  globalThis.__wizpActivationEventSmoke.push('{event_name}');
  context.subscriptions.push(vscode.commands.registerCommand('{command}', () => ({{
    eventName: '{event_name}',
    activationEvent: '{activation_event}',
    activatedEvents: globalThis.__wizpActivationEventSmoke.slice()
  }})));
}}

module.exports = {{ activate }};
""".strip(),
    )


def rpc(method: str, params: dict | None = None, request_id: int = 1):
    body: dict = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        body["params"] = params
    data = json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(RPC_URL, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = json.loads(response.read().decode())
    if "error" in payload:
        raise AssertionError(f"{method} returned error: {payload}")
    return payload["result"]


def http_get(path: str):
    with urllib.request.urlopen(BASE_URL + path, timeout=30) as response:
        return response.read().decode()


def wait_for_server(timeout: float = 15.0, required_command: str | None = None):
    deadline = time.time() + timeout
    last_commands = None
    while time.time() < deadline:
        try:
            result = rpc("extension/commands")
            commands = result.get("commands", [])
            last_commands = commands
            if required_command is None or any(command.get("command") == required_command for command in commands):
                return result
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(0.1)
    if required_command is not None:
        raise TimeoutError(f"WIZP extension command did not become ready: {required_command}; last={last_commands}")
    raise TimeoutError("WIZP HTTP RPC server did not become ready")


def main() -> int:
    if not BIN.exists():
        raise SystemExit(f"missing WIZP binary: {BIN}; run npm run build first")
    global RPC_URL, BASE_URL
    port = free_loopback_port()
    RPC_URL = f"http://127.0.0.1:{port}/api/rpc"
    BASE_URL = f"http://127.0.0.1:{port}"

    with tempfile.TemporaryDirectory(prefix="wizp-ext-host-smoke-") as tmp:
        root = Path(tmp)
        home = root / "home"
        ext_root = home / ".wizp" / "extensions"
        workspace = root / "workspace"
        ext_root.mkdir(parents=True)
        workspace.mkdir()
        shutil.copytree(FIXTURE, ext_root / "basic-api-smoke")
        write_extension(
            ext_root,
            "startup-activation-smoke",
            {
                "name": "startup-activation-smoke",
                "displayName": "Startup Activation Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["*"],
                "contributes": {
                    "commands": [
                        {"command": "startup-activation-smoke.status", "title": "Startup Activation Smoke Status"}
                    ]
                },
            },
            """
const vscode = require('vscode');

function activate(context) {
  globalThis.__wizpStartupActivationSmoke = (globalThis.__wizpStartupActivationSmoke || 0) + 1;
  context.subscriptions.push(vscode.commands.registerCommand('startup-activation-smoke.status', () => ({
    startupActivated: true,
    count: globalThis.__wizpStartupActivationSmoke
  })));
}

module.exports = { activate };
""".strip(),
        )
        write_extension(
            ext_root,
            "dependency-activation-base",
            {
                "name": "dependency-activation-base",
                "displayName": "Dependency Activation Base",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:dependency-activation-base.never"],
                "contributes": {
                    "commands": [
                        {"command": "dependency-activation-base.status", "title": "Dependency Activation Base Status"}
                    ]
                },
            },
            """
const vscode = require('vscode');

function activate(context) {
  globalThis.__wizpDependencyActivationOrder = globalThis.__wizpDependencyActivationOrder || [];
  globalThis.__wizpDependencyActivationOrder.push('base');
  context.subscriptions.push(vscode.commands.registerCommand('dependency-activation-base.status', () => ({
    baseActivated: true,
    order: globalThis.__wizpDependencyActivationOrder.slice()
  })));
}

module.exports = { activate };
""".strip(),
        )
        write_extension(
            ext_root,
            "dependency-activation-dependent",
            {
                "name": "dependency-activation-dependent",
                "displayName": "Dependency Activation Dependent",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:dependency-activation-dependent.run"],
                "extensionDependencies": ["dependency-activation-base"],
                "extensionPack": ["startup-activation-smoke"],
                "contributes": {
                    "commands": [
                        {"command": "dependency-activation-dependent.run", "title": "Dependency Activation Dependent Run"}
                    ]
                },
            },
            """
const vscode = require('vscode');
const path = require('path');

function activate(context) {
  globalThis.__wizpDependencyActivationOrder = globalThis.__wizpDependencyActivationOrder || [];
  globalThis.__wizpDependencyActivationOrder.push('dependent');
  context.subscriptions.push(vscode.commands.registerCommand('dependency-activation-dependent.run', async () => {
    const base = await vscode.commands.executeCommand('dependency-activation-base.status');
    return {
      dependentActivated: true,
      baseActivated: !!(base && base.baseActivated),
      order: globalThis.__wizpDependencyActivationOrder.slice(),
      pathJoin: path.join('/wizp', 'extension-host', '..', 'smoke.js')
    };
  }));
}

module.exports = { activate };
""".strip(),
        )
        write_extension(
            ext_root,
            "lifecycle-deactivation-smoke",
            {
                "name": "lifecycle-deactivation-smoke",
                "displayName": "Lifecycle Deactivation Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:lifecycle-deactivation-smoke.activate"],
                "contributes": {
                    "commands": [
                        {"command": "lifecycle-deactivation-smoke.activate", "title": "Lifecycle Deactivation Smoke Activate"}
                    ]
                },
            },
            """
const vscode = require('vscode');

function activate(context) {
  globalThis.__wizpDeactivateSmoke = ['activate'];
  context.subscriptions.push(vscode.commands.registerCommand('lifecycle-deactivation-smoke.activate', () => ({
    lifecycleActivated: true,
    log: globalThis.__wizpDeactivateSmoke.slice()
  })));
}

async function deactivate() {
  globalThis.__wizpDeactivateSmoke.push('deactivate:start');
  await new Promise((resolve) => setTimeout(resolve, 0));
  globalThis.__wizpDeactivateSmoke.push('deactivate:done');
  return 'deactivate-return';
}

module.exports = { activate, deactivate };
""".strip(),
        )
        write_extension(
            ext_root,
            "async-activation-smoke",
            {
                "name": "async-activation-smoke",
                "displayName": "Async Activation Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:async-activation-smoke.run"],
                "contributes": {
                    "commands": [
                        {"command": "async-activation-smoke.run", "title": "Async Activation Smoke Run"}
                    ]
                },
            },
            """
const vscode = require('vscode');

async function activate(context) {
  globalThis.__wizpAsyncActivationSmoke = ['activate:start'];
  await new Promise((resolve) => setTimeout(resolve, 0));
  globalThis.__wizpAsyncActivationSmoke.push('activate:done');
  context.subscriptions.push(vscode.commands.registerCommand('async-activation-smoke.run', () => ({
    asyncActivated: true,
    log: globalThis.__wizpAsyncActivationSmoke.slice()
  })));
  return { exported: true };
}

module.exports = { activate };
""".strip(),
        )
        write_extension(
            ext_root,
            "node-builtins-smoke",
            {
                "name": "node-builtins-smoke",
                "displayName": "Node Builtins Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:node-builtins-smoke.run"],
                "contributes": {
                    "commands": [
                        {"command": "node-builtins-smoke.run", "title": "Node Builtins Smoke Run"}
                    ]
                },
            },
            """
const vscode = require('vscode');
const os = require('os');
const nodeOs = require('node:os');
const processShim = require('process');
const nodeProcess = require('node:process');
const fs = require('fs');
const childProcess = require('node:child_process');
const util = require('node:util');
const plainUtil = require('util');
const assertShim = require('node:assert');
const assertStrict = require('assert/strict');
const nodeUrl = require('node:url');
const dns = require('node:dns');
const dnsPromises = require('node:dns/promises');
const nodeModule = require('module');
const nodeConsole = require('node:console');
const asyncHooks = require('node:async_hooks');
const nodeBuffer = require('node:buffer');
const nodeEvents = require('node:events');
const nodeHttp = require('node:http');
const nodeHttps = require('node:https');
const path = require('path');

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand('node-builtins-smoke.run', async () => ({
    ...(() => {
      const diskDir = path.join(processShim.cwd(), 'node-builtins-disk');
      const diskFile = path.join(diskDir, 'fixture.txt');
      fs.mkdirSync(diskDir, { recursive: true });
      fs.writeFileSync(diskFile, 'disk-data');
      fs.accessSync(diskFile);
      return {
        fsExists: fs.existsSync(diskFile),
        fsRead: fs.readFileSync(diskFile, 'utf8'),
        fsStatFile: fs.statSync(diskFile).isFile(),
        fsReaddir: fs.readdirSync(diskDir).includes('fixture.txt'),
        childOutput: childProcess.execFileSync('/bin/sh', ['-c', 'printf wizp-child'], { encoding: 'utf8' })
      };
    })(),
    childSpawnBuffers: await new Promise((resolve) => {
      const proc = childProcess.spawn('/bin/sh', ['-c', 'printf out; printf err >&2'], { stdio: ['ignore', 'pipe', 'pipe'] });
      const stdout = [];
      const stderr = [];
      proc.stdout.on('data', (chunk) => stdout.push(nodeBuffer.Buffer.isBuffer(chunk)));
      proc.stderr.on('data', (chunk) => stderr.push(nodeBuffer.Buffer.isBuffer(chunk)));
      proc.on('error', (error) => resolve({ error: String(error && error.message ? error.message : error) }));
      proc.on('close', (code) => resolve({ code, stdout, stderr }));
    }),
    childSpawnAsyncIterable: await (async () => {
      const proc = childProcess.spawn('/bin/sh', ['-c', 'printf async-out; printf async-err >&2'], { stdio: ['ignore', 'pipe', 'pipe'] });
      const readStream = async (stream) => {
        const chunks = [];
        for await (const chunk of stream) chunks.push(nodeBuffer.Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk));
        return chunks.join('');
      };
      const [stdout, stderr, code] = await Promise.all([
        readStream(proc.stdout),
        readStream(proc.stderr),
        new Promise((resolve) => proc.on('close', resolve)),
      ]);
      return { code, stdout, stderr };
    })(),
    blockedFetch: await (async () => {
      const response = await fetch('https://example.invalid/wizp-blocked-fetch-smoke');
      const body = await response.json();
      return {
        ok: response.ok,
        status: response.status,
        blocked: body.blocked === true,
        url: body.url
      };
    })(),
    blockedSecretFetchRedaction: await (async () => {
      const secretUrl = 'https://client:created-smoke-token@example.invalid/wizp-secret-fetch?access_token=real-smoke-token&api_key=created-smoke-token&safe=ok#frag';
      const before = (globalThis._wizpNetworkAudit || []).length;
      const response = await fetch(secretUrl);
      const body = await response.json();
      const entries = (globalThis._wizpNetworkAudit || []).slice(before);
      const surface = JSON.stringify({ body, entries });
      return {
        ok: response.ok,
        status: response.status,
        blocked: body.blocked === true,
        url: body.url,
        auditOptions: entries.map((entry) => entry.options || ''),
        auditHost: entries[0] && entries[0].host,
        auditAllowlisted: !!(entries[0] && entries[0].allowlisted),
        auditExplicitConsent: !!(entries[0] && entries[0].explicitConsent),
        auditPassthrough: entries[0] && entries[0].passthrough,
        auditFetchResolved: !!(entries[0] && entries[0].fetchResolved),
        leaked: surface.includes('real-smoke-token') || surface.includes('created-smoke-token'),
        redacted: surface.includes('REDACTED')
      };
    })(),
    blockedSecretHttpRedaction: await new Promise((resolve) => {
      const secretUrl = 'https://client:created-smoke-token@example.invalid/wizp-secret-http?token=real-smoke-token&password=created-smoke-token&safe=ok';
      const before = (globalThis._wizpNetworkAudit || []).length;
      const req = nodeHttps.request(secretUrl, (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(nodeBuffer.Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk)));
        response.on('end', () => {
          let body = {};
          try { body = JSON.parse(chunks.join('') || '{}'); } catch (error) { body = { parseError: String(error && error.message ? error.message : error) }; }
          const entries = (globalThis._wizpNetworkAudit || []).slice(before);
          const surface = JSON.stringify({ body, entries });
          resolve({
            status: response.statusCode,
            blocked: body.blocked === true,
            url: body.url,
            auditOptions: entries.map((entry) => entry.options || ''),
            auditHost: entries[0] && entries[0].host,
            auditAllowlisted: !!(entries[0] && entries[0].allowlisted),
            auditExplicitConsent: !!(entries[0] && entries[0].explicitConsent),
            auditPassthrough: entries[0] && entries[0].passthrough,
            auditFetchResolved: !!(entries[0] && entries[0].fetchResolved),
            leaked: surface.includes('real-smoke-token') || surface.includes('created-smoke-token'),
            redacted: surface.includes('REDACTED')
          });
        });
      });
      req.on('error', (error) => resolve({ error: String(error && error.message ? error.message : error) }));
      req.end();
    }),
    osPlatform: os.platform(),
    nodeOsPlatform: nodeOs.platform(),
    osArch: os.arch(),
    osHostname: os.hostname(),
    osUserInfo: os.userInfo().username,
    osNetworkInterfaces: os.networkInterfaces(),
    processPlatform: processShim.platform,
    nodeProcessArch: nodeProcess.arch,
    cwd: processShim.cwd(),
    hasNextTick: typeof processShim.nextTick === 'function',
    globalProcess: globalThis.process && globalThis.process.platform,
    hrtimeShape: (() => {
      const start = processShim.hrtime();
      const delta = processShim.hrtime(start);
      return Array.isArray(start) && start.length === 2 && Array.isArray(delta) && delta.length === 2 && typeof processShim.hrtime.bigint() === 'bigint';
    })(),
    utilFormat: util.format('hello %s %d', 'wizp', 7),
    utilInspect: plainUtil.inspect({ ok: true }),
    utilTypes: util.types.isNativeError(new Error('x')) && util.types.isPromise(Promise.resolve(true)),
    utilPromisify: typeof util.promisify === 'function',
    utilDeprecate: util.deprecate((value) => value + 1, 'wizp deprecated smoke')(6),
    assertOk: (() => { assertShim.ok(true); assertStrict.strictEqual(2 + 2, 4); return true; })(),
    fileUrlPath: nodeUrl.fileURLToPath(nodeUrl.pathToFileURL('/tmp/wizp smoke.txt')),
    parsedUrlHost: nodeUrl.parse('https://example.test/a?b=1').host,
    dnsLookupLocalhost: await dnsPromises.lookup('localhost'),
    dnsCallbackLocalhost: await new Promise((resolve, reject) => {
      dns.lookup('localhost', (error, address, family) => error ? reject(error) : resolve({ address, family }));
    }),
    dnsOrderApi: typeof dns.getDefaultResultOrder === 'function' && typeof dns.setDefaultResultOrder === 'function',
    modulePrototypeRequire: nodeModule.prototype.require('path').join('/wizp', 'module.js'),
    moduleResolve: nodeModule._resolveFilename('path'),
    moduleCreateRequire: nodeModule.createRequire(__filename)('path').basename('/tmp/wizp-module.txt'),
    moduleNatives: Object.keys(processShim.binding('natives')).includes('console') && Object.keys(processShim.binding('natives')).includes('module') && Object.keys(processShim.binding('natives')).includes('async_hooks'),
    consoleApi: typeof nodeConsole.Console === 'function' && typeof nodeConsole.log === 'function',
    asyncHooksStore: (() => {
      const storage = new asyncHooks.AsyncLocalStorage();
      return storage.run({ traceId: 'wizp-async' }, () => storage.getStore().traceId);
    })(),
    asyncResourceScope: (() => {
      const resource = new asyncHooks.AsyncResource('wizp-smoke');
      return typeof asyncHooks.createHook().enable().disable === 'function'
        && resource.asyncId() > 0
        && resource.runInAsyncScope((value) => value, null, 'resource-ok') === 'resource-ok';
    })(),
    eventsStaticEmitter: (() => {
      const emitter = new nodeEvents.EventEmitter();
      nodeEvents.setMaxListeners(23, emitter);
      return emitter.getMaxListeners() === 23 && nodeEvents.getMaxListeners(emitter) === 23;
    })(),
    eventsStaticAbortSignal: (() => {
      const controller = new AbortController();
      nodeEvents.setMaxListeners(17, controller.signal);
      return nodeEvents.getMaxListeners(controller.signal) === 17;
    })(),
    eventsAddAbortListener: await new Promise((resolve) => {
      const controller = new AbortController();
      let count = 0;
      const disposable = nodeEvents.addAbortListener(controller.signal, () => { count += 1; });
      controller.abort();
      setTimeout(() => {
        if (disposable && typeof disposable.dispose === 'function') disposable.dispose();
        resolve(count === 1);
      }, 0);
    }),
    httpAgentOptionsMutable: (() => {
      const agent = new nodeHttp.Agent({ keepAlive: true, maxSockets: 11 });
      nodeHttp.globalAgent.options.localAddress = '127.0.0.1';
      return typeof nodeHttp.request === 'function'
        && typeof nodeHttp.get === 'function'
        && agent.options.keepAlive === true
        && agent.maxSockets === 11
        && nodeHttp.globalAgent.options.localAddress === '127.0.0.1';
    })(),
    httpsAgentOptionsMutable: (() => {
      const agent = new nodeHttps.Agent({ rejectUnauthorized: false });
      nodeHttps.globalAgent.options.rejectUnauthorized = false;
      return typeof nodeHttps.request === 'function'
        && typeof nodeHttps.get === 'function'
        && agent.options.rejectUnauthorized === false
        && nodeHttps.globalAgent.options.rejectUnauthorized === false;
    })()
  })));
}

module.exports = { activate };
""".strip(),
        )
        write_extension(
            ext_root,
            "activation-error-smoke",
            {
                "name": "activation-error-smoke",
                "displayName": "Activation Error Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:activation-error-smoke.run"],
                "contributes": {
                    "commands": [
                        {"command": "activation-error-smoke.run", "title": "Activation Error Smoke Run"}
                    ]
                },
            },
            """
function activate() {
  throw new Error('activation-error-smoke boom');
}

module.exports = { activate };
""".strip(),
        )
        activation_event_smokes = [
            ("language", "onLanguage:smokelang", "language:smokelang"),
            ("workspace", "workspaceContains:package.json", "workspaceContains:package.json"),
            ("workspaceGlob", "workspaceContains:**/nested.lock", "workspaceContains:config/nested.lock"),
            ("workspaceEventGlob", "workspaceContains:src/**/*.wizp", "workspaceContains:src/deep/feature.wizp"),
            ("view", "onView:wizp.testView", "view:wizp.testView"),
            ("debug", "onDebug", "debug"),
            ("debugResolve", "onDebugResolve:node", "debugResolve:node"),
            ("task", "onTaskType:wizp", "task:wizp"),
            ("fileSystem", "onFileSystem:memfs", "fileSystem:memfs"),
        ]
        for event_name, activation_event, _ in activation_event_smokes:
            write_activation_event_extension(ext_root, event_name, activation_event)
        write_extension(
            ext_root,
            "enable-disable-smoke",
            {
                "name": "enable-disable-smoke",
                "publisher": "wizp-smoke",
                "displayName": "Enable Disable Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onLanguage:disablelang"],
                "contributes": {
                    "commands": [
                        {"command": "enable-disable-smoke.status", "title": "Enable Disable Smoke Status"}
                    ]
                },
            },
            """
const vscode = require('vscode');

function activate(context) {
  globalThis.__wizpEnableDisableSmoke = (globalThis.__wizpEnableDisableSmoke || 0) + 1;
  context.subscriptions.push(vscode.commands.registerCommand('enable-disable-smoke.status', () => ({
    activated: true,
    count: globalThis.__wizpEnableDisableSmoke
  })));
}

module.exports = { activate };
""".strip(),
        )
        (home / ".wizp" / "disabled-extensions").write_text("wizp-smoke.enable-disable-smoke\n")
        for name, command, key in [
            ("keybinding-conflict-a", "keybinding-conflict-a.run", "ctrl+shift+9"),
            ("keybinding-conflict-b", "keybinding-conflict-b.run", "ctrl+shift+9"),
            ("keybinding-chord-smoke", "keybinding-chord-smoke.run", "ctrl+k ctrl+9"),
        ]:
            write_extension(
                ext_root,
                name,
                {
                    "name": name,
                    "displayName": name,
                    "version": "0.0.1",
                    "main": "extension.js",
                    "activationEvents": [f"onCommand:{command}"],
                    "contributes": {
                        "commands": [{"command": command, "title": command}],
                        "keybindings": [{"command": command, "key": key, "when": "basicApiSmoke.enabled"}],
                    },
                },
                """
module.exports = { activate() {} };
""".strip(),
            )
        write_extension(
            ext_root,
            "save-bridge-smoke",
            {
                "name": "save-bridge-smoke",
                "displayName": "Save Bridge Smoke",
                "version": "0.0.1",
                "main": "extension.js",
                "activationEvents": ["onCommand:save-bridge-smoke.setup"],
                "contributes": {
                    "commands": [{"command": "save-bridge-smoke.setup", "title": "Save Bridge Smoke Setup"}]
                },
            },
            """
const vscode = require('vscode');

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand('save-bridge-smoke.setup', () => {
    context.subscriptions.push(vscode.workspace.onWillSaveTextDocument((event) => {
      if (!event.document.fileName.endsWith('save-bridge.txt')) return;
      event.waitUntil(Promise.resolve([
        vscode.TextEdit.insert(new vscode.Position(0, 0), 'bridge\\n')
      ]));
    }));
    return { ready: true };
  }));
}

module.exports = { activate };
""".strip(),
        )
        write_raw_extension(ext_root, "malformed-json-smoke", "{")
        write_raw_extension(
            ext_root,
            "malformed-types-smoke",
            json.dumps(
                {
                    "name": "malformed-types-smoke",
                    "version": "0.0.1",
                    "activationEvents": ["onCommand:malformed-types-smoke.run", 7],
                    "contributes": {
                        "commands": [
                            {"command": "malformed-types-smoke.run", "title": "Malformed Types Smoke"}
                        ]
                    },
                }
            ),
            "const vscode = require('vscode'); module.exports = { activate() { vscode.commands.registerCommand('malformed-types-smoke.run', () => true); } };",
        )
        (workspace / "basic-api-smoke-input.txt").write_text("fixture-data")
        (workspace / "package.json").write_text('{"name":"workspace-contains-smoke"}')
        (workspace / "config").mkdir()
        (workspace / "config" / "nested.lock").write_text("glob discovery")

        env = os.environ.copy()
        env["WIZP_PORT"] = str(port)
        env["HOME"] = str(home)
        env["WIZP_EXTENSION_DIR"] = str(ext_root)
        env["WIZP_EXTENSION_MESSAGE_SELECTION"] = "first"
        env["WIZP_EXTENSION_NETWORK_ALLOWLIST"] = "example.invalid"

        def launch_daemon():
            return subprocess.Popen([str(BIN)], cwd=str(workspace), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        proc = launch_daemon()
        try:
            commands = wait_for_server(required_command="basic-api-smoke.run")["commands"]
            assert any(command["command"] == "basic-api-smoke.run" for command in commands), commands
            assert any(command["command"] == "startup-activation-smoke.status" for command in commands), commands
            assert any(command["command"] == "dependency-activation-dependent.run" for command in commands), commands
            assert not any(command["command"] == "malformed-types-smoke.run" for command in commands), commands
            result = {"activated": True}
            for retry in range(5):
                if isinstance(result, dict) and result != {"activated": True}:
                    break
                time.sleep(0.1)
                try:
                    result = rpc("extension/execute", {"command": "startup-activation-smoke.status"}, request_id=430 + retry)
                except (TimeoutError, urllib.error.URLError):
                    result = {"activated": True}
            assert result.get("startupActivated") is True, result
            assert result["count"] == 1, result
            result = rpc("extension/execute", {"command": "dependency-activation-dependent.run"}, request_id=44)
            assert result["dependentActivated"] is True, result
            assert result["baseActivated"] is True, result
            assert result["order"] == ["base", "dependent"], result
            assert result["pathJoin"] == "/wizp/smoke.js", result
            result = rpc("extension/execute", {"command": "async-activation-smoke.run"}, request_id=70)
            assert result["asyncActivated"] is True, result
            assert result["log"] == ["activate:start", "activate:done"], result
            result = rpc("extension/execute", {"command": "node-builtins-smoke.run"}, request_id=78)
            assert result["osPlatform"] == result["nodeOsPlatform"] == "linux", result
            assert result["osArch"] == result["nodeProcessArch"] == "x64", result
            assert result["osHostname"] == "wizp-localhost", result
            assert isinstance(result["osUserInfo"], str) and result["osUserInfo"], result
            assert result["osNetworkInterfaces"] == {}, result
            assert result["processPlatform"] == "linux", result
            assert Path(result["cwd"]).resolve() == workspace.resolve(), result
            assert result["hasNextTick"] is True, result
            assert result["globalProcess"] == "linux", result
            assert result["hrtimeShape"] is True, result
            assert result["utilFormat"] == "hello wizp 7", result
            assert '"ok":true' in result["utilInspect"], result
            assert result["utilTypes"] is True and result["utilPromisify"] is True, result
            assert result["utilDeprecate"] == 7, result
            assert result["assertOk"] is True, result
            assert result["fileUrlPath"] == "/tmp/wizp smoke.txt", result
            assert result["parsedUrlHost"] == "example.test", result
            assert result["dnsLookupLocalhost"]["family"] in (4, 6), result
            assert result["dnsLookupLocalhost"]["address"] in ("127.0.0.1", "::1"), result
            assert result["dnsCallbackLocalhost"]["family"] in (4, 6), result
            assert result["dnsCallbackLocalhost"]["address"] in ("127.0.0.1", "::1"), result
            assert result["dnsOrderApi"] is True, result
            assert result["modulePrototypeRequire"] == "/wizp/module.js", result
            assert result["moduleResolve"] == "path", result
            assert result["moduleCreateRequire"] == "wizp-module.txt", result
            assert result["moduleNatives"] is True, result
            assert result["consoleApi"] is True, result
            assert result["asyncHooksStore"] == "wizp-async", result
            assert result["asyncResourceScope"] is True, result
            assert result["eventsStaticEmitter"] is True, result
            assert result["eventsStaticAbortSignal"] is True, result
            assert result["eventsAddAbortListener"] is True, result
            assert result["httpAgentOptionsMutable"] is True, result
            assert result["httpsAgentOptionsMutable"] is True, result
            assert result["fsExists"] is True, result
            assert result["fsRead"] == "disk-data", result
            assert result["fsStatFile"] is True, result
            assert result["fsReaddir"] is True, result
            assert result["childOutput"] == "wizp-child", result
            assert result["childSpawnBuffers"]["code"] == 0, result
            assert result["childSpawnBuffers"]["stdout"] and all(result["childSpawnBuffers"]["stdout"]), result
            assert result["childSpawnBuffers"]["stderr"] and all(result["childSpawnBuffers"]["stderr"]), result
            assert result["childSpawnAsyncIterable"]["code"] == 0, result
            assert result["childSpawnAsyncIterable"]["stdout"] == "async-out", result
            assert result["childSpawnAsyncIterable"]["stderr"] == "async-err", result
            assert result["blockedFetch"]["ok"] is False, result
            assert result["blockedFetch"]["status"] == 451, result
            assert result["blockedFetch"]["blocked"] is True, result
            assert result["blockedFetch"]["url"] == "https://example.invalid/wizp-blocked-fetch-smoke", result
            assert result["blockedSecretFetchRedaction"]["ok"] is False, result
            assert result["blockedSecretFetchRedaction"]["status"] == 451, result
            assert result["blockedSecretFetchRedaction"]["blocked"] is True, result
            assert result["blockedSecretFetchRedaction"]["leaked"] is False, result
            assert result["blockedSecretFetchRedaction"]["redacted"] is True, result
            assert result["blockedSecretFetchRedaction"]["auditHost"] == "example.invalid", result
            assert result["blockedSecretFetchRedaction"]["auditAllowlisted"] is True, result
            assert result["blockedSecretFetchRedaction"]["auditExplicitConsent"] is False, result
            assert result["blockedSecretFetchRedaction"]["auditPassthrough"] == "blocked", result
            assert result["blockedSecretFetchRedaction"]["auditFetchResolved"] is False, result
            assert "access_token=REDACTED" in result["blockedSecretFetchRedaction"]["url"], result
            assert "api_key=REDACTED" in result["blockedSecretFetchRedaction"]["url"], result
            assert result["blockedSecretFetchRedaction"]["auditOptions"] == [
                result["blockedSecretFetchRedaction"]["url"]
            ], result
            assert result["blockedSecretHttpRedaction"]["status"] == 451, result
            assert result["blockedSecretHttpRedaction"]["blocked"] is True, result
            assert result["blockedSecretHttpRedaction"]["leaked"] is False, result
            assert result["blockedSecretHttpRedaction"]["redacted"] is True, result
            assert result["blockedSecretHttpRedaction"]["auditHost"] == "example.invalid", result
            assert result["blockedSecretHttpRedaction"]["auditAllowlisted"] is True, result
            assert result["blockedSecretHttpRedaction"]["auditExplicitConsent"] is False, result
            assert result["blockedSecretHttpRedaction"]["auditPassthrough"] == "blocked", result
            assert result["blockedSecretHttpRedaction"]["auditFetchResolved"] is False, result
            assert "token=REDACTED" in result["blockedSecretHttpRedaction"]["url"], result
            assert "password=REDACTED" in result["blockedSecretHttpRedaction"]["url"], result
            assert result["blockedSecretHttpRedaction"]["auditOptions"] == [
                result["blockedSecretHttpRedaction"]["url"]
            ], result
            try:
                rpc("extension/execute", {"command": "activation-error-smoke.run"}, request_id=79)
                raise AssertionError("activation-error-smoke unexpectedly succeeded")
            except AssertionError as exc:
                assert "extension/execute returned error" in str(exc), exc
            errors = rpc("extension/activationErrors", request_id=80)
            error = next(item for item in errors["errors"] if item["id"] == "activation-error-smoke")
            assert errors["count"] >= 1, errors
            assert "activation-error-smoke boom" in error["message"], errors
            result = rpc("extension/activateByEvent", {"event": "language:not-a-startup"}, request_id=71)
            assert result["activated"] == 0, result
            result = rpc("extension/execute", {"command": "enable-disable-smoke.status"}, request_id=711)
            assert result is None, result
            result = rpc(
                "extension/execute",
                {"command": "workbench.extensions.disableExtension", "args": ["wizp-smoke.enable-disable-smoke"]},
                request_id=72,
            )
            assert result["disabled"] is True, result
            rpc("extension/languageProviders", {"languageId": "disablelang"}, request_id=73)
            result = rpc("extension/execute", {"command": "enable-disable-smoke.status"}, request_id=74)
            assert result is None, result
            result = rpc(
                "extension/execute",
                {"command": "workbench.extensions.enableExtension", "args": ["wizp-smoke.enable-disable-smoke"]},
                request_id=75,
            )
            assert result["enabled"] is True, result
            rpc("extension/languageProviders", {"languageId": "disablelang"}, request_id=76)
            result = rpc("extension/execute", {"command": "enable-disable-smoke.status"}, request_id=77)
            assert result["activated"] is True, result
            assert result["count"] == 1, result
            result = rpc("extension/execute", {"command": "lifecycle-deactivation-smoke.activate"}, request_id=45)
            assert result["lifecycleActivated"] is True, result
            assert result["log"] == ["activate"], result
            result = rpc("extension/deactivate", {"extensionId": "lifecycle-deactivation-smoke"}, request_id=46)
            assert result["deactivated"] is True, result
            assert result["value"] == "deactivate-return", result
            assert result["log"] == ["activate", "deactivate:start", "deactivate:done"], result
            result = rpc("extension/deactivate", {"extensionId": "lifecycle-deactivation-smoke"}, request_id=47)
            assert result["deactivated"] is False, result
            assert result["reason"] == "notActive", result
            for offset, (event_name, activation_event, trigger_event) in enumerate(activation_event_smokes):
                result = rpc("extension/execute", {"command": f"activation-event-smoke.{event_name}"}, request_id=48 + (offset * 3))
                if event_name in {"workspace", "workspaceGlob"}:
                    assert result["eventName"] == event_name, result
                    assert result["activationEvent"] == activation_event, result
                    continue
                assert result is None, result
                if event_name == "language":
                    rpc("extension/languageProviders", {"languageId": "smokelang"}, request_id=49 + (offset * 3))
                elif event_name == "view":
                    rpc("extension/views", {"view": "wizp.testView"}, request_id=49 + (offset * 3))
                elif event_name == "debug":
                    activated = rpc("extension/debugLifecycle", {"event": "debug"}, request_id=49 + (offset * 3))
                    assert activated["activated"] == 1, activated
                elif event_name == "debugResolve":
                    activated = rpc("extension/debugLifecycle", {"event": "debugResolve:node"}, request_id=49 + (offset * 3))
                    assert activated["activated"] == 1, activated
                elif event_name == "task":
                    http_get("/api/extension/tasks")
                elif event_name == "fileSystem":
                    activated = rpc("extension/fileSystemAccess", {"scheme": "memfs"}, request_id=49 + (offset * 3))
                    assert activated["activated"] == 1, activated
                elif event_name == "workspaceEventGlob":
                    activated = rpc("extension/activateByEvent", {"event": trigger_event}, request_id=49 + (offset * 3))
                    assert activated["event"] == trigger_event, activated
                    assert activated["activated"] == 1, activated
                else:
                    activated = rpc("extension/activateByEvent", {"event": trigger_event}, request_id=49 + (offset * 3))
                    assert activated["event"] == trigger_event, activated
                    assert activated["activated"] == 1, activated
                result = rpc("extension/execute", {"command": f"activation-event-smoke.{event_name}"}, request_id=50 + (offset * 3))
                assert result["eventName"] == event_name, result
                assert result["activationEvent"] == activation_event, result
                assert event_name in result["activatedEvents"], result
            gated = next(command for command in commands if command["command"] == "basic-api-smoke.enabledOnly")
            assert gated["enabled"] is False, gated
            result = rpc("extension/execute", {"command": "basic-api-smoke.run"}, request_id=3)
            assert result["commandRegistered"] is True, result
            assert result["messageShown"] is True, result
            assert result["messageItem"] is True, result
            assert result["quickPick"] is True, result
            assert result["inputBox"] is True, result
            assert result["progress"] is True, result
            assert result["statusBar"] is True, result
            assert result["outputChannel"] is True, result
            assert result["workspaceTrust"] is True, result
            assert result["workspaceTrustEvent"] is True, result
            assert result["fileRead"] is True, result
            assert result["fileWritten"] is True, result
            assert result.get("fsStat") is True, result
            assert result.get("fsReadDirectory") is True, result
            assert result.get("fsCopyRename") is True, result
            assert result.get("fsDelete") is True, result
            assert (workspace / "basic-api-smoke-output.txt").read_text() == "fixture-data"
            assert not (workspace / "basic-api-smoke-fs").exists()
            rpc("extension/execute", {"command": "setContext", "args": ["basicApiSmoke.enabled", True]}, request_id=4)
            rpc("extension/execute", {"command": "setContext", "args": ["resourceLangId", "zig"]}, request_id=5)
            commands = rpc("extension/commands", request_id=6)["commands"]
            gated = next(command for command in commands if command["command"] == "basic-api-smoke.enabledOnly")
            assert gated["enabled"] is True, gated
            result = rpc("extension/execute", {"command": "basic-api-smoke.enabledOnly"}, request_id=7)
            assert result["enabledOnly"] is True, result
            menus = rpc("extension/menus", {"menu": "editor/context"}, request_id=8)["menus"]
            menu_item = next(item for item in menus if item["command"] == "basic-api-smoke.menuCommand")
            assert menu_item["enabled"] is True, menu_item
            assert menu_item["group"] == "navigation@1", menu_item
            assert menu_item["alt"] == "basic-api-smoke.keybindingCommand", menu_item
            assert menu_item["args"] == ["from-menu"], menu_item
            result = rpc("extension/execute", {"command": "basic-api-smoke.menuCommand", "args": menu_item["args"]}, request_id=9)
            assert result["menuCommand"] is True, result
            assert result["source"] == "from-menu", result
            keybindings = rpc("extension/keybindings", {"platform": "linux"}, request_id=10)["keybindings"]
            keybinding = next(item for item in keybindings if item["command"] == "basic-api-smoke.keybindingCommand")
            assert keybinding["enabled"] is True, keybinding
            assert keybinding["key"] == "ctrl+alt+w", keybinding
            assert keybinding["isChord"] is False, keybinding
            assert keybinding["conflictCount"] == 1, keybinding
            conflict = next(item for item in keybindings if item["command"] == "keybinding-conflict-a.run")
            assert conflict["enabled"] is True, conflict
            assert conflict["key"] == "ctrl+shift+9", conflict
            assert conflict["conflictCount"] == 2, conflict
            chord = next(item for item in keybindings if item["command"] == "keybinding-chord-smoke.run")
            assert chord["enabled"] is True, chord
            assert chord["isChord"] is True, chord
            assert chord["conflictCount"] == 1, chord
            result = rpc("extension/execute", {"command": "basic-api-smoke.keybindingCommand"}, request_id=11)
            assert result["keybindingCommand"] is True, result
            config = rpc("extension/configuration", request_id=12)["configuration"]
            setting = next(item for item in config if item["key"] == "basicApiSmoke.enabledSetting")
            assert setting["default"] is True, setting
            assert setting["type"] == "boolean", setting
            result = rpc("extension/execute", {"command": "basic-api-smoke.diagnostics"}, request_id=13)
            assert result["diagnostics"] is True, result
            assert result["forEachCount"] == 1, result
            diagnostics = rpc("extension/diagnostics", request_id=14)["collections"]
            collection = next(item for item in diagnostics if item["name"] == "basic-api-smoke")
            assert len(collection["entries"]) == 1, collection
            entry = collection["entries"][0]
            assert entry["uri"].endswith("diag-b.txt"), entry
            assert entry["diagnostics"][0]["message"] == "final problem", entry
            assert entry["diagnostics"][0]["severity"] == 1, entry
            assert not any(item["name"] == "basic-api-smoke-temp" for item in diagnostics), diagnostics
            result = rpc("extension/execute", {"command": "basic-api-smoke.fsProvider"}, request_id=15)
            assert result["fsProvider"] is True, result
            assert result["statSize"] == 8, result
            assert result["listed"] is True, result
            assert result["copied"] is True, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.workspaceEdit"}, request_id=16)
            assert result["workspaceEdit"] is True, result
            assert result["firstText"] == "red fish\n", result
            assert result["secondText"] == "blue two fish\n", result
            assert result["renamedText"] == "created\n", result
            assert not (workspace / "workspace-edit-one.txt").exists()
            assert not (workspace / "workspace-edit-two.txt").exists()
            assert not (workspace / "workspace-edit-renamed.txt").exists()
            result = rpc("extension/execute", {"command": "basic-api-smoke.saveParticipant"}, request_id=17)
            assert result["saveParticipant"] is True, result
            assert result["willSaveSeen"] is True, result
            assert result["didSaveSeen"] is True, result
            assert result["diskText"] == "participant\nbody\n", result
            assert not (workspace / "save-participant.txt").exists()
            result = rpc("extension/execute", {"command": "basic-api-smoke.textDocumentEditorEvents"}, request_id=18)
            assert result["textDocumentEditorEvents"] is True, result
            assert result["saved"] is True, result
            assert result["activeMatches"] is True, result
            assert result["visibleCount"] >= 1, result
            assert result["viewColumn"] == 2, result
            assert result["selectionStartLine"] == 1, result
            assert result["selectionEndCharacter"] == 4, result
            assert result["visibleRangeStartLine"] == 1, result
            assert result["finalText"] == "start\nalpha\nbeta\n", result
            assert result["version"] == 2, result
            assert result["dirtyAfterSave"] is False, result
            assert result["isClosed"] is True, result
            assert [event.split(":", 1)[0] for event in result["events"]] == ["open", "change", "save", "close"], result
            assert "change:2:start\n" in result["events"], result
            result = rpc("extension/execute", {"command": "basic-api-smoke.terminalApi"}, request_id=19)
            assert result["terminalApi"] is True, result
            assert result["name"] == "Smoke Terminal", result
            assert result["processId"] > 0, result
            assert result["sentText"] == ["printf terminal-api", " && printf smoke\n"], result
            assert result["shown"] is False, result
            assert result["interacted"] is True, result
            assert result["activeBeforeDispose"] is True, result
            assert result["listedBeforeDispose"] is True, result
            assert result["listedAfterDispose"] is False, result
            assert result["exitStatusCode"] == 0, result
            assert result["exitStatusReason"] == 3, result
            assert result["events"] == ["open:Smoke Terminal", "active:Smoke Terminal", "active:Smoke Terminal", "close:Smoke Terminal", "active:none"], result
            result = rpc("extension/execute", {"command": "basic-api-smoke.terminalShellIntegration"}, request_id=190)
            assert result["terminalShellIntegration"] is True, result
            assert result["shellIntegrationPresent"] is True, result
            assert result["initialReady"] is True, result
            assert result["executionCommandLine"] == "source", result
            assert result["executionArgs"] == ["venv/bin/activate"], result
            assert result["sentText"] == ["source venv/bin/activate\n", "conda activate smoke-env\n"], result
            assert result["dataEvents"] == ["$ ", "$ ", "$ "], result
            assert result["startEvents"] == [{"commandLine": "source", "args": ["venv/bin/activate"]}], result
            assert result["endEvents"] == [{"commandLine": "source", "args": ["venv/bin/activate"], "exitCode": 0}], result
            assert len(result["integrationEvents"]) == 3, result
            assert result["integrationEvents"][0]["envKeys"] == [], result
            assert result["integrationEvents"][1]["envKeys"] == ["VIRTUAL_ENV"], result
            assert result["integrationEvents"][1]["envValue"]["VIRTUAL_ENV"] == "venv", result
            assert result["integrationEvents"][2]["envKeys"] == ["CONDA_PREFIX", "VIRTUAL_ENV"], result
            assert result["integrationEvents"][2]["envValue"]["CONDA_PREFIX"] == "smoke-env", result
            assert result["envKeys"] == ["CONDA_PREFIX", "VIRTUAL_ENV"], result
            assert result["virtualEnv"] == "venv", result
            assert result["condaPrefix"] == "smoke-env", result
            result = rpc("extension/execute", {"command": "basic-api-smoke.commentsLifecycle"}, request_id=191)
            assert result["commentsLifecycle"] is True, result
            assert result["controllerId"] == "smoke-comments-lifecycle", result
            assert result["controllerLabel"] == "Smoke Comments Lifecycle", result
            assert result["threadUri"] == "file:///workspace/comments-smoke.txt", result
            assert result["threadStartLine"] == 3, result
            assert result["threadStartCharacter"] == 2, result
            assert result["threadCommentCount"] == 1, result
            assert result["threadDispose"] is True, result
            assert result["controllerDispose"] is True, result
            assert result["uiEventCount"] >= 1, result
            assert result["uiEventUri"] == "/workspace/comments-smoke.txt", result
            assert result["uiEventLine"] == 3, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.apiPrimitives"}, request_id=20)
            assert result["apiPrimitives"] is True, result
            assert result["disposableCount"] == 11, result
            assert result["fired"] == ["one"], result
            assert result["cancelled"] is True, result
            assert result["tokenCancelled"] is True, result
            assert result["parsedScheme"] == "wizp", result
            assert result["parsedAuthority"] == "authority", result
            assert result["parsedPath"] == "/root/file.txt", result
            assert result["parsedQuery"] == "query=1", result
            assert result["parsedFragment"] == "frag", result
            assert result["joined"] == "file:///tmp/work/file.txt", result
            assert result["joinedHttps"] == "https://example.test/api/v1", result
            assert result["changed"] == "smoke://authority/changed?q=2#done", result
            assert result["jsonPath"] == "/changed", result
            assert result["jsonExternal"] == "smoke://authority/changed?q=2#done", result
            assert result["positionCompare"] == -1, result
            assert result["positionWithCharacter"] == 9, result
            assert result["rangeContains"] is True, result
            assert result["rangeIntersectionLine"] == 2, result
            assert result["rangeUnionEndCharacter"] == 1, result
            assert result["selectionReversed"] is True, result
            assert result["selectionStartLine"] == 1, result
            assert "```js" in result["markdownValue"], result
            assert result["markdownThemeIcons"] is True, result
            assert result["iconId"] == "zap", result
            assert result["iconColorId"] == "terminal.ansiGreen", result
            assert result["fileIconId"] == "file", result
            assert result["relativeBase"] == "/workspace", result
            assert result["relativePattern"] == "**/*.zig", result
            assert result["smokeCurrentLineFormat"] == "smoke-current-line-default", result
            assert result["smokeCurrentLineHasDefault"] is True, result
            assert result["smokeCurrentLineDirectFormat"] == result["smokeCurrentLineFormat"], result
            assert result["smokeCurrentLineInspectDefault"] == result["smokeCurrentLineFormat"], result
            result = rpc("extension/execute", {"command": "basic-api-smoke.extensionContext"}, request_id=21)
            assert result["extensionContext"] is True, result
            assert result["extensionPathEnds"] is True, result
            assert result["extensionUri"].endswith("basic-api-smoke"), result
            assert result["storageUri"].endswith(".wizp-context/wizp.basic-api-smoke"), result
            assert result["globalStorageUri"].endswith(".wizp-context/wizp.basic-api-smoke"), result
            assert result["logUri"].endswith(".wizp-context/logs"), result
            assert result["absolutePath"].endswith("basic-api-smoke/extension.js"), result
            assert result["extensionMode"] == 1, result
            assert result["packageName"] == "basic-api-smoke", result
            assert result["packageAiKeyType"] == "string", result
            assert result["extensionId"] == "wizp.basic-api-smoke", result
            assert result["extensionExportsActive"] is True, result
            assert result["quickInputInline"] == 2, result
            assert result["quickInputBack"] == "Back", result
            assert result["previousGlobal"] == 0, result
            assert result["currentGlobal"] == 1, result
            assert result["workspaceValue"] == {"ok": True, "run": 1}, result
            assert "runs" in result["globalKeys"], result
            assert result["secretBeforeDelete"] == "secret-value", result
            assert result["secretAfterDelete"] is None, result
            assert result["secretEvents"] == ["token", "token"], result
            assert result["envReplace"] == {"type": 1, "value": "one", "options": {}}, result
            assert result["envAppendDeleted"] is None, result
            assert result["envEntries"] == ["WIZP_APPEND:2:two", "WIZP_PREPEND:3:three", "WIZP_REPLACE:1:one"], result
            assert result["builtInGitEnv"] is True, result
            assert result["builtInGitRepositoryEvents"] is True, result
            assert result["scopedSame"] is True, result
            assert result["subscriptionsCount"] >= 1, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.extensionContext"}, request_id=22)
            assert result["previousGlobal"] == 1, result
            assert result["currentGlobal"] == 2, result
            assert result["workspaceValue"] == {"ok": True, "run": 2}, result
            global_memento = json.loads((ext_root / "basic-api-smoke" / ".wizp-context" / "global-memento.json").read_text())
            workspace_memento = json.loads(
                (ext_root / "basic-api-smoke" / ".wizp-context" / "workspace-memento.json").read_text()
            )
            assert global_memento["runs"] == 2, global_memento
            assert global_memento["__syncKeys"] == ["runs"], global_memento
            assert workspace_memento["workspaceValue"] == {"ok": True, "run": 2}, workspace_memento
            result = rpc("extension/execute", {"command": "basic-api-smoke.authSecretsPersistence"}, request_id=223)
            assert result["authSecretsPersistence"] is True, result
            assert result["before"] is None, result
            assert result["after"] == "persistent-secret-value", result
            assert result["backend"] == "encrypted-fallback", result
            assert result["osKeyring"] is False, result
            assert result["plaintextOnDisk"] is False, result
            secret_file = ext_root / "basic-api-smoke" / ".wizp-context" / "secrets-fallback.json"
            secret_payload = json.loads(secret_file.read_text())
            assert secret_payload["backend"] == "encrypted-fallback", secret_payload
            assert secret_payload["osKeyring"] is False, secret_payload
            assert "persistent-token" in secret_payload["values"], secret_payload
            assert "persistent-secret-value" not in secret_file.read_text(), secret_payload
            result = rpc("extension/deactivate", {"extensionId": "basic-api-smoke"}, request_id=220)
            assert result["deactivated"] is True, result
            result = rpc("extension/clearMementoCache", request_id=221)
            assert result["cleared"] is True, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.extensionContext"}, request_id=222)
            assert result["previousGlobal"] == 2, result
            assert result["currentGlobal"] == 3, result
            assert result["workspaceValue"] == {"ok": True, "run": 3}, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.authSecretsPersistence"}, request_id=224)
            assert result["before"] == "persistent-secret-value", result
            assert result["after"] == "persistent-secret-value", result
            assert result["backend"] == "encrypted-fallback", result
            proc.kill()
            proc.wait(timeout=5)
            time.sleep(0.1)
            proc = launch_daemon()
            commands = wait_for_server(required_command="basic-api-smoke.run")["commands"]
            assert any(command["command"] == "basic-api-smoke.longTailApis" for command in commands), commands
            result = rpc("extension/execute", {"command": "basic-api-smoke.extensionContext"}, request_id=225)
            assert result["previousGlobal"] == 3, result
            assert result["currentGlobal"] == 4, result
            assert result["workspaceValue"] == {"ok": True, "run": 4}, result
            global_memento = json.loads((ext_root / "basic-api-smoke" / ".wizp-context" / "global-memento.json").read_text())
            workspace_memento = json.loads(
                (ext_root / "basic-api-smoke" / ".wizp-context" / "workspace-memento.json").read_text()
            )
            assert global_memento["runs"] == 4, global_memento
            assert workspace_memento["workspaceValue"] == {"ok": True, "run": 4}, workspace_memento
            result = rpc("extension/execute", {"command": "basic-api-smoke.authSecretsPersistence"}, request_id=226)
            assert result["before"] == "persistent-secret-value", result
            assert result["after"] == "persistent-secret-value", result
            assert result["backend"] == "encrypted-fallback", result
            assert result["osKeyring"] is False, result
            assert result["plaintextOnDisk"] is False, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.decorations"}, request_id=23)
            assert result["decorations"] is True, result
            assert result["beforeCount"] == 1, result
            assert result["afterCount"] == 0, result
            assert result["startLine"] == 0, result
            assert result["startCharacter"] == 1, result
            assert result["endCharacter"] == 5, result
            assert result["hoverMessage"] == "decorated", result
            assert result["disposed"] is True, result
            decorations = rpc("extension/decorations", request_id=24)
            decoration_type = next(item for item in decorations["types"] if item["id"] == result["typeId"])
            assert decoration_type["disposed"] is True, decorations
            assert not any(
                item["typeId"] == result["typeId"] and item["ranges"]
                for editor in decorations["editors"]
                for item in editor["decorations"]
            ), decorations
            result = rpc("extension/execute", {"command": "basic-api-smoke.codeLensSetup"}, request_id=25)
            assert result["codeLensSetup"] is True, result
            lenses = rpc("extension/codeLenses", {"uri": "file://lens.txt"}, request_id=26)["lenses"]
            assert len(lenses) == 1, lenses
            lens = lenses[0]
            assert lens["range"]["start"]["line"] == 1, lens
            assert lens["range"]["end"]["character"] == 4, lens
            assert lens["command"]["title"] == "Run Lens", lens
            assert lens["command"]["command"] == "basic-api-smoke.codeLensCommand", lens
            result = rpc(
                "extension/execute",
                {"command": lens["command"]["command"], "args": lens["command"].get("arguments", [])},
                request_id=27,
            )
            assert result["codeLensCommand"] is True, result
            assert result["source"] == "from-codelens", result
            assert result["hits"] == 1, result
            result = rpc("extension/execute", {"command": "basic-api-smoke.inlayHintsSetup"}, request_id=28)
            assert result["inlayHintsSetup"] is True, result
            hints = rpc("extension/inlayHints", {"uri": "file://hints.txt"}, request_id=29)["hints"]
            assert len(hints) == 2, hints
            first, second = hints
            assert first["position"]["line"] == 0, first
            assert first["position"]["character"] == 4, first
            assert first["label"] == ": string", first
            assert first["kind"] == 1, first
            assert first["tooltip"] == "resolved by provider", first
            assert first["paddingLeft"] is True, first
            assert first["paddingRight"] is False, first
            assert second["position"]["line"] == 1, second
            assert second["position"]["character"] == 2, second
            assert second["label"] == "name:", second
            assert second["kind"] == 2, second
            assert second["tooltip"] == "resolved tooltip", second
            assert second["paddingRight"] is True, second
            result = rpc("extension/execute", {"command": "basic-api-smoke.semanticTokensSetup"}, request_id=30)
            assert result["semanticTokensSetup"] is True, result
            token_sets = rpc("extension/semanticTokens", {"uri": "file://semantic.txt"}, request_id=31)["tokens"]
            assert len(token_sets) == 1, token_sets
            token_set = token_sets[0]
            assert token_set["legend"]["tokenTypes"] == ["class", "function"], token_set
            assert token_set["legend"]["tokenModifiers"] == ["declaration", "static"], token_set
            assert token_set["resultId"] == "semantic-smoke", token_set
            assert token_set["data"] == [0, 0, 5, 0, 1, 1, 2, 4, 1, 2], token_set
            result = rpc("extension/execute", {"command": "basic-api-smoke.foldingRangesSetup"}, request_id=32)
            assert result["foldingRangesSetup"] is True, result
            folding_ranges = rpc("extension/foldingRanges", {"uri": "file://folding.txt"}, request_id=33)["ranges"]
            assert len(folding_ranges) == 2, folding_ranges
            first_fold = folding_ranges[0]
            second_fold = folding_ranges[1]
            assert first_fold["start"] == 0, first_fold
            assert first_fold["end"] == 3, first_fold
            assert first_fold["kind"] == "region", first_fold
            assert first_fold["startCharacter"] is None, first_fold
            assert second_fold["start"] == 5, second_fold
            assert second_fold["end"] == 7, second_fold
            assert second_fold["kind"] == "comment", second_fold
            assert second_fold["startCharacter"] == 1, second_fold
            assert second_fold["endCharacter"] == 9, second_fold
            result = rpc("extension/execute", {"command": "basic-api-smoke.languageProvidersSetup"}, request_id=34)
            assert result["languageProvidersSetup"] is True, result
            assert result["registrations"] == 13, result
            providers = rpc(
                "extension/languageProviders",
                {
                    "uri": "file://language-provider-source.txt",
                    "line": 2,
                    "character": 3,
                    "newName": "NewSmokeName",
                    "text": "oldName = smoke()\n",
                },
                request_id=35,
            )
            resolution = providers["providerResolution"]
            assert resolution["cancellationRequested"] is False, resolution
            completion_resolution = resolution["completion"]
            assert len(completion_resolution) == 3, completion_resolution
            assert completion_resolution[0]["score"] > completion_resolution[1]["score"], completion_resolution
            assert completion_resolution[1]["order"] < completion_resolution[2]["order"], completion_resolution
            completion_labels = {item["label"] for item in providers["completion"]["items"]}
            assert {"smokeCompletion", "smokeSecondCompletion", "smokeSpecificCompletion"} <= completion_labels, providers
            assert "smokeMarkdownOnlyCompletion" not in completion_labels, providers
            assert providers["completion"]["items"][0]["label"] == "smokeSpecificCompletion", providers
            completion = next(item for item in providers["completion"]["items"] if item["label"] == "smokeCompletion")
            assert completion["label"] == "smokeCompletion", providers
            assert completion["insertText"] == "smokeCompletion()", providers
            assert completion["detail"] == "fixture completion resolved", providers
            assert completion["documentation"] == "resolved completion docs", providers
            assert completion["commitCharacters"] == ["."], providers
            second_completion = next(item for item in providers["completion"]["items"] if item["label"] == "smokeSecondCompletion")
            assert second_completion["insertText"] == "smokeSecondCompletion()", providers
            assert second_completion["detail"] == "second fixture completion", providers
            assert providers["hover"]["contents"] == ["**Smoke Hover**", "`hover-docs`"], providers
            assert providers["hover"]["range"]["start"]["line"] == 2, providers
            signature = providers["signatureHelp"]
            assert signature["activeParameter"] == 1, signature
            assert signature["signatures"][0]["label"] == "smoke(a, b)", signature
            assert signature["signatures"][0]["parameters"][1]["documentation"] == "second param", signature
            definition = providers["definition"][0]
            assert definition["uri"].endswith("language-provider-target.txt"), definition
            assert definition["range"]["end"]["character"] == 7, definition
            declaration = providers["declaration"][0]
            assert declaration["uri"].endswith("language-provider-declaration.txt"), declaration
            assert declaration["range"]["start"]["line"] == 5, declaration
            type_definition = providers["typeDefinition"][0]
            assert type_definition["uri"].endswith("language-provider-type-definition.txt"), type_definition
            assert type_definition["range"]["end"]["character"] == 12, type_definition
            implementation = providers["implementation"][0]
            assert implementation["uri"].endswith("language-provider-implementation.txt"), implementation
            assert implementation["range"]["start"]["character"] == 3, implementation
            references = providers["references"]
            assert len(references) == 2, references
            assert references[1]["uri"].endswith("language-provider-reference.txt"), references
            assert providers["prepareRename"]["placeholder"] == "oldName", providers
            rename_changes = providers["rename"]["changes"]["file://language-provider-source.txt"]
            assert rename_changes[0]["newText"] == "NewSmokeName", rename_changes
            assert rename_changes[0]["range"]["end"]["character"] == 5, rename_changes
            action = providers["codeActions"][0]
            assert action["title"] == "Smoke Fix Resolved", action
            assert action["kind"] == "quickfix", action
            assert action["isPreferred"] is True, action
            assert action["command"]["command"] == "basic-api-smoke.keybindingCommand", action
            assert action["edit"]["changes"]["file://language-provider-source.txt"][0]["newText"] == "fixed", action
            cancelled_providers = rpc(
                "extension/languageProviders",
                {
                    "uri": "file://language-provider-source.txt",
                    "languageId": "plaintext",
                    "cancelled": True,
                    "text": "oldName = smoke()\n",
                },
                request_id=350,
            )
            assert cancelled_providers["providerResolution"]["cancellationRequested"] is True, cancelled_providers
            cancelled_labels = {item["label"] for item in cancelled_providers["completion"]["items"]}
            assert "smokeSpecificCompletionCancelled" in cancelled_labels, cancelled_providers
            assert "smokeMarkdownOnlyCompletion" not in cancelled_labels, cancelled_providers
            result = rpc("extension/execute", {"command": "basic-api-smoke.languageProvidersMoreSetup"}, request_id=36)
            assert result["languageProvidersMoreSetup"] is True, result
            assert result["registrations"] == 5, result
            more = rpc(
                "extension/languageProviders",
                {
                    "uri": "file://language-provider-source.txt",
                    "line": 3,
                    "character": 2,
                    "rangeStartLine": 5,
                    "rangeStartCharacter": 1,
                    "rangeEndLine": 5,
                    "rangeEndCharacter": 9,
                    "ch": ";",
                    "text": "format me\n",
                },
                request_id=37,
            )
            highlights = more["documentHighlights"]
            assert len(highlights) == 2, highlights
            assert highlights[0]["range"]["end"]["character"] == 12, highlights
            assert highlights[0]["kind"] == 1, highlights
            links = more["documentLinks"]
            assert len(links) == 2, links
            assert links[0]["target"].endswith("linked-target.txt"), links
            assert links[0]["tooltip"] == "open target", links
            assert links[1]["target"].endswith("resolved-link.txt"), links
            assert links[1]["tooltip"] == "resolved target", links
            assert more["documentFormatting"][0]["newText"] == "formatted-all", more
            assert more["rangeFormatting"][0]["newText"] == "formatted-range", more
            assert more["rangeFormatting"][0]["range"]["start"]["line"] == 5, more
            assert more["onTypeFormatting"][0]["newText"] == "typed-;", more
            assert more["onTypeFormatting"][0]["range"]["start"]["line"] == 3, more
            command_completion = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeCompletionItemProvider",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}, ".", 20],
                },
                request_id=371,
            )
            command_completion_labels = [item["label"] for item in command_completion["items"]]
            assert command_completion_labels[0] == "smokeSpecificCompletion", command_completion
            assert {"smokeCompletion", "smokeSecondCompletion", "smokeSpecificCompletion"} <= set(command_completion_labels), command_completion
            command_hover = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeHoverProvider",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}],
                },
                request_id=372,
            )
            assert command_hover[0]["contents"][0] == "**Smoke Hover**", command_hover
            command_definition = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeDefinitionProvider",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}],
                },
                request_id=373,
            )
            assert command_definition[0]["uri"].endswith("language-provider-target.txt"), command_definition
            command_references = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeReferenceProvider",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}, {"includeDeclaration": True}],
                },
                request_id=374,
            )
            assert len(command_references) == 2, command_references
            command_prepare_rename = rpc(
                "extension/execute",
                {
                    "command": "vscode.prepareRename",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}],
                },
                request_id=375,
            )
            assert command_prepare_rename["placeholder"] == "oldName", command_prepare_rename
            command_rename = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeDocumentRenameProvider",
                    "args": ["file://language-provider-source.txt", {"line": 2, "character": 3}, "RenamedFromCommand"],
                },
                request_id=376,
            )
            assert command_rename["changes"]["file://language-provider-source.txt"][0]["newText"] == "RenamedFromCommand", command_rename
            command_actions = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeCodeActionProvider",
                    "args": [
                        "file://language-provider-source.txt",
                        {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 5},
                        },
                    ],
                },
                request_id=377,
            )
            assert command_actions[0]["title"] == "Smoke Fix Resolved", command_actions
            command_formatting = rpc(
                "extension/execute",
                {
                    "command": "vscode.executeFormatDocumentProvider",
                    "args": ["file://language-provider-source.txt", {"tabSize": 2, "insertSpaces": True}],
                },
                request_id=378,
            )
            assert command_formatting[0]["newText"] == "formatted-all", command_formatting
            result = rpc("extension/execute", {"command": "basic-api-smoke.hierarchyProvidersSetup"}, request_id=38)
            assert result["hierarchyProvidersSetup"] is True, result
            assert result["registrations"] == 2, result
            hierarchy = rpc(
                "extension/languageProviders",
                {"uri": "file://hierarchy-source.txt", "line": 1, "character": 4},
                request_id=39,
            )
            call = hierarchy["callHierarchy"][0]
            assert call["item"]["name"] == "smokeCall", call
            assert call["incoming"][0]["from"]["name"] == "caller", call
            assert call["outgoing"][0]["to"]["name"] == "callee", call
            assert call["incoming"][0]["fromRanges"][0]["start"]["character"] == 2, call
            type_hierarchy = hierarchy["typeHierarchy"][0]
            assert type_hierarchy["item"]["name"] == "SmokeType", type_hierarchy
            assert type_hierarchy["supertypes"][0]["name"] == "BaseSmoke", type_hierarchy
            assert type_hierarchy["subtypes"][0]["name"] == "ChildSmoke", type_hierarchy
            result = rpc("extension/execute", {"command": "basic-api-smoke.diagnosticsLifecycle"}, request_id=40)
            assert result["diagnosticsLifecycle"] is True, result
            assert result["beforeClear"] == 2, result
            assert result["afterDelete"] == 1, result
            assert result["afterClear"] == 0, result
            diagnostics = rpc("extension/diagnostics", request_id=41)["collections"]
            assert not any(item["name"] == "basic-api-smoke-lifecycle" for item in diagnostics), diagnostics
            result = rpc("extension/execute", {"command": "basic-api-smoke.longTailApis"}, request_id=78)
            assert result["webviewPanel"] is True, result
            assert result["webviewPanelMessageReceived"] == "panel-message", result
            assert result["webviewPanelMessageInjected"] is True, result
            assert result["webviewPanelHtml"] == "<html><body>smoke</body></html>", result
            assert result["webviewViewRegistered"] is True, result
            assert result["webviewViewResolved"] is True, result
            assert result["webviewViewHtml"] == "<html><body>view</body></html>", result
            assert result["customEditorRegistered"] is True, result
            assert result["webviewPanelSerializerRegistered"] is True, result
            assert result["customEditorLifecycle"] is True, result
            assert 'data-custom-editor="true"' in result["customEditorHtml"], result
            assert result["treeRegistered"] is True, result
            assert result["treeCheckboxCount"] == 1, result
            assert result["treeCollapseCount"] == 1, result
            assert result["treeExpandCount"] == 1, result
            assert result["taskCount"] == 1, result
            assert result["taskName"] == "Smoke Task", result
            assert result["taskExecutionName"] == "Smoke Task", result
            assert result["debugStarted"] is True, result
            assert result["sourceControlGroup"] == 1, result
            assert result["commentThread"] == 1, result
            assert result["notebookController"] == "smoke-notebook", result
            assert result["notebookLifecycle"] is True, result
            assert result["notebookOutputs"] == ["stdout", "error"], result
            assert result["notebookOutputItems"] == [
                "text/plain",
                "application/vnd.code.notebook.stdout",
                "application/vnd.code.notebook.stderr",
                "application/vnd.code.notebook.error",
            ], result
            assert result["notebookOutputText"] == "plain smoke", result
            assert result["notebookDataLanguage"] == "javascript", result
            assert result["testController"] == "smoke-tests", result
            assert result["testExplorerLifecycle"] is True, result
            assert result["testItems"] == ["smoke-pass", "smoke-fail"], result
            assert result["testProfiles"] == ["Smoke Run Profile"], result
            assert result["testResults"] == ["passed", "failed"], result
            assert result["authSession"] == "smoke-session", result
            assert result["authToken"] == "real-smoke-token", result
            assert result["authSessionEventRegistered"] is True, result
            assert result["envMachineId"] == "wizp-machine", result
            assert result["envSessionId"] == "wizp-session", result
            assert result["envAppName"] == "WIZP", result
            assert result["envExternal"] == "https://example.test/path", result
            assert result["envTelemetryEnabled"] is False, result
            assert result["envTelemetryEventRegistered"] is True, result
            assert result["windowFocused"] is True, result
            assert result["windowStateEventRegistered"] is True, result
            assert result["l10n"] == "Smoke translated", result
            assert result["chatParticipantDisposable"] is True, result
            assert result["lmToolRegistered"] is True, result
            assert result["lmToolDisposed"] is True, result
            assert result["chatModelsLength"] == 0, result
            assert result["unsupportedLanguageModelApi"] == {
                "selectDefault": 0,
                "selectAny": 0,
                "selectOpenAi": 0,
                "noImplicitNetwork": True,
                "hasRequestApi": False,
                "hasModelObject": False,
            }, result
            assert result["proposedUnavailable"] is True, result
            contributions = rpc("extension/languageContributions", request_id=42)
            language = next(item for item in contributions["languages"] if item["id"] == "smokelang")
            assert language["aliases"] == ["SmokeLang", "smoke"], language
            assert language["extensions"] == [".smoke"], language
            assert language["configuration"] == "./language-configuration.json", language
            grammar = next(item for item in contributions["grammars"] if item["language"] == "smokelang")
            assert grammar["scopeName"] == "source.smoke", grammar
            assert grammar["path"] == "./syntaxes/smokelang.tmLanguage.json", grammar
            theme = next(item for item in contributions["themes"] if item["id"] == "smoke-dark")
            assert theme["label"] == "Smoke Dark", theme
            assert theme["uiTheme"] == "vs-dark", theme
            assert theme["path"] == "./themes/smoke-dark-color-theme.json", theme
            runtime = rpc("extension/languageRuntimePlan", request_id=421)
            assert runtime["defaultTokenizer"] == "monaco", runtime
            assert runtime["textMateTokenization"] == "opt-in", runtime
            assert runtime["loadPolicy"] == "lazy", runtime
            assert runtime["onigurumaLoadedByDefault"] is False, runtime
            assert runtime["preserveWizpUiTheme"] is True, runtime
            assert runtime["largeFileDegrades"] is True, runtime
            smoke_plan = next(item for item in runtime["plans"] if item["languageId"] == "smokelang")
            assert smoke_plan["configurationPath"] == "./language-configuration.json", smoke_plan
            assert smoke_plan["monacoLanguageConfiguration"] == "lazy", smoke_plan
            assert smoke_plan["textMateGrammar"]["scopeName"] == "source.smoke", smoke_plan
            assert smoke_plan["textMateGrammar"]["path"] == "./syntaxes/smokelang.tmLanguage.json", smoke_plan
            assert smoke_plan["textMateGrammar"]["policy"] == "opt-in-lazy", smoke_plan
            assert smoke_plan["tokenTheme"]["id"] == "smoke-dark", smoke_plan
            assert smoke_plan["tokenTheme"]["convertedToMonacoRules"] == "lazy", smoke_plan
            assert smoke_plan["tokenTheme"]["appliesUiColors"] is False, smoke_plan
            textmate_default = rpc("extension/textMateRuntimeSmoke", request_id=422)
            assert textmate_default["enabled"] is False, textmate_default
            assert textmate_default["loaded"] is False, textmate_default
            assert textmate_default["lazyLoaded"] is False, textmate_default
            assert textmate_default["grammarTokenized"] is False, textmate_default
            assert textmate_default["onigurumaLoadedByDefault"] is False, textmate_default
            assert textmate_default["monacoDefaultUnchanged"] is True, textmate_default
            textmate_enabled = rpc(
                "extension/textMateRuntimeSmoke",
                {
                    "enabled": True,
                    "languageId": "smokelang",
                    "source": "plain smoke\nember plain",
                },
                request_id=423,
            )
            assert textmate_enabled["enabled"] is True, textmate_enabled
            assert textmate_enabled["loaded"] is True, textmate_enabled
            assert textmate_enabled["lazyLoaded"] is True, textmate_enabled
            assert textmate_enabled["grammarLoadedFromContribution"] is True, textmate_enabled
            assert textmate_enabled["scopeName"] == "source.smoke", textmate_enabled
            assert textmate_enabled["grammarPath"] == "./syntaxes/smokelang.tmLanguage.json", textmate_enabled
            assert textmate_enabled["matchPattern"] == r"\b(smoke|ember)\b", textmate_enabled
            tokens = textmate_enabled["tokens"]
            assert [token["text"] for token in tokens] == ["smoke", "ember"], textmate_enabled
            assert all(token["scope"] == "keyword.control.smoke" for token in tokens), textmate_enabled
            assert tokens[0]["line"] == 0 and tokens[0]["startCharacter"] == 6, textmate_enabled
            assert tokens[1]["line"] == 1 and tokens[1]["startCharacter"] == 0, textmate_enabled
            rules = textmate_enabled["convertedTokenRules"]
            assert rules == [
                {
                    "token": "keyword.control.smoke",
                    "foreground": "#ffcc66",
                    "target": "editor-token",
                    "sourceTheme": "smoke-dark",
                }
            ], textmate_enabled
            assert textmate_enabled["appliesUiColors"] is False, textmate_enabled
            assert textmate_enabled["themeConversionTarget"] == "monaco-token-rules-only", textmate_enabled
            assert textmate_enabled["preserveWizpUiTheme"] is True, textmate_enabled
            snippet = next(item for item in contributions["snippets"] if item["language"] == "smokelang")
            assert snippet["path"] == "./snippets/smokelang.code-snippets", snippet
            container = next(item for item in contributions["viewsContainers"] if item["id"] == "basic-api-smoke-container")
            assert container["location"] == "activitybar", container
            assert container["title"] == "Smoke", container
            assert container["icon"] == "./media/smoke.svg", container
            view = next(item for item in contributions["views"] if item["id"] == "basic-api-smoke-view")
            assert view["location"] == "basic-api-smoke-container", view
            assert view["name"] == "Smoke View", view
            assert view["when"] == "basicApiSmoke.enabled", view
            welcome = next(item for item in contributions["viewsWelcome"] if item["view"] == "basic-api-smoke-view")
            assert welcome["contents"] == "Welcome to the smoke view.", welcome
            assert welcome["when"] == "basicApiSmoke.enabled", welcome
            breakpoint = next(item for item in contributions["breakpoints"] if item["language"] == "smokelang")
            assert breakpoint["language"] == "smokelang", breakpoint
            validation = next(item for item in contributions["jsonValidation"] if item["url"] == "./schemas/smoke.schema.json")
            assert validation["fileMatch"] == ["*.smoke.json"], validation
            formatter = next(item for item in contributions["resourceLabelFormatters"] if item["scheme"] == "memfs")
            assert formatter["formatting"]["label"] == "${path}", formatter
            assert formatter["formatting"]["workspaceSuffix"] == "mem", formatter
            matcher = next(item for item in contributions["problemMatchers"] if item["name"] == "smoke-problem")
            assert matcher["label"] == "Smoke Problem Matcher", matcher
            assert matcher["owner"] == "smokelang", matcher
            assert matcher["pattern"]["severity"] == 4, matcher
            task_definition = next(item for item in contributions["taskDefinitions"] if item["type"] == "smokeTask")
            assert task_definition["required"] == ["script"], task_definition
            assert task_definition["properties"]["script"]["type"] == "string", task_definition
            debugger = next(item for item in contributions["debuggers"] if item["type"] == "smoke-debug")
            assert debugger["label"] == "Smoke Debug", debugger
            assert debugger["program"] == "./debugAdapters/smokeDebug.js", debugger
            assert debugger["runtime"] == "node", debugger
            assert debugger["languages"] == ["smokelang"], debugger
            assert debugger["when"] == "basicApiSmoke.enabled", debugger
            assert debugger["hiddenWhen"] == "false", debugger
            assert debugger["deprecated"] == "Smoke debugger is retained for contribution snapshot parity.", debugger
            assert debugger["variables"]["pickSmokeProcess"] == "basic-api-smoke.pickProcess", debugger
            assert debugger["configurationSnippets"][0]["label"] == "Smoke Launch", debugger
            assert debugger["configurationSnippets"][0]["body"]["type"] == "smoke-debug", debugger
            assert debugger["configurationAttributes"]["launch"]["required"] == ["program"], debugger
            icon_theme = next(item for item in contributions["iconThemes"] if item["id"] == "smoke-icons")
            assert icon_theme["label"] == "Smoke Icons", icon_theme
            assert icon_theme["path"] == "./icons/smoke-icon-theme.json", icon_theme
            walkthrough = next(item for item in contributions["walkthroughs"] if item["id"] == "smokeWalkthrough")
            assert walkthrough["title"] == "Smoke Walkthrough", walkthrough
            assert walkthrough["steps"][0]["id"] == "smoke.step", walkthrough
            assert walkthrough["steps"][0]["completionEvents"] == ["onCommand:basic-api-smoke.run"], walkthrough
            containers_rpc = rpc("extension/viewsContainers", request_id=43)
            rpc_container = next(item for item in containers_rpc["containers"] if item["id"] == "basic-api-smoke-container")
            assert rpc_container["location"] == "activitybar", rpc_container
            views_rpc = rpc("extension/views", request_id=44)
            rpc_view = next(item for item in views_rpc["views"] if item["id"] == "basic-api-smoke-view")
            assert rpc_view["container"] == "basic-api-smoke-container", rpc_view
            assert rpc_view["name"] == "Smoke View", rpc_view
            welcome_rpc = rpc("extension/viewsWelcome", request_id=45)
            rpc_welcome = next(item for item in welcome_rpc["viewsWelcome"] if item["view"] == "basic-api-smoke-view")
            assert rpc_welcome["contents"] == "Welcome to the smoke view.", rpc_welcome
            result = rpc("extension/execute", {"command": "save-bridge-smoke.setup"}, request_id=171)
            assert result["ready"] is True, result
            result = rpc(
                "extension/applySaveParticipants",
                {"path": "save-bridge.txt", "content": "body\n", "languageId": "plaintext"},
                request_id=172,
            )
            assert result["changed"] is True, result
            assert result["content"] == "bridge\nbody\n", result
            restart = rpc("extension/restartHost", request_id=173)
            assert restart["ok"] is True, restart
            commands_after_restart = rpc("extension/commands", request_id=174)["commands"]
            startup_commands = [command for command in commands_after_restart if command["command"] == "startup-activation-smoke.status"]
            assert len(startup_commands) == 1, startup_commands
            result = rpc("extension/execute", {"command": "startup-activation-smoke.status"}, request_id=175)
            assert result["startupActivated"] is True, result
            assert result["count"] == 1, result
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    print("parity extension host smoke ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
