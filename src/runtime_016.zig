const std = @import("std");
const sync = @import("sync.zig");

pub fn initialize(environ: std.process.Environ) void {
    sync.initialize(environ);
}

pub fn io() std.Io {
    return sync.io();
}

pub fn createDirPath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), path);
}

pub fn deleteFile(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.deleteFileAbsolute(io(), path);
    } else {
        try std.Io.Dir.cwd().deleteFile(io(), path);
    }
}

pub fn monotonicNanoseconds() i96 {
    return std.Io.Clock.awake.now(io()).nanoseconds;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(limit));
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io(), path, .{});
    defer file.close(io());
    try writeAll(file, bytes);
}

pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io(), &buffer);
    writer.interface.writeAll(bytes) catch return writer.err.?;
    writer.flush() catch return writer.err.?;
}

pub fn read(file: std.Io.File, buffer: []u8) !usize {
    return file.readStreaming(io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |other| return other,
    };
}

pub fn sleepNanoseconds(nanoseconds: u64) void {
    std.Io.sleep(io(), .fromNanoseconds(nanoseconds), .awake) catch {};
}

pub fn nanoTimestamp() i128 {
    return std.Io.Timestamp.now(io(), .real).nanoseconds;
}

pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

pub fn timestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_s));
}

pub fn hasEnvVar(name: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const name_z = dupeZ(allocator, name) catch return false;
    defer allocator.free(name_z);
    return std.c.getenv(name_z.ptr) != null;
}

pub fn environmentMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    if (sync.processEnviron()) |environ| {
        return std.process.Environ.createMap(environ, allocator);
    }
    if (comptime @import("builtin").os.tag == .windows) {
        return std.process.Environ.createMap(.{ .block = .global }, allocator);
    }
    const entries: [:null]const ?[*:0]const u8 = std.mem.span(std.c.environ);
    return std.process.Environ.createMap(.{ .block = .{ .slice = entries } }, allocator);
}

pub fn posixEnvironment() [*:null]const ?[*:0]const u8 {
    comptime if (@import("builtin").os.tag == .windows) {
        @compileError("POSIX environment requested on Windows");
    };
    if (sync.processEnviron()) |environ| {
        return environ.block.slice.ptr;
    }
    return @ptrCast(std.c.environ);
}

pub fn dupeZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, value.len, 0);
    @memcpy(result, value);
    return result;
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const name_z = try dupeZ(allocator, name);
    defer allocator.free(name_z);
    const value = std.c.getenv(name_z.ptr) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, std.mem.sliceTo(value, 0));
}
