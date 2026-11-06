// WIZP Hub - Centralized Package Manager
// Downloads and manages LSPs, language tools, plugins, themes, snippets
// Similar to VS Code marketplace with unified catalog

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const http = std.http;
const zip = @import("zip.zig");

// ============================================================
// Package Types
// ============================================================

pub const PackageKind = enum {
    lsp_server, // Language Server (zls, rust-analyzer, etc.)
    language_tool, // Language toolchain (zig, rust, go, node, etc.)
    plugin, // Editor plugin/extension
    theme, // Color theme
    snippet, // Snippet collection
    build_system, // Build system definition
    syntax, // Syntax definition
};

pub const Platform = enum {
    linux_x64,
    linux_arm64,
    macos_x64,
    macos_arm64,
    windows_x64,
    windows_arm64,
};

// ============================================================
// Package Registry Entry
// ============================================================

pub const PackageEntry = struct {
    id: []const u8, // Unique ID: "zls", "rust-analyzer", "dracula-theme"
    name: []const u8, // Display name
    kind: PackageKind,
    description: []const u8,
    version: []const u8,
    author: []const u8 = "",
    homepage: []const u8 = "",
    repository: []const u8 = "",
    license: []const u8 = "MIT",
    icon: []const u8 = "",
    tags: []const []const u8 = &.{},
    /// Language this package targets (for LSPs/tools)
    language: []const u8 = "",
    /// Dependencies on other packages
    dependencies: []const []const u8 = &.{},
    /// Download info per platform
    downloads: []const PlatformDownload = &.{},
    /// Minimum Zedit version
    min_zedit_version: []const u8 = "0.1.0",
    /// Install size estimate (bytes)
    size_bytes: usize = 0,
    /// Rating (0-5)
    rating: f32 = 0.0,
    /// Download count
    downloads_count: usize = 0,
    /// Whether this is a built-in package
    builtin: bool = false,

    pub const PlatformDownload = struct {
        platform: Platform,
        url: []const u8,
        /// SHA256 hash for verification
        hash: ?[]const u8 = null,
        /// Install method
        method: InstallMethod = .download_extract,

        pub const InstallMethod = enum {
            download_extract, // Download archive and extract
            download_binary, // Download single binary
            git_clone, // Clone from git
            npm_install, // npm install -g
            cargo_install, // cargo install
            go_install, // go install
            pip_install, // pip install
            system_package, // apt/pacman/brew install
        };
    };
};

// ============================================================
// Installed Package
// ============================================================

pub const InstalledPackage = struct {
    entry: PackageEntry,
    install_path: []const u8,
    install_date: i64,
    auto_update: bool = true,
};

const PersistedPackage = struct {
    id: []const u8,
    install_path: []const u8,
    install_date: i64,
    auto_update: bool,
};
// Marketplace Registry
// ============================================================

pub const Registry = struct {
    packages: std.StringHashMapUnmanaged(PackageEntry),

    pub fn init(allocator: Allocator) !Registry {
        var reg = Registry{ .packages = .{} };
        try reg.loadBuiltinCatalog(allocator);
        return reg;
    }

    /// Load the built-in catalog of LSPs and language tools
    fn loadBuiltinCatalog(self: *Registry, allocator: Allocator) !void {
        const entries = comptime builtinCatalog();
        for (entries) |*entry| {
            const key = try allocator.dupe(u8, entry.id);
            errdefer allocator.free(key);
            try self.packages.put(allocator, key, entry.*);
        }
    }

    /// Search packages by query
    pub fn search(self: *Registry, allocator: Allocator, query: []const u8, kind: ?PackageKind) ![]const PackageEntry {
        var results = std.array_list.Managed(PackageEntry).init(allocator);
        defer results.deinit();
        var it = self.packages.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (kind != null and entry.kind != kind.?) continue;
            if (matchesQuery(query, entry.name) or matchesQuery(query, entry.description) or
                matchesQuery(query, entry.language))
            {
                try results.append(entry);
            }
        }
        return results.toOwnedSlice();
    }

    /// Get a specific package by ID
    pub fn get(self: *Registry, id: []const u8) ?PackageEntry {
        return self.packages.get(id);
    }

    pub fn deinit(self: *Registry, allocator: Allocator) void {
        var it = self.packages.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
        }
        self.packages.deinit(allocator);
    }
};

fn matchesQuery(query: []const u8, text: []const u8) bool {
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(text, query) != null;
}

// ============================================================
// Package Installer
// ============================================================

pub const InstallStatus = enum {
    pending,
    downloading,
    extracting,
    installing,
    completed,
    failed,
};

pub const InstallProgress = struct {
    status: InstallStatus,
    bytes_downloaded: usize = 0,
    total_bytes: usize = 0,
    message: []const u8 = "",
};

pub const Installer = struct {
    allocator: Allocator,
    client: http.Client,
    install_dir: []const u8,
    installed: std.StringHashMapUnmanaged(InstalledPackage),

    const Self = @This();

    pub fn init(allocator: Allocator, install_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator, .io = runtime.io() },
            .install_dir = install_dir,
            .installed = .{},
        };
    }

    /// Install a package from the registry
    pub fn install(self: *Self, entry: PackageEntry, on_progress: ?*const fn (InstallProgress) void) !void {
        // Check if already installed
        if (self.installed.contains(entry.id)) {
            return error.AlreadyInstalled;
        }

        // Resolve platform download
        const dl = self.resolvePlatformDownload(entry) orelse return error.UnsupportedPlatform;

        // Create install directory
        const pkg_dir = try std.fs.path.join(self.allocator, &.{ self.install_dir, entry.id });
        defer self.allocator.free(pkg_dir);
        try std.Io.Dir.cwd().createDirPath(runtime.io(), pkg_dir);

        // Download and install based on method
        switch (dl.method) {
            .download_extract => try self.downloadAndExtract(entry, dl, pkg_dir, on_progress),
            .download_binary => try self.downloadBinary(entry, dl, pkg_dir, on_progress),
            .git_clone => try self.gitClone(entry, dl, pkg_dir, on_progress),
            .npm_install => try self.npmInstall(entry, dl, pkg_dir, on_progress),
            .cargo_install => try self.cargoInstall(entry, dl, pkg_dir, on_progress),
            .go_install => try self.goInstall(entry, dl, pkg_dir, on_progress),
            .pip_install => try self.pipInstall(entry, dl, pkg_dir, on_progress),
            .system_package => try self.systemInstall(entry, dl, pkg_dir, on_progress),
        }

        // Record installation
        const path_dup = try self.allocator.dupe(u8, pkg_dir);
        try self.installed.put(self.allocator, entry.id, .{
            .entry = entry,
            .install_path = path_dup,
            .install_date = runtime.milliTimestamp(),
        });
    }

    /// Uninstall a package
    pub fn uninstall(self: *Self, package_id: []const u8) !void {
        if (self.installed.fetchRemove(package_id)) |kv| {
            const pkg = kv.value;
            self.allocator.free(pkg.install_path);
            // Delete install directory
            std.Io.Dir.cwd().deleteTree(runtime.io(), pkg.install_path) catch {};
        }
    }

    /// Update a package to latest version
    pub fn update(self: *Self, registry: *Registry, package_id: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        if (registry.get(package_id)) |latest| {
            try self.uninstall(package_id);
            try self.install(latest, on_progress);
        }
    }

    /// Check for updates across all installed packages
    pub fn checkUpdates(self: *Self, registry: *Registry, allocator: Allocator) ![]const UpdateInfo {
        var updates = std.array_list.Managed(UpdateInfo).init(allocator);
        var it = self.installed.iterator();
        while (it.next()) |kv| {
            if (registry.get(kv.key_ptr.*)) |latest| {
                if (!std.mem.eql(u8, kv.value_ptr.entry.version, latest.version)) {
                    try updates.append(.{
                        .id = kv.key_ptr.*,
                        .name = latest.name,
                        .current_version = kv.value_ptr.entry.version,
                        .latest_version = latest.version,
                    });
                }
            }
        }
        return updates.toOwnedSlice();
    }

    /// List all installed packages
    pub fn listInstalled(self: *Self, allocator: Allocator) ![]const InstalledPackage {
        var result = std.array_list.Managed(InstalledPackage).init(allocator);
        var it = self.installed.iterator();
        while (it.next()) |kv| {
            try result.append(kv.value_ptr.*);
        }
        return result.toOwnedSlice();
    }

    // ============================================================
    // Install Methods
    // ============================================================

    fn downloadAndExtract(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        const archive_path = try std.fs.path.join(self.allocator, &.{ dest, "download.archive" });
        defer self.allocator.free(archive_path);

        // Download
        try self.downloadFile(dl.url, archive_path, on_progress);

        // Extract based on extension
        if (std.mem.endsWith(u8, dl.url, ".tar.gz") or std.mem.endsWith(u8, dl.url, ".tgz")) {
            try self.extractTarGz(archive_path, dest);
        } else if (std.mem.endsWith(u8, dl.url, ".tar.xz")) {
            try self.extractTarXz(archive_path, dest);
        } else if (std.mem.endsWith(u8, dl.url, ".zip")) {
            try self.extractZip(archive_path, dest);
        }
    }

    fn downloadBinary(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        const name = entry.id;
        const bin_path = try std.fs.path.join(self.allocator, &.{ dest, name });
        defer self.allocator.free(bin_path);
        try self.downloadFile(dl.url, bin_path, on_progress);

        // Make executable
        std.Io.Dir.cwd().setFilePermissions(
            runtime.io(),
            bin_path,
            .fromMode(0o755),
            .{},
        ) catch {};
    }

    fn runInstallCommand(
        self: *Self,
        args: []const []const u8,
        failure_label: []const u8,
        completion_message: []const u8,
        on_progress: ?*const fn (InstallProgress) void,
    ) !void {
        const result = try std.process.run(self.allocator, runtime.io(), .{
            .argv = args,
            .stdout_limit = .limited(65536),
            .stderr_limit = .limited(65536),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const exit_code: u8 = switch (result.term) {
            .exited => |code| code,
            else => 1,
        };
        if (exit_code != 0) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "{s} failed (exit {}): {s}",
                .{ failure_label, exit_code, result.stderr },
            );
            defer self.allocator.free(message);
            if (on_progress) |callback| callback(.{ .status = .failed, .message = message });
            return error.InstallFailed;
        }
        if (on_progress) |callback| {
            callback(.{ .status = .completed, .message = completion_message });
        }
    }

    fn gitClone(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        if (on_progress) |callback| {
            callback(.{ .status = .installing, .message = "Cloning repository..." });
        }
        const args = [_][]const u8{ "git", "clone", "--depth", "1", dl.url, dest };
        try self.runInstallCommand(&args, "git clone", "Clone complete", on_progress);
    }

    fn npmInstall(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        if (on_progress) |callback| {
            callback(.{ .status = .installing, .message = "npm install..." });
        }
        const args = [_][]const u8{ "npm", "install", "--prefix", dest, dl.url };
        try self.runInstallCommand(&args, "npm install", "npm install complete", on_progress);
    }

    fn cargoInstall(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        if (on_progress) |callback| {
            callback(.{ .status = .installing, .message = "cargo install..." });
        }
        const args = [_][]const u8{ "cargo", "install", "--root", dest, dl.url };
        try self.runInstallCommand(&args, "cargo install", "cargo install complete", on_progress);
    }

    fn goInstall(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        _ = dest;
        if (on_progress) |callback| callback(.{ .status = .installing, .message = "go install..." });
        const args = [_][]const u8{ "go", "install", dl.url };
        try self.runInstallCommand(&args, "go install", "go install complete", on_progress);
    }

    fn pipInstall(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        if (on_progress) |callback| callback(.{ .status = .installing, .message = "pip install..." });
        const args = [_][]const u8{ "pip", "install", "--target", dest, dl.url };
        try self.runInstallCommand(&args, "pip install", "pip install complete", on_progress);
    }

    fn systemInstall(self: *Self, entry: PackageEntry, dl: PackageEntry.PlatformDownload, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        _ = entry;
        _ = dest;
        if (on_progress) |callback| {
            callback(.{ .status = .installing, .message = "Installing via system package manager..." });
        }
        const args = [_][]const u8{dl.url};
        try self.runInstallCommand(&args, "system install", "Install complete", on_progress);
    }

    /// Download a file with progress callback
    fn downloadFile(self: *Self, url: []const u8, dest: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodyComplete(&.{});
        var redirect_buffer: [4096]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        var file = try std.Io.Dir.cwd().createFile(runtime.io(), dest, .{});
        defer file.close(runtime.io());
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try reader.*.readSliceShort(&buf);
            if (n == 0) break;
            try runtime.writeAll(file, buf[0..n]);
            total += n;
            if (on_progress) |cb| cb(.{ .status = .downloading, .bytes_downloaded = total });
        }
    }

    /// Extract .tar.gz archive
    fn extractTarGz(self: *Self, archive: []const u8, dest: []const u8) !void {
        const args = [_][]const u8{ "tar", "xzf", archive, "-C", dest };
        try self.runInstallCommand(&args, "tar.gz extraction", "Extraction complete", null);
    }

    fn extractTarXz(self: *Self, archive: []const u8, dest: []const u8) !void {
        const args = [_][]const u8{ "tar", "xJf", archive, "-C", dest };
        try self.runInstallCommand(&args, "tar.xz extraction", "Extraction complete", null);
    }

    fn extractZip(self: *Self, archive: []const u8, dest: []const u8) !void {
        try zip.extractAll(self.allocator, archive, dest);
    }

    /// Resolve the best platform download for current system
    fn resolvePlatformDownload(_: *Self, entry: PackageEntry) ?PackageEntry.PlatformDownload {
        const current = detectPlatform();
        for (entry.downloads) |dl| {
            if (dl.platform == current) return dl;
        }
        // Fallback: first available
        if (entry.downloads.len > 0) return entry.downloads[0];
        return null;
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        var it = self.installed.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.install_path);
        }
        self.installed.deinit(self.allocator);
        self.allocator.free(self.install_dir);
    }
};

pub const UpdateInfo = struct {
    id: []const u8,
    name: []const u8,
    current_version: []const u8,
    latest_version: []const u8,
};

/// Detect current platform
pub fn detectPlatform() Platform {
    const target = @import("builtin");
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => .linux_x64,
            .aarch64 => .linux_arm64,
            else => .linux_x64,
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => .macos_x64,
            .aarch64 => .macos_arm64,
            else => .macos_arm64,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => .windows_x64,
            .aarch64 => .windows_arm64,
            else => .windows_x64,
        },
        else => .linux_x64,
    };
}

// ============================================================
// Built-in Catalog
// ============================================================

fn builtinCatalog() []const PackageEntry {
    return &.{
        // ---- LSP Servers ----
        PackageEntry{
            .id = "zls",
            .name = "Zig Language Server",
            .kind = .lsp_server,
            .description = "Official Zig Language Server (zls) - completions, hover, goto definition",
            .version = "0.13.0",
            .author = "Zig Community",
            .language = "zig",
            .repository = "https://github.com/zigtools/zls",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/zigtools/zls/releases/download/0.13.0/zls-x86_64-linux.tar.gz", .method = .download_extract },
                .{ .platform = .macos_arm64, .url = "https://github.com/zigtools/zls/releases/download/0.13.0/zls-aarch64-macos.tar.gz", .method = .download_extract },
                .{ .platform = .windows_x64, .url = "https://github.com/zigtools/zls/releases/download/0.13.0/zls-x86_64-windows.zip", .method = .download_extract },
            },
            .size_bytes = 8_000_000,
            .tags = &.{ "zig", "lsp", "completions" },
        },
        PackageEntry{
            .id = "rust-analyzer",
            .name = "Rust Analyzer",
            .kind = .lsp_server,
            .description = "Official Rust Language Server - fast completions, diagnostics, refactoring",
            .version = "2024-12-16",
            .author = "Rust Project",
            .language = "rust",
            .repository = "https://github.com/rust-lang/rust-analyzer",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-unknown-linux-gnu.gz", .method = .download_binary },
                .{ .platform = .macos_arm64, .url = "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-aarch64-apple-darwin.gz", .method = .download_binary },
                .{ .platform = .windows_x64, .url = "https://github.com/rust-lang/rust-analyzer/releases/latest/download/rust-analyzer-x86_64-pc-windows-msvc.zip", .method = .download_extract },
            },
            .size_bytes = 25_000_000,
            .tags = &.{ "rust", "lsp", "completions", "refactoring" },
        },
        PackageEntry{
            .id = "pyright",
            .name = "Pyright",
            .kind = .lsp_server,
            .description = "Static type checker and LSP for Python by Microsoft",
            .version = "1.1.390",
            .author = "Microsoft",
            .language = "python",
            .repository = "https://github.com/microsoft/pyright",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "pyright", .method = .npm_install },
                .{ .platform = .macos_arm64, .url = "pyright", .method = .npm_install },
                .{ .platform = .windows_x64, .url = "pyright", .method = .npm_install },
            },
            .size_bytes = 15_000_000,
            .tags = &.{ "python", "lsp", "type-checking" },
        },
        PackageEntry{
            .id = "typescript-language-server",
            .name = "TypeScript Language Server",
            .kind = .lsp_server,
            .description = "Official TypeScript/JavaScript LSP server",
            .version = "4.4.0",
            .author = "Microsoft",
            .language = "typescript",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "typescript-language-server", .method = .npm_install },
                .{ .platform = .macos_arm64, .url = "typescript-language-server", .method = .npm_install },
                .{ .platform = .windows_x64, .url = "typescript-language-server", .method = .npm_install },
            },
            .size_bytes = 10_000_000,
            .tags = &.{ "typescript", "javascript", "lsp" },
        },
        PackageEntry{
            .id = "gopls",
            .name = "gopls",
            .kind = .lsp_server,
            .description = "Official Go Language Server",
            .version = "0.17.1",
            .author = "Google",
            .language = "go",
            .repository = "https://github.com/golang/tools/tree/master/gopls",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "golang.org/x/tools/gopls@latest", .method = .go_install },
                .{ .platform = .macos_arm64, .url = "golang.org/x/tools/gopls@latest", .method = .go_install },
            },
            .size_bytes = 20_000_000,
            .tags = &.{ "go", "lsp" },
        },
        PackageEntry{
            .id = "lua-language-server",
            .name = "Lua Language Server",
            .kind = .lsp_server,
            .description = "Feature-rich Lua LSP with annotations support",
            .version = "3.13.5",
            .author = "sumneko",
            .language = "lua",
            .repository = "https://github.com/LuaLS/lua-language-server",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-linux-x64.tar.gz", .method = .download_extract },
                .{ .platform = .macos_arm64, .url = "https://github.com/LuaLS/lua-language-server/releases/latest/download/lua-language-server-darwin-arm64.tar.gz", .method = .download_extract },
            },
            .size_bytes = 30_000_000,
            .tags = &.{ "lua", "lsp" },
        },
        PackageEntry{
            .id = "jdtls",
            .name = "Eclipse JDTLS",
            .kind = .lsp_server,
            .description = "Java Language Server (Eclipse JDT LS)",
            .version = "1.40.0",
            .author = "Eclipse Foundation",
            .language = "java",
            .repository = "https://github.com/eclipse-jdtls/eclipse.jdt.ls",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://download.eclipse.org/jdtls/milestones/1.40.0/jdt-language-server-1.40.0-20240919.tar.gz", .method = .download_extract },
            },
            .size_bytes = 180_000_000,
            .tags = &.{ "java", "lsp" },
        },
        PackageEntry{
            .id = "clangd",
            .name = "clangd",
            .kind = .lsp_server,
            .description = "C/C++ Language Server from LLVM project",
            .version = "19.1.0",
            .author = "LLVM Project",
            .language = "c",
            .repository = "https://github.com/llvm/llvm-project",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/clangd/clangd/releases/latest/download/clangd-linux-19.1.0.zip", .method = .download_extract },
            },
            .size_bytes = 100_000_000,
            .tags = &.{ "c", "cpp", "lsp" },
        },
        PackageEntry{
            .id = "bash-language-server",
            .name = "Bash Language Server",
            .kind = .lsp_server,
            .description = "LSP server for Bash/Shell scripts",
            .version = "5.4.2",
            .author = "bash-lsp",
            .language = "bash",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "bash-language-server", .method = .npm_install },
            },
            .size_bytes = 5_000_000,
            .tags = &.{ "bash", "shell", "lsp" },
        },
        PackageEntry{
            .id = "marksman",
            .name = "Marksman",
            .kind = .lsp_server,
            .description = "Markdown LSP server with wiki-link support",
            .version = "2024-12-01",
            .author = "artempyanykh",
            .language = "markdown",
            .repository = "https://github.com/artempyanykh/marksman",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/artempyanykh/marksman/releases/latest/download/marksman-linux-x64", .method = .download_binary },
            },
            .size_bytes = 15_000_000,
            .tags = &.{ "markdown", "lsp" },
        },
        PackageEntry{
            .id = "yaml-language-server",
            .name = "YAML Language Server",
            .kind = .lsp_server,
            .description = "YAML LSP with schema validation",
            .version = "1.15.0",
            .author = "Red Hat",
            .language = "yaml",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "yaml-language-server", .method = .npm_install },
            },
            .size_bytes = 5_000_000,
            .tags = &.{ "yaml", "lsp", "schema" },
        },
        PackageEntry{
            .id = "json-lsp",
            .name = "JSON Language Server",
            .kind = .lsp_server,
            .description = "JSON LSP with schema support",
            .version = "1.0.0",
            .author = "vscode-langservers",
            .language = "json",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "vscode-langservers-extracted", .method = .npm_install },
            },
            .size_bytes = 3_000_000,
            .tags = &.{ "json", "lsp", "schema" },
        },
        PackageEntry{
            .id = "omnisharp",
            .name = "OmniSharp",
            .kind = .lsp_server,
            .description = "C# Language Server",
            .version = "1.39.13",
            .author = "OmniSharp",
            .language = "csharp",
            .repository = "https://github.com/OmniSharp/omnisharp-roslyn",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/OmniSharp/omnisharp-roslyn/releases/latest/download/omnisharp-linux-x64.tar.gz", .method = .download_extract },
            },
            .size_bytes = 50_000_000,
            .tags = &.{ "csharp", "lsp" },
        },

        // ---- Language Tools ----
        PackageEntry{
            .id = "zig-toolchain",
            .name = "Zig Toolchain",
            .kind = .language_tool,
            .description = "Zig compiler and build system",
            .version = "0.14.0",
            .author = "Zig Foundation",
            .language = "zig",
            .repository = "https://github.com/ziglang/zig",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz", .method = .download_extract },
                .{ .platform = .macos_arm64, .url = "https://ziglang.org/download/0.14.0/zig-macos-aarch64-0.14.0.tar.xz", .method = .download_extract },
            },
            .size_bytes = 50_000_000,
            .tags = &.{ "zig", "compiler", "toolchain" },
        },

        // ---- Themes ----
        PackageEntry{
            .id = "dracula-theme",
            .name = "Dracula Theme",
            .kind = .theme,
            .description = "Official Dracula color theme",
            .version = "2.0.0",
            .author = "Zeno Rocha",
            .builtin = true,
            .tags = &.{ "dark", "popular" },
        },
        PackageEntry{
            .id = "catppuccin-theme",
            .name = "Catppuccin Theme Pack",
            .kind = .theme,
            .description = "All 4 Catppuccin variants (Mocha, Macchiato, Frappe, Latte)",
            .version = "2.0.0",
            .author = "Catppuccin",
            .repository = "https://github.com/catppuccin/sublime-text",
            .downloads = &.{
                .{ .platform = .linux_x64, .url = "https://github.com/catppuccin/sublime-text/archive/refs/heads/main.zip", .method = .download_extract },
            },
            .size_bytes = 500_000,
            .tags = &.{ "dark", "light", "popular" },
        },
        PackageEntry{
            .id = "tokyo-night-theme",
            .name = "Tokyo Night Theme Pack",
            .kind = .theme,
            .description = "Tokyo Night and Tokyo Night Storm themes",
            .version = "1.0.0",
            .author = "Enkia",
            .builtin = true,
            .tags = &.{ "dark", "popular" },
        },

        // ---- Plugins ----
        PackageEntry{
            .id = "gitlens-zedit",
            .name = "GitLens for Zedit",
            .kind = .plugin,
            .description = "Git blame annotations, line history, and commit browsing",
            .version = "1.0.0",
            .author = "WIZP Community",
            .tags = &.{ "git", "blame", "history" },
        },
        PackageEntry{
            .id = "color-picker",
            .name = "Color Picker",
            .kind = .plugin,
            .description = "Visual color picker and inline color preview",
            .version = "1.0.0",
            .author = "WIZP Community",
            .tags = &.{ "color", "picker", "css" },
        },
        PackageEntry{
            .id = "prettier-zedit",
            .name = "Prettier Formatter",
            .kind = .plugin,
            .description = "Code formatting via Prettier",
            .version = "1.0.0",
            .author = "WIZP Community",
            .tags = &.{ "format", "prettier" },
        },
        PackageEntry{
            .id = "todo-tree",
            .name = "Todo Tree",
            .kind = .plugin,
            .description = "Show TODO, FIXME, HACK comments in tree view",
            .version = "1.0.0",
            .author = "WIZP Community",
            .tags = &.{ "todo", "tree" },
        },
        PackageEntry{
            .id = "bookmarks-zedit",
            .name = "Bookmarks",
            .kind = .plugin,
            .description = "Enhanced bookmarks with labels and navigation",
            .version = "1.0.0",
            .author = "WIZP Community",
            .tags = &.{ "bookmarks", "navigation" },
        },
    };
}

// ============================================================
// Marketplace Manager (High-level API)
// ============================================================

pub const Hub = struct {
    allocator: Allocator,
    registry: Registry,
    installer: Installer,
    data_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, data_dir: []const u8) !Self {
        const install_dir = try std.fs.path.join(allocator, &.{ data_dir, "packages" });
        std.Io.Dir.cwd().createDirPath(runtime.io(), install_dir) catch |err| {
            allocator.free(install_dir);
            return err;
        };
        const registry = Registry.init(allocator) catch |err| {
            allocator.free(install_dir);
            return err;
        };
        var hub = Self{
            .allocator = allocator,
            .registry = registry,
            .installer = Installer.init(allocator, install_dir),
            .data_dir = data_dir,
        };
        hub.loadState() catch |err| {
            hub.deinit();
            return err;
        };
        return hub;
    }

    /// Search marketplace
    pub fn search(self: *Self, allocator: Allocator, query: []const u8, kind: ?PackageKind) ![]const PackageEntry {
        return try self.registry.search(allocator, query, kind);
    }

    /// Install a package by ID
    pub fn install(self: *Self, package_id: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        const entry = self.registry.get(package_id) orelse return error.PackageNotFound;
        try self.installer.install(entry, on_progress);
        try self.saveState();
    }

    /// Uninstall a package
    pub fn uninstall(self: *Self, package_id: []const u8) !void {
        try self.installer.uninstall(package_id);
        try self.saveState();
    }

    /// Update a package
    pub fn update(self: *Self, package_id: []const u8, on_progress: ?*const fn (InstallProgress) void) !void {
        try self.installer.update(&self.registry, package_id, on_progress);
        try self.saveState();
    }

    /// Update all packages with available updates
    pub fn updateAll(self: *Self, allocator: Allocator) !void {
        const updates = try self.installer.checkUpdates(&self.registry, allocator);
        defer allocator.free(updates);
        for (updates) |upd| {
            if (std.mem.order(u8, upd.current_version, upd.latest_version) == .lt) {
                self.update(upd.id, null) catch continue;
            }
        }
    }

    /// Get installed packages
    pub fn getInstalled(self: *Self, allocator: Allocator) ![]const InstalledPackage {
        return try self.installer.listInstalled(allocator);
    }

    /// Get package details
    pub fn getPackage(self: *Self, id: []const u8) ?PackageEntry {
        return self.registry.get(id);
    }

    /// List available LSP servers for a language
    pub fn getLspForLanguage(self: *Self, allocator: Allocator, language: []const u8) ![]const PackageEntry {
        var results = std.array_list.Managed(PackageEntry).init(allocator);
        defer results.deinit();
        var it = self.registry.packages.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (entry.kind == .lsp_server and std.mem.eql(u8, entry.language, language)) {
                try results.append(entry);
            }
        }
        return results.toOwnedSlice();
    }

    /// Auto-install recommended LSPs for current project languages
    pub fn autoInstallLsps(self: *Self, languages: []const []const u8) !void {
        for (languages) |lang| {
            const lsps = try self.getLspForLanguage(self.allocator, lang);
            defer self.allocator.free(lsps);
            for (lsps) |lsp| {
                if (!self.installer.installed.contains(lsp.id)) {
                    self.install(lsp.id, null) catch continue;
                }
            }
        }
    }

    fn statePath(self: *Self) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.data_dir, "hub-state.json" });
    }

    /// Save marketplace state to disk
    pub fn saveState(self: *Self) !void {
        const path = try self.statePath();
        defer self.allocator.free(path);

        var packages = std.array_list.Managed(PersistedPackage).init(self.allocator);
        defer packages.deinit();
        var it = self.installer.installed.iterator();
        while (it.next()) |kv| {
            try packages.append(.{
                .id = kv.key_ptr.*,
                .install_path = kv.value_ptr.install_path,
                .install_date = kv.value_ptr.install_date,
                .auto_update = kv.value_ptr.auto_update,
            });
        }

        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try std.json.Stringify.value(packages.items, .{}, &output.writer);
        const content = try output.toOwnedSlice();
        defer self.allocator.free(content);
        try std.Io.Dir.cwd().writeFile(runtime.io(), .{ .sub_path = path, .data = content });
    }

    /// Load marketplace state from disk
    pub fn loadState(self: *Self) !void {
        const path = try self.statePath();
        defer self.allocator.free(path);
        const content = std.Io.Dir.cwd().readFileAlloc(runtime.io(), path, self.allocator, .limited(10 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(content);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), content, .{}) catch {
            return error.InvalidMarketplaceState;
        };
        defer parsed.deinit();
        const values = switch (parsed.value) {
            .array => |items| items.items,
            else => return error.InvalidMarketplaceState,
        };
        for (values) |value| {
            const object = switch (value) {
                .object => |item| item,
                else => continue,
            };
            const id_value = object.get("id") orelse continue;
            const path_value = object.get("install_path") orelse continue;
            const id = switch (id_value) {
                .string => |item| item,
                else => continue,
            };
            const install_path = switch (path_value) {
                .string => |item| item,
                else => continue,
            };
            const entry = self.registry.get(id) orelse continue;
            if (self.installer.installed.contains(id)) continue;
            std.Io.Dir.cwd().access(runtime.io(), install_path, .{}) catch continue;

            const key = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(key);
            const path_dup = try self.allocator.dupe(u8, install_path);
            errdefer self.allocator.free(path_dup);
            const install_date = if (object.get("install_date")) |item| switch (item) {
                .integer => |number| number,
                else => 0,
            } else 0;
            const auto_update = if (object.get("auto_update")) |item| switch (item) {
                .bool => |enabled| enabled,
                else => true,
            } else true;
            try self.installer.installed.put(self.allocator, key, .{
                .entry = entry,
                .install_path = path_dup,
                .install_date = install_date,
                .auto_update = auto_update,
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit(self.allocator);
        self.installer.deinit();
    }
};
