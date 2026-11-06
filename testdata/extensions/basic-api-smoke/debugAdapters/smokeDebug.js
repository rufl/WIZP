#!/usr/bin/env node

let buffer = Buffer.alloc(0);
const outbound = [];
let flushing = false;

function send(message) {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  outbound.push(body);
  flushOutbound();
}

function flushOutbound() {
  if (flushing || outbound.length === 0) return;
  flushing = true;
  const body = outbound.shift();
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  setTimeout(() => {
    process.stdout.write(body);
    flushing = false;
    setTimeout(flushOutbound, 5);
  }, 5);
}

function response(request, body = {}) {
  send({
    type: 'response',
    success: true,
    command: request.method || request.command,
    request_seq: request.id || request.seq,
    body,
  });
}

function event(eventName, body = {}) {
  send({ type: 'event', event: eventName, body });
}

function handle(request) {
  const command = request.method || request.command;
  switch (command) {
    case 'initialize':
      response(request, {
        supportsConfigurationDoneRequest: true,
        supportsEvaluateForHovers: true,
        supportsSetVariable: true,
      });
      break;
    case 'launch':
      response(request, { launched: true, program: request.params?.program || 'smoke' });
      break;
    case 'configurationDone':
      event('initialized');
      event('output', { category: 'console', output: 'external adapter output\n' });
      event('stopped', { reason: 'breakpoint', threadId: 1, allThreadsStopped: true });
      break;
    case 'setExceptionBreakpoints':
      response(request, {
        breakpoints: (request.params?.filters || []).map((filter) => ({ verified: true, filter })),
      });
      break;
    case 'stackTrace':
      response(request, {
        stackFrames: [
          { id: 100, name: 'main', source: { name: 'main.zig', path: 'main.zig', sourceReference: 3001 }, line: 8, column: 3 },
        ],
        totalFrames: 1,
      });
      break;
    case 'scopes':
      response(request, {
        scopes: [{ name: 'Locals', variablesReference: 200, expensive: false }],
      });
      break;
    case 'variables':
      response(request, {
        variables: [
          { name: 'answer', value: '42', type: 'i32', variablesReference: 0 },
          { name: 'message', value: 'external debug smoke', type: 'string', variablesReference: 0 },
        ],
      });
      break;
    case 'evaluate':
      response(request, {
        result: request.params?.expression === 'answer' ? '42' : `external:${request.params?.expression || ''}`,
        type: 'string',
        variablesReference: 0,
      });
      break;
    case 'continue':
      response(request, { allThreadsContinued: true });
      break;
    case 'next':
    case 'stepIn':
    case 'stepOut':
    case 'pause':
      response(request, {});
      break;
    case 'disconnect':
      response(request, { shutdown: true });
      setTimeout(() => process.exit(0), 50);
      break;
    default:
      response(request, {});
      break;
  }
}

function drain() {
  while (true) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = buffer.subarray(0, headerEnd).toString('utf8');
    const match = /Content-Length:\s*(\d+)/i.exec(header);
    if (!match) {
      buffer = buffer.subarray(headerEnd + 4);
      continue;
    }
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const body = buffer.subarray(bodyStart, bodyEnd).toString('utf8');
    buffer = buffer.subarray(bodyEnd);
    handle(JSON.parse(body));
  }
}

process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  drain();
});
process.stdin.resume();
