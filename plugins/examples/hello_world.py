"""
Example Sublime Text plugin for Zedit
Demonstrates TextCommand, WindowCommand, and EventListener
"""

import sublime
import sublime_plugin


class HelloWorldCommand(sublime_plugin.TextCommand):
    """Insert 'Hello, World!' at cursor position."""
    def run(self, edit: sublime.Edit):
        for region in self.view.sel():
            self.view.insert(edit, region.begin(), "Hello, World!")

    def is_enabled(self):
        return True

    def description(self):
        return "Insert Hello, World! at cursor"


class InsertDateCommand(sublime_plugin.TextCommand):
    """Insert current date at cursor."""
    def run(self, edit: sublime.Edit):
        from datetime import datetime
        date_str = datetime.now().strftime("%Y-%m-%d")
        for region in self.view.sel():
            self.view.replace(edit, region, date_str)


class DuplicateLineCommand(sublime_plugin.TextCommand):
    """Duplicate the current line."""
    def run(self, edit: sublime.Edit):
        for region in self.view.sel():
            line = self.view.line(region)
            line_text = self.view.substr(line)
            self.view.insert(edit, line.end(), "\n" + line_text)


class DeleteTrailingSpacesCommand(sublime_plugin.TextCommand):
    """Remove trailing whitespace from all lines."""
    def run(self, edit: sublime.Edit):
        regions = self.view.find_all("[ \t]+$", 0)
        for region in reversed(regions):
            self.view.erase(edit, region)


class SortLinesCommand(sublime_plugin.TextCommand):
    """Sort selected lines alphabetically."""
    def run(self, edit: sublime.Edit):
        for region in self.view.sel():
            lines_region = self.view.line(region)
            if lines_region.empty():
                continue
            text = self.view.substr(lines_region)
            lines = text.split("\n")
            lines.sort()
            sorted_text = "\n".join(lines)
            self.view.replace(edit, lines_region, sorted_text)


class ShowCharCountCommand(sublime_plugin.WindowCommand):
    """Show character count of active view in status bar."""
    def run(self):
        view = self.window.active_view()
        if view:
            count = view.size()
            sublime.status_message(f"Character count: {count}")


class HelloWorldListener(sublime_plugin.EventListener):
    """Log when files are saved."""
    def on_post_save(self, view: sublime.View):
        file_name = view.file_name() or "Untitled"
        print(f"[HelloWorld] File saved: {file_name}")

    def on_activated(self, view: sublime.View):
        file_name = view.file_name() or "Untitled"
        view.set_status("hello_world", f"📝 {file_name}")
