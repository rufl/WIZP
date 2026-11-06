// View - manages the visible portion of the buffer

const std = @import("std");

/// Viewport over the buffer
scroll_row: usize = 0,
scroll_col: usize = 0,
visible_rows: usize = 40,
visible_cols: usize = 80,
/// Tab width for display
tab_width: usize = 4,

const Self = @This();

/// Initialize with default dimensions
pub fn init() Self {
    return .{};
}

/// Set viewport dimensions (call on terminal resize)
pub fn resize(self: *Self, rows: usize, cols: usize) void {
    self.visible_rows = rows;
    self.visible_cols = cols;
}

/// Scroll view so that a given row and column are visible
pub fn scrollTo(self: *Self, row: usize, col: usize) void {
    if (row < self.scroll_row) {
        self.scroll_row = row;
    } else if (row >= self.scroll_row + self.visible_rows) {
        self.scroll_row = row - self.visible_rows + 1;
    }

    if (col < self.scroll_col) {
        self.scroll_col = col;
    } else if (col >= self.scroll_col + self.visible_cols) {
        self.scroll_col = col - self.visible_cols + 1;
    }
}

/// Scroll up by n lines
pub fn scrollUp(self: *Self, n: usize) void {
    self.scroll_row = self.scroll_row -| @min(self.scroll_row, n);
}

/// Scroll down by n lines
pub fn scrollDown(self: *Self, n: usize) void {
    self.scroll_row += n;
}

/// Scroll left by n columns
pub fn scrollLeft(self: *Self, n: usize) void {
    self.scroll_col = self.scroll_col -| @min(self.scroll_col, n);
}

/// Scroll right by n columns
pub fn scrollRight(self: *Self, n: usize) void {
    self.scroll_col += n;
}

/// Center the cursor in the view
pub fn centerOn(self: *Self, row: usize) void {
    if (row > self.visible_rows / 2) {
        self.scroll_row = row - self.visible_rows / 2;
    } else {
        self.scroll_row = 0;
    }
}

/// Get the first visible line number
pub fn firstVisibleLine(self: *Self) usize {
    return self.scroll_row;
}

/// Get the last visible line number
pub fn lastVisibleLine(self: *Self) usize {
    return self.scroll_row + self.visible_rows;
}

/// Check if a line is visible in the viewport
pub fn isLineVisible(self: *Self, line: usize) bool {
    return line >= self.scroll_row and line < self.scroll_row + self.visible_rows;
}

/// Get the screen row for a buffer line
pub fn bufferRowToScreenRow(self: *Self, buffer_row: usize) usize {
    return buffer_row -| self.scroll_row;
}
