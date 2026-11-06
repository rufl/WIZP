// WIZP Terminal Session — Ghostty-inspired PTY handling with dedicated reader thread
// Provides event-driven output for the webview terminal (xterm.js) via queue + condvar.
// This replaces the previous direct non-blocking read from the RPC handler.

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Test-only process controls are explicit so failure paths can be exercised
/// without replacing a real shell or disturbing another live session.
pub const CreateOptions = struct {
    inject_spawn_failure: bool = false,
};

pub const ExitKind = enum {
    running,
    exited,
    signaled,
    unknown,
};

pub const ExitStatus = struct {
    kind: ExitKind = .running,
    code: u8 = 0,
    signal: u8 = 0,
    reaped: bool = false,
};

/// The queue is deliberately finite; dropped bytes are reported in ReadResult.
pub const output_queue_capacity_bytes: usize = 16 * 1024 * 1024;
fn enqueueBoundedOutput(
    queue: anytype,
    head: *usize,
    dropped_bytes: *usize,
    data: []const u8,
    capacity: usize,
) void {
    if (capacity == 0) {
        dropped_bytes.* += data.len;
        return;
    }
    if (data.len >= capacity) {
        dropped_bytes.* += queue.items.len + data.len - capacity;
        queue.clearRetainingCapacity();
        head.* = 0;
        queue.appendSlice(data[data.len - capacity ..]) catch {
            dropped_bytes.* += capacity;
        };
        return;
    }
    // Until full, append normally. Once full, overwrite only the oldest bytes;
    // never shift the entire 16 MiB queue for each 4 KiB PTY read.
    const growth = @min(data.len, capacity - queue.items.len);
    const previous_len = queue.items.len;
    queue.resize(previous_len + growth) catch {
        dropped_bytes.* += data.len;
        return;
    };
    @memcpy(queue.items[previous_len..], data[0..growth]);
    const overflow = data[growth..];
    if (overflow.len == 0) return;
    dropped_bytes.* += overflow.len;
    const first = @min(overflow.len, capacity - head.*);
    @memcpy(queue.items[head.*..][0..first], overflow[0..first]);
    @memcpy(queue.items[0 .. overflow.len - first], overflow[first..]);
    head.* = (head.* + overflow.len) % capacity;
}

fn copyQueuedOutput(allocator: Allocator, items: []const u8, head: usize) ![]u8 {
    const owned = try allocator.alloc(u8, items.len);
    const first = items.len - head;
    @memcpy(owned[0..first], items[head..]);
    @memcpy(owned[first..], items[0..head]);
    return owned;
}

pub const Session = if (builtin.os.tag == .windows) struct {
    allocator: Allocator,
    spawn_result: ?pty.win.SpawnResult = null,
    child_pid: ?pty.Pid = null,
    read_thread: ?std.Thread = null,
    exit_thread: ?std.Thread = null,
    exit_status: ExitStatus = .{},
    reaping_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    hpc_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue: std.array_list.Managed(u8),
    queue_head: usize = 0,
    dropped_bytes: usize = 0,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: @import("../sync.zig").Mutex = .{},
    cond: @import("../sync.zig").Condition = .{},

    const Self = @This();
    const pty = @import("zigpty");

    pub const ReadResult = struct {
        data: []u8,
        eof: bool = false,
        dropped_bytes: usize = 0,
    };

    pub fn create(allocator: Allocator, shell_cmd: []const u8) !*Self {
        return createWithCwd(allocator, shell_cmd, ".");
    }

    pub fn createWithCwd(allocator: Allocator, shell_cmd: []const u8, cwd: []const u8) !*Self {
        return createWithCwdAndOptions(allocator, shell_cmd, cwd, .{});
    }

    pub fn createWithCwdAndOptions(
        allocator: Allocator,
        shell_cmd: []const u8,
        cwd: []const u8,
        options: CreateOptions,
    ) !*Self {
        if (options.inject_spawn_failure) return error.TerminalSpawnInjected;
        var cwd_dir = try std.Io.Dir.cwd().openDir(
            @import("../runtime_016.zig").io(),
            cwd,
            .{},
        );
        cwd_dir.close(@import("../runtime_016.zig").io());

        const command = try pty.win.utf8ToUtf16Alloc(allocator, shell_cmd);
        defer allocator.free(command);
        const cwd_w = try pty.win.utf8ToUtf16Alloc(allocator, cwd);
        defer allocator.free(cwd_w);
        const spawned = try pty.win.spawnConPty(command.ptr, null, cwd_w.ptr, 80, 24);

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .spawn_result = spawned,
            .child_pid = spawned.pid,
            .queue = std.array_list.Managed(u8).init(allocator),
        };
        errdefer self.deinit();

        self.read_thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});
        self.exit_thread = try std.Thread.spawn(.{}, exitThreadFn, .{self});
        return self;
    }

    /// Wait until the child has produced its initial prompt/output. This keeps
    /// writes issued immediately after spawn from racing shell initialization.
    pub fn waitForReady(self: *Self, timeout_ms: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len > 0 or !self.active.load(.seq_cst)) {
            return self.queue.items.len > 0;
        }
        self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * std.time.ns_per_ms) catch |err| {
            if (err != error.Timeout) return false;
        };
        return self.queue.items.len > 0;
    }

    pub fn exitStatus(self: *Self) ExitStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit_status;
    }

    pub fn read(self: *Self, timeout_ms: u32) !ReadResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len > 0) return self.takeQueued();
        if (!self.active.load(.seq_cst)) return self.takeDropped(true);

        self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * std.time.ns_per_ms) catch |err| {
            if (err == error.Timeout) return self.takeDropped(false);
            return err;
        };
        if (self.queue.items.len > 0) return self.takeQueued();
        return self.takeDropped(!self.active.load(.seq_cst));
    }

    pub fn write(self: *Self, data: []const u8) !void {
        if (data.len == 0) return;
        const result = self.spawn_result orelse return error.BrokenPipe;
        try pty.win.writeInput(result.conin, data);
    }

    pub fn resize(self: *Self, rows: usize, cols: usize) void {
        const result = self.spawn_result orelse return;
        pty.win.resizeConsole(result.hpc, @intCast(cols), @intCast(rows)) catch {};
    }

    pub fn kill(self: *Self) void {
        if (self.closed.swap(true, .acq_rel)) return;

        if (self.spawn_result) |result| pty.win.killProcess(result.process, 1);
        if (self.exit_thread) |thread| {
            thread.join();
            self.exit_thread = null;
        } else {
            self.closePseudoConsole();
        }
        if (self.read_thread) |thread| {
            thread.join();
            self.read_thread = null;
        }
        if (self.spawn_result) |*result| {
            pty.win.closePty(result);
            self.spawn_result = null;
        }
        self.child_pid = null;
        self.active.store(false, .seq_cst);
        self.cond.broadcast();
    }

    pub fn isClosed(self: *Self) bool {
        return self.closed.load(.acquire) or !self.active.load(.seq_cst);
    }

    pub fn deinit(self: *Self) void {
        self.kill();
        self.queue.deinit();
        self.allocator.destroy(self);
    }

    fn takeQueued(self: *Self) !ReadResult {
        const owned = try copyQueuedOutput(self.allocator, self.queue.items, self.queue_head);
        self.queue.clearRetainingCapacity();
        self.queue_head = 0;
        const dropped = self.dropped_bytes;
        self.dropped_bytes = 0;
        return .{ .data = owned, .eof = !self.active.load(.seq_cst), .dropped_bytes = dropped };
    }
    fn takeDropped(self: *Self, eof: bool) ReadResult {
        const dropped = self.dropped_bytes;
        self.dropped_bytes = 0;
        return .{ .data = &[_]u8{}, .eof = eof, .dropped_bytes = dropped };
    }

    fn readerThreadFn(self: *Self) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = self.spawn_result orelse break;
            const count = pty.win.readOutput(result.conout, &buffer);
            if (count == 0) break;
            self.mutex.lock();
            enqueueBoundedOutput(&self.queue, &self.queue_head, &self.dropped_bytes, buffer[0..count], output_queue_capacity_bytes);
            self.cond.signal();
            self.mutex.unlock();
        }
        self.active.store(false, .seq_cst);
        self.cond.broadcast();
    }

    fn exitThreadFn(self: *Self) void {
        const result = self.spawn_result orelse return;
        _ = pty.win.waitForExit(result.process);
        self.closePseudoConsole();
    }

    fn closePseudoConsole(self: *Self) void {
        if (self.hpc_closed.swap(true, .seq_cst)) return;
        if (self.spawn_result) |*result| {
            pty.win.closeConin(result);
            pty.win.closePseudoConsole(result.hpc);
        }
    }
} else struct {
    allocator: Allocator,
    master: std.posix.fd_t,
    read_thread: ?std.Thread = null,
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    queue: std.array_list.Managed(u8),
    queue_head: usize = 0,
    dropped_bytes: usize = 0,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: @import("../sync.zig").Mutex = .{},
    cond: @import("../sync.zig").Condition = .{},
    child_pid: ?std.process.Child.Id = null,
    exit_status: ExitStatus = .{},
    reaping_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_read: std.posix.fd_t,
    wake_write: std.posix.fd_t,

    const Self = @This();
    const pty = @import("zigpty");

    pub const ReadResult = struct {
        data: []u8,
        eof: bool = false,
        dropped_bytes: usize = 0,
    };

    pub fn create(allocator: Allocator, shell_cmd: []const u8) !*Self {
        return createWithCwd(allocator, shell_cmd, "/");
    }

    pub fn createWithCwd(allocator: Allocator, shell_cmd: []const u8, cwd: []const u8) !*Self {
        return createWithCwdAndOptions(allocator, shell_cmd, cwd, .{});
    }

    pub fn createWithCwdAndOptions(
        allocator: Allocator,
        shell_cmd: []const u8,
        cwd: []const u8,
        options: CreateOptions,
    ) !*Self {
        if (options.inject_spawn_failure) return error.TerminalSpawnInjected;
        var cwd_dir = try std.Io.Dir.cwd().openDir(
            @import("../runtime_016.zig").io(),
            cwd,
            .{},
        );
        cwd_dir.close(@import("../runtime_016.zig").io());

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const wake_fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            (std.Io.File{ .handle = wake_fds[0], .flags = .{ .nonblocking = true } }).close(
                @import("../runtime_016.zig").io(),
            );
            (std.Io.File{ .handle = wake_fds[1], .flags = .{ .nonblocking = true } }).close(
                @import("../runtime_016.zig").io(),
            );
        }

        const shell = if (std.mem.eql(u8, shell_cmd, "/bin/sh")) "/bin/bash" else shell_cmd;
        const shell_z = try runtime.dupeZ(allocator, shell);
        defer allocator.free(shell_z);
        const cwd_z = try runtime.dupeZ(allocator, cwd);
        defer allocator.free(cwd_z);

        var argv_buf: [8]?[*:0]const u8 = undefined;
        argv_buf[0] = shell_z.ptr;
        argv_buf[1] = "-l";
        argv_buf[2] = "-i";
        argv_buf[3] = null;

        const envp = runtime.posixEnvironment();

        const fork_result = try pty.forkPty(.{
            .file = shell_z.ptr,
            .argv = @ptrCast(&argv_buf),
            .envp = envp,
            .cwd = cwd_z.ptr,
            .cols = 80,
            .rows = 24,
            .use_utf8 = true,
        });
        self.* = .{
            .allocator = allocator,
            .master = fork_result.fd,
            .child_pid = fork_result.pid,
            .queue = std.array_list.Managed(u8).init(allocator),
            .wake_read = wake_fds[0],
            .wake_write = wake_fds[1],
        };
        errdefer self.deinit();

        const flags_raw = std.posix.system.fcntl(self.master, std.posix.F.GETFL, @as(usize, 0));
        if (flags_raw < 0) return error.TerminalIoSetupFailed;
        const nonblocking_flag: usize = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        const set_flags_result = std.posix.system.fcntl(self.master, std.posix.F.SETFL, @as(usize, @intCast(flags_raw)) | nonblocking_flag);
        if (set_flags_result < 0) return error.TerminalIoSetupFailed;
        self.read_thread = try std.Thread.spawn(.{}, readerThreadFn, .{self});
        self.resize(24, 80);

        return self;
    }

    /// Wait until the child has produced its initial prompt/output. This keeps
    /// writes issued immediately after spawn from racing shell initialization.
    pub fn waitForReady(self: *Self, timeout_ms: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len > 0 or !self.active.load(.seq_cst)) {
            return self.queue.items.len > 0;
        }
        self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * std.time.ns_per_ms) catch |err| {
            if (err != error.Timeout) return false;
        };
        return self.queue.items.len > 0;
    }

    fn readerThreadFn(self: *Self) void {
        var local_buf: [4096]u8 = undefined;

        while (self.active.load(.seq_cst)) {
            var poll_fds: [2]std.posix.pollfd = .{
                .{ .fd = self.master, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_read, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const poll_result = std.posix.poll(&poll_fds, -1) catch |err| {
                if (err == error.InterruptedSystemCall) continue;
                break;
            };
            if (poll_result == 0) continue;

            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                var discard: [64]u8 = undefined;
                _ = std.posix.read(self.wake_read, &discard) catch {};
                break;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(self.master, &local_buf) catch |err| {
                    if (err == error.InterruptedSystemCall or err == error.WouldBlock) continue;
                    break;
                };
                if (n == 0) {
                    break;
                }
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    enqueueBoundedOutput(&self.queue, &self.queue_head, &self.dropped_bytes, local_buf[0..n], output_queue_capacity_bytes);
                    self.cond.signal();
                }
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                break;
            }
        }

        if (!self.closed.load(.acquire)) {
            if (self.child_pid) |pid| self.reapChildOnce(pid);
        }
        self.active.store(false, .seq_cst);
        self.cond.broadcast();
    }

    pub fn exitStatus(self: *Self) ExitStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit_status;
    }

    pub fn read(self: *Self, timeout_ms: u32) !ReadResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0 and self.active.load(.seq_cst)) {
            const timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
            self.cond.timedWait(&self.mutex, timeout_ns) catch |err| {
                if (err != error.Timeout) return err;
            };
        }

        var owned: []u8 = &[_]u8{};
        if (self.queue.items.len > 0) {
            owned = try copyQueuedOutput(self.allocator, self.queue.items, self.queue_head);
            self.queue.clearRetainingCapacity();
            self.queue_head = 0;
        }
        const dropped_bytes = self.dropped_bytes;
        self.dropped_bytes = 0;
        return .{
            .data = owned,
            .eof = !self.active.load(.seq_cst),
            .dropped_bytes = dropped_bytes,
        };
    }

    pub fn write(self: *Self, data: []const u8) !void {
        if (data.len == 0) return;
        if (!self.active.load(.acquire)) return error.BrokenPipe;
        var offset: usize = 0;
        const deadline = runtime.nanoTimestamp() + 500 * std.time.ns_per_ms;
        const file = std.Io.File{ .handle = self.master, .flags = .{ .nonblocking = true } };
        while (offset < data.len) {
            const remaining_ns = deadline - runtime.nanoTimestamp();
            if (remaining_ns <= 0) return error.WriteTimeout;
            const remaining_ms: i32 = @intCast(@max(@divTrunc(remaining_ns, std.time.ns_per_ms), 1));
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = self.master,
                .events = std.posix.POLL.OUT,
                .revents = 0,
            }};
            const poll_result = std.posix.poll(&poll_fds, remaining_ms) catch |err| {
                if (err == error.InterruptedSystemCall) continue;
                return err;
            };
            if (poll_result == 0) return error.WriteTimeout;
            const end = @min(offset + 4096, data.len);
            const written = file.writeStreaming(runtime.io(), &.{}, &.{data[offset..end]}, 1) catch |err| {
                if (err == error.InterruptedSystemCall or err == error.WouldBlock) continue;
                return err;
            };
            if (written == 0) return error.WriteTimeout;
            offset += written;
        }
    }

    pub fn resize(self: *Self, rows: usize, cols: usize) void {
        if (!self.active.load(.acquire)) return;
        _ = pty.resize(self.master, @intCast(cols), @intCast(rows), 0, 0) catch {};
    }

    pub fn kill(self: *Self) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.active.store(false, .seq_cst);
        self.cond.broadcast();

        const child_pid = self.child_pid;
        if (child_pid) |pid| {
            _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }

        const wake_byte: u8 = 1;
        @import("../runtime_016.zig").writeAll(
            .{ .handle = self.wake_write, .flags = .{ .nonblocking = true } },
            &[_]u8{wake_byte},
        ) catch {};

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (child_pid) |pid| self.reapChildOnce(pid);

        (std.Io.File{
            .handle = self.master,
            .flags = .{ .nonblocking = false },
        }).close(@import("../runtime_016.zig").io());
        self.child_pid = null;
        (std.Io.File{
            .handle = self.wake_read,
            .flags = .{ .nonblocking = true },
        }).close(@import("../runtime_016.zig").io());
        (std.Io.File{
            .handle = self.wake_write,
            .flags = .{ .nonblocking = true },
        }).close(@import("../runtime_016.zig").io());
    }

    fn reapChildOnce(self: *Self, pid: std.process.Child.Id) void {
        if (self.reaping_started.swap(true, .acq_rel)) return;
        const status = reapChild(pid);
        self.mutex.lock();
        self.exit_status = status;
        self.mutex.unlock();
    }

    fn reapChild(pid: std.process.Child.Id) ExitStatus {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        var attempts: usize = 0;
        while (attempts < 50) {
            const result = std.posix.system.waitpid(pid, &status, @intCast(std.posix.W.NOHANG));
            switch (std.posix.errno(result)) {
                .SUCCESS => {
                    if (result != 0) return decodeExitStatus(status);
                    attempts += 1;
                    @import("../runtime_016.zig").sleepNanoseconds(10 * std.time.ns_per_ms);
                },
                .INTR => continue,
                .CHILD => return .{ .kind = .unknown, .reaped = true },
                else => return .{ .kind = .unknown, .reaped = false },
            }
        }

        _ = std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        while (true) {
            const result = std.posix.system.waitpid(pid, &status, 0);
            switch (std.posix.errno(result)) {
                .SUCCESS => return decodeExitStatus(status),
                .CHILD => return .{ .kind = .unknown, .reaped = true },
                .INTR => continue,
                else => return .{ .kind = .unknown, .reaped = false },
            }
        }
    }

    fn decodeExitStatus(status: if (builtin.link_libc) c_int else u32) ExitStatus {
        const portable_status: u32 = @intCast(status);
        if (std.posix.W.IFEXITED(portable_status)) {
            return .{ .kind = .exited, .code = @intCast(std.posix.W.EXITSTATUS(portable_status)), .reaped = true };
        }
        if (std.posix.W.IFSIGNALED(portable_status)) {
            return .{ .kind = .signaled, .signal = @intCast(@backingInt(std.posix.W.TERMSIG(portable_status))), .reaped = true };
        }
        return .{ .kind = .unknown, .reaped = true };
    }

    pub fn isClosed(self: *Self) bool {
        return self.closed.load(.acquire) or !self.active.load(.seq_cst);
    }

    pub fn deinit(self: *Self) void {
        self.kill();
        self.queue.deinit();
        self.allocator.destroy(self);
    }
};

test "bounded terminal output retains newest bytes with exact drop accounting" {
    const allocator = std.testing.allocator;
    var queue = std.array_list.Managed(u8).init(allocator);
    defer queue.deinit();
    var head: usize = 0;
    var dropped: usize = 0;

    enqueueBoundedOutput(&queue, &head, &dropped, "abcd", 5);
    enqueueBoundedOutput(&queue, &head, &dropped, "efg", 5);
    enqueueBoundedOutput(&queue, &head, &dropped, "hijk", 5);
    const wrapped = try copyQueuedOutput(allocator, queue.items, head);
    defer allocator.free(wrapped);
    try std.testing.expectEqualStrings("ghijk", wrapped);
    try std.testing.expectEqual(@as(usize, 6), dropped);

    enqueueBoundedOutput(&queue, &head, &dropped, "nopqrst", 5);
    const oversized = try copyQueuedOutput(allocator, queue.items, head);
    defer allocator.free(oversized);
    try std.testing.expectEqualStrings("pqrst", oversized);
    try std.testing.expectEqual(@as(usize, 13), dropped);
}

test "terminal session reports dropped output after EOF" {
    if (builtin.os.tag == .windows) return;

    const session = try Session.create(std.testing.allocator, "/bin/true");
    defer session.deinit();

    var reached_eof = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = try session.read(20);
        if (result.data.len > 0) std.testing.allocator.free(result.data);
        if (result.eof) {
            reached_eof = true;
            break;
        }
    }
    try std.testing.expect(reached_eof);

    session.mutex.lock();
    session.dropped_bytes = 23;
    session.mutex.unlock();

    const result = try session.read(0);
    if (result.data.len > 0) std.testing.allocator.free(result.data);
    try std.testing.expect(result.eof);
    try std.testing.expectEqual(@as(usize, 23), result.dropped_bytes);
}

test "terminal session spawn failure injection is typed and side-effect free" {
    if (builtin.os.tag == .windows) return;

    try std.testing.expectError(
        error.TerminalSpawnInjected,
        Session.createWithCwdAndOptions(
            std.testing.allocator,
            "/bin/sh",
            "/",
            .{ .inject_spawn_failure = true },
        ),
    );
}

test "terminal session retains normal exit status and reaps once" {
    if (builtin.os.tag == .windows) return;

    const session = try Session.create(std.testing.allocator, "/bin/true");
    defer session.deinit();

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = try session.read(20);
        if (result.data.len > 0) std.testing.allocator.free(result.data);
        if (result.eof) break;
    }

    const status = session.exitStatus();
    try std.testing.expectEqual(ExitKind.exited, status.kind);
    try std.testing.expect(status.reaped);
}

test "terminal session writes complete command batches" {
    if (builtin.os.tag == .windows) return;

    const session = try Session.create(std.testing.allocator, "/bin/bash");
    defer session.deinit();
    try session.write("printf 'WIZP_BATCH_WRITE_OK\\n'\n");

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = try session.read(20);
        defer if (result.data.len > 0) std.testing.allocator.free(result.data);
        try output.appendSlice(result.data);
        if (std.mem.indexOf(u8, output.items, "WIZP_BATCH_WRITE_OK") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, output.items, "WIZP_BATCH_WRITE_OK") != null);
}

test "terminal session retains abnormal exit status and reaps once" {
    if (builtin.os.tag == .windows) return;

    const session = try Session.create(std.testing.allocator, "/bin/bash");
    defer session.deinit();
    try std.posix.kill(session.child_pid.?, std.posix.SIG.KILL);

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const result = try session.read(20);
        if (result.data.len > 0) std.testing.allocator.free(result.data);
        if (result.eof) break;
    }

    const status = session.exitStatus();
    try std.testing.expectEqual(ExitKind.signaled, status.kind);
    try std.testing.expectEqual(
        @as(u8, @intCast(@backingInt(std.posix.SIG.KILL))),
        status.signal,
    );
    try std.testing.expect(status.reaped);
}

test "terminal session repeated natural exit cleanup is bounded" {
    if (builtin.os.tag == .windows) return;

    var cycle: usize = 0;
    while (cycle < 8) : (cycle += 1) {
        const session = try Session.create(std.testing.allocator, "/bin/true");
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            const result = try session.read(20);
            if (result.data.len > 0) std.testing.allocator.free(result.data);
            if (result.eof) break;
        }
        const status = session.exitStatus();
        try std.testing.expectEqual(ExitKind.exited, status.kind);
        try std.testing.expect(status.reaped);
        session.deinit();
    }
}

test "terminal session kill joins reader and reports EOF" {
    if (builtin.os.tag == .windows) return;

    const session = try Session.create(std.testing.allocator, "/bin/sh");
    const child_pid = session.child_pid.?;
    session.kill();
    try std.testing.expect(session.isClosed());
    try std.testing.expect(session.child_pid == null);

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const wait_result = std.posix.system.waitpid(child_pid, &status, @intCast(std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_result));

    const result = try session.read(0);
    defer if (result.data.len > 0) std.testing.allocator.free(result.data);
    try std.testing.expect(result.eof);

    // Teardown is intentionally idempotent after the reader thread and fds are closed.
    session.kill();
    try std.testing.expect(session.isClosed());
    session.deinit();
}
