// WIZP - Onboarding & UX Excellence
// Onboarding wizard, tutorial, metrics, crash recovery, hex viewer, recent projects

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

// ============================================================
// 1. Onboarding Wizard
// ============================================================

pub const OnboardingStep = enum {
    welcome,
    theme,
    keybind_style,
    ai_setup,
    lsp_setup,
    complete,
};

pub const OnboardingWizard = struct {
    current_step: OnboardingStep = .welcome,
    completed: bool = false,
    selected_theme: []const u8 = "one-dark",
    selected_keybind: KeybindStyle = .vscode,
    ai_provider: []const u8 = "ollama",
    ai_model: []const u8 = "codellama:7b",
    install_lsps: bool = true,

    pub const KeybindStyle = enum { vscode, sublime, vim };

    pub fn render(writer: anytype, wizard: *const OnboardingWizard) !void {
        switch (wizard.current_step) {
            .welcome => try writer.writeAll(
                \\╔══════════════════════════════════════════════════╗
                \\║           Welcome to WIZP!                       ║
                \\║    Ultra-lightweight Code Editor in Zig          ║
                \\╠══════════════════════════════════════════════════╣
                \\║  → Press Enter to begin setup                   ║
                \\║  → Press Esc to skip (use defaults)             ║
                \\╚══════════════════════════════════════════════════╝
                \\
            ),
            .theme => {
                try writer.writeAll("Choose your theme:\n\n");
                const themes = [_][]const u8{ "one-dark", "dracula", "nord", "monokai", "github-dark", "catppuccin-mocha", "tokyo-night", "solarized-dark" };
                for (themes, 0..) |t, i| {
                    try writer.print("  {d}. {s}\n", .{ i + 1, t });
                }
                try writer.writeAll("\nEnter number (1-8) or press Enter for one-dark: ");
            },
            .keybind_style => try writer.writeAll(
                \\Choose keybinding style:
                \\  1. VS Code (default)
                \\  2. Sublime Text
                \\  3. Vim
                \\Enter number (1-3):
                \\
            ),
            .ai_setup => try writer.writeAll(
                \\AI Assistant Setup:
                \\  1. Ollama (local, free) - codellama:7b
                \\  2. llama.cpp (local, free)
                \\  3. OpenRouter (cloud, API key)
                \\  4. DeepSeek (cloud, API key)
                \\  5. Skip AI setup
                \\Enter number (1-5):
                \\
            ),
            .lsp_setup => try writer.writeAll(
                \\Auto-install language servers?
                \\  ZLS (Zig), Rust Analyzer, Pyright, TypeScript LS, gopls...
                \\  [Y] Yes, install recommended LSPs
                \\  [N] No, I'll install manually
                \\
            ),
            .complete => try writer.writeAll(
                \\╔══════════════════════════════════════════════════╗
                \\║              Setup Complete!                     ║
                \\║    WIZP is ready. Start coding!                 ║
                \\║                                                  ║
                \\║  Quick Start:                                   ║
                \\║    Ctrl+O    Open file                          ║
                \\║    Ctrl+P    Quick open (fuzzy find)            ║
                \\║    Ctrl+B    Toggle sidebar                     ║
                \\║    Ctrl+I    AI inline completion               ║
                \\║    Ctrl+L    AI chat                            ║
                \\║    Ctrl+,    Settings                           ║
                \\║    F1        Command palette                    ║
                \\╚══════════════════════════════════════════════════╝
                \\
            ),
        }
    }

    pub fn handleInput(self: *OnboardingWizard, input: []const u8) void {
        const trimmed = std.mem.trim(u8, input, " \n\r");
        switch (self.current_step) {
            .welcome => {
                if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "\n")) self.current_step = .theme;
            },
            .theme => {
                const n = std.fmt.parseInt(usize, trimmed, 10) catch 1;
                const themes = [_][]const u8{ "one-dark", "dracula", "nord", "monokai", "github-dark", "catppuccin-mocha", "tokyo-night", "solarized-dark" };
                if (n >= 1 and n <= themes.len) self.selected_theme = themes[n - 1];
                self.current_step = .keybind_style;
            },
            .keybind_style => {
                self.selected_keybind = switch (std.fmt.parseInt(usize, trimmed, 10) catch 1) {
                    2 => .sublime,
                    3 => .vim,
                    else => .vscode,
                };
                self.current_step = .ai_setup;
            },
            .ai_setup => {
                const n = std.fmt.parseInt(usize, trimmed, 10) catch 1;
                if (n == 2) {
                    self.ai_provider = "llamacpp";
                    self.ai_model = "local-model";
                } else if (n == 3) {
                    self.ai_provider = "openrouter";
                    self.ai_model = "openai/gpt-4o-mini";
                } else if (n == 4) {
                    self.ai_provider = "deepseek";
                    self.ai_model = "deepseek-chat";
                } else if (n == 5) {
                    self.ai_provider = "";
                }
                self.current_step = if (n == 5) .complete else .lsp_setup;
            },
            .lsp_setup => {
                if (trimmed.len > 0) {
                    self.install_lsps = std.ascii.toLower(trimmed[0]) != 'n';
                } else {
                    self.install_lsps = true;
                }
                self.current_step = .complete;
            },
            .complete => {
                self.completed = true;
            },
        }
    }
};

// ============================================================
// 2. Interactive Tutorial
// ============================================================

pub const Tutorial = struct {
    pub const Lesson = struct {
        title: []const u8,
        description: []const u8,
        keys: []const []const u8,
    };

    pub fn getLessons() []const Lesson {
        return &.{
            .{ .title = "Movement", .description = "Move cursor with h/j/k/l or arrow keys", .keys = &.{ "h", "j", "k", "l", "↑", "↓", "←", "→" } },
            .{ .title = "Insert Mode", .description = "Press i to type text, Esc to return", .keys = &.{ "i", "Esc" } },
            .{ .title = "Save & Quit", .description = "Save your work and exit", .keys = &.{ "Ctrl+S", "Ctrl+Q" } },
            .{ .title = "Find Files", .description = "Quick open any file in project", .keys = &.{"Ctrl+P"} },
            .{ .title = "Command Palette", .description = "Access all commands", .keys = &.{ "F1", "Ctrl+Shift+P" } },
            .{ .title = "Split Editor", .description = "Work with multiple files side by side", .keys = &.{ "Ctrl+\\", "Ctrl+J/K" } },
            .{ .title = "AI Assistant", .description = "Get AI-powered code completions and chat", .keys = &.{ "Ctrl+I", "Ctrl+L" } },
            .{ .title = "Settings", .description = "Configure editor and AI", .keys = &.{"Ctrl+,"} },
        };
    }
};

// ============================================================
// 3. Performance Metrics
// ============================================================

pub const Metrics = struct {
    start_time: i64,
    file_open_time: i64 = 0,
    render_time: i64 = 0,
    memory_used: usize = 0,

    pub fn init() Metrics {
        return .{ .start_time = runtime.milliTimestamp() };
    }

    pub fn elapsed(self: *const Metrics) i64 {
        return runtime.milliTimestamp() - self.start_time;
    }

    pub fn report(self: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        const elapsed_ms = self.elapsed();
        const mem_mb = @as(f64, @floatFromInt(self.memory_used)) / 1024.0 / 1024.0;
        return try std.fmt.allocPrint(allocator,
            \\WIZP Performance Report
            \\  Uptime:      {d} ms
            \\  File open:   {d} ms
            \\  Render time: {d} ms
            \\  Memory used: {d:.1} MB
        , .{ elapsed_ms, self.file_open_time, self.render_time, mem_mb });
    }
};

// ============================================================
// 4. Crash Recovery
// ============================================================

pub const CrashRecovery = struct {
    allocator: Allocator,
    recovery_dir: []const u8,

    pub fn init(allocator: Allocator, recovery_dir: []const u8) CrashRecovery {
        return .{ .allocator = allocator, .recovery_dir = recovery_dir };
    }

    /// Save dirty buffers to recovery files
    pub fn saveRecovery(self: *CrashRecovery, file_path: []const u8, content: []const u8) !void {
        const io = @import("../runtime_016.zig").io();
        std.Io.Dir.cwd().createDirPath(io, self.recovery_dir) catch {};
        const name = try std.fmt.allocPrint(self.allocator, "{s}/recovery_{s}", .{ self.recovery_dir, std.fs.path.basename(file_path) });
        defer self.allocator.free(name);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = content });
    }

    /// Check for recovery files on startup
    pub fn checkRecovery(self: *CrashRecovery) ![]const RecoveryFile {
        var files = std.array_list.Managed(RecoveryFile).init(self.allocator);
        defer files.deinit();
        const io = @import("../runtime_016.zig").io();
        var dir = std.Io.Dir.cwd().openDir(io, self.recovery_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "recovery_")) {
                const original = entry.name["recovery_".len..];
                try files.append(.{ .original_name = try self.allocator.dupe(u8, original), .recovery_path = try std.fs.path.join(self.allocator, &.{ self.recovery_dir, entry.name }) });
            }
        }
        return files.toOwnedSlice();
    }

    /// Clean up recovery files
    pub fn cleanup(self: *CrashRecovery) void {
        std.Io.Dir.cwd().deleteTree(
            @import("../runtime_016.zig").io(),
            self.recovery_dir,
        ) catch {};
    }

    pub const RecoveryFile = struct { original_name: []const u8, recovery_path: []const u8 };
};

// ============================================================
// 5. Hex/Binary Viewer
// ============================================================

pub const HexViewer = struct {
    pub fn renderHex(allocator: Allocator, data: []const u8, offset: usize, max_lines: usize) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        const w = &buf.writer;
        const lines = @min(max_lines, (data.len + 15) / 16);
        for (0..lines) |i| {
            const addr = offset + i * 16;
            try w.print("{X:0>8}  ", .{addr});
            for (0..16) |j| {
                if (i * 16 + j < data.len) {
                    try w.print("{X:0>2} ", .{data[i * 16 + j]});
                } else try w.writeAll("   ");
                if (j == 7) try w.writeAll(" ");
            }
            try w.writeAll(" |");
            for (0..16) |j| {
                if (i * 16 + j < data.len) {
                    const ch = data[i * 16 + j];
                    try w.writeByte(if (ch >= 32 and ch < 127) ch else '.');
                } else try w.writeByte(' ');
            }
            try w.writeAll("|\n");
        }
        return buf.toOwnedSlice();
    }
};

// ============================================================
// 6. Recent Projects
// ============================================================

pub const RecentProjects = struct {
    projects: std.array_list.Managed(ProjectEntry),
    max_entries: usize = 20,

    pub const ProjectEntry = struct {
        path: []const u8,
        name: []const u8,
        last_opened: i64,
        file_count: usize,
    };

    pub fn init(allocator: Allocator) RecentProjects {
        return .{ .projects = std.array_list.Managed(ProjectEntry).init(allocator) };
    }

    pub fn add(self: *RecentProjects, allocator: Allocator, path: []const u8, name: []const u8) !void {
        for (self.projects.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.path, path)) {
                allocator.free(p.path);
                allocator.free(p.name);
                _ = self.projects.orderedRemove(i);
                break;
            }
        }
        try self.projects.insert(0, .{
            .path = try allocator.dupe(u8, path),
            .name = try allocator.dupe(u8, name),
            .last_opened = runtime.milliTimestamp(),
            .file_count = 0,
        });
        while (self.projects.items.len > self.max_entries) {
            const r = self.projects.pop();
            allocator.free(r.path);
            allocator.free(r.name);
        }
    }

    pub fn deinit(self: *RecentProjects, allocator: Allocator) void {
        for (self.projects.items) |p| {
            allocator.free(p.path);
            allocator.free(p.name);
        }
        self.projects.deinit();
    }
};
