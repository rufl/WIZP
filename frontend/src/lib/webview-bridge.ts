const HOST_FLAG = '__wizpWebviewHost';
const CLIENT_FLAG = '__wizpWebviewClient';

function injectIntoHtml(html: string, injection: string): string {
  const headMatch = html.match(/<head[^>]*>/i);
  if (headMatch && headMatch.index !== undefined) {
    const insertAt = headMatch.index + headMatch[0].length;
    return `${html.slice(0, insertAt)}${injection}${html.slice(insertAt)}`;
  }

  const bodyMatch = html.match(/<body[^>]*>/i);
  if (bodyMatch && bodyMatch.index !== undefined) {
    const insertAt = bodyMatch.index + bodyMatch[0].length;
    return `${html.slice(0, insertAt)}${injection}${html.slice(insertAt)}`;
  }

  return `${injection}${html}`;
}

export function decorateWebviewHtml(id: string, html: string): string {
  const bootstrap = `<script>
(function () {
  const WEBVIEW_ID = ${JSON.stringify(id)};
  if (window.__wizpAcquireVsCodeApiFor === WEBVIEW_ID) return;
  let state = null;
  const vscodeApi = Object.freeze({
    postMessage(message) {
      window.parent.postMessage({ ${CLIENT_FLAG}: true, id: WEBVIEW_ID, message: message }, '*');
      return Promise.resolve(true);
    },
    setState(value) {
      state = value;
      return value;
    },
    getState() {
      return state;
    }
  });
  window.__wizpAcquireVsCodeApiFor = WEBVIEW_ID;
  window.acquireVsCodeApi = function () {
    return vscodeApi;
  };
  window.addEventListener('message', function (event) {
    const payload = event && event.data;
    if (!payload || payload.${HOST_FLAG} !== true || payload.id !== WEBVIEW_ID) return;
    window.dispatchEvent(new MessageEvent('message', { data: payload.message }));
  });
}());
</script>`;

  return injectIntoHtml(html || '<!doctype html><html><body></body></html>', bootstrap);
}

export function postHostMessageToWebview(
  iframe: HTMLIFrameElement | null | undefined,
  id: string,
  message: any,
): boolean {
  const target = iframe?.contentWindow;
  if (!target) return false;
  target.postMessage({ [HOST_FLAG]: true, id, message }, '*');
  return true;
}

export function unwrapWebviewClientMessage(
  event: MessageEvent,
): { id: string; message: any } | null {
  const payload = event?.data;
  if (!payload || typeof payload !== 'object' || payload[CLIENT_FLAG] !== true) return null;
  if (typeof payload.id !== 'string') return null;
  return { id: payload.id, message: payload.message };
}

export function normalizeWebviewMessagePayload(message: any): any {
  if (
    message &&
    typeof message === 'object' &&
    message.type === 'from-extension' &&
    Object.prototype.hasOwnProperty.call(message, 'message')
  ) {
    return message.message;
  }
  return message;
}
