/**
 * WIZP — Electrobun Main Process
 *
 * Architecture (BunRPC proxy layer):
 *   Svelte WebView ──Electrobun typed RPC──→ Bun Main ──stdio──→ Zig daemon (--daemon)
 *
 *   The Electrobun Main process spawns the Zig daemon and acts as a typed RPC
 *   proxy between the Svelte renderer and the Zig backend. The renderer calls
 *   `rpc.request.sendDaemonRpc(method, params)` and the Main process forwards
 *   it to the daemon via stdio with Content-Length framing.
 *
 * Falls back to embedded-HTTP mode if daemon mode fails:
 *   WebView ──fetch /api/rpc──→ Zig embedded HTTP server ──stdio──→ internal daemon
 *
 * Frameless window: titleBarStyle "hidden" + custom titlebar in Svelte (Titlebar.svelte)
 * Native menu bar: setApplicationMenu with File/Edit/View/Help menus
 * Window state persistence: save/restore frame position via ~/.wizp-window-state.json
 */

import { BrowserWindow, app, ApplicationMenu, Utils } from "electrobun";
import { resolve, dirname, join } from "path";
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, openSync, closeSync, fsyncSync, renameSync, unlinkSync, realpathSync } from "fs";
import { homedir } from "os";
import { dlopen, suffix } from "bun:ffi";
import { AgentBridge } from "./agent";
import { AgentWorkspace } from "./agent-workspace";

// ─── Locate Zig binary ───────────────────────────────────────────────────────

const __dir = dirname(process.argv[1] ?? ".");
function readStartupOpenPaths(): string[] {
  const startupFile = Bun.env.WIZP_STARTUP_OPEN_PATHS_FILE;
  if (startupFile) {
    try {
      const paths = readFileSync(startupFile, "utf8")
        .split("\0")
        .filter((arg) => arg.length > 0);
      unlinkSync(startupFile);
      return paths;
    } catch {
      // Fall through to direct argv for development launchers without the wrapper.
    }
  }
  return process.argv.slice(2).filter((arg) => arg.length > 0 && arg !== "--");
}
const STARTUP_OPEN_PATHS = readStartupOpenPaths();
function findZigBinary(): string {
  const backendFilename = process.platform === "win32" ? "wizp.exe" : "wizp";
  const candidates = [
    resolve(__dir, "../../zig-out/bin", backendFilename),
    resolve(__dir, "../zig-out/bin", backendFilename),
    resolve(__dir, "zig-out/bin", backendFilename),
    resolve(__dir, "..", backendFilename),
    resolve(__dir, backendFilename),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return candidates[0];
}

const ZIG_BIN = findZigBinary();
function envPort(name: string, fallback: number): number {
  const parsed = Number.parseInt(Bun.env[name] ?? "", 10);
  if (Number.isFinite(parsed) && parsed >= 1024 && parsed <= 65535)
    return parsed;
  return fallback;
}

const WIZP_PORT = envPort("WIZP_PORT", 9876);
const WIZP_CONTROL_PORT = envPort("WIZP_CONTROL_PORT", 19876);
const WIZP_HOST = "127.0.0.1";
const WIZP_CONTROL_TOKEN = crypto.randomUUID();
const WIZP_GUI_BENCHMARK = Bun.env.WIZP_GUI_BENCHMARK === "1";
const WIZP_NATIVE_UI_SMOKE = Bun.env.WIZP_NATIVE_UI_SMOKE === "1";
const WIZP_STATE_DIR = join(
  Bun.env.XDG_STATE_HOME || join(homedir(), ".local", "state"),
  "wizp",
);
mkdirSync(WIZP_STATE_DIR, { recursive: true });
const WIZP_SESSION_PATH = resolve(Bun.env.WIZP_SESSION_PATH || join(WIZP_STATE_DIR, "session.json"));
mkdirSync(dirname(WIZP_SESSION_PATH), { recursive: true });
const GUI_BENCHMARK_PREFIX = "WIZP_GUI_STARTUP_BENCHMARK ";
const PLACEHOLDER_URL =
  "data:text/html;charset=utf-8,%3Cbody%20style%3D%22background%3A%231e1e1e%3B%20margin%3A0%3B%22%3E%3C%2Fbody%3E";

type RendererStartupMark = {
  rendererMs: number | null;
  receivedMs: number;
};

type NativeTerminalTelemetry = {
  reportedAt: string;
  sessionId: number | null;
  status: string;
  loopIterations: number;
  successfulEmptyReads: number;
  dataReadCount: number;
  renderedBytes: number;
  idlePollDelayMs: number;
  errorRetryDelayMs: number;
};

type NativeTerminalLinkActivation = {
  source: "pointer" | "keyboard";
  uri: string;
  activatedAt: string;
};

const startupStartedAt = performance.now();
const startupMarksMs: Record<string, number> = WIZP_GUI_BENCHMARK
  ? { processStart: 0 }
  : {};
const rendererStartupMarks: Record<string, RendererStartupMark> = {};
const webviewStartupDetails: Record<string, string> = {};
const nativeTerminalTelemetry: Record<string, NativeTerminalTelemetry> = {};
const nativeTerminalLinkActivations: NativeTerminalLinkActivation[] = [];
let guiBenchmarkEmitted = false;
let startupProbeInjected = false;
let mainWin: any = null;
let backendReadyChecked = false;
let navigationRequested = false;

function elapsedStartupMs(): number {
  return performance.now() - startupStartedAt;
}

function markStartup(name: string): number {
  const elapsed = elapsedStartupMs();
  if (WIZP_GUI_BENCHMARK) startupMarksMs[name] = elapsed;
  return elapsed;
}

function roundMs(value: number | null | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.round(value * 10) / 10;
}

function roundedMarks(source: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [key, value] of Object.entries(source)) {
    const rounded = roundMs(value);
    if (rounded !== null) out[key] = rounded;
  }
  return out;
}

function metricBetween(start: string, end: string): number | null {
  const a = startupMarksMs[start];
  const b = startupMarksMs[end];
  return roundMs(typeof a === "number" && typeof b === "number" ? b - a : null);
}

function rendererMetricBetween(start: string, end: string): number | null {
  const a = rendererStartupMarks[start]?.rendererMs;
  const b = rendererStartupMarks[end]?.rendererMs;
  return roundMs(typeof a === "number" && typeof b === "number" ? b - a : null);
}

function emitGuiBenchmark(reason: string) {
  if (!WIZP_GUI_BENCHMARK || guiBenchmarkEmitted) return;
  guiBenchmarkEmitted = true;
  markStartup("benchmarkReport");

  const rendererMarks: Record<string, RendererStartupMark> = {};
  for (const [key, mark] of Object.entries(rendererStartupMarks)) {
    rendererMarks[key] = {
      rendererMs: roundMs(mark.rendererMs),
      receivedMs: roundMs(mark.receivedMs) ?? mark.receivedMs,
    };
  }

  const report = {
    schema: 1,
    benchmarkKind: "electrobun-gui-cold",
    timestamp: new Date().toISOString(),
    reason,
    binary: ZIG_BIN,
    ports: { http: WIZP_PORT, control: WIZP_CONTROL_PORT },
    marksMs: roundedMarks(startupMarksMs),
    webviewDetails: webviewStartupDetails,
    rendererMarksMs: rendererMarks,
    metricsMs: {
      processToWindow: metricBetween("processStart", "windowCreated"),
      processToBackendReady: metricBetween("processStart", "backendReady"),
      backendReadyToNavigation: metricBetween(
        "backendReady",
        "navigationRequested",
      ),
      navigationToDomReady: metricBetween(
        "navigationRequested",
        "webview.dom-ready",
      ),
      navigationToRendererEntryReceived: metricBetween(
        "navigationRequested",
        "renderer.moduleLoaded",
      ),
      processToFirstRafReceived: metricBetween(
        "processStart",
        "renderer.firstRaf",
      ),
      processToFirstInteractiveReceived: metricBetween(
        "processStart",
        "renderer.secondRafInteractive",
      ),
      processToInjectedFirstRafReceived: metricBetween(
        "processStart",
        "renderer.injectedFirstRaf",
      ),
      processToInjectedSecondRafReceived: metricBetween(
        "processStart",
        "renderer.injectedSecondRafInteractive",
      ),
      processToInjectedBodyVisibleObserved: metricBetween(
        "processStart",
        "renderer.injectedBodyVisibleObserved",
      ),
      rendererModuleToSvelteMounted: rendererMetricBetween(
        "moduleLoaded",
        "svelteMounted",
      ),
      rendererModuleToFirstRaf: rendererMetricBetween(
        "moduleLoaded",
        "firstRaf",
      ),
      rendererModuleToSecondRafInteractive: rendererMetricBetween(
        "moduleLoaded",
        "secondRafInteractive",
      ),
    },
  };

  console.log(`${GUI_BENCHMARK_PREFIX}${JSON.stringify(report)}`); // craft-ignore: machine-readable benchmark output.
  setTimeout(() => {
    try {
      controlServer?.stop();
    } catch (_) {}
    try {
      stopZig();
    } catch (_) {}
    try {
      mainWin?.close();
    } catch (_) {}
    process.exit(0);
  }, 50);
}

function recordRendererStartupMark(name: string, rendererMs: number | null) {
  if (!WIZP_GUI_BENCHMARK || !name) return;
  if (rendererStartupMarks[name]) return;
  const receivedMs = markStartup(`renderer.${name}`);
  rendererStartupMarks[name] = { rendererMs, receivedMs };
  if (name === "secondRafInteractive") {
    emitGuiBenchmark("renderer-second-raf");
  } else if (name === "injectedBodyVisibleObserved") {
    setTimeout(() => emitGuiBenchmark("injected-body-visible"), 300);
  } else if (name === "injectedSecondRafInteractive") {
    setTimeout(() => emitGuiBenchmark("injected-second-raf"), 50);
  }
}

// ─── Spawn Zig daemon (daemon mode for BunRPC proxy) ─────────────────────────

type BackendState = "ready" | "disconnected" | "restarting" | "unavailable";
type BackendChild = Bun.Subprocess<"pipe", "inherit", "inherit">;
const backendInstanceId = crypto.randomUUID();
const MAX_ZIG_RESTART_ATTEMPTS = 3;
const ZIG_RESTART_DELAY_MS = 100;
const ZIG_RESTART_READY_TIMEOUT_MS = 10_000;
let zigProcess: BackendChild | null = null;
let backendOwnerToken: string | null = null;
let backendState: BackendState = "disconnected";
let backendGeneration = 0;
let zigRestartAttempts = 0;
let zigRestartPromise: Promise<void> | null = null;
let zigShutdownRequested = false;
let backendHeld = false;
let healthPromise: Promise<void> | null = null;
let retryPromise: Promise<void> | null = null;

function backendStatus() {
  return {
    state: backendState,
    instanceId: backendInstanceId,
    generation: backendGeneration,
    backendPid: zigProcess?.pid ?? null,
    restartAttempts: zigRestartAttempts,
  };
}

function setBackendState(state: BackendState) {
  backendState = state;
  const script = `window.dispatchEvent(new CustomEvent("wizpBackendStateChanged",{detail:${JSON.stringify(backendStatus())}}));`;
  try {
    const result = mainWin?.webview?.executeJavascript?.(script);
    if (result && typeof result.then === "function") void result.catch(() => {});
  } catch {}
}

// A PTY shell creates its own session, so killing the HTTP process group alone
// cannot own its lifetime. The inherited incarnation token also finds children
// reparented after an unexpected HTTP exit. Hold pidfds before signalling, and
// verify the token after opening each fd to rule out PID reuse.
const linuxProcessControl = process.platform === "linux"
  ? dlopen("libc.so.6", {
      pidfd_open: { args: ["i32", "u32"], returns: "i32" },
      pidfd_send_signal: { args: ["i32", "i32", "ptr", "u32"], returns: "i32" },
      close: { args: ["i32"], returns: "i32" },
    }).symbols
  : null;

function killBackendDescendants(token: string) {
  if (!linuxProcessControl) return;
  const marker = Buffer.from(`WIZP_BACKEND_OWNER=${token}\0`);
  const descriptors: number[] = [];
  const seen = new Set<number>();
  try {
    // Rescan after freezing the first set: a process may have forked while /proc
    // was enumerated. Once a pass finds no new members, all owners are stopped.
    for (;;) {
      let discovered = false;
      for (const entry of readdirSync("/proc")) {
        if (!/^[0-9]+$/.test(entry)) continue;
        const pid = Number(entry);
        if (pid === process.pid || seen.has(pid)) continue;
        try {
          if (!readFileSync(`/proc/${pid}/environ`).includes(marker)) continue;
          const fd = linuxProcessControl.pidfd_open(pid, 0);
          if (fd < 0) continue;
          try {
            if (!readFileSync(`/proc/${pid}/environ`).includes(marker)) {
              linuxProcessControl.close(fd);
              continue;
            }
          } catch {
            linuxProcessControl.close(fd);
            continue;
          }
          seen.add(pid);
          descriptors.push(fd);
          discovered = true;
          linuxProcessControl.pidfd_send_signal(fd, 19, null, 0);
        } catch {}
      }
      if (!discovered) break;
    }
    for (const fd of descriptors)
      linuxProcessControl.pidfd_send_signal(fd, 9, null, 0);
  } finally {
    for (const fd of descriptors) linuxProcessControl.close(fd);
  }
}

function terminateZigProcess(): BackendChild | null {
  const child = zigProcess;
  zigProcess = null;
  const token = backendOwnerToken;
  backendOwnerToken = null;
  if (token) killBackendDescendants(token);
  if (child) {
    try {
      if (process.platform === "win32")
        Bun.spawnSync(["taskkill", "/pid", String(child.pid), "/T", "/F"]);
      else if (process.platform !== "linux" && child.exitCode === null)
        process.kill(-child.pid, "SIGKILL");
    } catch {}
    try { child.kill("SIGKILL"); } catch {}
  }
  return child;
}

function startZig(): BackendChild | null {
  if (!existsSync(ZIG_BIN)) {
    markStartup("zigMissing");
    console.error(`[WIZP] ERROR: Binary not found at ${ZIG_BIN}`);
    return null;
  }
  markStartup("zigSpawnStart");
  const backendEnv = { ...process.env };
  delete backendEnv.LD_PRELOAD;
  delete backendEnv.LD_AUDIT;
  const token = crypto.randomUUID();
  let child: BackendChild;
  try {
    child = Bun.spawn([ZIG_BIN], {
      stdin: "pipe",
      stdout: "inherit",
      stderr: "inherit",
      detached: process.platform !== "win32",
      cwd: dirname(ZIG_BIN),
      env: {
        ...backendEnv,
        WIZP_PORT: String(WIZP_PORT),
        WIZP_WEBVIEW: "false",
        WIZP_NO_BROWSER: "1",
        WIZP_SESSION_PATH,
        WIZP_NATIVE_SESSION_OWNER: "1",
        WIZP_BACKEND_OWNER: token,
        WIZP_DEFAULT_TERMINAL_CWD: homedir(),
      },
    });
  } catch (error) {
    console.error("[WIZP] Failed to launch Zig HTTP server", error);
    return null;
  }
  zigProcess = child;
  backendOwnerToken = token;
  child.exited.then(() => {
    if (zigProcess !== child || zigShutdownRequested) return;
    // Keep the old owner token until the serialized supervisor cleans it up.
    setBackendState("disconnected");
    if (!backendHeld) void requestZigRestart();
  });
  return child;
}

async function backendRpc(method: string, params: Record<string, unknown> = {}) {
  const id = crypto.randomUUID();
  const response = await fetch(`http://${WIZP_HOST}:${WIZP_PORT}/api/rpc`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
    signal: AbortSignal.timeout(1500),
  });
  if (!response.ok) throw new Error(`Backend HTTP ${response.status}`);
  const reply = await response.json();
  if (reply?.jsonrpc !== "2.0" || reply.id !== id || reply.error || !Object.hasOwn(reply, "result"))
    throw new Error("Backend protocol unavailable");
  return reply.result;
}

type SessionSnapshot = Record<string, unknown>;
let sessionQueue: Promise<unknown> = Promise.resolve();

function withSession<T>(operation: () => T | Promise<T>): Promise<T> {
  const result = sessionQueue.then(operation);
  sessionQueue = result.catch(() => {});
  return result;
}

function isObject(value: unknown): value is SessionSnapshot {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validSession(value: unknown): value is SessionSnapshot {
  if (!isObject(value)) return false;
  for (const key of ["files", "folders"]) {
    const paths = value[key];
    if (paths !== undefined && (!Array.isArray(paths) || paths.some(
      (entry) => !isObject(entry) || typeof entry.path !== "string" || !entry.path || entry.path.includes("\0"),
    ))) return false;
  }
  if (value.editorSession !== undefined && !isObject(value.editorSession)) return false;
  for (const key of ["profile", "activeActivity", "splitDirection", "path"])
    if (value[key] !== undefined && typeof value[key] !== "string") return false;
  for (const key of ["trusted", "sidebarVisible", "panelVisible", "tabBarVisible"])
    if (value[key] !== undefined && typeof value[key] !== "boolean") return false;
  for (const key of ["panelHeight", "activeGroup"])
    if (value[key] !== undefined && (!Number.isSafeInteger(value[key]) || Number(value[key]) < 0)) return false;
  return true;
}

function readSession(): SessionSnapshot | null {
  let text: string;
  try { text = readFileSync(WIZP_SESSION_PATH, "utf8"); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
  const snapshot: unknown = JSON.parse(text);
  if (!validSession(snapshot)) throw new Error("Invalid canonical session");
  return { ...snapshot, path: WIZP_SESSION_PATH };
}

function writeSession(snapshot: SessionSnapshot) {
  const merged = { ...readSession(), ...snapshot, path: WIZP_SESSION_PATH };
  const temporary = `${WIZP_SESSION_PATH}.tmp.${crypto.randomUUID()}`;
  try {
    const fd = openSync(temporary, "wx", 0o600);
    try {
      writeFileSync(fd, JSON.stringify(merged));
      fsyncSync(fd);
    } finally { closeSync(fd); }
    renameSync(temporary, WIZP_SESSION_PATH);
    if (process.platform !== "win32") {
      const directory = openSync(dirname(WIZP_SESSION_PATH), "r");
      try { fsyncSync(directory); } finally { closeSync(directory); }
    }
  } finally {
    try { unlinkSync(temporary); } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}

async function restoreBackend(child: BackendChild): Promise<boolean> {
  const deadline = Date.now() + ZIG_RESTART_READY_TIMEOUT_MS;
  while (Date.now() < deadline && zigProcess === child && child.exitCode === null && !backendHeld && !zigShutdownRequested) {
    try {
      const identity = await backendRpc("backend/identity");
      if (identity?.owner !== backendOwnerToken) throw new Error("Backend owner mismatch");
      return await withSession(async () => {
        if (readSession()) await backendRpc("session/load", { path: WIZP_SESSION_PATH });
        if (zigProcess !== child || child.exitCode !== null || backendHeld || zigShutdownRequested) return false;
        backendGeneration++;
        zigRestartAttempts = 0;
        setBackendState("ready");
        return true;
      });
    } catch {}
    await Bun.sleep(10);
  }
  return false;
}

function requestZigRestart(): Promise<void> {
  if (zigRestartPromise) return zigRestartPromise;
  if (zigShutdownRequested || backendHeld) return Promise.resolve();
  zigRestartPromise = (async () => {
    while (!zigShutdownRequested && !backendHeld && zigRestartAttempts < MAX_ZIG_RESTART_ATTEMPTS) {
      const old = terminateZigProcess();
      if (old) await old.exited;
      zigRestartAttempts++;
      setBackendState("restarting");
      await Bun.sleep(ZIG_RESTART_DELAY_MS);
      if (zigShutdownRequested || backendHeld) break;
      const child = startZig();
      if (child && await restoreBackend(child)) return;
    }
    const old = terminateZigProcess();
    if (old) await old.exited;
    if (!zigShutdownRequested) setBackendState("unavailable");
  })().finally(() => {
    zigRestartPromise = null;
    // A child can exit between readiness and this promise settling.
    if (backendState === "disconnected" && !backendHeld && !zigShutdownRequested)
      void requestZigRestart();
  });
  return zigRestartPromise;
}

async function checkBackendHealth() {
  if (backendState !== "ready" || healthPromise) return healthPromise;
  const child = zigProcess;
  const owner = backendOwnerToken;
  healthPromise = backendRpc("backend/identity").then((identity) => {
    if (identity?.owner !== owner) throw new Error("Backend owner mismatch");
  }).catch(() => {
    if (zigProcess === child && backendState === "ready") {
      setBackendState("disconnected");
      void requestZigRestart();
    }
  }).finally(() => { healthPromise = null; });
  return healthPromise;
}

function retryBackend(): Promise<void> {
  if (retryPromise) return retryPromise;
  retryPromise = (async () => {
    if (backendState === "ready") await checkBackendHealth();
    if (backendState === "ready") return;
    if (zigRestartPromise) {
      await zigRestartPromise;
      return;
    }
    backendHeld = false;
    zigRestartAttempts = 0;
    await requestZigRestart();
  })().finally(() => { retryPromise = null; });
  return retryPromise;
}

async function disconnectBackend() {
  backendHeld = true;
  setBackendState("disconnected");
  const old = terminateZigProcess();
  if (old) await old.exited;
  if (zigRestartPromise) await zigRestartPromise;
  setBackendState("unavailable");
}

function reloadRenderer() {
  if (!mainWin?.webview) throw new Error("Renderer unavailable");
  mainWin.webview.loadURL(appUrl());
}

function stopZig() {
  zigShutdownRequested = true;
  terminateZigProcess();
}

let linuxPackagedExitStarted = false;

function forceLinuxPackagedExit(exitCode: number): boolean {
  if (process.platform !== "linux" || linuxPackagedExitStarted) return false;
  const nativeWrapperPath = join(process.cwd(), `libNativeWrapper.${suffix}`);
  if (!existsSync(nativeWrapperPath)) return false;

  try {
    const nativeWrapper = dlopen(nativeWrapperPath, {
      stopEventLoop: { args: [], returns: "void" },
      waitForShutdownComplete: { args: ["i32"], returns: "void" },
      forceExit: { args: ["i32"], returns: "void" },
    });
    linuxPackagedExitStarted = true;
    // Let CEF release its helper processes before applying Electrobun's
    // bounded force-exit fallback. This keeps packaged SIGTERM cleanup
    // graceful while retaining a finite shutdown bound.
    nativeWrapper.symbols.stopEventLoop();
    nativeWrapper.symbols.waitForShutdownComplete(5000);
    nativeWrapper.symbols.forceExit(exitCode);
    return true;
  } catch (error) {
    console.error("[WIZP] Failed to use bounded packaged exit", error);
    return false;
  }
}

let terminationPromise: Promise<void> | null = null;

function handleTerminationSignal(exitCode: number) {
  if (terminationPromise) return;
  saveWindowState(mainWin);
  terminationPromise = agentBridge.stop()
    .catch((error) => console.error("[WIZP] ZIPI shutdown failed", error))
    .then(() => {
      stopZig();
      if (!forceLinuxPackagedExit(exitCode)) process.exit(exitCode);
    });
}


// ─── Window state persistence ────────────────────────────────────────────────

const STATE_FILE = join(homedir(), ".wizp-window-state.json");
interface WindowState {
  x: number;
  y: number;
  width: number;
  height: number;
}

function loadWindowState(): WindowState {
  try {
    if (existsSync(STATE_FILE)) {
      const raw = readFileSync(STATE_FILE, "utf-8");
      const s = JSON.parse(raw);
      return {
        x: s.x ?? 80,
        y: s.y ?? 50,
        width: s.width ?? 1280,
        height: s.height ?? 820,
      };
    }
  } catch {}
  return { x: 80, y: 50, width: 1280, height: 820 };
}

function saveWindowState(win: any) {
  try {
    const bounds = win.getBounds?.() || {
      x: 80,
      y: 50,
      width: 1280,
      height: 820,
    };
    writeFileSync(STATE_FILE, JSON.stringify(bounds));
  } catch {}
}

// ─── Native menu bar ─────────────────────────────────────────────────────────

function buildNativeMenu() {
  ApplicationMenu.setApplicationMenu([
    {
      label: "File",
      submenu: [
        { label: "New File", accelerator: "CmdOrCtrl+N", action: "file:new" },
        {
          label: "Open File...",
          accelerator: "CmdOrCtrl+O",
          action: "file:open-dialog",
        },
        {
          label: "Open Folder...",
          accelerator: "CmdOrCtrl+K Ctrl+O",
          action: "file:open-folder-dialog",
        },
        { type: "separator" },
        { label: "Save", accelerator: "CmdOrCtrl+S", action: "file:save" },
        {
          label: "Save As...",
          accelerator: "CmdOrCtrl+Shift+S",
          action: "file:save-as",
        },
        { type: "separator" },
        { label: "Close Tab", accelerator: "CmdOrCtrl+W", action: "tab:close" },
        {
          label: "Close Window",
          accelerator: "CmdOrCtrl+Shift+W",
          action: "window:close",
        },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    {
      label: "Edit",
      submenu: [
        { label: "Undo", accelerator: "CmdOrCtrl+Z", action: "edit:undo" },
        {
          label: "Redo",
          accelerator: "CmdOrCtrl+Shift+Z",
          action: "edit:redo",
        },
        { type: "separator" },
        { label: "Cut", accelerator: "CmdOrCtrl+X", role: "cut" },
        { label: "Copy", accelerator: "CmdOrCtrl+C", role: "copy" },
        { label: "Paste", accelerator: "CmdOrCtrl+V", role: "paste" },
        { type: "separator" },
        { label: "Find", accelerator: "CmdOrCtrl+F", action: "search:find" },
        {
          label: "Replace",
          accelerator: "CmdOrCtrl+H",
          action: "search:replace",
        },
      ],
    },
    {
      label: "View",
      submenu: [
        {
          label: "Command Palette...",
          accelerator: "CmdOrCtrl+Shift+P",
          action: "view:command-palette",
        },
        {
          label: "Quick Open...",
          accelerator: "CmdOrCtrl+P",
          action: "view:quick-open",
        },
        { type: "separator" },
        {
          label: "Toggle Sidebar",
          accelerator: "CmdOrCtrl+B",
          action: "view:toggle-sidebar",
        },
        {
          label: "Toggle Panel",
          accelerator: "CmdOrCtrl+J",
          action: "view:toggle-panel",
        },
        {
          label: "Toggle Full Screen",
          accelerator: "F11",
          action: "view:toggle-fullscreen",
        },
        { type: "separator" },
        {
          label: "Zoom In",
          accelerator: "CmdOrCtrl+=",
          action: "view:zoom-in",
        },
        {
          label: "Zoom Out",
          accelerator: "CmdOrCtrl+-",
          action: "view:zoom-out",
        },
        {
          label: "Reset Zoom",
          accelerator: "CmdOrCtrl+0",
          action: "view:zoom-reset",
        },
      ],
    },
    {
      label: "Help",
      submenu: [
        { label: "About WIZP", action: "help:about" },
        {
          label: "Open Settings",
          accelerator: "CmdOrCtrl+,",
          action: "view:settings",
        },
      ],
    },
  ]);
}

// ─── Window control server (receives commands from renderer titlebar)
let controlServer: ReturnType<typeof Bun.serve> | null = null;
const agentBridge = new AgentBridge();
const nativeWebviewReports: Record<string, unknown> = {};
const agentWorkspace = new AgentWorkspace();

const CONTROL_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type,X-WIZP-Control-Token",
};

function controlResponse(body = "ok", status = 200) {
  return new Response(body, { status, headers: CONTROL_HEADERS });
}

function jsonControlResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      ...CONTROL_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}
async function trustedAgentWorkspace(): Promise<string> {
  if (backendState !== "ready") throw new Error("WIZP backend is unavailable.");
  const trust = await backendRpc("workspace/trustState");
  if (trust?.trusted !== true) throw new Error("Trust the workspace before editing with ZIPI.");
  const workspaceResult = await backendRpc("workspace/getFolders");
  const folders = Array.isArray(workspaceResult?.folders) ? workspaceResult.folders : [];
  const activeFolder = folders.find((folder: unknown) =>
    isObject(folder) && typeof folder.path === "string" && folder.path.length > 0,
  );
  if (!isObject(activeFolder) || typeof activeFolder.path !== "string")
    throw new Error("Open a workspace before using ZIPI.");
  return realpathSync(activeFolder.path);
}

function recordNativeTerminalTelemetry(payload: any) {
  const componentId = String(
    payload.componentId ?? payload.sessionId ?? "terminal",
  );
  const telemetry: NativeTerminalTelemetry = {
    reportedAt: new Date().toISOString(),
    sessionId:
      typeof payload.sessionId === "number" &&
      Number.isFinite(payload.sessionId)
        ? payload.sessionId
        : null,
    status: String(payload.status ?? "unknown").slice(0, 64),
    loopIterations: Math.max(0, Number(payload.loopIterations) || 0),
    successfulEmptyReads: Math.max(
      0,
      Number(payload.successfulEmptyReads) || 0,
    ),
    dataReadCount: Math.max(0, Number(payload.dataReadCount) || 0),
    renderedBytes: Math.max(0, Number(payload.renderedBytes) || 0),
    idlePollDelayMs: Math.max(0, Number(payload.idlePollDelayMs) || 0),
    errorRetryDelayMs: Math.max(0, Number(payload.errorRetryDelayMs) || 0),
  };
  nativeTerminalTelemetry[componentId.slice(0, 80)] = telemetry;
}

function telemetryPayloadFromSearchParams(params: URLSearchParams): any {
  return {
    componentId: params.get("componentId"),
    sessionId: Number.parseInt(params.get("sessionId") ?? "", 10),
    status: params.get("status"),
    loopIterations: Number.parseInt(params.get("loopIterations") ?? "", 10),
    successfulEmptyReads: Number.parseInt(
      params.get("successfulEmptyReads") ?? "",
      10,
    ),
    dataReadCount: Number.parseInt(params.get("dataReadCount") ?? "", 10),
    renderedBytes: Number.parseInt(params.get("renderedBytes") ?? "", 10),
    idlePollDelayMs: Number.parseInt(params.get("idlePollDelayMs") ?? "", 10),
    errorRetryDelayMs: Number.parseInt(
      params.get("errorRetryDelayMs") ?? "",
      10,
    ),
  };
}

function startControlServer() {
  controlServer = Bun.serve({
    port: WIZP_CONTROL_PORT,
    hostname: WIZP_HOST,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method === "OPTIONS") {
        return controlResponse("", 204);
      }
      if (url.pathname.startsWith("/__agent/")) {
        if (!["GET", "POST"].includes(req.method)) return controlResponse("method not allowed", 405);
        if (req.headers.get("X-WIZP-Control-Token") !== WIZP_CONTROL_TOKEN)
          return controlResponse("forbidden", 403);
        try {
          if (req.method === "GET" && url.pathname === "/__agent/status")
            return jsonControlResponse(agentBridge.status());
          if (req.method === "GET" && url.pathname === "/__agent/events")
            return jsonControlResponse({ events: agentBridge.takeEvents(), ...agentBridge.status() });
          if (req.method !== "POST") return controlResponse("method not allowed", 405);
          let payload: unknown;
          try { payload = await req.json(); }
          catch { return controlResponse("invalid json", 400); }
          if (!isObject(payload)) return controlResponse("invalid request", 400);
          if (url.pathname === "/__agent/start") {
            if (backendState !== "ready") return jsonControlResponse({ error: "WIZP backend is unavailable." }, 503);
            const trust = await backendRpc("workspace/trustState");
            if (trust?.trusted !== true) return jsonControlResponse({ error: "Trust the workspace before starting ZIPI." }, 403);
            const workspaceResult = await backendRpc("workspace/getFolders");
            const folders = Array.isArray(workspaceResult?.folders) ? workspaceResult.folders : [];
            const activeFolder = folders.find((folder: unknown) =>
              isObject(folder) && typeof folder.path === "string" && folder.path.length > 0,
            );
            if (!isObject(activeFolder) || typeof activeFolder.path !== "string")
              return jsonControlResponse({ error: "Open a workspace before starting ZIPI." }, 400);
            const workspace = realpathSync(activeFolder.path);
            const saved = await withSession(readSession);
            const savedSession = typeof saved?.agentSessionId === "string" ? saved.agentSessionId : null;
            const savedWorkspace = typeof saved?.agentWorkspace === "string" ? saved.agentWorkspace : null;
            try {
              const status = await agentBridge.start(workspace, savedSession, savedWorkspace);
              await withSession(() => writeSession({
                agentSessionId: status.sessionId,
                agentWorkspace: workspace,
              }));
              return jsonControlResponse(status);
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              console.error(`ZIPI ACP start failed: ${message}`);
              return jsonControlResponse({ error: message }, 500);
            }
          }
          if (url.pathname === "/__agent/prompt") {
            if (typeof payload.prompt !== "string" || !payload.prompt.trim() || payload.prompt.length > 100_000)
              return controlResponse("invalid prompt", 400);
            const workspace = await trustedAgentWorkspace();
            if (agentBridge.status().workspace !== workspace) return jsonControlResponse({ error: "Agent workspace changed; restart ZIPI." }, 409);
            const context = typeof payload.context === "string" ? payload.context.slice(0, 64_000) : "";
            return jsonControlResponse(await agentBridge.prompt(payload.prompt, context));
          }
          if (url.pathname === "/__agent/cancel")
            return jsonControlResponse(await agentBridge.cancel());
          if (url.pathname === "/__agent/stop")
            return jsonControlResponse(await agentBridge.stop());
          if (url.pathname === "/__agent/propose") {
            if (typeof payload.diff !== "string") return controlResponse("invalid patch", 400);
            const workspace = await trustedAgentWorkspace();
            if (agentBridge.status().workspace !== workspace) return jsonControlResponse({ error: "Agent workspace changed; restart ZIPI." }, 409);
            return jsonControlResponse(agentWorkspace.propose(workspace, payload.diff));
          }
          if (url.pathname === "/__agent/apply") {
            if (typeof payload.id !== "string") return controlResponse("invalid proposal ID", 400);
            const workspace = await trustedAgentWorkspace();
            return jsonControlResponse(agentWorkspace.apply(workspace, payload.id));
          }
          if (url.pathname === "/__agent/discard") {
            if (typeof payload.id !== "string") return controlResponse("invalid proposal ID", 400);
            return jsonControlResponse(agentWorkspace.discard(payload.id));
          }
          return controlResponse("not found", 404);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          return jsonControlResponse({ error: message }, 500);
        }
      }
      if (["/__native-backend", "/__native-backend-retry", "/__native-recovery", "/__native-session", "/__native-file-read", "/__native-file-save"].includes(url.pathname)) {
        if (url.pathname === "/__native-recovery" && !WIZP_NATIVE_UI_SMOKE)
          return controlResponse("not found", 404);
        const methods = url.pathname === "/__native-session" ? ["GET", "POST"]
          : url.pathname === "/__native-backend" ? ["GET"] : ["POST"];
        if (!methods.includes(req.method)) return controlResponse("method not allowed", 405);
        if (req.headers.get("X-WIZP-Control-Token") !== WIZP_CONTROL_TOKEN)
          return controlResponse("forbidden", 403);
        try {
          if (url.pathname === "/__native-backend") {
            return jsonControlResponse(backendStatus());
          }
          if (url.pathname === "/__native-backend-retry") {
            await retryBackend();
            return jsonControlResponse(backendStatus());
          }
          if (url.pathname === "/__native-session" && req.method === "GET")
            return jsonControlResponse(await withSession(readSession));
          let payload: unknown;
          try { payload = await req.json(); }
          catch { return controlResponse("invalid json", 400); }
          if (url.pathname === "/__native-file-read") {
            if (!isObject(payload) || typeof payload.path !== "string" || !payload.path || payload.path.includes("\0"))
              return controlResponse("invalid file path", 400);
            try {
              return jsonControlResponse({ content: readFileSync(payload.path, "utf8") });
            } catch {
              return controlResponse("file read failed", 404);
            }
          }
          if (url.pathname === "/__native-file-save") {
            if (
              !isObject(payload) ||
              typeof payload.path !== "string" ||
              !payload.path ||
              payload.path.includes("\0") ||
              typeof payload.content !== "string"
            )
              return controlResponse("invalid file save", 400);
            try {
              writeFileSync(payload.path, payload.content, "utf8");
              return jsonControlResponse({ saved: true });
            } catch {
              return controlResponse("file save failed", 500);
            }
          }
          if (url.pathname === "/__native-session") {
            if (!validSession(payload)) return controlResponse("invalid session", 400);
            await withSession(() => writeSession(payload));
            return jsonControlResponse({ saved: true });
          }
          if (!isObject(payload)) return controlResponse("invalid action", 400);
          if (payload.action === "disconnect") await disconnectBackend();
          else if (payload.action === "reload-renderer") reloadRenderer();
          else return controlResponse("invalid action", 400);
          return jsonControlResponse(backendStatus());
        } catch (error) {
          console.error("[WIZP] Native recovery operation failed", error);
          return controlResponse("native operation failed", 500);
        }
      }
      if (url.pathname === "/__startup-mark" && WIZP_GUI_BENCHMARK) {
        let payload: any = {};
        if (req.method === "POST") {
          try {
            payload = await req.json();
          } catch (_) {}
        }
        const name = String(payload.name ?? url.searchParams.get("name") ?? "");
        const rawRendererMs = payload.t ?? url.searchParams.get("t");
        const rendererMs =
          typeof rawRendererMs === "number"
            ? rawRendererMs
            : Number.parseFloat(String(rawRendererMs ?? ""));
        if (!name) return controlResponse("missing name", 400);
        recordRendererStartupMark(
          name,
          Number.isFinite(rendererMs) ? rendererMs : null,
        );
        return controlResponse("ok");
      }
      if (
        url.pathname === "/__native-terminal-telemetry" &&
        WIZP_NATIVE_UI_SMOKE
      ) {
        if (req.method === "POST") {
          let payload: any = {};
          try {
            payload = await req.json();
          } catch (_) {
            return controlResponse("invalid json", 400);
          }
          recordNativeTerminalTelemetry(payload);
          return controlResponse("ok");
        }
        if (url.searchParams.has("componentId")) {
          recordNativeTerminalTelemetry(
            telemetryPayloadFromSearchParams(url.searchParams),
          );
          return controlResponse("ok");
        }
        return jsonControlResponse({
          schema: 1,
          terminalCount: Object.keys(nativeTerminalTelemetry).length,
          terminals: nativeTerminalTelemetry,
        });
      }
      if (url.pathname === "/__native-clipboard-read") {
        if (req.method !== "POST")
          return controlResponse("method not allowed", 405);
        if (req.headers.get("X-WIZP-Control-Token") !== WIZP_CONTROL_TOKEN)
          return controlResponse("forbidden", 403);
        return jsonControlResponse({ text: Utils.clipboardReadText() ?? "" });
      }
      if (url.pathname === "/__native-open-external") {
        if (req.method !== "POST")
          return controlResponse("method not allowed", 405);
        if (req.headers.get("X-WIZP-Control-Token") !== WIZP_CONTROL_TOKEN)
          return controlResponse("forbidden", 403);
        let destination: URL;
        try {
          const payload = await req.json();
          if (typeof payload?.url !== "string") throw new Error("missing URL");
          destination = new URL(payload.url);
        } catch {
          return controlResponse("invalid URL", 400);
        }
        if (!["http:", "https:", "mailto:"].includes(destination.protocol))
          return controlResponse("unsupported URL scheme", 400);
        try {
          let opened: boolean;
          if (process.platform === "linux") {
            // The native wrapper's fallback interpolates URLs into shell syntax.
            const child = Bun.spawn(["xdg-open", destination.href], {
              stdout: "ignore",
              stderr: "inherit",
            });
            opened = (await child.exited) === 0;
          } else {
            opened = Utils.openExternal(destination.href);
          }
          return jsonControlResponse({ opened }, opened ? 200 : 502);
        } catch (error) {
          console.error("Failed to open external URL:", error);
          return controlResponse("external opener unavailable", 502);
        }
      }
      if (url.pathname === "/__native-terminal-link" && WIZP_NATIVE_UI_SMOKE) {
        const activation = url.searchParams.get("activation");
        if (activation === "pointer" || activation === "keyboard") {
          nativeTerminalLinkActivations.push({
            source: activation,
            uri: url.toString(),
            activatedAt: new Date().toISOString(),
          });
          if (nativeTerminalLinkActivations.length > 16)
            nativeTerminalLinkActivations.shift();
          return new Response(
            '<!doctype html><meta charset="utf-8"><title>WIZP link activated</title><script>window.close()</script>',
            {
              status: 200,
              headers: {
                ...CONTROL_HEADERS,
                "Content-Type": "text/html; charset=utf-8",
              },
            },
          );
        }
        return jsonControlResponse({
          schema: 1,
          activations: nativeTerminalLinkActivations,
        });
      }
      if (url.pathname === "/__webview-report" && WIZP_NATIVE_UI_SMOKE) {
        if (req.method === "POST") {
          let payload: unknown;
          try {
            payload = await req.json();
          } catch {
            return controlResponse("invalid json", 400);
          }
          const id =
            payload && typeof payload === "object" && "id" in payload
              ? String(payload.id ?? "")
              : "";
          if (!id || id.length > 120) return controlResponse("invalid id", 400);
          nativeWebviewReports[id] =
            payload && typeof payload === "object" && "result" in payload
              ? payload.result
              : null;
          return controlResponse("ok");
        }
        const id = url.searchParams.get("id") ?? "";
        if (id && Object.hasOwn(nativeWebviewReports, id)) {
          const result = nativeWebviewReports[id];
          delete nativeWebviewReports[id];
          return jsonControlResponse({ schema: 1, result });
        }
        return controlResponse("not found", 404);
      }
      if (
        url.pathname === "/__webview-evaluate" &&
        WIZP_NATIVE_UI_SMOKE &&
        mainWin?.webview
      ) {
        if (req.method !== "POST")
          return controlResponse("method not allowed", 405);
        let payload: unknown;
        try {
          payload = await req.json();
        } catch {
          return controlResponse("invalid json", 400);
        }
        const scriptValue =
          payload && typeof payload === "object" && "script" in payload
            ? payload.script
            : "";
        const script = String(scriptValue ?? "");
        if (!script || script.length > 8000)
          return controlResponse("invalid script", 400);
        try {
          const result = await mainWin.webview.executeJavascript(script);
          return jsonControlResponse({ schema: 1, result });
        } catch (err) {
          return jsonControlResponse({ schema: 1, error: String(err) }, 500);
        }
      }
      if (url.pathname === "/__window" && mainWin) {
        const action = url.searchParams.get("action");
        if (action === "close") {
          mainWin.close();
        } else if (action === "drag") {
          try {
            (mainWin as any).startDrag?.();
          } catch (_) {}
        } else if (action === "minimize") {
          try {
            (mainWin as any).minimize?.();
          } catch (_) {}
        } else if (action === "maximize") {
          try {
            (mainWin as any).maximize?.();
          } catch (_) {}
        } else if (action === "restore") {
          try {
            (mainWin as any).unmaximize?.();
          } catch (_) {}
        }
        return controlResponse("ok");
      }
      return controlResponse("not found", 404);
    },
  });
  markStartup("controlServerStarted");
  return controlServer.port;
}

function detailFromEvent(event: any): string | null {
  const detail = event?.data?.detail ?? event?.detail ?? event?.data ?? null;
  if (typeof detail === "string") return detail.slice(0, 512);
  if (detail === null || detail === undefined) return null;
  try {
    return JSON.stringify(detail).slice(0, 512);
  } catch (_) {
    return String(detail).slice(0, 512);
  }
}

function isPlaceholderNavigation(detail: string | null): boolean {
  return detail?.includes("data:text/html") ?? false;
}

function startupProbeScript(): string {
  const endpoint = `http://127.0.0.1:${WIZP_CONTROL_PORT}/__startup-mark`;
  return `
(() => {
  const endpoint = ${JSON.stringify(endpoint)};
  const keep = [];
  const mark = (name) => {
    try {
      const params = new URLSearchParams({
        name,
        t: String(performance.now()),
        href: window.location.href,
        source: "injected",
      });
      const url = endpoint + "?" + params.toString();
      const image = new Image();
      image.src = url + "&transport=injected-image&nonce=" + Date.now() + "-" + Math.random();
      keep.push(image);
      if (keep.length > 16) keep.shift();
      fetch(url + "&transport=injected-fetch", { mode: "no-cors", keepalive: true }).catch(() => {});
    } catch (_) {}
  };
  mark("injectedDomReady");
  requestAnimationFrame(() => {
    mark("injectedFirstRaf");
    requestAnimationFrame(() => mark("injectedSecondRafInteractive"));
  });
  const deadline = Date.now() + 3000;
  const observeBody = () => {
    if (document.body && !document.body.hasAttribute("data-svelte-boot")) {
      mark("injectedBodyVisibleObserved");
    } else if (Date.now() < deadline) {
      setTimeout(observeBody, 25);
    }
  };
  observeBody();
})();
`;
}

function injectStartupProbe(win: any) {
  if (!WIZP_GUI_BENCHMARK || startupProbeInjected) return;
  startupProbeInjected = true;
  markStartup("rendererProbeInjected");
  try {
    win.webview?.executeJavascript?.(startupProbeScript());
  } catch (_) {}
}

function installWebviewStartupMarks(win: any) {
  if (!WIZP_GUI_BENCHMARK) return;
  const events = [
    "will-navigate",
    "did-commit-navigation",
    "did-navigate",
    "did-navigate-in-page",
    "dom-ready",
  ];
  for (const eventName of events) {
    try {
      win.webview?.on?.(eventName, (event: any) => {
        const detail = detailFromEvent(event);
        if (detail) webviewStartupDetails[eventName] = detail;
        if (isPlaceholderNavigation(detail)) {
          markStartup(`webview.placeholder.${eventName}`);
          return;
        }
        markStartup(`webview.${eventName}`);
        if (eventName === "dom-ready") injectStartupProbe(win);
      });
    } catch (_) {}
  }
}

function appUrl(): string {
  const url = new URL(`http://${WIZP_HOST}:${WIZP_PORT}/`);
  url.searchParams.set("wizpControlPort", String(WIZP_CONTROL_PORT));
  url.searchParams.set("wizpControlToken", WIZP_CONTROL_TOKEN);
  url.searchParams.set("wizpSessionPath", WIZP_SESSION_PATH);
  for (const path of STARTUP_OPEN_PATHS) {
    url.searchParams.append("wizpOpenPath", path);
  }
  const nativeSmokeTerminals = Number.parseInt(
    Bun.env.WIZP_NATIVE_UI_SMOKE_TERMINALS ?? "",
    10,
  );
  if (
    Number.isFinite(nativeSmokeTerminals) &&
    nativeSmokeTerminals >= 1 &&
    nativeSmokeTerminals <= 8
  ) {
    url.searchParams.set(
      "wizpNativeSmokeTerminals",
      String(nativeSmokeTerminals),
    );
  }
  if (WIZP_GUI_BENCHMARK) {
    url.searchParams.set("wizpStartupBenchmark", "1");
  }
  return url.toString();
}

function tryNavigateToApp() {
  if (navigationRequested || !backendReadyChecked || !mainWin?.webview) return;
  navigationRequested = true;
  markStartup("navigationRequested");
  mainWin.webview.loadURL(appUrl());
}

function deferNativeMenu() {
  if (WIZP_NATIVE_UI_SMOKE) {
    markStartup("nativeMenuSkippedForSmoke");
    return;
  }
  setTimeout(() => {
    buildNativeMenu();
    markStartup("nativeMenuReady");
  }, 250);
}

// ─── Boot sequence ───────────────────────────────────────────────────────────

const saved = loadWindowState();

// Start the lightweight control server and backend before CEF window creation so
// backend readiness overlaps the native-window cold-start cost.
startControlServer();
void requestZigRestart().then(() => {
  backendReadyChecked = true;
  markStartup(backendState === "ready" ? "backendReady" : "backendReadyTimeout");
  tryNavigateToApp();
});

// Create the window immediately with a dark background HTML payload to avoid any white flash/blink
markStartup("windowCreateStart");
mainWin = new BrowserWindow({
  title: "WIZP",
  frame: saved,
  url: PLACEHOLDER_URL,
  html: null,
  preload: null,
  viewsRoot: null,
  titleBarStyle: "default",
  transparent: false,
  passthrough: false,
  navigationRules: null,
  sandbox: false,
  resizable: true,
});
markStartup("windowCreated");
installWebviewStartupMarks(mainWin);
tryNavigateToApp();

mainWin.on("move", () => saveWindowState(mainWin));
mainWin.on("resize", () => saveWindowState(mainWin));
deferNativeMenu();

if (WIZP_GUI_BENCHMARK) {
  const timeoutMs =
    Number.parseInt(Bun.env.WIZP_GUI_BENCHMARK_TIMEOUT_MS ?? "8000", 10) ||
    8000;
  setTimeout(() => emitGuiBenchmark("timeout"), timeoutMs);
}

process.on("SIGINT", () => {
  handleTerminationSignal(0);
});
process.on("SIGTERM", () => {
  handleTerminationSignal(0);
});
app.on("before-quit", () => {
  handleTerminationSignal(0);
});
