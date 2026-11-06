// Small JSON-RPC response builders kept outside the editor state machine.
const std = @import("std");
const ContentLength = @import("../protocol/ContentLength.zig");

pub fn errorResponse(allocator: std.mem.Allocator, id_str: []const u8, code: i32, message: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":", .{ id_str, code });
    try ContentLength.writeJsonString(w, message);
    try w.writeAll("}}");
    return try out.toOwnedSlice();
}

pub fn resultRaw(allocator: std.mem.Allocator, id_str: []const u8, raw_json: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, raw_json });
}

test "editor rpc builders escape errors and preserve raw results" {
    const error_response = try errorResponse(std.testing.allocator, "7", -1, "bad \"input\"");
    defer std.testing.allocator.free(error_response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-1,\"message\":\"bad \\\"input\\\"\"}}", error_response);
    const result_response = try resultRaw(std.testing.allocator, "7", "{\"ok\":true}");
    defer std.testing.allocator.free(result_response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}", result_response);
}
