// UI tools: snippets, build systems, completions UI, minimap, split view, floating windows
// Reuses patterns from flow (completion dropdown, editor gutter) and pixi (floating widgets)

const std = @import("std");
const runtime = @import("../runtime_016.zig");
const Allocator = std.mem.Allocator;

// ============================================================
// Snippets (.sublime-snippet compatible)
// ============================================================

pub const Snippet = struct {
    trigger: []const u8,
    content: []const u8,
    description: []const u8 = "",
    scope: []const u8 = "",

    /// Tab stops: $1, $2, ${1:text}, $0 (final position)
    pub fn expand(allocator: Allocator, snippet: Snippet, tab_stops: *TabStopManager) ![]const u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        var i: usize = 0;
        while (i < snippet.content.len) {
            if (snippet.content[i] == '$' and i + 1 < snippet.content.len) {
                i += 1;
                if (snippet.content[i] == '$') {
                    try result.append('$');
                    i += 1;
                    continue;
                }
                // Parse tab stop number
                var num: usize = 0;
                while (i < snippet.content.len and std.ascii.isDigit(snippet.content[i])) : (i += 1) {
                    num = num * 10 + (snippet.content[i] - '0');
                }
                // Check for default text ${N:text}
                if (i < snippet.content.len and snippet.content[i] == '{') {
                    i += 1;
                    var depth: usize = 1;
                    while (i < snippet.content.len and depth > 0) {
                        if (snippet.content[i] == '{') depth += 1;
                        if (snippet.content[i] == '}') depth -= 1;
                        if (depth > 0) i += 1;
                    }
                    if (i < snippet.content.len) i += 1;
                }
                _ = try tab_stops.addStop(allocator, num, result.items.len);
                var marker: [32]u8 = undefined;
                const marker_text = try std.fmt.bufPrint(&marker, "[TAB_STOP_{d}]", .{num});
                try result.appendSlice(marker_text);
            } else {
                try result.append(snippet.content[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice();
    }
};

pub const TabStopManager = struct {
    stops: std.array_list.Managed(TabStop),
    current_stop: usize = 0,

    pub const TabStop = struct {
        number: usize,
        position: usize, // byte offset in expanded text
    };

    pub fn addStop(self: *TabStopManager, _: Allocator, number: usize, position: usize) !TabStop {
        const stop = TabStop{ .number = number, .position = position };
        try self.stops.append(stop);
        return stop;
    }

    pub fn nextStop(self: *TabStopManager) ?usize {
        if (self.stops.items.len == 0) return null;
        const current = self.stops.items[self.current_stop].number;
        self.current_stop = (self.current_stop + 1) % self.stops.items.len;
        return current;
    }

    pub fn deinit(self: *TabStopManager, _: Allocator) void {
        self.stops.deinit();
    }

    const Self = @This();
};

// ============================================================
// Build Systems (.sublime-build compatible)
// ============================================================

pub const BuildSystem = struct {
    name: []const u8,
    cmd: []const []const u8,
    selector: []const u8 = "",
    working_dir: []const u8 = ".",
    file_patterns: []const []const u8 = &.{},
    variants: []const BuildVariant = &.{},

    pub const BuildVariant = struct {
        name: []const u8,
        cmd: []const []const u8,
    };

    pub fn run(allocator: Allocator, system: BuildSystem, variant: ?[]const u8) !BuildResult {
        const cmd = if (variant) |v| blk: {
            for (system.variants) |var_item| {
                if (std.mem.eql(u8, var_item.name, v)) break :blk var_item.cmd;
            }
            break :blk system.cmd;
        } else system.cmd;

        const result = try std.process.run(allocator, runtime.io(), .{
            .argv = cmd,
            .cwd = .{ .path = system.working_dir },
            .stdout_limit = .limited(10 * 1024 * 1024),
            .stderr_limit = .limited(10 * 1024 * 1024),
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
};

pub const BuildResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

// ============================================================
// Completion UI (dropdown from LSP + words)
// ============================================================

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind = .text,
    detail: []const u8 = "",
    documentation: []const u8 = "",
    insert_text: []const u8 = "",
    filter_text: []const u8 = "",
    sort_text: []const u8 = "",
    score: f32 = 0.0,

    pub const CompletionKind = enum {
        text,
        method,
        function,
        constructor,
        field,
        variable,
        class,
        interface,
        module,
        property,
        unit,
        value,
        enum_val,
        keyword,
        snippet,
        color,
        file,
        reference,
        folder,
        enum_member,
        constant,
        struct_val,
        event,
        operator,
        type_param,
    };
};

pub const CompletionUI = struct {
    allocator: Allocator,
    items: std.array_list.Managed(CompletionItem),
    selected: usize = 0,
    visible: bool = false,
    prefix: []const u8 = "",
    max_visible: usize = 10,

    pub fn init(allocator: Allocator) CompletionUI {
        return .{ .allocator = allocator };
    }

    pub fn show(self: *CompletionUI, prefix: []const u8) !void {
        self.prefix = prefix;
        self.selected = 0;
        self.visible = true;
    }

    pub fn hide(self: *CompletionUI) void {
        self.visible = false;
        self.items.clearRetainingCapacity();
    }

    pub fn filterByPrefix(self: *CompletionUI, prefix: []const u8) ![]const CompletionItem {
        var filtered = std.array_list.Managed(CompletionItem).init(self.allocator);
        for (self.items.items) |item| {
            const filter = if (item.filter_text.len > 0) item.filter_text else item.label;
            if (fuzzyMatches(prefix, filter)) {
                try filtered.append(item);
            }
        }
        // Sort by score descending
        std.mem.sort(CompletionItem, filtered.items, {}, struct {
            fn lt(_: void, a: CompletionItem, b: CompletionItem) bool {
                return a.score > b.score;
            }
        }.lt);
        return filtered.toOwnedSlice();
    }

    pub fn selectNext(self: *CompletionUI) void {
        if (self.items.items.len > 0) {
            self.selected = (self.selected + 1) % self.items.items.len;
        }
    }

    pub fn selectPrev(self: *CompletionUI) void {
        if (self.items.items.len > 0) {
            self.selected = (self.selected + self.items.items.len - 1) % self.items.items.len;
        }
    }

    pub fn getSelected(self: *CompletionUI) ?CompletionItem {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.selected];
    }

    pub fn deinit(self: *CompletionUI) void {
        self.items.deinit();
    }
};

fn fuzzyMatches(prefix: []const u8, candidate: []const u8) bool {
    if (prefix.len == 0) return true;
    var pi: usize = 0;
    for (candidate) |ch| {
        if (pi < prefix.len and std.ascii.toLower(ch) == std.ascii.toLower(prefix[pi])) {
            pi += 1;
            if (pi == prefix.len) return true;
        }
    }
    return false;
}

// ============================================================
// Minimap
// ============================================================

pub const Minimap = struct {
    width: usize = 8,
    visible: bool = true,
    /// Char-scale rendering buffer
    buffer: std.array_list.Managed(u8),

    pub fn init(allocator: Allocator) Minimap {
        return .{ .buffer = std.array_list.Managed(u8).init(allocator) };
    }

    /// Render minimap from buffer content
    pub fn render(allocator: Allocator, lines: []const []const u8, height: usize, map_width: usize) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        const scale = @max(1, lines.len / height);

        var i: usize = 0;
        while (i < lines.len and buf.items.len / map_width < height) : (i += scale) {
            const line = lines[i];
            // Crude visual representation: count non-whitespace density
            var density: usize = 0;
            for (line) |ch| {
                if (ch != ' ' and ch != '\t') density += 1;
            }
            const level: u8 = if (density == 0) ' ' else if (density < 10) '.' else if (density < 30) '-' else if (density < 60) ':' else '#';
            try buf.append(level);
        }
        return buf.toOwnedSlice();
    }

    pub fn deinit(self: *Minimap, _: Allocator) void {
        self.buffer.deinit();
    }
};

// ============================================================
// Split View (multiple editor panes)
// ============================================================

pub const SplitDirection = enum { horizontal, vertical };

pub const Pane = struct {
    id: usize,
    buffer_id: ?usize,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
};

pub const SplitView = struct {
    panes: std.array_list.Managed(Pane),
    active_pane: usize = 0,
    direction: SplitDirection = .vertical,

    pub fn init(allocator: Allocator) SplitView {
        return .{ .panes = std.array_list.Managed(Pane).init(allocator) };
    }

    pub fn split(self: *SplitView, allocator: Allocator, direction: SplitDirection) !usize {
        _ = allocator;
        const id = self.panes.items.len;
        try self.panes.append(.{
            .id = id,
            .buffer_id = if (self.panes.items.len > 0) self.panes.items[self.active_pane].buffer_id else null,
        });
        self.active_pane = id;
        self.direction = direction;
        return id;
    }

    pub fn closePane(self: *SplitView, id: usize) void {
        if (self.panes.items.len <= 1) return;
        for (self.panes.items, 0..) |p, i| {
            if (p.id == id) {
                _ = self.panes.orderedRemove(i);
                if (self.active_pane >= self.panes.items.len) {
                    self.active_pane = self.panes.items.len - 1;
                }
                return;
            }
        }
    }

    pub fn nextPane(self: *SplitView) void {
        self.active_pane = (self.active_pane + 1) % self.panes.items.len;
    }

    pub fn prevPane(self: *SplitView) void {
        self.active_pane = (self.active_pane + self.panes.items.len - 1) % self.panes.items.len;
    }

    pub fn getActivePane(self: *SplitView) ?*Pane {
        if (self.panes.items.len == 0) return null;
        return &self.panes.items[self.active_pane];
    }

    pub fn deinit(self: *SplitView, _: Allocator) void {
        self.panes.deinit();
    }

    const Self = @This();
};

// ============================================================
// Floating Windows (tooltips, docs, completion details)
// ============================================================

pub const FloatingWindow = struct {
    content: []const u8 = "",
    row: usize = 0,
    col: usize = 0,
    width: usize = 60,
    height: usize = 10,
    visible: bool = false,
    border: bool = true,
};

pub const FloatingWindowManager = struct {
    windows: std.array_list.Managed(FloatingWindow),

    pub fn init(allocator: Allocator) FloatingWindowManager {
        return .{ .windows = std.array_list.Managed(FloatingWindow).init(allocator) };
    }

    pub fn show(self: *FloatingWindowManager, allocator: Allocator, content: []const u8, row: usize, col: usize) !void {
        try self.windows.append(.{
            .content = try allocator.dupe(u8, content),
            .row = row,
            .col = col,
            .visible = true,
        });
    }

    pub fn hideAll(self: *FloatingWindowManager, allocator: Allocator) void {
        for (self.windows.items) |w| {
            allocator.free(w.content);
        }
        self.windows.clearRetainingCapacity();
    }

    pub fn deinit(self: *FloatingWindowManager, allocator: Allocator) void {
        self.hideAll(allocator);
        self.windows.deinit();
    }

    const Self = @This();
};
