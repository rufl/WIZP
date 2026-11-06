// Shared Content-Length framing helpers for LSP and DAP stdio transports.

const std = @import("std");
const builtin = @import("builtin");

pub const max_content_length: usize = 64 * 1024 * 1024;
pub const max_header_length: usize = 8 * 1024;
pub const default_read_timeout_ms: i32 = 30_000;

pub const RpcError = struct {
    code: i64,
    message: []u8,
};

pub fn waitReadable(handle: anytype, timeout_ms: i32) !void {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var timeout_100ns: windows.LARGE_INTEGER = -@as(windows.LARGE_INTEGER, timeout_ms) * 10_000;
        switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &timeout_100ns)) {
            windows.NTSTATUS.WAIT_0 => {},
            .TIMEOUT => return error.Timeout,
            else => return error.Unexpected,
        }
    } else {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const result = try std.posix.poll(&poll_fds, timeout_ms);
        if (result == 0) return error.Timeout;
    }
}

pub fn formatHeader(buffer: []u8, content_length: usize) ![]const u8 {
    return std.fmt.bufPrint(buffer, "Content-Length: {}\r\n\r\n", .{content_length});
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    const hex = "0123456789abcdef";
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0b...0x0c, 0x0e...0x1f => {
                try writer.writeAll("\\u00");
                try writer.writeByte(hex[byte >> 4]);
                try writer.writeByte(hex[byte & 0xf]);
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn writeRequest(writer: anytype, id: u64, method: []const u8, params: []const u8) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":", .{id});
    try writeJsonString(writer, method);
    try writer.print(",\"params\":{s}}}", .{params});
}

pub fn writeNotification(writer: anytype, method: []const u8, params: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeJsonString(writer, method);
    try writer.print(",\"params\":{s}}}", .{params});
}

pub fn resultResponse(allocator: std.mem.Allocator, id: []const u8, raw_result: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, raw_result });
}

pub fn parseRpcError(allocator: std.mem.Allocator, payload: []const u8) !?RpcError {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    const error_value = root.get("error") orelse return null;
    const error_object = switch (error_value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    const code = switch (error_object.get("code") orelse return error.InvalidJson) {
        .integer => |value| value,
        else => return error.InvalidJson,
    };
    const message = switch (error_object.get("message") orelse return error.InvalidJson) {
        .string => |value| try allocator.dupe(u8, value),
        else => return error.InvalidJson,
    };
    return RpcError{ .code = code, .message = message };
}

pub fn parseHeader(headers: []const u8) (error{ BadHeader, ContentLengthTooLarge, HeaderTooLarge })!usize {
    if (headers.len > max_header_length) return error.HeaderTooLarge;
    var content_length: ?usize = null;
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (!std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) continue;
        const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
        content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadHeader;
    }
    const length = content_length orelse return error.BadHeader;
    if (length > max_content_length) return error.ContentLengthTooLarge;
    return length;
}

test "Content-Length framing formats and parses" {
    var buffer: [64]u8 = undefined;
    const header = try formatHeader(&buffer, 42);
    try std.testing.expectEqual(@as(usize, 42), try parseHeader(header));
}

test "Content-Length framing rejects malformed headers" {
    try std.testing.expectError(error.BadHeader, parseHeader("Content-Type: application/json\r\n\r\n"));
    try std.testing.expectError(error.BadHeader, parseHeader("Content-Length: nope\r\n\r\n"));
}

test "Content-Length framing rejects oversized bodies" {
    var buffer: [128]u8 = undefined;
    const header = try formatHeader(&buffer, max_content_length + 1);
    try std.testing.expectError(error.ContentLengthTooLarge, parseHeader(header));
}

test "Content-Length framing rejects oversized headers" {
    const headers = @as([max_header_length + 1]u8, @splat(0));
    try std.testing.expectError(error.HeaderTooLarge, parseHeader(&headers));
}

test "JSON string framing escapes control characters" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeJsonString(&output.writer, "quote\" slash\\ line\n");
    try std.testing.expectEqualStrings("\"quote\\\" slash\\\\ line\\n\"", output.written());
}

test "JSON string framing escapes every C0 control byte and preserves UTF-8" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const input = [_]u8{ 0, 1, 8, 9, 10, 11, 12, 13, 14, 31, ' ', 0xc3, 0xa9 };
    try writeJsonString(&output.writer, &input);
    try std.testing.expectEqualStrings(
        "\"\\u0000\\u0001\\u0008\\t\\n\\u000b\\u000c\\r\\u000e\\u001f é\"",
        output.written(),
    );
}

test "JSON-RPC framing writes escaped request envelopes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeRequest(&output.writer, 7, "method\"name", "{}");
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"method\\\"name\",\"params\":{}}",
        output.written(),
    );
}

test "JSON-RPC result builder preserves raw result payloads" {
    const response = try resultResponse(std.testing.allocator, "7", "{\"ok\":true}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}", response);
}

test "Content-Length framing read timeout is bounded" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "sh", "-c", "sleep 1" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(std.testing.io);
    try std.testing.expectError(error.Timeout, waitReadable(child.stdout.?.handle, 0));
}

test "JSON-RPC error parser owns the message" {
    const parsed = (try parseRpcError(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad \\\"param\"}}")) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(parsed.message);
    try std.testing.expectEqual(@as(i64, -32602), parsed.code);
    try std.testing.expectEqualStrings("bad \"param", parsed.message);
}

test "JSON-RPC error parser distinguishes absent and malformed errors" {
    try std.testing.expect((try parseRpcError(std.testing.allocator, "{\"result\":true}")) == null);
    try std.testing.expectError(error.InvalidJson, parseRpcError(std.testing.allocator, "{\"error\":{\"code\":\"bad\"}}"));
}
