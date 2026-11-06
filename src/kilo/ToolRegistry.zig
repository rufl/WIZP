// Kilo Code Tool Registry for WIZP
// Complete AI agent tool system: read, write, edit, bash, grep, glob, webfetch, etc.
// Uses std.json for argument parsing instead of ad-hoc string-search.

const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("../runtime_016.zig");

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

pub const ToolPermission = enum { allow, deny, ask };

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
    permission: ToolPermission = .ask,
    requires_approval: bool = true,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8 = "",
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: ToolResult, allocator: Allocator) void {
        allocator.free(self.tool_call_id);
        if (self.content.len > 0) allocator.free(self.content);
        if (self.err_msg) |message| allocator.free(message);
    }
};

// Typed argument structs for std.json parsing
const ReadArgs = struct { path: []const u8 = "", offset: ?usize = null, limit: ?usize = null };
const WriteArgs = struct { path: []const u8 = "", content: []const u8 = "" };
const EditArgs = struct { path: []const u8 = "", edits: []const EditEntry = &.{} };
const EditEntry = struct { old: []const u8 = "", new: []const u8 = "" };
const BashArgs = struct { command: []const u8 = "", workdir: ?[]const u8 = null, timeout: ?usize = null };
const GrepArgs = struct { pattern: []const u8 = "", path: ?[]const u8 = null, include: ?[]const u8 = null };
const GlobArgs = struct { pattern: []const u8 = "*", path: ?[]const u8 = null };
const WebFetchArgs = struct { url: []const u8 = "", format: ?[]const u8 = null };
const WebSearchArgs = struct { query: []const u8 = "" };
const TodoWriteArgs = struct { todos: []const TodoEntry = &.{} };
const TodoEntry = struct { content: []const u8 = "", status: []const u8 = "pending" };
const TaskArgs = struct { description: []const u8 = "", prompt: ?[]const u8 = null, subagent: ?[]const u8 = null };
const PlanArgs = struct { goal: []const u8 = "", steps: []const []const u8 = &.{} };
const QuestionArgs = struct { question: []const u8 = "", options: []const []const u8 = &.{} };
const RecallArgs = struct { query: []const u8 = "" };
const PatchArgs = struct { path: []const u8 = "", patch: []const u8 = "" };
const DiagArgs = struct { path: ?[]const u8 = null };
const LspInfoArgs = struct { path: ?[]const u8 = null, line: ?usize = null, col: ?usize = null, action: ?[]const u8 = null };

/// Parse JSON arguments into typed struct. Returns default-initialized struct on parse failure.
fn parseArgs(comptime T: type, allocator: Allocator, json: []const u8) T {
    const parsed = std.json.parseFromSlice(T, allocator, json, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

/// All built-in Kilo Code tools
pub fn builtinTools() []const ToolDef {
    return &.{
        // File tools
        .{ .name = "read", .description = "Read a file from disk. Returns the file contents with line numbers.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string","description":"File path"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}
        , .permission = .allow },
        .{ .name = "write", .description = "Write a file to disk. Creates parent directories if needed.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        , .permission = .ask },
        .{ .name = "edit", .description = "Make precise edits to a file using search/replace. Multiple edits in one call.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"old":{"type":"string"},"new":{"type":"string"}}}}},"required":["path","edits"]}
        , .permission = .ask },
        .{ .name = "apply_patch", .description = "Apply a unified diff patch to a file.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"patch":{"type":"string"}},"required":["path","patch"]}
        , .permission = .ask },

        // Shell tools
        .{ .name = "bash", .description = "Execute a shell command. Returns stdout, stderr, and exit code.", .parameters =
        \\{"type":"object","properties":{"command":{"type":"string"},"workdir":{"type":"string"},"timeout":{"type":"integer"}},"required":["command"]}
        , .permission = .ask },

        // Search tools
        .{ .name = "grep", .description = "Search for a pattern in files. Supports regex.", .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"include":{"type":"string"}},"required":["pattern"]}
        , .permission = .allow },
        .{ .name = "glob", .description = "Find files matching a glob pattern.", .parameters =
        \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}
        , .permission = .allow },

        // LSP tools
        .{ .name = "diagnostics", .description = "Read LSP diagnostics for files.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"}},"required":[]}
        , .permission = .allow },
        .{ .name = "lsp_info", .description = "Get LSP information: hover, references, definitions.", .parameters =
        \\{"type":"object","properties":{"path":{"type":"string"},"line":{"type":"integer"},"col":{"type":"integer"},"action":{"type":"string","enum":["hover","definition","references"]}},"required":["path","line","col","action"]}
        , .permission = .allow },

        // Web tools
        .{ .name = "webfetch", .description = "Fetch content from a URL.", .parameters =
        \\{"type":"object","properties":{"url":{"type":"string"},"format":{"type":"string","enum":["text","html","markdown"]}},"required":["url"]}
        , .permission = .ask },
        .{ .name = "websearch", .description = "Search the web for information.", .parameters =
        \\{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}
        , .permission = .ask },

        // Task tools
        .{ .name = "task", .description = "Launch a sub-agent to handle a complex task independently.", .parameters =
        \\{"type":"object","properties":{"description":{"type":"string"},"prompt":{"type":"string"},"subagent":{"type":"string"}},"required":["description","prompt"]}
        , .permission = .allow },
        .{ .name = "todowrite", .description = "Create and manage a structured task list for your current session.", .parameters =
        \\{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed","cancelled"]}}}}},"required":["todos"]}
        , .permission = .allow },

        // Memory tools
        .{ .name = "recall", .description = "Recall information from previous sessions or memory.", .parameters =
        \\{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}
        , .permission = .allow },

        // Planning
        .{ .name = "plan", .description = "Create a plan before executing complex tasks. Enter plan mode.", .parameters =
        \\{"type":"object","properties":{"goal":{"type":"string"},"steps":{"type":"array","items":{"type":"string"}}},"required":["goal"]}
        , .permission = .allow },

        // Question
        .{ .name = "question", .description = "Ask the user a question when you need clarification.", .parameters =
        \\{"type":"object","properties":{"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"}}},"required":["question"]}
        , .permission = .allow },
    };
}

/// LSP client reference for diagnostics/lsp_info tools (optional)
var lsp_client: ?*anyopaque = null;

/// Set the LSP client for tool access
pub fn setLspClient(client: ?*anyopaque) void {
    lsp_client = client;
}

/// Execute a tool call. Pass lsp_client via setLspClient() before calling.
pub fn executeTool(allocator: Allocator, call: ToolCall, cwd: []const u8) !ToolResult {
    const result = switch (std.meta.stringToEnum(ToolName, call.name) orelse return error.UnknownTool) {
        .read => try toolRead(allocator, call.id, call.arguments, cwd),
        .write => try toolWrite(allocator, call.id, call.arguments, cwd),
        .edit => try toolEdit(allocator, call.id, call.arguments, cwd),
        .bash => try toolBash(allocator, call.id, call.arguments, cwd),
        .grep => try toolGrep(allocator, call.id, call.arguments, cwd),
        .glob => try toolGlob(allocator, call.id, call.arguments, cwd),
        .webfetch => try toolWebFetch(allocator, call.id, call.arguments),
        .websearch => try toolWebSearch(allocator, call.id, call.arguments),
        .todowrite => try toolTodoWrite(allocator, call.id, call.arguments),
        .task => try toolTask(allocator, call.id, call.arguments),
        .plan => try toolPlan(allocator, call.id, call.arguments),
        .question => try toolQuestion(allocator, call.id, call.arguments),
        .recall => try toolRecall(allocator, call.id, call.arguments),
        .diagnostics => try toolDiagnostics(allocator, call.id, call.arguments),
        .lsp_info => try toolLspInfo(allocator, call.id, call.arguments),
        .apply_patch => try toolApplyPatch(allocator, call.id, call.arguments, cwd),
    };
    return result;
}

const ToolName = enum {
    read,
    write,
    edit,
    apply_patch,
    bash,
    grep,
    glob,
    diagnostics,
    lsp_info,
    webfetch,
    websearch,
    task,
    todowrite,
    recall,
    plan,
    question,
};

fn toolRead(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const args = parseArgs(ReadArgs, allocator, args_json);
    if (args.path.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No path specified") };
    const path = args.path;
    const full_path = if (!std.fs.path.isAbsolute(path)) try std.fs.path.join(allocator, &.{ cwd, path }) else try allocator.dupe(u8, path);
    defer allocator.free(full_path);
    const content = std.Io.Dir.cwd().readFileAlloc(
        runtime.io(),
        full_path,
        allocator,
        .limited(1024 * 1024),
    ) catch |e| {
        return ToolResult{ .tool_call_id = id_dup, .err_msg = try std.fmt.allocPrint(allocator, "Failed to read: {s}", .{@errorName(e)}) };
    };
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        try w.print("{d: >4} {s}\n", .{ n, line });
    }
    allocator.free(content);
    return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
}

fn toolWrite(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const args = parseArgs(WriteArgs, allocator, args_json);
    if (args.path.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No path") };
    const path = args.path;
    const content = args.content;
    const full = if (!std.fs.path.isAbsolute(path)) try std.fs.path.join(allocator, &.{ cwd, path }) else try allocator.dupe(u8, path);
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |d| {
        std.Io.Dir.cwd().createDirPath(runtime.io(), d) catch {};
    }
    try std.Io.Dir.cwd().writeFile(runtime.io(), .{ .sub_path = full, .data = content });
    return ToolResult{ .tool_call_id = id_dup, .content = try std.fmt.allocPrint(allocator, "Written {} bytes to {s}", .{ content.len, path }) };
}

fn toolEdit(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(EditArgs, allocator, args_json);
    if (parsed.path.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No path") };
    const full = if (!std.fs.path.isAbsolute(parsed.path)) try std.fs.path.join(allocator, &.{ cwd, parsed.path }) else try allocator.dupe(u8, parsed.path);
    defer allocator.free(full);
    var text = try std.Io.Dir.cwd().readFileAlloc(
        runtime.io(),
        full,
        allocator,
        .limited(10 * 1024 * 1024),
    );
    defer allocator.free(text);
    var count: usize = 0;
    for (parsed.edits) |edit| {
        if (std.mem.indexOf(u8, text, edit.old)) |pos| {
            var new_text = std.array_list.Managed(u8).init(allocator);
            try new_text.appendSlice(text[0..pos]);
            try new_text.appendSlice(edit.new);
            try new_text.appendSlice(text[pos + edit.old.len ..]);
            const old = text;
            text = try new_text.toOwnedSlice();
            allocator.free(old);
            count += 1;
        }
    }
    try std.Io.Dir.cwd().writeFile(runtime.io(), .{ .sub_path = full, .data = text });
    return ToolResult{ .tool_call_id = id_dup, .content = try std.fmt.allocPrint(allocator, "Applied {} edit(s) to {s}", .{ count, parsed.path }) };
}

fn toolBash(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(BashArgs, allocator, args_json);
    if (parsed.command.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No command") };
    const shell_args = [_][]const u8{ "sh", "-c", parsed.command };
    const result = try std.process.run(allocator, runtime.io(), .{
        .argv = &shell_args,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const msg = try std.fmt.allocPrint(
        allocator,
        "Exit: {}\nSTDOUT:\n{s}\nSTDERR:\n{s}",
        .{ exitCode(result.term), result.stdout, result.stderr },
    );
    return ToolResult{ .tool_call_id = id_dup, .content = msg };
}

fn toolGrep(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(GrepArgs, allocator, args_json);
    if (parsed.pattern.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No pattern") };
    const args = [_][]const u8{ "grep", "-rn", "--color=never", parsed.pattern, cwd };
    const result = try std.process.run(allocator, runtime.io(), .{
        .argv = &args,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    allocator.free(result.stderr);
    const content = if (result.stdout.len > 0)
        result.stdout
    else blk: {
        allocator.free(result.stdout);
        break :blk try allocator.dupe(u8, "No matches found");
    };
    return ToolResult{ .tool_call_id = id_dup, .content = content };
}

fn toolGlob(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(GlobArgs, allocator, args_json);
    const args = [_][]const u8{ "find", cwd, "-name", parsed.pattern, "-type", "f" };
    const result = try std.process.run(allocator, runtime.io(), .{
        .argv = &args,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    allocator.free(result.stderr);
    return ToolResult{ .tool_call_id = id_dup, .content = result.stdout };
}

fn toolWebFetch(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(WebFetchArgs, allocator, args_json);
    if (parsed.url.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No URL") };
    const args = [_][]const u8{ "curl", "-sL", "--max-time", "10", parsed.url };
    const result = std.process.run(allocator, runtime.io(), .{
        .argv = &args,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return ToolResult{
        .tool_call_id = id_dup,
        .err_msg = try allocator.dupe(u8, "curl failed"),
    };
    allocator.free(result.stderr);
    return ToolResult{ .tool_call_id = id_dup, .content = result.stdout };
}

// ============================================================
// Module-level state for session tools
// ============================================================
var todo_items: std.array_list.Managed(TodoItem) = std.array_list.Managed(TodoItem).init(std.heap.page_allocator);
var plan_active: bool = false;
var plan_goal: []const u8 = "";
var plan_steps: std.array_list.Managed([]const u8) = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
var memory_store: std.StringHashMapUnmanaged([]const u8) = .{};
var pending_questions: std.array_list.Managed(QuestionEntry) = std.array_list.Managed(QuestionEntry).init(std.heap.page_allocator);

const TodoItem = struct { content: []const u8, status: TodoStatus };
const TodoStatus = enum { pending, in_progress, completed, cancelled };
const QuestionEntry = struct { id: []const u8, question: []const u8, options: []const []const u8 };

pub fn deinitSessionState(allocator: Allocator) void {
    for (todo_items.items) |t| allocator.free(t.content);
    todo_items.deinit();
    if (plan_goal.len > 0) allocator.free(plan_goal);
    for (plan_steps.items) |s| allocator.free(s);
    plan_steps.deinit();
    var mit = memory_store.iterator();
    while (mit.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    memory_store.deinit();
    for (pending_questions.items) |q| {
        allocator.free(q.id);
        allocator.free(q.question);
    }
    pending_questions.deinit();
}

fn toolWebSearch(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(WebSearchArgs, allocator, args_json);
    if (parsed.query.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No query provided") };
    const query = parsed.query;
    // Use DuckDuckGo HTML search (non-JS version)
    const url = try std.fmt.allocPrint(allocator, "https://html.duckduckgo.com/html/?q={s}", .{query});
    defer allocator.free(url);
    const args = [_][]const u8{ "curl", "-sL", "--max-time", "10", "-A", "WIZP/1.0", url };
    const response = std.process.run(allocator, runtime.io(), .{
        .argv = &args,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return ToolResult{
        .tool_call_id = id_dup,
        .err_msg = try allocator.dupe(u8, "curl failed"),
    };
    defer allocator.free(response.stdout);
    defer allocator.free(response.stderr);
    const out = response.stdout;
    // Extract result snippets from HTML
    var results: std.Io.Writer.Allocating = .init(allocator);
    const w = &results.writer;
    var pos: usize = 0;
    var count: usize = 0;
    while (count < 5) {
        if (std.mem.indexOfPos(u8, out, pos, "class=\"result__snippet\"")) |snip_start| {
            if (std.mem.indexOfScalarPos(u8, out, snip_start + 23, '>')) |tag_end| {
                if (std.mem.indexOfScalarPos(u8, out, tag_end, '<')) |close_tag| {
                    const snippet = out[tag_end + 1 .. close_tag];
                    const decoded = htmlDecode(allocator, snippet) catch continue;
                    try w.print("{d}. {s}\n", .{ count + 1, decoded });
                    count += 1;
                    pos = close_tag + 1;
                    continue;
                }
            }
        }
        break;
    }
    const content = if (results.written().len > 0) try results.toOwnedSlice() else try allocator.dupe(u8, "No search results found. Try a different query.");
    return ToolResult{ .tool_call_id = id_dup, .content = content };
}

fn htmlDecode(allocator: Allocator, s: []const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&' and i + 4 <= s.len) {
            if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try buf.append('<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try buf.append('>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try buf.append('&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try buf.append('"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "&#x27;")) {
                try buf.append('\'');
                i += 6;
                continue;
            }
        }
        try buf.append(s[i]);
        i += 1;
    }
    return buf.toOwnedSlice();
}

fn toolTodoWrite(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    // Parse todos array from JSON
    if (std.mem.indexOf(u8, args_json, "\"todos\"")) |_| {
        // Free previous todos
        for (todo_items.items) |t| allocator.free(t.content);
        todo_items.clearRetainingCapacity();
        // Extract todo items (simple string-search parser)
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, args_json, pos, "\"content\"")) |c_start| {
            if (std.mem.indexOfScalarPos(u8, args_json, c_start + 9, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, args_json, v0 + 1, '"')) |v1| {
                    const cnt = args_json[v0 + 1 .. v1];
                    var status: TodoStatus = .pending;
                    if (std.mem.indexOfPos(u8, args_json, c_start, "\"in_progress\"")) |_| status = .in_progress;
                    if (std.mem.indexOfPos(u8, args_json, c_start, "\"completed\"")) |_| status = .completed;
                    if (std.mem.indexOfPos(u8, args_json, c_start, "\"cancelled\"")) |_| status = .cancelled;
                    try todo_items.append(.{ .content = try allocator.dupe(u8, cnt), .status = status });
                    pos = v1 + 1;
                    continue;
                }
            }
            break;
        }
    }
    // Build response
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Todo list updated. {} items:\n", .{todo_items.items.len});
    for (todo_items.items, 0..) |item, i| {
        const st = switch (item.status) {
            .pending => "⏳",
            .in_progress => "🔄",
            .completed => "✅",
            .cancelled => "❌",
        };
        try w.print("  {d}. {s} {s}\n", .{ i + 1, st, item.content });
    }
    return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
}

fn toolTask(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(TaskArgs, allocator, args_json);
    const description = parsed.description;
    const prompt = parsed.prompt orelse description;
    const subagent = parsed.subagent orelse "assistant";
    if (description.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "description is required for task dispatch") };
    // Task dispatch stays inline until a separate agent-session runner owns this tool.
    const msg = try std.fmt.allocPrint(allocator,
        \\Task accepted for inline execution: {s}
        \\Requested agent: {s}
        \\Prompt: {s}
        \\
        \\No separate agent session was started. Use the available read, write, edit, bash,
        \\grep, and glob tools to complete the task inline.
    , .{ description, subagent, if (prompt.len > 0) prompt else description });
    return ToolResult{ .tool_call_id = id_dup, .content = msg };
}

fn toolPlan(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    // Parse goal and steps
    var goal: []const u8 = "";
    if (std.mem.indexOf(u8, args_json, "\"goal\"")) |s| {
        if (std.mem.indexOfScalarPos(u8, args_json, s + 7, '"')) |v0| {
            if (std.mem.indexOfScalarPos(u8, args_json, v0 + 1, '"')) |v1| goal = args_json[v0 + 1 .. v1];
        }
    }
    // Free previous plan
    if (plan_goal.len > 0) allocator.free(plan_goal);
    for (plan_steps.items) |s| allocator.free(s);
    plan_steps.clearRetainingCapacity();

    plan_goal = if (goal.len > 0) try allocator.dupe(u8, goal) else "";
    // Extract steps
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, args_json, pos, "\"steps\"")) |st_start| {
        pos = st_start + 7;
        // Find string items in steps array
        while (std.mem.indexOfPos(u8, args_json, pos, "\"")) |q_start| {
            if (std.mem.indexOfScalarPos(u8, args_json, q_start + 1, '"')) |q_end| {
                const step = args_json[q_start + 1 .. q_end];
                if (step.len > 0 and !std.mem.eql(u8, step, "steps")) {
                    try plan_steps.append(try allocator.dupe(u8, step));
                }
                pos = q_end + 1;
                if (std.mem.indexOfScalarPos(u8, args_json, pos, ']')) |_| break;
                continue;
            }
            break;
        }
        break;
    }
    plan_active = true;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("Plan mode activated.\nGoal: {s}\n\nSteps:\n", .{goal});
    for (plan_steps.items, 0..) |step, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, step });
    }
    try w.writeAll("\nProceed through each step. You may use todowrite to track progress.");
    return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
}

fn toolQuestion(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(QuestionArgs, allocator, args_json);
    if (parsed.question.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No question provided") };

    try pending_questions.append(.{
        .id = try allocator.dupe(u8, id_dup),
        .question = try allocator.dupe(u8, parsed.question),
        .options = parsed.options,
    });

    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    try w.print("❓ {s}\n", .{parsed.question});
    if (parsed.options.len > 0) {
        try w.writeAll("\nOptions:\n");
        for (parsed.options, 0..) |opt, i| {
            try w.print("  {d}. {s}\n", .{ i + 1, opt });
        }
    }
    try w.writeAll("\n⏳ Waiting for user response. The user will answer through the editor UI.");
    return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
}

fn toolRecall(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(RecallArgs, allocator, args_json);
    const query = parsed.query;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    var found: usize = 0;
    var mit = memory_store.iterator();
    while (mit.next()) |entry| {
        if (query.len == 0 or std.mem.indexOf(u8, entry.key_ptr.*, query) != null or std.mem.indexOf(u8, entry.value_ptr.*, query) != null) {
            try w.print("📌 {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            found += 1;
        }
    }
    if (found == 0) {
        try w.writeAll("No memories found. Use this tool to save important information for later recall.\n");
        try w.writeAll("Example: Save key findings, file paths, or decisions during your session.\n");
    }
    return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
}

/// Save a memory entry (can be called from other tools)
pub fn saveMemory(allocator: Allocator, key: []const u8, value: []const u8) !void {
    const k = try allocator.dupe(u8, key);
    const v = try allocator.dupe(u8, value);
    try memory_store.put(allocator, k, v);
}

fn toolApplyPatch(allocator: Allocator, id: []const u8, args_json: []const u8, cwd: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(PatchArgs, allocator, args_json);
    if (parsed.path.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No file path") };
    if (parsed.patch.len == 0) return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "No patch content") };
    const path = parsed.path;
    const patch = parsed.patch;

    // Write patch to temp file, apply with patch command
    const full_path = if (std.fs.path.isAbsolute(path)) try allocator.dupe(u8, path) else try std.fs.path.join(allocator, &.{ cwd, path });
    defer allocator.free(full_path);
    const patch_path = try std.fs.path.join(allocator, &.{ cwd, ".wizp-tmp-patch.diff" });
    defer allocator.free(patch_path);
    try std.Io.Dir.cwd().writeFile(runtime.io(), .{ .sub_path = patch_path, .data = patch });

    const args = [_][]const u8{ "patch", "-u", full_path, patch_path };
    const result = try std.process.run(allocator, runtime.io(), .{
        .argv = &args,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    std.Io.Dir.cwd().deleteFile(runtime.io(), patch_path) catch {};
    const code = exitCode(result.term);
    const msg = if (code == 0)
        try std.fmt.allocPrint(
            allocator,
            "Patch applied successfully to {s}\n{s}",
            .{ path, result.stdout },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Patch failed (exit {}): {s}",
            .{ code, result.stderr },
        );
    return ToolResult{ .tool_call_id = id_dup, .content = msg };
}

fn toolDiagnostics(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(DiagArgs, allocator, args_json);
    const file_path = parsed.path orelse "current file";

    // Try LSP client if available
    if (lsp_client) |client_ptr| {
        const LSP = @import("../lsp/LSP.zig");
        const lsp = @as(*LSP.LSPClient, @ptrCast(@alignCast(client_ptr)));
        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
        defer allocator.free(uri);
        const diags = lsp.getDiagnostics(uri);
        if (diags.len > 0) {
            var buf: std.Io.Writer.Allocating = .init(allocator);
            const w = &buf.writer;
            try w.print("Diagnostics for {s} ({} issues):\n", .{ file_path, diags.len });
            for (diags) |d| {
                const sev = switch (d.severity orelse .hint) {
                    .err => "ERROR",
                    .warning => "WARN",
                    .information => "INFO",
                    .hint => "HINT",
                };
                try w.print("  [{s}] Line {}: {s}\n", .{ sev, d.range.start.line + 1, d.message });
            }
            return ToolResult{ .tool_call_id = id_dup, .content = try buf.toOwnedSlice() };
        }
        const msg = try std.fmt.allocPrint(allocator, "No diagnostics for {s}.", .{file_path});
        return ToolResult{ .tool_call_id = id_dup, .content = msg };
    }

    const msg = try std.fmt.allocPrint(allocator,
        \\Diagnostics for {s}:
        \\No LSP server connected. Start a language server to get live diagnostics.
    , .{file_path});
    return ToolResult{ .tool_call_id = id_dup, .content = msg };
}

fn toolLspInfo(allocator: Allocator, id: []const u8, args_json: []const u8) !ToolResult {
    const id_dup = try allocator.dupe(u8, id);
    const parsed = parseArgs(LspInfoArgs, allocator, args_json);
    const action = parsed.action orelse "hover";
    const file_path = parsed.path orelse "current file";

    if (lsp_client) |client_ptr| {
        const LSP = @import("../lsp/LSP.zig");
        const lsp = @as(*LSP.LSPClient, @ptrCast(@alignCast(client_ptr)));
        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
        defer allocator.free(uri);
        const line = parsed.line orelse 0;
        const col = parsed.col orelse 0;

        if (std.mem.eql(u8, action, "hover")) {
            const result = lsp.hover(uri, line, col) catch {
                return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "Hover request failed") };
            };
            return ToolResult{ .tool_call_id = id_dup, .content = try allocator.dupe(u8, result) };
        }
        if (std.mem.eql(u8, action, "definition")) {
            const result = lsp.definition(uri, line, col) catch {
                return ToolResult{ .tool_call_id = id_dup, .err_msg = try allocator.dupe(u8, "Definition request failed") };
            };
            return ToolResult{ .tool_call_id = id_dup, .content = try allocator.dupe(u8, result) };
        }
        const msg = try std.fmt.allocPrint(allocator, "LSP action '{s}' requested for {s}:{d}:{d}", .{ action, file_path, line, col });
        return ToolResult{ .tool_call_id = id_dup, .content = msg };
    }

    const msg = try std.fmt.allocPrint(allocator,
        \\LSP {s} for {s}: No LSP server connected.
    , .{ action, file_path });
    return ToolResult{ .tool_call_id = id_dup, .content = msg };
}
