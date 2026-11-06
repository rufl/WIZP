import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { AgentWorkspace } from "./agent-workspace";

const directories: string[] = [];

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function workspace() {
  const directory = mkdtempSync(join(tmpdir(), "wizp-agent-workspace-"));
  directories.push(directory);
  return directory;
}

const patch = "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n";

test("agent patch apply is explicit and writes only the reviewed workspace file", () => {
  const root = workspace();
  writeFileSync(join(root, "file.txt"), "one\ntwo\n");
  const proposals = new AgentWorkspace();
  const proposal = proposals.propose(root, patch);
  expect(proposal.path).toBe("file.txt");
  expect(readFileSync(join(root, "file.txt"), "utf8")).toBe("one\ntwo\n");
  expect(proposals.apply(root, proposal.id)).toEqual({ applied: true, path: "file.txt" });
  expect(readFileSync(join(root, "file.txt"), "utf8")).toBe("one\nTWO\n");
});

test("agent patch apply rejects stale files and paths outside the workspace", () => {
  const root = workspace();
  writeFileSync(join(root, "file.txt"), "one\ntwo\n");
  const proposals = new AgentWorkspace();
  const proposal = proposals.propose(root, patch);
  writeFileSync(join(root, "file.txt"), "one\nchanged\n");
  expect(() => proposals.apply(root, proposal.id)).toThrow("File changed since review");
  const outsidePatch = "--- a/../outside.txt\n+++ b/../outside.txt\n@@ -1 +1 @@\n-old\n+new\n";
  expect(() => proposals.propose(root, outsidePatch)).toThrow("escapes the workspace");
});

test("agent patch approval rejects symlink targets", () => {
  const root = workspace();
  const outside = join(workspace(), "outside.txt");
  writeFileSync(outside, "one\ntwo\n");
  symlinkSync(outside, join(root, "file.txt"));
  const proposals = new AgentWorkspace();
  expect(() => proposals.propose(root, patch)).toThrow("existing regular file");
});

test("agent patch approval rejects invalid UTF-8 and inconsistent hunk coordinates", () => {
  const root = workspace();
  writeFileSync(join(root, "file.txt"), Buffer.from([0x6f, 0x6e, 0x65, 0x0a, 0xff, 0x0a]));
  const proposals = new AgentWorkspace();
  expect(() => proposals.propose(root, patch)).toThrow("not valid UTF-8");
  writeFileSync(join(root, "file.txt"), "one\ntwo\n");
  const wrongCoordinates = "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +8,2 @@\n one\n-two\n+TWO\n";
  expect(() => proposals.propose(root, wrongCoordinates)).toThrow("new-line coordinates");
});
