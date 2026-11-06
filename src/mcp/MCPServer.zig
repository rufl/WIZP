// MCP Server for WIZP - stdio JSON-RPC transport
// Implements the server side of MCP to expose tools to external clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ToolRegistry = @import("../kilo/ToolRegistry.zig");

pub const MCPServer = struct {
    allocator: Allocator,
    io: std.Io,
    // We don't own the process; we read from stdin and write to stdout.
    // Buffer for partial reads between calls
    read_buf: std.array_list.Managed(u8),

    pub fn init(allocator: Allocator, io: std.Io) MCPServer {
        return .{
            .allocator = allocator,
            .io = io,
            .read_buf = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MCPServer) void {
        self.read_buf.deinit();
    }

    const Request = struct {
        jsonrpc: ?[]const u8 = null,
        id: ?u64 = null,
        method: []const u8 = "",
        params: ?std.json.Value = null,
    };

    const ToolCallParams = struct {
        name: []const u8 = "",
        arguments: ?std.json.Value = null,
    };

    const TextContent = struct {
        type: []const u8 = "text",
        text: []const u8,
    };

    const ToolCallResult = struct {
        content: []const TextContent,
        isError: bool,
    };

    const ToolInfo = struct {
        name: []const u8,
        description: []const u8,
        inputSchema: std.json.Value,
    };

    const ToolsListResult = struct {
        tools: []const ToolInfo,
    };

    /// Read one complete JSON message from stdin.
    /// Handles both newline-delimited (single-line) and multi-line (pretty-printed) JSON
    /// by counting balanced braces/brackets.
    fn readRequest(self: *MCPServer) ![]const u8 {
        const stdin_file = std.Io.File.stdin();
        const io = self.io;
        const start = self.read_buf.items.len;
        var depth: usize = 0;
        var in_string: bool = false;
        var escape: bool = false;

        while (true) {
            var byte: [1]u8 = undefined;
            const reader = std.Io.File.reader(stdin_file, io, &byte);
            const n = try reader.read();
            if (n == 0) return error.MCPConnectionClosed;
            try self.read_buf.append(byte[0]);

            const ch = byte[0];
            if (escape) {
                escape = false;
                continue;
            }
            if (ch == '\\') {
                escape = true;
                continue;
            }
            if (ch == '"') {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (ch == '{' or ch == '[') {
                depth += 1;
            } else if (ch == '}' or ch == ']') {
                if (depth == 0) continue;
                depth -= 1;
                if (depth == 0) {
                    // Complete JSON object/array read
                    const result = try self.allocator.dupe(u8, self.read_buf.items[start..]);
                    self.read_buf.clearRetainingCapacity();
                    return result;
                }
            }
        }
    }

    fn send(self: *MCPServer, json: []const u8) !void {
        const stdout_file = std.Io.File.stdout();
        const io = self.io;
        var buf: [4096]u8 = undefined;
        const writer = std.Io.File.writer(stdout_file, io, &buf);
        try writer.writeAll(json);
        try writer.writeAll("\n");
    }

    fn sendResponse(self: *MCPServer, id: u64, result: []const u8) !void {
        const resp = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{s}}}", .{ id, result });
        defer self.allocator.free(resp);
        try self.send(resp);
    }

    fn sendError(self: *MCPServer, id: u64, code: i64, message: []const u8) !void {
        const msg_json = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(msg_json);
        const err = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id, code, msg_json });
        defer self.allocator.free(err);
        try self.send(err);
    }

    fn stringifyAlloc(allocator: Allocator, value: anytype) ![]u8 {
        var buffer: std.Io.Writer.Allocating = .init(allocator);
        errdefer buffer.deinit();
        try std.json.Stringify.value(value, .{}, &buffer.writer);
        return buffer.toOwnedSlice();
    }

    fn toolsListJson(self: *MCPServer) ![]u8 {
        const defs = ToolRegistry.builtinTools();
        var schemas = std.array_list.Managed(std.json.Parsed(std.json.Value)).init(self.allocator);
        defer {
            for (schemas.items) |*p| p.deinit();
            schemas.deinit();
        }

        var tools = std.array_list.Managed(ToolInfo).init(self.allocator);
        defer tools.deinit();

        for (defs) |def| {
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, def.parameters, .{});
            try schemas.append(parsed);
            try tools.append(.{
                .name = def.name,
                .description = def.description,
                .inputSchema = parsed.value,
            });
        }

        const payload = ToolsListResult{ .tools = tools.items };
        return try stringifyAlloc(self.allocator, payload);
    }

    /// Main server loop: reads requests, processes them, and sends responses.
    pub fn run(self: *MCPServer) !void {
        while (true) {
            const req = try self.readRequest();
            defer self.allocator.free(req);

            const parsed = std.json.parseFromSlice(Request, self.allocator, req, .{ .ignore_unknown_fields = true }) catch {
                continue;
            };
            defer parsed.deinit();

            const method = parsed.value.method;
            const req_id = parsed.value.id orelse continue;

            if (std.mem.eql(u8, method, "initialize")) {
                const payload = .{
                    .protocolVersion = "2024-11-05",
                    .capabilities = .{ .tools = .{} },
                    .serverInfo = .{ .name = "wizp", .version = "0.1.0" },
                };
                const result_json = try stringifyAlloc(self.allocator, payload);
                defer self.allocator.free(result_json);
                try self.sendResponse(req_id, result_json);
                continue;
            }

            if (std.mem.eql(u8, method, "tools/list")) {
                const result_json = try self.toolsListJson();
                defer self.allocator.free(result_json);
                try self.sendResponse(req_id, result_json);
                continue;
            }

            if (std.mem.eql(u8, method, "tools/call")) {
                const params_value = parsed.value.params orelse {
                    try self.sendError(req_id, -32602, "Missing params");
                    continue;
                };

                const params_json = try stringifyAlloc(self.allocator, params_value);
                defer self.allocator.free(params_json);

                const call_parsed = std.json.parseFromSlice(ToolCallParams, self.allocator, params_json, .{ .ignore_unknown_fields = true }) catch {
                    try self.sendError(req_id, -32602, "Invalid params");
                    continue;
                };
                defer call_parsed.deinit();

                if (call_parsed.value.name.len == 0) {
                    try self.sendError(req_id, -32602, "Missing tool name");
                    continue;
                }

                const args_json = if (call_parsed.value.arguments) |v| try stringifyAlloc(self.allocator, v) else try self.allocator.dupe(u8, "{}");
                defer self.allocator.free(args_json);

                const id_str = try std.fmt.allocPrint(self.allocator, "{}", .{req_id});
                defer self.allocator.free(id_str);

                const tool_result = ToolRegistry.executeTool(self.allocator, .{
                    .id = id_str,
                    .name = call_parsed.value.name,
                    .arguments = args_json,
                }, ".") catch |err| ToolRegistry.ToolResult{
                    .tool_call_id = try self.allocator.dupe(u8, id_str),
                    .err_msg = try std.fmt.allocPrint(self.allocator, "Tool execution failed: {s}", .{@errorName(err)}),
                };

                const text = tool_result.err_msg orelse tool_result.content;
                const is_error = tool_result.err_msg != null;

                const content_items = [_]TextContent{.{ .text = text }};
                const payload = ToolCallResult{ .content = &content_items, .isError = is_error };
                const result_json = try stringifyAlloc(self.allocator, payload);
                defer self.allocator.free(result_json);

                try self.sendResponse(req_id, result_json);

                self.allocator.free(tool_result.tool_call_id);
                if (tool_result.err_msg) |m| self.allocator.free(m);
                if (tool_result.content.len > 0) self.allocator.free(tool_result.content);
                continue;
            }

            if (std.mem.eql(u8, method, "shutdown")) {
                try self.sendResponse(req_id, "null");
                continue;
            }

            try self.sendError(req_id, -32601, "Method not found");
        }
    }
};
