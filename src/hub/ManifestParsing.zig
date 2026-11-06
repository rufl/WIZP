// Pure manifest field parsing shared by the extension host.
const std = @import("std");

pub fn stringArray(allocator: std.mem.Allocator, object: anytype, key: []const u8) !std.array_list.Managed([]const u8) {
    var items = std.array_list.Managed([]const u8).init(allocator);
    const value = object.get(key) orelse return items;
    switch (value) {
        .array => |array| {
            for (array.items) |item| {
                switch (item) {
                    .string => |s| if (s.len > 0) try items.append(try allocator.dupe(u8, s)),
                    else => return error.InvalidExtensionManifest,
                }
            }
        },
        else => return error.InvalidExtensionManifest,
    }
    return items;
}

pub fn ownedStringArray(allocator: std.mem.Allocator, object: anytype, key: []const u8) ![]const []const u8 {
    var items = try stringArray(allocator, object, key);
    if (items.items.len == 0) {
        items.deinit();
        return &.{};
    }
    return try items.toOwnedSlice();
}

pub fn ownedStringArrayLenient(allocator: std.mem.Allocator, object: anytype, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return &.{},
    };
    var items = std.array_list.Managed([]const u8).init(allocator);
    for (array.items) |item| {
        switch (item) {
            .string => |text| try items.append(try allocator.dupe(u8, text)),
            else => {},
        }
    }
    return try items.toOwnedSlice();
}

pub fn contributionArray(root: anytype, key: []const u8) ?std.json.Array {
    const contributes = switch (root.get("contributes") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return switch (contributes.get(key) orelse return null) {
        .array => |array| array,
        else => null,
    };
}

pub fn contributionObject(root: anytype, key: []const u8) ?std.json.ObjectMap {
    const contributes = switch (root.get("contributes") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return switch (contributes.get(key) orelse return null) {
        .object => |object| object,
        else => null,
    };
}

test "manifest contribution lookups preserve array and object kinds" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"contributes\":{\"commands\":[{\"command\":\"x\"}],\"menus\":{\"editor\":[]}}}", .{});
    defer parsed.deinit();
    try std.testing.expect(contributionArray(parsed.value.object, "commands") != null);
    try std.testing.expect(contributionObject(parsed.value.object, "menus") != null);
    try std.testing.expect(contributionObject(parsed.value.object, "commands") == null);
}

test "manifest lenient string arrays ignore non-string values" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"items\":[\"one\",true,\"two\"]}", .{});
    defer parsed.deinit();
    const items = try ownedStringArrayLenient(std.testing.allocator, parsed.value.object, "items");
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one", items[0]);
    try std.testing.expectEqualStrings("two", items[1]);
}
