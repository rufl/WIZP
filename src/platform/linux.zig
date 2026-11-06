// WIZP Platform Abstraction — Linux
// Provides OS-specific implementations for PTY, terminal I/O, and process spawning.
// Future: macOS and Windows modules selected via comptime switch on builtin.os.tag.

const std = @import("std");
var original_termios: ?std.posix.termios = null;

// PTY functions are declared explicitly because libc exposes the most stable cross-libc ABI.
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;

/// Open a pseudo-terminal pair using the correct Linux sequence.
/// Uses explicit extern "c" declarations for consistent Zig 0.16 libc behavior.
/// Returns (master_fd, slave_fd). Caller must close the slave fd after passing it to the child.
pub fn openPTY() !struct { master: std.posix.fd_t, slave: std.posix.fd_t } {
    const master = try std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer std.posix.close(master);

    if (grantpt(@intCast(master)) != 0) return error.GrantPtFailed;
    if (unlockpt(@intCast(master)) != 0) return error.UnlockPtFailed;

    var slave_name_buf: [64]u8 = undefined;
    if (ptsname_r(@intCast(master), &slave_name_buf, slave_name_buf.len) != 0) {
        return error.PtsnameFailed;
    }
    const slave_name = std.mem.sliceTo(&slave_name_buf, 0);

    const slave = try std.posix.open(slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer std.posix.close(slave);

    // Note: we intentionally leave the master in blocking mode.
    // The dedicated reader thread (see terminal/Session.zig) will block on read.
    // Previous non-blocking logic was only needed for the old RPC-polling design.

    return .{ .master = master, .slave = slave };
}

/// Resize a PTY via ioctl TIOCSWINSZ.
pub fn resizePTY(master: std.posix.fd_t, rows: usize, cols: usize) void {
    const TIOCSWINSZ = 0x5414;
    const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 }{
        .ws_row = @intCast(rows),
        .ws_col = @intCast(cols),
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = std.posix.system.ioctl(master, TIOCSWINSZ, @intFromPtr(&winsize));
}

/// Enable raw terminal mode on stdin.
pub fn enableRawMode() !void {
    const stdin = std.Io.File.stdin();
    const fd = stdin.handle;
    const original = try std.posix.tcgetattr(fd);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@backingInt(std.posix.V.MIN)] = 0;
    raw.cc[@backingInt(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    original_termios = original;
}

/// Disable raw terminal mode on stdin and restore every original flag.
pub fn disableRawMode() !void {
    const original = original_termios orelse return;
    try std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, original);
    original_termios = null;
}

/// Get terminal size via ioctl.
pub fn getTermSize() !struct { rows: usize, cols: usize } {
    const stdout = std.Io.File.stdout();
    const fd = stdout.handle;
    var ws: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (result == 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 40, .cols = 80 };
}
