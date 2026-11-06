// WIZP macOS Platform — WKWebView + Cocoa native window (Electrobun-style)
// Uses Objective-C runtime bindings to avoid needing Xcode/Swift.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) @compileError("macOS platform module only compiles on macOS");
}

var original_termios: ?std.posix.termios = null;

extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termp: ?*std.posix.termios,
    winp: ?*std.posix.winsize,
) c_int;
extern "c" fn close(fd: c_int) c_int;
pub fn openPTY() !struct { master: std.posix.fd_t, slave: std.posix.fd_t } {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
    return .{ .master = @intCast(master), .slave = @intCast(slave) };
}

pub fn resizePTY(master: std.posix.fd_t, rows: usize, cols: usize) !void {
    var ws: std.posix.winsize = .{
        .row = @intCast(rows),
        .col = @intCast(cols),
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = std.posix.system.ioctl(master, std.posix.T.IOCSWINSZ, @intFromPtr(&ws));
}

pub fn enableRawMode() !void {
    const stdin = std.Io.File.stdin();
    const fd = stdin.handle;
    const original = try std.posix.tcgetattr(fd);
    var raw = original;
    raw.lflag.icanon = false;
    raw.lflag.echo = false;
    raw.lflag.isig = false;
    raw.oflag.opost = false;
    raw.cflag.csize = .cs8;
    raw.cc[@backingInt(std.posix.V.min)] = 0;
    raw.cc[@backingInt(std.posix.V.time)] = 1;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    original_termios = original;
}

pub fn disableRawMode() !void {
    const original = original_termios orelse return;
    try std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, original);
    original_termios = null;
}

pub fn getTermSize() !struct { rows: usize, cols: usize } {
    const stdout = std.Io.File.stdout();
    const fd = stdout.handle;
    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result == 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 40, .cols = 80 };
}

pub fn createNativeWindow(title: [*:0]const u8, width: u32, height: u32, url: [*:0]const u8) !void {
    _ = title;
    _ = width;
    _ = height;
    _ = url;
    return error.NativeWindowUnavailable;
}

test "macOS PTY contract" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pty = try openPTY();
    defer {
        _ = close(@intCast(pty.master));
        _ = close(@intCast(pty.slave));
    }
}
