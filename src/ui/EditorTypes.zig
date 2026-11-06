// WIZP EditorTypes — shared type definitions for Editor and its sub-modules
// Extracted from Editor.zig to enable splitting the monolith.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("../buffer/Buffer.zig");
const Cursor = @import("../buffer/Cursor.zig");
const Selection = @import("../buffer/Selection.zig");
const View = @import("../buffer/View.zig");

pub const EditorMode = enum { normal, insert, visual, command, search };
pub const PanelType = enum { terminal, problems, output, debug_console };
pub const ActivityItem = enum { explorer, search, hub, git, debug, extensions };
pub const SplitDir = enum { none, horizontal, vertical };

pub const ACTIVITY_ICONS = std.StaticStringMap([]const u8).initComptime(.{
    .{ "explorer", "Fi" },
    .{ "search", "Se" },
    .{ "hub", "Hu" },
    .{ "git", "Gi" },
    .{ "debug", "De" },
    .{ "extensions", "Ex" },
});

pub const Layout = struct {
    sidebar_width: usize = 20,
    sidebar_visible: bool = false,
};

pub const LayoutConst = struct {
    pub const activity_width: usize = 2;
    pub const sidebar_min_width: usize = 15;
    pub const sidebar_max_width: usize = 40;
    pub const minimap_width: usize = 8;
    pub const tab_height: usize = 1;
    pub const breadcrumb_height: usize = 1;
    pub const status_height: usize = 1;
};

pub const Tab = struct {
    file_path: []const u8,
    buffer: Buffer,
    cursor: Cursor,
    view: View,
    selection: Selection,
    dirty: bool,
    active: bool,
};

pub const EditorGroup = struct {
    tabs: std.array_list.Managed(Tab),
    active_tab: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) EditorGroup {
        return .{
            .allocator = allocator,
            .tabs = std.array_list.Managed(Tab).init(allocator),
        };
    }
    pub fn addTab(self: *EditorGroup, path: []const u8, buf: Buffer) !void {
        const path_dup = try self.allocator.dupe(u8, path);
        try self.tabs.append(.{ .file_path = path_dup, .buffer = buf, .cursor = Cursor.at(0, 0), .view = View.init(), .selection = Selection.init(), .dirty = false, .active = true });
        self.active_tab = self.tabs.items.len - 1;
    }
    pub fn closeTab(self: *EditorGroup, index: usize) void {
        if (self.tabs.items.len <= 1) return;
        self.tabs.items[index].buffer.deinit();
        self.allocator.free(self.tabs.items[index].file_path);
        _ = self.tabs.orderedRemove(index);
        if (self.active_tab >= self.tabs.items.len) self.active_tab = self.tabs.items.len - 1;
    }
    pub fn closeOtherTabs(self: *EditorGroup) void {
        if (self.tabs.items.len <= 1) return;
        var i: usize = self.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (i != self.active_tab) {
                self.tabs.items[i].buffer.deinit();
                self.allocator.free(self.tabs.items[i].file_path);
                _ = self.tabs.orderedRemove(i);
                if (i < self.active_tab) self.active_tab -= 1;
            }
        }
    }
    pub fn closeTabsToRight(self: *EditorGroup) void {
        while (self.tabs.items.len > self.active_tab + 1) {
            const idx = self.tabs.items.len - 1;
            self.tabs.items[idx].buffer.deinit();
            self.allocator.free(self.tabs.items[idx].file_path);
            _ = self.tabs.orderedRemove(idx);
        }
    }
    pub fn getActiveTab(self: *EditorGroup) *Tab {
        return &self.tabs.items[self.active_tab];
    }
    pub fn removeTab(self: *EditorGroup, index: usize) Tab {
        const tab = self.tabs.orderedRemove(index);
        if (self.active_tab >= self.tabs.items.len and self.tabs.items.len > 0) self.active_tab = self.tabs.items.len - 1;
        return tab;
    }
    pub fn insertTabAt(self: *EditorGroup, index: usize, tab: Tab) !void {
        try self.tabs.insert(index, tab);
        if (self.active_tab >= index) self.active_tab += 1;
    }
    pub fn moveTabLeft(self: *EditorGroup) void {
        if (self.active_tab > 0) {
            const tab = self.tabs.orderedRemove(self.active_tab);
            self.tabs.insert(self.active_tab - 1, tab) catch {};
            self.active_tab -= 1;
        }
    }
    pub fn moveTabRight(self: *EditorGroup) void {
        if (self.active_tab < self.tabs.items.len - 1) {
            const tab = self.tabs.orderedRemove(self.active_tab);
            self.tabs.insert(self.active_tab + 1, tab) catch {};
            self.active_tab += 1;
        }
    }
    pub fn cycleNext(self: *EditorGroup) void {
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
    }
    pub fn cyclePrev(self: *EditorGroup) void {
        self.active_tab = (self.active_tab + self.tabs.items.len - 1) % self.tabs.items.len;
    }
    pub fn deinit(self: *EditorGroup) void {
        for (self.tabs.items) |*tab| {
            tab.buffer.deinit();
            self.allocator.free(tab.file_path);
        }
        self.tabs.deinit();
    }
};
