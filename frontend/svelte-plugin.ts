import { compile } from 'svelte/compiler';
import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';

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
  // Rewrite svelte/internal paths for Svelte 5
  code = code.replace(/from ['"]svelte\/internal\/disclose-version['"]/g, 'from "svelte/src/internal/disclose-version.js"');
  code = code.replace(/from ['"]svelte\/internal\/client['"]/g, 'from "svelte/src/internal/client/index.js"');
  processed.set(filepath, code);
  return code;
}

const sveltePlugin = {
  name: 'svelte',
  setup(build: any) {
    build.onLoad({ filter: /\.svelte$/ }, (args: any) => {
      const code = compileFile(args.path);
      return {
        contents: code,
        loader: 'js',
      };
    });
  },
};

export default sveltePlugin;
