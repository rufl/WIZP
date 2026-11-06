// Theme engine for WIZP - compatible with Sublime Text color schemes
// Supports .tmTheme (plist/XML), .sublime-color-scheme (JSON), and built-in themes

const std = @import("std");
const Allocator = std.mem.Allocator;

/// RGB color
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(hex: u24) Color {
        return .{
            .r = @intCast((hex >> 16) & 0xFF),
            .g = @intCast((hex >> 8) & 0xFF),
            .b = @intCast(hex & 0xFF),
        };
    }

    pub fn toHex(self: Color) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | @as(u24, self.b);
    }
};

/// ANSI color codes for terminal rendering
pub const AnsiColor = struct {
    pub const Reset = "\x1b[0m";
    pub const Bold = "\x1b[1m";
    pub const Dim = "\x1b[2m";
    pub const Italic = "\x1b[3m";
    pub const Underline = "\x1b[4m";
    pub const Blink = "\x1b[5m";
    pub const Reverse = "\x1b[7m";
    pub const Hidden = "\x1b[8m";

    pub fn fg(r: u8, g: u8, b: u8) [32]u8 {
        var buf: [32]u8 = @as([32]u8, @splat(0));
        _ = std.fmt.bufPrint(&buf, "\x1b[38;2;{};{};{}m", .{ r, g, b }) catch {};
        return buf;
    }

    pub fn bg(r: u8, g: u8, b: u8) [32]u8 {
        var buf: [32]u8 = @as([32]u8, @splat(0));
        _ = std.fmt.bufPrint(&buf, "\x1b[48;2;{};{};{}m", .{ r, g, b }) catch {};
        return buf;
    }
};

/// Style for a scope
pub const ScopeStyle = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// Complete theme definition
pub const ThemeDef = struct {
    allocator: Allocator,
    name: []const u8,
    author: []const u8 = "Zedit",
    /// Global settings
    background: Color = Color.fromHex(0x1E1E1E),
    foreground: Color = Color.fromHex(0xD4D4D4),
    caret: Color = Color.fromHex(0xFFFFFF),
    line_highlight: Color = Color.fromHex(0x2A2A2A),
    selection: Color = Color.fromHex(0x264F78),
    invisibles: Color = Color.fromHex(0x3B3B3B),
    gutter: Color = Color.fromHex(0x252526),
    gutter_foreground: Color = Color.fromHex(0x858585),
    /// Per-scope styles
    scopes: std.StringHashMapUnmanaged(ScopeStyle) = .empty,
    /// General scope mappings (for fallback)
    scope_map: std.StringHashMapUnmanaged(ScopeStyle) = .empty,

    pub fn deinit(self: *ThemeDef) void {
        var it = self.scopes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.scopes.deinit(self.allocator);

        var it2 = self.scope_map.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.scope_map.deinit(self.allocator);
    }
};

/// Pre-defined theme definitions (23 built-in themes)
pub fn builtinTheme(allocator: Allocator, name: []const u8) !ThemeDef {
    if (std.mem.eql(u8, name, "monokai")) return monokai(allocator);
    if (std.mem.eql(u8, name, "dracula")) return dracula(allocator);
    if (std.mem.eql(u8, name, "nord")) return nord(allocator);
    if (std.mem.eql(u8, name, "solarized-dark")) return solarizedDark(allocator);
    if (std.mem.eql(u8, name, "solarized-light")) return solarizedLight(allocator);
    if (std.mem.eql(u8, name, "gruvbox-dark")) return gruvboxDark(allocator);
    if (std.mem.eql(u8, name, "gruvbox-light")) return gruvboxLight(allocator);
    if (std.mem.eql(u8, name, "one-dark")) return oneDark(allocator);
    if (std.mem.eql(u8, name, "one-light")) return oneLight(allocator);
    if (std.mem.eql(u8, name, "catppuccin-mocha")) return catppuccinMocha(allocator);
    if (std.mem.eql(u8, name, "catppuccin-latte")) return catppuccinLatte(allocator);
    if (std.mem.eql(u8, name, "tokyo-night")) return tokyoNight(allocator);
    if (std.mem.eql(u8, name, "tokyo-night-storm")) return tokyoNightStorm(allocator);
    if (std.mem.eql(u8, name, "ayu-dark")) return ayuDark(allocator);
    if (std.mem.eql(u8, name, "ayu-mirage")) return ayuMirage(allocator);
    if (std.mem.eql(u8, name, "github-dark")) return githubDark(allocator);
    if (std.mem.eql(u8, name, "github-light")) return githubLight(allocator);
    if (std.mem.eql(u8, name, "material-darker")) return materialDarker(allocator);
    if (std.mem.eql(u8, name, "palenight")) return palenight(allocator);
    if (std.mem.eql(u8, name, "oceanic-next")) return oceanicNext(allocator);
    if (std.mem.eql(u8, name, "zenburn")) return zenburn(allocator);
    if (std.mem.eql(u8, name, "molokai")) return molokai(allocator);
    if (std.mem.eql(u8, name, "paseo")) return paseo(allocator);

    return error.UnknownTheme;
}

/// List all available built-in themes
pub fn listThemes() []const []const u8 {
    return &.{
        "monokai",          "dracula",       "nord",              "solarized-dark", "solarized-light",
        "gruvbox-dark",     "gruvbox-light", "one-dark",          "one-light",      "catppuccin-mocha",
        "catppuccin-latte", "tokyo-night",   "tokyo-night-storm", "ayu-dark",       "ayu-mirage",
        "github-dark",      "github-light",  "material-darker",   "palenight",      "oceanic-next",
        "zenburn",          "molokai",       "paseo",
    };
}

/// Get scope style for a given scope selector
pub fn getScopeStyle(theme: *const ThemeDef, scope: []const u8) ScopeStyle {
    // Try exact match first
    if (theme.scopes.get(scope)) |style| return style;

    // Try parent scopes (right to left)
    var s = scope;
    while (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
        s = scope[0..dot];
        if (theme.scopes.get(s)) |style| return style;
    }

    // Try scope_map
    if (theme.scope_map.get(scope)) |style| return style;

    // Default
    return .{ .foreground = theme.foreground };
}

/// ANSI SGR escape sequence for a given style.
/// Returns a slice into a static buffer; valid until next call to styleToAnsi.
pub fn styleToAnsi(style: ScopeStyle) []const u8 {
    const sgr_buf = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
    };
    sgr_buf.len = 0;

    // Reset
    sgr_buf.buf[sgr_buf.len] = 0x1b;
    sgr_buf.len += 1;
    sgr_buf.buf[sgr_buf.len] = '[';
    sgr_buf.len += 1;

    var need_sep = false;
    if (style.bold) {
        if (need_sep) {
            sgr_buf.buf[sgr_buf.len] = ';';
            sgr_buf.len += 1;
        }
        sgr_buf.buf[sgr_buf.len] = '1';
        sgr_buf.len += 1;
        need_sep = true;
    }
    if (style.italic) {
        if (need_sep) {
            sgr_buf.buf[sgr_buf.len] = ';';
            sgr_buf.len += 1;
        }
        sgr_buf.buf[sgr_buf.len] = '3';
        sgr_buf.len += 1;
        need_sep = true;
    }
    if (style.underline) {
        if (need_sep) {
            sgr_buf.buf[sgr_buf.len] = ';';
            sgr_buf.len += 1;
        }
        sgr_buf.buf[sgr_buf.len] = '4';
        sgr_buf.len += 1;
        need_sep = true;
    }

    // Foreground color
    if (style.foreground) |fg| {
        if (need_sep) {
            sgr_buf.buf[sgr_buf.len] = ';';
            sgr_buf.len += 1;
        }
        const fg_str = std.fmt.bufPrint(sgr_buf.buf[sgr_buf.len..], "38;2;{};{};{}", .{ fg.r, fg.g, fg.b }) catch "0";
        sgr_buf.len += fg_str.len;
        need_sep = true;
    }

    // Background color
    if (style.background) |bg| {
        if (need_sep) {
            sgr_buf.buf[sgr_buf.len] = ';';
            sgr_buf.len += 1;
        }
        const bg_str = std.fmt.bufPrint(sgr_buf.buf[sgr_buf.len..], "48;2;{};{};{}", .{ bg.r, bg.g, bg.b }) catch "0";
        sgr_buf.len += bg_str.len;
    }

    sgr_buf.buf[sgr_buf.len] = 'm';
    sgr_buf.len += 1;
    return sgr_buf.buf[0..sgr_buf.len];
}

// Helper to set scope style using the theme's allocator
fn setScope(t: *ThemeDef, scope: []const u8, style: ScopeStyle) !void {
    const key = try t.allocator.dupe(u8, scope);
    try t.scopes.put(t.allocator, key, style);
}

fn monokai(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Monokai",
        .author = "Wimer Hazenberg",
        .background = Color.fromHex(0x272822),
        .foreground = Color.fromHex(0xF8F8F2),
        .caret = Color.fromHex(0xF8F8F0),
        .line_highlight = Color.fromHex(0x3E3D32),
        .selection = Color.fromHex(0x49483E),
        .gutter = Color.fromHex(0x272822),
        .gutter_foreground = Color.fromHex(0x75715E),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x75715E), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xE6DB74) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xAE81FF) });
    try setScope(&t, "constant.language", .{ .foreground = Color.fromHex(0xAE81FF) });
    try setScope(&t, "constant.character", .{ .foreground = Color.fromHex(0xAE81FF) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0x66D9EF) });
    try setScope(&t, "storage.modifier", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x66D9EF) });
    try setScope(&t, "support.function.builtin", .{ .foreground = Color.fromHex(0x66D9EF) });
    try setScope(&t, "entity.name", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "variable", .{ .foreground = Color.fromHex(0xF8F8F2) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFD971F) });
    try setScope(&t, "variable.parameter", .{ .foreground = Color.fromHex(0xFD971F) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "markup.bold", .{ .foreground = Color.fromHex(0xF92672), .bold = true });
    try setScope(&t, "markup.italic", .{ .foreground = Color.fromHex(0xF92672), .italic = true });
    try setScope(&t, "markup.raw", .{ .foreground = Color.fromHex(0xE6DB74) });
    try setScope(&t, "markup.link", .{ .foreground = Color.fromHex(0x66D9EF), .underline = true });

    return t;
}

fn dracula(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Dracula",
        .author = "Zeno Rocha",
        .background = Color.fromHex(0x282A36),
        .foreground = Color.fromHex(0xF8F8F2),
        .caret = Color.fromHex(0xF8F8F2),
        .line_highlight = Color.fromHex(0x313340),
        .selection = Color.fromHex(0x44475A),
        .gutter = Color.fromHex(0x282A36),
        .gutter_foreground = Color.fromHex(0x6272A4),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x6272A4), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xF1FA8C) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xBD93F9) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xFF79C6) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xFF79C6) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xFF79C6) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0x8BE9FD) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x50FA7B) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x50FA7B) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0x8BE9FD) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xFF79C6) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xBD93F9) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0xBD93F9), .bold = true });
    try setScope(&t, "markup.bold", .{ .bold = true });
    try setScope(&t, "markup.italic", .{ .italic = true });

    return t;
}

fn nord(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Nord",
        .author = "Arctic Ice Studio",
        .background = Color.fromHex(0x2E3440),
        .foreground = Color.fromHex(0xD8DEE9),
        .caret = Color.fromHex(0xD8DEE9),
        .line_highlight = Color.fromHex(0x3B4252),
        .selection = Color.fromHex(0x434C5E),
        .gutter = Color.fromHex(0x2E3440),
        .gutter_foreground = Color.fromHex(0x4C566A),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x616E88), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xA3BE8C) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xB48EAD) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x81A1C1) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x81A1C1) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x81A1C1) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0x81A1C1) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x88C0D0) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x88C0D0) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0x8FBCBB) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x81A1C1) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xD08770) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0x8FBCBB), .bold = true });

    return t;
}

fn solarizedDark(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Solarized Dark",
        .author = "Ethan Schoonover",
        .background = Color.fromHex(0x002B36),
        .foreground = Color.fromHex(0x839496),
        .caret = Color.fromHex(0x839496),
        .line_highlight = Color.fromHex(0x073642),
        .selection = Color.fromHex(0x073642),
        .gutter = Color.fromHex(0x002B36),
        .gutter_foreground = Color.fromHex(0x586E75),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x586E75), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x2AA198) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xD33682) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x859900) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x859900) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x859900) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xB58900) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xB58900) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0x268BD2), .bold = true });

    return t;
}

fn solarizedLight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Solarized Light",
        .author = "Ethan Schoonover",
        .background = Color.fromHex(0xFDF6E3),
        .foreground = Color.fromHex(0x657B83),
        .caret = Color.fromHex(0x657B83),
        .line_highlight = Color.fromHex(0xEEE8D5),
        .selection = Color.fromHex(0xEEE8D5),
        .gutter = Color.fromHex(0xFDF6E3),
        .gutter_foreground = Color.fromHex(0x93A1A1),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x93A1A1), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x2AA198) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xD33682) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x859900) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x859900) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xB58900) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xB58900) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x268BD2) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0x268BD2) });

    return t;
}

fn gruvboxDark(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Gruvbox Dark",
        .author = "Pavel Pertsev",
        .background = Color.fromHex(0x282828),
        .foreground = Color.fromHex(0xEBDBB2),
        .caret = Color.fromHex(0xEBDBB2),
        .line_highlight = Color.fromHex(0x3C3836),
        .selection = Color.fromHex(0x504945),
        .gutter = Color.fromHex(0x282828),
        .gutter_foreground = Color.fromHex(0x7C6F64),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x928374), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xB8BB26) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xD3869B) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xFB4934) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xFB4934) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xFB4934) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFABD2F) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x83A598) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x83A598) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFABD2F) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xFB4934) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFE8019) });

    return t;
}

fn gruvboxLight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Gruvbox Light",
        .author = "Pavel Pertsev",
        .background = Color.fromHex(0xFBF1C7),
        .foreground = Color.fromHex(0x3C3836),
        .caret = Color.fromHex(0x3C3836),
        .line_highlight = Color.fromHex(0xEBDBB2),
        .selection = Color.fromHex(0xD5C4A1),
        .gutter = Color.fromHex(0xFBF1C7),
        .gutter_foreground = Color.fromHex(0xBDAA93),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x928374), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x79740E) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0x8F3F71) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x9D0006) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x9D0006) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xB57614) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x076678) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x076678) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xB57614) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x9D0006) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xAF3A03) });

    return t;
}

fn oneDark(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "One Dark",
        .author = "Atom",
        .background = Color.fromHex(0x282C34),
        .foreground = Color.fromHex(0xABB2BF),
        .caret = Color.fromHex(0x528BFF),
        .line_highlight = Color.fromHex(0x2C313C),
        .selection = Color.fromHex(0x3E4451),
        .gutter = Color.fromHex(0x282C34),
        .gutter_foreground = Color.fromHex(0x636D83),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x5C6370), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x98C379) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xD19A66) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xC678DD) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xC678DD) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x56B6C2) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xE5C07B) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x61AFEF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x61AFEF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xE5C07B) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xE06C75) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xE06C75) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0xE06C75), .bold = true });

    return t;
}

fn oneLight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "One Light",
        .author = "Atom",
        .background = Color.fromHex(0xFAFAFA),
        .foreground = Color.fromHex(0x383A42),
        .caret = Color.fromHex(0x526FFF),
        .line_highlight = Color.fromHex(0xF0F0F0),
        .selection = Color.fromHex(0xE5E5E6),
        .gutter = Color.fromHex(0xFAFAFA),
        .gutter_foreground = Color.fromHex(0x9D9D9F),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0xA0A1A7), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x50A14F) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0x986801) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xA626A4) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xA626A4) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xC18401) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x4078F2) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x4078F2) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xC18401) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xE45649) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xE45649) });

    return t;
}

fn catppuccinMocha(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Catppuccin Mocha",
        .author = "Catppuccin",
        .background = Color.fromHex(0x1E1E2E),
        .foreground = Color.fromHex(0xCDD6F4),
        .caret = Color.fromHex(0xF5E0DC),
        .line_highlight = Color.fromHex(0x313244),
        .selection = Color.fromHex(0x45475A),
        .gutter = Color.fromHex(0x1E1E2E),
        .gutter_foreground = Color.fromHex(0x6C7086),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x6C7086), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xA6E3A1) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFAB387) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xCBA6F7) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xCBA6F7) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x89DCEB) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xF9E2AF) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x89B4FA) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x89B4FA) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xF9E2AF) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF38BA8) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF38BA8) });

    return t;
}

fn catppuccinLatte(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Catppuccin Latte",
        .author = "Catppuccin",
        .background = Color.fromHex(0xEFF1F5),
        .foreground = Color.fromHex(0x4C4F69),
        .caret = Color.fromHex(0xDC8A78),
        .line_highlight = Color.fromHex(0xE6E9EF),
        .selection = Color.fromHex(0xCCD0DA),
        .gutter = Color.fromHex(0xEFF1F5),
        .gutter_foreground = Color.fromHex(0x9CA0B0),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x9CA0B0), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x40A02B) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFE640B) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x8839EF) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x8839EF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xDF8E1D) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x1E66F5) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x1E66F5) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xDF8E1D) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xD20F39) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xD20F39) });

    return t;
}

fn tokyoNight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Tokyo Night",
        .author = "Enkia",
        .background = Color.fromHex(0x1A1B26),
        .foreground = Color.fromHex(0xC0CAF5),
        .caret = Color.fromHex(0xC0CAF5),
        .line_highlight = Color.fromHex(0x292E42),
        .selection = Color.fromHex(0x364A82),
        .gutter = Color.fromHex(0x1A1B26),
        .gutter_foreground = Color.fromHex(0x565F89),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x565F89), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x9ECE6A) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFF9E64) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0x9D7CD8) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0x9D7CD8) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x89DDFF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xE0AF68) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x7DCFFF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x7DCFFF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xE0AF68) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF7768E) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF7768E) });

    return t;
}

fn tokyoNightStorm(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Tokyo Night Storm",
        .author = "Enkia",
        .background = Color.fromHex(0x24283B),
        .foreground = Color.fromHex(0xC0CAF5),
        .caret = Color.fromHex(0xC0CAF5),
        .line_highlight = Color.fromHex(0x2F344D),
        .selection = Color.fromHex(0x364A82),
        .gutter = Color.fromHex(0x24283B),
        .gutter_foreground = Color.fromHex(0x565F89),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x565F89), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x9ECE6A) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFF9E64) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xBB9AF7) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xBB9AF7) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x7DCFFF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xE0AF68) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x7DCFFF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x7DCFFF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xE0AF68) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF7768E) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF7768E) });

    return t;
}

fn ayuDark(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Ayu Dark",
        .author = "Ike Ku",
        .background = Color.fromHex(0x0A0E14),
        .foreground = Color.fromHex(0xB3B1AD),
        .caret = Color.fromHex(0xFFEE99),
        .line_highlight = Color.fromHex(0x131721),
        .selection = Color.fromHex(0x253340),
        .gutter = Color.fromHex(0x0A0E14),
        .gutter_foreground = Color.fromHex(0x4D5566),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x626A73), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xC2D94C) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFF8F40) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xFF8F40) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xFF8F40) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x39BAE6) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFFB454) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x73B8FF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0xFFD173) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFFB454) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x39BAE6) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFF8F40) });

    return t;
}

fn ayuMirage(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Ayu Mirage",
        .author = "Ike Ku",
        .background = Color.fromHex(0x1F2430),
        .foreground = Color.fromHex(0xCBCCC6),
        .caret = Color.fromHex(0xFFCC66),
        .line_highlight = Color.fromHex(0x2A2E3A),
        .selection = Color.fromHex(0x33415E),
        .gutter = Color.fromHex(0x1F2430),
        .gutter_foreground = Color.fromHex(0x5C6773),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x5C6773), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xBBE67E) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFFAE57) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xFFAE57) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xFFAE57) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x39BAE6) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFFD580) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x73D0FF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0xFFD173) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFFD580) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x5CCFE6) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFFAE57) });

    return t;
}

fn githubDark(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "GitHub Dark",
        .author = "GitHub",
        .background = Color.fromHex(0x0D1117),
        .foreground = Color.fromHex(0xC9D1D9),
        .caret = Color.fromHex(0x58A6FF),
        .line_highlight = Color.fromHex(0x161B22),
        .selection = Color.fromHex(0x264F78),
        .gutter = Color.fromHex(0x0D1117),
        .gutter_foreground = Color.fromHex(0x484F58),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x8B949E) });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xA5D6FF) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0x79C0FF) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xFF7B72) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xFF7B72) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xFF7B72) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFF7B72) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0xD2A8FF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0xD2A8FF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFFA657) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x7EE787) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFF7B72) });

    return t;
}

fn githubLight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "GitHub Light",
        .author = "GitHub",
        .background = Color.fromHex(0xFFFFFF),
        .foreground = Color.fromHex(0x24292F),
        .caret = Color.fromHex(0x0969DA),
        .line_highlight = Color.fromHex(0xF6F8FA),
        .selection = Color.fromHex(0xAFE0FF),
        .gutter = Color.fromHex(0xFFFFFF),
        .gutter_foreground = Color.fromHex(0x6E7781),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x6E7781) });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x0A3069) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0x0550AE) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xCF222E) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xCF222E) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xCF222E) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x8250DF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x8250DF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0x953800) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0x116329) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xCF222E) });

    return t;
}

fn materialDarker(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Material Darker",
        .author = "Mattia Astorino",
        .background = Color.fromHex(0x212121),
        .foreground = Color.fromHex(0xEEFFFF),
        .caret = Color.fromHex(0xFFCC00),
        .line_highlight = Color.fromHex(0x2C2C2C),
        .selection = Color.fromHex(0x424242),
        .gutter = Color.fromHex(0x212121),
        .gutter_foreground = Color.fromHex(0x616161),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x616161), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xC3E88D) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xF78C6C) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xC792EA) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xC792EA) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x89DDFF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFFCB6B) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x82AAFF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x82AAFF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFFCB6B) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF07178) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF07178) });

    return t;
}

fn palenight(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Palenight",
        .author = "Olaolu Olawuyi",
        .background = Color.fromHex(0x292D3E),
        .foreground = Color.fromHex(0xA6ACCD),
        .caret = Color.fromHex(0xFFCC00),
        .line_highlight = Color.fromHex(0x34324A),
        .selection = Color.fromHex(0x444267),
        .gutter = Color.fromHex(0x292D3E),
        .gutter_foreground = Color.fromHex(0x676E95),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x676E95), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xC3E88D) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xF78C6C) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xC792EA) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xC792EA) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x89DDFF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFFCB6B) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x82AAFF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x82AAFF) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFFCB6B) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF07178) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF07178) });

    return t;
}

fn oceanicNext(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Oceanic Next",
        .author = "Dmitri Voronianski",
        .background = Color.fromHex(0x1B2B34),
        .foreground = Color.fromHex(0xCDD3DE),
        .caret = Color.fromHex(0xD8DEE9),
        .line_highlight = Color.fromHex(0x243540),
        .selection = Color.fromHex(0x34495E),
        .gutter = Color.fromHex(0x1B2B34),
        .gutter_foreground = Color.fromHex(0x65737E),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x65737E), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x99C794) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xF99157) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xC594C5) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xC594C5) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0x5FB3B3) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xFAC863) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x6699CC) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x6699CC) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xFAC863) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xEC5F67) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xEC5F67) });

    return t;
}

fn zenburn(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Zenburn",
        .author = "Jani Nurminen",
        .background = Color.fromHex(0x3F3F3F),
        .foreground = Color.fromHex(0xDCDCCC),
        .caret = Color.fromHex(0xDCDCCC),
        .line_highlight = Color.fromHex(0x4B4B4B),
        .selection = Color.fromHex(0x5F5F5F),
        .gutter = Color.fromHex(0x3F3F3F),
        .gutter_foreground = Color.fromHex(0x7F9F7F),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x7F9F7F), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xCC9393) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0x8CD0D3) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xF0DFAF) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xF0DFAF) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xF0DFAF) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xDFAF8F) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x93E0E3) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x93E0E3) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xDFAF8F) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xEC93D3) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xEC93D3) });

    return t;
}

fn molokai(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Molokai",
        .author = "Tomas Restrepo",
        .background = Color.fromHex(0x1B1D1E),
        .foreground = Color.fromHex(0xF8F8F2),
        .caret = Color.fromHex(0xF8F8F0),
        .line_highlight = Color.fromHex(0x292929),
        .selection = Color.fromHex(0x3E3E3E),
        .gutter = Color.fromHex(0x1B1D1E),
        .gutter_foreground = Color.fromHex(0x465457),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x465457), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0xE6DB74) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xAE81FF) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0x66D9EF) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x66D9EF) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0xA6E22E) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF92672) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xFD971F) });

    return t;
}

fn paseo(allocator: Allocator) !ThemeDef {
    var t = ThemeDef{
        .allocator = allocator,
        .name = "Paseo",
        .author = "Paseo",
        .background = Color.fromHex(0x000000),
        .foreground = Color.fromHex(0xE4E4E7),
        .caret = Color.fromHex(0xF4F4F5),
        .line_highlight = Color.fromHex(0x18181B),
        .selection = Color.fromHex(0x27272A),
        .invisibles = Color.fromHex(0x3F3F46),
        .gutter = Color.fromHex(0x000000),
        .gutter_foreground = Color.fromHex(0x71717A),
    };
    t.scopes = std.StringHashMapUnmanaged(ScopeStyle){};
    t.scope_map = std.StringHashMapUnmanaged(ScopeStyle){};

    // Zinc neutrals keep prose and comments legible against the black editor.
    try setScope(&t, "comment", .{ .foreground = Color.fromHex(0x71717A), .italic = true });
    try setScope(&t, "string", .{ .foreground = Color.fromHex(0x4ADE80) });
    try setScope(&t, "constant", .{ .foreground = Color.fromHex(0xFBBF24) });
    try setScope(&t, "constant.numeric", .{ .foreground = Color.fromHex(0xFBBF24) });
    try setScope(&t, "constant.language", .{ .foreground = Color.fromHex(0xFBBF24) });
    try setScope(&t, "constant.character", .{ .foreground = Color.fromHex(0xFBBF24) });
    try setScope(&t, "keyword", .{ .foreground = Color.fromHex(0xC084FC) });
    try setScope(&t, "keyword.control", .{ .foreground = Color.fromHex(0xC084FC) });
    try setScope(&t, "keyword.operator", .{ .foreground = Color.fromHex(0xA78BFA) });
    try setScope(&t, "storage", .{ .foreground = Color.fromHex(0xC084FC) });
    try setScope(&t, "storage.type", .{ .foreground = Color.fromHex(0xC084FC) });
    try setScope(&t, "storage.modifier", .{ .foreground = Color.fromHex(0xA78BFA) });
    try setScope(&t, "support", .{ .foreground = Color.fromHex(0x22D3EE) });
    try setScope(&t, "support.function", .{ .foreground = Color.fromHex(0x60A5FA) });
    try setScope(&t, "support.function.builtin", .{ .foreground = Color.fromHex(0x60A5FA) });
    try setScope(&t, "entity.name", .{ .foreground = Color.fromHex(0x60A5FA) });
    try setScope(&t, "entity.name.function", .{ .foreground = Color.fromHex(0x60A5FA) });
    try setScope(&t, "entity.name.type", .{ .foreground = Color.fromHex(0x22D3EE) });
    try setScope(&t, "entity.name.tag", .{ .foreground = Color.fromHex(0xF472B6) });
    try setScope(&t, "variable", .{ .foreground = Color.fromHex(0xE4E4E7) });
    try setScope(&t, "variable.language", .{ .foreground = Color.fromHex(0xF472B6) });
    try setScope(&t, "variable.parameter", .{ .foreground = Color.fromHex(0xFDBA74) });
    try setScope(&t, "markup.heading", .{ .foreground = Color.fromHex(0x60A5FA), .bold = true });
    try setScope(&t, "markup.bold", .{ .foreground = Color.fromHex(0xF4F4F5), .bold = true });
    try setScope(&t, "markup.italic", .{ .foreground = Color.fromHex(0xD4D4D8), .italic = true });
    try setScope(&t, "markup.raw", .{ .foreground = Color.fromHex(0x4ADE80) });
    try setScope(&t, "markup.link", .{ .foreground = Color.fromHex(0x60A5FA), .underline = true });

    return t;
}
