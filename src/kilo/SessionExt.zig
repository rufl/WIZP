// Kilo Code Extended Features for WIZP
// Session persistence, hooks, checkpoints, file watcher, auto-approve rules

const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("../runtime_016.zig");

// ============================================================
// Session Persistence
// ============================================================

pub const SessionStore = struct {
    allocator: Allocator,
    data_dir: []const u8,

    pub fn init(allocator: Allocator, data_dir: []const u8) !SessionStore {
        try std.Io.Dir.cwd().createDirPath(runtime.io(), data_dir);
        return .{ .allocator = allocator, .data_dir = try allocator.dupe(u8, data_dir) };
    }

    fn sessionPath(self: *SessionStore, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.data_dir, filename });
    }

    /// Save session to disk as JSON
    pub fn save(self: *SessionStore, session_id: []const u8, messages: []const SessionMessage) !void {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        try w.writeAll("{\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"role\":\"{s}\",\"content\":\"", .{@tagName(msg.role)});
            for (msg.content) |ch| {
                switch (ch) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(ch),
                }
            }
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");

        try std.Io.Dir.cwd().writeFile(
            runtime.io(),
            .{ .sub_path = path, .data = buf.written() },
        );
    }

    /// Load session from disk
    pub fn load(self: *SessionStore, allocator: Allocator, session_id: []const u8) ![]const SessionMessage {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        const content = std.Io.Dir.cwd().readFileAlloc(
            runtime.io(),
            path,
            allocator,
            .limited(10 * 1024 * 1024),
        ) catch {
            return &[_]SessionMessage{};
        };
        defer allocator.free(content);

        // Parse JSON messages array: {"messages":[{"role":"...","content":"..."},...]}
        var messages = std.array_list.Managed(SessionMessage).init(allocator);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, content, pos, "\"role\"")) |role_start| {
            if (std.mem.indexOfScalarPos(u8, content, role_start + 6, '"')) |rv0| {
                if (std.mem.indexOfScalarPos(u8, content, rv0 + 1, '"')) |rv1| {
                    const role_str = content[rv0 + 1 .. rv1];
                    const role = std.meta.stringToEnum(SessionMessage.Role, role_str) orelse .user;
                    var msg_content: []const u8 = "";
                    if (std.mem.indexOfPos(u8, content, rv1, "\"content\"")) |c_start| {
                        if (std.mem.indexOfScalarPos(u8, content, c_start + 9, '"')) |cv0| {
                            if (std.mem.indexOfScalarPos(u8, content, cv0 + 1, '"')) |cv1| {
                                msg_content = content[cv0 + 1 .. cv1];
                            }
                        }
                    }
                    try messages.append(.{ .role = role, .content = try allocator.dupe(u8, msg_content) });
                    pos = role_start + 1;
                    continue;
                }
            }
            break;
        }
        return messages.toOwnedSlice();
    }

    /// List saved sessions
    pub fn list(self: *SessionStore) ![]const []const u8 {
        var sessions = std.array_list.Managed([]const u8).init(self.allocator);
        var dir = try std.Io.Dir.cwd().openDir(runtime.io(), self.data_dir, .{ .iterate = true });
        defer dir.close(runtime.io());
        var read_buffer: [std.Io.Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
        var iter = dir.reader(runtime.io(), &read_buffer);
        while (try iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".json")) {
                const name = entry.name[0 .. entry.name.len - 5];
                try sessions.append(try self.allocator.dupe(u8, name));
            }
        }
        return sessions.toOwnedSlice();
    }

    pub fn deinit(self: *SessionStore) void {
        self.allocator.free(self.data_dir);
    }
};

pub const SessionMessage = struct {
    role: Role,
    content: []const u8,
    pub const Role = enum { system, user, assistant, tool };
};

// ============================================================
// Hooks System
// ============================================================

pub const HookEvent = enum {
    pre_tool, // Before tool execution
    post_tool, // After tool execution
    pre_edit, // Before file edit
    post_edit, // After file edit
    session_start, // Session begins
    session_end, // Session ends
};

pub const Hook = struct {
    event: HookEvent,
    /// Shell command or function name to execute
    command: []const u8,
    /// Tool name filter (only for tool events)
    tool_filter: ?[]const u8 = null,
};

pub const HookManager = struct {
    allocator: Allocator,
    hooks: std.array_list.Managed(Hook),

    pub fn init(allocator: Allocator) HookManager {
        return .{ .allocator = allocator };
    }

    pub fn addHook(self: *HookManager, hook: Hook) !void {
        try self.hooks.append(hook);
    }

    pub fn runHooks(self: *HookManager, event: HookEvent, tool_name: ?[]const u8) !void {
        for (self.hooks.items) |hook| {
            if (hook.event != event) continue;
            if (hook.tool_filter) |filter| {
                if (tool_name == null or !std.mem.eql(u8, tool_name.?, filter)) continue;
            }
            // Execute hook command
            var args = [_][]const u8{ "sh", "-c", hook.command };
            const result = try std.process.run(self.allocator, runtime.io(), .{ .argv = &args });
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
    }

    pub fn deinit(self: *HookManager) void {
        self.hooks.deinit();
    }
};

// ============================================================
// Checkpoints (File State Snapshots)
// ============================================================

pub const Checkpoint = struct {
    id: usize,
    file_path: []const u8,
    content: []const u8,
    timestamp: i64,
    description: []const u8,
};

pub const CheckpointManager = struct {
    allocator: Allocator,
    checkpoints: std.array_list.Managed(Checkpoint),
    next_id: usize = 0,

    pub fn init(allocator: Allocator) CheckpointManager {
        return .{ .allocator = allocator };
    }

    /// Save a checkpoint before AI edits
    pub fn saveCheckpoint(self: *CheckpointManager, file_path: []const u8, description: []const u8) !usize {
        const content = std.Io.Dir.cwd().readFileAlloc(
            runtime.io(),
            file_path,
            self.allocator,
            .limited(10 * 1024 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) {
                const id = self.next_id;
                self.next_id += 1;
                return id;
            }
            return err;
        };
        const id = self.next_id;
        self.next_id += 1;
        try self.checkpoints.append(.{
            .id = id,
            .file_path = try self.allocator.dupe(u8, file_path),
            .content = content,
            .timestamp = runtime.milliTimestamp(),
            .description = try self.allocator.dupe(u8, description),
        });
        return id;
    }

    /// Restore a checkpoint (undo AI edits)
    pub fn restoreCheckpoint(self: *CheckpointManager, id: usize) !void {
        for (self.checkpoints.items) |cp| {
            if (cp.id == id) {
                try std.Io.Dir.cwd().writeFile(
                    runtime.io(),
                    .{ .sub_path = cp.file_path, .data = cp.content },
                );
                return;
            }
        }
        return error.CheckpointNotFound;
    }

    /// Get all checkpoints for a file
    pub fn getForFile(self: *CheckpointManager, file_path: []const u8) ![]Checkpoint {
        var result = std.array_list.Managed(Checkpoint).init(self.allocator);
        errdefer result.deinit();
        for (self.checkpoints.items) |cp| {
            if (std.mem.eql(u8, cp.file_path, file_path)) {
                try result.append(cp);
            }
        }
        return result.toOwnedSlice();
    }

    pub fn deinit(self: *CheckpointManager) void {
        for (self.checkpoints.items) |cp| {
            self.allocator.free(cp.file_path);
            self.allocator.free(cp.content);
            self.allocator.free(cp.description);
        }
        self.checkpoints.deinit();
    }
};

// ============================================================
// File Watcher
// ============================================================

pub const FileChange = struct {
    path: []const u8,
    kind: ChangeKind,
    pub const ChangeKind = enum { created, modified, deleted };
};

pub const FileWatcher = struct {
    allocator: Allocator,
    watched_files: std.StringHashMapUnmanaged(i64), // path -> mtime
    changes: std.array_list.Managed(FileChange),

    pub fn init(allocator: Allocator) FileWatcher {
        return .{ .allocator = allocator };
    }

    pub fn watchFile(self: *FileWatcher, path: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch {
            try self.watched_files.put(self.allocator, try self.allocator.dupe(u8, path), 0);
            return;
        };
        try self.watched_files.put(
            self.allocator,
            try self.allocator.dupe(u8, path),
            @intCast(stat.mtime.nanoseconds),
        );
    }

    pub fn unwatchFile(self: *FileWatcher, path: []const u8) void {
        if (self.watched_files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Poll for changes. Returns new changes since last poll.
    pub fn poll(self: *FileWatcher) ![]const FileChange {
        self.changes.clearRetainingCapacity();
        var it = self.watched_files.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const old_mtime = entry.value_ptr.*;
            const stat = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch {
                try self.changes.append(.{ .path = path, .kind = .deleted });
                continue;
            };
            const new_mtime: i64 = @intCast(stat.mtime.nanoseconds);
            if (new_mtime != old_mtime) {
                const kind: FileChange.ChangeKind = if (old_mtime == 0) .created else .modified;
                try self.changes.append(.{ .path = path, .kind = kind });
                entry.value_ptr.* = new_mtime;
            }
        }
        return self.changes.items;
    }

    pub fn deinit(self: *FileWatcher) void {
        var it = self.watched_files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watched_files.deinit();
        self.changes.deinit();
    }
};

// ============================================================
// Auto-Approve Rules
// ============================================================

pub const ApproveRule = struct {
    /// Tool name to auto-approve
    tool_name: []const u8,
    /// Path pattern (glob) to auto-approve for
    path_pattern: ?[]const u8 = null,
    /// Max auto-approvals per session
    max_approvals: usize = 10,
    /// Current count
    count: usize = 0,
};

pub const ApproveManager = struct {
    allocator: Allocator,
    rules: std.array_list.Managed(ApproveRule),

    pub fn init(allocator: Allocator) ApproveManager {
        return .{ .allocator = allocator };
    }

    pub fn addRule(self: *ApproveManager, rule: ApproveRule) !void {
        try self.rules.append(rule);
    }

    /// Check if a tool call can be auto-approved
    pub fn canAutoApprove(self: *ApproveManager, tool_name: []const u8, file_path: ?[]const u8) bool {
        for (self.rules.items) |*rule| {
            if (!std.mem.eql(u8, rule.tool_name, tool_name)) continue;
            if (rule.count >= rule.max_approvals) continue;
            if (rule.path_pattern) |pattern| {
                if (file_path == null or !matchGlob(file_path.?, pattern)) continue;
            }
            rule.count += 1;
            return true;
        }
        return false;
    }

    /// Reset counters (per session)
    pub fn resetCounts(self: *ApproveManager) void {
        for (self.rules.items) |*rule| {
            rule.count = 0;
        }
    }

    pub fn deinit(self: *ApproveManager) void {
        for (self.rules.items) |rule| {
            self.allocator.free(rule.tool_name);
            if (rule.path_pattern) |p| self.allocator.free(p);
        }
        self.rules.deinit();
    }
};

fn matchGlob(path: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    return std.mem.indexOf(u8, path, pattern) != null;
}
