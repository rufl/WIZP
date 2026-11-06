// WIZP Tree-sitter integration — incremental parsing for syntax highlighting.
// Wraps the tree-sitter C library (https://tree-sitter.github.io).
//
// To enable: place tree-sitter source in lib/tree-sitter/ and build with:
//   zig build -DTREE_SITTER_AVAILABLE=1
//
// Architecture:
//   Language  — compiled grammar (.so loaded at runtime or linked statically)
//   Parser    — incremental parser state
//   Tree      — concrete syntax tree (CST), updated on each edit
//   Node      — a node in the tree with type, range, children
//   Query     — pattern matching on trees (for highlighting, folding)

const std = @import("std");
const ts_options = @import("tree_sitter_options");

/// Whether tree-sitter is compiled into this build.
pub const available = ts_options.available;

/// Byte offset in source text.
pub const ByteOffset = u32;

/// A point in source text (row, column), both 0-indexed.
pub const Point = struct {
    row: u32,
    column: u32,
};

/// Range in source text.
pub const Range = struct {
    start_byte: ByteOffset,
    end_byte: ByteOffset,
    start_point: Point,
    end_point: Point,
};

/// Node type identifier from the grammar.
pub const NodeType = []const u8;

/// A node in the concrete syntax tree.
pub const Node = struct {
    ts_node: if (available) TSNode else void,

    pub fn nodeType(self: Node) NodeType {
        if (!available) return "unknown";
        return std.mem.span(ts_node_type(self.ts_node));
    }

    pub fn startByte(self: Node) ByteOffset {
        if (!available) return 0;
        return ts_node_start_byte(self.ts_node);
    }

    pub fn endByte(self: Node) ByteOffset {
        if (!available) return 0;
        return ts_node_end_byte(self.ts_node);
    }

    pub fn startPoint(self: Node) Point {
        if (!available) return .{ .row = 0, .column = 0 };
        const p = ts_node_start_point(self.ts_node);
        return .{ .row = p.row, .column = p.column };
    }

    pub fn endPoint(self: Node) Point {
        if (!available) return .{ .row = 0, .column = 0 };
        const p = ts_node_end_point(self.ts_node);
        return .{ .row = p.row, .column = p.column };
    }

    pub fn range(self: Node) Range {
        return .{
            .start_byte = self.startByte(),
            .end_byte = self.endByte(),
            .start_point = self.startPoint(),
            .end_point = self.endPoint(),
        };
    }

    pub fn childCount(self: Node) u32 {
        if (!available) return 0;
        return ts_node_child_count(self.ts_node);
    }

    pub fn child(self: Node, index: u32) ?Node {
        if (!available) return null;
        const child_ts = ts_node_child(self.ts_node, index);
        if (ts_node_is_null(child_ts)) return null;
        return Node{ .ts_node = child_ts };
    }

    pub fn parent(self: Node) ?Node {
        if (!available) return null;
        const p = ts_node_parent(self.ts_node);
        if (ts_node_is_null(p)) return null;
        return Node{ .ts_node = p };
    }

    pub fn isNull(self: Node) bool {
        if (!available) return true;
        return ts_node_is_null(self.ts_node);
    }

    pub fn hasError(self: Node) bool {
        if (!available) return false;
        return ts_node_has_error(self.ts_node);
    }

    pub fn isNamed(self: Node) bool {
        if (!available) return false;
        return ts_node_is_named(self.ts_node);
    }
};

/// A complete syntax tree for a source file.
pub const Tree = struct {
    ts_tree: if (available) *TSTree else *anyopaque,
    allocator: std.mem.Allocator,

    pub fn rootNode(self: *const Tree) Node {
        if (!available) return Node{ .ts_node = {} };
        return Node{ .ts_node = ts_tree_root_node(self.ts_tree) };
    }

    pub fn edit(self: *Tree, ed: InputEdit) void {
        if (!available) {
            _ = ed;
            return;
        }
        var ts_edit: TSInputEdit = .{
            .start_byte = edit.start_byte,
            .old_end_byte = edit.old_end_byte,
            .new_end_byte = edit.new_end_byte,
            .start_point = .{ .row = edit.start_point.row, .column = edit.start_point.column },
            .old_end_point = .{ .row = edit.old_end_point.row, .column = edit.old_end_point.column },
            .new_end_point = .{ .row = edit.new_end_point.row, .column = edit.new_end_point.column },
        };
        ts_tree_edit(self.ts_tree, &ts_edit);
    }

    pub fn deinit(self: *Tree) void {
        if (!available) return;
        ts_tree_delete(self.ts_tree);
    }
};

/// Edit applied to a tree (for incremental re-parsing).
pub const InputEdit = struct {
    start_byte: ByteOffset,
    old_end_byte: ByteOffset,
    new_end_byte: ByteOffset,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

/// Parser for incremental parsing of source code.
pub const Parser = struct {
    ts_parser: if (available) *TSParser else *anyopaque,

    pub fn init() !Parser {
        if (!available) return Parser{ .ts_parser = undefined };
        const parser = ts_parser_new() orelse return error.TreeSitterInitFailed;
        return Parser{ .ts_parser = parser };
    }

    pub fn setLanguage(self: *Parser, lang: *const Language) !void {
        if (!available) return;
        if (!ts_parser_set_language(self.ts_parser, lang.ts_lang)) {
            return error.IncompatibleLanguage;
        }
    }

    pub fn parse(self: *Parser, source: []const u8, old_tree: ?*Tree) !Tree {
        if (!available) return Tree{ .ts_tree = undefined, .allocator = undefined };
        const tree = ts_parser_parse_string(
            self.ts_parser,
            if (old_tree) |t| t.ts_tree else null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;
        return Tree{ .ts_tree = tree, .allocator = undefined };
    }

    pub fn deinit(self: *Parser) void {
        if (!available) return;
        ts_parser_delete(self.ts_parser);
    }
};

/// A tree-sitter language grammar.
pub const Language = struct {
    ts_lang: if (available) *const TSLanguage else *anyopaque,

    /// Get the language's field name for a given field ID.
    pub fn fieldNameForId(self: *const Language, id: u16) ?[]const u8 {
        if (!available) return null;
        const name = ts_language_field_name_for_id(self.ts_lang, id);
        if (name == null) return null;
        return std.mem.span(name);
    }

    /// Get the number of distinct node types in this language.
    pub fn symbolCount(self: *const Language) u32 {
        if (!available) return 0;
        return ts_language_symbol_count(self.ts_lang);
    }

    /// Get the node type string for a symbol ID.
    pub fn symbolName(self: *const Language, symbol: u16) ?[]const u8 {
        if (!available) return null;
        const name = ts_language_symbol_name(self.ts_lang, symbol);
        if (name == null) return null;
        return std.mem.span(name);
    }
};

/// A tree-sitter query for pattern matching.
pub const Query = struct {
    ts_query: if (available) *TSQuery else *anyopaque,

    pub fn init(lang: *const Language, source: []const u8) !Query {
        if (!available) return Query{ .ts_query = undefined };
        var error_offset: u32 = 0;
        var error_type: TSQueryError = .None;
        const query = ts_query_new(
            lang.ts_lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            return switch (error_type) {
                .Syntax => error.QuerySyntaxError,
                .NodeType => error.QueryNodeTypeError,
                .Field => error.QueryFieldError,
                .Capture => error.QueryCaptureError,
                .Structure => error.QueryStructureError,
                .Language => error.QueryLanguageError,
                else => error.QueryError,
            };
        };
        return Query{ .ts_query = query };
    }

    /// Execute a query and call a callback for each match.
    pub fn matches(
        self: *const Query,
        node: Node,
        source: []const u8,
        comptime cb: fn (capture_name: []const u8, capture_node: Node) void,
    ) void {
        if (!available) return;
        var cursor = ts_query_cursor_new();
        defer ts_query_cursor_delete(cursor);
        ts_query_cursor_exec(cursor, self.ts_query, node.ts_node);

        var match: TSQueryMatch = undefined;
        while (ts_query_cursor_next_match(cursor, &match)) {
            for (0..match.capture_count) |i| {
                const capture = match.captures[i];
                const capture_name = std.mem.span(ts_query_capture_name_for_id(
                    self.ts_query,
                    capture.index,
                    null,
                ) orelse continue);
                const cap_node = Node{ .ts_node = capture.node };
                cb(capture_name, cap_node);
            }
        }
        _ = source;
    }

    pub fn deinit(self: *Query) void {
        if (!available) return;
        ts_query_delete(self.ts_query);
    }
};

// ============================================================
// C API declarations (linked when TREE_SITTER_AVAILABLE=1)
// ============================================================

const TSParser = if (available) @import("tree_sitter_c") else opaque {};
const TSTree = if (available) @import("tree_sitter_c") else opaque {};
const TSLanguage = if (available) @import("tree_sitter_c") else opaque {};
const TSNode = if (available) @import("tree_sitter_c") else opaque {};
const TSQuery = if (available) @import("tree_sitter_c") else opaque {};
const TSQueryCursor = if (available) @import("tree_sitter_c") else opaque {};
const TSQueryMatch = if (available) @import("tree_sitter_c") else opaque {};
const TSQueryCapture = if (available) @import("tree_sitter_c") else opaque {};
const TSInputEdit = if (available) @import("tree_sitter_c") else opaque {};
const TSQueryError = if (available) @import("tree_sitter_c") else opaque {};

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(parser: *TSParser) void;
extern fn ts_parser_set_language(parser: *TSParser, language: *const TSLanguage) bool;
extern fn ts_parser_parse_string(parser: *TSParser, old_tree: ?*TSTree, source: [*]const u8, len: u32) ?*TSTree;

extern fn ts_tree_root_node(tree: *TSTree) TSNode;
extern fn ts_tree_edit(tree: *TSTree, edit: *const TSInputEdit) void;
extern fn ts_tree_delete(tree: *TSTree) void;

extern fn ts_node_type(node: TSNode) [*:0]const u8;
extern fn ts_node_start_byte(node: TSNode) u32;
extern fn ts_node_end_byte(node: TSNode) u32;
extern fn ts_node_start_point(node: TSNode) struct { row: u32, column: u32 };
extern fn ts_node_end_point(node: TSNode) struct { row: u32, column: u32 };
extern fn ts_node_child_count(node: TSNode) u32;
extern fn ts_node_child(node: TSNode, index: u32) TSNode;
extern fn ts_node_parent(node: TSNode) TSNode;
extern fn ts_node_is_null(node: TSNode) bool;
extern fn ts_node_has_error(node: TSNode) bool;
extern fn ts_node_is_named(node: TSNode) bool;

extern fn ts_language_field_name_for_id(lang: *const TSLanguage, id: u16) ?[*:0]const u8;
extern fn ts_language_symbol_count(lang: *const TSLanguage) u32;
extern fn ts_language_symbol_name(lang: *const TSLanguage, symbol: u16) ?[*:0]const u8;

extern fn ts_query_new(lang: *const TSLanguage, source: [*]const u8, len: u32, error_offset: *u32, error_type: *c_uint) ?*TSQuery;
extern fn ts_query_delete(query: *TSQuery) void;
extern fn ts_query_cursor_new() *TSQueryCursor;
extern fn ts_query_cursor_delete(cursor: *TSQueryCursor) void;
extern fn ts_query_cursor_exec(cursor: *TSQueryCursor, query: *TSQuery, node: TSNode) void;
extern fn ts_query_cursor_next_match(cursor: *TSQueryCursor, match: *TSQueryMatch) bool;
extern fn ts_query_capture_name_for_id(query: *const TSQuery, id: u32, len: ?*u32) ?[*:0]const u8;

// ============================================================
// Tests
// ============================================================

test "TreeSitter unavailable stub" {
    if (available) return; // Skip if real tree-sitter is linked

    const parser = try Parser.init();
    defer parser.deinit();

    const source = "int main() { return 0; }";
    var tree = try parser.parse(source, null);
    defer tree.deinit();

    const root = tree.rootNode();
    try std.testing.expect(root.isNull());
    try std.testing.expectEqual(@as(u32, 0), root.childCount());
    try std.testing.expectEqualStrings("unknown", root.nodeType());
}

test "TreeSitter Node navigation stub" {
    if (available) return;
    const node = Node{ .ts_node = {} };
    try std.testing.expect(node.isNull());
    try std.testing.expectEqual(@as(u32, 0), node.startByte());
    try std.testing.expectEqual(@as(u32, 0), node.endByte());
    try std.testing.expectEqual(null, node.parent());
}

test "TreeSitter Query stub" {
    if (available) return;
    const node = Node{ .ts_node = {} };
    var capture_count: usize = 0;
    // Query not testable in stub mode since Language needs real TSLanguage
    _ = node;
    _ = capture_count;
}
