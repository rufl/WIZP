// WIZP EditorRenderer — extracted from Editor.zig monolith
// Contains the VSCode color palette and sidebar render helpers.

const std = @import("std");
const Theme = @import("../theme/Theme.zig");
const Color = Theme.Color;
const Experience = @import("../polish/Experience.zig");
const Terminal = @import("Terminal.zig").Terminal;

pub const FileTreeEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    git_status: ?u8 = null,
};

/// VSCode color palette (default dark theme)
pub const VSColors = struct {
    pub const bg = Color.fromHex(0x1E1E1E);
    pub const sidebar_bg = Color.fromHex(0x252526);
    pub const activity_bg = Color.fromHex(0x333333);
    pub const activity_active = Color.fromHex(0xFFFFFF);
    pub const activity_inactive = Color.fromHex(0x858585);
    pub const tab_bg = Color.fromHex(0x2D2D2D); // Inactive tab
    pub const tab_active_bg = Color.fromHex(0x1E1E1E);
    pub const tab_border = Color.fromHex(0x252526);
    pub const status_bg = Color.fromHex(0x007ACC);
    pub const status_fg = Color.fromHex(0xFFFFFF);
    pub const status_dim = Color.fromHex(0xBBBBBB);
    pub const panel_bg = Color.fromHex(0x1E1E1E);
    pub const panel_border = Color.fromHex(0x474747);
    pub const breadcrumb_bg = Color.fromHex(0x1E1E1E);
    pub const breadcrumb_fg = Color.fromHex(0xCCCCCC);
    pub const line_num_fg = Color.fromHex(0x858585);
    pub const line_num_active_fg = Color.fromHex(0xC6C6C6);
    pub const scrollbar_bg = Color.fromHex(0x1E1E1E);
    pub const scrollbar_fg = Color.fromHex(0x424242);
    pub const selection_bg = Color.fromHex(0x264F78);
    pub const cursor_fg = Color.fromHex(0xFFFFFF);
    pub const match_bracket_bg = Color.fromHex(0x515C6A);
    pub const whitespace_fg = Color.fromHex(0x3B3B3B);
};

/// Render search sidebar content
pub fn renderSearchSidebar(terminal: *Terminal, rows: usize, x: usize) !void {
    _ = rows;
    var y: usize = 1;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("🔍 Search in files...", .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
    y += 2;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("Type to search across project", .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
}

/// Render source control sidebar
pub fn renderGitSidebar(terminal: *Terminal, rows: usize, x: usize, branch: ?[]const u8, items: []const []const u8, err_msg: ?[]const u8) !void {
    var y: usize = 1;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("⑂ Source Control", .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg, .bold = true });
    y += 2;

    if (err_msg) |m| {
        try terminal.moveTo(y, x + 1);
        try terminal.writeStyled(m, .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
        return;
    }

    if (branch) |b| {
        try terminal.moveTo(y, x + 1);
        try terminal.writeStyled("On ", .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
        try terminal.writeStyled(b, .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg, .bold = true });
        y += 2;
    }

    if (items.len == 0) {
        try terminal.moveTo(y, x + 1);
        try terminal.writeStyled("Working tree clean", .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
        return;
    }

    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("Changes", .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg, .bold = true });
    y += 1;

    const max_y = if (rows > 2) rows - 2 else rows;
    var i: usize = 0;
    while (i < items.len and y < max_y) : (i += 1) {
        try terminal.moveTo(y, x + 1);
        try terminal.writeStyled(items[i], .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg });
        y += 1;
    }
}

/// Render debug sidebar
pub fn renderDebugSidebar(terminal: *Terminal, rows: usize, x: usize) !void {
    _ = rows;
    var y: usize = 1;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("🐛 Debug", .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg, .bold = true });
    y += 2;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("No debug configuration", .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });
}

/// Render file tree sidebar
pub fn renderFileTree(terminal: *Terminal, rows: usize, x: usize, w: usize, cwd_label: []const u8, entries: []const FileTreeEntry, selected: usize) !void {
    var y: usize = 1;
    try terminal.moveTo(y, x + 1);
    try terminal.writeStyled("Explorer", .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg, .bold = true });
    try terminal.writeStyled(" ", .{ .foreground = VSColors.breadcrumb_fg, .background = VSColors.sidebar_bg });
    const dir_preview = if (cwd_label.len > w - 10) cwd_label[0..@min(cwd_label.len, w - 10)] else cwd_label;
    try terminal.writeStyled(dir_preview, .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg });

    y += 1;
    const max_y = if (rows > 2) rows - 1 else rows;
    var i: usize = 0;
    while (i < entries.len and y < max_y) : (i += 1) {
        const entry = entries[i];
        const is_selected = i == selected;
        const bg = if (is_selected) VSColors.selection_bg else VSColors.sidebar_bg;
        const icon = if (entry.kind == .directory) "📁 " else Experience.FileIcons.getIcon(entry.name);
        const name = if (entry.name.len > w - 5) entry.name[0..@min(entry.name.len, w - 7)] else entry.name;
        const fg = if (entry.kind == .directory) VSColors.status_bg else VSColors.breadcrumb_fg;

        try terminal.moveTo(y, x + 1);
        if (entry.git_status) |st| {
            const st_fg = switch (st) {
                'M' => VSColors.status_bg,
                'A' => Color.fromHex(0x89D185),
                'D' => Color.fromHex(0xF14C4C),
                else => VSColors.activity_inactive,
            };
            var st_buf: [2]u8 = .{ st, ' ' };
            try terminal.writeStyled(st_buf[0..], .{ .foreground = st_fg, .background = bg, .bold = true });
        } else {
            try terminal.writeStyled("  ", .{ .foreground = fg, .background = bg });
        }
        try terminal.writeStyled(icon, .{ .foreground = fg, .background = bg });
        try terminal.writeStyled(name, .{ .foreground = fg, .background = bg });
        y += 1;
    }
}
