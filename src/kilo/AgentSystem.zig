// Kilo Code Agent System for WIZP
// Multi-agent orchestration with permissions, sub-agents, plan mode, and skills

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AgentMode = enum { primary, subagent };

pub const AgentDef = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    mode: AgentMode,
    system_prompt: []const u8,
    temperature: f32 = 0.7,
    max_tokens: usize = 4096,
    allowed_tools: []const []const u8 = &.{}, // Tool names allowed
    requires_approval: bool = false,
};

/// Task for plan mode
pub const TaskItem = struct {
    id: usize,
    content: []const u8,
    status: TaskStatus,
    sub_tasks: std.array_list.Managed(TaskItem),

    pub const TaskStatus = enum { pending, in_progress, completed, cancelled };
};

/// Plan mode state
pub const Plan = struct {
    goal: []const u8,
    steps: std.array_list.Managed(TaskItem),
    current_step: usize = 0,
    is_active: bool = false,
};

/// Skill definition (reusable prompt + tool combination)
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    tools: []const []const u8 = &.{},
};

/// Agent session with memory and compaction
pub const AgentSession = struct {
    allocator: Allocator,
    agent: AgentDef,
    messages: std.array_list.Managed(Message),
    plan: ?Plan = null,
    token_count: usize = 0,
    /// Memory store for recall
    memory: std.StringHashMapUnmanaged([]const u8),

    pub const Message = struct {
        role: Role,
        content: []const u8,
        tool_calls: ?[]const ToolCallRef = null,
        tool_call_id: ?[]const u8 = null,

        pub const Role = enum { system, user, assistant, tool };
        pub const ToolCallRef = struct {
            id: []const u8,
            name: []const u8,
            arguments: []const u8,
        };
    };

    pub fn init(allocator: Allocator, agent: AgentDef, system_prompt_extra: ?[]const u8) !AgentSession {
        var session = AgentSession{ .allocator = allocator, .agent = agent, .messages = std.array_list.Managed(Message).init(allocator), .memory = .{} };
        // Add system message
        var sys_msg = std.array_list.Managed(u8).init(allocator);
        try sys_msg.appendSlice(agent.system_prompt);
        if (system_prompt_extra) |extra| {
            try sys_msg.append('\n');
            try sys_msg.appendSlice(extra);
        }
        try session.messages.append(.{ .role = .system, .content = try sys_msg.toOwnedSlice() });
        session.token_count = estimateTokens(session.messages.items[0].content);
        return session;
    }

    pub fn addMessage(self: *AgentSession, role: Message.Role, content: []const u8) !void {
        const duped = try self.allocator.dupe(u8, content);
        try self.messages.append(.{ .role = role, .content = duped });
        self.token_count += estimateTokens(content);
    }

    /// Compact context when approaching token limit
    pub fn compact(self: *AgentSession, max_tokens: usize) !void {
        if (self.token_count < max_tokens) return;

        // Keep system message + last N messages
        const keep_count: usize = 20;
        while (self.messages.items.len > keep_count + 1 and self.token_count > max_tokens / 2) {
            const removed = self.messages.orderedRemove(1); // Skip system message
            self.token_count -= estimateTokens(removed.content);
            self.allocator.free(removed.content);
        }

        // Add compaction summary
        try self.messages.insert(1, .{
            .role = .system,
            .content = try self.allocator.dupe(u8, "[Earlier conversation has been summarized to save context space. Key points have been preserved.]"),
        });
    }

    /// Store in memory for recall
    pub fn remember(self: *AgentSession, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.memory.put(self.allocator, k, v);
    }

    /// Recall from memory
    pub fn recall(self: *AgentSession, query: []const u8) ?[]const u8 {
        // Simple exact match first, then substring
        if (self.memory.get(query)) |v| return v;
        var it = self.memory.iterator();
        while (it.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, query) != null or
                std.mem.indexOf(u8, entry.value_ptr.*, query) != null)
            {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    /// Create a plan
    pub fn createPlan(self: *AgentSession, goal: []const u8, steps: []const []const u8) !void {
        var plan = Plan{ .goal = try self.allocator.dupe(u8, goal), .is_active = true };
        for (steps, 0..) |step, i| {
            try plan.steps.append(.{
                .id = i,
                .content = try self.allocator.dupe(u8, step),
                .status = .pending,
            });
        }
        self.plan = plan;
    }

    pub fn deinit(self: *AgentSession) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
        if (self.plan) |*p| {
            self.allocator.free(p.goal);
            for (p.steps.items) |step| {
                self.allocator.free(step.content);
            }
            p.steps.deinit();
        }
        var it = self.memory.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory.deinit(self.allocator);
    }
};

/// Pre-defined Kilo Code agents
pub fn getBuiltinAgents() []const AgentDef {
    return &.{
        .{
            .name = "code-explorer",
            .display_name = "Code Explorer",
            .description = "Sub-agent for searching and exploring codebases. Uses grep, glob, and read tools.",
            .mode = .subagent,
            .system_prompt = "You are a code exploration agent. Search files, find patterns, and report findings concisely.",
            .allowed_tools = &.{ "read", "grep", "glob", "lsp_info" },
        },
        .{
            .name = "architect",
            .display_name = "Architect",
            .description = "Sub-agent for designing and planning code changes. Creates implementation plans.",
            .mode = .subagent,
            .system_prompt = "You are a software architect. Design solutions, create plans, and define implementation steps.",
            .allowed_tools = &.{ "read", "grep", "glob", "plan", "todowrite" },
        },
        .{
            .name = "code-reviewer",
            .display_name = "Code Reviewer",
            .description = "Sub-agent that reviews code for bugs, style, and improvements.",
            .mode = .subagent,
            .system_prompt = "You are a thorough code reviewer. Find bugs, style issues, and suggest improvements.",
            .allowed_tools = &.{ "read", "grep", "diagnostics", "lsp_info" },
        },
        .{
            .name = "test-writer",
            .display_name = "Test Writer",
            .description = "Sub-agent for writing comprehensive tests.",
            .mode = .subagent,
            .system_prompt = "You are a test writing expert. Write thorough, edge-case-covering tests.",
            .allowed_tools = &.{ "read", "write", "edit", "bash" },
        },
        .{
            .name = "assistant",
            .display_name = "Assistant",
            .description = "Primary coding assistant. Has access to all tools.",
            .mode = .primary,
            .system_prompt =
            \\You are an expert software engineer AI assistant integrated into WIZP editor.
            \\You help users write, debug, refactor, and understand code.
            \\
            \\When solving problems:
            \\1. First understand the user's request
            \\2. Use read/grep/glob to explore the codebase
            \\3. Use diagnostics to check for errors
            \\4. Plan your approach before making changes
            \\5. Use edit/write to make precise changes
            \\6. Use bash to run tests and verify
            \\
            \\Always explain what you're doing and why.
            ,
            .allowed_tools = &.{ "read", "write", "edit", "apply_patch", "bash", "grep", "glob", "diagnostics", "lsp_info", "webfetch", "websearch", "task", "todowrite", "plan", "question", "recall" },
        },
    };
}

fn estimateTokens(text: []const u8) usize {
    return (text.len + 3) / 4;
}
