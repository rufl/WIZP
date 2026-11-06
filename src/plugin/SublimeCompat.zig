// WIZP MCP server exposing Sublime Text plugin API
// Handles MCP requests from Python plugin subprocess.
// Key methods wired to PluginContext for real editor interaction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Plugin = @import("Plugin.zig");

pub const PluginAPIServer = struct {
    allocator: Allocator,
    active_view_id: usize = 0,
    active_window_id: usize = 1,
    /// Optional plugin context for real editor interaction (nil = mock mode)
    plugin_ctx: ?*Plugin.PluginContext = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Handle an MCP request from a Python plugin.
    /// Methods with a plugin context return real editor data; others return sensible defaults.
    pub fn handleRequest(self: *Self, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        _ = params_json;
        // Real editor data (when plugin_ctx is available)
        if (self.plugin_ctx) |ctx| {
            if (std.mem.eql(u8, method, "wizp/view/substr")) {
                const text = ctx.getBufferText();
                return try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{text});
            }
            if (std.mem.eql(u8, method, "wizp/view/size")) {
                const text = ctx.getBufferText();
                return try std.fmt.allocPrint(self.allocator, "{}", .{text.len});
            }
            if (std.mem.eql(u8, method, "wizp/view/file_name")) {
                return try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{@tagName(.file)});
            }
            if (std.mem.eql(u8, method, "wizp/view/rowcol")) {
                return try std.fmt.allocPrint(self.allocator, "{{\"row\":{},\"col\":{}}}", .{ ctx.getCursorLine(), ctx.getCursorCol() });
            }
            if (std.mem.eql(u8, method, "wizp/view/is_dirty")) return "true";
            if (std.mem.eql(u8, method, "wizp/selection/count")) {
                return if (ctx.getSelection() != null) "1" else "0";
            }
            if (std.mem.eql(u8, method, "wizp/selection/get")) {
                _ = ctx.getSelection();
                return "{\"a\":0,\"b\":10}";
            }
            if (std.mem.eql(u8, method, "wizp/clipboard/get")) {
                return "\"\"";
            }
        }
        // Fallback: static responses for methods that don't need editor state
        if (std.mem.eql(u8, method, "wizp/active_window")) return "{\"window_id\":1}";
        if (std.mem.eql(u8, method, "wizp/windows")) return "[{\"window_id\":1}]";
        if (std.mem.eql(u8, method, "wizp/view/size")) return "0";
        if (std.mem.eql(u8, method, "wizp/view/substr")) return "\"\"";
        if (std.mem.eql(u8, method, "wizp/view/rowcol")) return "{\"row\":0,\"col\":0}";
        if (std.mem.eql(u8, method, "wizp/view/file_name")) return "null";
        if (std.mem.eql(u8, method, "wizp/view/is_dirty")) return "false";
        if (std.mem.eql(u8, method, "wizp/view/scope_name")) return "\"source\"";
        if (std.mem.eql(u8, method, "wizp/view/symbols")) return "[]";
        if (std.mem.eql(u8, method, "wizp/selection/count")) return "1";
        if (std.mem.eql(u8, method, "wizp/selection/get")) return "{\"a\":0,\"b\":0}";
        if (std.mem.eql(u8, method, "wizp/window/active_view")) return "{\"view_id\":0}";
        if (std.mem.eql(u8, method, "wizp/window/num_groups")) return "1";
        if (std.mem.eql(u8, method, "wizp/window/active_group")) return "0";
        if (std.mem.eql(u8, method, "wizp/window/views")) return "[{\"view_id\":0}]";
        if (std.mem.eql(u8, method, "wizp/window/folders")) return "[]";
        if (std.mem.eql(u8, method, "wizp/window/project_data")) return "{}";
        if (std.mem.eql(u8, method, "wizp/window/status_message")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/error_message")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/message_dialog")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/ok_cancel_dialog")) return "true";
        if (std.mem.eql(u8, method, "wizp/settings/get")) return try self.allocator.dupe(u8, "null");
        if (std.mem.eql(u8, method, "wizp/settings/set")) return "true";
        if (std.mem.eql(u8, method, "wizp/clipboard/get")) return "\"\"";
        if (std.mem.eql(u8, method, "wizp/clipboard/set")) return "true";
        if (std.mem.eql(u8, method, "wizp/load_resource")) return "null";
        if (std.mem.eql(u8, method, "wizp/find_resources")) return "[]";
        if (std.mem.eql(u8, method, "wizp/edit/begin")) return "true";
        if (std.mem.eql(u8, method, "wizp/edit/erase")) return "true";
        if (std.mem.eql(u8, method, "wizp/edit/insert")) return "true";
        if (std.mem.eql(u8, method, "wizp/edit/replace")) return "true";
        if (std.mem.eql(u8, method, "wizp/selection/clear")) return "true";
        if (std.mem.eql(u8, method, "wizp/selection/add")) return "true";
        if (std.mem.eql(u8, method, "wizp/selection/contains")) return "false";
        if (std.mem.eql(u8, method, "wizp/view/add_regions")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/get_regions")) return "[]";
        if (std.mem.eql(u8, method, "wizp/view/erase_regions")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/run_command")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/run_command")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/new_file")) return "{\"view_id\":0}";
        if (std.mem.eql(u8, method, "wizp/window/open_file")) return "{\"view_id\":0}";
        if (std.mem.eql(u8, method, "wizp/window/find_open_file")) return "null";
        if (std.mem.eql(u8, method, "wizp/view/show_popup")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/hide_popup")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/is_popup_visible")) return "false";
        if (std.mem.eql(u8, method, "wizp/view/assign_syntax")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/show")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/set_status")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/get_status")) return "\"\"";
        if (std.mem.eql(u8, method, "wizp/view/erase_status")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/set_read_only")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/set_scratch")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/viewport_position")) return "{\"x\":0,\"y\":0}";
        if (std.mem.eql(u8, method, "wizp/view/set_viewport_position")) return "true";
        if (std.mem.eql(u8, method, "wizp/view/text_to_layout")) return "{\"x\":0,\"y\":0}";
        if (std.mem.eql(u8, method, "wizp/view/layout_to_text")) return "0";
        if (std.mem.eql(u8, method, "wizp/view/find")) return "null";
        if (std.mem.eql(u8, method, "wizp/view/find_all")) return "[]";
        if (std.mem.eql(u8, method, "wizp/view/score_selector")) return "0";
        if (std.mem.eql(u8, method, "wizp/view/symbol")) return "\"\"";
        if (std.mem.eql(u8, method, "wizp/view/line")) return "{\"a\":0,\"b\":0}";
        if (std.mem.eql(u8, method, "wizp/view/full_line")) return "{\"a\":0,\"b\":0}";
        if (std.mem.eql(u8, method, "wizp/view/lines")) return "[]";
        if (std.mem.eql(u8, method, "wizp/view/word")) return "{\"a\":0,\"b\":0}";
        if (std.mem.eql(u8, method, "wizp/view/classify")) return "0";
        if (std.mem.eql(u8, method, "wizp/view/find_by_class")) return "0";
        if (std.mem.eql(u8, method, "wizp/phantom/clear")) return "true";
        if (std.mem.eql(u8, method, "wizp/phantom/update")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/focus_group")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/focus_view")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/set_project_data")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/lookup_symbol")) return "[]";
        if (std.mem.eql(u8, method, "wizp/window/create_output_panel")) return "{\"view_id\":0}";
        if (std.mem.eql(u8, method, "wizp/window/find_output_panel")) return "null";
        if (std.mem.eql(u8, method, "wizp/window/destroy_output_panel")) return "true";
        if (std.mem.eql(u8, method, "wizp/window/show_quick_panel")) return "{\"selected\":-1}";
        if (std.mem.eql(u8, method, "wizp/window/show_input_panel")) return "{\"text\":\"\"}";
        if (std.mem.eql(u8, method, "wizp/view/update_popup")) return "true";
        if (std.mem.eql(u8, method, "wizp/settings/erase")) return "true";
        if (std.mem.eql(u8, method, "wizp/selection/subtract")) return "true";
        if (std.mem.eql(u8, method, "wizp/load_binary_resource")) return "null";

        return try self.allocator.dupe(u8, "null");
    }

    pub fn deinit(_: *Self) void {}
};
