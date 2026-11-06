// First-class language support: Zig & Rust
// Deep integration with toolchains, LSP, build systems, test runners

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// Project Type Detection
// ============================================================

pub const ProjectType = enum {
    zig,
    rust,
    unknown,
};

/// Detect project type from root directory
pub fn detectProject(allocator: Allocator, dir: []const u8) !ProjectType {
    // Check for build.zig / build.zig.zon (Zig)
    const zig_build = try std.fs.path.join(allocator, &.{ dir, "build.zig" });
    defer allocator.free(zig_build);
    if (std.Io.Dir.cwd().access(@import("../runtime_016.zig").io(), zig_build, .{})) |_| {
        return .zig;
    } else |_| {}

    const zig_zon = try std.fs.path.join(allocator, &.{ dir, "build.zig.zon" });
    defer allocator.free(zig_zon);
    if (std.Io.Dir.cwd().access(@import("../runtime_016.zig").io(), zig_zon, .{})) |_| {
        return .zig;
    } else |_| {}

    // Check for Cargo.toml (Rust)
    const cargo = try std.fs.path.join(allocator, &.{ dir, "Cargo.toml" });
    defer allocator.free(cargo);
    if (std.Io.Dir.cwd().access(@import("../runtime_016.zig").io(), cargo, .{})) |_| {
        return .rust;
    } else |_| {}

    return .unknown;
}

// ============================================================
// Build Result
// ============================================================

pub const BuildResult = struct {
    success: bool,
    output: []const u8,
    errors: []const u8,
    duration_ms: u64,

    pub fn deinit(self: *BuildResult, allocator: Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        if (self.errors.len > 0) allocator.free(self.errors);
        self.output = "";
        self.errors = "";
    }
};

pub const TestResult = struct {
    passed: usize,
    failed: usize,
    skipped: usize,
    output: []const u8,
    duration_ms: u64,
};

// ============================================================
// Zig First-Class Support
// ============================================================

pub const ZigSupport = struct {
    allocator: Allocator,
    zig_path: []const u8, // Path to zig binary
    zls_path: ?[]const u8, // Path to ZLS binary
    project_root: []const u8, // Project root directory
    build_target: ?[]const u8 = null, // Build target (for run)

    pub fn init(allocator: Allocator, project_root: []const u8) !ZigSupport {
        // Auto-detect zig binary path
        const zig_path = try findBinary(allocator, "zig") orelse try allocator.dupe(u8, "zig");
        const zls_path = try findBinary(allocator, "zls");

        return ZigSupport{
            .allocator = allocator,
            .zig_path = zig_path,
            .zls_path = zls_path,
            .project_root = try allocator.dupe(u8, project_root),
        };
    }

    /// Build project: `zig build`
    pub fn build(self: *ZigSupport) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Build with specific target: `zig build <step>`
    pub fn buildStep(self: *ZigSupport, step: []const u8) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build", step };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Run project: `zig build run`
    pub fn run(self: *ZigSupport) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build", "run" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Run tests: `zig build test`
    pub fn runTests(self: *ZigSupport) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build", "test" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Run specific test: `zig build test --test-filter <name>`
    pub fn runTestsFilter(self: *ZigSupport, filter: []const u8) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build", "test", "--test-filter", filter };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Format code: `zig fmt <file>`
    pub fn formatFile(self: *ZigSupport, file_path: []const u8) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "fmt", file_path };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Format entire project: `zig fmt <dir>`
    pub fn formatProject(self: *ZigSupport) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "fmt", self.project_root };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Check (no output changes): `zig fmt --check <file>`
    pub fn formatCheck(self: *ZigSupport, file_path: []const u8) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "fmt", "--check", file_path };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Get zig version
    pub fn version(self: *ZigSupport) ![]const u8 {
        const args = [_][]const u8{ self.zig_path, "version" };
        const result = try runCommand(self.allocator, &args, self.project_root);
        return if (result.success) std.mem.trim(u8, result.output, " \n\r") else "unknown";
    }

    /// List available build steps
    pub fn listSteps(self: *ZigSupport) ![]const u8 {
        // zig build --help shows available steps
        const args = [_][]const u8{ self.zig_path, "build", "--help" };
        const result = try runCommand(self.allocator, &args, self.project_root);
        return result.output;
    }

    /// Generate docs: `zig build docs` or `zig std`
    pub fn docs(self: *ZigSupport) !BuildResult {
        const args = [_][]const u8{ self.zig_path, "build", "docs" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Translate C to Zig: `zig translate-c <file>`
    pub fn translateC(self: *ZigSupport, file_path: []const u8) ![]const u8 {
        const args = [_][]const u8{ self.zig_path, "translate-c", file_path };
        const result = try runCommand(self.allocator, &args, self.project_root);
        return result.output;
    }

    /// Check if zig is available
    pub fn isAvailable(self: *ZigSupport) bool {
        const args = [_][]const u8{ self.zig_path, "version" };
        var result = runCommand(self.allocator, &args, self.project_root) catch return false;
        defer result.deinit(self.allocator);
        return result.success;
    }

    /// Get LSP initialization config for ZLS
    pub fn getLspConfig(_: *ZigSupport, allocator: Allocator) ![]const u8 {
        return try allocator.dupe(u8,
            \\{"zig_exe_path":"<auto>","build_runner_path":"<auto>",
            \\"enable_build_on_save":true,"warn_style":true,
            \\"highlight_global_var_declarations":true,
            \\"dangerous_comptime_experiments_do_not_enable":false}
        );
    }

    pub fn deinit(self: *ZigSupport) void {
        self.allocator.free(self.zig_path);
        if (self.zls_path) |p| self.allocator.free(p);
        self.allocator.free(self.project_root);
    }
};

// ============================================================
// Rust First-Class Support
// ============================================================

pub const RustSupport = struct {
    allocator: Allocator,
    cargo_path: []const u8, // Path to cargo binary
    rustc_path: ?[]const u8, // Path to rustc binary
    rustfmt_path: ?[]const u8, // Path to rustfmt binary
    clippy_path: ?[]const u8, // Path to clippy binary
    rust_analyzer_path: ?[]const u8, // Path to rust-analyzer
    project_root: []const u8,

    pub fn init(allocator: Allocator, project_root: []const u8) !RustSupport {
        const cargo_path = try findBinary(allocator, "cargo") orelse try allocator.dupe(u8, "cargo");
        const rustc_path = try findBinary(allocator, "rustc");
        const rustfmt_path = try findBinary(allocator, "rustfmt");
        const clippy_path = try findBinary(allocator, "clippy-driver");
        const ra_path = try findBinary(allocator, "rust-analyzer");

        return RustSupport{
            .allocator = allocator,
            .cargo_path = cargo_path,
            .rustc_path = rustc_path,
            .rustfmt_path = rustfmt_path,
            .clippy_path = clippy_path,
            .rust_analyzer_path = ra_path,
            .project_root = try allocator.dupe(u8, project_root),
        };
    }

    /// Build: `cargo build`
    pub fn build(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "build" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Release build: `cargo build --release`
    pub fn buildRelease(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "build", "--release" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Run: `cargo run`
    pub fn run(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "run" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Test: `cargo test`
    pub fn runTests(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "test" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Test single: `cargo test <name>`
    pub fn runTestsFilter(self: *RustSupport, filter: []const u8) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "test", filter };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Check: `cargo check` (fast, no codegen)
    pub fn check(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "check" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Format: `cargo fmt`
    pub fn format(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "fmt" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Format check: `cargo fmt -- --check`
    pub fn formatCheck(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "fmt", "--", "--check" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Clippy: `cargo clippy`
    pub fn clippy(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "clippy" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Clippy with all lints: `cargo clippy -- -W clippy::all`
    pub fn clippyPedantic(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "clippy", "--", "-W", "clippy::all" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Docs: `cargo doc --open`
    pub fn docs(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "doc" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Update dependencies: `cargo update`
    pub fn update(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "update" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Add dependency: `cargo add <crate>`
    pub fn addCrate(self: *RustSupport, crate_name: []const u8, features: ?[]const u8) !BuildResult {
        var arg_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer arg_list.deinit();
        try arg_list.append(self.cargo_path);
        try arg_list.append("add");
        try arg_list.append(crate_name);
        if (features) |f| {
            try arg_list.append("--features");
            try arg_list.append(f);
        }
        return runCommand(self.allocator, arg_list.items, self.project_root);
    }

    /// Clean: `cargo clean`
    pub fn clean(self: *RustSupport) !BuildResult {
        const args = [_][]const u8{ self.cargo_path, "clean" };
        return runCommand(self.allocator, &args, self.project_root);
    }

    /// Get rustc version
    pub fn version(self: *RustSupport) ![]const u8 {
        const args = [_][]const u8{ self.cargo_path, "--version" };
        const result = try runCommand(self.allocator, &args, self.project_root);
        return if (result.success) std.mem.trim(u8, result.output, " \n\r") else "unknown";
    }

    /// List available targets/binaries in Cargo.toml
    pub fn listTargets(self: *RustSupport) ![]const u8 {
        const args = [_][]const u8{ self.cargo_path, "metadata", "--format-version=1", "--no-deps" };
        const result = try runCommand(self.allocator, &args, self.project_root);
        return result.output;
    }

    /// Get LSP config for rust-analyzer
    pub fn getLspConfig(_: *RustSupport, allocator: Allocator) ![]const u8 {
        return try allocator.dupe(u8,
            \\{"checkOnSave":{"command":"clippy"},"cargo":{"buildScripts":true},
            \\"procMacro":true,"completion":{"postfix":true},
            \\"diagnostics":true,"inlayHints":true}
        );
    }

    pub fn deinit(self: *RustSupport) void {
        self.allocator.free(self.cargo_path);
        if (self.rustc_path) |p| self.allocator.free(p);
        if (self.rustfmt_path) |p| self.allocator.free(p);
        if (self.clippy_path) |p| self.allocator.free(p);
        if (self.rust_analyzer_path) |p| self.allocator.free(p);
        self.allocator.free(self.project_root);
    }
};

// ============================================================
// Unified Language Manager
// ============================================================

pub const LanguageManager = struct {
    allocator: Allocator,
    zig: ?ZigSupport = null,
    rust: ?RustSupport = null,
    project_type: ProjectType = .unknown,
    project_root: []const u8,

    pub fn init(allocator: Allocator, project_root: []const u8) !LanguageManager {
        var lm = LanguageManager{
            .allocator = allocator,
            .project_root = try allocator.dupe(u8, project_root),
        };
        lm.project_type = try detectProject(allocator, project_root);

        switch (lm.project_type) {
            .zig => lm.zig = try ZigSupport.init(allocator, project_root),
            .rust => lm.rust = try RustSupport.init(allocator, project_root),
            .unknown => {},
        }
        return lm;
    }

    /// Build project using appropriate toolchain
    pub fn build(self: *LanguageManager) !BuildResult {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| z.build() else error.NoToolchain,
            .rust => if (self.rust) |*r| r.build() else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    /// Run project
    pub fn run(self: *LanguageManager) !BuildResult {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| z.run() else error.NoToolchain,
            .rust => if (self.rust) |*r| r.run() else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    /// Run tests
    pub fn runTests(self: *LanguageManager, filter: ?[]const u8) !BuildResult {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| if (filter) |f| z.runTestsFilter(f) else z.runTests() else error.NoToolchain,
            .rust => if (self.rust) |*r| if (filter) |f| r.runTestsFilter(f) else r.runTests() else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    /// Format code
    pub fn format(self: *LanguageManager, file_path: []const u8) !BuildResult {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| z.formatFile(file_path) else error.NoToolchain,
            .rust => if (self.rust) |*r| r.format() else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    /// Get LSP configuration for the detected language
    pub fn getLspConfig(self: *LanguageManager, allocator2: Allocator) ![]const u8 {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| z.getLspConfig(allocator2) else error.NoToolchain,
            .rust => if (self.rust) |*r| r.getLspConfig(allocator2) else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    /// Get available build steps/targets
    pub fn listTargets(self: *LanguageManager) ![]const u8 {
        return switch (self.project_type) {
            .zig => if (self.zig) |*z| z.listSteps() else error.NoToolchain,
            .rust => if (self.rust) |*r| r.listTargets() else error.NoToolchain,
            .unknown => error.NoToolchain,
        };
    }

    pub fn deinit(self: *LanguageManager) void {
        if (self.zig) |*z| z.deinit();
        if (self.rust) |*r| r.deinit();
        self.allocator.free(self.project_root);
    }
};

// ============================================================
// Snippets for Zig & Rust
// ============================================================

pub const ZIG_SNIPPETS = [_]SnippetDef{
    .{ .trigger = "fn", .desc = "Function", .body = "fn ${1:name}(${2:params}) ${3:ReturnType} {\n    ${0}\n}" },
    .{ .trigger = "pubfn", .desc = "Public function", .body = "pub fn ${1:name}(${2:params}) ${3:ReturnType} {\n    ${0}\n}" },
    .{ .trigger = "zigtest", .desc = "Zig test block", .body = "test \"${1:name}\" {\n    ${0}\n}" },
    .{ .trigger = "struct", .desc = "Struct", .body = "const ${1:Name} = struct {\n    ${0}\n};" },
    .{ .trigger = "enum", .desc = "Enum", .body = "const ${1:Name} = enum {\n    ${0}\n};" },
    .{ .trigger = "if", .desc = "If statement", .body = "if (${1:condition}) {\n    ${0}\n}" },
    .{ .trigger = "ife", .desc = "If-else", .body = "if (${1:condition}) {\n    ${2}\n} else {\n    ${0}\n}" },
    .{ .trigger = "for", .desc = "For loop", .body = "for (${1:items}) |${2:item}| {\n    ${0}\n}" },
    .{ .trigger = "while", .desc = "While loop", .body = "while (${1:condition}) : (${2:increment}) {\n    ${0}\n}" },
    .{ .trigger = "switch", .desc = "Switch", .body = "switch (${1:value}) {\n    ${2:pattern} => ${0},\n    else => unreachable,\n}" },
    .{ .trigger = "try", .desc = "Try-catch", .body = "${1:expr} catch |err| {\n    ${0}\n}" },
    .{ .trigger = "alloc", .desc = "Allocator pattern", .body = "const allocator = std.self.allocator;\n${0}" },
    .{ .trigger = "main", .desc = "Main function", .body = "pub fn main() !void {\n    ${0}\n}" },
    .{ .trigger = "print", .desc = "Debug print", .body = "std.debug.print(\"{s}\\n\", .{${1:value}});" },
    .{ .trigger = "defer", .desc = "Defer", .body = "defer ${1:expr};" },
    .{ .trigger = "comptime", .desc = "Comptime block", .body = "comptime {\n    ${0}\n}" },
    .{ .trigger = "ArrayList", .desc = "ArrayList type", .body = "std.array_list.Managed(${1:T})" },
    .{ .trigger = "HashMap", .desc = "HashMap type", .body = "std.StringHashMap(${1:V})" },
    .{ .trigger = "buf", .desc = "Buffer print", .body = "var buf: [${1:1024}]u8 = undefined;\nconst str = try std.fmt.bufPrint(&buf, \"${2}\", .{${3}});" },
    .{ .trigger = "gpa", .desc = "Debug allocator", .body = "var debug_allocator = std.heap.DebugAllocator(.{}).init;\ndefer _ = debug_allocator.deinit();\nconst allocator = debug_allocator.allocator();" },
};

pub const RUST_SNIPPETS = [_]SnippetDef{
    .{ .trigger = "fn", .desc = "Function", .body = "fn ${1:name}(${2:params}) -> ${3:ReturnType} {\n    ${0}\n}" },
    .{ .trigger = "pubfn", .desc = "Public function", .body = "pub fn ${1:name}(${2:params}) -> ${3:ReturnType} {\n    ${0}\n}" },
    .{ .trigger = "zigtest", .desc = "Test", .body = "#[test]\nfn ${1:name}() {\n    ${0}\n}" },
    .{ .trigger = "mod", .desc = "Test module", .body = "#[cfg(test)]\nmod tests {\n    use super::*;\n\n    #[test]\n    fn ${1:name}() {\n        ${0}\n    }\n}" },
    .{ .trigger = "struct", .desc = "Struct", .body = "struct ${1:Name} {\n    ${0}\n}" },
    .{ .trigger = "impl", .desc = "Impl block", .body = "impl ${1:Type} {\n    ${0}\n}" },
    .{ .trigger = "trait", .desc = "Trait", .body = "trait ${1:Name} {\n    ${0}\n}" },
    .{ .trigger = "enum", .desc = "Enum", .body = "enum ${1:Name} {\n    ${0}\n}" },
    .{ .trigger = "match", .desc = "Match", .body = "match ${1:value} {\n    ${2:pattern} => ${0},\n}" },
    .{ .trigger = "iflet", .desc = "If let", .body = "if let ${1:pattern} = ${2:expr} {\n    ${0}\n}" },
    .{ .trigger = "for", .desc = "For loop", .body = "for ${1:item} in ${2:iter} {\n    ${0}\n}" },
    .{ .trigger = "iter", .desc = "Iterator method", .body = ".iter().${1:map}(|${2:x}| ${0})" },
    .{ .trigger = "println", .desc = "Print line", .body = "println!(\"{}\", ${1:value});" },
    .{ .trigger = "format", .desc = "Format macro", .body = "format!(\"{}\", ${1:value})" },
    .{ .trigger = "vec", .desc = "Vec macro", .body = "vec![${0}]" },
    .{ .trigger = "derive", .desc = "Derive", .body = "#[derive(Debug, Clone${1:, Serialize, Deserialize})]" },
    .{ .trigger = "main", .desc = "Main function", .body = "fn main() {\n    ${0}\n}" },
    .{ .trigger = "Result", .desc = "Result type", .body = "Result<${1:T}, ${2:E}>" },
    .{ .trigger = "Option", .desc = "Option type", .body = "Option<${1:T}>" },
    .{ .trigger = "unwrap", .desc = "Unwrap-or pattern", .body = "${1:value}.unwrap_or(${0})" },
    .{ .trigger = "ok", .desc = "Ok/Err", .body = "Ok(${1:value})" },
    .{ .trigger = "closure", .desc = "Closure", .body = "|${1:x}| ${0}" },
    .{ .trigger = "mut", .desc = "Mutable variable", .body = "let mut ${1:name} = ${0};" },
    .{ .trigger = "let", .desc = "Let binding", .body = "let ${1:name} = ${0};" },
};

pub const SnippetDef = struct {
    trigger: []const u8,
    desc: []const u8,
    body: []const u8,
};

// ============================================================
// Utility: find binary in PATH
// ============================================================

fn findBinary(allocator: Allocator, name: []const u8) !?[]const u8 {
    const path_env_owned = @import("../runtime_016.zig").getEnvVarOwned(allocator, "PATH") catch null;
    defer if (path_env_owned) |value| allocator.free(value);
    const path_env = path_env_owned orelse "/usr/bin:/usr/local/bin:/bin";
    var paths = std.mem.splitScalar(u8, path_env, ':');
    while (paths.next()) |dir| {
        const full = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(full);
        if (std.Io.Dir.cwd().access(@import("../runtime_016.zig").io(), full, .{})) |_| {
            return try allocator.dupe(u8, full);
        } else |_| {}
    }
    return null;
}

/// Run a command and capture output
fn runCommand(allocator: Allocator, args: []const []const u8, cwd: []const u8) !BuildResult {
    const runtime = @import("../runtime_016.zig");
    const start = runtime.milliTimestamp();
    const result = try std.process.run(allocator, runtime.io(), .{
        .argv = args,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    const duration = @as(u64, @intCast(runtime.milliTimestamp() - start));
    return .{
        .success = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .output = result.stdout,
        .errors = result.stderr,
        .duration_ms = duration,
    };
}
