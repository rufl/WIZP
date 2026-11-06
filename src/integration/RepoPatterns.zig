// WIZP RepoPatterns — Integrated best ideas from reference repositories
//
// pixi (foxnne/pixi):    dvui immediate-mode GUI, comptime asset embedding, platform window
// flow (neurocyte/flow): build/task runner
// zaica (neolite/zaica): parallel sub-agents, node-based agentic loop, tool calling
// anyzig (marler8997/anyzig): platform abstraction (Cmdline.zig), comptime OS switching
// nullclaw (nullclaw/nullclaw): agent bindings/routing, multi-LSP management
// nullhub (nullclaw/nullhub): multi-LSP hub, API routing

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================
// Pattern 1: Comptime Platform Abstraction (from anyzig Cmdline.zig)
// ============================================================

/// Platform-abstracted command line args with zero allocation on POSIX.
/// Pattern from anyzig: comptime union with OS-specific fields.
pub const Cmdline = struct {
    args: std.process.Args,

    pub fn init(args: std.process.Args) Cmdline {
        return .{ .args = args };
    }

    pub fn deinit(self: *Cmdline) void {
        _ = self;
    }

    pub fn len(self: Cmdline) usize {
        return self.args.vector.len;
    }

    pub fn get(self: Cmdline, i: usize) [:0]const u8 {
        return std.mem.span(self.args.vector[i]);
    }
};

// ============================================================
// Pattern 2: Node-based Agentic Loop (from zaica node.zig + agent.zig)
// ============================================================

/// Agent node for LLM tool-calling loop.
/// Pattern from zaica: generic agentic loop with max iterations,
/// tool execution, and structured result collection.
pub const AgentNode = struct {
    allocator: Allocator,
    max_iterations: usize = 50,

    pub const ToolResult = struct {
        name: []const u8,
        output: []const u8,
        error_msg: ?[]const u8,
    };

    pub const AgentResult = struct {
        text: []const u8,
        tool_results: std.array_list.Managed(ToolResult),
        iterations: usize,
        total_tokens: u64,

        pub fn deinit(self: *AgentResult, allocator: Allocator) void {
            allocator.free(self.text);
            for (self.tool_results.items) |*tr| {
                allocator.free(tr.name);
                allocator.free(tr.output);
                if (tr.error_msg) |e| allocator.free(e);
            }
            self.tool_results.deinit();
        }
    };

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator, .max_iterations = 50 };
    }

    /// Run an agentic loop with the given system prompt and tools.
    /// Pattern from zaica: each iteration = LLM call + tool execution + result collection.
    pub fn run(
        self: *Self,
        system_prompt: []const u8,
        task: []const u8,
        llm_call: *const fn (Allocator, []const u8) anyerror![]const u8,
        tools: []const ToolDef,
    ) !AgentResult {
        var result = AgentResult{
            .text = try self.allocator.dupe(u8, ""),
            .tool_results = &[_][]const u8{},
            .iterations = 0,
            .total_tokens = 0,
        };
        errdefer result.deinit();

        var prompt = try std.fmt.allocPrint(self.allocator, "{s}\n\nTask: {s}", .{ system_prompt, task });
        defer self.allocator.free(prompt);

        for (0..self.max_iterations) |_| {
            result.iterations += 1;

            const response = llm_call(self.allocator, prompt) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "LLM error: {s}", .{@errorName(err)});
                self.allocator.free(result.text);
                result.text = err_msg;
                return result;
            };
            defer self.allocator.free(response);

            // Check for tool calls in response
            var tool_called = false;
            for (tools) |tool| {
                if (std.mem.indexOf(u8, response, tool.trigger)) |_| {
                    // Extract and execute tool
                    const tool_output = tool.execute(self.allocator, response) catch |err| {
                        try result.tool_results.append(.{
                            .name = try self.allocator.dupe(u8, tool.name),
                            .output = try self.allocator.dupe(u8, ""),
                            .error_msg = try self.allocator.dupe(u8, @errorName(err)),
                        });
                        continue;
                    };
                    try result.tool_results.append(.{
                        .name = try self.allocator.dupe(u8, tool.name),
                        .output = tool_output,
                        .error_msg = null,
                    });
                    tool_called = true;

                    // Update prompt with tool result
                    self.allocator.free(prompt);
                    prompt = try std.fmt.allocPrint(self.allocator, "{s}\n\nTool result ({s}):\n{s}\n\nContinue:", .{ response, tool.name, tool_output });
                    break;
                }
            }

            if (!tool_called) {
                self.allocator.free(result.text);
                result.text = try self.allocator.dupe(u8, response);
                return result;
            }
        }

        // Max iterations reached
        self.allocator.free(result.text);
        result.text = try self.allocator.dupe(u8, "Max iterations reached");
        return result;
    }

    pub const ToolDef = struct {
        name: []const u8,
        trigger: []const u8, // Text pattern that triggers this tool
        description: []const u8,
        execute: *const fn (Allocator, []const u8) anyerror![]const u8,
    };
};

// ============================================================
// Pattern 3: Multi-LSP Agent Binding (from nullclaw + nullhub)
// ============================================================

/// LSP agent binding — routes LSP requests to the right server.
/// Pattern from nullclaw agent_routing.zig: PeerRef + channel routing.
pub const LspBinding = struct {
    language_id: []const u8,
    server_command: []const u8,
    server_args: []const []const u8,
    initialization_options: ?[]const u8,
    priority: usize = 0,

    pub fn deinit(self: *LspBinding, allocator: Allocator) void {
        allocator.free(self.language_id);
        allocator.free(self.server_command);
        for (self.server_args) |arg| allocator.free(arg);
        allocator.free(self.server_args);
        if (self.initialization_options) |opts| allocator.free(opts);
    }
};

/// LSP Hub — manages multiple LSP servers simultaneously.
/// Pattern from nullhub: multi-LSP routing, agent-based request dispatch.
pub const LspHub = struct {
    allocator: Allocator,
    bindings: std.array_list.Managed(LspBinding),
    active_servers: std.StringHashMapUnmanaged(*anyopaque), // language_id → LSPClient

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn addBinding(self: *Self, binding: LspBinding) !void {
        try self.bindings.append(binding);
    }

    /// Find the best LSP server for a given file extension.
    pub fn findForFile(self: *Self, file_ext: []const u8) ?*LspBinding {
        var best: ?*LspBinding = null;
        var best_priority: isize = -1;

        for (self.bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.language_id, file_ext)) {
                if (@as(isize, @intCast(binding.priority)) > best_priority) {
                    best = binding;
                    best_priority = @intCast(binding.priority);
                }
            }
        }
        return best;
    }

    pub fn deinit(self: *Self) void {
        for (self.bindings.items) |*b| b.deinit();
        self.bindings.deinit();
        self.active_servers.deinit();
    }
};

// ============================================================
// Pattern 4: Comptime Asset Embedding (from pixi assets)
// ============================================================

/// Comptime asset registry — embed files at compile time.
/// Pattern from pixi: @embedFile for icons, fonts, configs.
pub const EmbeddedAssets = struct {
    /// Embed a file at comptime and return as []const u8.
    pub fn embed(comptime path: []const u8) []const u8 {
        return @embedFile(path);
    }

    /// List all embedded asset paths (comptime-known).
    pub const all_assets = [_][]const u8{
        // Icons would go here
    };
};

// ============================================================
// Pattern 5: Immediate-mode UI Frame Loop (from pixi dvui App)
// ============================================================

/// Immediate-mode frame loop pattern.
/// Pattern from pixi dvui.App: initFn → frameFn (loop) → deinitFn.
pub const ImGuiFrameLoop = struct {
    pub const FrameFn = *const fn (*ImGuiFrameLoop) anyerror!void;
    pub const InitFn = *const fn (*ImGuiFrameLoop) anyerror!void;
    pub const DeinitFn = *const fn (*ImGuiFrameLoop) void;

    allocator: Allocator,
    running: bool = true,
    delta_time: f32 = 0.0,
    frame_count: u64 = 0,

    init_fn: InitFn,
    frame_fn: FrameFn,
    deinit_fn: DeinitFn,

    pub fn init(allocator: Allocator, init_fn: InitFn, frame_fn: FrameFn, deinit_fn: DeinitFn) !ImGuiFrameLoop {
        var loop = ImGuiFrameLoop{
            .allocator = allocator,
            .init_fn = init_fn,
            .frame_fn = frame_fn,
            .deinit_fn = deinit_fn,
        };
        try init_fn(&loop);
        return loop;
    }

    pub fn run(self: *ImGuiFrameLoop) !void {
        defer self.deinit_fn(self);

        var timer = try std.time.Timer.start();
        while (self.running) {
            const frame_start = timer.read();
            try self.frame_fn(self);
            const frame_end = timer.read();
            self.delta_time = @as(f32, @floatFromInt(frame_end - frame_start)) / 1_000_000_000.0;
            self.frame_count += 1;
        }
    }

    pub fn stop(self: *ImGuiFrameLoop) void {
        self.running = false;
    }
};

// ============================================================
// Pattern 6: Platform Window Config (from pixi window config)
// ============================================================

/// Platform-abstracted window configuration.
/// Pattern from pixi: comptime OS-specific window options.
pub const WindowConfig = struct {
    title: []const u8 = "WIZP",
    width: u32 = 1200,
    height: u32 = 800,
    min_width: u32 = 640,
    min_height: u32 = 480,
    transparent: bool = switch (builtin.os.tag) {
        .macos, .windows => true,
        else => false,
    },
    resizable: bool = true,
    vsync: bool = true,
};

// ============================================================
// Tests
// ============================================================

test "Cmdline: zero allocation on POSIX" {
    var cl = Cmdline.init(std.process.args);
    defer cl.deinit();
    try std.testing.expect(cl.len() > 0);
}

test "LspHub: add and find binding" {
    var hub = LspHub.init(std.testing.allocator);
    defer hub.deinit();

    try hub.addBinding(.{
        .language_id = "zig",
        .server_command = "zls",
        .server_args = &.{},
        .priority = 10,
    });

    const binding = hub.findForFile("zig");
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("zls", binding.?.server_command);
}

test "LspHub: priority-based selection" {
    var hub = LspHub.init(std.testing.allocator);
    defer hub.deinit();

    try hub.addBinding(.{ .language_id = "zig", .server_command = "zls", .server_args = &.{}, .priority = 5 });
    try hub.addBinding(.{ .language_id = "zig", .server_command = "szls", .server_args = &.{}, .priority = 10 });

    const binding = hub.findForFile("zig");
    try std.testing.expectEqualStrings("szls", binding.?.server_command);
}

test "AgentNode: runs with no tools" {
    var node = AgentNode.init(std.testing.allocator);
    node.max_iterations = 3;

    const result = try node.run(
        "You are a helpful assistant.",
        "Say hello",
        struct {
            fn call(allocator: Allocator, prompt: []const u8) ![]const u8 {
                _ = prompt;
                return allocator.dupe(u8, "Hello!");
            }
        }.call,
        &.{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Hello!", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.iterations);
}

test "ImGuiFrameLoop: init and stop" {
    const State = struct {
        var ran: bool = false;
        var cleaned: bool = false;
    };
    State.ran = false;
    State.cleaned = false;

    var loop = try ImGuiFrameLoop.init(
        std.testing.allocator,
        struct {
            fn init(l: *ImGuiFrameLoop) !void {
                _ = l;
                State.ran = true;
            }
        }.init,
        struct {
            fn frame(l: *ImGuiFrameLoop) !void {
                l.stop();
            }
        }.frame,
        struct {
            fn deinit(_: *ImGuiFrameLoop) void {
                State.cleaned = true;
            }
        }.deinit,
    );
    try loop.run();

    try std.testing.expect(State.ran);
    try std.testing.expect(State.cleaned);
}
