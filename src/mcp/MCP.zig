// MCP Client for WIZP - stdio JSON-RPC transport with line-delimited messages
// MCP uses newline-delimited JSON (one message per line, terminated by \n).
const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("../runtime_016.zig");

pub const ToolDef = struct { name: []const u8, description: []const u8, inputSchema: []const u8 = "{}" };

pub const MCPClient = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    next_id: u64 = 1,
    tools: std.array_list.Managed(ToolDef),
    /// Buffer for partial reads between calls
    read_buf: std.array_list.Managed(u8),
    /// Cached capabilities from initialize response
    server_name: []const u8 = "",
    server_version: []const u8 = "",

    pub fn init(allocator: Allocator) MCPClient {
        return .{ .allocator = allocator, .process = null, .next_id = 1, .tools = std.array_list.Managed(ToolDef).init(allocator), .read_buf = std.array_list.Managed(u8).init(allocator) };
    }

    pub fn connect(self: *MCPClient, cmd: []const u8, args: []const []const u8) !void {
        var all_args = std.array_list.Managed([]const u8).init(self.allocator);
        defer all_args.deinit();
        try all_args.append(cmd);
        for (args) |a| try all_args.append(a);
        const child = try std.process.spawn(runtime.io(), .{
            .argv = all_args.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.process = child;
        try self.sendRequest("initialize", "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"wizp\",\"version\":\"1.0\"}}");
        const init_resp = try self.readResponse();
        defer self.allocator.free(init_resp);
        // Parse server name/version from init response (best-effort)
        if (std.mem.indexOf(u8, init_resp, "\"name\"")) |ns| {
            if (std.mem.indexOfScalarPos(u8, init_resp, ns + 6, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, init_resp, v0 + 1, '"')) |v1| {
                    self.server_name = try self.allocator.dupe(u8, init_resp[v0 + 1 .. v1]);
                }
            }
        }
        try self.sendNotification("notifications/initialized", null);
    }

    fn send(self: *MCPClient, json: []const u8) !void {
        try runtime.writeAll(self.process.?.stdin.?, json);
        try runtime.writeAll(self.process.?.stdin.?, "\n");
    }

    fn sendRequest(self: *MCPClient, method: []const u8, params: ?[]const u8) !void {
        const id = self.next_id;
        self.next_id += 1;
        const req = if (params) |p| try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p }) else try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"{s}\"}}", .{ id, method });
        defer self.allocator.free(req);
        try self.send(req);
    }

    fn sendNotification(self: *MCPClient, method: []const u8, params: ?[]const u8) !void {
        const msg = if (params) |p| try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, p }) else try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method});
        defer self.allocator.free(msg);
        try self.send(msg);
    }

    /// Read one complete JSON message from stdout.
    /// Handles both newline-delimited (single-line) and multi-line (pretty-printed) JSON
    /// by counting balanced braces/brackets.
    fn readResponse(self: *MCPClient) ![]const u8 {
        const stdout = self.process.?.stdout.?;
        const start = self.read_buf.items.len;
        var depth: usize = 0;
        var in_string: bool = false;
        var escape: bool = false;

        while (true) {
            var byte: [1]u8 = undefined;
            const n = try runtime.read(stdout, &byte);
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

    pub fn listTools(self: *MCPClient) ![]const u8 {
        try self.sendRequest("tools/list", null);
        return try self.readResponse();
    }
    pub fn callTool(self: *MCPClient, name: []const u8, args: []const u8) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"name\":\"{s}\",\"arguments\":{s}}}", .{ name, args });
        defer self.allocator.free(params);
        try self.sendRequest("tools/call", params);
        return try self.readResponse();
    }

    pub fn shutdown(self: *MCPClient) void {
        if (self.process) |*p| {
            p.kill(runtime.io());
            self.process = null;
        }
    }
    pub fn deinit(self: *MCPClient) void {
        self.shutdown();
        self.tools.deinit();
        self.read_buf.deinit();
        if (self.server_name.len > 0) self.allocator.free(self.server_name);
        if (self.server_version.len > 0) self.allocator.free(self.server_version);
    }
};
