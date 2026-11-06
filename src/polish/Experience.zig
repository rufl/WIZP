// WIZP Polish - Final UX features for VS Code replacement
// LSP auto-install, format on save, diagnostics, goto-def, welcome page, config

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

// ============================================================
// LSP Auto-Install Detector
// ============================================================

pub const LspDetector = struct {
    /// Map file extensions to recommended LSP packages
    const lsp_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".zig", "zls" },
        .{ ".rs", "rust-analyzer" },
        .{ ".py", "pyright" },
        .{ ".ts", "typescript-language-server" },
        .{ ".tsx", "typescript-language-server" },
        .{ ".js", "typescript-language-server" },
        .{ ".go", "gopls" },
        .{ ".lua", "lua-language-server" },
        .{ ".java", "jdtls" },
        .{ ".c", "clangd" },
        .{ ".h", "clangd" },
        .{ ".cpp", "clangd" },
        .{ ".hpp", "clangd" },
        .{ ".sh", "bash-language-server" },
        .{ ".bash", "bash-language-server" },
        .{ ".md", "marksman" },
        .{ ".yaml", "yaml-language-server" },
        .{ ".yml", "yaml-language-server" },
        .{ ".json", "json-lsp" },
        .{ ".cs", "omnisharp" },
    });

    /// Detect if we need to suggest an LSP install
    pub fn detect(file_path: []const u8) ?LspSuggestion {
        const ext = std.fs.path.extension(file_path);
        if (lsp_map.get(ext)) |pkg_id| {
            return LspSuggestion{
                .package_id = pkg_id,
                .file_extension = ext,
                .message = switch (std.meta.stringToEnum(LspName, pkg_id) orelse return null) {
                    .zls => "Zig Language Server (ZLS) provides completions, hover, and diagnostics for Zig files.",
                    .@"rust-analyzer" => "Rust Analyzer provides fast completions, type hints, and refactoring for Rust.",
                    .pyright => "Pyright provides static type checking and IntelliSense for Python.",
                    .@"typescript-language-server" => "TypeScript Language Server provides IntelliSense for JS/TS files.",
                    .gopls => "gopls is the official Go language server with completions and diagnostics.",
                    .@"lua-language-server" => "Lua Language Server provides annotations and completions for Lua.",
                    .jdtls => "Eclipse JDTLS provides Java language support.",
                    .clangd => "clangd provides C/C++ language intelligence from the LLVM project.",
                    .@"bash-language-server" => "Bash Language Server provides shell script completions.",
                    .marksman => "Marksman provides Markdown LSP with wiki-link support.",
                    .@"yaml-language-server" => "YAML Language Server provides schema validation.",
                    .@"json-lsp" => "JSON Language Server provides schema support for JSON files.",
                    .omnisharp => "OmniSharp provides C# language support.",
                },
            };
        }
        return null;
    }
};

pub const LspSuggestion = struct {
    package_id: []const u8,
    file_extension: []const u8,
    message: []const u8,
};

const LspName = enum {
    zls,
    @"rust-analyzer",
    pyright,
    @"typescript-language-server",
    gopls,
    @"lua-language-server",
    jdtls,
    clangd,
    @"bash-language-server",
    marksman,
    @"yaml-language-server",
    @"json-lsp",
    omnisharp,
};

// ============================================================
// Format on Save
// ============================================================

pub const Formatter = struct {
    pub const FormatCommand = struct {
        cmd: []const []const u8,
        args: []const []const u8,
    };

    pub fn getFormatter(language: []const u8) ?FormatCommand {
        if (std.mem.eql(u8, language, "zig")) return .{ .cmd = &.{"zig"}, .args = &.{"fmt"} };
        if (std.mem.eql(u8, language, "rust")) return .{ .cmd = &.{"rustfmt"}, .args = &.{} };
        if (std.mem.eql(u8, language, "python")) return .{ .cmd = &.{"black"}, .args = &.{} };
        if (std.mem.eql(u8, language, "javascript")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "typescript")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "go")) return .{ .cmd = &.{"gofmt"}, .args = &.{"-w"} };
        if (std.mem.eql(u8, language, "lua")) return .{ .cmd = &.{"stylua"}, .args = &.{} };
        if (std.mem.eql(u8, language, "json")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "yaml")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "css")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "html")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        if (std.mem.eql(u8, language, "markdown")) return .{ .cmd = &.{"prettier"}, .args = &.{"--write"} };
        return null;
    }

    pub fn formatFile(allocator: Allocator, file_path: []const u8, language: []const u8) !FormatResult {
        const fmt = getFormatter(language) orelse return error.NoFormatter;

        var all_args = std.array_list.Managed([]const u8).init(allocator);
        defer all_args.deinit();
        for (fmt.cmd) |c| try all_args.append(c);
        for (fmt.args) |a| try all_args.append(a);
        try all_args.append(file_path);

        const io = runtime.io();
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const result = try std.process.run(allocator, io, .{
            .argv = all_args.items,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        return FormatResult{
            .success = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            },
            .duration_ms = @intCast(@divTrunc(start.untilNow(io).raw.nanoseconds, std.time.ns_per_ms)),
            .output = result.stdout,
            .errors = result.stderr,
        };
    }
};

pub const FormatResult = struct {
    success: bool,
    duration_ms: u64,
    output: []const u8,
    errors: []const u8,
};

// ============================================================
// Language-specific file type icons
// ============================================================

pub const FileIcons = struct {
    const icon_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "zig", "⚡" },
        .{ "zir", "⚡" },
        .{ "rs", "🦀" },
        .{ "py", "🐍" },
        .{ "pyi", "🐍" },
        .{ "js", "🟨" },
        .{ "jsx", "⚛️" },
        .{ "mjs", "🟨" },
        .{ "ts", "🔷" },
        .{ "tsx", "⚛️" },
        .{ "go", "🔵" },
        .{ "c", "⚙️" },
        .{ "h", "⚙️" },
        .{ "cpp", "⚙️" },
        .{ "hpp", "⚙️" },
        .{ "java", "☕" },
        .{ "rb", "💎" },
        .{ "lua", "🌙" },
        .{ "sh", "🐚" },
        .{ "bash", "🐚" },
        .{ "zsh", "🐚" },
        .{ "html", "🌐" },
        .{ "htm", "🌐" },
        .{ "css", "🎨" },
        .{ "scss", "🎨" },
        .{ "less", "🎨" },
        .{ "json", "📋" },
        .{ "jsonc", "📋" },
        .{ "yaml", "📄" },
        .{ "yml", "📄" },
        .{ "toml", "⚙️" },
        .{ "md", "📝" },
        .{ "mdx", "📝" },
        .{ "sql", "🗄️" },
        .{ "xml", "📰" },
        .{ "dockerfile", "🐳" },
        .{ "makefile", "🔨" },
        .{ "lock", "🔒" },
    });

    pub fn getIcon(file_path: []const u8) []const u8 {
        const ext = std.fs.path.extension(file_path);
        if (icon_map.get(ext)) |icon| return icon;

        // Special filenames (case-insensitive matching)
        const basename = std.fs.path.basename(file_path);
        if (std.ascii.findIgnoreCase(basename, "makefile") != null) return "🔨";
        if (std.ascii.findIgnoreCase(basename, "dockerfile") != null) return "🐳";
        if (std.ascii.findIgnoreCase(basename, ".env") != null) return "🔧";
        if (std.ascii.findIgnoreCase(basename, ".gitignore") != null) return "🙈";
        if (std.ascii.findIgnoreCase(basename, "license") != null) return "📜";
        if (std.ascii.findIgnoreCase(basename, "readme") != null) return "📖";

        return "📄";
    }
};

// ============================================================
// Welcome Page
// ============================================================

pub const WelcomePage = struct {
    pub fn render(writer: anytype, recent_files: []const []const u8) !void {
        try writer.writeAll(
            \\
            \\  ╔══════════════════════════════════════════════════╗
            \\  ║              WIZP Code Editor v0.1.0              ║
            \\  ║        Ultra-lightweight • Zig-powered • AI-ready  ║
            \\  ╠══════════════════════════════════════════════════╣
            \\  ║                                                  ║
            \\  ║  Quick Start:                                    ║
            \\  ║    Ctrl+O      Open file                         ║
            \\  ║    Ctrl+N      New file                          ║
            \\  ║    Ctrl+P      Quick open (goto anything)        ║
            \\  ║    Ctrl+Shift+P Command palette                  ║
            \\  ║                                                  ║
            \\  ║  AI Assistant:                      ║
            \\  ║    Ctrl+I      Inline AI completion              ║
            \\  ║    Ctrl+L      AI Chat                           ║
            \\  ║    Ctrl+,      AI Settings                       ║
            \\  ║                                                  ║
            \\  ║  Start:                                         ║
            \\  ║    wizp --ai ollama codellama:7b                 ║
            \\  ║    wizp --ai openrouter openai/gpt-4o-mini KEY  ║
            \\  ║                                                  ║
        );
        if (recent_files.len > 0) {
            try writer.writeAll("  ║  Recent Files:\n");
            const count = @min(recent_files.len, @as(usize, 8));
            for (recent_files[0..count], 0..) |f, i| {
                try writer.print("  ║    {d}. {s}\n", .{ i + 1, std.fs.path.basename(f) });
            }
        }
        try writer.writeAll(
            \\  ║                                                  ║
            \\  ╚══════════════════════════════════════════════════╝
            \\
        );
    }
};

// ============================================================
// Diagnostics Gutter Icons
// ============================================================

pub const DiagnosticGutter = struct {
    pub const Icon = struct {
        line: usize,
        severity: Severity,
        message: []const u8,

        pub const Severity = enum { err, warn, info, hint };

        pub fn symbol(s: Severity) []const u8 {
            return switch (s) {
                .err => "🔴",
                .warn => "🟡",
                .info => "🔵",
                .hint => "💡",
            };
        }
    };
};

// ============================================================
// Config File (.wizprc)
// ============================================================

pub const WizpConfig = struct {
    theme: []const u8 = "one-dark",
    tab_width: usize = 4,
    use_spaces: bool = true,
    format_on_save: bool = true,
    auto_install_lsp: bool = true,
    show_welcome: bool = true,
    ai_provider: []const u8 = "ollama",
    ai_model: []const u8 = "codellama:7b",
    ai_api_key: ?[]const u8 = null,
    ai_api_base: ?[]const u8 = null,
    lsp_servers: std.StringHashMapUnmanaged([]const u8),

    pub fn load(allocator: Allocator, dir: []const u8) !WizpConfig {
        const path = try std.fs.path.join(allocator, &.{ dir, ".wizprc" });
        defer allocator.free(path);

        var config = WizpConfig{};

        const content = runtime.readFileAlloc(allocator, path, 4096) catch {
            // No config file: dup defaults to heap so deinit can free them unconditionally
            config.theme = try allocator.dupe(u8, config.theme);
            config.ai_provider = try allocator.dupe(u8, config.ai_provider);
            config.ai_model = try allocator.dupe(u8, config.ai_model);
            return config;
        };
        defer allocator.free(content);

        // Parse simple key=value format
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " ");
                const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \"");

                if (std.mem.eql(u8, key, "theme")) config.theme = try allocator.dupe(u8, value);
                if (std.mem.eql(u8, key, "tab_width")) config.tab_width = std.fmt.parseInt(usize, value, 10) catch 4;
                if (std.mem.eql(u8, key, "use_spaces")) config.use_spaces = std.mem.eql(u8, value, "true");
                if (std.mem.eql(u8, key, "format_on_save")) config.format_on_save = std.mem.eql(u8, value, "true");
                if (std.mem.eql(u8, key, "ai_provider")) config.ai_provider = try allocator.dupe(u8, value);
                if (std.mem.eql(u8, key, "ai_model")) config.ai_model = try allocator.dupe(u8, value);
            }
        }

        // Ensure all string fields are heap-allocated so deinit can free unconditionally.
        // Fields not set by config file still hold comptime default pointers.
        if (std.mem.eql(u8, config.theme, "one-dark")) config.theme = try allocator.dupe(u8, config.theme);
        if (std.mem.eql(u8, config.ai_provider, "ollama")) config.ai_provider = try allocator.dupe(u8, config.ai_provider);
        if (std.mem.eql(u8, config.ai_model, "codellama:7b")) config.ai_model = try allocator.dupe(u8, config.ai_model);
        return config;
    }

    pub fn deinit(self: *WizpConfig, allocator: Allocator) void {
        // Free all heap-allocated string fields. Default comptime literals are
        // never freed by load(), so all strings owned by config are heap-allocated.
        allocator.free(self.theme);
        allocator.free(self.ai_provider);
        allocator.free(self.ai_model);
        if (self.ai_api_key) |k| allocator.free(k);
        if (self.ai_api_base) |b| allocator.free(b);
        // Free lsp_servers entries
        var it = self.lsp_servers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.lsp_servers.deinit();
    }
};
