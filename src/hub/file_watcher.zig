const std = @import("std");
const posix = std.os.linux;
const bun = @import("root").bun;
const JSC = bun.JSC;

const Watch = struct {
    wd: i32,
    path: []const u8,
    callback: JSC.JSValue,
    recursive: bool,
};

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    watches: std.AutoArrayHashMapUnmanaged(i32, Watch) = .{},
    poller: ?*std.Thread = null,
    running: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(true),

    pub fn init(allocator: std.mem.Allocator) !*FileWatcher {
        const fd = posix.inotify_init1(posix.IN_NONBLOCK);
        if (fd < 0) return error.InotifyInitFailed;

        const self = try allocator.create(FileWatcher);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
        };

        self.poller = try std.Thread.spawn(.{}, pollEvents, .{self});
        return self;
    }

    pub fn deinit(self: *FileWatcher) void {
        self.running.store(false, .monotonic);
        if (self.poller) |t| t.join();

        var it = self.watches.iterator();
        while (it.next()) |entry| {
            _ = posix.inotify_rm_watch(self.fd, entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }
        self.watches.deinit();
        _ = posix.close(self.fd);
        self.allocator.destroy(self);
    }

    pub fn addWatch(self: *FileWatcher, path: []const u8, recursive: bool, callback: JSC.JSValue) !i32 {
        const wd = posix.inotify_add_watch(
            self.fd,
            path,
            posix.IN_MODIFY | posix.IN_CREATE | posix.IN_DELETE | posix.IN_MOVED_FROM | posix.IN_MOVED_TO,
        );
        if (wd < 0) return error.AddWatchFailed;

        const dup_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(dup_path);

        try self.watches.put(self.allocator, wd, .{
            .wd = wd,
            .path = dup_path,
            .callback = callback,
            .recursive = recursive,
        });

        return wd;
    }

    fn pollEvents(self: *FileWatcher) void {
        var event_buf: [4096]u8 align(std.mem.align_of(posix.inotify_event)) = undefined;

        while (self.running.load(.monotonic)) {
            const len = posix.read(self.fd, &event_buf, event_buf.len);
            if (len < 0) continue;

            var offset: usize = 0;
            while (offset < len) {
                const event = (*const posix.inotify_event)(&event_buf[offset]);
                offset += @sizeOf(posix.inotify_event) + event.len;

                if (self.watches.getPtr(event.wd)) |watch| {
                    const global = JSC.Javascript.bunGlobal();
                    const event_name: [:0]const u8 = switch (event.mask) {
                        posix.IN_MODIFY => "modify",
                        posix.IN_CREATE => "create",
                        posix.IN_DELETE => "delete",
                        posix.IN_MOVED_FROM => "move_from",
                        posix.IN_MOVED_TO => "move_to",
                        else => continue,
                    };

                    const js_event = JSC.JSValue.createObject(global);
                    _ = js_event.put("type", JSC.JSValue.createString(global, event_name));
                    _ = js_event.put("path", JSC.JSValue.createString(global, watch.path));
                    const args = [_]JSC.JSValue{js_event};
                    _ = watch.callback.call(global, &args, .{});
                }
            }
        }
    }
};
