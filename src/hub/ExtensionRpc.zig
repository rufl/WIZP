// JSON-RPC response construction for the extension host transport.
const std = @import("std");
const EditorJson = @import("../ui/EditorJson.zig");
const ContentLength = @import("../protocol/ContentLength.zig");

pub fn errorResponse(allocator: std.mem.Allocator, id_str: []const u8, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":", .{ id_str, code });
    try ContentLength.writeJsonString(writer, message);
    try writer.writeAll("}}");
    return try out.toOwnedSlice();
}

/// Return the raw JSON representation of a JSON-RPC id.
/// The caller owns the request body, so the returned slice is borrowed.
pub fn id(json: []const u8) ?[]const u8 {
    return EditorJson.value(json, "id");
}

/// Extract a borrowed JSON string value from a bounded request.
pub fn stringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const field_key = if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"')
        key[1 .. key.len - 1]
    else
        key;
    return EditorJson.escapedStringParam(json, field_key);
}

test "extension RPC error responses escape messages" {
    const response = try errorResponse(std.testing.allocator, "3", -32602, "bad \"request\"");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32602,\"message\":\"bad \\\"request\\\"\"}}", response);
}

test "extension RPC id parsing preserves string and numeric ids" {
    try std.testing.expectEqualStrings("\"abc\"", id("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"x\"}").?);
    try std.testing.expectEqualStrings("42", id("{\"id\": 42, \"method\":\"x\"}").?);
    try std.testing.expectEqualStrings("42", id("{ \"id\" : 42, \"method\" : \"x\" }").?);
    try std.testing.expect(id("{\"method\":\"notification\"}") == null);
}

test "extension RPC string values trim whitespace and reject non-strings" {
    try std.testing.expectEqualStrings("alpha", stringValue("{\"name\": \"alpha\"}", "\"name\"").?);
    try std.testing.expect(stringValue("{\"name\": 42}", "\"name\"") == null);
    try std.testing.expect(stringValue("{\"name\":\"unterminated}", "\"name\"") == null);
    try std.testing.expectEqualStrings("alpha", stringValue("{ \"name\" : \"alpha\" }", "\"name\"").?);
    try std.testing.expectEqualStrings("path\\\"tail", stringValue("{ \"name\" : \"path\\\\\\\"tail\" }", "\"name\"").?);
}
