// Cursor management for WIZP — codepoint-aware
// col is the byte offset in the current line.
// col_cp is the codepoint offset for display (Ln, Col in status bar).

const std = @import("std");
const Buffer = @import("Buffer.zig");
const unicode = @import("unicode.zig");

/// Cursor position in the buffer
row: usize = 0,
/// Byte offset in the current line
col: usize = 0,
/// Codepoint offset in the current line (for display)
col_cp: usize = 0,
/// Preferred column for vertical movement (bytes)
target_col: usize = 0,
/// Visual column (accounting for tabs)
visual_col: usize = 0,

const Self = @This();

/// Create a cursor at a specific position
pub fn at(row: usize, col: usize) Self {
    return .{ .row = row, .col = col, .col_cp = col, .target_col = col, .visual_col = col };
}

/// Move cursor left by one codepoint.
pub fn moveLeft(self: *Self, buffer: *Buffer) void {
    if (self.col > 0) {
        const line = buffer.getLine(self.row, buffer.allocator) catch return;
        defer buffer.allocator.free(line);
        // Find start of previous codepoint
        if (unicode.prevCodepoint(line, self.col)) |prev| {
            self.col -= prev.len;
        } else {
            self.col -= 1; // fallback for invalid sequences
        }
        self.target_col = self.col;
    } else if (self.row > 0) {
        self.row -= 1;
        self.col = buffer.lineLength(self.row);
        self.target_col = self.col;
    }
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move cursor right by one codepoint.
pub fn moveRight(self: *Self, buffer: *Buffer) void {
    const line_len = buffer.lineLength(self.row);
    if (self.col < line_len) {
        const line = buffer.getLine(self.row, buffer.allocator) catch return;
        defer buffer.allocator.free(line);
        const width = unicode.codepointWidth(line[self.col]);
        self.col += width;
        self.target_col = self.col;
    } else if (self.row + 1 < buffer.lineCount()) {
        self.row += 1;
        self.col = 0;
        self.target_col = 0;
    }
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Recalculate col_cp (codepoint column) from current byte position
fn updateCodepointCol(self: *Self, buffer: *Buffer) void {
    const line = buffer.getLine(self.row, buffer.allocator) catch return;
    defer buffer.allocator.free(line);
    self.col_cp = unicode.byteToCodepointOffset(line, self.col);
}

/// Move cursor up one line
pub fn moveUp(self: *Self, buffer: *Buffer) void {
    if (self.row > 0) {
        self.row -= 1;
        self.col = @min(self.target_col, buffer.lineLength(self.row));
    }
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move cursor down one line
pub fn moveDown(self: *Self, buffer: *Buffer) void {
    if (self.row + 1 < buffer.lineCount()) {
        self.row += 1;
        self.col = @min(self.target_col, buffer.lineLength(self.row));
    }
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move to start of line
pub fn moveHome(self: *Self, buffer: *Buffer) void {
    // First press: first non-whitespace, second press: column 0
    if (self.col > 0) {
        const line = buffer.getLine(self.row, buffer.allocator) catch return;
        defer buffer.allocator.free(line);
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (self.col == i) {
            self.col = 0;
        } else {
            self.col = i;
        }
    }
    self.target_col = self.col;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move to end of line
pub fn moveEnd(self: *Self, buffer: *Buffer) void {
    self.col = buffer.lineLength(self.row);
    self.target_col = self.col;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move to start of buffer
pub fn moveTop(self: *Self, buffer: *Buffer) void {
    self.row = 0;
    self.col = 0;
    self.target_col = 0;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move to end of buffer
pub fn moveBottom(self: *Self, buffer: *Buffer) void {
    self.row = buffer.lineCount() -| 1;
    self.col = buffer.lineLength(self.row);
    self.target_col = self.col;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move forward by one word
pub fn moveWordForward(self: *Self, buffer: *Buffer) void {
    const line = buffer.getLine(self.row, buffer.allocator) catch return;
    defer buffer.allocator.free(line);

    var col = self.col;
    // Skip current word
    while (col < line.len and isWordChar(line[col])) : (col += 1) {}
    // Skip whitespace
    while (col < line.len and (line[col] == ' ' or line[col] == '\t')) : (col += 1) {}

    if (col < line.len) {
        self.col = col;
    } else if (self.row + 1 < buffer.lineCount()) {
        self.row += 1;
        self.col = 0;
    }
    self.target_col = self.col;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Move backward by one word
pub fn moveWordBack(self: *Self, buffer: *Buffer) void {
    const line = buffer.getLine(self.row, buffer.allocator) catch return;
    defer buffer.allocator.free(line);

    var col = self.col;
    if (col == 0) {
        if (self.row > 0) {
            self.row -= 1;
            self.col = buffer.lineLength(self.row);
        }
        self.target_col = self.col;
        self.updateCodepointCol(buffer);
        self.updateVisual(buffer);
        return;
    }
    col -= 1;
    // Skip whitespace
    while (col > 0 and (line[col] == ' ' or line[col] == '\t')) : (col -= 1) {}
    // Skip word
    while (col > 0 and isWordChar(line[col])) : (col -= 1) {}
    if (!isWordChar(line[col])) col += 1;
    self.col = col;
    self.target_col = self.col;
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}

/// Scroll cursor into view
pub fn scrollIntoView(self: *Self, view: anytype) void {
    if (self.row < view.scroll_row) {
        view.scroll_row = self.row;
    } else if (self.row >= view.scroll_row + view.visible_rows) {
        view.scroll_row = self.row - view.visible_rows + 1;
    }
    if (self.visual_col < view.scroll_col) {
        view.scroll_col = self.visual_col;
    } else if (self.visual_col >= view.scroll_col + view.visible_cols) {
        view.scroll_col = self.visual_col - view.visible_cols + 1;
    }
}

/// Update visual column accounting for tabs
fn updateVisual(self: *Self, buffer: *Buffer) void {
    const line = buffer.getLine(self.row, buffer.allocator) catch {
        self.visual_col = self.col;
        return;
    };
    defer buffer.allocator.free(line);
    self.visual_col = @as(usize, self.col);
    var col: usize = 0;
    for (line) |ch| {
        if (col >= self.col) break;
        if (ch == '\t') {
            col += 4 - (col % 4);
        } else {
            col += 1;
        }
    }
    self.visual_col = col;
}

/// Check if character is a word character
fn isWordChar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

/// Get byte offset of cursor in buffer
pub fn toOffset(self: *Self, buffer: *Buffer) usize {
    return buffer.lineColToOffset(self.row, self.col);
}

/// Clamp cursor within buffer bounds
pub fn clamp(self: *Self, buffer: *Buffer) void {
    if (self.row >= buffer.lineCount()) {
        self.row = buffer.lineCount() -| 1;
    }
    self.col = @min(self.col, buffer.lineLength(self.row));
    self.target_col = @min(self.target_col, self.col);
    self.updateCodepointCol(buffer);
    self.updateVisual(buffer);
}
