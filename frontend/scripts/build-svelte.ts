import { compile } from 'svelte/compiler';
import { readFileSync } from 'fs';

const processed = new Map<string, string>();

function compileFile(filepath: string): string {
  if (processed.has(filepath)) return processed.get(filepath)!;
  const source = readFileSync(filepath, 'utf-8');
  const result = compile(source, {
    generate: 'client',
    filename: filepath,
    runes: true,
  });
  let code = result.js.code;
  // Keep svelte/internal/* imports as-is — Bun resolves via package.json exports
  processed.set(filepath, code);
  return code;
}

const result = await Bun.build({
  entrypoints: ['svelte-entry.ts'],
  outdir: 'dist',
  format: 'esm',
  target: 'browser',
  plugins: [{
    name: 'svelte',
    setup(build: any) {
      build.onLoad({ filter: /\.svelte$/ }, (args: any) => {
        const code = compileFile(args.path);
        return { contents: code, loader: 'js' };
      });
    },
  }],
});

if (!result.success) {
  console.error('Build failed:');
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

console.log(`Build succeeded: ${result.outputs.length} output(s)`);
for (const output of result.outputs) {
  console.log(`  ${output.path} (${(output.size / 1024).toFixed(1)} KB)`);
}
