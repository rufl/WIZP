import { createHash } from "crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, openSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "fs";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "path";

type Proposal = {
  id: string;
  root: string;
  target: string;
  relativePath: string;
  originalHash: string;
  content: string;
  mode: number;
  diff: string;
};

export class AgentWorkspace {
  private readonly proposals = new Map<string, Proposal>();

  propose(workspace: string, diff: string) {
    if (diff.length > 256_000) throw new Error("Patch exceeds 256 KiB.");
    const root = realpathSync(workspace);
    const parsed = applyUnifiedDiff(diff);
    const target = resolve(root, parsed.path);
    assertWithin(root, target);
    if (!existsSync(target) || lstatSync(target).isSymbolicLink()) throw new Error("Patch target must be an existing regular file.");
    const canonicalTarget = realpathSync(target);
    assertWithin(root, canonicalTarget);
    const file = statSync(canonicalTarget);
    if (!file.isFile()) throw new Error("Patch target is not a regular file.");
    const originalBytes = readFileSync(canonicalTarget);
    if (originalBytes.includes(0)) throw new Error("Binary files are not supported.");
    const original = originalBytes.toString("utf8");
    if (!Buffer.from(original, "utf8").equals(originalBytes))
      throw new Error("Patch target is not valid UTF-8.");
    const content = applyHunks(original, parsed.hunks);
    if (content === original) throw new Error("Patch does not change the file.");
    const id = crypto.randomUUID();
    const proposal: Proposal = {
      id,
      root,
      target: canonicalTarget,
      relativePath: relative(root, canonicalTarget).split(sep).join("/"),
      originalHash: sha256(original),
      content,
      mode: file.mode & 0o777,
      diff,
    };
    this.proposals.set(id, proposal);
    while (this.proposals.size > 32) {
      const oldest = this.proposals.keys().next().value;
      if (!oldest) break;
      this.proposals.delete(oldest);
    }
    return { id, path: proposal.relativePath, diff };
  }

  apply(workspace: string, id: string) {
    const proposal = this.proposals.get(id);
    if (!proposal) throw new Error("Patch proposal expired or was already applied.");
    const root = realpathSync(workspace);
    if (root !== proposal.root) throw new Error("Workspace changed after patch review.");
    const target = realpathSync(proposal.target);
    assertWithin(root, target);
    if (target !== proposal.target || lstatSync(proposal.target).isSymbolicLink()) throw new Error("Patch target changed after review.");
    const current = readFileSync(target, "utf8");
    if (sha256(current) !== proposal.originalHash) throw new Error("File changed since review; generate a fresh patch.");
    const temporary = resolve(dirname(target), `.${basename(target)}.wizp-${id}.tmp`);
    let descriptor: number | null = null;
    try {
      descriptor = openSync(temporary, "wx", proposal.mode);
      writeFileSync(descriptor, proposal.content, "utf8");
      fsyncSync(descriptor);
      closeSync(descriptor);
      descriptor = null;
      renameSync(temporary, target);
      if (process.platform !== "win32") {
        const directory = openSync(dirname(target), "r");
        try { fsyncSync(directory); } finally { closeSync(directory); }
      }
    } finally {
      if (descriptor !== null) closeSync(descriptor);
      try { unlinkSync(temporary); } catch (error) {
        if (!error || typeof error !== "object" || !("code" in error) || error.code !== "ENOENT") throw error;
      }
    }
    this.proposals.delete(id);
    return { applied: true, path: proposal.relativePath };
  }

  discard(id: string) {
    return { discarded: this.proposals.delete(id) };
  }
}

function sha256(content: string) {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

function assertWithin(root: string, target: string) {
  const rel = relative(root, target);
  if (!rel || rel === ".") throw new Error("Patch must target a file below the workspace root.");
  if (isAbsolute(rel) || rel === ".." || rel.startsWith(`..${sep}`)) throw new Error("Patch target escapes the workspace.");
}

function applyUnifiedDiff(diff: string): { path: string; hunks: string[] } {
  const lines = diff.replaceAll("\r\n", "\n").split("\n");
  if (lines.length < 4 || !lines[0].startsWith("--- a/") || !lines[1].startsWith("+++ b/"))
    throw new Error("Expected a single-file unified diff with --- a/path and +++ b/path headers.");
  const oldPath = lines[0].slice(6);
  const newPath = lines[1].slice(6);
  if (!oldPath || oldPath !== newPath || oldPath.startsWith("/") || oldPath.includes("\\") || oldPath.includes("\0"))
    throw new Error("Added, deleted, renamed, absolute, and non-portable paths are not supported.");
  const normalized = resolve("/workspace", oldPath);
  const path = relative("/workspace", normalized);
  if (!path || path === "." || path === ".." || path.startsWith(`..${sep}`) || isAbsolute(path))
    throw new Error("Patch path escapes the workspace.");
  const hunks = lines.slice(2);
  if (!hunks.some((line) => line.startsWith("@@ "))) throw new Error("Unified diff contains no hunks.");
  if (hunks.some((line) => line.startsWith("\\ No newline"))) throw new Error("No-newline patch markers are not supported.");
  return { path, hunks };
}

function applyHunks(original: string, patchLines: string[]) {
  const finalNewline = original.endsWith("\n");
  const source = original.split("\n");
  if (finalNewline) source.pop();
  const output: string[] = [];
  let cursor = 0;
  let changed = false;
  let index = 0;
  while (index < patchLines.length) {
    const header = patchLines[index];
    if (!header.startsWith("@@ ")) {
      if (header !== "" && !header.startsWith("diff ") && !header.startsWith("index "))
        throw new Error("Unexpected content outside unified diff hunks.");
      index++;
      continue;
    }
    const match = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(header);
    if (!match) throw new Error("Invalid unified diff hunk header.");
    const oldStart = Number(match[1]);
    const expectedOld = Number(match[2] ?? 1);
    const newStart = Number(match[3]);
    const expectedNew = Number(match[4] ?? 1);
    const start = oldStart === 0 ? 0 : oldStart - 1;
    if (start < cursor || start > source.length) throw new Error("Patch hunks overlap or exceed the target file.");
    output.push(...source.slice(cursor, start));
    const expectedOutputStart = newStart === 0 ? 0 : newStart - 1;
    if (output.length !== expectedOutputStart) throw new Error("Patch hunk new-line coordinates do not match its position.");
    cursor = start;
    let consumedOld = 0;
    let producedNew = 0;
    index++;
    while (index < patchLines.length && !patchLines[index].startsWith("@@ ")) {
      const line = patchLines[index++];
      if (!line) break;
      const marker = line[0];
      const text = line.slice(1);
      if (marker === " ") {
        if (source[cursor] !== text) throw new Error("Patch context does not match the current file.");
        output.push(text);
        cursor++;
        consumedOld++;
        producedNew++;
      } else if (marker === "-") {
        if (source[cursor] !== text) throw new Error("Patch removal does not match the current file.");
        cursor++;
        consumedOld++;
        changed = true;
      } else if (marker === "+") {
        output.push(text);
        producedNew++;
        changed = true;
      } else {
        throw new Error("Invalid unified diff line.");
      }
    }
    if (consumedOld !== expectedOld || producedNew !== expectedNew) throw new Error("Unified diff hunk counts do not match its body.");
  }
  output.push(...source.slice(cursor));
  if (!changed) throw new Error("Patch contains no additions or removals.");
  return output.join("\n") + (finalNewline ? "\n" : "");
}
