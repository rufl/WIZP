// WIZP Ghostty Bindings — Real C ABI bindings for libghostty
//
// Ghostty (ghostty.org) is a GPU-accelerated terminal emulator written in Zig.
// Its C API (libghostty) provides: surface_new, surface_render, key input, PTY read.
//
// These bindings use runtime dlopen/dlsym to avoid hard compile-time dependency.
// If libghostty.so is present, GPU rendering is available. Otherwise falls back to xterm.js.
//
// C API reference: https://ghostty.org/docs/api/c

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

// Ghostty C types (opaque pointers)
const ghostty_surface_t = *anyopaque;
const ghostty_allocator_t = ?*anyopaque;
const ghostty_surface_config_t = opaque {};

// Ghostty input key struct (matches ghostty_input_key_s)
const GhosttyInputKey = extern struct {
    action: GhosttyKeyAction,
    mods: GhosttyKeyMods,
    key: u32,
    text: [32]u8,
    text_len: u32,
};

const GhosttyKeyAction = enum(u32) {
    press = 0,
    repeat = 1,
    release = 2,
};

const GhosttyKeyMods = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u26 = 0,
};

// Ghostty surface config (matches ghostty_surface_config_s)
const GhosttySurfaceConfig = extern struct {
    allocator: ghostty_allocator_t,
    working_directory: ?[*:0]const u8 = null,
    command: ?[*:0]const u8 = null,
    font_size: u32 = 14,
    font_family: ?[*:0]const u8 = null,
    background: u32 = 0x1E1E2EFF,
    foreground: u32 = 0xCDD6F4FF,
    cursor_color: u32 = 0xF5E0DCFF,
    palette: [16]u32 = @as([16]u32, @splat(0)),
    cols: u32 = 80,
    rows: u32 = 24,
    cursor_style: GhosttyCursorStyle = .bar,
};

const GhosttyCursorStyle = enum(u32) {
    block = 0,
    bar = 1,
    underline = 2,
    _,
};

// Function pointer types
const GhosttySurfaceNewFn = *const fn (*GhosttySurfaceConfig) callconv(.c) ?ghostty_surface_t;
const GhosttySurfaceFreeFn = *const fn (ghostty_surface_t) callconv(.c) void;
const GhosttySurfaceRenderFn = *const fn (ghostty_surface_t, u32, u32) callconv(.c) void;
const GhosttySurfaceReadFn = *const fn (ghostty_surface_t, [*]u8, usize) callconv(.c) usize;
const GhosttySurfaceWriteFn = *const fn (ghostty_surface_t, [*]const u8, usize) callconv(.c) void;
const GhosttySurfaceSetSizeFn = *const fn (ghostty_surface_t, u32, u32, u32, u32) callconv(.c) void;
const GhosttySurfaceKeyFn = *const fn (ghostty_surface_t, GhosttyInputKey) callconv(.c) void;

/// Ghostty GPU terminal — dynamically loaded from libghostty.so
pub const Ghostty = struct {
    allocator: Allocator,
    lib: ?std.DynLib = null,
    surface: ?ghostty_surface_t = null,

    // Function pointers (null if library not loaded)
    surface_new: ?GhosttySurfaceNewFn = null,
    surface_free: ?GhosttySurfaceFreeFn = null,
    surface_render: ?GhosttySurfaceRenderFn = null,
    surface_read: ?GhosttySurfaceReadFn = null,
    surface_write: ?GhosttySurfaceWriteFn = null,
    surface_set_size: ?GhosttySurfaceSetSizeFn = null,
    surface_key: ?GhosttySurfaceKeyFn = null,

    const Self = @This();

    /// Check if libghostty is available on the system (without loading it).
    pub fn available() bool {
        if (builtin.os.tag != .linux) return false;
        // Check common install paths
        const paths = [_][]const u8{
            "/usr/lib/libghostty.so",
            "/usr/local/lib/libghostty.so",
            "/usr/lib/x86_64-linux-gnu/libghostty.so",
        };
        for (paths) |path| {
            std.Io.Dir.accessAbsolute(
                @import("../runtime_016.zig").io(),
                path,
                .{},
            ) catch continue;
            return true;
        }
        return false;
    }

    /// Initialize Ghostty runtime. Tries to load libghostty dynamically.
    /// Returns initialized Ghostty even if library not found (available() = false).
    pub fn init(allocator: Allocator) Self {
        var self = Self{ .allocator = allocator };

        const lib_paths = [_][]const u8{
            "libghostty.so",
            "libghostty.so.0",
            "/usr/lib/libghostty.so",
            "/usr/local/lib/libghostty.so",
            "/usr/lib/x86_64-linux-gnu/libghostty.so",
        };

        for (lib_paths) |path| {
            const lib = std.DynLib.open(path) catch continue;
            self.lib = lib;
            break;
        }

        if (self.lib) |*lib| {
            self.surface_new = lib.lookup(GhosttySurfaceNewFn, "ghostty_surface_new");
            self.surface_free = lib.lookup(GhosttySurfaceFreeFn, "ghostty_surface_free");
            self.surface_render = lib.lookup(GhosttySurfaceRenderFn, "ghostty_surface_render");
            self.surface_read = lib.lookup(GhosttySurfaceReadFn, "ghostty_surface_read");
            self.surface_write = lib.lookup(GhosttySurfaceWriteFn, "ghostty_surface_write");
            self.surface_set_size = lib.lookup(GhosttySurfaceSetSizeFn, "ghostty_surface_set_size");
            self.surface_key = lib.lookup(GhosttySurfaceKeyFn, "ghostty_surface_key");
        }

        return self;
    }

    /// Create a GPU-accelerated terminal surface.
    pub fn createSurface(self: *Self, cols: u32, rows: u32) !void {
        const new_fn = self.surface_new orelse return error.GhosttyNotAvailable;

        var config = GhosttySurfaceConfig{
            .allocator = null, // null allocator = use default
            .cols = cols,
            .rows = rows,
            .font_size = 14,
            .cursor_style = .bar,
            .background = 0x1E1E2EFF, // Catppuccin Mocha base
            .foreground = 0xCDD6F4FF, // Catppuccin Mocha text
            .cursor_color = 0xF5E0DCFF,
        };

        self.surface = new_fn(&config) orelse return error.GhosttySurfaceFailed;
    }

    /// Render a frame at the given pixel dimensions.
    pub fn render(self: *Self, width: u32, height: u32) !void {
        const render_fn = self.surface_render orelse return error.GhosttyNotAvailable;
        const surf = self.surface orelse return error.GhosttyNoSurface;
        render_fn(surf, width, height);
    }

    /// Read terminal output into buffer. Returns bytes read (0 = no data / EOF).
    pub fn read(self: *Self, buf: []u8) !usize {
        const read_fn = self.surface_read orelse return error.GhosttyNotAvailable;
        const surf = self.surface orelse return error.GhosttyNoSurface;
        return read_fn(surf, buf.ptr, buf.len);
    }

    /// Write user input to the terminal.
    pub fn write(self: *Self, data: []const u8) !void {
        const write_fn = self.surface_write orelse return error.GhosttyNotAvailable;
        const surf = self.surface orelse return error.GhosttyNoSurface;
        write_fn(surf, data.ptr, data.len);
    }

    /// Send a key event to the terminal.
    pub fn keyEvent(self: *Self, key: u32, mods: GhosttyKeyMods) !void {
        const key_fn = self.surface_key orelse return error.GhosttyNotAvailable;
        const surf = self.surface orelse return error.GhosttyNoSurface;
        key_fn(surf, .{
            .action = .press,
            .mods = mods,
            .key = key,
            .text = @as([32]u8, @splat(0)),
            .text_len = 0,
        });
    }

    /// Resize the terminal surface.
    pub fn setSize(self: *Self, cols: u32, rows: u32, width: u32, height: u32) !void {
        const size_fn = self.surface_set_size orelse return error.GhosttyNotAvailable;
        const surf = self.surface orelse return error.GhosttyNoSurface;
        size_fn(surf, cols, rows, width, height);
    }

    /// Get the Ghostty library version string.
    pub fn version(self: *Self) []const u8 {
        if (self.surface_new != null) return "ghostty (libghostty)";
        return "xterm.js (fallback)";
    }

    /// Check if Ghostty is loaded and available.
    pub fn isAvailable(self: *Self) bool {
        return self.surface_new != null and
            self.surface_render != null and
            self.surface_read != null;
    }

    pub fn deinit(self: *Self) void {
        if (self.surface) |surf| {
            if (self.surface_free) |free_fn| {
                free_fn(surf);
            }
            self.surface = null;
        }
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
        self.* = undefined;
    }
};

test "Ghostty: init and availability probe are safe" {
    var g = Ghostty.init(std.testing.allocator);
    defer g.deinit();
    if (g.isAvailable()) {
        try std.testing.expectEqualStrings("ghostty (libghostty)", g.version());
    } else {
        try std.testing.expectEqualStrings("xterm.js (fallback)", g.version());
        try std.testing.expectError(error.GhosttyNotAvailable, g.render(800, 600));
    }
}

test "Ghostty: static availability check is non-crashing" {
    _ = Ghostty.available();
}
