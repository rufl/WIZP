// LSP Client for WIZP - Full stdio-based implementation with proper header protocol
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json_mod = std.json;
const ContentLength = @import("../protocol/ContentLength.zig");
const runtime = @import("../runtime_016.zig");

pub const DiagnosticSeverity = enum(u8) { err = 1, warning = 2, information = 3, hint = 4 };
pub const Diagnostic = struct { range: Range, severity: ?DiagnosticSeverity = null, message: []const u8 };
pub const Range = struct { start: Position, end: Position };
pub const Position = struct { line: usize, character: usize };
pub const CompletionItem = struct { label: []const u8, kind: ?CompletionItemKind = null, detail: ?[]const u8 = null, insertText: ?[]const u8 = null };
pub const CompletionItemKind = enum(u8) { Text = 1, Method = 2, Function = 3, Constructor = 4, Field = 5, Variable = 6, Class = 7, Interface = 8, Module = 9, Property = 10, Unit = 11, Value = 12, EnumMember = 13, Constant = 14, Struct = 15, Event = 16, Operator = 17, TypeParameter = 18 };

pub const LSPClient = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    next_id: u64 = 1,
    /// Stored per-file diagnostics from publishDiagnostics notifications
    diagnostics: std.StringHashMapUnmanaged([]Diagnostic),
    deinitialized: bool = false,
    /// Serializes send+read to prevent interleaving across worker threads
    lsp_mutex: @import("../sync.zig").Mutex = .{},

    pub fn init(allocator: Allocator) LSPClient {
        return .{ .allocator = allocator, .process = null, .next_id = 1, .diagnostics = .{} };
    }

    pub fn start(self: *LSPClient, cmd: []const u8, args: []const []const u8) !void {
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
    }

    /// Send a JSON-RPC request with proper Content-Length header
    fn send(self: *LSPClient, method: []const u8, params: []const u8) !void {
        self.lsp_mutex.lock();
        defer self.lsp_mutex.unlock();
        const proc = &self.process.?;
        const id = self.next_id;
        self.next_id += 1;
        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try ContentLength.writeRequest(&body_buf.writer, id, method, params);
        const body = body_buf.written();
        var header_buf: [128]u8 = undefined;
        const header = try ContentLength.formatHeader(&header_buf, body.len);
        try runtime.writeAll(proc.stdin.?, header);
        try runtime.writeAll(proc.stdin.?, body);
    }

    /// Send a notification (no id field)
    fn sendNotification(self: *LSPClient, method: []const u8, params: []const u8) !void {
        self.lsp_mutex.lock();
        defer self.lsp_mutex.unlock();
        const proc = &self.process.?;
        var body_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_buf.deinit();
        try ContentLength.writeNotification(&body_buf.writer, method, params);
        const body = body_buf.written();
        var header_buf: [128]u8 = undefined;
        const header = try ContentLength.formatHeader(&header_buf, body.len);
        try runtime.writeAll(proc.stdin.?, header);
        try runtime.writeAll(proc.stdin.?, body);
    }

    /// Read an LSP response message. Notifications encountered while waiting
    /// are automatically dispatched via handlePublishDiagnostics.
    fn read(self: *LSPClient) ![]const u8 {
        self.lsp_mutex.lock();
        defer self.lsp_mutex.unlock();
        return self.readLocked();
    }

    /// Internal read — caller must hold lsp_mutex
    fn readLocked(self: *LSPClient) ![]const u8 {
        while (true) {
            const msg = try self.readRaw();
            if (std.mem.indexOf(u8, msg, "\"id\"")) |_| {
                return msg;
            } else {
                if (std.mem.indexOf(u8, msg, "\"method\"")) |m_start| {
                    if (std.mem.indexOfScalarPos(u8, msg, m_start + 8, '"')) |v0| {
                        if (std.mem.indexOfScalarPos(u8, msg, v0 + 1, '"')) |v1| {
                            const method = msg[v0 + 1 .. v1];
                            if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                                self.handlePublishDiagnostics(msg) catch {};
                            }
                        }
                    }
                }
                self.allocator.free(msg);
            }
        }
    }

    /// Read a single raw LSP message from stdout
    fn readRaw(self: *LSPClient) ![]const u8 {
        const proc = &self.process.?;
        const stdout = proc.stdout.?;
        var header_buf: [512]u8 = undefined;
        var header_len: usize = 0;
        while (header_len < header_buf.len) {
            ContentLength.waitReadable(stdout.handle, ContentLength.default_read_timeout_ms) catch |err| {
                if (err == error.Timeout) return error.LSPReadTimeout;
                return err;
            };
            const n = try runtime.read(stdout, header_buf[header_len .. header_len + 1]);
            if (n == 0) return error.LSPConnectionClosed;
            header_len += 1;
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
        }
        if (header_len >= header_buf.len) return error.LSPHeaderTooLarge;
        const headers = header_buf[0..header_len];
        const content_length = ContentLength.parseHeader(headers) catch |err| switch (err) {
            error.ContentLengthTooLarge => return error.LSPContentLengthTooLarge,
            error.HeaderTooLarge => return error.LSPHeaderTooLarge,
            error.BadHeader => return error.LSPBadHeader,
        };
        var body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);
        var read_total: usize = 0;
        while (read_total < content_length) {
            ContentLength.waitReadable(stdout.handle, ContentLength.default_read_timeout_ms) catch |err| {
                if (err == error.Timeout) return error.LSPReadTimeout;
                return err;
            };
            const n = try runtime.read(stdout, body[read_total..]);
            if (n == 0) return error.LSPConnectionClosed;
            read_total += n;
        }
        return body;
    }

    pub fn initialize(self: *LSPClient, root: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        var root_uri: std.Io.Writer.Allocating = .init(self.allocator);
        defer root_uri.deinit();
        try root_uri.writer.writeAll("file://");
        try root_uri.writer.writeAll(root);
        try params.writer.print("{{\"processId\":{},\"rootUri\":", .{std.os.linux.getpid()});
        try ContentLength.writeJsonString(&params.writer, root_uri.written());
        try params.writer.writeAll(",\"capabilities\":{\"textDocument\":{\"completion\":{\"dynamicRegistration\":true},\"hover\":{\"dynamicRegistration\":true},\"definition\":{\"dynamicRegistration\":true}}}}");
        try self.send("initialize", params.written());
        const resp = try self.read();
        defer self.allocator.free(resp);
        // Store server capabilities if needed for feature detection
        try self.sendNotification("initialized", "{}");
    }

    pub fn didOpen(self: *LSPClient, uri: []const u8, text: []const u8, lang: []const u8) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.writeAll(",\"languageId\":");
        try ContentLength.writeJsonString(writer, lang);
        try writer.writeAll(",\"version\":1,\"text\":");
        try ContentLength.writeJsonString(writer, text);
        try writer.writeAll("}}");
        try self.sendNotification("textDocument/didOpen", params.written());
    }

    pub fn didChange(self: *LSPClient, uri: []const u8, text: []const u8, version: u64) !void {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.print(",\"version\":{}}},\"contentChanges\":[{{\"text\":", .{version});
        try ContentLength.writeJsonString(writer, text);
        try writer.writeAll("}]}");
        try self.sendNotification("textDocument/didChange", params.written());
    }

    pub fn didSave(self: *LSPClient, uri: []const u8) !void {
        const params = try documentUriParams(self.allocator, uri);
        defer self.allocator.free(params);
        try self.sendNotification("textDocument/didSave", params);
    }

    pub fn didClose(self: *LSPClient, uri: []const u8) !void {
        const params = try documentUriParams(self.allocator, uri);
        defer self.allocator.free(params);
        try self.sendNotification("textDocument/didClose", params);
    }

    pub fn completion(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const params = try documentPositionParams(self.allocator, uri, line, col);
        defer self.allocator.free(params);
        try self.send("textDocument/completion", params);
        return try self.read();
    }

    pub fn completionItemsJson(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const resp = try self.completion(uri, line, col);
        defer self.allocator.free(resp);
        return self.extractCompletionItemsJson(resp) catch try self.allocator.dupe(u8, "[]");
    }

    pub fn hover(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const params = try documentPositionParams(self.allocator, uri, line, col);
        defer self.allocator.free(params);
        try self.send("textDocument/hover", params);
        return try self.read();
    }

    pub fn hoverText(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const resp = try self.hover(uri, line, col);
        defer self.allocator.free(resp);
        return self.extractHoverText(resp) catch try self.allocator.dupe(u8, "");
    }

    fn documentUriParams(allocator: Allocator, uri: []const u8) ![]u8 {
        var params: std.Io.Writer.Allocating = .init(allocator);
        errdefer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.writeAll("}}");
        return try params.toOwnedSlice();
    }

    fn documentPositionParams(allocator: Allocator, uri: []const u8, line: usize, col: usize) ![]u8 {
        var params: std.Io.Writer.Allocating = .init(allocator);
        errdefer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.print("}},\"position\":{{\"line\":{},\"character\":{}}}}}", .{ line, col });
        return try params.toOwnedSlice();
    }

    test "LSP document parameter builders escape URI and position payloads" {
        const uri_params = try documentUriParams(std.testing.allocator, "file:///tmp/a\\\"b");
        defer std.testing.allocator.free(uri_params);
        try std.testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///tmp/a\\\\\\\"b\"}}", uri_params);

        const position_params = try documentPositionParams(std.testing.allocator, "file:///tmp/line\n", 4, 9);
        defer std.testing.allocator.free(position_params);
        try std.testing.expectEqualStrings("{\"textDocument\":{\"uri\":\"file:///tmp/line\\n\"},\"position\":{\"line\":4,\"character\":9}}", position_params);
    }

    pub fn definition(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const params = try documentPositionParams(self.allocator, uri, line, col);
        defer self.allocator.free(params);
        try self.send("textDocument/definition", params);
        return try self.read();
    }

    pub fn signatureHelp(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const params = try documentPositionParams(self.allocator, uri, line, col);
        defer self.allocator.free(params);
        try self.send("textDocument/signatureHelp", params);
        return try self.read();
    }

    pub fn signatureHelpJson(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const resp = try self.signatureHelp(uri, line, col);
        defer self.allocator.free(resp);
        return self.extractSignatureHelpJson(resp) catch try self.allocator.dupe(u8, "null");
    }

    pub fn references(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        const base = try documentPositionParams(self.allocator, uri, line, col);
        defer self.allocator.free(base);
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        try params.writer.writeAll(base[0 .. base.len - 1]);
        try params.writer.writeAll(",\"context\":{\"includeDeclaration\":true}}");
        try self.send("textDocument/references", params.written());
        return try self.read();
    }

    pub fn rename(self: *LSPClient, uri: []const u8, line: usize, col: usize, new_name: []const u8) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.print("}},\"position\":{{\"line\":{},\"character\":{}}},\"newName\":", .{ line, col });
        try ContentLength.writeJsonString(writer, new_name);
        try writer.writeByte('}');
        try self.send("textDocument/rename", params.written());
        return try self.read();
    }

    pub fn codeAction(self: *LSPClient, uri: []const u8, line: usize, col: usize) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.print("}},\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"context\":{{\"diagnostics\":[]}}}}", .{ line, col, line, col });
        try self.send("textDocument/codeAction", params.written());
        return try self.read();
    }

    pub fn inlayHint(self: *LSPClient, uri: []const u8) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"textDocument\":{\"uri\":");
        try ContentLength.writeJsonString(writer, uri);
        try writer.writeAll("},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":99999,\"character\":99999}}}");
        try self.send("textDocument/inlayHint", params.written());
        return try self.read();
    }

    pub fn documentSymbol(self: *LSPClient, uri: []const u8) ![]const u8 {
        const params = try documentUriParams(self.allocator, uri);
        defer self.allocator.free(params);
        try self.send("textDocument/documentSymbol", params);
        return try self.read();
    }

    pub fn workspaceSymbol(self: *LSPClient, query: []const u8) ![]const u8 {
        var params: std.Io.Writer.Allocating = .init(self.allocator);
        defer params.deinit();
        const writer = &params.writer;
        try writer.writeAll("{\"query\":");
        try ContentLength.writeJsonString(writer, query);
        try writer.writeByte('}');
        try self.send("workspace/symbol", params.written());
        return try self.read();
    }

    fn extractSignatureHelpJson(self: *LSPClient, resp: []const u8) ![]const u8 {
        try self.rejectRpcError(resp);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = try json_mod.parseFromSlice(json_mod.Value, arena.allocator(), resp, .{});
        const root = parsed.value;
        const result_val = switch (root) {
            .object => |o| o.get("result") orelse return error.BadLspResponse,
            else => return error.BadLspResponse,
        };
        var tmp_buf: [8192]u8 = undefined;
        var io_writer = std.Io.Writer.fixed(&tmp_buf);
        try json_mod.Stringify.value(result_val, .{}, &io_writer);
        var buf = std.array_list.Managed(u8).init(self.allocator);
        errdefer buf.deinit();
        try buf.appendSlice(tmp_buf[0..io_writer.end]);
        return try buf.toOwnedSlice();
    }

    fn extractCompletionItemsJson(self: *LSPClient, resp: []const u8) ![]const u8 {
        try self.rejectRpcError(resp);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = try json_mod.parseFromSlice(json_mod.Value, arena.allocator(), resp, .{});
        const root = parsed.value;

        const result_val = switch (root) {
            .object => |o| o.get("result") orelse return error.BadLspResponse,
            else => return error.BadLspResponse,
        };

        const items_val = switch (result_val) {
            .array => result_val,
            .object => |o| o.get("items") orelse return error.BadLspResponse,
            else => return error.BadLspResponse,
        };

        var tmp_buf: [8192]u8 = undefined;
        var io_writer = std.Io.Writer.fixed(&tmp_buf);
        try json_mod.Stringify.value(items_val, .{}, &io_writer);
        var buf = std.array_list.Managed(u8).init(self.allocator);
        errdefer buf.deinit();
        try buf.appendSlice(tmp_buf[0..io_writer.end]);
        return try buf.toOwnedSlice();
    }

    fn extractHoverText(self: *LSPClient, resp: []const u8) ![]const u8 {
        try self.rejectRpcError(resp);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = try json_mod.parseFromSlice(json_mod.Value, arena.allocator(), resp, .{});
        const root = parsed.value;

        const result_val = switch (root) {
            .object => |o| o.get("result") orelse return error.BadLspResponse,
            else => return error.BadLspResponse,
        };

        const contents_val = switch (result_val) {
            .object => |o| o.get("contents") orelse return error.BadLspResponse,
            else => return error.BadLspResponse,
        };

        const text: []const u8 = switch (contents_val) {
            .string => |s| s,
            .object => |o| if (o.get("value")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "",
            .array => |a| if (a.items.len > 0) switch (a.items[0]) {
                .string => |s| s,
                .object => |o| if (o.get("value")) |v| switch (v) {
                    .string => |s| s,
                    else => "",
                } else "",
                else => "",
            } else "",
            else => "",
        };

        return try self.allocator.dupe(u8, text);
    }

    fn rejectRpcError(self: *LSPClient, resp: []const u8) !void {
        const rpc_error = try ContentLength.parseRpcError(self.allocator, resp) orelse return;
        defer self.allocator.free(rpc_error.message);
        return error.BadLspResponse;
    }

    /// Poll for pending server to client notifications without blocking.
    /// Call this from the editor render loop to receive diagnostics.
    pub fn pollNotifications(self: *LSPClient) void {
        const proc = self.process orelse return;
        const stdout = proc.stdout orelse return;

        // Acquire mutex — if another thread is mid-read, skip this poll
        if (!self.lsp_mutex.tryLock()) return;
        defer self.lsp_mutex.unlock();

        const fd = stdout.handle;
        while (true) {
            ContentLength.waitReadable(fd, 0) catch return;
            const msg = self.readLocked() catch {
                return;
            };
            defer self.allocator.free(msg);

            if (std.mem.indexOf(u8, msg, "\"method\"")) |m_start| {
                if (std.mem.indexOfScalarPos(u8, msg, m_start + 8, '"')) |v0| {
                    if (std.mem.indexOfScalarPos(u8, msg, v0 + 1, '"')) |v1| {
                        const method = msg[v0 + 1 .. v1];
                        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                            self.handlePublishDiagnostics(msg) catch {};
                        }
                    }
                }
            }
        }
    }

    /// Parse a textDocument/publishDiagnostics notification and store diagnostics
    fn handlePublishDiagnostics(self: *LSPClient, json: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = try json_mod.parseFromSlice(json_mod.Value, arena.allocator(), json, .{});
        const root = parsed.value;
        const obj = switch (root) {
            .object => |o| o,
            else => return,
        };

        const uri = switch (obj.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };
        const diags_arr = switch (obj.get("diagnostics") orelse return) {
            .array => |a| a,
            else => return,
        };

        var diags = std.array_list.Managed(Diagnostic).init(self.allocator);
        errdefer {
            for (diags.items) |d| self.allocator.free(d.message);
            diags.deinit();
        }

        for (diags_arr.items) |diag_val| {
            const d = switch (diag_val) {
                .object => |o| o,
                else => continue,
            };
            const message = switch (d.get("message") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const severity = if (d.get("severity")) |sv| switch (sv) {
                .integer => |i| @as(DiagnosticSeverity, @fromBackingInt(@intCast(i))),
                else => null,
            } else null;
            const range_obj = switch (d.get("range") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const start_obj = switch (range_obj.get("start") orelse continue) {
                .object => |o| o,
                else => continue,
            };
            const line_val = switch (start_obj.get("line") orelse continue) {
                .integer => |i| i,
                else => continue,
            };
            const char_val = switch (start_obj.get("character") orelse continue) {
                .integer => |i| i,
                else => continue,
            };
            const line = std.math.cast(usize, line_val) orelse 0;
            const chr = std.math.cast(usize, char_val) orelse 0;

            try diags.append(.{
                .range = .{ .start = .{ .line = line, .character = chr }, .end = .{ .line = line, .character = chr } },
                .severity = severity,
                .message = try self.allocator.dupe(u8, message),
            });
        }

        // Replace diagnostics for this URI
        // Free old diagnostics entry if it exists
        if (self.diagnostics.fetchRemove(uri)) |entry| {
            for (entry.value) |d| self.allocator.free(d.message);
            self.allocator.free(entry.value);
            self.allocator.free(entry.key);
        }
        const uri_key = try self.allocator.dupe(u8, uri);
        try self.diagnostics.put(self.allocator, uri_key, try diags.toOwnedSlice());
    }

    /// Get diagnostics for a file URI (call from editor gutter rendering)
    pub fn getDiagnostics(self: *LSPClient, uri: []const u8) []const Diagnostic {
        return self.diagnostics.get(uri) orelse &.{};
    }

    pub fn shutdown(self: *LSPClient) void {
        if (self.process) |*p| {
            p.kill(runtime.io());
            self.process = null;
        }
    }
    pub fn deinit(self: *LSPClient) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.shutdown();
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |d| {
                self.allocator.free(d.message);
            }
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(self.allocator);
    }

    test "LSP deinit is safe before a server starts" {
        var client = LSPClient.init(std.testing.allocator);
        client.shutdown();
        client.deinit();
    }

    test "LSP deinit terminates a live child process" {
        if (builtin.os.tag == .windows) return;
        var client = LSPClient.init(std.testing.allocator);
        try client.start("/bin/sh", &.{ "-c", "sleep 30" });
        client.deinit();
        try std.testing.expect(client.process == null);
    }
};

test "LSP completion item extraction" {
    var client = LSPClient.init(std.testing.allocator);
    const resp =
        \\{"jsonrpc":"2.0","id":1,"result":{"isIncomplete":false,"items":[{"label":"std","kind":9},{"label":"std.mem","kind":9}]}}
    ;
    const items_json = try client.extractCompletionItemsJson(resp);
    defer std.testing.allocator.free(items_json);
    try std.testing.expectEqualStrings("[{\"label\":\"std\",\"kind\":9},{\"label\":\"std.mem\",\"kind\":9}]", items_json);
}

test "LSP hover text extraction" {
    var client = LSPClient.init(std.testing.allocator);
    const resp =
        \\{"jsonrpc":"2.0","id":1,"result":{"contents":{"kind":"markdown","value":"**foo**\\nbar"}}}
    ;
    const text = try client.extractHoverText(resp);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("**foo**\\nbar", text);
}
