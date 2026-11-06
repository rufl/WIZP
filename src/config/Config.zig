// Configuration management for WIZP
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EditorConfig = struct {
    theme: []const u8 = "",
    tab_width: usize = 4,
    use_spaces: bool = true,
    show_line_numbers: bool = true,
    show_gutter: bool = true,
    highlight_current_line: bool = true,
    font_size: u8 = 14,
    line_wrap: bool = false,
    auto_indent: bool = true,
    auto_save: bool = false,
    format_on_save: bool = true,
    auto_install_lsp: bool = true,
    rulers: []const usize = &.{},
    scrolloff: usize = 4,
    mouse: bool = true,

    pub fn deinit(self: *EditorConfig, allocator: Allocator) void {
        if (self.theme.len > 0) allocator.free(self.theme);
        self.theme = "";
    }

    pub fn load(allocator: Allocator, path: []const u8) !EditorConfig {
        var config = EditorConfig{};
        const content = std.Io.Dir.cwd().readFileAlloc(
            @import("../runtime_016.zig").io(),
            path,
            allocator,
            .limited(4096),
        ) catch return config;
        defer allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " ");
                const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \"");
                if (std.mem.eql(u8, key, "theme")) {
                    const duped = try allocator.dupe(u8, value);
                    if (config.theme.len > 0) allocator.free(config.theme);
                    config.theme = duped;
                } else if (std.mem.eql(u8, key, "tab_width")) {
                    config.tab_width = std.fmt.parseInt(usize, value, 10) catch 4;
                } else if (std.mem.eql(u8, key, "use_spaces")) {
                    config.use_spaces = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "show_line_numbers")) {
                    config.show_line_numbers = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "show_gutter")) {
                    config.show_gutter = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "highlight_current_line")) {
                    config.highlight_current_line = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "font_size")) {
                    config.font_size = std.fmt.parseInt(u8, value, 10) catch 14;
                } else if (std.mem.eql(u8, key, "line_wrap")) {
                    config.line_wrap = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "auto_indent")) {
                    config.auto_indent = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "auto_save")) {
                    config.auto_save = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "format_on_save")) {
                    config.format_on_save = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "auto_install_lsp")) {
                    config.auto_install_lsp = !std.mem.eql(u8, value, "false");
                } else if (std.mem.eql(u8, key, "scrolloff")) {
                    config.scrolloff = std.fmt.parseInt(usize, value, 10) catch 4;
                } else if (std.mem.eql(u8, key, "mouse")) {
                    config.mouse = !std.mem.eql(u8, value, "false");
                }
            }
        }
        return config;
    }

    pub fn save(self: *const EditorConfig, allocator: Allocator, path: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;
        try w.print("theme = {s}\n", .{self.theme});
        try w.print("tab_width = {}\n", .{self.tab_width});
        try w.print("use_spaces = {}\n", .{self.use_spaces});
        try w.print("show_line_numbers = {}\n", .{self.show_line_numbers});
        try w.print("show_gutter = {}\n", .{self.show_gutter});
        try w.print("highlight_current_line = {}\n", .{self.highlight_current_line});
        try w.print("font_size = {}\n", .{self.font_size});
        try w.print("line_wrap = {}\n", .{self.line_wrap});
        try w.print("auto_indent = {}\n", .{self.auto_indent});
        try w.print("auto_save = {}\n", .{self.auto_save});
        try w.print("format_on_save = {}\n", .{self.format_on_save});
        try w.print("auto_install_lsp = {}\n", .{self.auto_install_lsp});
        try w.print("scrolloff = {}\n", .{self.scrolloff});
        try w.print("mouse = {}\n", .{self.mouse});
        try std.Io.Dir.cwd().writeFile(
            @import("../runtime_016.zig").io(),
            .{ .sub_path = path, .data = buf.written() },
        );
    }
};
