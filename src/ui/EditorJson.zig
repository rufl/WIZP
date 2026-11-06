// Stateless JSON field readers for editor RPC/configuration dispatch.
const std = @import("std");

pub fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const field_value = object.get(key) orelse return null;
    return switch (field_value) {
        .string => |s| s,
        else => null,
    };
}

pub fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    const field_value = object.get(key) orelse return false;
    return switch (field_value) {
        .bool => |b| b,
        else => false,
    };
}

pub fn matchingDelimiter(json: []const u8, start: usize, open: u8, close: u8) ?usize {
    if (start >= json.len or json[start] != open) return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_string) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true else if (c == open) depth += 1 else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn fieldValueStart(body: []const u8, key: []const u8) ?usize {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, body, search_start, needle)) |field_start| {
        var cursor = field_start + needle.len;
        while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) : (cursor += 1) {}
        if (cursor < body.len and body[cursor] == ':') {
            cursor += 1;
            while (cursor < body.len and std.ascii.isWhitespace(body[cursor])) : (cursor += 1) {}
            return if (cursor < body.len) cursor else null;
        }
        search_start = field_start + needle.len;
    }
    return null;
}

pub fn value(body: []const u8, key: []const u8) ?[]const u8 {
    const start = fieldValueStart(body, key) orelse return null;
    const raw = body[start..];
    if (raw.len == 0) return null;
    if (raw[0] == '{') {
        const end = matchingDelimiter(raw, 0, '{', '}') orelse return null;
        return raw[0 .. end + 1];
    }
    if (raw[0] == '[') {
        const end = matchingDelimiter(raw, 0, '[', ']') orelse return null;
        return raw[0 .. end + 1];
    }
    if (raw[0] == '"') {
        var escaped = false;
        var end: usize = 1;
        while (end < raw.len) : (end += 1) {
            if (escaped) {
                escaped = false;
            } else if (raw[end] == '\\') {
                escaped = true;
            } else if (raw[end] == '"') {
                return raw[0 .. end + 1];
            }
        }
        return null;
    }
    var end: usize = 0;
    while (end < raw.len and raw[end] != ',' and raw[end] != '}') : (end += 1) {}
    return std.mem.trim(u8, raw[0..end], " \t\r\n");
}

pub fn numberParam(body: []const u8, key: []const u8) ?usize {
    const i = fieldValueStart(body, key) orelse return null;
    var j = i;
    while (j < body.len and body[j] >= '0' and body[j] <= '9') : (j += 1) {}
    if (j == i) return null;
    return std.fmt.parseInt(usize, body[i..j], 10) catch null;
}

pub fn boolParam(body: []const u8, key: []const u8) ?bool {
    const i = fieldValueStart(body, key) orelse return null;
    if (std.mem.startsWith(u8, body[i..], "true")) return true;
    if (std.mem.startsWith(u8, body[i..], "false")) return false;
    return null;
}

pub fn escapedStringParam(body: []const u8, key: []const u8) ?[]const u8 {
    const start = fieldValueStart(body, key) orelse return null;
    if (body[start] != '"') return null;
    const val_start = start + 1;
    var i = val_start;
    while (i < body.len) : (i += 1) {
        if (body[i] != '"') continue;
        var escapes: usize = 0;
        var j = i;
        while (j > val_start and body[j - 1] == '\\') : (j -= 1) escapes += 1;
        if (escapes % 2 == 0) return body[val_start..i];
    }
    return null;
}

pub fn unescapeString(allocator: std.mem.Allocator, escaped: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    var i: usize = 0;
    while (i < escaped.len) {
        if (escaped[i] == '\\' and i + 1 < escaped.len) {
            switch (escaped[i + 1]) {
                'n' => {
                    try out.append('\n');
                    i += 2;
                },
                'r' => {
                    try out.append('\r');
                    i += 2;
                },
                't' => {
                    try out.append('\t');
                    i += 2;
                },
                '"' => {
                    try out.append('"');
                    i += 2;
                },
                '\\' => {
                    try out.append('\\');
                    i += 2;
                },
                '/' => {
                    try out.append('/');
                    i += 2;
                },
                'u' => {
                    if (i + 5 < escaped.len) {
                        const code_unit = std.fmt.parseInt(u16, escaped[i + 2 .. i + 6], 16) catch 0;
                        if (code_unit >= 0xD800 and code_unit <= 0xDBFF and i + 11 < escaped.len and escaped[i + 6] == '\\' and escaped[i + 7] == 'u') {
                            const low = std.fmt.parseInt(u16, escaped[i + 8 .. i + 12], 16) catch 0;
                            if (low >= 0xDC00 and low <= 0xDFFF) {
                                const codepoint: u21 = 0x10000 + (@as(u21, code_unit) - 0xD800) * 0x400 + (@as(u21, low) - 0xDC00);
                                var buf: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                                try out.appendSlice(buf[0..len]);
                                i += 12;
                                continue;
                            }
                        }
                        if (code_unit >= 0xD800 and code_unit <= 0xDFFF) {
                            try out.appendSlice("\xEF\xBF\xBD");
                        } else if (code_unit <= 0x7f) {
                            try out.append(@intCast(code_unit));
                        } else {
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(@intCast(code_unit), &buf) catch 0;
                            try out.appendSlice(buf[0..len]);
                        }
                        i += 6;
                    } else {
                        try out.append('\\');
                        i += 1;
                    }
                },
                else => {
                    try out.append(escaped[i]);
                    i += 1;
                },
            }
        } else {
            try out.append(escaped[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice();
}

test "editor JSON field readers reject wrong types" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"name\":\"task\",\"enabled\":true,\"count\":1}", .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("task", stringField(object, "name").?);
    try std.testing.expect(boolField(object, "enabled"));
    try std.testing.expect(stringField(object, "count") == null);
    try std.testing.expect(!boolField(object, "missing"));
}

test "editor JSON value reader respects nested strings and delimiters" {
    try std.testing.expectEqualStrings("{\"text\":\"}\"}", value("{\"payload\":{\"text\":\"}\"},\"ok\":true}", "payload").?);
    try std.testing.expectEqualStrings("[1,2]", value("{\"items\":[1,2],\"ok\":true}", "items").?);
}

test "editor JSON readers accept whitespace around field separators" {
    try std.testing.expectEqualStrings("\"rpc-7\"", value("{ \"id\" : \"rpc-7\", \"method\" : \"workspace/getFolders\" }", "id").?);
    try std.testing.expectEqualStrings("workspace/getFolders", escapedStringParam("{ \"id\" : 7, \"method\" : \"workspace/getFolders\" }", "method").?);
    try std.testing.expectEqual(@as(?usize, 42), numberParam("{\"line\" \t:\n 42}", "line"));
    try std.testing.expectEqual(@as(?bool, true), boolParam("{\"enabled\" : true}", "enabled"));
}

test "editor JSON parameter readers parse expected scalar types" {
    try std.testing.expectEqual(@as(?usize, 42), numberParam("{\"line\": 42}", "line"));
    try std.testing.expectEqual(@as(?bool, true), boolParam("{\"enabled\": true}", "enabled"));
    try std.testing.expect(numberParam("{\"line\":true}", "line") == null);
}

test "editor JSON escaped strings round trip" {
    const raw = escapedStringParam("{\"text\":\"line\\nquote\\\"\"}", "text").?;
    const decoded = try unescapeString(std.testing.allocator, raw);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("line\nquote\"", decoded);
}

test "editor JSON escaped strings preserve backslash-before-quote and unicode" {
    const raw = escapedStringParam("{\"text\":\"path\\\\\\\"tail\\u00e9\"}", "text").?;
    const decoded = try unescapeString(std.testing.allocator, raw);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("path\\\"tailé", decoded);
}

test "editor JSON escaped surrogate pairs decode as UTF-8" {
    const raw = escapedStringParam("{\"text\":\"emoji\\ud83d\\ude00\"}", "text").?;
    const decoded = try unescapeString(std.testing.allocator, raw);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("emoji😀", decoded);
}
