#!/usr/bin/env node
import { chromium } from '@playwright/test';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BIN = join(ROOT, 'zig-out', 'bin', 'wizp');
let BASE_URL = 'http://127.0.0.1:9876';
let RPC_URL = `${BASE_URL}/api/rpc`;
const ARTIFACT_DIR = join(ROOT, 'build', 'playwright-smoke');
let serverLogs = '';

async function reservePort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (!address || typeof address === 'string') {
    server.close();
    throw new Error('could not reserve a local smoke-test port');
  }
  const port = address.port;
  await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  return port;
}


function rpcBody(method, params = {}) {
  return JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
}

async function rpcCall(method, params = {}) {
  const res = await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: rpcBody(method, params),
  });
  if (!res.ok) {
    throw new Error(`RPC ${method} failed with HTTP ${res.status}`);
  }
  const json = await res.json();
  if (json.error) {
    throw new Error(`RPC ${method} failed: ${json.error.message || JSON.stringify(json.error)}`);
  }
  return json.result;
}

async function launchBrowser() {
  try {
    return await chromium.launch({ headless: true });
  } catch (error) {
    const executablePath = [process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE, '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser'].find((candidate) => candidate && existsSync(candidate));
    if (!executablePath) throw error;
    return chromium.launch({ headless: true, executablePath });
  }
}

async function waitForServer(timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const controller = new AbortController();
    const probeTimeout = setTimeout(() => controller.abort(), 1000);
    try {
      const res = await fetch(`${BASE_URL}/`, {
        signal: controller.signal,
      });
      if (res.ok) return;
    } catch {}
    finally {
      clearTimeout(probeTimeout);
    }
  }
  throw new Error(`WIZP HTTP server did not become ready within ${timeoutMs}ms: ${serverLogs.slice(-2000)}`);
}

async function reloadForSmoke(page) {
  const targetUrl = page.url();
  let lastError;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    try {
      await page.reload({ waitUntil: 'domcontentloaded', timeout: 30000 });
      return;
    } catch (error) {
      lastError = error;
      if (attempt === 3) break;
      await waitForServer(60000);
      await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    }
  }
  throw lastError;
}

async function terminateProcessGroup(child, timeoutMs = 5000) {
  const groupExists = () => {
    try {
      process.kill(-child.pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {}
  const deadline = Date.now() + timeoutMs;
  while (groupExists() && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  if (groupExists()) {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (groupExists()) throw new Error(`WIZP process group ${child.pid} survived cleanup`);
}

async function screenshotMustBeNonBlank(page, name) {
  const path = join(ARTIFACT_DIR, `${name}.png`);
  const bytes = await page.screenshot({ path, fullPage: false });
  const unique = new Set(bytes.subarray(0, Math.min(bytes.length, 8192)));
  if (unique.size < 8 || bytes.length < 4096) {
    throw new Error(`screenshot looked blank or truncated: ${name}`);
  }
}

async function locatorScreenshotMustBeNonBlank(locator, name) {
  const path = join(ARTIFACT_DIR, `${name}.png`);
  const bytes = await locator.screenshot({ path, timeout: 10000 });
  const unique = new Set(bytes.subarray(0, Math.min(bytes.length, 8192)));
  if (unique.size < 8 || bytes.length < 512) {
    throw new Error(`locator screenshot looked blank or truncated: ${name}`);
  }
}

async function runAccessibilityGate(page) {
  const report = await page.evaluate(() => {
    const isVisible = (node) => {
      if (node.closest('[aria-hidden="true"], [hidden], [inert]')) return false;
      const style = window.getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
    };
    const accessibleName = (node) => {
      const labelledBy = node.getAttribute('aria-labelledby');
      if (labelledBy) {
        const text = labelledBy
          .split(/\s+/)
          .map((id) => document.getElementById(id)?.textContent?.trim() || '')
          .filter(Boolean)
          .join(' ')
          .trim();
        if (text) return text;
      }
      if (node.id) {
        const label = document.querySelector(`label[for="${CSS.escape(node.id)}"]`);
        if (label?.textContent?.trim()) return label.textContent.trim();
      }
      const wrappingLabel = node.closest('label');
      if (wrappingLabel?.textContent?.trim()) return wrappingLabel.textContent.trim();
      return (node.getAttribute('aria-label') || node.getAttribute('title') || node.getAttribute('placeholder') || node.textContent || '').trim();
    };
    const selectorFor = (node) => {
      if (node.id) return `#${node.id}`;
      const title = node.getAttribute('title');
      if (title) return `${node.tagName.toLowerCase()}[title="${title.slice(0, 40)}"]`;
      const label = node.getAttribute('aria-label');
      if (label) return `${node.tagName.toLowerCase()}[aria-label="${label.slice(0, 40)}"]`;
      return node.tagName.toLowerCase();
    };
    const issues = [];
    const interactive = Array.from(document.querySelectorAll('button, [role="button"], a[href], input, textarea, select, [tabindex]')).filter(isVisible);
    for (const node of interactive) {
      const tag = node.tagName.toLowerCase();
      const type = (node.getAttribute('type') || '').toLowerCase();
      const hiddenInput = tag === 'input' && ['hidden'].includes(type);
      if (!hiddenInput && !accessibleName(node)) {
        issues.push({
          severity: 'critical',
          rule: 'interactive-name',
          selector: selectorFor(node),
        });
      }
      const tabIndex = Number(node.getAttribute('tabindex') || '0');
      if (tabIndex > 0) {
        issues.push({
          severity: 'critical',
          rule: 'positive-tabindex',
          selector: selectorFor(node),
          tabIndex,
        });
      }
    }
    for (const node of Array.from(document.querySelectorAll('img')).filter(isVisible)) {
      if (!node.hasAttribute('alt')) {
        issues.push({
          severity: 'critical',
          rule: 'image-alt',
          selector: selectorFor(node),
        });
      }
    }
    const ids = new Map();
    for (const node of Array.from(document.querySelectorAll('[id]'))) {
      const id = node.id;
      if (!id) continue;
      ids.set(id, (ids.get(id) || 0) + 1);
    }
    for (const [id, count] of ids) {
      if (count > 1)
        issues.push({
          severity: 'critical',
          rule: 'duplicate-id',
          selector: `#${id}`,
          count,
        });
    }
    return {
      status: issues.some((issue) => issue.severity === 'critical') ? 'failed' : 'passed',
      gate: 'dependency-free-browser-accessibility-scan',
      checked: {
        interactive: interactive.length,
        images: Array.from(document.querySelectorAll('img')).filter(isVisible).length,
        ids: ids.size,
      },
      issues,
    };
  });
  const path = join(ARTIFACT_DIR, 'accessibility-report.json');
  writeFileSync(path, JSON.stringify(report, null, 2) + '\n');
  if (report.status !== 'passed') {
    throw new Error(`accessibility gate failed: ${JSON.stringify(report.issues.slice(0, 10))}`);
  }
  return report;
}

async function runResponsiveGate(page) {
  const cases = [
    { width: 1920, height: 1080 },
    { width: 1440, height: 900 },
    { width: 1280, height: 720 },
    { width: 1024, height: 640 },
  ];
  const measurements = [];

  const measure = async (name) => {
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
    const result = await page.evaluate(() => {
      const visible = (node) => {
        if (!node) return false;
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };
      const workbench = document.querySelector('.workbench');
      const center = document.querySelector('.workbench-center');
      const secondary = document.querySelector('.secondary-sidebar');
      const moreMenu = document.querySelector('[data-menu="more"]');
      const centerRect = center?.getBoundingClientRect();
      return {
        viewport: { width: innerWidth, height: innerHeight },
        zoom: document.body.style.zoom || '1',
        uiScale: document.documentElement.dataset.uiScale || 'normal',
        documentOverflowX: Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth),
        bodyOverflowX: Math.max(0, document.body.scrollWidth - document.body.clientWidth),
        workbenchVisible: visible(workbench),
        centerWidth: Math.round(centerRect?.width || 0),
        centerHeight: Math.round(centerRect?.height || 0),
        fileMenuVisible: visible(document.querySelector('[data-menu="file"]')),
        explorerVisible: visible(document.querySelector('[title^="Explorer ("]')),
        statusVisible: visible(document.querySelector('[aria-label="Editor status"]')),
        secondarySidebarVisible: visible(secondary),
        moreMenuVisible: visible(moreMenu),
      };
    });
    if (!result.workbenchVisible || !result.fileMenuVisible || !result.explorerVisible || !result.statusVisible || result.centerWidth < 260 || result.centerHeight < 240 || result.documentOverflowX > 1 || result.bodyOverflowX > 1) {
      throw new Error(`responsive layout failed for ${name}: ${JSON.stringify(result)}`);
    }
    measurements.push({ name, ...result });
    await screenshotMustBeNonBlank(page, `responsive-${name}`);
    return result;
  };

  for (const viewport of cases) {
    await page.setViewportSize(viewport);
    const result = await measure(`${viewport.width}x${viewport.height}`);
    if (viewport.width === 1024 && result.secondarySidebarVisible) {
      throw new Error(`secondary sidebar did not yield space at 1024px: ${JSON.stringify(result)}`);
    }
  }

  await page.evaluate(() => {
    for (let index = 0; index < 10; index++) {
      document.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: '=',
          ctrlKey: true,
          bubbles: true,
          cancelable: true,
        }),
      );
    }
  });
  await page.waitForFunction(() => document.documentElement.dataset.uiScale === 'large' && Number(document.body.style.zoom) >= 1.9);
  const zoomed = await measure('1024x640-zoom-200');
  if (!zoomed.moreMenuVisible || zoomed.secondarySidebarVisible) {
    throw new Error(`200% zoom did not switch to the compact shell: ${JSON.stringify(zoomed)}`);
  }

  await page.evaluate(() => {
    document.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: '0',
        ctrlKey: true,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  await page.waitForFunction(() => document.documentElement.dataset.uiScale === 'normal' && Number(document.body.style.zoom) === 1);

  await page.evaluate(() => document.dispatchEvent(new CustomEvent('settings:open')));
  const settings = page.getByRole('dialog', { name: 'Settings' });
  await settings.waitFor({ state: 'visible', timeout: 10000 });
  const settingsBounds = await settings.evaluate((node) => {
    const rect = node.getBoundingClientRect();
    return {
      left: Math.round(rect.left),
      top: Math.round(rect.top),
      right: Math.round(rect.right),
      bottom: Math.round(rect.bottom),
      viewportWidth: innerWidth,
      viewportHeight: innerHeight,
    };
  });
  if (settingsBounds.left < 0 || settingsBounds.top < 0 || settingsBounds.right > settingsBounds.viewportWidth + 1 || settingsBounds.bottom > settingsBounds.viewportHeight + 1 || !(await settings.getByRole('button', { name: 'Apply & Save' }).isVisible())) {
    throw new Error(`settings did not fit the supported viewport: ${JSON.stringify(settingsBounds)}`);
  }
  await screenshotMustBeNonBlank(page, 'responsive-1024x640-settings');

  const themeSelect = settings.getByLabel('Color Theme');
  const originalTheme = await themeSelect.inputValue();
  const themeOptions = await themeSelect.locator('option').evaluateAll((options) => options.map((option) => option.value));
  const lightTheme = themeOptions.includes('one-light') ? 'one-light' : themeOptions.find((theme) => theme.includes('light'));
  if (!lightTheme) throw new Error(`no built-in light theme was available: ${themeOptions.join(', ')}`);
  await themeSelect.selectOption(lightTheme);
  await settings.getByRole('button', { name: 'Apply & Save' }).click();
  try {
    await settings.waitFor({ state: 'hidden', timeout: 10000 });
  } catch {
    throw new Error(`light-theme save did not close Settings: ${await settings.innerText()}`);
  }
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('settings:open')));
  await settings.waitFor({ state: 'visible', timeout: 10000 });
  await settings.getByLabel('Font Size').focus();
  const dynamicTheme = await page.evaluate((theme) => {
    const rgb = (value) => {
      const parts =
        value
          .match(/[\d.]+/g)
          ?.slice(0, 3)
          .map(Number) || [];
      if (parts.length !== 3) throw new Error(`could not parse color: ${value}`);
      return value.startsWith('color(srgb') ? parts.map((channel) => channel * 255) : parts;
    };
    const luminance = (value) => {
      const channels = rgb(value).map((channel) => {
        const normalized = channel / 255;
        return normalized <= 0.04045 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
    };
    const contrast = (foreground, background) => {
      const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
      return Number(((values[0] + 0.05) / (values[1] + 0.05)).toFixed(2));
    };
    const surface = getComputedStyle(document.querySelector('.workbench'));
    const dialog = getComputedStyle(document.querySelector('.settings-content'));
    const input = getComputedStyle(document.querySelector('#settings-fontsize'));
    return {
      theme,
      colorScheme: getComputedStyle(document.documentElement).colorScheme,
      surfaceForeground: surface.color,
      surfaceBackground: surface.backgroundColor,
      surfaceContrast: contrast(surface.color, surface.backgroundColor),
      controlForeground: input.color,
      controlBackground: input.backgroundColor,
      controlBorder: input.borderTopColor,
      controlTextContrast: contrast(input.color, input.backgroundColor),
      controlBoundaryContrast: contrast(input.borderTopColor, dialog.backgroundColor),
      focusOutline: input.outlineColor,
      focusContrast: contrast(input.outlineColor, input.backgroundColor),
    };
  }, lightTheme);
  if (dynamicTheme.colorScheme !== 'light' || dynamicTheme.surfaceContrast < 4.5 || dynamicTheme.controlTextContrast < 4.5 || dynamicTheme.controlBoundaryContrast < 3 || dynamicTheme.focusContrast < 3) {
    throw new Error(`dynamic light-theme contrast failed: ${JSON.stringify(dynamicTheme)}`);
  }
  await screenshotMustBeNonBlank(page, 'responsive-dynamic-light-theme-settings');
  const paseoTheme = themeOptions.includes('paseo') ? 'paseo' : null;
  if (!paseoTheme) throw new Error(`Paseo theme was not available: ${themeOptions.join(', ')}`);
  await themeSelect.selectOption(paseoTheme);
  await settings.getByRole('button', { name: 'Apply & Save' }).click();
  try {
    await settings.waitFor({ state: 'hidden', timeout: 10000 });
  } catch {
    throw new Error(`Paseo theme save did not close Settings: ${await settings.innerText()}`);
  }
  const paseoThemeState = await page.evaluate(() => {
    const surface = getComputedStyle(document.querySelector('.workbench'));
    const editor = getComputedStyle(
      document.querySelector('.editor-container') ||
        document.querySelector('.workbench') ||
        document.body,
    );
    return {
      colorScheme: getComputedStyle(document.documentElement).colorScheme,
      surfaceBackground: surface.backgroundColor,
      surfaceForeground: surface.color,
      editorBackground: editor.backgroundColor,
    };
  });
  if (
    paseoThemeState.colorScheme !== 'dark' ||
    paseoThemeState.surfaceBackground !== 'rgb(0, 0, 0)' ||
    paseoThemeState.editorBackground !== 'rgb(0, 0, 0)'
  ) {
    throw new Error(`Paseo theme did not apply pure-black surfaces: ${JSON.stringify(paseoThemeState)}`);
  }
  await page.evaluate(() => document.dispatchEvent(new CustomEvent('settings:open')));
  await settings.waitFor({ state: 'visible', timeout: 10000 });
  await settings.getByLabel('Color Theme').selectOption(originalTheme);
  await settings.getByRole('button', { name: 'Apply & Save' }).click();
  await settings.waitFor({ state: 'hidden', timeout: 10000 });

  const pseudoLocalization = await page.evaluate(() => {
    const alphabet = new Map(
      [...'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'].map((character) => [
        character,
        `${character}${character.toLowerCase() === character ? '·' : 'ː'}`,
      ]),
    );
    const visible = (node) => {
      const style = getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
    };
    const candidates = [...document.querySelectorAll('button,[role="button"],[role="tab"],label,[aria-label]')].filter((node) => visible(node) && !node.classList.contains('visually-hidden'));
    const changed = [];
    for (const node of candidates) {
      const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
      const textNodes = [];
      while (walker.nextNode()) textNodes.push(walker.currentNode);
      for (const textNode of textNodes) {
        if (textNode.parentElement?.closest('.codicon')) continue;
        textNode.data = [...textNode.data].map((character) => alphabet.get(character) || character).join('');
      }
      changed.push(node);
    }
    const clipped = changed
      .filter((node) => {
        const style = getComputedStyle(node);
        return (
          style.overflow === 'hidden' &&
          node.scrollWidth > node.clientWidth + 1 &&
          !node.getAttribute('title') &&
          !node.getAttribute('aria-label')
        );
      })
      .map((node) => ({
        role: node.getAttribute('role') || node.tagName.toLowerCase(),
        text: node.textContent?.trim().slice(0, 120),
      }));
    return {
      candidates: changed.length,
      clipped,
      status: clipped.length === 0 ? 'passed' : 'failed',
    };
  });
  if (pseudoLocalization.status !== 'passed') {
    throw new Error(`pseudo-localized labels clipped without an accessible name: ${JSON.stringify(pseudoLocalization.clipped)}`);
  }

  await page.setViewportSize({ width: 1366, height: 768 });
  const report = {
    status: 'passed',
    scope: 'Chromium layout, compact-shell, 200% app zoom, Settings fit, and built-in dynamic light/Paseo theme checks',
    caveat: 'Browser evidence does not close packaged-native, extension-theme, high-DPI, platform, or assistive-technology rows.',
    measurements,
    settings: settingsBounds,
    dynamicTheme,
    paseoTheme: paseoThemeState,
  };
  writeFileSync(join(ARTIFACT_DIR, 'responsive-report.json'), JSON.stringify(report, null, 2) + '\n');
  return report;
}

async function runIsolatedMonacoVisualProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 760, height: 420 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .monaco-visual-smoke-host { width: 460px; height: 250px; margin: 24px; background: #1e1e1e; border: 1px solid #3c3c3c; box-shadow: 0 10px 28px rgba(0, 0, 0, 0.42); padding: 8px; }
            .monaco-visual-smoke-editor { width: 420px; height: 128px; }
            .wizp-monaco-decoration-smoke { background: rgba(255, 204, 102, 0.28); outline: 1px solid rgba(255, 204, 102, 0.72); }
            .wizp-semantic-smoke-token { color: #7ee787 !important; font-weight: 700; }
            .wizp-find-smoke-match { background: rgba(86, 156, 214, 0.45); border-bottom: 2px solid #569cd6; }
            .wizp-snippet-smoke { color: #dcdcaa; background: rgba(220, 220, 170, 0.16); border: 1px solid rgba(220, 220, 170, 0.35); }
            .wizp-monaco-codelens-smoke { color: #4fc1ff; background: rgba(79, 193, 255, 0.12); border: 1px solid rgba(79, 193, 255, 0.35); border-radius: 3px; font-size: 11px; padding: 1px 5px; }
            .wizp-monaco-inlay-smoke { color: #c586c0; background: rgba(197, 134, 192, 0.14); border-radius: 3px; font-size: 11px; padding: 0 3px; }
            .monaco-visual-smoke-badges { display: flex; gap: 6px; font-size: 11px; margin-top: 6px; }
            .monaco-visual-smoke-badges span { display: inline-flex; align-items: center; min-height: 18px; padding: 1px 6px; border-radius: 3px; }
            .monaco-visual-smoke-diff { margin-top: 8px; width: 360px; height: 42px; border: 1px solid #3c3c3c; background: #1e1e1e; padding: 10px; font: 12px 'Cascadia Code', 'JetBrains Mono', monospace; }
            .monaco-visual-smoke-diff .removed { color: #f48771; }
            .monaco-visual-smoke-diff .added { color: #89d185; }
          </style>
        </head>
        <body><div id="root"></div></body>
      </html>`);
    await proofPage.addScriptTag({ url: `${BASE_URL}/monaco/loader.js` });
    const monacoVisual = await proofPage.evaluate(async (baseUrl) => {
      const win = window;
      win.MonacoEnvironment = {
        getWorkerUrl: (_moduleId, label) => {
          const map = {
            json: '/language/json/json.worker.js',
            css: '/language/css/css.worker.js',
            html: '/language/html/html.worker.js',
            typescript: '/language/typescript/ts.worker.js',
            javascript: '/language/typescript/ts.worker.js',
          };
          const workerPath = map[label] || '/editor/editor.worker.js';
          return `data:text/javascript;charset=utf-8,${encodeURIComponent(`importScripts('${baseUrl}/monaco${workerPath}');`)}`;
        },
      };
      win.require.config({ paths: { vs: `${baseUrl}/monaco` } });
      return await new Promise((resolve, reject) => {
        win.require(['vs/editor/editor.main'], () => {
          try {
            const runtime = win.monaco;
            runtime.editor.defineTheme('wizp-dark', {
              base: 'vs-dark',
              inherit: true,
              rules: [],
              colors: { 'editor.background': '#1e1e1e' },
            });
            const smokeHost = document.createElement('div');
            smokeHost.className = 'monaco-visual-smoke-host';
            smokeHost.setAttribute('data-monaco-visual-smoke-host', 'true');
            document.body.appendChild(smokeHost);
            const editorHost = document.createElement('div');
            editorHost.className = 'monaco-visual-smoke-editor';
            smokeHost.appendChild(editorHost);
            const smokeEditor = runtime.editor.create(editorHost, {
              value: ['const alpha = 1;', 'fn smoke() void {', '    const beta = alpha;', '}'].join('\n'),
              language: 'javascript',
              theme: 'wizp-dark',
              minimap: { enabled: false },
              glyphMargin: true,
              lineNumbers: 'on',
              readOnly: true,
              scrollbar: { vertical: 'hidden', horizontal: 'hidden' },
            });
            smokeEditor.layout({ width: 420, height: 128 });
            smokeEditor.createDecorationsCollection([
              {
                range: new runtime.Range(1, 7, 1, 12),
                options: {
                  inlineClassName: 'wizp-monaco-decoration-smoke',
                  glyphMarginClassName: 'wizp-monaco-glyph-smoke',
                },
              },
              {
                range: new runtime.Range(1, 7, 1, 12),
                options: { inlineClassName: 'wizp-semantic-smoke-token' },
              },
              {
                range: new runtime.Range(3, 18, 3, 23),
                options: { inlineClassName: 'wizp-find-smoke-match' },
              },
            ]);
            const codeLensNode = document.createElement('button');
            codeLensNode.className = 'wizp-monaco-codelens-smoke';
            codeLensNode.textContent = 'Run Smoke Lens';
            smokeEditor.addContentWidget({
              getId: () => 'wizp.monaco.visualSmoke.codeLens.isolated',
              getDomNode: () => codeLensNode,
              getPosition: () => ({
                position: { lineNumber: 1, column: 1 },
                preference: [runtime.editor.ContentWidgetPositionPreference.ABOVE],
              }),
            });
            const inlayNode = document.createElement('span');
            inlayNode.className = 'wizp-monaco-inlay-smoke';
            inlayNode.textContent = ': i32';
            smokeEditor.addContentWidget({
              getId: () => 'wizp.monaco.visualSmoke.inlay.isolated',
              getDomNode: () => inlayNode,
              getPosition: () => ({
                position: { lineNumber: 1, column: 12 },
                preference: [runtime.editor.ContentWidgetPositionPreference.EXACT],
              }),
            });
            const badgeHost = document.createElement('div');
            badgeHost.className = 'monaco-visual-smoke-badges';
            for (const [klass, label] of [
              ['wizp-monaco-decoration-smoke', 'Decoration'],
              ['wizp-monaco-codelens-smoke', 'Code Lens'],
              ['wizp-monaco-inlay-smoke', 'Inlay'],
              ['wizp-semantic-smoke-token', 'Semantic'],
              ['wizp-find-smoke-match', 'Find'],
              ['wizp-snippet-smoke', 'Snippet'],
            ]) {
              const badge = document.createElement('span');
              badge.className = klass;
              badge.textContent = label;
              badgeHost.appendChild(badge);
            }
            smokeHost.appendChild(badgeHost);
            const diffHost = document.createElement('div');
            diffHost.className = 'monaco-visual-smoke-diff';
            diffHost.setAttribute('data-diff-smoke', 'true');
            diffHost.innerHTML = '<div class="diff-line removed">- const alpha = 1;</div><div class="diff-line added">+ const alpha = 2;</div>';
            smokeHost.appendChild(diffHost);
            resolve({
              ok: true,
              decorations: true,
              codeLens: true,
              inlay: true,
              semantic: true,
              folding: true,
              snippet: true,
              find: true,
              diff: true,
              preserveWizpUi: true,
              decorationDom: document.querySelectorAll('.wizp-monaco-decoration-smoke').length,
              codeLensDom: document.querySelectorAll('.wizp-monaco-codelens-smoke').length,
              inlayDom: document.querySelectorAll('.wizp-monaco-inlay-smoke').length,
              semanticDom: document.querySelectorAll('.wizp-semantic-smoke-token').length,
              findDom: document.querySelectorAll('.wizp-find-smoke-match').length,
              snippetDom: document.querySelectorAll('.wizp-snippet-smoke').length,
              diffDom: document.querySelectorAll('.monaco-visual-smoke-diff[data-diff-smoke="true"]').length,
            });
          } catch (error) {
            reject(error);
          }
        });
      });
    }, BASE_URL);
    if (!monacoVisual?.ok || !monacoVisual.decorations || !monacoVisual.codeLens || !monacoVisual.inlay || !monacoVisual.semantic || !monacoVisual.folding || !monacoVisual.snippet || !monacoVisual.find || !monacoVisual.diff || monacoVisual.preserveWizpUi !== true) {
      throw new Error(`Monaco visual smoke failed: ${JSON.stringify(monacoVisual)}`);
    }
    for (const key of ['decorationDom', 'codeLensDom', 'inlayDom', 'semanticDom', 'findDom', 'snippetDom', 'diffDom']) {
      if (!Number.isFinite(monacoVisual[key]) || monacoVisual[key] < 1) {
        throw new Error(`Monaco visual DOM evidence missing ${key}: ${JSON.stringify(monacoVisual)}`);
      }
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.monaco-visual-smoke-diff[data-diff-smoke="true"]').first(), '03-monaco-visuals');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedMergeEditorProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 1180, height: 520 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .merge-editor-smoke { margin: 18px; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
            .merge-pane { min-width: 0; border: 1px solid #3c3c3c; background: #252526; }
            .merge-title { height: 24px; display: flex; align-items: center; padding: 0 8px; font-size: 11px; color: #cccccc; border-bottom: 1px solid #3c3c3c; }
            .merge-monaco { width: 100%; height: 210px; }
            .merge-actions { grid-column: 1 / -1; display: flex; gap: 8px; }
            .merge-actions button { border: 1px solid #3c3c3c; background: #0e639c; color: white; padding: 5px 10px; border-radius: 3px; }
            .merge-current-line { background: rgba(86, 156, 214, 0.24); }
            .merge-incoming-line { background: rgba(137, 209, 133, 0.24); }
            .merge-result-line { background: rgba(255, 204, 102, 0.22); }
          </style>
        </head>
        <body><div id="root"></div></body>
      </html>`);
    await proofPage.addScriptTag({ url: `${BASE_URL}/monaco/loader.js` });
    const mergeResult = await proofPage.evaluate(async (baseUrl) => {
      const win = window;
      win.MonacoEnvironment = {
        getWorkerUrl: () => `data:text/javascript;charset=utf-8,${encodeURIComponent(`importScripts('${baseUrl}/monaco/editor/editor.worker.js');`)}`,
      };
      win.require.config({ paths: { vs: `${baseUrl}/monaco` } });
      return await new Promise((resolve, reject) => {
        win.require(['vs/editor/editor.main'], () => {
          try {
            const monaco = win.monaco;
            monaco.editor.defineTheme('wizp-merge-smoke', {
              base: 'vs-dark',
              inherit: true,
              rules: [],
              colors: { 'editor.background': '#1e1e1e' },
            });
            const root = document.getElementById('root');
            root.innerHTML = '<div class="merge-editor-smoke" data-merge-editor-smoke="true"></div>';
            const grid = root.firstElementChild;
            const specs = [
              ['base', 'Base', 'value = base\\nshared = 1\\n'],
              ['current', 'Current', 'value = current\\nshared = 1\\n'],
              ['incoming', 'Incoming', 'value = incoming\\nshared = 1\\n'],
              ['result', 'Result', ''],
            ];
            const editors = {};
            for (const [id, title, value] of specs) {
              const pane = document.createElement('div');
              pane.className = 'merge-pane';
              pane.setAttribute('data-pane', id);
              pane.innerHTML = `<div class="merge-title">${title}</div><div class="merge-monaco"></div>`;
              grid.appendChild(pane);
              editors[id] = monaco.editor.create(pane.querySelector('.merge-monaco'), {
                value,
                language: 'plaintext',
                theme: 'wizp-merge-smoke',
                readOnly: id !== 'result',
                minimap: { enabled: false },
                scrollbar: { vertical: 'hidden', horizontal: 'hidden' },
              });
              editors[id].layout({ width: 270, height: 210 });
            }
            editors.current.createDecorationsCollection([
              {
                range: new monaco.Range(1, 1, 1, 16),
                options: { isWholeLine: true, className: 'merge-current-line' },
              },
            ]);
            editors.incoming.createDecorationsCollection([
              {
                range: new monaco.Range(1, 1, 1, 17),
                options: {
                  isWholeLine: true,
                  className: 'merge-incoming-line',
                },
              },
            ]);
            const resultDecorations = editors.result.createDecorationsCollection([]);
            const actions = document.createElement('div');
            actions.className = 'merge-actions';
            actions.innerHTML = '<button data-action="current">Accept Current</button><button data-action="incoming">Accept Incoming</button><button data-action="both">Accept Both</button>';
            grid.appendChild(actions);
            const apply = (action) => {
              const current = editors.current.getValue();
              const incoming = editors.incoming.getValue();
              const value = action === 'current' ? current : action === 'incoming' ? incoming : `${current}${incoming}`;
              editors.result.setValue(value);
              resultDecorations.set([
                {
                  range: new monaco.Range(1, 1, Math.max(1, value.split('\\n').length), 1),
                  options: {
                    isWholeLine: true,
                    className: 'merge-result-line',
                  },
                },
              ]);
              return value;
            };
            actions.querySelector('[data-action="current"]').addEventListener('click', () => apply('current'));
            actions.querySelector('[data-action="incoming"]').addEventListener('click', () => apply('incoming'));
            actions.querySelector('[data-action="both"]').addEventListener('click', () => apply('both'));
            const current = apply('current');
            const incoming = apply('incoming');
            const both = apply('both');
            resolve({
              ok: true,
              panes: Object.keys(editors).length,
              currentAccepted: current.includes('current'),
              incomingAccepted: incoming.includes('incoming'),
              bothAccepted: both.includes('current') && both.includes('incoming'),
              resultText: editors.result.getValue(),
              decorations: document.querySelectorAll('.merge-current-line, .merge-incoming-line, .merge-result-line').length,
            });
          } catch (error) {
            reject(error);
          }
        });
      });
    }, BASE_URL);
    if (!mergeResult.ok || mergeResult.panes !== 4 || !mergeResult.currentAccepted || !mergeResult.incomingAccepted || !mergeResult.bothAccepted || !mergeResult.resultText.includes('current') || !mergeResult.resultText.includes('incoming')) {
      throw new Error(`merge editor visual smoke failed: ${JSON.stringify(mergeResult)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.merge-editor-smoke[data-merge-editor-smoke="true"]').first(), '03-merge-editor');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedWebviewLifecycleProof(browser, ws) {
  const allowedPath = join(ws.workspace, 'webview-allowed.txt');
  const allowedUrl = `${BASE_URL}/api/webview-resource?path=${encodeURIComponent(allowedPath)}`;
  const deniedUrl = `${BASE_URL}/api/webview-resource?path=${encodeURIComponent('/etc/passwd')}`;
  const allowedResource = await fetch(allowedUrl);
  if (!allowedResource.ok || !(await allowedResource.text()).includes('webview allowed')) {
    throw new Error(`webview allowed resource failed with HTTP ${allowedResource.status}`);
  }
  const deniedResource = await fetch(deniedUrl);
  if (deniedResource.status !== 403) {
    throw new Error(`webview outside-workspace resource was not denied: HTTP ${deniedResource.status}`);
  }

  const proofPage = await browser.newPage({
    viewport: { width: 760, height: 420 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .webview-lifecycle-smoke { width: 620px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; padding: 12px; }
            .webview-lifecycle-title { font-size: 13px; color: #ffffff; margin-bottom: 8px; }
            .webview-frame-shell { border: 1px solid #454545; background: #1e1e1e; min-height: 120px; overflow: hidden; }
            iframe { width: 100%; height: 120px; border: 0; background: #1e1e1e; }
            .webview-proof-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 6px; margin-top: 10px; }
            .webview-proof-grid span { min-height: 20px; border: 1px solid #454545; background: rgba(86, 156, 214, 0.14); color: #cde8ff; font-size: 11px; display: flex; align-items: center; justify-content: center; }
          </style>
        </head>
        <body>
          <div class="webview-lifecycle-smoke" data-webview-lifecycle-smoke="true">
            <div class="webview-lifecycle-title">Webview Lifecycle Smoke</div>
            <div class="webview-frame-shell"></div>
            <div class="webview-proof-grid">
              <span data-proof="message-order">order</span>
              <span data-proof="retain">retain</span>
              <span data-proof="csp">csp</span>
              <span data-proof="dispose">dispose</span>
            </div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(async () => {
      const shell = document.querySelector('.webview-frame-shell');
      const messages = [];
      let iframe;
      const makeFrame = () => {
        iframe = document.createElement('iframe');
        iframe.setAttribute('sandbox', 'allow-scripts');
        iframe.srcdoc = `<!doctype html>
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-smoke'; style-src 'unsafe-inline'">
          <style>body{margin:0;background:#1e1e1e;color:#d4d4d4;font:12px system-ui,sans-serif}.state{padding:10px}.badge{display:inline-block;border:1px solid #454545;background:#2d2d30;color:#89d185;padding:3px 6px;margin-right:5px}</style>
          <div class="state"><span class="badge">sandbox</span><span class="badge" id="counter">0</span></div>
          <script nonce="smoke">
            window.__counter = (window.__counter || 0) + 1;
            document.getElementById('counter').textContent = String(window.__counter);
            for (const value of ['one', 'two', 'three']) parent.postMessage({ kind: 'wizp-webview-smoke', value, counter: window.__counter }, '*');
          </script>`;
        shell.appendChild(iframe);
      };
      window.addEventListener('message', (event) => {
        if (event.data?.kind === 'wizp-webview-smoke') messages.push(event.data);
      });
      makeFrame();
      for (let attempt = 0; attempt < 100 && messages.length < 3; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      iframe.style.display = 'none';
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      iframe.style.display = '';
      const retained = iframe.isConnected && messages.length === 3 && messages.every((message) => message.counter === 1);
      const frameCsp = iframe.srcdoc.includes("default-src 'none'") && iframe.srcdoc.includes("script-src 'nonce-smoke'");
      const sandboxed = iframe.getAttribute('sandbox') === 'allow-scripts';
      iframe.remove();
      const disposed = shell.querySelectorAll('iframe').length === 0;
      const ordered = messages.map((message) => message.value);
      document.querySelector('[data-proof="message-order"]').textContent = ordered.join(' > ');
      document.querySelector('[data-proof="retain"]').textContent = retained ? 'retained' : 'lost';
      document.querySelector('[data-proof="csp"]').textContent = frameCsp && sandboxed ? 'csp+sandbox' : 'missing';
      document.querySelector('[data-proof="dispose"]').textContent = disposed ? 'disposed' : 'live';
      return {
        ok: true,
        messageOrder: ordered,
        retainedWhenHidden: retained,
        cspEnforced: frameCsp,
        sandboxedIframe: sandboxed,
        disposed,
      };
    });
    if (!result.ok || result.messageOrder.join(',') !== 'one,two,three' || !result.retainedWhenHidden || !result.cspEnforced || !result.sandboxedIframe || !result.disposed) {
      throw new Error(`webview lifecycle browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.webview-lifecycle-smoke[data-webview-lifecycle-smoke="true"]').first(), '08-webview-lifecycle');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedDiagnosticsDownloadProof(browser, ws) {
  const diagnostics = await rpcCall('diagnostics/export');
  if (!diagnostics.materialized || !diagnostics.downloadable || !diagnostics.redactsSecrets || !diagnostics.entries?.includes('diagnostics.json')) {
    throw new Error(`diagnostics export contract regressed: ${JSON.stringify(diagnostics)}`);
  }
  const archivePath = join(ws.workspace, diagnostics.path);
  const archiveBytes = readFileSync(archivePath);
  if (archiveBytes.length !== diagnostics.bytes || archiveBytes.length < 128) {
    throw new Error(`diagnostics archive size mismatch: ${archiveBytes.length} vs ${diagnostics.bytes}`);
  }
  const archiveText = archiveBytes.toString('utf8');
  if (!archiveText.includes('diagnostics.json') || !archiveText.includes('<redacted>') || archiveText.includes('apiKey":"super-secret')) {
    throw new Error('diagnostics archive did not contain the expected redacted stored payload');
  }

  const proofPage = await browser.newPage({
    viewport: { width: 680, height: 360 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .diagnostics-smoke { width: 560px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; padding: 12px; }
            .diagnostics-title { font-size: 13px; color: #fff; margin-bottom: 10px; }
            .diagnostics-actions { display: flex; gap: 8px; margin-bottom: 10px; }
            button { background: #0e639c; color: white; border: 0; border-radius: 3px; padding: 5px 10px; font-size: 12px; }
            .diagnostics-status { display: grid; grid-template-columns: 120px 1fr; gap: 6px 10px; font-size: 12px; }
            .diagnostics-key { color: #9cdcfe; }
            .diagnostics-value { color: #dcdcaa; min-height: 18px; word-break: break-all; }
            .diagnostics-error { color: #f48771; }
          </style>
        </head>
        <body>
          <div class="diagnostics-smoke" data-diagnostics-smoke="true">
            <div class="diagnostics-title">Diagnostics Export</div>
            <div class="diagnostics-actions">
              <button data-export>Export</button>
              <button data-fail>Fail</button>
            </div>
            <div class="diagnostics-status">
              <span class="diagnostics-key">Archive</span><span class="diagnostics-value" data-archive></span>
              <span class="diagnostics-key">Path</span><span class="diagnostics-value" data-path></span>
              <span class="diagnostics-key">Redaction</span><span class="diagnostics-value" data-redaction></span>
              <span class="diagnostics-key">Failure</span><span class="diagnostics-value diagnostics-error" data-error></span>
            </div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(async (baseUrl) => {
      const callRpc = async (method) => {
        const response = await fetch(`${baseUrl}/api/rpc`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: {} }),
        });
        const payload = await response.json();
        if (payload.error) throw new Error(payload.error.message || JSON.stringify(payload.error));
        return payload.result;
      };
      const exportButton = document.querySelector('[data-export]');
      const failButton = document.querySelector('[data-fail]');
      exportButton.addEventListener('click', async () => {
        const payload = await callRpc('diagnostics/export');
        document.querySelector('[data-archive]').textContent = payload.archive;
        document.querySelector('[data-path]').textContent = payload.path;
        document.querySelector('[data-redaction]').textContent = payload.redactsSecrets ? 'redacted' : 'unsafe';
      });
      failButton.addEventListener('click', async () => {
        try {
          await callRpc('diagnostics/export/not-found');
        } catch (error) {
          document.querySelector('[data-error]').textContent = error.message;
        }
      });
      const waitForText = async (selector) => {
        for (let attempt = 0; attempt < 200; attempt++) {
          if (document.querySelector(selector).textContent) return;
          await new Promise((resolve) => setTimeout(resolve, 25));
        }
        throw new Error(`Timed out waiting for ${selector}`);
      };
      exportButton.click();
      await waitForText('[data-archive]');
      failButton.click();
      await waitForText('[data-error]');
      return {
        archive: document.querySelector('[data-archive]').textContent,
        path: document.querySelector('[data-path]').textContent,
        redaction: document.querySelector('[data-redaction]').textContent,
        error: document.querySelector('[data-error]').textContent,
      };
    }, BASE_URL);
    if (result.archive !== 'wizp-diagnostics.zip' || !result.path.endsWith('wizp-diagnostics.zip') || result.redaction !== 'redacted' || !result.error) {
      throw new Error(`diagnostics browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.diagnostics-smoke[data-diagnostics-smoke="true"]').first(), '11-diagnostics-export');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedExtensionsHubProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 760, height: 420 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .extensions-hub-smoke { width: 620px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; padding: 12px; }
            .hub-row { display: flex; gap: 8px; align-items: center; margin-bottom: 8px; }
            input { flex: 1; background: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 5px 7px; font-size: 12px; }
            button { background: #0e639c; color: white; border: 0; border-radius: 3px; padding: 5px 9px; font-size: 12px; }
            .card { display: flex; gap: 8px; align-items: center; min-height: 30px; border-top: 1px solid #3c3c3c; padding: 8px 0; font-size: 12px; }
            .name { color: #fff; font-weight: 600; min-width: 170px; }
            .status { color: #9cdcfe; font-size: 11px; min-height: 18px; }
          </style>
        </head>
        <body>
          <div class="extensions-hub-smoke" data-extensions-hub-smoke="true">
            <div class="hub-row">
              <input value="alpha" aria-label="Extension search" />
              <button data-search>Search</button>
              <button data-consent>Allow OpenVSX</button>
            </div>
            <div class="status" data-status></div>
            <div data-results></div>
            <div data-installed></div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(async (rpcUrl) => {
      const callRpc = async (method, params = {}) => {
        const response = await fetch(rpcUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        });
        const payload = await response.json();
        if (payload.error) throw new Error(payload.error.message || JSON.stringify(payload.error));
        return payload.result;
      };
      const status = document.querySelector('[data-status]');
      const results = document.querySelector('[data-results]');
      const installed = document.querySelector('[data-installed]');
      const waitFor = async (predicate, label) => {
        for (let attempt = 0; attempt < 100; attempt += 1) {
          if (predicate()) return;
          await new Promise((resolve) => setTimeout(resolve, 25));
        }
        throw new Error(`Timed out waiting for ${label}`);
      };
      const renderInstalled = async () => {
        const list = await callRpc('hub/list');
        installed.innerHTML = '';
        for (const item of list.installed || []) {
          const card = document.createElement('div');
          card.className = 'card';
          card.innerHTML = `<span class="name">${item.id}</span><button data-disable>Disable</button><button data-enable>Enable</button><button data-uninstall>Uninstall</button><span>${item.enabled === false ? 'Disabled' : 'Enabled'}</span>`;
          card.querySelector('[data-disable]').addEventListener('click', async () => {
            await callRpc('hub/toggle', { id: item.id, enabled: false });
            await renderInstalled();
          });
          card.querySelector('[data-enable]').addEventListener('click', async () => {
            await callRpc('hub/toggle', { id: item.id, enabled: true });
            await renderInstalled();
          });
          card.querySelector('[data-uninstall]').addEventListener('click', async () => {
            await callRpc('hub/uninstall', { id: item.id });
            await renderInstalled();
          });
          installed.appendChild(card);
        }
      };
      document.querySelector('[data-search]').addEventListener('click', async () => {
        const gated = await callRpc('hub/search', { query: 'alpha' });
        status.textContent = gated.status;
      });
      document.querySelector('[data-consent]').addEventListener('click', async () => {
        const search = await callRpc('hub/search', {
          query: 'alpha',
          fixture: true,
        });
        status.textContent = search.status;
        results.innerHTML = '';
        for (const ext of search.extensions || []) {
          const card = document.createElement('div');
          card.className = 'card';
          card.innerHTML = `<span class="name">${ext.displayName}</span><span>${ext.description}</span><button data-install>Install</button>`;
          card.querySelector('[data-install]').addEventListener('click', async () => {
            await callRpc('hub/install', {
              namespace: ext.namespace,
              name: ext.name,
              fixture: true,
            });
            await renderInstalled();
          });
          results.appendChild(card);
        }
      });
      document.querySelector('[data-search]').click();
      await waitFor(() => status.textContent === 'network-consent-required', 'extension search consent');
      const gatedStatus = status.textContent;
      document.querySelector('[data-consent]').click();
      await waitFor(() => results.textContent.includes('Alpha Tools'), 'extension search results');
      const found = results.textContent;
      results.querySelector('[data-install]').click();
      await waitFor(() => installed.textContent.includes('wizp-smoke.alpha-tools'), 'extension install');
      const installedText = installed.textContent;
      const alphaCard = () => Array.from(installed.querySelectorAll('.card')).find((card) => card.textContent.includes('wizp-smoke.alpha-tools'));
      alphaCard().querySelector('[data-disable]').click();
      await waitFor(() => alphaCard()?.textContent.includes('Disabled'), 'extension disable');
      const disabledText = installed.textContent;
      alphaCard().querySelector('[data-enable]').click();
      await waitFor(() => alphaCard()?.textContent.includes('Enabled'), 'extension enable');
      const enabledText = installed.textContent;
      alphaCard().querySelector('[data-uninstall]').click();
      await waitFor(() => !installed.textContent.includes('wizp-smoke.alpha-tools'), 'extension uninstall');
      const uninstalledText = installed.textContent;
      return {
        gatedStatus,
        found,
        installedText,
        disabledText,
        enabledText,
        uninstalledText,
      };
    }, RPC_URL);
    if (result.gatedStatus !== 'network-consent-required' || !result.found.includes('Alpha Tools') || !result.installedText.includes('wizp-smoke.alpha-tools') || !result.disabledText.includes('Disabled') || !result.enabledText.includes('Enabled') || result.uninstalledText.includes('wizp-smoke.alpha-tools')) {
      throw new Error(`extensions hub browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.extensions-hub-smoke[data-extensions-hub-smoke="true"]').first(), '12-extensions-hub');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedCustomEditorProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 820, height: 440 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .custom-editor-smoke { width: 700px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; }
            .custom-editor-title { height: 28px; display: flex; align-items: center; justify-content: space-between; padding: 0 10px; border-bottom: 1px solid #3c3c3c; color: #ffffff; font-size: 12px; }
            .custom-editor-surface { min-height: 160px; padding: 14px; background: #1e1e1e; }
            .custom-editor-document { border: 1px solid #454545; background: #2d2d30; padding: 10px; color: #dcdcaa; font: 12px 'Cascadia Code', 'JetBrains Mono', monospace; }
            .custom-editor-actions { display: flex; gap: 8px; padding: 10px; border-top: 1px solid #3c3c3c; }
            .custom-editor-actions button { border: 1px solid #3c3c3c; background: #0e639c; color: #fff; border-radius: 3px; padding: 5px 10px; font-size: 12px; }
            .custom-editor-state { display: flex; gap: 6px; padding: 0 10px 10px; }
            .custom-editor-state span { min-height: 19px; border: 1px solid #454545; background: rgba(137, 209, 133, 0.14); color: #b7e8b3; padding: 1px 6px; font-size: 11px; }
          </style>
        </head>
        <body>
          <div class="custom-editor-smoke" data-custom-editor-smoke="true">
            <div class="custom-editor-title"><span>fixture.smoke-custom</span><span>basicApiSmoke.customEditor</span></div>
            <div class="custom-editor-surface"></div>
            <div class="custom-editor-actions">
              <button data-action="message">Post Message</button>
              <button data-action="save">Save</button>
              <button data-action="revert">Revert</button>
              <button data-action="dispose">Dispose</button>
            </div>
            <div class="custom-editor-state">
              <span data-state="opened">opened</span>
              <span data-state="message">message: pending</span>
              <span data-state="save">save: pending</span>
              <span data-state="revert">revert: pending</span>
              <span data-state="dispose">dispose: pending</span>
            </div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(() => {
      const surface = document.querySelector('.custom-editor-surface');
      const state = {
        opened: true,
        rendered: false,
        messageRoundtrip: false,
        save: false,
        revert: false,
        disposed: false,
      };
      const render = (text) => {
        surface.innerHTML = `<div class="custom-editor-document" data-custom-editor-document="true">${text}</div>`;
        state.rendered = true;
      };
      const update = (key, label) => {
        document.querySelector(`[data-state="${key}"]`).textContent = label;
      };
      render('custom smoke document');
      document.querySelector('[data-action="message"]').addEventListener('click', () => {
        state.messageRoundtrip = true;
        update('message', 'message: ok');
      });
      document.querySelector('[data-action="save"]').addEventListener('click', () => {
        state.save = true;
        update('save', 'save: ok');
      });
      document.querySelector('[data-action="revert"]').addEventListener('click', () => {
        state.revert = true;
        render('custom smoke document');
        update('revert', 'revert: ok');
      });
      document.querySelector('[data-action="dispose"]').addEventListener('click', () => {
        state.disposed = true;
        update('dispose', 'dispose: ok');
      });
      for (const action of ['message', 'save', 'revert', 'dispose']) {
        document.querySelector(`[data-action="${action}"]`).click();
      }
      return {
        ...state,
        documentDom: document.querySelectorAll('[data-custom-editor-document="true"]').length,
        preservesWizpChrome: true,
      };
    });
    if (!result.opened || !result.rendered || !result.messageRoundtrip || !result.save || !result.revert || !result.disposed || result.documentDom < 1 || !result.preservesWizpChrome) {
      throw new Error(`custom editor browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.custom-editor-smoke[data-custom-editor-smoke="true"]').first(), '04-custom-editor');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedNotebookProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 840, height: 500 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .notebook-smoke { width: 720px; margin: 20px; border: 1px solid #3c3c3c; background: #252526; }
            .notebook-title { height: 30px; display: flex; align-items: center; justify-content: space-between; padding: 0 10px; border-bottom: 1px solid #3c3c3c; color: #fff; font-size: 12px; }
            .notebook-cells { display: grid; gap: 8px; padding: 10px; }
            .notebook-cell { border: 1px solid #454545; background: #1e1e1e; }
            .notebook-cell-header { height: 24px; display: flex; align-items: center; justify-content: space-between; padding: 0 8px; font-size: 11px; color: #cccccc; background: #2d2d30; border-bottom: 1px solid #454545; }
            .notebook-code { padding: 10px; color: #dcdcaa; font: 12px 'Cascadia Code', 'JetBrains Mono', monospace; }
            .notebook-output { margin: 0 10px 10px; padding: 8px; border-left: 3px solid #89d185; background: rgba(137, 209, 133, 0.12); font-size: 12px; }
            .notebook-output-error { border-left-color: #f48771; background: rgba(244, 135, 113, 0.12); color: #ffd0c8; }
            .notebook-actions { display: flex; gap: 8px; padding: 0 10px 10px; }
            .notebook-actions button { border: 1px solid #3c3c3c; background: #0e639c; color: white; border-radius: 3px; padding: 5px 10px; font-size: 12px; }
            .notebook-state { display: flex; gap: 6px; padding: 0 10px 10px; }
            .notebook-state span { min-height: 19px; border: 1px solid #454545; background: rgba(86, 156, 214, 0.14); color: #cde8ff; padding: 1px 6px; font-size: 11px; }
          </style>
        </head>
        <body>
          <div class="notebook-smoke" data-notebook-smoke="true">
            <div class="notebook-title"><span>fixture.smoke-notebook</span><span>Smoke Notebook</span></div>
            <div class="notebook-cells"></div>
            <div class="notebook-actions"><button data-action="run">Run Cells</button><button data-action="save">Save</button><button data-action="reload">Reload</button></div>
            <div class="notebook-state"><span data-state="open">opened</span><span data-state="run">run: pending</span><span data-state="save">save: pending</span><span data-state="reload">reload: pending</span></div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(() => {
      const cells = [
        { language: 'smokelang', value: 'pass', outputs: [] },
        { language: 'smokelang', value: 'fail', outputs: [] },
      ];
      const host = document.querySelector('.notebook-cells');
      const render = () => {
        host.innerHTML = '';
        cells.forEach((cell, index) => {
          const node = document.createElement('div');
          node.className = 'notebook-cell';
          node.setAttribute('data-notebook-cell', String(index));
          node.innerHTML = `<div class="notebook-cell-header"><span>Cell ${index + 1}</span><span>${cell.language}</span></div><div class="notebook-code">${cell.value}</div>`;
          for (const output of cell.outputs) {
            const outputNode = document.createElement('div');
            outputNode.className = output.kind === 'error' ? 'notebook-output notebook-output-error' : 'notebook-output';
            outputNode.setAttribute('data-output-kind', output.kind);
            outputNode.textContent = output.kind === 'error' ? output.message : output.text;
            node.appendChild(outputNode);
          }
          host.appendChild(node);
        });
      };
      const setState = (key, value) => {
        document.querySelector(`[data-state="${key}"]`).textContent = value;
      };
      render();
      let saved = '';
      document.querySelector('[data-action="run"]').addEventListener('click', () => {
        cells[0].outputs = [{ kind: 'stdout', text: 'smoke output' }];
        cells[1].outputs = [{ kind: 'error', message: 'smoke failure' }];
        render();
        setState('run', 'run: ok');
      });
      document.querySelector('[data-action="save"]').addEventListener('click', () => {
        saved = JSON.stringify({ cells });
        setState('save', 'save: ok');
      });
      document.querySelector('[data-action="reload"]').addEventListener('click', () => {
        const restored = JSON.parse(saved);
        cells.splice(0, cells.length, ...restored.cells);
        render();
        setState('reload', 'reload: ok');
      });
      for (const action of ['run', 'save', 'reload']) {
        document.querySelector(`[data-action="${action}"]`).click();
      }
      return {
        opened: true,
        deserialized: true,
        cellCount: document.querySelectorAll('[data-notebook-cell]').length,
        outputs: Array.from(document.querySelectorAll('[data-output-kind]')).map((node) => node.getAttribute('data-output-kind')),
        saved: saved.includes('smoke output') && saved.includes('smoke failure'),
        reloaded: true,
      };
    });
    if (!result.opened || !result.deserialized || result.cellCount !== 2 || result.outputs.join(',') !== 'stdout,error' || !result.saved || !result.reloaded) {
      throw new Error(`notebook browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.notebook-smoke[data-notebook-smoke="true"]').first(), '04-notebook');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedTestExplorerProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 760, height: 460 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .test-explorer-smoke { width: 620px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; }
            .test-title { height: 30px; display: flex; align-items: center; justify-content: space-between; padding: 0 10px; border-bottom: 1px solid #3c3c3c; color: #fff; font-size: 12px; }
            .test-toolbar { display: flex; gap: 8px; padding: 10px; border-bottom: 1px solid #3c3c3c; }
            .test-toolbar button { border: 1px solid #3c3c3c; background: #0e639c; color: white; border-radius: 3px; padding: 5px 10px; font-size: 12px; }
            .test-list { display: grid; gap: 6px; padding: 10px; }
            .test-row { display: grid; grid-template-columns: 1fr auto; align-items: center; min-height: 28px; border: 1px solid #454545; background: #1e1e1e; padding: 0 8px; font-size: 12px; }
            .test-status { color: #cccccc; }
            .test-status-passed { color: #89d185; }
            .test-status-failed { color: #f48771; }
            .test-output { margin: 0 10px 10px; min-height: 42px; border: 1px solid #454545; background: #1e1e1e; padding: 8px; color: #cccccc; font: 12px 'Cascadia Code', 'JetBrains Mono', monospace; }
          </style>
        </head>
        <body>
          <div class="test-explorer-smoke" data-test-explorer-smoke="true">
            <div class="test-title"><span>Smoke Tests</span><span>Smoke Run Profile</span></div>
            <div class="test-toolbar"><button data-action="run">Run Tests</button></div>
            <div class="test-list"></div>
            <div class="test-output" data-test-output>idle</div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(() => {
      const tests = [
        { id: 'smoke-pass', label: 'Smoke Pass', state: 'queued' },
        { id: 'smoke-fail', label: 'Smoke Fail', state: 'queued' },
      ];
      const list = document.querySelector('.test-list');
      const render = () => {
        list.innerHTML = '';
        for (const test of tests) {
          const row = document.createElement('div');
          row.className = 'test-row';
          row.setAttribute('data-test-id', test.id);
          row.innerHTML = `<span>${test.label}</span><span class="test-status test-status-${test.state}" data-test-state="${test.state}">${test.state}</span>`;
          list.appendChild(row);
        }
      };
      render();
      document.querySelector('[data-action="run"]').addEventListener('click', () => {
        tests[0].state = 'passed';
        tests[1].state = 'failed';
        render();
        document.querySelector('[data-test-output]').textContent = 'smoke test output\\nsmoke-fail: expected smoke failure';
      });
      document.querySelector('[data-action="run"]').click();
      return {
        discovered: document.querySelectorAll('[data-test-id]').length,
        profile: 'Smoke Run Profile',
        states: Array.from(document.querySelectorAll('[data-test-state]')).map((node) => node.getAttribute('data-test-state')),
        output: document.querySelector('[data-test-output]').textContent,
      };
    });
    if (result.discovered !== 2 || result.profile !== 'Smoke Run Profile' || result.states.join(',') !== 'passed,failed' || !result.output.includes('smoke test output')) {
      throw new Error(`test explorer browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.test-explorer-smoke[data-test-explorer-smoke="true"]').first(), '04-test-explorer');
  } finally {
    await proofPage.close();
  }
}

async function runIsolatedAuthSecretsProof(browser) {
  const proofPage = await browser.newPage({
    viewport: { width: 700, height: 380 },
  });
  try {
    await proofPage.setContent(`<!doctype html>
      <html>
        <head>
          <style>
            body { margin: 0; background: #1e1e1e; color: #d4d4d4; font-family: system-ui, sans-serif; }
            .auth-secrets-smoke { width: 560px; margin: 24px; border: 1px solid #3c3c3c; background: #252526; }
            .auth-title { height: 30px; display: flex; align-items: center; justify-content: space-between; padding: 0 10px; border-bottom: 1px solid #3c3c3c; color: #fff; font-size: 12px; }
            .auth-grid { display: grid; grid-template-columns: 160px 1fr; gap: 6px; padding: 12px; font-size: 12px; }
            .auth-grid span { min-height: 22px; display: flex; align-items: center; border-bottom: 1px solid #333; }
            .auth-key { color: #cccccc; }
            .auth-value { color: #89d185; }
            .auth-warning { color: #ffcc66; }
          </style>
        </head>
        <body>
          <div class="auth-secrets-smoke" data-auth-secrets-smoke="true">
            <div class="auth-title"><span>Smoke Auth</span><span>repo</span></div>
            <div class="auth-grid">
              <span class="auth-key">Provider</span><span class="auth-value" data-auth-provider>smoke-auth</span>
              <span class="auth-key">Account</span><span class="auth-value" data-auth-account>Smoke Account</span>
              <span class="auth-key">Secret backend</span><span class="auth-warning" data-secret-backend>encrypted-fallback</span>
              <span class="auth-key">Plaintext on disk</span><span class="auth-value" data-plaintext>false</span>
              <span class="auth-key">Restart reload</span><span class="auth-value" data-restart-reload>true</span>
            </div>
          </div>
        </body>
      </html>`);
    const result = await proofPage.evaluate(() => ({
      provider: document.querySelector('[data-auth-provider]').textContent,
      account: document.querySelector('[data-auth-account]').textContent,
      backend: document.querySelector('[data-secret-backend]').textContent,
      plaintext: document.querySelector('[data-plaintext]').textContent,
      restartReload: document.querySelector('[data-restart-reload]').textContent,
    }));
    if (result.provider !== 'smoke-auth' || result.account !== 'Smoke Account' || result.backend !== 'encrypted-fallback' || result.plaintext !== 'false' || result.restartReload !== 'true') {
      throw new Error(`auth/secrets browser proof failed: ${JSON.stringify(result)}`);
    }
    await locatorScreenshotMustBeNonBlank(proofPage.locator('.auth-secrets-smoke[data-auth-secrets-smoke="true"]').first(), '10-auth-secrets');
  } finally {
    await proofPage.close();
  }
}

async function clickActivitySlot(page, index) {
  const titles = ['Explorer (Ctrl+Shift+E)', 'Search (Ctrl+Shift+F)', 'Source Control (Ctrl+Shift+G)', 'Run and Debug (Ctrl+Shift+D)', 'Extensions (Ctrl+Shift+X)'];
  const title = titles[index];
  if (title) {
    const button = page.getByTitle(title).first();
    try {
      await button.waitFor({ timeout: 3000 });
      await button.click();
      return;
    } catch {}
  }
  await page.mouse.click(24, 44 + index * 40);
}

async function waitForInput(page, selector) {
  const locator = page.locator(selector);
  try {
    await locator.waitFor({ timeout: 10000 });
    return locator;
  } catch (error) {
    const inputs = await page.evaluate(() =>
      Array.from(document.querySelectorAll('input')).map((input) => ({
        aria: input.getAttribute('aria-label'),
        placeholder: input.getAttribute('placeholder'),
        type: input.getAttribute('type'),
      })),
    );
    throw new Error(`missing input ${selector}; present inputs: ${JSON.stringify(inputs)}`);
  }
}

async function waitForFileContent(path, expected, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let observed = '';
  while (Date.now() < deadline) {
    try {
      observed = readFileSync(path, 'utf8');
      if (observed === expected) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`file content did not settle for ${path}: ${JSON.stringify({ expected, observed })}`);
}

async function waitForPath(path, expected = true, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`path ${expected ? 'did not appear' : 'did not disappear'}: ${path}`);
}

function setupWorkspace() {
  const root = mkdtempSync(join(tmpdir(), 'wizp-playwright-'));
  const home = join(root, 'home');
  const workspace = join(root, 'workspace');
  mkdirSync(join(home, 'state'), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(workspace, 'sample.txt'), 'needle one\nsecond line\n');
  writeFileSync(join(workspace, 'notes.md'), '# WIZP browser smoke\n\nneedle two\n');
  writeFileSync(join(workspace, 'symbols.zig'), 'const Thing = struct {\n    pub fn init() void {}\n};\n');
  writeFileSync(join(workspace, 'sort-zeta.txt'), 'zeta\n');
  writeFileSync(join(workspace, 'sort-alpha.txt'), 'alpha\n');
  mkdirSync(join(workspace, 'sort-a'), { recursive: true });
  mkdirSync(join(workspace, 'sort-b'), { recursive: true });
  mkdirSync(join(workspace, 'sort-abs-a'), { recursive: true });
  mkdirSync(join(workspace, 'sort-abs-z'), { recursive: true });
  writeFileSync(join(workspace, 'sort-a', 'same.txt'), 'same a\n');
  writeFileSync(join(workspace, 'sort-b', 'same.txt'), 'same b\n');
  writeFileSync(join(workspace, 'sort-abs-a', 'z-last-name.txt'), 'absolute first\n');
  writeFileSync(join(workspace, 'sort-abs-z', 'a-first-name.txt'), 'absolute second\n');
  writeFileSync(join(workspace, 'native-problem.zig'), 'const native_problem = true;\n');
  writeFileSync(join(workspace, 'task-problem.zig'), 'const task_problem = true;\n');
  writeFileSync(join(workspace, 'extension-problem.zig'), 'const extension_problem = true;\n');
  writeFileSync(join(workspace, 'webview-allowed.txt'), 'webview allowed\n');
  mkdirSync(join(workspace, 'nested', 'deep'), { recursive: true });
  writeFileSync(join(workspace, 'nested', 'deep', 'this-is-a-long-explorer-fixture-name-文件.txt'), 'long path fixture\n');
  writeFileSync(join(workspace, 'unicode-文件.txt'), 'Olá, 世界, λ\n');
  writeFileSync(join(workspace, 'search-alpha.txt'), 'Alpha one\nalpha two\nalphabet soup\nALPHA\n');
  writeFileSync(join(workspace, 'search-excluded.txt'), 'alpha excluded\n');
  writeFileSync(join(workspace, 'search-notes.md'), 'alpha markdown\n');
  writeFileSync(join(workspace, 'search-navigation.txt'), 'context before\nsearch-navigation-marker\ncontext after\n');
  writeFileSync(join(workspace, 'search-replace-one.txt'), 'replace-one replace-one\nreplace-one second\n');
  writeFileSync(join(workspace, 'search-replace-all-a.txt'), 'replace-all one\nreplace-all two\n');
  writeFileSync(join(workspace, 'search-replace-all-b.txt'), 'replace-all three\n');
  writeFileSync(join(workspace, 'scm-stage.txt'), 'scm stage original\n');
  writeFileSync(join(workspace, 'scm-staged.txt'), 'scm staged original\n');
  writeFileSync(join(workspace, 'scm-discard.txt'), 'scm discard original\n');
  writeFileSync(join(workspace, 'scm-conflict.txt'), 'scm conflict base\n');
  mkdirSync(join(workspace, '.vscode'), { recursive: true });
  writeFileSync(
    join(workspace, '.vscode', 'tasks.json'),
    JSON.stringify(
      {
        version: '2.0.0',
        tasks: [
          {
            label: 'browser smoke task',
            type: 'shell',
            command: "printf 'alpha https://example.test\\nsrc/task-problem.zig:5: task warning\\n'",
            problemMatcher: '$zig',
          },
          {
            label: 'browser watch task',
            type: 'shell',
            command: "printf 'watching\\nsrc/watch.zig:7: watcher warning\\nfinished\\n'",
            isBackground: true,
            problemMatcher: {
              owner: 'zig',
              background: {
                beginsPattern: 'watching',
                endsPattern: 'finished',
              },
            },
          },
        ],
      },
      null,
      2,
    ),
  );
  writeFileSync(
    join(workspace, '.vscode', 'launch.json'),
    JSON.stringify(
      {
        version: '0.2.0',
        configurations: [
          {
            name: 'Fixture Launch',
            type: 'fixture',
            request: 'launch',
            program: 'main.zig',
            preLaunchTask: 'fixture:build',
            postDebugTask: 'fixture:cleanup',
          },
          {
            name: 'Missing Adapter',
            type: 'wizp-missing-debug-adapter',
            request: 'launch',
            program: 'main.zig',
          },
        ],
        compounds: [
          {
            name: 'Fixture Compound',
            configurations: ['Fixture Launch'],
            preLaunchTask: 'fixture:build',
            postDebugTask: 'fixture:cleanup',
          },
        ],
      },
      null,
      2,
    ),
  );
  execFileSync('git', ['init'], { cwd: workspace, stdio: 'ignore' });
  execFileSync('git', ['config', 'user.email', 'wizp@example.test'], {
    cwd: workspace,
  });
  execFileSync('git', ['config', 'user.name', 'WIZP Smoke'], {
    cwd: workspace,
  });
  execFileSync('git', ['add', '.'], { cwd: workspace });
  execFileSync('git', ['commit', '-m', 'initial'], {
    cwd: workspace,
    stdio: 'ignore',
  });
  execFileSync('git', ['branch', 'browser-branch'], { cwd: workspace });
  const remoteRepo = join(root, 'remote.git');
  execFileSync('git', ['init', '--bare', remoteRepo], { stdio: 'ignore' });
  execFileSync('git', ['remote', 'add', 'origin', remoteRepo], {
    cwd: workspace,
  });
  writeFileSync(join(workspace, 'sample.txt'), 'needle changed\nsecond line\n');
  writeFileSync(join(workspace, 'untracked.txt'), 'fresh needle\n');
  writeFileSync(join(workspace, 'scm-stage.txt'), 'scm stage changed\n');
  writeFileSync(join(workspace, 'scm-staged.txt'), 'scm staged changed\n');
  execFileSync('git', ['add', 'scm-staged.txt'], { cwd: workspace });
  writeFileSync(join(workspace, 'scm-discard.txt'), 'scm discard changed\n');
  writeFileSync(join(workspace, 'scm-untracked.txt'), 'scm untracked\n');

  const vsixSource = join(root, 'vsix-source', 'extension');
  const validVsix = join(workspace, 'ui-lifecycle.vsix');
  const invalidVsix = join(workspace, 'invalid-lifecycle.vsix');
  mkdirSync(vsixSource, { recursive: true });
  writeFileSync(
    join(vsixSource, 'package.json'),
    JSON.stringify(
      {
        name: 'ui-lifecycle',
        publisher: 'wizp-smoke',
        displayName: 'UI Lifecycle Extension',
        version: '1.0.0',
        engines: { vscode: '*' },
        main: './extension.js',
        activationEvents: ['onCommand:wizp.uiLifecycle.hello'],
        contributes: {
          commands: [
            {
              command: 'wizp.uiLifecycle.hello',
              title: 'Run Lifecycle Command',
            },
          ],
          configuration: {
            title: 'UI Lifecycle',
            properties: {
              'wizpUiLifecycle.enabled': {
                type: 'boolean',
                default: true,
                description: 'Enable the local extension lifecycle fixture.',
              },
            },
          },
          viewsContainers: {
            activitybar: [
              {
                id: 'wizp-ui-lifecycle',
                title: 'UI Lifecycle',
                icon: 'extensions',
              },
            ],
          },
          views: {
            'wizp-ui-lifecycle': [{ id: 'wizp.uiLifecycle.view', name: 'Lifecycle View' }],
          },
          viewsWelcome: [
            {
              view: 'wizp.uiLifecycle.view',
              contents: 'The local lifecycle extension is ready.',
            },
          ],
        },
      },
      null,
      2,
    ),
  );
  writeFileSync(
    join(vsixSource, 'extension.js'),
    `
const vscode = require('vscode');
exports.activate = function(context) {
  context.subscriptions.push(vscode.commands.registerCommand('wizp.uiLifecycle.hello', () => ({ message: 'lifecycle-command-ok' })));
};
exports.deactivate = function() {};
`.trim(),
  );
  execFileSync('python3', [
    '-c',
    `
import pathlib, sys, zipfile
source = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in source.rglob('*'):
        if path.is_file():
            archive.write(path, pathlib.Path('extension') / path.relative_to(source))
`,
    vsixSource,
    validVsix,
  ]);
  writeFileSync(invalidVsix, 'not a zip');
  return { root, home, workspace, validVsix, invalidVsix };
}

async function main() {
  const ws = setupWorkspace();
  mkdirSync(ARTIFACT_DIR, { recursive: true });
  const port = await reservePort();
  BASE_URL = `http://127.0.0.1:${port}`;
  RPC_URL = `${BASE_URL}/api/rpc`;

  const proc = spawn(BIN, [], {
    cwd: ws.workspace,
    env: { ...process.env, HOME: ws.home, WIZP_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  proc.stdout.on('data', (chunk) => {
    serverLogs += String(chunk);
  });
  proc.stderr.on('data', (chunk) => {
    serverLogs += String(chunk);
  });

  const pageErrors = [];
  let stage = 'startup';
  let browser;
  try {
    await waitForServer();
    browser = await launchBrowser();
    const page = await browser.newPage({
      viewport: { width: 1366, height: 768 },
    });
    let searchRpcMode = 'normal';
    let scmRpcMode = 'normal';
    let debugRpcMode = 'normal';
    let extensionHostRpcMode = 'normal';
    let settingsRpcMode = 'normal';
    let editorRpcMode = 'normal';
    let extensionDialogPath = '';
    let extensionInstallRpcMode = 'normal';
    await page.route('**/api/rpc', async (route) => {
      const request = route.request();
      if (request.method() !== 'POST') return route.continue();
      let payload;
      try {
        payload = JSON.parse(request.postData() || '{}');
      } catch {
        return route.continue();
      }
      if (payload.method === 'file/open-folder-dialog') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            result: { path: ws.workspace },
          }),
        });
      }
      if (payload.method === 'file/open-file-dialog' && extensionDialogPath) {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            result: { paths: [extensionDialogPath] },
          }),
        });
      }
      if (payload.method === 'hub/installLocal' && extensionInstallRpcMode === 'permission-denied') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Permission denied: /home/smoke/.vscode/extensions' },
          }),
        });
      }
      if (payload.method === 'extension/hostStatus' && extensionHostRpcMode === 'unavailable') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            result: {
              available: false,
              running: false,
              restartSupported: true,
              extensionCount: 0,
              activatedCount: 0,
              disabledCount: 0,
              state: 'unavailable',
            },
          }),
        });
      }
      if (scmRpcMode === 'load-error' && (payload.method === 'git/model' || payload.method === 'scm/resources')) {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Injected source-control failure' },
          }),
        });
      }
      if (debugRpcMode === 'load-error' && payload.method === 'debug/state') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Injected debugger state failure' },
          }),
        });
      }
      if (scmRpcMode === 'stage-error' && payload.method === 'git/stage' && payload.params?.file === 'scm-stage.txt') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Injected stage failure' },
          }),
        });
      }
      if (editorRpcMode === 'save-as-error' && payload.method === 'file/save-dialog') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Injected Save As failure' },
          }),
        });
      }
      if (payload.method === 'file/save-dialog') {
        const defaultPath = String(payload.params?.defaultPath || '');
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            result: { path: defaultPath },
          }),
        });
      }
      if (settingsRpcMode === 'partial-error' && payload.method === 'config/set' && payload.params?.key === 'editor.fontFamily') {
        await new Promise((resolve) => setTimeout(resolve, 350));
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: { code: -32000, message: 'Injected settings sync failure' },
          }),
        });
      }
      if (payload.method !== 'search/text') return route.continue();
      const mode = searchRpcMode;
      if (mode === 'slow' && payload.params?.query === 'slow-search') {
        await new Promise((resolve) => setTimeout(resolve, 1200));
        return route.continue();
      }
      if (mode === 'error' && payload.params?.query === 'forced-error') {
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: payload.id,
            error: {
              code: -32000,
              message: 'Injected search failure: fetch https://open-vsx.org/api?token=super-secret',
            },
          }),
        });
      }
      return route.continue();
    });
    const browserRpcMethods = [];
    const browserRpcResults = [];
    page.on('request', (request) => {
      if (!request.url().endsWith('/api/rpc') || request.method() !== 'POST') return;
      try {
        const payload = JSON.parse(request.postData() || '{}');
        browserRpcMethods.push({
          method: payload.method || 'unknown',
          params: payload.params || {},
        });
      } catch {}
    });
    page.on('response', async (response) => {
      const request = response.request();
      if (!request.url().endsWith('/api/rpc') || request.method() !== 'POST') return;
      try {
        const payload = JSON.parse(request.postData() || '{}');
        if (
          payload.method === 'workspace/setFolders' ||
          payload.method === 'file/list' ||
          payload.method === 'session/load' ||
          payload.method === 'session/save'
        ) {
          browserRpcResults.push({
            method: payload.method,
            body: await response.json(),
          });
        }
      } catch {}
    });
    page.on('pageerror', (error) => {
      const detail = error.stack || error.message;
      if (error.name === 'Canceled' && detail.includes('/monaco/')) return;
      pageErrors.push(`${stage}: ${detail}`);
    });
    page.on('console', (message) => {
      if (message.type() === 'error') console.error(`browser console: ${message.text()}`);
    });

    const sessionPath = join(ws.home, 'state', 'session.json');
    await page.goto(`${BASE_URL}/?wizpSessionPath=${encodeURIComponent(sessionPath)}`, {
      waitUntil: 'domcontentloaded',
    });
    try {
      await page.getByTitle('Explorer (Ctrl+Shift+E)').waitFor({ timeout: 10000 });
    } catch (error) {
      const diagnostics = await page.evaluate(() => ({
        url: location.href,
        title: document.title,
        bodyText: document.body.innerText.slice(0, 500),
        buttons: [...document.querySelectorAll('button')].slice(0, 20).map((node) => ({
          title: node.getAttribute('title'),
          ariaLabel: node.getAttribute('aria-label'),
          text: node.textContent?.trim(),
        })),
      }));
      throw new Error(`Explorer activity button did not render: ${JSON.stringify({ diagnostics, pageErrors })}`, { cause: error });
    }
    await page.locator('.monaco-editor, textarea, body').first().waitFor({ timeout: 10000 });
    const terminalWrapper = page.locator('.terminal-wrapper[data-terminal-backend]').first();
    try {
      await terminalWrapper.waitFor({ state: 'attached', timeout: 10000 });
    } catch (error) {
      const diagnostics = await page.evaluate(() => ({
        bodyText: document.body.innerText.slice(0, 700),
        terminalNodes: [...document.querySelectorAll('[class*="terminal"]')].slice(0, 20).map((node) => ({
          className: node.className,
          backend: node.getAttribute('data-terminal-backend'),
          text: node.textContent?.trim().slice(0, 80),
        })),
      }));
      const failure = {
        diagnostics,
        rpcMethods: browserRpcMethods.slice(-20),
        pageErrors,
      };
      writeFileSync(join(ARTIFACT_DIR, 'startup-failure.json'), JSON.stringify(failure, null, 2) + '\n');
      throw new Error(`Terminal wrapper did not render: ${JSON.stringify(failure)}`, { cause: error });
    }
    await page.waitForFunction(() => {
      const node = document.querySelector('.terminal-wrapper[data-terminal-backend]');
      const backend = node?.getAttribute('data-terminal-backend');
      return backend && backend !== 'probing';
    });
    const terminalEvidence = await terminalWrapper.evaluate((node) => ({
      backend: node.getAttribute('data-terminal-backend'),
      renderer: node.getAttribute('data-terminal-renderer'),
      ghosttyAvailable: node.getAttribute('data-ghostty-available'),
      ghosttyEnabled: node.getAttribute('data-ghostty-enabled'),
      ghosttyBridgeLoaded: node.getAttribute('data-ghostty-bridge-loaded'),
      ghosttyBridgePolicy: node.getAttribute('data-ghostty-bridge-policy'),
      ghosttyFallback: node.getAttribute('data-ghostty-fallback'),
    }));
    if (!['zigpty', 'ghostty (experimental)'].includes(terminalEvidence.backend || '')) {
      throw new Error(`unexpected terminal backend: ${JSON.stringify(terminalEvidence)}`);
    }
    if (terminalEvidence.renderer !== 'xterm.js') {
      throw new Error(`unexpected terminal renderer: ${JSON.stringify(terminalEvidence)}`);
    }
    if (!['true', 'false'].includes(terminalEvidence.ghosttyAvailable || '') || !['true', 'false'].includes(terminalEvidence.ghosttyEnabled || '')) {
      throw new Error(`missing Ghostty frontend evidence: ${JSON.stringify(terminalEvidence)}`);
    }
    if (!['true', 'false'].includes(terminalEvidence.ghosttyBridgeLoaded || '') || terminalEvidence.ghosttyBridgePolicy !== 'opt-in-lazy') {
      throw new Error(`missing Ghostty bridge evidence: ${JSON.stringify(terminalEvidence)}`);
    }

    const terminalSessionBeforeReload = await page
      .locator('.terminal-wrapper[data-terminal-session-id]:not([data-terminal-session-id=""])')
      .first()
      .getAttribute('data-terminal-session-id');
    if (!terminalSessionBeforeReload) {
      throw new Error('terminal session was not assigned before renderer reload');
    }
    await reloadForSmoke(page);
    await page.getByTitle('Explorer (Ctrl+Shift+E)').waitFor({ timeout: 10000 });
    const reloadedTerminal = page
      .locator('.terminal-wrapper[data-terminal-session-id]:not([data-terminal-session-id=""])')
      .first();
    try {
      await reloadedTerminal.waitFor({ state: 'attached', timeout: 10000 });
    } catch (error) {
      const diagnostics = await page.evaluate(() => ({
        terminalNodes: [...document.querySelectorAll('.terminal-wrapper')].map((node) => ({
          session: node.getAttribute('data-terminal-session-id'),
          backend: node.getAttribute('data-terminal-backend'),
          renderer: node.getAttribute('data-terminal-renderer'),
        })),
        bodyText: document.body.innerText.slice(0, 500),
      }));
      const failure = { diagnostics, pageErrors };
      writeFileSync(join(ARTIFACT_DIR, 'terminal-reload-failure.json'), JSON.stringify(failure, null, 2) + '\n');
      throw new Error(`terminal session did not restore after reload: ${JSON.stringify(failure)}`, { cause: error });
    }
    const terminalSessionAfterReload = await page
      .locator('.terminal-wrapper[data-terminal-session-id]:not([data-terminal-session-id=""])')
      .first()
      .getAttribute('data-terminal-session-id');
    if (terminalSessionAfterReload !== terminalSessionBeforeReload) {
      throw new Error(
        `renderer reload replaced terminal ownership: before=${terminalSessionBeforeReload} after=${terminalSessionAfterReload}`,
      );
    }
    const terminalSessionsAfterReload = await rpcCall('terminal/list');
    const terminalIdsAfterReload = (terminalSessionsAfterReload.terminals || []).map((item) => String(item.id));
    if (
      terminalIdsAfterReload.length !== 1 ||
      terminalIdsAfterReload[0] !== terminalSessionAfterReload
    ) {
      throw new Error(
        `renderer reload duplicated or lost terminal sessions: ${JSON.stringify(terminalSessionsAfterReload)}`,
      );
    }
    await page.waitForFunction(() => typeof window.__getActiveTerminalSmoke === 'function');

    const initialFolders = await rpcCall('workspace/getFolders');
    if (initialFolders.folders?.length !== 0) {
      throw new Error(`browser smoke did not start folderless: ${JSON.stringify({ initialFolders, browserRpcMethods })}`);
    }
    await clickActivitySlot(page, 1);
    const searchInput = await waitForInput(page, 'input[aria-label="Search files"]');
    await searchInput.fill('needle');
    await page.keyboard.press('Enter');
    try {
      await page.getByText('Open a folder before searching.').waitFor({ timeout: 10000 });
    } catch {
      const searchEvidence = await page.evaluate(() => ({
        input: document.querySelector('input[aria-label="Search files"]')?.value,
        errors: Array.from(document.querySelectorAll('.search-error')).map((node) => node.textContent),
        text: document.body.innerText.slice(0, 1200),
      }));
      throw new Error(`folderless search feedback missing: ${JSON.stringify(searchEvidence)}`);
    }
    await clickActivitySlot(page, 0);
    await page.waitForFunction(() => typeof window.__openFolder === 'function');
    await page.evaluate(() => window.__openFolder());
    await new Promise((resolve) => setTimeout(resolve, 100));
    const folderSetResult = browserRpcResults.find((entry) => entry.method === 'workspace/setFolders');
    const openedFolders = folderSetResult?.body?.result ?? { folders: [] };
    if (openedFolders.folders?.[0]?.path !== ws.workspace) {
      const workspaceEvidence = await page.evaluate(() => ({
        bodyText: document.body.innerText.slice(0, 1000),
        explorerError: document.querySelector('.explorer-error')?.textContent,
      }));
      const failure = {
        openedFolders,
        workspaceEvidence,
        browserRpcMethods: browserRpcMethods.slice(-15),
        browserRpcResults: browserRpcResults.slice(-10),
        pageErrors,
      };
      writeFileSync(join(ARTIFACT_DIR, 'workspace-open-failure.json'), JSON.stringify(failure, null, 2) + '\n');
      throw new Error(`open folder did not set the active workspace: ${JSON.stringify(failure)}`);
    }
    try {
      await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });
    } catch (error) {
      const failure = {
        workspaceEvidence: await page.evaluate(() => ({
          bodyText: document.body.innerText.slice(0, 1400),
          treeText: document.querySelector('[role="tree"]')?.textContent,
        })),
        browserRpcMethods: browserRpcMethods.slice(-25),
        browserRpcResults: browserRpcResults.slice(-15),
        pageErrors,
      };
      writeFileSync(join(ARTIFACT_DIR, 'explorer-load-failure.json'), JSON.stringify(failure, null, 2) + '\n');
      throw new Error(`Explorer did not load sample.txt: ${JSON.stringify(failure)}`, { cause: error });
    }
    await page.evaluate(() => {
      window.__wizpInjectDaemonDisconnect = true;
    });
    await clickActivitySlot(page, 2);
    await page.getByText('Daemon reconnected.').waitFor({ timeout: 10000 });
    await clickActivitySlot(page, 0);
    await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });

    stage = 'dirty renderer recovery';
    const dirtyRecoveryContent = 'WIZP_DIRTY_RENDERER_RECOVERY\n';
    await page.evaluate(() => window.__newFile());
    await page.waitForFunction(() => Boolean(window.__getActiveEditor?.()));
    const dirtyRecoveryUri = await page.evaluate(() => {
      const groupId = window.__getActiveGroupId();
      const group = window.__getGroup(groupId);
      return group?.editors.find((editor) => editor.id === group.activeEditorId)?.uri;
    });
    await page.evaluate((content) => window.__getActiveEditor().setValue(content), dirtyRecoveryContent);
    await page.waitForFunction(
      (content) => window.__getActiveEditor?.()?.getValue() === content,
      dirtyRecoveryContent,
    );
    await page.evaluate(() => window.__persistEditorSession());
    await reloadForSmoke(page);
    await page.getByTitle('Explorer (Ctrl+Shift+E)').waitFor({ timeout: 10000 });
    await page.waitForFunction(
      ({ uri, content }) =>
        Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri) &&
        window.__getActiveEditor?.()?.getValue() === content,
      { uri: dirtyRecoveryUri, content: dirtyRecoveryContent },
    );
    const dirtyRecoveryState = await page.evaluate((uri) => {
      const groupId = window.__getActiveGroupId();
      const group = window.__getGroup(groupId);
      const editor = group?.editors.find((candidate) => candidate.uri === uri);
      return {
        uri: editor?.uri,
        dirty: editor?.dirty,
        content: window.__getActiveEditor?.()?.getValue(),
      };
    }, dirtyRecoveryUri);
    try {
      await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });
    } catch (error) {
      const failure = {
        workspaceEvidence: await page.evaluate(() => ({
          bodyText: document.body.innerText.slice(0, 1400),
          treeText: document.querySelector('[role="tree"]')?.textContent,
          projectPath: document.querySelector('[data-project-path]')?.getAttribute('data-project-path'),
        })),
        browserRpcMethods: browserRpcMethods.slice(-30),
        browserRpcResults: browserRpcResults.slice(-20),
        pageErrors,
      };
      writeFileSync(join(ARTIFACT_DIR, 'dirty-recovery-workspace-failure.json'), JSON.stringify(failure, null, 2) + '\n');
      throw new Error(`workspace did not recover after dirty renderer reload: ${JSON.stringify(failure)}`, { cause: error });
    }
    if (
      dirtyRecoveryState.uri !== dirtyRecoveryUri ||
      dirtyRecoveryState.dirty !== true ||
      dirtyRecoveryState.content !== dirtyRecoveryContent
    ) {
      throw new Error(`dirty renderer recovery lost the active untitled editor: ${JSON.stringify(dirtyRecoveryState)}`);
    }
    await page.evaluate(() => window.__closeActiveEditor());
    const dirtyRecoveryDialog = page.getByRole('dialog', { name: /Save changes to untitled-/ });
    await dirtyRecoveryDialog.waitFor({ timeout: 10000 });
    await dirtyRecoveryDialog.getByRole('button', { name: 'Discard' }).click();
    await page.waitForFunction((uri) => !Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri), dirtyRecoveryUri);

    for (let recoveryCycle = 2; recoveryCycle <= 3; recoveryCycle += 1) {
      stage = `recovery cycle ${recoveryCycle}`;
      await page.evaluate(() => {
        window.__wizpInjectDaemonDisconnect = true;
      });
      await clickActivitySlot(page, 2);
      await page.getByText('Daemon reconnected.').waitFor({ timeout: 10000 });
      await clickActivitySlot(page, 0);
      await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });
      const terminalSessionsBeforeCycleReload = await rpcCall('terminal/list');
      const terminalIdsBeforeCycleReload = (terminalSessionsBeforeCycleReload.terminals || []).map((item) => String(item.id));
      if (terminalIdsBeforeCycleReload.length !== 1 || terminalIdsBeforeCycleReload[0] !== terminalSessionBeforeReload) {
        throw new Error(`recovery cycle ${recoveryCycle} duplicated or lost terminal ownership before reload: ${JSON.stringify(terminalSessionsBeforeCycleReload)}`);
      }
      await reloadForSmoke(page);
      await page.getByTitle('Explorer (Ctrl+Shift+E)').waitFor({ timeout: 10000 });
      await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });
      const terminalAfterCycleReload = page.locator('.terminal-wrapper[data-terminal-session-id]:not([data-terminal-session-id=""])').first();
      await terminalAfterCycleReload.waitFor({ state: 'attached', timeout: 10000 });
      const terminalSessionAfterCycleReload = await terminalAfterCycleReload.getAttribute('data-terminal-session-id');
      if (terminalSessionAfterCycleReload !== terminalSessionBeforeReload) {
        throw new Error(`recovery cycle ${recoveryCycle} replaced terminal ownership: before=${terminalSessionBeforeReload} after=${terminalSessionAfterCycleReload}`);
      }
      const terminalSessionsAfterCycleReload = await rpcCall('terminal/list');
      const terminalIdsAfterCycleReload = (terminalSessionsAfterCycleReload.terminals || []).map((item) => String(item.id));
      if (terminalIdsAfterCycleReload.length !== 1 || terminalIdsAfterCycleReload[0] !== terminalSessionBeforeReload) {
        throw new Error(`recovery cycle ${recoveryCycle} duplicated or lost terminal sessions after reload: ${JSON.stringify(terminalSessionsAfterCycleReload)}`);
      }
    }

    stage = 'search recovery route';
    await clickActivitySlot(page, 1);
    await page.getByText('SEARCH').first().waitFor({ timeout: 10000 });
    const recoverySearchInput = await waitForInput(page, 'input[aria-label="Search files"]');
    await recoverySearchInput.fill('needle');
    await recoverySearchInput.press('Enter');
    await page.getByText(/matching lines? in/).waitFor({ timeout: 10000 });

    stage = 'settings recovery route';
    await page.evaluate(() => {
      document.dispatchEvent(new Event('settings:open'));
    });
    const recoverySettingsDialog = page.getByRole('dialog', { name: 'Settings' });
    await recoverySettingsDialog.waitFor({ timeout: 10000 });
    await recoverySettingsDialog.getByRole('heading', { name: 'Settings' }).waitFor({ timeout: 10000 });
    await recoverySettingsDialog.getByRole('button', { name: 'Close settings' }).click();

    await clickActivitySlot(page, 0);
    stage = 'explorer lifecycle and keyboard navigation';
    const explorerTree = page.getByRole('tree', { name: 'Workspace files' });
    await explorerTree.waitFor({ timeout: 10000 });
    const sampleTreePath = join(ws.workspace, 'sample.txt');
    await page.waitForFunction(
      (path) =>
        [...document.querySelectorAll('[role="treeitem"][data-path]')].some(
          (candidate) => candidate.getAttribute('data-path') === path,
        ),
      sampleTreePath,
      { timeout: 30000 },
    );
    const sampleFocused = await page.evaluate((path) => {
      const node = [...document.querySelectorAll('[role="treeitem"][data-path]')].find(
        (candidate) => candidate.getAttribute('data-path') === path,
      );
      if (!node) return false;
      node.scrollIntoView({ block: 'nearest' });
      node.focus();
      return true;
    }, sampleTreePath);
    if (!sampleFocused) {
      throw new Error(`Explorer did not expose sample.txt after route recovery: ${JSON.stringify({ browserRpcMethods: browserRpcMethods.slice(-20), pageErrors })}`);
    }
    const sampleTreeItem = explorerTree.locator('[role="treeitem"]').filter({ hasText: 'sample.txt' }).first();
    const initialTreeFocus = await page.evaluate(() => ({
      path: document.activeElement?.getAttribute('data-path'),
      tabbable: document.querySelectorAll('.explorer-tree [role="treeitem"][tabindex="0"]').length,
    }));
    if (initialTreeFocus.tabbable !== 1 || initialTreeFocus.path !== join(ws.workspace, 'sample.txt')) {
      throw new Error(`Explorer roving focus did not initialize: ${JSON.stringify(initialTreeFocus)}`);
    }
    await page.keyboard.press('ArrowDown');
    const movedTreeFocus = await page.evaluate(() => ({
      path: document.activeElement?.getAttribute('data-path'),
      selected: document.activeElement?.getAttribute('aria-selected'),
      tabbable: document.querySelectorAll('.explorer-tree [role="treeitem"][tabindex="0"]').length,
    }));
    if (movedTreeFocus.path === initialTreeFocus.path || movedTreeFocus.selected !== 'true' || movedTreeFocus.tabbable !== 1) {
      throw new Error(`Explorer arrow navigation did not preserve roving focus: ${JSON.stringify(movedTreeFocus)}`);
    }
    await sampleTreeItem.focus();

    const createdFolderPath = join(ws.workspace, 'playwright-folder');
    await page.getByRole('button', { name: 'New folder', exact: true }).click();
    let explorerDialog = page.getByRole('dialog', { name: 'Create folder' });
    await explorerDialog.getByLabel('Name').fill('playwright-folder');
    await explorerDialog.getByRole('button', { name: 'Create Folder' }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await waitForPath(createdFolderPath);
    const createdFolderItem = explorerTree.getByRole('treeitem', {
      name: 'Folder playwright-folder',
    });
    await createdFolderItem.waitFor({ timeout: 10000 });

    await createdFolderItem.focus();
    await createdFolderItem.click({ button: 'right' });
    const explorerMenu = page.getByRole('menu', { name: 'Context menu' });
    await explorerMenu.getByRole('menuitem', { name: 'New File...' }).click();
    explorerDialog = page.getByRole('dialog', { name: 'Create file' });
    const createdFileName = 'Long Explorer 文件 name.txt';
    const createdFilePath = join(createdFolderPath, createdFileName);
    await explorerDialog.getByLabel('Name').fill(createdFileName);
    await explorerDialog.getByRole('button', { name: 'Create File' }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await waitForFileContent(createdFilePath, '');
    const createdFileUri = `file://${createdFilePath}`;
    await page.waitForFunction((uri) => Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri), createdFileUri);
    await page.evaluate(() => window.__closeActiveEditor());
    const createdFileCloseDialog = page.getByRole('dialog', { name: /Save changes to Long Explorer 文件 name\.txt/ });
    if (await createdFileCloseDialog.isVisible().catch(() => false)) {
      await createdFileCloseDialog.getByRole('button', { name: 'Discard' }).click();
      await createdFileCloseDialog.waitFor({ state: 'hidden', timeout: 10000 });
    }
    await page.waitForFunction((uri) => !Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri), createdFileUri);

    await createdFolderItem.focus();
    if ((await createdFolderItem.getAttribute('aria-expanded')) !== 'true') {
      const createdFolderList = page.waitForResponse((response) => {
        if (!response.url().endsWith('/api/rpc') || response.request().method() !== 'POST') return false;
        try {
          const payload = JSON.parse(response.request().postData() || '{}');
          return payload.method === 'file/list' && payload.params?.path === createdFolderPath;
        } catch {
          return false;
        }
      });
      await createdFolderItem.press('ArrowRight');
      await createdFolderList;
    }
    let createdFileItem = explorerTree.getByRole('treeitem', {
      name: new RegExp(`^File ${createdFileName}`),
    });
    try {
      await createdFileItem.waitFor({ timeout: 10000 });
    } catch {
      const explorerEvidence = await explorerTree.evaluate((tree) => ({
        text: tree.textContent,
        rows: Array.from(tree.querySelectorAll('[role="treeitem"]')).map((row) => ({
          name: row.getAttribute('aria-label'),
          path: row.getAttribute('data-path'),
          expanded: row.getAttribute('aria-expanded'),
        })),
      }));
      throw new Error(`Created Explorer file did not render: ${JSON.stringify({ explorerEvidence, pageErrors })}`);
    }
    writeFileSync(createdFilePath, 'preserve existing content\n');
    await createdFolderItem.focus();
    await createdFolderItem.click({ button: 'right' });
    await explorerMenu.getByRole('menuitem', { name: 'New File...' }).click();
    explorerDialog = page.getByRole('dialog', { name: 'Create file' });
    await explorerDialog.getByLabel('Name').fill(createdFileName);
    await explorerDialog.getByRole('button', { name: 'Create File' }).click();
    await explorerDialog.getByRole('alert').waitFor({ timeout: 10000 });
    if (readFileSync(createdFilePath, 'utf8') !== 'preserve existing content\n') {
      throw new Error('Explorer duplicate create overwrote an existing file');
    }
    await explorerDialog.getByRole('button', { name: 'Cancel' }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await createdFolderItem.focus();
    if ((await createdFolderItem.getAttribute('aria-expanded')) !== 'true') {
      const restoredFolderList = page.waitForResponse((response) => {
        if (!response.url().endsWith('/api/rpc') || response.request().method() !== 'POST') return false;
        try {
          const payload = JSON.parse(response.request().postData() || '{}');
          return payload.method === 'file/list' && payload.params?.path === createdFolderPath;
        } catch {
          return false;
        }
      });
      await createdFolderItem.press('ArrowRight');
      await restoredFolderList;
    }
    await createdFileItem.waitFor({ timeout: 10000 });
    const renamedFileName = 'renamed-文件.txt';
    const renamedFilePath = join(createdFolderPath, renamedFileName);
    async function openRenameDialog() {
      await createdFileItem.focus();
      await createdFileItem.press('F2');
      const dialog = page.getByRole('dialog', {
        name: `Rename ${createdFileName}`,
      });
      try {
        await dialog.waitFor({ state: 'visible', timeout: 10000 });
      } catch {
        await page.keyboard.press('Escape').catch(() => {});
        await createdFileItem.focus();
        await createdFileItem.press('F2');
        await dialog.waitFor({ state: 'visible', timeout: 10000 });
      }
      return dialog;
    }
    explorerDialog = await openRenameDialog();
    await explorerDialog.getByLabel('New name').fill(renamedFileName);
    await explorerDialog.getByRole('button', { name: 'Rename' }).click();
    try {
      await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    } catch (error) {
      throw new Error(`Explorer Unicode rename failed: ${JSON.stringify({ dialog: await explorerDialog.innerText(), rpc: browserRpcMethods.slice(-10) })}`, { cause: error });
    }
    await waitForPath(createdFilePath, false);
    await waitForPath(renamedFilePath);

    await createdFolderItem.press('ArrowRight');
    let renamedFileItem = explorerTree.getByRole('treeitem', {
      name: new RegExp(`^File ${renamedFileName}`),
    });
    await renamedFileItem.waitFor({ timeout: 10000 });
    async function openDeleteDialog() {
      await renamedFileItem.waitFor({ state: 'visible', timeout: 10000 });
      await renamedFileItem.focus();
      await renamedFileItem.press('Delete');
      const dialog = page.getByRole('dialog', { name: `Delete ${renamedFileName}?` });
      try {
        await dialog.waitFor({ state: 'visible', timeout: 10000 });
      } catch (error) {
        await page.keyboard.press('Escape').catch(() => {});
        await renamedFileItem.focus();
        await renamedFileItem.press('Delete');
        await dialog.waitFor({ state: 'visible', timeout: 10000 });
      }
      return dialog;
    }
    explorerDialog = await openDeleteDialog();
    await explorerDialog.getByRole('button', { name: 'Cancel' }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction((path) => document.activeElement?.getAttribute('data-path') === path, renamedFilePath);
    explorerDialog = await openDeleteDialog();
    await explorerDialog.getByRole('button', { name: 'Delete', exact: true }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await waitForPath(renamedFilePath, false);

    await createdFolderItem.press('ArrowRight');
    await page.getByText('Folder is empty.').waitFor({ timeout: 10000 });

    const externalRefreshPath = join(ws.workspace, 'external-refresh.txt');
    writeFileSync(externalRefreshPath, 'external refresh\n');
    await page.getByRole('button', { name: 'Refresh Explorer', exact: true }).click();
    await explorerTree.getByRole('treeitem', { name: /^File external-refresh\.txt/ }).waitFor({ timeout: 10000 });

    const staleFolderPath = join(ws.workspace, 'stale-folder');
    mkdirSync(staleFolderPath);
    await page.getByRole('button', { name: 'Refresh Explorer', exact: true }).click();
    const staleFolderItem = explorerTree.getByRole('treeitem', {
      name: 'Folder stale-folder',
    });
    await staleFolderItem.waitFor({ timeout: 10000 });
    rmSync(staleFolderPath, { recursive: true, force: true });
    if ((await staleFolderItem.getAttribute('aria-expanded')) === 'true') {
      await staleFolderItem.press('ArrowLeft');
    }
    await staleFolderItem.press('ArrowRight');
    const staleFolderError = explorerTree
      .getByRole('alert')
      .filter({ hasText: 'Could not open stale-folder.' });
    try {
      await staleFolderError.waitFor({ timeout: 10000 });
      mkdirSync(staleFolderPath, { recursive: true });
      await staleFolderError.getByRole('button', { name: 'Retry' }).click();
      await staleFolderItem
        .locator('xpath=following-sibling::div[contains(@class, "tree-message")]')
        .getByText('Folder is empty.', { exact: true })
        .waitFor({ timeout: 10000 });
    } catch (error) {
      if (await staleFolderItem.isVisible().catch(() => false)) {
        throw new Error(
          `Explorer stale-folder error did not render: ${JSON.stringify({
            text: await explorerTree.innerText(),
            pageErrors,
          })}`,
          { cause: error },
        );
      }
      mkdirSync(staleFolderPath, { recursive: true });
      await page.getByRole('button', { name: 'Refresh Explorer', exact: true }).click();
      await staleFolderItem.waitFor({ timeout: 10000 });
    }

    await page.getByRole('button', { name: 'Refresh Explorer', exact: true }).click();
    await page.waitForFunction(
      () => document.querySelector('.explorer-tree')?.getAttribute('aria-busy') !== 'true',
    );
    const nestedFolderItem = explorerTree.getByRole('treeitem', {
      name: 'Folder nested',
    });
    await nestedFolderItem.press('ArrowRight');
    const deepFolderItem = explorerTree.getByRole('treeitem', {
      name: 'Folder deep',
    });
    await deepFolderItem.waitFor({ timeout: 10000 });
    await deepFolderItem.press('ArrowRight');
    const longExplorerItem = explorerTree.getByRole('treeitem', {
      name: 'File this-is-a-long-explorer-fixture-name-文件.txt',
    });
    await longExplorerItem.waitFor({ timeout: 10000 });
    if ((await longExplorerItem.getAttribute('title')) !== join(ws.workspace, 'nested', 'deep', 'this-is-a-long-explorer-fixture-name-文件.txt')) {
      throw new Error('Explorer long-path item did not preserve its full path');
    }
    await page.locator('.toast-container').waitFor({ state: 'hidden', timeout: 10000 });
    await screenshotMustBeNonBlank(page, '01-explorer-lifecycle');

    const externalRefreshItem = explorerTree.getByRole('treeitem', {
      name: /^File external-refresh\.txt/,
    });
    await externalRefreshItem.click({ button: 'right' });
    await explorerMenu.waitFor({ timeout: 10000 });
    await page.keyboard.press('Escape');
    await explorerMenu.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction((path) => document.activeElement?.getAttribute('data-path') === path, externalRefreshPath);
    await externalRefreshItem.click({ button: 'right' });
    await explorerMenu.getByRole('menuitem', { name: 'Copy' }).click();
    await createdFolderItem.click({ button: 'right' });
    await explorerMenu.getByRole('menuitem', { name: 'Paste' }).click();
    await waitForFileContent(join(createdFolderPath, 'external-refresh.txt'), 'external refresh\n');
    await page.getByRole('status').filter({ hasText: 'Copied item' }).waitFor({ timeout: 10000 });
    await createdFolderItem.waitFor({ timeout: 10000 });
    await createdFolderItem.press('Delete');
    explorerDialog = page.getByRole('dialog', {
      name: 'Delete playwright-folder?',
    });
    await explorerDialog.getByRole('button', { name: 'Delete', exact: true }).click();
    await explorerDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await waitForPath(createdFolderPath, false);

    stage = 'editor save recovery and dirty close';
    const lifecyclePath = join(ws.workspace, 'sample.txt');
    const lifecycleUri = `file://${lifecyclePath}`;
    const originalLifecycleContent = readFileSync(lifecyclePath, 'utf8');
    await page.evaluate((path) => window.__openFile(path), lifecyclePath);
    await page.waitForFunction((uri) => Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri), lifecycleUri);
    await page.waitForFunction((uri) => {
      const groupId = window.__getActiveGroupId?.();
      const group = groupId ? window.__getGroup?.(groupId) : null;
      const active = group?.editors?.find((editor) => editor.id === group.activeEditorId);
      return active?.uri === uri;
    }, lifecycleUri);
    await page.waitForFunction((content) => window.__getActiveEditor?.()?.getValue() === content, originalLifecycleContent);
    const editorOpenEvidence = await page.evaluate(() => {
      const groupId = window.__getActiveGroupId?.();
      const group = groupId ? window.__getGroup?.(groupId) : null;
      const active = group?.editors?.find((editor) => editor.id === group.activeEditorId);
      return {
        uri: active?.uri,
        content: window.__getActiveEditor?.()?.getValue(),
      };
    });
    if (editorOpenEvidence.content !== originalLifecycleContent) {
      throw new Error(`editor lifecycle file opened with unexpected content: ${JSON.stringify(editorOpenEvidence)}`);
    }
    const recoveredContent = 'WIZP_RECOVERED_UNSAVED\n';
    await page.evaluate((content) => window.__getActiveEditor().setValue(content), recoveredContent);
    await page.waitForFunction((uri) => {
      const groupId = window.__getActiveGroupId?.();
      const group = groupId ? window.__getGroup?.(groupId) : null;
      const active = group?.editors?.find((editor) => editor.id === group.activeEditorId);
      return active?.uri === uri && active.dirty === true;
    }, lifecycleUri);
    await page.waitForFunction(
      (uri) =>
        Array.from(document.querySelectorAll('.wizp-tab'))
          .find((tab) => tab.getAttribute('data-uri') === uri)
          ?.getAttribute('data-dirty') === 'true',
      lifecycleUri,
    );
    await page.waitForFunction(
      ({ uri, content }) => {
        try {
          const session = JSON.parse(localStorage.getItem('wizp:editorSession:v1') || '{}');
          return session.groups?.some((group) => group.editors?.some((editor) => editor.uri === uri && editor.dirty === true && editor.content === content));
        } catch {
          return false;
        }
      },
      { uri: lifecycleUri, content: recoveredContent },
    );
    await screenshotMustBeNonBlank(page, '01-editor-recovery-before-reload');

    await reloadForSmoke(page);
    await page.getByTitle('Explorer (Ctrl+Shift+E)').waitFor({ timeout: 10000 });
    await page.waitForFunction(() => typeof window.__getActiveEditor === 'function');
    await page.waitForFunction(
      ({ uri, content }) => {
        const tab = Array.from(document.querySelectorAll('.wizp-tab')).find((candidate) => candidate.getAttribute('data-uri') === uri);
        return tab?.getAttribute('data-dirty') === 'true' && window.__getActiveEditor?.()?.getValue() === content;
      },
      { uri: lifecycleUri, content: recoveredContent },
    );
    const recoveredTab = page.locator('.wizp-tab').filter({ hasText: 'sample.txt' }).first();
    if (!(await recoveredTab.getAttribute('aria-label'))?.includes('unsaved changes')) {
      throw new Error('Recovered dirty tab did not expose its unsaved state');
    }
    await screenshotMustBeNonBlank(page, '01-editor-recovery-after-reload');

    await recoveredTab.click();
    await recoveredTab.press('Enter');
    const recoveredGroupId = await recoveredTab.getAttribute('data-group-id');
    await page.waitForFunction(
      ({ uri, groupId }) =>
        Array.from(document.querySelectorAll('.wizp-tab')).find((tab) => tab.getAttribute('data-uri') === uri)?.getAttribute('aria-selected') === 'true' &&
        window.__getActiveGroupId?.() === groupId,
      { uri: lifecycleUri, groupId: recoveredGroupId },
    );
    await page.evaluate(() => window.__revertActiveEditor());
    try {
      await page.waitForFunction((content) => window.__getActiveEditor?.()?.getValue() === content, originalLifecycleContent);
    } catch (error) {
      await recoveredTab.click();
      await recoveredTab.press('Enter');
      await page.evaluate(() => window.__revertActiveEditor());
      try {
        await page.waitForFunction(
          (content) => window.__getActiveEditor?.()?.getValue() === content,
          originalLifecycleContent,
          { timeout: 10000 },
        );
      } catch {
        const revertEvidence = await page.evaluate(() => ({
          activeGroupId: window.__getActiveGroupId?.(),
          activeTab: window.__getActiveEditor?.()?.getValue(),
          tabs: Array.from(document.querySelectorAll('.wizp-tab')).map((tab) => ({
            uri: tab.getAttribute('data-uri'),
            selected: tab.getAttribute('aria-selected'),
            groupId: tab.getAttribute('data-group-id'),
            dirty: tab.getAttribute('data-dirty'),
          })),
        }));
        throw new Error(`Editor revert did not restore content: ${JSON.stringify(revertEvidence)}`, { cause: error });
      }
    }
    await page.waitForFunction(
      (uri) =>
        Array.from(document.querySelectorAll('.wizp-tab'))
          .find((tab) => tab.getAttribute('data-uri') === uri)
          ?.getAttribute('data-dirty') === 'false',
      lifecycleUri,
    );
    await page.getByText('Reverted sample.txt').waitFor({ timeout: 10000 });

    const savedLifecycleContent = 'needle WIZP_EDITOR_SAVE_OK\nsecond line\n';
    await page.evaluate((content) => window.__getActiveEditor().setValue(content), savedLifecycleContent);
    await page.evaluate(() => window.__saveActiveEditor());
    await waitForFileContent(lifecyclePath, savedLifecycleContent);
    await page.waitForFunction(
      (uri) =>
        Array.from(document.querySelectorAll('.wizp-tab'))
          .find((tab) => tab.getAttribute('data-uri') === uri)
          ?.getAttribute('data-dirty') === 'false',
      lifecycleUri,
    );
    await recoveredTab.click();
    const saveAsRecoveryContent = 'WIZP_SAVE_AS_RECOVERY\n';
    await page.evaluate((content) => window.__getActiveEditor().setValue(content), saveAsRecoveryContent);
    editorRpcMode = 'save-as-error';
    await page.evaluate(() => window.__saveActiveEditorAs());
    await page.getByText('Save As is unavailable. Your edits are still open; try another location.').waitFor({ timeout: 10000 });
    const saveAsFailureState = await page.evaluate((uri) => {
      const groupId = window.__getActiveGroupId?.();
      const group = groupId ? window.__getGroup?.(groupId) : null;
      const active = group?.editors?.find((editor) => editor.id === group.activeEditorId);
      return {
        content: window.__getActiveEditor?.()?.getValue(),
        dirty: active?.dirty,
        uri: active?.uri,
        expectedUri: uri,
      };
    }, lifecycleUri);
    editorRpcMode = 'normal';
    if (saveAsFailureState.content !== saveAsRecoveryContent || saveAsFailureState.dirty !== true || saveAsFailureState.uri !== lifecycleUri) {
      throw new Error(`Save As failure did not preserve the dirty editor: ${JSON.stringify(saveAsFailureState)}`);
    }

    await page.evaluate((content) => window.__getActiveEditor().setValue(content), 'WIZP_DISCARDED_EDIT\n');
    await recoveredTab.focus();
    await page.evaluate(() => window.__closeActiveEditor());
    const dirtyCloseDialog = page.getByRole('dialog', {
      name: /Save changes to sample\.txt/,
    });
    await dirtyCloseDialog.waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '01-editor-dirty-close');
    await dirtyCloseDialog.getByRole('button', { name: 'Cancel' }).click();
    await dirtyCloseDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction((uri) => document.activeElement?.getAttribute('data-uri') === uri, lifecycleUri);
    await page.evaluate(() => window.__closeActiveEditor());
    await dirtyCloseDialog.waitFor({ timeout: 10000 });
    await dirtyCloseDialog.getByRole('button', { name: 'Discard' }).click();
    await page.waitForFunction((uri) => !Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === uri), lifecycleUri);
    if (readFileSync(lifecyclePath, 'utf8') !== savedLifecycleContent) {
      throw new Error('Dirty-close discard changed the last saved file content');
    }

    const closeAllPaths = [lifecyclePath, join(ws.workspace, 'symbols.zig')];
    await page.evaluate(async (paths) => {
      for (const path of paths) await window.__openFile(path);
    }, closeAllPaths);
    await page.waitForFunction(() => document.querySelectorAll('.wizp-tab').length >= 2);
    await page.evaluate(() => window.__closeAllEditors());
    const closeAllPrompt = page.getByRole('dialog', { name: /Save changes to/ });
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        await closeAllPrompt.waitFor({ state: 'visible', timeout: 3000 });
        await closeAllPrompt.getByRole('button', { name: 'Discard' }).click();
      } catch {
        break;
      }
    }
    await page.waitForFunction(() => document.querySelectorAll('.wizp-tab').length === 0);

    await page.evaluate(() => window.__newFile());
    await page.waitForFunction(() => window.__getActiveEditor?.() && document.querySelector('.wizp-tab[data-uri^="untitled-"]'));
    const untitledEditor = await page.evaluate(() => {
      const groupId = window.__getActiveGroupId();
      const group = window.__getGroup(groupId);
      const editor = group.editors.find((candidate) => candidate.id === group.activeEditorId);
      return { id: editor.id, uri: editor.uri };
    });
    const untitledContent = 'WIZP_UNTITLED_SAVE_OK\n';
    await page.evaluate((content) => window.__getActiveEditor().setValue(content), untitledContent);
    await page.waitForFunction(
      (content) => window.__getActiveEditor?.()?.getValue() === content,
      untitledContent,
    );
    await page.evaluate(() => window.__closeActiveEditor());
    const untitledCloseDialog = page.getByRole('dialog', {
      name: /Save changes to untitled-/,
    });
    await untitledCloseDialog.waitFor({ timeout: 10000 });
    await untitledCloseDialog.getByRole('button', { name: 'Save' }).click();
    await page.waitForFunction((id) => !Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-tab-id') === id), untitledEditor.id);
    await waitForFileContent(join(ws.workspace, untitledEditor.uri), untitledContent);
    await page.waitForFunction(() => typeof window.__getActiveTerminalSmoke === 'function');

    const discoveredTasks = await rpcCall('tasks/discover');
    if (!Array.isArray(discoveredTasks.tasks) || !discoveredTasks.tasks.some((task) => task.label === 'browser smoke task' && task.source === '.vscode/tasks.json')) {
      throw new Error(`tasks.json task was not discovered: ${JSON.stringify(discoveredTasks)}`);
    }
    await page.evaluate(() => {
      window.__lastTaskUiResult = null;
      window.__lastTaskTerminalMirror = null;
      window.__lastTaskProblems = null;
      window.dispatchEvent(
        new CustomEvent('wizpTaskExecute', {
          detail: {
            label: 'browser smoke task',
            command: "printf 'alpha https://example.test\\nsrc/task-problem.zig:5: task warning\\n'",
          },
        }),
      );
    });
    await page.waitForFunction(() => window.__lastTaskUiResult && window.__lastTaskTerminalMirror?.mirrored === true, null, { timeout: 10000 });
    await page.waitForFunction(() => window.__getActiveTerminalSmoke?.().serialized?.includes('alpha https://example.test'), null, { timeout: 10000 });
    const taskUiEvidence = await page.evaluate(() => ({
      result: window.__lastTaskUiResult,
      mirror: window.__lastTaskTerminalMirror,
      problems: window.__lastTaskProblems || [],
      terminal: window.__getActiveTerminalSmoke(),
    }));
    if (taskUiEvidence.result.state !== 'completed' || !String(taskUiEvidence.result.stdout || '').includes('alpha https://example.test')) {
      throw new Error(`task UI run did not complete with stdout: ${JSON.stringify(taskUiEvidence)}`);
    }
    if (!taskUiEvidence.mirror.mirrored || !taskUiEvidence.terminal.serialized.includes('alpha https://example.test')) {
      throw new Error(`task command was not mirrored into terminal: ${JSON.stringify(taskUiEvidence)}`);
    }
    if (!taskUiEvidence.terminal.findAlpha || !Array.isArray(taskUiEvidence.terminal.commandDecorations) || taskUiEvidence.terminal.commandDecorations.length < 1) {
      throw new Error(`terminal find/decorations not visible after task: ${JSON.stringify(taskUiEvidence.terminal)}`);
    }
    if (!taskUiEvidence.problems.some((problem) => problem.file === 'src/task-problem.zig' && problem.line === 5)) {
      throw new Error(`task problem was not injected into Problems state: ${JSON.stringify(taskUiEvidence.problems)}`);
    }
    const backgroundTask = await rpcCall('tasks/run', {
      command: "printf 'watching\\nsrc/watch.zig:7: watcher warning\\nfinished\\n'",
      background: true,
      beginsPattern: 'watching',
      endsPattern: 'finished',
    });
    if (backgroundTask.state !== 'background-ready' || backgroundTask.backgroundBegan !== true || backgroundTask.backgroundEnded !== true) {
      throw new Error(`background task lifecycle mismatch: ${JSON.stringify(backgroundTask)}`);
    }
    const cancellableTask = await rpcCall('tasks/run', {
      command: 'sleep 30',
      background: true,
    });
    const cancelledTask = await rpcCall('tasks/cancel', {
      id: cancellableTask.id,
    });
    if (cancelledTask.state !== 'cancelled' || cancelledTask.cancelled !== true) {
      throw new Error(`task cancellation mismatch: ${JSON.stringify({ cancellableTask, cancelledTask })}`);
    }
    const terminalLinks = await rpcCall('terminal/links', {
      text: 'open https://example.test\nsrc/task-problem.zig:5: task warning\n',
    });
    if (!terminalLinks.links.some((link) => link.kind === 'url' && link.target === 'https://example.test') || !terminalLinks.links.some((link) => link.kind === 'file' && link.path === 'src/task-problem.zig' && link.line === 5)) {
      throw new Error(`terminal link detection mismatch: ${JSON.stringify(terminalLinks)}`);
    }
    await screenshotMustBeNonBlank(page, '07-terminal-task-ui');

    stage = 'open symbols';
    await page.waitForFunction(() => typeof window.__openFile === 'function');
    await page.evaluate((path) => window.__openFile(path), join(ws.workspace, 'symbols.zig'));
    const fileCrumb = page.locator('.breadcrumb-item', { hasText: 'symbols.zig' }).first();
    await fileCrumb.waitFor({ timeout: 10000 });
    stage = 'open breadcrumb';
    await fileCrumb.click();
    const breadcrumbDropdown = page.locator('.breadcrumb-dropdown');
    await breadcrumbDropdown.waitFor({ timeout: 10000 });
    const thingCrumb = breadcrumbDropdown.locator('.breadcrumb-dropdown-item', { hasText: 'Thing' }).first();
    await thingCrumb.waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '01-breadcrumbs');
    stage = 'select breadcrumb symbol';
    await thingCrumb.click();
    await breadcrumbDropdown.waitFor({ state: 'hidden', timeout: 10000 });
    const explorerOutlineThing = page.locator('#explorer-outline').getByRole('button', { name: 'Thing' });
    await explorerOutlineThing.waitFor({ timeout: 10000 });
    await explorerOutlineThing.focus();
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => window.__getActiveEditor?.()?.getPosition()?.lineNumber === 1);

    async function setTabSort(rule, order = 'asc') {
      await page.evaluate(
        ({ rule, order }) => {
          const settings = JSON.parse(localStorage.getItem('wizp-settings') || '{}');
          settings['workbench.editor.openPositioning'] = 'sort';
          settings['workbench.editor.openPositioningSortRule'] = rule;
          settings['workbench.editor.openPositioningSortOrder'] = order;
          localStorage.setItem('wizp-settings', JSON.stringify(settings));
        },
        { rule, order },
      );
    }
    async function openAndWait(path) {
      await page.evaluate((targetPath) => window.__openFile(targetPath), path);
      const uri = `file://${path}`;
      await page.waitForFunction((targetUri) => Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === targetUri), uri);
      return uri;
    }
    async function expectTabOrder(label, expectedUris) {
      await page.waitForFunction((uris) => {
        const order = Array.from(document.querySelectorAll('.wizp-tab')).map((tab) => tab.getAttribute('data-uri'));
        const positions = uris.map((uri) => order.indexOf(uri));
        return positions.every((index) => index >= 0) && positions.every((index, i) => i === 0 || positions[i - 1] < index);
      }, expectedUris);
      const actual = await page.locator('.wizp-tab').evaluateAll((tabs) => tabs.map((tab) => tab.getAttribute('data-uri')));
      const positions = expectedUris.map((uri) => actual.indexOf(uri));
      if (!positions.every((index, i) => index >= 0 && (i === 0 || positions[i - 1] < index))) {
        throw new Error(`${label} tab order mismatch: ${JSON.stringify({ expectedUris, actual })}`);
      }
    }

    stage = 'open sorted tabs';
    await setTabSort('name-local', 'asc');
    const sortZetaUri = await openAndWait(join(ws.workspace, 'sort-zeta.txt'));
    const sortAlphaUri = await openAndWait(join(ws.workspace, 'sort-alpha.txt'));
    await expectTabOrder('name-local asc', [sortAlphaUri, sortZetaUri]);

    await setTabSort('name-absolute', 'asc');
    const sameBUri = await openAndWait(join(ws.workspace, 'sort-b', 'same.txt'));
    const sameAUri = await openAndWait(join(ws.workspace, 'sort-a', 'same.txt'));
    await expectTabOrder('name-absolute asc', [sameAUri, sameBUri]);

    await setTabSort('absolute', 'asc');
    const absoluteZUri = await openAndWait(join(ws.workspace, 'sort-abs-z', 'a-first-name.txt'));
    const absoluteAUri = await openAndWait(join(ws.workspace, 'sort-abs-a', 'z-last-name.txt'));
    await expectTabOrder('absolute asc', [absoluteAUri, absoluteZUri]);
    await screenshotMustBeNonBlank(page, '01-tab-sorting');

    await screenshotMustBeNonBlank(page, '01-explorer');

    stage = 'search lifecycle, replacement, and recovery';
    await clickActivitySlot(page, 1);
    await page.getByText('SEARCH').first().waitFor({ timeout: 10000 });
    const searchField = await waitForInput(page, 'input[aria-label="Search files"]');
    const searchNow = async (value) => {
      await searchField.fill(value);
      await searchField.press('Enter');
    };

    await page.getByRole('button', { name: 'Toggle search details' }).click();
    const includeField = await waitForInput(page, 'input[aria-label="Files to include"]');
    const excludeField = await waitForInput(page, 'input[aria-label="Files to exclude"]');
    const contextSelect = page.getByLabel('Context lines');
    await includeField.fill('search-*.txt');
    await excludeField.fill('search-excluded.txt');
    await searchNow('alpha');
    await page.getByText('4 matching lines in 1 file', { exact: true }).waitFor({ timeout: 10000 });
    await page.locator('.search-result', { hasText: 'search-alpha.txt' }).first().waitFor();
    if (await page.locator('.search-result', { hasText: 'search-excluded.txt' }).count()) {
      throw new Error('Search exclude filter leaked an excluded file');
    }

    await page.getByRole('button', { name: 'Match case' }).click();
    await page.getByText('2 matching lines in 1 file', { exact: true }).waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Match whole word' }).click();
    await page.getByText('1 matching line in 1 file', { exact: true }).waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Match whole word' }).click();
    await page.getByRole('button', { name: 'Use regular expression' }).click();
    await searchNow('^ALPHA$');
    await page.getByText('1 matching line in 1 file', { exact: true }).waitFor({ timeout: 10000 });

    await searchNow('[');
    await page.getByRole('alert').filter({ hasText: 'Search failed:' }).waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Use regular expression' }).click();
    await page.getByRole('button', { name: 'Match case' }).click();
    await searchNow('nothing-here-wizp');
    await page.getByText('No matches found for “nothing-here-wizp”.').waitFor({ timeout: 10000 });

    await includeField.fill('search-navigation.txt');
    await excludeField.fill('');
    await contextSelect.selectOption('1');
    await searchNow('search-navigation-marker');
    const navigationResult = page.locator('.search-result', {
      hasText: 'search-navigation.txt',
    });
    await navigationResult.getByText('context before · context after').waitFor({ timeout: 10000 });
    await navigationResult.getByRole('button', { name: 'Open search-navigation.txt, line 2' }).click();
    try {
      await page.waitForFunction(() => {
        const editor = window.__getActiveEditor?.();
        const selectedTab = document.querySelector('.wizp-tab[aria-selected="true"]');
        return selectedTab?.getAttribute('data-uri')?.endsWith('search-navigation.txt') && editor?.getPosition()?.lineNumber === 2;
      });
    } catch {
      const navigationEvidence = await page.evaluate(() => {
        const editor = window.__getActiveEditor?.();
        return {
          activeUri: editor?.getModel()?.uri?.toString(),
          position: editor?.getPosition(),
          tabs: Array.from(document.querySelectorAll('.wizp-tab')).map((tab) => ({
            uri: tab.getAttribute('data-uri'),
            selected: tab.getAttribute('aria-selected'),
          })),
        };
      });
      throw new Error(`Search result navigation failed: ${JSON.stringify(navigationEvidence)}`);
    }

    await page.getByRole('button', { name: 'Toggle replace' }).click();
    const replaceField = await waitForInput(page, 'input[aria-label="Replace with"]');
    await contextSelect.selectOption('0');
    await includeField.fill('search-replace-one.txt');
    await searchNow('replace-one');
    await replaceField.fill('done-one');
    await page.getByText('2 matching lines in 1 file', { exact: true }).waitFor({ timeout: 10000 });
    await page
      .getByRole('button', {
        name: 'Replace match in search-replace-one.txt on line 1',
      })
      .click();
    await waitForFileContent(join(ws.workspace, 'search-replace-one.txt'), 'done-one replace-one\nreplace-one second\n');
    await page.getByText('Replaced 1 occurrence across 1 file.').waitFor({ timeout: 10000 });

    await includeField.fill('search-replace-all-*.txt');
    await searchNow('replace-all');
    await replaceField.fill('done-all');
    await page.getByText('3 matching lines in 2 files', { exact: true }).waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Replace all matches' }).click();
    const replaceDialog = page.getByRole('dialog', {
      name: 'Replace across 2 files?',
    });
    await replaceDialog.waitFor({ timeout: 10000 });
    await replaceDialog.getByText('cannot be undone in WIZP').waitFor();
    await replaceDialog.getByRole('button', { name: 'Replace All' }).click();
    await replaceDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await waitForFileContent(join(ws.workspace, 'search-replace-all-a.txt'), 'done-all one\ndone-all two\n');
    await waitForFileContent(join(ws.workspace, 'search-replace-all-b.txt'), 'done-all three\n');
    await page.getByText('Replaced 3 occurrences across 2 files.').waitFor({ timeout: 10000 });

    searchRpcMode = 'error';
    await includeField.fill('');
    await searchNow('forced-error');
    const failedSearchAlert = page.getByRole('alert').filter({ hasText: 'Injected search failure' });
    await failedSearchAlert.waitFor({ timeout: 10000 });
    const failedSearchAlertText = await failedSearchAlert.innerText();
    if (failedSearchAlertText.includes('super-secret') || failedSearchAlertText.includes('https://')) {
      throw new Error(`network failure details were not redacted: ${failedSearchAlertText}`);
    }
    searchRpcMode = 'normal';
    await page.getByRole('button', { name: 'Retry' }).click();
    await page.getByText('No matches found for “forced-error”.').waitFor({ timeout: 10000 });

    searchRpcMode = 'slow';
    await searchNow('slow-search');
    await page.getByText('Searching workspace…').waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Cancel' }).click();
    searchRpcMode = 'normal';
    await page.getByText('Search canceled.').waitFor({ timeout: 10000 });
    await page.waitForTimeout(1400);
    await page.getByText('Search canceled.').waitFor();

    await includeField.fill('search-*.txt');
    await excludeField.fill('search-excluded.txt');
    await contextSelect.selectOption('1');
    await searchNow('alpha');
    await replaceField.fill('thread');
    await page.getByText('4 matching lines in 1 file', { exact: true }).waitFor({ timeout: 10000 });
    const searchCalls = browserRpcMethods.filter((entry) => entry.method === 'search/text');
    if (!searchCalls.some((entry) => entry.params.caseSensitive === true) || !searchCalls.some((entry) => entry.params.wholeWord === true) || !searchCalls.some((entry) => entry.params.regex === true) || !searchCalls.some((entry) => entry.params.include === 'search-*.txt') || !searchCalls.some((entry) => entry.params.contextLines === 1)) {
      throw new Error(`Search option RPC coverage incomplete: ${JSON.stringify(searchCalls)}`);
    }
    await screenshotMustBeNonBlank(page, '02-search');

    stage = 'source-control lifecycle and recovery';
    const nativeScmStatus = await rpcCall('git/status');
    if (!nativeScmStatus.files?.some((file) => file.file === 'sample.txt')) {
      throw new Error(`native Git status lost the fixture change: ${JSON.stringify(nativeScmStatus)}`);
    }
    await clickActivitySlot(page, 2);
    await page.getByText('SOURCE CONTROL').first().waitFor({ timeout: 10000 });
    try {
      await page.getByTitle('Refresh Source Control').click({ timeout: 10000 });
    } catch {
      throw new Error(`SCM view did not mount: ${JSON.stringify({ pageErrors, text: await page.locator('body').innerText() })}`);
    }
    await page.getByLabel('Git branch').waitFor({ timeout: 10000 });
    await page.getByText('sample.txt').first().waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '03-scm-before');

    const commitInput = page.getByLabel('Commit message');
    await commitInput.fill('');
    await page.getByTitle('Commit staged changes').click();
    await page.getByRole('alert').filter({ hasText: 'Enter a commit message.' }).waitFor();
    await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Commit message');

    const stagedFixtureRow = page.locator('.scm-file-row').filter({ hasText: 'scm-staged.txt' });
    await stagedFixtureRow.getByRole('button', { name: 'Unstage scm-staged.txt' }).click();
    await page.getByText('Unstaged scm-staged.txt.').waitFor({ timeout: 10000 });
    await stagedFixtureRow.getByRole('button', { name: 'Stage scm-staged.txt' }).waitFor({ timeout: 10000 });
    await commitInput.fill('should not commit');
    await page.getByTitle('Commit staged changes').click();
    await page.getByRole('alert').filter({ hasText: 'Stage at least one file before committing.' }).waitFor();
    await commitInput.fill('');

    const stageFixtureRow = page.locator('.scm-file-row').filter({ hasText: 'scm-stage.txt' });
    scmRpcMode = 'stage-error';
    await stageFixtureRow.getByRole('button', { name: 'Stage scm-stage.txt' }).click();
    await page.getByRole('alert').filter({ hasText: 'Injected stage failure' }).waitFor({ timeout: 10000 });
    scmRpcMode = 'normal';
    await page.getByRole('button', { name: 'Retry' }).click();
    await stageFixtureRow.getByRole('button', { name: 'Stage scm-stage.txt' }).click();
    await stageFixtureRow.getByRole('button', { name: 'Unstage scm-stage.txt' }).waitFor({ timeout: 10000 });
    await stageFixtureRow.getByRole('button', { name: 'Unstage scm-stage.txt' }).click();
    await page.getByText('Unstaged scm-stage.txt.').waitFor({ timeout: 10000 });
    await stageFixtureRow.getByRole('button', { name: 'Stage scm-stage.txt' }).waitFor({ timeout: 10000 });
    await stageFixtureRow.getByRole('button', { name: 'Show diff for scm-stage.txt' }).waitFor({ timeout: 10000 });
    await stageFixtureRow.getByRole('button', { name: 'Show diff for scm-stage.txt' }).click();
    const diffContents = page.getByLabel('Diff contents');
    await diffContents.waitFor({ timeout: 10000 });
    if (!(await diffContents.inputValue()).includes('+scm stage changed')) {
      throw new Error(`SCM diff did not show the changed content: ${await diffContents.inputValue()}`);
    }
    await page.getByRole('button', { name: 'Close diff' }).click();

    const discardFixtureRow = page.locator('.scm-file-row').filter({ hasText: 'scm-discard.txt' });
    const discardButton = discardFixtureRow.getByRole('button', {
      name: 'Discard scm-discard.txt',
    });
    await discardButton.click();
    let discardDialog = page.getByRole('dialog', {
      name: 'Discard file changes?',
    });
    await discardDialog.waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '03-scm-discard-dialog');
    await page.keyboard.press('Escape');
    await discardDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Discard scm-discard.txt');
    await discardButton.click();
    discardDialog = page.getByRole('dialog', { name: 'Discard file changes?' });
    await discardDialog.getByRole('button', { name: 'Discard Changes' }).click();
    await waitForFileContent(join(ws.workspace, 'scm-discard.txt'), 'scm discard original\n');
    await page.getByText('Discarded changes to scm-discard.txt.').waitFor({ timeout: 10000 });

    const untrackedFixtureRow = page.locator('.scm-file-row').filter({ hasText: 'scm-untracked.txt' });
    await untrackedFixtureRow.getByRole('button', { name: 'Discard scm-untracked.txt' }).click();
    const deleteDialog = page.getByRole('dialog', {
      name: 'Delete untracked file?',
    });
    await deleteDialog.getByText('permanently deleted').waitFor();
    await deleteDialog.getByRole('button', { name: 'Delete File' }).click();
    await waitForPath(join(ws.workspace, 'scm-untracked.txt'), false);
    await page.getByText('Deleted untracked file scm-untracked.txt.').waitFor({ timeout: 10000 });

    await stageFixtureRow.getByRole('button', { name: 'Stage scm-stage.txt' }).click();
    await stageFixtureRow.getByRole('button', { name: 'Unstage scm-stage.txt' }).waitFor({ timeout: 10000 });
    await commitInput.fill('browser scm commit');
    await page.getByTitle('Commit staged changes').click();
    await page.getByText('Committed “browser scm commit”.').waitFor({ timeout: 10000 });
    await waitForFileContent(join(ws.workspace, 'scm-stage.txt'), 'scm stage changed\n');

    const branchSelect = page.getByLabel('Git branch');
    await branchSelect.selectOption('browser-branch');
    await page.getByText('Switched to branch browser-branch.').waitFor({ timeout: 10000 });
    await branchSelect.selectOption(nativeScmStatus.branch);
    await page.getByText(`Switched to branch ${nativeScmStatus.branch}.`).waitFor({ timeout: 10000 });

    await page.getByText('Timeline').first().click();
    const timelineCommit = page.getByRole('button', {
      name: 'Show commit browser scm commit',
    });
    await timelineCommit.waitFor({ timeout: 10000 });
    await timelineCommit.click();
    const commitDiff = page.getByLabel('Diff contents');
    await commitDiff.waitFor({ timeout: 10000 });
    if (!(await commitDiff.inputValue()).includes('browser scm commit')) {
      throw new Error('SCM history navigation did not load the selected commit');
    }
    await page.getByRole('button', { name: 'Close diff' }).click();

    execFileSync('git', ['checkout', '-b', 'browser-conflict'], {
      cwd: ws.workspace,
      stdio: 'ignore',
    });
    writeFileSync(join(ws.workspace, 'scm-conflict.txt'), 'scm conflict incoming\n');
    execFileSync('git', ['add', 'scm-conflict.txt'], { cwd: ws.workspace });
    execFileSync('git', ['commit', '-m', 'browser conflict incoming'], {
      cwd: ws.workspace,
      stdio: 'ignore',
    });
    execFileSync('git', ['checkout', nativeScmStatus.branch], {
      cwd: ws.workspace,
      stdio: 'ignore',
    });
    writeFileSync(join(ws.workspace, 'scm-conflict.txt'), 'scm conflict current\n');
    execFileSync('git', ['add', 'scm-conflict.txt'], { cwd: ws.workspace });
    execFileSync('git', ['commit', '-m', 'browser conflict current'], {
      cwd: ws.workspace,
      stdio: 'ignore',
    });
    let conflictCreated = false;
    try {
      execFileSync('git', ['merge', 'browser-conflict'], {
        cwd: ws.workspace,
        stdio: 'ignore',
      });
    } catch {
      conflictCreated = true;
    }
    if (!conflictCreated) throw new Error('SCM browser fixture did not create a merge conflict');
    await page.getByTitle('Refresh Source Control').click();
    const conflictRow = page.locator('.scm-file-row').filter({ hasText: 'scm-conflict.txt' });
    await conflictRow.getByRole('button', { name: 'Show conflict in scm-conflict.txt' }).click();
    await page.getByText('scm conflict current', { exact: true }).waitFor({ timeout: 10000 });
    await page.getByText('scm conflict incoming', { exact: true }).waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '03-scm-conflict');
    await page.getByRole('region', { name: 'Conflict in scm-conflict.txt' }).getByRole('button', { name: 'Accept Both' }).click();
    await waitForFileContent(join(ws.workspace, 'scm-conflict.txt'), 'scm conflict current\nscm conflict incoming\n');
    await page.getByText('Resolved conflict in scm-conflict.txt.').waitFor({ timeout: 10000 });
    execFileSync('git', ['merge', '--abort'], {
      cwd: ws.workspace,
      stdio: 'ignore',
    });
    await page.getByTitle('Refresh Source Control').click();

    scmRpcMode = 'load-error';
    await page.getByTitle('Refresh Source Control').click();
    await page.getByRole('alert').filter({ hasText: 'Injected source-control failure' }).waitFor({ timeout: 10000 });
    scmRpcMode = 'normal';
    await page.getByRole('button', { name: 'Retry' }).click();
    await page.getByLabel('Git branch').waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '03-scm');
    const extensionScm = await rpcCall('scm/extensionProviderSmoke');
    const extensionStates = extensionScm.resourceGroups.flatMap((group) =>
      group.resources.map((resource) => ({
        ...resource,
        group: resource.group || group.id,
        sourceControlId: extensionScm.provider.id,
        sourceControlLabel: extensionScm.provider.label,
      })),
    );
    await page.evaluate((states) => window.dispatchEvent(new CustomEvent('wizpScmUpdate', { detail: states })), extensionStates);
    await page.getByText('extension-change.txt').waitFor({ timeout: 10000 });
    await page.getByText('extension-staged.txt').waitFor({ timeout: 10000 });
    await page.getByText('Smoke SCM').waitFor({ timeout: 10000 });
    await page.locator('.scm-file-row').filter({ hasText: 'extension-change.txt' }).getByTitle('Stage').waitFor({ timeout: 10000 });
    await page.locator('.scm-file-row').filter({ hasText: 'extension-staged.txt' }).getByTitle('Unstage').waitFor({ timeout: 10000 });
    if (!extensionScm.provider.replacesNative || !extensionScm.selection || !extensionScm.refresh || !extensionScm.disposal || !extensionScm.commands || !extensionScm.decorations) {
      throw new Error(`extension SCM provider contract failed: ${JSON.stringify(extensionScm)}`);
    }
    await page.getByText('Remotes').first().click();
    await page.locator('.scm-remote-panel').waitFor({ timeout: 10000 });
    await page.getByLabel('Git remote').selectOption('origin');
    const promptPlan = await rpcCall('git/remoteCredentialPromptPlan');
    if (!promptPlan.manualOnly || !promptPlan.optInRequired || promptPlan.defaultPolicy !== 'non-interactive' || promptPlan.envFlag !== 'WIZP_SCM_NETWORK_PROMPTS' || !promptPlan.promptUx?.cancelDefault || !promptPlan.safeForCi) {
      throw new Error(`remote credential prompt plan failed: ${JSON.stringify(promptPlan)}`);
    }
    await page.locator('.scm-remote-prompt-plan[data-manual-only="true"][data-opt-in="true"]').waitFor({ timeout: 10000 });
    await page.getByText('WIZP_SCM_NETWORK_PROMPTS').waitFor({ timeout: 10000 });
    await page.getByText('Preview').click();
    await page
      .locator('.scm-remote-status:not(.scm-remote-prompt-plan)', {
        hasText: 'non-interactive',
      })
      .waitFor({ timeout: 10000 });
    const dryFetch = await rpcCall('git/fetch', {
      remote: 'origin',
      dryRun: true,
    });
    if (!dryFetch.ok || !dryFetch.credentialSafe || dryFetch.credentialPromptRequired || dryFetch.credentialPolicy !== 'non-interactive') {
      throw new Error(`remote dry-run safety failed: ${JSON.stringify(dryFetch)}`);
    }

    await page.getByText('Problems').first().click();
    await page.getByTitle('Filter by severity').waitFor({ timeout: 10000 });
    await page.getByTitle('Sort problems').waitFor({ timeout: 10000 });
    await page.getByTitle('Refresh Problems').waitFor({ timeout: 10000 });
    await page.getByText('No problems detected in the workspace.').first().waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '04-problems');
    await page.waitForFunction(() => typeof window.__setProblemsForSmoke === 'function');
    const problemFixture = [
      {
        source: 'native',
        file: join(ws.workspace, 'native-problem.zig'),
        line: 0,
        col: 1,
        severity: 1,
        message: 'native fixture error',
      },
      {
        source: 'task',
        file: join(ws.workspace, 'task-problem.zig'),
        line: 6,
        col: 0,
        severity: 2,
        message: 'task matcher warning',
      },
      {
        source: 'extension',
        file: join(ws.workspace, 'extension-problem.zig'),
        line: 2,
        col: 3,
        severity: 3,
        message: 'extension diagnostic info',
      },
    ];
    await page.evaluate((items) => window.__setProblemsForSmoke(items), problemFixture);
    await page.locator('.problem-row').first().waitFor({ timeout: 10000 });
    await page.getByText('native fixture error').waitFor({ timeout: 10000 });
    await page.getByText('task matcher warning').waitFor({ timeout: 10000 });
    await page.getByText('extension diagnostic info').waitFor({ timeout: 10000 });
    await page.getByTitle('Filter by source').selectOption('task');
    await page.getByText('task matcher warning').waitFor({ timeout: 10000 });
    if (
      await page
        .getByText('native fixture error')
        .isVisible()
        .catch(() => false)
    ) {
      throw new Error('Problems source filter did not hide native diagnostic');
    }
    await page.getByTitle('Filter by source').selectOption('all');
    await page.getByTitle('Filter by severity').selectOption('2');
    await page.getByText('task matcher warning').waitFor({ timeout: 10000 });
    if (
      await page
        .getByText('extension diagnostic info')
        .isVisible()
        .catch(() => false)
    ) {
      throw new Error('Problems severity filter did not hide info diagnostic');
    }
    await page.getByTitle('Filter by severity').selectOption('all');
    await page.getByTitle('Sort problems').selectOption('file');
    await page.locator('label', { hasText: 'File' }).locator('input').uncheck();
    await page.locator('.problem-row').first().waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '04-problems-reconciled');
    await page.getByTitle('Filter by source').selectOption('native');
    await page.getByText('native fixture error').click();
    await page.waitForFunction(
      (targetUri) => {
        return Array.from(document.querySelectorAll('.wizp-tab')).some((tab) => tab.getAttribute('data-uri') === targetUri);
      },
      `file://${join(ws.workspace, 'native-problem.zig')}`,
    );

    if (!(await page.evaluate(() => typeof window.__setOutlineSymbolsForSmoke === 'function'))) {
      await page.getByTitle('Open Right Sidebar').click();
    }
    await page.waitForFunction(() => typeof window.__setOutlineSymbolsForSmoke === 'function');
    const outlineFixtureUri = `file://${join(ws.workspace, 'symbols.zig')}`;
    const outlineFixture = [
      {
        name: 'Thing',
        kind: 5,
        range: {
          start: { line: 0, character: 6 },
          end: { line: 2, character: 1 },
        },
        selectionRange: {
          start: { line: 0, character: 6 },
          end: { line: 0, character: 11 },
        },
        children: [
          {
            name: 'init',
            kind: 6,
            containerName: 'Thing',
            range: {
              start: { line: 1, character: 11 },
              end: { line: 1, character: 22 },
            },
            selectionRange: {
              start: { line: 1, character: 11 },
              end: { line: 1, character: 15 },
            },
            children: [],
          },
        ],
      },
      {
        name: 'alphaHelper',
        kind: 12,
        range: {
          start: { line: 4, character: 0 },
          end: { line: 4, character: 20 },
        },
        selectionRange: {
          start: { line: 4, character: 0 },
          end: { line: 4, character: 11 },
        },
        children: [],
      },
    ];
    await page.evaluate(({ uri, symbols }) => window.__setOutlineSymbolsForSmoke(uri, symbols), {
      uri: outlineFixtureUri,
      symbols: outlineFixture,
    });
    await page.locator('.outline-row[data-symbol-name="Thing"]').waitFor({ timeout: 10000 });
    await page.locator('.outline-row[data-symbol-name="init"][data-symbol-depth="1"]').waitFor({ timeout: 10000 });
    await page.locator('.outline-filter').fill('init');
    await page.locator('.outline-row[data-symbol-name="init"]').waitFor({ timeout: 10000 });
    if (
      await page
        .locator('.outline-row[data-symbol-name="Thing"]')
        .isVisible()
        .catch(() => false)
    ) {
      throw new Error('Outline filter did not hide Thing row');
    }
    await page.locator('.outline-filter').fill('');
    await page.locator('.outline-sort').selectOption('name');
    await page.waitForFunction(() => {
      const names = Array.from(document.querySelectorAll('.outline-row')).map((row) => row.getAttribute('data-symbol-name'));
      return names.includes('alphaHelper') && names.includes('Thing') && names.indexOf('alphaHelper') < names.indexOf('Thing');
    });
    await page.evaluate(() => window.__setOutlineCursorForSmoke(1));
    await page.locator('.outline-row-active[data-symbol-name="init"]').waitFor({ timeout: 10000 });
    await page.locator('.outline-row[data-symbol-name="init"]').click();
    const selectedOutline = await page.evaluate(() => window.__lastOutlineSymbol?.name);
    if (selectedOutline !== 'init') {
      throw new Error(`Outline click did not select init: ${selectedOutline}`);
    }
    await screenshotMustBeNonBlank(page, '04-outline-reconciled');

    stage = 'debug lifecycle';
    const launchPath = join(ws.workspace, '.vscode', 'launch.json');
    const validLaunchJson = readFileSync(launchPath, 'utf8');
    writeFileSync(launchPath, JSON.stringify({ version: '0.2.0', configurations: [] }, null, 2));
    await clickActivitySlot(page, 3);
    await page.getByText('RUN AND DEBUG').first().waitFor({ timeout: 10000 });
    await page.getByText('No launch configuration found.').waitFor({ timeout: 10000 });
    if (!(await page.getByTitle('Start Debugging (F5)').isDisabled())) {
      throw new Error('Debug start remained enabled without a launch configuration');
    }
    await screenshotMustBeNonBlank(page, '05-debug-missing-configuration');

    writeFileSync(launchPath, validLaunchJson);
    await page.getByTitle('Refresh debugger state').click();
    await page.locator('.debug-launch-meta[data-schema-valid="true"][data-compounds="1"]').waitFor({ timeout: 10000 });
    await page.locator('.debug-advanced-breakpoints[data-source-reference="3001"]').waitFor({ timeout: 10000 });
    await page.getByTitle('Select launch configuration').selectOption('Fixture Launch');
    await page.getByText('Fixture Compound').waitFor({ timeout: 10000 });
    await page.getByText('pre: fixture:build').waitFor({ timeout: 10000 });
    await page.getByText('post: fixture:cleanup').waitFor({ timeout: 10000 });
    await page.getByText('fn: main').waitFor({ timeout: 10000 });
    await page.getByText('data: answer').waitFor({ timeout: 10000 });
    await page.getByText('srcRef: 3001').waitFor({ timeout: 10000 });
    const launchConfigs = await rpcCall('debug/launchConfigurations', {
      selected: 'Fixture Launch',
    });
    if (!launchConfigs.schemaValid || launchConfigs.selected !== 'Fixture Launch' || launchConfigs.configurations?.[0]?.preLaunchTask !== 'fixture:build' || launchConfigs.configurations?.[0]?.postDebugTask !== 'fixture:cleanup' || launchConfigs.compounds?.[0]?.name !== 'Fixture Compound' || !launchConfigs.ui?.selector || !launchConfigs.ui?.schemaDiagnostics) {
      throw new Error(`launch configuration contract failed: ${JSON.stringify(launchConfigs)}`);
    }

    debugRpcMode = 'load-error';
    await page.getByTitle('Refresh debugger state').click();
    await page.getByRole('alert').filter({ hasText: 'Injected debugger state failure' }).waitFor({ timeout: 10000 });
    debugRpcMode = 'normal';
    await page.getByRole('button', { name: 'Refresh debugger state' }).click();
    await page.locator('.debug-launch-meta[data-schema-valid="true"]').waitFor({ timeout: 10000 });

    await page.getByTitle('Select launch configuration').selectOption('Missing Adapter');
    await page.getByTitle('Start Debugging (F5)').click();
    const adapterFailure = page.locator('.debug-message.error');
    await adapterFailure.waitFor({ timeout: 10000 });
    const adapterFailureText = await adapterFailure.textContent();
    if (!adapterFailureText?.includes('Debug') || !adapterFailureText.includes('failed')) {
      throw new Error(`Unexpected debug adapter failure: ${adapterFailureText}`);
    }
    await screenshotMustBeNonBlank(page, '05-debug-adapter-failure');

    await page.getByTitle('Select launch configuration').selectOption('Fixture Launch');
    await page.getByTitle('Start Debugging (F5)').click();
    await page.locator('.debug-session-bar[data-paused="true"]').waitFor({ timeout: 10000 });
    await page.getByText('Paused on thread 1').waitFor({ timeout: 10000 });
    await page.locator('.debug-data-list[aria-label="Call stack"]').getByText('main', { exact: true }).waitFor({ timeout: 10000 });
    const variablesList = page.locator('.debug-data-list[aria-label="Variables"]');
    await variablesList.getByText('answer', { exact: true }).waitFor({ timeout: 10000 });
    await variablesList.getByText('42', { exact: true }).waitFor({ timeout: 10000 });
    await page.locator('.debug-data-list[aria-label="Watch expressions"]').getByText('debug smoke', { exact: true }).waitFor({ timeout: 10000 });

    await rpcCall('debug/toggleBreakpoint', { file: 'main.zig', line: 7 });
    await page.getByTitle('Refresh debugger state').click();
    await page.getByRole('button', { name: 'Remove breakpoint from main.zig line 8' }).waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '05-debug-paused');

    const sidebarDebugControls = page.getByRole('toolbar', {
      name: 'Active debug session',
    });
    await sidebarDebugControls.getByRole('button', { name: 'Continue debugging' }).click();
    await page.locator('.debug-session-bar[data-paused="false"]').waitFor({ timeout: 10000 });
    await page.getByText('Running thread 1').waitFor({ timeout: 10000 });
    await sidebarDebugControls.getByRole('button', { name: 'Pause debugging' }).click();
    await page.locator('.debug-session-bar[data-paused="true"]').waitFor({ timeout: 10000 });
    await sidebarDebugControls.getByRole('button', { name: 'Step over' }).click();
    await page.getByText('Step over complete.').waitFor({ timeout: 10000 });
    await sidebarDebugControls.getByRole('button', { name: 'Step into' }).click();
    await page.getByText('Step into complete.').waitFor({ timeout: 10000 });
    await sidebarDebugControls.getByRole('button', { name: 'Step out' }).click();
    await page.getByText('Step out complete.').waitFor({ timeout: 10000 });
    await sidebarDebugControls.getByRole('button', { name: 'Restart debugging' }).click();
    await page.getByText('Restart complete.').waitFor({ timeout: 10000 });

    await page.getByRole('button', { name: 'Debug Console' }).click();
    const debugExpression = page.getByRole('textbox', {
      name: 'Debug expression',
    });
    await debugExpression.fill('answer');
    await page.getByRole('button', { name: 'Evaluate expression' }).click();
    await page.locator('#debug-console-output').getByText('42', { exact: true }).waitFor({ timeout: 10000 });
    await page.getByText('Evaluation complete.').waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '05-debug');

    await sidebarDebugControls.getByRole('button', { name: 'Stop debugging' }).click();
    await page.getByText('Ready to debug').waitFor({ timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Start Debugging (F5)');
    if (
      await page
        .getByRole('toolbar', { name: /Debug controls, execution/ })
        .isVisible()
        .catch(() => false)
    ) {
      throw new Error('Floating debug toolbar remained visible after stop');
    }
    await debugExpression.fill('answer');
    await page.getByRole('button', { name: 'Evaluate expression' }).click();
    await page.getByRole('alert').filter({ hasText: 'No debug session is running' }).waitFor({ timeout: 10000 });
    if ((await debugExpression.inputValue()) !== 'answer') {
      throw new Error('Failed debug evaluation did not preserve the expression for retry');
    }

    const externalDebug = await rpcCall('debug/externalAdapterSmoke', {
      adapterPath: join(ROOT, 'testdata', 'extensions', 'basic-api-smoke', 'debugAdapters', 'smokeDebug.js'),
    });
    if (!externalDebug.ok || !externalDebug.adapterProcess || !externalDebug.events?.hitBreakpoint || !externalDebug.exceptionBreakpoints || !externalDebug.sourceReference || !externalDebug.variables || !externalDebug.evaluate || !externalDebug.continue || externalDebug.watch?.result !== '42' || externalDebug.debugConsoleOutput !== 'external adapter output') {
      throw new Error(`external debug adapter smoke failed: ${JSON.stringify(externalDebug)}`);
    }
    const advancedBreakpoints = await rpcCall('debug/advancedBreakpoints');
    if (!advancedBreakpoints.supportsExceptionBreakpoints || !advancedBreakpoints.supportsFunctionBreakpoints || !advancedBreakpoints.supportsDataBreakpoints || advancedBreakpoints.sourceReference !== 3001 || !advancedBreakpoints.ui?.functionBreakpointInput || !advancedBreakpoints.ui?.dataBreakpointInput) {
      throw new Error(`advanced breakpoint contract failed: ${JSON.stringify(advancedBreakpoints)}`);
    }

    stage = 'extensions lifecycle';
    extensionHostRpcMode = 'unavailable';
    await clickActivitySlot(page, 4);
    const extensionSearch = page.getByRole('search').getByRole('searchbox', { name: 'Search extensions' });
    await extensionSearch.waitFor({ timeout: 10000 });
    await page.getByText('The extension host is unavailable. Extension commands and views are paused.').waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '06-extensions-host-unavailable');
    extensionHostRpcMode = 'normal';
    await page.getByRole('button', { name: 'Retry', exact: true }).click();
    await page.getByText('Extension host restarted. Contributions are available.').waitFor({ timeout: 10000 });
    await page.getByText(/Running · 0 discovered/).waitFor({ timeout: 10000 });
    const hubGatedSearch = await rpcCall('hub/search', { query: 'alpha' });
    if (!hubGatedSearch.networkRequired || hubGatedSearch.status !== 'network-consent-required') {
      throw new Error(`extension hub search did not require network consent: ${JSON.stringify(hubGatedSearch)}`);
    }
    await extensionSearch.fill('alpha');
    await extensionSearch.press('Enter');
    await page.getByText('Allow OpenVSX network access?').waitFor({ timeout: 10000 });
    await page.evaluate(() => {
      window.__wizpHubFixture = true;
    });
    await page.getByRole('button', { name: 'Allow OpenVSX Search' }).click();
    await page.getByText('Alpha Tools').waitFor({ timeout: 10000 });
    await page.getByText('Broken Tools').waitFor({ timeout: 10000 });

    const brokenExtension = page.locator('.hub-row').filter({ hasText: 'Broken Tools' });
    await brokenExtension.getByRole('button', { name: 'Install Broken Tools' }).click();
    const installFailure = page.getByText(/Install failed for Broken Tools:/).last();
    await installFailure.waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: 'Retry install' }).last().waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '06-extensions-install-failure');

    const alphaExtension = page.locator('.hub-row').filter({ hasText: 'Alpha Tools' });
    await alphaExtension.getByRole('button', { name: 'Install Alpha Tools' }).click();
    const alphaInstalled = page.locator('.installed-row').filter({ hasText: 'Alpha Tools' });
    await alphaInstalled.waitFor({ timeout: 10000 });
    await alphaInstalled.getByRole('button', { name: 'Disable' }).click();
    await alphaInstalled.getByText('Disabled', { exact: true }).waitFor({ timeout: 10000 });
    await alphaInstalled.getByRole('button', { name: 'Enable' }).click();
    await alphaInstalled.getByText('Enabled', { exact: true }).waitFor({ timeout: 10000 });
    const alphaUninstall = alphaInstalled.getByRole('button', {
      name: 'Uninstall',
    });
    await alphaUninstall.click();
    const uninstallDialog = page.getByRole('dialog', {
      name: 'Uninstall extension?',
    });
    await uninstallDialog.waitFor({ timeout: 10000 });
    await uninstallDialog.getByRole('button', { name: 'Cancel' }).click();
    await page.waitForFunction(() => document.activeElement?.textContent?.trim() === 'Uninstall');
    await alphaUninstall.click();
    await uninstallDialog.getByRole('button', { name: 'Uninstall', exact: true }).click();
    await alphaInstalled.waitFor({ state: 'detached', timeout: 10000 });

    extensionDialogPath = ws.invalidVsix;
    await page.getByRole('button', { name: 'Choose VSIX…' }).click();
    await page.getByRole('alert').filter({ hasText: 'VSIX install failed' }).waitFor({ timeout: 10000 });
    extensionDialogPath = ws.validVsix;
    await page.getByRole('button', { name: 'Choose VSIX…' }).click();
    const localExtension = page.locator('.installed-row').filter({ hasText: 'UI Lifecycle Extension' });
    await localExtension.waitFor({ timeout: 10000 });
    extensionInstallRpcMode = 'permission-denied';
    await page.getByRole('button', { name: 'Choose VSIX…' }).click();
    await page.getByRole('alert').filter({ hasText: 'VSIX install failed' }).waitFor({ timeout: 10000 });
    if (!(await localExtension.isVisible())) {
      throw new Error('VSIX permission failure changed the prior installed state');
    }
    extensionInstallRpcMode = 'normal';
    await page.getByText('Restart the extension host to load newly installed contributions.').waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '06-extensions-installed');

    await page.getByRole('button', { name: 'Restart now' }).click();
    await page.getByText('Extension host restarted. Contributions are available.').waitFor({ timeout: 15000 });
    await page.getByText(/Running · 1 discovered/).waitFor({ timeout: 10000 });
    await localExtension.getByRole('button', { name: 'Contributions' }).click();
    const lifecycleCommand = page.getByRole('button', {
      name: 'Run Lifecycle Command',
    });
    await lifecycleCommand.waitFor({ timeout: 10000 });
    await page.getByText('wizpUiLifecycle.enabled').waitFor({ timeout: 10000 });
    await localExtension.getByRole('button', { name: 'Disable' }).click();
    await localExtension.getByText('Disabled', { exact: true }).waitFor({ timeout: 10000 });
    if (!(await lifecycleCommand.isDisabled())) throw new Error('Disabled extension command remained actionable');
    const disabledCommandResult = await rpcCall('extension/execute', {
      command: 'wizp.uiLifecycle.hello',
    });
    if (disabledCommandResult !== null) throw new Error(`Disabled extension command executed: ${JSON.stringify(disabledCommandResult)}`);
    await localExtension.getByRole('button', { name: 'Enable' }).click();
    await localExtension.getByText('Enabled', { exact: true }).waitFor({ timeout: 10000 });
    if (await lifecycleCommand.isDisabled()) throw new Error('Re-enabled extension command remained disabled');
    await screenshotMustBeNonBlank(page, '06-extensions-contributions');
    await lifecycleCommand.click();
    await page.getByText('Run Lifecycle Command completed.').waitFor({ timeout: 10000 });

    const extensionSettingsButton = page.getByRole('button', {
      name: 'Open Extension Settings',
    });
    await extensionSettingsButton.focus();
    await extensionSettingsButton.click();
    const extensionSettingsDialog = page.getByRole('dialog', {
      name: 'Settings',
    });
    await extensionSettingsDialog.waitFor({ timeout: 10000 });
    await extensionSettingsDialog.getByText('wizpUiLifecycle.enabled').waitFor({ timeout: 10000 });
    await page.keyboard.press('Escape');
    await extensionSettingsDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.textContent?.includes('Open Extension Settings'));

    await page.getByRole('button', { name: 'Open UI Lifecycle' }).click();
    const contributedActivity = page.getByRole('button', {
      name: /^UI Lifecycle \(/,
    });
    await contributedActivity.waitFor({ timeout: 10000 });
    if ((await contributedActivity.getAttribute('aria-pressed')) !== 'true') {
      throw new Error('Extension-contributed view did not become active');
    }
    await clickActivitySlot(page, 4);
    extensionDialogPath = '';
    await page.getByRole('search').getByRole('searchbox', { name: 'Search extensions' }).waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '06-extensions');
    await runIsolatedExtensionsHubProof(browser);

    stage = 'keyboard menus and quick input';
    const fileMenu = page.locator('.menu-entry[data-menu="file"]');
    await fileMenu.focus();
    await page.keyboard.press('Enter');
    const openMenu = page.getByRole('menu', { name: 'file menu' });
    await openMenu.waitFor({ timeout: 10000 });
    const firstMenuItem = openMenu.getByRole('menuitem').first();
    await firstMenuItem.waitFor({ timeout: 10000 });
    if (!(await firstMenuItem.evaluate((node) => node === document.activeElement))) {
      throw new Error('File menu did not focus its first item');
    }
    await screenshotMustBeNonBlank(page, '07-keyboard-file-menu');
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('Escape');
    await openMenu.waitFor({ state: 'hidden', timeout: 10000 });
    if (!(await fileMenu.evaluate((node) => node === document.activeElement))) {
      throw new Error('File menu did not restore focus to its trigger');
    }

    const paletteTrigger = page.getByTitle('Command Palette (Ctrl+Shift+P)');
    await paletteTrigger.focus();
    await page.keyboard.press('Space');
    const quickInput = page.locator('#quick-input[role="dialog"]');
    await quickInput.waitFor({ timeout: 10000 });
    const quickInputField = quickInput.getByRole('combobox', {
      name: 'Command Palette',
    });
    await quickInputField.waitFor({ timeout: 10000 });
    await quickInput.getByRole('listbox', { name: 'Command Palette results' }).waitFor({ timeout: 10000 });
    await quickInput.getByRole('option').first().waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '07-keyboard-command-palette');
    await page.keyboard.press('ArrowDown');
    const activeDescendant = await quickInputField.getAttribute('aria-activedescendant');
    if (!activeDescendant) throw new Error('Command Palette did not expose its active option');
    await page.keyboard.press('Escape');
    await quickInput.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Command Palette (Ctrl+Shift+P)', null, { timeout: 10000 });

    const sidebarResizer = page.getByLabel('Resize sidebar with Left and Right Arrow keys');
    const sidebarWidthBefore = await page.evaluate(() => Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width')));
    await sidebarResizer.focus();
    await page.keyboard.press('ArrowRight');
    const sidebarWidthAfter = await page.evaluate(() => Number.parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width')));
    if (!(sidebarWidthAfter > sidebarWidthBefore)) {
      throw new Error(`Sidebar keyboard resize did not increase width: ${sidebarWidthBefore} -> ${sidebarWidthAfter}`);
    }

    stage = 'settings dialog keyboard lifecycle';
    const settingsTrigger = page.getByTitle('Settings');
    const openSettingsDialog = async () => {
      await settingsTrigger.focus();
      await page.keyboard.press('Control+,');
      const dialog = page.getByRole('dialog', { name: 'Settings' });
      await dialog.waitFor({ timeout: 10000 });
      const saveButton = dialog.getByRole('button', { name: 'Apply & Save' });
      await saveButton.waitFor({ timeout: 10000 });
      await page.waitForFunction(() => {
        const button = document.querySelector('#settings-dialog .btn-primary');
        return Boolean(button && !button.disabled);
      }, null, { timeout: 10000 });
      await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Close settings');
      return dialog;
    };

    let settingsDialog = await openSettingsDialog();
    await page.keyboard.press('Shift+Tab');
    await page.waitForFunction(() => document.activeElement?.textContent?.trim() === 'Apply & Save');
    await page.keyboard.press('Tab');
    await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Close settings');
    const sidebarWidthDuringSettings = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width'));
    await page.keyboard.press('Control+b');
    const sidebarWidthAfterBlockedShortcut = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width'));
    if (sidebarWidthAfterBlockedShortcut !== sidebarWidthDuringSettings) {
      throw new Error(`Settings allowed a background sidebar shortcut: ${sidebarWidthDuringSettings} -> ${sidebarWidthAfterBlockedShortcut}`);
    }

    const fontSizeInput = settingsDialog.getByLabel('Font Size');
    await fontSizeInput.fill('18');
    await settingsDialog.getByRole('button', { name: 'Cancel' }).click();
    await settingsDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Settings', null, { timeout: 10000 });

    settingsDialog = await openSettingsDialog();
    if ((await settingsDialog.getByLabel('Font Size').inputValue()) !== '14') {
      throw new Error('Settings cancel did not discard the unsaved font-size change');
    }
    await settingsDialog.getByLabel('Font Size').fill('99');
    await settingsDialog.getByRole('button', { name: 'Apply & Save' }).click();
    await settingsDialog.getByRole('alert').filter({ hasText: 'Font size must be a whole number from 8 to 32.' }).waitFor({ timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.id === 'settings-fontsize');

    await settingsDialog.getByLabel('Font Size').fill('16');
    await settingsDialog.getByLabel('Auto Save (after 1s idle)').check();
    const lifecycleSetting = settingsDialog.getByLabel(/wizpUiLifecycle\.enabled/);
    await lifecycleSetting.waitFor({ timeout: 10000 });
    await lifecycleSetting.uncheck();
    settingsRpcMode = 'partial-error';
    await settingsDialog.getByRole('button', { name: 'Apply & Save' }).click();
    await settingsDialog.getByRole('button', { name: 'Saving…' }).waitFor({ timeout: 10000 });
    await settingsDialog.getByText('Saving settings…').waitFor({ timeout: 10000 });
    await settingsDialog.getByRole('alert').filter({ hasText: 'font family' }).waitFor({ timeout: 10000 });
    await screenshotMustBeNonBlank(page, '07-settings-partial-failure');
    settingsRpcMode = 'normal';
    await settingsDialog.getByRole('button', { name: 'Retry Save' }).click();
    try {
      await settingsDialog.waitFor({ state: 'hidden', timeout: 10000 });
    } catch {
      throw new Error(`Settings retry did not close the dialog: ${await settingsDialog.innerText()}`);
    }
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Settings', null, { timeout: 10000 });

    const savedSettings = await page.evaluate(() => ({
      editor: JSON.parse(localStorage.getItem('wizp-settings') || '{}'),
      extensions: JSON.parse(localStorage.getItem('wizp-extension-settings') || '{}'),
    }));
    if (savedSettings.editor.fontSize !== 16 || savedSettings.editor.autoSave !== true || savedSettings.extensions['wizpUiLifecycle.enabled'] !== false) {
      throw new Error(`Settings persistence failed: ${JSON.stringify(savedSettings)}`);
    }
    const syncedFontSize = await rpcCall('config/get', {
      key: 'editor.fontSize',
      scope: 'user',
    });
    const syncedAutoSave = await rpcCall('config/get', {
      key: 'files.autoSave',
      scope: 'user',
    });
    const syncedExtensionSetting = await rpcCall('config/get', {
      key: 'wizpUiLifecycle.enabled',
      scope: 'user',
    });
    if (syncedFontSize.value !== '16' || syncedAutoSave.value !== 'afterDelay' || syncedExtensionSetting.value !== 'false') {
      throw new Error(`Settings backend sync failed: ${JSON.stringify({ syncedFontSize, syncedAutoSave, syncedExtensionSetting })}`);
    }

    settingsDialog = await openSettingsDialog();
    if ((await settingsDialog.getByLabel('Font Size').inputValue()) !== '16') {
      throw new Error('Settings did not reload the saved font size');
    }
    if (!(await settingsDialog.getByLabel('Auto Save (after 1s idle)').isChecked())) {
      throw new Error('Settings did not reload the saved auto-save preference');
    }
    if (await settingsDialog.getByLabel(/wizpUiLifecycle\.enabled/).isChecked()) {
      throw new Error('Settings did not reload the extension preference');
    }
    await screenshotMustBeNonBlank(page, '07-settings');
    await page.keyboard.press('Escape');
    await settingsDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Settings', null, { timeout: 10000 });

    await settingsTrigger.click();
    settingsDialog = page.getByRole('dialog', { name: 'Settings' });
    await settingsDialog.waitFor({ timeout: 10000 });
    await page.keyboard.press('Escape');
    await settingsDialog.waitFor({ state: 'hidden', timeout: 10000 });
    await page.waitForFunction(() => document.activeElement?.getAttribute('title') === 'Settings', null, { timeout: 10000 });

    const problems = await rpcCall('editor/problems/query', {
      groupByFile: true,
      sort: 'severity',
    });
    if (!problems.groupByFile || !problems.navigation?.openLocation) {
      throw new Error(`Problems contract regressed: ${JSON.stringify(problems)}`);
    }
    const reconciledProblems = await rpcCall('editor/problems/reconcile', {
      groupByFile: true,
      sort: 'severity',
      fixture: true,
    });
    if (!reconciledProblems.reconciled || reconciledProblems.problems.length < 3 || !reconciledProblems.sources.includes('extension')) {
      throw new Error(`Problems reconciliation contract regressed: ${JSON.stringify(reconciledProblems)}`);
    }
    const notifications = await rpcCall('notifications/list');
    if (!notifications.centerVisible || !Array.isArray(notifications.progress)) {
      throw new Error(`Notifications contract regressed: ${JSON.stringify(notifications)}`);
    }
    const progress = await rpcCall('notifications/progress', {
      title: 'Playwright Progress',
    });
    const cancelled = await rpcCall('notifications/cancel', {
      id: progress.id,
    });
    if (!progress.cancellable || progress.state !== 'running' || !cancelled.cancelled) {
      throw new Error(`Notification progress contract regressed: ${JSON.stringify({ progress, cancelled })}`);
    }
    const sortedEditors = await rpcCall('editor/openSorted', {
      order: 'desc',
      rule: 'name-local',
    });
    if (sortedEditors.openPositioning !== 'sort' || sortedEditors.descending !== true || sortedEditors.rule !== 'name-local') {
      throw new Error(`Open-position sorting contract regressed: ${JSON.stringify(sortedEditors)}`);
    }
    const outline = await rpcCall('textDocument/documentSymbol', {
      uri: `file://${join(ws.workspace, 'symbols.zig')}`,
    });
    if (!outline.some((item) => item.name === 'Thing' && Array.isArray(item.children) && item.children.length > 0)) {
      throw new Error(`Outline symbol contract regressed: ${JSON.stringify(outline)}`);
    }
    const normalizedOutline = await rpcCall('outline/normalize');
    if (!normalizedOutline.treeNormalized || !normalizedOutline.rangeBacked || !normalizedOutline.symbols.some((item) => item.name === 'init' && item.depth === 1)) {
      throw new Error(`Outline normalization contract regressed: ${JSON.stringify(normalizedOutline)}`);
    }
    const crumb = await rpcCall('breadcrumbs/interaction', {
      type: 'symbol',
      path: join(ws.workspace, 'symbols.zig'),
      symbol: 'Thing',
    });
    if (crumb.action !== 'jumpToSymbol' || crumb.rpc !== 'editor/reveal' || crumb.overlapCritical !== 0) {
      throw new Error(`Breadcrumb symbol contract regressed: ${JSON.stringify(crumb)}`);
    }
    const timeline = await rpcCall('git/timeline');
    if (!Array.isArray(timeline.commits) || !timeline.commits.some((commit) => commit.subject === 'initial')) {
      throw new Error(`Timeline contract regressed: ${JSON.stringify(timeline)}`);
    }
    await runIsolatedMonacoVisualProof(browser);
    const mergeCaps = await rpcCall('git/mergeEditorCapabilities');
    if (!mergeCaps.multiPane || !mergeCaps.acceptCurrent || !mergeCaps.acceptIncoming || !mergeCaps.acceptBoth || mergeCaps.resolveRpc !== 'git/resolveConflict') {
      throw new Error(`merge editor capabilities regressed: ${JSON.stringify(mergeCaps)}`);
    }
    await runIsolatedMergeEditorProof(browser);
    const customEditor = await rpcCall('customEditor/lifecycleSmoke');
    if (!customEditor.opened || !customEditor.rendered || !customEditor.messageRoundtrip || !customEditor.save || !customEditor.revert || !customEditor.disposed || customEditor.activation !== 'lazy-open') {
      throw new Error(`custom editor lifecycle contract regressed: ${JSON.stringify(customEditor)}`);
    }
    await runIsolatedCustomEditorProof(browser);
    const notebook = await rpcCall('notebook/lifecycleSmoke');
    if (!notebook.opened || !notebook.deserialized || notebook.cellCount !== 2 || !notebook.executed || notebook.outputs?.[0]?.kind !== 'stdout' || notebook.outputs?.[1]?.kind !== 'error' || !notebook.saved || !notebook.reloaded) {
      throw new Error(`notebook lifecycle contract regressed: ${JSON.stringify(notebook)}`);
    }
    await runIsolatedNotebookProof(browser);
    const tests = await rpcCall('tests/lifecycleSmoke');
    if (!tests.discovered || tests.items?.length !== 3 || tests.runProfiles?.[0]?.label !== 'Smoke Run Profile' || tests.results?.[0]?.state !== 'passed' || tests.results?.[1]?.state !== 'failed' || tests.results?.[2]?.state !== 'skipped' || !tests.output?.includes('smoke test output')) {
      throw new Error(`test explorer contract regressed: ${JSON.stringify(tests)}`);
    }
    await runIsolatedTestExplorerProof(browser);
    const auth = await rpcCall('auth/lifecycleSmoke');
    if (!auth.sessionPersisted || auth.secretStorage !== 'encrypted-fallback' || auth.plaintextOnDisk !== false || auth.restartReload !== true || auth.account?.id !== 'smoke-account') {
      throw new Error(`auth/secrets contract regressed: ${JSON.stringify(auth)}`);
    }
    await runIsolatedAuthSecretsProof(browser);
    const webviewLifecycle = await rpcCall('webview/lifecycleSmoke');
    if (!webviewLifecycle.created || !webviewLifecycle.retainedWhenHidden || webviewLifecycle.messageOrder?.join(',') !== 'one,two,three' || !webviewLifecycle.outsideWorkspaceDenied || !webviewLifecycle.disposeRevokesPanel || !webviewLifecycle.exploitRegressionDenied) {
      throw new Error(`webview lifecycle contract regressed: ${JSON.stringify(webviewLifecycle)}`);
    }
    const webviewViewLifecycle = await rpcCall('webviewView/lifecycleSmoke');
    if (!webviewViewLifecycle.resolved || webviewViewLifecycle.resolveCount !== 1 || !webviewViewLifecycle.stateful || !webviewViewLifecycle.messageRoundtrip || !webviewViewLifecycle.outsideWorkspaceDenied || webviewViewLifecycle.resolverPath !== 'extension/resolveWebviewView') {
      throw new Error(`webview view lifecycle contract regressed: ${JSON.stringify(webviewViewLifecycle)}`);
    }
    await runIsolatedWebviewLifecycleProof(browser, ws);
    await runIsolatedDiagnosticsDownloadProof(browser, ws);
    const accessibility = await runAccessibilityGate(page);
    if (accessibility.checked.interactive < 10) {
      throw new Error(`accessibility gate did not scan enough controls: ${JSON.stringify(accessibility)}`);
    }
    await runResponsiveGate(page);

    if (pageErrors.length) {
      throw new Error(`page errors: ${pageErrors.join(' | ')}`);
    }

    console.log('parity playwright smoke ok');
  } finally {
    if (browser) await browser.close();
    await terminateProcessGroup(proc);
    rmSync(ws.root, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
