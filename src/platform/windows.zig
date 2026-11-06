// WIZP Windows platform contract.
// The active Windows terminal path uses zigpty/ConPTY; this legacy facade
// reports unavailable native-window operations instead of claiming success.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) @compileError("Windows platform module only compiles on Windows");
}

pub fn openPTY() !struct { master: usize, slave: usize } {
    return error.PTYUnavailable;
}

pub fn resizePTY(master: usize, rows: usize, cols: usize) !void {
    _ = master;
    _ = rows;
    _ = cols;
    return error.PTYUnavailable;
}

pub fn enableRawMode() !void {
    return error.TerminalUnavailable;
}

pub fn disableRawMode() !void {
    return error.TerminalUnavailable;
}

pub fn getTermSize() !struct { rows: usize, cols: usize } {
    return error.TerminalUnavailable;
}

pub fn createNativeWindow(title: [*:0]const u8, width: u32, height: u32, url: [*:0]const u8) !void {
    _ = title;
    _ = width;
    _ = height;
    _ = url;
    return error.NativeWindowUnavailable;
}

test "Windows platform unavailable operations are explicit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.PTYUnavailable, openPTY());
    try std.testing.expectError(error.TerminalUnavailable, getTermSize());
    try std.testing.expectError(error.NativeWindowUnavailable, createNativeWindow("", 0, 0, ""));
}
