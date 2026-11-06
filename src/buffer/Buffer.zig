// WIZP - Ultra-lightweight code editor in Zig
// Core text buffer using piece table data structure for efficient edits

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cursor = @import("Cursor.zig");
pub const Selection = @import("Selection.zig");
pub const View = @import("View.zig");

const Self = @This();

/// Piece table node - represents a span of text
pub const Piece = struct {
    /// true = from original buffer, false = from add buffer
    original: bool,
    start: usize,
    len: usize,
};

/// Line information for fast line/column access
pub const LineInfo = struct {
    start: usize, // byte offset where this line starts in the logical text
    len: usize, // byte length of this line (including newline)
};

allocator: Allocator,
/// Original file content (immutable)
original: []const u8,
/// Track if original is mmap'd (needs munmap instead of free)
original_is_mmap: bool = false,
/// Added text (append-only)
add: std.array_list.Managed(u8),
/// Piece table - describes the logical sequence of text
pieces: std.array_list.Managed(Piece),
/// Line index for fast byte-offset <-> line/col conversion
lines: std.array_list.Managed(LineInfo),
line_count: usize = 0,
/// File path
file_path: ?[]const u8 = null,
/// End-of-line mode
eol: EolMode = .lf,
/// Whether the buffer has unsaved changes
dirty: bool = false,
/// File type for syntax highlighting
file_type: ?[]const u8 = null,
/// Undo/redo stacks — piece table snapshots (original/add are append-only, pieces refs stay valid)
undo_stack: std.array_list.Managed(UndoEntry),
redo_stack: std.array_list.Managed(UndoEntry),
/// When false, insert/delete/replace skip pushing undo (set true during user edits)
undo_track: bool = false,

pub const UndoEntry = struct {
    pieces: []Piece,
    cursor_row: usize,
    cursor_col: usize,
};

pub const EolMode = enum { lf, crlf, cr };

pub fn initEmpty(comptime T: type) std.array_list.Managed(T) {
    return std.array_list.Managed(T).init(undefined);
}

/// Initialize an empty buffer
pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .original = &[_]u8{},
        .original_is_mmap = false,
        .add = std.array_list.Managed(u8).init(allocator),
        .pieces = std.array_list.Managed(Piece).init(allocator),
        .lines = std.array_list.Managed(LineInfo).init(allocator),
        .undo_stack = std.array_list.Managed(UndoEntry).init(allocator),
        .redo_stack = std.array_list.Managed(UndoEntry).init(allocator),
        .undo_track = true,
    };
}

/// Load a file into the buffer
pub fn loadFile(self: *Self, file_path: []const u8) !void {
    const io = @import("../sync.zig").io();
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > 0) {
        const builtin = @import("builtin");
        if (builtin.os.tag != .windows) {
            const mem = try std.posix.mmap(
                null,
                stat.size,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
            self.original = mem;
            self.original_is_mmap = true;
        } else {
            const read_limit = std.math.cast(usize, stat.size + 1) orelse return error.FileTooBig;
            self.original = try @import("../runtime_016.zig").readFileAlloc(
                self.allocator,
                file_path,
                read_limit,
            );
            self.original_is_mmap = false;
        }
    } else {
        self.original = &[_]u8{};
        self.original_is_mmap = false;
    }

    // Initial single piece covering everything
    try self.pieces.append(.{ .original = true, .start = 0, .len = self.original.len });
    self.file_path = try self.allocator.dupe(u8, file_path);
    self.dirty = false;

    try self.rebuildLines();
    self.detectEol();
    self.detectFileType();
}

/// Initialize from a string in memory
pub fn initFromString(allocator: Allocator, text: []const u8) !Self {
    var self = Self.init(allocator);
    self.original = try allocator.dupe(u8, text);
    self.original_is_mmap = false;
    try self.pieces.append(.{ .original = true, .start = 0, .len = text.len });
    try self.rebuildLines();
    return self;
}

/// Get the full logical text as a single string
pub fn getText(self: *Self, allocator: Allocator) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    for (self.pieces.items) |piece| {
        const src = if (piece.original) self.original else self.add.items;
        try buf.appendSlice(src[piece.start .. piece.start + piece.len]);
    }
    return try buf.toOwnedSlice();
}

/// Total length of the logical text
pub fn totalLength(self: *Self) usize {
    var len: usize = 0;
    for (self.pieces.items) |piece| {
        len += piece.len;
    }
    return len;
}

/// Insert text at a byte offset
pub fn insert(self: *Self, offset: usize, text: []const u8) !void {
    if (text.len == 0) return;
    if (self.undo_track) try self.pushUndo(0, 0);

    const add_start = self.add.items.len;
    try self.add.appendSlice(text);

    // Find which piece contains the offset
    var pos: usize = 0;
    for (self.pieces.items, 0..) |piece, i| {
        if (offset >= pos and offset <= pos + piece.len) {
            const local_offset = offset - pos;

            // Split the current piece into two if insertion is in the middle
            if (local_offset > 0 and local_offset < piece.len) {
                const left = Piece{ .original = piece.original, .start = piece.start, .len = local_offset };
                const right = Piece{ .original = piece.original, .start = piece.start + local_offset, .len = piece.len - local_offset };
                const new_piece = Piece{ .original = false, .start = add_start, .len = text.len };

                self.pieces.items[i] = left;
                try self.pieces.insert(i + 1, new_piece);
                try self.pieces.insert(i + 2, right);
            } else if (local_offset == 0) {
                const new_piece = Piece{ .original = false, .start = add_start, .len = text.len };
                try self.pieces.insert(i, new_piece);
            } else {
                const new_piece = Piece{ .original = false, .start = add_start, .len = text.len };
                try self.pieces.insert(i + 1, new_piece);
            }
            self.dirty = true;
            try self.rebuildLines();
            return;
        }
        pos += piece.len;
    }

    // Append at end
    const new_piece = Piece{ .original = false, .start = add_start, .len = text.len };
    try self.pieces.append(new_piece);
    self.dirty = true;
    try self.rebuildLines();
    self.compactPieces();
}

/// Delete text at a byte range
pub fn delete(self: *Self, offset: usize, len: usize) !void {
    if (len == 0) return;
    const total = self.totalLength();
    if (offset >= total) return;
    if (self.undo_track) try self.pushUndo(0, 0);
    const delete_end = @min(total, offset + len);

    var kept = std.array_list.Managed(Piece).init(self.allocator);
    var pos: usize = 0;
    for (self.pieces.items) |piece| {
        const piece_end = pos + piece.len;
        if (piece_end <= offset or pos >= delete_end) {
            try kept.append(piece);
        } else {
            if (offset > pos) {
                try kept.append(.{ .original = piece.original, .start = piece.start, .len = offset - pos });
            }
            if (delete_end < piece_end) {
                try kept.append(.{ .original = piece.original, .start = piece.start + (delete_end - pos), .len = piece_end - delete_end });
            }
        }
        pos = piece_end;
    }

    self.pieces.deinit();
    self.pieces = kept;
    self.dirty = true;
    try self.rebuildLines();
    self.compactPieces();
}

/// Replace text in a range (atomic — single undo entry)
pub fn replace(self: *Self, offset: usize, len: usize, text: []const u8) !void {
    // Push undo BEFORE any mutation so partial failure can be rolled back
    if (self.undo_track) try self.pushUndo(0, 0);
    self.undo_track = false;
    defer self.undo_track = true;
    try self.delete(offset, len);
    try self.insert(offset, text);
}

/// Push current piece table state to undo stack before a mutation
pub fn pushUndo(self: *Self, cursor_row: usize, cursor_col: usize) !void {
    // Deep-copy current pieces list
    const pieces_copy = try self.allocator.dupe(Piece, self.pieces.items);
    try self.undo_stack.append(.{
        .pieces = pieces_copy,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
    });
    // Clear redo stack on new mutation
    for (self.redo_stack.items) |entry| self.allocator.free(entry.pieces);
    self.redo_stack.clearRetainingCapacity();
}

/// Undo last mutation. Returns new cursor position (row, col).
pub fn undo(self: *Self, cursor_row: usize, cursor_col: usize) ?struct { row: usize, col: usize } {
    if (self.undo_stack.items.len == 0) return null;
    const entry = self.undo_stack.pop().?;

    // Save current state to redo stack
    const current_pieces = self.allocator.dupe(Piece, self.pieces.items) catch return null;
    self.redo_stack.append(.{
        .pieces = current_pieces,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
    }) catch {
        self.allocator.free(current_pieces);
        return null;
    };

    // Restore prior piece state (suppress undo tracking during restore)
    self.undo_track = false;
    defer self.undo_track = true;
    self.pieces.clearRetainingCapacity();
    self.pieces.appendSlice(entry.pieces) catch return null;
    self.allocator.free(entry.pieces);
    self.dirty = true;
    self.rebuildLines() catch return null;

    return .{ .row = entry.cursor_row, .col = entry.cursor_col };
}

/// Redo last undone mutation. Returns new cursor position (row, col).
pub fn redo(self: *Self, cursor_row: usize, cursor_col: usize) ?struct { row: usize, col: usize } {
    if (self.redo_stack.items.len == 0) return null;
    const entry = self.redo_stack.pop().?;

    // Save current state to undo stack
    const current_pieces = self.allocator.dupe(Piece, self.pieces.items) catch return null;
    self.undo_stack.append(.{
        .pieces = current_pieces,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
    }) catch {
        self.allocator.free(current_pieces);
        return null;
    };

    // Restore from redo (suppress undo tracking during restore)
    self.undo_track = false;
    defer self.undo_track = true;
    self.pieces.clearRetainingCapacity();
    self.pieces.appendSlice(entry.pieces) catch return null;
    self.allocator.free(entry.pieces);
    self.dirty = true;
    self.rebuildLines() catch return null;

    return .{ .row = entry.cursor_row, .col = entry.cursor_col };
}

/// Save buffer to file
pub fn save(self: *Self) !void {
    if (self.file_path == null) return error.NoFilePath;

    const text = try self.getText(self.allocator);
    defer self.allocator.free(text);

    // Convert EOL if needed
    const output = switch (self.eol) {
        .lf => text,
        .crlf => try self.convertEol(text, "\r\n"),
        .cr => try self.convertEol(text, "\r"),
    };
    const owned = output.ptr != text.ptr;
    defer if (owned) self.allocator.free(output);

    try @import("../runtime_016.zig").writeFile(self.file_path.?, output);
    self.dirty = false;
}

fn convertEol(self: *Self, text: []const u8, new_eol: []const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(self.allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            try buf.appendSlice(new_eol);
            i += 1;
        } else if (text[i] == '\r') {
            if (i + 1 < text.len and text[i + 1] == '\n') {
                try buf.appendSlice(new_eol);
                i += 2;
            } else {
                try buf.appendSlice(new_eol);
                i += 1;
            }
        } else {
            try buf.append(text[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice();
}

/// Rebuild the line index
fn rebuildLines(self: *Self) !void {
    self.lines.clearRetainingCapacity();
    self.line_count = 0;

    var line_start: usize = 0;
    var byte_pos: usize = 0;

    for (self.pieces.items) |piece| {
        const src = if (piece.original) self.original else self.add.items;
        const slice = src[piece.start .. piece.start + piece.len];
        var i: usize = 0;
        while (i < slice.len) : (i += 1) {
            const ch = slice[i];
            if (ch == '\r') {
                // CR or CRLF — if followed by \n, include both in the line length
                if (i + 1 < slice.len and slice[i + 1] == '\n') {
                    try self.lines.append(.{ .start = line_start, .len = byte_pos - line_start + 2 });
                    line_start = byte_pos + 2;
                    byte_pos += 2;
                    self.line_count += 1;
                    i += 1; // skip the \n in the loop increment
                    continue;
                } else {
                    try self.lines.append(.{ .start = line_start, .len = byte_pos - line_start + 1 });
                    line_start = byte_pos + 1;
                }
                self.line_count += 1;
            } else if (ch == '\n') {
                try self.lines.append(.{ .start = line_start, .len = byte_pos - line_start + 1 });
                line_start = byte_pos + 1;
                self.line_count += 1;
            }
            byte_pos += 1;
        }
    }

    // Always retain the final logical line, including the empty line after a
    // trailing newline. This matches editor and LSP line-count semantics.
    try self.lines.append(.{ .start = line_start, .len = byte_pos - line_start });
    self.line_count += 1;
}

/// Compact pieces by merging adjacent pieces from the same buffer.
/// Prevents piece table bloat from many small edits.
fn compactPieces(self: *Self) void {
    if (self.pieces.items.len < 2) return;
    var i: usize = 1;
    while (i < self.pieces.items.len) {
        const prev = self.pieces.items[i - 1];
        const curr = self.pieces.items[i];
        if (prev.original == curr.original) {
            // Same buffer — check adjacency
            const prev_end = prev.start + prev.len;
            if (prev_end == curr.start) {
                // Adjacent — merge into prev
                self.pieces.items[i - 1].len += curr.len;
                _ = self.pieces.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

/// Get the text for a specific line
pub fn getLine(self: *Self, line: usize, allocator: Allocator) ![]const u8 {
    if (line >= self.line_count) return "";

    const info = self.lines.items[line];
    const content_len = self.lineLength(line);
    var buf = std.array_list.Managed(u8).init(allocator);
    var pos: usize = 0;
    for (self.pieces.items) |piece| {
        const piece_end = pos + piece.len;
        if (info.start < piece_end and info.start + content_len > pos) {
            const src = if (piece.original) self.original else self.add.items;
            const start = if (info.start > pos) info.start - pos else 0;
            const end = @min(piece.len, info.start + content_len - pos);
            try buf.appendSlice(src[piece.start + start .. piece.start + end]);
        }
        pos = piece_end;
        if (pos >= info.start + content_len) break;
    }
    return try buf.toOwnedSlice();
}

/// Convert byte offset to line and column (0-indexed)
pub fn offsetToLineCol(self: *Self, offset: usize) struct { line: usize, col: usize } {
    for (self.lines.items, 0..) |info, i| {
        if (offset < info.start + info.len) {
            return .{ .line = i, .col = offset - info.start };
        }
    }
    if (self.line_count > 0) {
        const last = self.lines.items[self.line_count - 1];
        return .{ .line = self.line_count - 1, .col = offset - last.start };
    }
    return .{ .line = 0, .col = 0 };
}

/// Convert line and column to byte offset
pub fn lineColToOffset(self: *Self, line: usize, col: usize) usize {
    if (line >= self.line_count) {
        return self.totalLength();
    }
    const info = self.lines.items[line];
    return @min(info.start + col, info.start + info.len);
}

/// Detect end-of-line mode
fn detectEol(self: *Self) void {
    for (self.pieces.items) |piece| {
        const src = if (piece.original) self.original else self.add.items;
        const slice = src[piece.start .. piece.start + piece.len];
        for (slice, 0..) |ch, j| {
            if (ch == '\r') {
                if (j + 1 < slice.len and slice[j + 1] == '\n') {
                    self.eol = .crlf;
                } else {
                    self.eol = .cr;
                }
                return;
            } else if (ch == '\n') {
                self.eol = .lf;
                return;
            }
        }
    }
}

/// Detect file type from extension
fn detectFileType(self: *Self) void {
    if (self.file_path) |path| {
        const ext = std.fs.path.extension(path);
        self.file_type = LANGUAGE_MAP.get(ext);
    }
}

/// Free all resources
pub fn deinit(self: *Self) void {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        if (self.original_is_mmap) {
            if (self.original.len > 0) {
                const aligned_slice: []align(std.heap.page_size_min) const u8 = @alignCast(self.original);
                std.posix.munmap(aligned_slice);
            }
        } else {
            if (self.original.len > 0) {
                self.allocator.free(self.original);
            }
        }
    } else {
        if (self.original.len > 0) {
            self.allocator.free(self.original);
        }
    }
    self.add.deinit();
    self.pieces.deinit();
    self.lines.deinit();
    for (self.undo_stack.items) |entry| self.allocator.free(entry.pieces);
    self.undo_stack.deinit();
    for (self.redo_stack.items) |entry| self.allocator.free(entry.pieces);
    self.redo_stack.deinit();
    if (self.file_path) |p| self.allocator.free(p);
}

/// Number of lines
pub fn lineCount(self: *Self) usize {
    return self.line_count;
}

/// Number of characters in a line (excluding newline)
pub fn lineLength(self: *Self, line: usize) usize {
    if (line >= self.line_count) return 0;
    const info = self.lines.items[line];
    // Remove trailing newline from length
    if (info.len > 0) {
        const last_char = self.charAt(info.start + info.len - 1);
        if (last_char == '\n') {
            if (info.len > 1 and self.charAt(info.start + info.len - 2) == '\r') return info.len - 2;
            return info.len - 1;
        } else if (last_char == '\r') {
            return info.len - 1;
        }
    }
    return info.len;
}

/// Get character at byte offset
fn charAt(self: *Self, offset: usize) u8 {
    var pos: usize = 0;
    for (self.pieces.items) |piece| {
        if (offset >= pos and offset < pos + piece.len) {
            const src = if (piece.original) self.original else self.add.items;
            return src[piece.start + (offset - pos)];
        }
        pos += piece.len;
    }
    return 0;
}

/// Common language extensions map
const LANGUAGE_MAP = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".zig", "zig" },
    .{ ".zir", "zig" },
    .{ ".rs", "rust" },
    .{ ".c", "c" },
    .{ ".h", "c" },
    .{ ".cpp", "cpp" },
    .{ ".cc", "cpp" },
    .{ ".cxx", "cpp" },
    .{ ".hpp", "cpp" },
    .{ ".py", "python" },
    .{ ".pyi", "python" },
    .{ ".pyx", "python" },
    .{ ".js", "javascript" },
    .{ ".jsx", "javascript" },
    .{ ".mjs", "javascript" },
    .{ ".cjs", "javascript" },
    .{ ".ts", "typescript" },
    .{ ".tsx", "typescript" },
    .{ ".go", "go" },
    .{ ".java", "java" },
    .{ ".kt", "kotlin" },
    .{ ".swift", "swift" },
    .{ ".rb", "ruby" },
    .{ ".lua", "lua" },
    .{ ".sh", "bash" },
    .{ ".bash", "bash" },
    .{ ".zsh", "bash" },
    .{ ".fish", "fish" },
    .{ ".html", "html" },
    .{ ".htm", "html" },
    .{ ".css", "css" },
    .{ ".scss", "scss" },
    .{ ".sass", "sass" },
    .{ ".less", "less" },
    .{ ".json", "json" },
    .{ ".jsonc", "jsonc" },
    .{ ".yaml", "yaml" },
    .{ ".yml", "yaml" },
    .{ ".toml", "toml" },
    .{ ".xml", "xml" },
    .{ ".md", "markdown" },
    .{ ".mdx", "markdown" },
    .{ ".sql", "sql" },
    .{ ".r", "r" },
    .{ ".m", "objective-c" },
    .{ ".mm", "objective-cpp" },
    .{ ".tex", "latex" },
    .{ ".nim", "nim" },
    .{ ".odin", "odin" },
    .{ ".v", "v" },
    .{ ".scala", "scala" },
    .{ ".clj", "clojure" },
    .{ ".cljs", "clojure" },
    .{ ".ex", "elixir" },
    .{ ".exs", "elixir" },
    .{ ".erl", "erlang" },
    .{ ".hs", "haskell" },
    .{ ".ml", "ocaml" },
    .{ ".mli", "ocaml" },
    .{ ".php", "php" },
    .{ ".dart", "dart" },
    .{ ".rkt", "racket" },
    .{ ".scm", "scheme" },
    .{ ".lisp", "lisp" },
    .{ ".ino", "cpp" },
    .{ ".cmake", "cmake" },
    .{ "CMakeLists.txt", "cmake" },
    .{ "Makefile", "makefile" },
    .{ "Dockerfile", "dockerfile" },
    .{ ".dockerfile", "dockerfile" },
});
