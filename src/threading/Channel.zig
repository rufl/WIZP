// Thread-safe channel for inter-thread communication.
// Mutex-protected queue — safe for multiple producers/consumers.
//
// Usage:
//   var ch = Channel(u8).init(allocator);
//   ch.push(42) catch {};
//   if (ch.pop()) |val| { ... }

const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        queue: std.array_list.Managed(T),
        read_index: usize = 0,
        mutex: @import("../sync.zig").Mutex = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .queue = std.array_list.Managed(T).init(allocator), .read_index = 0 };
        }

        /// Push a value. Thread-safe.
        pub fn push(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(value);
        }

        /// Pop a value. Returns null if queue is empty. Thread-safe.
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.queue.items.len <= self.read_index) return null;
            const val = self.queue.items[self.read_index];
            self.read_index += 1;
            if (self.read_index == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.read_index = 0;
            }
            return val;
        }

        /// Non-blocking: drain all available items into a callback with context.
        pub fn drain(self: *Self, ctx: anytype, comptime cb: fn (@TypeOf(ctx), T) void) void {
            while (self.pop()) |item| {
                cb(ctx, item);
            }
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }
    };
}

// ============================================================
// Common message types used across threads
// ============================================================

/// Commands from main thread to render thread
pub const RenderCmd = union(enum) {
    full_redraw: void,
    dirty_region: struct { row: usize, col: usize, rows: usize, cols: usize },
    resize: struct { rows: usize, cols: usize },
    quit: void,
};

/// Results from worker threads back to main thread
pub const AiChatResult = struct { response: []const u8, is_error: bool };
pub const AiCompletionResult = struct { text: []const u8 };
pub const FileResult = struct { path: []const u8, buffer_idx: usize };
pub const FileSavedResult = struct { path: []const u8, ok: bool };
pub const LspResult = struct { path: []const u8 };
pub const LspDiagResult = struct { path: []const u8, count: usize };
pub const LspCompletionResult = struct { id: u32, items: []const u8 };
pub const LspHoverResult = struct { id: u32, info: []const u8 };
pub const LspDefResult = struct { id: u32, uri: []const u8, line: usize, col: usize };
pub const SearchResult = struct { query: []const u8, matches: usize };
pub const GitResult = struct { branch: []const u8, files: []const u8 };
pub const ErrorResult = struct { msg: []const u8 };

pub const WorkerResult = union(enum) {
    file_loaded: FileResult,
    file_saved: FileSavedResult,
    lsp_initialized: LspResult,
    lsp_diagnostics: LspDiagResult,
    lsp_completion: LspCompletionResult,
    lsp_hover: LspHoverResult,
    lsp_definition: LspDefResult,
    search_complete: SearchResult,
    ai_completion: AiCompletionResult,
    ai_chat_response: AiChatResult,
    git_status: GitResult,
    err: ErrorResult,
};

test "Channel push/pop" {
    const allocator = std.testing.allocator;
    var ch = Channel(u32).init(allocator);
    defer ch.deinit();

    try ch.push(42);
    try ch.push(100);

    try std.testing.expectEqual(@as(?u32, 42), ch.pop());
    try std.testing.expectEqual(@as(?u32, 100), ch.pop());
    try std.testing.expectEqual(@as(?u32, null), ch.pop());
}

test "Channel drain" {
    const allocator = std.testing.allocator;
    var ch = Channel(u32).init(allocator);
    defer ch.deinit();

    try ch.push(1);
    try ch.push(2);
    try ch.push(3);

    var sum: u32 = 0;
    ch.drain(&sum, struct {
        fn cb(ctx: *u32, v: u32) void {
            ctx.* += v;
        }
    }.cb);

    try std.testing.expectEqual(@as(u32, 6), sum);
    try std.testing.expectEqual(@as(?u32, null), ch.pop());
}
