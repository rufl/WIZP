#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { chromium, firefox } from 'playwright';

function argValue(name, fallback = '') {
  const index = process.argv.indexOf(name);
  if (index >= 0 && index + 1 < process.argv.length) return process.argv[index + 1];
  return fallback;
}

function normalizeText(value) {
  if (value === undefined || value === null) return '';
  return String(value);
}

const baseUrl = argValue('--base-url');
const resultPath = argValue('--result');
const screenshotPath = argValue('--screenshot-path');
const timeoutMs = Number(argValue('--timeout-ms', '9000')) || 9000;
const settleMs = Number(argValue('--settle-ms', '1200')) || 1200;
const navTimeoutMs = Number(argValue('--nav-timeout-ms', String(Math.min(timeoutMs, 8000)))) || Math.min(timeoutMs, 8000);
const viewport = {
  width: Number(argValue('--viewport-width', '1280')) || 1280,
  height: Number(argValue('--viewport-height', '900')) || 900,
};
let viewIds = [];
let seedUiEvents = [];
try {
  const parsed = JSON.parse(argValue('--view-ids', '[]'));
  if (Array.isArray(parsed)) viewIds = parsed.map((value) => normalizeText(value)).filter(Boolean);
} catch {
  viewIds = [];
}
try {
  const parsed = JSON.parse(argValue('--seed-ui-events', '[]'));
  if (Array.isArray(parsed)) seedUiEvents = parsed.filter((value) => value && typeof value === 'object');
} catch {
  seedUiEvents = [];
}

const startedAt = Date.now();
const perViewBudgetMs =
  viewIds.length > 0
    ? Math.max(500, Math.min(2000, Math.floor(timeoutMs / Math.max(viewIds.length * 2, 2))))
    : Math.max(500, Math.min(1500, settleMs));
const result = {
  status: 'started',
  baseUrl,
  viewIds,
  timings: {},
  uiEvents: [],
  pollResponseCount: 0,
  uiEventCount: 0,
  console: [],
  pageErrors: [],
  requestFailures: [],
  webviewResponses: [],
  switchedViews: [],
  iframes: [],
  screenshots: [],
  viewport,
  warnings: [],
};

function finish() {
  result.uiEventCount = Array.isArray(result.uiEvents) ? result.uiEvents.length : 0;
  result.timings.totalMs = Date.now() - startedAt;
  if (resultPath) {
    fs.writeFileSync(resultPath, JSON.stringify(result, null, 2));
  } else {
    process.stdout.write(JSON.stringify(result, null, 2));
  }
}

let browser;

function iframeTitleForId(id) {
  if (id.startsWith('webviewView:')) {
    return `${id.split(':', 2)[1]} webview`;
  }
  return `${id} webview`;
}

function relativePathForReport(filePath) {
  try {
    return path.relative(process.cwd(), filePath) || filePath;
  } catch {
    return filePath;
  }
}

async function captureScreenshot(page, label) {
  if (!screenshotPath) return;
  try {
    fs.mkdirSync(path.dirname(screenshotPath), { recursive: true });
    const buffer = await page.screenshot({ path: screenshotPath, fullPage: false, type: 'png' });
    const byteLength = buffer && typeof buffer.length === 'number' ? buffer.length : fs.statSync(screenshotPath).size;
    const record = {
      label,
      path: relativePathForReport(screenshotPath),
      byteLength,
      status: byteLength > 0 ? 'captured' : 'empty',
      viewport,
    };
    result.screenshots.push(record);
    result.screenshot = record;
  } catch (error) {
    const record = {
      label,
      path: relativePathForReport(screenshotPath),
      status: 'capture-error',
      error: normalizeText(error),
      viewport,
    };
    result.screenshots.push(record);
    result.screenshot = record;
    result.warnings.push(`screenshot-capture-error: ${normalizeText(error)}`);
  }
}

try {
  const launchAttempts = [];
  const browserCandidates = [
    {
      name: 'playwright-chromium',
      launch: () => chromium.launch({ headless: true }),
    },
    {
      name: 'system-chrome',
      executablePath: [
        '/usr/bin/google-chrome-stable',
        '/usr/bin/google-chrome',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
      ].find((candidate) => fs.existsSync(candidate)),
      launch() {
        if (!this.executablePath) throw new Error('system chrome executable not found');
        return chromium.launch({
          headless: true,
          executablePath: this.executablePath,
          args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
        });
      },
    },
    {
      name: 'system-firefox',
      executablePath: ['/usr/bin/firefox', '/bin/firefox'].find((candidate) => fs.existsSync(candidate)),
      launch() {
        if (!this.executablePath) throw new Error('system firefox executable not found');
        return firefox.launch({ headless: true, executablePath: this.executablePath });
      },
    },
  ];
  let launchError = null;
  for (const candidate of browserCandidates) {
    try {
      browser = await candidate.launch();
      result.browserEngine = candidate.name;
      if (candidate.executablePath) result.browserExecutable = candidate.executablePath;
      break;
    } catch (error) {
      launchAttempts.push({
        candidate: candidate.name,
        executablePath: candidate.executablePath || '',
        error: normalizeText(error),
      });
      launchError = error;
    }
  }
  result.launchAttempts = launchAttempts;
  if (!browser) throw launchError || new Error('no browser candidate launched');
  const page = await browser.newPage({ viewport });

  page.on('console', (msg) => {
    result.console.push({
      type: msg.type(),
      text: msg.text(),
    });
  });

  page.on('pageerror', (error) => {
    result.pageErrors.push({
      message: normalizeText(error && error.message),
      stack: normalizeText(error && error.stack),
    });
  });

  page.on('requestfailed', (request) => {
    result.requestFailures.push({
      url: request.url(),
      method: request.method(),
      failure: normalizeText(request.failure() && request.failure().errorText),
    });
  });

  page.on('response', async (response) => {
    const url = response.url();
    if (url.includes('/api/extension/ui/poll')) {
      result.pollResponseCount += 1;
      try {
        const body = await response.text();
        const payload = JSON.parse(body);
        if (Array.isArray(payload) && payload.length > 0) {
          result.uiEvents.push(...payload);
        }
      } catch (error) {
        result.warnings.push(`ui-poll-parse-error: ${normalizeText(error)}`);
      }
      return;
    }
    if (url.includes('/api/extension/webview/html') || url.includes('/api/webview-resource')) {
      try {
        const text = await response.text();
        result.webviewResponses.push({
          url,
          status: response.status(),
          contentType: response.headers()['content-type'] || '',
          snippet: text.slice(0, 1200),
        });
      } catch (error) {
        result.webviewResponses.push({
          url,
          status: response.status(),
          contentType: response.headers()['content-type'] || '',
          error: normalizeText(error),
        });
      }
    }
  });

  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: navTimeoutMs });
  result.timings.gotoMs = Date.now() - startedAt;

  try {
    await page.waitForFunction(
      () =>
        typeof window.__switchSidebarView === 'function' &&
        typeof window.__focusWebviewPanel === 'function' &&
        typeof window.__seedWebviewPanelForProbe === 'function' &&
        typeof window.__fetchWebviewPanelsForProbe === 'function',
      {
      timeout: Math.min(6000, timeoutMs),
      },
    );
  } catch {
    result.warnings.push(
      'window.__switchSidebarView, window.__focusWebviewPanel, window.__seedWebviewPanelForProbe, and window.__fetchWebviewPanelsForProbe did not become available before timeout',
    );
  }

  await page.waitForTimeout(250);

  if (seedUiEvents.length > 0) {
    result.seedDispatch = await page.evaluate(async (events) => {
      const pendingMessages = (window.__wizpPendingWebviewMessages ||= {});
      const snapshot = () => {
        const activeGroupId =
          typeof window.__getActiveGroupId === 'function' ? window.__getActiveGroupId() : null;
        const activeGroup =
          activeGroupId && typeof window.__getGroup === 'function'
            ? window.__getGroup(activeGroupId)
            : null;
        return {
          activeGroupId,
          iframeCount: document.querySelectorAll('iframe').length,
          domGroupIds: Array.from(document.querySelectorAll('[data-group-id]')).map((node) =>
            node.getAttribute('data-group-id') || '',
          ),
          activeGroupEditorCount: Array.isArray(activeGroup?.editors) ? activeGroup.editors.length : 0,
        };
      };
      const seeded = [];
      for (const item of Array.isArray(events) ? events : []) {
        if (!item || typeof item !== 'object') continue;
        if (item.type === 'webviewPanelCreated') {
          await window.__seedWebviewPanelForProbe?.(item);
          seeded.push({ type: item.type, id: item.id, state: snapshot() });
        } else if (item.type === 'webviewPanelUpdated') {
          await window.__seedWebviewPanelForProbe?.(item);
          seeded.push({ type: item.type, id: item.id, state: snapshot() });
        } else if (item.type === 'webviewPanelReveal') {
          await window.__seedWebviewPanelForProbe?.(item);
          seeded.push({ type: item.type, id: item.id, state: snapshot() });
        } else if (item.type === 'webviewPanelDisposed') {
          window.dispatchEvent(new CustomEvent('wizpWebviewPanelDisposed', { detail: item }));
          seeded.push({ type: item.type, id: item.id, state: snapshot() });
        } else if (item.type === 'webviewRegistered') {
          window.dispatchEvent(new CustomEvent('wizpWebviewRegistered', { detail: item.id }));
          seeded.push({ type: item.type, id: item.id, state: snapshot() });
        } else if (item.type === 'webviewPostMessage') {
          const id = item.id === undefined || item.id === null ? '' : String(item.id);
          if (!id) continue;
          const queue = Array.isArray(pendingMessages[id]) ? pendingMessages[id] : (pendingMessages[id] = []);
          queue.push(item.message);
          window.dispatchEvent(
            new CustomEvent('wizpWebviewPostMessage', {
              detail: { id, message: item.message },
            }),
          );
          seeded.push({ type: item.type, id, state: snapshot() });
        }
      }
      return seeded;
    }, seedUiEvents);
    result.seedUiEventCount = seedUiEvents.length;
    await page.waitForTimeout(Math.min(600, Math.max(150, Math.floor(settleMs / 2))));
  }

  result.durablePanelSnapshot = await page.evaluate(async () => {
    const snapshot = () => {
      const activeGroupId =
        typeof window.__getActiveGroupId === 'function' ? window.__getActiveGroupId() : null;
      const activeGroup =
        activeGroupId && typeof window.__getGroup === 'function'
          ? window.__getGroup(activeGroupId)
          : null;
      return {
        activeGroupId,
        iframeCount: document.querySelectorAll('iframe').length,
        domGroupIds: Array.from(document.querySelectorAll('[data-group-id]')).map((node) =>
          node.getAttribute('data-group-id') || '',
        ),
        activeGroupEditorCount: Array.isArray(activeGroup?.editors) ? activeGroup.editors.length : 0,
      };
    };
    if (typeof window.__fetchWebviewPanelsForProbe !== 'function') {
      return { status: 'helper-missing', panels: [], state: snapshot() };
    }
    try {
      const panels = await window.__fetchWebviewPanelsForProbe();
      return {
        status: 'ok',
        panelCount: Array.isArray(panels) ? panels.length : 0,
        panels: Array.isArray(panels) ? panels : [],
        state: snapshot(),
      };
    } catch (error) {
      return {
        status: 'error',
        error: normalizeText(error),
        panels: [],
        state: snapshot(),
      };
    }
  });

  const durablePanels = Array.isArray(result.durablePanelSnapshot?.panels)
    ? result.durablePanelSnapshot.panels.filter(
        (panel) => panel && typeof panel === 'object' && viewIds.includes(normalizeText(panel.id)),
      )
    : [];
  if (durablePanels.length > 0) {
    result.durableSeedDispatch = await page.evaluate(async (panels) => {
      const snapshot = () => {
        const activeGroupId =
          typeof window.__getActiveGroupId === 'function' ? window.__getActiveGroupId() : null;
        const activeGroup =
          activeGroupId && typeof window.__getGroup === 'function'
            ? window.__getGroup(activeGroupId)
            : null;
        return {
          activeGroupId,
          iframeCount: document.querySelectorAll('iframe').length,
          domGroupIds: Array.from(document.querySelectorAll('[data-group-id]')).map((node) =>
            node.getAttribute('data-group-id') || '',
          ),
          activeGroupEditorCount: Array.isArray(activeGroup?.editors) ? activeGroup.editors.length : 0,
        };
      };
      const seeded = [];
      for (const panel of Array.isArray(panels) ? panels : []) {
        if (!panel || typeof panel !== 'object' || !panel.id) continue;
        await window.__seedWebviewPanelForProbe?.(panel);
        seeded.push({ id: String(panel.id), title: String(panel.title || ''), state: snapshot() });
      }
      return seeded;
    }, durablePanels);
    await page.waitForTimeout(Math.min(600, Math.max(150, Math.floor(settleMs / 2))));
  }

  for (const viewId of viewIds) {
    const iframeTitle = iframeTitleForId(viewId);
    try {
      if (viewId.startsWith('webviewView:')) {
        const shortId = viewId.split(':', 2)[1];
        await page.evaluate((id) => {
          window.__switchSidebarView?.(`contributed:${id}`);
          window.dispatchEvent(new CustomEvent('wizpWebviewRegistered', { detail: id }));
        }, shortId);
      } else {
        await page.evaluate((id) => {
          window.__focusWebviewPanel?.(id);
          window.dispatchEvent(
            new CustomEvent('wizpWebviewPanelReveal', { detail: { id, preserveFocus: false } }),
          );
        }, viewId);
      }
      result.switchedViews.push({ id: viewId, status: 'requested' });
      try {
        await page.waitForSelector(`iframe[title="${iframeTitle}"]`, {
          timeout: perViewBudgetMs,
        });
        result.switchedViews[result.switchedViews.length - 1].status = 'iframe-visible';
      } catch {
        result.switchedViews[result.switchedViews.length - 1].status = 'iframe-not-visible';
      }
      await page.waitForTimeout(perViewBudgetMs);
    } catch (error) {
      result.switchedViews.push({ id: viewId, status: 'switch-error', error: normalizeText(error) });
    }
  }

  await page.waitForTimeout(Math.max(perViewBudgetMs, Math.min(settleMs, 1500)));

  result.iframes = await page.evaluate(() =>
    Array.from(document.querySelectorAll('iframe')).map((frame) => ({
      title: frame.getAttribute('title') || '',
      src: frame.getAttribute('src') || '',
    })),
  );
  result.sidebarSnapshot = await page.evaluate(() => ({
    headers: Array.from(document.querySelectorAll('.tree-header')).map((node) => node.textContent || ''),
    webviewContainers: document.querySelectorAll('.webview-container').length,
  }));
  result.dom = {
    title: await page.title(),
    url: page.url(),
    iframeCount: result.iframes.length,
  };
  await captureScreenshot(page, 'post-view-switch');
  result.status = 'frontend-webview-probe-captured';
} catch (error) {
  result.status = 'frontend-webview-probe-error';
  result.error = normalizeText(error);
  result.stack = normalizeText(error && error.stack);
} finally {
  if (browser) {
    await browser.close().catch(() => {});
  }
  finish();
}
