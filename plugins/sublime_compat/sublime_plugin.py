"""
sublime_plugin module compatibility shim for Zedit
Provides the plugin base classes and command system that all
Sublime Text plugins use.
"""

import sys
import time
from typing import Callable, Dict, Any, List, Optional

# Import our sublime compat module
try:
    import sublime
except ImportError:
    from . import sublime


# ============================================================
# Plugin Base Classes
# ============================================================

class CommandInputHandler:
    """Base for multi-step command inputs."""
    def name(self) -> str:
        return ""

    def placeholder(self) -> str:
        return ""

    def initial_text(self) -> str:
        return ""

    def preview(self, text: str):
        pass

    def validate(self, text: str) -> bool:
        return True

    def confirm(self, text: str):
        pass

    def cancel(self):
        pass

    def next_input(self, args: dict) -> Optional['CommandInputHandler']:
        return None


class TextCommand:
    """Base class for text commands (operate on a View)."""
    def __init__(self, view):
        self.view = view

    def run_(self, edit_token, args: dict):
        """Called internally before run(). Creates Edit from token."""
        edit = sublime.Edit._edit_from_token(self.view.id(), edit_token)
        try:
            self.run(edit, **args)
        finally:
            pass

    def run(self, edit: sublime.Edit, **args):
        """Override this with your command implementation."""
        pass

    def is_enabled_(self, **args) -> bool:
        return self.is_enabled(**args)

    def is_enabled(self, **args) -> bool:
        return True

    def is_visible_(self, **args) -> bool:
        return self.is_visible(**args)

    def is_visible(self, **args) -> bool:
        return True

    def description_(self, **args) -> str:
        return self.description(**args)

    def description(self, **args) -> str:
        return ""

    def want_event(self) -> bool:
        return False

    def input(self, args: dict) -> Optional[CommandInputHandler]:
        return None

    def input_description(self) -> str:
        return ""


class WindowCommand:
    """Base class for window commands (operate on a Window)."""
    def __init__(self, window):
        self.window = window

    def run(self, **args):
        """Override this with your command implementation."""
        pass

    def is_enabled(self, **args) -> bool:
        return True

    def is_visible(self, **args) -> bool:
        return True

    def description(self, **args) -> str:
        return ""

    def want_event(self) -> bool:
        return False

    def input(self, args: dict) -> Optional[CommandInputHandler]:
        return None

    def input_description(self) -> str:
        return ""


class ApplicationCommand:
    """Base class for application-level commands."""
    def run(self, **args):
        pass

    def is_enabled(self, **args) -> bool:
        return True

    def is_visible(self, **args) -> bool:
        return True

    def description(self, **args) -> str:
        return ""

    def want_event(self) -> bool:
        return False

    def input(self, args: dict) -> Optional[CommandInputHandler]:
        return None


# ============================================================
# Event Listeners
# ============================================================

class EventListener:
    """Base class for event listeners."""
    @classmethod
    def is_applicable(cls, settings: sublime.Settings) -> bool:
        return True

    @classmethod
    def applies_to_primary_view_only(cls) -> bool:
        return True

    def on_new(self, view: sublime.View):
        pass

    def on_new_async(self, view: sublime.View):
        pass

    def on_clone(self, view: sublime.View):
        pass

    def on_clone_async(self, view: sublime.View):
        pass

    def on_load(self, view: sublime.View):
        pass

    def on_load_async(self, view: sublime.View):
        pass

    def on_pre_close(self, view: sublime.View):
        pass

    def on_close(self, view: sublime.View):
        pass

    def on_pre_save(self, view: sublime.View):
        pass

    def on_pre_save_async(self, view: sublime.View):
        pass

    def on_post_save(self, view: sublime.View):
        pass

    def on_post_save_async(self, view: sublime.View):
        pass

    def on_modified(self, view: sublime.View):
        pass

    def on_modified_async(self, view: sublime.View):
        pass

    def on_selection_modified(self, view: sublime.View):
        pass

    def on_selection_modified_async(self, view: sublime.View):
        pass

    def on_activated(self, view: sublime.View):
        pass

    def on_activated_async(self, view: sublime.View):
        pass

    def on_deactivated(self, view: sublime.View):
        pass

    def on_deactivated_async(self, view: sublime.View):
        pass

    def on_hover(self, view: sublime.View, point: int, hover_zone: int):
        pass

    def on_query_context(self, view: sublime.View, key: str, operator: int,
                         operand: str, match_all: bool) -> Optional[bool]:
        return None

    def on_query_completions(self, view: sublime.View, prefix: str,
                             locations: List[int]) -> Any:
        return None

    def on_text_command(self, view: sublime.View, command_name: str,
                        args: dict) -> Any:
        return (command_name, args)

    def on_window_command(self, window: sublime.Window, command_name: str,
                          args: dict) -> Any:
        return (command_name, args)

    def on_post_text_command(self, view: sublime.View, command_name: str,
                             args: dict):
        pass

    def on_post_window_command(self, window: sublime.Window, command_name: str,
                               args: dict):
        pass

    def on_new_window(self, window: sublime.Window):
        pass

    def on_new_window_async(self, window: sublime.Window):
        pass

    def on_pre_close_window(self, window: sublime.Window):
        pass

    def on_close_window(self, window: sublime.Window):
        pass

    def on_exit(self):
        pass

    def on_associate_buffer(self, buffer_id: int, file_name: str):
        pass

    def on_associate_buffer_async(self, buffer_id: int, file_name: str):
        pass

    def on_close_buffer(self, buffer_id: int):
        pass

    def on_close_buffer_async(self, buffer_id: int):
        pass


class ViewEventListener:
    """Per-view event listener (more efficient than global EventListener)."""
    @classmethod
    def is_applicable(cls, settings: sublime.Settings) -> bool:
        return True

    @classmethod
    def applies_to_primary_view_only(cls) -> bool:
        return True

    def __init__(self, view: sublime.View):
        self.view = view

    def on_activated(self):
        pass

    def on_activated_async(self):
        pass

    def on_deactivated(self):
        pass

    def on_deactivated_async(self):
        pass

    def on_modified(self):
        pass

    def on_modified_async(self):
        pass

    def on_selection_modified(self):
        pass

    def on_selection_modified_async(self):
        pass

    def on_pre_save(self):
        pass

    def on_pre_save_async(self):
        pass

    def on_post_save(self):
        pass

    def on_post_save_async(self):
        pass

    def on_load(self):
        pass

    def on_load_async(self):
        pass

    def on_pre_close(self):
        pass

    def on_close(self):
        pass

    def on_hover(self, point: int, hover_zone: int):
        pass

    def on_query_context(self, key: str, operator: int,
                         operand: str, match_all: bool) -> Optional[bool]:
        return None

    def on_query_completions(self, prefix: str,
                             locations: List[int]) -> Any:
        return None


# ============================================================
# Command Registration Helpers
# ============================================================

class BackInputHandler(CommandInputHandler):
    """Special input handler to go back."""
    pass


class ListInputHandler(CommandInputHandler):
    """Input handler that shows a list of items."""
    def __init__(self, items: list):
        self._items = items

    def list_items(self) -> list:
        return self._items


class _TextChangeListener:
    """Adapter that maps text change events to on_modified callbacks."""
    pass


# ============================================================
# Plugin registry (used by Zedit to discover and load plugins)
# ============================================================

class _PluginRegistry:
    """Holds all registered plugin classes for discovery."""
    text_commands: Dict[str, type] = {}
    window_commands: Dict[str, type] = {}
    app_commands: Dict[str, type] = {}
    event_listeners: List[type] = []
    view_event_listeners: List[type] = []

    @classmethod
    def register_text_command(cls, name: str, cmd_class: type):
        cls.text_commands[name] = cmd_class

    @classmethod
    def register_window_command(cls, name: str, cmd_class: type):
        cls.window_commands[name] = cmd_class

    @classmethod
    def register_app_command(cls, name: str, cmd_class: type):
        cls.app_commands[name] = cmd_class

    @classmethod
    def register_event_listener(cls, listener_class: type):
        cls.event_listeners.append(listener_class)

    @classmethod
    def register_view_event_listener(cls, listener_class: type):
        cls.view_event_listeners.append(listener_class)


# ============================================================
# CompletionItem (for on_query_completions return values)
# ============================================================

class CompletionItem:
    """Represents a completion item returned by on_query_completions."""
    def __init__(self, trigger: str, annotation: str = "",
                 completion: str = "", completion_format: int = 0,
                 kind: Any = None, details: str = ""):
        self.trigger = trigger
        self.annotation = annotation
        self.completion = completion if completion else trigger
        self.completion_format = completion_format
        self.kind = kind
        self.details = details

    def __eq__(self, other):
        return (isinstance(other, CompletionItem) and
                self.trigger == other.trigger)

    @staticmethod
    def snippet_completion(trigger: str, contents: str, annotation: str = "",
                           kind: Any = None, details: str = "") -> 'CompletionItem':
        return CompletionItem(trigger, annotation, contents,
                              sublime.COMPLETION_FLAG_KEEP_PREFIX,
                              kind, details)

    @staticmethod
    def command_completion(trigger: str, command: str, args: dict = None,
                           annotation: str = "", kind: Any = None,
                           details: str = "") -> 'CompletionItem':
        item = CompletionItem(trigger, annotation, trigger, 0, kind, details)
        item._command = command
        item._args = args
        return item


# ============================================================
# QuickPanelItem (for show_quick_panel with rich items)
# ============================================================

class QuickPanelItem:
    """Rich item for show_quick_panel with annotations and kind."""
    def __init__(self, trigger: str, annotation: str = "",
                 kind: Any = None, details: str = ""):
        self.trigger = trigger
        self.annotation = annotation
        self.kind = kind
        self.details = details


# ============================================================
# ListInputItem (for ListInputHandler)
# ============================================================

class ListInputItem:
    """Rich item for ListInputHandler."""
    def __init__(self, text: str, value: Any, details: str = "",
                 annotation: str = "", kind: Any = None):
        self.text = text
        self.value = value
        self.details = details
        self.annotation = annotation
        self.kind = kind


# ============================================================
# Plugin Loader
# ============================================================

def _discover_plugin_classes(module):
    """Scan a module for plugin classes and register them."""
    for name in dir(module):
        obj = getattr(module, name)
        if not isinstance(obj, type):
            continue

        if issubclass(obj, ApplicationCommand) and obj is not ApplicationCommand:
            cmd_name = _command_name_from_class(obj)
            _PluginRegistry.register_app_command(cmd_name, obj)

        elif issubclass(obj, WindowCommand) and obj is not WindowCommand:
            cmd_name = _command_name_from_class(obj)
            _PluginRegistry.register_window_command(cmd_name, obj)

        elif issubclass(obj, TextCommand) and obj is not TextCommand:
            cmd_name = _command_name_from_class(obj)
            _PluginRegistry.register_text_command(cmd_name, obj)

        elif issubclass(obj, EventListener) and obj is not EventListener:
            _PluginRegistry.register_event_listener(obj)

        elif issubclass(obj, ViewEventListener) and obj is not ViewEventListener:
            _PluginRegistry.register_view_event_listener(obj)


def _command_name_from_class(cls: type) -> str:
    """Convert class name to command name.
    MyExampleCommand -> my_example
    """
    name = cls.__name__
    # Remove trailing 'Command'
    if name.endswith("Command"):
        name = name[:-7]

    # Convert CamelCase to snake_case
    result = []
    for i, ch in enumerate(name):
        if ch.isupper() and i > 0:
            result.append("_")
        result.append(ch.lower())
    return "".join(result)


def load_plugin(plugin_path: str):
    """Load a Sublime Text plugin from a .py file."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("plugin", plugin_path)
    if spec is None or spec.loader is None:
        return
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _discover_plugin_classes(module)


def load_plugins_from_dir(plugin_dir: str):
    """Load all .py files from a plugin directory."""
    import os
    if not os.path.isdir(plugin_dir):
        return
    for fname in sorted(os.listdir(plugin_dir)):
        if fname.endswith(".py") and not fname.startswith("_"):
            try:
                load_plugin(os.path.join(plugin_dir, fname))
            except Exception as e:
                print(f"Error loading plugin {fname}: {e}", file=sys.stderr)
