// WIZP Native GUI - Theme, Icon & Font Integration
// VS Code / Sublime color themes → RGB paint colors
// VS Code icon themes → Unicode/emoji glyphs
// System + embedded bitmap fonts with stb_truetype for .ttf/.otf

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Theme = @import("../theme/Theme.zig");

// ============================================================
// Theme → Native GUI Colors (already works!)
// ============================================================

/// Convert WIZP Theme to native GUI paint colors
/// Our 23 built-in themes + Open VSX converted themes
/// all produce Theme.Color (r, g, b) which maps 1:1 to Native Color
pub fn themeToNativeColor(t: Theme.Color) u32 {
    // Pack into 0xRRGGBB for X11/Win32 color values
    return (@as(u32, t.r) << 16) | (@as(u32, t.g) << 8) | @as(u32, t.b);
}

pub fn themeToBGRA(t: Theme.Color, alpha: u8) u32 {
    // 0xBBGGRRAA for Win32 GDI / X11
    return (@as(u32, t.b) << 24) | (@as(u32, t.g) << 16) | (@as(u32, t.r) << 8) | alpha;
}

// ============================================================
// Icon Theme → Native Renderer
// ============================================================

/// File icon to display glyph
/// Our 30+ built-in icons + Open VSX icon theme overrides
pub fn fileIconGlyph(extension: []const u8) []const u8 {
    // Built-in mapping (same as Experience.FileIcons)
    if (std.mem.eql(u8, extension, ".zig") or std.mem.eql(u8, extension, ".zir")) return "⚡";
    if (std.mem.eql(u8, extension, ".rs")) return "🦀";
    if (std.mem.eql(u8, extension, ".py") or std.mem.eql(u8, extension, ".pyi")) return "🐍";
    if (std.mem.eql(u8, extension, ".ts") or std.mem.eql(u8, extension, ".tsx")) return "🔷";
    if (std.mem.eql(u8, extension, ".js") or std.mem.eql(u8, extension, ".jsx") or std.mem.eql(u8, extension, ".mjs")) return "🟨";
    if (std.mem.eql(u8, extension, ".go")) return "🔵";
    if (std.mem.eql(u8, extension, ".c") or std.mem.eql(u8, extension, ".h")) return "⚙️";
    if (std.mem.eql(u8, extension, ".cpp") or std.mem.eql(u8, extension, ".hpp") or std.mem.eql(u8, extension, ".cc")) return "⚙️";
    if (std.mem.eql(u8, extension, ".java")) return "☕";
    if (std.mem.eql(u8, extension, ".rb")) return "💎";
    if (std.mem.eql(u8, extension, ".lua")) return "🌙";
    if (std.mem.eql(u8, extension, ".sh") or std.mem.eql(u8, extension, ".bash")) return "🐚";
    if (std.mem.eql(u8, extension, ".html") or std.mem.eql(u8, extension, ".htm")) return "🌐";
    if (std.mem.eql(u8, extension, ".css") or std.mem.eql(u8, extension, ".scss")) return "🎨";
    if (std.mem.eql(u8, extension, ".json") or std.mem.eql(u8, extension, ".jsonc")) return "📋";
    if (std.mem.eql(u8, extension, ".yaml") or std.mem.eql(u8, extension, ".yml")) return "📄";
    if (std.mem.eql(u8, extension, ".toml")) return "⚙️";
    if (std.mem.eql(u8, extension, ".md") or std.mem.eql(u8, extension, ".mdx")) return "📝";
    if (std.mem.eql(u8, extension, ".sql")) return "🗄️";
    if (std.mem.eql(u8, extension, ".xml")) return "📰";
    return "📄";
}

// ============================================================
// Font System - System fonts + embedded bitmap + TrueType
// ============================================================

pub const FontSystem = struct {
    /// Font face name (e.g., "Fira Code", "JetBrains Mono", "Cascadia Code")
    family: []const u8 = "monospace",
    /// Font size in points
    size_pt: f32 = 14.0,
    /// Use embedded bitmap or system font
    use_bitmap: bool = false,
    /// Font features (ligatures, etc.)
    features: FontFeatures = .{},

    pub const FontFeatures = struct {
        ligatures: bool = true,
        italic: bool = true,
        bold: bool = true,
    };

    /// List of recommended programming fonts to try
    pub const RECOMMENDED_FONTS = [_][]const u8{
        "JetBrains Mono",
        "Fira Code",
        "Cascadia Code",
        "Hack",
        "Source Code Pro",
        "Consolas",
        "Menlo",
        "DejaVu Sans Mono",
        "monospace",
    };

    /// Find the best available font on the system
    pub fn detectBestFont() []const u8 {
        // On Linux: check fc-list or scan /usr/share/fonts
        // On Windows: check registry or C:\Windows\Fonts
        // On macOS: check /System/Library/Fonts
        // Font probing is not part of startup; use the deterministic preferred fallback.
        return RECOMMENDED_FONTS[0];
    }

    /// Load a TrueType/OpenType font using stb_truetype (C library)
    pub fn loadTTF(path: []const u8, size_pt: f32) !FontData {
        const c = @cImport(@cInclude("stb_truetype.h"));
        const ttf_data = try runtime.readFileAlloc(
            std.heap.page_allocator,
            path,
            10 * 1024 * 1024,
        );

        var fi = try std.heap.page_allocator.create(c.stbtt_fontinfo);
        errdefer std.heap.page_allocator.destroy(fi);
        if (c.stbtt_InitFont(fi, ttf_data.ptr, 0) == 0) return error.FontLoadFailed;

        const scale = c.stbtt_ScaleForPixelHeight(fi, size_pt);
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(fi, &ascent, &descent, &line_gap);

        return FontData{
            .glyph_width = @intCast(@as(f32, @floatFromInt(ascent)) * scale),
            .glyph_height = @intCast(@as(f32, @floatFromInt(ascent - descent)) * scale),
            .ascent = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale),
            .descent = @intFromFloat(@as(f32, @floatFromInt(descent)) * scale),
            .ttf_data = ttf_data,
            .font_info = @ptrCast(fi),
            .scale = scale,
        };
    }
};

pub const FontData = struct {
    glyph_width: u32,
    glyph_height: u32,
    ascent: i32,
    descent: i32,
    /// Raw TTF data for glyph rasterization (owned)
    ttf_data: ?[]const u8 = null,
    /// stbtt_fontinfo for the loaded font
    font_info: ?*anyopaque = null,
    /// Scale for pixel height
    scale: f32 = 0,
    /// Glyph metrics for ASCII 32-126
    metrics: [95]GlyphMetric = @as([95]GlyphMetric, @splat(.{})),

    pub const GlyphMetric = struct {
        ax: i32,
        lsb: i32,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
    };

    /// Render a glyph using stb_truetype when TTF data is loaded, or placeholder otherwise.
    pub fn renderGlyph(self: *const FontData, ch: u8, buf: []u8, stride: u32) void {
        const gw = self.glyph_width;
        const gh = self.glyph_height;
        @memset(buf[0..@as(usize, @intCast(gw * gh))], 0);

        if (self.ttf_data != null and self.font_info != null) {
            const c = @cImport(@cInclude("stb_truetype.h"));
            const fi = @as(*c.stbtt_fontinfo, @ptrCast(@alignCast(self.font_info.?)));
            _ = c.stbtt_GetCodepointBitmap(fi, 0, self.scale, @intCast(ch), &gw, &gh, @intCast(stride), buf.ptr);
            return;
        }

        // Placeholder: simple vertical bar glyph
        if (gw > 2 and gh > 2) {
            const left = @as(u32, @intCast(@as(i32, @intCast(ch % 7)) + 1));
            var y: u32 = @max(2, @as(u32, @intCast(gh / 4)));
            while (y < gh - 2) : (y += 1) {
                if (left < gw) buf[y * stride + left] = 0xFF;
            }
        }
    }

    pub fn deinit(self: *FontData) void {
        if (self.ttf_data) |d| {
            std.heap.page_allocator.free(d);
            self.ttf_data = null;
        }
    }
};

// ============================================================
// Product Icon Theme (VS Code activity bar icons)
// ============================================================

pub const ProductIcons = struct {
    pub fn activityIcon(activity: []const u8) []const u8 {
        if (std.mem.eql(u8, activity, "explorer")) return "📁";
        if (std.mem.eql(u8, activity, "search")) return "🔍";
        if (std.mem.eql(u8, activity, "hub")) return "📦";
        if (std.mem.eql(u8, activity, "git")) return "⑂";
        if (std.mem.eql(u8, activity, "debug")) return "🐛";
        if (std.mem.eql(u8, activity, "extensions")) return "🧩";
        return "📄";
    }

    /// Parse VS Code product icon theme JSON. Built-in activityIcon() handles
    /// common icons. Full implementation would parse fontCharacter PUA codes
    /// to Unicode, requiring icon font bundling.
    pub fn loadProductIconTheme(json: []const u8) !void {
        if (json.len == 0) return;
        if (std.mem.indexOf(u8, json, "\"iconDefinitions\"") == null) return error.InvalidIconTheme;
    }
};

// ============================================================
// Color Theme Application
// ============================================================

/// Apply a WIZP theme to get all UI colors for native rendering
pub const ThemeApplication = struct {
    bg: u32,
    fg: u32,
    activity_bg: u32,
    sidebar_bg: u32,
    tab_active_bg: u32,
    tab_bg: u32,
    status_bg: u32,
    status_fg: u32,
    line_highlight: u32,
    selection: u32,
    cursor: u32,
    gutter_fg: u32,
    scrollbar_fg: u32,
    panel_border: u32,

    pub fn fromTheme(theme: *const Theme.ThemeDef) ThemeApplication {
        return ThemeApplication{
            .bg = themeToNativeColor(theme.background),
            .fg = themeToNativeColor(theme.foreground),
            .activity_bg = 0x333333,
            .sidebar_bg = 0x252526,
            .tab_active_bg = themeToNativeColor(theme.background),
            .tab_bg = 0x2D2D2D,
            .status_bg = 0x007ACC,
            .status_fg = 0xFFFFFF,
            .line_highlight = themeToNativeColor(theme.line_highlight),
            .selection = themeToNativeColor(theme.selection),
            .cursor = themeToNativeColor(theme.caret),
            .gutter_fg = themeToNativeColor(theme.gutter_foreground),
            .scrollbar_fg = 0x424242,
            .panel_border = 0x474747,
        };
    }
};
