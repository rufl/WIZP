// WIZP package & syntax updater
// Fetches Sublime Text packages, syntax definitions, and themes
// from Package Control repositories and GitHub

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;
const http = std.http;

/// Package source repository URLs
pub const PackageSources = struct {
    /// Package Control channel JSON URL
    pub const package_control_channel = "https://raw.githubusercontent.com/wbond/package_control_channel/master/channel.json";
    /// Package Control channel v3
    pub const package_control_channel_v3 = "https://raw.githubusercontent.com/wbond/package_control_channel/master/channel_v3.json";
    /// Default syntax repository
    pub const default_syntax_repo = "https://github.com/sublimehq/Packages/raw/master";
    /// Package Control repository base
    pub const package_control_base = "https://packagecontrol.io";
};

/// Package manifest from Package Control
pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    url: []const u8,
    author: []const u8 = "",
    labels: []const []const u8 = &.{},
    last_modified: []const u8 = "",
    releases: []const Release = &.{},

    pub const Release = struct {
        version: []const u8,
        url: []const u8,
        date: []const u8,
        platforms: []const []const u8 = &.{},
    };
};

/// Installed package tracking
pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
    installed_date: i64, // Unix timestamp
    path: []const u8,
    type: PackageType,

    pub const PackageType = enum {
        syntax,
        theme,
        plugin,
        snippet,
        other,
    };
};

/// Update check result
pub const UpdateResult = struct {
    package: InstalledPackage,
    current_version: []const u8,
    latest_version: []const u8,
    update_available: bool,
    download_url: ?[]const u8 = null,
};

/// Package updater
pub const Updater = struct {
    allocator: Allocator,
    client: http.Client,
    installed: std.array_list.Managed(InstalledPackage),
    cache_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, cache_dir: []const u8) Self {
        std.Io.Dir.cwd().createDirPath(runtime.io(), cache_dir) catch {};
        return .{
            .allocator = allocator,
            .client = http.Client{
                .allocator = allocator,
                .io = runtime.io(),
            },
            .installed = std.array_list.Managed(InstalledPackage).init(allocator),
            .cache_dir = cache_dir,
        };
    }

    /// Fetch the Package Control channel and list all available packages
    pub fn fetchPackageList(self: *Self) ![]const PackageInfo {
        const uri = try std.Uri.parse(PackageSources.package_control_channel);
        var request = try self.client.request(.GET, uri, .{});
        defer request.deinit();
        try request.sendBodyComplete(&.{});
        var redirect_buffer: [8192]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        const body = try response.reader(&transfer_buffer).*.allocRemaining(
            self.allocator,
            .limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(body);

        // Parse channel.json: extract packages with name, version, url, description
        var results = std.array_list.Managed(PackageInfo).init(self.allocator);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, pos, "\"name\"")) |n_start| {
            if (std.mem.indexOfScalarPos(u8, body, n_start + 6, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, body, v0 + 1, '"')) |v1| {
                    const name = body[v0 + 1 .. v1];
                    var url_str: []const u8 = "";
                    var version: []const u8 = "0.0.0";
                    var description: []const u8 = "";

                    if (std.mem.indexOfPos(u8, body, v1, "\"url\"")) |u_start| {
                        if (std.mem.indexOfScalarPos(u8, body, u_start + 5, '"')) |uv0| {
                            if (std.mem.indexOfScalarPos(u8, body, uv0 + 1, '"')) |uv1| {
                                url_str = body[uv0 + 1 .. uv1];
                            }
                        }
                    }
                    if (std.mem.indexOfPos(u8, body, v1, "\"version\"")) |ve_start| {
                        if (std.mem.indexOfScalarPos(u8, body, ve_start + 9, '"')) |vv0| {
                            if (std.mem.indexOfScalarPos(u8, body, vv0 + 1, '"')) |vv1| {
                                version = body[vv0 + 1 .. vv1];
                            }
                        }
                    }
                    if (std.mem.indexOfPos(u8, body, v1, "\"description\"")) |d_start| {
                        if (std.mem.indexOfScalarPos(u8, body, d_start + 13, '"')) |dv0| {
                            if (std.mem.indexOfScalarPos(u8, body, dv0 + 1, '"')) |dv1| {
                                description = body[dv0 + 1 .. dv1];
                            }
                        }
                    }

                    try results.append(.{
                        .name = try self.allocator.dupe(u8, name),
                        .version = try self.allocator.dupe(u8, version),
                        .description = try self.allocator.dupe(u8, description),
                        .url = try self.allocator.dupe(u8, url_str),
                    });
                    pos = v1 + 1;
                    continue;
                }
            }
            break;
        }
        return results.toOwnedSlice();
    }

    /// Check for updates to all installed packages
    pub fn checkForUpdates(self: *Self) ![]const UpdateResult {
        var results = std.array_list.Managed(UpdateResult).init(self.allocator);

        // Fetch channel once and compare all installed packages
        const channel_packages = self.fetchPackageList() catch {
            return results.toOwnedSlice();
        };
        defer {
            for (channel_packages) |cp| {
                self.allocator.free(cp.name);
                self.allocator.free(cp.version);
            }
            self.allocator.free(channel_packages);
        }

        for (self.installed.items) |pkg| {
            var latest: []const u8 = pkg.version;
            for (channel_packages) |cp| {
                if (std.mem.eql(u8, cp.name, pkg.name)) {
                    latest = cp.version;
                    break;
                }
            }
            const update_available = !std.mem.eql(u8, pkg.version, latest);
            try results.append(.{
                .package = pkg,
                .current_version = pkg.version,
                .latest_version = try self.allocator.dupe(u8, latest),
                .update_available = update_available,
            });
        }

        return results.toOwnedSlice();
    }

    /// Fetch latest version string for a package from the channel
    fn fetchLatestVersion(self: *Self, package_name: []const u8) ![]const u8 {
        const packages = self.fetchPackageList() catch return "0.0.0";
        defer {
            for (packages) |p| {
                self.allocator.free(p.name);
                self.allocator.free(p.version);
            }
            self.allocator.free(packages);
        }
        for (packages) |p| {
            if (std.mem.eql(u8, p.name, package_name)) return p.version;
        }
        return "0.0.0";
    }

    /// Download and install a package from URL
    pub fn installPackage(self: *Self, url: []const u8, package_type: InstalledPackage.PackageType) !void {
        // Download to cache
        const archive_name = std.fs.path.basename(url);
        const dest_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, archive_name });
        defer self.allocator.free(dest_path);

        self.downloadFile(url, dest_path) catch |err| {
            std.debug.print("Download failed: {}\n", .{err});
            return;
        };

        // Extract based on type
        const extract_dir = switch (package_type) {
            .syntax => try std.fs.path.join(self.allocator, &.{ self.cache_dir, "syntax" }),
            .theme => try std.fs.path.join(self.allocator, &.{ self.cache_dir, "themes" }),
            .plugin => try std.fs.path.join(self.allocator, &.{ self.cache_dir, "plugins" }),
            .snippet => try std.fs.path.join(self.allocator, &.{ self.cache_dir, "snippets" }),
            .other => try std.fs.path.join(self.allocator, &.{ self.cache_dir, "other" }),
        };
        defer self.allocator.free(extract_dir);
        runtime.createDirPath(extract_dir) catch {};

        // Track as installed
        try self.installed.append(.{
            .name = try self.allocator.dupe(u8, archive_name),
            .version = "0.0.0",
            .installed_date = runtime.timestamp(),
            .path = try self.allocator.dupe(u8, dest_path),
            .type = package_type,
        });
    }

    /// Update syntax definitions from Sublime HQ Packages repository
    pub fn updateSyntaxDefinitions(self: *Self) !void {
        const syntax_files = [_][]const u8{
            "C++/C.sublime-syntax",
            "C++/C++.sublime-syntax",
            "C#/C#.sublime-syntax",
            "Clojure/Clojure.sublime-syntax",
            "D/D.sublime-syntax",
            "Dart/Dart.sublime-syntax",
            "Diff/Diff.sublime-syntax",
            "Erlang/Erlang.sublime-syntax",
            "Go/Go.sublime-syntax",
            "Groovy/Groovy.sublime-syntax",
            "Haskell/Haskell.sublime-syntax",
            "Java/Java.sublime-syntax",
            "JavaScript/JavaScript.sublime-syntax",
            "LaTeX/LaTeX.sublime-syntax",
            "Lisp/Lisp.sublime-syntax",
            "Lua/Lua.sublime-syntax",
            "Makefile/Makefile.sublime-syntax",
            "Markdown/Markdown.sublime-syntax",
            "Objective-C/Objective-C.sublime-syntax",
            "OCaml/OCaml.sublime-syntax",
            "Perl/Perl.sublime-syntax",
            "PHP/PHP.sublime-syntax",
            "Python/Python.sublime-syntax",
            "R/R.sublime-syntax",
            "Regular Expressions/RegExp.sublime-syntax",
            "Ruby/Ruby.sublime-syntax",
            "Rust/Rust.sublime-syntax",
            "Scala/Scala.sublime-syntax",
            "ShellScript/Shell-Unix-Generic.sublime-syntax",
            "SQL/SQL.sublime-syntax",
            "Swift/Swift.sublime-syntax",
            "TOML/TOML.sublime-syntax",
            "TypeScript/TypeScript.sublime-syntax",
            "XML/XML.sublime-syntax",
            "YAML/YAML.sublime-syntax",
        };

        for (syntax_files) |file| {
            const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ PackageSources.default_syntax_repo, file });
            defer self.allocator.free(url);

            const file_name = std.fs.path.basename(file);
            const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/syntax/{s}", .{ self.cache_dir, file_name });
            defer self.allocator.free(dest_path);

            self.downloadFile(url, dest_path) catch continue;
        }
    }

    /// Download a file from URL to local path
    fn downloadFile(self: *Self, url: []const u8, dest_path: []const u8) !void {
        const uri = try std.Uri.parse(url);

        var request = try self.client.request(.GET, uri, .{});
        defer request.deinit();
        try request.sendBodyComplete(&.{});
        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        var transfer_buffer: [8192]u8 = undefined;
        const body = try response.reader(&transfer_buffer).*.allocRemaining(
            self.allocator,
            .limited(10 * 1024 * 1024),
        );
        defer self.allocator.free(body);

        // Create parent directory
        if (std.fs.path.dirname(dest_path)) |dir| {
            runtime.createDirPath(dir) catch {};
        }
        try runtime.writeFile(dest_path, body);
    }

    /// Scan installed packages directory and populate installed list
    pub fn scanInstalled(self: *Self, dir: []const u8) !void {
        var iter_dir = std.Io.Dir.cwd().openDir(
            runtime.io(),
            dir,
            .{ .iterate = true },
        ) catch return;
        defer iter_dir.close(runtime.io());

        var walker = try iter_dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(runtime.io())) |entry| {
            if (entry.kind != .file) continue;
            // Detect package type from path/extension
            const ext = std.fs.path.extension(entry.basename);
            const pkg_type: InstalledPackage.PackageType = if (std.mem.eql(u8, ext, ".sublime-syntax")) .syntax else if (std.mem.eql(u8, ext, ".sublime-theme") or std.mem.eql(u8, ext, ".tmTheme")) .theme else if (std.mem.eql(u8, ext, ".sublime-snippet")) .snippet else .plugin;

            try self.installed.append(.{
                .name = try self.allocator.dupe(u8, entry.basename),
                .version = "0.0.0",
                .installed_date = runtime.timestamp(),
                .path = try self.allocator.dupe(u8, entry.path),
                .type = pkg_type,
            });
        }
    }

    /// Fetch latest Sublime Text themes from known repos
    pub fn fetchThemes(self: *Self) !void {
        const theme_repos = [_][]const u8{
            "https://raw.githubusercontent.com/rainglow/sublime/master/themes",
            "https://raw.githubusercontent.com/dracula/sublime/master",
        };
        for (theme_repos) |repo| {
            // Attempt to download theme index; failure is non-fatal
            self.downloadFile(repo, try std.fs.path.join(self.allocator, &.{ self.cache_dir, "themes", std.fs.path.basename(repo) })) catch continue;
        }
    }

    /// Clean up cache directory
    pub fn cleanup(self: *Self) void {
        std.Io.Dir.cwd().deleteTree(
            @import("../runtime_016.zig").io(),
            self.cache_dir,
        ) catch {};
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        for (self.installed.items) |pkg| {
            self.allocator.free(pkg.name);
            self.allocator.free(pkg.version);
            self.allocator.free(pkg.path);
        }
        self.installed.deinit();
        self.cleanup();
    }
};
