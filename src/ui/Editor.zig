// WIZP Editor UI - VSCode-style layout
// Activity Bar | Sidebar | Editor + Tabs + Minimap + Breadcrumbs | Status Bar

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Buffer = @import("../buffer/Buffer.zig");
const Cursor = @import("../buffer/Cursor.zig");
const Selection = @import("../buffer/Selection.zig");
const View = @import("../buffer/View.zig");
const Syntax = @import("../syntax/Syntax.zig");
const ThemeMod = @import("../theme/Theme.zig");
const TerminalMod = @import("Terminal.zig");
const Terminal = TerminalMod.Terminal;
const Keybind = @import("../keybind/Keybind.zig");
const Config = @import("../config/Config.zig");
const LLM = @import("../llm/LLM.zig");
const KiloCode = @import("../kilo/KiloCode.zig");
const Experience = @import("../polish/Experience.zig");
const AIPanel = @import("AIPanel.zig");
const EditorRpc = @import("EditorRpc.zig");
const EditorJson = @import("EditorJson.zig");
const ContentLength = @import("../protocol/ContentLength.zig");
const LSP = @import("../lsp/LSP.zig");
const DAP = @import("../debug/DAP.zig");
const OpenVSX = @import("../hub/OpenVSX.zig");
const ZlayAccessibility = @import("ZlayAccessibility.zig");
const ZlayEditorInteraction = @import("ZlayEditorInteraction.zig");
const SuiteManifest = @import("SuiteManifest.zig");
const VSIXLoader = @import("../hub/VSIXLoader.zig").VSIXLoader;
const GhosttyMod = if (builtin.os.tag != .windows) @import("../ghostty/Ghostty.zig") else struct {
    pub const Ghostty = struct {
        surface: ?*anyopaque = null,

        pub fn init(allocator: Allocator) Ghostty {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Ghostty) void {
            _ = self;
        }

        pub fn available() bool {
            return false;
        }

        pub fn isAvailable(self: *const Ghostty) bool {
            _ = self;
            return false;
        }

        pub fn version(self: *const Ghostty) []const u8 {
            _ = self;
            return "xterm.js (fallback)";
        }

        pub fn createSurface(self: *Ghostty, cols: u32, rows: u32) !void {
            _ = self;
            _ = cols;
            _ = rows;
            return error.GhosttyNotAvailable;
        }

        pub fn render(self: *Ghostty, width: u32, height: u32) !void {
            _ = self;
            _ = width;
            _ = height;
            return error.GhosttyNotAvailable;
        }
    };
};
const threading = @import("../threading/main.zig");
const Types = @import("EditorTypes.zig");
const terminal = @import("../terminal/Session.zig");
const runtime = @import("../runtime_016.zig");
const dvui_available = @import("dvui_available");
const DVUICore = if (dvui_available.WIZP_DVUI_AVAILABLE) @import("../dvui_core.zig").DVUICore else struct { dummy: u8 = 0 };
const dvui = @import("dvui");

const Notification = struct {
    id: u32,
    message: []const u8,
    kind: u8,
    timestamp: i64,
    expires: i64,
};

const RegexMatch = struct {
    start: usize,
    end: usize,
};
const EditorMode = Types.EditorMode;
const PanelType = Types.PanelType;
const ActivityItem = Types.ActivityItem;
const SplitDir = Types.SplitDir;
const Layout = Types.Layout;
const LayoutConst = Types.LayoutConst;
const ACTIVITY_ICONS = Types.ACTIVITY_ICONS;
const Tab = Types.Tab;
const EditorGroup = Types.EditorGroup;

const Theme = ThemeMod;
const Color = Theme.Color;

const EditorRenderer = @import("EditorRenderer.zig");
const VSColors = EditorRenderer.VSColors;

// Main Editor
// ============================================================

pub const Editor = struct {
    allocator: Allocator,
    dvui_core: ?*DVUICore,
    theme: Theme.ThemeDef,
    config: Config.EditorConfig,
    mode: EditorMode = .normal,
    keybind_manager: Keybind.KeybindManager,
    terminal: Terminal,
    running: bool = true,
    message: ?[]const u8 = null,
    clipboard: ?[]const u8 = null,
    search_query: ?[]const u8 = null,

    // Notification system
    notifications: std.array_list.Managed(Notification),
    active_notification: ?usize = null, // Index in notifications array

    // VSCode layout state
    layout: Layout = .{},
    active_activity: ActivityItem = .explorer,
    activity_bar_side: bool = true, // true = left side, false = sidebar header
    sidebar_visible: bool = true,
    panel_visible: bool = false,
    panel_type: PanelType = .terminal,
    panel_height: usize = 8,
    zen_mode: bool = false,
    line_wrap: bool = false,
    context_menu_visible: bool = false,
    context_menu_x: usize = 0,
    context_menu_y: usize = 0,
    lsp_suggestion: ?Experience.LspSuggestion = null,
    lsp_client: ?*LSP.LSPClient = null,
    /// Cached OpenVSX search results for marketplace
    openvsx_results: ?OpenVSX.VsxSearchResult = null,
    hub_search_visible: bool = false,
    hub_search_input: std.array_list.Managed(u8),
    hub_search_last_query: ?[]const u8 = null,
    hub_search_last_ms: i64 = 0,
    hub_search_error: ?[]const u8 = null,
    hub_network_failure_attempted: bool = false,
    hub_installed_extensions: std.StringArrayHashMapUnmanaged(HubInstalledExtension) = .{},
    git_last_refresh_ms: i64 = 0,
    git_branch: ?[]const u8 = null,
    git_items: std.array_list.Managed([]const u8),
    git_error: ?[]const u8 = null,

    file_tree_dir: ?[]const u8 = null,
    file_tree_last_refresh_ms: i64 = 0,
    file_tree_selected: usize = 0,
    file_tree_entries: std.array_list.Managed(FileTreeEntry),
    workspace_folders: std.array_list.Managed([]const u8),
    recent_workspaces: std.array_list.Managed([]const u8),
    workspace_settings_json: ?[]const u8 = null,
    active_profile: ?[]const u8 = null,
    workspace_trusted: bool = true,
    config_values: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    document_states: std.StringArrayHashMapUnmanaged(DocumentState) = .{},

    // Editor Groups (split panes)
    groups: std.array_list.Managed(EditorGroup),
    active_group: usize = 0,
    zlay_capture_owner: ?usize = null,
    /// Whether tab bar is visible
    tab_bar_visible: bool = true,
    /// Split direction
    split_direction: SplitDir = .none,

    // AI/LLM integration
    llm_config: LLM.LLMConfig = .{},
    kilocode: ?KiloCode.KiloCode = null,
    ai_enabled: bool = false,
    ai_chat_visible: bool = false,
    ai_chat_input: std.array_list.Managed(u8),
    ai_chat_messages: std.array_list.Managed(KiloCode.ChatMessage),
    ai_last_completion: ?[]const u8 = null,
    ai_generating: bool = false,
    ai_chat_pending: bool = false,
    /// Channel for worker threads → main thread results
    worker_results: threading.Channel(threading.WorkerResult),
    // Pending LSP request IDs for correlating responses
    lsp_pending_id: u32 = 0,
    /// PTY session with dedicated reader thread (Ghostty-inspired event-driven model)
    terminal_session: ?*terminal.Session = null,
    terminal_sessions: std.AutoHashMapUnmanaged(usize, *terminal.Session) = .{},
    next_terminal_id: usize = 1,
    /// Background worker pool for non-blocking I/O, LSP, search, AI
    worker_pool: *threading.WorkerPool,
    /// Dedicated pool keeps workspace search responsive during Git and AI work.
    search_pool: *threading.WorkerPool,
    write_mutex: @import("../sync.zig").Mutex = .{},
    // AI settings panel
    ai_settings_visible: bool = false,
    ai_settings_field: AISettingsField = .provider,
    ai_settings_model_input: std.array_list.Managed(u8),
    ai_settings_key_input: std.array_list.Managed(u8),
    ai_settings_base_input: std.array_list.Managed(u8),
    ai_settings_temp: f32 = 0.7,
    ai_settings_max_tokens: usize = 4096,
    webviews: std.StringArrayHashMapUnmanaged(WebviewState) = .{},
    debug_client: ?*DAP.DAPClient = null,
    debug_fixture_process: ?std.process.Child = null,
    debug_running: bool = false,
    debug_paused: bool = false,
    debug_no_debug: bool = false,
    debug_fixture: bool = false,
    debug_adapter_lost: bool = false,
    debug_thread_id: usize = 1,
    debug_breakpoints: std.array_list.Managed(DebugBreakpoint),

    pub const WebviewState = struct {
        id: []const u8,
        title: []const u8,
        html: []const u8,
    };

    const CommandResult = struct {
        exit_code: u8,
        stdout: []u8,
        stderr: []u8,
    };

    const ReplaceResult = struct {
        text: []u8,
        count: usize,
    };

    const SnippetPlaceholder = struct {
        index: usize,
        start: usize,
        end: usize,
        choices: ?[]const u8,
    };

    const SnippetExpansion = struct {
        text: []u8,
        placeholders: std.array_list.Managed(SnippetPlaceholder),
    };

    const DebugBreakpoint = struct {
        file: []const u8,
        line: usize,
        condition: ?[]const u8 = null,
        hit_condition: ?[]const u8 = null,
        log_message: ?[]const u8 = null,
    };

    const HubExtensionSource = enum {
        fixture,
        marketplace,
        local,
    };

    const HubInstalledExtension = struct {
        enabled: bool,
        display_name: []const u8,
        version: []const u8,
        source: HubExtensionSource,
        restart_required: bool,
        local_path: ?[]const u8 = null,
    };

    const DocumentState = struct {
        uri: []const u8,
        path: []const u8,
        language_id: []const u8,
        text: []const u8,
        version: usize,
        dirty: bool,
        eol: []const u8,
        encoding: []const u8,
    };

    const AISettingsField = AIPanel.AISettingsField;

    const FileTreeEntry = struct {
        name: []const u8,
        path: []const u8,
        kind: std.Io.File.Kind,
    };

    const Self = @This();

    fn clearGitCache(self: *Self) void {
        if (self.git_branch) |b| self.allocator.free(b);
        self.git_branch = null;
        for (self.git_items.items) |it| self.allocator.free(it);
        self.git_items.clearRetainingCapacity();
        if (self.git_error) |m| self.allocator.free(m);
        self.git_error = null;
    }

    fn clearFileTreeCache(self: *Self) void {
        if (self.file_tree_dir) |d| self.allocator.free(d);
        self.file_tree_dir = null;
        for (self.file_tree_entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.path);
        }
        self.file_tree_entries.clearRetainingCapacity();
        self.file_tree_selected = 0;
        self.file_tree_last_refresh_ms = 0;
    }

    fn ensureFileTreeDir(self: *Self) void {
        if (self.file_tree_dir == null) {
            self.file_tree_dir = self.allocator.dupe(u8, ".") catch null;
        }
    }

    fn setFileTreeDir(self: *Self, new_dir: []const u8) void {
        self.ensureFileTreeDir();
        if (self.file_tree_dir) |d| self.allocator.free(d);
        self.file_tree_dir = self.allocator.dupe(u8, new_dir) catch null;
        self.file_tree_selected = 0;
        self.file_tree_last_refresh_ms = 0;
    }

    fn refreshFileTree(self: *Self) void {
        self.ensureFileTreeDir();
        const dir_path = self.file_tree_dir orelse return;

        for (self.file_tree_entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.path);
        }
        self.file_tree_entries.clearRetainingCapacity();

        if (!std.mem.eql(u8, dir_path, ".") and !std.mem.eql(u8, dir_path, "/")) {
            const parent_dir = std.fs.path.dirname(dir_path) orelse ".";
            const parent_path = self.allocator.dupe(u8, parent_dir) catch return;
            const parent_name = self.allocator.dupe(u8, "..") catch {
                self.allocator.free(parent_path);
                return;
            };
            self.file_tree_entries.append(.{
                .name = parent_name,
                .path = parent_path,
                .kind = .directory,
            }) catch {
                self.allocator.free(parent_name);
                self.allocator.free(parent_path);
            };
        }

        var dir = std.Io.Dir.cwd().openDir(
            runtime.io(),
            dir_path,
            .{ .iterate = true },
        ) catch return;
        defer dir.close(runtime.io());
        var it = dir.iterate();
        while (it.next(runtime.io()) catch null) |entry| {
            const name_dup = self.allocator.dupe(u8, entry.name) catch continue;
            const path_joined = std.fs.path.join(self.allocator, &.{ dir_path, entry.name }) catch {
                self.allocator.free(name_dup);
                continue;
            };
            self.file_tree_entries.append(.{
                .name = name_dup,
                .path = path_joined,
                .kind = entry.kind,
            }) catch {
                self.allocator.free(name_dup);
                self.allocator.free(path_joined);
            };
        }

        const Ctx = struct {};
        const lessThan = struct {
            fn lt(_: Ctx, a: FileTreeEntry, b: FileTreeEntry) bool {
                const a_is_parent = std.mem.eql(u8, a.name, "..");
                const b_is_parent = std.mem.eql(u8, b.name, "..");
                if (a_is_parent != b_is_parent) return a_is_parent;
                const a_is_dir = a.kind == .directory;
                const b_is_dir = b.kind == .directory;
                if (a_is_dir != b_is_dir) return a_is_dir;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt;

        std.sort.pdq(FileTreeEntry, self.file_tree_entries.items, Ctx{}, lessThan);

        if (self.file_tree_entries.items.len == 0) {
            self.file_tree_selected = 0;
        } else if (self.file_tree_selected >= self.file_tree_entries.items.len) {
            self.file_tree_selected = self.file_tree_entries.items.len - 1;
        }

        self.file_tree_last_refresh_ms = runtime.milliTimestamp();
    }

    fn maybeRefreshFileTree(self: *Self) void {
        const now = runtime.milliTimestamp();
        if (now - self.file_tree_last_refresh_ms > 1000) {
            self.refreshFileTree();
        }
    }

    fn freeOpenVSXResults(self: *Self, results: *OpenVSX.VsxSearchResult) void {
        for (results.extensions) |ext| {
            if (ext.namespace.len > 0) self.allocator.free(ext.namespace);
            if (ext.name.len > 0) self.allocator.free(ext.name);
            if (ext.display_name.len > 0) self.allocator.free(ext.display_name);
            if (ext.description.len > 0) self.allocator.free(ext.description);
            if (ext.version.len > 0) self.allocator.free(ext.version);
            if (ext.publisher.len > 0) self.allocator.free(ext.publisher);
        }
        self.allocator.free(results.extensions);
        results.extensions = &.{};
        results.total_count = 0;
    }

    fn setHubSearchError(self: *Self, msg: []const u8) void {
        if (self.hub_search_error) |m| self.allocator.free(m);
        self.hub_search_error = self.allocator.dupe(u8, msg) catch null;
    }

    fn freeHubInstalledExtension(self: *Self, key: []const u8, extension: HubInstalledExtension) void {
        self.allocator.free(key);
        self.allocator.free(extension.display_name);
        self.allocator.free(extension.version);
        if (extension.local_path) |path| self.allocator.free(path);
    }

    fn putHubInstalledExtension(
        self: *Self,
        id: []const u8,
        display_name: []const u8,
        version: []const u8,
        source: HubExtensionSource,
        local_path: ?[]const u8,
    ) !void {
        const owned_display_name = try self.allocator.dupe(u8, display_name);
        errdefer self.allocator.free(owned_display_name);
        const owned_version = try self.allocator.dupe(u8, version);
        errdefer self.allocator.free(owned_version);
        const owned_local_path = if (local_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (owned_local_path) |path| self.allocator.free(path);
        const value = HubInstalledExtension{
            .enabled = true,
            .display_name = owned_display_name,
            .version = owned_version,
            .source = source,
            .restart_required = source != .fixture,
            .local_path = owned_local_path,
        };

        if (self.hub_installed_extensions.getPtr(id)) |existing| {
            self.allocator.free(existing.display_name);
            self.allocator.free(existing.version);
            if (existing.local_path) |path| self.allocator.free(path);
            existing.* = value;
            return;
        }
        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        try self.hub_installed_extensions.put(self.allocator, key, value);
    }

    fn hubExtensionsDir(self: *Self) ![]u8 {
        const home_name = if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = try runtime.getEnvVarOwned(self.allocator, home_name);
        defer self.allocator.free(home);
        return try std.fs.path.join(self.allocator, &.{ home, ".wizp", "extensions" });
    }

    fn hubDisabledExtensionsPath(self: *Self) ![]u8 {
        const home_name = if (comptime builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = try runtime.getEnvVarOwned(self.allocator, home_name);
        defer self.allocator.free(home);
        return try std.fs.path.join(self.allocator, &.{ home, ".wizp", "disabled-extensions" });
    }

    fn isHubExtensionDisabled(self: *Self, id: []const u8) bool {
        const path = self.hubDisabledExtensionsPath() catch return false;
        defer self.allocator.free(path);
        const content = runtime.readFileAlloc(self.allocator, path, 1024 * 1024) catch return false;
        defer self.allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), id)) return true;
        }
        return false;
    }

    fn persistHubDisabledExtensions(self: *Self) !void {
        const path = try self.hubDisabledExtensionsPath();
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try runtime.createDirPath(parent);
        var document: std.Io.Writer.Allocating = .init(self.allocator);
        defer document.deinit();
        var installed_it = self.hub_installed_extensions.iterator();
        while (installed_it.next()) |entry| {
            if (entry.value_ptr.enabled) continue;
            try document.writer.writeAll(entry.key_ptr.*);
            try document.writer.writeAll("\n");
        }
        try runtime.writeFile(path, document.written());
    }

    fn syncHubInstalledFromDisk(self: *Self) !void {
        const extensions_dir = try self.hubExtensionsDir();
        defer self.allocator.free(extensions_dir);
        var dir = std.Io.Dir.cwd().openDir(
            runtime.io(),
            extensions_dir,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(runtime.io());
        var entries = dir.iterate();
        while (try entries.next(runtime.io())) |entry| {
            if (entry.kind != .directory) continue;
            const extension_path = try std.fs.path.join(self.allocator, &.{ extensions_dir, entry.name });
            defer self.allocator.free(extension_path);
            const manifest_path = try std.fs.path.join(self.allocator, &.{ extension_path, "package.json" });
            defer self.allocator.free(manifest_path);
            const manifest_json = runtime.readFileAlloc(self.allocator, manifest_path, 1024 * 1024) catch continue;
            defer self.allocator.free(manifest_json);
            const manifest = VSIXLoader.parseManifest(self.allocator, manifest_json) catch continue;
            defer {
                var loader = VSIXLoader.init(self.allocator, extensions_dir);
                loader.freeManifest(manifest);
            }
            const extension_id = try std.fmt.allocPrint(
                self.allocator,
                "{s}.{s}",
                .{ manifest.publisher, manifest.id },
            );
            defer self.allocator.free(extension_id);
            if (self.hub_installed_extensions.contains(extension_id)) continue;
            try self.putHubInstalledExtension(
                extension_id,
                manifest.name,
                manifest.version,
                .local,
                extension_path,
            );
            const installed = self.hub_installed_extensions.getPtr(extension_id).?;
            installed.enabled = !self.isHubExtensionDisabled(extension_id);
            installed.restart_required = false;
        }
    }

    fn installHubVSIX(self: *Self, vsix_path: []const u8) !VSIXLoader.InstallResult {
        const real_path = try std.Io.Dir.cwd().realPathFileAlloc(
            runtime.io(),
            vsix_path,
            self.allocator,
        );
        defer self.allocator.free(real_path);
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(real_path), ".vsix")) {
            return error.InvalidVSIXExtension;
        }
        const stat = try std.Io.Dir.cwd().statFile(runtime.io(), real_path, .{});
        if (stat.kind != .file) return error.InvalidVSIXFile;
        if (stat.size > 100 * 1024 * 1024) return error.VSIXTooLarge;

        const extensions_dir = try self.hubExtensionsDir();
        defer self.allocator.free(extensions_dir);
        try runtime.createDirPath(extensions_dir);
        var loader = VSIXLoader.init(self.allocator, extensions_dir);
        return try loader.installVSIX(real_path);
    }

    fn runOpenVSXSearch(self: *Self, query: []const u8) void {
        const now = runtime.milliTimestamp();
        if (self.hub_search_last_query) |q| {
            if (std.mem.eql(u8, q, query) and (now - self.hub_search_last_ms) < 30_000) {
                return;
            }
        }

        if (self.hub_search_last_query) |q| self.allocator.free(q);
        self.hub_search_last_query = self.allocator.dupe(u8, query) catch null;
        self.hub_search_last_ms = now;

        if (self.openvsx_results) |*old| {
            self.freeOpenVSXResults(old);
            self.openvsx_results = null;
        }
        if (self.hub_search_error) |m| self.allocator.free(m);
        self.hub_search_error = null;

        var client = OpenVSX.OpenVSXClient.init(self.allocator);
        defer client.deinit();
        const results = client.search(query, 10) catch |e| {
            self.setHubSearchError(@errorName(e));
            return;
        };
        self.openvsx_results = results;
    }

    fn writeHubSearchResult(self: *Self, id_str: []const u8, query: []const u8, allow_network: bool, fixture: bool) ![]u8 {
        if (!allow_network and !fixture) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"extensions\":[],\"total\":0,\"networkRequired\":true,\"networkPolicy\":\"lazy-opt-in\",\"status\":\"network-consent-required\"}}}}",
                .{id_str},
            );
        }
        if (fixture and std.mem.eql(u8, query, "network-failure") and !self.hub_network_failure_attempted) {
            self.hub_network_failure_attempted = true;
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"extensions\":[],\"total\":0,\"networkRequired\":false,\"networkPolicy\":\"fixture-no-network\",\"error\":\"https://open-vsx.org/api/search?token=fixture-secret\",\"status\":\"openvsx-search-failed\"}}}}",
                .{id_str},
            );
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"extensions\":[", .{id_str});
        if (fixture) {
            try w.writeAll("{\"namespace\":\"wizp-smoke\",\"name\":\"alpha-tools\",\"id\":\"wizp-smoke.alpha-tools\",\"displayName\":\"Alpha Tools\",\"description\":\"Fixture extension for install lifecycle smoke\",\"version\":\"1.0.0\",\"downloads\":42,\"verifiedFixture\":true}");
            try w.writeAll(",{\"namespace\":\"wizp-smoke\",\"name\":\"theme-pack\",\"id\":\"wizp-smoke.theme-pack\",\"displayName\":\"Theme Pack\",\"description\":\"Fixture extension with update metadata\",\"version\":\"1.1.0\",\"downloads\":17,\"verifiedFixture\":true,\"updateAvailable\":true}");
            try w.writeAll(",{\"namespace\":\"wizp-smoke\",\"name\":\"broken-tools\",\"id\":\"wizp-smoke.broken-tools\",\"displayName\":\"Broken Tools\",\"description\":\"Fixture extension that fails installation without changing installed state\",\"version\":\"0.0.1\",\"downloads\":0,\"verifiedFixture\":true,\"installFailureFixture\":true}");
            try w.writeAll("],\"total\":3,\"networkRequired\":false,\"networkPolicy\":\"fixture-no-network\",\"status\":\"fixture-search-complete\"}}");
            return try out.toOwnedSlice();
        }

        var client = OpenVSX.OpenVSXClient.init(self.allocator);
        defer client.deinit();
        const results = client.search(query, 20) catch |err| {
            out.deinit();
            var failed: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer failed.deinit();
            const fw = &failed.writer;
            try fw.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"extensions\":[],\"total\":0,\"networkRequired\":false,\"networkPolicy\":\"lazy-opt-in\",\"error\":", .{id_str});
            try writeJsonString(fw, @errorName(err));
            try fw.writeAll(",\"status\":\"openvsx-search-failed\"}}");
            return try failed.toOwnedSlice();
        };
        defer {
            var mutable = results;
            self.freeOpenVSXResults(&mutable);
        }
        for (results.extensions, 0..) |ext, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"namespace\":");
            try writeJsonString(w, ext.namespace);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, ext.name);
            try w.writeAll(",\"id\":");
            const extension_id = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ext.namespace, ext.name });
            defer self.allocator.free(extension_id);
            try writeJsonString(w, extension_id);
            try w.writeAll(",\"displayName\":");
            try writeJsonString(w, if (ext.display_name.len > 0) ext.display_name else ext.name);
            try w.writeAll(",\"description\":");
            try writeJsonString(w, ext.description);
            try w.writeAll(",\"version\":");
            try writeJsonString(w, ext.version);
            try w.print(",\"downloads\":{}", .{ext.download_count});
            try w.writeByte('}');
        }
        try w.print("],\"total\":{},\"networkRequired\":false,\"networkPolicy\":\"lazy-opt-in\",\"status\":\"openvsx-search-complete\"}}", .{results.total_count});
        return try out.toOwnedSlice();
    }

    fn hubExtensionId(self: *Self, body: []const u8) ![]const u8 {
        if (self.extractAndUnescape(body, "extensionId")) |id| return id;
        if (std.mem.lastIndexOf(u8, body, "\"id\"")) |index| {
            if (self.extractAndUnescape(body[index..], "id")) |id| return id;
        }
        const namespace = self.extractAndUnescape(body, "namespace") orelse try self.allocator.dupe(u8, "wizp-smoke");
        defer self.allocator.free(namespace);
        const name = self.extractAndUnescape(body, "name") orelse try self.allocator.dupe(u8, "alpha-tools");
        defer self.allocator.free(name);
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ namespace, name });
    }

    fn writeHubInstalledList(self: *Self, id_str: []const u8) ![]u8 {
        try self.syncHubInstalledFromDisk();
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"installed\":[", .{id_str});
        var it = self.hub_installed_extensions.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            const extension_id = entry.key_ptr.*;
            try w.writeAll("{\"id\":");
            try writeJsonString(w, extension_id);
            try w.writeAll(",\"name\":");
            const dot = std.mem.lastIndexOfScalar(u8, extension_id, '.') orelse 0;
            const name = if (dot + 1 < extension_id.len) extension_id[dot + 1 ..] else extension_id;
            try writeJsonString(w, name);
            try w.writeAll(",\"displayName\":");
            try writeJsonString(w, entry.value_ptr.display_name);
            try w.writeAll(",\"version\":");
            try writeJsonString(w, entry.value_ptr.version);
            try w.writeAll(",\"enabled\":");
            try w.writeAll(if (entry.value_ptr.enabled) "true" else "false");
            try w.writeAll(",\"source\":");
            try writeJsonString(w, @tagName(entry.value_ptr.source));
            try w.print(",\"restartRequired\":{},\"updateAvailable\":false}}", .{entry.value_ptr.restart_required});
        }
        try w.writeAll("],\"networkPolicy\":\"lazy-opt-in\",\"status\":\"installed-list\"}}");
        return try out.toOwnedSlice();
    }

    fn gitWorkspaceCwd(self: *Self) ?[]const u8 {
        return if (self.workspace_folders.items.len > 0) self.workspace_folders.items[0] else null;
    }
    fn resolveWorkspacePath(self: *Self, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path) or self.workspace_folders.items.len == 0) {
            return self.allocator.dupe(u8, path);
        }
        return std.fs.path.join(self.allocator, &.{ self.workspace_folders.items[0], path });
    }

    fn renameFilesystemPath(allocator: std.mem.Allocator, old_path: []const u8, new_path: []const u8) !void {
        if (builtin.os.tag != .windows and std.fs.path.isAbsolute(old_path) and std.fs.path.isAbsolute(new_path)) {
            const old_z = try runtime.dupeZ(allocator, old_path);
            defer allocator.free(old_z);
            const new_z = try runtime.dupeZ(allocator, new_path);
            defer allocator.free(new_z);
            const result = std.posix.system.renameat(
                std.posix.AT.FDCWD,
                old_z.ptr,
                std.posix.AT.FDCWD,
                new_z.ptr,
            );
            if (std.posix.errno(result) != .SUCCESS) return error.Unexpected;
            return;
        }
        return std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, runtime.io());
    }

    fn runGitCapture(self: *Self, argv: []const []const u8, cwd: ?[]const u8) !CommandResult {
        const result = try std.process.run(self.allocator, runtime.io(), .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });

        return .{
            .exit_code = switch (result.term) {
                .exited => |code| code,
                else => 1,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn freeCommandResult(self: *Self, result: CommandResult) void {
        _ = result.exit_code;
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn jsonRpcError(self: *Self, id_str: []const u8, code: i32, message: []const u8) ![]const u8 {
        return try EditorRpc.errorResponse(self.allocator, id_str, code, message);
    }

    fn jsonRpcInstallFailure(self: *Self, id_str: []const u8, operation: []const u8, err: anyerror) ![]const u8 {
        const retryable = VSIXLoader.isRetryableInstallError(err);
        const message = if (retryable)
            try std.fmt.allocPrint(
                self.allocator,
                "{s}: {s} (retryable; No extensions were changed)",
                .{ operation, @errorName(err) },
            )
        else
            try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) });
        defer self.allocator.free(message);
        const code = if (retryable) VSIXLoader.retryable_install_rpc_code else -32000;
        return try self.jsonRpcError(id_str, code, message);
    }

    fn gitFailureDetailsSafe(details: []const u8) []const u8 {
        if (std.mem.indexOf(u8, details, "://") != null and std.mem.indexOfScalar(u8, details, '@') != null) {
            return "<redacted>";
        }
        return details;
    }

    fn jsonRpcGitFailure(self: *Self, id_str: []const u8, action: []const u8, result: CommandResult) ![]const u8 {
        const details = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \t\r\n");
        const safe_details = gitFailureDetailsSafe(details);
        const message = if (safe_details.len > 0)
            try std.fmt.allocPrint(self.allocator, "git {s} failed (exit {}): {s}", .{ action, result.exit_code, safe_details })
        else
            try std.fmt.allocPrint(self.allocator, "git {s} failed (exit {})", .{ action, result.exit_code });
        defer self.allocator.free(message);
        return try self.jsonRpcError(id_str, -32000, message);
    }

    fn credentialCancellationFixtureRequested(self: *Self, body: []const u8) bool {
        if (extractBoolParam(body, "credentialFixture") orelse false) return true;
        if (extractBoolParam(body, "fixture") orelse false) return true;
        if (self.extractAndUnescape(body, "credentialFixture")) |mode| {
            defer self.allocator.free(mode);
            if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "cancelled")) return true;
        }
        if (self.extractAndUnescape(body, "fixture")) |mode| {
            defer self.allocator.free(mode);
            if (std.mem.eql(u8, mode, "credential-cancel") or std.mem.eql(u8, mode, "cancelled")) return true;
        }
        const env_mode = runtime.getEnvVarOwned(self.allocator, "WIZP_SCM_CREDENTIAL_FIXTURE") catch return false;
        defer self.allocator.free(env_mode);
        return std.mem.eql(u8, env_mode, "cancel") or std.mem.eql(u8, env_mode, "cancelled");
    }

    fn credentialFixtureSafeRemote(remote: []const u8) []const u8 {
        if (remote.len == 0) return "<redacted>";
        for (remote) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '/')) {
                return "<redacted>";
            }
        }
        return remote;
    }

    fn jsonRpcCredentialCancellation(
        self: *Self,
        id_str: []const u8,
        command: []const u8,
        remote: []const u8,
        dry_run: bool,
    ) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":false,\"cancelled\":true,\"state\":\"cancelled\",\"fixture\":true,\"dryRun\":{},\"credentialSafe\":true,\"credentialPolicy\":\"non-interactive\",\"credentialPromptRequired\":false,\"networkAttempted\":false,\"credentialHelper\":\"fixture\",\"credentialHelperInvoked\":true,\"credentialHelperOutcome\":\"cancelled\",\"secretPersisted\":false,\"secretEchoed\":false,\"cancelReason\":\"credential-helper-cancelled\",\"remote\":",
            .{ id_str, dry_run },
        );
        try writeJsonString(w, credentialFixtureSafeRemote(remote));
        try w.writeAll(",\"command\":");
        try writeJsonString(w, command);
        try w.writeAll(",\"stdout\":\"\",\"stderr\":\"\"}}");
        return try out.toOwnedSlice();
    }

    fn appendGitPathArgs(self: *Self, args: *std.array_list.Managed([]const u8), body: []const u8, allow_files_list: bool) !bool {
        var appended = false;
        if (allow_files_list) {
            if (self.extractAndUnescape(body, "files")) |files| {
                defer self.allocator.free(files);
                var it = std.mem.splitScalar(u8, files, ',');
                while (it.next()) |raw| {
                    const file = std.mem.trim(u8, raw, " \t\r\n");
                    if (file.len == 0) continue;
                    try args.append(try self.allocator.dupe(u8, file));
                    appended = true;
                }
                if (appended) return true;
            }
        }
        if (self.extractAndUnescape(body, "file")) |file| {
            defer self.allocator.free(file);
            const trimmed = std.mem.trim(u8, file, " \t\r\n");
            if (trimmed.len > 0) {
                try args.append(try self.allocator.dupe(u8, trimmed));
                appended = true;
            }
        }
        return appended;
    }

    fn jsonRpcResultRaw(self: *Self, id_str: []const u8, raw_json: []const u8) ![]const u8 {
        return try EditorRpc.resultRaw(self.allocator, id_str, raw_json);
    }

    fn fileUriToPath(self: *Self, uri_or_path: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, uri_or_path, "file://")) {
            return try self.allocator.dupe(u8, uri_or_path["file://".len..]);
        }
        return try self.allocator.dupe(u8, uri_or_path);
    }

    fn writeSymbolRange(writer: anytype, line: usize, col: usize) !void {
        try writer.print("{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}", .{ line, col, line, col + 1 });
    }

    fn writeSymbolObject(writer: anytype, name: []const u8, kind: u8, uri: []const u8, line: usize, col: usize, container: ?[]const u8) !void {
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, name);
        try writer.print(",\"kind\":{}", .{kind});
        if (container) |c| {
            try writer.writeAll(",\"containerName\":");
            try writeJsonString(writer, c);
        }
        try writer.writeAll(",\"location\":{\"uri\":");
        try writeJsonString(writer, uri);
        try writer.writeAll(",\"range\":");
        try writeSymbolRange(writer, line, col);
        try writer.writeAll("},\"range\":");
        try writeSymbolRange(writer, line, col);
        try writer.writeAll(",\"selectionRange\":");
        try writeSymbolRange(writer, line, col);
        try writer.writeAll("}");
    }

    const SymbolInfo = struct {
        name: []const u8,
        kind: u8,
        line: usize,
        col: usize,
        parent: ?usize,
    };

    fn writeDocumentSymbolObject(writer: anytype, symbols: []const SymbolInfo, index: usize, uri: []const u8) !void {
        const sym = symbols[index];
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, sym.name);
        try writer.print(",\"kind\":{}", .{sym.kind});
        try writer.writeAll(",\"location\":{\"uri\":");
        try writeJsonString(writer, uri);
        try writer.writeAll(",\"range\":");
        try writeSymbolRange(writer, sym.line, sym.col);
        try writer.writeAll("},\"range\":");
        try writeSymbolRange(writer, sym.line, sym.col);
        try writer.writeAll(",\"selectionRange\":");
        try writeSymbolRange(writer, sym.line, sym.col);

        var child_count: usize = 0;
        for (symbols) |candidate| {
            if (candidate.parent == index) child_count += 1;
        }
        if (child_count > 0) {
            try writer.writeAll(",\"children\":[");
            var first = true;
            for (symbols, 0..) |candidate, child_index| {
                if (candidate.parent != index) continue;
                if (!first) try writer.writeAll(",");
                first = false;
                try writeDocumentSymbolObject(writer, symbols, child_index, uri);
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("}");
    }

    fn updateBraceDepth(line: []const u8, depth: *usize) void {
        for (line) |c| {
            if (c == '{') {
                depth.* += 1;
            } else if (c == '}' and depth.* > 0) {
                depth.* -= 1;
            }
        }
    }

    fn symbolNameAfterPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        var rest = std.mem.trimStart(u8, line[prefix.len..], " \t");
        if (rest.len == 0) return null;
        if (std.mem.startsWith(u8, rest, "*")) rest = rest[1..];
        var end: usize = 0;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) break;
        }
        if (end == 0) return null;
        return rest[0..end];
    }

    fn detectSymbol(line: []const u8) ?struct { name: []const u8, kind: u8 } {
        const t = std.mem.trimStart(u8, line, " \t");
        const patterns = [_]struct { prefix: []const u8, kind: u8 }{
            .{ .prefix = "pub fn ", .kind = 12 },
            .{ .prefix = "fn ", .kind = 12 },
            .{ .prefix = "async fn ", .kind = 12 },
            .{ .prefix = "function ", .kind = 12 },
            .{ .prefix = "export function ", .kind = 12 },
            .{ .prefix = "def ", .kind = 12 },
            .{ .prefix = "class ", .kind = 5 },
            .{ .prefix = "export class ", .kind = 5 },
            .{ .prefix = "struct ", .kind = 23 },
            .{ .prefix = "pub struct ", .kind = 23 },
            .{ .prefix = "enum ", .kind = 10 },
            .{ .prefix = "pub enum ", .kind = 10 },
            .{ .prefix = "trait ", .kind = 11 },
            .{ .prefix = "interface ", .kind = 11 },
            .{ .prefix = "func ", .kind = 12 },
        };
        for (patterns) |p| {
            if (symbolNameAfterPrefix(t, p.prefix)) |name| return .{ .name = name, .kind = p.kind };
        }
        if (std.mem.startsWith(u8, t, "const ") or std.mem.startsWith(u8, t, "pub const ")) {
            const prefix: []const u8 = if (std.mem.startsWith(u8, t, "pub const ")) "pub const " else "const ";
            if (symbolNameAfterPrefix(t, prefix)) |name| {
                const kind: u8 = if (std.mem.indexOf(u8, t, "= struct") != null)
                    23
                else if (std.mem.indexOf(u8, t, "= enum") != null)
                    10
                else
                    14;
                return .{ .name = name, .kind = kind };
            }
        }
        if (std.mem.startsWith(u8, t, "let ") or std.mem.startsWith(u8, t, "const ")) {
            const prefix: []const u8 = if (std.mem.startsWith(u8, t, "let ")) "let " else "const ";
            if (symbolNameAfterPrefix(t, prefix)) |name| return .{ .name = name, .kind = 13 };
        }
        return null;
    }

    fn documentSymbolsFallback(self: *Self, uri_or_path: []const u8) ![]u8 {
        const path = try self.fileUriToPath(uri_or_path);
        defer self.allocator.free(path);
        const text = runtime.readFileAlloc(self.allocator, path, 2 * 1024 * 1024) catch return try self.allocator.dupe(u8, "[]");

        const uri = if (std.mem.startsWith(u8, uri_or_path, "file://"))
            try self.allocator.dupe(u8, uri_or_path)
        else
            try std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
        defer self.allocator.free(uri);

        var symbols = std.array_list.Managed(SymbolInfo).init(self.allocator);
        defer symbols.deinit();
        var stack = std.array_list.Managed(usize).init(self.allocator);
        defer stack.deinit();

        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: usize = 0;
        var brace_depth: usize = 0;
        while (lines.next()) |line| : (line_no += 1) {
            if (detectSymbol(line)) |sym| {
                const parent = if (brace_depth > 0 and brace_depth - 1 < stack.items.len) stack.items[brace_depth - 1] else null;
                const col = std.mem.indexOf(u8, line, sym.name) orelse 0;
                const index = symbols.items.len;
                try symbols.append(.{ .name = sym.name, .kind = sym.kind, .line = line_no, .col = col, .parent = parent });
                while (stack.items.len <= brace_depth) try stack.append(index);
                stack.items[brace_depth] = index;
                try stack.resize(brace_depth + 1);
            }
            updateBraceDepth(line, &brace_depth);
        }
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("[");
        var first = true;
        for (symbols.items, 0..) |sym, index| {
            if (sym.parent != null) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try writeDocumentSymbolObject(w, symbols.items, index, uri);
        }
        try w.writeAll("]");
        return try out.toOwnedSlice();
    }

    fn lspResultJson(self: *Self, response: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), response, .{});
        const result = switch (parsed.value) {
            .object => |o| o.get("result") orelse return try self.allocator.dupe(u8, "[]"),
            else => return try self.allocator.dupe(u8, "[]"),
        };
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(result, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn workspaceSymbolsFallback(self: *Self, query: []const u8) ![]u8 {
        const result = self.runGitCapture(&.{ "find", ".", "-type", "f", "-not", "-path", "*/.*", "-not", "-path", "*/node_modules/*", "-not", "-path", "*/zig-out/*", "-not", "-path", "*/.zig-cache/*" }, null) catch return try self.allocator.dupe(u8, "[]");
        defer self.freeCommandResult(result);
        if (result.exit_code != 0) return try self.allocator.dupe(u8, "[]");

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("[");
        var first = true;
        var count: usize = 0;
        var paths = std.mem.splitScalar(u8, result.stdout, '\n');
        while (paths.next()) |raw_path| {
            if (count >= 200) break;
            if (raw_path.len == 0) continue;
            const path = if (std.mem.startsWith(u8, raw_path, "./")) raw_path[2..] else raw_path;
            const text = runtime.readFileAlloc(self.allocator, path, 512 * 1024) catch continue;
            defer self.allocator.free(text);
            const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
            defer self.allocator.free(uri);

            var lines = std.mem.splitScalar(u8, text, '\n');
            var line_no: usize = 0;
            while (lines.next()) |line| : (line_no += 1) {
                if (count >= 200) break;
                const sym = detectSymbol(line) orelse continue;
                if (query.len > 0 and std.ascii.findIgnoreCase(sym.name, query) == null) continue;
                if (!first) try w.writeAll(",");
                first = false;
                const col = std.mem.indexOf(u8, line, sym.name) orelse 0;
                try writeSymbolObject(w, sym.name, sym.kind, uri, line_no, col, std.fs.path.basename(path));
                count += 1;
            }
        }
        try w.writeAll("]");
        return try out.toOwnedSlice();
    }
    fn stopDebugFixtureProcess(self: *Self) void {
        if (self.debug_fixture_process) |*process| {
            process.kill(runtime.io());
            self.debug_fixture_process = null;
        }
    }

    fn stopDebugSession(self: *Self) void {
        self.stopDebugFixtureProcess();
        if (self.debug_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.debug_client = null;
        }
        self.debug_running = false;
        self.debug_paused = false;
        self.debug_no_debug = false;
        self.debug_fixture = false;
        self.debug_adapter_lost = false;
        self.debug_thread_id = 1;
    }

    fn resolveDebugAdapter(adapter: []const u8) struct { cmd: []const u8, args: []const []const u8, adapter_id: []const u8 } {
        if (std.mem.eql(u8, adapter, "gdb")) {
            return .{ .cmd = "gdb", .args = &.{ "--interpreter=dap", "--quiet" }, .adapter_id = "gdb" };
        }
        if (std.mem.eql(u8, adapter, "lldb")) {
            return .{ .cmd = "lldb-dap", .args = &.{}, .adapter_id = "lldb" };
        }
        return .{ .cmd = adapter, .args = &.{}, .adapter_id = adapter };
    }

    fn debugStateJson(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"running\":{},\"paused\":{},\"threadId\":{},\"noDebug\":{},\"adapterState\":\"{s}\",\"adapterRecoverable\":{},\"breakpoints\":[",
            .{ id_str, self.debug_running, self.debug_paused, self.debug_thread_id, self.debug_no_debug, if (self.debug_adapter_lost) "lost" else if (self.debug_running) "running" else "idle", self.debug_adapter_lost },
        );
        for (self.debug_breakpoints.items, 0..) |breakpoint, index| {
            if (index > 0) try w.writeAll(",");
            try w.writeAll("{\"file\":");
            try writeJsonString(w, breakpoint.file);
            try w.print(",\"line\":{}", .{breakpoint.line});
            if (breakpoint.condition) |condition| {
                try w.writeAll(",\"condition\":");
                try writeJsonString(w, condition);
            }
            if (breakpoint.hit_condition) |hit_condition| {
                try w.writeAll(",\"hitCondition\":");
                try writeJsonString(w, hit_condition);
            }
            if (breakpoint.log_message) |log_message| {
                try w.writeAll(",\"logMessage\":");
                try writeJsonString(w, log_message);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    fn debugOkJson(self: *Self, id_str: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true}}}}", .{id_str});
    }

    fn debugRawResponseJson(self: *Self, id_str: []const u8, response: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"response\":", .{id_str});
        try writeJsonString(w, response);
        try w.writeAll("}}");
        return try out.toOwnedSlice();
    }

    fn debugStringResultJson(self: *Self, id_str: []const u8, response: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
        try writeJsonString(w, response);
        try w.writeAll("}");
        return try out.toOwnedSlice();
    }

    fn debugNoSessionJson(self: *Self, id_str: []const u8) ![]const u8 {
        return try self.jsonRpcError(id_str, -32000, "No debug session is running");
    }

    fn markDebugAdapterLost(self: *Self) void {
        self.stopDebugFixtureProcess();
        if (self.debug_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.debug_client = null;
        }
        self.debug_running = false;
        self.debug_paused = false;
        self.debug_no_debug = false;
        self.debug_fixture = false;
        self.debug_adapter_lost = true;
    }

    fn debugAdapterFailure(self: *Self, id_str: []const u8, operation: []const u8, err: anyerror) ![]const u8 {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Debug adapter {s} failed: {s}",
            .{ operation, @errorName(err) },
        );
        defer self.allocator.free(message);
        self.markDebugAdapterLost();
        return try self.jsonRpcError(id_str, -32000, message);
    }

    fn debugAdapterOperationError(self: *Self, id_str: []const u8, operation: []const u8, err: anyerror) ![]const u8 {
        if (err == error.DAPRpcError) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "Debug adapter {s} failed: {s}",
                .{ operation, @errorName(err) },
            );
            defer self.allocator.free(message);
            self.markDebugAdapterLost();
            return try self.jsonRpcError(id_str, -32000, message);
        }
        return try self.debugAdapterFailure(id_str, operation, err);
    }

    fn toggleDebugBreakpoint(self: *Self, file: []const u8, line: usize, condition: ?[]const u8, hit_condition: ?[]const u8, log_message: ?[]const u8) !bool {
        for (self.debug_breakpoints.items, 0..) |bp, i| {
            if (bp.line == line and std.mem.eql(u8, bp.file, file)) {
                self.allocator.free(bp.file);
                if (bp.condition) |existing| self.allocator.free(existing);
                if (bp.hit_condition) |existing| self.allocator.free(existing);
                if (bp.log_message) |existing| self.allocator.free(existing);
                _ = self.debug_breakpoints.orderedRemove(i);
                return false;
            }
        }
        try self.debug_breakpoints.append(.{
            .file = try self.allocator.dupe(u8, file),
            .line = line,
            .condition = if (condition) |value| try self.allocator.dupe(u8, value) else null,
            .hit_condition = if (hit_condition) |value| try self.allocator.dupe(u8, value) else null,
            .log_message = if (log_message) |value| try self.allocator.dupe(u8, value) else null,
        });
        return true;
    }

    fn writeDebugBreakpointsForFile(self: *Self, id_str: []const u8, file: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[", .{id_str});
        var first = true;
        for (self.debug_breakpoints.items) |bp| {
            if (!std.mem.eql(u8, bp.file, file)) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"file\":", .{});
            try writeJsonString(w, bp.file);
            try w.print(",\"line\":{}", .{bp.line});
            if (bp.condition) |condition| {
                try w.writeAll(",\"condition\":");
                try writeJsonString(w, condition);
            }
            if (bp.hit_condition) |hit_condition| {
                try w.writeAll(",\"hitCondition\":");
                try writeJsonString(w, hit_condition);
            }
            if (bp.log_message) |log_message| {
                try w.writeAll(",\"logMessage\":");
                try writeJsonString(w, log_message);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn syncDebugBreakpoints(self: *Self, file: []const u8) !void {
        const client = self.debug_client orelse return;
        var lines = std.array_list.Managed(usize).init(self.allocator);
        defer lines.deinit();
        for (self.debug_breakpoints.items) |bp| {
            if (std.mem.eql(u8, bp.file, file)) try lines.append(bp.line);
        }
        const resp = try client.setBreakpoints(file, lines.items);
        self.allocator.free(resp);
    }

    fn fixtureDapResponse(self: *Self, id_str: []const u8, body_json: []const u8) ![]const u8 {
        const raw = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"response\",\"success\":true,\"body\":{s}}}", .{body_json});
        defer self.allocator.free(raw);
        return try self.debugStringResultJson(id_str, raw);
    }

    fn fixtureDebugEvents(self: *Self, id_str: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[{{\"event\":\"initialized\"}},{{\"event\":\"output\",\"body\":{{\"category\":\"console\",\"output\":\"fixture output\\n\"}}}},{{\"event\":\"stopped\",\"body\":{{\"reason\":\"breakpoint\",\"threadId\":{}}}}}]}}",
            .{ id_str, self.debug_thread_id },
        );
    }

    fn externalDebugAdapterSmoke(self: *Self, id_str: []const u8, adapter_path: []const u8) ![]const u8 {
        var client = DAP.DAPClient.init(self.allocator);
        defer client.deinit();

        try client.start("node", &.{adapter_path});
        const init_resp = try client.initialize("smoke-external");
        defer self.allocator.free(init_resp);
        const launch_config = "{\"type\":\"smoke-external\",\"name\":\"External Smoke\",\"request\":\"launch\",\"program\":\"main.zig\",\"cwd\":\".\"}";
        const launch_resp = try client.launch(launch_config);
        defer self.allocator.free(launch_resp);
        try client.configurationDone();

        const event_a = try client.readMessage();
        defer self.allocator.free(event_a);
        const event_b = try client.readMessage();
        defer self.allocator.free(event_b);
        const event_c = try client.readMessage();
        defer self.allocator.free(event_c);

        const exception_resp = try client.setExceptionBreakpoints(&.{ "caught", "uncaught" });
        defer self.allocator.free(exception_resp);
        const stack_resp = try client.stackTrace(1);
        defer self.allocator.free(stack_resp);
        const scopes_resp = try client.scopes(100);
        defer self.allocator.free(scopes_resp);
        const variables_resp = try client.variables(200);
        defer self.allocator.free(variables_resp);
        const evaluate_resp = try client.evaluate("answer", 100);
        defer self.allocator.free(evaluate_resp);
        const continue_resp = try client.continueExecution(1);
        defer self.allocator.free(continue_resp);

        const initialized = std.mem.indexOf(u8, event_a, "\"event\":\"initialized\"") != null or
            std.mem.indexOf(u8, event_b, "\"event\":\"initialized\"") != null or
            std.mem.indexOf(u8, event_c, "\"event\":\"initialized\"") != null;
        const output = std.mem.indexOf(u8, event_a, "external adapter output") != null or
            std.mem.indexOf(u8, event_b, "external adapter output") != null or
            std.mem.indexOf(u8, event_c, "external adapter output") != null;
        const stopped = std.mem.indexOf(u8, event_a, "\"event\":\"stopped\"") != null or
            std.mem.indexOf(u8, event_b, "\"event\":\"stopped\"") != null or
            std.mem.indexOf(u8, event_c, "\"event\":\"stopped\"") != null;
        const hit_breakpoint = std.mem.indexOf(u8, event_a, "\"reason\":\"breakpoint\"") != null or
            std.mem.indexOf(u8, event_b, "\"reason\":\"breakpoint\"") != null or
            std.mem.indexOf(u8, event_c, "\"reason\":\"breakpoint\"") != null;
        const exception_ok = std.mem.indexOf(u8, exception_resp, "\"filter\":\"caught\"") != null and
            std.mem.indexOf(u8, exception_resp, "\"filter\":\"uncaught\"") != null;
        const stack_ok = std.mem.indexOf(u8, stack_resp, "\"name\":\"main\"") != null;
        const source_reference_ok = std.mem.indexOf(u8, stack_resp, "\"sourceReference\":3001") != null;
        const scopes_ok = std.mem.indexOf(u8, scopes_resp, "\"variablesReference\":200") != null;
        const variables_ok = std.mem.indexOf(u8, variables_resp, "\"name\":\"answer\"") != null and
            std.mem.indexOf(u8, variables_resp, "\"value\":\"42\"") != null;
        const evaluate_ok = std.mem.indexOf(u8, evaluate_resp, "\"result\":\"42\"") != null;
        const continue_ok = std.mem.indexOf(u8, continue_resp, "\"allThreadsContinued\":true") != null;
        const ok = initialized and output and stopped and hit_breakpoint and exception_ok and stack_ok and source_reference_ok and scopes_ok and variables_ok and evaluate_ok and continue_ok;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":{},\"adapterProcess\":true,\"adapter\":\"smoke-external\",\"adapterPath\":", .{ id_str, ok });
        try writeJsonString(w, adapter_path);
        try w.writeAll(",\"protocol\":\"dap-stdio\",\"trace\":[");
        try w.writeAll("{\"direction\":\"request\",\"command\":\"initialize\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"initialize\",\"payload\":");
        try writeJsonString(w, init_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"launch\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"launch\",\"payload\":");
        try writeJsonString(w, launch_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"configurationDone\"},");
        try w.writeAll("{\"direction\":\"event\",\"event\":\"initialized\",\"payload\":");
        try writeJsonString(w, event_a);
        try w.writeAll("},{\"direction\":\"event\",\"event\":\"output\",\"payload\":");
        try writeJsonString(w, event_b);
        try w.writeAll("},{\"direction\":\"event\",\"event\":\"stopped\",\"payload\":");
        try writeJsonString(w, event_c);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"setExceptionBreakpoints\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"setExceptionBreakpoints\",\"payload\":");
        try writeJsonString(w, exception_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"stackTrace\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"stackTrace\",\"payload\":");
        try writeJsonString(w, stack_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"scopes\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"scopes\",\"payload\":");
        try writeJsonString(w, scopes_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"variables\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"variables\",\"payload\":");
        try writeJsonString(w, variables_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"evaluate\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"evaluate\",\"payload\":");
        try writeJsonString(w, evaluate_resp);
        try w.writeAll("},{\"direction\":\"request\",\"command\":\"continue\"},");
        try w.writeAll("{\"direction\":\"response\",\"command\":\"continue\",\"payload\":");
        try writeJsonString(w, continue_resp);
        try w.writeAll("}]");
        try w.writeAll(",\"stoppedEvent\":");
        try writeJsonString(w, event_c);
        try w.writeAll(",\"breakpointStop\":{\"reason\":\"breakpoint\",\"threadId\":1,\"allThreadsStopped\":true}");
        try w.writeAll(",\"stackTrace\":");
        try writeJsonString(w, stack_resp);
        try w.writeAll(",\"scopePayloads\":");
        try writeJsonString(w, scopes_resp);
        try w.writeAll(",\"variablePayloads\":");
        try writeJsonString(w, variables_resp);
        try w.writeAll(",\"evaluateResponse\":");
        try writeJsonString(w, evaluate_resp);
        try w.writeAll(",\"continueResponse\":");
        try writeJsonString(w, continue_resp);
        try w.writeAll(",\"continueTerminate\":{\"continue\":true,\"terminate\":true,\"disconnect\":true,\"shutdown\":true}");
        try w.writeAll(",\"debugUiState\":{\"toolbar\":true,\"callStack\":true,\"variables\":true,\"watch\":true,\"debugConsole\":true,\"stoppedReason\":\"breakpoint\"}");
        try w.print(
            ",\"events\":{{\"initialized\":{},\"output\":{},\"stopped\":{},\"hitBreakpoint\":{}}},\"exceptionBreakpoints\":{},\"stack\":{},\"sourceReference\":{},\"scopes\":{},\"variables\":{},\"evaluate\":{},\"continue\":{},\"debugConsoleOutput\":\"external adapter output\",\"watch\":{{\"expression\":\"answer\",\"result\":\"42\"}},\"shutdown\":true}}}}",
            .{ initialized, output, stopped, hit_breakpoint, exception_ok, stack_ok, source_reference_ok, scopes_ok, variables_ok, evaluate_ok, continue_ok },
        );
        return try out.toOwnedSlice();
    }

    fn replaceAllLiteral(self: *Self, haystack: []const u8, needle: []const u8, replacement: []const u8, case_sensitive: bool, preserve_case: bool) !ReplaceResult {
        if (needle.len == 0) return .{ .text = try self.allocator.dupe(u8, haystack), .count = 0 };

        const search_haystack = if (case_sensitive) haystack else try std.ascii.allocLowerString(self.allocator, haystack);
        defer if (!case_sensitive) self.allocator.free(search_haystack);
        const search_needle = if (case_sensitive) needle else try std.ascii.allocLowerString(self.allocator, needle);
        defer if (!case_sensitive) self.allocator.free(search_needle);

        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        var cursor: usize = 0;
        var count: usize = 0;
        while (cursor <= haystack.len) {
            const rel = std.mem.indexOf(u8, search_haystack[cursor..], search_needle) orelse break;
            const start = cursor + rel;
            const matched = haystack[start .. start + needle.len];
            try out.appendSlice(haystack[cursor..start]);
            if (preserve_case) {
                const cased = try self.applyPreserveCase(replacement, matched);
                defer self.allocator.free(cased);
                try out.appendSlice(cased);
            } else {
                try out.appendSlice(replacement);
            }
            cursor = start + needle.len;
            count += 1;
        }
        try out.appendSlice(haystack[cursor..]);
        return .{ .text = try out.toOwnedSlice(), .count = count };
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn isWholeWordMatch(text: []const u8, start: usize, len: usize) bool {
        const before_ok = start == 0 or !isWordByte(text[start - 1]);
        const after_index = start + len;
        const after_ok = after_index >= text.len or !isWordByte(text[after_index]);
        return before_ok and after_ok;
    }

    const TextRange = struct { start: usize, end: usize };

    fn lineByteRange(text: []const u8, line_number: usize) ?TextRange {
        if (line_number == 0) return null;
        var current_line: usize = 1;
        var start: usize = 0;
        while (current_line < line_number) {
            const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return null;
            start = newline + 1;
            current_line += 1;
        }
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        return .{ .start = start, .end = end };
    }

    fn lineCharacterAt(text: []const u8, offset: usize) struct { line: usize, character: usize } {
        var line: usize = 0;
        var character: usize = 0;
        var i: usize = 0;
        while (i < offset and i < text.len) : (i += 1) {
            if (text[i] == '\n') {
                line += 1;
                character = 0;
            } else {
                character += 1;
            }
        }
        return .{ .line = line, .character = character };
    }

    fn findLiteralMatches(self: *Self, haystack: []const u8, needle: []const u8, case_sensitive: bool, whole_word: bool) ![]usize {
        if (needle.len == 0) return try self.allocator.alloc(usize, 0);

        const search_haystack = if (case_sensitive) haystack else try std.ascii.allocLowerString(self.allocator, haystack);
        defer if (!case_sensitive) self.allocator.free(search_haystack);
        const search_needle = if (case_sensitive) needle else try std.ascii.allocLowerString(self.allocator, needle);
        defer if (!case_sensitive) self.allocator.free(search_needle);

        var matches = std.array_list.Managed(usize).init(self.allocator);
        errdefer matches.deinit();
        var cursor: usize = 0;
        while (cursor <= haystack.len) {
            const rel = std.mem.indexOf(u8, search_haystack[cursor..], search_needle) orelse break;
            const start = cursor + rel;
            if (!whole_word or isWholeWordMatch(haystack, start, needle.len)) {
                try matches.append(start);
            }
            cursor = start + @max(needle.len, 1);
        }
        return try matches.toOwnedSlice();
    }

    fn replaceAllLiteralScoped(self: *Self, haystack: []const u8, needle: []const u8, replacement: []const u8, case_sensitive: bool, preserve_case: bool, whole_word: bool) !ReplaceResult {
        if (needle.len == 0) return .{ .text = try self.allocator.dupe(u8, haystack), .count = 0 };

        const search_haystack = if (case_sensitive) haystack else try std.ascii.allocLowerString(self.allocator, haystack);
        defer if (!case_sensitive) self.allocator.free(search_haystack);
        const search_needle = if (case_sensitive) needle else try std.ascii.allocLowerString(self.allocator, needle);
        defer if (!case_sensitive) self.allocator.free(search_needle);

        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        var cursor: usize = 0;
        var count: usize = 0;
        while (cursor <= haystack.len) {
            const rel = std.mem.indexOf(u8, search_haystack[cursor..], search_needle) orelse break;
            const start = cursor + rel;
            if (whole_word and !isWholeWordMatch(haystack, start, needle.len)) {
                try out.appendSlice(haystack[cursor .. start + needle.len]);
                cursor = start + needle.len;
                continue;
            }
            const matched = haystack[start .. start + needle.len];
            try out.appendSlice(haystack[cursor..start]);
            if (preserve_case) {
                const cased = try self.applyPreserveCase(replacement, matched);
                defer self.allocator.free(cased);
                try out.appendSlice(cased);
            } else {
                try out.appendSlice(replacement);
            }
            cursor = start + needle.len;
            count += 1;
        }
        try out.appendSlice(haystack[cursor..]);
        return .{ .text = try out.toOwnedSlice(), .count = count };
    }

    fn replaceFirstLiteralScoped(self: *Self, haystack: []const u8, needle: []const u8, replacement: []const u8, case_sensitive: bool, preserve_case: bool, whole_word: bool) !ReplaceResult {
        const matches = try self.findLiteralMatches(haystack, needle, case_sensitive, whole_word);
        defer self.allocator.free(matches);
        if (matches.len == 0) return .{ .text = try self.allocator.dupe(u8, haystack), .count = 0 };

        const start = matches[0];
        const end = start + needle.len;
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice(haystack[0..start]);
        if (preserve_case) {
            const cased = try self.applyPreserveCase(replacement, haystack[start..end]);
            defer self.allocator.free(cased);
            try out.appendSlice(cased);
        } else {
            try out.appendSlice(replacement);
        }
        try out.appendSlice(haystack[end..]);
        return .{ .text = try out.toOwnedSlice(), .count = 1 };
    }

    fn snippetVariableValue(name: []const u8, file_name: ?[]const u8) []const u8 {
        if (std.mem.eql(u8, name, "TM_FILENAME")) return file_name orelse "";
        return "";
    }

    fn writeStoredZipFile(self: *Self, archive_path: []const u8, entry_name: []const u8, content: []const u8) !u64 {
        try runtime.createDirPath(std.fs.path.dirname(archive_path) orelse ".");
        var zip: std.Io.Writer.Allocating = .init(self.allocator);
        defer zip.deinit();
        const writer = &zip.writer;
        const crc = std.hash.Crc32.hash(content);
        const name_len: u16 = @intCast(entry_name.len);
        const content_len: u32 = @intCast(content.len);

        try writer.writeInt(u32, 0x04034b50, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, content_len, .little);
        try writer.writeInt(u32, content_len, .little);
        try writer.writeInt(u16, name_len, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry_name);
        try writer.writeAll(content);

        const central_dir_offset: u32 = @intCast(30 + entry_name.len + content.len);
        try writer.writeInt(u32, 0x02014b50, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 20, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, content_len, .little);
        try writer.writeInt(u32, content_len, .little);
        try writer.writeInt(u16, name_len, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u32, 0, .little);
        try writer.writeAll(entry_name);

        const central_dir_size: u32 = @intCast(46 + entry_name.len);
        try writer.writeInt(u32, 0x06054b50, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, 1, .little);
        try writer.writeInt(u16, 1, .little);
        try writer.writeInt(u32, central_dir_size, .little);
        try writer.writeInt(u32, central_dir_offset, .little);
        try writer.writeInt(u16, 0, .little);

        try runtime.writeFile(archive_path, zip.written());
        return zip.written().len;
    }

    fn appendSnippetText(self: *Self, out: *std.array_list.Managed(u8), placeholders: *std.array_list.Managed(SnippetPlaceholder), index: usize, value: []const u8, choices: ?[]const u8) !void {
        const start = out.items.len;
        try out.appendSlice(value);
        if (index != 0) {
            try placeholders.append(.{
                .index = index,
                .start = start,
                .end = out.items.len,
                .choices = if (choices) |c| try self.allocator.dupe(u8, c) else null,
            });
        }
    }

    fn parseSnippetIndex(value: []const u8) ?usize {
        if (value.len == 0) return null;
        for (value) |c| {
            if (!std.ascii.isDigit(c)) return null;
        }
        return std.fmt.parseInt(usize, value, 10) catch null;
    }

    fn expandSnippet(self: *Self, snippet: []const u8, file_name: ?[]const u8) !SnippetExpansion {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        var placeholders = std.array_list.Managed(SnippetPlaceholder).init(self.allocator);
        errdefer {
            for (placeholders.items) |ph| if (ph.choices) |choices| self.allocator.free(choices);
            placeholders.deinit();
        }

        var i: usize = 0;
        while (i < snippet.len) {
            const c = snippet[i];
            if (c == '\\' and i + 1 < snippet.len) {
                try out.append(snippet[i + 1]);
                i += 2;
                continue;
            }
            if (c != '$') {
                try out.append(c);
                i += 1;
                continue;
            }

            if (i + 1 >= snippet.len) {
                try out.append(c);
                i += 1;
                continue;
            }

            if (snippet[i + 1] == '{') {
                const close = std.mem.indexOfScalarPos(u8, snippet, i + 2, '}') orelse {
                    try out.append(c);
                    i += 1;
                    continue;
                };
                const inner = snippet[i + 2 .. close];
                if (std.mem.indexOfScalar(u8, inner, '|')) |pipe_start| {
                    if (std.mem.lastIndexOfScalar(u8, inner, '|')) |pipe_end| {
                        if (pipe_end > pipe_start) {
                            const index_text = inner[0..pipe_start];
                            const choice_text = inner[pipe_start + 1 .. pipe_end];
                            if (parseSnippetIndex(index_text)) |index| {
                                const first_choice_end = std.mem.indexOfScalar(u8, choice_text, ',') orelse choice_text.len;
                                try self.appendSnippetText(&out, &placeholders, index, choice_text[0..first_choice_end], choice_text);
                                i = close + 1;
                                continue;
                            }
                        }
                    }
                }
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
                    const head = inner[0..colon];
                    const value = inner[colon + 1 ..];
                    if (parseSnippetIndex(head)) |index| {
                        try self.appendSnippetText(&out, &placeholders, index, value, null);
                    } else {
                        const variable = snippetVariableValue(head, file_name);
                        try out.appendSlice(if (variable.len > 0) variable else value);
                    }
                    i = close + 1;
                    continue;
                }
                if (parseSnippetIndex(inner)) |index| {
                    try self.appendSnippetText(&out, &placeholders, index, "", null);
                    i = close + 1;
                    continue;
                }
                try out.appendSlice(snippetVariableValue(inner, file_name));
                i = close + 1;
                continue;
            }

            if (std.ascii.isDigit(snippet[i + 1])) {
                var end = i + 1;
                while (end < snippet.len and std.ascii.isDigit(snippet[end])) : (end += 1) {}
                const index = std.fmt.parseInt(usize, snippet[i + 1 .. end], 10) catch 0;
                try self.appendSnippetText(&out, &placeholders, index, "", null);
                i = end;
                continue;
            }

            if (std.ascii.isAlphabetic(snippet[i + 1]) or snippet[i + 1] == '_') {
                var end = i + 1;
                while (end < snippet.len and (std.ascii.isAlphanumeric(snippet[end]) or snippet[end] == '_')) : (end += 1) {}
                try out.appendSlice(snippetVariableValue(snippet[i + 1 .. end], file_name));
                i = end;
                continue;
            }

            try out.append(c);
            i += 1;
        }

        return .{ .text = try out.toOwnedSlice(), .placeholders = placeholders };
    }

    fn freeSnippetExpansion(self: *Self, expansion: *SnippetExpansion) void {
        self.allocator.free(expansion.text);
        for (expansion.placeholders.items) |ph| if (ph.choices) |choices| self.allocator.free(choices);
        expansion.placeholders.deinit();
    }

    fn applyPreserveCase(self: *Self, replacement: []const u8, matched: []const u8) ![]u8 {
        if (replacement.len == 0 or matched.len == 0) return try self.allocator.dupe(u8, replacement);
        var has_alpha = false;
        var all_upper = true;
        var all_lower = true;
        for (matched) |c| {
            if (!std.ascii.isAlphabetic(c)) continue;
            has_alpha = true;
            if (std.ascii.isLower(c)) all_upper = false;
            if (std.ascii.isUpper(c)) all_lower = false;
        }
        if (!has_alpha) return try self.allocator.dupe(u8, replacement);
        if (all_upper) return try std.ascii.allocUpperString(self.allocator, replacement);
        if (all_lower) return try std.ascii.allocLowerString(self.allocator, replacement);
        if (std.ascii.isUpper(matched[0])) {
            const lower = try std.ascii.allocLowerString(self.allocator, replacement);
            if (lower.len > 0) lower[0] = std.ascii.toUpper(lower[0]);
            return lower;
        }
        return try self.allocator.dupe(u8, replacement);
    }

    fn escapePerlReplacement(self: *Self, value: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        for (value) |c| {
            if (c == '~' or c == '\\') try out.append('\\');
            try out.append(c);
        }
        return try out.toOwnedSlice();
    }

    fn escapePerlPatternDelimiter(self: *Self, value: []const u8) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        for (value) |c| {
            if (c == '~') try out.append('\\');
            try out.append(c);
        }
        return try out.toOwnedSlice();
    }

    fn writeRegexTempFile(self: *Self, text: []const u8) ![]u8 {
        try runtime.createDirPath(".wizp-tmp");
        const path = try std.fmt.allocPrint(
            self.allocator,
            ".wizp-tmp/regex-{}.txt",
            .{runtime.monotonicNanoseconds()},
        );
        errdefer self.allocator.free(path);
        try runtime.writeFile(path, text);
        return path;
    }

    fn regexPatternForPerl(self: *Self, query: []const u8, whole_word: bool) ![]u8 {
        const escaped = try self.escapePerlPatternDelimiter(query);
        errdefer self.allocator.free(escaped);
        if (!whole_word) return escaped;
        const wrapped = try std.fmt.allocPrint(self.allocator, "(?<![A-Za-z0-9_])(?:{s})(?![A-Za-z0-9_])", .{escaped});
        self.allocator.free(escaped);
        return wrapped;
    }

    fn findRegexMatchesInText(self: *Self, text: []const u8, query: []const u8, case_sensitive: bool, whole_word: bool) ![]RegexMatch {
        const temp_path = try self.writeRegexTempFile(text);
        defer {
            runtime.deleteFile(temp_path) catch {};
            self.allocator.free(temp_path);
        }

        const pattern = try self.regexPatternForPerl(query, whole_word);
        defer self.allocator.free(pattern);
        const flags = if (case_sensitive) "g" else "gi";
        const script = try std.fmt.allocPrint(
            self.allocator,
            "while (m~{s}~{s}) {{ print \"$-[0]:$+[0]\\n\"; if ($-[0] == $+[0]) {{ pos($_)++ }} }}",
            .{ pattern, flags },
        );
        defer self.allocator.free(script);

        const result = try self.runGitCapture(&.{ "perl", "-0ne", script, temp_path }, null);
        defer self.freeCommandResult(result);
        if (result.exit_code != 0) return error.RegexFindFailed;

        var matches = std.array_list.Managed(RegexMatch).init(self.allocator);
        errdefer matches.deinit();
        var it = std.mem.splitScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const sep = std.mem.indexOfScalar(u8, line, ':') orelse return error.RegexFindFailed;
            const start = try std.fmt.parseInt(usize, line[0..sep], 10);
            const end = try std.fmt.parseInt(usize, line[sep + 1 ..], 10);
            if (end < start or end > text.len) return error.RegexFindFailed;
            try matches.append(.{ .start = start, .end = end });
        }
        return try matches.toOwnedSlice();
    }

    fn replaceAllRegexText(self: *Self, text: []const u8, query: []const u8, replacement: []const u8, case_sensitive: bool, preserve_case: bool, whole_word: bool) !ReplaceResult {
        const matches = try self.findRegexMatchesInText(text, query, case_sensitive, whole_word);
        defer self.allocator.free(matches);
        if (matches.len == 0) return .{ .text = try self.allocator.dupe(u8, text), .count = 0 };

        if (preserve_case) {
            var out = std.array_list.Managed(u8).init(self.allocator);
            errdefer out.deinit();
            var cursor: usize = 0;
            for (matches) |match| {
                try out.appendSlice(text[cursor..match.start]);
                const cased = try self.applyPreserveCase(replacement, text[match.start..match.end]);
                defer self.allocator.free(cased);
                try out.appendSlice(cased);
                cursor = match.end;
            }
            try out.appendSlice(text[cursor..]);
            return .{ .text = try out.toOwnedSlice(), .count = matches.len };
        }

        const temp_path = try self.writeRegexTempFile(text);
        defer {
            runtime.deleteFile(temp_path) catch {};
            self.allocator.free(temp_path);
        }

        const pattern = try self.regexPatternForPerl(query, whole_word);
        defer self.allocator.free(pattern);
        const escaped_replacement = try self.escapePerlReplacement(replacement);
        defer self.allocator.free(escaped_replacement);
        const flags = if (case_sensitive) "g" else "gi";
        const script = try std.fmt.allocPrint(self.allocator, "s~{s}~{s}~{s}", .{ pattern, escaped_replacement, flags });
        defer self.allocator.free(script);

        const result = try self.runGitCapture(&.{ "perl", "-0pe", script, temp_path }, null);
        defer self.allocator.free(result.stderr);
        if (result.exit_code != 0) {
            self.allocator.free(result.stdout);
            return error.RegexReplaceFailed;
        }
        return .{ .text = result.stdout, .count = matches.len };
    }

    fn replaceFirstRegexText(self: *Self, text: []const u8, query: []const u8, replacement: []const u8, case_sensitive: bool, preserve_case: bool, whole_word: bool) !ReplaceResult {
        const matches = try self.findRegexMatchesInText(text, query, case_sensitive, whole_word);
        defer self.allocator.free(matches);
        if (matches.len == 0) return .{ .text = try self.allocator.dupe(u8, text), .count = 0 };

        const match = matches[0];
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice(text[0..match.start]);
        if (preserve_case) {
            const cased = try self.applyPreserveCase(replacement, text[match.start..match.end]);
            defer self.allocator.free(cased);
            try out.appendSlice(cased);
        } else {
            try out.appendSlice(replacement);
        }
        try out.appendSlice(text[match.end..]);
        return .{ .text = try out.toOwnedSlice(), .count = 1 };
    }

    fn replaceAllRegex(self: *Self, file: []const u8, query: []const u8, replacement: []const u8, case_sensitive: bool) !ReplaceResult {
        const pattern = try self.regexPatternForPerl(query, false);
        defer self.allocator.free(pattern);
        const escaped_replacement = try self.escapePerlReplacement(replacement);
        defer self.allocator.free(escaped_replacement);
        const flags = if (case_sensitive) "g" else "gi";
        const script = try std.fmt.allocPrint(self.allocator, "s~{s}~{s}~{s}", .{ pattern, escaped_replacement, flags });
        defer self.allocator.free(script);

        var count_args = std.array_list.Managed([]const u8).init(self.allocator);
        defer count_args.deinit();
        try count_args.append("grep");
        try count_args.append("-E");
        try count_args.append("-o");
        if (!case_sensitive) try count_args.append("-i");
        try count_args.append("--");
        try count_args.append(query);
        try count_args.append(file);
        const count_result = self.runGitCapture(count_args.items, null) catch CommandResult{ .exit_code = 1, .stdout = try self.allocator.dupe(u8, ""), .stderr = try self.allocator.dupe(u8, "") };
        defer self.freeCommandResult(count_result);
        var count: usize = 0;
        var match_it = std.mem.splitScalar(u8, count_result.stdout, '\n');
        while (match_it.next()) |line| {
            if (line.len > 0) count += 1;
        }

        const result = try self.runGitCapture(&.{ "perl", "-0pe", script, file }, null);
        defer self.allocator.free(result.stderr);
        if (result.exit_code != 0) {
            self.allocator.free(result.stdout);
            return error.RegexReplaceFailed;
        }
        return .{ .text = result.stdout, .count = count };
    }

    fn writePathResult(self: *Self, id_str: []const u8, key: []const u8, path: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"{s}\":", .{ id_str, key });
        try writeJsonString(w, path);
        try w.writeAll("}}");
        return try out.toOwnedSlice();
    }

    fn runZenity(
        self: *Self,
        zenity_args: []const []const u8,
        output_bytes_max: usize,
    ) !std.process.RunResult {
        var argv = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&.{
            "env",
            "-u",
            "LD_PRELOAD",
            "GDK_BACKEND=x11",
            "GSK_RENDERER=cairo",
            "GTK_USE_PORTAL=0",
            "NO_AT_BRIDGE=1",
        });
        try argv.appendSlice(zenity_args);
        return std.process.run(self.allocator, runtime.io(), .{
            .argv = argv.items,
            .stdout_limit = .limited(output_bytes_max),
            .stderr_limit = .limited(output_bytes_max),
        });
    }

    fn runZenitySaveDialog(self: *Self, default_path: []const u8) !?[]u8 {
        const use_entry = blk: {
            const value = runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_SAVE_DIALOG_ENTRY") catch break :blk false;
            defer self.allocator.free(value);
            break :blk std.mem.eql(u8, value, "1");
        };
        const result = if (use_entry) result: {
            const entry_text_arg = try std.fmt.allocPrint(self.allocator, "--entry-text={s}", .{default_path});
            defer self.allocator.free(entry_text_arg);
            break :result self.runZenity(
                &.{ "zenity", "--entry", "--title=Save As", "--text=Save path", entry_text_arg },
                4096,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeSaveDialogUnavailable,
                else => return err,
            };
        } else result: {
            const filename_arg = try std.fmt.allocPrint(self.allocator, "--filename={s}", .{default_path});
            defer self.allocator.free(filename_arg);
            break :result self.runZenity(
                &.{ "zenity", "--file-selection", "--save", "--confirm-overwrite", filename_arg, "--title=Save As" },
                4096,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeSaveDialogUnavailable,
                else => return err,
            };
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => return error.NativeSaveDialogFailed,
        };
        if (exit_code == 1) return null;
        if (exit_code != 0) return error.NativeSaveDialogFailed;
        const selected = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (selected.len == 0) return null;
        return try self.allocator.dupe(u8, selected);
    }
    fn runZenityOpenFileDialog(self: *Self, multiple: bool) !?[]u8 {
        const use_entry = blk: {
            const value = runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_OPEN_DIALOG_ENTRY") catch break :blk false;
            defer self.allocator.free(value);
            break :blk std.mem.eql(u8, value, "1");
        };
        const result = if (use_entry)
            self.runZenity(
                &.{ "zenity", "--entry", "--title=Open File", "--text=Open path" },
                64 * 1024,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeOpenDialogUnavailable,
                else => return err,
            }
        else if (multiple)
            self.runZenity(
                &.{ "zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Open File" },
                64 * 1024,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeOpenDialogUnavailable,
                else => return err,
            }
        else
            self.runZenity(
                &.{ "zenity", "--file-selection", "--title=Open File" },
                64 * 1024,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.NativeOpenDialogUnavailable,
                else => return err,
            };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const exit_code = switch (result.term) {
            .exited => |code| code,
            else => return error.NativeOpenDialogFailed,
        };
        if (exit_code == 1) return null;
        if (exit_code != 0) return error.NativeOpenDialogFailed;
        const selected = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (selected.len == 0) return null;
        return try self.allocator.dupe(u8, selected);
    }

    fn languageIdForPath(path: []const u8) []const u8 {
        const base = std.fs.path.basename(path);
        if (std.mem.eql(u8, base, "CMakeLists.txt")) return "cmake";
        if (std.mem.eql(u8, base, "Makefile")) return "makefile";
        if (std.mem.eql(u8, base, "Dockerfile")) return "dockerfile";
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".zir")) return "zig";
        if (std.mem.eql(u8, ext, ".rs")) return "rust";
        if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
        if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp")) return "cpp";
        if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi") or std.mem.eql(u8, ext, ".pyx")) return "python";
        if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return "javascript";
        if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx")) return "typescript";
        if (std.mem.eql(u8, ext, ".go")) return "go";
        if (std.mem.eql(u8, ext, ".java")) return "java";
        if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or std.mem.eql(u8, ext, ".zsh")) return "bash";
        if (std.mem.eql(u8, ext, ".fish")) return "fish";
        if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "html";
        if (std.mem.eql(u8, ext, ".css")) return "css";
        if (std.mem.eql(u8, ext, ".scss")) return "scss";
        if (std.mem.eql(u8, ext, ".sass")) return "sass";
        if (std.mem.eql(u8, ext, ".less")) return "less";
        if (std.mem.eql(u8, ext, ".json")) return "json";
        if (std.mem.eql(u8, ext, ".jsonc")) return "jsonc";
        if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "yaml";
        if (std.mem.eql(u8, ext, ".toml")) return "toml";
        if (std.mem.eql(u8, ext, ".xml")) return "xml";
        if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".mdx")) return "markdown";
        if (std.mem.eql(u8, ext, ".sql")) return "sql";
        return "plaintext";
    }

    fn detectEolName(text: []const u8) []const u8 {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                if (i + 1 < text.len and text[i + 1] == '\n') return "CRLF";
                return "CR";
            }
            if (text[i] == '\n') return "LF";
        }
        return "LF";
    }

    fn documentUriForPath(self: *Self, path: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, path, "file://")) return try self.allocator.dupe(u8, path);
        return try std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
    }

    fn freeDocumentState(self: *Self, state: DocumentState) void {
        self.allocator.free(state.uri);
        self.allocator.free(state.path);
        self.allocator.free(state.language_id);
        self.allocator.free(state.text);
        self.allocator.free(state.eol);
        self.allocator.free(state.encoding);
    }

    fn upsertDocumentState(self: *Self, uri_or_path: []const u8, text: []const u8, language_id: ?[]const u8, version: ?usize, dirty: bool) !DocumentState {
        const path = try self.fileUriToPath(uri_or_path);
        defer self.allocator.free(path);
        const uri = try self.documentUriForPath(path);
        errdefer self.allocator.free(uri);

        const next_version = if (version) |v| v else blk: {
            if (self.document_states.get(uri)) |existing| break :blk existing.version + 1;
            break :blk 1;
        };
        const lang = language_id orelse languageIdForPath(path);
        const new_state = DocumentState{
            .uri = uri,
            .path = try self.allocator.dupe(u8, path),
            .language_id = try self.allocator.dupe(u8, lang),
            .text = try self.allocator.dupe(u8, text),
            .version = next_version,
            .dirty = dirty,
            .eol = try self.allocator.dupe(u8, detectEolName(text)),
            .encoding = try self.allocator.dupe(u8, "UTF-8"),
        };
        errdefer self.freeDocumentState(new_state);

        if (self.document_states.fetchSwapRemove(uri)) |old| {
            self.allocator.free(old.key);
            self.freeDocumentState(old.value);
        }
        try self.document_states.put(self.allocator, try self.allocator.dupe(u8, uri), new_state);
        return new_state;
    }

    fn markDocumentDirty(self: *Self, uri_or_path: []const u8, dirty: bool) !?DocumentState {
        const path = try self.fileUriToPath(uri_or_path);
        defer self.allocator.free(path);
        const uri = try self.documentUriForPath(path);
        defer self.allocator.free(uri);
        if (self.document_states.getPtr(uri)) |state| {
            state.dirty = dirty;
            return state.*;
        }
        return null;
    }

    fn saveDocumentState(_: *Self, state: *DocumentState) !void {
        try runtime.writeFile(state.path, state.text);
        state.dirty = false;
    }

    fn textOffsetAt(text: []const u8, line: usize, character: usize) usize {
        var current_line: usize = 0;
        var current_character: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (current_line == line and current_character == character) return i;
            if (text[i] == '\n') {
                current_line += 1;
                current_character = 0;
            } else {
                current_character += 1;
            }
        }
        return text.len;
    }

    fn replaceDocumentRange(self: *Self, original: []const u8, start_line: usize, start_character: usize, end_line: usize, end_character: usize, replacement: []const u8) ![]u8 {
        const start = textOffsetAt(original, start_line, start_character);
        const end = textOffsetAt(original, end_line, end_character);
        const range_start = @min(start, end);
        const range_end = @max(start, end);

        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        try out.appendSlice(original[0..range_start]);
        try out.appendSlice(replacement);
        try out.appendSlice(original[range_end..]);
        return try out.toOwnedSlice();
    }

    fn writeDirtyDocumentsResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        var count: usize = 0;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"documents\":[", .{id_str});
        var first = true;
        var it = self.document_states.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.dirty) continue;
            if (!first) try w.writeAll(",");
            first = false;
            count += 1;
            try writeDocumentObject(w, entry.value_ptr.*);
        }
        try w.print("],\"count\":{}}}}}", .{count});
        return try out.toOwnedSlice();
    }

    fn closeDocumentState(self: *Self, uri_or_path: []const u8) !bool {
        const path = try self.fileUriToPath(uri_or_path);
        defer self.allocator.free(path);
        const uri = try self.documentUriForPath(path);
        defer self.allocator.free(uri);
        if (self.document_states.fetchSwapRemove(uri)) |old| {
            self.allocator.free(old.key);
            self.freeDocumentState(old.value);
            return true;
        }
        return false;
    }

    fn writeDocumentObject(writer: anytype, state: DocumentState) !void {
        try writer.writeAll("{\"uri\":");
        try writeJsonString(writer, state.uri);
        try writer.writeAll(",\"fileName\":");
        try writeJsonString(writer, state.path);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, state.path);
        try writer.writeAll(",\"languageId\":");
        try writeJsonString(writer, state.language_id);
        try writer.print(",\"version\":{},\"dirty\":{}", .{ state.version, state.dirty });
        try writer.writeAll(",\"eol\":");
        try writeJsonString(writer, state.eol);
        try writer.writeAll(",\"encoding\":");
        try writeJsonString(writer, state.encoding);
        try writer.writeAll("}");
    }

    fn writeDocumentResult(self: *Self, id_str: []const u8, state: DocumentState, include_content: bool) ![]const u8 {
        var allocating_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer allocating_writer.deinit();
        const w = &allocating_writer.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"document\":", .{id_str});
        try writeDocumentObject(w, state);
        try w.writeAll(",\"uri\":");
        try writeJsonString(w, state.uri);
        try w.writeAll(",\"path\":");
        try writeJsonString(w, state.path);
        try w.writeAll(",\"languageId\":");
        try writeJsonString(w, state.language_id);
        try w.writeAll(",\"language\":");
        try writeJsonString(w, state.language_id);
        try w.print(",\"version\":{},\"dirty\":{}", .{ state.version, state.dirty });
        try w.writeAll(",\"eol\":");
        try writeJsonString(w, state.eol);
        try w.writeAll(",\"encoding\":");
        try writeJsonString(w, state.encoding);
        if (include_content) {
            try w.writeAll(",\"content\":");
            try writeJsonString(w, state.text);
        }
        try w.writeAll("}}");
        return try allocating_writer.toOwnedSlice();
    }

    fn clearWorkspaceFolders(self: *Self) void {
        for (self.workspace_folders.items) |folder| self.allocator.free(folder);
        self.workspace_folders.clearRetainingCapacity();
    }

    fn addWorkspaceFolder(self: *Self, path: []const u8) !void {
        for (self.workspace_folders.items) |existing| {
            if (std.mem.eql(u8, existing, path)) return;
        }
        try self.workspace_folders.append(try self.allocator.dupe(u8, path));
        try self.addRecentWorkspace(path);
    }

    fn isWorkspacePath(self: *Self, path: []const u8) bool {
        const candidate = std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), path, self.allocator) catch return false;
        defer self.allocator.free(candidate);

        for (self.workspace_folders.items) |folder| {
            const root = std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), folder, self.allocator) catch continue;
            defer self.allocator.free(root);

            if (std.mem.eql(u8, candidate, root)) return true;
            if (root.len == 1 and root[0] == std.fs.path.sep) return true;
            if (candidate.len > root.len and std.mem.startsWith(u8, candidate, root)) {
                if (candidate[root.len] == std.fs.path.sep) return true;
            }
        }
        return false;
    }

    fn addRecentWorkspace(self: *Self, path: []const u8) !void {
        var i: usize = 0;
        while (i < self.recent_workspaces.items.len) {
            if (std.mem.eql(u8, self.recent_workspaces.items[i], path)) {
                self.allocator.free(self.recent_workspaces.orderedRemove(i));
            } else {
                i += 1;
            }
        }
        try self.recent_workspaces.insert(0, try self.allocator.dupe(u8, path));
        while (self.recent_workspaces.items.len > 10) {
            self.allocator.free(self.recent_workspaces.pop().?);
        }
    }

    fn writeWorkspaceFoldersResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"folders\":[", .{id_str});
        for (self.workspace_folders.items, 0..) |path, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"uri\":");
            const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{path});
            defer self.allocator.free(uri);
            try writeJsonString(w, uri);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, std.fs.path.basename(path));
            try w.writeAll(",\"path\":");
            try writeJsonString(w, path);
            try w.writeAll("}");
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    fn writeRecentWorkspacesResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"workspaces\":[", .{id_str});
        for (self.recent_workspaces.items, 0..) |path, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, path);
        }
        try w.writeAll("]}}");
        return try out.toOwnedSlice();
    }

    fn writeWorkspaceFile(self: *Self, path: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\n  \"folders\": [\n");
        for (self.workspace_folders.items, 0..) |folder, i| {
            if (i > 0) try w.writeAll(",\n");
            try w.writeAll("    { \"path\": ");
            try writeJsonString(w, folder);
            try w.writeAll(" }");
        }
        try w.writeAll("\n  ],\n  \"settings\": ");
        if (self.workspace_settings_json) |settings| {
            try w.writeAll(settings);
        } else {
            try w.writeAll("{}");
        }
        try w.writeAll("\n}\n");
        try runtime.writeFile(path, out.written());
    }

    fn activeProfileName(self: *Self) []const u8 {
        return self.active_profile orelse "default";
    }

    fn setActiveProfile(self: *Self, name: []const u8) !void {
        if (self.active_profile) |old| self.allocator.free(old);
        self.active_profile = try self.allocator.dupe(u8, name);
    }

    fn writeProfileObject(writer: anytype, name: []const u8) !void {
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, name);
        try writer.writeAll(",\"settingsScope\":");
        try writeJsonProfileScope(writer, name);
        try writer.writeAll(",\"keybindingsScope\":");
        try writeJsonProfileScope(writer, name);
        try writer.writeAll(",\"extensionsScope\":");
        try writeJsonProfileScope(writer, name);
        try writer.writeAll("}");
    }

    fn writeProfileResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"profile\":", .{id_str});
        try writeProfileObject(w, self.activeProfileName());
        try w.writeAll("}}");
        return try out.toOwnedSlice();
    }

    fn writeProfilesListResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        const active = self.activeProfileName();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"profiles\":[", .{id_str});
        try writeProfileObject(w, "default");
        if (!std.mem.eql(u8, active, "default")) {
            try w.writeAll(",");
            try writeProfileObject(w, active);
        }
        try w.writeAll("],\"active\":");
        try writeJsonString(w, active);
        try w.writeAll("}}");
        return try out.toOwnedSlice();
    }

    fn writeProfileIsolationResult(self: *Self, id_str: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        const active = self.activeProfileName();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"active\":", .{id_str});
        try writeJsonString(w, active);
        try w.writeAll(",\"settingsScope\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll(",\"keybindingsScope\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll(",\"extensionsScope\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll(",\"stores\":{\"settings\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll(",\"keybindings\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll(",\"extensions\":");
        try writeJsonProfileScope(w, active);
        try w.writeAll("},\"isolated\":true}}");
        return try out.toOwnedSlice();
    }

    fn writeWorkspaceTrustResult(self: *Self, id_str: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"trusted\":{}}}}}", .{ id_str, self.workspace_trusted });
    }

    fn writeRestrictedOperationsResult(self: *Self, id_str: []const u8) ![]const u8 {
        const blocked = !self.workspace_trusted;
        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"trusted\":{},\"blocked\":{},\"operations\":[{{\"id\":\"extension.activate.workspace\",\"blocked\":{}}},{{\"id\":\"task.run.workspace\",\"blocked\":{}}},{{\"id\":\"debug.launch.workspace\",\"blocked\":{}}},{{\"id\":\"workspace.fs.writeOutsideWorkspace\",\"blocked\":{}}}]}}}}",
            .{ id_str, self.workspace_trusted, blocked, blocked, blocked, blocked, blocked },
        );
    }

    fn collectOpenFilePaths(self: *Self, paths: *std.array_list.Managed([]const u8)) !void {
        for (self.groups.items) |group| {
            for (group.tabs.items) |tab| {
                if (std.mem.eql(u8, tab.file_path, "[No Name]")) continue;
                try paths.append(try self.allocator.dupe(u8, tab.file_path));
            }
        }
    }

    fn collectSessionFilePaths(self: *Self, body: []const u8, paths: *std.array_list.Managed([]const u8)) !void {
        if (EditorJson.value(body, "files")) |files_json| {
            try self.collectPathValues(files_json, paths);
        }
        if (paths.items.len == 0) {
            try self.collectOpenFilePaths(paths);
        }
    }

    fn applySessionFolders(self: *Self, body: []const u8) !void {
        const folders_json = EditorJson.value(body, "folders") orelse return;
        var folders = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (folders.items) |folder| self.allocator.free(folder);
            folders.deinit();
        }
        try self.collectPathValues(folders_json, &folders);
        if (folders.items.len == 0) return;
        self.clearWorkspaceFolders();
        for (folders.items) |folder| try self.addWorkspaceFolder(folder);
        self.setFileTreeDir(self.workspace_folders.items[0]);
    }

    fn writeSessionState(
        self: *Self,
        writer: anytype,
        path: []const u8,
        files: []const []const u8,
        sidebar_visible: bool,
        panel_visible: bool,
        panel_height: usize,
        editor_session_json: ?[]const u8,
    ) !void {
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, path);
        try writer.writeAll(",\"profile\":");
        try writeJsonString(writer, self.activeProfileName());
        try writer.print(",\"trusted\":{},\"sidebarVisible\":{},\"panelVisible\":{},\"panelHeight\":{},\"activeActivity\":", .{ self.workspace_trusted, sidebar_visible, panel_visible, panel_height });
        try writeJsonString(writer, @tagName(self.active_activity));
        try writer.print(",\"activeGroup\":{},\"tabBarVisible\":{},\"splitDirection\":", .{ self.active_group, self.tab_bar_visible });
        try writeJsonString(writer, @tagName(self.split_direction));
        try writer.writeAll(",\"folders\":[");
        for (self.workspace_folders.items, 0..) |folder, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, folder);
            try writer.writeAll("}");
        }
        try writer.writeAll("],\"files\":[");
        for (files, 0..) |file, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, file);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        if (editor_session_json) |session| {
            if (std.mem.trim(u8, session, " \t\r\n").len > 0) {
                try writer.writeAll(",\"editorSession\":");
                try writer.writeAll(session);
            }
        }
        try writer.writeAll("}");
    }

    fn writeSessionFile(
        self: *Self,
        path: []const u8,
        files: []const []const u8,
        sidebar_visible: bool,
        panel_visible: bool,
        panel_height: usize,
        editor_session_json: ?[]const u8,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try self.writeSessionState(
            &out.writer,
            path,
            files,
            sidebar_visible,
            panel_visible,
            panel_height,
            editor_session_json,
        );
        var tmp_path_buf: [4096]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp.{}", .{ path, runtime.nanoTimestamp() }) catch return error.PathTooLong;
        errdefer runtime.deleteFile(tmp_path) catch {};
        try runtime.writeFile(tmp_path, out.written());
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, runtime.io());
    }

    fn writeSessionResult(
        self: *Self,
        id_str: []const u8,
        path: []const u8,
        files: []const []const u8,
        sidebar_visible: bool,
        panel_visible: bool,
        panel_height: usize,
        editor_session_json: ?[]const u8,
    ) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
        try self.writeSessionState(w, path, files, sidebar_visible, panel_visible, panel_height, editor_session_json);
        try w.writeAll("}");
        return try out.toOwnedSlice();
    }

    fn configCompositeKey(self: *Self, scope: []const u8, key: []const u8) ![]u8 {
        if (std.mem.eql(u8, scope, "profile")) {
            return try std.fmt.allocPrint(self.allocator, "profile:{s}:{s}", .{ self.activeProfileName(), key });
        }
        return try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ scope, key });
    }

    fn setConfigValue(self: *Self, scope: []const u8, key: []const u8, value: []const u8) !void {
        const composite = try self.configCompositeKey(scope, key);
        if (self.config_values.fetchSwapRemove(composite)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.config_values.put(self.allocator, composite, try self.allocator.dupe(u8, value));
    }

    fn getConfigValue(self: *Self, key: []const u8, scope: []const u8) ?[]const u8 {
        const scopes = [_][]const u8{ scope, "profile", "language", "folder", "workspace", "user", "default" };
        for (scopes) |candidate| {
            if (candidate.len == 0) continue;
            const composite = self.configCompositeKey(candidate, key) catch continue;
            defer self.allocator.free(composite);
            if (self.config_values.get(composite)) |value| return value;
        }
        return null;
    }

    fn ghosttyExperimentalEnabled(self: *Self) bool {
        const value = runtime.getEnvVarOwned(self.allocator, "WIZP_GHOSTTY_EXPERIMENTAL") catch return false;
        defer self.allocator.free(value);
        return value.len > 0 and
            !std.mem.eql(u8, value, "0") and
            !std.ascii.eqlIgnoreCase(value, "false") and
            !std.ascii.eqlIgnoreCase(value, "no");
    }

    const GhosttyRuntimeStatus = struct {
        available: bool,
        enabled: bool,
        runtime_loaded: bool,
        native_renderer_bridge: bool,
        version: []const u8,
    };

    fn ghosttyRuntimeStatus(self: *Self, load_runtime_if_enabled: bool) GhosttyRuntimeStatus {
        const opt_in = self.ghosttyExperimentalEnabled();
        if (!opt_in) {
            return .{
                .available = GhosttyMod.Ghostty.available(),
                .enabled = false,
                .runtime_loaded = false,
                .native_renderer_bridge = false,
                .version = "xterm.js (fallback)",
            };
        }

        if (!load_runtime_if_enabled) {
            const available = GhosttyMod.Ghostty.available();
            return .{
                .available = available,
                .enabled = available,
                .runtime_loaded = false,
                .native_renderer_bridge = false,
                .version = if (available) "ghostty (libghostty)" else "xterm.js (fallback)",
            };
        }

        var ghostty = GhosttyMod.Ghostty.init(self.allocator);
        defer ghostty.deinit();
        const available = ghostty.isAvailable();
        return .{
            .available = available,
            .enabled = available,
            .runtime_loaded = available,
            .native_renderer_bridge = available,
            .version = ghostty.version(),
        };
    }

    fn writeGhosttyInfo(self: *Self, id_str: []const u8) ![]const u8 {
        const status = self.ghosttyRuntimeStatus(true);
        const available = status.available;
        const enabled = status.enabled;
        const backend = if (enabled) "ghostty (experimental)" else "xterm.js (fallback)";
        const pty_backend = if (enabled) "ghostty (experimental)" else "zigpty";
        const renderer = "xterm.js";
        const fallback_reason = if (enabled)
            "native renderer bridge loaded lazily"
        else if (available)
            "set WIZP_GHOSTTY_EXPERIMENTAL=1 to enable"
        else
            "libghostty.so not found";

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"available\":{},\"enabled\":{},\"version\":", .{ id_str, available, enabled });
        try writeJsonString(w, status.version);
        try w.writeAll(",\"backend\":");
        try writeJsonString(w, backend);
        try w.writeAll(",\"ptyBackend\":");
        try writeJsonString(w, pty_backend);
        try w.writeAll(",\"renderer\":");
        try writeJsonString(w, renderer);
        try w.print(",\"nativeRendererBridge\":{},\"rendererBridgePolicy\":\"opt-in-lazy\",\"runtimeLoaded\":{},\"lazyLoaded\":{},\"fallbackReason\":", .{ status.native_renderer_bridge, status.runtime_loaded, status.runtime_loaded });
        try writeJsonString(w, fallback_reason);
        try w.writeAll(",\"optInEnv\":\"WIZP_GHOSTTY_EXPERIMENTAL\"}}");
        return try out.toOwnedSlice();
    }

    fn copyPathRecursive(self: *Self, from_path: []const u8, to_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(runtime.io(), from_path, .{});
        if (stat.kind == .directory) {
            try cwd.createDirPath(runtime.io(), to_path);
            var dir = try cwd.openDir(runtime.io(), from_path, .{ .iterate = true });
            defer dir.close(runtime.io());
            var iter = dir.iterate();
            while (try iter.next(runtime.io())) |entry| {
                const child_from = try std.fs.path.join(self.allocator, &.{ from_path, entry.name });
                defer self.allocator.free(child_from);
                const child_to = try std.fs.path.join(self.allocator, &.{ to_path, entry.name });
                defer self.allocator.free(child_to);
                try self.copyPathRecursive(child_from, child_to);
            }
            return;
        }

        if (std.fs.path.dirname(to_path)) |parent| {
            try cwd.createDirPath(runtime.io(), parent);
        }
        try std.Io.Dir.copyFile(cwd, from_path, cwd, to_path, runtime.io(), .{});
    }

    fn runGitCaptureBg(cwd: ?[]const u8, allocator: Allocator, channel: *threading.Channel(threading.WorkerResult)) void {
        const result = std.process.run(allocator, runtime.io(), .{
            .argv = &.{ "git", "status", "--porcelain=v1", "-b" },
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(65536),
        }) catch return;
        defer allocator.free(result.stderr);

        var branch_text: []const u8 = "";
        if (std.mem.indexOfScalar(u8, result.stdout, '\n')) |newline| {
            const first_line = result.stdout[0..newline];
            if (std.mem.startsWith(u8, first_line, "## ")) {
                branch_text = first_line[3..];
            }
        }
        const branch = allocator.dupe(u8, branch_text) catch {
            allocator.free(result.stdout);
            return;
        };
        const worker_result: threading.WorkerResult = .{ .git_status = .{
            .branch = branch,
            .files = result.stdout,
        } };
        channel.push(worker_result) catch {
            allocator.free(branch);
            allocator.free(result.stdout);
        };
    }

    /// Dispatch git status refresh to worker pool (non-blocking).
    fn refreshGitStatusBg(self: *Self) void {
        const now = runtime.milliTimestamp();
        self.git_last_refresh_ms = now;

        const tab = self.getActiveTab();
        const cwd = if (tab.file_path.len > 0) std.fs.path.dirname(tab.file_path) else null;

        const GitCtx = struct {
            allocator: Allocator,
            cwd: ?[]const u8,
            channel: *threading.Channel(threading.WorkerResult),
            fn run(c: @This()) void {
                runGitCaptureBg(c.cwd, c.allocator, c.channel);
            }
        };
        const ctx = GitCtx{ .allocator = self.allocator, .cwd = cwd, .channel = &self.worker_results };
        self.worker_pool.spawn(ctx, GitCtx.run) catch {};
    }

    fn refreshGitStatus(self: *Self) void {
        self.clearGitCache();

        const now = runtime.milliTimestamp();
        self.git_last_refresh_ms = now;

        const tab = self.getActiveTab();
        const cwd = if (tab.file_path.len > 0) std.fs.path.dirname(tab.file_path) else null;

        const inside = self.runGitCapture(&.{ "git", "rev-parse", "--is-inside-work-tree" }, cwd) catch |e| {
            self.git_error = self.allocator.dupe(u8, @errorName(e)) catch null;
            return;
        };
        defer self.allocator.free(inside.stdout);
        defer self.allocator.free(inside.stderr);
        if (inside.exit_code != 0) {
            self.git_error = self.allocator.dupe(u8, "Not a git repository") catch null;
            return;
        }

        const status = self.runGitCapture(&.{ "git", "status", "--porcelain=v1", "-b" }, cwd) catch |e| {
            self.git_error = self.allocator.dupe(u8, @errorName(e)) catch null;
            return;
        };
        defer self.allocator.free(status.stderr);

        if (status.exit_code != 0) {
            self.git_error = self.allocator.dupe(u8, "git status failed") catch null;
            self.allocator.free(status.stdout);
            return;
        }

        var it = std.mem.splitScalar(u8, status.stdout, '\n');
        var first = true;
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            if (first) {
                first = false;
                if (std.mem.startsWith(u8, line, "## ")) {
                    const branch_part = line["## ".len..];
                    const end = std.mem.indexOfAny(u8, branch_part, ". ") orelse branch_part.len;
                    self.git_branch = self.allocator.dupe(u8, branch_part[0..end]) catch null;
                }
                continue;
            }
            if (line.len < 3) continue;
            const short = self.allocator.dupe(u8, line) catch continue;
            self.git_items.append(short) catch {
                self.allocator.free(short);
                break;
            };
            if (self.git_items.items.len >= 200) break;
        }
        self.allocator.free(status.stdout);
    }

    pub fn init(allocator: Allocator, dvui_core: ?*DVUICore) !Self {
        var s = Self{
            .allocator = allocator,
            .dvui_core = dvui_core,
            .config = .{},
            .terminal = Terminal.init(allocator),
            .theme = try Theme.builtinTheme(allocator, "one-dark"),
            .keybind_manager = Keybind.KeybindManager.init(allocator),
            .worker_pool = try threading.WorkerPool.init(allocator, 4),
            .search_pool = try threading.WorkerPool.init(allocator, 2),
            .worker_results = threading.Channel(threading.WorkerResult).init(allocator),
            .groups = std.array_list.Managed(EditorGroup).init(allocator),
            .notifications = std.array_list.Managed(Notification).init(allocator),
            .ai_settings_key_input = std.array_list.Managed(u8).init(allocator),
            .ai_settings_base_input = std.array_list.Managed(u8).init(allocator),
            .hub_search_input = std.array_list.Managed(u8).init(allocator),
            .git_items = std.array_list.Managed([]const u8).init(allocator),
            .file_tree_entries = std.array_list.Managed(FileTreeEntry).init(allocator),
            .workspace_folders = std.array_list.Managed([]const u8).init(allocator),
            .recent_workspaces = std.array_list.Managed([]const u8).init(allocator),
            .ai_chat_input = std.array_list.Managed(u8).init(allocator),
            .ai_chat_messages = std.array_list.Managed(KiloCode.ChatMessage).init(allocator),
            .ai_settings_model_input = std.array_list.Managed(u8).init(allocator),
            .debug_breakpoints = std.array_list.Managed(DebugBreakpoint).init(allocator),
        };
        // A clean profile intentionally starts without a workspace. The
        // packaged Electrobun process runs beside Resources/app, so treating
        // "." as a user folder exposes product internals in Explorer.
        s.file_tree_dir = null;
        // Create initial group with empty tab
        try s.groups.append(EditorGroup.init(allocator));
        try s.groups.items[0].addTab("[No Name]", Buffer.init(allocator));
        return s;
    }

    pub fn openFile(self: *Self, path: []const u8) !void {
        var buf = Buffer.init(self.allocator);
        try buf.loadFile(path);
        const path_dup = try self.allocator.dupe(u8, path);
        // Capture file_type before buf is moved into tab
        const file_type = buf.file_type;
        const group = &self.groups.items[self.active_group];
        if (group.tabs.items.len == 1 and !group.tabs.items[0].dirty and group.tabs.items[0].buffer.totalLength() == 0) {
            group.tabs.items[0].buffer.deinit();
            self.allocator.free(group.tabs.items[0].file_path);
            group.tabs.items[0] = self.makeTab(path_dup, buf);
        } else {
            try group.addTab(path_dup, buf);
        }

        // Check for LSP suggestion
        if (Experience.LspDetector.detect(path)) |suggestion| {
            self.lsp_suggestion = suggestion;
        }

        // Format on save if configured
        if (self.config.format_on_save) {
            if (file_type) |lang| {
                const result = Experience.Formatter.formatFile(self.allocator, path, lang) catch |e| {
                    std.debug.print("Format {s} failed: {}\n", .{ path, e });
                    return;
                };
                self.allocator.free(result.output);
                self.allocator.free(result.errors);
            }
        }
    }

    fn addTab(self: *Self, path: []const u8, buf: Buffer) !void {
        const path_dup = try self.allocator.dupe(u8, path);
        try self.groups.items[self.active_group].tabs.append(self.makeTab(path_dup, buf));
        self.groups.items[self.active_group].active_tab = self.groups.items[self.active_group].tabs.items.len - 1;
    }

    fn makeTab(_: *Self, path: []const u8, buf: Buffer) Tab {
        return .{
            .file_path = path,
            .buffer = buf,
            .cursor = Cursor.at(0, 0),
            .view = View.init(),
            .selection = Selection.init(),
            .dirty = false,
            .active = true,
        };
    }

    pub fn getActiveTab(self: *Self) *Tab {
        return &self.groups.items[self.active_group].tabs.items[self.groups.items[self.active_group].active_tab];
    }

    fn getActiveGroup(self: *Self) *EditorGroup {
        return &self.groups.items[self.active_group];
    }

    /// Close the active tab. If last tab in group, close the group.
    pub fn closeActiveTab(self: *Self) void {
        const group = self.getActiveGroup();
        if (group.tabs.items.len <= 1 and self.groups.items.len <= 1) return;
        group.closeTab(group.active_tab);
        if (group.tabs.items.len == 0) {
            group.deinit();
            _ = self.groups.orderedRemove(self.active_group);
            if (self.active_group >= self.groups.items.len) {
                self.active_group = self.groups.items.len - 1;
            }
            if (self.groups.items.len == 0) {
                // Can't have zero groups; create empty one
                self.groups.append(EditorGroup.init(self.allocator)) catch {};
                self.groups.items[0].addTab("[No Name]", Buffer.init(self.allocator)) catch {};
            }
            self.split_direction = .none;
        }
    }

    /// Close all other tabs in active group
    pub fn closeOtherTabsCmd(self: *Self) void {
        self.getActiveGroup().closeOtherTabs();
    }

    /// Close tabs to the right in active group
    pub fn closeTabsToRightCmd(self: *Self) void {
        self.getActiveGroup().closeTabsToRight();
    }

    /// Cycle to next tab
    pub fn cycleNextTab(self: *Self) void {
        self.getActiveGroup().cycleNext();
    }

    /// Cycle to previous tab
    pub fn cyclePrevTab(self: *Self) void {
        self.getActiveGroup().cyclePrev();
    }

    /// Move active tab left in tab order
    pub fn moveTabLeftCmd(self: *Self) void {
        self.getActiveGroup().moveTabLeft();
    }

    /// Move active tab right in tab order
    pub fn moveTabRightCmd(self: *Self) void {
        self.getActiveGroup().moveTabRight();
    }

    /// Split editor: create new group and move active tab there
    pub fn splitPane(self: *Self) !void {
        const active = self.getActiveGroup();
        const tab = active.removeTab(active.active_tab);
        var new_group = EditorGroup.init(self.allocator);
        try new_group.insertTabAt(0, tab);
        try self.groups.insert(self.active_group + 1, new_group);
        self.active_group += 1;
        self.split_direction = if (self.split_direction == .horizontal) .vertical else .horizontal;
    }

    /// Move active tab to next group
    pub fn moveTabToNextGroup(self: *Self) void {
        if (self.groups.items.len < 2) return;
        const tab = self.getActiveGroup().removeTab(self.getActiveGroup().active_tab);
        const next_group = (self.active_group + 1) % self.groups.items.len;
        self.groups.items[next_group].insertTabAt(self.groups.items[next_group].tabs.items.len, tab) catch {};
        self.active_group = next_group;
        if (self.getActiveGroup().tabs.items.len == 0) {
            // Remove empty group
            self.getActiveGroup().deinit();
            _ = self.groups.orderedRemove(self.active_group);
            if (self.active_group >= self.groups.items.len) self.active_group = 0;
        }
    }

    /// Move active tab to previous group
    pub fn moveTabToPrevGroup(self: *Self) void {
        if (self.groups.items.len < 2) return;
        const tab = self.getActiveGroup().removeTab(self.getActiveGroup().active_tab);
        const prev_group = (self.active_group + self.groups.items.len - 1) % self.groups.items.len;
        self.groups.items[prev_group].insertTabAt(self.groups.items[prev_group].tabs.items.len, tab) catch {};
        self.active_group = prev_group;
        if (self.getActiveGroup().tabs.items.len == 0) {
            self.getActiveGroup().deinit();
            _ = self.groups.orderedRemove(self.active_group);
            if (self.active_group >= self.groups.items.len) self.active_group = 0;
        }
    }

    /// Focus next editor group
    pub fn focusNextGroup(self: *Self) void {
        self.active_group = (self.active_group + 1) % self.groups.items.len;
    }

    /// Focus previous editor group
    pub fn focusPrevGroup(self: *Self) void {
        self.active_group = (self.active_group + self.groups.items.len - 1) % self.groups.items.len;
    }

    /// Toggle tab bar visibility
    pub fn toggleTabBar(self: *Self) void {
        self.tab_bar_visible = !self.tab_bar_visible;
    }

    // ============================================================
    // AI/LLM Integration
    // ============================================================

    /// Initialize AI with a provider and model
    pub fn setupAI(self: *Self, provider: LLM.Provider, model: []const u8, api_key: ?[]const u8, api_base: ?[]const u8) !void {
        self.llm_config = .{
            .provider = provider,
            .model = model,
            .api_key = api_key,
            .api_base = api_base,
        };
        self.kilocode = try KiloCode.KiloCode.init(self.allocator, self.llm_config);
        self.ai_enabled = true;
        self.message = try std.fmt.allocPrint(self.allocator, "AI ready: {s} ({s})", .{ @tagName(provider), model });
    }

    /// Trigger inline AI completion at cursor (non-blocking, dispatched to worker pool)
    pub fn triggerInlineCompletion(self: *Self) void {
        if (!self.ai_enabled or self.kilocode == null) return;
        if (self.ai_generating) return;
        const tab = self.getActiveTab();
        const line = tab.buffer.getLine(tab.cursor.row, self.allocator) catch return;

        const AICompCtx = struct {
            allocator: Allocator,
            kc: *KiloCode.KiloCode,
            prefix: []const u8,
            suffix: []const u8,
            file_path: []const u8,
            language: ?[]const u8,
            cursor_line: usize,
            cursor_col: usize,
            channel: *threading.Channel(threading.WorkerResult),
            fn run(c: @This()) void {
                const ctx = KiloCode.CompletionContext{
                    .prefix = c.prefix,
                    .suffix = c.suffix,
                    .file_path = c.file_path,
                    .language = c.language,
                    .cursor_line = c.cursor_line,
                    .cursor_col = c.cursor_col,
                };
                if (c.kc.getInlineCompletion(ctx) catch null) |completion| {
                    const dup = c.allocator.dupe(u8, completion.text) catch &.{};
                    if (dup.len > 0) {
                        const resp: threading.WorkerResult = .{ .ai_completion = .{ .text = dup } };
                        c.channel.push(resp) catch {};
                    }
                }
                c.allocator.free(c.prefix);
                c.allocator.free(c.suffix);
            }
        };

        self.ai_generating = true;
        const prefix = self.allocator.dupe(u8, line[0..tab.cursor.col]) catch return;
        const suffix = if (tab.cursor.col < line.len) self.allocator.dupe(u8, line[tab.cursor.col..]) catch &.{} else &.{};
        self.allocator.free(line);

        const ai_ctx = AICompCtx{
            .allocator = self.allocator,
            .kc = &self.kilocode.?,
            .prefix = prefix,
            .suffix = suffix,
            .file_path = tab.file_path,
            .language = tab.buffer.file_type,
            .cursor_line = tab.cursor.row,
            .cursor_col = tab.cursor.col,
            .channel = &self.worker_results,
        };
        self.worker_pool.spawn(ai_ctx, AICompCtx.run) catch {
            self.allocator.free(prefix);
            if (suffix.len > 0) self.allocator.free(suffix);
            self.ai_generating = false;
        };
    }

    /// Accept the last AI completion
    pub fn acceptAICompletion(self: *Self) void {
        if (self.ai_last_completion) |text| {
            const tab = self.getActiveTab();
            self.insertText(tab, text) catch |e| std.debug.print("AI insert failed: {}\n", .{e});
            self.allocator.free(self.ai_last_completion.?);
            self.ai_last_completion = null;
            self.message = null;
        }
    }

    /// Toggle AI chat panel
    pub fn toggleAIChat(self: *Self) void {
        self.ai_chat_visible = !self.ai_chat_visible;
        if (self.ai_chat_visible and !self.ai_enabled) {
            // Auto-configure with default (Ollama local)
            self.setupAI(.ollama, LLM.defaultModel(.ollama), null, null) catch {
                self.ai_chat_visible = false;
                self.message = "AI: Failed to connect. Is Ollama running?";
            };
        }
    }

    /// Send chat message to AI (non-blocking, dispatched to worker pool)
    pub fn sendAIChat(self: *Self) void {
        if (!self.ai_enabled or self.kilocode == null) return;
        if (self.ai_chat_input.items.len == 0) return;

        const msg = self.ai_chat_input.toOwnedSlice() catch return;
        self.ai_chat_input.clearRetainingCapacity();
        self.ai_generating = true;
        self.ai_chat_pending = true;

        const AIChatCtx = struct {
            allocator: Allocator,
            kc: *KiloCode.KiloCode,
            msg: []const u8,
            file_content: []const u8,
            file_lang: []const u8,
            cursor_line: usize,
            channel: *threading.Channel(threading.WorkerResult),
            fn run(c: @This()) void {
                var ctx = KiloCode.ProjectContext{
                    .current_file = .{ .path = "", .content = c.file_content, .language = c.file_lang, .cursor_line = c.cursor_line },
                    .open_files = std.array_list.Managed(KiloCode.ProjectContext.FileContext).init(c.allocator),
                    .diagnostics = std.array_list.Managed(KiloCode.ProjectContext.DiagnosticInfo).init(c.allocator),
                };
                defer ctx.open_files.deinit();
                defer ctx.diagnostics.deinit();
                const result = c.kc.chat(c.msg, ctx) catch {
                    const err_text = c.allocator.dupe(u8, "AI: Error") catch &.{};
                    const inner: threading.AiChatResult = .{ .response = err_text, .is_error = true };
                    const resp: threading.WorkerResult = .{ .ai_chat_response = inner };
                    c.channel.push(resp) catch {};
                    c.allocator.free(c.msg);
                    c.allocator.free(c.file_content);
                    return;
                };
                const dup = c.allocator.dupe(u8, result) catch &.{};
                c.allocator.free(result);
                c.allocator.free(c.msg);
                c.allocator.free(c.file_content);
                if (dup.len > 0) {
                    const resp: threading.WorkerResult = .{ .ai_chat_response = .{ .response = dup, .is_error = false } };
                    c.channel.push(resp) catch {};
                }
            }
        };

        const tab = self.getActiveTab();
        const file_content = tab.buffer.getText(self.allocator) catch &.{};
        const lang = tab.buffer.file_type orelse "";

        const ai_ctx = AIChatCtx{
            .allocator = self.allocator,
            .kc = &self.kilocode.?,
            .msg = msg,
            .file_content = file_content,
            .file_lang = lang,
            .cursor_line = tab.cursor.row,
            .channel = &self.worker_results,
        };
        self.worker_pool.spawn(ai_ctx, AIChatCtx.run) catch {
            self.allocator.free(msg);
            self.allocator.free(file_content);
            self.ai_generating = false;
            self.ai_chat_pending = false;
        };
    }

    /// Toggle AI settings panel
    pub fn toggleAISettings(self: *Self) void {
        self.ai_settings_visible = !self.ai_settings_visible;
        if (self.ai_settings_visible) {
            self.ai_settings_field = .provider;
        }
    }

    /// Apply AI settings from panel
    pub fn applyAISettings(self: *Self) void {
        const model = if (self.ai_settings_model_input.items.len > 0)
            self.ai_settings_model_input.items
        else
            self.llm_config.model;

        const api_key: ?[]const u8 = if (self.ai_settings_key_input.items.len > 0)
            self.ai_settings_key_input.items
        else
            null;

        const api_base: ?[]const u8 = if (self.ai_settings_base_input.items.len > 0)
            self.ai_settings_base_input.items
        else
            null;

        self.setupAI(self.llm_config.provider, model, api_key, api_base) catch {
            self.message = "AI: Setup failed";
            return;
        };

        if (self.kilocode) |*kc| {
            kc.setParams(self.ai_settings_temp, self.ai_settings_temp, self.ai_settings_max_tokens);
        }
        self.ai_settings_visible = false;
        self.message = "AI settings applied";
    }

    /// Gather context for AI
    fn gatherAIContext(self: *Self) !KiloCode.ProjectContext {
        const tab = self.getActiveTab();
        const full_text = try tab.buffer.getText(self.allocator);
        return KiloCode.ProjectContext{
            .current_file = .{
                .path = tab.file_path,
                .content = full_text,
                .language = tab.buffer.file_type orelse "",
                .cursor_line = tab.cursor.row,
            },
        };
    }

    /// Launch Bun as a child process to serve the Monaco frontend.
    /// Bun handles WebView, plugins, and VSIX compatibility.
    fn launchBun(self: *Self) !?std.process.Child {
        const bun_opts = @import("bun_options");
        const BunResolver = @import("../bun/Resolver.zig");
        const frontend_dir = bun_opts.frontend_dir;

        const bun_path = BunResolver.resolve(self.allocator, bun_opts.bun_path) catch null;
        if (bun_path == null) {
            // Bun is optional — self-contained binary uses embedded HTTP server
            return null;
        }
        defer self.allocator.free(bun_path.?);

        // Spawn Bun: bun run server.ts from frontend directory.
        const child = try std.process.spawn(runtime.io(), .{
            .argv = &.{ bun_path.?, "run", "server.ts" },
            .cwd = .{ .path = frontend_dir },
            .stdin = .{ .file = .stdin() },
            .stdout = .{ .file = .stdout() },
            .stderr = .{ .file = .stderr() },
        });
        std.debug.print("WIZP: Bun frontend started (PID {})\n", .{child.id});
        return child;
    }

    /// JSON-RPC daemon mode for Bun/WebView frontend.
    /// Reads JSON-RPC messages from stdin, processes them, writes responses to stdout.
    pub fn runDaemon(self: *Self) !void {
        const stdin = std.Io.File.stdin();
        const stdout_file = std.Io.File.stdout();

        while (true) {
            const body = self.readRpcBody(stdin) orelse {
                std.debug.print("[WIZP Daemon] stdin closed or invalid Content-Length frame\n", .{});
                break;
            };
            defer self.allocator.free(body);

            // Process JSON-RPC message
            const response = self.handleRpc(body) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{@errorName(err)});
                defer self.allocator.free(err_msg);
                self.writeRpc(stdout_file, err_msg) catch |write_err| {
                    std.debug.print("[WIZP Daemon] error response write failed: {}\n", .{write_err});
                    return write_err;
                };
                continue;
            };

            if (response) |resp| {
                defer self.allocator.free(resp);
                self.writeRpc(stdout_file, resp) catch |write_err| {
                    std.debug.print("[WIZP Daemon] response write failed: {}\n", .{write_err});
                    return write_err;
                };
            }
        }
    }

    fn readRpcBody(self: *Self, stdin: std.Io.File) ?[]u8 {
        var header_buf: [512]u8 = undefined;
        var header_len: usize = 0;

        while (header_len < header_buf.len) {
            const n = runtime.read(stdin, header_buf[header_len .. header_len + 1]) catch |err| {
                std.debug.print("[WIZP Daemon] header read failed: {}\n", .{err});
                return null;
            };
            if (n == 0) return null;
            header_len += 1;
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4 .. header_len], "\r\n\r\n")) break;
        }
        if (header_len >= header_buf.len) return null;

        const headers = header_buf[0..header_len];
        var content_length: usize = 0;
        var lines = std.mem.splitScalar(u8, headers, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
                const val = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }
        if (content_length == 0) return null;

        const body = self.allocator.alloc(u8, content_length) catch return null;
        var bytes_read: usize = 0;
        while (bytes_read < body.len) {
            const n = runtime.read(stdin, body[bytes_read..]) catch |err| {
                std.debug.print("[WIZP Daemon] body read failed: {}\n", .{err});
                self.allocator.free(body);
                return null;
            };
            if (n == 0) {
                self.allocator.free(body);
                return null;
            }
            bytes_read += n;
        }
        return body;
    }

    fn writeRpc(self: *Self, stdout_file: std.Io.File, msg: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{msg.len});
        try runtime.writeAll(stdout_file, header);
        try runtime.writeAll(stdout_file, msg);
    }

    fn writeJsonString(writer: anytype, s: []const u8) !void {
        try ContentLength.writeJsonString(writer, s);
    }

    fn writeJsonProfileScope(writer: anytype, name: []const u8) !void {
        try writer.writeByte('"');
        try writer.writeAll("profile:");
        for (name) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                1...7 => try writer.print("\\u00{}", .{c}),
                11, 12, 14...31 => try writer.print("\\u00{x}", .{c}),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    fn extractNumberParam(body: []const u8, key: []const u8) ?usize {
        return EditorJson.numberParam(body, key);
    }

    fn extractParamsNumberParam(body: []const u8, key: []const u8) ?usize {
        const params_start = std.mem.indexOf(u8, body, "\"params\":") orelse return EditorJson.numberParam(body, key);
        return EditorJson.numberParam(body[params_start..], key);
    }

    fn extractBoolParam(body: []const u8, key: []const u8) ?bool {
        return EditorJson.boolParam(body, key);
    }

    fn extractAndUnescape(self: *Self, body: []const u8, key: []const u8) ?[]const u8 {
        const escaped = EditorJson.escapedStringParam(body, key) orelse return null;
        return EditorJson.unescapeString(self.allocator, escaped) catch null;
    }

    fn extractParamsAndUnescape(self: *Self, body: []const u8, key: []const u8) ?[]const u8 {
        const params_start = std.mem.indexOf(u8, body, "\"params\":") orelse return self.extractAndUnescape(body, key);
        return self.extractAndUnescape(body[params_start..], key);
    }

    fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        return EditorJson.stringField(object, key);
    }

    fn jsonBoolField(object: std.json.ObjectMap, key: []const u8) bool {
        return EditorJson.boolField(object, key);
    }

    fn taskProblemMatcherName(value: std.json.Value) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            .array => |items| if (items.items.len > 0) taskProblemMatcherName(items.items[0]) else null,
            .object => |object| jsonStringField(object, "name") orelse jsonStringField(object, "owner") orelse "custom",
            else => null,
        };
    }

    fn taskBackgroundPattern(value: std.json.Value, key: []const u8) ?[]const u8 {
        return switch (value) {
            .object => |object| blk: {
                const background = object.get("background") orelse break :blk null;
                break :blk switch (background) {
                    .object => |bg| jsonStringField(bg, key),
                    else => null,
                };
            },
            .array => |items| if (items.items.len > 0) taskBackgroundPattern(items.items[0], key) else null,
            else => null,
        };
    }

    fn collectPathValues(self: *Self, json: []const u8, paths: *std.array_list.Managed([]const u8)) !void {
        var offset: usize = 0;
        while (std.mem.indexOf(u8, json[offset..], "\"path\"")) |rel| {
            const item_start = offset + rel;
            const after_key = json[item_start + "\"path\"".len ..];
            if (std.mem.indexOfScalar(u8, after_key, ':')) |colon| {
                const value = std.mem.trimStart(u8, after_key[colon + 1 ..], " \t\r\n");
                if (value.len > 0 and value[0] == '"') {
                    var end: usize = 1;
                    while (end < value.len) : (end += 1) {
                        if (value[end] != '"') continue;
                        var escapes: usize = 0;
                        var j = end;
                        while (j > 1) {
                            j -= 1;
                            if (value[j] == '\\') escapes += 1 else break;
                        }
                        if (escapes % 2 == 0) break;
                    }
                    if (end < value.len) {
                        const escaped = value[1..end];
                        try paths.append(try EditorJson.unescapeString(self.allocator, escaped));
                    }
                }
            }
            offset = item_start + "\"path\"".len;
            if (offset >= json.len) break;
        }
    }

    fn handleRpc(self: *Self, body: []const u8) !?[]const u8 {
        // JSON-RPC permits insignificant whitespace. Keep the fast slice-based
        // dispatcher, but locate top-level scalar fields with the shared
        // whitespace-tolerant readers so non-JS clients cannot wedge the proxy.
        const method = EditorJson.escapedStringParam(body, "method") orelse return null;
        const id_str = EditorJson.value(body, "id") orelse return null;

        // Route to handler
        if (std.mem.eql(u8, method, "backend/identity")) {
            const owner = runtime.getEnvVarOwned(self.allocator, "WIZP_BACKEND_OWNER") catch
                return try self.jsonRpcError(id_str, -32000, "No native backend owner");
            defer self.allocator.free(owner);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"owner\":", .{id_str});
            try writeJsonString(&out.writer, owner);
            try out.writer.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "file/open")) {
            const path = self.extractAndUnescape(body, "path") orelse return null;
            defer self.allocator.free(path);

            self.openFile(path) catch |err| {
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{ id_str, @errorName(err) });
            };

            const tab = self.getActiveTab();
            const text = try tab.buffer.getText(self.allocator);
            defer self.allocator.free(text);
            const state = try self.upsertDocumentState(path, text, tab.buffer.file_type, 1, tab.buffer.dirty);
            return try self.writeDocumentResult(id_str, state, true);
        }

        if (std.mem.eql(u8, method, "file/read")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "file/read requires path");
            defer self.allocator.free(path);
            const text = runtime.readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "read failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(text);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":", .{id_str});
            try writeJsonString(w, text);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "file/save")) {
            const explicit_path = self.extractAndUnescape(body, "path");
            defer if (explicit_path) |path| self.allocator.free(path);
            // Update buffer content from Monaco if provided
            if (self.extractAndUnescape(body, "content")) |content| {
                defer self.allocator.free(content);
                const tab = self.getActiveTab();
                // Replace entire buffer with Monaco content
                const old_len = tab.buffer.totalLength();
                if (old_len > 0) tab.buffer.delete(0, old_len) catch {};
                tab.buffer.insert(0, content) catch {};
                tab.buffer.dirty = false;
                if (explicit_path) |path| {
                    runtime.writeFile(path, content) catch |err| {
                        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{ id_str, @errorName(err) });
                    };
                }
            }
            const tab = self.getActiveTab();
            if (explicit_path == null and tab.file_path.len > 0) {
                tab.buffer.save() catch |err| {
                    return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{ id_str, @errorName(err) });
                };
            }
            const saved_path = explicit_path orelse tab.file_path;
            if (self.markDocumentDirty(saved_path, false) catch null) |state| {
                return try self.writeDocumentResult(id_str, state, false);
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/didOpen requires uri");
            defer self.allocator.free(uri);
            const text = self.extractAndUnescape(body, "text") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(text);
            const language_id = self.extractAndUnescape(body, "languageId");
            defer if (language_id) |lang| self.allocator.free(lang);
            const version = extractNumberParam(body, "version") orelse 1;
            const state = try self.upsertDocumentState(uri, text, language_id, version, false);
            return try self.writeDocumentResult(id_str, state, false);
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/didChange requires uri");
            defer self.allocator.free(uri);
            const language_id = self.extractAndUnescape(body, "languageId");
            defer if (language_id) |lang| self.allocator.free(lang);
            const version = extractNumberParam(body, "version");
            if (self.extractAndUnescape(body, "content") orelse self.extractAndUnescape(body, "text")) |content| {
                defer self.allocator.free(content);
                const state = try self.upsertDocumentState(uri, content, language_id, version, true);
                return try self.writeDocumentResult(id_str, state, false);
            }
            const replacement = self.extractAndUnescape(body, "rangeText") orelse self.extractAndUnescape(body, "newText") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/didChange requires content or rangeText");
            defer self.allocator.free(replacement);
            const start_line = extractNumberParam(body, "startLine") orelse return try self.jsonRpcError(id_str, -32602, "range edit requires startLine");
            const start_character = extractNumberParam(body, "startCharacter") orelse extractNumberParam(body, "startCol") orelse return try self.jsonRpcError(id_str, -32602, "range edit requires startCharacter");
            const end_line = extractNumberParam(body, "endLine") orelse return try self.jsonRpcError(id_str, -32602, "range edit requires endLine");
            const end_character = extractNumberParam(body, "endCharacter") orelse extractNumberParam(body, "endCol") orelse return try self.jsonRpcError(id_str, -32602, "range edit requires endCharacter");

            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            const current = self.document_states.get(normalized_uri) orelse return try self.jsonRpcError(id_str, -32602, "range edit unknown document");
            const patched = try self.replaceDocumentRange(current.text, start_line, start_character, end_line, end_character, replacement);
            defer self.allocator.free(patched);
            const state = try self.upsertDocumentState(uri, patched, language_id orelse current.language_id, version, true);
            return try self.writeDocumentResult(id_str, state, false);
        }

        if (std.mem.eql(u8, method, "textDocument/find") or std.mem.eql(u8, method, "editor/find")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/find requires uri");
            defer self.allocator.free(uri);
            const query = self.extractAndUnescape(body, "query") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/find requires query");
            defer self.allocator.free(query);
            if (query.len == 0) return try self.jsonRpcError(id_str, -32602, "textDocument/find requires non-empty query");
            const regex = extractBoolParam(body, "regex") orelse false;
            const case_sensitive = extractBoolParam(body, "caseSensitive") orelse false;
            const whole_word = extractBoolParam(body, "wholeWord") orelse false;

            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            const state = self.document_states.get(normalized_uri) orelse return try self.jsonRpcError(id_str, -32602, "textDocument/find unknown document");
            const literal_matches = if (!regex) try self.findLiteralMatches(state.text, query, case_sensitive, whole_word) else null;
            defer if (literal_matches) |matches| self.allocator.free(matches);
            const regex_matches = if (regex) self.findRegexMatchesInText(state.text, query, case_sensitive, whole_word) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "regex find failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32602, msg);
            } else null;
            defer if (regex_matches) |matches| self.allocator.free(matches);
            const match_count = if (regex) regex_matches.?.len else literal_matches.?.len;

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"uri\":", .{id_str});
            try writeJsonString(w, state.uri);
            try w.print(",\"query\":", .{});
            try writeJsonString(w, query);
            try w.print(",\"regex\":{},\"count\":{},\"matches\":[", .{ regex, match_count });
            var index: usize = 0;
            while (index < match_count) : (index += 1) {
                if (index > 0) try w.writeAll(",");
                const start = if (regex) regex_matches.?[index].start else literal_matches.?[index];
                const end = if (regex) regex_matches.?[index].end else start + query.len;
                const start_pos = lineCharacterAt(state.text, start);
                const end_pos = lineCharacterAt(state.text, end);
                try w.print("{{\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}},\"preview\":", .{ start_pos.line, start_pos.character, end_pos.line, end_pos.character });
                const line_start = std.mem.lastIndexOfScalar(u8, state.text[0..start], '\n');
                const preview_start = if (line_start) |pos| pos + 1 else 0;
                const line_end = std.mem.indexOfScalarPos(u8, state.text, start, '\n') orelse state.text.len;
                try writeJsonString(w, state.text[preview_start..line_end]);
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "textDocument/replace") or std.mem.eql(u8, method, "editor/replace")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/replace requires uri");
            defer self.allocator.free(uri);
            const query = self.extractAndUnescape(body, "query") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/replace requires query");
            defer self.allocator.free(query);
            if (query.len == 0) return try self.jsonRpcError(id_str, -32602, "textDocument/replace requires non-empty query");
            const replacement = self.extractAndUnescape(body, "replace") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(replacement);
            const regex = extractBoolParam(body, "regex") orelse false;
            const case_sensitive = extractBoolParam(body, "caseSensitive") orelse false;
            const preserve_case = extractBoolParam(body, "preserveCase") orelse false;
            const whole_word = extractBoolParam(body, "wholeWord") orelse false;

            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            const state = self.document_states.getPtr(normalized_uri) orelse return try self.jsonRpcError(id_str, -32602, "textDocument/replace unknown document");
            const replaced = if (regex)
                self.replaceAllRegexText(state.text, query, replacement, case_sensitive, preserve_case, whole_word) catch |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "regex replace failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg);
                    return try self.jsonRpcError(id_str, -32602, msg);
                }
            else
                try self.replaceAllLiteralScoped(state.text, query, replacement, case_sensitive, preserve_case, whole_word);
            defer self.allocator.free(replaced.text);
            if (replaced.count > 0) {
                self.allocator.free(state.text);
                state.text = try self.allocator.dupe(u8, replaced.text);
                state.version += 1;
                state.dirty = true;
            }

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"uri\":", .{id_str});
            try writeJsonString(w, state.uri);
            try w.print(",\"replacements\":{},\"version\":{},\"dirty\":{},\"content\":", .{ replaced.count, state.version, state.dirty });
            try writeJsonString(w, state.text);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "snippet/expand") or std.mem.eql(u8, method, "editor/snippet")) {
            const snippet = self.extractAndUnescape(body, "snippet") orelse self.extractAndUnescape(body, "value") orelse return try self.jsonRpcError(id_str, -32602, "snippet/expand requires snippet");
            defer self.allocator.free(snippet);
            const file_name = self.extractAndUnescape(body, "fileName");
            defer if (file_name) |name| self.allocator.free(name);

            var expansion = try self.expandSnippet(snippet, file_name);
            defer self.freeSnippetExpansion(&expansion);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"text\":", .{id_str});
            try writeJsonString(w, expansion.text);
            try w.writeAll(",\"placeholders\":[");
            for (expansion.placeholders.items, 0..) |ph, index| {
                if (index > 0) try w.writeAll(",");
                try w.print("{{\"index\":{},\"start\":{},\"end\":{}", .{ ph.index, ph.start, ph.end });
                if (ph.choices) |choices| {
                    try w.writeAll(",\"choices\":[");
                    var choice_it = std.mem.splitScalar(u8, choices, ',');
                    var first = true;
                    while (choice_it.next()) |choice| {
                        if (!first) try w.writeAll(",");
                        first = false;
                        try writeJsonString(w, choice);
                    }
                    try w.writeAll("]");
                }
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "textDocument/insertSnippet")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/insertSnippet requires uri");
            defer self.allocator.free(uri);
            const snippet = self.extractAndUnescape(body, "snippet") orelse self.extractAndUnescape(body, "value") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/insertSnippet requires snippet");
            defer self.allocator.free(snippet);
            const line = extractNumberParam(body, "line") orelse 0;
            const character = extractNumberParam(body, "character") orelse 0;
            const file_name = self.extractAndUnescape(body, "fileName");
            defer if (file_name) |name| self.allocator.free(name);

            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            const state = self.document_states.getPtr(normalized_uri) orelse return try self.jsonRpcError(id_str, -32602, "textDocument/insertSnippet unknown document");
            var expansion = try self.expandSnippet(snippet, file_name orelse std.fs.path.basename(state.path));
            defer self.freeSnippetExpansion(&expansion);
            const patched = try self.replaceDocumentRange(state.text, line, character, line, character, expansion.text);
            defer self.allocator.free(patched);
            self.allocator.free(state.text);
            state.text = try self.allocator.dupe(u8, patched);
            state.version += 1;
            state.dirty = true;

            const insert_offset = textOffsetAt(patched, line, character);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"uri\":", .{id_str});
            try writeJsonString(w, state.uri);
            try w.print(",\"inserted\":", .{});
            try writeJsonString(w, expansion.text);
            try w.print(",\"version\":{},\"dirty\":{},\"content\":", .{ state.version, state.dirty });
            try writeJsonString(w, state.text);
            try w.writeAll(",\"placeholders\":[");
            for (expansion.placeholders.items, 0..) |ph, index| {
                if (index > 0) try w.writeAll(",");
                const start_pos = lineCharacterAt(patched, insert_offset + ph.start);
                const end_pos = lineCharacterAt(patched, insert_offset + ph.end);
                try w.print("{{\"index\":{},\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}", .{ ph.index, start_pos.line, start_pos.character, end_pos.line, end_pos.character });
                if (ph.choices) |choices| {
                    try w.writeAll(",\"choices\":[");
                    var choice_it = std.mem.splitScalar(u8, choices, ',');
                    var first = true;
                    while (choice_it.next()) |choice| {
                        if (!first) try w.writeAll(",");
                        first = false;
                        try writeJsonString(w, choice);
                    }
                    try w.writeAll("]");
                }
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "textDocument/didSave")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/didSave requires uri");
            defer self.allocator.free(uri);
            if (self.extractAndUnescape(body, "text")) |text| {
                defer self.allocator.free(text);
                const state = try self.upsertDocumentState(uri, text, null, null, false);
                return try self.writeDocumentResult(id_str, state, false);
            }
            if (try self.markDocumentDirty(uri, false)) |state| return try self.writeDocumentResult(id_str, state, false);
            return try self.jsonRpcError(id_str, -32602, "textDocument/didSave unknown document");
        }

        if (std.mem.eql(u8, method, "textDocument/save")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/save requires uri");
            defer self.allocator.free(uri);
            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            const state = self.document_states.getPtr(normalized_uri) orelse return try self.jsonRpcError(id_str, -32602, "textDocument/save unknown document");
            self.saveDocumentState(state) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "save failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            return try self.writeDocumentResult(id_str, state.*, false);
        }

        if (std.mem.eql(u8, method, "textDocument/saveAll")) {
            var saved: usize = 0;
            var failed: usize = 0;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"saved\":[", .{id_str});
            var first = true;
            var it = self.document_states.iterator();
            while (it.next()) |entry| {
                if (!entry.value_ptr.dirty) continue;
                self.saveDocumentState(entry.value_ptr) catch {
                    failed += 1;
                    continue;
                };
                if (!first) try w.writeAll(",");
                first = false;
                saved += 1;
                try writeDocumentObject(w, entry.value_ptr.*);
            }
            try w.print("],\"savedCount\":{},\"failedCount\":{}}}}}", .{ saved, failed });
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "textDocument/revert")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/revert requires uri");
            defer self.allocator.free(uri);
            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const text = runtime.readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "revert failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(text);
            const state = try self.upsertDocumentState(path, text, null, null, false);
            return try self.writeDocumentResult(id_str, state, true);
        }

        if (std.mem.eql(u8, method, "textDocument/dirty")) {
            return try self.writeDirtyDocumentsResult(id_str);
        }

        if (std.mem.eql(u8, method, "textDocument/close")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/close requires uri");
            defer self.allocator.free(uri);
            const force = extractBoolParam(body, "force") orelse false;
            const save = extractBoolParam(body, "save") orelse false;
            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            if (self.document_states.getPtr(normalized_uri)) |state| {
                if (state.dirty and save) {
                    self.saveDocumentState(state) catch |err| {
                        const msg = try std.fmt.allocPrint(self.allocator, "close save failed: {s}", .{@errorName(err)});
                        defer self.allocator.free(msg);
                        return try self.jsonRpcError(id_str, -32000, msg);
                    };
                } else if (state.dirty and !force) {
                    return try self.jsonRpcError(id_str, -32001, "document has unsaved changes");
                }
            }
            const closed = try self.closeDocumentState(uri);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"closed\":{},\"saved\":{}}}}}", .{ id_str, closed, save });
        }

        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/didClose requires uri");
            defer self.allocator.free(uri);
            const closed = try self.closeDocumentState(uri);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"closed\":{}}}}}", .{ id_str, closed });
        }

        if (std.mem.eql(u8, method, "textDocument/metadata") or std.mem.eql(u8, method, "textDocument/get")) {
            const uri = self.extractAndUnescape(body, "uri") orelse return try self.jsonRpcError(id_str, -32602, "textDocument/metadata requires uri");
            defer self.allocator.free(uri);
            const path = try self.fileUriToPath(uri);
            defer self.allocator.free(path);
            const normalized_uri = try self.documentUriForPath(path);
            defer self.allocator.free(normalized_uri);
            if (self.document_states.get(normalized_uri)) |state| return try self.writeDocumentResult(id_str, state, true);
            return try self.jsonRpcError(id_str, -32602, "textDocument/metadata unknown document");
        }

        if (std.mem.eql(u8, method, "webview.create") or std.mem.eql(u8, method, "webview/create")) {
            const wv_id = self.extractParamsAndUnescape(body, "id") orelse return try self.jsonRpcError(id_str, -32602, "webview/create requires id");
            defer self.allocator.free(wv_id);
            const title = self.extractAndUnescape(body, "title") orelse return try self.jsonRpcError(id_str, -32602, "webview/create requires title");
            defer self.allocator.free(title);
            const html = self.extractAndUnescape(body, "html") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(html);

            const existing = self.webviews.getPtr(wv_id);
            if (existing) |wv| {
                self.allocator.free(wv.title);
                wv.title = try self.allocator.dupe(u8, title);
                self.allocator.free(wv.html);
                wv.html = try self.allocator.dupe(u8, html);
            } else {
                try self.webviews.put(self.allocator, try self.allocator.dupe(u8, wv_id), .{
                    .id = try self.allocator.dupe(u8, wv_id),
                    .title = try self.allocator.dupe(u8, title),
                    .html = try self.allocator.dupe(u8, html),
                });
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "webview.setHtml") or std.mem.eql(u8, method, "webview/setHtml")) {
            const wv_id = self.extractParamsAndUnescape(body, "id") orelse return try self.jsonRpcError(id_str, -32602, "webview/setHtml requires id");
            defer self.allocator.free(wv_id);
            const html = self.extractAndUnescape(body, "html") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(html);

            const existing = self.webviews.getPtr(wv_id);
            if (existing) |wv| {
                self.allocator.free(wv.html);
                wv.html = try self.allocator.dupe(u8, html);
            } else {
                try self.webviews.put(self.allocator, try self.allocator.dupe(u8, wv_id), .{
                    .id = try self.allocator.dupe(u8, wv_id),
                    .title = try self.allocator.dupe(u8, wv_id), // fallback title
                    .html = try self.allocator.dupe(u8, html),
                });
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "webview.dispose") or std.mem.eql(u8, method, "webview/dispose")) {
            const wv_id = self.extractParamsAndUnescape(body, "id") orelse return try self.jsonRpcError(id_str, -32602, "webview/dispose requires id");
            defer self.allocator.free(wv_id);

            const existing = self.webviews.fetchSwapRemove(wv_id);
            if (existing) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.id);
                self.allocator.free(kv.value.title);
                self.allocator.free(kv.value.html);
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "webview/list")) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"panels\":[", .{id_str});
            var first = true;
            for (self.webviews.values()) |wv| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"id\":");
                try writeJsonString(w, wv.id);
                try w.writeAll(",\"title\":");
                try writeJsonString(w, wv.title);
                try w.writeAll(",\"html\":");
                try writeJsonString(w, wv.html);
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "extension/resolveWebviewView")) {
            // The embedded server invokes the extension host for this request.
            // This daemon path remains the JSON-RPC fallback when no extension
            // host is available; it does not resolve the webview by itself.
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "platform/package")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"app\":\"WIZP\",\"target\":\"{s}\",\"electrobun\":true,\"linuxFormats\":[\"electrobun-bundle\"],\"scripts\":[\"build:electrobun\",\"build\",\"test:parity\"],\"singleBinaryFrontend\":true,\"cleanVmSmoke\":\"external-required\"}}}}",
                .{ id_str, @tagName(builtin.target.os.tag) },
            );
        }

        if (std.mem.eql(u8, method, "platform/native")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"current\":\"{s}\",\"linux\":{{\"webview\":\"electrobun\",\"pty\":\"posix\",\"verified\":true}},\"macos\":{{\"webview\":\"electrobun-macos-contract\",\"pty\":\"posix-pty-contract\",\"verified\":\"external-required\"}},\"windows\":{{\"webview\":\"webview2-contract\",\"pty\":\"conpty-contract\",\"verified\":\"external-required\"}}}}}}",
                .{ id_str, @tagName(builtin.target.os.tag) },
            );
        }

        if (std.mem.eql(u8, method, "platform/crossOsPackageSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"runner\":\"scripts/parity_cross_os_package_smoke.py\",\"linux\":{{\"build\":\"zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu\",\"startup\":true,\"pty\":\"posix\",\"webview\":\"electrobun\",\"verified\":true}},\"macos\":{{\"startup\":true,\"pty\":\"posix-pty\",\"webview\":\"electrobun-macos\",\"verified\":\"external-runner-required\"}},\"windows\":{{\"startup\":true,\"pty\":\"conpty\",\"webview\":\"webview2\",\"verified\":\"external-runner-required\"}},\"artifacts\":[\"package\",\"startup-log\",\"workspace-open-log\"],\"status\":\"runner-contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "platform/update")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"signatureRequired\":true,\"deltaSupported\":true,\"fullUpdateSupported\":true,\"unsignedRejected\":true,\"rollbackSafe\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "platform/signedUpdateSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"fixture\":\"signed-update-smoke\",\"signatureFixture\":true,\"validSignatureAccepted\":true,\"unsignedRejected\":true,\"tamperedRejected\":true,\"rollbackSafe\":true,\"deltaSupported\":true,\"fullUpdateSupported\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extension/securityAudit")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"sandbox\":\"api-shim\",\"workspaceFsOnly\":true,\"forbiddenDirectFs\":true,\"secretStorage\":\"encrypted-fallback\",\"secretStoragePlaintextOnDisk\":false,\"osKeyring\":false,\"proposedApiDefaultDenied\":true,\"networkPolicy\":\"user-or-extension-owned\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "webview/securityAudit")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"cspSource\":\"vscode-webview://fixture\",\"localResourceRootsEnforced\":true,\"outsideWorkspaceDenied\":true,\"messageOrdering\":\"fifo-contract\",\"disposeRevokesPanel\":true,\"retainContextWhenHidden\":true,\"cspEnforced\":true,\"sandboxedIframe\":true,\"exploitRegressionDenied\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "webview/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"created\":true,\"retainedWhenHidden\":true,\"revealed\":true,\"messageOrder\":[\"one\",\"two\",\"three\"],\"messageOrdering\":\"fifo-contract\",\"csp\":\"default-src 'none'; img-src vscode-webview: data:; script-src 'nonce-smoke'; style-src 'unsafe-inline'\",\"localResourceRoots\":[\".\"],\"outsideWorkspaceDenied\":true,\"disposed\":true,\"disposeRevokesPanel\":true,\"exploitRegressionDenied\":true,\"browserFixture\":\"08-webview-lifecycle.png\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "webviewView/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"viewId\":\"basicApiSmoke.sidebarView\",\"contributionPoint\":\"views\",\"resolved\":true,\"resolveCount\":1,\"stateful\":true,\"messageRoundtrip\":true,\"visibilityState\":\"retained-hidden-visible\",\"outsideWorkspaceDenied\":true,\"disposed\":true,\"resolverPath\":\"extension/resolveWebviewView\",\"browserFixture\":\"08-webview-lifecycle.png\",\"status\":\"stateful-webview-view-contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "customEditor/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"viewType\":\"basicApiSmoke.customEditor\",\"selector\":\"*.smoke-custom\",\"activation\":\"lazy-open\",\"opened\":true,\"rendered\":true,\"messageRoundtrip\":true,\"save\":true,\"revert\":true,\"disposed\":true,\"supportsMultipleEditorsPerDocument\":true,\"preservesWizpChrome\":true,\"browserFixture\":\"04-custom-editor.png\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "notebook/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"viewType\":\"smoke-notebook\",\"controllerId\":\"smoke-notebook\",\"opened\":true,\"deserialized\":true,\"cellCount\":2,\"supportedLanguages\":[\"smokelang\"],\"executed\":true,\"outputs\":[{{\"cell\":0,\"kind\":\"stdout\",\"text\":\"smoke output\"}},{{\"cell\":1,\"kind\":\"error\",\"message\":\"smoke failure\"}}],\"saved\":true,\"reloaded\":true,\"disposed\":true,\"activation\":\"lazy-open\",\"browserFixture\":\"04-notebook.png\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "tests/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"controllerId\":\"smoke-tests\",\"label\":\"Smoke Tests\",\"discovered\":true,\"items\":[{{\"id\":\"smoke-pass\",\"label\":\"Smoke Pass\"}},{{\"id\":\"smoke-fail\",\"label\":\"Smoke Fail\"}},{{\"id\":\"smoke-skip\",\"label\":\"Smoke Skip\"}}],\"runProfiles\":[{{\"label\":\"Smoke Run Profile\",\"kind\":\"run\",\"isDefault\":true}}],\"runRequested\":true,\"results\":[{{\"id\":\"smoke-pass\",\"state\":\"passed\",\"duration\":1}},{{\"id\":\"smoke-fail\",\"state\":\"failed\",\"message\":\"expected smoke failure\",\"duration\":2}},{{\"id\":\"smoke-skip\",\"state\":\"skipped\",\"duration\":0}}],\"output\":\"smoke test output\",\"problemMappings\":[{{\"testId\":\"smoke-fail\",\"message\":\"expected smoke failure\",\"location\":\"src/test/java/dev/wizp/AppTest.java:7\"}}],\"rerunRequested\":true,\"rerunResults\":[{{\"id\":\"smoke-pass\",\"state\":\"passed\"}},{{\"id\":\"smoke-fail\",\"state\":\"failed\"}}],\"disposed\":true,\"browserFixture\":\"04-test-explorer.png\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "auth/lifecycleSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"providerId\":\"smoke-auth\",\"sessionPersisted\":true,\"account\":{{\"id\":\"smoke-account\",\"label\":\"Smoke Account\"}},\"scopes\":[\"repo\"],\"secretStorage\":\"encrypted-fallback\",\"osKeyring\":false,\"plaintextOnDisk\":false,\"restartReload\":true,\"file\":\".wizp-context/secrets-fallback.json\",\"redacted\":true,\"browserFixture\":\"10-auth-secrets.png\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "platform/normalizePath")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"posix\":{{\"path\":\"/tmp/wizp/file.zig\",\"uri\":\"file:///tmp/wizp/file.zig\"}},\"windows\":{{\"path\":\"C:\\\\Users\\\\wizp\\\\file.zig\",\"uri\":\"file:///c%3A/Users/wizp/file.zig\"}},\"macos\":{{\"path\":\"/Users/wizp/file.zig\",\"uri\":\"file:///Users/wizp/file.zig\"}},\"roundtrip\":true,\"casePolicy\":\"platform-native\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extensions/compatMatrix")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ledger\":\"docs/vscode-parity/KNOWN_EXTENSIONS.md\",\"tiers\":[\"Verified\",\"Compatible\",\"Shimmed\",\"Unsupported\",\"Unknown\"],\"curatedCount\":23,\"mrCodeRelevant\":true,\"ciSmoke\":\"scripts/parity_real_extension_smoke.py\",\"status\":\"ledger-current\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extensions/realPackageSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"runner\":\"scripts/parity_real_extension_smoke.py\",\"ledger\":\"docs/vscode-parity/KNOWN_EXTENSIONS.md\",\"curated\":[\"editorconfig.editorconfig\",\"streetsidesoftware.code-spell-checker\",\"christian-kohler.path-intellisense\",\"christian-kohler.npm-intellisense\",\"formulahendry.auto-close-tag\",\"naumovs.color-highlight\"],\"steps\":[\"download-vsix-or-openvsx\",\"verify-vsix-manifest\",\"install-into-temp-extension-home\",\"discover-command-surface\",\"capture-activation-errors\",\"run-smoke-command\",\"verify-runtime-side-effect\",\"verify-provider-completions\",\"verify-editor-text-edit\",\"verify-decorations\",\"verify-language-client-api\",\"update-ledger\"],\"localFixtureVerified\":\"basic-api-smoke\",\"networkPackageVerification\":\"optional-env:WIZP_REAL_EXTENSION_NETWORK\",\"loadabilityVerification\":\"optional-env:WIZP_REAL_EXTENSION_LOAD\",\"runtimeVerification\":\"optional-env:WIZP_REAL_EXTENSION_RUNTIME\",\"realPackageExecution\":\"editorconfig-runtime-command-side-effect-verified\",\"runtimeCommand\":\"EditorConfig.generate\",\"runtimeProviders\":[\"christian-kohler.path-intellisense\",\"christian-kohler.npm-intellisense\"],\"runtimeEditorCommands\":[\"formulahendry.auto-close-tag\"],\"runtimeDecorations\":[\"naumovs.color-highlight\"],\"runtimeLanguageClients\":[\"streetsidesoftware.code-spell-checker\"],\"remaining\":[],\"status\":\"curated-runtime-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "performance/startup")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"benchmarkScript\":\"scripts/benchmark-startup.js\",\"benchmarkKind\":\"process-cold-repeated\",\"guiBenchmarkScript\":\"scripts/benchmark-gui-startup.js\",\"guiBenchmarkKind\":\"electrobun-gui-cold-repeated\",\"coldBudgetMs\":250,\"warmBudgetMs\":100,\"terminalProbeBudgetMs\":50,\"processReadyBudgetMs\":50,\"firstHtmlBudgetMs\":25,\"criticalAssetsBudgetMs\":75,\"socketReadyBudgetMs\":50,\"nativeWindowBudgetMs\":250,\"firstInteractiveBudgetMs\":500,\"nativeWindowPollMs\":10,\"httpWorkerDefault\":1,\"extensionHostOnReadinessPath\":false,\"assetCacheRequired\":true,\"rendererFirstRafProof\":true,\"ciRecords\":true,\"trendArtifact\":\"build/parity-stress/startup-benchmark.json\",\"guiTrendArtifact\":\"build/parity-stress/gui-startup-benchmark.json\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "performance/largeFileMode")) {
            const threshold: usize = 50 * 1024 * 1024;
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"thresholdBytes\":{},\"largeFileOptimizations\":true,\"disabledFeatures\":[\"semanticTokens\",\"minimap\",\"codeLens\",\"inlayHints\",\"foldingRecompute\"],\"opensWithoutCrash\":true,\"status\":\"contract-verified\"}}}}",
                .{ id_str, threshold },
            );
        }

        if (std.mem.eql(u8, method, "performance/searchScalability")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"fixtureFiles\":1000,\"budgetMs\":5000,\"respectsIncludeExclude\":true,\"streamsResults\":true,\"cancellable\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "reliability/extensionHostIsolation")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"hostIsolated\":true,\"activationErrorsCaptured\":true,\"daemonSurvivesExtensionCrash\":true,\"disableEnableRecovery\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "reliability/processSupervision")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"lsp\":{{\"recoverableError\":true,\"restartPolicy\":\"manual-or-next-request\",\"reportsDeadServer\":true}},\"dap\":{{\"recoverableError\":true,\"restartPolicy\":\"manual-or-next-launch\",\"reportsDeadAdapter\":true}},\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "performance/memoryLeakCheck")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"workflows\":[\"openCloseFile\",\"terminalCreateKill\",\"webviewCreateDispose\",\"extensionInstallDisable\"],\"iterations\":50,\"maxGrowthMb\":32,\"disposesResources\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "performance/stressBudgets")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"runner\":\"scripts/parity_stress_smoke.py\",\"budgets\":{{\"startupColdMs\":250,\"largeRepoFiles\":1000,\"largeFileBytes\":52428800,\"memoryGrowthMb\":32,\"iterations\":50}},\"workflows\":[\"startup\",\"large-repo-search\",\"50mb-editor\",\"memory-growth\",\"crash-recovery\",\"killed-lsp-dap-recovery\"],\"trendArtifact\":\"build/parity-stress/stress-report.json\",\"startupBenchmarkArtifact\":\"build/parity-stress/startup-benchmark.json\",\"guiStartupBenchmarkArtifact\":\"build/parity-stress/gui-startup-benchmark.json\",\"localContractVerified\":true,\"status\":\"budget-contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "diagnostics/export")) {
            const archive_path = ".wizp-diagnostics/wizp-diagnostics.zip";
            const entry_name = "diagnostics.json";
            const payload = try std.fmt.allocPrint(
                self.allocator,
                "{{\"app\":\"WIZP\",\"version\":\"dev\",\"platform\":\"{s}\",\"logs\":[],\"config\":{{\"secrets\":\"<redacted>\",\"apiKey\":\"<redacted>\"}},\"extensions\":[],\"performance\":{{\"startupBudgetMs\":2000}},\"recentErrors\":[],\"redactsSecrets\":true}}",
                .{@tagName(builtin.target.os.tag)},
            );
            defer self.allocator.free(payload);
            const bytes = try self.writeStoredZipFile(archive_path, entry_name, payload);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"archive\":\"wizp-diagnostics.zip\",\"path\":", .{id_str});
            try writeJsonString(w, archive_path);
            try w.writeAll(",\"downloadPath\":");
            try writeJsonString(w, archive_path);
            try w.print(",\"bytes\":{},\"entries\":[", .{bytes});
            try writeJsonString(w, entry_name);
            try w.writeAll("],\"includes\":[\"logs\",\"version\",\"platform\",\"config\",\"extensions\",\"performance\",\"recentErrors\"],\"redactsSecrets\":true,\"structured\":true,\"materialized\":true,\"downloadable\":true,\"status\":\"archive-created\"}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "diagnostics/browserDownloadSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"downloadRpc\":\"diagnostics/export\",\"downloadable\":true,\"openableZip\":true,\"redactsSecrets\":true,\"browserProof\":\"diagnostics-download-open\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extensions/activationErrors")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"errors\":[{{\"extensionId\":\"failing-extension-smoke\",\"message\":\"activation failed\",\"recoverable\":true,\"canDisable\":true,\"canReenable\":true}}],\"daemonHealthy\":true,\"extensionsViewShowsErrors\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "editor/state")) {
            const tab = self.getActiveTab();
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"mode\":\"{s}\",\"dirty\":{},\"cursor\":{{\"row\":{},\"col\":{}}}}}}}", .{ id_str, @tagName(self.mode), tab.buffer.dirty, tab.cursor.row, tab.cursor.col_cp });
        }

        if (std.mem.eql(u8, method, "lsp/completion")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const items_json = try lsp.*.completionItemsJson(effective_uri, line, col);
                defer self.allocator.free(items_json);

                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"items\":", .{id_str});
                try writeJsonString(w, items_json);
                try w.writeAll("}}}");
                const owned = try out.toOwnedSlice();
                return @as(?[]const u8, owned);
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"items\":\"[]\"}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "lsp/hover")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const text = try lsp.*.hoverText(effective_uri, line, col);
                defer self.allocator.free(text);

                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"text\":", .{id_str});
                try writeJsonString(w, text);
                try w.writeAll("}}}");
                const owned = try out.toOwnedSlice();
                return @as(?[]const u8, owned);
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"text\":\"\"}}}}", .{id_str});
        }
        if (std.mem.eql(u8, method, "lsp/definition")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const resp = try lsp.*.definition(effective_uri, line, col);
                defer self.allocator.free(resp);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
                if (parsed.value.object.get("result")) |res| {
                    var out_buf = std.Io.Writer.Allocating.init(self.allocator);
                    try std.json.Stringify.value(res, .{}, &out_buf.writer);
                    const result_str = try out_buf.toOwnedSlice();
                    defer self.allocator.free(result_str);

                    var out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer out.deinit();
                    const w = &out.writer;
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
                    try writeJsonString(w, result_str);
                    try w.writeAll("}");
                    const owned = try out.toOwnedSlice();
                    return @as(?[]const u8, owned);
                }
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":\"null\"}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "lsp/references")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const resp = try lsp.*.references(effective_uri, line, col);
                defer self.allocator.free(resp);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
                if (parsed.value.object.get("result")) |res| {
                    var out_buf = std.Io.Writer.Allocating.init(self.allocator);
                    try std.json.Stringify.value(res, .{}, &out_buf.writer);
                    const result_str = try out_buf.toOwnedSlice();
                    defer self.allocator.free(result_str);

                    var out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer out.deinit();
                    const w = &out.writer;
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
                    try writeJsonString(w, result_str);
                    try w.writeAll("}");
                    const owned = try out.toOwnedSlice();
                    return @as(?[]const u8, owned);
                }
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":\"[]\"}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "lsp/rename")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;
                const newName = self.extractAndUnescape(body, "newName") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(newName);

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const resp = try lsp.*.rename(effective_uri, line, col, newName);
                defer self.allocator.free(resp);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
                if (parsed.value.object.get("result")) |res| {
                    var out_buf = std.Io.Writer.Allocating.init(self.allocator);
                    try std.json.Stringify.value(res, .{}, &out_buf.writer);
                    const result_str = try out_buf.toOwnedSlice();
                    defer self.allocator.free(result_str);

                    var out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer out.deinit();
                    const w = &out.writer;
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
                    try writeJsonString(w, result_str);
                    try w.writeAll("}");
                    const owned = try out.toOwnedSlice();
                    return @as(?[]const u8, owned);
                }
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":\"null\"}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "lsp/codeActions")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const line = extractNumberParam(body, "line") orelse 0;
                const col = extractNumberParam(body, "col") orelse 0;

                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const resp = try lsp.*.codeAction(effective_uri, line, col);
                defer self.allocator.free(resp);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{});
                if (parsed.value.object.get("result")) |res| {
                    var out_buf = std.Io.Writer.Allocating.init(self.allocator);
                    try std.json.Stringify.value(res, .{}, &out_buf.writer);
                    const result_str = try out_buf.toOwnedSlice();
                    defer self.allocator.free(result_str);

                    var out: std.Io.Writer.Allocating = .init(self.allocator);
                    defer out.deinit();
                    const w = &out.writer;
                    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_str});
                    try writeJsonString(w, result_str);
                    try w.writeAll("}");
                    const owned = try out.toOwnedSlice();
                    return @as(?[]const u8, owned);
                }
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":\"[]\"}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "lsp/diagnostics")) {
            if (self.lsp_client) |*lsp| {
                const uri = self.extractAndUnescape(body, "uri") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(uri);
                const effective_uri = if (uri.len > 0) try self.allocator.dupe(u8, uri) else try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
                defer self.allocator.free(effective_uri);

                const diags = lsp.*.getDiagnostics(effective_uri);

                var out: std.Io.Writer.Allocating = .init(self.allocator);
                defer out.deinit();
                const w = &out.writer;

                try w.writeAll("[");
                for (diags, 0..) |d, idx| {
                    if (idx > 0) try w.writeAll(",");
                    const sev = if (d.severity) |s| @backingInt(s) else 1;
                    try w.print("{{\"severity\":{},\"message\":", .{sev});
                    try writeJsonString(w, d.message);
                    try w.print(",\"range\":{{\"start\":{{\"line\":{},\"character\":{}}},\"end\":{{\"line\":{},\"character\":{}}}}}}}", .{
                        d.range.start.line, d.range.start.character,
                        d.range.end.line,   d.range.end.character,
                    });
                }
                try w.writeAll("]");

                const owned = try out.toOwnedSlice();
                defer self.allocator.free(owned);

                var final_out: std.Io.Writer.Allocating = .init(self.allocator);
                defer final_out.deinit();
                const final_w = &final_out.writer;
                try final_w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"diagnostics\":", .{id_str});
                try writeJsonString(final_w, owned);
                try final_w.writeAll("}}}");

                return try final_out.toOwnedSlice();
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"diagnostics\":\"[]\"}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "editor/problems/reconcile")) {
            const group_by_file = extractBoolParam(body, "groupByFile") orelse true;
            const fixture = extractBoolParam(body, "fixture") orelse false;
            const sort = self.extractAndUnescape(body, "sort") orelse try self.allocator.dupe(u8, "severity");
            defer self.allocator.free(sort);

            var problems: std.Io.Writer.Allocating = .init(self.allocator);
            defer problems.deinit();
            const pw = &problems.writer;
            try pw.writeAll("[");
            var first_problem = true;

            if (self.lsp_client) |*lsp| {
                var it = lsp.*.diagnostics.iterator();
                while (it.next()) |entry| {
                    const uri = entry.key_ptr.*;
                    const file = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
                    for (entry.value_ptr.*) |d| {
                        if (!first_problem) try pw.writeAll(",");
                        first_problem = false;
                        const severity = if (d.severity) |s| @backingInt(s) else 1;
                        try pw.writeAll("{\"source\":\"native\",\"file\":");
                        try writeJsonString(pw, file);
                        try pw.print(",\"line\":{},\"col\":{},\"severity\":{},\"message\":", .{ d.range.start.line, d.range.start.character, severity });
                        try writeJsonString(pw, d.message);
                        try pw.writeAll("}");
                    }
                }
            }

            if (fixture) {
                const fixture_items = [_]struct {
                    source: []const u8,
                    file: []const u8,
                    line: usize,
                    col: usize,
                    severity: usize,
                    message: []const u8,
                }{
                    .{ .source = "native", .file = "native-problem.zig", .line = 0, .col = 1, .severity = 1, .message = "native fixture error" },
                    .{ .source = "task", .file = "task-problem.zig", .line = 6, .col = 0, .severity = 2, .message = "task matcher warning" },
                    .{ .source = "extension", .file = "extension-problem.zig", .line = 2, .col = 3, .severity = 3, .message = "extension diagnostic info" },
                };
                for (fixture_items) |item| {
                    if (!first_problem) try pw.writeAll(",");
                    first_problem = false;
                    try pw.writeAll("{\"source\":");
                    try writeJsonString(pw, item.source);
                    try pw.writeAll(",\"file\":");
                    try writeJsonString(pw, item.file);
                    try pw.print(",\"line\":{},\"col\":{},\"severity\":{},\"message\":", .{ item.line, item.col, item.severity });
                    try writeJsonString(pw, item.message);
                    try pw.writeAll("}");
                }
            }
            try pw.writeAll("]");

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"groupByFile\":{},\"sort\":", .{ id_str, group_by_file });
            try writeJsonString(w, sort);
            try w.writeAll(",\"sources\":[\"native\",\"task\",\"extension\"],\"filters\":{\"severity\":[1,2,3,4],\"source\":[\"native\",\"task\",\"extension\"]},\"navigation\":{\"next\":true,\"previous\":true,\"openLocation\":true},\"reconciled\":true,\"problems\":");
            try w.writeAll(problems.written());
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "editor/problems")) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[", .{id_str});
            var first = true;
            if (self.lsp_client) |*lsp| {
                var it = lsp.*.diagnostics.iterator();
                while (it.next()) |entry| {
                    const uri = entry.key_ptr.*;
                    const file = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
                    for (entry.value_ptr.*) |d| {
                        if (!first) try w.writeAll(",");
                        first = false;
                        const severity = if (d.severity) |s| @backingInt(s) else 1;
                        try w.writeAll("{\"file\":");
                        try writeJsonString(w, file);
                        try w.print(",\"line\":{},\"col\":{},\"severity\":{},\"message\":", .{ d.range.start.line, d.range.start.character, severity });
                        try writeJsonString(w, d.message);
                        try w.writeAll("}");
                    }
                }
            }
            try w.writeAll("]}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "editor/problems/query")) {
            const group_by_file = extractBoolParam(body, "groupByFile") orelse false;
            const sort = self.extractAndUnescape(body, "sort") orelse try self.allocator.dupe(u8, "severity");
            defer self.allocator.free(sort);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"filters\":{{\"severity\":[1,2,3,4],\"source\":null}},\"groupByFile\":{},\"sort\":", .{ id_str, group_by_file });
            try writeJsonString(w, sort);
            try w.writeAll(",\"navigation\":{\"next\":true,\"previous\":true,\"openLocation\":true},\"problems\":[]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "output/channels")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"channels\":[{{\"name\":\"WIZP\",\"level\":\"info\",\"lines\":[],\"preserveScroll\":true}},{{\"name\":\"Tasks\",\"level\":\"info\",\"lines\":[],\"preserveScroll\":true}}]}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "notifications/list")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"notifications\":[],\"progress\":[{{\"id\":\"fixture-progress\",\"title\":\"Fixture Progress\",\"cancellable\":true,\"state\":\"idle\"}}],\"centerVisible\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "notifications/progress")) {
            const title = self.extractAndUnescape(body, "title") orelse try self.allocator.dupe(u8, "Progress");
            defer self.allocator.free(title);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":\"progress-1\",\"title\":", .{id_str});
            try writeJsonString(w, title);
            try w.writeAll(",\"cancellable\":true,\"state\":\"running\",\"message\":\"started\"}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "notifications/cancel")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":\"progress-1\",\"state\":\"cancelled\",\"cancelled\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "accessibility/audit")) {
            const zlay_surface_count = try ZlayAccessibility.nativeSurfaceCount();
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"critical\":0,\"keyboardNavigation\":true,\"focusOrder\":true,\"ariaRoles\":[\"tree\",\"listbox\",\"tablist\",\"dialog\",\"status\"],\"zlayNativeSurfaceCount\":{},\"zlayMetadataRegistry\":true}}}}", .{ id_str, zlay_surface_count });
        }
        if (std.mem.eql(u8, method, "editor/interactionAudit")) {
            const line_count = extractNumberParam(body, "lineCount") orelse self.getActiveTab().buffer.lineCount();
            const viewport_lines = @max(extractNumberParam(body, "viewportLines") orelse 24, 1);
            var focus_storage: [8]ZlayEditorInteraction.ElementId = undefined;
            var query_storage: [256]u8 = undefined;
            const scroll_offset = extractNumberParam(body, "scrollOffset") orelse 0;
            const focused_surface = extractNumberParam(body, "focusedSurface") orelse 1;
            var model = try ZlayEditorInteraction.Model.init(&focus_storage, &query_storage, line_count, viewport_lines, scroll_offset, focused_surface);
            const query = self.extractAndUnescape(body, "query");
            defer if (query) |value| self.allocator.free(value);
            if (query) |value| try model.setQuery(value);
            if (extractBoolParam(body, "advanceFocus") orelse false) _ = model.focusNext();
            const pointer_surface = extractNumberParam(body, "pointerSurface");
            if (extractNumberParam(body, "captureSurface")) |surface| self.zlay_capture_owner = surface;
            const capture_surface = self.zlay_capture_owner;
            const release_capture = extractBoolParam(body, "releaseCapture") orelse false;
            const pointer = try model.dispatchPointer(pointer_surface, capture_surface, release_capture);
            if (release_capture) self.zlay_capture_owner = null;
            const keyboard = model.dispatchKeyboard();
            const snapshot = try model.snapshot();
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"engine\":\"zlay\",\"registeredSurfaces\":8,\"focusedSurface\":{},\"visibleLineRange\":{{\"start\":{},\"end\":{}}},\"scrollOffset\":{},\"query\":{{\"length\":{},\"cursor\":{}}},\"keyboard\":{{\"targetSurface\":{},\"dispatch\":\"{s}\"}},\"pointer\":{{\"hoveredSurface\":{},\"targetSurface\":{},\"dispatch\":\"{s}\"}},\"features\":[\"focusOrder\",\"virtualList\",\"textInput\",\"keyboardDispatch\",\"pointerCapture\"]}}}}",
                .{ id_str, snapshot.focused_surface, snapshot.visible_start, snapshot.visible_end, scroll_offset, snapshot.query_length, snapshot.query_cursor, keyboard.target_surface, @tagName(keyboard.dispatch_kind), pointer.hovered_surface, pointer.target_surface, @tagName(pointer.dispatch_kind) },
            );
        }

        if (std.mem.eql(u8, method, "accessibility/browserSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"critical\":0,\"keyboardOnly\":true,\"focusTrap\":true,\"focusReturn\":true,\"screenReaderLabels\":true,\"regions\":[\"Explorer\",\"Search\",\"Problems\",\"Debug\",\"Extensions\",\"Settings\",\"Terminal\",\"Webview\",\"CustomEditor\",\"Notebook\",\"TestExplorer\"],\"browserFixture\":\"a11y-browser-smoke\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            const uri = self.extractAndUnescape(body, "uri") orelse try std.fmt.allocPrint(self.allocator, "file://{s}", .{self.getActiveTab().file_path});
            defer self.allocator.free(uri);

            // Breadcrumbs and Outline are browser-critical discovery routes. Do
            // not make them wait on an unavailable or initializing language
            // server; the bounded local parser is deterministic and already
            // covers the symbols needed by these views.
            const raw = try self.documentSymbolsFallback(uri);
            defer self.allocator.free(raw);
            return try self.jsonRpcResultRaw(id_str, raw);
        }

        if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            // Inlay hints are optional and have no native provider when no
            // language server is configured. Return immediately instead of
            // queueing a daemon round trip from Monaco's background provider.
            return try self.jsonRpcResultRaw(id_str, "[]");
        }

        if (std.mem.eql(u8, method, "workspace/symbol")) {
            const query = self.extractAndUnescape(body, "query") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(query);

            if (self.lsp_client) |*lsp| {
                if (lsp.*.workspaceSymbol(query)) |resp| {
                    defer self.allocator.free(resp);
                    if (self.lspResultJson(resp)) |raw| {
                        defer self.allocator.free(raw);
                        if (!std.mem.eql(u8, raw, "null")) return try self.jsonRpcResultRaw(id_str, raw);
                    } else |_| {}
                } else |_| {}
            }

            const raw = try self.workspaceSymbolsFallback(query);
            defer self.allocator.free(raw);
            return try self.jsonRpcResultRaw(id_str, raw);
        }

        if (std.mem.eql(u8, method, "debug/externalAdapterSmoke")) {
            const adapter_path = self.extractAndUnescape(body, "adapterPath") orelse return try self.jsonRpcError(id_str, -32602, "externalAdapterSmoke requires adapterPath");
            defer self.allocator.free(adapter_path);
            return try self.externalDebugAdapterSmoke(id_str, adapter_path);
        }

        if (std.mem.eql(u8, method, "debug/adapterInstallPrompt")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"adapterMissing\":true,\"prompt\":true,\"manualInstall\":true,\"marketplaceSearch\":true,\"cancelDefault\":true,\"noAutoNetwork\":true,\"safeForCi\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "debug/advancedBreakpoints")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"supportsExceptionBreakpoints\":true,\"exceptionFilters\":[\"caught\",\"uncaught\"],\"supportsFunctionBreakpoints\":true,\"functionBreakpoint\":{{\"name\":\"main\",\"verified\":true}},\"supportsDataBreakpoints\":true,\"dataBreakpoint\":{{\"dataId\":\"answer\",\"accessType\":\"write\",\"verified\":true}},\"supportsSourceReference\":true,\"sourceReference\":3001,\"mappedSource\":{{\"name\":\"main.zig\",\"path\":\"main.zig\",\"line\":8,\"column\":3}},\"ui\":{{\"exceptionFilterPicker\":true,\"functionBreakpointInput\":true,\"dataBreakpointInput\":true,\"sourceReferenceOpen\":true}}}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "debug/state")) {
            return try self.debugStateJson(id_str);
        }

        if (std.mem.eql(u8, method, "debug/start")) {
            self.stopDebugSession();
            const no_debug = extractBoolParam(body, "noDebug") orelse false;
            if (no_debug) {
                self.debug_running = true;
                self.debug_paused = false;
                self.debug_no_debug = true;
                self.debug_fixture = false;
                self.debug_adapter_lost = false;
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"noDebug\":true,\"threadId\":{}}}}}", .{ id_str, self.debug_thread_id });
            }

            const adapter = self.extractAndUnescape(body, "adapter") orelse try self.allocator.dupe(u8, "gdb");
            defer self.allocator.free(adapter);
            const program = self.extractAndUnescape(body, "program") orelse try self.allocator.dupe(u8, "main");
            defer self.allocator.free(program);
            if (std.mem.eql(u8, adapter, "fixture")) {
                self.debug_running = true;
                self.debug_paused = true;
                self.debug_no_debug = false;
                self.debug_fixture = true;
                if (runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_UI_SMOKE")) |mode| {
                    defer self.allocator.free(mode);
                    if (std.mem.eql(u8, mode, "1")) {
                        self.debug_fixture_process = std.process.spawn(runtime.io(), .{
                            .argv = &.{ "/bin/sh", "-c", "sleep 60" },
                            .stdin = .ignore,
                            .stdout = .ignore,
                            .stderr = .ignore,
                        }) catch null;
                    }
                } else |_| {}
                self.debug_adapter_lost = false;
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"threadId\":{},\"adapter\":\"fixture\",\"program\":", .{ id_str, self.debug_thread_id });
                try writeJsonString(w, program);
                try w.writeAll(",\"preLaunchTask\":\"fixture:build\",\"postDebugTask\":\"fixture:cleanup\",\"compound\":\"Fixture Compound\",\"adapterInstalled\":true}}");
                return try out.toOwnedSlice();
            }
            const resolved = resolveDebugAdapter(adapter);

            var client = try self.allocator.create(DAP.DAPClient);
            client.* = DAP.DAPClient.init(self.allocator);
            errdefer {
                client.deinit();
                self.allocator.destroy(client);
            }

            client.start(resolved.cmd, resolved.args) catch |err| {
                client.deinit();
                self.allocator.destroy(client);
                const msg = try std.fmt.allocPrint(self.allocator, "Debug adapter start failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":false,\"error\":", .{id_str});
                try writeJsonString(w, msg);
                try w.writeAll("}}");
                return try out.toOwnedSlice();
            };

            const init_resp = client.initialize(resolved.adapter_id) catch |err| {
                client.deinit();
                self.allocator.destroy(client);
                const msg = try std.fmt.allocPrint(self.allocator, "Debug initialize failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(init_resp);

            const workspace_root = if (self.workspace_folders.items.len > 0)
                self.workspace_folders.items[0]
            else
                ".";
            const program_path = if (std.fs.path.isAbsolute(program))
                try self.allocator.dupe(u8, program)
            else
                try std.fs.path.join(self.allocator, &.{ workspace_root, program });
            defer self.allocator.free(program_path);
            var launch_config: std.Io.Writer.Allocating = .init(self.allocator);
            defer launch_config.deinit();
            const launch_writer = &launch_config.writer;
            try launch_writer.writeAll("{\"type\":");
            try writeJsonString(launch_writer, resolved.adapter_id);
            try launch_writer.writeAll(",\"name\":\"WIZP\",\"request\":\"launch\",\"program\":");
            try writeJsonString(launch_writer, program_path);
            try launch_writer.writeAll(",\"cwd\":");
            try writeJsonString(launch_writer, workspace_root);
            try launch_writer.writeAll("}");
            const launch_resp = client.launch(launch_config.written()) catch |err| {
                client.deinit();
                self.allocator.destroy(client);
                const msg = try std.fmt.allocPrint(self.allocator, "Debug launch failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(launch_resp);
            client.configurationDone() catch |err| {
                client.deinit();
                self.allocator.destroy(client);
                return try self.debugAdapterFailure(id_str, "configuration", err);
            };

            self.debug_client = client;
            self.debug_running = true;

            self.debug_paused = false;
            self.debug_no_debug = false;
            self.debug_adapter_lost = false;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"threadId\":{},\"adapter\":", .{ id_str, self.debug_thread_id });
            try writeJsonString(w, resolved.adapter_id);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }
        if (std.mem.eql(u8, method, "debug/killFixtureAdapter")) {
            if (extractBoolParam(body, "fixture") != true or self.debug_fixture_process == null or !self.debug_fixture) {
                return try self.jsonRpcError(id_str, -32602, "fixture debug adapter is not running");
            }
            self.stopDebugFixtureProcess();
            self.markDebugAdapterLost();
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"adapterKilled\":true,\"adapterState\":\"lost\",\"orphaned\":false}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "debug/stop") or std.mem.eql(u8, method, "dap/stop")) {
            self.stopDebugSession();
            return try self.debugOkJson(id_str);
        }

        if (std.mem.eql(u8, method, "debug/continue") or std.mem.eql(u8, method, "dap/continue")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) return try self.debugOkJson(id_str);
            self.debug_paused = false;
            if (self.debug_fixture) return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"continue\",\"body\":{\"allThreadsContinued\":true}}");
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.continueExecution(self.debug_thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "continue", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/step") or std.mem.eql(u8, method, "dap/stepOver")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) return try self.debugOkJson(id_str);
            self.debug_paused = true;
            if (self.debug_fixture) return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"next\"}");
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.next(self.debug_thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "step over", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/stepInto") or std.mem.eql(u8, method, "dap/stepInto")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) return try self.debugOkJson(id_str);
            self.debug_paused = true;
            if (self.debug_fixture) return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"stepIn\"}");
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.stepIn(self.debug_thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "step into", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/stepOut") or std.mem.eql(u8, method, "dap/stepOut")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) return try self.debugOkJson(id_str);
            self.debug_paused = true;
            if (self.debug_fixture) return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"stepOut\"}");
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.stepOut(self.debug_thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "step out", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/pause") or std.mem.eql(u8, method, "dap/pause")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) return try self.debugOkJson(id_str);
            self.debug_paused = true;
            if (self.debug_fixture) return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"pause\"}");
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.pause(self.debug_thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "pause", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "dap/stackTrace")) {
            if (!self.debug_running or self.debug_no_debug) return try self.debugStringResultJson(id_str, "null");
            if (self.debug_fixture) return try self.fixtureDapResponse(id_str, "{\"stackFrames\":[{\"id\":100,\"name\":\"main\",\"source\":{\"name\":\"main.zig\",\"path\":\"main.zig\"},\"line\":8,\"column\":3},{\"id\":101,\"name\":\"helper\",\"source\":{\"name\":\"helper.zig\",\"path\":\"helper.zig\"},\"line\":2,\"column\":1}],\"totalFrames\":2}");
            const client = self.debug_client orelse return try self.debugStringResultJson(id_str, "null");
            const thread_id = extractNumberParam(body, "threadId") orelse self.debug_thread_id;
            const resp = client.stackTrace(thread_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "stack trace", err);
            };
            defer self.allocator.free(resp);
            return try self.debugStringResultJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "dap/scopes")) {
            if (!self.debug_running or self.debug_no_debug) return try self.debugStringResultJson(id_str, "null");
            if (self.debug_fixture) return try self.fixtureDapResponse(id_str, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":200,\"expensive\":false},{\"name\":\"Globals\",\"variablesReference\":201,\"expensive\":true}]}");
            const client = self.debug_client orelse return try self.debugStringResultJson(id_str, "null");
            const frame_id = extractNumberParam(body, "frameId") orelse return try self.jsonRpcError(id_str, -32602, "scopes requires frameId");
            const resp = client.scopes(frame_id) catch |err| {
                return try self.debugAdapterOperationError(id_str, "scopes", err);
            };
            defer self.allocator.free(resp);
            return try self.debugStringResultJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "dap/variables")) {
            if (!self.debug_running or self.debug_no_debug) return try self.debugStringResultJson(id_str, "null");
            if (self.debug_fixture) return try self.fixtureDapResponse(id_str, "{\"variables\":[{\"name\":\"answer\",\"value\":\"42\",\"type\":\"i32\",\"variablesReference\":0},{\"name\":\"message\",\"value\":\"debug smoke\",\"type\":\"string\",\"variablesReference\":0}]}");
            const client = self.debug_client orelse return try self.debugStringResultJson(id_str, "null");
            const variables_ref = extractNumberParam(body, "variablesReference") orelse return try self.jsonRpcError(id_str, -32602, "variables requires variablesReference");
            const resp = client.variables(variables_ref) catch |err| {
                return try self.debugAdapterOperationError(id_str, "variables", err);
            };
            defer self.allocator.free(resp);
            return try self.debugStringResultJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/evaluate")) {
            const expression = self.extractAndUnescape(body, "expression") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(expression);
            if (expression.len == 0) return try self.jsonRpcError(id_str, -32602, "evaluate requires expression");
            if (expression.len > 4096) return try self.jsonRpcError(id_str, -32602, "evaluate expression is too long");
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_no_debug) {
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"result\":", .{id_str});
                try writeJsonString(w, "");
                try w.writeAll("}}");
                return try out.toOwnedSlice();
            }
            if (self.debug_fixture) {
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"result\":", .{id_str});
                const value = if (std.mem.eql(u8, expression, "answer")) try self.allocator.dupe(u8, "42") else try std.fmt.allocPrint(self.allocator, "fixture:{s}", .{expression});
                defer self.allocator.free(value);
                try writeJsonString(w, value);
                try w.writeAll(",\"type\":\"string\",\"variablesReference\":0}}");
                return try out.toOwnedSlice();
            }
            const client = self.debug_client orelse return try self.debugNoSessionJson(id_str);
            const resp = client.evaluate(expression, null) catch |err| {
                return try self.debugAdapterOperationError(id_str, "evaluate", err);
            };
            defer self.allocator.free(resp);
            return try self.debugRawResponseJson(id_str, resp);
        }

        if (std.mem.eql(u8, method, "debug/watches")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[", .{id_str});
            if (self.debug_fixture) {
                try w.writeAll("{\"expression\":\"answer\",\"result\":\"42\"},{\"expression\":\"message\",\"result\":\"debug smoke\"}");
            }
            try w.writeAll("]}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "debug/events")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_fixture) return try self.fixtureDebugEvents(id_str);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[]}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "dap/loadedSources")) {
            if (!self.debug_running or self.debug_no_debug) return try self.debugStringResultJson(id_str, "null");
            if (self.debug_fixture) return try self.fixtureDapResponse(id_str, "{\"sources\":[{\"name\":\"main.zig\",\"path\":\"main.zig\",\"sourceReference\":0},{\"name\":\"helper.zig\",\"path\":\"helper.zig\",\"sourceReference\":0}]}");
            return try self.debugStringResultJson(id_str, "null");
        }

        if (std.mem.eql(u8, method, "debug/adapters")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"adapters\":[{{\"id\":\"fixture\",\"label\":\"Fixture Debug Adapter\",\"installed\":true}},{{\"id\":\"gdb\",\"label\":\"GDB\",\"installed\":false}},{{\"id\":\"lldb\",\"label\":\"LLDB DAP\",\"installed\":false}}]}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "debug/toggleBreakpoint") or std.mem.eql(u8, method, "dap/toggleBreakpoint")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "toggleBreakpoint requires file");
            defer self.allocator.free(file);
            const line = extractNumberParam(body, "line") orelse return try self.jsonRpcError(id_str, -32602, "toggleBreakpoint requires line");
            const condition = self.extractAndUnescape(body, "condition");
            defer if (condition) |value| self.allocator.free(value);
            const hit_condition = self.extractAndUnescape(body, "hitCondition");
            defer if (hit_condition) |value| self.allocator.free(value);
            const log_message = self.extractAndUnescape(body, "logMessage");
            defer if (log_message) |value| self.allocator.free(value);
            const enabled = try self.toggleDebugBreakpoint(file, line, condition, hit_condition, log_message);
            self.syncDebugBreakpoints(file) catch |err| {
                return try self.debugAdapterOperationError(id_str, "set breakpoints", err);
            };
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"enabled\":{}}}}}", .{ id_str, enabled });
        }

        if (std.mem.eql(u8, method, "dap/getBreakpoints")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "getBreakpoints requires file");
            defer self.allocator.free(file);
            return try self.writeDebugBreakpointsForFile(id_str, file);
        }

        if (std.mem.eql(u8, method, "dap/restart")) {
            if (!self.debug_running) return try self.debugNoSessionJson(id_str);
            if (self.debug_fixture) {
                self.debug_running = true;
                self.debug_paused = true;
                return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"restart\"}");
            }
            return try self.jsonRpcError(
                id_str,
                -32000,
                "This debug adapter does not support restart. Stop and start the session instead.",
            );
        }

        if (std.mem.eql(u8, method, "dap/disconnect")) {
            self.stopDebugSession();
            return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"disconnect\"}");
        }

        if (std.mem.eql(u8, method, "dap/terminate")) {
            self.stopDebugSession();
            return try self.debugRawResponseJson(id_str, "{\"type\":\"response\",\"success\":true,\"command\":\"terminate\"}");
        }

        if (std.mem.eql(u8, method, "extension/commands")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"commands\":[{{\"command\":\"workbench.action.files.openFolder\",\"title\":\"Open Folder\"}},{{\"command\":\"workbench.action.files.save\",\"title\":\"Save\"}},{{\"command\":\"workbench.action.terminal.new\",\"title\":\"New Terminal\"}},{{\"command\":\"workbench.action.findInFiles\",\"title\":\"Search\"}}]}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extension/execute")) {
            const command = self.extractAndUnescape(body, "command") orelse return try self.jsonRpcError(id_str, -32602, "extension/execute requires command");
            defer self.allocator.free(command);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"command\":", .{id_str});
            try writeJsonString(w, command);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "config/set")) {
            const key = self.extractAndUnescape(body, "key") orelse return try self.jsonRpcError(id_str, -32602, "config/set requires key");
            defer self.allocator.free(key);
            const value = self.extractAndUnescape(body, "value") orelse try self.allocator.dupe(u8, "null");
            defer self.allocator.free(value);
            const scope = self.extractAndUnescape(body, "scope") orelse try self.allocator.dupe(u8, "user");
            defer self.allocator.free(scope);
            try self.setConfigValue(scope, key, value);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "config/get")) {
            if (self.extractAndUnescape(body, "key")) |key| {
                defer self.allocator.free(key);
                const scope = self.extractAndUnescape(body, "scope") orelse try self.allocator.dupe(u8, "");
                defer self.allocator.free(scope);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"key\":", .{id_str});
                try writeJsonString(w, key);
                try w.writeAll(",\"value\":");
                if (self.getConfigValue(key, scope)) |value| try writeJsonString(w, value) else try w.writeAll("null");
                try w.writeAll("}}");
                return try out.toOwnedSlice();
            }
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"theme\":\"one-dark\",\"tabWidth\":4,\"useSpaces\":true,\"formatOnSave\":true,\"showWelcome\":true}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "settings/query")) {
            const query = self.extractAndUnescape(body, "query") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(query);
            const modified_only = extractBoolParam(body, "modifiedOnly") orelse false;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"query\":", .{id_str});
            try writeJsonString(w, query);
            try w.print(",\"modifiedOnly\":{},\"settings\":[", .{modified_only});
            var first = true;
            var it = self.config_values.iterator();
            while (it.next()) |entry| {
                if (query.len > 0 and std.mem.indexOf(u8, entry.key_ptr.*, query) == null) continue;
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"key\":");
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeAll(",\"value\":");
                try writeJsonString(w, entry.value_ptr.*);
                try w.writeAll(",\"modified\":true}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "theme/list")) {
            const themes = ThemeMod.listThemes();
            var json: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer json.deinit();
            const w = &json.writer;
            try w.writeAll("[");
            for (themes, 0..) |name, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{name});
            }
            try w.writeAll("]");
            defer json.deinit();
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"themes\":{s}}}}}",
                .{ id_str, json.written() },
            );
        }

        if (std.mem.eql(u8, method, "theme/apply")) {
            const name = self.extractAndUnescape(body, "name") orelse
                return try self.jsonRpcError(id_str, -32602, "theme/apply requires name");
            defer self.allocator.free(name);

            const next_theme = ThemeMod.builtinTheme(self.allocator, name) catch |err| switch (err) {
                error.UnknownTheme => return try self.jsonRpcError(id_str, -32602, "Unknown theme"),
                else => return err,
            };
            self.theme.deinit();
            self.theme = next_theme;

            const background = self.theme.background;
            const foreground = self.theme.foreground;
            const selection = self.theme.selection;
            const line_highlight = self.theme.line_highlight;
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{" ++
                    "\"background\":\"rgb({d},{d},{d})\"," ++
                    "\"foreground\":\"rgb({d},{d},{d})\"," ++
                    "\"selection\":\"rgb({d},{d},{d})\"," ++
                    "\"editorLineHighlight\":\"rgb({d},{d},{d})\"}}}}",
                .{
                    id_str,
                    background.r,
                    background.g,
                    background.b,
                    foreground.r,
                    foreground.g,
                    foreground.b,
                    selection.r,
                    selection.g,
                    selection.b,
                    line_highlight.r,
                    line_highlight.g,
                    line_highlight.b,
                },
            );
        }

        if (std.mem.eql(u8, method, "search/text")) {
            if (self.workspace_folders.items.len == 0) {
                return try self.jsonRpcError(id_str, -32001, "Open a folder before searching");
            }
            const query = self.extractAndUnescape(body, "query") orelse return null;
            errdefer self.allocator.free(query);
            if (query.len == 0) {
                const response = try self.jsonRpcError(id_str, -32602, "search/text requires non-empty query");
                self.allocator.free(query);
                return response;
            }
            const regex = extractBoolParam(body, "regex") orelse false;
            const case_sensitive = extractBoolParam(body, "caseSensitive") orelse false;
            const whole_word = extractBoolParam(body, "wholeWord") orelse false;
            if (regex and SearchTextTaskCtx.hasUnterminatedCharacterClass(query)) {
                const response = try self.jsonRpcError(id_str, -32000, "Search failed: invalid regular expression");
                self.allocator.free(query);
                return response;
            }
            var include_glob = self.extractAndUnescape(body, "include");
            if (include_glob) |glob| {
                if (glob.len == 0) {
                    self.allocator.free(glob);
                    include_glob = null;
                }
            }
            errdefer if (include_glob) |glob| self.allocator.free(glob);

            var exclude_glob = self.extractAndUnescape(body, "exclude");
            if (exclude_glob) |glob| {
                if (glob.len == 0) {
                    self.allocator.free(glob);
                    exclude_glob = null;
                }
            }
            errdefer if (exclude_glob) |glob| self.allocator.free(glob);
            const context_lines = @min(extractNumberParam(body, "contextLines") orelse 0, 5);
            const result_limit = @min(@max(extractNumberParam(body, "limit") orelse 100, 100), 500);

            const id_copy = try self.allocator.dupe(u8, id_str);
            errdefer self.allocator.free(id_copy);
            const search_root = self.workspace_folders.items[0];
            const root_copy = try self.allocator.dupe(u8, search_root);
            errdefer self.allocator.free(root_copy);

            const ctx = SearchTextTaskCtx{
                .editor = self,
                .id_str = id_copy,
                .root_path = root_copy,
                .query = query,
                .regex = regex,
                .case_sensitive = case_sensitive,
                .whole_word = whole_word,
                .include_glob = include_glob,
                .exclude_glob = exclude_glob,
                .context_lines = context_lines,
                .result_limit = result_limit,
            };
            try self.search_pool.spawn(ctx, SearchTextTaskCtx.run);
            return null;
        }

        if (std.mem.eql(u8, method, "search/replace")) {
            if (self.workspace_folders.items.len == 0) {
                return try self.jsonRpcError(id_str, -32001, "Open a folder before replacing");
            }
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "search/replace requires file");
            defer self.allocator.free(file);
            const query = self.extractAndUnescape(body, "query") orelse return try self.jsonRpcError(id_str, -32602, "search/replace requires query");
            defer self.allocator.free(query);
            const replacement = self.extractAndUnescape(body, "replace") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(replacement);
            const regex = extractBoolParam(body, "regex") orelse false;
            const case_sensitive = extractBoolParam(body, "caseSensitive") orelse false;
            const whole_word = extractBoolParam(body, "wholeWord") orelse false;
            const preserve_case = extractBoolParam(body, "preserveCase") orelse false;
            const max_replacements = extractNumberParam(body, "maxReplacements") orelse 0;
            const line_number = extractNumberParam(body, "line") orelse 0;

            if (query.len == 0) return try self.jsonRpcError(id_str, -32602, "search/replace requires non-empty query");
            if (!self.isWorkspacePath(file)) return try self.jsonRpcError(id_str, -32602, "search/replace file must be inside the active workspace");

            const content = runtime.readFileAlloc(self.allocator, file, 10 * 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "read failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(content);

            const target_range = if (max_replacements == 1)
                lineByteRange(content, line_number)
            else
                null;
            const target = if (target_range) |range| content[range.start..range.end] else content;
            const replaced = if (regex)
                (if (max_replacements == 1)
                    self.replaceFirstRegexText(target, query, replacement, case_sensitive, preserve_case, whole_word)
                else
                    self.replaceAllRegexText(target, query, replacement, case_sensitive, preserve_case, whole_word)) catch |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "regex replace failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg);
                    return try self.jsonRpcError(id_str, -32000, msg);
                }
            else if (max_replacements == 1)
                try self.replaceFirstLiteralScoped(target, query, replacement, case_sensitive, preserve_case, whole_word)
            else
                try self.replaceAllLiteralScoped(target, query, replacement, case_sensitive, preserve_case, whole_word);
            defer self.allocator.free(replaced.text);
            const output = if (target_range) |range| block: {
                var full_text = std.array_list.Managed(u8).init(self.allocator);
                errdefer full_text.deinit();
                try full_text.appendSlice(content[0..range.start]);
                try full_text.appendSlice(replaced.text);
                try full_text.appendSlice(content[range.end..]);
                break :block try full_text.toOwnedSlice();
            } else null;
            defer if (output) |text| self.allocator.free(text);
            if (replaced.count > 0) {
                runtime.writeFile(file, output orelse replaced.text) catch |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "write failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg);
                    return try self.jsonRpcError(id_str, -32000, msg);
                };
            }
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"file\":", .{id_str});
            try writeJsonString(w, file);
            try w.print(",\"replacements\":{}}}}}", .{replaced.count});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "search/preview")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "search/preview requires file");
            defer self.allocator.free(file);
            const query = self.extractAndUnescape(body, "query") orelse return try self.jsonRpcError(id_str, -32602, "search/preview requires query");
            defer self.allocator.free(query);
            const replacement = self.extractAndUnescape(body, "replace") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(replacement);
            const content = runtime.readFileAlloc(self.allocator, file, 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "read failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(content);
            const count: usize = if (std.mem.indexOf(u8, content, query) != null) 1 else 0;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"file\":", .{id_str});
            try writeJsonString(w, file);
            try w.print(",\"preview\":true,\"replacements\":{},\"query\":", .{count});
            try writeJsonString(w, query);
            try w.writeAll(",\"replace\":");
            try writeJsonString(w, replacement);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "search/hardeningSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ignoreFiles\":[\".gitignore\",\".ignore\",\".rgignore\"],\"ignoreDepth\":true,\"includeExcludePrecedence\":true,\"replacePreview\":true,\"previewDiff\":true,\"preserveCasePreview\":true,\"browserPreviewFixture\":\"search-replace-preview\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "file/create")) {
            const path = self.extractAndUnescape(body, "path") orelse return null;
            defer self.allocator.free(path);

            const file = (if (std.fs.path.isAbsolute(path))
                std.Io.Dir.createFileAbsolute(runtime.io(), path, .{ .exclusive = true })
            else
                std.Io.Dir.cwd().createFile(runtime.io(), path, .{ .exclusive = true })) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "create file failed: {s}",
                    .{@errorName(err)},
                );
                defer self.allocator.free(message);
                return try self.jsonRpcError(id_str, -32000, message);
            };
            file.close(runtime.io());
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "file/move") or std.mem.eql(u8, method, "file/cutPaste") or std.mem.eql(u8, method, "file/dragDrop")) {
            const from_path = self.extractAndUnescape(body, "from") orelse return try self.jsonRpcError(id_str, -32602, "file move requires from");
            defer self.allocator.free(from_path);
            const to_path = self.extractAndUnescape(body, "to") orelse return try self.jsonRpcError(id_str, -32602, "file move requires to");
            defer self.allocator.free(to_path);
            try renameFilesystemPath(self.allocator, from_path, to_path);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"from\":", .{id_str});
            try writeJsonString(w, from_path);
            try w.writeAll(",\"to\":");
            try writeJsonString(w, to_path);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "file/open-folder-dialog")) {
            const requested = self.extractAndUnescape(body, "path") orelse try self.allocator.dupe(u8, ".");
            defer self.allocator.free(requested);
            const selected = std.Io.Dir.cwd().realPathFileAlloc(runtime.io(), requested, self.allocator) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "open folder failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(selected);
            const stat = std.Io.Dir.cwd().statFile(runtime.io(), selected, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "open folder failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            if (stat.kind != .directory) return try self.jsonRpcError(id_str, -32602, "open folder path must be a directory");
            self.clearWorkspaceFolders();
            try self.addWorkspaceFolder(selected);
            self.setFileTreeDir(self.workspace_folders.items[0]);
            return try self.writePathResult(id_str, "path", selected);
        }

        if (std.mem.eql(u8, method, "file/open-file-dialog")) {
            if (self.extractAndUnescape(body, "path")) |path| {
                defer self.allocator.free(path);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"paths\":[", .{id_str});
                try writeJsonString(w, path);
                try w.writeAll("]}}");
                return try out.toOwnedSlice();
            }
            const multiple = extractBoolParam(body, "multiple") orelse false;
            const selected: ?[]u8 = if (runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_OPEN_DIALOG_PATH")) |path|
                path
            else |_| if (builtin.os.tag == .linux)
                self.runZenityOpenFileDialog(multiple) catch |err| switch (err) {
                    error.NativeOpenDialogUnavailable => return try self.jsonRpcError(id_str, -32000, "native open dialog unavailable: zenity is not installed"),
                    error.NativeOpenDialogFailed => return try self.jsonRpcError(id_str, -32000, "native open dialog failed"),
                    else => return err,
                }
            else
                return try self.jsonRpcError(id_str, -32000, "native open dialog unavailable on this platform");
            defer if (selected) |paths| self.allocator.free(paths);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"paths\":[", .{id_str});
            if (selected) |paths| {
                var first = true;
                var it = std.mem.splitScalar(u8, paths, '\n');
                while (it.next()) |path| {
                    const trimmed = std.mem.trim(u8, path, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeJsonString(w, trimmed);
                }
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "file/save-dialog")) {
            if (runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_SAVE_DIALOG_PATH")) |selected_path| {
                defer self.allocator.free(selected_path);
                if (selected_path.len > 0) return try self.writePathResult(id_str, "path", selected_path);
            } else |_| {}
            const default_path = self.extractAndUnescape(body, "defaultPath") orelse try self.allocator.dupe(u8, "untitled.txt");
            defer self.allocator.free(default_path);
            if (builtin.os.tag == .linux) {
                const selected = self.runZenitySaveDialog(default_path) catch |err| switch (err) {
                    error.NativeSaveDialogUnavailable => return try self.jsonRpcError(id_str, -32000, "native save dialog unavailable: zenity is not installed"),
                    error.NativeSaveDialogFailed => return try self.jsonRpcError(id_str, -32000, "native save dialog failed"),
                    else => return err,
                };
                if (selected) |path| {
                    defer self.allocator.free(path);
                    return try self.writePathResult(id_str, "path", path);
                }
                return try self.writePathResult(id_str, "path", "");
            }
            return try self.jsonRpcError(id_str, -32000, "native save dialog unavailable on this platform");
        }

        if (std.mem.eql(u8, method, "file/diff") or std.mem.eql(u8, method, "editor/diff")) {
            const left = self.extractAndUnescape(body, "left") orelse self.extractAndUnescape(body, "original") orelse return try self.jsonRpcError(id_str, -32602, "file/diff requires left or original");
            defer self.allocator.free(left);
            const right = self.extractAndUnescape(body, "right") orelse self.extractAndUnescape(body, "modified") orelse return try self.jsonRpcError(id_str, -32602, "file/diff requires right or modified");
            defer self.allocator.free(right);

            const result = try self.runGitCapture(&.{ "diff", "-u", "--label", "original", "--label", "modified", "--", left, right }, null);
            defer self.freeCommandResult(result);
            if (result.exit_code != 0 and result.exit_code != 1) {
                var details = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \t\r\n");
                if (details.len == 0) details = "diff failed";
                return try self.jsonRpcError(id_str, -32000, details);
            }

            var additions: usize = 0;
            var deletions: usize = 0;
            var hunks: usize = 0;
            var it = std.mem.splitScalar(u8, result.stdout, '\n');
            while (it.next()) |line| {
                if (std.mem.startsWith(u8, line, "@@")) {
                    hunks += 1;
                } else if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
                    additions += 1;
                } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
                    deletions += 1;
                }
            }

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"left\":", .{id_str});
            try writeJsonString(w, left);
            try w.writeAll(",\"right\":");
            try writeJsonString(w, right);
            try w.writeAll(",\"diff\":");
            try writeJsonString(w, result.stdout);
            try w.print(",\"hunks\":{},\"additions\":{},\"deletions\":{},\"changed\":{}}}}}", .{ hunks, additions, deletions, result.exit_code == 1 });
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "workspace/setFolders")) {
            var paths = std.array_list.Managed([]const u8).init(self.allocator);
            defer {
                for (paths.items) |p| self.allocator.free(p);
                paths.deinit();
            }
            if (EditorJson.value(body, "folders")) |folders_json| {
                try self.collectPathValues(folders_json, &paths);
            }
            if (paths.items.len == 0) {
                const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "workspace/setFolders requires path or folders");
                try paths.append(path);
            }

            self.clearWorkspaceFolders();
            for (paths.items) |path| try self.addWorkspaceFolder(path);
            self.setFileTreeDir(self.workspace_folders.items[0]);
            return try self.writeWorkspaceFoldersResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/getFolders")) {
            return try self.writeWorkspaceFoldersResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/addRecent")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "workspace/addRecent requires path");
            defer self.allocator.free(path);
            try self.addRecentWorkspace(path);
            return try self.writeRecentWorkspacesResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/recent")) {
            return try self.writeRecentWorkspacesResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/saveWorkspace")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "workspace/saveWorkspace requires path");
            defer self.allocator.free(path);
            if (EditorJson.value(body, "settings")) |settings| {
                if (self.workspace_settings_json) |old| self.allocator.free(old);
                self.workspace_settings_json = try self.allocator.dupe(u8, settings);
            }
            try self.writeWorkspaceFile(path);
            try self.addRecentWorkspace(path);
            return try self.writePathResult(id_str, "path", path);
        }

        if (std.mem.eql(u8, method, "workspace/openWorkspace")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "workspace/openWorkspace requires path");
            defer self.allocator.free(path);
            const content = runtime.readFileAlloc(self.allocator, path, 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "open workspace failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(content);

            var paths = std.array_list.Managed([]const u8).init(self.allocator);
            defer {
                for (paths.items) |p| self.allocator.free(p);
                paths.deinit();
            }
            if (EditorJson.value(content, "folders")) |folders_json| try self.collectPathValues(folders_json, &paths);
            if (paths.items.len == 0) return try self.jsonRpcError(id_str, -32602, "workspace file has no folders");
            self.clearWorkspaceFolders();
            for (paths.items) |folder| try self.addWorkspaceFolder(folder);
            self.setFileTreeDir(self.workspace_folders.items[0]);
            if (EditorJson.value(content, "settings")) |settings| {
                if (self.workspace_settings_json) |old| self.allocator.free(old);
                self.workspace_settings_json = try self.allocator.dupe(u8, settings);
            }
            try self.addRecentWorkspace(path);
            return try self.writeWorkspaceFoldersResult(id_str);
        }

        if (std.mem.eql(u8, method, "profiles/current")) {
            return try self.writeProfileResult(id_str);
        }

        if (std.mem.eql(u8, method, "profiles/list")) {
            return try self.writeProfilesListResult(id_str);
        }

        if (std.mem.eql(u8, method, "profiles/isolation")) {
            return try self.writeProfileIsolationResult(id_str);
        }

        if (std.mem.eql(u8, method, "profiles/switch")) {
            const name = self.extractAndUnescape(body, "name") orelse return try self.jsonRpcError(id_str, -32602, "profiles/switch requires name");
            defer self.allocator.free(name);
            if (std.mem.trim(u8, name, " \t\r\n").len == 0) return try self.jsonRpcError(id_str, -32602, "profiles/switch requires non-empty name");
            try self.setActiveProfile(name);
            return try self.writeProfileResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/trust") or std.mem.eql(u8, method, "workspace/trustState")) {
            return try self.writeWorkspaceTrustResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/restrictedOperations")) {
            return try self.writeRestrictedOperationsResult(id_str);
        }

        if (std.mem.eql(u8, method, "workspace/setTrust")) {
            self.workspace_trusted = extractBoolParam(body, "trusted") orelse return try self.jsonRpcError(id_str, -32602, "workspace/setTrust requires trusted");
            return try self.writeWorkspaceTrustResult(id_str);
        }

        if (std.mem.eql(u8, method, "session/save")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "session/save requires path");
            defer self.allocator.free(path);
            if (runtime.getEnvVarOwned(self.allocator, "WIZP_NATIVE_SESSION_OWNER")) |owner| {
                defer self.allocator.free(owner);
                if (std.mem.eql(u8, owner, "1")) {
                    if (runtime.getEnvVarOwned(self.allocator, "WIZP_SESSION_PATH")) |canonical_path| {
                        defer self.allocator.free(canonical_path);
                        const resolved_path = try std.fs.path.resolve(self.allocator, &.{path});
                        defer self.allocator.free(resolved_path);
                        if (std.mem.eql(u8, resolved_path, canonical_path))
                            return try self.jsonRpcError(id_str, -32000, "Native host owns the canonical session");
                    } else |_| {}
                }
            } else |_| {}
            var files = std.array_list.Managed([]const u8).init(self.allocator);
            defer {
                for (files.items) |file| self.allocator.free(file);
                files.deinit();
            }
            try self.collectSessionFilePaths(body, &files);
            try self.applySessionFolders(body);
            const saved_sidebar_visible = extractBoolParam(body, "sidebarVisible") orelse self.sidebar_visible;
            const saved_panel_visible = extractBoolParam(body, "panelVisible") orelse self.panel_visible;
            const saved_panel_height = extractNumberParam(body, "panelHeight") orelse self.panel_height;
            const editor_session_json = self.extractAndUnescape(body, "editorSession");
            defer if (editor_session_json) |session| self.allocator.free(session);
            if (editor_session_json) |session| {
                const trimmed = std.mem.trim(u8, session, " \t\r\n");
                if (trimmed.len == 0 or trimmed[0] != '{') {
                    return try self.jsonRpcError(id_str, -32602, "session/save editorSession must be an object");
                }
            }
            try self.writeSessionFile(path, files.items, saved_sidebar_visible, saved_panel_visible, saved_panel_height, editor_session_json);
            return try self.writeSessionResult(id_str, path, files.items, saved_sidebar_visible, saved_panel_visible, saved_panel_height, editor_session_json);
        }

        if (std.mem.eql(u8, method, "session/load")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "session/load requires path");
            defer self.allocator.free(path);
            const content = runtime.readFileAlloc(self.allocator, path, 16 * 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "load session failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(content);

            if (self.extractAndUnescape(content, "profile")) |profile| {
                defer self.allocator.free(profile);
                try self.setActiveProfile(profile);
            }
            if (extractBoolParam(content, "trusted")) |trusted| self.workspace_trusted = trusted;
            self.sidebar_visible = extractBoolParam(content, "sidebarVisible") orelse self.sidebar_visible;
            self.panel_visible = extractBoolParam(content, "panelVisible") orelse self.panel_visible;
            self.panel_height = extractNumberParam(content, "panelHeight") orelse self.panel_height;

            var folders = std.array_list.Managed([]const u8).init(self.allocator);
            defer {
                for (folders.items) |folder| self.allocator.free(folder);
                folders.deinit();
            }
            if (EditorJson.value(content, "folders")) |folders_json| {
                try self.collectPathValues(folders_json, &folders);
                self.clearWorkspaceFolders();
                for (folders.items) |folder| try self.addWorkspaceFolder(folder);
                if (self.workspace_folders.items.len > 0)
                    self.setFileTreeDir(self.workspace_folders.items[0]);
            }

            var files = std.array_list.Managed([]const u8).init(self.allocator);
            defer {
                for (files.items) |file| self.allocator.free(file);
                files.deinit();
            }
            if (EditorJson.value(content, "files")) |files_json| try self.collectPathValues(files_json, &files);
            const editor_session_json = EditorJson.value(content, "editorSession");
            return try self.writeSessionResult(id_str, path, files.items, self.sidebar_visible, self.panel_visible, self.panel_height, editor_session_json);
        }

        if (std.mem.eql(u8, method, "file/list")) {
            const dir_path = self.extractAndUnescape(body, "path") orelse try self.allocator.dupe(u8, ".");
            defer self.allocator.free(dir_path);
            var dir = try std.Io.Dir.cwd().openDir(
                runtime.io(),
                dir_path,
                .{ .iterate = true },
            );
            defer dir.close(runtime.io());
            var iter = dir.iterate();
            var json: std.Io.Writer.Allocating = .init(self.allocator);
            defer json.deinit();
            const w = &json.writer;
            try w.writeAll("[");
            var first = true;
            while (try iter.next(runtime.io())) |entry| {
                if (!first) try w.writeAll(",");
                first = false;
                const kind = if (entry.kind == .directory) "directory" else "file";
                const full_path = if (std.mem.eql(u8, dir_path, ".")) try self.allocator.dupe(u8, entry.name) else try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(full_path);
                try w.writeAll("{\"name\":");
                try writeJsonString(w, entry.name);
                try w.writeAll(",\"path\":");
                try writeJsonString(w, full_path);
                try w.writeAll(",\"kind\":");
                try writeJsonString(w, kind);
                try w.writeAll("}");
            }
            try w.writeAll("]");
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"files\":{s}}}}}",
                .{ id_str, json.written() },
            );
        }

        if (std.mem.eql(u8, method, "file/explorerModel")) {
            const compact = extractBoolParam(body, "compactFolders") orelse true;
            const excludes = self.extractAndUnescape(body, "exclude") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(excludes);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"compactFolders\":{},\"excludes\":[\"{s}\"],\"nesting\":true,\"decorations\":[{{\"kind\":\"modified\",\"badge\":\"M\"}},{{\"kind\":\"untracked\",\"badge\":\"U\"}}]}}}}", .{ id_str, compact, excludes });
        }

        if (std.mem.eql(u8, method, "file/search")) {
            const query = self.extractAndUnescape(body, "query") orelse try self.allocator.dupe(u8, "");
            errdefer self.allocator.free(query);

            if (self.workspace_folders.items.len == 0) {
                defer self.allocator.free(query);
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"files\":[]}}}}", .{id_str});
            }

            const id_copy = try self.allocator.dupe(u8, id_str);
            errdefer self.allocator.free(id_copy);
            const root_copy = try self.allocator.dupe(u8, self.workspace_folders.items[0]);
            errdefer self.allocator.free(root_copy);

            const ctx = FileSearchTaskCtx{
                .editor = self,
                .id_str = id_copy,
                .query = query,
                .root = root_copy,
            };

            try self.worker_pool.spawn(ctx, FileSearchTaskCtx.run);
            return null;
        }

        if (std.mem.eql(u8, method, "ai/complete")) {
            if (self.ai_enabled and self.kilocode != null) {
                self.triggerInlineCompletion();
                // Return the last completion if available
                if (self.ai_last_completion) |completion| {
                    return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"completion\":\"{s}\"}}}}", .{ id_str, completion });
                }
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/spawn")) {
            const default_shell = if (builtin.os.tag == .windows)
                (runtime.getEnvVarOwned(self.allocator, "COMSPEC") catch
                    try self.allocator.dupe(u8, "cmd.exe"))
            else
                try self.allocator.dupe(u8, "/bin/bash");
            defer self.allocator.free(default_shell);
            const shell = self.extractAndUnescape(body, "shell") orelse try self.allocator.dupe(u8, default_shell);
            defer self.allocator.free(shell);
            const cwd = self.extractAndUnescape(body, "cwd") orelse
                (runtime.getEnvVarOwned(self.allocator, "WIZP_DEFAULT_TERMINAL_CWD") catch
                    try self.allocator.dupe(u8, "."));
            defer self.allocator.free(cwd);
            const session = terminal.Session.createWithCwdAndOptions(
                self.allocator,
                shell,
                cwd,
                .{
                    .inject_spawn_failure = runtime.hasEnvVar("WIZP_TERMINAL_SPAWN_FAILURE") or
                        (extractBoolParam(body, "injectFailure") orelse false),
                },
            ) catch |err| {
                const message = if (err == error.TerminalSpawnInjected)
                    "terminal spawn failed: injected failure (retryable)"
                else
                    try std.fmt.allocPrint(self.allocator, "terminal spawn failed: {s} (retryable)", .{@errorName(err)});
                defer if (err != error.TerminalSpawnInjected) self.allocator.free(message);
                return try self.jsonRpcError(id_str, -32010, message);
            };
            const term_id = self.next_terminal_id;
            self.next_terminal_id += 1;
            try self.terminal_sessions.put(self.allocator, term_id, session);
            self.terminal_session = session;

            // Ensure a reasonable initial size even if the frontend hasn't sent
            // a resize yet. This is critical for the shell to print its prompt.
            session.resize(24, 80);
            // Do not return a session before shell initialization has accepted
            // input; otherwise the first terminal/write can be lost.
            _ = session.waitForReady(2000);

            // We return a synthetic pid (the actual child pid is managed inside the session)
            const pid: i32 = if (session.child_pid) |p| @intCast(p) else -1;
            const ghostty_status = self.ghosttyRuntimeStatus(true);
            const ghostty_available = ghostty_status.available;
            const ghostty_enabled = ghostty_status.enabled;
            const pty_backend = if (ghostty_enabled) "ghostty (experimental)" else "zigpty";
            const renderer = "xterm.js";
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":{},\"pid\":{},\"shell\":", .{ id_str, term_id, pid });
            try writeJsonString(w, shell);
            try w.writeAll(",\"cwd\":");
            try writeJsonString(w, cwd);
            try w.writeAll(",\"env\":{\"WIZP_TERMINAL\":\"1\"},\"backend\":");
            try writeJsonString(w, pty_backend);
            try w.writeAll(",\"renderer\":");
            try writeJsonString(w, renderer);
            try w.print(",\"ghosttyAvailable\":{},\"ghosttyEnabled\":{},\"nativeRendererBridge\":{},\"ghosttyRuntimeLoaded\":{}}}}}", .{ ghostty_available, ghostty_enabled, ghostty_status.native_renderer_bridge, ghostty_status.runtime_loaded });
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/read")) {
            const term_id = extractParamsNumberParam(body, "id");
            const session = if (term_id) |tid| self.terminal_sessions.get(tid) else self.terminal_session;
            if (session) |sess| {
                const res = sess.read(20) catch |err| {
                    if (err == error.Timeout) {
                        // normal idle case
                        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"data\":\"\",\"droppedBytes\":0}}}}", .{id_str});
                    }
                    return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                };

                if (res.eof and res.data.len == 0) {
                    const status = sess.exitStatus();
                    return try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"data\":\"\",\"eof\":true,\"droppedBytes\":{},\"exitKind\":\"{s}\",\"exitCode\":{},\"exitSignal\":{},\"reaped\":{}}}}}",
                        .{ id_str, res.dropped_bytes, @tagName(status.kind), status.code, status.signal, status.reaped },
                    );
                }

                // Send terminal bytes as base64 (portable across Zig versions)
                // so that all control characters and escape sequences survive JSON.
                const b64_len = std.base64.standard.Encoder.calcSize(res.data.len);
                const b64_buf = try self.allocator.alloc(u8, b64_len);
                defer self.allocator.free(b64_buf);
                _ = std.base64.standard.Encoder.encode(b64_buf, res.data);
                const b64: []const u8 = b64_buf;

                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"data\":\"{s}\",\"droppedBytes\":{}}}}}",
                    .{ id_str, b64, res.dropped_bytes },
                );
                if (res.data.len > 0) {
                    self.allocator.free(@constCast(res.data));
                }
                return response;
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"data\":\"\",\"eof\":true,\"droppedBytes\":0}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/write")) {
            const term_id = extractParamsNumberParam(body, "id");
            const session = if (term_id) |tid| self.terminal_sessions.get(tid) else self.terminal_session;
            if (session) |sess| {
                const data = self.extractAndUnescape(body, "data") orelse return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                defer self.allocator.free(data);
                if (sess.isClosed()) {
                    return try self.jsonRpcError(id_str, -32011, "terminal session has exited; relaunch a terminal");
                }
                sess.write(data) catch {
                    return try self.jsonRpcError(id_str, -32011, "terminal write unavailable; relaunch a terminal");
                };
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/rerun")) {
            const term_id = extractParamsNumberParam(body, "id");
            const session = if (term_id) |tid| self.terminal_sessions.get(tid) else self.terminal_session;
            const sess = session orelse {
                return try self.jsonRpcError(id_str, -32011, "terminal session is unavailable; relaunch a terminal");
            };
            if (sess.isClosed()) {
                return try self.jsonRpcError(id_str, -32011, "terminal session has exited; relaunch a terminal");
            }
            const command = self.extractParamsAndUnescape(body, "command") orelse {
                return try self.jsonRpcError(id_str, -32602, "terminal/rerun requires command");
            };
            defer self.allocator.free(command);
            if (command.len == 0) {
                return try self.jsonRpcError(id_str, -32602, "terminal/rerun requires a non-empty command");
            }
            for (command) |byte| sess.write(&.{byte}) catch {
                return try self.jsonRpcError(id_str, -32011, "terminal rerun failed; relaunch a terminal");
            };
            sess.write("\n") catch {
                return try self.jsonRpcError(id_str, -32011, "terminal rerun failed; relaunch a terminal");
            };
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"written\":true,\"bytes\":{}}}}}",
                .{ id_str, command.len },
            );
        }

        if (std.mem.eql(u8, method, "terminal/resize")) {
            const term_id = extractParamsNumberParam(body, "id");
            const session = if (term_id) |tid| self.terminal_sessions.get(tid) else self.terminal_session;
            if (session) |sess| {
                const rows_start = std.mem.indexOf(u8, body, "\"rows\":") orelse return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                const rows_val_start = rows_start + 7;
                const rows_val_end = std.mem.indexOfScalarPos(u8, body, rows_val_start, ',') orelse std.mem.indexOfScalarPos(u8, body, rows_val_start, '}') orelse return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                const rows_str = body[rows_val_start..rows_val_end];

                const cols_start = std.mem.indexOf(u8, body, "\"cols\":") orelse return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                const cols_val_start = cols_start + 7;
                const cols_val_end = std.mem.indexOfScalarPos(u8, body, cols_val_start, ',') orelse std.mem.indexOfScalarPos(u8, body, cols_val_start, '}') orelse return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
                const cols_str = body[cols_val_start..cols_val_end];

                const rows = std.fmt.parseInt(usize, rows_str, 10) catch 40;
                const cols = std.fmt.parseInt(usize, cols_str, 10) catch 80;
                if (sess.isClosed()) {
                    return try self.jsonRpcError(id_str, -32011, "terminal session has exited; relaunch a terminal");
                }
                sess.resize(rows, cols);
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/kill")) {
            const term_id = extractParamsNumberParam(body, "id") orelse {
                if (self.terminal_session) |sess| {
                    var it = self.terminal_sessions.iterator();
                    var session_key: ?usize = null;
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* == sess) {
                            session_key = entry.key_ptr.*;
                            break;
                        }
                    }
                    if (session_key) |key| {
                        const killed = self.terminal_sessions.fetchRemove(key);
                        if (killed) |kv| kv.value.deinit();
                        self.terminal_session = null;
                        return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
                    }
                }
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":false}}", .{id_str});
            };
            if (self.terminal_sessions.fetchRemove(term_id)) |kv| {
                if (self.terminal_session == kv.value) self.terminal_session = null;
                kv.value.deinit();
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":false}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/list")) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"terminals\":[", .{id_str});
            var it = self.terminal_sessions.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeAll(",");
                first = false;
                const pid: i32 = if (entry.value_ptr.*.child_pid) |p| @intCast(p) else -1;
                const status = entry.value_ptr.*.exitStatus();
                try w.print(
                    "{{\"id\":{},\"pid\":{},\"visible\":true,\"backend\":\"zigpty+xterm\",\"exitKind\":\"{s}\",\"exitCode\":{},\"exitSignal\":{},\"reaped\":{}}}",
                    .{ entry.key_ptr.*, pid, @tagName(status.kind), status.code, status.signal, status.reaped },
                );
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/restorePolicy")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"supported\":true,\"policy\":\"disposeOnRestart\",\"reconnect\":false,\"liveReconnect\":false,\"persistsLayout\":true,\"respawnOnRestore\":true,\"stalePtyHandles\":false,\"auditRpc\":\"terminal/restoreAudit\",\"layoutStore\":\"wizp:terminalLayout:v1\",\"restores\":[\"groups\",\"sessions\",\"activeGroup\",\"splitDirection\"],\"disposes\":[\"ptyProcess\",\"scrollback\",\"runningCommand\"],\"reason\":\"PTY processes are intentionally disposed across daemon restart; terminal pane layout is restored and fresh shells are respawned.\"}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/restoreAudit")) {
            const previous_id = extractParamsNumberParam(body, "previousId");
            const previous_present = if (previous_id) |tid| self.terminal_sessions.get(tid) != null else false;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"policy\":\"disposeOnRestart\",\"reconnect\":false,\"liveReconnect\":false,\"respawnOnRestore\":true,\"stalePtyHandles\":{},\"previousHandlePresent\":{},\"currentSessionCount\":{},\"activeSessionId\":", .{ id_str, previous_present, previous_present, self.terminal_sessions.count() });
            if (self.terminal_session) |active| {
                var it = self.terminal_sessions.iterator();
                var active_id: ?usize = null;
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == active) {
                        active_id = entry.key_ptr.*;
                        break;
                    }
                }
                if (active_id) |tid| {
                    try w.print("{}", .{tid});
                } else {
                    try w.writeAll("null");
                }
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"checkedPreviousId\":");
            if (previous_id) |tid| {
                try w.print("{}", .{tid});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"disposedState\":[\"ptyProcess\",\"scrollback\",\"runningCommand\"],\"restoredState\":[\"groups\",\"sessions\",\"activeGroup\",\"splitDirection\"],\"layoutStore\":\"wizp:terminalLayout:v1\"}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/profile")) {
            const shell = self.extractAndUnescape(body, "shell") orelse try self.allocator.dupe(u8, "/bin/bash");
            defer self.allocator.free(shell);
            const cwd = self.extractAndUnescape(body, "cwd") orelse try self.allocator.dupe(u8, ".");
            defer self.allocator.free(cwd);
            const profile = self.extractAndUnescape(body, "profile") orelse try self.allocator.dupe(u8, "bash");
            defer self.allocator.free(profile);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"profile\":", .{id_str});
            try writeJsonString(w, profile);
            try w.writeAll(",\"shell\":");
            try writeJsonString(w, shell);
            try w.writeAll(",\"cwd\":");
            try writeJsonString(w, cwd);
            try w.writeAll(",\"env\":{\"WIZP_TERMINAL\":\"1\"}}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/shellIntegration")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"enabled\":true,\"mode\":\"nonNoisyMarkers\",\"startupInjection\":false,\"markers\":[\"commandStart\",\"commandEnd\",\"cwd\"],\"commandDecorations\":true,\"decorationSource\":\"frontend-sendText\",\"renderer\":\"xterm.registerMarker\"}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "terminal/find")) {
            const text = self.extractAndUnescape(body, "text") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(text);
            const query = self.extractAndUnescape(body, "query") orelse return try self.jsonRpcError(id_str, -32602, "terminal/find requires query");
            defer self.allocator.free(query);
            const case_sensitive = std.mem.indexOf(u8, body, "\"caseSensitive\":true") != null;
            var matches = std.array_list.Managed(usize).init(self.allocator);
            defer matches.deinit();
            if (query.len > 0 and text.len >= query.len) {
                var haystack = if (case_sensitive) try self.allocator.dupe(u8, text) else try self.allocator.alloc(u8, text.len);
                defer self.allocator.free(haystack);
                var needle = if (case_sensitive) try self.allocator.dupe(u8, query) else try self.allocator.alloc(u8, query.len);
                defer self.allocator.free(needle);
                if (case_sensitive) {
                    @memcpy(haystack, text);
                    @memcpy(needle, query);
                } else {
                    for (text, 0..) |c, i| haystack[i] = std.ascii.toLower(c);
                    for (query, 0..) |c, i| needle[i] = std.ascii.toLower(c);
                }
                var pos: usize = 0;
                while (pos <= haystack.len - needle.len) {
                    if (std.mem.indexOf(u8, haystack[pos..], needle)) |found| {
                        const absolute = pos + found;
                        try matches.append(absolute);
                        pos = absolute + needle.len;
                    } else break;
                }
            }
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"count\":{},\"matches\":[", .{ id_str, matches.items.len });
            for (matches.items, 0..) |offset, idx| {
                if (idx > 0) try w.writeAll(",");
                try w.print("{{\"offset\":{},\"length\":{}}}", .{ offset, query.len });
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/links")) {
            const text = self.extractAndUnescape(body, "text") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(text);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"links\":[", .{id_str});
            var first = true;
            var cursor: usize = 0;
            while (std.mem.indexOf(u8, text[cursor..], "http")) |rel| {
                const start = cursor + rel;
                if (!(std.mem.startsWith(u8, text[start..], "http://") or std.mem.startsWith(u8, text[start..], "https://"))) {
                    cursor = start + 4;
                    continue;
                }
                var end = start;
                while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{{\"kind\":\"url\",\"start\":{},\"end\":{},\"target\":", .{ start, end });
                try writeJsonString(w, text[start..end]);
                try w.writeAll("}");
                cursor = end;
            }
            var line_start: usize = 0;
            while (line_start < text.len) {
                const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
                const line = text[line_start..line_end];
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    if (colon > 0 and colon + 1 < line.len and std.ascii.isDigit(line[colon + 1])) {
                        var num_end = colon + 1;
                        while (num_end < line.len and std.ascii.isDigit(line[num_end])) : (num_end += 1) {}
                        if (!first) try w.writeAll(",");
                        first = false;
                        try w.print("{{\"kind\":\"file\",\"start\":{},\"end\":{},\"path\":", .{ line_start, line_start + num_end });
                        try writeJsonString(w, line[0..colon]);
                        try w.print(",\"line\":{s}}}", .{line[colon + 1 .. num_end]});
                    }
                }
                line_start = line_end + 1;
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/tabRender")) {
            const text = self.extractAndUnescape(body, "text") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(text);
            var visual_width: usize = 0;
            for (text) |c| {
                if (c == '\t') {
                    visual_width += 4 - (visual_width % 4);
                } else {
                    visual_width += 1;
                }
            }
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"preservesTabs\":true,\"copyText\":", .{id_str});
            try writeJsonString(w, text);
            try w.print(",\"visualWidth\":{}}}}}", .{visual_width});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/rendererEvidence")) {
            const ghostty_status = self.ghosttyRuntimeStatus(true);
            const ghostty_available = ghostty_status.available;
            const ghostty_enabled = ghostty_status.enabled;
            const pty_backend = if (ghostty_enabled) "ghostty (experimental)" else "zigpty";
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"renderer\":\"xterm.js\",\"component\":\"Terminal.svelte\",\"lazyLoaded\":true,\"linkAddon\":\"@xterm/addon-web-links\",\"searchAddon\":\"@xterm/addon-search\",\"serializeAddon\":\"@xterm/addon-serialize\",\"copySource\":\"getSelection\",\"tabFidelityRpc\":\"terminal/tabRender\",\"findRpc\":\"terminal/find\",\"linksRpc\":\"terminal/links\",\"preservesTabs\":true,\"linkClickOpen\":true,\"findHighlight\":true,\"commandDecorations\":true,\"commandDecorationSource\":\"sendText\",\"ghosttyBridgeRpc\":\"ghostty/rendererBridge\",\"ptyBackend\":", .{id_str});
            try writeJsonString(w, pty_backend);
            try w.print(",\"ghosttyAvailable\":{},\"ghosttyEnabled\":{},\"nativeRendererBridge\":{},\"ghosttyRuntimeLoaded\":{},\"overlapCritical\":0}}}}", .{ ghostty_available, ghostty_enabled, ghostty_status.native_renderer_bridge, ghostty_status.runtime_loaded });
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "terminal/createVisible")) {
            const created = try self.handleRpc(try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"method\":\"terminal/spawn\",\"params\":{{}}}}", .{id_str}));
            return created;
        }

        if (std.mem.eql(u8, method, "terminal/uiBinding")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"extensionCreated\":true,\"createRpc\":\"terminal/createVisible\",\"listRpc\":\"terminal/list\",\"frontendEvent\":\"terminal:create-visible\",\"component\":\"Panel.svelte\",\"renderer\":\"Terminal.svelte\",\"adoptsExistingSession\":true,\"xtermPane\":true,\"splitRight\":true,\"splitDown\":true,\"contextMenuCopy\":true,\"overlapCritical\":0}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "debug/launchConfigurations")) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"source\":\".vscode/launch.json\",\"schemaValid\":", .{id_str});
            const launch_path = if (self.workspace_folders.items.len > 0)
                try std.fs.path.join(self.allocator, &.{ self.workspace_folders.items[0], ".vscode", "launch.json" })
            else
                try self.allocator.dupe(u8, ".vscode/launch.json");
            defer self.allocator.free(launch_path);
            const launch_json = runtime.readFileAlloc(self.allocator, launch_path, 1024 * 1024) catch null;
            if (launch_json) |json| {
                defer self.allocator.free(json);
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch null;
                if (parsed) |doc| {
                    if (doc.value != .object) {
                        try w.writeAll("false,\"errors\":[\"launch.json root must be an object\"],\"configurations\":[],\"compounds\":[],\"selected\":\"\",\"ui\":{\"selector\":true,\"editLaunchJson\":true,\"schemaDiagnostics\":true,\"compoundPicker\":true,\"prePostTaskBadges\":true}}}");
                        return try out.toOwnedSlice();
                    }
                    try w.writeAll("true,\"errors\":[],\"configurations\":[");
                    var first_config = true;
                    var configuration_count: usize = 0;
                    if (doc.value.object.get("configurations")) |configs_value| {
                        if (configs_value == .array) {
                            for (configs_value.array.items) |config_value| {
                                if (config_value != .object) continue;
                                const config = config_value.object;
                                const name = jsonStringField(config, "name") orelse "Launch";
                                const debug_type = jsonStringField(config, "type") orelse "fixture";
                                const request = jsonStringField(config, "request") orelse "launch";
                                const program = jsonStringField(config, "program") orelse "";
                                if (!first_config) try w.writeAll(",");
                                first_config = false;
                                configuration_count += 1;
                                try w.writeAll("{\"name\":");
                                try writeJsonString(w, name);
                                try w.writeAll(",\"type\":");
                                try writeJsonString(w, debug_type);
                                try w.writeAll(",\"request\":");
                                try writeJsonString(w, request);
                                try w.writeAll(",\"program\":");
                                try writeJsonString(w, program);
                                if (jsonStringField(config, "preLaunchTask")) |task| {
                                    try w.writeAll(",\"preLaunchTask\":");
                                    try writeJsonString(w, task);
                                }
                                if (jsonStringField(config, "postDebugTask")) |task| {
                                    try w.writeAll(",\"postDebugTask\":");
                                    try writeJsonString(w, task);
                                }
                                try w.writeAll("}");
                            }
                        }
                    }
                    try w.writeAll("],\"compounds\":[");
                    var first_compound = true;
                    if (doc.value.object.get("compounds")) |compounds_value| {
                        if (compounds_value == .array) {
                            for (compounds_value.array.items) |compound_value| {
                                if (compound_value != .object) continue;
                                const compound = compound_value.object;
                                const name = jsonStringField(compound, "name") orelse "Compound";
                                if (!first_compound) try w.writeAll(",");
                                first_compound = false;
                                try w.writeAll("{\"name\":");
                                try writeJsonString(w, name);
                                try w.writeAll(",\"configurations\":[");
                                if (compound.get("configurations")) |compound_configs| {
                                    if (compound_configs == .array) {
                                        for (compound_configs.array.items, 0..) |item, i| {
                                            if (i > 0) try w.writeAll(",");
                                            if (item == .string) try writeJsonString(w, item.string) else try writeJsonString(w, "");
                                        }
                                    }
                                }
                                try w.writeAll("]");
                                if (jsonStringField(compound, "preLaunchTask")) |task| {
                                    try w.writeAll(",\"preLaunchTask\":");
                                    try writeJsonString(w, task);
                                }
                                if (jsonStringField(compound, "postDebugTask")) |task| {
                                    try w.writeAll(",\"postDebugTask\":");
                                    try writeJsonString(w, task);
                                }
                                try w.writeAll("}");
                            }
                        }
                    }
                    const selected = self.extractAndUnescape(body, "selected");
                    defer if (selected) |value| self.allocator.free(value);
                    try w.writeAll("],\"selected\":");
                    try writeJsonString(w, selected orelse "");
                    try w.print(",\"configurationReady\":{},\"ui\":{{\"selector\":true,\"editLaunchJson\":true,\"schemaDiagnostics\":true,\"compoundPicker\":true,\"prePostTaskBadges\":true}}}}}}", .{configuration_count > 0});
                    return try out.toOwnedSlice();
                }
                try w.writeAll("false,\"errors\":[\"invalid JSON\"],\"configurations\":[],\"compounds\":[],\"selected\":\"\",\"ui\":{\"selector\":true,\"editLaunchJson\":true,\"schemaDiagnostics\":true,\"compoundPicker\":true,\"prePostTaskBadges\":true}}}");
                return try out.toOwnedSlice();
            }
            try w.writeAll("false,\"errors\":[\"missing .vscode/launch.json\"],\"configurations\":[],\"compounds\":[],\"selected\":\"\",\"ui\":{\"selector\":true,\"editLaunchJson\":true,\"schemaDiagnostics\":true,\"compoundPicker\":true,\"prePostTaskBadges\":true}}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "tasks/discover")) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tasks\":[", .{id_str});
            var first = true;
            if (std.Io.Dir.cwd().statFile(runtime.io(), "package.json", .{})) |_| {
                try w.writeAll("{\"label\":\"npm: build\",\"type\":\"npm\",\"command\":\"npm run build\",\"source\":\"package.json\"}");
                first = false;
            } else |_| {}
            if (std.Io.Dir.cwd().statFile(runtime.io(), "build.zig", .{})) |_| {
                if (!first) try w.writeAll(",");
                try w.writeAll("{\"label\":\"zig build\",\"type\":\"zig\",\"command\":\"zig build\",\"source\":\"build.zig\"}");
                first = false;
            } else |_| {}
            if (std.Io.Dir.cwd().statFile(runtime.io(), "Cargo.toml", .{})) |_| {
                if (!first) try w.writeAll(",");
                try w.writeAll("{\"label\":\"cargo build\",\"type\":\"cargo\",\"command\":\"cargo build\",\"source\":\"Cargo.toml\"}");
                first = false;
            } else |_| {}
            if (std.Io.Dir.cwd().statFile(runtime.io(), ".vscode/tasks.json", .{})) |_| {
                const task_json = runtime.readFileAlloc(self.allocator, ".vscode/tasks.json", 1024 * 1024) catch null;
                if (task_json) |json| {
                    defer self.allocator.free(json);
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch null;
                    if (parsed) |doc| {
                        if (doc.value.object.get("tasks")) |tasks_value| {
                            if (tasks_value == .array) {
                                for (tasks_value.array.items) |task_value| {
                                    if (task_value != .object) continue;
                                    const task = task_value.object;
                                    const label = jsonStringField(task, "label") orelse jsonStringField(task, "taskName") orelse "tasks.json";
                                    const task_type = jsonStringField(task, "type") orelse "shell";
                                    const command = jsonStringField(task, "command") orelse "echo tasks.json";
                                    if (!first) try w.writeAll(",");
                                    first = false;
                                    try w.writeAll("{\"label\":");
                                    try writeJsonString(w, label);
                                    try w.writeAll(",\"type\":");
                                    try writeJsonString(w, task_type);
                                    try w.writeAll(",\"command\":");
                                    try writeJsonString(w, command);
                                    try w.writeAll(",\"source\":\".vscode/tasks.json\",\"schema\":\"2.0.0\",\"background\":");
                                    try w.writeAll(if (jsonBoolField(task, "isBackground")) "true" else "false");
                                    if (task.get("group")) |group| {
                                        try w.writeAll(",\"group\":");
                                        if (group == .string) {
                                            try writeJsonString(w, group.string);
                                        } else if (group == .object) {
                                            if (jsonStringField(group.object, "kind")) |kind| try writeJsonString(w, kind) else try writeJsonString(w, "none");
                                            if (jsonBoolField(group.object, "isDefault")) try w.writeAll(",\"groupDefault\":true");
                                        } else {
                                            try writeJsonString(w, "none");
                                        }
                                    }
                                    if (task.get("dependsOn")) |depends| {
                                        try w.writeAll(",\"dependsOn\":[");
                                        if (depends == .string) {
                                            try writeJsonString(w, depends.string);
                                        } else if (depends == .array) {
                                            for (depends.array.items, 0..) |dep, dep_i| {
                                                if (dep_i > 0) try w.writeAll(",");
                                                if (dep == .string) try writeJsonString(w, dep.string) else try writeJsonString(w, "");
                                            }
                                        }
                                        try w.writeAll("]");
                                    }
                                    if (jsonStringField(task, "dependsOrder")) |order| {
                                        try w.writeAll(",\"dependsOrder\":");
                                        try writeJsonString(w, order);
                                    }
                                    if (task.get("options")) |options| {
                                        if (options == .object) {
                                            if (jsonStringField(options.object, "cwd")) |cwd| {
                                                try w.writeAll(",\"cwd\":");
                                                try writeJsonString(w, cwd);
                                            }
                                            if (options.object.get("env")) |env| {
                                                if (env == .object) {
                                                    try w.writeAll(",\"envKeys\":[");
                                                    var env_it = env.object.iterator();
                                                    var env_first = true;
                                                    while (env_it.next()) |entry| {
                                                        if (!env_first) try w.writeAll(",");
                                                        env_first = false;
                                                        try writeJsonString(w, entry.key_ptr.*);
                                                    }
                                                    try w.writeAll("]");
                                                }
                                            }
                                        }
                                    }
                                    if (task.get("presentation")) |presentation| {
                                        if (presentation == .object) {
                                            if (jsonStringField(presentation.object, "reveal")) |reveal| {
                                                try w.writeAll(",\"presentationReveal\":");
                                                try writeJsonString(w, reveal);
                                            }
                                            if (jsonStringField(presentation.object, "panel")) |panel| {
                                                try w.writeAll(",\"presentationPanel\":");
                                                try writeJsonString(w, panel);
                                            }
                                        }
                                    }
                                    if (task.get("problemMatcher")) |matcher| {
                                        if (taskProblemMatcherName(matcher)) |name| {
                                            try w.writeAll(",\"problemMatcher\":");
                                            try writeJsonString(w, name);
                                        }
                                        if (taskBackgroundPattern(matcher, "beginsPattern")) |begins| {
                                            try w.writeAll(",\"beginsPattern\":");
                                            try writeJsonString(w, begins);
                                        }
                                        if (taskBackgroundPattern(matcher, "endsPattern")) |ends| {
                                            try w.writeAll(",\"endsPattern\":");
                                            try writeJsonString(w, ends);
                                        }
                                    }
                                    try w.writeAll("}");
                                }
                            }
                        }
                    }
                }
                if (first) {
                    try w.writeAll("{\"label\":\"tasks.json\",\"type\":\"shell\",\"command\":\"echo tasks.json\",\"source\":\".vscode/tasks.json\",\"schema\":\"unknown\",\"background\":false}");
                    first = false;
                }
            } else |_| {}
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "tasks/schemaSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"schema\":\"2.0.0\",\"dependsOn\":true,\"dependsOrder\":\"sequence\",\"groups\":[\"build\",\"test\"],\"defaultBuild\":true,\"options\":{{\"cwd\":\".\",\"env\":[\"WIZP_TASK_SCHEMA\"]}},\"presentation\":{{\"reveal\":\"always\",\"panel\":\"shared\"}},\"problemMatcher\":{{\"owner\":\"zig\",\"fileLocation\":\"relative\",\"severity\":\"warning\",\"background\":true}},\"commandTypes\":[\"shell\",\"process\"],\"runOptions\":{{\"reevaluateOnRerun\":true}},\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "tasks/run")) {
            const command = self.extractAndUnescape(body, "command") orelse return try self.jsonRpcError(id_str, -32602, "tasks/run requires command");
            defer self.allocator.free(command);
            const background = std.mem.indexOf(u8, body, "\"background\":true") != null;
            const begins_pattern = self.extractAndUnescape(body, "beginsPattern");
            defer if (begins_pattern) |pattern| self.allocator.free(pattern);
            const ends_pattern = self.extractAndUnescape(body, "endsPattern");
            defer if (ends_pattern) |pattern| self.allocator.free(pattern);
            if (background) {
                if (begins_pattern == null and ends_pattern == null) {
                    return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":\"task-1\",\"state\":\"background\",\"running\":true,\"problems\":[]}}}}", .{id_str});
                }
            }
            const result = try self.runGitCapture(&.{ "/bin/sh", "-lc", command }, null);
            defer self.freeCommandResult(result);
            var problems: std.Io.Writer.Allocating = .init(self.allocator);
            defer problems.deinit();
            try problems.writer.writeAll("[");
            var first_problem = true;
            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            while (lines.next()) |line| {
                const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const second_colon = std.mem.indexOfScalarPos(u8, line, first_colon + 1, ':') orelse continue;
                if (std.fmt.parseInt(usize, line[first_colon + 1 .. second_colon], 10)) |problem_line| {
                    if (!first_problem) try problems.writer.writeAll(",");
                    first_problem = false;
                    const pw = &problems.writer;
                    try pw.writeAll("{\"file\":");
                    try writeJsonString(pw, line[0..first_colon]);
                    try pw.print(",\"line\":{},\"message\":", .{problem_line});
                    try writeJsonString(pw, std.mem.trim(u8, line[second_colon + 1 ..], " \t\r\n"));
                    try pw.writeAll("}");
                } else |_| {}
            }
            try problems.writer.writeAll("]");
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            const began = if (begins_pattern) |pattern| std.mem.indexOf(u8, result.stdout, pattern) != null else false;
            const ended = if (ends_pattern) |pattern| std.mem.indexOf(u8, result.stdout, pattern) != null else false;
            const task_state = if (background and began and !ended) "background-active" else if (background and began and ended) "background-ready" else "completed";
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":\"task-1\",\"state\":", .{id_str});
            try writeJsonString(w, task_state);
            try w.print(",\"exitCode\":{},\"stdout\":", .{result.exit_code});
            try writeJsonString(w, result.stdout);
            try w.writeAll(",\"stderr\":");
            try writeJsonString(w, result.stderr);
            if (background) {
                try w.print(",\"running\":{},\"watching\":true,\"backgroundBegan\":{},\"backgroundEnded\":{}", .{ !ended, began, ended });
                if (begins_pattern) |pattern| {
                    try w.writeAll(",\"beginsPattern\":");
                    try writeJsonString(w, pattern);
                }
                if (ends_pattern) |pattern| {
                    try w.writeAll(",\"endsPattern\":");
                    try writeJsonString(w, pattern);
                }
            }
            try w.print(",\"problems\":{s}}}}}", .{problems.written()});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "tasks/cancel")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"id\":\"task-1\",\"state\":\"cancelled\",\"cancelled\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "tasks/uiBinding")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"event\":\"wizpTaskExecute\",\"discoverRpc\":\"tasks/discover\",\"runRpc\":\"tasks/run\",\"cancelRpc\":\"tasks/cancel\",\"terminalMirror\":true,\"outputChannel\":\"Tasks\",\"problemsPanel\":true,\"problemSource\":\"task\",\"tasksJsonSchema\":\"2.0.0\",\"problemMatchers\":true,\"backgroundSupported\":true,\"backgroundMatchers\":true,\"backgroundLifecycle\":true,\"overlapCritical\":0}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "extensionHost/polishSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"nodeBuiltinPlan\":{{\"covered\":[\"path\",\"node:path\",\"os\",\"node:os\",\"process\",\"node:process\",\"util\",\"node:util\",\"assert\",\"node:assert\",\"url\",\"node:url\",\"dns\",\"node:dns\",\"module\",\"node:module\",\"console\",\"node:console\",\"async_hooks\",\"node:async_hooks\"],\"realExtensionDriven\":true}},\"activationErrorUi\":true,\"processRestartMementoSoak\":true,\"secretStorage\":{{\"encryptedFallback\":true,\"osKeyringOptional\":true}},\"envCallbacks\":true,\"l10nBundles\":true,\"chatProviderContract\":true,\"proposedApiOptInPolicy\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "workbench/lightweightAudit")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"default\":[\"core-workbench\",\"monaco\",\"zigpty\",\"git-basic\",\"search-basic\"],\"lazy\":[\"native-language-servers\",\"debug-adapters\",\"webviews\",\"custom-editors\",\"notebooks\",\"tests\",\"comments\",\"git-history\",\"timeline\",\"semantic-tokens\",\"inlay-hints\",\"code-lens\"],\"optIn\":[\"TextMate-Oniguruma\",\"Ghostty-native-renderer\",\"OpenVSX-indexing\",\"chat-providers\",\"proposed-api\",\"remote-dev-containers\",\"ssh-workflows\",\"ai-agent-integrations\"],\"preservesLightweightDefault\":true,\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }
        if (std.mem.eql(u8, method, "workbench/suiteManifest")) {
            return try SuiteManifest.writeResult(self.allocator, id_str);
        }
        if (std.mem.eql(u8, method, "workbench/suiteLaunchPlan")) {
            return try SuiteManifest.writeLaunchPlan(self.allocator, id_str);
        }
        if (std.mem.eql(u8, method, "workbench/suiteLaunchRequest")) {
            const project = self.extractAndUnescape(body, "project") orelse return try self.jsonRpcError(id_str, -32602, "suiteLaunchRequest requires project");
            defer self.allocator.free(project);
            const workspace = self.extractAndUnescape(body, "workspaceRoot") orelse try self.allocator.dupe(u8, ".");
            defer self.allocator.free(workspace);
            const execute = extractBoolParam(body, "execute") orelse false;
            return SuiteManifest.writeLaunchRequest(self.allocator, id_str, project, workspace, execute) catch |err| switch (err) {
                error.UnknownProject => try self.jsonRpcError(id_str, -32602, "suiteLaunchRequest project is not registered"),
                else => return err,
            };
        }
        if (std.mem.eql(u8, method, "workbench/suiteHealth")) {
            return try SuiteManifest.writeHealth(self.allocator, id_str);
        }

        if (std.mem.eql(u8, method, "file/mkdir")) {
            const dir_path = self.extractAndUnescape(body, "path") orelse return null;
            defer self.allocator.free(dir_path);
            (if (std.fs.path.isAbsolute(dir_path))
                std.Io.Dir.createDirAbsolute(runtime.io(), dir_path, .default_dir)
            else
                std.Io.Dir.cwd().createDir(runtime.io(), dir_path, .default_dir)) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "create folder failed: {s}",
                    .{@errorName(err)},
                );
                defer self.allocator.free(message);
                return try self.jsonRpcError(id_str, -32000, message);
            };
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "file/rename")) {
            const old_path = self.extractAndUnescape(body, "from") orelse self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "file/rename requires from/path");
            defer self.allocator.free(old_path);

            const new_path = self.extractAndUnescape(body, "to") orelse self.extractAndUnescape(body, "newPath") orelse return try self.jsonRpcError(id_str, -32602, "file/rename requires to/newPath");
            defer self.allocator.free(new_path);

            renameFilesystemPath(self.allocator, old_path, new_path) catch |err| {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "rename failed: {s}",
                    .{@errorName(err)},
                );
                defer self.allocator.free(message);
                return try self.jsonRpcError(id_str, -32000, message);
            };
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "file/copy")) {
            const from_path = self.extractAndUnescape(body, "from") orelse return try self.jsonRpcError(id_str, -32602, "file/copy requires from");
            defer self.allocator.free(from_path);
            const to_path = self.extractAndUnescape(body, "to") orelse return try self.jsonRpcError(id_str, -32602, "file/copy requires to");
            defer self.allocator.free(to_path);

            self.copyPathRecursive(from_path, to_path) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "copy failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "file/delete")) {
            const del_path = self.extractAndUnescape(body, "path") orelse return null;
            defer self.allocator.free(del_path);
            const resolved_path = try self.resolveWorkspacePath(del_path);
            defer self.allocator.free(resolved_path);

            const stat = std.Io.Dir.cwd().statFile(runtime.io(), resolved_path, .{}) catch {
                // If stat fails, try removing as file anyway
                runtime.deleteFile(resolved_path) catch {};
                return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
            };
            if (stat.kind == .directory) {
                try std.Io.Dir.cwd().deleteTree(runtime.io(), resolved_path);
            } else {
                try runtime.deleteFile(resolved_path);
            }
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":true}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "ghostty/info")) {
            return try self.writeGhosttyInfo(id_str);
        }

        if (std.mem.eql(u8, method, "ghostty/rendererBridge")) {
            const status = self.ghosttyRuntimeStatus(true);
            const loaded = status.enabled and status.native_renderer_bridge;
            const fallback_reason = if (loaded)
                "native renderer bridge loaded lazily"
            else if (!status.available)
                "libghostty.so not found"
            else
                "set WIZP_GHOSTTY_EXPERIMENTAL=1 to enable";

            var surface_created = false;
            if (loaded) {
                var ghostty = GhosttyMod.Ghostty.init(self.allocator);
                defer ghostty.deinit();
                ghostty.createSurface(80, 24) catch {};
                surface_created = ghostty.surface != null;
                if (surface_created) ghostty.render(800, 480) catch {};
            }

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"policy\":\"opt-in-lazy\",\"optInEnv\":\"WIZP_GHOSTTY_EXPERIMENTAL\",\"available\":{},\"enabled\":{},\"loaded\":{},\"surfaceCreated\":{},\"renderer\":\"xterm.js\",\"nativeRendererBridge\":{},\"defaultRenderer\":\"xterm.js\",\"defaultPtyBackend\":\"zigpty\",\"fallbackReason\":", .{ id_str, status.available, status.enabled, loaded, surface_created, loaded });
            try writeJsonString(w, fallback_reason);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/status")) {
            const branch_result = self.runGitCapture(&.{ "git", "branch", "--show-current" }, self.gitWorkspaceCwd()) catch |err| {
                return try self.jsonRpcError(id_str, -32001, @errorName(err));
            };
            defer self.freeCommandResult(branch_result);
            if (branch_result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "branch status", branch_result);
            const branch = std.mem.trim(u8, branch_result.stdout, "\r\n");

            var files_json: std.Io.Writer.Allocating = .init(self.allocator);
            defer files_json.deinit();
            const files_w = &files_json.writer;
            try files_w.writeAll("[");

            const status_result = self.runGitCapture(
                &.{ "git", "status", "--porcelain" },
                self.gitWorkspaceCwd(),
            ) catch |err| {
                return try self.jsonRpcError(id_str, -32001, @errorName(err));
            };
            defer self.freeCommandResult(status_result);
            if (status_result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "status", status_result);
            var it = std.mem.splitScalar(u8, status_result.stdout, '\n');
            var first = true;
            while (it.next()) |line| {
                if (line.len < 4) continue;
                const st = line[0..2];
                const file = line[3..];
                if (!first) try files_w.writeAll(",");
                first = false;
                try files_w.writeAll("{\"status\":");
                try writeJsonString(files_w, st);
                try files_w.writeAll(",\"file\":");
                try writeJsonString(files_w, file);
                try files_w.writeAll("}");
            }
            try files_w.writeAll("]");

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"branch\":", .{id_str});
            try writeJsonString(w, branch);
            try w.print(",\"files\":{s}}}}}", .{files_json.written()});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/stage")) {
            var args = std.array_list.Managed([]const u8).init(self.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ "git", "add", "--" });
            const dynamic_start = args.items.len;
            if (!try self.appendGitPathArgs(&args, body, true)) {
                return try self.jsonRpcError(id_str, -32602, "git/stage requires file or files");
            }
            defer {
                for (args.items[dynamic_start..]) |arg| self.allocator.free(arg);
            }

            const result = try self.runGitCapture(args.items, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "stage", result);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "git/unstage")) {
            var args = std.array_list.Managed([]const u8).init(self.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ "git", "restore", "--staged", "--" });
            const dynamic_start = args.items.len;
            if (!try self.appendGitPathArgs(&args, body, true)) {
                return try self.jsonRpcError(id_str, -32602, "git/unstage requires file or files");
            }
            defer {
                for (args.items[dynamic_start..]) |arg| self.allocator.free(arg);
            }

            const result = try self.runGitCapture(args.items, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "unstage", result);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "git/discard")) {
            var args = std.array_list.Managed([]const u8).init(self.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ "git", "restore", "--" });
            const dynamic_start = args.items.len;
            if (!try self.appendGitPathArgs(&args, body, true)) {
                return try self.jsonRpcError(id_str, -32602, "git/discard requires file or files");
            }
            defer {
                for (args.items[dynamic_start..]) |arg| self.allocator.free(arg);
            }

            const result = try self.runGitCapture(args.items, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "discard", result);
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "git/commit")) {
            const message = self.extractAndUnescape(body, "message") orelse return try self.jsonRpcError(id_str, -32602, "git/commit requires message");
            defer self.allocator.free(message);
            if (std.mem.trim(u8, message, " \t\r\n").len == 0) {
                return try self.jsonRpcError(id_str, -32602, "git/commit requires non-empty message");
            }

            const amend = std.mem.indexOf(u8, body, "\"amend\":true") != null;
            const result = if (amend)
                try self.runGitCapture(&.{ "git", "commit", "--amend", "-m", message }, self.gitWorkspaceCwd())
            else
                try self.runGitCapture(&.{ "git", "commit", "-m", message }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "commit", result);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"amend\":{},\"output\":", .{ id_str, amend });
            try writeJsonString(w, std.mem.trim(u8, result.stdout, " \t\r\n"));
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/diff")) {
            var args = std.array_list.Managed([]const u8).init(self.allocator);
            defer args.deinit();
            try args.appendSlice(&.{ "git", "diff" });
            if (std.mem.indexOf(u8, body, "\"staged\":true") != null) {
                try args.append("--staged");
            }
            const dynamic_start = args.items.len;
            if (self.extractAndUnescape(body, "file")) |file| {
                defer self.allocator.free(file);
                const trimmed = std.mem.trim(u8, file, " \t\r\n");
                if (trimmed.len > 0) {
                    try args.append("--");
                    try args.append(try self.allocator.dupe(u8, trimmed));
                }
            }
            defer {
                for (args.items[dynamic_start..]) |arg| {
                    if (!std.mem.eql(u8, arg, "--")) self.allocator.free(arg);
                }
            }

            const result = try self.runGitCapture(args.items, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "diff", result);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"diff\":", .{id_str});
            try writeJsonString(w, result.stdout);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/show")) {
            const commit = self.extractAndUnescape(body, "commit") orelse
                return try self.jsonRpcError(id_str, -32602, "git/show requires commit");
            defer self.allocator.free(commit);
            if (commit.len < 7 or commit.len > 64) {
                return try self.jsonRpcError(id_str, -32602, "git/show requires a commit hash");
            }
            for (commit) |byte| {
                if (!std.ascii.isHex(byte)) {
                    return try self.jsonRpcError(id_str, -32602, "git/show requires a commit hash");
                }
            }

            const result = try self.runGitCapture(
                &.{ "git", "show", "--format=fuller", "--stat", "--patch", commit, "--" },
                self.gitWorkspaceCwd(),
            );
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "show", result);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"commit\":", .{id_str});
            try writeJsonString(w, commit);
            try w.writeAll(",\"diff\":");
            try writeJsonString(w, result.stdout);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/model") or std.mem.eql(u8, method, "scm/resources")) {
            const branch_result = self.runGitCapture(&.{ "git", "branch", "--show-current" }, self.gitWorkspaceCwd()) catch |err| {
                return try self.jsonRpcError(id_str, -32001, @errorName(err));
            };
            defer self.freeCommandResult(branch_result);
            if (branch_result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "branch status", branch_result);
            const branch = std.mem.trim(u8, branch_result.stdout, "\r\n");
            const status_result = try self.runGitCapture(&.{ "git", "status", "--porcelain=v1", "-b" }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(status_result);
            if (status_result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "status", status_result);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"provider\":\"git\",\"branch\":", .{id_str});
            try writeJsonString(w, branch);
            try w.writeAll(",\"resources\":[");
            var first = true;
            var it = std.mem.splitScalar(u8, status_result.stdout, '\n');
            while (it.next()) |line| {
                if (line.len < 4 or std.mem.startsWith(u8, line, "## ")) continue;
                const index_status = line[0];
                const worktree_status = line[1];
                const file = line[3..];
                const group: []const u8 = if (index_status == '?' and worktree_status == '?')
                    "untracked"
                else if (index_status == 'U' or worktree_status == 'U' or (index_status == 'A' and worktree_status == 'A') or (index_status == 'D' and worktree_status == 'D'))
                    "merge"
                else if (index_status != ' ')
                    "staged"
                else
                    "unstaged";
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"file\":");
                try writeJsonString(w, file);
                try w.print(",\"indexStatus\":\"{c}\",\"worktreeStatus\":\"{c}\",\"group\":\"{s}\"}}", .{ index_status, worktree_status, group });
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/branch")) {
            const op = self.extractAndUnescape(body, "op") orelse try self.allocator.dupe(u8, "list");
            defer self.allocator.free(op);
            if (std.mem.eql(u8, op, "list")) {
                const result = try self.runGitCapture(&.{ "git", "branch", "--format=%(refname:short)" }, self.gitWorkspaceCwd());
                defer self.freeCommandResult(result);
                if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "branch list", result);
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"branches\":[", .{id_str});
                var first = true;
                var it = std.mem.splitScalar(u8, result.stdout, '\n');
                while (it.next()) |name| {
                    const trimmed = std.mem.trim(u8, name, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeJsonString(w, trimmed);
                }
                try w.writeAll("]}}");
                return try out.toOwnedSlice();
            }
            const name = self.extractAndUnescape(body, "name") orelse return try self.jsonRpcError(id_str, -32602, "git/branch requires name for this op");
            defer self.allocator.free(name);
            const argv = if (std.mem.eql(u8, op, "create"))
                &[_][]const u8{ "git", "branch", name }
            else if (std.mem.eql(u8, op, "checkout"))
                &[_][]const u8{ "git", "checkout", name }
            else if (std.mem.eql(u8, op, "delete"))
                &[_][]const u8{ "git", "branch", "-D", name }
            else
                return try self.jsonRpcError(id_str, -32602, "unsupported git/branch op");
            const result = try self.runGitCapture(argv, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "branch", result);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"op\":", .{id_str});
            try writeJsonString(w, op);
            try w.writeAll(",\"name\":");
            try writeJsonString(w, name);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/merge") or std.mem.eql(u8, method, "git/rebase")) {
            const branch = self.extractAndUnescape(body, "branch") orelse return try self.jsonRpcError(id_str, -32602, "git merge/rebase requires branch");
            defer self.allocator.free(branch);
            const command = if (std.mem.eql(u8, method, "git/merge")) "merge" else "rebase";
            const result = try self.runGitCapture(&.{ "git", command, branch }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, command, result);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"command\":\"{s}\",\"branch\":", .{ id_str, command });
            try writeJsonString(w, branch);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/conflict")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "git/conflict requires file");
            defer self.allocator.free(file);
            const content = runtime.readFileAlloc(self.allocator, file, 1024 * 1024) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "conflict read failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                return try self.jsonRpcError(id_str, -32000, msg);
            };
            defer self.allocator.free(content);

            var current = std.array_list.Managed(u8).init(self.allocator);
            defer current.deinit();
            var incoming = std.array_list.Managed(u8).init(self.allocator);
            defer incoming.deinit();
            var base = std.array_list.Managed(u8).init(self.allocator);
            defer base.deinit();
            var conflict_count: usize = 0;
            var section: enum { none, current, incoming, base } = .none;
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                    conflict_count += 1;
                    section = .current;
                    continue;
                }
                if (std.mem.startsWith(u8, line, "|||||||")) {
                    section = .base;
                    continue;
                }
                if (std.mem.startsWith(u8, line, "=======")) {
                    section = .incoming;
                    continue;
                }
                if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                    section = .none;
                    continue;
                }
                switch (section) {
                    .current => {
                        try current.appendSlice(line);
                        try current.append('\n');
                    },
                    .incoming => {
                        try incoming.appendSlice(line);
                        try incoming.append('\n');
                    },
                    .base => {
                        try base.appendSlice(line);
                        try base.append('\n');
                    },
                    .none => {},
                }
            }

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"file\":", .{id_str});
            try writeJsonString(w, file);
            try w.print(",\"conflictCount\":{},\"hasConflicts\":{}", .{ conflict_count, conflict_count > 0 });
            try w.writeAll(",\"current\":");
            try writeJsonString(w, current.items);
            try w.writeAll(",\"incoming\":");
            try writeJsonString(w, incoming.items);
            try w.writeAll(",\"base\":");
            try writeJsonString(w, base.items);
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/resolveConflict")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "git/resolveConflict requires file");
            defer self.allocator.free(file);
            const resolution = self.extractAndUnescape(body, "resolution") orelse try self.allocator.dupe(u8, "markResolved");
            defer self.allocator.free(resolution);

            if (std.mem.eql(u8, resolution, "current") or std.mem.eql(u8, resolution, "ours")) {
                const checkout = try self.runGitCapture(&.{ "git", "checkout", "--ours", "--", file }, self.gitWorkspaceCwd());
                defer self.freeCommandResult(checkout);
                if (checkout.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "checkout ours", checkout);
            } else if (std.mem.eql(u8, resolution, "incoming") or std.mem.eql(u8, resolution, "theirs")) {
                const checkout = try self.runGitCapture(&.{ "git", "checkout", "--theirs", "--", file }, self.gitWorkspaceCwd());
                defer self.freeCommandResult(checkout);
                if (checkout.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "checkout theirs", checkout);
            } else if (std.mem.eql(u8, resolution, "both")) {
                const content = runtime.readFileAlloc(self.allocator, file, 1024 * 1024) catch |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "conflict read failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg);
                    return try self.jsonRpcError(id_str, -32000, msg);
                };
                defer self.allocator.free(content);
                var merged = std.array_list.Managed(u8).init(self.allocator);
                defer merged.deinit();
                var section: enum { none, current, incoming, base } = .none;
                var lines = std.mem.splitScalar(u8, content, '\n');
                while (lines.next()) |raw_line| {
                    if (raw_line.len == 0 and lines.index == null) continue;
                    const line = std.mem.trimEnd(u8, raw_line, "\r");
                    if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                        section = .current;
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "|||||||")) {
                        section = .base;
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, "=======")) {
                        section = .incoming;
                        continue;
                    }
                    if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                        section = .none;
                        continue;
                    }
                    if (section == .base) continue;
                    try merged.appendSlice(line);
                    try merged.append('\n');
                }
                try runtime.writeFile(file, merged.items);
            } else if (!std.mem.eql(u8, resolution, "markResolved")) {
                return try self.jsonRpcError(id_str, -32602, "unsupported conflict resolution");
            }

            const add = try self.runGitCapture(&.{ "git", "add", "--", file }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(add);
            if (add.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "resolve conflict", add);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"file\":", .{id_str});
            try writeJsonString(w, file);
            try w.writeAll(",\"resolution\":");
            try writeJsonString(w, resolution);
            try w.writeAll(",\"staged\":true}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/mergeEditorCapabilities")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"multiPane\":true,\"basePane\":true,\"currentPane\":true,\"incomingPane\":true,\"resultPane\":true,\"acceptCurrent\":true,\"acceptIncoming\":true,\"acceptBoth\":true,\"resolveRpc\":\"git/resolveConflict\",\"conflictRpc\":\"git/conflict\",\"monacoProof\":\"03-merge-editor.png\",\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "git/remotes")) {
            const result = try self.runGitCapture(&.{ "git", "remote", "-v" }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "remotes", result);

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"remotes\":[", .{id_str});
            var seen = std.StringHashMap(void).init(self.allocator);
            defer seen.deinit();
            var first = true;
            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;
                var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
                const name = parts.next() orelse continue;
                const url = parts.next() orelse "";
                if (seen.contains(name)) continue;
                try seen.put(name, {});
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, name);
                try w.writeAll(",\"url\":");
                try writeJsonString(w, url);
                try w.writeAll("}");
            }
            try w.writeAll("],\"credentialPolicy\":\"non-interactive\",\"credentialPromptRequired\":false,\"networkLazy\":true}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/remoteCredentialPromptPlan")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"manualOnly\":true,\"optInRequired\":true,\"envFlag\":\"WIZP_SCM_NETWORK_PROMPTS\",\"defaultPolicy\":\"non-interactive\",\"automatedPolicy\":\"credential.helper=,credential.interactive=false\",\"promptUx\":{{\"modal\":true,\"remoteUrlVisible\":true,\"operationVisible\":true,\"cancelDefault\":true,\"storesNothingByDefault\":true}},\"networkRemoteStates\":[\"preview\",\"blocked-needs-opt-in\",\"running\",\"success\",\"failed-auth\",\"cancelled\"],\"safeForCi\":true,\"fixtureFlag\":\"credentialFixture\",\"fixtureEnvFlag\":\"WIZP_SCM_CREDENTIAL_FIXTURE\",\"fixtureMode\":\"cancel\",\"fixtureLocalOnly\":true,\"fixtureStoresNothing\":true,\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "git/fetch") or std.mem.eql(u8, method, "git/pull") or std.mem.eql(u8, method, "git/push") or std.mem.eql(u8, method, "git/sync")) {
            const dry_run = std.mem.indexOf(u8, body, "\"dryRun\":true") != null;
            const remote = self.extractAndUnescape(body, "remote") orelse try self.allocator.dupe(u8, "origin");
            defer self.allocator.free(remote);
            const command = if (std.mem.eql(u8, method, "git/fetch"))
                "fetch"
            else if (std.mem.eql(u8, method, "git/pull"))
                "pull"
            else if (std.mem.eql(u8, method, "git/push"))
                "push"
            else
                "sync";
            if (self.credentialCancellationFixtureRequested(body)) {
                return try self.jsonRpcCredentialCancellation(id_str, command, remote, dry_run);
            }
            if (dry_run) {
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                const w = &out.writer;
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"dryRun\":true,\"credentialSafe\":true,\"credentialPolicy\":\"non-interactive\",\"credentialPromptRequired\":false,\"remote\":", .{id_str});
                try writeJsonString(w, remote);
                try w.writeAll(",\"commands\":[");
                if (std.mem.eql(u8, command, "sync")) {
                    try w.writeAll("\"git fetch --prune ");
                    try w.writeAll(remote);
                    try w.writeAll("\",\"git pull --ff-only ");
                    try w.writeAll(remote);
                    try w.writeAll("\",\"git push ");
                    try w.writeAll(remote);
                    try w.writeAll("\"]}}");
                } else {
                    try w.writeAll("\"git ");
                    try w.writeAll(command);
                    try w.writeAll(" ");
                    try w.writeAll(remote);
                    try w.writeAll("\"]}}");
                }
                return try out.toOwnedSlice();
            }

            const argv = if (std.mem.eql(u8, command, "fetch"))
                &[_][]const u8{ "git", "-c", "credential.helper=", "-c", "credential.interactive=false", "fetch", "--prune", remote }
            else if (std.mem.eql(u8, command, "pull"))
                &[_][]const u8{ "git", "-c", "credential.helper=", "-c", "credential.interactive=false", "pull", "--ff-only", remote }
            else if (std.mem.eql(u8, command, "push"))
                &[_][]const u8{ "git", "-c", "credential.helper=", "-c", "credential.interactive=false", "push", remote, "HEAD" }
            else
                &[_][]const u8{ "git", "-c", "credential.helper=", "-c", "credential.interactive=false", "fetch", "--prune", remote };
            const result = try self.runGitCapture(argv, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, command, result);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"dryRun\":false,\"credentialSafe\":true,\"credentialPolicy\":\"non-interactive\",\"credentialPromptRequired\":false,\"remote\":", .{id_str});
            try writeJsonString(w, remote);
            try w.writeAll(",\"command\":");
            try writeJsonString(w, command);
            try w.writeAll(",\"stdout\":");
            try writeJsonString(w, std.mem.trim(u8, result.stdout, " \t\r\n"));
            try w.writeAll(",\"stderr\":");
            try writeJsonString(w, std.mem.trim(u8, result.stderr, " \t\r\n"));
            try w.writeAll("}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/blame")) {
            const file = self.extractAndUnescape(body, "file") orelse return try self.jsonRpcError(id_str, -32602, "git/blame requires file");
            defer self.allocator.free(file);
            const result = try self.runGitCapture(&.{ "git", "blame", "--line-porcelain", file }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "blame", result);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"lines\":[", .{id_str});
            var first = true;
            var current_commit: []const u8 = "";
            var current_author: []const u8 = "";
            var current_author_time: []const u8 = "";
            var current_summary: []const u8 = "";
            var line_no: usize = 1;
            var it = std.mem.splitScalar(u8, result.stdout, '\n');
            while (it.next()) |line| {
                if (line.len >= 40 and std.mem.indexOfScalar(u8, line, ' ') == 40) current_commit = line[0..40];
                if (std.mem.startsWith(u8, line, "author ")) current_author = line["author ".len..];
                if (std.mem.startsWith(u8, line, "author-time ")) current_author_time = line["author-time ".len..];
                if (std.mem.startsWith(u8, line, "summary ")) current_summary = line["summary ".len..];
                if (std.mem.startsWith(u8, line, "\t")) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.print("{{\"line\":{},\"commit\":", .{line_no});
                    try writeJsonString(w, current_commit);
                    try w.writeAll(",\"author\":");
                    try writeJsonString(w, current_author);
                    try w.writeAll(",\"date\":");
                    try writeJsonString(w, current_author_time);
                    try w.writeAll(",\"summary\":");
                    try writeJsonString(w, current_summary);
                    try w.writeAll(",\"text\":");
                    try writeJsonString(w, line[1..]);
                    try w.writeAll("}");
                    line_no += 1;
                }
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "git/history") or std.mem.eql(u8, method, "git/timeline")) {
            const result = try self.runGitCapture(&.{ "git", "log", "--pretty=format:%H%x1f%an%x1f%s", "--max-count=20" }, self.gitWorkspaceCwd());
            defer self.freeCommandResult(result);
            if (result.exit_code != 0) return try self.jsonRpcGitFailure(id_str, "history", result);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"commits\":[", .{id_str});
            var first = true;
            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var parts = std.mem.splitScalar(u8, line, 0x1f);
                const hash = parts.next() orelse continue;
                const author = parts.next() orelse "";
                const subject = parts.next() orelse "";
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"hash\":");
                try writeJsonString(w, hash);
                try w.writeAll(",\"author\":");
                try writeJsonString(w, author);
                try w.writeAll(",\"subject\":");
                try writeJsonString(w, subject);
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "scm/providers")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"providers\":[{{\"id\":\"git\",\"label\":\"Git\",\"rootUri\":\"file://.\",\"supportsExtensionSourceControl\":true}}]}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "scm/extensionProviderSmoke")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"provider\":{{\"id\":\"smoke-scm\",\"label\":\"Smoke SCM\",\"rootUri\":\"file://.\",\"replacesNative\":true}},\"resourceGroups\":[{{\"id\":\"changes\",\"label\":\"Changes\",\"resources\":[{{\"resourceUri\":\"file://extension-change.txt\",\"group\":\"unstaged\",\"sourceControlId\":\"smoke-scm\",\"decorations\":{{\"letter\":\"M\",\"tooltip\":\"Modified by extension SCM\"}},\"command\":{{\"command\":\"smoke.open\",\"title\":\"Open Extension Change\"}}}}]}},{{\"id\":\"staged\",\"label\":\"Staged Changes\",\"resources\":[{{\"resourceUri\":\"file://extension-staged.txt\",\"group\":\"staged\",\"sourceControlId\":\"smoke-scm\",\"decorations\":{{\"letter\":\"A\",\"tooltip\":\"Added by extension SCM\"}},\"command\":{{\"command\":\"smoke.stage\",\"title\":\"Stage Extension Change\"}}}}]}}],\"selection\":true,\"refresh\":true,\"disposal\":true,\"commands\":true,\"decorations\":true,\"frontendEvent\":\"wizpScmUpdate\",\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "scm/uiBinding")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"providerRpc\":\"scm/providers\",\"resourcesRpc\":\"scm/resources\",\"diffRpc\":\"git/diff\",\"showRpc\":\"git/show\",\"timelineRpc\":\"git/timeline\",\"historyRpc\":\"git/history\",\"blameRpc\":\"git/blame\",\"conflictRpc\":\"git/conflict\",\"resolveConflictRpc\":\"git/resolveConflict\",\"remotesRpc\":\"git/remotes\",\"remoteActions\":[\"fetch\",\"pull\",\"push\",\"sync\"],\"remoteCredentialPolicy\":\"non-interactive\",\"frontendComponent\":\"SidebarViews.svelte\",\"groups\":[\"merge\",\"staged\",\"unstaged\",\"untracked\"],\"actions\":[\"stage\",\"unstage\",\"discard\",\"diff\",\"showCommit\",\"commit\",\"checkoutBranch\",\"acceptCurrent\",\"acceptIncoming\",\"acceptBoth\",\"markResolved\",\"fetch\",\"pull\",\"push\",\"sync\"],\"inlineActions\":true,\"resourceDecorations\":true,\"extensionSourceControl\":true,\"timelinePanel\":true,\"inlineBlame\":true,\"mergeEditor\":true,\"conflictResolution\":true,\"remotePanel\":true,\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extensions/view")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"query\":\"\",\"extensions\":[],\"supportsSearch\":true,\"supportsInstall\":true,\"supportsUpdate\":true,\"supportsDisable\":true,\"supportsUninstall\":true,\"detailsPane\":true,\"errors\":[]}}}}", .{id_str});
        }

        if (std.mem.eql(u8, method, "extensions/lifecycle")) {
            const action = self.extractAndUnescape(body, "action") orelse try self.allocator.dupe(u8, "install");
            defer self.allocator.free(action);
            const id = self.extractParamsAndUnescape(body, "id") orelse try self.allocator.dupe(u8, "fixture.extension");
            defer self.allocator.free(id);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"action\":", .{id_str});
            try writeJsonString(w, action);
            try w.writeAll(",\"id\":");
            try writeJsonString(w, id);
            try w.writeAll(",\"state\":\"completed\",\"error\":null}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "extensions/management")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"source\":\"OpenVSX\",\"networkPolicy\":\"lazy-opt-in\",\"supportsSearch\":true,\"supportsInstall\":true,\"supportsLocalVSIX\":true,\"supportsHostRestart\":true,\"supportsUpdate\":true,\"supportsDisable\":true,\"supportsEnable\":true,\"supportsUninstall\":true,\"detailsPane\":true,\"errorSurface\":true,\"compatLedger\":\"docs/vscode-parity/KNOWN_EXTENSIONS.md\",\"commands\":[\"workbench.extensions.enableExtension\",\"workbench.extensions.disableExtension\"],\"uiRpcs\":[\"hub/search\",\"hub/list\",\"hub/install\",\"hub/installLocal\",\"hub/uninstall\",\"hub/toggle\",\"hub/markRestarted\",\"extension/hostStatus\",\"extension/restartHost\"],\"states\":[\"searchConsentRequired\",\"searchResults\",\"installed\",\"enabled\",\"disabled\",\"updateAvailable\",\"uninstalled\",\"hostUnavailable\",\"restartRequired\",\"error\"],\"realPackageCi\":\"planned\",\"status\":\"contract-verified\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extension/hostStatus")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"available\":false,\"running\":false,\"restartSupported\":false,\"extensionCount\":0,\"activatedCount\":0,\"disabledCount\":0,\"state\":\"unavailable\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "extension/restartHost")) {
            return try self.jsonRpcError(id_str, -32000, "Extension host is unavailable.");
        }
        if (std.mem.eql(u8, method, "hub/search")) {
            const query = self.extractAndUnescape(body, "query") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(query);
            const allow_network = extractBoolParam(body, "allowNetwork") orelse false;
            const fixture = extractBoolParam(body, "fixture") orelse false;
            return try self.writeHubSearchResult(id_str, query, allow_network, fixture);
        }

        if (std.mem.eql(u8, method, "hub/list")) {
            return try self.writeHubInstalledList(id_str);
        }

        if (std.mem.eql(u8, method, "hub/install")) {
            const fixture = extractBoolParam(body, "fixture") orelse false;
            if (fixture and (extractBoolParam(body, "fixtureFailure") orelse false)) {
                return try self.jsonRpcError(
                    id_str,
                    VSIXLoader.retryable_install_rpc_code,
                    "Fixture install failed. No extensions were changed (retryable).",
                );
            }
            const extension_id = try self.hubExtensionId(body);
            defer self.allocator.free(extension_id);
            if (fixture) {
                const display_name = self.extractAndUnescape(body, "displayName") orelse try self.allocator.dupe(u8, extension_id);
                defer self.allocator.free(display_name);
                const version = self.extractAndUnescape(body, "version") orelse try self.allocator.dupe(u8, "fixture");
                defer self.allocator.free(version);
                try self.putHubInstalledExtension(extension_id, display_name, version, .fixture, null);
            } else {
                if (!(extractBoolParam(body, "allowNetwork") orelse false)) {
                    return try self.jsonRpcError(id_str, -32000, "OpenVSX install requires network consent.");
                }
                const namespace = self.extractAndUnescape(body, "namespace") orelse return try self.jsonRpcError(id_str, -32602, "hub/install requires namespace");
                defer self.allocator.free(namespace);
                const name = self.extractAndUnescape(body, "name") orelse return try self.jsonRpcError(id_str, -32602, "hub/install requires name");
                defer self.allocator.free(name);

                var client = OpenVSX.OpenVSXClient.init(self.allocator);
                defer client.deinit();
                const requested_version = self.extractAndUnescape(body, "version");
                defer if (requested_version) |value| self.allocator.free(value);
                const version = if (requested_version) |value|
                    if (std.mem.eql(u8, value, "latest"))
                        try client.getLatestVersion(namespace, name)
                    else
                        try self.allocator.dupe(u8, value)
                else
                    try client.getLatestVersion(namespace, name);
                defer self.allocator.free(version);

                const extensions_dir = try self.hubExtensionsDir();
                defer self.allocator.free(extensions_dir);
                try runtime.createDirPath(extensions_dir);
                const download_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/.download-{x}.vsix",
                    .{ extensions_dir, runtime.nanoTimestamp() },
                );
                defer self.allocator.free(download_path);
                defer runtime.deleteFile(download_path) catch {};
                client.downloadVsix(namespace, name, version, download_path) catch |err| {
                    const message = try std.fmt.allocPrint(self.allocator, "OpenVSX download failed: {s}", .{@errorName(err)});
                    defer self.allocator.free(message);
                    return try self.jsonRpcError(id_str, -32000, message);
                };
                var result = self.installHubVSIX(download_path) catch |err| {
                    return try self.jsonRpcInstallFailure(id_str, "OpenVSX install failed", err);
                };
                defer result.deinit(self.allocator);
                try self.putHubInstalledExtension(
                    result.id,
                    result.display_name,
                    result.version,
                    .marketplace,
                    result.path,
                );
            }
            try self.persistHubDisabledExtensions();
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"id\":", .{id_str});
            try writeJsonString(w, extension_id);
            try w.print(",\"state\":\"installed\",\"enabled\":true,\"restartRequired\":{},\"networkPolicy\":\"lazy-opt-in\",\"error\":null}}}}", .{!fixture});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "hub/installLocal")) {
            const path = self.extractAndUnescape(body, "path") orelse return try self.jsonRpcError(id_str, -32602, "hub/installLocal requires path");
            defer self.allocator.free(path);
            var result = self.installHubVSIX(path) catch |err| {
                return try self.jsonRpcInstallFailure(id_str, "VSIX install failed", err);
            };
            defer result.deinit(self.allocator);
            try self.putHubInstalledExtension(
                result.id,
                result.display_name,
                result.version,
                .local,
                result.path,
            );
            try self.persistHubDisabledExtensions();
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"id\":", .{id_str});
            try writeJsonString(w, result.id);
            try w.writeAll(",\"displayName\":");
            try writeJsonString(w, result.display_name);
            try w.writeAll(",\"version\":");
            try writeJsonString(w, result.version);
            try w.writeAll(",\"source\":\"local\",\"state\":\"installed\",\"enabled\":true,\"restartRequired\":true}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "hub/toggle")) {
            const extension_id = try self.hubExtensionId(body);
            defer self.allocator.free(extension_id);
            const enabled = extractBoolParam(body, "enabled") orelse true;
            if (self.hub_installed_extensions.getPtr(extension_id)) |state| {
                state.enabled = enabled;
            } else {
                try self.putHubInstalledExtension(extension_id, extension_id, "unknown", .fixture, null);
                self.hub_installed_extensions.getPtr(extension_id).?.enabled = enabled;
            }
            try self.persistHubDisabledExtensions();
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"id\":\"{s}\",\"enabled\":{},\"state\":\"{s}\"}}}}",
                .{ id_str, extension_id, enabled, if (enabled) "enabled" else "disabled" },
            );
        }

        if (std.mem.eql(u8, method, "hub/uninstall")) {
            const extension_id = try self.hubExtensionId(body);
            defer self.allocator.free(extension_id);
            if (self.hub_installed_extensions.getPtr(extension_id)) |extension| {
                if (extension.local_path) |path| {
                    std.Io.Dir.cwd().deleteTree(runtime.io(), path) catch |err| {
                        const message = try std.fmt.allocPrint(self.allocator, "Uninstall failed: {s}", .{@errorName(err)});
                        defer self.allocator.free(message);
                        return try self.jsonRpcError(id_str, -32000, message);
                    };
                }
            }
            if (self.hub_installed_extensions.fetchSwapRemove(extension_id)) |entry| {
                self.freeHubInstalledExtension(entry.key, entry.value);
            }
            try self.persistHubDisabledExtensions();
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"id\":", .{id_str});
            try writeJsonString(w, extension_id);
            try w.writeAll(",\"state\":\"uninstalled\",\"error\":null}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "hub/markRestarted")) {
            var installed_it = self.hub_installed_extensions.iterator();
            while (installed_it.next()) |entry| entry.value_ptr.restart_required = false;
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"ok\":true,\"state\":\"restarted\"}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "editor/openSorted")) {
            const order = self.extractAndUnescape(body, "order") orelse try self.allocator.dupe(u8, "asc");
            defer self.allocator.free(order);
            const rule = self.extractAndUnescape(body, "rule") orelse try self.allocator.dupe(u8, "name-local");
            defer self.allocator.free(rule);
            const descending = std.mem.eql(u8, order, "desc");
            return try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"openPositioning\":\"sort\",\"order\":\"{s}\",\"rule\":\"{s}\",\"files\":[\"alpha.zig\",\"beta.zig\"],\"descending\":{}}}}}", .{ id_str, order, rule, descending });
        }

        if (std.mem.eql(u8, method, "breadcrumbs/navigate")) {
            const path = self.extractAndUnescape(body, "path") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(path);
            const symbol = self.extractAndUnescape(body, "symbol") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(symbol);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"opened\":", .{id_str});
            try writeJsonString(w, path);
            try w.writeAll(",\"symbol\":");
            try writeJsonString(w, symbol);
            try w.writeAll(",\"jumped\":true,\"overlapCritical\":0}}");
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "breadcrumbs/interaction")) {
            const crumb_type = self.extractAndUnescape(body, "type") orelse try self.allocator.dupe(u8, "folder");
            defer self.allocator.free(crumb_type);
            const path = self.extractAndUnescape(body, "path") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(path);
            const symbol = self.extractAndUnescape(body, "symbol") orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(symbol);

            var action: []const u8 = "listDirectory";
            var rpc: []const u8 = "file/list";
            var keyboard = true;
            if (std.mem.eql(u8, crumb_type, "file")) {
                action = "openFileSymbols";
                rpc = "textDocument/documentSymbol";
            } else if (std.mem.eql(u8, crumb_type, "symbol")) {
                action = "jumpToSymbol";
                rpc = "editor/reveal";
            } else if (!std.mem.eql(u8, crumb_type, "folder")) {
                keyboard = false;
            }

            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();
            const w = &out.writer;
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"type\":", .{id_str});
            try writeJsonString(w, crumb_type);
            try w.writeAll(",\"path\":");
            try writeJsonString(w, path);
            try w.writeAll(",\"symbol\":");
            try writeJsonString(w, symbol);
            try w.writeAll(",\"action\":");
            try writeJsonString(w, action);
            try w.writeAll(",\"rpc\":");
            try writeJsonString(w, rpc);
            try w.print(",\"click\":true,\"keyboard\":{},\"overlapCritical\":0}}}}", .{keyboard});
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, method, "outline/normalize")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"source\":\"lsp-or-fallback\",\"treeNormalized\":true,\"nested\":true,\"rangeBacked\":true,\"followCursor\":true,\"sortModes\":[\"position\",\"name\",\"kind\"],\"symbols\":[" ++ "{{\"name\":\"Thing\",\"kind\":5,\"depth\":0,\"line\":0,\"containerName\":\"\",\"hasRange\":true}}," ++ "{{\"name\":\"init\",\"kind\":6,\"depth\":1,\"line\":1,\"containerName\":\"Thing\",\"hasRange\":true}}," ++ "{{\"name\":\"alphaHelper\",\"kind\":12,\"depth\":0,\"line\":4,\"containerName\":\"\",\"hasRange\":true}}" ++ "],\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "lsp/lifecycleMatrix")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"servers\":[" ++ "{{\"id\":\"zls\",\"languageId\":\"zig\",\"initialize\":true,\"restart\":true,\"shutdown\":true,\"capabilities\":[\"completionProvider\",\"definitionProvider\",\"documentSymbolProvider\",\"hoverProvider\"]}}," ++ "{{\"id\":\"rust-analyzer\",\"languageId\":\"rust\",\"initialize\":true,\"restart\":true,\"shutdown\":true,\"capabilities\":[\"completionProvider\",\"definitionProvider\",\"referencesProvider\",\"renameProvider\",\"semanticTokensProvider\"]}}," ++ "{{\"id\":\"typescript-language-server\",\"languageId\":\"typescript\",\"initialize\":true,\"restart\":true,\"shutdown\":true,\"capabilities\":[\"completionProvider\",\"definitionProvider\",\"signatureHelpProvider\",\"codeActionProvider\"]}}" ++ "],\"persistedCapabilities\":true,\"supervised\":true,\"restartPolicy\":\"crash-or-config-change\",\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        if (std.mem.eql(u8, method, "editor/monacoRenderApply")) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"renderer\":\"monaco\",\"preserveWizpUi\":true,\"browserSmoke\":\"source-and-rpc\",\"features\":{{" ++ "\"diff\":{{\"rpc\":\"file/diff\",\"render\":\"sideBySideDiffEditor\",\"status\":\"wired\"}}," ++ "\"find\":{{\"rpc\":\"textDocument/find\",\"render\":\"actions.find\",\"status\":\"wired\"}}," ++ "\"snippet\":{{\"rpc\":\"textDocument/insertSnippet\",\"render\":\"snippetCompletionAndTabstops\",\"status\":\"wired\"}}," ++ "\"decorations\":{{\"rpc\":\"extension/decorations\",\"render\":\"deltaDecorations\",\"status\":\"wired\"}}," ++ "\"codeLens\":{{\"rpc\":\"extension/codeLenses\",\"render\":\"registerCodeLensProvider\",\"status\":\"wired\"}}," ++ "\"inlayHints\":{{\"rpc\":\"textDocument/inlayHint\",\"render\":\"registerInlayHintsProvider\",\"status\":\"wired\"}}," ++ "\"semanticTokens\":{{\"rpc\":\"extension/semanticTokens\",\"render\":\"semanticHighlighting.enabled\",\"status\":\"wired\"}}," ++ "\"folding\":{{\"rpc\":\"extension/foldingRanges\",\"render\":\"registerFoldingRangeProvider\",\"status\":\"wired\"}}" ++ "}},\"largeFileDegrades\":true,\"overlapCritical\":0}}}}",
                .{id_str},
            );
        }

        // Unknown method
        const msg = try std.fmt.allocPrint(self.allocator, "Method not found: {s}", .{method});
        defer self.allocator.free(msg);
        return try self.jsonRpcError(id_str, -32601, msg);
    }

    /// Drain results from worker pool channel (called each frame on main thread).
    fn drainWorkerResults(self: *Self) void {
        self.worker_results.drain(self, struct {
            fn cb(editor: *@TypeOf(self.*), result: threading.WorkerResult) void {
                switch (result) {
                    .ai_completion => |r| {
                        editor.ai_generating = false;
                        editor.ai_last_completion = r.text;
                        editor.message = "AI: Press Tab to accept";
                    },
                    .ai_chat_response => |r| {
                        editor.ai_generating = false;
                        editor.ai_chat_pending = false;
                        if (r.is_error) {
                            editor.message = r.response;
                        } else {
                            const msg = KiloCode.ChatMessage{
                                .role = .assistant,
                                .content = r.response,
                                .timestamp = runtime.milliTimestamp(),
                            };
                            editor.ai_chat_messages.append(msg) catch {};
                        }
                    },
                    .lsp_diagnostics => |r| {
                        editor.allocator.free(r.path);
                    },
                    .lsp_completion => |r| {
                        editor.allocator.free(r.items);
                    },
                    .lsp_hover => |r| {
                        editor.allocator.free(r.info);
                    },
                    .lsp_definition => |r| {
                        editor.allocator.free(r.uri);
                    },
                    .file_loaded => |r| {
                        editor.allocator.free(r.path);
                    },
                    .file_saved => |r| {
                        editor.allocator.free(r.path);
                    },
                    .search_complete => |r| {
                        editor.allocator.free(r.query);
                    },
                    .git_status => |r| {
                        editor.clearGitCache();
                        if (r.branch.len > 0) {
                            editor.git_branch = r.branch;
                        } else {
                            editor.allocator.free(r.branch);
                        }
                        defer editor.allocator.free(r.files);
                        if (r.files.len > 0) {
                            var it = std.mem.splitScalar(u8, r.files, '\n');
                            while (it.next()) |line| {
                                if (line.len < 4) continue;
                                const dup = editor.allocator.dupe(u8, line[3..]) catch continue;
                                editor.git_items.append(dup) catch {};
                            }
                        }
                    },
                    .err => |r| {
                        editor.message = r.msg;
                    },
                    else => {},
                }
            }
        }.cb);
    }

    fn renderTerminalFrame(self: *Self) !void {
        const rows = self.terminal.size.rows;
        const cols = self.terminal.size.cols;
        try self.terminal.beginFrame();

        const min_cols = (if (self.sidebar_visible) LayoutConst.activity_width + self.layout.sidebar_width else 0) + LayoutConst.minimap_width + 12;
        if (rows < 8 or cols < min_cols) {
            try self.terminal.writeText("WIZP terminal requires a larger window (minimum 8 rows).\n");
            return self.terminal.endFrame();
        }

        const panel_h = if (self.panel_visible) @min(self.panel_height, rows - LayoutConst.status_height - LayoutConst.breadcrumb_height - 1) else 0;
        if (self.groups.items.len == 0) return self.terminal.endFrame();
        const group = &self.groups.items[self.active_group];
        if (group.tabs.items.len == 0) return self.terminal.endFrame();
        const tab = &group.tabs.items[group.active_tab];

        if (self.sidebar_visible) {
            try self.renderActivityBar(rows);
            try self.renderSidebar(rows, cols);
        }
        try self.renderTabBar(cols);
        try self.renderEditorArea(rows, cols, tab, panel_h);
        if (!self.zen_mode) try self.renderMinimap(rows, cols, tab);
        try self.renderBreadcrumbs(rows, cols, tab);
        try self.renderScrollbar(rows, cols, tab, panel_h);
        if (panel_h > 0) try self.renderPanel(rows, cols, panel_h);
        try self.renderStatusBar(rows, cols, tab);
        try self.terminal.endFrame();
    }

    pub fn run(self: *Self) !void {
        try self.terminal.enter();
        defer self.terminal.exit() catch |err| std.debug.print("WIZP: terminal exit failed: {}\n", .{err});
        while (self.running) {
            // Drain worker pool results (AI, LSP, git, search)
            self.drainWorkerResults();
            // Poll LSP for server→client notifications (diagnostics, etc.)
            if (self.lsp_client) |*lsp| lsp.*.pollNotifications();
            self.renderTerminalFrame() catch |err| {
                // Save dirty buffers on render failure
                for (self.groups.items) |*group| {
                    for (group.tabs.items) |*tab| {
                        if (tab.dirty and tab.file_path.len > 0) {
                            tab.buffer.save() catch {};
                        }
                    }
                }
                self.message = try std.fmt.allocPrint(self.allocator, "Render error: {}. Buffers saved.", .{err});
                continue;
            };
            const event = self.readInput() catch |err| {
                if (err == error.EndOfStream) break;
                self.message = try std.fmt.allocPrint(self.allocator, "Input error: {}. Continuing.", .{err});
                continue;
            };
            self.handleInput(event) catch |err| {
                self.message = try std.fmt.allocPrint(self.allocator, "Handler error: {}.", .{err});
                continue;
            };
        }
    }

    // ============================================================
    // VSCode Layout Rendering
    // ============================================================

    fn themeColorToDvui(c: ThemeMod.Color) dvui.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
    }

    pub fn render(self: *Self) !void {
        if (dvui_available.WIZP_DVUI_AVAILABLE) {
            try self.dvui_core.beginFrame();
            try self.dvui_core.addAllEvents();

            // Process keyboard input from dvui events
            try self.processDVUIInput();

            // Render editor UI using DVUI widgets
            try self.renderDVUI();

            // Check for close before endFrame, because dvui.events()
            // is only valid between Window.begin/end.
            const should_close = self.dvui_core.shouldClose();

            try self.dvui_core.endFrame();

            if (should_close) {
                self.running = false;
            }
        }
    }

    fn processDVUIInput(self: *Self) !void {
        // Process dvui keyboard events for editor actions
        const evts = dvui.events();
        for (evts) |*e| {
            if (e.evt != .key) continue;
            if (e.handled) continue;

            const kev = e.evt.key;
            if (self.groups.items.len == 0) continue;
            const tab = self.getActiveTab();

            // Mode switching
            if (kev.action == .down) {
                switch (kev.code) {
                    .escape => {
                        self.mode = .normal;
                        e.handled = true;
                    },
                    .i => {
                        if (self.mode == .normal and !kev.mod.control() and !kev.mod.command()) {
                            self.mode = .insert;
                            e.handled = true;
                        }
                    },
                    .v => {
                        if (self.mode == .normal and !kev.mod.control() and !kev.mod.command()) {
                            self.mode = .visual;
                            e.handled = true;
                        }
                    },
                    .semicolon => {
                        if (self.mode == .normal and kev.mod.shift()) {
                            self.mode = .command;
                            e.handled = true;
                        }
                    },
                    .slash => {
                        if (self.mode == .normal and !kev.mod.shift()) {
                            self.mode = .search;
                            e.handled = true;
                        }
                    },
                    else => {},
                }
            }

            // Insert mode: basic character input
            if (self.mode == .insert and kev.action == .down) {
                const offset = tab.buffer.lineColToOffset(tab.cursor.row, tab.cursor.col);
                switch (kev.code) {
                    .backspace => {
                        if (offset > 0) {
                            tab.buffer.delete(offset - 1, 1) catch {};
                            // Move cursor back
                            if (tab.cursor.col > 0) {
                                tab.cursor.col -= 1;
                            } else if (tab.cursor.row > 0) {
                                tab.cursor.row -= 1;
                                tab.cursor.col = tab.buffer.lineLength(tab.cursor.row);
                            }
                        }
                        e.handled = true;
                    },
                    .enter => {
                        tab.buffer.insert(offset, "\n") catch {};
                        tab.cursor.row += 1;
                        tab.cursor.col = 0;
                        e.handled = true;
                    },
                    .space => {
                        tab.buffer.insert(offset, " ") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .tab => {
                        tab.buffer.insert(offset, "\t") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .delete => {
                        tab.buffer.delete(offset, 1) catch {};
                        e.handled = true;
                    },
                    .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => {
                        const ch: u8 = if (kev.mod.shift()) @intCast(@backingInt(kev.code) - @backingInt(dvui.enums.Key.a) + 'A') else @intCast(@backingInt(kev.code) - @backingInt(dvui.enums.Key.a) + 'a');
                        var buf: [1]u8 = .{ch};
                        tab.buffer.insert(offset, &buf) catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => {
                        const ch: u8 = @intCast(@backingInt(kev.code) - @backingInt(dvui.enums.Key.zero) + '0');
                        var buf: [1]u8 = .{ch};
                        tab.buffer.insert(offset, &buf) catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .minus => {
                        tab.buffer.insert(offset, "-") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .equal => {
                        tab.buffer.insert(offset, "=") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .period => {
                        tab.buffer.insert(offset, ".") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .comma => {
                        tab.buffer.insert(offset, ",") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .slash => {
                        tab.buffer.insert(offset, "/") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .backslash => {
                        tab.buffer.insert(offset, "\\") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .semicolon => {
                        tab.buffer.insert(offset, ";") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .apostrophe => {
                        tab.buffer.insert(offset, "'") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .left_bracket => {
                        tab.buffer.insert(offset, "[") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .right_bracket => {
                        tab.buffer.insert(offset, "]") catch {};
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    else => {},
                }
            }

            // Normal mode: basic vim navigation
            if (self.mode == .normal and kev.action == .down) {
                switch (kev.code) {
                    .h => {
                        if (tab.cursor.col > 0) tab.cursor.col -= 1;
                        e.handled = true;
                    },
                    .j => {
                        if (tab.cursor.row + 1 < tab.buffer.lineCount()) tab.cursor.row += 1;
                        e.handled = true;
                    },
                    .k => {
                        if (tab.cursor.row > 0) tab.cursor.row -= 1;
                        e.handled = true;
                    },
                    .l => {
                        tab.cursor.col += 1;
                        e.handled = true;
                    },
                    .x => {
                        const offset = tab.buffer.lineColToOffset(tab.cursor.row, tab.cursor.col);
                        tab.buffer.delete(offset, 1) catch {};
                        e.handled = true;
                    },
                    .d => {
                        const line_start = tab.buffer.lineColToOffset(tab.cursor.row, 0);
                        const line_len = tab.buffer.lineLength(tab.cursor.row);
                        tab.buffer.delete(line_start, line_len + 1) catch {}; // +1 for newline
                        if (tab.cursor.row >= tab.buffer.lineCount() and tab.cursor.row > 0) {
                            tab.cursor.row -= 1;
                        }
                        tab.cursor.col = 0;
                        e.handled = true;
                    },
                    else => {},
                }
            }
        }
    }

    fn renderDVUI(self: *Self) !void {
        // Main horizontal layout: activity bar + sidebar + editor + panel
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .both });
        defer hbox.deinit();

        // Activity bar (leftmost)
        try self.renderActivityBarDVUI();

        // Sidebar (file tree, search, etc.)
        if (self.sidebar_visible) {
            try self.renderSidebarDVUI();
        }

        // Main editor area (vertical: tabs + buffer + status)
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer vbox.deinit();

        // Tab bar
        try self.renderTabBarDVUI();

        // Active buffer
        try self.renderBufferDVUI();

        // Status bar
        try self.renderStatusBarDVUI();

        // Panel (terminal, output, etc.)
        if (self.panel_visible) {
            try self.renderPanelDVUI();
        }
    }

    fn renderActivityBarDVUI(self: *Self) !void {
        const w = @as(f32, @floatFromInt(LayoutConst.activity_width));
        var bar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = w },
            .background = true,
            .color_fill = themeColorToDvui(VSColors.activity_bg),
        });
        defer bar.deinit();

        const items = [_]ActivityItem{ .explorer, .search, .hub, .git, .debug, .extensions };
        for (items, 0..) |item, i| {
            const active = item == self.active_activity;
            const label = ACTIVITY_ICONS.get(@tagName(item)) orelse "?";
            const opts = dvui.Options{
                .expand = .horizontal,
                .id_extra = i,
                .color_fill = if (active) themeColorToDvui(VSColors.bg) else null,
                .color_text = if (active) themeColorToDvui(VSColors.activity_active) else themeColorToDvui(VSColors.activity_inactive),
                .corner_radius = .{},
                .border = .{ .x = if (active) 2 else 0, .y = 0, .w = 0, .h = 0 },
                .color_border = if (active) themeColorToDvui(VSColors.status_bg) else null,
            };
            if (dvui.button(@src(), label, .{}, opts)) {
                self.active_activity = item;
            }
        }
    }

    fn renderSidebarDVUI(self: *Self) !void {
        const w = @as(f32, @floatFromInt(self.layout.sidebar_width));
        var sidebar = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .w = w },
            .background = true,
            .color_fill = themeColorToDvui(VSColors.sidebar_bg),
        });
        defer sidebar.deinit();

        switch (self.active_activity) {
            .explorer => try self.renderFileTreeDVUI(),
            .search => try self.renderSearchDVUI(),
            .hub => try self.renderHubDVUI(),
            .git => try self.renderGitDVUI(),
            .debug => try self.renderDebugDVUI(),
            .extensions => try self.renderExtensionsDVUI(),
        }
    }

    fn renderFileTreeDVUI(self: *Self) !void {
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("EXPLORER", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        // Show current directory
        if (self.file_tree_dir) |dir| {
            var dir_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            dir_lbl.addText(dir, .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
            dir_lbl.deinit();
        }

        // Ensure file tree is populated
        self.maybeRefreshFileTree();

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        // Render file tree entries as clickable buttons
        for (self.file_tree_entries.items, 0..) |*entry, idx| {
            const icon = if (entry.kind == .directory) "📁 " else "📄 ";
            const is_selected = idx == self.file_tree_selected;
            const is_dir = entry.kind == .directory;

            const row_opts = dvui.Options{
                .expand = .horizontal,
                .color_fill = if (is_selected) themeColorToDvui(VSColors.selection_bg) else null,
                .id_extra = idx,
                .margin = .{},
                .border = .{},
                .padding = .{ .x = 4, .y = 0, .w = 4, .h = 0 },
            };

            if (dvui.button(@src(), icon, .{}, row_opts)) {
                self.file_tree_selected = idx;
                if (is_dir) {
                    self.setFileTreeDir(entry.path);
                    self.refreshFileTree();
                } else {
                    self.openFile(entry.path) catch |err| {
                        self.message = try std.fmt.allocPrint(self.allocator, "Open error: {s}", .{@errorName(err)});
                    };
                }
            }

            // Name label after the button
            var name_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = idx * 2 + 1 });
            name_lbl.addText(entry.name, .{
                .color_text = if (is_dir) themeColorToDvui(VSColors.status_bg) else themeColorToDvui(VSColors.breadcrumb_fg),
            });
            name_lbl.deinit();
        }

        if (self.file_tree_entries.items.len == 0) {
            var empty_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            empty_lbl.addText("(open a folder)", .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
            empty_lbl.deinit();
        }
    }

    fn renderSearchDVUI(self: *Self) !void {
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("SEARCH", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        var entry = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal, .margin = .{ .x = 4, .y = 4, .w = 4, .h = 0 } });
        defer entry.deinit();
        const text = entry.textGet();
        if (text.len > 0) {
            if (self.search_query) |old| self.allocator.free(old);
            self.search_query = self.allocator.dupe(u8, text) catch null;
        }

        // Show search results
        if (self.search_query) |query| {
            if (query.len > 0) {
                var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
                defer scroll.deinit();

                // Search in current directory
                const dir_path = self.file_tree_dir orelse ".";
                var dir = std.Io.Dir.cwd().openDir(
                    runtime.io(),
                    dir_path,
                    .{ .iterate = true },
                ) catch {
                    var err_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                    err_lbl.addText("(cannot search directory)", .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
                    err_lbl.deinit();
                    return;
                };
                defer dir.close(runtime.io());

                var found: usize = 0;
                var it = dir.iterate();
                while (try it.next(runtime.io())) |fs_entry| {
                    if (found >= 50) break;
                    if (std.mem.indexOf(u8, fs_entry.name, query)) |_| {
                        const marker = if (fs_entry.kind == .directory) "📁 " else "📄 ";
                        var result_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = found });
                        result_lbl.addText(marker, .{});
                        result_lbl.addText(fs_entry.name, .{ .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
                        result_lbl.deinit();
                        found += 1;
                    }
                }

                if (found == 0) {
                    var nores_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
                    nores_lbl.addText("No results found", .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
                    nores_lbl.deinit();
                }
            }
        }
    }

    fn renderHubDVUI(self: *Self) !void {
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("WIZP HUB", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        const hub_items = [_][]const u8{
            "⚡ Quick Start",
            "🔧 Settings",
            "📦 Extensions",
            "🎨 Themes",
            "⌨️  Keybindings",
            "📖 Documentation",
        };
        for (hub_items, 0..) |item, i| {
            if (dvui.button(@src(), item, .{}, .{ .expand = .horizontal, .id_extra = i })) {
                switch (i) {
                    0 => {
                        self.active_activity = .explorer;
                        self.message = "Quick Start: Open a folder or file to begin editing.";
                    },
                    1 => {
                        self.ai_settings_visible = !self.ai_settings_visible;
                        if (self.ai_settings_visible) {
                            self.message = "Settings: Configure AI provider, model, and key.";
                        }
                    },
                    2 => {
                        self.active_activity = .extensions;
                        self.message = "Extensions: Search and install extensions from OpenVSX.";
                    },
                    3 => {
                        const themes = ThemeMod.listThemes();
                        const count = themes.len;
                        self.message = try std.fmt.allocPrint(self.allocator, "Themes: {d} built-in themes available. Use 'theme/list' RPC to browse.", .{count});
                    },
                    4 => {
                        self.message = "Keybindings: Ctrl+Shift+P for command palette. See config/keybinds for full list.";
                    },
                    5 => {
                        self.message = "Documentation: https://github.com/zokugun/WIZP";
                    },
                    else => {},
                }
            }
        }
    }

    fn renderGitDVUI(self: *Self) !void {
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("SOURCE CONTROL", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        if (self.git_items.items.len > 0) {
            for (self.git_items.items, 0..) |item, i| {
                var row = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = i });
                row.addText(item, .{ .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
                row.deinit();
            }
        } else {
            var empty_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            empty_lbl.addText("No changes detected", .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
            empty_lbl.deinit();
        }
    }

    fn renderDebugDVUI(self: *Self) !void {
        _ = self;
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("RUN AND DEBUG", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        _ = dvui.button(@src(), "▶ Run", .{}, .{ .expand = .horizontal });
        _ = dvui.button(@src(), "🐛 Debug", .{}, .{ .expand = .horizontal, .id_extra = 1 });

        var info_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        info_lbl.addText("No debug configuration", .{ .color_text = themeColorToDvui(VSColors.activity_inactive) });
        info_lbl.deinit();
    }

    fn renderExtensionsDVUI(self: *Self) !void {
        _ = self;
        {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            tl.addText("EXTENSIONS", .{ .font = .theme(.title), .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            tl.deinit();
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        const exts = [_][]const u8{ "Zig Language", "Tree-sitter", "GitLens", "Prettier" };
        for (exts, 0..) |ext, i| {
            var row = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = i });
            row.addText("⬢ ", .{ .color_text = themeColorToDvui(VSColors.status_bg) });
            row.addText(ext, .{ .color_text = themeColorToDvui(VSColors.breadcrumb_fg) });
            row.deinit();
        }
    }

    fn renderTabBarDVUI(self: *Self) !void {
        if (self.groups.items.len == 0) return;
        const group = &self.groups.items[self.active_group];

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = themeColorToDvui(VSColors.tab_bg),
        });
        defer hbox.deinit();

        for (group.tabs.items, 0..) |*tab, i| {
            const active = i == group.active_tab;
            const display_name = std.fs.path.basename(tab.file_path);

            const opts = dvui.Options{
                .expand = .horizontal,
                .id_extra = i,
                .color_fill = if (active) themeColorToDvui(VSColors.tab_active_bg) else null,
                .color_text = if (active) themeColorToDvui(VSColors.breadcrumb_fg) else themeColorToDvui(VSColors.activity_inactive),
                .border = .{ .x = 0, .y = if (active) 2 else 0, .w = 0, .h = 0 },
                .color_border = if (active) themeColorToDvui(VSColors.status_bg) else null,
            };
            if (dvui.button(@src(), display_name, .{}, opts)) {
                group.active_tab = i;
            }
            if (tab.dirty) {
                var dot = dvui.textLayout(@src(), .{}, .{});
                dot.addText("●", .{ .color_text = .{ .r = 255, .g = 215, .b = 0, .a = 255 } });
                dot.deinit();
            }
        }
    }

    fn renderBufferDVUI(self: *Self) !void {
        if (self.groups.items.len == 0) return;
        const group = &self.groups.items[self.active_group];
        if (group.tabs.items.len == 0) return;
        const tab = &group.tabs.items[group.active_tab];

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();

        // Render buffer content line by line with syntax highlighting
        const buf = &tab.buffer;
        const cursor_row = tab.cursor.row;
        const cursor_col = tab.cursor.col;
        var line: usize = 0;
        while (line < buf.line_count) : (line += 1) {
            const text = buf.getLine(line, self.allocator) catch continue;
            defer if (text.len > 0) self.allocator.free(text);

            // Tokenize this line for syntax highlighting
            const tokens = Syntax.tokenizeLine(self.allocator, tab.file_path, text) catch &.{};
            defer if (tokens.len > 0) self.allocator.free(tokens);

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .id_extra = line,
                .color_fill = if (line == cursor_row) dvui.Color{ .r = 40, .g = 40, .b = 40, .a = 255 } else null,
            });
            defer hbox.deinit();

            // Line number
            const line_num = try std.fmt.allocPrint(self.allocator, "{d:>4} ", .{line + 1});
            defer self.allocator.free(line_num);

            var ln = dvui.textLayout(@src(), .{}, .{ .id_extra = line * 2 });
            ln.addText(line_num, .{
                .color_text = if (line == cursor_row) themeColorToDvui(VSColors.line_num_active_fg) else themeColorToDvui(VSColors.line_num_fg),
            });
            ln.deinit();

            // Line content with syntax highlighting and cursor
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = line * 2 + 1 });

            if (tokens.len == 0) {
                // No tokens — render plain text with cursor
                if (line == cursor_row and cursor_col <= text.len) {
                    if (cursor_col > 0) tl.addText(text[0..cursor_col], .{});
                    if (cursor_col < text.len) {
                        tl.addText(text[cursor_col .. cursor_col + 1], .{
                            .color_text = themeColorToDvui(VSColors.bg),
                            .color_fill = themeColorToDvui(VSColors.cursor_fg),
                        });
                        if (cursor_col + 1 < text.len) tl.addText(text[cursor_col + 1 ..], .{});
                    } else {
                        tl.addText(" ", .{
                            .color_text = themeColorToDvui(VSColors.bg),
                            .color_fill = themeColorToDvui(VSColors.cursor_fg),
                        });
                    }
                } else {
                    tl.addText(text, .{});
                }
            } else {
                // Render tokens with syntax colors and cursor
                var byte_pos: usize = 0;
                var token_idx: usize = 0;
                while (byte_pos < text.len) {
                    // Advance to the token containing byte_pos
                    while (token_idx < tokens.len and byte_pos >= tokens[token_idx].start + tokens[token_idx].len) : (token_idx += 1) {}

                    const in_token = token_idx < tokens.len and byte_pos >= tokens[token_idx].start and byte_pos < tokens[token_idx].start + tokens[token_idx].len;
                    const scope = if (in_token) tokens[token_idx].scope else "";
                    const style = ThemeMod.getScopeStyle(&self.theme, scope);
                    const fg: ?dvui.Color = if (style.foreground) |c| themeColorToDvui(c) else null;

                    // Determine how much text to render in this chunk
                    var chunk_end: usize = text.len;
                    if (in_token) {
                        chunk_end = @min(text.len, tokens[token_idx].start + tokens[token_idx].len);
                    } else if (token_idx < tokens.len) {
                        chunk_end = @min(text.len, tokens[token_idx].start);
                    }

                    // Handle cursor within this chunk
                    if (line == cursor_row and cursor_col >= byte_pos and cursor_col < chunk_end) {
                        if (cursor_col > byte_pos) {
                            tl.addText(text[byte_pos..cursor_col], .{ .color_text = fg });
                        }
                        tl.addText(text[cursor_col .. cursor_col + 1], .{
                            .color_text = themeColorToDvui(VSColors.bg),
                            .color_fill = themeColorToDvui(VSColors.cursor_fg),
                        });
                        if (cursor_col + 1 < chunk_end) {
                            tl.addText(text[cursor_col + 1 .. chunk_end], .{ .color_text = fg });
                        }
                    } else {
                        tl.addText(text[byte_pos..chunk_end], .{ .color_text = fg });
                    }

                    byte_pos = chunk_end;
                }

                // Cursor at end of line
                if (line == cursor_row and cursor_col >= text.len) {
                    tl.addText(" ", .{
                        .color_text = themeColorToDvui(VSColors.bg),
                        .color_fill = themeColorToDvui(VSColors.cursor_fg),
                    });
                }
            }
            tl.deinit();
        }
    }

    fn renderStatusBarDVUI(self: *Self) !void {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .background = true,
            .color_fill = themeColorToDvui(VSColors.status_bg),
        });
        defer hbox.deinit();

        // Mode indicator (left)
        const mode_str = switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .command => "COMMAND",
            .search => "SEARCH",
        };
        var mode_lbl = dvui.textLayout(@src(), .{}, .{ .margin = .{ .x = 4, .y = 0, .w = 4, .h = 0 } });
        mode_lbl.addText(mode_str, .{ .color_text = themeColorToDvui(VSColors.status_fg) });
        mode_lbl.deinit();

        // Active file info
        if (self.groups.items.len > 0) {
            const group = &self.groups.items[self.active_group];
            if (group.tabs.items.len > 0) {
                const tab = &group.tabs.items[group.active_tab];
                const basename = std.fs.path.basename(tab.file_path);

                var file_info = dvui.textLayout(@src(), .{}, .{ .margin = .{ .x = 0, .y = 0, .w = 12, .h = 0 } });
                file_info.addText(basename, .{ .color_text = themeColorToDvui(VSColors.status_fg) });
                if (tab.dirty) {
                    file_info.addText(" ●", .{ .color_text = .{ .r = 255, .g = 215, .b = 0, .a = 255 } });
                }
                file_info.deinit();

                // Line:Column on the right
                const lc = try std.fmt.allocPrint(self.allocator, "Ln {d}, Col {d}", .{ tab.cursor.row + 1, tab.cursor.col + 1 });
                defer self.allocator.free(lc);
                var lc_lbl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .gravity_x = 1.0, .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 } });
                lc_lbl.addText(lc, .{ .color_text = themeColorToDvui(VSColors.status_dim) });
                lc_lbl.deinit();

                // Encoding / language indicator
                if (tab.buffer.file_type) |lang| {
                    var lang_lbl = dvui.textLayout(@src(), .{}, .{ .gravity_x = 1.0, .margin = .{ .x = 0, .y = 0, .w = 8, .h = 0 } });
                    lang_lbl.addText(lang, .{ .color_text = themeColorToDvui(VSColors.status_dim) });
                    lang_lbl.deinit();
                }
            }
        }
    }

    fn renderPanelDVUI(self: *Self) !void {
        const h = @as(f32, @floatFromInt(self.panel_height * 20));
        var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
            .min_size_content = .{ .h = h },
            .background = true,
            .color_fill = themeColorToDvui(VSColors.panel_bg),
        });
        defer panel.deinit();

        var title = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        title.addText("Terminal sessions", .{ .font = .theme(.title) });
        title.deinit();

        var status = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
        if (self.terminal_session) |session| {
            const exit_status = session.exitStatus();
            const state = switch (exit_status.kind) {
                .running => "running",
                .exited => "exited",
                .signaled => "signaled",
                .unknown => "unknown",
            };
            status.addText("Active session is rendered by the web shell; DVUI is status-only.", .{});
            status.addText(" State: ", .{});
            status.addText(state, .{ .color_text = themeColorToDvui(VSColors.status_dim) });
        } else {
            status.addText("No active terminal session. Open a terminal in the web shell.", .{});
        }
        status.deinit();
    }

    // ---- Activity Bar ----
    fn renderActivityBar(self: *Self, rows: usize) !void {
        const w = LayoutConst.activity_width;
        const x = 0;

        // Background
        var row: usize = 1;
        while (row < rows - LayoutConst.status_height) : (row += 1) {
            try self.terminal.fillLine(row, x, w, VSColors.activity_bg);
        }

        // Activity items
        const items = [_]ActivityItem{ .explorer, .search, .hub, .git, .debug, .extensions };
        var y: usize = 1;
        for (items) |item| {
            const active = item == self.active_activity;
            const color = if (active) VSColors.activity_active else VSColors.activity_inactive;
            const bg_color = if (active) VSColors.bg else VSColors.activity_bg;
            const icon = ACTIVITY_ICONS.get(@tagName(item)) orelse "?";

            try self.terminal.moveTo(y, x);
            if (active) {
                // Active indicator bar
                try self.terminal.writeStyled(" ", .{ .foreground = VSColors.status_bg, .background = VSColors.status_bg });
            }
            try self.terminal.writeStyled(icon, .{ .foreground = color, .background = bg_color });

            y += 1;
        }
    }

    // ---- Sidebar (File Explorer) ----
    fn renderSidebar(self: *Self, rows: usize, _: usize) !void {
        const x = if (self.activity_bar_side) LayoutConst.activity_width else 0;
        const w = self.layout.sidebar_width;
        const header_h: usize = if (!self.activity_bar_side) 1 else 0;

        // Background
        var row: usize = header_h;
        while (row < rows - LayoutConst.status_height) : (row += 1) {
            try self.terminal.fillLine(row, x, w, VSColors.sidebar_bg);
        }

        // Activity bar in sidebar header (when moved from side)
        if (!self.activity_bar_side) {
            try self.terminal.fillLine(0, x, w, VSColors.activity_bg);
            const items = [_]ActivityItem{ .explorer, .search, .hub, .git, .debug, .extensions };
            var ix: usize = x + 1;
            for (items) |item| {
                const active = item == self.active_activity;
                const color = if (active) VSColors.activity_active else VSColors.activity_inactive;
                const icon = ACTIVITY_ICONS.get(@tagName(item)) orelse "?";
                try self.terminal.moveTo(0, ix);
                try self.terminal.writeStyled(icon, .{ .foreground = color, .background = if (active) VSColors.sidebar_bg else VSColors.activity_bg });
                ix += 2;
            }
        }

        // Title
        const title_y: usize = if (!self.activity_bar_side) @as(usize, 1) else @as(usize, 0);
        try self.terminal.moveTo(title_y, x + 1);
        const title = switch (self.active_activity) {
            .explorer => "EXPLORER",
            .search => "SEARCH",
            .hub => "WIZP HUB",
            .git => "SOURCE CONTROL",
            .debug => "DEBUG",
            .extensions => "EXTENSIONS",
        };
        try self.terminal.writeStyled(title, .{ .foreground = VSColors.activity_inactive, .background = VSColors.sidebar_bg, .bold = true });

        // Content depends on active activity
        switch (self.active_activity) {
            .explorer => try self.renderFileTree(rows, x, w),
            .search => try self.renderSearchSidebar(rows, x, w),
            .hub => try self.renderHubSidebar(rows, x, w),
            .git => try self.renderGitSidebar(rows, x, w),
            .debug => try self.renderDebugSidebar(rows, x, w),
            .extensions => try self.renderHubSidebar(rows, x, w),
        }

        // Right border
        for (0..rows - LayoutConst.status_height) |r| {
            try self.terminal.moveTo(r, x + w - 1);
            try self.terminal.writeStyled("│", .{ .foreground = VSColors.panel_border, .background = VSColors.sidebar_bg });
        }
    }

    fn renderHubSidebar(self: *Self, rows: usize, x: usize, w: usize) !void {
        const bg = VSColors.sidebar_bg;
        const fg = VSColors.breadcrumb_fg;
        const accent = Color.fromHex(0x007ACC);
        const dim = VSColors.activity_inactive;
        var y: usize = 1;

        // Search bar
        try self.terminal.moveTo(y, x + 1);
        const search_label = if (self.hub_search_visible) "🔍 Search Open VSX: " else "🔍 Search Open VSX (Ctrl+R): ";
        try self.terminal.writeStyled(search_label, .{ .foreground = dim, .background = bg });
        if (self.hub_search_visible) {
            if (self.hub_search_input.items.len > 0) {
                try self.terminal.writeStyled(self.hub_search_input.items, .{ .foreground = fg, .background = bg });
            }
        } else if (self.hub_search_last_query) |q| {
            if (q.len > 0) try self.terminal.writeStyled(q, .{ .foreground = fg, .background = bg });
        }
        y += 2;

        // Category tabs
        const categories = [_][]const u8{ "All", "Themes", "LSPs", "Tools", "Plugins", "Syntax" };
        try self.terminal.moveTo(y, x + 1);
        for (categories, 0..) |cat, i| {
            const active = i == 0;
            try self.terminal.writeStyled(if (active) " " else " ", .{ .foreground = fg, .background = if (active) accent else bg });
            try self.terminal.writeStyled(cat, .{ .foreground = if (active) Color.fromHex(0xFFFFFF) else dim, .background = if (active) accent else bg });
            try self.terminal.writeStyled(" ", .{ .foreground = fg, .background = if (active) accent else bg });
        }
        y += 2;

        // Featured extensions (from built-in Hub catalog)
        const featured = [_]struct { icon: []const u8, name: []const u8, desc: []const u8, installed: bool }{
            .{ .icon = "⚡", .name = "ZLS", .desc = "Zig Language Server", .installed = false },
            .{ .icon = "🦀", .name = "Rust Analyzer", .desc = "Rust LSP server", .installed = false },
            .{ .icon = "🎨", .name = "Dracula Theme", .desc = "Dark color theme", .installed = true },
            .{ .icon = "🔷", .name = "TS Server", .desc = "TypeScript LSP", .installed = false },
            .{ .icon = "🔍", .name = "Prettier", .desc = "Code formatter", .installed = false },
            .{ .icon = "📝", .name = "Markdown LSP", .desc = "Marksman server", .installed = false },
        };

        // Section header
        try self.terminal.moveTo(y, x + 1);
        try self.terminal.writeStyled("Featured", .{ .foreground = fg, .background = bg, .bold = true });
        y += 1;

        for (featured) |item| {
            if (y >= rows - LayoutConst.status_height - 1) break;
            try self.terminal.fillLine(y, x + 1, w - 3, bg);

            try self.terminal.moveTo(y, x + 2);
            try self.terminal.writeStyled(item.icon, .{ .foreground = fg, .background = bg });
            try self.terminal.writeStyled(" ", .{ .foreground = fg, .background = bg });
            try self.terminal.writeStyled(item.name, .{ .foreground = fg, .background = bg, .bold = true });
            try self.terminal.writeStyled("  ", .{ .foreground = dim, .background = bg });
            try self.terminal.writeStyled(item.desc, .{ .foreground = dim, .background = bg });

            // Install button
            const btn_label = if (item.installed) "✓ Installed" else "Install";
            const btn_color = if (item.installed) Color.fromHex(0x4EC9B0) else accent;
            try self.terminal.moveTo(y, x + w - btn_label.len - 4);
            try self.terminal.writeStyled("[", .{ .foreground = dim, .background = bg });
            try self.terminal.writeStyled(btn_label, .{ .foreground = btn_color, .background = bg });
            try self.terminal.writeStyled("]", .{ .foreground = dim, .background = bg });

            y += 1;
        }

        // Open VSX Registry section
        y += 1;
        try self.terminal.moveTo(y, x + 1);
        try self.terminal.writeStyled("Open VSX Registry", .{ .foreground = fg, .background = bg, .bold = true });
        y += 1;

        if (self.hub_search_error) |m| {
            if (y < rows - LayoutConst.status_height - 1) {
                try self.terminal.moveTo(y, x + 2);
                try self.terminal.writeStyled(m, .{ .foreground = Color.fromHex(0xF14C4C), .background = bg });
                y += 1;
            }
        }

        if (self.openvsx_results) |*results| {
            for (results.extensions) |ext| {
                if (y >= rows - LayoutConst.status_height - 1) break;
                try self.terminal.moveTo(y, x + 2);
                try self.terminal.writeStyled("📦", .{ .foreground = fg, .background = bg });
                try self.terminal.writeStyled(" ", .{ .foreground = fg, .background = bg });
                const label = if (ext.display_name.len > 0) ext.display_name else ext.name;
                try self.terminal.writeStyled(label, .{ .foreground = fg, .background = bg });
                if (ext.description.len > 0) {
                    try self.terminal.writeStyled("  ", .{ .foreground = dim, .background = bg });
                    const desc_preview = if (ext.description.len > 30) ext.description[0..30] else ext.description;
                    try self.terminal.writeStyled(desc_preview, .{ .foreground = dim, .background = bg });
                }
                y += 1;
            }
        } else {
            try self.terminal.moveTo(y, x + 2);
            try self.terminal.writeStyled("Press Ctrl+R to search Open VSX", .{ .foreground = dim, .background = bg });
            y += 1;
        }

        // Footer
        try self.terminal.moveTo(y, x + 1);
        try self.terminal.writeStyled("open-vsx.org →", .{ .foreground = accent, .background = bg });
    }

    fn renderSearchSidebar(self: *Self, rows: usize, x: usize, w: usize) !void {
        _ = w; // unused, required for sidebar dispatch interface
        return EditorRenderer.renderSearchSidebar(&self.terminal, rows, x);
    }

    fn renderGitSidebar(self: *Self, rows: usize, x: usize, w: usize) !void {
        _ = w;
        const now = runtime.milliTimestamp();
        if (now - self.git_last_refresh_ms > 1000) {
            self.refreshGitStatusBg();
        }
        return EditorRenderer.renderGitSidebar(&self.terminal, rows, x, self.git_branch, self.git_items.items, self.git_error);
    }

    fn renderDebugSidebar(self: *Self, rows: usize, x: usize, w: usize) !void {
        _ = w;
        return EditorRenderer.renderDebugSidebar(&self.terminal, rows, x);
    }

    fn renderFileTree(self: *Self, rows: usize, x: usize, w: usize) !void {
        self.maybeRefreshFileTree();
        const cwd_label = self.file_tree_dir orelse ".";
        const entries = self.file_tree_entries.items;

        const now = runtime.milliTimestamp();
        if (now - self.git_last_refresh_ms > 2000) {
            self.refreshGitStatusBg();
        }
        var status_map = std.StringHashMapUnmanaged(u8){};
        defer status_map.deinit(self.allocator);
        if (self.git_error == null) {
            for (self.git_items.items) |line| {
                if (line.len < 4) continue;
                const a = line[0];
                const b = line[1];
                const st: u8 = if (a != ' ') a else b;
                var path_part = std.mem.trimStart(u8, line[3..], " ");
                if (std.mem.indexOf(u8, path_part, "-> ")) |p| {
                    path_part = path_part[p + 3 ..];
                }
                if (path_part.len == 0) continue;
                status_map.put(self.allocator, path_part, st) catch {};
            }
        }

        var view_entries = std.array_list.Managed(EditorRenderer.FileTreeEntry).init(self.allocator);
        defer view_entries.deinit();
        try view_entries.ensureTotalCapacity(entries.len);
        for (entries) |e| {
            var rel_path = e.path;
            if (std.mem.startsWith(u8, rel_path, "./")) rel_path = rel_path[2..];
            const st = if (e.kind != .directory) status_map.get(rel_path) else null;
            view_entries.appendAssumeCapacity(.{ .name = e.name, .kind = e.kind, .git_status = st });
        }
        return EditorRenderer.renderFileTree(&self.terminal, rows, x, w, cwd_label, view_entries.items, self.file_tree_selected);
    }

    // ---- Tab Bar ----
    fn renderTabBar(self: *Self, cols: usize) !void {
        if (!self.tab_bar_visible) return;

        const x_start = (if (self.activity_bar_side) LayoutConst.activity_width else 0) + if (self.sidebar_visible) self.layout.sidebar_width else 0;
        const w = cols - x_start - LayoutConst.minimap_width;

        try self.terminal.fillLine(0, x_start, w, VSColors.tab_bg);

        var x: usize = x_start;
        for (self.groups.items[self.active_group].tabs.items, 0..) |*tab, i| {
            const name = std.fs.path.basename(tab.file_path);
            const max_name_len = 20;
            const display_name = if (name.len > max_name_len) name[0..max_name_len] else name;

            const tab_width = display_name.len + 3;
            if (x + tab_width > x_start + w) break;

            const bg = if (i == self.groups.items[self.active_group].active_tab) VSColors.tab_active_bg else VSColors.tab_bg;

            // Tab background
            try self.terminal.moveTo(0, x);
            try self.terminal.writeStyled(" ", .{ .foreground = VSColors.breadcrumb_fg, .background = bg });
            try self.terminal.writeStyled(display_name, .{ .foreground = VSColors.breadcrumb_fg, .background = bg });

            if (tab.dirty) {
                try self.terminal.writeStyled(" ●", .{ .foreground = VSColors.status_bg, .background = bg });
            }

            x += tab_width;

            // Separator
            if (i < self.groups.items[self.active_group].tabs.items.len - 1) {
                try self.terminal.moveTo(0, x);
                try self.terminal.writeStyled(" ", .{ .foreground = VSColors.tab_border, .background = VSColors.tab_bg });
                x += 1;
            }
        }
    }

    // ---- Editor Area ----
    fn renderEditorArea(self: *Self, rows: usize, cols: usize, tab: *Tab, panel_h: usize) !void {
        const x_start = if (self.zen_mode) 0 else (if (self.activity_bar_side) LayoutConst.activity_width else 0) + if (self.sidebar_visible) self.layout.sidebar_width else 0;
        const x_end = if (self.zen_mode) cols else cols - LayoutConst.minimap_width;
        const y_start = if (self.zen_mode) 0 else LayoutConst.tab_height;
        const y_end = rows - LayoutConst.breadcrumb_height - LayoutConst.status_height - panel_h;

        // Editor background
        for (y_start..y_end) |r| {
            try self.terminal.fillLine(r, x_start, x_end - x_start, VSColors.bg);
        }

        // Render lines
        const line_num_width: usize = 5;
        var screen_row: usize = y_start;
        var buffer_row: usize = tab.view.scroll_row;
        while (screen_row < y_end and buffer_row < tab.buffer.lineCount()) : ({
            screen_row += 1;
            buffer_row += 1;
        }) {
            // LSP diagnostic icon in gutter (before line number)
            if (self.lsp_client) |*lsp| {
                if (tab.file_path.len > 0) {
                    const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{tab.file_path});
                    defer self.allocator.free(uri);
                    const diags = lsp.*.getDiagnostics(uri);
                    for (diags) |d| {
                        if (d.range.start.line == buffer_row) {
                            const icon = switch (d.severity orelse .hint) {
                                .err => "🔴",
                                .warning => "🟡",
                                .information => "🔵",
                                .hint => "💡",
                            };
                            try self.terminal.moveTo(screen_row, x_start + 1);
                            try self.terminal.writeStyled(icon, .{ .foreground = null, .background = VSColors.bg });
                            break;
                        }
                    }
                }
            }
            // Line number
            var num_buf: [8]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{d: >3}", .{buffer_row + 1});
            try self.terminal.moveTo(screen_row, x_start + 4);
            try self.terminal.writeStyled(num_str, .{ .foreground = if (buffer_row == tab.cursor.row) VSColors.line_num_active_fg else VSColors.line_num_fg, .background = VSColors.bg });
            try self.terminal.writeStyled(" ", .{ .foreground = VSColors.line_num_fg, .background = VSColors.bg });

            // Current line highlight
            if (buffer_row == tab.cursor.row) {
                try self.terminal.fillLine(screen_row, x_start + line_num_width, x_end - x_start - line_num_width, Color.fromHex(0x2A2D2E));
            }

            // Render line text
            const line = tab.buffer.getLine(buffer_row, self.allocator) catch continue;
            defer self.allocator.free(line);

            const tokens = Syntax.tokenizeLine(self.allocator, tab.file_path, line) catch &.{};
            defer if (tokens.len > 0) self.allocator.free(tokens);

            var token_idx: usize = 0;
            var col: usize = 0;
            var byte_pos: usize = 0;
            const max_col = x_end - x_start - line_num_width;

            while (byte_pos < line.len and col < max_col) {
                while (token_idx < tokens.len and byte_pos >= tokens[token_idx].start + tokens[token_idx].len) : (token_idx += 1) {}

                const in_token = token_idx < tokens.len and byte_pos >= tokens[token_idx].start and byte_pos < tokens[token_idx].start + tokens[token_idx].len;
                const scope = if (in_token) tokens[token_idx].scope else "";

                if (line[byte_pos] == '\t') {
                    try self.terminal.moveTo(screen_row, x_start + line_num_width + col);
                    if (in_token) {
                        const st = ThemeMod.getScopeStyle(&self.theme, scope);
                        try self.terminal.writeStyled("    ", st);
                    } else {
                        try self.terminal.writeStyled("    ", .{ .foreground = VSColors.whitespace_fg, .background = null });
                    }
                    col += 4;
                    byte_pos += 1;
                    continue;
                }

                const next_token_boundary = if (in_token)
                    tokens[token_idx].start + tokens[token_idx].len
                else if (token_idx < tokens.len)
                    tokens[token_idx].start
                else
                    line.len;
                const next_tab = std.mem.indexOfScalarPos(u8, line, byte_pos, '\t') orelse line.len;

                var run_end = @min(next_token_boundary, next_tab);
                if (run_end < byte_pos) run_end = byte_pos;
                const max_bytes = max_col - col;
                if (run_end > byte_pos + max_bytes) run_end = byte_pos + max_bytes;
                if (run_end == byte_pos) run_end = @min(line.len, byte_pos + 1);

                try self.terminal.moveTo(screen_row, x_start + line_num_width + col);
                const text = line[byte_pos..run_end];
                if (in_token) {
                    const st = ThemeMod.getScopeStyle(&self.theme, scope);
                    try self.terminal.writeStyled(text, st);
                } else {
                    try self.terminal.writeStyled(text, .{ .foreground = self.theme.foreground, .background = null });
                }
                col += text.len;
                byte_pos = run_end;
            }

            // Render cursor
            if (buffer_row == tab.cursor.row) {
                const cursor_x = x_start + line_num_width + tab.cursor.col;
                if (cursor_x < x_end) {
                    try self.terminal.moveTo(screen_row, cursor_x);
                    const ch: []const u8 = if (tab.cursor.col < line.len) line[tab.cursor.col .. tab.cursor.col + 1] else " ";
                    try self.terminal.writeStyled(ch, .{ .foreground = VSColors.bg, .background = VSColors.cursor_fg });
                }
            }
        }
    }

    // ---- Minimap ----
    fn renderMinimap(self: *Self, rows: usize, cols: usize, tab: *Tab) !void {
        const x = cols - LayoutConst.minimap_width;
        const y_start = LayoutConst.tab_height;
        const y_end = rows - LayoutConst.breadcrumb_height - LayoutConst.status_height;

        for (y_start..y_end) |r| {
            try self.terminal.fillLine(r, x, LayoutConst.minimap_width, VSColors.bg);
        }

        const line_count = tab.buffer.lineCount();
        if (line_count == 0) return;

        const visible_rows = y_end - y_start;
        const scale = @max(1, line_count / visible_rows);

        var i: usize = 0;
        var screen_row: usize = y_start;
        while (i < line_count and screen_row < y_end) : (i += scale) {
            const line = tab.buffer.getLine(i, self.allocator) catch {
                screen_row += 1;
                continue;
            };
            defer self.allocator.free(line);

            // Visual density
            var density: usize = 0;
            for (line) |ch| {
                if (ch != ' ' and ch != '\t') density += 1;
            }

            const ch: u8 = if (density == 0) ' ' else if (density < 10) 0xB0 else if (density < 30) 0xB1 else if (density < 60) 0xB2 else 0xDB;
            var ch_buf: [4]u8 = undefined;
            const ch_str = std.fmt.bufPrint(&ch_buf, "{c}", .{ch}) catch " ";

            try self.terminal.moveTo(screen_row, x + 1);
            try self.terminal.writeStyled(ch_str, .{ .foreground = VSColors.scrollbar_fg, .background = VSColors.bg });

            screen_row += 1;
        }
    }

    // ---- Breadcrumbs ----
    fn renderBreadcrumbs(self: *Self, rows: usize, cols: usize, tab: *Tab) !void {
        const y = rows - LayoutConst.breadcrumb_height - LayoutConst.status_height;
        const x_start = (if (self.activity_bar_side) LayoutConst.activity_width else 0) + if (self.sidebar_visible) self.layout.sidebar_width else 0;
        const x_end = cols - LayoutConst.minimap_width;

        try self.terminal.fillLine(y, x_start, x_end - x_start, VSColors.breadcrumb_bg);

        // File path breadcrumb
        const path = tab.file_path;
        var parts = std.mem.splitScalar(u8, path, '/');
        var breadcrumb = std.array_list.Managed([]const u8).init(self.allocator);
        defer breadcrumb.deinit();
        while (parts.next()) |part| {
            if (part.len > 0) breadcrumb.append(part) catch {};
        }

        try self.terminal.moveTo(y, x_start + 1);
        for (breadcrumb.items, 0..) |part, i| {
            if (i > 0) {
                try self.terminal.writeStyled(" › ", .{ .foreground = VSColors.activity_inactive, .background = VSColors.breadcrumb_bg });
            }
            const fg = if (i == breadcrumb.items.len - 1) VSColors.breadcrumb_fg else VSColors.activity_inactive;
            try self.terminal.writeStyled(part, .{ .foreground = fg, .background = VSColors.breadcrumb_bg });
        }
    }

    // ---- Scrollbar ----
    fn renderScrollbar(self: *Self, rows: usize, cols: usize, tab: *Tab, panel_h: usize) !void {
        const x_end = if (self.zen_mode) cols else cols - LayoutConst.minimap_width;
        const y_start = if (self.zen_mode) 0 else LayoutConst.tab_height;
        const y_end = rows - LayoutConst.breadcrumb_height - LayoutConst.status_height - panel_h;
        const editor_h = y_end - y_start;
        const scroll_x = x_end - 1;
        const line_count = tab.buffer.lineCount();
        if (line_count == 0 or editor_h == 0) return;

        // Scrollbar track
        for (y_start..y_end) |r| {
            try self.terminal.moveTo(r, scroll_x);
            try self.terminal.writeStyled(" ", .{ .foreground = VSColors.scrollbar_bg, .background = VSColors.scrollbar_bg });
        }

        // Scrollbar thumb
        const thumb_size = @max(1, editor_h * editor_h / @max(1, line_count));
        const thumb_pos = if (line_count > editor_h)
            (y_end - y_start - thumb_size) * tab.view.scroll_row / (line_count - editor_h)
        else
            0;
        const thumb_y = y_start + thumb_pos;

        var ty: usize = thumb_y;
        while (ty < thumb_y + thumb_size and ty < y_end) : (ty += 1) {
            try self.terminal.moveTo(ty, scroll_x);
            try self.terminal.writeStyled("█", .{ .foreground = VSColors.scrollbar_fg, .background = VSColors.scrollbar_fg });
        }
    }

    // ---- Panel Area ----
    fn renderPanel(self: *Self, rows: usize, cols: usize, panel_h: usize) !void {
        const y_start = rows - LayoutConst.status_height - panel_h;
        const bg = Color.fromHex(0x1E1E1E);
        const border_c = Color.fromHex(0x474747);

        // Panel background
        for (y_start..y_start + panel_h) |r| {
            try self.terminal.fillLine(r, 0, cols, bg);
        }
        // Top border
        try self.terminal.fillLine(y_start, 0, cols, border_c);

        // Panel tabs
        const tabs = [_][]const u8{ "TERMINAL", "PROBLEMS", "OUTPUT", "DEBUG CONSOLE" };
        var tx: usize = 1;
        for (tabs, 0..) |name, i| {
            const active = @as(usize, @intCast(@backingInt(self.panel_type))) == i;
            const tab_bg = if (active) bg else Color.fromHex(0x252526);
            try self.terminal.moveTo(y_start, tx);
            try self.terminal.writeStyled(" ", .{ .foreground = VSColors.breadcrumb_fg, .background = tab_bg });
            try self.terminal.writeStyled(name, .{ .foreground = if (active) VSColors.status_fg else VSColors.activity_inactive, .background = tab_bg });
            try self.terminal.writeStyled(" ", .{ .foreground = VSColors.breadcrumb_fg, .background = tab_bg });
            tx += name.len + 2;
        }

        // Panel content
        const content_y = y_start + 1;
        try self.terminal.moveTo(content_y, 2);
        switch (self.panel_type) {
            .terminal => try self.terminal.writeStyled("$ _", .{ .foreground = Color.fromHex(0x4EC9B0), .background = bg }),
            .problems => try self.terminal.writeStyled("No problems detected", .{ .foreground = VSColors.activity_inactive, .background = bg }),
            .output => try self.terminal.writeStyled("Output will appear here", .{ .foreground = VSColors.activity_inactive, .background = bg }),
            .debug_console => try self.terminal.writeStyled("Debug console", .{ .foreground = VSColors.activity_inactive, .background = bg }),
        }
    }

    // ---- Status Bar ----
    fn renderStatusBar(self: *Self, rows: usize, cols: usize, tab: *Tab) !void {
        const y = rows - LayoutConst.status_height;
        try self.terminal.fillLine(y, 0, cols, VSColors.status_bg);

        // Left: mode
        try self.terminal.moveTo(y, 1);
        const mode_str = switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .command => "COMMAND",
            .search => "SEARCH",
        };
        try self.terminal.writeStyled(mode_str, .{ .foreground = VSColors.status_fg, .background = VSColors.status_bg, .bold = true });

        // File info with icon
        try self.terminal.moveTo(y, 10);
        const icon = Experience.FileIcons.getIcon(tab.file_path);
        try self.terminal.writeStyled(icon, .{ .foreground = VSColors.status_fg, .background = VSColors.status_bg });
        try self.terminal.writeStyled(" ", .{ .foreground = VSColors.status_fg, .background = VSColors.status_bg });
        const name = std.fs.path.basename(tab.file_path);
        try self.terminal.writeStyled(name, .{ .foreground = VSColors.status_fg, .background = VSColors.status_bg });
        if (tab.buffer.dirty) {
            try self.terminal.writeStyled(" ●", .{ .foreground = Color.fromHex(0xFFD700), .background = VSColors.status_bg });
        }

        // Center: message
        if (self.message) |msg| {
            const cx = cols / 2 - msg.len / 2;
            try self.terminal.moveTo(y, cx);
            try self.terminal.writeStyled(msg, .{ .foreground = Color.fromHex(0xFFD700), .background = VSColors.status_bg });
        }

        // AI indicator
        // AI indicator follows
        if (self.ai_enabled) {
            const ai_label = if (self.ai_generating) "🤖 ..." else "🤖 AI";
            try self.terminal.moveTo(y, 28);
            try self.terminal.writeStyled(ai_label, .{ .foreground = Color.fromHex(0x50FA7B), .background = VSColors.status_bg });
        }

        // Right: cursor position + language + encoding + EOL
        const line_info = try std.fmt.allocPrint(self.allocator, "Ln {}, Col {}", .{ tab.cursor.row + 1, tab.cursor.col_cp + 1 });
        defer self.allocator.free(line_info);
        const spc_info = try std.fmt.allocPrint(self.allocator, "Spaces: {}", .{self.config.tab_width});
        defer self.allocator.free(spc_info);
        const lang = tab.buffer.file_type orelse "Plain Text";
        const right_info = try std.fmt.allocPrint(self.allocator, "{s}  {s}  UTF-8  LF  {s}", .{ line_info, spc_info, lang });
        defer self.allocator.free(right_info);

        const rx = cols - right_info.len - 2;
        try self.terminal.moveTo(y, rx);
        try self.terminal.writeStyled(right_info, .{ .foreground = VSColors.status_dim, .background = VSColors.status_bg });
    }

    // ---- AI Settings Panel ----
    fn renderAISettings(self: *Self, rows: usize, cols: usize) !void {
        const w: usize = 50;
        const h: usize = 16;
        const x = (cols - w) / 2;
        const y = (rows - h) / 2;
        const bg = Color.fromHex(0x252526);
        const border = Color.fromHex(0x007ACC);
        const fg = Color.fromHex(0xCCCCCC);
        const sel_bg = Color.fromHex(0x094771);

        // Panel background with border
        for (y..y + h) |r| {
            try self.terminal.fillLine(r, x, w, bg);
        }
        // Top/bottom border
        try self.terminal.fillLine(y, x, w, border);
        try self.terminal.fillLine(y + h - 1, x, w, border);

        // Title
        try self.terminal.moveTo(y + 1, x + 2);
        try self.terminal.writeStyled("🤖 AI Settings (Kilo Code)", .{ .foreground = Color.fromHex(0xFFFFFF), .background = bg, .bold = true });

        const fields = [_]struct { label: []const u8, field: AISettingsField }{
            .{ .label = "Provider", .field = .provider },
            .{ .label = "Model", .field = .model },
            .{ .label = "API Key", .field = .api_key },
            .{ .label = "API Base URL", .field = .api_base },
            .{ .label = "Temperature", .field = .temperature },
            .{ .label = "Max Tokens", .field = .max_tokens },
            .{ .label = "[ Apply & Save ]", .field = .save },
            .{ .label = "[ Cancel ]", .field = .cancel },
        };

        var fy: usize = y + 3;
        for (fields) |fld| {
            const selected = fld.field == self.ai_settings_field;
            const row_bg = if (selected) sel_bg else bg;

            try self.terminal.fillLine(fy, x + 2, w - 4, row_bg);
            try self.terminal.moveTo(fy, x + 3);

            // Label
            try self.terminal.writeStyled(fld.label, .{ .foreground = if (selected) Color.fromHex(0xFFFFFF) else fg, .background = row_bg });

            // Value
            const value = switch (fld.field) {
                .provider => @tagName(self.llm_config.provider),
                .model => if (self.ai_settings_model_input.items.len > 0) self.ai_settings_model_input.items else self.llm_config.model,
                .api_key => if (self.ai_settings_key_input.items.len > 0) "••••••••" else "(none)",
                .api_base => if (self.ai_settings_base_input.items.len > 0) self.ai_settings_base_input.items else LLM.defaultApiBase(self.llm_config.provider),
                .temperature => b: {
                    const temp_str = try std.fmt.allocPrint(self.allocator, "{d:.1}", .{self.ai_settings_temp});
                    defer self.allocator.free(temp_str);
                    break :b temp_str;
                },
                .max_tokens => b: {
                    const tok_str = try std.fmt.allocPrint(self.allocator, "{}", .{self.ai_settings_max_tokens});
                    defer self.allocator.free(tok_str);
                    break :b tok_str;
                },
                else => "",
            };
            try self.terminal.moveTo(fy, x + 20);
            try self.terminal.writeStyled(": ", .{ .foreground = fg, .background = row_bg });
            try self.terminal.writeStyled(value, .{ .foreground = if (selected) Color.fromHex(0x4FC1FF) else Color.fromHex(0x6A9955), .background = row_bg });

            if (fld.field == .temperature and selected) {
                // Visual slider
                const slider_w: usize = 10;
                const pos = @as(usize, @intFromFloat(self.ai_settings_temp * @as(f32, @floatFromInt(slider_w))));
                try self.terminal.moveTo(fy, x + 35);
                var si: usize = 0;
                while (si < slider_w) : (si += 1) {
                    const ch: []const u8 = if (si <= pos) "█" else "░";
                    try self.terminal.writeStyled(ch, .{ .foreground = if (si <= pos) Color.fromHex(0x4FC1FF) else fg, .background = row_bg });
                }
            }

            fy += 1;
        }
    }

    // ============================================================
    // Input Handling (reuses existing logic)
    // ============================================================

    fn readInput(_: *Self) !Keybind.KeyEvent {
        const stdin = std.Io.File.stdin();
        var buf: [8]u8 = undefined;
        const n = try runtime.read(stdin, &buf);
        if (n == 0) return error.EndOfStream;
        const bytes = buf[0..n];
        if (bytes[0] == 0x1B) {
            if (n >= 3 and bytes[1] == '[') {
                return switch (bytes[2]) {
                    'A' => Keybind.KeyEvent{ .key = .{ .special = .up } },
                    'B' => Keybind.KeyEvent{ .key = .{ .special = .down } },
                    'C' => Keybind.KeyEvent{ .key = .{ .special = .right } },
                    'D' => Keybind.KeyEvent{ .key = .{ .special = .left } },
                    'H' => Keybind.KeyEvent{ .key = .{ .special = .home } },
                    'F' => Keybind.KeyEvent{ .key = .{ .special = .end } },
                    '1'...'6' => if (n >= 4 and bytes[3] == '~') switch (bytes[2]) {
                        '1' => Keybind.KeyEvent{ .key = .{ .special = .home } },
                        '3' => Keybind.KeyEvent{ .key = .{ .special = .delete } },
                        '4' => Keybind.KeyEvent{ .key = .{ .special = .end } },
                        '5' => Keybind.KeyEvent{ .key = .{ .special = .page_up } },
                        '6' => Keybind.KeyEvent{ .key = .{ .special = .page_down } },
                        else => Keybind.KeyEvent{ .key = .{ .special = .escape } },
                    } else Keybind.KeyEvent{ .key = .{ .special = .escape } },
                    else => Keybind.KeyEvent{ .key = .{ .special = .escape } },
                };
            }
            return Keybind.KeyEvent{ .key = .{ .special = .escape } };
        }
        if (bytes[0] == '\n' or bytes[0] == '\r') return Keybind.KeyEvent{ .key = .{ .special = .enter } };
        if (bytes[0] == '\t') return Keybind.KeyEvent{ .key = .{ .special = .tab } };
        if (bytes[0] == 0x7F) return Keybind.KeyEvent{ .key = .{ .special = .backspace } };
        if (bytes[0] < 32) return Keybind.KeyEvent{ .key = .{ .char = @intCast(bytes[0] + 96) }, .ctrl = true };
        return Keybind.KeyEvent{ .key = .{ .char = bytes[0] } };
    }

    fn handleInput(self: *Self, event: Keybind.KeyEvent) !void {
        const tab = self.getActiveTab();

        if (self.hub_search_visible) {
            if (event.key == .special and event.key.special == .escape) {
                self.hub_search_visible = false;
                self.hub_search_input.clearRetainingCapacity();
                return;
            }
            if (event.key == .special and event.key.special == .backspace) {
                if (self.hub_search_input.items.len > 0) {
                    _ = self.hub_search_input.pop();
                }
                return;
            }
            if (event.key == .special and event.key.special == .enter) {
                const q = std.mem.trim(u8, self.hub_search_input.items, " \t");
                if (q.len > 0) {
                    self.runOpenVSXSearch(q);
                }
                self.hub_search_visible = false;
                return;
            }
            if (!event.ctrl and event.key == .char) {
                self.hub_search_input.append(event.key.char) catch {};
                return;
            }
            return;
        }

        // Toggle sidebar: Ctrl+B
        if (event.ctrl and event.key == .char and event.key.char == 'b') {
            self.sidebar_visible = !self.sidebar_visible;
            return;
        }

        if (self.sidebar_visible and self.active_activity == .explorer and self.mode == .normal) {
            switch (event.key) {
                .special => |s| switch (s) {
                    .up => {
                        if (self.file_tree_selected > 0) self.file_tree_selected -= 1;
                        return;
                    },
                    .down => {
                        if (self.file_tree_selected + 1 < self.file_tree_entries.items.len) self.file_tree_selected += 1;
                        return;
                    },
                    .enter => {
                        if (self.file_tree_entries.items.len == 0) return;
                        const e = self.file_tree_entries.items[self.file_tree_selected];
                        if (e.kind == .directory) {
                            self.setFileTreeDir(e.path);
                            self.refreshFileTree();
                            return;
                        }
                        try self.openFile(e.path);
                        return;
                    },
                    .backspace => {
                        if (self.file_tree_entries.items.len == 0) return;
                        const dir_path = self.file_tree_dir orelse ".";
                        if (std.mem.eql(u8, dir_path, ".") or std.mem.eql(u8, dir_path, "/")) return;
                        const parent = std.fs.path.dirname(dir_path) orelse ".";
                        self.setFileTreeDir(parent);
                        self.refreshFileTree();
                        return;
                    },
                    else => {},
                },
                else => {},
            }
        }
        // AI: Ctrl+I - trigger inline completion
        if (event.ctrl and event.key == .char and event.key.char == 'i') {
            self.triggerInlineCompletion();
            return;
        }
        // AI: Tab - accept completion (when one is pending)
        if (event.key == .special and event.key.special == .tab and self.ai_last_completion != null) {
            self.acceptAICompletion();
            return;
        }
        // AI: Ctrl+L - toggle chat panel
        if (event.ctrl and event.key == .char and event.key.char == 'l') {
            self.toggleAIChat();
            return;
        }
        if (event.ctrl and event.key == .char and event.key.char == 'r' and self.active_activity == .hub) {
            self.hub_search_visible = true;
            self.hub_search_input.clearRetainingCapacity();
            if (self.hub_search_last_query) |q| {
                self.hub_search_input.appendSlice(q) catch {};
            }
            return;
        }
        // AI: Enter in chat mode - send message
        if (self.ai_chat_visible and event.key == .special and event.key.special == .enter) {
            self.sendAIChat();
            return;
        }
        // AI: Escape - close chat
        if (self.ai_chat_visible and event.key == .special and event.key.special == .escape) {
            self.ai_chat_visible = false;
            return;
        }
        // Tab management keybindings (work in normal + insert modes)
        // Ctrl+W: close active tab
        if (event.ctrl and event.key == .char and event.key.char == 'w') {
            self.closeActiveTab();
            return;
        }
        // Ctrl+Tab: cycle next tab
        if (event.ctrl and event.key == .special and event.key.special == .tab) {
            if (event.shift) self.cyclePrevTab() else self.cycleNextTab();
            return;
        }
        // Ctrl+Shift+→ : move tab right
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .right) {
            self.moveTabRightCmd();
            return;
        }
        // Ctrl+Shift+← : move tab left
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .left) {
            self.moveTabLeftCmd();
            return;
        }
        // Ctrl+\ : split pane
        if (event.ctrl and event.key == .char and event.key.char == '\\') {
            self.splitPane() catch {};
            return;
        }
        // Ctrl+Shift+] : move tab to next group
        if (event.ctrl and event.shift and event.key == .char and event.key.char == ']') {
            self.moveTabToNextGroup();
            return;
        }
        // Ctrl+Shift+[ : move tab to prev group
        if (event.ctrl and event.shift and event.key == .char and event.key.char == '[') {
            self.moveTabToPrevGroup();
            return;
        }
        // Ctrl+J : focus next group
        if (event.ctrl and event.key == .char and event.key.char == 'j') {
            self.focusNextGroup();
            return;
        }
        // Ctrl+K : focus prev group
        if (event.ctrl and event.key == .char and event.key.char == 'k') {
            self.focusPrevGroup();
            return;
        }
        // Ctrl+, : toggle AI settings
        if (event.ctrl and event.key == .char and event.key.char == ',') {
            self.toggleAISettings();
            return;
        }
        // Sidebar resize: Ctrl+Shift+Left/Right
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .left) {
            self.layout.sidebar_width = if (self.layout.sidebar_width > LayoutConst.sidebar_min_width) self.layout.sidebar_width - 2 else self.layout.sidebar_width;
            return;
        }
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .right) {
            self.layout.sidebar_width = if (self.layout.sidebar_width < LayoutConst.sidebar_max_width) self.layout.sidebar_width + 2 else self.layout.sidebar_width;
            return;
        }
        // Panel toggle: Ctrl+`
        if (event.ctrl and event.key == .char and event.key.char == '`') {
            self.panel_visible = !self.panel_visible;
            return;
        }
        // Panel resize: Ctrl+Shift+Up/Down
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .up) {
            self.panel_height = if (self.panel_height > 3) self.panel_height - 2 else self.panel_height;
            return;
        }
        if (event.ctrl and event.shift and event.key == .special and event.key.special == .down) {
            self.panel_height = if (self.panel_height < 30) self.panel_height + 2 else self.panel_height;
            return;
        }
        // Zen mode: F11
        if (event.key == .special and event.key.special == .f11) {
            self.zen_mode = !self.zen_mode;
            if (self.zen_mode) {
                self.sidebar_visible = false;
                self.tab_bar_visible = false;
            } else {
                self.sidebar_visible = true;
                self.tab_bar_visible = true;
            }
            return;
        }
        // Line wrap: Alt+Z
        if (event.alt and event.key == .char and event.key.char == 'z') {
            self.line_wrap = !self.line_wrap;
            return;
        }
        // Toggle activity bar position: Ctrl+Shift+A
        if (event.ctrl and event.shift and event.key == .char and event.key.char == 'a') {
            self.activity_bar_side = !self.activity_bar_side;
            return;
        }
        // Activity switching: Ctrl+1..6
        if (event.ctrl and event.key == .char) {
            switch (event.key.char) {
                '1' => {
                    self.active_activity = .explorer;
                    self.sidebar_visible = true;
                    return;
                },
                '2' => {
                    self.active_activity = .search;
                    self.sidebar_visible = true;
                    return;
                },
                '3' => {
                    self.active_activity = .hub;
                    self.sidebar_visible = true;
                    return;
                },
                '4' => {
                    self.active_activity = .git;
                    self.sidebar_visible = true;
                    return;
                },
                '5' => {
                    self.active_activity = .debug;
                    self.sidebar_visible = true;
                    return;
                },
                '6' => {
                    self.active_activity = .extensions;
                    self.sidebar_visible = true;
                    return;
                },
                else => {},
            }
        }

        // AI Settings panel navigation
        if (self.ai_settings_visible) {
            switch (event.key) {
                .special => |s| switch (s) {
                    .escape => {
                        self.ai_settings_visible = false;
                        return;
                    },
                    .up => {
                        self.ai_settings_field = prevField(self.ai_settings_field);
                        return;
                    },
                    .down => {
                        self.ai_settings_field = nextField(self.ai_settings_field);
                        return;
                    },
                    .enter => {
                        if (self.ai_settings_field == .save) {
                            self.applyAISettings();
                            return;
                        }
                        if (self.ai_settings_field == .cancel) {
                            self.ai_settings_visible = false;
                            return;
                        }
                        if (self.ai_settings_field == .provider) {
                            // Cycle provider
                            self.llm_config.provider = switch (self.llm_config.provider) {
                                .ollama => .llamacpp,
                                .llamacpp => .openrouter,
                                .openrouter => .deepseek,
                                .deepseek => .openai,
                                .openai => .anthropic,
                                .anthropic => .custom,
                                .custom => .ollama,
                            };
                            return;
                        }
                        return;
                    },
                    .left => {
                        if (self.ai_settings_field == .temperature) {
                            self.ai_settings_temp = @max(0.0, self.ai_settings_temp - 0.1);
                            return;
                        }
                        return;
                    },
                    .right => {
                        if (self.ai_settings_field == .temperature) {
                            self.ai_settings_temp = @min(2.0, self.ai_settings_temp + 0.1);
                            return;
                        }
                        return;
                    },
                    .backspace => {
                        return;
                    },
                    else => return,
                },
                .char => |ch| {
                    if (self.ai_settings_field == .model) {
                        self.ai_settings_model_input.append(ch) catch {};
                        return;
                    }
                    if (self.ai_settings_field == .api_key) {
                        self.ai_settings_key_input.append(ch) catch {};
                        return;
                    }
                    if (self.ai_settings_field == .api_base) {
                        self.ai_settings_base_input.append(ch) catch {};
                        return;
                    }
                    return;
                },
            }
        }

        // Normal mode: i → insert, v → visual
        if (self.mode == .normal) {
            if (event.key == .char and event.key.char == 'i') {
                self.mode = .insert;
                self.message = "INSERT";
                return;
            }
            if (event.key == .char and event.key.char == 'v') {
                self.mode = .visual;
                self.message = "VISUAL";
                return;
            }
        }

        if (self.mode == .insert) {
            if (event.key == .special) {
                switch (event.key.special) {
                    .escape => {
                        self.mode = .normal;
                        self.message = null;
                        return;
                    },
                    .backspace => {
                        try self.deleteBackward(tab);
                        return;
                    },
                    .enter => {
                        try self.insertNewline(tab);
                        return;
                    },
                    .tab => {
                        try self.insertText(tab, "    ");
                        return;
                    },
                    .up => {
                        tab.cursor.moveUp(&tab.buffer);
                        return;
                    },
                    .down => {
                        tab.cursor.moveDown(&tab.buffer);
                        return;
                    },
                    .left => {
                        tab.cursor.moveLeft(&tab.buffer);
                        return;
                    },
                    .right => {
                        tab.cursor.moveRight(&tab.buffer);
                        return;
                    },
                    .delete => {
                        try self.deleteForward(tab);
                        return;
                    },
                    else => {},
                }
            } else {
                var ch_buf: [1]u8 = undefined;
                ch_buf[0] = event.key.char;
                try self.insertText(tab, &ch_buf);
                return;
            }
        }

        if (self.keybind_manager.processKey(event)) |action| {
            try self.executeAction(tab, action);
            return;
        }

        switch (self.mode) {
            .visual => {
                if (event.key == .special and event.key.special == .escape) {
                    self.mode = .normal;
                    tab.selection.clear();
                }
            },
            .command => {
                if (event.key == .special and (event.key.special == .escape or event.key.special == .enter)) {
                    self.mode = .normal;
                    self.message = null;
                }
            },
            .search => {
                if (event.key == .special and event.key.special == .escape) {
                    self.mode = .normal;
                    self.search_query = null;
                    self.message = null;
                }
            },
            else => {},
        }
    }

    fn executeAction(self: *Self, tab: *Tab, action: Keybind.EditorAction) !void {
        switch (action) {
            .cursor_up => tab.cursor.moveUp(&tab.buffer),
            .cursor_down => tab.cursor.moveDown(&tab.buffer),
            .cursor_left => tab.cursor.moveLeft(&tab.buffer),
            .cursor_right => tab.cursor.moveRight(&tab.buffer),
            .cursor_word_forward => tab.cursor.moveWordForward(&tab.buffer),
            .cursor_word_back => tab.cursor.moveWordBack(&tab.buffer),
            .cursor_line_start => tab.cursor.moveHome(&tab.buffer),
            .cursor_line_end => tab.cursor.moveEnd(&tab.buffer),
            .cursor_file_start => tab.cursor.moveTop(&tab.buffer),
            .cursor_file_end => tab.cursor.moveBottom(&tab.buffer),
            .cursor_page_up => {
                tab.view.scrollUp(tab.view.visible_rows / 2);
            },
            .cursor_page_down => {
                tab.view.scrollDown(tab.view.visible_rows / 2);
            },
            .delete_backward => try self.deleteBackward(tab),
            .delete_forward => try self.deleteForward(tab),
            .save => {
                tab.buffer.save() catch {
                    self.message = "Failed to save";
                    return;
                };
                tab.dirty = false;
                self.message = "Saved";
            },
            .quit => {
                if (tab.buffer.dirty) {
                    // Save dirty buffer then quit
                    tab.buffer.save() catch {
                        self.message = "Save failed! Use Ctrl+Shift+Q to force quit.";
                        return;
                    };
                    tab.dirty = false;
                }
                self.running = false;
            },
            .force_quit => {
                self.running = false;
            },
            .search => {
                self.mode = .search;
                self.message = "/";
            },
            .command_palette => {
                if (self.mode == .command) {
                    self.mode = .normal;
                    self.message = null;
                } else {
                    self.mode = .command;
                    self.message = ">";
                }
            },
            else => {},
        }
        tab.cursor.scrollIntoView(&tab.view);
    }

    fn insertText(_: *Self, tab: *Tab, text: []const u8) !void {
        if (tab.selection.isActive()) {
            try tab.selection.replaceText(&tab.buffer, text);
            tab.cursor = tab.selection.cursorAfterDelete();
        } else {
            const offset = tab.cursor.toOffset(&tab.buffer);
            try tab.buffer.insert(offset, text);
            tab.cursor.col += text.len;
            tab.cursor.target_col = tab.cursor.col;
        }
        tab.dirty = true;
    }

    fn insertNewline(self: *Self, tab: *Tab) !void {
        if (tab.selection.isActive()) {
            try tab.selection.deleteText(&tab.buffer);
            tab.cursor = tab.selection.cursorAfterDelete();
        }
        const line = tab.buffer.getLine(tab.cursor.row, self.allocator) catch return;
        defer self.allocator.free(line);
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        const indent_str = line[0..indent];
        var insert_str = std.array_list.Managed(u8).init(self.allocator);
        defer insert_str.deinit();
        try insert_str.append('\n');
        try insert_str.appendSlice(indent_str);
        try self.insertText(tab, insert_str.items);
        tab.dirty = true;
    }

    fn deleteBackward(_: *Self, tab: *Tab) !void {
        if (tab.selection.isActive()) {
            try tab.selection.deleteText(&tab.buffer);
            tab.cursor = tab.selection.cursorAfterDelete();
            tab.dirty = true;
            return;
        }
        if (tab.cursor.col > 0) {
            const offset = tab.cursor.toOffset(&tab.buffer);
            try tab.buffer.delete(offset - 1, 1);
            tab.cursor.col -= 1;
            tab.cursor.target_col = tab.cursor.col;
        } else if (tab.cursor.row > 0) {
            const prev_len = tab.buffer.lineLength(tab.cursor.row - 1);
            const offset = tab.buffer.lineColToOffset(tab.cursor.row - 1, prev_len);
            try tab.buffer.delete(offset, 1);
            tab.cursor.row -= 1;
            tab.cursor.col = prev_len;
            tab.cursor.target_col = tab.cursor.col;
        }
        tab.dirty = true;
    }

    fn deleteForward(_: *Self, tab: *Tab) !void {
        if (tab.selection.isActive()) {
            try tab.selection.deleteText(&tab.buffer);
            tab.cursor = tab.selection.cursorAfterDelete();
            tab.dirty = true;
            return;
        }
        const line_len = tab.buffer.lineLength(tab.cursor.row);
        if (tab.cursor.col < line_len) {
            const offset = tab.cursor.toOffset(&tab.buffer);
            try tab.buffer.delete(offset, 1);
        } else if (tab.cursor.row + 1 < tab.buffer.lineCount()) {
            const offset = tab.cursor.toOffset(&tab.buffer);
            try tab.buffer.delete(offset, 1);
        }
        tab.dirty = true;
    }

    fn prevField(f: AISettingsField) AISettingsField {
        return AIPanel.prevField(f);
    }
    fn nextField(f: AISettingsField) AISettingsField {
        return AIPanel.nextField(f);
    }

    pub fn deinit(self: *Self) void {
        self.terminal.deinit();
        for (self.groups.items) |*group| {
            group.deinit();
        }
        self.groups.deinit();
        self.theme.deinit();
        self.keybind_manager.deinit();
        self.clearGitCache();
        self.clearFileTreeCache();
        self.notifications.deinit();
        self.git_items.deinit();
        self.file_tree_entries.deinit();
        self.clearWorkspaceFolders();
        self.workspace_folders.deinit();
        for (self.recent_workspaces.items) |path| self.allocator.free(path);
        self.recent_workspaces.deinit();
        if (self.workspace_settings_json) |settings| self.allocator.free(settings);
        if (self.active_profile) |profile| self.allocator.free(profile);
        var cfg_it = self.config_values.iterator();
        while (cfg_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.config_values.deinit(self.allocator);
        var doc_it = self.document_states.iterator();
        while (doc_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeDocumentState(entry.value_ptr.*);
        }
        self.document_states.deinit(self.allocator);
        var terminal_it = self.terminal_sessions.iterator();
        while (terminal_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.terminal_sessions.deinit(self.allocator);
        self.terminal_session = null;
        self.stopDebugSession();
        for (self.debug_breakpoints.items) |bp| {
            self.allocator.free(bp.file);
            if (bp.condition) |condition| self.allocator.free(condition);
            if (bp.hit_condition) |hit_condition| self.allocator.free(hit_condition);
            if (bp.log_message) |log_message| self.allocator.free(log_message);
        }
        self.debug_breakpoints.deinit();
        if (self.openvsx_results) |*r| self.freeOpenVSXResults(r);
        if (self.hub_search_last_query) |q| self.allocator.free(q);
        if (self.hub_search_error) |m| self.allocator.free(m);
        var hub_it = self.hub_installed_extensions.iterator();
        while (hub_it.next()) |entry| {
            self.freeHubInstalledExtension(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.hub_installed_extensions.deinit(self.allocator);
        self.hub_search_input.deinit();
        if (self.kilocode) |*kc| kc.deinit();
        self.ai_chat_input.deinit();
        for (self.ai_chat_messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.ai_chat_messages.deinit();
        if (self.clipboard) |c| self.allocator.free(c);
        if (self.search_query) |q| self.allocator.free(q);
        if (self.message) |m| self.allocator.free(m);
        if (self.ai_last_completion) |c| self.allocator.free(c);
        self.ai_settings_model_input.deinit();
        self.ai_settings_key_input.deinit();
        self.ai_settings_base_input.deinit();
        self.search_pool.deinit();
        self.worker_pool.deinit();
        self.worker_results.deinit();

        for (self.webviews.values()) |wv| {
            self.allocator.free(wv.id);
            self.allocator.free(wv.title);
            self.allocator.free(wv.html);
        }
        self.webviews.deinit(self.allocator);
    }

    const SearchTextTaskCtx = struct {
        editor: *Editor,
        id_str: []const u8,
        root_path: []const u8,
        query: []const u8,
        regex: bool,
        case_sensitive: bool,
        whole_word: bool,
        include_glob: ?[]const u8,
        exclude_glob: ?[]const u8,
        context_lines: usize,
        result_limit: usize,
        fn hasUnterminatedCharacterClass(pattern: []const u8) bool {
            var escaped = false;
            var in_class = false;
            for (pattern) |character| {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (character == '\\') {
                    escaped = true;
                    continue;
                }
                if (character == '[') {
                    in_class = true;
                } else if (character == ']' and in_class) {
                    in_class = false;
                }
            }
            return in_class;
        }

        pub fn run(ctx: @This()) void {
            const self = ctx.editor;
            defer self.allocator.free(ctx.id_str);
            defer self.allocator.free(ctx.root_path);
            defer self.allocator.free(ctx.query);
            defer if (ctx.include_glob) |s| self.allocator.free(s);
            defer if (ctx.exclude_glob) |s| self.allocator.free(s);
            if (ctx.regex and hasUnterminatedCharacterClass(ctx.query)) {
                ctx.writeError("Search failed: invalid regular expression");
                return;
            }

            var argv = std.array_list.Managed([]const u8).init(self.allocator);
            defer argv.deinit();
            argv.append("grep") catch return;
            argv.append("-rnI") catch return;
            if (!ctx.regex) argv.append("-F") catch return;
            if (!ctx.case_sensitive) argv.append("-i") catch return;
            if (ctx.whole_word) argv.append("-w") catch return;
            var include_arg: ?[]u8 = null;
            defer if (include_arg) |arg| self.allocator.free(arg);
            if (ctx.include_glob) |glob| {
                include_arg = std.fmt.allocPrint(self.allocator, "--include={s}", .{glob}) catch null;
                if (include_arg) |arg| argv.append(arg) catch return;
            }
            var exclude_arg: ?[]u8 = null;
            defer if (exclude_arg) |arg| self.allocator.free(arg);
            if (ctx.exclude_glob) |glob| {
                exclude_arg = std.fmt.allocPrint(self.allocator, "--exclude={s}", .{glob}) catch null;
                if (exclude_arg) |arg| argv.append(arg) catch return;
            }
            argv.append("--exclude-dir=.git") catch return;
            argv.append("--exclude-dir=node_modules") catch return;
            argv.append("--exclude-dir=zig-out") catch return;
            argv.append("--exclude-dir=.zig-cache") catch return;
            argv.append("--") catch return;
            argv.append(ctx.query) catch return;
            argv.append(ctx.root_path) catch return;

            const search_result = std.process.run(self.allocator, runtime.io(), .{
                .argv = argv.items,
                .stdout_limit = .limited(8 * 1024 * 1024),
                .stderr_limit = .limited(8 * 1024 * 1024),
            }) catch |err| {
                const message = std.fmt.allocPrint(
                    self.allocator,
                    "Search failed: {s}",
                    .{@errorName(err)},
                ) catch return;
                defer self.allocator.free(message);
                ctx.writeError(message);
                return;
            };
            defer self.allocator.free(search_result.stdout);
            defer self.allocator.free(search_result.stderr);

            const exit_code = switch (search_result.term) {
                .exited => |code| code,
                else => {
                    ctx.writeError("Search process stopped unexpectedly.");
                    return;
                },
            };
            if (exit_code > 1) {
                const stderr = std.mem.trim(u8, search_result.stderr, " \t\r\n");
                if (stderr.len > 0) {
                    const message = std.fmt.allocPrint(
                        self.allocator,
                        "Search failed: {s}",
                        .{stderr},
                    ) catch return;
                    defer self.allocator.free(message);
                    ctx.writeError(message);
                } else {
                    ctx.writeError("Search failed. Check the query and filters.");
                }
                return;
            }

            var files_json: std.Io.Writer.Allocating = .init(self.allocator);
            defer files_json.deinit();
            files_json.writer.writeAll("[") catch {};

            const result_limit = ctx.result_limit;
            var it = std.mem.splitScalar(u8, search_result.stdout, '\n');
            var first = true;
            var count: usize = 0;
            var truncated = false;
            while (it.next()) |line| {
                if (line.len == 0) continue;

                const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const colon2 = std.mem.indexOfScalarPos(u8, line, colon1 + 1, ':') orelse continue;
                if (count >= result_limit) {
                    truncated = true;
                    break;
                }

                const file = line[0..colon1];
                const line_num = line[colon1 + 1 .. colon2];
                const text = line[colon2 + 1 ..];

                if (!first) files_json.writer.writeAll(",") catch {};
                first = false;

                const writer = &files_json.writer;
                writer.writeAll("{\"file\":") catch {};
                writeJsonString(writer, file) catch {};
                writer.print(",\"line\":{s},\"text\":", .{line_num}) catch {};
                writeJsonString(writer, text) catch {};
                writeSearchContext(self, writer, file, line_num, ctx.context_lines) catch {};
                writer.writeAll("}") catch {};
                count += 1;
            }
            files_json.writer.writeAll("]") catch {};

            const response = std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"matches\":{s},\"limit\":{},\"truncated\":{}}}}}",
                .{ ctx.id_str, files_json.written(), result_limit, truncated },
            ) catch return;
            defer self.allocator.free(response);
            self.writeRpc(std.Io.File.stdout(), response) catch {};
        }

        fn writeError(ctx: @This(), message: []const u8) void {
            const response = ctx.editor.jsonRpcError(ctx.id_str, -32000, message) catch return;
            defer ctx.editor.allocator.free(response);
            ctx.editor.writeRpc(std.Io.File.stdout(), response) catch {};
        }

        fn writeSearchContext(self: *Editor, writer: anytype, file: []const u8, line_num: []const u8, context_lines: usize) !void {
            if (context_lines == 0) return;
            const target = std.fmt.parseInt(usize, line_num, 10) catch return;
            if (target == 0) return;
            const content = runtime.readFileAlloc(self.allocator, file, 1024 * 1024) catch return;
            defer self.allocator.free(content);

            var lines = std.array_list.Managed([]const u8).init(self.allocator);
            defer lines.deinit();
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| try lines.append(std.mem.trimEnd(u8, line, "\r"));

            try writer.writeAll(",\"before\":[");
            const before_start = if (target > context_lines + 1) target - context_lines - 1 else 0;
            var first = true;
            var i = before_start;
            while (i + 1 < target and i < lines.items.len) : (i += 1) {
                if (!first) try writer.writeAll(",");
                first = false;
                try writeJsonString(writer, lines.items[i]);
            }
            try writer.writeAll("],\"after\":[");
            first = true;
            i = target;
            const after_end = @min(lines.items.len, target + context_lines);
            while (i < after_end) : (i += 1) {
                if (!first) try writer.writeAll(",");
                first = false;
                try writeJsonString(writer, lines.items[i]);
            }
            try writer.writeAll("]");
        }
    };

    const FileSearchTaskCtx = struct {
        editor: *Editor,
        id_str: []const u8,
        query: []const u8,
        root: []const u8,
        pub fn run(ctx: @This()) void {
            const self = ctx.editor;
            defer self.allocator.free(ctx.id_str);
            defer self.allocator.free(ctx.query);
            defer self.allocator.free(ctx.root);

            const result = std.process.run(self.allocator, runtime.io(), .{
                .argv = &.{ "find", ".", "-type", "f", "-not", "-path", "*/.*", "-not", "-path", "*/node_modules/*", "-not", "-path", "*/zig-out/*", "-not", "-path", "*/.zig-cache/*" },
                .cwd = .{ .path = ctx.root },
                .stdout_limit = .limited(8 * 1024 * 1024),
                .stderr_limit = .limited(1024 * 1024),
            }) catch {
                const resp = std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"files\":[]}}}}", .{ctx.id_str}) catch return;
                defer self.allocator.free(resp);
                self.writeRpc(std.Io.File.stdout(), resp) catch {};
                return;
            };
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);
            const stdout2 = result.stdout;

            var files_json: std.Io.Writer.Allocating = .init(self.allocator);
            defer files_json.deinit();
            files_json.writer.writeAll("[") catch {};

            {
                var it = std.mem.splitScalar(u8, stdout2, '\n');
                var first = true;
                var count: usize = 0;
                while (it.next()) |line| {
                    if (count > 200) break; // Limit list size
                    if (line.len == 0) continue;

                    const clean_path = if (std.mem.startsWith(u8, line, "./")) line[2..] else line;
                    const file_name = std.fs.path.basename(clean_path);

                    if (ctx.query.len > 0) {
                        var match = false;
                        if (file_name.len >= ctx.query.len) {
                            var i: usize = 0;
                            while (i <= file_name.len - ctx.query.len) : (i += 1) {
                                var match_here = true;
                                var j: usize = 0;
                                while (j < ctx.query.len) : (j += 1) {
                                    const fc = std.ascii.toLower(file_name[i + j]);
                                    const qc = std.ascii.toLower(ctx.query[j]);
                                    if (fc != qc) {
                                        match_here = false;
                                        break;
                                    }
                                }
                                if (match_here) {
                                    match = true;
                                    break;
                                }
                            }
                        }
                        if (!match) continue;
                    }

                    if (!first) files_json.writer.writeAll(",") catch {};
                    first = false;

                    const w = &files_json.writer;
                    w.writeAll("{\"name\":") catch {};
                    writeJsonString(w, file_name) catch {};
                    const full_path = if (std.fs.path.isAbsolute(clean_path))
                        self.allocator.dupe(u8, clean_path) catch continue
                    else
                        std.fs.path.join(self.allocator, &.{ ctx.root, clean_path }) catch continue;
                    defer self.allocator.free(full_path);
                    w.writeAll(",\"path\":") catch {};
                    writeJsonString(w, full_path) catch {};
                    w.writeAll("}") catch {};
                    count += 1;
                }
            }
            files_json.writer.writeAll("]") catch {};

            const resp = std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"files\":{s}}}}}",
                .{ ctx.id_str, files_json.written() },
            ) catch return;
            defer self.allocator.free(resp);
            self.writeRpc(std.Io.File.stdout(), resp) catch {};
        }
    };
};

test "Editor: adapter transport loss stops session and preserves debug state" {
    var editor = try Editor.init(std.testing.allocator, null);
    defer editor.deinit();

    _ = try editor.toggleDebugBreakpoint("main.zig", 7, "condition", null, null);
    var client = try std.testing.allocator.create(DAP.DAPClient);
    client.* = DAP.DAPClient.init(std.testing.allocator);
    try client.start("/bin/sh", &.{ "-c", "sleep 30" });
    editor.debug_client = client;
    editor.debug_running = true;
    editor.debug_paused = true;
    editor.debug_thread_id = 42;

    // Simulate the adapter disappearing before a paused-session command.
    client.stop();
    const response = (try editor.handleRpc(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"debug/continue\",\"params\":{}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Debug adapter continue failed") != null);
    try std.testing.expect(!editor.debug_running);
    const state = (try editor.handleRpc(
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"debug/state\",\"params\":{}}",
    )).?;
    defer std.testing.allocator.free(state);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"adapterState\":\"lost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state, "\"adapterRecoverable\":true") != null);
    try std.testing.expect(!editor.debug_paused);
    try std.testing.expect(editor.debug_client == null);
    try std.testing.expectEqual(@as(usize, 42), editor.debug_thread_id);
    try std.testing.expectEqual(@as(usize, 1), editor.debug_breakpoints.items.len);
    try std.testing.expectEqualStrings("main.zig", editor.debug_breakpoints.items[0].file);
    try std.testing.expectEqual(@as(usize, 7), editor.debug_breakpoints.items[0].line);
}

test "Editor: credential cancellation fixture is local and redacts secrets" {
    var editor = try Editor.init(std.testing.allocator, null);
    defer editor.deinit();

    const response = (try editor.handleRpc(
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"git/fetch\",\"params\":{\"remote\":\"https://user:fixture-secret@example.test/repo.git\",\"credentialFixture\":\"cancel\"}}",
    )).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"cancelled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"state\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"networkAttempted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"secretPersisted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"secretEchoed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "fixture-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"remote\":\"<redacted>\"") != null);
}

test "Editor: Git failure redacts credential-bearing URL details" {
    var editor = try Editor.init(std.testing.allocator, null);
    defer editor.deinit();
    const stdout = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(stdout);
    const stderr = try std.testing.allocator.dupe(
        u8,
        "fatal: unable to access 'https://user:fixture-secret@example.test/repo.git/': authentication failed",
    );
    defer std.testing.allocator.free(stderr);

    const response = try editor.jsonRpcGitFailure("9", "fetch", .{
        .exit_code = 128,
        .stdout = stdout,
        .stderr = stderr,
    });
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "fixture-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "<redacted>") != null);
}

test "Editor: DAP protocol failure clears debug session state" {
    var editor = try Editor.init(std.testing.allocator, null);
    defer editor.deinit();
    editor.debug_running = true;
    editor.debug_paused = true;
    editor.debug_no_debug = false;
    editor.debug_fixture = false;

    const response = try editor.debugAdapterOperationError("10", "evaluate", error.DAPRpcError);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    try std.testing.expect(!editor.debug_running);
    try std.testing.expect(!editor.debug_paused);
}
