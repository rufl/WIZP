// WIZP Zig 0.16 compatibility helpers for modules that need explicit I/O.

const std = @import("std");
const runtime = @import("runtime_016.zig");

pub const Allocator = std.mem.Allocator;

pub fn ManagedArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

pub const Gpa = struct {
    inner: std.heap.DebugAllocator(.{}) = .init,

    pub fn allocator(self: *Gpa) Allocator {
        return self.inner.allocator();
    }

    pub fn deinit(self: *Gpa) std.heap.Check {
        return self.inner.deinit();
    }
};

pub fn gpa() Gpa {
    return .{};
}

pub const cwd = struct {
    pub fn openFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().openFile(runtime.io(), path, options);
    }

    pub fn createFile(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().createFile(runtime.io(), path, options);
    }

    pub fn openDir(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(runtime.io(), path, options);
    }

    pub fn readFileAlloc(allocator: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
        return runtime.readFileAlloc(allocator, path, max_bytes);
    }

    pub fn makePath(path: []const u8) !void {
        return runtime.createDirPath(path);
    }

    pub fn deleteTree(path: []const u8) !void {
        return std.Io.Dir.cwd().deleteTree(runtime.io(), path);
    }
};

pub fn stdinFile() std.Io.File {
    return .stdin();
}

pub fn stdoutFile() std.Io.File {
    return .stdout();
}

pub fn stderrFile() std.Io.File {
    return .stderr();
}

pub fn argsAlloc(allocator: Allocator, process_args: std.process.Args) ![][]u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer iterator.deinit();
    var args = ManagedArrayList([]u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }
    while (iterator.next()) |arg| {
        try args.append(try allocator.dupe(u8, arg));
    }
    return args.toOwnedSlice();
}

pub fn argsFree(allocator: Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

pub fn openFileAbsolute(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(runtime.io(), path, options);
}

pub fn fileExists(path: []const u8) bool {
    const file = openFileAbsolute(path, .{}) catch return false;
    file.close(runtime.io());
    return true;
}
