// WIZP Tree-sitter Grammar Runtime Loader
// Dynamically loads .so grammar files for incremental parsing.
// Downloads grammars from GitHub releases on first use.

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Represents a dynamically loaded Tree-sitter grammar (.so/.dylib/.dll)
pub const Grammar = struct {
    name: []const u8,
    language: *anyopaque, // TSLanguage pointer
    lib: std.posix.DynLib,
    allocator: Allocator,

    const Self = @This();

    /// Load a grammar from a shared library file path.
    pub fn load(allocator: Allocator, name: []const u8, path: []const u8) !Self {
        var lib = try std.posix.DynLib.open(path);
        errdefer lib.close();

        // Tree-sitter grammars export a function named "tree_sitter_<name>"
        const symbol_name = try std.fmt.allocPrint(allocator, "tree_sitter_{s}", .{name});
        defer allocator.free(symbol_name);

        const language = lib.lookup(*anyopaque, symbol_name) catch {
            lib.close();
            return error.GrammarSymbolNotFound;
        };

        return Self{
            .name = try allocator.dupe(u8, name),
            .language = language,
            .lib = lib,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.lib.close();
        self.* = undefined;
    }
};

/// Grammar registry — manages downloaded and loaded grammars.
pub const GrammarRegistry = struct {
    allocator: Allocator,
    grammars: std.StringHashMapUnmanaged(Grammar),
    cache_dir: []const u8,

    const Self = @This();

    /// Known grammar download URLs (GitHub releases)
    const GRAMMAR_REPOS = [_]struct { name: []const u8, repo: []const u8 }{
        .{ .name = "json", .repo = "tree-sitter/tree-sitter-json" },
        .{ .name = "javascript", .repo = "tree-sitter/tree-sitter-javascript" },
        .{ .name = "python", .repo = "tree-sitter/tree-sitter-python" },
        .{ .name = "rust", .repo = "tree-sitter/tree-sitter-rust" },
        .{ .name = "go", .repo = "tree-sitter/tree-sitter-go" },
        .{ .name = "c", .repo = "tree-sitter/tree-sitter-c" },
        .{ .name = "cpp", .repo = "tree-sitter/tree-sitter-cpp" },
        .{ .name = "bash", .repo = "tree-sitter/tree-sitter-bash" },
        .{ .name = "html", .repo = "tree-sitter/tree-sitter-html" },
        .{ .name = "css", .repo = "tree-sitter/tree-sitter-css" },
        .{ .name = "markdown", .repo = "tree-sitter/tree-sitter-markdown" },
        .{ .name = "typescript", .repo = "tree-sitter/tree-sitter-typescript" },
        .{ .name = "yaml", .repo = "tree-sitter/tree-sitter-yaml" },
        .{ .name = "toml", .repo = "tree-sitter/tree-sitter-toml" },
        .{ .name = "lua", .repo = "tree-sitter/tree-sitter-lua" },
        .{ .name = "zig", .repo = "tree-sitter/tree-sitter-zig" },
    };

    pub fn init(allocator: Allocator, cache_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
    }

    /// Get or download a grammar by name.
    pub fn getGrammar(self: *Self, name: []const u8) !*Grammar {
        if (self.grammars.getPtr(name)) |g| return g;

        const ext = switch (builtin.os.tag) {
            .linux => "so",
            .macos => "dylib",
            .windows => "dll",
            else => return error.UnsupportedPlatform,
        };

        const filename = try std.fmt.allocPrint(self.allocator, "tree-sitter-{s}.{s}", .{ name, ext });
        defer self.allocator.free(filename);

        const path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, filename });
        defer self.allocator.free(path);

        // Check if already downloaded
        const file = std.Io.Dir.openFileAbsolute(runtime.io(), path, .{}) catch null;
        if (file) |opened_file| {
            opened_file.close(runtime.io());
            var grammar = try Grammar.load(self.allocator, name, path);
            try self.grammars.put(self.allocator, try self.allocator.dupe(u8, name), grammar);
            return self.grammars.getPtr(name).?;
        }

        return error.GrammarNotDownloaded;
    }

    /// Download a grammar from GitHub releases.
    pub fn downloadGrammar(self: *Self, name: []const u8) !void {
        // Find repo URL
        var repo_url: ?[]const u8 = null;
        for (GRAMMAR_REPOS) |repo| {
            if (std.mem.eql(u8, repo.name, name)) {
                repo_url = repo.repo;
                break;
            }
        }
        const repo = repo_url orelse return error.UnknownGrammar;

        // Determine platform-specific release asset
        const platform_tag = switch (builtin.os.tag) {
            .linux => "linux-x64",
            .macos => "macos",
            .windows => "windows-x64",
            else => return error.UnsupportedPlatform,
        };

        const download_url = try std.fmt.allocPrint(
            self.allocator,
            "https://github.com/{s}/releases/latest/download/tree-sitter-{s}-{s}.so",
            .{ repo, name, platform_tag },
        );
        defer self.allocator.free(download_url);

        std.log.warn(
            "automatic grammar download is unavailable for {s}; install it from {s}",
            .{ name, download_url },
        );
        return error.AutomaticDownloadUnavailable;
    }

    pub fn deinit(self: *Self) void {
        var it = self.grammars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var grammar = entry.value_ptr.*;
            grammar.deinit();
        }
        self.grammars.deinit();
    }
};

test "GrammarRegistry: init" {
    var reg = GrammarRegistry.init(std.testing.allocator, "/tmp/wizp-grammars");
    defer reg.deinit();
}

test "GrammarRegistry: unknown grammar" {
    var reg = GrammarRegistry.init(std.testing.allocator, "/tmp/wizp-grammars");
    defer reg.deinit();
    try std.testing.expectError(error.GrammarNotDownloaded, reg.getGrammar("nonexistent"));
}
