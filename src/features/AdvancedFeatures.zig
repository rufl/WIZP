// Advanced features: diff editor, terminal panel, spell check, inlay hints, recent files, code lens
// Reuses patterns from flow (diff, LSP types) and nullclaw (terminal)

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

// ============================================================
// Diff Engine (unified diff)
// ============================================================

pub const DiffLine = struct {
    kind: DiffKind,
    text: []const u8,
    old_line: ?usize = null,
    new_line: ?usize = null,

    pub const DiffKind = enum { unchanged, added, removed, modified };
};

pub const DiffEngine = struct {
    pub fn compute(allocator: Allocator, old_text: []const u8, new_text: []const u8) ![]const DiffLine {
        var result = std.array_list.Managed(DiffLine).init(allocator);

        const old_lines = try splitLines(allocator, old_text);
        defer allocator.free(old_lines);
        const new_lines = try splitLines(allocator, new_text);
        defer allocator.free(new_lines);

        // Simple LCS-based diff
        const lcs = try computeLCS(allocator, old_lines, new_lines);
        defer allocator.free(lcs);

        var oi: usize = 0;
        var ni: usize = 0;
        var li: usize = 0;

        while (oi < old_lines.len or ni < new_lines.len) {
            if (li < lcs.len and oi < old_lines.len and ni < new_lines.len and
                lcs[li].old_idx == oi and lcs[li].new_idx == ni)
            {
                try result.append(.{ .kind = .unchanged, .text = try allocator.dupe(u8, old_lines[oi]), .old_line = oi + 1, .new_line = ni + 1 });
                oi += 1;
                ni += 1;
                li += 1;
            } else if (oi < old_lines.len and (li >= lcs.len or lcs[li].old_idx != oi)) {
                if (ni < new_lines.len and (li >= lcs.len or lcs[li].new_idx != ni)) {
                    // Both changed -> modified
                    try result.append(.{ .kind = .removed, .text = try allocator.dupe(u8, old_lines[oi]), .old_line = oi + 1 });
                    try result.append(.{ .kind = .added, .text = try allocator.dupe(u8, new_lines[ni]), .new_line = ni + 1 });
                    oi += 1;
                    ni += 1;
                } else {
                    try result.append(.{ .kind = .removed, .text = try allocator.dupe(u8, old_lines[oi]), .old_line = oi + 1 });
                    oi += 1;
                }
            } else if (ni < new_lines.len and (li >= lcs.len or lcs[li].new_idx != ni)) {
                try result.append(.{ .kind = .added, .text = try allocator.dupe(u8, new_lines[ni]), .new_line = ni + 1 });
                ni += 1;
            }
        }

        return result.toOwnedSlice();
    }

    fn computeLCS(allocator: Allocator, a: []const []const u8, b: []const []const u8) ![]const LCSMatch {
        var matches = std.array_list.Managed(LCSMatch).init(allocator);

        // Greedy LCS (simple but effective for code)
        var bi: usize = 0;
        for (a, 0..) |line_a, ai| {
            if (bi < b.len) {
                var search = bi;
                while (search < b.len) : (search += 1) {
                    if (std.mem.eql(u8, line_a, b[search])) {
                        try matches.append(.{ .old_idx = ai, .new_idx = search });
                        bi = search + 1;
                        break;
                    }
                }
            }
        }

        return matches.toOwnedSlice();
    }

    const LCSMatch = struct { old_idx: usize, new_idx: usize };
};

fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        try lines.append(line);
    }
    return lines.toOwnedSlice();
}

// ============================================================
// Terminal Panel (embedded shell)
// ============================================================

pub const TerminalPanel = struct {
    allocator: Allocator,
    pty_master: ?std.posix.fd_t = null,
    child: ?std.process.Child = null,
    buffer: std.array_list.Managed(u8),
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    rows: usize = 24,
    cols: usize = 80,

    pub fn init(allocator: Allocator) TerminalPanel {
        return .{ .allocator = allocator };
    }

    /// Spawn a shell in a real PTY using posix_openpt
    pub fn spawn(self: *TerminalPanel, shell: []const u8) !void {
        // Open PTY master
        const master = try std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer std.posix.close(master);

        // Grant access to slave
        _ = std.posix.system.grantpt(master);
        _ = std.posix.system.unlockpt(master);

        // Get slave path
        var slave_name_buf: [64]u8 = undefined;
        const slave_name = try std.posix.system.ptsname_r(master, &slave_name_buf);

        // Open slave
        const slave = try std.posix.open(slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer std.posix.close(slave);

        // Spawn shell connected to PTY slave
        const args = [_][]const u8{shell};
        const slave_file: std.Io.File = .{ .handle = slave };
        const child = try std.process.spawn(runtime.io(), .{
            .argv = &args,
            .stdin = .{ .file = slave_file },
            .stdout = .{ .file = slave_file },
            .stderr = .{ .file = slave_file },
        });
        // Close slave fd in parent — child has its own copy
        std.posix.close(slave);

        self.pty_master = master;
        self.child = child;
    }

    /// Read output from shell (non-blocking, from PTY master)
    pub fn readOutput(self: *TerminalPanel) ![]const u8 {
        if (self.pty_master) |master| {
            // Set non-blocking
            const flags = try std.posix.fcntl(master, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(master, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);

            var buf: [4096]u8 = undefined;
            const n = std.posix.read(master, &buf) catch |err| switch (err) {
                error.WouldBlock => return "",
                else => return err,
            };

            // Restore blocking
            _ = std.posix.fcntl(master, std.posix.F.SETFL, flags) catch {};

            if (n > 0) {
                const start = self.buffer.items.len;
                try self.buffer.appendSlice(buf[0..n]);
                return self.buffer.items[start..];
            }
        }
        return "";
    }

    /// Write input to shell (to PTY master)
    pub fn writeInput(self: *TerminalPanel, data: []const u8) !void {
        if (self.pty_master) |master| {
            _ = try std.posix.write(master, data);
        }
    }

    /// Resize PTY terminal via ioctl TIOCSWINSZ
    pub fn resize(self: *TerminalPanel, rows: usize, cols: usize) void {
        self.rows = rows;
        self.cols = cols;
        if (self.pty_master) |master| {
            const TIOCSWINSZ = 0x5414; // Linux ioctl for setting window size
            const winsize = extern struct {
                ws_row: u16,
                ws_col: u16,
                ws_xpixel: u16,
                ws_ypixel: u16,
            }{
                .ws_row = @intCast(rows),
                .ws_col = @intCast(cols),
                .ws_xpixel = 0,
                .ws_ypixel = 0,
            };
            _ = std.posix.system.ioctl(master, TIOCSWINSZ, @intFromPtr(&winsize));
        }
    }

    pub fn close(self: *TerminalPanel) void {
        if (self.child) |*child| {
            child.kill(runtime.io());
        }
        if (self.pty_master) |master| {
            std.posix.close(master);
        }
        self.child = null;
        self.pty_master = null;
    }

    pub fn deinit(self: *TerminalPanel, allocator: Allocator) void {
        self.close();
        _ = allocator;
        self.buffer.deinit();
    }

    const Self = @This();
};

// ============================================================
// Spell Check
// ============================================================

pub const SpellChecker = struct {
    /// Simple dictionary of common words (extendable)
    dictionary: std.StringHashMapUnmanaged(void),
    /// Ignored words (per session)
    ignored: std.StringHashMapUnmanaged(void),

    pub fn init(allocator: Allocator) SpellChecker {
        return .{
            .dictionary = std.StringHashMapUnmanaged(void).init(allocator),
            .ignored = std.StringHashMapUnmanaged(void).init(allocator),
        };
    }

    /// Load dictionary from file (one word per line)
    pub fn loadDictionary(self: *SpellChecker, allocator: Allocator, path: []const u8) !void {
        const content = try runtime.readFileAlloc(allocator, path, 10 * 1024 * 1024);
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                const word = try allocator.dupe(u8, line);
                try self.dictionary.put(allocator, word, {});
            }
        }
    }

    /// Check if a word is spelled correctly
    pub fn check(self: *SpellChecker, word: []const u8) bool {
        if (word.len == 0) return true;
        if (self.ignored.contains(word)) return true;
        if (self.dictionary.contains(word)) return true;

        // Check lowercase version
        var lower_buf: [128]u8 = undefined;
        if (word.len > lower_buf.len) return false;
        const lower = std.ascii.lowerString(&lower_buf, word);
        return self.dictionary.contains(lower) or self.ignored.contains(lower);
    }

    /// Find misspelled words in text
    pub fn findErrors(self: *SpellChecker, allocator: Allocator, text: []const u8) ![]const SpellError {
        var errors = std.array_list.Managed(SpellError).init(allocator);
        var words = std.mem.splitAny(u8, text, " \t\n\r,.;:!?\"'()[]{}<>");

        var pos: usize = 0;
        while (words.next()) |word| {
            if (word.len > 0 and !self.check(word)) {
                try errors.append(.{ .word = try allocator.dupe(u8, word), .offset = pos });
            }
            pos += word.len + 1;
        }
        return errors.toOwnedSlice();
    }

    /// Add word to ignore list
    pub fn ignoreWord(self: *SpellChecker, allocator: Allocator, word: []const u8) !void {
        const duped = try allocator.dupe(u8, word);
        try self.ignored.put(allocator, duped, {});
    }

    pub fn deinit(self: *SpellChecker, allocator: Allocator) void {
        var it = self.dictionary.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.dictionary.deinit();

        var it2 = self.ignored.iterator();
        while (it2.next()) |entry| allocator.free(entry.key_ptr.*);
        self.ignored.deinit();
    }

    const Self = @This();

    pub const SpellError = struct {
        word: []const u8,
        offset: usize,
    };
};

// ============================================================
// Inlay Hints (type annotations, parameter names)
// ============================================================

pub const InlayHint = struct {
    line: usize,
    col: usize,
    label: []const u8,
    kind: InlayHintKind = .type_hint,
    padding_left: bool = false,
    padding_right: bool = true,

    pub const InlayHintKind = enum { type_hint, parameter_hint };
};

pub const InlayHintManager = struct {
    hints: std.array_list.Managed(InlayHint),
    enabled: bool = true,

    pub fn init(allocator: Allocator) InlayHintManager {
        return .{ .hints = std.array_list.Managed(InlayHint).init(allocator) };
    }

    pub fn setHints(self: *InlayHintManager, allocator: Allocator, new_hints: []const InlayHint) !void {
        for (self.hints.items) |h| allocator.free(h.label);
        self.hints.clearRetainingCapacity();
        for (new_hints) |hint| {
            try self.hints.append(.{
                .line = hint.line,
                .col = hint.col,
                .label = try allocator.dupe(u8, hint.label),
                .kind = hint.kind,
            });
        }
    }

    pub fn getHintsForLine(self: *InlayHintManager, line: usize) []const InlayHint {
        var start: usize = 0;
        var count: usize = 0;
        for (self.hints.items, 0..) |h, i| {
            if (h.line == line) {
                if (count == 0) start = i;
                count += 1;
            }
        }
        if (count == 0) return &.{};
        return self.hints.items[start .. start + count];
    }

    pub fn deinit(self: *InlayHintManager, allocator: Allocator) void {
        for (self.hints.items) |h| allocator.free(h.label);
        self.hints.deinit();
    }

    const Self = @This();
};

// ============================================================
// Recent Files (MRU - Most Recently Used)
// ============================================================

pub const RecentFiles = struct {
    files: std.array_list.Managed(RecentEntry),
    max_entries: usize = 100,

    pub const RecentEntry = struct {
        path: []const u8,
        timestamp: i64,
        line: usize = 0,
        col: usize = 0,
    };

    pub fn init(allocator: Allocator) RecentFiles {
        return .{ .files = std.array_list.Managed(RecentEntry).init(allocator) };
    }

    pub fn add(self: *RecentFiles, allocator: Allocator, path: []const u8, line: usize, col: usize) !void {
        // Remove if already exists
        for (self.files.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                allocator.free(entry.path);
                _ = self.files.orderedRemove(i);
                break;
            }
        }

        // Add to front
        try self.files.insert(0, .{
            .path = try allocator.dupe(u8, path),
            .timestamp = runtime.milliTimestamp(),
            .line = line,
            .col = col,
        });

        // Trim if too many
        while (self.files.items.len > self.max_entries) {
            const removed = self.files.pop();
            allocator.free(removed.path);
        }
    }

    pub fn getRecent(self: *RecentFiles, max: usize) []const RecentEntry {
        const count = @min(max, self.files.items.len);
        return self.files.items[0..count];
    }

    pub fn deinit(self: *RecentFiles, allocator: Allocator) void {
        for (self.files.items) |entry| {
            allocator.free(entry.path);
        }
        self.files.deinit();
    }

    const Self = @This();
};

// ============================================================
// Code Lens (clickable code annotations)
// ============================================================

pub const CodeLens = struct {
    range: CodeLensRange,
    command: ?CodeLensCommand = null,
    data: ?[]const u8 = null,

    pub const CodeLensRange = struct {
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    };

    pub const CodeLensCommand = struct {
        title: []const u8,
        command: []const u8,
        arguments: ?[]const u8 = null,
    };
};

pub const CodeLensManager = struct {
    lenses: std.array_list.Managed(CodeLens),

    pub fn init(allocator: Allocator) CodeLensManager {
        return .{ .lenses = std.array_list.Managed(CodeLens).init(allocator) };
    }

    pub fn setLenses(self: *CodeLensManager, allocator: Allocator, lenses: []const CodeLens) !void {
        for (self.lenses.items) |l| {
            if (l.data) |d| allocator.free(d);
            if (l.command) |c| allocator.free(c.title);
        }
        self.lenses.clearRetainingCapacity();

        for (lenses) |lens| {
            var duped = lens;
            if (lens.data) |d| duped.data = try allocator.dupe(u8, d);
            if (lens.command) |c| {
                duped.command = .{
                    .title = try allocator.dupe(u8, c.title),
                    .command = lens.command.?.command,
                    .arguments = lens.command.?.arguments,
                };
            }
            try self.lenses.append(duped);
        }
    }

    pub fn getLensesForLine(self: *CodeLensManager, line: usize) []const CodeLens {
        var start: usize = 0;
        var count: usize = 0;
        for (self.lenses.items, 0..) |l, i| {
            if (l.range.start_line == line) {
                if (count == 0) start = i;
                count += 1;
            }
        }
        if (count == 0) return &.{};
        return self.lenses.items[start .. start + count];
    }

    pub fn deinit(self: *CodeLensManager, allocator: Allocator) void {
        for (self.lenses.items) |l| {
            if (l.data) |d| allocator.free(d);
            if (l.command) |c| allocator.free(c.title);
        }
        self.lenses.deinit();
    }

    const Self = @This();
};
