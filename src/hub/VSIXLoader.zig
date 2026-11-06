// WIZP VSIX Loader: .vsix package extraction and installation
// VSIX files are ZIP archives containing extension code + package.json manifest.
// Uses Zig's standard ZIP implementation without an `unzip` dependency.
//
// Workflow:
// 1. Open .vsix as ZIP (via zip.zig)
// 2. Read extension/package.json
// 3. Extract to extensions/{publisher}-{id}/
// 4. Register with ExtensionHost
//
// Supports:
// - Local .vsix files (code --install-extension)
// - OpenVSX registry downloads (via Hub)
// - Extension update checks

const std = @import("std");
const Allocator = std.mem.Allocator;
const zip = @import("zip.zig");

pub const VSIXManifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    publisher: []const u8,
    main: []const u8,
    activation_events: []const []const u8 = &.{},
    engines: Engines = .{},
    contributes: ?[]const u8 = null,

    pub const Engines = struct {
        vscode: []const u8 = "*",
    };
};

pub const VSIXLoader = struct {
    allocator: Allocator,
    extensions_dir: []const u8,

    const Self = @This();

    /// JSON-RPC code used for install failures that are safe to retry.
    ///
    /// Keep this distinct from the generic RPC failure code so callers can
    /// reliably distinguish a failed transaction from AlreadyInstalled.
    pub const retryable_install_rpc_code: i32 = -32011;

    pub const InstallErrorClass = enum {
        retryable,
        already_installed,
    };

    pub fn classifyInstallError(err: anyerror) InstallErrorClass {
        return if (err == error.AlreadyInstalled) .already_installed else .retryable;
    }

    pub fn isRetryableInstallError(err: anyerror) bool {
        return classifyInstallError(err) == .retryable;
    }

    pub const InstallResult = struct {
        path: []const u8,
        id: []const u8,
        display_name: []const u8,
        version: []const u8,

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.path);
            allocator.free(self.id);
            allocator.free(self.display_name);
            allocator.free(self.version);
            self.* = undefined;
        }
    };

    pub fn init(allocator: Allocator, extensions_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .extensions_dir = extensions_dir,
        };
    }

    /// Parse VSIX manifest from package.json contents.
    pub fn parseManifest(allocator: Allocator, json: []const u8) !VSIXManifest {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidManifest;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidManifest,
        };
        const id = switch (root.get("name") orelse return error.InvalidManifest) {
            .string => |value| value,
            else => return error.InvalidManifest,
        };
        const display_name = if (root.get("displayName")) |value| switch (value) {
            .string => |text| text,
            else => id,
        } else id;
        const version = if (root.get("version")) |value| switch (value) {
            .string => |text| text,
            else => "0.0.0",
        } else "0.0.0";
        const publisher = if (root.get("publisher")) |value| switch (value) {
            .string => |text| text,
            else => "unknown",
        } else "unknown";
        const main_file = if (root.get("main")) |value| switch (value) {
            .string => |text| text,
            else => "extension.js",
        } else "extension.js";

        var activation_events = std.array_list.Managed([]const u8).init(allocator);
        if (root.get("activationEvents")) |value| {
            if (value == .array) {
                for (value.array.items) |item| {
                    if (item == .string and item.string.len > 0) {
                        try activation_events.append(try allocator.dupe(u8, item.string));
                    }
                }
            }
        }

        const engines_vscode = if (root.get("engines")) |value| switch (value) {
            .object => |engines| if (engines.get("vscode")) |vscode| switch (vscode) {
                .string => |text| text,
                else => "*",
            } else "*",
            else => "*",
        } else "*";

        return VSIXManifest{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, display_name),
            .version = try allocator.dupe(u8, version),
            .publisher = try allocator.dupe(u8, publisher),
            .main = try allocator.dupe(u8, main_file),
            .activation_events = try activation_events.toOwnedSlice(),
            .engines = .{ .vscode = try allocator.dupe(u8, engines_vscode) },
        };
    }

    /// Install a .vsix file into the extensions directory.
    pub fn installVSIX(self: *Self, vsix_path: []const u8) !InstallResult {
        const staging_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/.installing-{x}",
            .{ self.extensions_dir, @import("../runtime_016.zig").nanoTimestamp() },
        );
        defer self.allocator.free(staging_path);
        // Remove any stale private staging tree before beginning a new
        // transaction. deleteTree treats a missing path as success.
        try std.Io.Dir.cwd().deleteTree(
            @import("../runtime_016.zig").io(),
            staging_path,
        );
        try std.Io.Dir.cwd().createDirPath(
            @import("../runtime_016.zig").io(),
            staging_path,
        );
        // Extraction, manifest parsing, and the final rename are one
        // transaction. The destination is never removed or replaced on
        // failure; only this private staging tree is cleaned up.
        defer cleanupStaging(staging_path);

        try self.extractVSIX(vsix_path, staging_path);

        const extracted_root = try std.fs.path.join(self.allocator, &.{ staging_path, "extension" });
        defer self.allocator.free(extracted_root);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ extracted_root, "package.json" });
        defer self.allocator.free(manifest_path);
        const manifest_json = try std.Io.Dir.cwd().readFileAlloc(
            @import("../runtime_016.zig").io(),
            manifest_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(manifest_json);

        const manifest = try parseManifest(self.allocator, manifest_json);
        defer self.freeManifest(manifest);

        const ext_dir_name = try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ manifest.publisher, manifest.id });
        defer self.allocator.free(ext_dir_name);

        const ext_path = try std.fs.path.join(self.allocator, &.{ self.extensions_dir, ext_dir_name });
        errdefer self.allocator.free(ext_path);
        if (std.Io.Dir.cwd().statFile(
            @import("../runtime_016.zig").io(),
            ext_path,
            .{},
        )) |_| {
            return error.AlreadyInstalled;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const extension_id = try std.fmt.allocPrint(
            self.allocator,
            "{s}.{s}",
            .{ manifest.publisher, manifest.id },
        );
        errdefer self.allocator.free(extension_id);
        const display_name = try self.allocator.dupe(u8, manifest.name);
        errdefer self.allocator.free(display_name);
        const version = try self.allocator.dupe(u8, manifest.version);
        errdefer self.allocator.free(version);

        try std.Io.Dir.cwd().rename(
            extracted_root,
            std.Io.Dir.cwd(),
            ext_path,
            @import("../runtime_016.zig").io(),
        );
        return .{
            .path = ext_path,
            .id = extension_id,
            .display_name = display_name,
            .version = version,
        };
    }

    fn extractVSIX(self: *Self, vsix_path: []const u8, dest_dir: []const u8) !void {
        try zip.extractAll(self.allocator, vsix_path, dest_dir);
    }

    pub fn freeManifest(self: *Self, manifest: VSIXManifest) void {
        self.allocator.free(manifest.id);
        self.allocator.free(manifest.name);
        self.allocator.free(manifest.version);
        self.allocator.free(manifest.publisher);
        self.allocator.free(manifest.main);
        self.allocator.free(manifest.engines.vscode);
        for (manifest.activation_events) |ae| self.allocator.free(ae);
        self.allocator.free(manifest.activation_events);
    }
};

fn cleanupStaging(staging_path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(
        @import("../runtime_016.zig").io(),
        staging_path,
    ) catch |err| {
        std.log.warn("failed to remove VSIX staging directory '{s}': {}", .{ staging_path, err });
    };
}

test "VSIX manifest parsing preserves escaped structured fields" {
    const allocator = std.testing.allocator;
    var loader = VSIXLoader.init(allocator, "");
    const manifest = try VSIXLoader.parseManifest(
        allocator,
        "{ \"name\" : \"publisher.extension\", \"displayName\" : \"Quoted \\\"Extension\\\"\", \"version\" : \"1.2.3\", \"publisher\" : \"publisher\", \"main\" : \"extension.js\", \"activationEvents\" : [\"onStartup\", \"onCommand:test\"], \"engines\" : { \"vscode\" : \"^1.90.0\" } }",
    );
    defer loader.freeManifest(manifest);
    try std.testing.expectEqualStrings("publisher.extension", manifest.id);
    try std.testing.expectEqualStrings("Quoted \"Extension\"", manifest.name);
    try std.testing.expectEqualStrings("1.2.3", manifest.version);
    try std.testing.expectEqualStrings("publisher", manifest.publisher);
    try std.testing.expectEqualStrings("^1.90.0", manifest.engines.vscode);
    try std.testing.expectEqual(@as(usize, 2), manifest.activation_events.len);
    try std.testing.expectEqualStrings("onCommand:test", manifest.activation_events[1]);
}

test "VSIX install failure cleans private staging output" {
    const allocator = std.testing.allocator;
    const runtime = @import("../runtime_016.zig");
    const root = try std.fmt.allocPrint(allocator, "/tmp/wizp-vsix-loader-test-{x}", .{runtime.nanoTimestamp()});
    defer allocator.free(root);
    std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};
    try std.Io.Dir.cwd().createDirPath(runtime.io(), root);
    defer std.Io.Dir.cwd().deleteTree(runtime.io(), root) catch {};

    const vsix_path = try std.fs.path.join(allocator, &.{ root, "invalid.vsix" });
    defer allocator.free(vsix_path);
    try std.Io.Dir.cwd().writeFile(runtime.io(), .{ .sub_path = vsix_path, .data = "not a zip" });

    var loader = VSIXLoader.init(allocator, root);
    var saw_failure = false;
    if (loader.installVSIX(vsix_path)) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    } else |err| {
        saw_failure = true;
        try std.testing.expect(VSIXLoader.isRetryableInstallError(err));
    }
    try std.testing.expect(saw_failure);

    var extensions_dir = try std.Io.Dir.cwd().openDir(runtime.io(), root, .{ .iterate = true });
    defer extensions_dir.close(runtime.io());
    var entries = extensions_dir.iterate();
    while (try entries.next(runtime.io())) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".installing-"));
    }
}

test "VSIX install error classification keeps AlreadyInstalled explicit" {
    try std.testing.expect(!VSIXLoader.isRetryableInstallError(error.AlreadyInstalled));
    try std.testing.expect(VSIXLoader.isRetryableInstallError(error.BadZip));
    try std.testing.expectEqual(
        VSIXLoader.InstallErrorClass.already_installed,
        VSIXLoader.classifyInstallError(error.AlreadyInstalled),
    );
    try std.testing.expectEqual(
        VSIXLoader.InstallErrorClass.retryable,
        VSIXLoader.classifyInstallError(error.BadZip),
    );
}
