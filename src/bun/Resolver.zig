const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const runtime = @import("../runtime_016.zig");

pub fn resolve(allocator: Allocator, configured_path: []const u8) !?[]u8 {
    const executable_name = if (builtin.os.tag == .windows and std.mem.eql(u8, configured_path, "bun"))
        "bun.exe"
    else
        configured_path;
    if (try resolveConfiguredPath(allocator, executable_name)) |path| return path;
    if (try resolveAdjacentToExe(allocator, executable_name)) |path| return path;
    if (try resolvePathSearch(allocator, executable_name)) |path| return path;
    const fallback_name = if (builtin.os.tag == .windows) "bun.exe" else "bun";
    if (!std.mem.eql(u8, executable_name, fallback_name)) {
        if (try resolvePathSearch(allocator, fallback_name)) |path| return path;
    }
    return null;
}

fn resolveConfiguredPath(allocator: Allocator, configured_path: []const u8) !?[]u8 {
    if (configured_path.len == 0) return null;
    if (std.fs.path.isAbsolute(configured_path)) {
        return if (fileIsRegularAbsolute(configured_path))
            try allocator.dupe(u8, configured_path)
        else
            null;
    }

    if (fileIsRegularRelative(configured_path)) {
        const real = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), configured_path, allocator);
        return real;
    }

    return null;
}

fn resolveAdjacentToExe(allocator: Allocator, executable_name: []const u8) !?[]u8 {
    const exe_path = std.process.executablePathAlloc(runtime.io(), allocator) catch return null;
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    var dir = try allocator.dupe(u8, exe_dir);
    defer allocator.free(dir);

    var depth: usize = 0;
    while (true) : (depth += 1) {
        const sibling = try std.fs.path.join(allocator, &.{ dir, executable_name });
        defer allocator.free(sibling);
        if (fileIsRegularAbsolute(sibling)) return try allocator.dupe(u8, sibling);

        const in_bin = try std.fs.path.join(allocator, &.{ dir, "bin", executable_name });
        defer allocator.free(in_bin);
        if (fileIsRegularAbsolute(in_bin)) return try allocator.dupe(u8, in_bin);

        if (depth >= 4) break;
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == dir.len and std.mem.eql(u8, parent, dir)) break;

        const next_dir = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = next_dir;
    }

    return null;
}

fn resolvePathSearch(allocator: Allocator, executable_name: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, executable_name, '/')) |_| return null;

    const path_env = runtime.getEnvVarOwned(allocator, "PATH") catch return null;
    defer allocator.free(path_env);
    const path_separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var parts = std.mem.splitScalar(u8, path_env, path_separator);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ part, executable_name });
        defer allocator.free(candidate);
        if (fileIsRegularAbsolute(candidate)) return try allocator.dupe(u8, candidate);
    }
    return null;
}

fn fileIsRegularAbsolute(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(runtime.io(), path, .{}) catch return false;
    defer file.close(runtime.io());
    const stat = file.stat(runtime.io()) catch return false;
    return stat.kind == .file;
}

fn fileIsRegularRelative(path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(runtime.io(), path, .{}) catch return false;
    defer file.close(runtime.io());
    const stat = file.stat(runtime.io()) catch return false;
    return stat.kind == .file;
}

test "Bun resolver rejects a directory that has the executable name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "bun", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const directory_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bun" });
    defer std.testing.allocator.free(directory_path);

    try std.testing.expect(!fileIsRegularAbsolute(directory_path));

    var executable = try tmp.dir.createFile(std.testing.io, "bun-runtime", .{});
    executable.close(std.testing.io);
    const executable_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bun-runtime" });
    defer std.testing.allocator.free(executable_path);
    try std.testing.expect(fileIsRegularAbsolute(executable_path));
}
