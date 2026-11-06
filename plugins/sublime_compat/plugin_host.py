#!/usr/bin/env python3
"""
Zedit Sublime Plugin Host
Loads and runs Sublime Text plugins in a subprocess, communicating
with Zedit via MCP JSON-RPC over stdin/stdout.
"""

import sys
import os
import json

# Add compat directory to path so plugins can import sublime/sublime_plugin
_compat_dir = os.path.dirname(os.path.abspath(__file__))
if _compat_dir not in sys.path:
    sys.path.insert(0, _compat_dir)

# Patch the sublime module's MCP bridge to use our stdin/stdout
import sublime as _sublime
import sublime_plugin as _splugin

def main():
    """Main loop: read MCP requests, dispatch to plugins, send responses."""
    plugin_dirs = sys.argv[1:] if len(sys.argv) > 1 else []

    # Load plugins from specified directories
    for plugin_dir in plugin_dirs:
        if os.path.isdir(plugin_dir):
            _splugin.load_plugins_from_dir(plugin_dir)
        elif os.path.isfile(plugin_dir) and plugin_dir.endswith(".py"):
            _splugin.load_plugin(plugin_dir)

    # Main MCP loop
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue

            msg = json.loads(line)
            response = handle_mcp_message(msg)
            if response is not None:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()

        except json.JSONDecodeError:
            continue
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Plugin host error: {e}", file=sys.stderr)


def handle_mcp_message(msg: dict) -> dict:
    """Handle an MCP JSON-RPC message."""
    msg_id = msg.get("id")
    method = msg.get("method", "")
    params = msg.get("params", {})

    result = dispatch_command(method, params)

    if msg_id is not None:
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": result
        }
    return None


def dispatch_command(method: str, params: dict):
    """Dispatch a command to the appropriate handler."""
    if method == "initialize":
        return {"capabilities": {"tools": {}, "resources": {}}}
    elif method == "wizp/run_text_command":
        return run_text_command(params)
    elif method == "wizp/run_window_command":
        return run_window_command(params)
    elif method == "wizp/run_app_command":
        return run_app_command(params)
    elif method == "wizp/notify_event":
        return notify_event_listeners(params)
    elif method == "shutdown":
        sys.exit(0)

    # Forward to sublime module MCP bridge
    return None


def run_text_command(params: dict):
    """Run a TextCommand from a loaded plugin."""
    cmd_name = params.get("command", "")
    view_id = params.get("view_id", 0)
    cmd_args = params.get("args", {})
    if isinstance(cmd_args, str):
        cmd_args = json.loads(cmd_args)

    cmd_class = _splugin._PluginRegistry.text_commands.get(cmd_name)
    if cmd_class is None:
        return {"error": f"Unknown text command: {cmd_name}"}

    view = _sublime.View(view_id)
    cmd = cmd_class(view)

    # Create edit token
    edit = _sublime.Edit(view_id)
    try:
        cmd.run_(edit.token, cmd_args)
    except Exception as e:
        return {"error": str(e)}

    return {"success": True}


def run_window_command(params: dict):
    """Run a WindowCommand from a loaded plugin."""
    cmd_name = params.get("command", "")
    window_id = params.get("window_id", 1)
    cmd_args = params.get("args", {})
    if isinstance(cmd_args, str):
        cmd_args = json.loads(cmd_args)

    cmd_class = _splugin._PluginRegistry.window_commands.get(cmd_name)
    if cmd_class is None:
        return {"error": f"Unknown window command: {cmd_name}"}

    window = _sublime.Window(window_id)
    cmd = cmd_class(window)
    try:
        cmd.run(**cmd_args)
    except Exception as e:
        return {"error": str(e)}

    return {"success": True}


def run_app_command(params: dict):
    """Run an ApplicationCommand from a loaded plugin."""
    cmd_name = params.get("command", "")
    cmd_args = params.get("args", {})
    if isinstance(cmd_args, str):
        cmd_args = json.loads(cmd_args)

    cmd_class = _splugin._PluginRegistry.app_commands.get(cmd_name)
    if cmd_class is None:
        return {"error": f"Unknown app command: {cmd_name}"}

    try:
        cmd = cmd_class()
        cmd.run(**cmd_args)
    except Exception as e:
        return {"error": str(e)}

    return {"success": True}


def notify_event_listeners(params: dict):
    """Notify all EventListeners of an event."""
    event_type = params.get("event", "")
    event_params = params.get("params", {})

    for listener_class in _splugin._PluginRegistry.event_listeners:
        try:
            listener = listener_class()
            handler = getattr(listener, event_type, None)
            if handler:
                handler(**event_params)
        except Exception:
            pass

    return {"success": True}


if __name__ == "__main__":
    main()
