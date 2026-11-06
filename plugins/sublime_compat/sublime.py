"""
sublime module compatibility shim for Zedit
Reimplements the Sublime Text Python API, proxying all operations
to Zedit via MCP JSON-RPC protocol.
"""

import sys
import os
import json
import threading
import time
import queue
import enum
from typing import Optional, List, Dict, Any, Callable, Tuple

# ============================================================
# MCP Bridge to Zedit
# ============================================================

class MCPBridge:
    """Communicates with Zedit via MCP JSON-RPC over stdio."""
    _instance = None
    _request_id = 0
    _pending = {}
    _lock = threading.Lock()
    _write_lock = threading.Lock()
    _reader_thread = None
    _running = False
    _event_queue = queue.Queue()

    def __init__(self):
        self._request_id = 0
        self._pending = {}
        self._running = True
        self._reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self._reader_thread.start()
        self._send_initialize()

    @classmethod
    def instance(cls):
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def _send_initialize(self):
        resp = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}, "resources": {}},
            "clientInfo": {"name": "zedit-sublime-plugin", "version": "1.0.0"}
        })
        if resp:
            self._notify("notifications/initialized", {})

    def _read_loop(self):
        """Read JSON-RPC responses and events from stdin."""
        while self._running:
            try:
                line = sys.stdin.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                msg = json.loads(line)
                if "id" in msg and msg["id"] is not None:
                    with self._lock:
                        rid = msg["id"]
                        if rid in self._pending:
                            self._pending[rid] = msg
                elif "method" in msg:
                    # Notification/event
                    self._event_queue.put(msg)
            except Exception:
                break

    def request(self, method: str, params: dict = None) -> Optional[dict]:
        """Send a JSON-RPC request and wait for response."""
        with self._lock:
            self._request_id += 1
            rid = self._request_id

        req = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            req["params"] = params

        with self._write_lock:
            sys.stdout.write(json.dumps(req) + "\n")
            sys.stdout.flush()

        # Wait for response (timeout after 5 seconds)
        deadline = time.time() + 5.0
        while time.time() < deadline:
            with self._lock:
                if rid in self._pending:
                    resp = self._pending.pop(rid)
                    if "error" in resp:
                        return None
                    return resp.get("result")
            time.sleep(0.01)
        return None

    def _notify(self, method: str, params: dict = None):
        """Send a notification (no response expected)."""
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        with self._write_lock:
            sys.stdout.write(json.dumps(msg) + "\n")
            sys.stdout.flush()

    def get_events(self) -> list:
        """Get queued events from Zedit."""
        events = []
        while not self._event_queue.empty():
            try:
                events.append(self._event_queue.get_nowait())
            except queue.Empty:
                break
        return events

    def shutdown(self):
        self._running = False
        self._notify("shutdown", {})


# ============================================================
# Sublime API Compatibility
# ============================================================

# Constants
HOVER_TEXT = 1
HOVER_GOTO = 2
HOVER_DYNAMIC = 3

ENCODED_POSITION = 1
TRANSIENT = 4
FORCE_GROUP = 8
IGNORECASE = 2
LITERAL = 1

MONOSPACE_FONT = 1
KEEP_OPEN_ON_FOCUS_LOST = 2
WANT_EVENT = 4

DIALOG_CANCEL = 0
DIALOG_YES = 1
DIALOG_NO = 2

HTML = 1
COOPERATE_WITH_AUTO_COMPLETE = 2
HIDE_ON_MOUSE_MOVE = 4
HIDE_ON_MOUSE_MOVE_AWAY = 8
KEEP_ON_SELECTION_MODIFIED = 16
HIDE_ON_CHARACTER_EVENT = 32

DRAW_EMPTY = 1
HIDE_ON_MINIMAP = 2
DRAW_EMPTY_AS_OVERWRITE = 4
DRAW_STIPPLED_UNDERLINE = 8
DRAW_SQUIGGLY_UNDERLINE = 16
PERSISTENT = 32
HIDDEN = 128

OP_EQUAL = 0
OP_NOT_EQUAL = 1
OP_REGEX_MATCH = 2
OP_NOT_REGEX_MATCH = 3
OP_REGEX_CONTAINS = 4
OP_NOT_REGEX_CONTAINS = 5

CLASS_WORD_START = 1
CLASS_WORD_END = 2
CLASS_PUNCTUATION_START = 4
CLASS_PUNCTUATION_END = 8
CLASS_SUB_WORD_START = 16
CLASS_SUB_WORD_END = 32
CLASS_LINE_START = 64
CLASS_LINE_END = 128
CLASS_EMPTY_LINE = 256

INHIBIT_WORD_COMPLETIONS = 1
INHIBIT_EXPLICIT_COMPLETIONS = 2
DYNAMIC_COMPLETIONS = 4

KIND_ID_AMBIGUOUS = 0
KIND_ID_KEYWORD = 1
KIND_ID_TYPE = 2
KIND_ID_FUNCTION = 3
KIND_ID_NAMESPACE = 4
KIND_ID_NAVIGATION = 5
KIND_ID_MARKUP = 6
KIND_ID_VARIABLE = 7
KIND_ID_SNIPPET = 8

KIND_AMBIGUOUS = (KIND_ID_AMBIGUOUS, "", "")
KIND_KEYWORD = (KIND_ID_KEYWORD, "", "")
KIND_TYPE = (KIND_ID_TYPE, "", "")
KIND_FUNCTION = (KIND_ID_FUNCTION, "", "")
KIND_NAMESPACE = (KIND_ID_NAMESPACE, "", "")
KIND_NAVIGATION = (KIND_ID_NAVIGATION, "", "")
KIND_MARKUP = (KIND_ID_MARKUP, "", "")
KIND_VARIABLE = (KIND_ID_VARIABLE, "", "")
KIND_SNIPPET = (KIND_ID_SNIPPET, "", "")

COMPLETION_FLAG_KEEP_PREFIX = 1
COMPLETION_FLAG_INVERT_ORDER = 2

# Layer constants
LAYER_BELOW = -1
LAYER_DEFAULT = 0
LAYER_ABOVE = 1
LAYER_BLOCK = 2

# Version
def version() -> str:
    return "4096"

def platform() -> str:
    return sys.platform

def arch() -> str:
    return "x64"

def channel() -> str:
    return "stable"


# ============================================================
# Region
# ============================================================

class Region:
    """Represents a text region (a, b)."""
    def __init__(self, a: int, b: int = None):
        self.a = a
        self.b = b if b is not None else a

    def __repr__(self):
        return f"Region({self.a}, {self.b})"

    def __eq__(self, other):
        return isinstance(other, Region) and self.a == other.a and self.b == other.b

    def __contains__(self, x):
        if isinstance(x, Region):
            return self.contains(x)
        return self.a <= x < self.b

    def begin(self) -> int:
        return min(self.a, self.b)

    def end(self) -> int:
        return max(self.a, self.b)

    def size(self) -> int:
        return abs(self.a - self.b)

    def empty(self) -> bool:
        return self.a == self.b

    def cover(self, other: 'Region') -> 'Region':
        return Region(min(self.begin(), other.begin()), max(self.end(), other.end()))

    def intersection(self, other: 'Region') -> 'Region':
        result = Region(max(self.begin(), other.begin()), min(self.end(), other.end()))
        return result if result.begin() < result.end() else Region(0)

    def intersects(self, other: 'Region') -> bool:
        return self.begin() < other.end() and self.end() > other.begin()

    def contains(self, other: 'Region') -> bool:
        return self.begin() <= other.begin() and self.end() >= other.end()


# ============================================================
# Selection
# ============================================================

class Selection:
    """Manages cursor selections in a view."""
    def __init__(self, view_id: int):
        self._view_id = view_id
        self._bridge = MCPBridge.instance()

    def __len__(self) -> int:
        result = self._bridge.request("wizp/selection/count", {"view_id": self._view_id})
        return result if result else 1

    def __getitem__(self, index: int):
        result = self._bridge.request("wizp/selection/get", {"view_id": self._view_id, "index": index})
        if result:
            return Region(result["a"], result["b"])
        return Region(0)

    def __iter__(self):
        for i in range(len(self)):
            yield self[i]

    def clear(self):
        self._bridge.request("wizp/selection/clear", {"view_id": self._view_id})

    def add(self, region: Region):
        self._bridge.request("wizp/selection/add", {
            "view_id": self._view_id, "a": region.a, "b": region.b
        })

    def add_all(self, regions: list):
        for r in regions:
            self.add(r)

    def subtract(self, region: Region):
        self._bridge.request("wizp/selection/subtract", {
            "view_id": self._view_id, "a": region.a, "b": region.b
        })

    def contains(self, region: Region) -> bool:
        result = self._bridge.request("wizp/selection/contains", {
            "view_id": self._view_id, "a": region.a, "b": region.b
        })
        return result if result else False


# ============================================================
# Settings
# ============================================================

class Settings:
    """Settings object backed by Zedit config."""
    def __init__(self, settings_id: str = None):
        self._id = settings_id
        self._bridge = MCPBridge.instance()
        self._cache = {}

    def get(self, key: str, default=None):
        if key in self._cache:
            return self._cache[key]
        result = self._bridge.request("wizp/settings/get", {
            "settings_id": self._id, "key": key
        })
        val = result if result is not None else default
        self._cache[key] = val
        return val

    def set(self, key: str, value):
        self._cache[key] = value
        self._bridge.request("wizp/settings/set", {
            "settings_id": self._id, "key": key, "value": json.dumps(value)
        })

    def erase(self, key: str):
        if key in self._cache:
            del self._cache[key]
        self._bridge.request("wizp/settings/erase", {
            "settings_id": self._id, "key": key
        })

    def has(self, key: str) -> bool:
        return self.get(key) is not None

    def to_dict(self) -> dict:
        return dict(self._cache)

    def add_on_change(self, key: str, callback: Callable):
        """Register a callback for setting changes."""
        _callback_registry.register_setting_callback(self._id, key, callback)


# ============================================================
# Phantom and PhantomSet
# ============================================================

class Phantom:
    """Represents an HTML phantom attached to a region."""
    def __init__(self, region: Region, content: str, layout: int, on_navigate: Callable = None):
        self.region = region
        self.content = content
        self.layout = layout
        self.on_navigate = on_navigate


class PhantomSet:
    """Manages a collection of phantoms for a view."""
    def __init__(self, view: 'View', key: str = ""):
        self._view_id = view.id()
        self._key = key
        self._bridge = MCPBridge.instance()
        self._phantoms = []

    def __del__(self):
        self._bridge.request("wizp/phantom/clear", {"view_id": self._view_id, "key": self._key})

    def update(self, phantoms: List[Phantom]):
        self._phantoms = phantoms
        data = [{"a": p.region.a, "b": p.region.b, "content": p.content, "layout": p.layout}
                for p in phantoms]
        self._bridge.request("wizp/phantom/update", {
            "view_id": self._view_id, "key": self._key, "phantoms": data
        })


# ============================================================
# View
# ============================================================

class View:
    """Represents a text editor view."""
    def __init__(self, view_id: int = None):
        self._id = view_id
        self._bridge = MCPBridge.instance()
        self._sel = Selection(self._id) if self._id else None

    def id(self) -> int:
        return self._id

    def file_name(self) -> Optional[str]:
        result = self._bridge.request("wizp/view/file_name", {"view_id": self._id})
        return result if result else None

    def name(self) -> str:
        result = self._bridge.request("wizp/view/name", {"view_id": self._id})
        return result if result else ""

    def is_dirty(self) -> bool:
        result = self._bridge.request("wizp/view/is_dirty", {"view_id": self._id})
        return result if result else False

    def is_read_only(self) -> bool:
        result = self._bridge.request("wizp/view/is_read_only", {"view_id": self._id})
        return result if result else False

    def set_read_only(self, value: bool):
        self._bridge.request("wizp/view/set_read_only", {"view_id": self._id, "value": value})

    def is_scratch(self) -> bool:
        result = self._bridge.request("wizp/view/is_scratch", {"view_id": self._id})
        return result if result else False

    def set_scratch(self, value: bool):
        self._bridge.request("wizp/view/set_scratch", {"view_id": self._id, "value": value})

    def size(self) -> int:
        result = self._bridge.request("wizp/view/size", {"view_id": self._id})
        return result if result else 0

    def sel(self) -> Selection:
        if self._sel is None:
            self._sel = Selection(self._id)
        return self._sel

    def substr(self, region: Region) -> str:
        result = self._bridge.request("wizp/view/substr", {
            "view_id": self._id, "a": region.a, "b": region.b
        })
        return result if result else ""

    def find(self, pattern: str, start: int, flags: int = 0) -> Optional[Region]:
        result = self._bridge.request("wizp/view/find", {
            "view_id": self._id, "pattern": pattern, "start": start, "flags": flags
        })
        if result and result.get("a") is not None:
            return Region(result["a"], result["b"])
        return None

    def find_all(self, pattern: str, flags: int = 0, fmt: str = None, extractions: list = None) -> List[Region]:
        result = self._bridge.request("wizp/view/find_all", {
            "view_id": self._id, "pattern": pattern, "flags": flags
        })
        if result:
            return [Region(r["a"], r["b"]) for r in result]
        return []

    def rowcol(self, point: int) -> Tuple[int, int]:
        result = self._bridge.request("wizp/view/rowcol", {
            "view_id": self._id, "point": point
        })
        if result:
            return (result["row"], result["col"])
        return (0, 0)

    def text_point(self, row: int, col: int) -> int:
        result = self._bridge.request("wizp/view/text_point", {
            "view_id": self._id, "row": row, "col": col
        })
        return result if result else 0

    def line(self, region: Region) -> Region:
        result = self._bridge.request("wizp/view/line", {
            "view_id": self._id, "a": region.a, "b": region.b
        })
        if result:
            return Region(result["a"], result["b"])
        return Region(0)

    def full_line(self, region: Region) -> Region:
        result = self._bridge.request("wizp/view/full_line", {
            "view_id": self._id, "a": region.a, "b": region.b
        })
        if result:
            return Region(result["a"], result["b"])
        return Region(0)

    def lines(self, region: Region) -> List[Region]:
        result = self._bridge.request("wizp/view/lines", {
            "view_id": self._id, "a": region.a, "b": region.b
        })
        if result:
            return [Region(r["a"], r["b"]) for r in result]
        return []

    def word(self, region: Region) -> Region:
        result = self._bridge.request("wizp/view/word", {
            "view_id": self._id, "a": region.a, "b": region.b
        })
        if result:
            return Region(result["a"], result["b"])
        return Region(0)

    def classify(self, point: int) -> int:
        result = self._bridge.request("wizp/view/classify", {
            "view_id": self._id, "point": point
        })
        return result if result else 0

    def find_by_class(self, point: int, forward: bool, classes: int, separators: str = "") -> int:
        result = self._bridge.request("wizp/view/find_by_class", {
            "view_id": self._id, "point": point, "forward": forward,
            "classes": classes, "separators": separators
        })
        return result if result else point

    def expand_by_class(self, region: Region, classes: int, separators: str = "") -> Region:
        a = self.find_by_class(region.a, False, classes, separators)
        b = self.find_by_class(region.b, True, classes, separators)
        return Region(a, b)

    def scope_name(self, point: int) -> str:
        result = self._bridge.request("wizp/view/scope_name", {
            "view_id": self._id, "point": point
        })
        return result if result else ""

    def scope_name_region(self, region: Region) -> str:
        return self.scope_name(region.begin())

    def score_selector(self, point: int, selector: str) -> int:
        result = self._bridge.request("wizp/view/score_selector", {
            "view_id": self._id, "point": point, "selector": selector
        })
        return result if result else 0

    def match_selector(self, point: int, selector: str) -> bool:
        return self.score_selector(point, selector) > 0

    def symbol(self) -> str:
        result = self._bridge.request("wizp/view/symbol", {"view_id": self._id})
        return result if result else ""

    def symbols(self) -> list:
        result = self._bridge.request("wizp/view/symbols", {"view_id": self._id})
        return result if result else []

    def indexed_symbols(self) -> list:
        result = self._bridge.request("wizp/view/indexed_symbols", {"view_id": self._id})
        return result if result else []

    def set_status(self, key: str, value: str):
        self._bridge.request("wizp/view/set_status", {
            "view_id": self._id, "key": key, "value": value
        })

    def get_status(self, key: str) -> str:
        result = self._bridge.request("wizp/view/get_status", {
            "view_id": self._id, "key": key
        })
        return result if result else ""

    def erase_status(self, key: str):
        self._bridge.request("wizp/view/erase_status", {
            "view_id": self._id, "key": key
        })

    def settings(self) -> Settings:
        return Settings(f"view_{self._id}")

    def window(self) -> Optional['Window']:
        result = self._bridge.request("wizp/view/window", {"view_id": self._id})
        if result:
            return Window(result["window_id"])
        return None

    def run_command(self, cmd: str, args: dict = None):
        params = {"view_id": self._id, "command": cmd}
        if args:
            params["args"] = json.dumps(args)
        self._bridge.request("wizp/view/run_command", params)

    def show_popup_menu(self, items: list, on_done: Callable, flags: int = 0):
        _popup_manager.show_menu(self._id, items, on_done, flags)

    def show_popup(self, content: str, flags: int = 0, location: int = -1,
                   max_width: int = 320, max_height: int = 240,
                   on_navigate: Callable = None, on_hide: Callable = None):
        self._bridge.request("wizp/view/show_popup", {
            "view_id": self._id, "content": content, "flags": flags,
            "location": location, "max_width": max_width, "max_height": max_height
        })

    def update_popup(self, content: str):
        self._bridge.request("wizp/view/update_popup", {
            "view_id": self._id, "content": content
        })

    def hide_popup(self):
        self._bridge.request("wizp/view/hide_popup", {"view_id": self._id})

    def is_popup_visible(self) -> bool:
        result = self._bridge.request("wizp/view/is_popup_visible", {"view_id": self._id})
        return result if result else False

    def show(self, location: int, show_surrounds: bool = True):
        self._bridge.request("wizp/view/show", {
            "view_id": self._id, "location": location, "show_surrounds": show_surrounds
        })

    def add_regions(self, key: str, regions: List[Region], scope: str = "",
                    icon: str = "", flags: int = 0):
        data = {"view_id": self._id, "key": key, "scope": scope, "icon": icon, "flags": flags}
        data["regions"] = [{"a": r.a, "b": r.b} for r in regions]
        self._bridge.request("wizp/view/add_regions", data)

    def get_regions(self, key: str) -> List[Region]:
        result = self._bridge.request("wizp/view/get_regions", {
            "view_id": self._id, "key": key
        })
        if result:
            return [Region(r["a"], r["b"]) for r in result]
        return []

    def erase_regions(self, key: str):
        self._bridge.request("wizp/view/erase_regions", {
            "view_id": self._id, "key": key
        })

    def assign_syntax(self, syntax_file: str):
        self._bridge.request("wizp/view/assign_syntax", {
            "view_id": self._id, "syntax_file": syntax_file
        })

    def set_syntax_file(self, syntax_file: str):
        self.assign_syntax(syntax_file)

    def change_count(self) -> int:
        result = self._bridge.request("wizp/view/change_count", {"view_id": self._id})
        return result if result else 0

    def change_id(self) -> tuple:
        return (self.id(), self.change_count())

    def text_to_region(self, text: str) -> Optional[Region]:
        """Find text and return its region."""
        r = self.find(text, 0, LITERAL)
        return r

    def visible_region(self) -> Region:
        result = self._bridge.request("wizp/view/visible_region", {"view_id": self._id})
        if result:
            return Region(result["a"], result["b"])
        return Region(0)

    def viewport_position(self) -> Tuple[float, float]:
        result = self._bridge.request("wizp/view/viewport_position", {"view_id": self._id})
        if result:
            return (result["x"], result["y"])
        return (0.0, 0.0)

    def set_viewport_position(self, pos: Tuple[float, float], animate: bool = True):
        self._bridge.request("wizp/view/set_viewport_position", {
            "view_id": self._id, "x": pos[0], "y": pos[1], "animate": animate
        })

    def viewport_extent(self) -> Tuple[float, float]:
        result = self._bridge.request("wizp/view/viewport_extent", {"view_id": self._id})
        if result:
            return (result["width"], result["height"])
        return (800.0, 600.0)

    def layout_extent(self) -> Tuple[float, float]:
        result = self._bridge.request("wizp/view/layout_extent", {"view_id": self._id})
        if result:
            return (result["width"], result["height"])
        return (800.0, 600.0)

    def text_to_layout(self, point: int) -> Tuple[float, float]:
        result = self._bridge.request("wizp/view/text_to_layout", {
            "view_id": self._id, "point": point
        })
        if result:
            return (result["x"], result["y"])
        return (0.0, 0.0)

    def layout_to_text(self, pos: Tuple[float, float]) -> int:
        result = self._bridge.request("wizp/view/layout_to_text", {
            "view_id": self._id, "x": pos[0], "y": pos[1]
        })
        return result if result else 0

    def em_width(self) -> float:
        return 8.0

    def line_height(self) -> float:
        return 16.0


# ============================================================
# Edit
# ============================================================

class Edit:
    """Token passed to TextCommand.run() for making edits."""
    _next_id = 0
    _token_map = {}

    def __init__(self, view_id: int):
        self._view_id = view_id
        Edit._next_id += 1
        self._edit_id = Edit._next_id
        Edit._token_map[self._edit_id] = (view_id, self)
        self._bridge = MCPBridge.instance()
        self._bridge.request("wizp/edit/begin", {
            "view_id": view_id, "edit_id": self._edit_id
        })

    @staticmethod
    def _edit_from_token(view_id: int, token: int) -> 'Edit':
        if token in Edit._token_map:
            return Edit._token_map[token][1]
        e = Edit(view_id)
        Edit._token_map[token] = (view_id, e)
        return e

    @property
    def token(self) -> int:
        return self._edit_id

    def erase(self, region: Region):
        self._bridge.request("wizp/edit/erase", {
            "view_id": self._view_id, "edit_id": self._edit_id,
            "a": region.a, "b": region.b
        })

    def insert(self, point: int, text: str):
        self._bridge.request("wizp/edit/insert", {
            "view_id": self._view_id, "edit_id": self._edit_id,
            "point": point, "text": text
        })

    def replace(self, region: Region, text: str):
        self._bridge.request("wizp/edit/replace", {
            "view_id": self._view_id, "edit_id": self._edit_id,
            "a": region.a, "b": region.b, "text": text
        })


# ============================================================
# Window
# ============================================================

class Window:
    """Represents a window containing views."""
    def __init__(self, window_id: int = None):
        self._id = window_id
        self._bridge = MCPBridge.instance()

    def id(self) -> int:
        return self._id

    def is_valid(self) -> bool:
        return self._id is not None

    def active_view(self) -> Optional[View]:
        result = self._bridge.request("wizp/window/active_view", {"window_id": self._id})
        if result:
            return View(result["view_id"])
        return None

    def new_file(self, flags: int = 0, syntax: str = "") -> View:
        result = self._bridge.request("wizp/window/new_file", {
            "window_id": self._id, "flags": flags, "syntax": syntax
        })
        if result:
            return View(result["view_id"])
        return View(0)

    def open_file(self, file_name: str, flags: int = 0, group: int = -1) -> View:
        result = self._bridge.request("wizp/window/open_file", {
            "window_id": self._id, "file_name": file_name,
            "flags": flags, "group": group
        })
        if result:
            return View(result["view_id"])
        return View(0)

    def find_open_file(self, file_name: str) -> Optional[View]:
        result = self._bridge.request("wizp/window/find_open_file", {
            "window_id": self._id, "file_name": file_name
        })
        if result:
            return View(result["view_id"])
        return None

    def views(self, group: int = -1, include_transient: bool = False) -> List[View]:
        result = self._bridge.request("wizp/window/views", {
            "window_id": self._id, "group": group, "include_transient": include_transient
        })
        if result:
            return [View(v["view_id"]) for v in result]
        return []

    def active_sheet(self):
        return self.active_view()

    def sheets(self):
        return self.views()

    def selected_sheets(self):
        return self.views()

    def num_groups(self) -> int:
        result = self._bridge.request("wizp/window/num_groups", {"window_id": self._id})
        return result if result else 1

    def active_group(self) -> int:
        result = self._bridge.request("wizp/window/active_group", {"window_id": self._id})
        return result if result else 0

    def focus_group(self, idx: int):
        self._bridge.request("wizp/window/focus_group", {
            "window_id": self._id, "index": idx
        })

    def focus_view(self, view: View):
        self._bridge.request("wizp/window/focus_view", {
            "window_id": self._id, "view_id": view.id()
        })

    def run_command(self, cmd: str, args: dict = None):
        params = {"window_id": self._id, "command": cmd}
        if args:
            params["args"] = json.dumps(args)
        self._bridge.request("wizp/window/run_command", params)

    def show_quick_panel(self, items: list, on_done: Callable,
                         flags: int = 0, selected_index: int = -1,
                         on_highlight: Callable = None):
        _popup_manager.show_quick_panel(self._id, items, on_done, flags,
                                        selected_index, on_highlight)

    def show_input_panel(self, caption: str, initial_text: str,
                         on_done: Callable, on_change: Callable = None,
                         on_cancel: Callable = None):
        _popup_manager.show_input_panel(self._id, caption, initial_text,
                                        on_done, on_change, on_cancel)

    def status_message(self, msg: str):
        self._bridge.request("wizp/window/status_message", {
            "window_id": self._id, "message": msg
        })

    def error_message(self, msg: str):
        """Show error message dialog."""
        self._bridge.request("wizp/window/error_message", {
            "window_id": self._id, "message": msg
        })

    def message_dialog(self, msg: str):
        self._bridge.request("wizp/window/message_dialog", {
            "window_id": self._id, "message": msg
        })

    def ok_cancel_dialog(self, msg: str, ok_title: str = "OK") -> bool:
        result = self._bridge.request("wizp/window/ok_cancel_dialog", {
            "window_id": self._id, "message": msg, "ok_title": ok_title
        })
        return result if result else False

    def yes_no_cancel_dialog(self, msg: str, yes_title: str = "Yes",
                             no_title: str = "No") -> int:
        result = self._bridge.request("wizp/window/yes_no_cancel_dialog", {
            "window_id": self._id, "message": msg,
            "yes_title": yes_title, "no_title": no_title
        })
        return result if result else DIALOG_CANCEL

    def folders(self) -> List[str]:
        result = self._bridge.request("wizp/window/folders", {"window_id": self._id})
        return result if result else []

    def project_file_name(self) -> Optional[str]:
        result = self._bridge.request("wizp/window/project_file_name", {"window_id": self._id})
        return result if result else None

    def project_data(self) -> dict:
        result = self._bridge.request("wizp/window/project_data", {"window_id": self._id})
        return result if result else {}

    def set_project_data(self, data: dict):
        self._bridge.request("wizp/window/set_project_data", {
            "window_id": self._id, "data": json.dumps(data)
        })

    def settings(self) -> Settings:
        return Settings(f"window_{self._id}")

    def template_settings(self) -> Settings:
        return Settings("template")

    def lookup_symbol_in_index(self, symbol: str) -> list:
        result = self._bridge.request("wizp/window/lookup_symbol", {
            "window_id": self._id, "symbol": symbol
        })
        return result if result else []

    def create_output_panel(self, name: str, unlisted: bool = False) -> View:
        result = self._bridge.request("wizp/window/create_output_panel", {
            "window_id": self._id, "name": name, "unlisted": unlisted
        })
        if result:
            return View(result["view_id"])
        return View(0)

    def find_output_panel(self, name: str) -> Optional[View]:
        result = self._bridge.request("wizp/window/find_output_panel", {
            "window_id": self._id, "name": name
        })
        if result:
            return View(result["view_id"])
        return None

    def destroy_output_panel(self, name: str):
        self._bridge.request("wizp/window/destroy_output_panel", {
            "window_id": self._id, "name": name
        })


# ============================================================
# Global API Functions
# ============================================================

def active_window() -> Optional[Window]:
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/active_window", {})
    if result:
        return Window(result["window_id"])
    return None

def windows() -> List[Window]:
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/windows", {})
    if result:
        return [Window(w["window_id"]) for w in result]
    return []

def set_timeout(callback: Callable, delay_ms: int):
    """Schedule a callback after delay_ms milliseconds."""
    _timer_manager.schedule(callback, delay_ms, repeat=False)

def set_async_timeout(callback: Callable, delay_ms: int):
    """Like set_timeout but runs on async thread."""
    threading.Thread(target=lambda: (time.sleep(delay_ms / 1000.0), callback()),
                     daemon=True).start()

def error_message(msg: str):
    win = active_window()
    if win:
        win.error_message(msg)

def message_dialog(msg: str):
    win = active_window()
    if win:
        win.message_dialog(msg)

def ok_cancel_dialog(msg: str, ok_title: str = "OK") -> bool:
    win = active_window()
    if win:
        return win.ok_cancel_dialog(msg, ok_title)
    return False

def yes_no_cancel_dialog(msg: str, yes_title: str = "Yes",
                         no_title: str = "No") -> int:
    win = active_window()
    if win:
        return win.yes_no_cancel_dialog(msg, yes_title, no_title)
    return DIALOG_CANCEL

def status_message(msg: str):
    win = active_window()
    if win:
        win.status_message(msg)

def load_settings(name: str) -> Settings:
    return Settings(f"file_{name}")

def save_settings(name: str):
    """Settings are auto-saved via MCP."""
    pass

def load_resource(name: str) -> Optional[str]:
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/load_resource", {"name": name})
    return result if result else None

def load_binary_resource(name: str) -> Optional[bytes]:
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/load_binary_resource", {"name": name})
    if result:
        return bytes(result)
    return None

def find_resources(pattern: str) -> List[str]:
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/find_resources", {"pattern": pattern})
    return result if result else []

def encode_value(value, pretty: bool = False) -> str:
    return json.dumps(value, indent=2 if pretty else None)

def decode_value(data: str):
    return json.loads(data)

def expand_variables(value, window: Window = None) -> str:
    """Expand ${file}, ${project}, etc."""
    # Simple substitution
    result = value
    result = result.replace("${file}", "")
    result = result.replace("${project}", "")
    result = result.replace("${platform}", sys.platform)
    return result

def run_command(cmd: str, args: dict = None):
    win = active_window()
    if win:
        win.run_command(cmd, args)

def get_clipboard_async(callback: Callable):
    """Get clipboard content asynchronously."""
    bridge = MCPBridge.instance()
    result = bridge.request("wizp/clipboard/get", {})
    if callback:
        callback(result if result else "")

def set_clipboard(text: str):
    bridge = MCPBridge.instance()
    bridge.request("wizp/clipboard/set", {"text": text})

def log_commands(flag: bool = None) -> bool:
    return False

def log_input(flag: bool = None) -> bool:
    return False

def log_result_regex(flag: bool = None) -> bool:
    return False

def score_selector(scope_name: str, selector: str) -> int:
    """Score a scope against a selector. Simplified implementation."""
    # Simple scoring: exact match = highest, prefix = medium
    if scope_name == selector:
        return 1024
    if scope_name.startswith(selector):
        return 512
    selector_parts = selector.split(".")
    scope_parts = scope_name.split(".")
    score = 0
    for sp in scope_parts:
        for sel in selector_parts:
            if sp == sel:
                score += 256
            elif sp.startswith(sel):
                score += 128
    return score

# ============================================================
# Internal helpers
# ============================================================

class _CallbackRegistry:
    """Registry for event/setting change callbacks."""
    def __init__(self):
        self._setting_callbacks = {}  # (settings_id, key) -> [callbacks]

    def register_setting_callback(self, settings_id, key, callback):
        k = (settings_id, key)
        if k not in self._setting_callbacks:
            self._setting_callbacks[k] = []
        self._setting_callbacks[k].append(callback)


class _TimerManager:
    """Manages set_timeout callbacks."""
    def __init__(self):
        self._timers = []

    def schedule(self, callback, delay_ms, repeat=False):
        if delay_ms <= 0:
            callback()
            return
        def _run():
            time.sleep(delay_ms / 1000.0)
            callback()
        t = threading.Thread(target=_run, daemon=True)
        t.start()


class _PopupManager:
    """Manages popup menus and quick panels via MCP."""
    _pending_popups = {}

    def show_quick_panel(self, window_id, items, on_done, flags, selected_index, on_highlight):
        bridge = MCPBridge.instance()
        result = bridge.request("wizp/window/show_quick_panel", {
            "window_id": window_id, "items": json.dumps(items),
            "flags": flags, "selected_index": selected_index
        })
        if result and on_done:
            on_done(result.get("selected", -1))

    def show_input_panel(self, window_id, caption, initial_text, on_done, on_change, on_cancel):
        bridge = MCPBridge.instance()
        result = bridge.request("wizp/window/show_input_panel", {
            "window_id": window_id, "caption": caption, "initial_text": initial_text
        })
        if result and on_done:
            on_done(result.get("text", ""))


_callback_registry = _CallbackRegistry()
_timer_manager = _TimerManager()
_popup_manager = _PopupManager()
