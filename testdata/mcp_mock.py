#!/usr/bin/env python3
"""Minimal line-delimited MCP initialize responder for integration tests."""

import json
import sys

for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    if request.get("method") == "initialize":
        response = {
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "serverInfo": {"name": "wizp-mcp-mock", "version": "1.0"},
                "capabilities": {},
            },
        }
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
