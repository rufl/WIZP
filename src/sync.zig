const std = @import("std");

/// Process-wide threaded I/O backs the Zig 0.16 synchronization primitives.
/// It is initialized exactly once and intentionally lives for the process: it
/// owns no per-request state, while its futex implementation wakes our native
/// worker and terminal threads without busy-waiting.
const RuntimeState = enum(u8) { uninitialized, initializing, ready };

var runtime_state = std.atomic.Value(RuntimeState).init(.uninitialized);
var configured_environ: std.process.Environ = .empty;
var environ_configured = false;
var threaded_io: std.Io.Threaded = undefined;

pub fn initialize(environ: std.process.Environ) void {
    std.debug.assert(runtime_state.load(.acquire) == .uninitialized);
    configured_environ = environ;
    environ_configured = true;
}

pub fn processEnviron() ?std.process.Environ {
    return if (environ_configured) configured_environ else null;
}

pub fn io() std.Io {
    while (true) {
        switch (runtime_state.load(.acquire)) {
            .ready => return threaded_io.io(),
            .uninitialized => {
                if (runtime_state.cmpxchgStrong(
                    .uninitialized,
                    .initializing,
                    .acq_rel,
                    .acquire,
                ) == null) {
                    threaded_io = .init(std.heap.page_allocator, .{
                        .environ = configured_environ,
                    });
                    runtime_state.store(.ready, .release);
                }
            },
            .initializing => std.atomic.spinLoopHint(),
        }
    }
}

/// A blocking mutex compatible with the pre-0.16 call sites, backed by the
/// Zig 0.16 futex-aware implementation rather than a CPU spin lock.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

/// Condition variable with both blocking and bounded waits. The sequence
/// counter prevents a signal between predicate inspection and sleeping from
/// being lost; futex waits avoid the previous nanosecond-counted busy loop.
pub const Condition = struct {
    epoch: std.atomic.Value(u32) = .init(0),

    pub fn signal(self: *Condition) void {
        _ = self.epoch.fetchAdd(1, .release);
        io().futexWake(u32, &self.epoch.raw, 1);
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.epoch.fetchAdd(1, .release);
        io().futexWake(u32, &self.epoch.raw, std.math.maxInt(u32));
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const observed = self.epoch.load(.acquire);
        mutex.unlock();
        defer mutex.lock();

        while (self.epoch.load(.acquire) == observed) {
            io().futexWaitUncancelable(u32, &self.epoch.raw, observed);
        }
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const observed = self.epoch.load(.acquire);
        mutex.unlock();
        defer mutex.lock();

        if (self.epoch.load(.acquire) != observed) return;
        io().futexWaitTimeout(
            u32,
            &self.epoch.raw,
            observed,
            .{ .duration = .{ .raw = .fromNanoseconds(timeout_ns), .clock = .awake } },
        ) catch |err| switch (err) {
            error.Canceled => unreachable,
        };
        if (self.epoch.load(.acquire) == observed) return error.Timeout;
    }
};
