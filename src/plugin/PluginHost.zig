// Sublime Text plugin host manager for WIZP
// Manages Python subprocess running Sublime-compatible plugins via MCP

const std = @import("std");
const Allocator = std.mem.Allocator;
const SublimeCompat = @import("SublimeCompat.zig");
const runtime = @import("../runtime_016.zig");

pub const PluginHost = struct {
    allocator: Allocator,
    api_server: SublimeCompat.PluginAPIServer,
    child_process: ?std.process.Child = null,
    plugin_dirs: std.array_list.Managed([]const u8),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .api_server = SublimeCompat.PluginAPIServer.init(allocator),
            .child_process = null,
            .plugin_dirs = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    /// Add a plugin directory to load
    pub fn addPluginDir(self: *Self, dir: []const u8) !void {
        const duped = try self.allocator.dupe(u8, dir);
        try self.plugin_dirs.append(duped);
    }

    /// Start the Python plugin host process
    pub fn start(self: *Self) !void {
        // Build command args: python3 plugin_host.py [plugin_dirs...]
        var args = std.array_list.Managed([]const u8).init(self.allocator);
        defer args.deinit();
        try args.append("python3");
        try args.append("plugins/sublime_compat/plugin_host.py");

        // Add plugin directories
        for (self.plugin_dirs.items) |dir| {
            try args.append(dir);
        }

        const child = try std.process.spawn(runtime.io(), .{
            .argv = args.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.child_process = child;
    }

    /// Send an MCP request to the plugin host and get response
    pub fn sendMCPRequest(self: *Self, method: []const u8, params_json: ?[]const u8) !?[]const u8 {
        if (self.child_process) |*child| {
            const stdin = child.stdin orelse return error.NoStdin;
            const stdout = child.stdout orelse return error.NoStdout;

            // Build JSON-RPC request
            var req: std.Io.Writer.Allocating = .init(self.allocator);
            defer req.deinit();
            const writer = &req.writer;
            try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\"", .{method});
            if (params_json) |p| {
                try writer.print(",\"params\":{s}", .{p});
            }
            try writer.writeAll("}\n");

            // Send request
            try runtime.writeAll(stdin, req.written());

            // Read response line
            var buf: [4096]u8 = undefined;
            const n = try runtime.read(stdout, &buf);
            if (n > 0) {
                const line = buf[0..n];
                // Parse JSON response
                if (std.mem.indexOf(u8, line, "\"result\"")) |_| {
                    // Extract result value (simplified)
                    return try self.allocator.dupe(u8, line);
                }
            }
        }

        // Fallback: handle locally
        return try self.api_server.handleRequest(method, params_json);
    }

    /// Stop the plugin host
    pub fn stop(self: *Self) void {
        if (self.child_process) |*child| {
            const stdin = child.stdin orelse return;
            runtime.writeAll(
                stdin,
                "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\"}\n",
            ) catch {};
            child.kill(runtime.io());
            self.child_process = null;
        }
    }

    /// Check if plugin host is running
    pub fn isRunning(self: *Self) bool {
        return self.child_process != null;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        for (self.plugin_dirs.items) |dir| {
            self.allocator.free(dir);
        }
        self.plugin_dirs.deinit();
        self.api_server.deinit();
    }
};
