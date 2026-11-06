import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import * as cp from "child_process";

let outputChannel: vscode.OutputChannel;
let daemonProc: cp.ChildProcess | null = null;
let daemonBuffer = "";
let rpcId = 1;
const pendingRpc: Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }> = new Map();

function getWizpBin(): string {
  const bundled = path.join(__dirname, "bin", "wizp");
  if (fs.existsSync(bundled)) return bundled;
  const buildOutput = path.join(__dirname, "..", "zig-out", "bin", "wizp");
  if (fs.existsSync(buildOutput)) return buildOutput;
  return bundled;
}

export function activate(context: vscode.ExtensionContext) {
  outputChannel = vscode.window.createOutputChannel("WIZP");
  outputChannel.appendLine("WIZP Editor activating...");

  const bin = getWizpBin();
  if (!fs.existsSync(bin)) {
    outputChannel.appendLine("WARNING: Zig binary not found at " + bin);
    vscode.window.showWarningMessage("WIZP: Zig binary not found. Run: zig build -Doptimize=ReleaseSafe");
  }

  context.subscriptions.push(
    vscode.commands.registerCommand("wizp.openEditor", () => createPanel(context.extensionUri)),
    vscode.commands.registerCommand("wizp.openEditorSide", () => createPanel(context.extensionUri, true)),
    { dispose: stopDaemon }
  );

  outputChannel.appendLine("WIZP Editor activated.");
}

export function deactivate() { stopDaemon(); }

function createPanel(extensionUri: vscode.Uri, side = false) {
  const column = side ? vscode.ViewColumn.Beside : vscode.ViewColumn.One;
  const panel = vscode.window.createWebviewPanel(
    "wizp-editor", "WIZP Editor", column,
    {
      enableScripts: true,
      retainContextWhenHidden: true,
      localResourceRoots: [vscode.Uri.joinPath(extensionUri, "media")],
    }
  );
  panel.webview.html = getWebviewHtml(panel.webview, extensionUri);
  panel.webview.onDidReceiveMessage(async (msg: unknown) => {
    if (!msg || typeof msg !== "object") return;
    const m = msg as Record<string, unknown>;
    if (m.type === "rpc" && typeof m.id === "number" && typeof m.method === "string") {
      try {
        const result = await sendRpc(m.method, m.params);
        panel.webview.postMessage({ type: "rpc-result", id: m.id, result });
      } catch (e: unknown) {
        const err = e instanceof Error ? e.message : String(e);
        panel.webview.postMessage({ type: "rpc-result", id: m.id, error: err });
      }
    }
  });
  panel.onDidDispose(stopDaemon);
  ensureDaemon().then(ok => {
    panel.webview.postMessage({ type: "daemon-status", ok });
  });
}

async function ensureDaemon(): Promise<boolean> {
  if (daemonProc && !daemonProc.killed) return true;
  return startDaemon();
}

async function startDaemon(): Promise<boolean> {
  const bin = getWizpBin();
  if (!fs.existsSync(bin)) {
    outputChannel.appendLine("ERROR: Binary not found: " + bin);
    return false;
  }
  return new Promise((resolve) => {
    try {
      daemonProc = cp.spawn(bin, ["--daemon"], { stdio: ["pipe", "pipe", "pipe"] });
      daemonProc.on("error", (err) => {
        outputChannel.appendLine("Daemon error: " + err.message);
        daemonProc = null;
        resolve(false);
      });
      daemonProc.on("spawn", () => {
        outputChannel.appendLine("Daemon started (pid " + daemonProc!.pid + ")");
        resolve(true);
      });
      daemonProc.on("exit", (code, signal) => {
        outputChannel.appendLine("Daemon exited (code=" + code + " signal=" + signal + ")");
        daemonProc = null;
      });
      daemonProc.stderr?.on("data", (d) => outputChannel.appendLine("daemon: " + d));
      daemonProc.stdout?.on("data", (data: Buffer) => {
        daemonBuffer += data.toString();
        parseDaemonOutput();
      });
    } catch (e: unknown) {
      outputChannel.appendLine("Daemon start failed: " + (e instanceof Error ? e.message : String(e)));
      resolve(false);
    }
  });
}

function parseDaemonOutput(): void {
  while (true) {
    const hdrEnd = daemonBuffer.indexOf("\r\n\r\n");
    if (hdrEnd === -1) break;
    const clMatch = daemonBuffer.match(/Content-Length: (\d+)/);
    if (!clMatch) { daemonBuffer = daemonBuffer.substring(hdrEnd + 4); continue; }
    const len = parseInt(clMatch[1], 10);
    if (isNaN(len) || len < 0) { daemonBuffer = daemonBuffer.substring(hdrEnd + 4); continue; }
    const bodyStart = hdrEnd + 4;
    if (daemonBuffer.length < bodyStart + len) break;
    const body = daemonBuffer.substring(bodyStart, bodyStart + len);
    daemonBuffer = daemonBuffer.substring(bodyStart + len);
    try {
      const resp = JSON.parse(body) as Record<string, unknown>;
      if (resp.jsonrpc !== "2.0") continue;
      if (typeof resp.id === "number") {
        const pending = pendingRpc.get(resp.id);
        if (pending) {
          pendingRpc.delete(resp.id);
          if (resp.error && typeof resp.error === "object") {
            const errObj = resp.error as Record<string, unknown>;
            pending.reject(new Error(typeof errObj.message === "string" ? errObj.message : "RPC error"));
          } else {
            pending.resolve(resp.result);
          }
        }
      }
    } catch { /* malformed JSON, skip */ }
  }
}

function stopDaemon(): void {
  if (daemonProc) {
    try {
      const body = JSON.stringify({ jsonrpc: "2.0", id: 0, method: "shutdown" });
      daemonProc.stdin?.write("Content-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
    } catch { /* ignore write errors during shutdown */ }
    setTimeout(() => {
      if (daemonProc && !daemonProc.killed) daemonProc.kill("SIGTERM");
      daemonProc = null;
    }, 500);
  }
  for (const [, p] of pendingRpc) p.reject(new Error("daemon stopped"));
  pendingRpc.clear();
}

async function sendRpc(method: string, params?: unknown, timeoutMs = 30000): Promise<unknown> {
  if (!daemonProc) await startDaemon();
  if (!daemonProc) throw new Error("Daemon not running — build with: zig build -Doptimize=ReleaseSafe");
  const id = rpcId++;
  const body = JSON.stringify({ jsonrpc: "2.0", id, method, params });
  const msg = "Content-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body;
  return new Promise((resolve, reject) => {
    pendingRpc.set(id, { resolve: resolve as (v: unknown) => void, reject });
    daemonProc!.stdin!.write(msg);
    setTimeout(() => {
      if (pendingRpc.has(id)) {
        pendingRpc.delete(id);
        reject(new Error("RPC timeout: " + method));
      }
    }, timeoutMs);
  });
}

function getWebviewHtml(webview: vscode.Webview, extensionUri: vscode.Uri): string {
  const media = webview.asWebviewUri(vscode.Uri.joinPath(extensionUri, "media"));
  const nonce = String(Date.now());
  const csp = [
    "default-src 'none'",
    "style-src 'unsafe-inline' " + webview.cspSource,
    "script-src 'nonce-" + nonce + "' 'unsafe-inline' " + webview.cspSource + " https:",
    "worker-src blob: data: https:",
    "child-src blob: data: https:",
    "font-src " + webview.cspSource + " https:",
    "img-src " + webview.cspSource + " https:",
    "connect-src https://open-vsx.org",
  ].join("; ");
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><title>WIZP Editor</title>
<meta http-equiv="Content-Security-Policy" content="${csp}">
<link rel="stylesheet" href="${media}/editor.css">
</head>
<body>
<div id="app">
  <div id="sidebar"><div id="sidebar-header">EXPLORER</div><div id="file-tree"></div></div>
  <div id="main">
    <div id="tabs"></div>
    <div id="editor"></div>
    <div id="panel"></div>
    <div id="status">
      <span id="btn-term">Terminal</span>
      <span id="status-diag">OK</span>
      <span id="status-file">[No Name]</span>
      <span id="status-lang">plaintext</span>
      <span id="status-daemon" style="margin-left:auto">●</span>
    </div>
  </div>
</div>
<div id="notify"></div>
<script nonce="${nonce}" src="https://cdn.jsdelivr.net/npm/monaco-editor@0.55.0/min/vs/loader.js"></script>
<script nonce="${nonce}" src="${media}/editor.js"></script>
</body>
</html>`;
}
