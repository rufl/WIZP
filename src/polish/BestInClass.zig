// WIZP Best-in-Class Features
// Git blame, session restore, bracket colorization, symbol outline,
// word highlight, whitespace rendering, indent detection, auto-save

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

pub const GitBlame = struct {
    pub const BlameLine = struct { hash: []const u8, author: []const u8, date: []const u8, summary: []const u8, line_number: usize };

    pub fn blame(allocator: Allocator, file_path: []const u8) ![]const BlameLine {
        const dir = std.fs.path.dirname(file_path) orelse ".";
        const args = [_][]const u8{ "git", "blame", "--porcelain", file_path };
        const result = try std.process.run(allocator, runtime.io(), .{
            .argv = &args,
            .cwd = .{ .path = dir },
            .stdout_limit = .limited(10 * 1024 * 1024),
            .stderr_limit = .limited(65536),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitBlameFailed,
            else => return error.GitBlameFailed,
        }
        return parseBlame(allocator, result.stdout);
    }

    fn parseBlame(allocator: Allocator, output: []const u8) ![]const BlameLine {
        var results = std.array_list.Managed(BlameLine).init(allocator);
        var lines = std.mem.splitScalar(u8, output, '\n');
        var hash: []const u8 = "";
        var author: []const u8 = "";
        var date: []const u8 = "";
        var summary: []const u8 = "";
        var line_num: usize = 1;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '\t') continue;
            if (std.mem.startsWith(u8, line, "author ")) {
                author = line[7..];
            } else if (std.mem.startsWith(u8, line, "author-time ")) {
                date = line[12..];
            } else if (std.mem.startsWith(u8, line, "summary ")) {
                summary = line[8..];
            } else if (line.len >= 40 and isHex(line[0])) {
                // Emit previous entry before starting new one
                if (hash.len > 0) {
                    const h = try allocator.dupe(u8, hash[0..@min(8, hash.len)]);
                    const a = try allocator.dupe(u8, author);
                    const d = try allocator.dupe(u8, date);
                    const s = try allocator.dupe(u8, summary);
                    try results.append(.{ .hash = h, .author = a, .date = d, .summary = s, .line_number = line_num });
                }
                hash = line[0..40];
                if (line.len > 41) {
                    line_num = std.fmt.parseInt(usize, line[41..], 10) catch line_num;
                }
            }
        }
        if (hash.len > 0) {
            const h = try allocator.dupe(u8, hash[0..@min(8, hash.len)]);
            const a = try allocator.dupe(u8, author);
            const d = try allocator.dupe(u8, date);
            const s = try allocator.dupe(u8, summary);
            try results.append(.{ .hash = h, .author = a, .date = d, .summary = s, .line_number = line_num });
        }
        return results.toOwnedSlice();
    }
    fn isHex(ch: u8) bool {
        return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
    }
};

pub const SessionState = struct {
    open_files: std.array_list.Managed([]const u8),
    active_file: []const u8 = "",
    cursor_positions: std.StringHashMapUnmanaged(CursorPos),
    sidebar_visible: bool = true,
    sidebar_width: usize = 20,
    pub const CursorPos = struct { line: usize, col: usize };

    pub fn save(allocator: Allocator, state: *const SessionState, path: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;
        try w.print("active={s}\nsidebar={s}\nsidebar_width={}\n", .{ state.active_file, if (state.sidebar_visible) "true" else "false", state.sidebar_width });
        for (state.open_files.items) |f| {
            try w.print("file={s}", .{f});
            if (state.cursor_positions.get(f)) |pos| try w.print(":{}:{}", .{ pos.line, pos.col });
            try w.writeAll("\n");
        }
        try std.Io.Dir.cwd().writeFile(
            @import("../runtime_016.zig").io(),
            .{ .sub_path = path, .data = buf.written() },
        );
    }

    pub fn load(allocator: Allocator, path: []const u8) !SessionState {
        var state = SessionState{ .open_files = std.array_list.Managed([]const u8).init(allocator), .cursor_positions = .{} };
        const content = std.Io.Dir.cwd().readFileAlloc(
            @import("../runtime_016.zig").io(),
            path,
            allocator,
            .limited(65536),
        ) catch return state;
        defer allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "active=")) state.active_file = try allocator.dupe(u8, line[7..]) else if (std.mem.startsWith(u8, line, "sidebar=")) state.sidebar_visible = std.mem.eql(u8, line[8..], "true") else if (std.mem.startsWith(u8, line, "sidebar_width=")) state.sidebar_width = std.fmt.parseInt(usize, line[14..], 10) catch 20 else if (std.mem.startsWith(u8, line, "file=")) {
                const rest = line[5..];
                if (std.mem.indexOfScalar(u8, rest, ':')) |c1| {
                    const path_part = rest[0..c1];
                    const rest2 = rest[c1 + 1 ..];
                    if (std.mem.indexOfScalar(u8, rest2, ':')) |c2| {
                        const ln = std.fmt.parseInt(usize, rest2[0..c2], 10) catch 0;
                        const cn = std.fmt.parseInt(usize, rest2[c2 + 1 ..], 10) catch 0;
                        try state.cursor_positions.put(allocator, try allocator.dupe(u8, path_part), .{ .line = ln, .col = cn });
                    }
                    try state.open_files.append(try allocator.dupe(u8, path_part));
                } else try state.open_files.append(try allocator.dupe(u8, rest));
            }
        }
        return state;
    }

    pub fn deinit(self: *SessionState, allocator: Allocator) void {
        for (self.open_files.items) |f| allocator.free(f);
        self.open_files.deinit();
        var it = self.cursor_positions.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        self.cursor_positions.deinit(allocator);
        if (self.active_file.len > 0) allocator.free(self.active_file);
    }
};

pub const BracketColors = struct {
    const COLORS = [_]u24{ 0xFFD700, 0xDA70D6, 0x87CEEB, 0xFF6B6B, 0x98FB98, 0xFFA500 };
    pub fn getColor(depth: usize) u24 {
        return COLORS[depth % COLORS.len];
    }
};

pub const WordHighlighter = struct {
    pub const Match = struct { line: usize, col: usize, len: usize };
    pub fn findOccurrences(allocator: Allocator, content: []const u8, word: []const u8) ![]const Match {
        if (word.len == 0) return &.{};
        var matches = std.array_list.Managed(Match).init(allocator);
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 1;
        while (lines.next()) |line| : (line_num += 1) {
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, line, start, word)) |col| {
                const before = if (col > 0) line[col - 1] else 0;
                const after = if (col + word.len < line.len) line[col + word.len] else 0;
                if (!isWordChar(before) and !isWordChar(after)) try matches.append(.{ .line = line_num, .col = col, .len = word.len });
                start = col + word.len;
            }
        }
        return matches.toOwnedSlice();
    }
    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
    }
};

pub const IndentDetector = struct {
    pub const IndentInfo = struct { use_spaces: bool, size: usize, confidence: f32 };
    pub fn detect(content: []const u8) IndentInfo {
        var si: usize = 0;
        var ti: usize = 0;
        var ts: usize = 0;
        var lc: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| : (lc += 1) {
            if (line.len == 0) continue;
            if (line[0] == ' ') {
                si += 1;
                var i: usize = 0;
                while (i < line.len and line[i] == ' ') : (i += 1) {}
                ts += i;
            } else if (line[0] == '\t') ti += 1;
        }
        if (ti > si) return .{ .use_spaces = false, .size = 4, .confidence = @as(f32, @floatFromInt(ti)) / @as(f32, @floatFromInt(@max(1, lc))) };
        if (si > 0) {
            const avg = ts / si;
            var sz: usize = 4;
            if (avg <= 3) sz = 2;
            if (avg >= 8) sz = 8;
            return .{ .use_spaces = true, .size = sz, .confidence = 0.9 };
        }
        return .{ .use_spaces = true, .size = 4, .confidence = 0.0 };
    }
};

pub const AutoSaver = struct {
    enabled: bool = false,
    delay_ms: u64 = 1000,
    last_edit_time: i64 = 0,
    save_on_focus_loss: bool = true,
    pub fn notifyEdit(self: *AutoSaver) void {
        self.last_edit_time = runtime.milliTimestamp();
    }
    pub fn shouldSave(self: *AutoSaver) bool {
        if (!self.enabled) return false;
        return runtime.milliTimestamp() - self.last_edit_time > @as(i64, @intCast(self.delay_ms));
    }
};
