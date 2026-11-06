// WIZP Worker Pool — lightweight thread pool for background tasks.
//
// Usage:
//   var pool = WorkerPool.init(allocator, 4);
//   defer pool.deinit();
//   try pool.spawn(myTask, &args);
//
// Tasks can post results back to main thread via a Channel(WorkerResult).

const std = @import("std");
const Channel = @import("Channel.zig");

/// A task that can be executed by the worker pool.
pub const Task = struct {
    execute: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
    ctx_deinit: *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void,
};

/// Thread pool with a fixed number of worker threads.
pub const WorkerPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    /// Mutex-protected task queue (shared by all workers)
    mutex: @import("../sync.zig").Mutex = .{},
    cond: @import("../sync.zig").Condition = .{},
    queue: std.array_list.Managed(Task),
    read_index: usize = 0,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, num_threads: usize) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, num_threads),
            .queue = std.array_list.Managed(Task).init(allocator),
            .read_index = 0,
        };
        errdefer allocator.free(self.threads);

        for (0..num_threads) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        return self;
    }

    /// Submit a task for background execution. Returns immediately.
    pub fn spawn(self: *Self, ctx: anytype, comptime exec_fn: fn (ctx: @TypeOf(ctx)) void) !void {
        const Ctx = @TypeOf(ctx);
        const Boxed = struct {
            fn execute(ptr: *anyopaque) void {
                const real_ctx: *Ctx = @ptrCast(@alignCast(ptr));
                exec_fn(real_ctx.*);
            }
        };

        const ctx_copy = try self.allocator.create(Ctx);
        ctx_copy.* = ctx;

        const task = Task{
            .execute = Boxed.execute,
            .ctx = @ptrCast(ctx_copy),
            .ctx_deinit = struct {
                fn deinit(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                    const real: *Ctx = @ptrCast(@alignCast(ptr));
                    allocator.destroy(real);
                }
            }.deinit,
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(task);
        }
        self.cond.signal();
    }

    fn workerLoop(pool: *Self) void {
        while (true) {
            const task: ?Task = blk: {
                pool.mutex.lock();
                defer pool.mutex.unlock();

                while (pool.queue.items.len <= pool.read_index and !pool.shutdown.load(.acquire)) {
                    pool.cond.wait(&pool.mutex);
                }

                if (pool.shutdown.load(.acquire) and pool.queue.items.len <= pool.read_index) {
                    break :blk null;
                }

                const t = pool.queue.items[pool.read_index];
                pool.read_index += 1;
                if (pool.read_index == pool.queue.items.len) {
                    pool.queue.clearRetainingCapacity();
                    pool.read_index = 0;
                }
                break :blk t;
            };

            if (task) |t| {
                t.execute(t.ctx);
                t.ctx_deinit(pool.allocator, t.ctx);
            } else {
                break;
            }
        }
    }

    /// Shut down all worker threads. Blocks until all threads exit.
    pub fn deinit(self: *Self) void {
        const allocator = self.allocator;
        self.shutdown.store(true, .release);
        self.cond.broadcast();

        for (self.threads) |thread| {
            thread.join();
        }

        // Drain remaining tasks (their contexts were allocated by spawn())
        for (self.queue.items[self.read_index..]) |t| {
            t.ctx_deinit(self.allocator, t.ctx);
        }
        self.queue.deinit();
        self.allocator.free(self.threads);
        allocator.destroy(self);
    }
};

// ============================================================
// Tests
// ============================================================

test "WorkerPool spawn and result" {
    const pool = try WorkerPool.init(std.testing.allocator, 2);
    defer pool.deinit();

    const Ctx = struct {
        value: std.atomic.Value(u32),

        fn task(ctx: *@This()) void {
            ctx.value.store(42, .release);
        }
    };

    var ctx = Ctx{ .value = std.atomic.Value(u32).init(0) };
    try pool.spawn(&ctx, Ctx.task);

    @import("../runtime_016.zig").sleepNanoseconds(10 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 42), ctx.value.load(.acquire));
}

test "WorkerPool multiple tasks" {
    const pool = try WorkerPool.init(std.testing.allocator, 4);
    defer pool.deinit();

    const Ctx = struct {
        counter: std.atomic.Value(u32),

        fn task(ctx: *@This()) void {
            _ = ctx.counter.fetchAdd(1, .monotonic);
        }
    };

    var ctx = Ctx{ .counter = std.atomic.Value(u32).init(0) };

    for (0..10) |_| {
        try pool.spawn(&ctx, Ctx.task);
    }

    @import("../runtime_016.zig").sleepNanoseconds(50 * std.time.ns_per_ms);

    const count = ctx.counter.load(.acquire);
    try std.testing.expect(count >= 1);
}

test "WorkerPool deinit joins workers and drains queued tasks" {
    const Ctx = struct {
        completed: std.atomic.Value(u32),

        fn task(ctx: *@This()) void {
            _ = ctx.completed.fetchAdd(1, .release);
        }
    };

    var ctx = Ctx{ .completed = std.atomic.Value(u32).init(0) };
    const pool = try WorkerPool.init(std.testing.allocator, 2);
    for (0..32) |_| try pool.spawn(&ctx, Ctx.task);

    pool.deinit();

    try std.testing.expectEqual(@as(u32, 32), ctx.completed.load(.acquire));
}
