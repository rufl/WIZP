#!/usr/bin/env node
/* Measure WIZP process-cold startup and first-load server latency. */

const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");

function parseArgs(argv) {
  const args = {
    binary: "./zig-out/bin/wizp",
    runs: 9,
    warmups: 0,
    portBase: 19876,
    timeoutMs: 5000,
    output: "build/parity-stress/startup-benchmark.json",
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => argv[++i];
    if (arg === "--binary") args.binary = next();
    else if (arg === "--runs") args.runs = Number.parseInt(next(), 10);
    else if (arg === "--warmups") args.warmups = Number.parseInt(next(), 10);
    else if (arg === "--port-base") args.portBase = Number.parseInt(next(), 10);
    else if (arg === "--timeout-ms") args.timeoutMs = Number.parseInt(next(), 10);
    else if (arg === "--output") args.output = next();
    else if (arg === "--help" || arg === "-h") {
      console.log(`Usage: node scripts/benchmark-startup.js [options]

Options:
  --binary PATH       WIZP binary to benchmark (default: ./zig-out/bin/wizp)
  --runs N           Measured process-cold server runs (default: 9)
  --warmups N        Unrecorded warmup runs (default: 0)
  --port-base PORT   First benchmark port (default: 19876)
  --timeout-ms MS    Per-run readiness timeout (default: 5000)
  --output PATH      JSON report path (default: build/parity-stress/startup-benchmark.json)
`);
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!Number.isFinite(args.runs) || args.runs < 1) args.runs = 1;
  if (!Number.isFinite(args.warmups) || args.warmups < 0) args.warmups = 0;
  if (!Number.isFinite(args.portBase) || args.portBase < 1024) args.portBase = 19876;
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs < 100) args.timeoutMs = 5000;
  return args;
}

function nowMs() {
  return Number(process.hrtime.bigint()) / 1_000_000;
}

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[index];
}

function summarize(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const sum = sorted.reduce((acc, value) => acc + value, 0);
  return {
    min: sorted[0] ?? 0,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    max: sorted[sorted.length - 1] ?? 0,
    mean: sorted.length ? sum / sorted.length : 0,
  };
}

function request(port, pathname, timeoutMs) {
  const started = nowMs();
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port,
        path: pathname,
        method: "GET",
        agent: false,
        timeout: timeoutMs,
        headers: { "Cache-Control": "no-cache" },
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const body = Buffer.concat(chunks);
          resolve({
            path: pathname,
            statusCode: res.statusCode,
            bytes: body.length,
            durationMs: nowMs() - started,
            body,
          });
        });
      },
    );
    req.on("timeout", () => {
      req.destroy(new Error(`timeout fetching ${pathname}`));
    });
    req.on("error", reject);
    req.end();
  });
}

async function waitForReady(port, timeoutMs) {
  const started = nowMs();
  let attempts = 0;
  while (nowMs() - started < timeoutMs) {
    attempts += 1;
    try {
      const ready = await request(port, "/__wizp_ready", 250);
      if (ready.statusCode === 204) {
        return { durationMs: nowMs() - started, attempts };
      }
    } catch (_) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  }
  throw new Error(`timeout waiting for WIZP on port ${port}`);
}

function extractCriticalAssets(html) {
  const assets = new Set();
  const re = /\b(?:src|href)=["']([^"']+)["']/g;
  let match;
  while ((match = re.exec(html))) {
    const ref = match[1];
    if (ref.startsWith("/assets/") || ref === "/favicon.svg") {
      assets.add(ref);
    }
  }
  return [...assets].sort();
}

function collectOutput(child) {
  const chunks = [];
  const push = (chunk) => {
    chunks.push(Buffer.from(chunk));
    while (chunks.reduce((sum, item) => sum + item.length, 0) > 32_768) {
      chunks.shift();
    }
  };
  child.stdout?.on("data", push);
  child.stderr?.on("data", push);
  return () => Buffer.concat(chunks).toString("utf8");
}

async function terminalProbe(binary, timeoutMs) {
  const started = nowMs();
  const child = spawn(binary, ["--terminal-probe"], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });
  const output = collectOutput(child);
  const exitCode = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("terminal probe timed out"));
    }, timeoutMs);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
  const text = output();
  if (exitCode !== 0 || !text.includes("WIZP terminal probe ready")) {
    throw new Error(`terminal probe failed (${exitCode}): ${text.slice(-800)}`);
  }
  return { durationMs: nowMs() - started, exitCode };
}

async function serverRun(binary, port, timeoutMs) {
  const started = nowMs();
  const child = spawn(binary, [], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      WIZP_PORT: String(port),
      WIZP_NO_BROWSER: "1",
    },
  });
  const output = collectOutput(child);
  let killed = false;
  const cleanup = async () => {
    if (killed) return;
    killed = true;
    try {
      child.kill("SIGTERM");
    } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 25));
    try {
      child.kill("SIGKILL");
    } catch (_) {}
  };

  try {
    const ready = await waitForReady(port, timeoutMs);
    const processReadyMs = nowMs() - started;
    const index = await request(port, "/", timeoutMs);
    if (index.statusCode !== 200) {
      throw new Error(`GET / returned ${index.statusCode}`);
    }
    const assets = extractCriticalAssets(index.body.toString("utf8"));
    const assetStarted = nowMs();
    const assetResults = await Promise.all(assets.map((asset) => request(port, asset, timeoutMs)));
    const assetLoadMs = nowMs() - assetStarted;
    const monacoLoader = await request(port, "/monaco/loader.js", timeoutMs);
    const failedAsset = assetResults.find((result) => result.statusCode !== 200);
    if (failedAsset) {
      throw new Error(`asset ${failedAsset.path} returned ${failedAsset.statusCode}`);
    }
    return {
      port,
      processReadyMs,
      readyPollMs: ready.durationMs,
      readyAttempts: ready.attempts,
      firstHtmlMs: index.durationMs,
      firstHtmlBytes: index.bytes,
      criticalAssetCount: assetResults.length,
      criticalAssetsMs: assetLoadMs,
      criticalAssetBytes: assetResults.reduce((sum, result) => sum + result.bytes, 0),
      monacoLoaderMs: monacoLoader.durationMs,
      monacoLoaderBytes: monacoLoader.bytes,
      totalMeasuredMs: nowMs() - started,
      stderrTail: output().slice(-800),
    };
  } finally {
    await cleanup();
  }
}

function rounded(value) {
  return Math.round(value * 10) / 10;
}

function roundedSummary(values) {
  const raw = summarize(values);
  return Object.fromEntries(Object.entries(raw).map(([key, value]) => [key, rounded(value)]));
}

async function main() {
  const args = parseArgs(process.argv);
  const binary = path.resolve(ROOT, args.binary);
  if (!fs.existsSync(binary)) {
    throw new Error(`missing WIZP binary: ${binary}. Run npm run build first.`);
  }

  console.log("=== WIZP Cold-Start Benchmark ===");
  console.log(`binary: ${path.relative(ROOT, binary)}`);
  console.log(`runs: ${args.runs}, warmups: ${args.warmups}, portBase: ${args.portBase}`);

  const terminal = await terminalProbe(binary, args.timeoutMs);
  console.log(`terminal probe: ${rounded(terminal.durationMs)}ms`);

  for (let i = 0; i < args.warmups; i += 1) {
    await serverRun(binary, args.portBase + i, args.timeoutMs);
  }

  const runs = [];
  for (let i = 0; i < args.runs; i += 1) {
    const run = await serverRun(binary, args.portBase + args.warmups + i, args.timeoutMs);
    runs.push(run);
    console.log(
      `#${String(i + 1).padStart(2, "0")} ready=${rounded(run.processReadyMs)}ms html=${rounded(run.firstHtmlMs)}ms assets=${rounded(run.criticalAssetsMs)}ms monacoLoader=${rounded(run.monacoLoaderMs)}ms`,
    );
  }

  const report = {
    schema: 1,
    benchmarkKind: "process-cold-repeated",
    timestamp: new Date().toISOString(),
    binary,
    environment: {
      platform: process.platform,
      arch: process.arch,
      node: process.version,
      wizpHttpWorkers: process.env.WIZP_HTTP_WORKERS ?? "default",
    },
    terminalProbe: { durationMs: rounded(terminal.durationMs), exitCode: terminal.exitCode },
    runs: runs.map((run) => ({
      ...run,
      processReadyMs: rounded(run.processReadyMs),
      firstHtmlMs: rounded(run.firstHtmlMs),
      criticalAssetsMs: rounded(run.criticalAssetsMs),
      monacoLoaderMs: rounded(run.monacoLoaderMs),
      totalMeasuredMs: rounded(run.totalMeasuredMs),
    })),
    summary: {
      processReadyMs: roundedSummary(runs.map((run) => run.processReadyMs)),
      firstHtmlMs: roundedSummary(runs.map((run) => run.firstHtmlMs)),
      criticalAssetsMs: roundedSummary(runs.map((run) => run.criticalAssetsMs)),
      monacoLoaderMs: roundedSummary(runs.map((run) => run.monacoLoaderMs)),
      totalMeasuredMs: roundedSummary(runs.map((run) => run.totalMeasuredMs)),
    },
  };

  const output = path.resolve(ROOT, args.output);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(report, null, 2) + "\n");

  console.log("\nSummary:");
  console.log(`ready p50/p95: ${report.summary.processReadyMs.p50}ms / ${report.summary.processReadyMs.p95}ms`);
  console.log(`html  p50/p95: ${report.summary.firstHtmlMs.p50}ms / ${report.summary.firstHtmlMs.p95}ms`);
  console.log(`assets p50/p95: ${report.summary.criticalAssetsMs.p50}ms / ${report.summary.criticalAssetsMs.p95}ms`);
  console.log(`report: ${path.relative(ROOT, output)}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
