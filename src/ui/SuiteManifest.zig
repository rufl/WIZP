const std = @import("std");
const runtime = @import("../runtime_016.zig");

const Project = struct {
    id: []const u8,
    role: []const u8,
    path: []const u8,
};

const projects = [_]Project{
    .{ .id = "ZNAP", .role = "orchestration", .path = "../../../tools/ZNAP" },
    .{ .id = "ZIPI", .role = "inference", .path = "../../../tools/ZIPI" },
    .{ .id = "ZINC", .role = "runtime", .path = "../../../tools/ZINC_BUILD" },
    .{ .id = "ZMITH", .role = "tooling", .path = "../../../tools/ZMITH" },
    .{ .id = "WIZP", .role = "workbench", .path = "." },
    .{ .id = "DOT", .role = "asset-design", .path = "../../EMBER/DOT" },
    .{ .id = "ARCGEN", .role = "generation", .path = "../../ARCGEN" },
    .{ .id = "NOCTTY", .role = "terminal", .path = "../../NOCTTY" },
    .{ .id = "NOCTED", .role = "editor", .path = "../../NOCTTY" },
    .{ .id = "OVERZEER", .role = "automation", .path = "../../../OVERZEER" },
};

fn available(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(runtime.io(), path, .{}) catch return false;
    return stat.kind == .directory;
}

pub fn writeResult(allocator: std.mem.Allocator, id_str: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"suite\":\"lichforge-workstation\",\"orchestration\":\"WIZP\",\"language\":\"zig\",\"integrationMode\":\"capability-manifest\",\"projects\":[", .{id_str});
    for (projects, 0..) |project, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"role\":\"{s}\",\"available\":{} }}", .{ project.id, project.role, available(project.path) });
    }
    try w.writeAll("],\"principles\":[\"zig-first\",\"hardware-aware\",\"portable-where-possible\",\"composable-workflows\"],\"status\":\"contract-verified\"}}");
    return out.toOwnedSlice();
}

const LaunchDescriptor = struct {
    id: []const u8,
    runner: []const u8,
};

const launch_descriptors = [_]LaunchDescriptor{
    .{ .id = "ZNAP", .runner = "zig-build" },
    .{ .id = "ZIPI", .runner = "zig-build" },
    .{ .id = "ZINC", .runner = "zig-build" },
    .{ .id = "ZMITH", .runner = "zig-build" },
    .{ .id = "WIZP", .runner = "zig-build" },
    .{ .id = "DOT", .runner = "project-native" },
    .{ .id = "ARCGEN", .runner = "project-native" },
    .{ .id = "NOCTTY", .runner = "zig-build" },
    .{ .id = "NOCTED", .runner = "zig-build" },
    .{ .id = "OVERZEER", .runner = "service-native" },
};

pub fn writeLaunchPlan(allocator: std.mem.Allocator, id_str: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"policy\":\"explicit-opt-in\",\"execution\":\"disabled-by-default\",\"descriptors\":[", .{id_str});
    for (launch_descriptors, 0..) |descriptor, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"runner\":\"{s}\",\"requiresConfirmation\":true}}", .{ descriptor.id, descriptor.runner });
    }
    try w.writeAll("],\"status\":\"plan-only\"}}");
    return out.toOwnedSlice();
}
fn projectById(id: []const u8) ?Project {
    for (projects) |project| {
        if (std.mem.eql(u8, project.id, id)) return project;
    }
    return null;
}

pub fn writeLaunchRequest(
    allocator: std.mem.Allocator,
    id_str: []const u8,
    project_id: []const u8,
    workspace_root: []const u8,
    execute_requested: bool,
) ![]u8 {
    const project = projectById(project_id) orelse return error.UnknownProject;
    const workspace_present = available(workspace_root);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"project\":\"{s}\",\"runner\":\"{s}\",\"workspacePresent\":{},\"projectPresent\":{},\"dryRun\":true,\"executeRequested\":{},\"executionBlocked\":true,\"requiresConfirmation\":true,\"confirmation\":\"WIZP_SUITE_CONFIRM\",\"status\":\"launch-not-started\"}}}}",
        .{ id_str, project.id, launchRunner(project.id), workspace_present, available(project.path), execute_requested },
    );
    return out.toOwnedSlice();
}

fn launchRunner(project_id: []const u8) []const u8 {
    for (launch_descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.id, project_id)) return descriptor.runner;
    }
    return "unknown";
}

pub fn writeHealth(allocator: std.mem.Allocator, id_str: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"probe\":\"filesystem-only\",\"sideEffects\":false,\"projects\":[", .{id_str});
    for (projects, 0..) |project, index| {
        if (index != 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"capability\":\"{s}\",\"ready\":{}}}", .{ project.id, project.role, available(project.path) });
    }
    try w.writeAll("],\"status\":\"probe-complete\"}}");
    return out.toOwnedSlice();
}

test "suite manifest reports the current WIZP workbench" {
    const response = try writeResult(std.testing.allocator, "1");
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"WIZP\"") != null);
}
