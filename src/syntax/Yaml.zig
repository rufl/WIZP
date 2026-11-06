// WIZP YAML Parser — Minimal YAML subset for .sublime-syntax files
// Handles: key-value pairs, nested maps, lists, quoted strings, comments.
// Does NOT handle: anchors, aliases, tags, multi-doc (---), flow style { }.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const YamlValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string: []const u8,
    list: std.array_list.Managed(YamlValue),
    map: std.StringHashMapUnmanaged(YamlValue),

    pub fn deinit(self: *YamlValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .list => |*l| {
                for (l.items) |*item| item.deinit();
                l.deinit();
            },
            .map => |*m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var val = entry.value_ptr.*;
                    val.deinit();
                }
                m.deinit();
            },
            else => {},
        }
    }

    pub fn format(self: YamlValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .null_val => try writer.writeAll("null"),
            .bool_val => |b| try writer.print("{}", .{b}),
            .int_val => |i| try writer.print("{}", .{i}),
            .float_val => |f| try writer.print("{}", .{f}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .list => |l| {
                try writer.writeAll("[");
                for (l.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format("", .{}, writer);
                }
                try writer.writeAll("]");
            },
            .map => |m| {
                try writer.writeAll("{");
                var it = m.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                    try entry.value_ptr.*.format("", .{}, writer);
                }
                try writer.writeAll("}");
            },
        }
    }

    pub fn asString(self: YamlValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asBool(self: YamlValue) ?bool {
        return switch (self) {
            .bool_val => |b| b,
            else => null,
        };
    }

    pub fn asMap(self: *YamlValue) ?*std.StringHashMapUnmanaged(YamlValue) {
        return switch (self.*) {
            .map => |*m| m,
            else => null,
        };
    }

    pub fn asList(self: *YamlValue) ?*std.array_list.Managed(YamlValue) {
        return switch (self.*) {
            .list => |*l| l,
            else => null,
        };
    }

    pub fn get(self: *YamlValue, allocator: Allocator, key: []const u8) ?*YamlValue {
        if (self.asMap()) |m| {
            return m.getPtr(key);
        }
        _ = allocator;
        return null;
    }
};

pub const ParseError = error{
    UnexpectedEof,
    InvalidIndent,
    InvalidYaml,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, input: []const u8) Self {
        return .{
            .allocator = allocator,
            .input = input,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn peek(self: *Self) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Self) ?u8 {
        const ch = self.peek() orelse return null;
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return ch;
    }

    fn skipWhitespace(self: *Self) void {
        while (self.peek()) |ch| {
            if (ch == ' ' or ch == '\t') {
                _ = self.advance();
            } else if (ch == '#') {
                // Skip comment to end of line
                while (self.peek()) |c| {
                    if (c == '\n') break;
                    _ = self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn skipNewlines(self: *Self) void {
        while (self.peek()) |ch| {
            if (ch == '\n' or ch == '\r') {
                _ = self.advance();
            } else {
                break;
            }
        }
    }

    fn parseString(self: *Self) ![]const u8 {
        const start = self.pos;
        const quote = self.peek() orelse return error.UnexpectedEof;

        if (quote == '"' or quote == '\'') {
            _ = self.advance(); // opening quote
            while (self.peek()) |ch| {
                if (ch == '\\') {
                    _ = self.advance();
                    _ = self.advance();
                    continue;
                }
                if (ch == quote) {
                    _ = self.advance(); // closing quote
                    return self.input[start + 1 .. self.pos - 1];
                }
                if (ch == '\n') return error.InvalidYaml;
                _ = self.advance();
            }
            return error.UnexpectedEof;
        }

        // Unquoted string: read until special character
        while (self.peek()) |ch| {
            switch (ch) {
                ':', '#', '\n', '\r', '[', ']', '{', '}', ',' => break,
                else => _ = self.advance(),
            }
        }
        if (self.pos == start) return error.InvalidYaml;
        return std.mem.trim(u8, self.input[start..self.pos], " \t");
    }

    fn parseScalar(self: *Self) !YamlValue {
        const start = self.pos;
        const ch = self.peek() orelse return .{ .null_val = {} };

        // Null
        if (ch == '~') {
            _ = self.advance();
            return .{ .null_val = {} };
        }

        // Quoted string
        if (ch == '"' or ch == '\'') {
            const s = try self.parseString();
            const duped = try self.allocator.dupe(u8, s);
            return .{ .string = duped };
        }

        // Unquoted value
        const raw = try self.parseString();

        // Check for null
        if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~") or raw.len == 0) {
            return .{ .null_val = {} };
        }
        // Check for bool
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "on")) {
            return .{ .bool_val = true };
        }
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "off")) {
            return .{ .bool_val = false };
        }
        // Check for int
        if (std.fmt.parseInt(i64, raw, 10)) |i| {
            return .{ .int_val = i };
        } else |_| {}
        // Check for float
        if (std.fmt.parseFloat(f64, raw)) |f| {
            return .{ .float_val = f };
        } else |_| {}

        // String
        const duped = try self.allocator.dupe(u8, raw);
        return .{ .string = duped };
    }

    fn parseList(self: *Self, base_indent: usize) !YamlValue {
        var list = std.array_list.Managed(YamlValue).init(self.allocator);
        errdefer {
            for (list.items) |*item| item.deinit();
            list.deinit();
        }

        while (true) {
            self.skipNewlines();
            self.skipWhitespace();

            // Check indent
            const current_indent = self.countIndent();
            if (current_indent < base_indent) break;

            const ch = self.peek() orelse break;

            if (ch == '-' and self.peekNextIsSpaceOrNewline()) {
                _ = self.advance(); // skip '-'
                self.skipWhitespace();

                const item_indent = self.col; // indent after dash+space
                const val = try self.parseValue(item_indent);
                try list.append(val);
            } else if (ch == '\n') {
                _ = self.advance();
            } else {
                break;
            }
        }

        return .{ .list = list };
    }

    fn parseMap(self: *Self, base_indent: usize) !YamlValue {
        var map = std.StringHashMapUnmanaged(YamlValue){};
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                var val = entry.value_ptr.*;
                val.deinit();
            }
            map.deinit();
        }

        while (true) {
            self.skipNewlines();
            self.skipWhitespace();

            const current_indent = self.countIndent();
            if (current_indent < base_indent) break;
            if (current_indent > base_indent) {
                // Nested content — parent should handle
                break;
            }

            const ch = self.peek() orelse break;

            // Check for list item (dash) — this is a list, not a map
            if (ch == '-' and self.peekNextIsSpaceOrNewline()) {
                break;
            }

            // Parse key
            const key_start = self.pos;
            const key = try self.parseString();
            if (key.len == 0) break;

            self.skipWhitespace();

            // Expect colon
            if (self.peek() == ':') {
                _ = self.advance();
                self.skipWhitespace();

                const duped_key = try self.allocator.dupe(u8, key);

                // Check if value is on next line (block style)
                if (self.peek() == '\n' or self.peek() == '\r') {
                    _ = self.advance();
                    self.skipWhitespace();
                    const next_indent = self.countIndent();

                    if (next_indent > base_indent) {
                        // Block map or list
                        const val = try self.parseValue(next_indent);
                        try map.put(self.allocator, duped_key, val);
                    } else {
                        // Empty value
                        try map.put(self.allocator, duped_key, .{ .null_val = {} });
                    }
                } else {
                    // Inline value
                    const ch2 = self.peek() orelse {
                        try map.put(self.allocator, duped_key, .{ .null_val = {} });
                        break;
                    };
                    if (ch2 == '[') {
                        // Inline list
                        _ = self.advance();
                        var inline_list = std.array_list.Managed(YamlValue).init(self.allocator);
                        while (self.peek()) |c| {
                            self.skipWhitespace();
                            if (c == ']') {
                                _ = self.advance();
                                break;
                            }
                            if (c == ',') {
                                _ = self.advance();
                                continue;
                            }
                            const item = try self.parseScalar();
                            try inline_list.append(item);
                        }
                        try map.put(self.allocator, duped_key, .{ .list = inline_list });
                    } else if (ch2 == '{') {
                        // Inline map — skip (rare in syntax files)
                        _ = self.advance();
                        var depth: usize = 1;
                        while (self.peek()) |c2| {
                            _ = self.advance();
                            if (c2 == '{') depth += 1;
                            if (c2 == '}') {
                                depth -= 1;
                                if (depth == 0) break;
                            }
                        }
                        try map.put(self.allocator, duped_key, .{ .null_val = {} });
                    } else {
                        const val = try self.parseScalar();
                        try map.put(self.allocator, duped_key, val);
                    }
                }
            } else {
                break;
            }
        }

        return .{ .map = map };
    }

    fn parseValue(self: *Self, indent: usize) !YamlValue {
        _ = indent;
        const ch = self.peek() orelse return .{ .null_val = {} };

        if (ch == '-') {
            return self.parseList(indent);
        }
        if (ch == '[') {
            _ = self.advance();
            var list = std.array_list.Managed(YamlValue).init(self.allocator);
            while (self.peek()) |c| {
                self.skipWhitespace();
                if (c == ']') {
                    _ = self.advance();
                    break;
                }
                if (c == ',') {
                    _ = self.advance();
                    continue;
                }
                const item = try self.parseScalar();
                try list.append(item);
            }
            return .{ .list = list };
        }

        return self.parseMap(indent);
    }

    fn peekNextIsSpaceOrNewline(self: *Self) bool {
        const next = if (self.pos + 1 < self.input.len) self.input[self.pos + 1] else return true;
        return next == ' ' or next == '\t' or next == '\n' or next == '\r';
    }

    fn countIndent(self: *Self) usize {
        var count: usize = 0;
        var idx = self.pos;
        while (idx < self.input.len) {
            const ch = self.input[idx];
            if (ch == ' ') {
                count += 1;
                idx += 1;
            } else if (ch == '\t') {
                count += 2; // tabs = 2 spaces
                idx += 1;
            } else {
                break;
            }
        }
        return count;
    }

    pub fn parse(self: *Self) !YamlValue {
        self.skipWhitespace();
        self.skipNewlines();

        // Skip %YAML directive if present
        if (self.pos < self.input.len and self.input[self.pos] == '%') {
            while (self.peek()) |ch| {
                if (ch == '\n') {
                    _ = self.advance();
                    break;
                }
                _ = self.advance();
            }
        }

        // Skip --- document separator
        self.skipWhitespace();
        self.skipNewlines();
        if (self.pos + 3 <= self.input.len and std.mem.eql(u8, self.input[self.pos..@min(self.pos + 3, self.input.len)], "---")) {
            self.pos += 3;
            self.col += 3;
            self.skipWhitespace();
            self.skipNewlines();
        }

        return self.parseMap(0);
    }
};

test "YAML: simple key-value" {
    const input = "name: JavaScript\nscope: source.js\n";
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    try std.testing.expectEqualStrings("JavaScript", map.get("name").?.string);
    try std.testing.expectEqualStrings("source.js", map.get("scope").?.string);
}

test "YAML: list of strings" {
    const input = "file_extensions:\n  - js\n  - jsx\n  - mjs\n";
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    const list = map.get("file_extensions").?.asList().?;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("js", list.items[0].string);
    try std.testing.expectEqualStrings("mjs", list.items[2].string);
}

test "YAML: nested contexts with patterns" {
    const input =
        \\contexts:
        \\  main:
        \\    - match: '\b(function)\b'
        \\      scope: keyword.control.js
        \\    - match: //.*
        \\      scope: comment.line.js
        \\  strings:
        \\    - match: '"'
        \\      scope: string.quoted.double.js
        \\      push: string-content
    ;
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    const contexts = map.get("contexts").?.asMap().?;
    try std.testing.expect(contexts.get("main") != null);
    try std.testing.expect(contexts.get("strings") != null);

    const main_ctx = contexts.get("main").?.asList().?;
    try std.testing.expectEqual(@as(usize, 2), main_ctx.items.len);

    const first_pattern = main_ctx.items[0].asMap().?;
    try std.testing.expectEqualStrings("\\b(function)\\b", first_pattern.get("match").?.string);
    try std.testing.expectEqualStrings("keyword.control.js", first_pattern.get("scope").?.string);
}

test "YAML: inline list" {
    const input = "file_extensions: [js, jsx, mjs]\n";
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    const list = map.get("file_extensions").?.asList().?;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}

test "YAML: booleans and null" {
    const input = "hidden: true\nfirst_line_match: null\n";
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    try std.testing.expectEqual(true, map.get("hidden").?.bool_val);
    try std.testing.expect(map.get("first_line_match").?.asString() == null);
}

test "YAML: comments" {
    const input =
        \\# This is a comment
        \\name: Python  # inline comment
        \\scope: source.python
    ;
    var parser = Parser.init(std.testing.allocator, input);
    var val = try parser.parse();
    defer val.deinit(std.testing.allocator);

    const map = val.asMap().?;
    try std.testing.expectEqualStrings("Python", map.get("name").?.string);
}
