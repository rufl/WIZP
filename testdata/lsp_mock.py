#!/usr/bin/env python3
"""Mock LSP server for WIZP integration tests.
Implements minimal LSP protocol over stdio with Content-Length headers."""

import sys
import json

def read_message():
    """Read an LSP message from stdin."""
    headers = {}
    while True:
        line = sys.stdin.readline().rstrip('\r\n')
        if not line:
            break
        if ':' in line:
            key, val = line.split(':', 1)
            headers[key.strip()] = val.strip()
    content_length = int(headers.get('Content-Length', 0))
    body = sys.stdin.read(content_length)
    return json.loads(body)

def send_message(msg):
    """Send an LSP message to stdout."""
    body = json.dumps(msg)
    header = f"Content-Length: {len(body)}\r\n\r\n"
    sys.stdout.write(header + body)
    sys.stdout.flush()

def main():
    # Wait for initialize request
    req = read_message()
    if req.get('method') == 'initialize':
        # Send initialize response
        send_message({
            "jsonrpc": "2.0",
            "id": req['id'],
            "result": {
                "capabilities": {
                    "textDocumentSync": 1,
                    "completionProvider": {"triggerCharacters": ["."]},
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "diagnosticProvider": {}
                },
                "serverInfo": {"name": "mock-lsp", "version": "1.0"}
            }
        })

    # Read initialized notification (discard)
    read_message()

    # Service loop
    while True:
        try:
            req = read_message()
        except (EOFError, SystemExit):
            break

        method = req.get('method', '')
        msg_id = req.get('id')

        if method == 'textDocument/completion':
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": [
                    {"label": "mockFunction", "kind": 3, "detail": "fn() void"},
                    {"label": "mockVariable", "kind": 6, "detail": "u32"},
                    {"label": "mockConstant", "kind": 14, "detail": "const"},
                ]
            })
        elif method == 'textDocument/hover':
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "contents": {"kind": "markdown", "value": "**mockFunction**\n\nMock function documentation."}
                }
            })
        elif method == 'textDocument/definition':
            params = req.get('params', {})
            pos = params.get('position', {})
            send_message({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "uri": params.get('textDocument', {}).get('uri', ''),
                    "range": {
                        "start": {"line": pos.get('line', 0), "character": 0},
                        "end": {"line": pos.get('line', 0), "character": 10}
                    }
                }
            })
        elif method == 'shutdown':
            send_message({"jsonrpc": "2.0", "id": msg_id, "result": None})
            break
        else:
            # Unknown method — respond with empty result
            if msg_id:
                send_message({"jsonrpc": "2.0", "id": msg_id, "result": None})

if __name__ == '__main__':
    main()
