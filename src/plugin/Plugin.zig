// Plugin system for WIZP - lightweight WASM-based plugins
// PluginContext carries references to the editor's live state,
// allowing C-callable plugin functions to read/write the editor.

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    author: []const u8 = "",
    main: []const u8 = "main",
};

/// Live context passed to plugin API functions via opaque pointer.
/// Cast from `?*anyopaque` to `*PluginContext` inside API functions.
pub const PluginContext = struct {
    /// Get full text of active buffer
    getBufferText: *const fn () []const u8,
    /// Replace active buffer text
    setBufferText: *const fn ([]const u8) void,
    /// Get cursor line (0-based)
    getCursorLine: *const fn () usize,
    /// Get cursor column (0-based)
    getCursorCol: *const fn () usize,
    /// Get selected text (null if no selection)
    getSelection: *const fn () ?[]const u8,
    /// Show message in editor status bar
    showMessage: *const fn ([]const u8) void,
    /// Allocator for returning strings
    allocator: Allocator,
};

pub const PluginAPI = struct {
    pub fn getText(ptr: ?*anyopaque) callconv(.C) ?[*:0]const u8 {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return null)));
        const text = ctx.getBufferText();
        const duped = runtime.dupeZ(ctx.allocator, text) catch return null;
        return duped.ptr;
    }
    pub fn setText(ptr: ?*anyopaque, text: [*:0]const u8) callconv(.C) void {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return)));
        ctx.setBufferText(std.mem.span(text));
    }
    pub fn getCursorLine(ptr: ?*anyopaque) callconv(.C) usize {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return 0)));
        return ctx.getCursorLine();
    }
    pub fn getCursorCol(ptr: ?*anyopaque) callconv(.C) usize {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return 0)));
        return ctx.getCursorCol();
    }
    pub fn showMessage(ptr: ?*anyopaque, msg: [*:0]const u8) callconv(.C) void {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return)));
        ctx.showMessage(std.mem.span(msg));
    }
    pub fn getSelection(ptr: ?*anyopaque) callconv(.C) ?[*:0]const u8 {
        const ctx = @as(*PluginContext, @ptrCast(@alignCast(ptr orelse return null)));
        const sel = ctx.getSelection() orelse return null;
        const duped = runtime.dupeZ(ctx.allocator, sel) catch return null;
        return duped.ptr;
    }
};

pub const PluginManager = struct {
    allocator: Allocator,
    plugins: std.array_list.Managed(Plugin),

    pub const Plugin = struct {
        manifest: PluginManifest,
        loaded: bool = false,
    };

    pub fn init(allocator: Allocator) PluginManager {
        return .{ .allocator = allocator, .plugins = std.array_list.Managed(PluginManager.Plugin).init(allocator) };
    }

    /// Load a plugin from a directory containing plugin.json or package.json
    pub fn loadPlugin(self: *PluginManager, path: []const u8) !void {
        // Try plugin.json first, then package.json
        const manifest_path = try std.fs.path.join(self.allocator, &.{ path, "plugin.json" });
        defer self.allocator.free(manifest_path);

        const content = runtime.readFileAlloc(self.allocator, manifest_path, 16384) catch {
            // Try package.json fallback
            const pkg_path = try std.fs.path.join(self.allocator, &.{ path, "package.json" });
            defer self.allocator.free(pkg_path);
            const pkg_content = runtime.readFileAlloc(self.allocator, pkg_path, 16384) catch {
                // No manifest found; register with directory name
                try self.plugins.append(.{
                    .manifest = .{
                        .name = std.fs.path.basename(path),
                        .version = "0.1.0",
                    },
                    .loaded = true,
                });
                return;
            };
            defer self.allocator.free(pkg_content);
            const manifest = try parseManifest(self.allocator, pkg_content);
            try self.plugins.append(.{ .manifest = manifest, .loaded = true });
            return;
        };
        defer self.allocator.free(content);
        const manifest = try parseManifest(self.allocator, content);
        try self.plugins.append(.{ .manifest = manifest, .loaded = true });
    }

    fn parseManifest(allocator: Allocator, json: []const u8) !PluginManifest {
        var manifest = PluginManifest{ .name = "unknown", .version = "0.1.0" };
        if (std.mem.indexOf(u8, json, "\"name\"")) |ns| {
            if (std.mem.indexOfScalarPos(u8, json, ns + 6, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    manifest.name = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOf(u8, json, "\"version\"")) |vs| {
            if (std.mem.indexOfScalarPos(u8, json, vs + 9, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    manifest.version = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOf(u8, json, "\"description\"")) |ds| {
            if (std.mem.indexOfScalarPos(u8, json, ds + 13, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    manifest.description = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOf(u8, json, "\"author\"")) |as| {
            if (std.mem.indexOfScalarPos(u8, json, as + 8, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    manifest.author = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOf(u8, json, "\"main\"")) |ms| {
            if (std.mem.indexOfScalarPos(u8, json, ms + 6, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    manifest.main = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        return manifest;
    }

    pub fn deinit(self: *PluginManager) void {
        self.plugins.deinit();
    }
};
