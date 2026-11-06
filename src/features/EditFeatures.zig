// Edit features: bracket highlighting, indent guides, auto-pairing, multi-cursor, folding, bookmarks
// Reuses patterns from flow (buffer operations) and pixi (rendering)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bracket pair definitions
pub const BracketPair = struct { open: u8, close: u8 };
pub const BRACKETS = [_]BracketPair{
    .{ .open = '(', .close = ')' },
    .{ .open = '[', .close = ']' },
    .{ .open = '{', .close = '}' },
    .{ .open = '<', .close = '>' },
};

pub const QUOTES = [_]u8{ '"', '\'', '`' };

/// Bracket highlighting - finds matching bracket and returns its position
pub fn findMatchingBracket(line: []const u8, col: usize) ?usize {
    if (col >= line.len) return null;
    const ch = line[col];
    const pair = for (BRACKETS) |bp| {
        if (bp.open == ch) break bp;
        if (bp.close == ch) break bp;
    } else return null;

    const forward = ch == pair.open;
    const target = if (forward) pair.close else pair.open;
    var depth: usize = 0;
    var i: usize = if (forward) col + 1 else col;

    while (forward and i < line.len) : (i += 1) {
        if (line[i] == pair.open) depth += 1;
        if (line[i] == target) {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    while (!forward and i > 0) {
        const j = i - 1;
        if (j < line.len) {
            if (line[j] == pair.close) depth += 1;
            if (line[j] == target) {
                if (depth == 0) return j;
                depth -= 1;
            }
        }
        i = j;
    }
    return null;
}

/// Auto-pairing: returns the closing character to insert after an opening bracket/quote
pub fn getAutoPair(open_char: u8) ?u8 {
    for (BRACKETS) |bp| {
        if (bp.open == open_char) return bp.close;
    }
    for (QUOTES) |q| {
        if (q == open_char) return q;
    }
    return null;
}

/// Check if auto-pair should be skipped (cursor is before closing char of same type)
pub fn shouldSkipAutoPair(line: []const u8, col: usize, ch: u8) bool {
    if (col >= line.len) return false;
    return line[col] == ch;
}

/// Indent guide calculation - returns array of indent levels for a line
pub fn getIndentLevels(line: []const u8, tab_width: usize) IndentGuide {
    var guide: IndentGuide = .{};
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        guide.total_indent += if (line[i] == '\t') tab_width else 1;
        if (guide.total_indent % tab_width == 0) {
            if (guide.level < 16) {
                guide.levels[guide.level] = true;
                guide.level += 1;
            }
        }
        i += 1;
    }
    return guide;
}

pub const IndentGuide = struct {
    levels: [16]bool = @as([16]bool, @splat(false)),
    level: usize = 0,
    total_indent: usize = 0,
};

// ============================================================
// Multi-Cursor support
// ============================================================

pub const MultiCursor = struct {
    cursors: std.array_list.Managed(CursorPos),
    primary: usize = 0,

    pub const CursorPos = struct {
        row: usize,
        col: usize,
        target_col: usize,
    };

    pub fn init(allocator: Allocator) MultiCursor {
        return .{ .cursors = std.array_list.Managed(CursorPos).init(allocator) };
    }

    pub fn add(self: *MultiCursor, allocator: Allocator, row: usize, col: usize) !void {
        _ = allocator;
        try self.cursors.append(.{ .row = row, .col = col, .target_col = col });
    }

    pub fn addNextMatch(self: *MultiCursor, allocator: Allocator, buffer: anytype, word: []const u8) !void {
        const primary = self.cursors.items[self.primary];
        var row = primary.row + 1;
        while (row < buffer.lineCount()) : (row += 1) {
            const line = buffer.getLine(row, allocator) catch continue;
            defer allocator.free(line);
            if (std.mem.indexOf(u8, line, word)) |col| {
                try self.add(allocator, row, col);
                break;
            }
        }
    }

    pub fn removePrimary(self: *Self) void {
        _ = self.cursors.orderedRemove(self.primary);
        if (self.primary >= self.cursors.items.len and self.cursors.items.len > 0) {
            self.primary = self.cursors.items.len - 1;
        }
    }

    pub fn clear(self: *Self) void {
        self.cursors.clearRetainingCapacity();
    }

    const Self = @This();
};

// ============================================================
// Code Folding
// ============================================================

pub const FoldRegion = struct {
    start_line: usize,
    end_line: usize,
    level: usize,
};

pub const FoldManager = struct {
    regions: std.array_list.Managed(FoldRegion),
    folded: std.array_list.Managed(bool),

    pub fn init(allocator: Allocator) FoldManager {
        return .{
            .regions = std.array_list.Managed(FoldRegion).init(allocator),
            .folded = std.array_list.Managed(bool).init(allocator),
        };
    }

    /// Compute fold regions by indentation
    pub fn computeFolds(self: *Self, allocator: Allocator, buffer: anytype, tab_width: usize) !void {
        self.regions.clearRetainingCapacity();
        self.folded.clearRetainingCapacity();

        const FoldCandidate = struct { line: usize, indent: usize };
        var stack = std.array_list.Managed(FoldCandidate).init(allocator);
        defer stack.deinit();

        var line: usize = 0;
        while (line < buffer.lineCount()) : (line += 1) {
            const text = buffer.getLine(line, allocator) catch continue;
            defer allocator.free(text);
            const indent = countIndent(text, tab_width);

            // Pop stack until we find a parent
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].indent >= indent) {
                if (stack.pop()) |candidate| {
                    if (candidate.line < line - 1) {
                        try self.regions.append(.{
                            .start_line = candidate.line,
                            .end_line = line - 1,
                            .level = stack.items.len,
                        });
                        try self.folded.append(false);
                    }
                }
            }

            try stack.append(.{ .line = line, .indent = indent });
        }

        // Close remaining
        while (stack.items.len > 0) {
            if (stack.pop()) |candidate| {
                if (candidate.line < buffer.lineCount() - 1) {
                    try self.regions.append(.{
                        .start_line = candidate.line,
                        .end_line = buffer.lineCount() - 1,
                        .level = stack.items.len,
                    });
                    try self.folded.append(false);
                }
            }
        }
    }

    pub fn toggleFold(self: *Self, line: usize) void {
        for (self.regions.items, 0..) |region, i| {
            if (line >= region.start_line and line <= region.end_line) {
                self.folded.items[i] = !self.folded.items[i];
                return;
            }
        }
    }

    pub fn isLineVisible(self: *Self, line: usize) bool {
        for (self.regions.items, 0..) |region, i| {
            if (self.folded.items[i] and line > region.start_line and line <= region.end_line) {
                return false;
            }
        }
        return true;
    }

    pub fn deinit(self: *Self, _: Allocator) void {
        self.regions.deinit();
        self.folded.deinit();
    }

    const Self = @This();
};

fn countIndent(line: []const u8, tab_width: usize) usize {
    var indent: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            indent += 1;
        } else if (ch == '\t') {
            indent += tab_width;
        } else {
            break;
        }
    }
    return indent;
}

// ============================================================
// Bookmarks
// ============================================================

pub const Bookmark = struct {
    line: usize,
    col: usize,
    note: ?[]const u8 = null,
};

pub const BookmarkManager = struct {
    bookmarks: std.array_list.Managed(Bookmark),

    pub fn init(allocator: Allocator) BookmarkManager {
        return .{ .bookmarks = std.array_list.Managed(Bookmark).init(allocator) };
    }

    pub fn toggle(self: *Self, allocator: Allocator, line: usize, col: usize) !void {
        for (self.bookmarks.items, 0..) |bm, i| {
            if (bm.line == line) {
                if (bm.note) |n| allocator.free(n);
                _ = self.bookmarks.orderedRemove(i);
                return;
            }
        }
        try self.bookmarks.append(.{ .line = line, .col = col });
    }

    pub fn hasBookmark(self: *Self, line: usize) bool {
        for (self.bookmarks.items) |bm| {
            if (bm.line == line) return true;
        }
        return false;
    }

    pub fn nextBookmark(self: *Self, current_line: usize) ?usize {
        for (self.bookmarks.items) |bm| {
            if (bm.line > current_line) return bm.line;
        }
        if (self.bookmarks.items.len > 0) return self.bookmarks.items[0].line;
        return null;
    }

    pub fn prevBookmark(self: *Self, current_line: usize) ?usize {
        var i: usize = self.bookmarks.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bookmarks.items[i].line < current_line) return self.bookmarks.items[i].line;
        }
        if (self.bookmarks.items.len > 0) return self.bookmarks.items[self.bookmarks.items.len - 1].line;
        return null;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.bookmarks.items) |bm| {
            if (bm.note) |n| allocator.free(n);
        }
        self.bookmarks.deinit();
    }

    const Self = @This();
};
