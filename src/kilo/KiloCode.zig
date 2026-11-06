// Kilo Code AI Assistant port for WIZP
// Native Zig implementation of AI-powered coding assistant
// Features: inline completions, chat, code actions, context gathering

const std = @import("std");
const Allocator = std.mem.Allocator;
const LLM = @import("../llm/LLM.zig");

/// AI completion request context
pub const CompletionContext = struct {
    /// Text before cursor
    prefix: []const u8,
    /// Text after cursor
    suffix: []const u8,
    /// Current file path
    file_path: ?[]const u8 = null,
    /// Current language
    language: ?[]const u8 = null,
    /// Cursor line and column
    cursor_line: usize = 0,
    cursor_col: usize = 0,
    /// Tab stop positions (for multi-cursor)
    tab_size: usize = 4,
};

/// AI completion result
pub const Completion = struct {
    /// The completion text
    text: []const u8,
    /// Display text (may differ from inserted text)
    display_text: ?[]const u8 = null,
    /// Range to replace in buffer
    range: ?CompletionRange = null,
    /// Provider that generated this
    provider: CompletionProvider = .llm,

    pub const CompletionRange = struct {
        start_line: usize,
        start_col: usize,
        end_line: usize,
        end_col: usize,
    };

    pub const CompletionProvider = enum {
        llm,
        lsp,
        snippet,
        path,
        word,
    };
};

/// Chat message in conversation
pub const ChatMessage = struct {
    role: Role,
    content: []const u8,
    timestamp: i64,

    pub const Role = enum { user, assistant, system, err_msg };
};

/// Code action types
pub const CodeAction = enum {
    explain, // Explain selected code
    fix, // Fix bugs in selected code
    improve, // Improve/refactor selected code
    document, // Add documentation
    gen_test, // Generate tests
    review, // Code review
    complete, // Complete/inline suggestion
    chat, // Chat about code
};

/// Chat session configuration
pub const ChatConfig = struct {
    model: []const u8 = "openai/gpt-4o-mini",
    temperature: f32 = 0.7,
    max_tokens: usize = 4096,
    top_p: f32 = 1.0,
    top_k: usize = 0,
    system_prompt: []const u8 = "You are an expert software engineer AI assistant.",
    include_context: bool = true,
    stream: bool = true,
};

/// AI edit result with diff preview
pub const AIEditResult = struct {
    original: []const u8,
    modified: []const u8,
    diff_lines: std.array_list.Managed(AIEditResult.DiffLine),
    accepted: bool = false,

    pub const DiffLine = struct {
        kind: enum { unchanged, added, removed },
        text: []const u8,
    };
};

/// Prompt template for common tasks
pub const PromptTemplate = struct {
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    user_prompt_template: []const u8, // {code} placeholder
};

/// Token usage tracking
pub const TokenUsage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    cost_usd: f32 = 0.0,
};

/// Project context collected for AI
pub const ProjectContext = struct {
    /// Current file content
    current_file: ?FileContext = null,
    /// Open files (paths and content summaries)
    open_files: std.array_list.Managed(FileContext),
    /// Project structure (file tree)
    project_structure: ?[]const u8 = null,
    /// Git diff (if available)
    git_diff: ?[]const u8 = null,
    /// Current selection
    selection: ?[]const u8 = null,
    /// Language server diagnostics
    diagnostics: std.array_list.Managed(DiagnosticInfo),

    pub const FileContext = struct {
        path: []const u8,
        content: []const u8,
        language: []const u8 = "",
        cursor_line: usize = 0,
    };

    pub const DiagnosticInfo = struct {
        file: []const u8,
        line: usize,
        col: usize,
        message: []const u8,
        severity: []const u8 = "error",
    };
};

/// Kilo Code AI Assistant
pub const KiloCode = struct {
    allocator: Allocator,
    llm_client: LLM.LLMClient,
    config: ChatConfig,
    /// Conversation history
    chat_history: std.array_list.Managed(ChatMessage),
    /// Completion cache (debounce)
    completion_cache: std.StringHashMapUnmanaged([]const u8),
    /// Last completion request time
    last_completion_time: i64 = 0,
    /// Completion debounce ms
    debounce_ms: i64 = 300,
    /// Whether AI is currently generating
    generating: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator, llm_config: LLM.LLMConfig) !Self {
        return Self{
            .allocator = allocator,
            .llm_client = LLM.LLMClient.init(allocator, llm_config),
            .config = .{
                .model = llm_config.model,
                .temperature = llm_config.temperature,
                .max_tokens = llm_config.max_tokens,
            },
            .chat_history = std.array_list.Managed(ChatMessage).init(allocator),
            .completion_cache = .{},
        };
    }

    // ============================================================
    // Inline Completions
    // ============================================================

    /// Request an inline completion at cursor position
    pub fn getInlineCompletion(self: *Self, ctx: CompletionContext) !?Completion {
        // Debounce: don't request if too soon
        const now = @import("../runtime_016.zig").milliTimestamp();
        if (now - self.last_completion_time < self.debounce_ms) {
            return null;
        }
        self.last_completion_time = now;

        // Build completion prompt
        const prompt = try self.buildCompletionPrompt(ctx);
        defer self.allocator.free(prompt);

        // Request from LLM
        const messages = [_]LLM.Message{
            .{ .role = .system, .content = self.buildCompletionSystemPrompt(ctx) },
            .{ .role = .user, .content = prompt },
        };

        const req = LLM.CompletionRequest{
            .messages = &messages,
            .stream = false,
        };

        const response = try self.llm_client.complete(req);
        const completion_text = try self.extractCompletion(response.content, ctx);
        if (completion_text.len == 0) return null;

        return Completion{
            .text = completion_text,
            .provider = .llm,
        };
    }

    /// Stream inline completion tokens
    pub fn streamInlineCompletion(self: *Self, ctx: CompletionContext, on_token: *const fn ([]const u8) void) !void {
        const prompt = try self.buildCompletionPrompt(ctx);
        defer self.allocator.free(prompt);

        const messages = [_]LLM.Message{
            .{ .role = .system, .content = self.buildCompletionSystemPrompt(ctx) },
            .{ .role = .user, .content = prompt },
        };

        const req = LLM.CompletionRequest{
            .messages = &messages,
            .stream = true,
        };

        _ = try self.llm_client.streamComplete(req, on_token);
    }

    /// Build completion-specific system prompt
    fn buildCompletionSystemPrompt(_: *Self, _: CompletionContext) []const u8 {
        return "You are a code completion AI. Complete the code at the cursor position. " ++
            "Output ONLY the completion text without any explanation. " ++
            "Match the existing code style, indentation, and conventions. " ++
            "Do not repeat code that already appears before the cursor.";
    }

    /// Build the completion prompt with Fill-in-the-Middle format
    fn buildCompletionPrompt(self: *Self, ctx: CompletionContext) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);

        // Use FIM (Fill-in-the-Middle) format
        try buf.appendSlice("<PRE>\n");
        try buf.appendSlice(ctx.prefix);
        try buf.appendSlice("\n<SUF>\n");
        try buf.appendSlice(ctx.suffix);
        try buf.appendSlice("\n<MID>");

        return buf.toOwnedSlice();
    }

    /// Extract just the completion from LLM response.
    /// Strips repeated prefix/suffix content and markdown fences.
    fn extractCompletion(self: *Self, response: []const u8, ctx: CompletionContext) ![]const u8 {
        var text = response;

        // Remove markdown code fences
        if (std.mem.startsWith(u8, text, "```")) {
            if (std.mem.indexOfScalarPos(u8, text, 3, '\n')) |newline| {
                text = text[newline + 1 ..];
            }
        }
        if (std.mem.endsWith(u8, text, "```")) {
            text = text[0 .. text.len - 3];
        }

        // Strip suffix if the model repeated it (common with FIM models)
        if (ctx.suffix.len > 0) {
            if (std.mem.indexOf(u8, text, ctx.suffix)) |suf_pos| {
                text = text[0..suf_pos];
            }
        }

        // Strip common prefix repetition (model echoed the last line of prefix)
        if (ctx.prefix.len > 0) {
            var prefix_iter = std.mem.splitScalar(u8, ctx.prefix, '\n');
            var last_line: []const u8 = "";
            while (prefix_iter.next()) |line| last_line = line;
            if (last_line.len > 0 and std.mem.startsWith(u8, text, last_line)) {
                text = text[last_line.len..];
            }
        }

        return try self.allocator.dupe(u8, std.mem.trim(u8, text, " \t\n\r"));
    }

    // ============================================================
    // Code Actions
    // ============================================================

    /// Execute a code action on selected text
    pub fn executeCodeAction(self: *Self, action: CodeAction, selected_text: []const u8, context: ProjectContext) ![]const u8 {
        const system_prompt = switch (action) {
            .explain => "You are a code explanation expert. Explain the following code clearly and concisely.",
            .fix => "You are a bug-fixing expert. Fix all bugs in the following code. Output ONLY the corrected code.",
            .improve => "You are a code optimization expert. Improve the following code for better performance, readability, and maintainability. Output ONLY the improved code.",
            .document => "You are a documentation expert. Add comprehensive documentation comments to the following code. Output the code WITH added documentation.",
            .gen_test => "You are a testing expert. Generate comprehensive unit tests for the following code. Output ONLY the test code.",
            .review => "You are a code review expert. Review the following code and provide detailed feedback on bugs, style, performance, and security.",
            .complete => "Complete the following code fragment. Output ONLY the completion.",
            .chat => self.config.system_prompt,
        };

        const user_prompt = try self.buildCodeActionPrompt(action, selected_text, context);
        defer self.allocator.free(user_prompt);

        const messages = [_]LLM.Message{
            .{ .role = .system, .content = system_prompt },
            .{ .role = .user, .content = user_prompt },
        };

        var req = LLM.CompletionRequest{
            .messages = &messages,
            .stream = false,
        };

        // For code modifications, set appropriate temperature
        switch (action) {
            .fix, .improve, .document, .gen_test, .complete => {
                req.stream = false;
            },
            else => {},
        }

        const response = try self.llm_client.complete(req);
        return try self.allocator.dupe(u8, response.content);
    }

    /// Build prompt for a code action
    fn buildCodeActionPrompt(self: *Self, action: CodeAction, selected_text: []const u8, context: ProjectContext) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(self.allocator);

        switch (action) {
            .explain => {
                try buf.appendSlice("Explain this code:\n\n");
                try buf.appendSlice(selected_text);
            },
            .fix => {
                try buf.appendSlice("Fix all bugs, errors, and issues in this code:\n\n");
                try buf.appendSlice(selected_text);
            },
            .improve => {
                try buf.appendSlice("Improve this code for better performance, readability, and maintainability:\n\n");
                try buf.appendSlice(selected_text);
            },
            .document => {
                try buf.appendSlice("Add comprehensive documentation to this code:\n\n");
                try buf.appendSlice(selected_text);
            },
            .gen_test => {
                try buf.appendSlice("Generate comprehensive unit tests for this code:\n\n");
                try buf.appendSlice(selected_text);
            },
            .review => {
                try buf.appendSlice("Review this code and provide feedback:\n\n");
                try buf.appendSlice(selected_text);
                if (context.diagnostics.items.len > 0) {
                    try buf.appendSlice("\n\nExisting issues found:\n");
                    for (context.diagnostics.items) |diag| {
                        try buf.print("- [{s}] Line {d}: {s}\n", .{
                            diag.severity,
                            diag.line + 1,
                            diag.message,
                        });
                    }
                }
            },
            .complete => {
                try buf.appendSlice("Complete this code fragment:\n\n");
                try buf.appendSlice(selected_text);
            },
            .chat => {
                try buf.appendSlice(selected_text);
            },
        }

        // Add file context
        if (context.current_file) |cf| {
            try buf.print("\n\nFile: {s}\nLanguage: {s}\n", .{
                cf.path,
                cf.language,
            });
        }

        return buf.toOwnedSlice();
    }

    // ============================================================
    // Chat Interface
    // ============================================================

    /// Send a chat message and get response
    pub fn chat(self: *Self, user_message: []const u8, context: ?ProjectContext) ![]const u8 {
        // Add user message to history
        try self.addToHistory(.user, user_message);

        // Build messages from history
        var messages = std.array_list.Managed(LLM.Message).init(self.allocator);
        defer messages.deinit();

        // System prompt with context
        var system_msg = std.array_list.Managed(u8).init(self.allocator);
        defer system_msg.deinit();
        try system_msg.appendSlice(self.config.system_prompt);

        if (context) |ctx| {
            try self.appendContextToPrompt(&system_msg, ctx);
        }

        const system_content = try system_msg.toOwnedSlice();
        defer self.allocator.free(system_content);
        try messages.append(.{ .role = .system, .content = system_content });

        for (self.chat_history.items) |msg| {
            try messages.append(.{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .system => .system,
                    .err_msg => .user,
                },
                .content = msg.content,
            });
        }

        const req = LLM.CompletionRequest{
            .messages = messages.items,
            .stream = self.config.stream,
        };

        const response = try self.llm_client.complete(req);
        try self.addToHistory(.assistant, response.content);

        return try self.allocator.dupe(u8, response.content);
    }

    pub fn chatStream(self: *Self, user_message: []const u8, context: ?ProjectContext, on_token: *const fn ([]const u8) void) !void {
        try self.addToHistory(.user, user_message);

        var messages = std.array_list.Managed(LLM.Message).init(self.allocator);
        defer messages.deinit();

        var system_msg = std.array_list.Managed(u8).init(self.allocator);
        defer system_msg.deinit();
        try system_msg.appendSlice(self.config.system_prompt);

        if (context) |ctx| {
            try self.appendContextToPrompt(&system_msg, ctx);
        }

        const system_content = try system_msg.toOwnedSlice();
        defer self.allocator.free(system_content);
        try messages.append(.{ .role = .system, .content = system_content });

        for (self.chat_history.items) |msg| {
            try messages.append(.{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .system => .system,
                    .err_msg => .user,
                },
                .content = msg.content,
            });
        }

        const req = LLM.CompletionRequest{
            .messages = messages.items,
            .stream = true,
        };

        self.generating = true;
        defer self.generating = false;

        const response = try self.llm_client.streamComplete(req, on_token);
        try self.addToHistory(.assistant, response.content);
    }

    /// Add context information to system prompt
    fn appendContextToPrompt(_: *Self, buf: *std.array_list.Managed(u8), ctx: ProjectContext) !void {
        if (ctx.current_file) |cf| {
            try buf.print("\n\nCurrent file: {s} ({s})\nContent:\n```\n{s}\n```\n", .{
                cf.path,
                cf.language,
                cf.content,
            });
        }

        if (ctx.selection) |selection| {
            try buf.print("\nSelected code:\n```\n{s}\n```\n", .{selection});
        }

        if (ctx.open_files.items.len > 0) {
            try buf.appendSlice("\nOpen files:\n");
            for (ctx.open_files.items) |open_file| {
                try buf.print("- {s} ({s})\n", .{
                    open_file.path,
                    open_file.language,
                });
            }
        }

        if (ctx.git_diff) |diff| {
            try buf.print("\nGit diff:\n```diff\n{s}\n```\n", .{diff});
        }

        if (ctx.diagnostics.items.len > 0) {
            try buf.appendSlice("\nDiagnostics:\n");
            for (ctx.diagnostics.items) |diagnostic| {
                try buf.print("- [{s}] {s}:{d}:{d} - {s}\n", .{
                    diagnostic.severity,
                    diagnostic.file,
                    diagnostic.line + 1,
                    diagnostic.col + 1,
                    diagnostic.message,
                });
            }
        }
    }

    /// Add message to chat history
    fn addToHistory(self: *Self, role: ChatMessage.Role, content: []const u8) !void {
        const duped = try self.allocator.dupe(u8, content);
        try self.chat_history.append(.{
            .role = role,
            .content = duped,
            .timestamp = @import("../runtime_016.zig").milliTimestamp(),
        });

        // Trim history if too long (keep last 50 messages)
        while (self.chat_history.items.len > 50) {
            const removed = self.chat_history.orderedRemove(0);
            self.allocator.free(removed.content);
        }
    }

    /// Clear chat history
    pub fn clearHistory(self: *Self) void {
        for (self.chat_history.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.chat_history.clearRetainingCapacity();
    }

    // ============================================================
    // Context Gathering
    // ============================================================

    /// Gather project context for AI
    pub fn gatherContext(self: *Self, current_file: ?[]const u8, current_content: ?[]const u8, selection: ?[]const u8) !ProjectContext {
        var ctx = ProjectContext{};

        if (current_file != null and current_content != null) {
            ctx.current_file = .{
                .path = current_file.?,
                .content = current_content.?,
                .language = detectLanguage(current_file.?),
            };
        }

        if (selection) |sel| {
            ctx.selection = try self.allocator.dupe(u8, sel);
        }

        return ctx;
    }

    /// Apply AI-suggested edit to buffer, returning diff preview
    pub fn applyEdit(self: *Self, original: []const u8, modified: []const u8) !AIEditResult {
        var result = AIEditResult{
            .original = try self.allocator.dupe(u8, original),
            .modified = try self.allocator.dupe(u8, modified),
            .diff_lines = std.array_list.Managed(AIEditResult.DiffLine).init(self.allocator),
        };

        // Compute simple line-based diff
        const orig_lines = splitLines(self.allocator, original);
        defer self.allocator.free(orig_lines);
        const mod_lines = splitLines(self.allocator, modified);
        defer self.allocator.free(mod_lines);

        var oi: usize = 0;
        var mi: usize = 0;
        while (oi < orig_lines.len or mi < mod_lines.len) {
            if (oi < orig_lines.len and mi < mod_lines.len and std.mem.eql(u8, orig_lines[oi], mod_lines[mi])) {
                try result.diff_lines.append(.{ .kind = .unchanged, .text = try self.allocator.dupe(u8, orig_lines[oi]) });
                oi += 1;
                mi += 1;
            } else if (oi < orig_lines.len) {
                try result.diff_lines.append(.{ .kind = .removed, .text = try self.allocator.dupe(u8, orig_lines[oi]) });
                oi += 1;
            } else if (mi < mod_lines.len) {
                try result.diff_lines.append(.{ .kind = .added, .text = try self.allocator.dupe(u8, mod_lines[mi]) });
                mi += 1;
            }
        }

        return result;
    }

    /// Switch model at runtime
    pub fn switchModel(self: *Self, model: []const u8, api_key: ?[]const u8, api_base: ?[]const u8) void {
        self.llm_client.close();
        self.llm_client = LLM.LLMClient.init(self.allocator, .{
            .provider = self.llm_client.config.provider,
            .model = model,
            .api_key = api_key,
            .api_base = api_base,
        });
        self.config.model = model;
    }

    /// Set temperature/top_p
    pub fn setParams(self: *Self, temperature: f32, top_p: f32, max_tokens: usize) void {
        self.config.temperature = temperature;
        self.config.top_p = top_p;
        self.config.max_tokens = max_tokens;
    }

    /// Estimate token count (simple: ~4 chars per token)
    pub fn estimateTokens(text: []const u8) usize {
        return (text.len + 3) / 4;
    }

    /// Get built-in prompt templates
    pub fn getTemplates() []const PromptTemplate {
        return &.{
            .{ .name = "explain", .description = "Explain code", .system_prompt = "You are a code explanation expert.", .user_prompt_template = "Explain this code in detail:\n\n```\n{code}\n```" },
            .{ .name = "fix", .description = "Fix bugs", .system_prompt = "You are a bug-fixing expert. Output ONLY the corrected code.", .user_prompt_template = "Fix all bugs in this code:\n\n```\n{code}\n```" },
            .{ .name = "improve", .description = "Improve code", .system_prompt = "You are a code optimization expert.", .user_prompt_template = "Improve this code:\n\n```\n{code}\n```" },
            .{ .name = "document", .description = "Add docs", .system_prompt = "You are a documentation expert.", .user_prompt_template = "Add comprehensive docs to this code:\n\n```\n{code}\n```" },
            .{ .name = "tests", .description = "Generate tests", .system_prompt = "You are a testing expert.", .user_prompt_template = "Generate unit tests for this code:\n\n```\n{code}\n```" },
            .{ .name = "review", .description = "Code review", .system_prompt = "You are a code review expert.", .user_prompt_template = "Review this code:\n\n```\n{code}\n```" },
            .{ .name = "refactor", .description = "Refactor code", .system_prompt = "You are a refactoring expert.", .user_prompt_template = "Refactor this code for better structure:\n\n```\n{code}\n```" },
            .{ .name = "simplify", .description = "Simplify code", .system_prompt = "You are a code simplification expert.", .user_prompt_template = "Simplify this code:\n\n```\n{code}\n```" },
            .{ .name = "debug", .description = "Add debug prints", .system_prompt = "You are a debugging expert.", .user_prompt_template = "Add debug logging to this code:\n\n```\n{code}\n```" },
            .{ .name = "types", .description = "Add type annotations", .system_prompt = "You are a type system expert.", .user_prompt_template = "Add type annotations to this code:\n\n```\n{code}\n```" },
        };
    }

    /// Execute code action on selection using a prompt template
    pub fn executeTemplateAction(self: *Self, template: PromptTemplate, code: []const u8) ![]const u8 {
        // Replace {code} placeholder
        var prompt = std.array_list.Managed(u8).init(self.allocator);
        var i: usize = 0;
        while (i < template.user_prompt_template.len) {
            if (i + 6 <= template.user_prompt_template.len and std.mem.eql(u8, template.user_prompt_template[i .. i + 6], "{code}")) {
                try prompt.appendSlice(code);
                i += 6;
            } else {
                try prompt.append(template.user_prompt_template[i]);
                i += 1;
            }
        }

        const messages = [_]LLM.Message{
            .{ .role = .system, .content = template.system_prompt },
            .{ .role = .user, .content = prompt.items },
        };

        const req = LLM.CompletionRequest{ .messages = &messages, .stream = false };
        const response = try self.llm_client.complete(req);
        return try self.allocator.dupe(u8, response.content);
    }

    pub fn deinit(self: *Self) void {
        self.clearHistory();
        self.llm_client.close();
        var it = self.completion_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.completion_cache.deinit(self.allocator);
    }
};

fn splitLines(allocator: std.mem.Allocator, text: []const u8) []const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        lines.append(allocator.dupe(u8, line) catch continue) catch continue;
    }
    return lines.toOwnedSlice() catch &.{};
}

/// Detect language from file extension
fn detectLanguage(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".zig")) return "zig";
    if (std.mem.eql(u8, ext, ".rs")) return "rust";
    if (std.mem.eql(u8, ext, ".py")) return "python";
    if (std.mem.eql(u8, ext, ".js")) return "javascript";
    if (std.mem.eql(u8, ext, ".ts")) return "typescript";
    if (std.mem.eql(u8, ext, ".go")) return "go";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
    if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) return "cpp";
    if (std.mem.eql(u8, ext, ".java")) return "java";
    if (std.mem.eql(u8, ext, ".rb")) return "ruby";
    if (std.mem.eql(u8, ext, ".lua")) return "lua";
    if (std.mem.eql(u8, ext, ".sh")) return "bash";
    return "";
}
