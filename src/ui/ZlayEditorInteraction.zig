const std = @import("std");
const zlay = @import("zlay");

pub const ElementId = zlay.interaction.ElementId;
const Interaction = zlay.interaction.Interaction;
const Key = zlay.text_widgets.Key;
const TextInput = zlay.text_widgets.TextInput;
const VirtualListState = zlay.text_widgets.VirtualListState;

pub const Model = struct {
    interaction: Interaction,
    lines: VirtualListState,
    query: TextInput,

    pub fn init(
        focus_storage: []ElementId,
        query_storage: []u8,
        line_count: usize,
        viewport_lines: usize,
        scroll_offset: usize,
        focused_surface: usize,
    ) !Model {
        var model = Model{
            .interaction = Interaction.init(focus_storage),
            .lines = try VirtualListState.init(line_count, 1, @floatFromInt(viewport_lines), @floatFromInt(scroll_offset), 2),
            .query = TextInput.init(query_storage),
        };
        for (0..@min(focus_storage.len, 8)) |index| {
            try model.interaction.register(.{ .id = @intCast(index + 1) });
        }
        _ = model.interaction.focusAt(if (focused_surface > 0) focused_surface - 1 else 0);
        return model;
    }

    pub fn setQuery(self: *Model, value: []const u8) !void {
        try self.query.setSlice(value);
    }

    pub fn handleQueryKey(self: *Model, key: Key, shift: bool) !bool {
        return self.query.handleKeyWithModifiers(key, shift);
    }

    pub fn focusNext(self: *Model) ?usize {
        const id = self.interaction.focusNext() orelse return null;
        return id.id;
    }

    pub fn dispatchKeyboard(self: *const Model) DispatchSnapshot {
        const decision = self.interaction.dispatch(.{ .kind = .keyboard });
        return .{
            .hovered_surface = 0,
            .target_surface = if (decision.target) |id| id.id else 0,
            .dispatch_kind = decision.kind,
        };
    }

    pub fn dispatchPointer(self: *Model, hit_surface: ?usize, capture_surface: ?usize, release_capture: bool) !DispatchSnapshot {
        if (capture_surface) |surface| try self.interaction.capturePointer(.{ .id = @intCast(surface) });
        const hit_target = if (hit_surface) |surface| ElementId{ .id = @intCast(surface) } else null;
        const decision = self.interaction.dispatchPointer(.{
            .kind = .pointer,
            .hit_target = hit_target,
            .pointer_phase = if (release_capture) .up else .down,
        });
        if (release_capture) _ = self.interaction.releasePointer();
        return .{
            .hovered_surface = if (self.interaction.hovered()) |id| id.id else 0,
            .target_surface = if (decision.target) |id| id.id else 0,
            .dispatch_kind = decision.kind,
        };
    }

    pub fn snapshot(self: *const Model) !Snapshot {
        const visible = try self.lines.visibleRange();
        const focused = self.interaction.focused();
        return .{
            .focused_surface = if (focused) |id| id.id else 0,
            .visible_start = visible.start,
            .visible_end = visible.end,
            .query_length = self.query.len(),
            .query_cursor = self.query.cursorPosition(),
        };
    }
};

pub const DispatchSnapshot = struct {
    hovered_surface: usize,
    target_surface: usize,
    dispatch_kind: zlay.interaction.DispatchKind,
};

pub const Snapshot = struct {
    focused_surface: usize,
    visible_start: usize,
    visible_end: usize,
    query_length: usize,
    query_cursor: usize,
};
test "retained editor model dispatches focus, pointer, viewport, and query" {
    var focus_storage: [8]ElementId = undefined;
    var query_storage: [256]u8 = undefined;
    var model = try Model.init(&focus_storage, &query_storage, 120, 20, 37, 8);
    try model.setQuery("alpha");
    const snapshot = try model.snapshot();
    try std.testing.expectEqual(@as(usize, 8), snapshot.focused_surface);
    try std.testing.expectEqual(@as(usize, 35), snapshot.visible_start);
    try std.testing.expectEqual(@as(usize, 59), snapshot.visible_end);
    try std.testing.expectEqual(@as(usize, 5), snapshot.query_cursor);
    const keyboard = model.dispatchKeyboard();
    try std.testing.expectEqual(@as(usize, 8), keyboard.target_surface);
    try std.testing.expectEqual(zlay.interaction.DispatchKind.focused, keyboard.dispatch_kind);
    const pointer = try model.dispatchPointer(3, 8, false);
    try std.testing.expectEqual(@as(usize, 3), pointer.hovered_surface);
    try std.testing.expectEqual(@as(usize, 8), pointer.target_surface);
    try std.testing.expectEqual(zlay.interaction.DispatchKind.captured, pointer.dispatch_kind);
}
