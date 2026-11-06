//! Stub DVUI module for compilation without DVUI dependency.
//! This provides minimal type definitions to allow the editor to compile
//! when WIZP_DVUI_AVAILABLE is false. The native GUI path via DVUI is
//! experimental and requires SDL3, OpenGL, and other heavy dependencies.

const std = @import("std");

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Size = extern struct {
    width: f32,
    height: f32,
};

pub const Point = extern struct {
    x: f32,
    y: f32,
};

pub const Context = opaque {};

pub fn beginFrame(ctx: *Context) void {
    _ = ctx;
}

pub fn endFrame(ctx: *Context) void {
    _ = ctx;
}

pub fn getScreenSize(ctx: *Context) Size {
    _ = ctx;
    return .{ .width = 1280, .height = 720 };
}

pub fn rect(ctx: *Context, r: Rect) void {
    _ = ctx;
    _ = r;
}

pub fn handleEvent(ctx: *Context, event: anytype) bool {
    _ = ctx;
    _ = event;
    return false;
}

pub fn initContext(allocator: std.mem.Allocator, options: anytype) !*Context {
    _ = allocator;
    _ = options;
    return error.DvuiNotAvailable;
}

pub fn deinitContext(ctx: *Context) void {
    _ = ctx;
}

pub fn loadFont(allocator: std.mem.Allocator, options: anytype) !*anyopaque {
    _ = allocator;
    _ = options;
    return error.DvuiNotAvailable;
}
