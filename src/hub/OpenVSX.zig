// WIZP Hub - Open VSX Registry Integration
// Browse, search, and install VS Code extensions from open-vsx.org
// Converts themes, icon themes, and TextMate syntaxes to WIZP format

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const zip = @import("zip.zig");

/// Open VSX API base URL
pub const API_BASE = "https://open-vsx.org/api";

// ============================================================
// VSX Extension Info
// ============================================================

pub const VsxExtension = struct {
    namespace: []const u8,
    name: []const u8,
    display_name: []const u8 = "",
    description: []const u8 = "",
    version: []const u8 = "",
    publisher: []const u8 = "",
    download_count: usize = 0,
    rating: f32 = 0,
    categories: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    /// Whether this has themes we can install
    has_themes: bool = false,
    has_icon_theme: bool = false,
    has_syntax: bool = false,

    pub fn deinit(self: *VsxExtension, allocator: Allocator) void {
        if (self.namespace.len > 0) allocator.free(self.namespace);
        if (self.name.len > 0) allocator.free(self.name);
        if (self.display_name.len > 0) allocator.free(self.display_name);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.publisher.len > 0) allocator.free(self.publisher);
    }
};

pub const VsxSearchResult = struct {
    extensions: []const VsxExtension,
    total_count: usize,
};

// ============================================================
// Open VSX Client
// ============================================================

pub const OpenVSXClient = struct {
    allocator: Allocator,
    client: http.Client,

    pub fn init(allocator: Allocator) OpenVSXClient {
        return .{
            .allocator = allocator,
            .client = http.Client{
                .allocator = allocator,
                .io = @import("../runtime_016.zig").io(),
            },
        };
    }

    /// Search extensions by query
    pub fn search(self: *OpenVSXClient, query: []const u8, size: usize) !VsxSearchResult {
        var encoded = std.Io.Writer.Allocating.init(self.allocator);
        defer encoded.deinit();
        try (std.Uri.Component{ .raw = query }).formatEscaped(&encoded.writer);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/-/search?query={s}&size={d}&includeAllVersions=false", .{ API_BASE, encoded.written(), size });
        defer self.allocator.free(url);
        const body = try self.httpGet(url);
        defer self.allocator.free(body);
        return parseSearchResults(self.allocator, body);
    }

    /// Get extension details
    pub fn getExtension(self: *OpenVSXClient, namespace: []const u8, name: []const u8) !VsxExtension {
        if (!validExtensionSegment(namespace) or !validExtensionSegment(name)) {
            return error.InvalidExtensionIdentifier;
        }
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ API_BASE, namespace, name });
        defer self.allocator.free(url);
        const body = try self.httpGet(url);
        defer self.allocator.free(body);
        return parseExtension(self.allocator, body);
    }

    /// Download a .vsix file
    pub fn downloadVsix(self: *OpenVSXClient, namespace: []const u8, name: []const u8, version: []const u8, dest: []const u8) !void {
        if (!validExtensionSegment(namespace) or !validExtensionSegment(name) or !validExtensionSegment(version)) {
            return error.InvalidExtensionIdentifier;
        }
        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}/{s}/file/{s}.{s}-{s}.vsix", .{ API_BASE, namespace, name, version, namespace, name, version });
        defer self.allocator.free(url);
        try self.httpDownload(url, dest);
    }

    /// Get latest version
    pub fn getLatestVersion(self: *OpenVSXClient, namespace: []const u8, name: []const u8) ![]const u8 {
        var ext = try self.getExtension(namespace, name);
        defer ext.deinit(self.allocator);
        return try self.allocator.dupe(u8, ext.version);
    }

    fn httpGet(self: *OpenVSXClient, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var response_body = std.ArrayListUnmanaged(u8).empty;
        errdefer response_body.deinit(self.allocator);

        var allocating_writer = std.Io.Writer.Allocating.fromArrayList(self.allocator, &response_body);
        const response = try self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_writer = &allocating_writer.writer,
        });
        if (response.status.class() != .success) return error.OpenVSXRequestFailed;
        return response_body.toOwnedSlice(self.allocator);
    }

    fn httpDownload(self: *OpenVSXClient, url: []const u8, dest: []const u8) !void {
        const uri = try std.Uri.parse(url);
        const runtime = @import("../runtime_016.zig");
        var file = try std.Io.Dir.cwd().createFile(runtime.io(), dest, .{ .truncate = true });
        errdefer std.Io.Dir.cwd().deleteFile(runtime.io(), dest) catch |err| {
            std.log.warn("failed to remove incomplete OpenVSX download '{s}': {}", .{ dest, err });
        };
        defer file.close(runtime.io());
        var write_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(runtime.io(), &write_buffer);
        const response = try self.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .GET,
            .response_writer = &file_writer.interface,
        });
        try file_writer.flush();
        if (response.status.class() != .success) return error.OpenVSXDownloadFailed;
        const stat = try file.stat(runtime.io());
        if (stat.size > 100 * 1024 * 1024) return error.OpenVSXDownloadTooLarge;
    }

    pub fn deinit(self: *OpenVSXClient) void {
        self.client.deinit();
    }
};

fn validExtensionSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

test "OpenVSX extension identifier segments reject URL path injection" {
    try std.testing.expect(validExtensionSegment("publisher-name"));
    try std.testing.expect(validExtensionSegment("extension.name_2"));
    try std.testing.expect(!validExtensionSegment("publisher/other"));
    try std.testing.expect(!validExtensionSegment("version?download=true"));
    try std.testing.expect(!validExtensionSegment(""));
}

// ============================================================
// VSIX Package Parser
// ============================================================

pub const VsixPackage = struct {
    manifest: VsxExtension,
    themes: []const VsxTheme,
    icon_themes: []const VsxIconTheme,
    syntax_files: []const VsxSyntax,

    pub const VsxTheme = struct {
        name: []const u8,
        path: []const u8, // Path inside VSIX
        content: []const u8,
    };

    pub const VsxIconTheme = struct {
        name: []const u8,
        path: []const u8,
        content: []const u8,
    };

    pub const VsxSyntax = struct {
        name: []const u8,
        scope: []const u8,
        path: []const u8,
        content: []const u8,
    };

    /// Parse a .vsix file (ZIP format) and extract manifest, themes, icon themes, syntax files
    pub fn parse(allocator: Allocator, vsix_path: []const u8) !@This() {
        // Create temp dir and extract with unzip (handles DEFLATE compression)
        var tmp_buf: [256]u8 = undefined;
        const tmp_dir = try std.fmt.bufPrint(&tmp_buf, "/tmp/wizp-vsix-{x}", .{@import("../runtime_016.zig").nanoTimestamp()});
        std.Io.Dir.cwd().createDirPath(
            @import("../runtime_016.zig").io(),
            tmp_dir,
        ) catch {};
        defer std.Io.Dir.cwd().deleteTree(
            @import("../runtime_016.zig").io(),
            tmp_dir,
        ) catch {};

        const unzip_result = std.process.run(
            allocator,
            @import("../runtime_016.zig").io(),
            .{ .argv = &.{ "unzip", "-o", vsix_path, "-d", tmp_dir } },
        ) catch return error.BadZip;
        defer allocator.free(unzip_result.stdout);
        defer allocator.free(unzip_result.stderr);
        const unzip_ok = switch (unzip_result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!unzip_ok) {
            std.debug.print("WIZP VSIX: unzip reported failure for {s}\n", .{vsix_path});
            return error.BadZip;
        }

        // Read manifest from extracted files
        var manifest_path_buf: [512]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/extension/package.json", .{tmp_dir});
        const manifest: VsxExtension = manifest: {
            const manifest_json = std.Io.Dir.cwd().readFileAlloc(
                @import("../runtime_016.zig").io(),
                manifest_path,
                allocator,
                .limited(1024 * 1024),
            ) catch |err| {
                if (err == error.FileNotFound) {
                    const root_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/package.json", .{tmp_dir});
                    const root_json = std.Io.Dir.cwd().readFileAlloc(
                        @import("../runtime_016.zig").io(),
                        root_path,
                        allocator,
                        .limited(1024 * 1024),
                    ) catch break :manifest .{ .namespace = "", .name = "" };
                    defer allocator.free(root_json);
                    break :manifest try parseExtension(allocator, root_json);
                }
                break :manifest .{ .namespace = "", .name = "" };
            };
            const m = try parseExtension(allocator, manifest_json);
            allocator.free(manifest_json);
            break :manifest m;
        };

        var themes = std.ArrayListUnmanaged(VsxTheme).empty;
        var icon_themes = std.ArrayListUnmanaged(VsxIconTheme).empty;
        var syntax_files = std.ArrayListUnmanaged(VsxSyntax).empty;

        // Walk extracted files looking for theme JSONs
        std.debug.print("WIZP VSIX: scanning {s} for themes...\n", .{tmp_dir});
        try scanExtractedFiles(allocator, tmp_dir, "", &themes, &icon_themes, &syntax_files);
        std.debug.print("WIZP VSIX: scan complete -> themes={}, icon_themes={}\n", .{ themes.items.len, icon_themes.items.len });

        return @This(){
            .manifest = manifest,
            .themes = try themes.toOwnedSlice(allocator),
            .icon_themes = try icon_themes.toOwnedSlice(allocator),
            .syntax_files = try syntax_files.toOwnedSlice(allocator),
        };
    }
};

// Helper: recursively scan extracted VSIX directory for theme/syntax files
fn scanExtractedFiles(
    allocator: Allocator,
    base: []const u8,
    relative: []const u8,
    themes: *std.ArrayListUnmanaged(VsixPackage.VsxTheme),
    icon_themes: *std.ArrayListUnmanaged(VsixPackage.VsxIconTheme),
    syntax_files: *std.ArrayListUnmanaged(VsixPackage.VsxSyntax),
) !void {
    const search_path = if (relative.len > 0) try std.fs.path.join(allocator, &.{ base, relative }) else try allocator.dupe(u8, base);
    defer if (relative.len > 0) allocator.free(search_path);

    const io = @import("../runtime_016.zig").io();
    var dir = try std.Io.Dir.cwd().openDir(
        io,
        if (relative.len > 0) search_path else base,
        .{ .iterate = true },
    );
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const entry_rel = if (relative.len > 0) try std.fs.path.join(allocator, &.{ relative, entry.name }) else try allocator.dupe(u8, entry.name);
        defer allocator.free(entry_rel);

        if (entry.kind == .directory) {
            try scanExtractedFiles(allocator, base, entry_rel, themes, icon_themes, syntax_files);
        } else if (entry.kind == .file) {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (std.mem.endsWith(u8, entry.name, "package.json")) continue;

            const full_path = try std.fs.path.join(allocator, &.{ base, entry_rel });
            defer allocator.free(full_path);

            const content = std.Io.Dir.cwd().readFileAlloc(
                io,
                full_path,
                allocator,
                .limited(1024 * 1024),
            ) catch {
                std.debug.print("WIZP VSIX: cannot read {s}\n", .{full_path});
                continue;
            };
            defer allocator.free(content);

            if (std.mem.indexOf(u8, content, "\"tokenColors\"") != null or
                std.mem.indexOf(u8, content, "\"colors\"") != null or
                std.mem.indexOf(u8, content, "\"rules\"") != null)
            {
                std.debug.print("WIZP VSIX: found theme {s}\n", .{entry_rel});
                try themes.append(allocator, .{
                    .name = try allocator.dupe(u8, entry_rel),
                    .path = try allocator.dupe(u8, entry_rel),
                    .content = try allocator.dupe(u8, content),
                });
            } else if (std.mem.indexOf(u8, content, "\"iconDefinitions\"") != null) {
                try icon_themes.append(allocator, .{
                    .name = try allocator.dupe(u8, entry_rel),
                    .path = try allocator.dupe(u8, entry_rel),
                    .content = try allocator.dupe(u8, content),
                });
            } else if (std.mem.indexOf(u8, content, "\"patterns\"") != null or
                std.mem.indexOf(u8, content, "\"repository\"") != null)
            {
                try syntax_files.append(allocator, .{
                    .name = try allocator.dupe(u8, entry_rel),
                    .scope = "",
                    .path = try allocator.dupe(u8, entry_rel),
                    .content = try allocator.dupe(u8, content),
                });
            }
        }
    }
}

// ============================================================
// VS Code Theme → WIZP Theme Converter
// ============================================================

pub const ThemeConverter = struct {
    /// Convert a VS Code color theme JSON to WIZP Theme
    /// VS Code theme format:
    /// { "colors": { "editor.background": "#1e1e1e", ... }, "tokenColors": [...] }
    pub fn convert(allocator: Allocator, vs_theme_json: []const u8, name: []const u8) !Theme.ThemeDef {
        var theme = Theme.ThemeDef{
            .allocator = allocator,
            .name = name,
            .author = "VS Code Marketplace",
        };

        // Extract chrome colors
        if (std.mem.indexOf(u8, vs_theme_json, "\"editor.background\"")) |start| {
            if (extractColor(vs_theme_json, start)) |color| theme.background = color;
        }
        if (std.mem.indexOf(u8, vs_theme_json, "\"editor.foreground\"")) |start| {
            if (extractColor(vs_theme_json, start)) |color| theme.foreground = color;
        }
        if (std.mem.indexOf(u8, vs_theme_json, "\"editor.lineHighlightBackground\"")) |start| {
            if (extractColor(vs_theme_json, start)) |color| theme.line_highlight = color;
        }
        if (std.mem.indexOf(u8, vs_theme_json, "\"editor.selectionBackground\"")) |start| {
            if (extractColor(vs_theme_json, start)) |color| theme.selection = color;
        }

        // Parse tokenColors
        theme.scopes = std.StringHashMapUnmanaged(Theme.ScopeStyle){};
        theme.scope_map = std.StringHashMapUnmanaged(Theme.ScopeStyle){};

        var token_start: usize = 0;
        while (std.mem.indexOfPos(u8, vs_theme_json, token_start, "\"scope\"")) |scope_idx| {
            token_start = scope_idx + 7;
            // Parse the scope value (can be a string or array of strings)
            var scopes = std.array_list.Managed([]const u8).init(allocator);

            // Skip whitespace and colon
            var scope_val_start = scope_idx + 7;
            while (scope_val_start < vs_theme_json.len and (vs_theme_json[scope_val_start] == ' ' or vs_theme_json[scope_val_start] == '\n' or vs_theme_json[scope_val_start] == '\t' or vs_theme_json[scope_val_start] == ':' or vs_theme_json[scope_val_start] == '"')) : (scope_val_start += 1) {
                if (vs_theme_json[scope_val_start] == '[') {
                    // Array of scopes: ["scope1", "scope2"]
                    var arr_pos = scope_val_start + 1;
                    while (arr_pos < vs_theme_json.len) {
                        if (vs_theme_json[arr_pos] == '"') {
                            if (std.mem.indexOfScalarPos(u8, vs_theme_json, arr_pos + 1, '"')) |end_q| {
                                const s = vs_theme_json[arr_pos + 1 .. end_q];
                                if (s.len > 0) scopes.append(s) catch {};
                                arr_pos = end_q + 1;
                                continue;
                            }
                        }
                        if (vs_theme_json[arr_pos] == ']') break;
                        arr_pos += 1;
                    }
                    break;
                }
            }

            if (scopes.items.len == 0) {
                // Single string scope
                if (scope_val_start < vs_theme_json.len and vs_theme_json[scope_val_start] == '"') {
                    scope_val_start += 1;
                    if (std.mem.indexOfScalarPos(u8, vs_theme_json, scope_val_start, '"')) |scope_val_end| {
                        const scope_name = vs_theme_json[scope_val_start..scope_val_end];
                        if (scope_name.len > 0) scopes.append(scope_name) catch {};
                    }
                }
            }

            // Parse settings: foreground color and fontStyle
            var style = Theme.ScopeStyle{};
            if (std.mem.indexOfPos(u8, vs_theme_json, scope_idx, "\"foreground\"")) |fg_idx| {
                if (extractColor(vs_theme_json, fg_idx)) |c| style.foreground = c;
            }
            if (std.mem.indexOfPos(u8, vs_theme_json, scope_idx, "\"fontStyle\"")) |fs_idx| {
                if (std.mem.indexOfPos(u8, vs_theme_json, fs_idx, "bold")) |_| style.bold = true;
                if (std.mem.indexOfPos(u8, vs_theme_json, fs_idx, "italic")) |_| style.italic = true;
                if (std.mem.indexOfPos(u8, vs_theme_json, fs_idx, "underline")) |_| style.underline = true;
            }

            // Store style for each scope
            for (scopes.items) |scope_name| {
                const key = try allocator.dupe(u8, scope_name);
                try theme.scopes.put(allocator, key, style);
                // Also map to WIZP categories
                const mapped = mapScopeToCategory(scope_name);
                try theme.scope_map.put(allocator, try allocator.dupe(u8, mapped), style);
            }
        }

        return theme;
    }

    /// Map TextMate scope to WIZP scope category with best-match fallback
    pub fn mapScopeToCategory(scope: []const u8) []const u8 {
        if (std.mem.startsWith(u8, scope, "keyword")) return "keyword";
        if (std.mem.startsWith(u8, scope, "storage")) return "keyword";
        if (std.mem.startsWith(u8, scope, "string")) return "string";
        if (std.mem.startsWith(u8, scope, "comment")) return "comment";
        if (std.mem.startsWith(u8, scope, "constant")) return "constant";
        if (std.mem.startsWith(u8, scope, "variable")) return "variable";
        if (std.mem.startsWith(u8, scope, "entity.name.function")) return "function";
        if (std.mem.startsWith(u8, scope, "entity.name.type")) return "type";
        if (std.mem.startsWith(u8, scope, "entity.name")) return "entity";
        if (std.mem.startsWith(u8, scope, "entity")) return "type";
        if (std.mem.startsWith(u8, scope, "support.function")) return "function";
        if (std.mem.startsWith(u8, scope, "support.type")) return "type";
        if (std.mem.startsWith(u8, scope, "support.class")) return "type";
        if (std.mem.startsWith(u8, scope, "support")) return "support";
        if (std.mem.startsWith(u8, scope, "meta")) return "meta";
        if (std.mem.startsWith(u8, scope, "punctuation")) return "punctuation";
        if (std.mem.startsWith(u8, scope, "invalid")) return "error";
        if (std.mem.startsWith(u8, scope, "markup")) return "markup";
        if (std.mem.startsWith(u8, scope, "text")) return "text";
        // Best-match fallback: strip last dot-segment and retry
        if (std.mem.lastIndexOfScalar(u8, scope, '.')) |dot| {
            const parent = scope[0..dot];
            if (parent.len > 0) return mapScopeToCategory(parent);
        }
        return scope;
    }

    /// Extract a hex color from JSON near a position.
    /// Looks for "#RRGGBB" or "#RRGGBBAA" pattern after `start`.
    fn extractColor(json: []const u8, start: usize) ?Color {
        var pos = start;
        // Find '#' character
        while (pos < json.len) : (pos += 1) {
            if (json[pos] == '#') {
                // Parse 6 or 8 hex digits
                if (pos + 7 <= json.len) {
                    const r = parseHexPair(json[pos + 1], json[pos + 2]);
                    const g = parseHexPair(json[pos + 3], json[pos + 4]);
                    const b = parseHexPair(json[pos + 5], json[pos + 6]);
                    if (r != null and g != null and b != null) {
                        return Color{ .r = r.?, .g = g.?, .b = b.? };
                    }
                }
                return null;
            }
        }
        return null;
    }

    fn parseHexPair(hi: u8, lo: u8) ?u8 {
        const h = hexVal(hi);
        const l = hexVal(lo);
        if (h == null or l == null) return null;
        return h.? * 16 + l.?;
    }

    fn hexVal(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};

// ============================================================
// Sublime Color Scheme → WIZP Theme Converter
// ============================================================

pub const SublimeColorSchemeConverter = struct {
    pub const Var = struct { k: []const u8, v: []const u8 };

    pub fn convert(allocator: Allocator, json: []const u8, name: []const u8) !Theme.ThemeDef {
        var theme = Theme.ThemeDef{
            .allocator = allocator,
            .name = name,
            .author = "Sublime Text",
        };
        theme.scopes = std.StringHashMapUnmanaged(Theme.ScopeStyle){};
        theme.scope_map = std.StringHashMapUnmanaged(Theme.ScopeStyle){};
        var _vars: [128]Var = undefined;
        var vc: usize = 0;

        // Parse "variables"
        if (std.mem.indexOf(u8, json, "\"variables\"")) |vp| {
            var p = vp + 12;
            while (p < json.len) {
                while (p < json.len and json[p] != '"') p += 1;
                if (p >= json.len) break;
                p += 1;
                if (std.mem.indexOfScalarPos(u8, json, p, '"')) |ke| {
                    const k = json[p..ke];
                    p = ke + 1;
                    while (p < json.len and (json[p] == ':' or json[p] == ' ' or json[p] == '\t' or json[p] == '\n')) p += 1;
                    if (p >= json.len) break;
                    if (json[p] == '"') {
                        p += 1;
                        if (std.mem.indexOfScalarPos(u8, json, p, '"')) |ve| {
                            if (vc < _vars.len) {
                                _vars[vc] = .{ .k = k, .v = json[p..ve] };
                                vc += 1;
                            }
                            p = ve + 1;
                        } else break;
                    } else if (json[p] == '#') {
                        var ep = p;
                        while (ep < json.len and (json[ep] >= '0' and json[ep] <= '9' or json[ep] >= 'a' and json[ep] <= 'f' or json[ep] >= 'A' and json[ep] <= 'F' or json[ep] == '#')) ep += 1;
                        if (vc < _vars.len) {
                            _vars[vc] = .{ .k = k, .v = json[p..ep] };
                            vc += 1;
                        }
                        p = ep;
                    }
                } else break;
                if (p < json.len and json[p] == '}') break;
            }
        }

        // Parse "globals" → theme chrome colors
        if (std.mem.indexOf(u8, json, "\"globals\"")) |gp| {
            if (extractJsonString(json, gp, "background")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.background = c;
            }
            if (extractJsonString(json, gp, "foreground")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.foreground = c;
            }
            if (extractJsonString(json, gp, "caret")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.caret = c;
            }
            if (extractJsonString(json, gp, "selection")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.selection = c;
            }
            if (extractJsonString(json, gp, "line_highlight")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.line_highlight = c;
            }
            if (extractJsonString(json, gp, "gutter")) |v| {
                if (resolveVars(v, _vars[0..vc])) |c| theme.gutter = c;
            }
        }

        // Parse "rules" → syntax highlighting
        var rp: usize = 0;
        while (std.mem.indexOfPos(u8, json, rp, "\"scope\"")) |si| : (rp = si + 7) {
            var scopes = std.ArrayListUnmanaged([]const u8).empty;
            if (std.mem.indexOfScalarPos(u8, json, si + 7, '"')) |vs| {
                if (std.mem.indexOfScalarPos(u8, json, vs + 1, '"')) |ve| {
                    var sit = std.mem.splitScalar(u8, json[vs + 1 .. ve], ',');
                    while (sit.next()) |s| {
                        const t = std.mem.trim(u8, s, " \t\r\n");
                        if (t.len > 0) scopes.append(allocator, t) catch continue;
                    }
                }
            }
            if (scopes.items.len == 0) continue;

            var style = Theme.ScopeStyle{};
            if (extractJsonString(json, si, "foreground")) |fv| {
                if (resolveVars(fv, _vars[0..vc])) |c| style.foreground = c;
            }
            if (extractJsonString(json, si, "background")) |bv| {
                if (resolveVars(bv, _vars[0..vc])) |c| style.background = c;
            }
            if (extractJsonString(json, si, "font_style")) |fs| {
                if (std.mem.indexOf(u8, fs, "bold") != null) style.bold = true;
                if (std.mem.indexOf(u8, fs, "italic") != null) style.italic = true;
                if (std.mem.indexOf(u8, fs, "underline") != null) style.underline = true;
            }

            for (scopes.items) |sn| {
                const key = try allocator.dupe(u8, sn);
                try theme.scopes.put(allocator, key, style);
                const mapped = ThemeConverter.mapScopeToCategory(sn);
                try theme.scope_map.put(allocator, try allocator.dupe(u8, mapped), style);
            }
            scopes.deinit(allocator);
        }

        return theme;
    }

    /// Extract a JSON string value for a given key within a JSON object region
    fn extractJsonString(json: []const u8, start: usize, key: []const u8) ?[]const u8 {
        var nb: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&nb, "\"{s}\"", .{key}) catch return null;
        const ki = std.mem.indexOfPos(u8, json, start, needle) orelse return null;
        var ps = ki + needle.len;
        while (ps < json.len and (json[ps] == ':' or json[ps] == ' ' or json[ps] == '\t' or json[ps] == '\n')) ps += 1;
        if (ps >= json.len) return null;
        if (json[ps] == '"') {
            ps += 1;
            if (std.mem.indexOfScalarPos(u8, json, ps, '"')) |pe| return json[ps..pe];
            return null;
        }
        if (json[ps] == '#') {
            var ep = ps;
            while (ep < json.len and (json[ep] >= '0' and json[ep] <= '9' or json[ep] >= 'a' and json[ep] <= 'f' or json[ep] >= 'A' and json[ep] <= 'F' or json[ep] == '#' or json[ep] >= '(' and json[ep] <= 'z')) ep += 1;
            return json[ps..ep];
        }
        return null;
    }

    /// Resolve var(name) references and parse hex to Color
    fn resolveVars(val: []const u8, vars: []const SublimeColorSchemeConverter.Var) ?Color {
        var resolved = val;
        if (val.len > 0 and val[0] == '#') return hexToColor(val);
        if (std.mem.startsWith(u8, val, "var(") and val.len > 5 and val[val.len - 1] == ')') {
            const vn = val[4 .. val.len - 1];
            for (vars) |v| {
                if (std.mem.eql(u8, v.k, vn)) {
                    resolved = v.v;
                    break;
                }
            }
        }
        if (resolved.len > 0 and resolved[0] == '#') return hexToColor(resolved);
        if (std.mem.startsWith(u8, resolved, "color(")) {
            // Sublime color() expressions are unsupported and omitted.
            return null;
        }
        // Handle recursive var() inside var()
        if (std.mem.startsWith(u8, resolved, "var(")) {
            return resolveVars(resolved, vars);
        }
        return null;
    }

    fn hexToColor(s: []const u8) ?Color {
        if (s.len < 7 or s[0] != '#') return null;
        const r = hexByte(s[1..3]) orelse return null;
        const g = hexByte(s[3..5]) orelse return null;
        const b = hexByte(s[5..7]) orelse return null;
        return Color{ .r = r, .g = g, .b = b };
    }

    fn hexByte(s: []const u8) ?u8 {
        if (s.len < 2) return null;
        const hi = hexDigit(s[0]) orelse return null;
        const lo = hexDigit(s[1]) orelse return null;
        return hi * 16 + lo;
    }

    fn hexDigit(c: u8) ?u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }
};

const Theme = @import("../theme/Theme.zig");
const Color = Theme.Color;

// ============================================================
// TextMate Syntax → WIZP Syntax Converter
// ============================================================

pub const SyntaxConverter = struct {
    /// Convert TextMate .tmLanguage JSON to WIZP syntax patterns.
    /// Extracts "match" patterns from the JSON "patterns" array.
    pub fn convert(allocator: Allocator, tm_json: []const u8, name: []const u8, scope: []const u8) !Syntax.SyntaxDefinition {
        var patterns = std.array_list.Managed(Syntax.MatchPattern).init(allocator);

        // Find patterns array and extract "match" entries
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, tm_json, pos, "\"match\"")) |m_start| {
            pos = m_start + 7;
            // Extract regex after "match"
            if (std.mem.indexOfScalarPos(u8, tm_json, m_start + 7, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, tm_json, v0 + 1, '"')) |v1| {
                    const regex = tm_json[v0 + 1 .. v1];

                    // Find scope name
                    var scope_name: []const u8 = "source";
                    if (std.mem.indexOfPos(u8, tm_json, v1, "\"name\"")) |n_start| {
                        if (std.mem.indexOfScalarPos(u8, tm_json, n_start + 6, '"')) |nv0| {
                            if (std.mem.indexOfScalarPos(u8, tm_json, nv0 + 1, '"')) |nv1| {
                                scope_name = tm_json[nv0 + 1 .. nv1];
                            }
                        }
                    }

                    try patterns.append(.{
                        .regex = try allocator.dupe(u8, regex),
                        .scope = try allocator.dupe(u8, scope_name),
                    });
                }
            }
        }

        return Syntax.SyntaxDefinition{
            .name = try allocator.dupe(u8, name),
            .scope = try allocator.dupe(u8, scope),
            .match_patterns = try patterns.toOwnedSlice(),
        };
    }
};

const Syntax = @import("../syntax/Syntax.zig");

// ============================================================
// JSON Parsers (minimal, no dependency)
// ============================================================

fn parseSearchResults(allocator: Allocator, json: []const u8) !VsxSearchResult {
    var extensions = std.array_list.Managed(VsxExtension).init(allocator);
    var total_count: usize = 0;

    // Extract totalCount
    if (std.mem.indexOf(u8, json, "\"totalCount\"")) |tc| {
        if (std.mem.indexOfScalarPos(u8, json, tc + 12, ':')) |col| {
            var num_start = col + 1;
            while (num_start < json.len and json[num_start] == ' ') num_start += 1;
            var num_end = num_start;
            while (num_end < json.len and json[num_end] >= '0' and json[num_end] <= '9') num_end += 1;
            total_count = std.fmt.parseInt(usize, json[num_start..num_end], 10) catch 0;
        }
    }

    // Find each extension object by looking for "namespace" keys in "extensions" array
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, "\"namespace\"")) |ns| {
        pos = ns + 12;
        var ext = VsxExtension{ .namespace = "", .name = "" };

        if (std.mem.indexOfScalarPos(u8, json, ns + 12, '"')) |v0| {
            if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                ext.namespace = try allocator.dupe(u8, json[v0 + 1 .. v1]);
            }
        }
        if (std.mem.indexOfPos(u8, json, pos, "\"name\"")) |n_start| {
            if (std.mem.indexOfScalarPos(u8, json, n_start + 6, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    const n = json[v0 + 1 .. v1];
                    if (!std.mem.eql(u8, n, ext.namespace)) ext.name = try allocator.dupe(u8, n);
                }
            }
        }
        if (std.mem.indexOfPos(u8, json, pos, "\"displayName\"")) |dn| {
            if (std.mem.indexOfScalarPos(u8, json, dn + 13, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    ext.display_name = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOfPos(u8, json, pos, "\"description\"")) |d| {
            if (std.mem.indexOfScalarPos(u8, json, d + 13, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    ext.description = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOfPos(u8, json, pos, "\"version\"")) |v| {
            if (std.mem.indexOfScalarPos(u8, json, v + 9, '"')) |v0| {
                if (std.mem.indexOfScalarPos(u8, json, v0 + 1, '"')) |v1| {
                    ext.version = try allocator.dupe(u8, json[v0 + 1 .. v1]);
                }
            }
        }
        if (std.mem.indexOfPos(u8, json, pos, "\"downloadCount\"")) |dc| {
            if (std.mem.indexOfScalarPos(u8, json, dc + 15, ':')) |col| {
                var n = col + 1;
                while (n < json.len and json[n] == ' ') n += 1;
                var ne = n;
                while (ne < json.len and json[ne] >= '0' and json[ne] <= '9') ne += 1;
                ext.download_count = std.fmt.parseInt(usize, json[n..ne], 10) catch 0;
            }
        }

        // Detect what this extension provides
        if (std.mem.indexOfPos(u8, json, pos, "\"themes\"")) |_| ext.has_themes = true;
        if (std.mem.indexOfPos(u8, json, pos, "\"iconThemes\"")) |_| ext.has_icon_theme = true;
        if (std.mem.indexOfPos(u8, json, pos, "\"grammars\"")) |_| ext.has_syntax = true;

        if (ext.namespace.len > 0) {
            try extensions.append(ext);
        }
    }

    const ext_count = extensions.items.len;
    return VsxSearchResult{
        .extensions = try extensions.toOwnedSlice(),
        .total_count = if (total_count > 0) total_count else ext_count,
    };
}

pub fn parseExtension(allocator: Allocator, json: []const u8) !VsxExtension {
    var ext = VsxExtension{ .namespace = "", .name = "" };

    // Extract namespace
    if (std.mem.indexOf(u8, json, "\"namespace\"")) |ns_start| {
        if (std.mem.indexOfScalarPos(u8, json, ns_start + 12, '"')) |val_start| {
            if (std.mem.indexOfScalarPos(u8, json, val_start + 1, '"')) |val_end| {
                ext.namespace = try allocator.dupe(u8, json[val_start + 1 .. val_end]);
            }
        }
    }

    // Extract name
    if (std.mem.indexOf(u8, json, "\"name\"")) |n_start| {
        if (std.mem.indexOfScalarPos(u8, json, n_start + 6, '"')) |val_start| {
            if (std.mem.indexOfScalarPos(u8, json, val_start + 1, '"')) |val_end| {
                const name_slice = json[val_start + 1 .. val_end];
                if (!std.mem.eql(u8, name_slice, ext.namespace)) {
                    ext.name = try allocator.dupe(u8, name_slice);
                }
            }
        }
    }

    // Extract displayName
    if (std.mem.indexOf(u8, json, "\"displayName\"")) |dn_start| {
        if (std.mem.indexOfScalarPos(u8, json, dn_start + 13, '"')) |val_start| {
            if (std.mem.indexOfScalarPos(u8, json, val_start + 1, '"')) |val_end| {
                ext.display_name = try allocator.dupe(u8, json[val_start + 1 .. val_end]);
            }
        }
    }

    // Extract description
    if (std.mem.indexOf(u8, json, "\"description\"")) |d_start| {
        if (std.mem.indexOfScalarPos(u8, json, d_start + 13, '"')) |val_start| {
            if (std.mem.indexOfScalarPos(u8, json, val_start + 1, '"')) |val_end| {
                ext.description = try allocator.dupe(u8, json[val_start + 1 .. val_end]);
            }
        }
    }

    // Extract version
    if (std.mem.indexOf(u8, json, "\"version\"")) |v_start| {
        if (std.mem.indexOfScalarPos(u8, json, v_start + 9, '"')) |val_start| {
            if (std.mem.indexOfScalarPos(u8, json, val_start + 1, '"')) |val_end| {
                ext.version = try allocator.dupe(u8, json[val_start + 1 .. val_end]);
            }
        }
    }

    return ext;
}

// ============================================================
// VS Code Icon Theme Converter
// ============================================================

pub const IconThemeConverter = struct {
    /// Convert VS Code icon theme JSON to WIZP file icon map.
    /// VS Code icon theme format:
    /// { "iconDefinitions": { "_file": { "iconPath": "./file.svg" }, ... },
    ///   "fileExtensions": { "zig": "_file", "rs": "_rust", ... },
    ///   "fileNames": { "Makefile": "_makefile", ... } }
    pub fn convert(allocator: Allocator, icon_json: []const u8) !std.StringHashMapUnmanaged([]const u8) {
        var map: std.StringHashMapUnmanaged([]const u8) = .empty;

        // Map file extensions to their icon definition names
        // Simple icon mapping: ext -> unicode emoji based on common associations
        var ext_mapping = std.StringHashMap([]const u8).init(allocator);

        // Parse fileExtensions: "ext": "iconDefinitionName"
        var ext_start: usize = 0;
        while (std.mem.indexOfPos(u8, icon_json, ext_start, "\"fileExtensions\"")) |fe_start| {
            ext_start = fe_start + 16;
            // Inside fileExtensions object, find key-value pairs
            var pair_start = ext_start;
            while (std.mem.indexOfPos(u8, icon_json, pair_start, "\"")) |q_start| {
                if (std.mem.indexOfScalarPos(u8, icon_json, q_start + 1, '"')) |q_end| {
                    const ext = icon_json[q_start + 1 .. q_end];
                    if (ext.len == 0 or std.mem.eql(u8, ext, "fileExtensions")) {
                        pair_start = q_end + 1;
                        continue;
                    }
                    // Find the value (icon definition name)
                    if (std.mem.indexOfPos(u8, icon_json, q_end, "\"")) |v_start| {
                        if (std.mem.indexOfScalarPos(u8, icon_json, v_start + 1, '"')) |v_end| {
                            const icon_name = icon_json[v_start + 1 .. v_end];
                            // Map common icon names to emoji
                            const emoji = mapIconToEmoji(icon_name);
                            try ext_mapping.put(try allocator.dupe(u8, ext), try allocator.dupe(u8, emoji));
                            pair_start = v_end + 1;
                        } else break;
                    } else break;
                } else break;
                if (std.mem.indexOfScalarPos(u8, icon_json, pair_start, '}')) |_| break;
            }
            break;
        }

        // Parse fileNames too
        var fn_start: usize = 0;
        while (std.mem.indexOfPos(u8, icon_json, fn_start, "\"fileNames\"")) |fn_s| {
            fn_start = fn_s + 12;
            var pair_start = fn_start;
            while (std.mem.indexOfPos(u8, icon_json, pair_start, "\"")) |q_start| {
                if (std.mem.indexOfScalarPos(u8, icon_json, q_start + 1, '"')) |q_end| {
                    const fname = icon_json[q_start + 1 .. q_end];
                    if (fname.len == 0 or std.mem.eql(u8, fname, "fileNames")) {
                        pair_start = q_end + 1;
                        continue;
                    }
                    if (std.mem.indexOfPos(u8, icon_json, q_end, "\"")) |v_start| {
                        if (std.mem.indexOfScalarPos(u8, icon_json, v_start + 1, '"')) |v_end| {
                            const icon_name = icon_json[v_start + 1 .. v_end];
                            const emoji = mapIconToEmoji(icon_name);
                            try ext_mapping.put(try allocator.dupe(u8, fname), try allocator.dupe(u8, emoji));
                            pair_start = v_end + 1;
                        } else break;
                    } else break;
                } else break;
                if (std.mem.indexOfScalarPos(u8, icon_json, pair_start, '}')) |_| break;
            }
            break;
        }

        // Convert StringHashMap to StringHashMapUnmanaged for return type
        var it = ext_mapping.iterator();
        while (it.next()) |entry| {
            try map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        return map;
    }

    fn mapIconToEmoji(name: []const u8) []const u8 {
        if (std.mem.indexOf(u8, name, "rust") != null) return "🦀";
        if (std.mem.indexOf(u8, name, "zig") != null) return "⚡";
        if (std.mem.indexOf(u8, name, "python") != null) return "🐍";
        if (std.mem.indexOf(u8, name, "javascript") != null or std.mem.indexOf(u8, name, "js") != null) return "🟨";
        if (std.mem.indexOf(u8, name, "typescript") != null or std.mem.indexOf(u8, name, "ts") != null) return "🔷";
        if (std.mem.indexOf(u8, name, "react") != null or std.mem.indexOf(u8, name, "jsx") != null) return "⚛️";
        if (std.mem.indexOf(u8, name, "go") != null) return "🔵";
        if (std.mem.indexOf(u8, name, "java") != null) return "☕";
        if (std.mem.indexOf(u8, name, "ruby") != null) return "💎";
        if (std.mem.indexOf(u8, name, "lua") != null) return "🌙";
        if (std.mem.indexOf(u8, name, "html") != null) return "🌐";
        if (std.mem.indexOf(u8, name, "css") != null) return "🎨";
        if (std.mem.indexOf(u8, name, "json") != null) return "📋";
        if (std.mem.indexOf(u8, name, "yaml") != null or std.mem.indexOf(u8, name, "yml") != null) return "📄";
        if (std.mem.indexOf(u8, name, "markdown") != null or std.mem.indexOf(u8, name, "md") != null) return "📝";
        if (std.mem.indexOf(u8, name, "docker") != null) return "🐳";
        if (std.mem.indexOf(u8, name, "git") != null) return "🔀";
        if (std.mem.indexOf(u8, name, "file") != null or std.mem.indexOf(u8, name, "default") != null) return "📄";
        if (std.mem.indexOf(u8, name, "folder") != null) return "📁";
        return "📄";
    }
};
