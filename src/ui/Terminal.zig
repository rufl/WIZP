// Terminal rendering for WIZP - ultra-lightweight ANSI-based UI

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const theme_mod = @import("../theme/Theme.zig");

/// Terminal dimensions
pub const TermSize = struct {
    rows: usize,
    cols: usize,
};

/// Terminal backend for rendering
pub const Terminal = struct {
    allocator: Allocator,
    size: TermSize = .{ .rows = 40, .cols = 80 },
    /// Buffer for the next frame
    front_buffer: std.Io.Writer.Allocating,
    /// Previous frame (for diff-based rendering)
    back_buffer: std.Io.Writer.Allocating,
    /// Output buffer for buffered stdout writes
    out_buf: [4096]u8 = undefined,
    /// Current output writer
    writer: ?std.Io.File.Writer = null,
    original_termios: ?std.posix.termios = null,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .front_buffer = .init(allocator),
            .back_buffer = .init(allocator),
        };
    }

    /// Enter raw mode and start rendering
    pub fn enter(self: *Self) !void {
        self.writer = std.Io.File.stdout().writerStreaming(
            @import("../runtime_016.zig").io(),
            &self.out_buf,
        );

        // Get terminal size
        self.size = try self.getTermSize();

        try self.enableRawMode();
        errdefer self.disableRawMode() catch {};

        // Write escape sequences directly to stdout (not front_buffer —
        // front_buffer gets cleared by beginFrame before first render)
        const seqs = "\x1b[?25l\x1b[2J\x1b[H\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h";
        try self.writer.?.interface.writeAll(seqs);
        try self.writer.?.flush();
    }

    /// Exit raw mode and restore terminal
    pub fn exit(self: *Self) !void {
        errdefer self.disableRawMode() catch {};
        // Write cleanup sequences directly to stdout
        const seqs = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?1049l\x1b[?25h";
        try self.writer.?.interface.writeAll(seqs);
        try self.writer.?.flush();
        try self.disableRawMode();
    }

    /// Begin a new frame
    pub fn beginFrame(self: *Self) !void {
        self.front_buffer.clearRetainingCapacity();
        try self.front_buffer.writer.writeAll("\x1b[H"); // Move to home
    }

    /// End the current frame and render to screen
    pub fn endFrame(self: *Self) !void {
        const writer = if (self.writer) |*value| value else return;
        // Write the entire frame
        try writer.interface.writeAll(self.front_buffer.written());
        try writer.flush();
        // Move cursor to bottom for input
        try self.write("\x1b[{};1H", .{self.size.rows});
    }

    /// Move cursor to position (1-indexed for terminal)
    pub fn moveTo(self: *Self, row: usize, col: usize) !void {
        try self.front_buffer.writer.print("\x1b[{};{}H", .{ row + 1, col + 1 });
    }

    /// Write styled text to the buffer
    pub fn writeStyled(self: *Self, text: []const u8, style: theme_mod.ScopeStyle) !void {
        // Apply foreground color
        if (style.foreground) |fg| {
            try self.front_buffer.writer.print("\x1b[38;2;{};{};{}m", .{ fg.r, fg.g, fg.b });
        }
        // Apply background color
        if (style.background) |bg| {
            try self.front_buffer.writer.print("\x1b[48;2;{};{};{}m", .{ bg.r, bg.g, bg.b });
        }
        // Apply bold
        if (style.bold) {
            try self.front_buffer.writer.writeAll("\x1b[1m");
        }
        // Apply italic
        if (style.italic) {
            try self.front_buffer.writer.writeAll("\x1b[3m");
        }
        // Apply underline
        if (style.underline) {
            try self.front_buffer.writer.writeAll("\x1b[4m");
        }

        // Write the text
        try self.front_buffer.writer.writeAll(text);

        // Reset all styles
        try self.front_buffer.writer.writeAll("\x1b[0m");
    }

    /// Write unstyled text
    pub fn writeText(self: *Self, text: []const u8) !void {
        try self.front_buffer.writer.writeAll(text);
    }

    /// Fill a line with a background color
    pub fn fillLine(self: *Self, row: usize, col_start: usize, len: usize, color: theme_mod.Color) !void {
        try self.moveTo(row, col_start);
        try self.front_buffer.writer.print("\x1b[48;2;{};{};{}m", .{ color.r, color.g, color.b });
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try self.front_buffer.writer.writeAll(" ");
        }
        try self.front_buffer.writer.writeAll("\x1b[0m");
    }

    /// Clear the screen
    pub fn clear(self: *Self) !void {
        try self.front_buffer.writer.writeAll("\x1b[2J\x1b[H");
    }

    /// Write raw text (no formatting)
    pub fn writeRaw(self: *Self, text: []const u8) !void {
        try self.front_buffer.writer.writeAll(text);
    }

    /// Write formatted string
    pub fn write(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        try self.front_buffer.writer.print(fmt, args);
    }

    /// Get terminal size via ioctl
    fn getTermSize(_: *Self) !TermSize {
        if (comptime builtin.os.tag == .windows) {
            return error.TerminalUnavailable;
        } else {
            const stdout = std.Io.File.stdout();
            const fd = stdout.handle;

            var ws: std.posix.winsize = undefined;
            const result = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (result == 0 and ws.row > 0 and ws.col > 0) {
                return TermSize{ .rows = ws.row, .cols = ws.col };
            }

            return TermSize{ .rows = 40, .cols = 80 };
        }
    }

    fn enableRawMode(self: *Self) !void {
        if (comptime builtin.os.tag == .windows) {
            return error.TerminalUnavailable;
        } else {
            const fd = std.Io.File.stdin().handle;
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
            self.original_termios = original;
        }
    }

    fn disableRawMode(self: *Self) !void {
        if (comptime builtin.os.tag == .windows) {
            return;
        } else if (self.original_termios) |original| {
            try std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, original);
            self.original_termios = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.front_buffer.deinit();
        self.back_buffer.deinit();
    }
};
