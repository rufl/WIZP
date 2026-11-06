// LLM integration for WIZP - OpenRouter, DeepSeek, Ollama, llama.cpp, OpenAI-compatible APIs
// Reuses patterns from zaica (SSE streaming, HTTP client)

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

/// LLM provider types
pub const Provider = enum {
    openrouter,
    deepseek,
    openai,
    anthropic,
    ollama, // Local Ollama (http://localhost:11434)
    llamacpp, // llama.cpp server (OpenAI-compatible)
    custom,
};

/// LLM configuration
pub const LLMConfig = struct {
    provider: Provider = .openrouter,
    api_key: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    model: []const u8 = "openai/gpt-4o-mini",
    temperature: f32 = 0.7,
    max_tokens: usize = 4096,
    top_p: f32 = 1.0,
    /// Ollama-specific: keep model loaded in memory
    keep_alive: ?[]const u8 = null,
};

/// Get default model for each provider
pub fn defaultModel(provider: Provider) []const u8 {
    return switch (provider) {
        .openrouter => "openai/gpt-4o-mini",
        .deepseek => "deepseek-chat",
        .openai => "gpt-4o-mini",
        .anthropic => "claude-3-5-sonnet-20241022",
        .ollama => "codellama:7b",
        .llamacpp => "local-model",
        .custom => "gpt-4o-mini",
    };
}

/// Get default API base for each provider
pub fn defaultApiBase(provider: Provider) []const u8 {
    return switch (provider) {
        .openrouter => "https://openrouter.ai/api/v1",
        .deepseek => "https://api.deepseek.com/v1",
        .openai => "https://api.openai.com/v1",
        .anthropic => "https://api.anthropic.com/v1",
        .ollama => "http://localhost:11434/api",
        .llamacpp => "http://localhost:8080/v1",
        .custom => "http://localhost:8080/v1",
    };
}

/// Chat message
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub const Role = enum { system, user, assistant, tool };

    pub const ToolCall = struct {
        id: []const u8,
        function: Function,
        pub const Function = struct { name: []const u8, arguments: []const u8 };
    };
};

/// LLM completion request
pub const CompletionRequest = struct {
    messages: []const Message,
    tools: ?[]const ToolDef = null,
    stream: bool = true,

    pub const ToolDef = struct {
        type_: []const u8 = "function",
        function: FunctionDef,
        pub const FunctionDef = struct {
            name: []const u8,
            description: []const u8,
            parameters: []const u8, // JSON Schema as string
        };
    };
};

/// LLM completion response
pub const CompletionResponse = struct {
    content: []const u8,
    tool_calls: ?[]const Message.ToolCall = null,
    finish_reason: []const u8 = "stop",
    usage: ?TokenUsage = null,

    pub const TokenUsage = struct {
        prompt_tokens: usize,
        completion_tokens: usize,
        total_tokens: usize,
    };
};

/// SSE event from streaming response
pub const SSEEvent = struct {
    event: ?[]const u8 = null,
    data: []const u8,
};

/// Streaming callback: called for each token as it arrives
pub const StreamCallback = *const fn (token: []const u8) void;

/// LLM client
pub const LLMClient = struct {
    allocator: Allocator,
    config: LLMConfig,
    client: http.Client,

    const Self = @This();

    pub fn init(allocator: Allocator, config: LLMConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .client = http.Client{
                .allocator = allocator,
                .io = @import("../runtime_016.zig").io(),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    /// Get the API base URL for the configured provider
    pub fn getApiBase(self: *Self) []const u8 {
        if (self.config.api_base) |base| return base;
        return defaultApiBase(self.config.provider);
    }

    /// Get the chat completions endpoint
    pub fn getChatEndpoint(self: *Self) ![]const u8 {
        const base = self.getApiBase();
        // Ollama uses /api/chat, others use /chat/completions
        if (self.config.provider == .ollama) {
            return try std.fmt.allocPrint(self.allocator, "{s}/chat", .{base});
        }
        return try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{base});
    }

    /// Build JSON request body for chat completion
    pub fn buildRequestBody(self: *Self, req: CompletionRequest) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        const w = &buf.writer;

        try w.writeAll("{");
        try w.print("\"model\":\"{s}\"", .{self.config.model});
        try w.print(",\"temperature\":{d}", .{self.config.temperature});
        try w.print(",\"max_tokens\":{}", .{self.config.max_tokens});
        try w.print(",\"top_p\":{d}", .{self.config.top_p});
        try w.print(",\"stream\":{}", .{req.stream});

        // Messages
        try w.writeAll(",\"messages\":[");
        for (req.messages, 0..) |msg, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{");
            try w.print("\"role\":\"{s}\"", .{@tagName(msg.role)});
            try w.print(",\"content\":", .{});
            try writeJsonString(w, msg.content);

            if (msg.tool_calls) |tc| {
                try w.writeAll(",\"tool_calls\":[");
                for (tc, 0..) |call, j| {
                    if (j > 0) try w.writeAll(",");
                    try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ call.id, call.function.name, call.function.arguments });
                }
                try w.writeAll("]");
            }
            if (msg.tool_call_id) |tcid| {
                try w.print(",\"tool_call_id\":\"{s}\"", .{tcid});
            }
            try w.writeAll("}");
        }
        try w.writeAll("]");

        // Tools
        if (req.tools) |tools| {
            try w.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{ tool.function.name, tool.function.description, tool.function.parameters });
            }
            try w.writeAll("]");
        }

        try w.writeAll("}");
        return buf.toOwnedSlice();
    }

    /// Send a non-streaming chat completion request
    pub fn complete(self: *Self, req: CompletionRequest) !CompletionResponse {
        const body = try self.buildRequestBody(req);
        defer self.allocator.free(body);

        const endpoint = try self.getChatEndpoint();
        defer self.allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);

        var header_buf: [4]http.Header = undefined;
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
        var auth_buf: [256]u8 = undefined;
        if (self.config.api_key) |key| {
            const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key});
            header_buf[header_count] = .{ .name = "Authorization", .value = auth };
            header_count += 1;
        }

        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();
        _ = try self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = body,
            .extra_headers = header_buf[0..header_count],
            .response_writer = &response_body.writer,
        });

        return parseResponse(self.allocator, response_body.written());
    }

    /// Stream a chat completion, calling callback for each token
    pub fn streamComplete(self: *Self, req: CompletionRequest, callback: StreamCallback) !CompletionResponse {
        var stream_req = req;
        stream_req.stream = true;
        const body = try self.buildRequestBody(stream_req);
        defer self.allocator.free(body);

        const endpoint = try self.getChatEndpoint();
        defer self.allocator.free(endpoint);

        const uri = try std.Uri.parse(endpoint);

        var header_buf: [4]http.Header = undefined;
        var header_count: usize = 0;
        header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
        var auth_buf: [256]u8 = undefined;
        if (self.config.api_key) |key| {
            const auth = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key});
            header_buf[header_count] = .{ .name = "Authorization", .value = auth };
            header_count += 1;
        }

        var request = try self.client.request(.POST, uri, .{
            .extra_headers = header_buf[0..header_count],
        });
        defer request.deinit();
        try request.sendBodyComplete(@constCast(body));
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var response = try request.receiveHead(&server_header_buffer);
        var transfer_buffer: [4096]u8 = undefined;
        const response_reader = response.reader(&transfer_buffer);

        // Read and parse SSE stream
        var pending = std.array_list.Managed(u8).init(self.allocator);
        defer pending.deinit();
        var full_content = std.array_list.Managed(u8).init(self.allocator);
        var buf: [4096]u8 = undefined;
        var done: bool = false;

        while (!done) {
            const n = try response_reader.readSliceShort(&buf);
            if (n == 0) break;
            const chunk = buf[0..n];
            try parseSSEChunk(self.allocator, &pending, &full_content, chunk, callback, &done);
        }

        return CompletionResponse{
            .content = try full_content.toOwnedSlice(),
            .finish_reason = "stop",
        };
    }

    pub fn close(self: *Self) void {
        self.deinit();
    }
};

/// Write a JSON-escaped string
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            1...7 => try writer.print("\\u00{}", .{c}),
            11, 12, 14...31 => try writer.print("\\u00{x}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Simple JSON response parser
fn parseResponse(allocator: Allocator, body: []const u8) !CompletionResponse {
    const Payload = struct {
        const Choice = struct {
            message: ?struct { content: ?[]const u8 = null } = null,
        };

        choices: []Choice = &[_]Choice{},
        @"error": ?struct { message: ?[]const u8 = null } = null,
    };

    var parsed = std.json.parseFromSlice(Payload, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return CompletionResponse{ .content = try allocator.dupe(u8, body), .finish_reason = "stop" };
    };
    defer parsed.deinit();

    if (parsed.value.@"error") |e| {
        const msg = e.message orelse "LLM API error";
        return CompletionResponse{ .content = try allocator.dupe(u8, msg), .finish_reason = "error" };
    }

    if (parsed.value.choices.len > 0) {
        if (parsed.value.choices[0].message) |m| {
            if (m.content) |c| {
                return CompletionResponse{ .content = try allocator.dupe(u8, c), .finish_reason = "stop" };
            }
        }
    }

    return CompletionResponse{ .content = try allocator.dupe(u8, body), .finish_reason = "stop" };
}

fn parseSSEChunk(allocator: Allocator, pending: *std.array_list.Managed(u8), full_content: *std.array_list.Managed(u8), chunk: []const u8, callback: StreamCallback, done: *bool) !void {
    try pending.appendSlice(chunk);

    var consumed: usize = 0;
    while (true) {
        const remaining = pending.items[consumed..];
        var delim_len: usize = 0;
        const delim_pos = if (std.mem.indexOf(u8, remaining, "\r\n\r\n")) |p| blk: {
            delim_len = 4;
            break :blk p;
        } else if (std.mem.indexOf(u8, remaining, "\n\n")) |p| blk: {
            delim_len = 2;
            break :blk p;
        } else null;

        if (delim_pos == null) break;
        const pos = delim_pos.?;
        const event_text = remaining[0..pos];
        consumed += pos + delim_len;

        var lines = std.mem.splitScalar(u8, event_text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (!std.mem.startsWith(u8, line, "data:")) continue;
            const data = std.mem.trimStart(u8, line[5..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                done.* = true;
                break;
            }

            const Payload = struct {
                const Choice = struct {
                    delta: ?struct { content: ?[]const u8 = null } = null,
                    message: ?struct { content: ?[]const u8 = null } = null,
                };
                choices: []Choice = &[_]Choice{},
            };

            var parsed = std.json.parseFromSlice(Payload, allocator, data, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();

            if (parsed.value.choices.len == 0) continue;
            const choice0 = parsed.value.choices[0];
            const token_opt: ?[]const u8 = if (choice0.delta) |d| d.content else if (choice0.message) |m| m.content else null;
            if (token_opt) |token| {
                try full_content.appendSlice(token);
                callback(token);
            }
        }

        if (done.*) break;
    }

    if (consumed > 0) {
        const remaining_len = pending.items.len - consumed;
        std.mem.copyForwards(u8, pending.items[0..remaining_len], pending.items[consumed..]);
        pending.shrinkRetainingCapacity(remaining_len);
    }
}

test "LLM: parseResponse extracts assistant message content" {
    const testing = std.testing;

    const body = "{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}";
    const resp = try parseResponse(testing.allocator, body);
    defer testing.allocator.free(resp.content);
    try testing.expectEqualStrings("hello", resp.content);
    try testing.expectEqualStrings("stop", resp.finish_reason);
}

test "LLM: parseResponse surfaces error message" {
    const testing = std.testing;

    const body = "{\"error\":{\"message\":\"bad key\"}}";
    const resp = try parseResponse(testing.allocator, body);
    defer testing.allocator.free(resp.content);
    try testing.expectEqualStrings("bad key", resp.content);
    try testing.expectEqualStrings("error", resp.finish_reason);
}

test "LLM: SSE parsing handles \\r\\n\\r\\n and chunk boundaries" {
    const testing = std.testing;

    const Noop = struct {
        fn f(_: []const u8) void {}
    };
    const noop: StreamCallback = &Noop.f;

    var pending = std.array_list.Managed(u8).init(testing.allocator);
    defer pending.deinit();
    var full = std.array_list.Managed(u8).init(testing.allocator);
    defer full.deinit();
    var done: bool = false;

    const p1a = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\r\n\r\n";
    const p1b = "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\r\n\r\n";
    const p2 = "data: [DONE]\r\n\r\n";
    const all = p1a ++ p1b ++ p2;

    try parseSSEChunk(testing.allocator, &pending, &full, all[0..20], noop, &done);
    try testing.expect(!done);
    try parseSSEChunk(testing.allocator, &pending, &full, all[20..55], noop, &done);
    try testing.expect(!done);
    try parseSSEChunk(testing.allocator, &pending, &full, all[55..], noop, &done);
    try testing.expect(done);
    try testing.expectEqualStrings("Hello", full.items);
}
