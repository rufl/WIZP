// Selection management for WIZP

const std = @import("std");
const Buffer = @import("Buffer.zig");
const Cursor = @import("Cursor.zig");

/// Selection type
mode: Mode = .none,
/// Start of selection (may be before or after cursor)
anchor: Cursor = .{},
/// Current cursor position (end of selection)
cursor: Cursor = .{},

pub const Mode = enum { none, char, word, line, block };

const Self = @This();

/// Initialize with no selection
pub fn init() Self {
    return .{ .anchor = Cursor.at(0, 0), .cursor = Cursor.at(0, 0) };
}

/// Get the normalized selection range (start <= end)
pub fn getRange(self: *Self) struct { start_row: usize, start_col: usize, end_row: usize, end_col: usize } {
    if (self.anchor.row < self.cursor.row or
        (self.anchor.row == self.cursor.row and self.anchor.col <= self.cursor.col))
    {
        return .{
            .start_row = self.anchor.row,
            .start_col = self.anchor.col,
            .end_row = self.cursor.row,
            .end_col = self.cursor.col,
        };
    } else {
        return .{
            .start_row = self.cursor.row,
            .start_col = self.cursor.col,
            .end_row = self.anchor.row,
            .end_col = self.anchor.col,
        };
    }
}

/// Get selected text
pub fn getText(self: *Self, buffer: *Buffer, allocator: std.mem.Allocator) ![]const u8 {
    if (self.mode == .none) return "";

    const range = self.getRange();
    const start_offset = buffer.lineColToOffset(range.start_row, range.start_col);
    const end_offset = buffer.lineColToOffset(range.end_row, range.end_col);

    const full_text = try buffer.getText(allocator);
    defer allocator.free(full_text);

    const len = end_offset - start_offset;
    const result = try allocator.alloc(u8, len);
    @memcpy(result, full_text[start_offset..end_offset]);
    return result;
}

/// Start a character-wise selection at cursor
pub fn startChar(self: *Self, cursor: Cursor) void {
    self.anchor = cursor;
    self.cursor = cursor;
    self.mode = .char;
}

/// Start a word-wise selection at cursor (double click)
pub fn startWord(self: *Self, cursor: Cursor, buffer: *Buffer) void {
    const line = buffer.getLine(cursor.row, buffer.allocator) catch return;
    defer buffer.allocator.free(line);

    var start = cursor.col;
    var end = cursor.col;
    while (start > 0 and isWordChar(line[start - 1])) : (start -= 1) {}
    while (end < line.len and isWordChar(line[end])) : (end += 1) {}

    self.anchor = Cursor.at(cursor.row, start);
    self.cursor = Cursor.at(cursor.row, end);
    self.mode = .word;
}

/// Start a line-wise selection at cursor (triple click)
pub fn startLine(self: *Self, cursor: Cursor, buffer: *Buffer) void {
    self.anchor = Cursor.at(cursor.row, 0);
    self.cursor = Cursor.at(cursor.row, buffer.lineLength(cursor.row));
    self.mode = .line;
}

/// Extend selection to new cursor position
pub fn extendTo(self: *Self, cursor: Cursor) void {
    self.cursor = cursor;
}

/// Select all text in buffer
pub fn selectAll(self: *Self, buffer: *Buffer) void {
    self.anchor = Cursor.at(0, 0);
    const last_row = buffer.lineCount() -| 1;
    self.cursor = Cursor.at(last_row, buffer.lineLength(last_row));
    self.mode = .char;
}

/// Clear selection
pub fn clear(self: *Self) void {
    self.mode = .none;
}

/// Check if selection is active
pub fn isActive(self: *Self) bool {
    if (self.mode == .none) return false;
    return self.anchor.row != self.cursor.row or self.anchor.col != self.cursor.col;
}

/// Check if a line is within the selection
pub fn containsLine(self: *Self, line: usize) bool {
    if (!self.isActive()) return false;
    const range = self.getRange();
    return line >= range.start_row and line <= range.end_row;
}

/// Check if a specific (row, col) is within the selection
pub fn contains(self: *Self, row: usize, col: usize) bool {
    if (!self.isActive()) return false;
    const range = self.getRange();
    if (row < range.start_row or row > range.end_row) return false;
    if (row == range.start_row and row == range.end_row) {
        return col >= range.start_col and col < range.end_col;
    }
    if (row == range.start_row) return col >= range.start_col;
    if (row == range.end_row) return col < range.end_col;
    return true;
}

/// Delete selected text
pub fn deleteText(self: *Self, buffer: *Buffer) !void {
    if (!self.isActive()) return;
    const range = self.getRange();
    const start = buffer.lineColToOffset(range.start_row, range.start_col);
    const end = buffer.lineColToOffset(range.end_row, range.end_col);
    try buffer.delete(start, end - start);
    self.clear();
}

/// Replace selected text
pub fn replaceText(self: *Self, buffer: *Buffer, text: []const u8) !void {
    if (!self.isActive()) return;
    const range = self.getRange();
    const start = buffer.lineColToOffset(range.start_row, range.start_col);
    const end = buffer.lineColToOffset(range.end_row, range.end_col);
    try buffer.replace(start, end - start, text);
    self.clear();
}

/// Get cursor position after operation (at start of deleted range)
pub fn cursorAfterDelete(self: *Self) Cursor {
    const range = self.getRange();
    return Cursor.at(range.start_row, range.start_col);
}

fn isWordChar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}
