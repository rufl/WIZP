#!/usr/bin/env node
/* Measure WIZP Electrobun native-window startup through first renderer RAF. */

const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

if (process.env.LICHFORGE_ISOLATED_DISPLAY !== "1") {
  const runner = process.env.OVERZEER_DISPLAY_RUNNER || `${process.env.HOME}/.local/bin/overzeer-isolated-display`;
  if (!fs.existsSync(runner)) {
    console.error("shared isolated display runner is required; refusing the active desktop");
    process.exit(1);
  }
  const result = spawnSync(runner, ["--screen", "1280x820x24", "--timeout", "300", "--wm", "none", "--", process.execPath, __filename, ...process.argv.slice(2)], { stdio: "inherit", env: process.env });
  process.exit(result.status ?? 1);
}

const ROOT = path.resolve(__dirname, "..");
const PREFIX = "WIZP_GUI_STARTUP_BENCHMARK ";

function parseArgs(argv) {
  const args = {
    binary: "./build/dev-linux-x64/WIZP-dev/bin/launcher",
    runs: 5,
    warmups: 0,
    portBase: 21876,
    controlPortBase: 22876,
    timeoutMs: 12000,
    output: "build/parity-stress/gui-startup-benchmark.json",
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => argv[++i];
    if (arg === "--binary") args.binary = next();
    else if (arg === "--runs") args.runs = Number.parseInt(next(), 10);
    else if (arg === "--warmups") args.warmups = Number.parseInt(next(), 10);
    else if (arg === "--port-base") args.portBase = Number.parseInt(next(), 10);
    else if (arg === "--control-port-base") args.controlPortBase = Number.parseInt(next(), 10);
    else if (arg === "--timeout-ms") args.timeoutMs = Number.parseInt(next(), 10);
    else if (arg === "--output") args.output = next();
    else if (arg === "--help" || arg === "-h") {
      console.log(`Usage: node scripts/benchmark-gui-startup.js [options]

Options:
  --binary PATH              Native Electrobun launcher (default: packaged Linux launcher)
  --runs N                   Measured native GUI runs (default: 5)
  --warmups N                Unrecorded warmup runs (default: 0)
  --port-base PORT           First backend HTTP port (default: 21876)
  --control-port-base PORT   First window-control port (default: 22876)
  --timeout-ms MS            Per-run benchmark timeout (default: 12000)
  --output PATH              JSON report path (default: build/parity-stress/gui-startup-benchmark.json)
`);
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!Number.isFinite(args.runs) || args.runs < 1) args.runs = 1;
  if (!Number.isFinite(args.warmups) || args.warmups < 0) args.warmups = 0;
  if (!Number.isFinite(args.portBase) || args.portBase < 1024) args.portBase = 21876;
  if (!Number.isFinite(args.controlPortBase) || args.controlPortBase < 1024) args.controlPortBase = 22876;
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs < 1000) args.timeoutMs = 12000;
  return args;
}

function nowMs() {
  return Number(process.hrtime.bigint()) / 1_000_000;
}

function rounded(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.round(value * 10) / 10;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[index];
}

function formatMetric(value) {
  const roundedValue = rounded(value);
  return roundedValue === null ? "n/a" : `${roundedValue}ms`;
}

function summarize(values) {
  const sorted = values.filter((value) => typeof value === "number" && Number.isFinite(value)).sort((a, b) => a - b);
  if (sorted.length === 0) {
    return { min: null, p50: null, p95: null, max: null, mean: null };
  }
  const sum = sorted.reduce((acc, value) => acc + value, 0);
  return {
    min: rounded(sorted[0] ?? 0),
    p50: rounded(percentile(sorted, 50)),
    p95: rounded(percentile(sorted, 95)),
    max: rounded(sorted[sorted.length - 1] ?? 0),
    mean: rounded(sorted.length ? sum / sorted.length : 0),
  };
}

function trimOutput(output) {
  if (output.length <= 1_048_576) return output;
  return output.slice(output.length - 1_048_576);
}

function extractReport(output) {
  const index = output.indexOf(PREFIX);
  if (index === -1) return null;
  const start = index + PREFIX.length;
  let depth = 0;
  let inString = false;
  let escaped = false;
  let end = -1;
  for (let i = start; i < output.length; i += 1) {
    const ch = output[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      escaped = true;
      continue;
    }
    if (ch === "\"") {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end === -1) return null;
  const line = output.slice(start, end).trim();
  try {
    return JSON.parse(line);
  } catch (_) {
    return null;
  }
}

async function guiRun(binary, index, port, controlPort, timeoutMs) {
  const started = nowMs();
  const runStateDir = fs.mkdtempSync(path.join(os.tmpdir(), `wizp-gui-startup-${index}-`));
  const cleanupStateDir = () => {
    try { fs.rmSync(runStateDir, { recursive: true, force: true }); } catch (_) {}
  };
  const child = spawn(binary, [], {
    cwd: ROOT,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      WIZP_GUI_BENCHMARK: "1",
      WIZP_GUI_BENCHMARK_TIMEOUT_MS: String(Math.max(1000, timeoutMs - 4000)),
      WIZP_HTTP_WORKERS: process.env.WIZP_HTTP_WORKERS ?? "1",
      WIZP_PORT: String(port),
      WIZP_CONTROL_PORT: String(controlPort),
      XDG_CACHE_HOME: path.join(runStateDir, "cache"),
      XDG_CONFIG_HOME: path.join(runStateDir, "config"),
      XDG_DATA_HOME: path.join(runStateDir, "data"),
      XDG_STATE_HOME: path.join(runStateDir, "state"),
    },
  });

  let output = "";
  let parsed = null;

  const killGroup = (signal) => {
    try {
      process.kill(-child.pid, signal);
    } catch (_) {
      try { child.kill(signal); } catch (_) {}
    }
  };

  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (parsed) {
        finishOk();
        return;
      }
      killGroup("SIGTERM");
      setTimeout(() => {
        killGroup("SIGKILL");
      }, 250).unref?.();
      settled = true;
      cleanupStateDir();
      reject(new Error(`GUI benchmark run ${index} timed out: ${output.slice(-1200)}`));
    }, timeoutMs);

    const finishOk = () => {
      if (settled || !parsed) return;
      settled = true;
      clearTimeout(timer);
      const launcherToReportMs = nowMs() - started;
      const result = {
        run: index,
        port,
        controlPort,
        runStateDir,
        exitCode: child.exitCode,
        signal: child.signalCode,
        launcherToReportMs,
        report: parsed,
        stderrTail: output.slice(-1200),
      };
      const finish = () => {
        cleanupStateDir();
        resolve(result);
      };
      if (child.exitCode !== null || child.signalCode !== null) {
        finish();
        return;
      }
      const killTimer = setTimeout(() => {
        killGroup("SIGKILL");
      }, 500);
      killTimer.unref?.();
      child.once("exit", () => {
        result.exitCode = child.exitCode;
        result.signal = child.signalCode;
        clearTimeout(killTimer);
        finish();
      });
      killGroup("SIGTERM");
    };

    const append = (chunk) => {
      const combined = output + Buffer.from(chunk).toString("utf8");
      parsed = parsed || extractReport(combined);
      output = trimOutput(combined);
      if (parsed) finishOk();
    };
    child.stdout?.on("data", append);
    child.stderr?.on("data", append);

    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      cleanupStateDir();
      reject(error);
    });

    child.on("exit", (code, signal) => {
      if (settled) return;
      clearTimeout(timer);
      parsed = parsed || extractReport(output);
      if (!parsed) {
        settled = true;
        cleanupStateDir();
        reject(new Error(`GUI benchmark run ${index} exited without report (${code ?? signal}): ${output.slice(-1200)}`));
        return;
      }
      settled = true;
      const launcherToReportMs = nowMs() - started;
      cleanupStateDir();
      resolve({
        run: index,
        port,
        controlPort,
        exitCode: code,
        signal,
        launcherToReportMs,
        report: parsed,
        stderrTail: output.slice(-1200),
      });
    });
  });
}

function compactRun(run) {
  const metrics = run.report.metricsMs || {};
  const appInteractive = rounded(metrics.processToFirstInteractiveReceived);
  const injectedInteractive = rounded(metrics.processToInjectedSecondRafReceived);
  return {
    run: run.run,
    port: run.port,
    controlPort: run.controlPort,
    exitCode: run.exitCode,
    signal: run.signal,
    launcherToReportMs: rounded(run.launcherToReportMs),
    processToWindowMs: rounded(metrics.processToWindow),
    processToBackendReadyMs: rounded(metrics.processToBackendReady),
    navigationToDomReadyMs: rounded(metrics.navigationToDomReady),
    processToFirstRafReceivedMs: rounded(metrics.processToFirstRafReceived),
    processToFirstInteractiveReceivedMs: appInteractive,
    processToInjectedFirstRafReceivedMs: rounded(metrics.processToInjectedFirstRafReceived),
    processToInjectedSecondRafReceivedMs: injectedInteractive,
    processToInjectedBodyVisibleObservedMs: rounded(metrics.processToInjectedBodyVisibleObserved),
    processToFirstInteractiveProofMs: appInteractive ?? injectedInteractive,
    rendererModuleToSecondRafInteractiveMs: rounded(metrics.rendererModuleToSecondRafInteractive),
    marksMs: run.report.marksMs,
    webviewDetails: run.report.webviewDetails,
    rendererMarksMs: run.report.rendererMarksMs,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  const binary = path.resolve(ROOT, args.binary);
  if (!fs.existsSync(binary)) {
    throw new Error(`missing native launcher: ${binary}. Run npm run build:self-contained first or pass --binary.`);
  }
  if (process.platform === "linux" && !process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) {
    throw new Error("native GUI benchmark requires DISPLAY or WAYLAND_DISPLAY; run inside a desktop session or xvfb-run.");
  }

  console.log("=== WIZP Native GUI Startup Benchmark ===");
  console.log(`binary: ${path.relative(ROOT, binary)}`);
  console.log(`runs: ${args.runs}, warmups: ${args.warmups}, portBase: ${args.portBase}, controlPortBase: ${args.controlPortBase}`);

  for (let i = 0; i < args.warmups; i += 1) {
    await guiRun(binary, i + 1, args.portBase + i, args.controlPortBase + i, args.timeoutMs);
  }

  const runs = [];
  for (let i = 0; i < args.runs; i += 1) {
    const offset = args.warmups + i;
    const run = await guiRun(binary, i + 1, args.portBase + offset, args.controlPortBase + offset, args.timeoutMs);
    runs.push(run);
    const metrics = run.report.metricsMs || {};
    const interactive = rounded(metrics.processToFirstInteractiveReceived) ?? rounded(metrics.processToInjectedSecondRafReceived);
    console.log(
      `#${String(i + 1).padStart(2, "0")} window=${formatMetric(metrics.processToWindow)} backend=${formatMetric(metrics.processToBackendReady)} dom=${formatMetric(metrics.navigationToDomReady)} interactive=${formatMetric(interactive)}`,
    );
  }

  const compactRuns = runs.map(compactRun);
  const report = {
    schema: 1,
    benchmarkKind: "electrobun-gui-cold-repeated",
    timestamp: new Date().toISOString(),
    binary,
    environment: {
      platform: process.platform,
      arch: process.arch,
      node: process.version,
      display: process.env.DISPLAY || null,
      waylandDisplay: process.env.WAYLAND_DISPLAY || null,
      wizpHttpWorkers: process.env.WIZP_HTTP_WORKERS ?? "1",
    },
    runs: compactRuns,
    summary: {
      launcherToReportMs: summarize(runs.map((run) => run.launcherToReportMs)),
      processToWindowMs: summarize(compactRuns.map((run) => run.processToWindowMs)),
      processToBackendReadyMs: summarize(compactRuns.map((run) => run.processToBackendReadyMs)),
      navigationToDomReadyMs: summarize(compactRuns.map((run) => run.navigationToDomReadyMs)),
      processToFirstRafReceivedMs: summarize(compactRuns.map((run) => run.processToFirstRafReceivedMs)),
      processToFirstInteractiveReceivedMs: summarize(compactRuns.map((run) => run.processToFirstInteractiveReceivedMs)),
      processToInjectedFirstRafReceivedMs: summarize(compactRuns.map((run) => run.processToInjectedFirstRafReceivedMs)),
      processToInjectedSecondRafReceivedMs: summarize(compactRuns.map((run) => run.processToInjectedSecondRafReceivedMs)),
      processToInjectedBodyVisibleObservedMs: summarize(compactRuns.map((run) => run.processToInjectedBodyVisibleObservedMs)),
      processToFirstInteractiveProofMs: summarize(compactRuns.map((run) => run.processToFirstInteractiveProofMs)),
      rendererModuleToSecondRafInteractiveMs: summarize(compactRuns.map((run) => run.rendererModuleToSecondRafInteractiveMs)),
    },
  };

  const output = path.resolve(ROOT, args.output);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + "\n");

  console.log("\nSummary:");
  console.log(`window p50/p95: ${report.summary.processToWindowMs.p50}ms / ${report.summary.processToWindowMs.p95}ms`);
  console.log(`backend p50/p95: ${report.summary.processToBackendReadyMs.p50}ms / ${report.summary.processToBackendReadyMs.p95}ms`);
  console.log(`interactive p50/p95: ${report.summary.processToFirstInteractiveProofMs.p50}ms / ${report.summary.processToFirstInteractiveProofMs.p95}ms`);
  console.log(`report: ${path.relative(ROOT, output)}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
