// Minimal JSON value helpers for extension-host request payloads.
// Full manifest parsing belongs in ManifestParsing; JSON-RPC framing belongs
// in ExtensionRpc. These helpers cover only bounded request fragments.
const std = @import("std");

pub fn value(json: []const u8, key: []const u8) ?[]const u8 {
    const key_start = std.mem.indexOf(u8, json, key) orelse return null;
    const after_key = json[key_start + key.len ..];
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const after_colon = std.mem.trimStart(u8, after_key[colon + 1 ..], " \t\n\r");
    if (after_colon.len == 0) return null;

    if (after_colon[0] == '[') {
        const end = matchingDelimiter(after_colon, 0, '[', ']') orelse return null;
        return after_colon[0 .. end + 1];
    }
    if (after_colon[0] == '{') {
        const end = matchingDelimiter(after_colon, 0, '{', '}') orelse return null;
        return after_colon[0 .. end + 1];
    }
    if (after_colon[0] == '"') {
        const parsed = firstString(after_colon) orelse return null;
        return after_colon[0 .. parsed.len + 2];
    }

    var end: usize = 0;
    while (end < after_colon.len and after_colon[end] != ',' and after_colon[end] != '}') : (end += 1) {}
    return std.mem.trim(u8, after_colon[0..end], " \t\r\n");
}

pub fn firstArrayString(json: []const u8, key: []const u8) ?[]const u8 {
    const raw = value(json, key) orelse return null;
    if (raw.len == 0 or raw[0] != '[') return null;
    return firstString(raw);
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

pub fn firstString(json: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, json, '"') orelse return null;
    var i = start + 1;
    while (i < json.len) : (i += 1) {
        if (json[i] != '"') continue;
        var escape_count: usize = 0;
        var j = i;
        while (j > start + 1) {
            j -= 1;
            if (json[j] == '\\') escape_count += 1 else break;
        }
        if (escape_count % 2 == 0) return json[start + 1 .. i];
    }
    return null;
}

pub fn unescape(allocator: std.mem.Allocator, escaped: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < escaped.len) {
        if (escaped[i] == '\\' and i + 1 < escaped.len) {
            switch (escaped[i + 1]) {
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                '/' => try out.append('/'),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                else => try out.append(escaped[i + 1]),
            }
            i += 2;
        } else {
            try out.append(escaped[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice();
}

test "extension JSON helpers match bounded request fragments" {
    try std.testing.expectEqualStrings("[\"one\",\"two\"]", value("{\"args\":[\"one\",\"two\"]}", "\"args\"").?);
    try std.testing.expectEqualStrings("one", firstArrayString("{\"args\":[\"one\"]}", "\"args\"").?);
    try std.testing.expect(matchingDelimiter("{\"x\": [1, {\"y\": 2}]}", 0, '{', '}') != null);
}

test "extension JSON unescape handles request arguments" {
    const result = try unescape(std.testing.allocator, "a\\nquote\\\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\nquote\"", result);
}
