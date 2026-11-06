import { afterEach, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, watch, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AgentBridge } from "./agent";

const temporaryDirectories: string[] = [];
const originalZipi = Bun.env.ZIPI_BIN;
const bridges: AgentBridge[] = [];

afterEach(async () => {
  await Promise.all(bridges.splice(0).map((bridge) => bridge.stop()));
  if (originalZipi === undefined) {
    delete process.env.ZIPI_BIN;
    delete Bun.env.ZIPI_BIN;
  } else {
    process.env.ZIPI_BIN = originalZipi;
    Bun.env.ZIPI_BIN = originalZipi;
  }
  for (const directory of temporaryDirectories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fakeZipi() {
  const directory = mkdtempSync(join(tmpdir(), "wizp-agent-bridge-"));
  temporaryDirectories.push(directory);
  const executable = join(directory, "fake-zipi");
  const spawnLog = join(directory, "spawns");
  writeFileSync(spawnLog, "");
  writeFileSync(executable, `#!/usr/bin/env python3
import json, sys, time
spawn_log = ${JSON.stringify(spawnLog)}
with open(spawn_log, "a") as log: log.write("spawn\\n")
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    with open(spawn_log, "a") as log: log.write(method + "\\n")
    if method == "initialize":
        time.sleep(0.1)
        print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":{}}), flush=True)
    elif method == "session/new":
        time.sleep(0.2)
        print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":{"sessionId":"single-flight"}}), flush=True)
    elif method == "shutdown":
        print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":{}}), flush=True)
        break
`);
  chmodSync(executable, 0o755);
  process.env.ZIPI_BIN = executable;
  Bun.env.ZIPI_BIN = executable;
  return { directory, spawnLog };
}

test("concurrent starts share initialized session and reject another workspace", async () => {
  const { directory, spawnLog } = fakeZipi();
  const bridge = new AgentBridge();
  bridges.push(bridge);

  const first = bridge.start(directory);
  const second = bridge.start(directory);
  await expect(bridge.start(tmpdir())).rejects.toThrow("Stop the current agent before changing workspace.");
  const [firstStatus, secondStatus] = await Promise.all([first, second]);

  expect(firstStatus.sessionId).toBe("single-flight");
  expect(secondStatus.sessionId).toBe("single-flight");
  expect(readFileSync(spawnLog, "utf8").trim().split("\n").filter((line) => line === "spawn")).toHaveLength(1);
});

test("stop during session creation does not restore a stale session", async () => {
  const { directory, spawnLog } = fakeZipi();
  const bridge = new AgentBridge();
  bridges.push(bridge);

  const watcher = watch(spawnLog);
  const sessionRequest = new Promise<void>((resolve) => {
    watcher.on("change", () => {
      if (readFileSync(spawnLog, "utf8").includes("session/new")) resolve();
    });
  });
  const starting = bridge.start(directory);
  try {
    await sessionRequest;
  } finally {
    watcher.close();
  }

  const stopping = bridge.stop();
  await expect(starting).rejects.toThrow("ZIPI agent stopped during startup.");
  await stopping;
  expect(bridge.status()).toMatchObject({ available: false, sessionId: null, workspace: "" });
});
