//! Stub SDL3 backend module for compilation without SDL3 dependency.
//! This provides minimal type definitions to allow the editor to compile.
//! The native GUI path via SDL3 is experimental and not actively maintained.

const std = @import("std");

pub const Event = extern struct {
    type: u32,
    padding: [56]u8,
};

pub const Window = extern struct {
    ptr: ?*anyopaque = null,
};

pub fn init(comptime W: type) !void {
    _ = W;
    return error.SdlInitFailed;
}

pub fn createWindow(title: [*:0]const u8, w: i32, h: i32) !Window {
    _ = title;
    _ = w;
    _ = h;
    return error.SdlWindowCreationFailed;
}

pub fn pollEvent() ?Event {
    return null;
}

pub fn getWindowSize(win: Window) struct { w: i32, h: i32 } {
    _ = win;
    return .{ .w = 800, .h = 600 };
}
