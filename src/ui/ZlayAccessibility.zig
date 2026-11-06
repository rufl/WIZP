const std = @import("std");

const zlay = @import("zlay");

const Metadata = zlay.accessibility.WidgetMetadata;
const Registry = zlay.accessibility.Registry;
const Role = zlay.accessibility.Role;

const Surface = struct {
    role: Role,
    label: []const u8,
};

const surfaces = [_]Surface{
    .{ .role = .tree, .label = "Explorer" },
    .{ .role = .search, .label = "Search" },
    .{ .role = .list, .label = "Source Control" },
    .{ .role = .generic, .label = "Debug" },
    .{ .role = .list, .label = "Extensions" },
    .{ .role = .dialog, .label = "Settings" },
    .{ .role = .generic, .label = "Terminal" },
    .{ .role = .generic, .label = "Editor" },
};

/// Build the renderer-neutral metadata registry used by native UI adapters.
/// The registry borrows labels from the static surface table and owns no memory.
pub fn nativeSurfaceCount() !usize {
    var storage: [surfaces.len]Metadata = undefined;
    var registry = Registry.init(&storage);
    for (surfaces, 1..) |surface, index| {
        try registry.register(.{
            .id = .{ .id = @intCast(index) },
            .role = surface.role,
            .label = .fromSlice(surface.label),
        });
    }
    return registry.len();
}

test "native accessibility surfaces register with ZLAY" {
    try std.testing.expectEqual(surfaces.len, try nativeSurfaceCount());
}
