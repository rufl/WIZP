import { compile } from 'svelte/compiler';
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, relative } from 'path';

const SRC_DIR = './src';
const OUT_DIR = './src/sveltecomp';

function ensureDir(dir: string) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

function walkDir(dir: string, callback: (path: string) => void) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
      walkDir(full, callback);
    } else {
      callback(full);
    }
  }
}

ensureDir(OUT_DIR);

let compiled = 0;
walkDir(SRC_DIR, (filepath) => {
  if (!filepath.endsWith('.svelte')) return;
  const source = readFileSync(filepath, 'utf-8');
  const result = compile(source, {
    generate: 'client',
    filename: filepath,
    runes: true,
  });
  const outPath = join(OUT_DIR, relative(SRC_DIR, filepath).replace(/\.svelte$/, '.js'));
  ensureDir(join(outPath, '..'));
  let code = result.js.code;
  code = code.replace(/from ['"]([^'"]+)\.svelte['"]/g, 'from "$1.js"');
  code = code.replace(/from ['"]svelte\/internal\/disclose-version['"]/g, 'from "svelte/src/internal/disclose-version.js"');
  code = code.replace(/from ['"]svelte\/internal\/client['"]/g, 'from "svelte/src/internal/client/index.js"');
  // svelte/internal/* -> svelte/internal/* (Bun resolves node_modules)
  writeFileSync(outPath, code);
  compiled++;
});

console.log(`Svelte: compiled ${compiled} component(s) to ${OUT_DIR}/`);
