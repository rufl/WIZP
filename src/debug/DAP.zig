// DAP Client for WIZP — Debug Adapter Protocol (stdio JSON-RPC, mirrors LSP client)
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ContentLength = @import("../protocol/ContentLength.zig");
const runtime = @import("../runtime_016.zig");

pub const DAPClient = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    next_id: u64 = 1,
    dap_mutex: @import("../sync.zig").Mutex = .{},
    running: bool = false,

    pub fn init(allocator: Allocator) DAPClient {
        return .{ .allocator = allocator, .process = null, .next_id = 1 };
    }

    pub fn start(self: *DAPClient, cmd: []const u8, args: []const []const u8) !void {
        if (std.fs.path.isAbsolute(cmd)) {
            try std.Io.Dir.cwd().access(runtime.io(), cmd, .{});
        }
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
        self.running = true;
    }

    pub fn stop(self: *DAPClient) void {
        if (self.process) |*proc| {
            proc.kill(runtime.io());
            self.process = null;
        }
        self.running = false;
    }

    pub fn deinit(self: *DAPClient) void {
        self.stop();
        self.running = false;
    }

    // ─────────────────── Request methods ─────────────────

    pub fn initialize(self: *DAPClient, adapter_id: []const u8) ![]const u8 {
        var params_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer params_buf.deinit();
        const params_writer = &params_buf.writer;
        try params_writer.writeAll("{\"clientID\":\"wizp\",\"clientName\":\"WIZP\",\"adapterID\":");
        try ContentLength.writeJsonString(params_writer, adapter_id);
        try params_writer.writeAll(",\"locale\":\"en\",\"linesStartAt1\":true,\"columnsStartAt1\":true,\"supportsVariableType\":true,\"supportsVariablePaging\":true,\"supportsRunInTerminalRequest\":true}");
        const params = params_buf.written();
        try self.send("initialize", params);
        return self.read();
    }

    pub fn launch(self: *DAPClient, config_json: []const u8) ![]const u8 {
        try self.send("launch", config_json);
        return self.read();
    }

    pub fn attach(self: *DAPClient, config_json: []const u8) ![]const u8 {
        try self.send("attach", config_json);
        return self.read();
    }

    pub fn configurationDone(self: *DAPClient) !void {
        self.dap_mutex.lock();
        defer self.dap_mutex.unlock();
        const proc = &self.process.?;
        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try ContentLength.writeRequest(&body_buf.writer, self.next_id, "configurationDone", "{}");
        const body = body_buf.written();
        self.next_id += 1;
        var hdr: [128]u8 = undefined;
        const h = try ContentLength.formatHeader(&hdr, body.len);
        try runtime.writeAll(proc.stdin.?, h);
        try runtime.writeAll(proc.stdin.?, body);
    }

    pub fn setBreakpoints(self: *DAPClient, source_path: []const u8, lines: []const usize) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"source\":{\"name\":");
        try ContentLength.writeJsonString(w, source_path);
        try w.writeAll(",\"path\":");
        try ContentLength.writeJsonString(w, source_path);
        try w.writeAll("},\"breakpoints\":[");
        for (lines, 0..) |line, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"line\":{}}}", .{line + 1});
        }
        try w.writeAll("]}");
        try self.send("setBreakpoints", params.written());
        return self.read();
    }

    pub fn setExceptionBreakpoints(self: *DAPClient, filters: []const []const u8) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"filters\":[");
        for (filters, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try ContentLength.writeJsonString(w, f);
        }
        try w.writeAll("]}");
        try self.send("setExceptionBreakpoints", params.written());
        return self.read();
    }

    pub fn continueExecution(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{}}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("continue", params);
        return self.read();
    }

    pub fn next(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{}}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("next", params);
        return self.read();
    }

    pub fn stepIn(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{}}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("stepIn", params);
        return self.read();
    }

    pub fn stepOut(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{}}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("stepOut", params);
        return self.read();
    }

    pub fn pause(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{}}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("pause", params);
        return self.read();
    }

    pub fn threads(self: *DAPClient) ![]const u8 {
        try self.send("threads", "{}");
        return self.read();
    }

    pub fn stackTrace(self: *DAPClient, thread_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"threadId\":{},\"levels\":50}}", .{thread_id});
        defer self.allocator.free(params);
        try self.send("stackTrace", params);
        return self.read();
    }

    pub fn scopes(self: *DAPClient, frame_id: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"frameId\":{}}}", .{frame_id});
        defer self.allocator.free(params);
        try self.send("scopes", params);
        return self.read();
    }

    pub fn variables(self: *DAPClient, variables_ref: usize) ![]const u8 {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"variablesReference\":{}}}", .{variables_ref});
        defer self.allocator.free(params);
        try self.send("variables", params);
        return self.read();
    }

    pub fn evaluate(self: *DAPClient, expression: []const u8, frame_id: ?usize) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const w = &params.writer;
        try w.writeAll("{\"expression\":");
        try ContentLength.writeJsonString(w, expression);
        if (frame_id) |fid| try w.print(",\"frameId\":{}", .{fid});
        try w.writeAll("}");
        try self.send("evaluate", params.written());
        return self.read();
    }

    pub fn readMessage(self: *DAPClient) ![]const u8 {
        return self.read();
    }

    // ─────────────────── Protocol helpers ─────────────────

    fn send(self: *DAPClient, method: []const u8, params: []const u8) !void {
        self.dap_mutex.lock();
        defer self.dap_mutex.unlock();
        const proc = &(self.process orelse return error.AdapterUnavailable);
        if (!self.running) return error.AdapterUnavailable;
        const id = self.next_id;
        self.next_id += 1;
        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try ContentLength.writeRequest(&body_buf.writer, id, method, params);
        const body = body_buf.written();
        var hdr: [128]u8 = undefined;
        const h = try ContentLength.formatHeader(&hdr, body.len);
        runtime.writeAll(proc.stdin.?, h) catch |err| {
            self.markTransportFailure();
            return err;
        };
        runtime.writeAll(proc.stdin.?, body) catch |err| {
            self.markTransportFailure();
            return err;
        };
    }

    fn markTransportFailure(self: *DAPClient) void {
        self.stop();
    }

    fn read(self: *DAPClient) ![]const u8 {
        self.dap_mutex.lock();
        defer self.dap_mutex.unlock();
        return self.readTransport() catch |err| {
            if (err != error.DAPRpcError) self.markTransportFailure();
            return err;
        };
    }

    fn readTransport(self: *DAPClient) ![]const u8 {
        const proc = &(self.process orelse return error.AdapterUnavailable);
        if (!self.running) return error.AdapterUnavailable;
        // Read Content-Length header
        var hdr_buf: [1024]u8 = undefined;
        var hdr_len: usize = 0;
        while (hdr_len < hdr_buf.len) {
            ContentLength.waitReadable(proc.stdout.?.handle, ContentLength.default_read_timeout_ms) catch |err| {
                if (err == error.Timeout) return error.DAPReadTimeout;
                return err;
            };
            const n = try runtime.read(proc.stdout.?, hdr_buf[hdr_len .. hdr_len + 1]);
            if (n == 0) return error.ConnectionClosed;
            hdr_len += n;
            if (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n")) |_| break;
        }
        // Parse Content-Length
        const cl = ContentLength.parseHeader(hdr_buf[0..hdr_len]) catch |err| switch (err) {
            error.ContentLengthTooLarge => return error.ContentLengthTooLarge,
            error.HeaderTooLarge => return error.HeaderTooLarge,
            error.BadHeader => return error.BadHeader,
        };
        // Read body
        var body = try self.allocator.alloc(u8, cl);
        errdefer self.allocator.free(body);
        var bytes_read: usize = 0;
        while (bytes_read < cl) {
            ContentLength.waitReadable(proc.stdout.?.handle, ContentLength.default_read_timeout_ms) catch |err| {
                if (err == error.Timeout) return error.DAPReadTimeout;
                return err;
            };
            const n = try runtime.read(proc.stdout.?, body[bytes_read..cl]);
            if (n == 0) return error.ConnectionClosed;
            bytes_read += n;
        }
        if (try ContentLength.parseRpcError(self.allocator, body)) |rpc_error| {
            defer self.allocator.free(rpc_error.message);
            self.allocator.free(body);
            return error.DAPRpcError;
        }
        return body;
    }
};

test "DAP stop kills and reaps a live child process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var client = DAPClient.init(std.testing.allocator);
    defer client.deinit();
    try client.start("/bin/sh", &.{ "-c", "sleep 30" });
    try std.testing.expect(client.process != null);
    try std.testing.expect(client.running);

    client.stop();
    try std.testing.expect(client.process == null);
    try std.testing.expect(!client.running);
}
