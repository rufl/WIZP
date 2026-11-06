import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import path from 'path';
import fs from 'fs';

const sourcemaps = process.env.WIZP_FRONTEND_SOURCEMAPS === '1';

function copyMonacoPlugin() {
  return {
    name: 'copy-monaco',
    closeBundle() {
      const src = path.resolve(__dirname, '..', 'monaco-vs');
      const dest = path.resolve(__dirname, 'dist', 'monaco');
      if (!fs.existsSync(src)) { console.warn('[wizp] monaco-vs/ not found, skipping copy'); return; }
      fs.cpSync(src, dest, { recursive: true });
      console.log('[wizp] Copied monaco-vs/ → dist/monaco/'); // craft-ignore: intentional build status output.
    },
  };
}

export default defineConfig({
  plugins: [
    svelte({
      compilerOptions: { runes: true },
    }),
    copyMonacoPlugin(),
  ],
  resolve: {
    alias: {
      $lib: path.resolve(__dirname, './src/lib'),
    },
  },
  build: {
    target: 'esnext',
    minify: 'esbuild',
    sourcemap: sourcemaps,
    rollupOptions: {
      output: {
        manualChunks(id) {
          const normalized = id.replace(/\\/g, '/');
          if (id.includes('monaco-editor')) {
            return 'monaco';
          }
          if (normalized.includes('/node_modules/') && normalized.includes('bits-ui')) {
            return 'bits-ui';
          }
          if (normalized.includes('/node_modules/svelte/')) {
            return 'svelte';
          }
          if (normalized.includes('/node_modules/@xterm/')) {
            return 'terminal';
          }
        },
      },
    },
  },
  server: {
    port: 5173,
    strictPort: false,
  },
  // Future: add resolve.alias for monaco-api tree-shaking when we reach PHASE 5
});
